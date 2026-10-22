# Existing Business Logic and Workflows

This describes what CompuLab **actually does today** (2026-10-22), traced through the code. It is not what the system was intended to do. It describes `main`. Where branch `phase1-security-fixes` (commit `1c57df4`; committed locally, not pushed or deployed) changes the behavior, a **Phase 1 branch** note says so ([SYSTEM_AUDIT.md §6](SYSTEM_AUDIT.md#6-phase-1-remediation-branch-phase1-security-fixes)). Evidence labels (Observed / Tested / Assumption / Unverified) are defined in [SYSTEM_AUDIT.md](SYSTEM_AUDIT.md#evidence-labels-used-throughout).

Each workflow is written as:
**User action → URL → View or service → Validation → Database operation → Response → Next step.**

---

## 1. Roles

| Role | Signs in to the website? | Can do | Notes |
|---|---|---|---|
| Superuser | Yes (also `/admin/`) | Everything; exempt from email verification | Created only with `manage.py createsuperuser` |
| Admin (`role='admin'`) | Yes, after email verification | User management, all labs, reservations, reports, logs | Not a Django superuser unless created that way |
| Lab In-Charge (`incharge`) | Yes, after verification | Their `assigned_lab`: PC status, override, manual unlock, reservations, inventory, issues, reports (scoped) | Lab scoping is enforced in most views, **not** in Override/Manual Unlock POST (audit M2), and not in reservation management. **Phase 1 branch:** both are lab-scoped |
| Instructor | Yes, after verification | Own reservations, own rosters (list only, see audit H3), attendance, issue reports, alerts | Sets own password on first verification. **Phase 1 branch:** every roster view is scoped to their own rosters |
| Student | **Never** | Unlocks a lab PC with ID number + reservation code | No usable password. Email is used only for notifications |

There is **no public self-registration**. Every account is created by an Admin (or by `createsuperuser`). In this codebase, "registration" means *an Admin creates the account*.

---

## 2. Workflows

### 2.1 Staff account creation (the "registration" flow)

1. **Admin opens Users → Add user** → `GET /accounts/users/add/` → `UserCreateView` (admin only) → form `AdminUserCreateForm`.
2. **Submit** → `POST` same URL. Validation:
   - Gmail-only email ([email_rules.py](../accounts/email_rules.py));
   - email unique;
   - ID number unique (case-insensitive);
   - department/year-level consistency;
   - role-specific rules: Admin requires a password typed by the creating admin; In-Charge and Instructor get **no password** (`set_unusable_password()`); Student requires email, ID, department and year, and gets no password.
3. **Database:** `INSERT accounts_user` (`email_verified=False`), then `INSERT accounts_activitylog` (`register`).
4. **Email (synchronous):**
   - non-students get `send_verification_email()`: it sets `email_verification_sent_at`, sends a signed 72-hour link, and on SMTP failure restores the previous timestamp and logs the error;
   - students get `send_student_welcome_email()`, with errors logged.
5. **Response:** redirect to the Users list with "verification email was sent" or "could not be sent — use Resend".
6. **Next step:** the account owner clicks the link (§2.2).

Source: [accounts/views.py:742](../accounts/views.py#L742), [accounts/forms.py:92](../accounts/forms.py#L92).

### 2.2 Email verification

1. **User clicks the link** → `GET /accounts/verify-email/<uidb64>/<token>/` → `verify_email`.
2. **Validation:** `EmailVerificationTokenGenerator.check_status()` returns `valid`, `expired` (more than 72 h), `used` (a genuine link for an already-verified account) or `invalid` (tampered, superseded by a newer link, wrong account, or the email has changed since).
3. **If the account has no usable password** (In-Charge or Instructor first time): show the set-password form. `POST` validates with Django's password validators and saves `password` and `email_verified=True`.
4. **Otherwise** (Admin, or re-verification after an email change): `UPDATE email_verified=True`.
5. **Response:** a result page (verified, password set, expired, used or invalid), with a resend form.
6. **Resend:**
   - the public form `/accounts/verify-email/resend/` always answers the same way, whether or not the account exists;
   - it is rate-limited by a 120 s per-account cooldown, 5 per account per day and 30 site-wide per hour;
   - the admin button `/accounts/users/<pk>/resend-verification/` respects the cooldown.

Tested by 25 tests in [accounts/tests.py](../accounts/tests.py) (all pass).

### 2.3 Login and logout (staff)

1. **User enters email + password** → `POST /accounts/login/` → `CompulabLoginView`.
2. **Authentication:** `VerifiedEmailBackend` (Django `ModelBackend`) refuses inactive accounts and any account that `requires_verification()`. The form turns "correct password but unverified" into a helpful message; otherwise it gives the generic error.
3. **Extra checks:** students are refused even if they somehow had a password. Failed attempts are counted per email in the file cache (15 minutes). On the 3rd failure, all Admins get an in-app notification **and an email**. Attempts are **never blocked**.
4. **Database:** session row in `django_session`; `last_login` updated.
5. **Response:** always redirect to `role_redirect`, then the role's own dashboard (`?next=` is ignored).
6. **Logout:** Django's `LogoutView` (POST).

Every later request re-runs the verification check through `get_user()`, so un-verifying an account ends its sessions.

### 2.4 Password reset

**Self-service (online only)**

1. `POST /accounts/password_reset/` with an email → `CompulabPasswordResetView`.
2. Django sends a reset link (built from `SITE_DOMAIN`) **synchronously**. In Django 5.0, a send failure is logged and swallowed. The user still sees "email sent".
3. `GET`/`POST /accounts/reset/<uid>/<token>/` → new password saved → "password changed" confirmation email (synchronous, failures swallowed).

**Admin-assisted**

- `POST /accounts/users/<pk>/reset-password/` → `UserResetPasswordView`. The admin types the new password; it is saved; `ActivityLog` `reset_password` is written; the user gets an email.
- The admin therefore knows the password. **It does not set `email_verified`**, so an unverified account stays locked out.

**Self (signed in):** Profile → change password (current password required) → email + `ActivityLog`.

### 2.5 Student accounts and import

- **Single student:** created as in §2.1 with `role='student'`; welcome email.
- **Bulk:** `POST /accounts/users/import/` with a department and a CSV/XLSX file.
  - Each row is validated (ID, name, year level, email format, Gmail domain, uniqueness against the database and against earlier rows in the same file).
  - Each valid row is `INSERT`ed with an unusable password, followed by **one synchronous welcome email per row** and an `ActivityLog` row.
  - No transaction: a crash halfway leaves a partial import (re-running skips the rows already created).

### 2.6 Reservations: request → approval → session

1. **Request is created** by an Admin/In-Charge on someone's behalf (`/schedule/requests/new/`) or by an Instructor for themselves (`/schedule/requests/new/mine/`).
2. **Validation:** `_slot_error()` applies.
   - Instructor, Student and Group bookings exclusively block the whole lab and must fall within lab hours. A class larger than the PC count is capped, not rejected.
   - Walk-in and Override bookings reserve a number of PCs against remaining capacity (an Override may exceed availability, but not the total PC count).
   - The requester must match an active registered account.
3. **Database:** `INSERT scheduling_sessionrequest` (`status='pending'`). A conflict triggers a "reservation conflict" notification.
4. **Approval:** `POST /schedule/request/<pk>/approve/` → `approve_request`.
   - `_slot_error()` is re-checked.
   - A 6-character code is generated from 32 unambiguous characters, unique against both tables.
   - The request is set to `approved` with the code, and a `Session` row is inserted.
   - The requester is notified (in-app plus a branded email with the code); Walk-in/Override approvals also notify the In-Charge.
   - **This view has no authentication check** (audit C1, Tested). **Phase 1 branch:** login plus Admin or In-Charge (own lab only) required.
5. **Decline:** `POST /schedule/request/<pk>/decline/` → status `declined`, notify. **No authentication check.** **Phase 1 branch:** same rule as approval.
6. **Edit or delete an approved session:** `SessionUpdateView` (role-checked; past sessions locked) and `delete_session` (**no authentication check**). **Phase 1 branch:** both require Admin, or In-Charge for their own lab only.

### 2.7 Class rosters → generated sessions

1. **Create roster** (`/schedule/rosters/new/`): name, course, section, lab, instructor, weekdays, time and validity period.
   - Created by an Admin/In-Charge: auto-approved, and sessions are generated immediately.
   - Created by an Instructor: `pending`; the In-Charge and Admins are notified.
2. **Approve or reject** (`/schedule/rosters/<pk>/approve|reject/`, Admin/In-Charge):
   - approval re-checks instructor, classroom and section conflicts against other active rosters, then `generate_sessions()`;
   - rejection stores a reason and notifies the instructor.
3. **`generate_sessions()`:** for every matching weekday between the validity dates, if no session exists yet for that roster, date and time, and `_slot_error()` passes, it inserts a `Session` with its own code. It is idempotent and skips conflicting dates.
4. **Edits:** `prune_stale_future_sessions()` deletes today-or-later sessions with no check-ins that no longer match the schedule, instructor or lab. Past sessions and sessions with check-ins are never touched.
5. **Students:** added by search or by CSV import (existing student accounts only). Each addition notifies the student, in-app and by email.
6. **Code delivery:** 55-60 minutes before each generated session, the reminder thread notifies the instructor (in-app and email) and **emails the code to every roster student**. Instructors can also see codes on their own calendar (`/schedule/instructor/`).

### 2.8 Student unlocks a lab PC (the core flow)

1. **Student types ID + code on the lock screen** → the agent `POST`s `/labs/api/pc-agent-login/` with `{secret, id_number, reservation_code}`.
2. **Validation** in `pc_agent_login_api` → `verify_reservation_and_check_in()` ([labs/views.py:236](../labs/views.py#L236)):
   1. the shared secret matches;
   2. the PC is identified by `REMOTE_ADDR == PC.ip_address`;
   3. a `Session` with this code exists **in this PC's lab**;
   4. this ID is not already active on another PC;
   5. who may use the code:
      - the primary requester; or
      - a roster member; or
      - anyone, for Group, Walk-in and Override bookings, capped at `student_count` or `pcs_requested`; or
      - for Instructor (class) bookings only, any registered active account as a walk-in if the lab has a free working PC;
   6. the session's account is active;
   7. **date is today and the current time is within start to end**.
3. **Unlock signal:** server → agent `POST http://<pc-ip>:5555/unlock`. If this fails, **nothing is recorded as checked in** and the student sees the reason.
4. **Database** (no transaction):
   - `SessionCheckIn` `update_or_create` (session + ID);
   - `PC` set to `in_use`, with `current_user`, `current_session` and `last_active`;
   - `ActivityLog` `pc_unlock`.
5. **Response** to the agent: PC id, display name, session end time and server time. The agent hides the lock screen, starts a drift-corrected countdown with a warning, and auto-relocks at the session end.
6. **While unlocked:** every 8 s the agent posts the foreground window title (and the URL, if `uiautomation` is installed) → `PCActivityLog` row; `PC.last_active` updated.
7. **End:** the student clicks Log out / Lock now, or time expires → the agent relocks locally and posts `/pc-agent-logout/` or `/pc-agent-end-session/` → the PC is set back to `online` and cleared; `ActivityLog` `pc_lock`.

A browser variant exists at `/labs/pc-login/` (`ReservationPCLoginView`, public, no secret, also identifies the PC by IP) for labs that use a separate kiosk.

### 2.9 Override check-in and manual unlock (staff at the dashboard)

- **Override** (`/labs/pc-status/override-checkin/`, Admin/In-Charge): pick a PC and a registered student or instructor.
  - Free PC: unlock immediately; `SessionCheckIn` `override`; PC `in_use` with `current_login_via_override=True`.
  - Occupied PC: the outgoing check-in is marked `checked_out_at`, a 30-second warning is sent to the agent, and a **daemon thread sleeps 32 s** and then grants the PC. If the server restarts during the wait, the grant never happens.
- **Manual unlock** (`/labs/pc-status/manual-unlock/`): a guest with no account. The typed full name is required; a synthetic `GUEST-<pc>-<timestamp>` check-in is created; the PC goes `in_use` with `current_guest_name`.
- **Offline emergency tool** (`lab_pc_agent/manual_unlock.html`): an In-Charge opens the file locally and sends `/unlock` to the agent with the shared secret, **no server needed**. Later it posts `/labs/api/manual-unlock-log/` with the typed In-Charge name (unverified) to record it.
- **Force release, lock, shutdown, restart** (single PC or bulk): role-checked; In-Charge scoped to their lab; signal sent to the agent; `ActivityLog`.

### 2.10 Background automation (inside the web process)

| Loop | Interval | Does | Failure behavior |
|---|---|---|---|
| PC status checker ([labs/network.py:500](../labs/network.py#L500)) | 20 s | Pings every PC that has an IP. Online/offline transitions update status and trigger notifications (with email). An `in_use` PC that stops answering is cleared | Exceptions swallowed silently |
| Stale-session release | 20 s (same loop) | Releases `in_use` PCs with no agent heartbeat for 5 min, or 15 min past session end, or 4 h with no session | Same |
| After-hours auto-lock | 20 s (same loop) | Sends `/lock` to normal (non-override, non-guest) sessions past the lab's closing time | Same |
| Reminders ([notifications/reminders.py](../notifications/reminders.py)) | 60 s | "Starting soon" at 10-15 min; roster code emails at 55-60 min | Missed windows are never retried |
| Activity-log wipe ([labs/maintenance.py](../labs/maintenance.py)) | Daily at 00:00 | Exports all `PCActivityLog` rows to `.xlsx`, deletes them all, prunes `.xlsx` older than 14 days | If the export fails, nothing is deleted |
| Cloud sync pusher ([cloud_sync/sync.py](../cloud_sync/sync.py)) | 60 s | Pushes `SyncQueue` rows to `CLOUD_SERVER_URL` | Disabled by default; the receiver does not exist |

All loops start in every process that imports the app (except `manage.py` commands other than `runserver`) unless `COMPULAB_BACKGROUND_TASKS=False`.

### 2.11 Attendance

- **Derived, not stored.** "Present" means a `pc_unlock` `ActivityLog` row for a roster ID within the session's lab and time window. Walk-in, override and guest check-ins are listed separately.
- **Manual marks:** `ManualAttendanceRecord` rows entered by the instructor override the PC-derived status.
- **Reports and exports:** instructor attendance page; admin/In-Charge attendance report.
- **Consequence:** attendance depends on `ActivityLog` rows and on PCs reaching the server at login time.

### 2.12 Issues, inventory, maintenance, notifications, reports

- **Issues:** Instructors, In-Charges and Admins report an issue for a lab or PC. The lab's In-Charge and the Admins are notified. Status changes (assigned, in progress, resolved) notify the reporter. An Instructor's "delete" hides the report only for them.
- **Inventory and maintenance:** CRUD for inventory; maintenance schedule/complete; equipment issues; retirement with reason and who retired it. Notifications are sent.
- **Notifications:** in-app rows per user (pin, read, delete; Admins can delete anyone's). Manual compose by Admin/In-Charge. Alert Settings toggles per category. Every auto-notification also sends a plain email if the recipient has an email address.
- **Reports:** five report pages with PDF/Excel export, built from live data; `ReportLog` remembers who generated what.

---

## 3. Source of truth

| Data | Source of truth | Copies or derived data |
|---|---|---|
| Accounts, roles, verification state | `accounts_user` (MySQL) | none |
| Labs, PCs, PC live status | `labs_lab`, `labs_pc` | Agent holds its own lock state and countdown locally. The server's `PC.status` is a best-effort mirror kept current by pings, heartbeats and agent callbacks |
| Reservations and schedule | `scheduling_sessionrequest`, `scheduling_session` | none |
| Who used which PC | `scheduling_sessioncheckin` and `accounts_activitylog` (`pc_unlock` / `pc_lock`) | none |
| Attendance | Derived at read time from `ActivityLog` plus `ManualAttendanceRecord` | Exported files |
| Screen activity | `labs_pcactivitylog` (≤ 1 day) | `media/activity_log_backups/*.xlsx` (14 days) |
| Notifications | `notifications_notification` | Email copies (fire-and-forget); `cloud_sync_syncqueue` rows (never consumed) |
| Rate-limit and failed-login counters | `.django_cache/` files | none |
| Agent credentials | `PC_AGENT_SHARED_SECRET` in the server `.env` | The same value on every PC (`agent_config.local.json`) and in any copy of `manual_unlock.html` setup |

## 4. External dependencies

| Dependency | Required for | Without it |
|---|---|---|
| MySQL/MariaDB server | Everything | App does not start or serve |
| LAN path server ↔ lab PCs (ports 8000 and 5555, ICMP) | PC login, unlock/lock, status, activity | Students cannot unlock PCs (except through the offline tool); statuses go stale |
| SMTP server (internet) | Verification, password reset, all email copies, reservation codes for students | See the feature matrix. Pages stall up to `EMAIL_TIMEOUT` per message (Unverified duration) |
| Google Fonts (internet) | Typography only | Browser falls back to system fonts |
| CDNs (cdnjs, jsdelivr) | Only if the bundled `static/vendor/*` files are missing | Not needed in normal operation (Observed: local files are loaded first) |
| Permanent internet connection | **Not required** when the server is on-prem | Required to use the MochaHost instance at all |
| Remote database | Not used | n/a |

---

## 5. Feature matrix: online vs offline

"Offline" here means: **the CompuLab server and the lab PCs are on the same working LAN, but the internet is down.** "Server down" behavior is noted separately. Offline behavior marked *Expected* follows from the code but has **not been tested** on a real network (Unverified).

| Feature | Current implementation | Online behavior | Offline behavior (on-prem server) | Problems or limitations |
|---|---|---|---|---|
| Registration (staff) | Admin-only creation; verification email sent synchronously | Works (Tested in unit tests) | Account is created; email fails after a timeout; admin sees "could not be sent" (Expected) | No path to activate the account offline (H2); request stalls (H4) |
| Registration (students, single or import) | Admin creates; welcome email per student | Works | Accounts created; each email times out; large imports may exceed request time (Expected, timing Unverified) | H4. Welcome emails are lost, not deferred |
| Account verification | Signed 72 h single-use link; must be clicked | Works (Tested) | Impossible: no email leaves. Link from an earlier email still works if it can reach the server (Expected) | H2. Expired links need a new email |
| Authentication (staff login) | Email + password; verified accounts only; sessions in the database | Works (Tested) | Works for already-verified accounts (Expected; only the database is involved). The 3rd-failure alert email stalls that login response | No lockout (M5) |
| Password reset | Self-service by email; admin sets password | Works (self-service Unverified end-to-end) | Self-service: user is told "email sent", nothing arrives. Admin reset works, but the admin knows the password | Needs an offline-safe reset (see OFFLINE doc) |
| Student PC unlock | Agent → server → agent, IP-identified, code + time window | Works (Unverified on hardware during this audit) | Works: no internet involved (Expected) | Shared secret (H1); IP identity (M6); no transactions (M4) |
| Reservations and approvals | Request → approve → session + code | Works; **anonymous users can approve or delete** (C1, Tested; fixed in commit `1c57df4`, not deployed) | Works; approval email stalls the request; requester learns the code from staff (Expected) | C1, H4 |
| Roster sessions and code reminders | Reminder thread emails codes 1 h before | Works | In-app notification for the instructor works; student emails fail. Students must get the code from the instructor (Expected) | M11; missed reminders not retried |
| Database access | Local MySQL | Works | Unaffected by the internet (Expected) | No scheduled backup (M9) |
| Notifications (in-app) | Rows per user | Works | Works (Expected) | none |
| Notifications (email copies) | Sent in the same request or loop | Works, best-effort | Each fails after a timeout and is dropped; PC-status loop slows exactly when PCs or the network fail (Expected) | H4 |
| Reports and exports | Generated from live data | Works | Works (Expected) | none |
| Remote access | Only the MochaHost instance is internet-reachable; on-prem has none configured (Tailscale only described in `cloud_sync/SETUP.md`) | Hosted site reachable, but it **cannot control PCs** and has separate data | Hosted site unreachable from the lab; on-prem server not reachable from outside | Two independent databases if both are used: no sync exists |
| LAN connectivity | Staff browsers on `http://<server-ip>:8000`; agents on 5555 | Works | Unaffected (Expected) | Plain HTTP (M7); fixed IPs in agent config; `ALLOWED_HOSTS` must list the IP |
| Connectivity indicator | Footer shows `navigator.onLine` | Shows "operational" | May still show "operational" (the client network is up) | Does not reflect internet or server state (L5) |
| Cloud sync | Outbox plus pusher; no receiver | Not functional | Queue grows | M10 |
| **Server down** (any mode) | n/a | Website unavailable; students cannot unlock PCs | Same | Only `manual_unlock.html` works (needs the secret) |

## 6. Implementation completeness

| Classification | Features |
|---|---|
| Fully implemented | Staff login and roles; email verification (online); reservations and approval logic (minus the auth gap); roster approval and session generation; PC unlock/lock/override/manual unlock; PC status checker and stale release; after-hours lock; attendance (derived plus manual); issues; inventory and maintenance; notifications in-app; reports and exports; activity log and nightly wipe |
| Partially implemented | Cloud sync (sender only, notifications only); email delivery (no queue or retry); offline emergency unlock (works, but with an unverified actor); connectivity indicator (client NIC only) |
| Interface only | Footer "Offline — showing cached data" text: nothing is cached |
| Planned, not implemented | Cloud receiver (`/api/ping/`, `/api/sync/`); "topology C" polling agents (`DEPLOYMENT.md`) |
| Fails under certain conditions | Anything that emails, when SMTP is unreachable (stalls, silent drops); override grant across a server restart; account activation without email; duplicated background loops under multi-process servers; PC identity behind a proxy or after a DHCP change |
