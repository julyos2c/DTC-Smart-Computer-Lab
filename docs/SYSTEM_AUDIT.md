# CompuLab (DTC Smart Computer Lab): System Audit

**Audit date:** 2026-10-22
**Scope:** branch `main` working tree (commit `8a85667` plus the uncommitted changes present on that date; those changes were later committed as `f511574`)
**Type:** read-only. No project code, configuration, database or deployment was changed.

> **Remediation status (updated 2026-10-22).** The findings below describe `main` as audited; line numbers refer to that code.
> C1, H3, M1, M2 and L1 are fixed on branch **`phase1-security-fixes`**, in commit **`1c57df4`**. That commit is **committed locally but not pushed or deployed**, so `main` and the hosted (MochaHost) instance still have these vulnerabilities. Details and test evidence are in [§6](#6-phase-1-remediation-branch-phase1-security-fixes). All other findings are open.

Companion documents:

| Document | Contents |
|---|---|
| [EXISTING_BUSINESS_LOGIC.md](EXISTING_BUSINESS_LOGIC.md) | Every workflow traced end-to-end, sources of truth, online/offline feature matrix |
| [HYBRID_ARCHITECTURE.md](HYBRID_ARCHITECTURE.md) | Architecture options, recommendation, connectivity model, synchronization specification |
| [OFFLINE_ACCOUNT_VERIFICATION.md](OFFLINE_ACCOUNT_VERIFICATION.md) | Account lifecycle, offline activation, password reset, email outbox, decision flow |
| [LAN_AND_REMOTE_ACCESS.md](LAN_AND_REMOTE_ACCESS.md) | Network design, remote access, server and client installers |
| [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) | Before/after logic, phased plan, open decisions |

### Evidence labels used throughout

- **Observed:** read directly in the code (file and line given).
- **Tested:** reproduced by running the code against a throwaway in-memory SQLite database. The real MySQL database was never touched; it was not running during the audit.
- **Assumption:** inferred, not confirmed.
- **Unverified:** not tested; behavior depends on the environment.

No secret values (passwords, keys, tokens, mailbox credentials) appear in these documents.

---

## Executive summary

1. **What the system does today.** CompuLab is a Django web application for managing the college's computer laboratories. Staff (Admin, Lab In-Charge, Instructor) sign in with email and password to manage labs, PCs, inventory, maintenance, issue reports, class rosters, reservations, attendance, reports and notifications. Students never sign in to the website. They unlock a lab PC by typing their ID number and a reservation code into a full-screen lock screen, which is drawn by a Python agent (`lab_pc_agent/agent.py`) running on every lab PC.

2. **How the main business logic works.** One MySQL/MariaDB database is the single source of truth. An approved reservation, or a class roster's generated schedule, becomes a `Session` with a 6-character code. When a student types an ID and code on the lock screen, the agent forwards them to the server. The server identifies the PC by its IP address, checks the session's lab, date, time window and who may use the code, then tells the agent to unlock. Background threads inside the web process ping every PC every 20 seconds, release stuck sessions, lock PCs after closing time, send reminders, and back up and then wipe the PC activity log every night.

3. **What is incomplete or problematic.**
   - Four reservation endpoints have **no login check** (Tested). Anyone who can reach the site can approve or decline requests, download a request PDF containing its reservation code, and delete scheduled sessions.
   - Instructors can open and edit other instructors' class rosters.
   - All lab PCs share one agent secret, sent in plain text over HTTP.
   - Every email is sent inside the request or background loop that triggered it, with a 20-second timeout and no queue.
   - There is no way to activate a staff account except by clicking an emailed link.
   - `cloud_sync` is half-built: it has a sender with no receiver, and only notifications are queued.

4. **Offline support today: partial and accidental.** The application needs no internet service except outgoing email (SMTP) and, for appearance only, Google Fonts. Chart.js, FullCalendar and SweetAlert2 are bundled locally, with CDN fallbacks. So if the Django server runs **on the LAN**, dashboards, reservations and PC unlocking keep working without internet. What fails offline is email: account verification, password reset, reservation codes for students, and alerts. Pages that send email also stall. The public instance at `compulab.danaotechnologicalcollege.com` (cPanel/Passenger, see `passenger_wsgi.py` and `DEPLOYMENT.md` §5) cannot reach lab PCs at all, and it is unreachable from the lab whenever the internet is down.

5. **What must change for hybrid operation.**
   - Close the security blockers.
   - Make one on-premises server the authoritative system.
   - Move email into a durable outbox.
   - Add an approved offline account-activation path.
   - Move background loops into a separate worker service.
   - Give each PC agent its own credential.
   - Show real connectivity status in the UI.
   - Package the server and the agent as installers.

6. **Recommended server and client architecture.** One on-premises CompuLab server per campus: Windows, waitress as the app server, MariaDB, and a worker service, all installed as Windows services. That server is the **only** writable copy of the data. There is no bidirectional synchronization. The "client" is (a) the existing lab PC agent, repackaged with its own installer and per-PC credentials, and (b) an optional lightweight launcher for staff PCs that opens the server in a browser. Remote users reach the same server through a VPN overlay. The MochaHost instance is retired or reduced to a public landing page. A one-way, read-only mirror is an optional later phase.

7. **Recommended offline account verification.** Combine three mechanisms:
   - **Admin-issued one-time activation codes**, handed to the person in person. The owner sets their own password; the system records "identity confirmed by admin X at time T".
   - **Deferred email verification** through the outbox.
   - **Pre-provisioning** of accounts before each term.

   Email ownership, identity approval and authentication become separate, recorded facts instead of a single `email_verified` flag.

8. **Recommended remote access.** Tailscale, or self-hosted WireGuard if a managed service is not acceptable, terminating on the on-premises server. Never port-forward the web port (8000), MySQL (3306) or the agent port (5555).

9. **Main security and data-integrity risks.**
   - The unauthenticated reservation endpoints (Critical).
   - The shared, plaintext agent secret, plus an old secret value visible in the public GitHub repository's history.
   - Missing ownership checks.
   - Override grants run on in-memory timers that a restart loses.
   - No database transactions around PC check-in.
   - No scheduled, tested database backup.
   - Plain HTTP on the LAN.
   - Django 5.0 (end-of-life) in the development requirements.

10. **Recommended implementation order.**
    1. Security fixes.
    2. Account lifecycle and email outbox.
    3. Worker service and connectivity status.
    4. Server packaging, backups and the Django 5.2 upgrade.
    5. Agent hardening and the client installer.
    6. Remote access.
    7. Optional read-only mirror.
    8. Reliability and recovery testing.

    The open decisions are at the end of [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md#decisions-needed-before-implementation).

---

## 1. Environment snapshot

| Item | Found | Evidence |
|---|---|---|
| Python (local venv) | 3.11.16 | `venv\Scripts\python --version` |
| Django (local venv) | 5.0.14, end-of-life (no security fixes since April 2025) | `requirements.txt` pins `<5.1` because the local XAMPP MariaDB is 10.4 |
| Django (production requirements) | 5.2 LTS line | `requirements-production.txt` (Python 3.13, MariaDB 11.4 on the host) |
| Database | MySQL/MariaDB only (`django.db.backends.mysql`, `utf8mb4`, strict mode) | [compulab/settings.py:163](../compulab/settings.py#L163) |
| App server | waitress 3.0.2 installed locally; Passenger on cPanel | `pip list`, [passenger_wsgi.py](../passenger_wsgi.py) |
| Static files | WhiteNoise (compressed, non-manifest) | [compulab/settings.py:219](../compulab/settings.py#L219) |
| Cache | File-based (`.django_cache/`), shared by worker processes; used for rate limits | [compulab/settings.py:284](../compulab/settings.py#L284) |
| Email | SMTP from `.env`; falls back to the console backend when no credentials are set | [compulab/settings.py:240](../compulab/settings.py#L240) |
| Time zone | Asia/Manila, `USE_TZ=True` | settings |
| Git remote | Public GitHub repository (`julyos2c/DTC-Smart-Computer-Lab`, reachable without login) | `git remote -v`, GitHub API returned 200 unauthenticated |
| `manage.py check` | No issues | Tested |
| `makemigrations --check` | No missing migrations | Tested |
| `check --deploy` (DEBUG off) | 4 warnings, all HTTPS-related (HSTS, SSL redirect, secure cookies). Expected while the LAN is plain HTTP | Tested |
| Test suite | 40 tests, all pass on SQLite | Tested (see §5) |

---

## 2. Project inventory

There is no `main.py` or `todo.py`. The entry points are `manage.py`, [compulab/wsgi.py](../compulab/wsgi.py), [passenger_wsgi.py](../passenger_wsgi.py) and, on each lab PC, [lab_pc_agent/agent.py](../lab_pc_agent/agent.py).

### 2.1 Django project: `compulab/`

| File | Purpose | Status and concerns |
|---|---|---|
| [settings.py](../compulab/settings.py) | All configuration, read from `.env`. Refuses to start in production without `DJANGO_SECRET_KEY` and `PC_AGENT_SHARED_SECRET` | Complete. Defaults hardcode two LAN IPs into `ALLOWED_HOSTS` and `CSRF_TRUSTED_ORIGINS` (L60, L70). Several operational values are constants rather than environment values (`PC_STATUS_CHECK_INTERVAL_SECONDS`, `CLOUD_SYNC_INTERVAL_SECONDS`, wipe schedule) |
| [urls.py](../compulab/urls.py) | Root routes; overrides Django's login and password-reset views; serves `media/avatars/` only | Complete. Activity-log backups are correctly *not* served (Tested by `MediaExposureTests`) |
| [background.py](../compulab/background.py) | Decides whether a process should start the background loops | Works for single-process waitress. Under several worker processes, every process starts its own loops, so they run in duplicate |
| [wsgi.py](../compulab/wsgi.py) / [asgi.py](../compulab/asgi.py) | Standard entry points | ASGI is unused |
| [tests.py](../compulab/tests.py) | Cross-app tests: anonymous access, no 500s per role, agent secret, calendar XSS, media exposure, production-settings guards | The access sweep only covers **parameter-free GET** URLs, which is why the unauthenticated `pk`-based POST endpoints (finding C1) were never caught |
| `templates/` | All HTML templates (about 100), grouped by app | Footer "System operational / Offline" status uses `navigator.onLine`, which reflects the viewer's own network adapter, not the server or the internet ([footer.html:73](../compulab/templates/dashboard/footer.html#L73)) |

### 2.2 `accounts/`: users, authentication, verification, attendance, audit log

| File | Purpose | Status and concerns |
|---|---|---|
| [models.py](../accounts/models.py) | `User` (email login, no username; roles `admin`, `incharge`, `instructor`, `student`; `id_number`, `department`, `year_level`, `assigned_lab`, `avatar`, `theme`, `email_verified`, `email_verification_sent_at`). `ActivityLog` is the audit trail (actor, action, target, details, optional PC) | Complete. `email_verified` is the only lifecycle flag: there is no record of *who* approved an account or *how* it was verified |
| [verification.py](../accounts/verification.py) | `requires_verification()` (superusers and students are exempt) and an HMAC token generator. The token is bound to email, verified flag and send time, so links are single-use and superseded by newer links; they expire after 72 hours | Complete and well tested |
| [backends.py](../accounts/backends.py) | `VerifiedEmailBackend` refuses unverified accounts on every login route and drops existing sessions | Complete |
| [forms.py](../accounts/forms.py) | Admin create/edit forms, login form, profile and password forms, student import form, Gmail-only rule | Editing a still-unverified Instructor or In-Charge **forces the admin to type a password** (L343-350), which defeats the "owner sets own password" design |
| [views.py](../accounts/views.py) (1,924 lines) | Login, password reset, profile, role dashboards (In-Charge, Instructor), user management, verification, resend, attendance, log history, exports, student import, requester search, theme | Large, multi-purpose module. Email sends are synchronous (L688, L732, L1875) |
| [mixins.py](../accounts/mixins.py) | `RoleRequiredMixin`, modal helpers, generic `bulk_delete` | Role-only checks; no object ownership checks |
| [admin.py](../accounts/admin.py) | Django admin for `User` | `email_verified` is not editable anywhere in the UI (L32-40) |
| [email_rules.py](../accounts/email_rules.py) | Gmail-only address rule | A policy decision; it blocks institutional addresses |
| [imports.py](../accounts/imports.py) | CSV/XLSX parsing for student imports | No file-size limit |
| [constants.py](../accounts/constants.py), [context_processors.py](../accounts/context_processors.py) | Departments and year levels; sidebar counters | Sidebar counters run 3 count queries on every page |
| `management/commands/check_emails.py` | Lists non-Gmail accounts | Utility |
| [tests.py](../accounts/tests.py) | 25 email-verification tests | Good coverage of verification; none for offline paths |

### 2.3 `labs/`: labs, PCs, agent API, inventory, maintenance, reports

| File | Purpose | Status and concerns |
|---|---|---|
| [models.py](../labs/models.py) | `Lab` (opening and closing hours), `PC` (IP, status, current user/session/guest), `PCActivityLog`, `InventoryItem`, `MaintenanceLog`, `EquipmentIssue`, `ReportLog` | `PC.ip_address` is unique only at form level, not in the database |
| [views.py](../labs/views.py) (3,100+ lines) | Admin dashboard; reservation check-in logic (`verify_reservation_and_check_in`); the six agent JSON APIs; PC status; override; manual unlock; activity log; power actions; lab, PC and inventory CRUD; maintenance; equipment issues | Core logic, mostly complete. Only **one** `transaction.atomic()` in the whole codebase (L2436). Override grants run on a sleeping daemon thread (L1271) |
| [network.py](../labs/network.py) | Ping-based status checker, unlock/lock/power/override signals to agents, stale-session release, after-hours auto-lock, the 20-second background loop | Works. The loop swallows every exception without logging (L539-542). The secret is sent in the JSON body over HTTP (L79) |
| [maintenance.py](../labs/maintenance.py) | Nightly backup of `PCActivityLog` to `.xlsx`, then deletes every row | Works. Retention is 14 days of spreadsheets. If the backup fails, the wipe is skipped (an exception raised before the delete) |
| [reports.py](../labs/reports.py) | Five reports plus PDF/Excel export helpers | Role-checked; In-Charge scoped to their lab |
| [privacy.py](../labs/privacy.py) | Maps window titles and URLs to app or site labels | Descriptive only |
| [forms.py](../labs/forms.py) | Lab, PC, inventory and maintenance forms. PC IP must be unique and not loopback | Complete |
| `management/commands/` | `auto_lock_after_hours`, `wipe_activity_logs`, `seed_pc_activity_demo` | `seed_pc_activity_demo` writes demo data; must never run on production |
| `views-old.py` (2,030 lines) | Old copy of `views.py` | **Dead code.** Not importable (hyphen in the name). Tracked in git |
| `tests.py` | Empty | No tests for the most security-sensitive app |

### 2.4 `scheduling/`: reservations, sessions, rosters, check-ins

| File | Purpose | Status and concerns |
|---|---|---|
| [models.py](../scheduling/models.py) | `ClassRoster` (approval workflow, weekly schedule, `generate_sessions()`), `RosterStudent`, `Session` (unique `reservation_code`), `SessionCheckIn`, `SessionRequest`, `ManualAttendanceRecord` | Complete. Integer primary keys only, no UUIDs |
| [views.py](../scheduling/views.py) (1,484 lines) | Calendar, request management, approval, roster CRUD, approve/reject, generate sessions, roster student management | **C1:** `approve_request`, `decline_request`, `delete_session`, `export_request_pdf` have no auth check. **H3:** roster detail, update and function views do not check ownership |
| [utils.py](../scheduling/utils.py) | Code generation, capacity rules, roster conflict detection, `json_for_script` | Codes use `random.choices`, not `secrets` (L31) |
| [forms.py](../scheduling/forms.py) | Request, session and roster forms; the "requester must be a registered account" rule | Not reviewed line by line |
| `tests.py` | Empty | |

### 2.5 `notifications/`

| File | Purpose | Status and concerns |
|---|---|---|
| [models.py](../notifications/models.py) | `Notification` (per user), `AlertSettings` singleton toggles | Complete |
| [services.py](../notifications/services.py) | Every auto-notification. Creates in-app rows, then **sends email synchronously, one message per recipient** (L92), and enqueues each notification to `cloud_sync` | Primary offline bottleneck (finding H4) |
| [reminders.py](../notifications/reminders.py) | Daemon thread every 60 s: "starting soon" (10-15 min) and roster reservation-code reminders (55-60 min) | If the server is down during the window, the reminder is **never** sent; there is no catch-up |
| [views.py](../notifications/views.py) | List, read/unread, pin, delete, compose, alert settings | Some state changes accept GET |
| `tests.py` | Empty | |

### 2.6 `issues/`

| File | Purpose | Status |
|---|---|---|
| [models.py](../issues/models.py), [views.py](../issues/views.py) | Facility and PC issue reports (open, assigned, in progress, resolved) with notifications. Instructors see only their own reports | Complete. Role checks present. `tests.py` empty |

### 2.7 `cloud_sync/`

| File | Purpose | Status |
|---|---|---|
| [models.py](../cloud_sync/models.py) | `SyncQueue` outbox (`edge_id` UUID, JSON payload, `attempts`, `last_error`) and `enqueue()`, which silently swallows errors | **Partially implemented.** Only `notifications.services.notify()` enqueues anything. With `CLOUD_SERVER_URL` blank (the default), the table grows forever and nothing reads it |
| [sync.py](../cloud_sync/sync.py) | Background pusher to `CLOUD_SERVER_URL/api/sync/` | The receiving endpoint does not exist in this repository (`DEPLOYMENT.md` says so). `last_error` is never written |
| `SETUP.md` | Setup notes (Filipino), including Tailscale | Documentation only |

### 2.8 `lab_pc_agent/`: runs on every lab PC

| File | Purpose | Status and concerns |
|---|---|---|
| [agent.py](../lab_pc_agent/agent.py) (1,939 lines) | Tkinter full-screen lock screen with an ID + code login form. HTTP listener on `0.0.0.0:5555` (`/unlock`, `/lock`, `/override-warning`, `/shutdown`, `/restart`, `/ping`). Countdown and auto-relock (clock-drift corrected from server time). Activity reporting every 8 s (window title, optional URL). Network-status probe | Works as designed, but authentication is a single shared secret compared in plain text (L170) with CORS `*` (L133). The README admits it is an application-level lock: killing `python.exe` bypasses it unless Task Manager is disabled |
| [hardening.py](../lab_pc_agent/hardening.py) | Blocks Win/Alt-Tab hotkeys and disables Task Manager through the registry while locked | Windows-only, best effort |
| `manual_unlock.html` | Offline emergency tool: an In-Charge opens it locally and unlocks a PC directly through its agent, then logs the unlock to the server later | Needs the shared secret in the browser, and the name typed is unverified |
| `agent_config.json` / `.local.json` | Per-PC config; the secret lives in the gitignored `.local.json` | `server_url` is a fixed IP; a server IP change requires editing every PC |
| [README.md](../lab_pc_agent/README.md) | Setup (Filipino) | Manual, per-PC installation |
| `test_url.py` | Ad-hoc manual test script | Not an automated test |

### 2.9 Other root files

| File | Note |
|---|---|
| [DEPLOYMENT.md](../DEPLOYMENT.md) | Accurate topology notes (A: on-prem, B: on-prem plus MochaHost mirror, C: everything hosted). Recommends A |
| `static.zip` (2.6 MB), `structure.txt` (1.1 MB tree listing including `venv/`) | Tracked in git; no runtime purpose |
| `data.json`, `data_backup.json` | Local `dumpdata` exports containing 3 user records and 25 activity-log rows. Gitignored (not in the repo) but **sensitive** if the folder is copied or shared |
| `db.sqlite3` (0 bytes), `db.sqlite3.backup` | Leftovers from before MySQL; unused |

### 2.10 System map (as it is today)

```
                         ┌──────────────────────────── Internet ────────────────────────────┐
                         │  SMTP mailbox (mail.<college-domain>:465)    Google Fonts (CSS)   │
                         │  MochaHost cPanel: compulab.<college-domain>  (Passenger + MariaDB)│
                         │      └─ cannot reach lab PCs (private 192.168.x.x addresses)       │
                         └──────────────▲───────────────────────────────▲───────────────────┘
                                        │ SMTP (synchronous,             │ HTTPS (staff browsers
                                        │ inside requests/loops)         │ when internet is up)
 ┌──────────────────────────────── School LAN ───────────────────────────┼───────────────────┐
 │                                                                        │                   │
 │  Staff PC (browser) ──HTTP:8000──►  On-prem CompuLab server (Django + waitress, Windows)    │
 │                                     ├─ MySQL/MariaDB (XAMPP 10.4, localhost:3306)          │
 │                                     ├─ background threads in the web process:              │
 │                                     │    ping PCs 20 s · release stale · auto-lock ·       │
 │                                     │    reminders 60 s · nightly activity wipe ·          │
 │                                     │    cloud_sync pusher (disabled by default)           │
 │                                     └─ .django_cache (rate-limit counters)                 │
 │                                        ▲                         │                          │
 │      agent → server: HTTP:8000 JSON    │ login, info, activity,  │ server → agent: HTTP:5555│
 │      (secret in body, PC identified    │ logout, end-session     │ unlock/lock/override/    │
 │       by source IP)                    │                         ▼ shutdown/restart + ping  │
 │  Lab PC 1..n: lab_pc_agent (Tkinter lock screen, listener 0.0.0.0:5555)                     │
 │  In-Charge laptop: manual_unlock.html ──HTTP:5555──► agent directly (server not needed)    │
 └───────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Prioritized findings

Severity: **Critical** = exploitable now, or blocks safe deployment; **High** = serious risk or blocks a stated requirement; **Medium** = should be fixed during the hybrid work; **Low** = improvement.
"Blocker" means blocking for hybrid deployment.

### Critical

**C1. Reservation endpoints reachable without logging in.** Tested.
- **Where:** [scheduling/views.py:213](../scheduling/views.py#L213) `delete_session`, [:398](../scheduling/views.py#L398) `approve_request`, [:469](../scheduling/views.py#L469) `decline_request`, [:483](../scheduling/views.py#L483) `export_request_pdf`.
- **Evidence:** none of the four checks authentication or role. A probe on a throwaway database, with an anonymous client and CSRF enforcement on, produced: approve → 302, request `approved`, reservation code issued; decline → 302, `declined`; export → 200 PDF (contains the code); delete → 302, session gone. CSRF is no barrier, because any visitor gets a token from the login page.
- **Impact:** anyone who can reach the site (the internet, for the hosted instance) can approve their own pending request and obtain a working unlock code, decline other people's requests, delete the official schedule, and read request details. The existing test missed it because it only sweeps parameter-free GET URLs.
- **Fix:** add the `admin`/`incharge` role check (and POST-only) to all four; extend `compulab/tests.py` to call every `pk` route anonymously and with each role.
- **Blocker:** yes. Fix before anything else, and on the hosted instance as well.
- **Status:** fixed in commit `1c57df4` on branch `phase1-security-fixes` (committed locally; not pushed or deployed). The hosted instance is still exposed. See §6.

### High

**H1. One shared agent secret, sent in plain text, stored on student-used PCs.** Observed.
- **Where:** [labs/network.py:79](../labs/network.py#L79), [labs/views.py:547](../labs/views.py#L547) (and the five other agent APIs), [lab_pc_agent/agent.py:170](../lab_pc_agent/agent.py#L170), `agent_config.local.json`.
- **Evidence:** every agent and the server use the same value. It travels as JSON over HTTP and is compared with `!=`. The agent listens on all interfaces with CORS `*`. The previous secret value is committed in the public repository's history (`HEAD:compulab/settings.py` L279, `HEAD:lab_pc_agent/agent_config.json` L4). The agent now refuses that value, and the server no longer falls back to it.
- **Impact:** anyone who obtains the secret can unlock, lock, shut down or restart every PC; impersonate any PC (forge activity, release sessions); and write fake "manual unlock" audit entries. Ways to obtain it: reading the config file on a lab PC (Unverified; depends on NTFS permissions), sniffing the LAN or Wi-Fi, or using an old copy.
- **Fix:** per-PC credentials (a random token per PC, stored hashed in the database), HMAC-signed requests with timestamp and nonce, Windows Firewall rule allowing port 5555 only from the server, config file readable only by SYSTEM and Administrators, agent running as a service. Confirm production never used the old value.
- **Blocker:** yes, for a production LAN rollout.

**H2. No offline way to activate staff accounts; editing a pending account forces a password.** Observed.
- **Where:** [accounts/verification.py:23](../accounts/verification.py#L23), [accounts/views.py:811](../accounts/views.py#L811), [accounts/admin.py:32](../accounts/admin.py#L32), [accounts/forms.py:343](../accounts/forms.py#L343).
- **Evidence:** `email_verified` can only become true by clicking the emailed link. It is not on any form or in Django admin. Superusers are exempt; `role='admin'` accounts created through the UI are not. Saving the edit form for an unverified Instructor or In-Charge with blank password fields fails with "This account doesn't have a password yet".
- **Impact:** while SMTP or the internet is down, newly created Admin, In-Charge and Instructor accounts can never sign in. The workaround (admin sets a password) leaves the account still blocked, and means the admin knows the user's password.
- **Fix:** see [OFFLINE_ACCOUNT_VERIFICATION.md](OFFLINE_ACCOUNT_VERIFICATION.md).
- **Blocker:** yes (core requirement).

**H3. Instructors can view and modify any class roster.** Observed.
- **Where:** [scheduling/views.py:960](../scheduling/views.py#L960) `RosterDetailView`, `RosterUpdateView.get_queryset` (about L1206), [:1003](../scheduling/views.py#L1003) `roster_generate_sessions`, [:1067](../scheduling/views.py#L1067) `roster_archive`, [:1379](../scheduling/views.py#L1379) `roster_add_student`, [:1401](../scheduling/views.py#L1401) `roster_remove_student`, [:1413](../scheduling/views.py#L1413) `roster_import_students`.
- **Evidence:** the roster list is filtered to the instructor's own rosters; none of these views are.
- **Impact:** an instructor can read another class's student list, archive the class, change its students, or regenerate and prune its sessions.
- **Fix:** scope querysets to `instructor=request.user` for the instructor role; add tests.
- **Blocker:** yes.
- **Status:** fixed in commit `1c57df4` on branch `phase1-security-fixes` (committed locally; not pushed or deployed). See §6.

**H4. Email is synchronous everywhere, with no queue.** Observed. Timing is Unverified.
- **Where:** [notifications/services.py:92](../notifications/services.py#L92) (`notify`, one SMTP connection per recipient), [:230](../notifications/services.py#L230) (one email per roster student), [accounts/views.py:688](../accounts/views.py#L688), [:732](../accounts/views.py#L732), [:1875](../accounts/views.py#L1875) (one welcome email per imported student), `EMAIL_TIMEOUT=20` ([settings.py:254](../compulab/settings.py#L254)).
- **Impact when the internet or SMTP is down:**
  - each send can block for up to the timeout, depending on whether DNS fails fast or the connection times out (not measured);
  - a page that notifies 5 recipients can hang for minutes;
  - a 100-student import can exceed any request timeout;
  - the PC-status loop sends offline/online alerts, so it stalls exactly when the network is unhealthy, delaying status updates and auto-locks;
  - failed messages are dropped (`fail_silently=True`); nothing retries.
- **Fix:** durable `EmailOutbox` table plus a worker with backoff; see [OFFLINE_ACCOUNT_VERIFICATION.md §6](OFFLINE_ACCOUNT_VERIFICATION.md#6-email-outbox-durable-queue).
- **Blocker:** yes, for offline mode.

### Medium

| ID | Finding | Where (evidence) | Impact | Fix | Blocker |
|---|---|---|---|---|---|
| M1 | Non-admin "Admin" role can reset or edit **superuser** accounts | [accounts/views.py:1548](../accounts/views.py#L1548), `UserUpdateView` | A `role='admin'` account (not superuser, no `/admin/` access) can set a superuser's password and sign in as them, gaining raw Django admin access | Only superusers may edit or reset superusers; log it | No. **Fixed in `1c57df4`** (committed locally; not pushed or deployed; §6) |
| M2 | Lab In-Charge not limited to their own lab on Override and Manual Unlock | [labs/views.py:1199](../labs/views.py#L1199), [:1368](../labs/views.py#L1368) (only the picker is filtered) | An In-Charge can POST another lab's PC id and unlock or take it over | Check `pc.lab_id == user.assigned_lab_id` in `post()` | No. **Fixed in `1c57df4`** (committed locally; not pushed or deployed; §6) |
| M3 | Background work is in-memory and silent | [labs/network.py:539](../labs/network.py#L539), [notifications/reminders.py](../notifications/reminders.py), [labs/views.py:1271](../labs/views.py#L1271) | Exceptions are swallowed with no log. An override grant scheduled on a sleeping thread is **lost if the server restarts** (old user ends, new user never gets the PC). Reminders missed during downtime are never sent. With more than one web process, every loop runs once per process (duplicate alerts and emails) | Separate worker service; durable job table; logging | Yes (reliability) |
| M4 | No transactions or row locks around PC check-in, override and capacity checks | [labs/views.py:236](../labs/views.py#L236) and the PC endpoints; only one `atomic()` exists | Two simultaneous logins can exceed a group or walk-in cap, or double-assign a PC; a crash between writes leaves the PC "in use" without a check-in | `transaction.atomic()` plus `select_for_update()` on the PC and session rows | Yes (integrity) |
| M5 | No lockout or rate limit on staff login or the reservation-code login | [accounts/views.py:70-84](../accounts/views.py#L70) (admin alert at 3 failures, never blocks); [labs/views.py:535](../labs/views.py#L535), [:493](../labs/views.py#L493) | Unlimited password guessing; code guessing from a registered PC IP (space 32⁶ ≈ 1.07 × 10⁹, reduced in practice by the date and time window) | Per-account and per-IP throttling with backoff; `secrets.choice` for codes | No |
| M6 | PC identity = source IP address | All agent APIs, `ReservationPCLoginView` | A reverse proxy, NAT, VPN or DHCP change makes PCs "not registered" or mis-identified. Blocks putting nginx, IIS or Caddy in front without extra trusted-proxy logic | Per-PC token identity (see H1); IP kept as a hint only | Yes (installers) |
| M7 | Plain HTTP on the LAN | `.env` `DJANGO_SECURE_SSL=False` by design | Session cookies and passwords readable on shared Wi-Fi or a mirrored switch port | LAN TLS, or restrict staff access to wired VLAN or VPN; see LAN doc | Decision |
| M8 | Django 5.0 end-of-life in `requirements.txt`; development and production differ (5.0 vs 5.2) | `requirements.txt`, `requirements-production.txt` | Unpatched framework vulnerabilities on the on-prem server; behavior differences between environments | Install MariaDB ≥ 10.5 on the server and standardize on Django 5.2 LTS (the docs say the tests pass there) | Yes (server installer) |
| M9 | No scheduled, verified database backup | `DEPLOYMENT.md` §6 is manual only | A disk failure on the on-prem server loses everything | Scheduled `mysqldump` plus a media copy, retention, monthly restore test | Yes |
| M10 | `cloud_sync` is half-built and grows forever | [cloud_sync/models.py:53](../cloud_sync/models.py#L53), [sync.py](../cloud_sync/sync.py) | Every notification adds a `SyncQueue` row that nothing consumes; errors are swallowed | Disable enqueue until a sync design is approved; prune | No |
| M11 | Students receive roster reservation codes only by email | [notifications/services.py:230](../notifications/services.py#L230) | Students receive the reservation code only by email. Offline, they never get it, and nothing tells the instructor | Show the code on the instructor dashboard (already in-app) and mark "email pending" | No |

### Low

| ID | Finding | Where | Fix |
|---|---|---|---|
| L1 | Anonymous requests to several function views crash with `AttributeError` (HTTP 500) instead of redirecting to login | [scheduling/views.py:1011](../scheduling/views.py#L1011), [:1073](../scheduling/views.py#L1073), `pc_force_release`, `_pc_power_action`, `maintenance_complete`, `equipment_issue_resolve` | `@login_required` first. **Fixed in `1c57df4`** (committed locally; not pushed or deployed; §6) |
| L2 | Secret comparison not constant-time | agent APIs, agent handler | `hmac.compare_digest` (superseded by H1 fix) |
| L3 | State changes accept GET | [notifications/views.py:62-108](../notifications/views.py#L62) | `@require_POST` |
| L4 | No upload size limits on CSV/XLSX import | [accounts/forms.py:466](../accounts/forms.py#L466) | Size cap plus row cap |
| L5 | Footer connectivity badge is misleading | [footer.html:73](../compulab/templates/dashboard/footer.html#L73) | Replace with server-reported status (see HYBRID §4) |
| L6 | Email templates hardcode the public site URL in the footer | `compulab/templates/emails/*.html` (5 files) | Use `SITE_URL` |
| L7 | Gmail-only rule | [accounts/email_rules.py](../accounts/email_rules.py) | Policy decision; institutional domain may be preferable |
| L8 | Repository hygiene: `labs/views-old.py`, `static.zip`, `structure.txt` tracked; empty `tests.py` in labs, scheduling, notifications and issues; local `data*.json` dumps with user records | repo root | Remove dead files; move dumps out of the project folder |
| L9 | Activity log is fully wiped nightly; spreadsheets kept 14 days | [labs/maintenance.py](../labs/maintenance.py) | Retention policy decision (privacy vs evidence) |
| L10 | Default `ALLOWED_HOSTS` and CSRF origins hardcode two LAN IPs | [settings.py:60](../compulab/settings.py#L60) | Empty defaults; the installer writes `.env` |
| L11 | Django's built-in `/accounts/password_change/` page is also routed (via `include('django.contrib.auth.urls')`). A change made there skips the `ActivityLog` entry and confirmation email that the Profile page's own password change writes | [compulab/urls.py](../compulab/urls.py), [accounts/views.py:174](../accounts/views.py#L174) | Remove or redirect the built-in route |
| L12 | Deleting a Lab permanently deletes its PCs, sessions, requests, check-ins, manual attendance, inventory, maintenance logs and issues (`on_delete=CASCADE` chain); only `ActivityLog` rows survive | model `on_delete` settings (`labs/models.py`, `scheduling/models.py`, `issues/models.py`); `LabDeleteView` [labs/views.py:2293](../labs/views.py#L2293) | Block deletion while history exists, or archive labs instead |

---

## 4. Reliability and multi-user behavior

| Question | Answer | Basis |
|---|---|---|
| Several simultaneous users? | Yes for normal pages (waitress is multi-threaded; MySQL handles concurrency). Contended operations (check-in caps, override, PC assignment) are racy | Observed (M4) |
| Interrupted connections (staff browser) | Normal HTTP behavior. A form submitted twice can create duplicates; there are no idempotency keys | Observed |
| Interrupted connections (agent ↔ server) | Agent login fails visibly. Session-end notifications are best-effort with no retry; the server's stale-session sweeper releases the PC within 5 minutes (heartbeat) or after the session ends plus 15 minutes | Observed ([labs/network.py:311](../labs/network.py#L311)) |
| Unexpected server restart | Committed data is safe (MySQL). Lost: pending override grants and any reminder whose window passes while the server is down. Rate-limit counters survive (file cache). Lab PCs stay locked or unlocked locally; agents keep their own countdown | Observed |
| Server down entirely | Students cannot log in to PCs. The In-Charge can use `manual_unlock.html` with the shared secret; the unlock is logged later | Observed |

## 5. Test evidence

- `python manage.py test`, run with an audit-only settings override (in-memory SQLite, background tasks off, local-memory email and cache), kept outside the repository: **40 tests, OK** (21.5 s). Coverage is concentrated on email verification (25 tests in `accounts/tests.py`) and cross-app checks (15 tests in `compulab/tests.py`). The `labs`, `scheduling`, `notifications` and `issues` apps have no tests.
- Anonymous-access probe for C1 (same throwaway database): results quoted in C1.
- Not tested: MySQL-specific behavior, SMTP failure timing, agent behavior, Windows service behavior, load. These remain **Unverified**.

## 6. Phase 1 remediation (branch `phase1-security-fixes`)

**State:** committed locally on branch `phase1-security-fixes`. **Not pushed, not deployed.** `main` and the hosted instance are unchanged and still have these vulnerabilities.

| Commit | Contents |
|---|---|
| `f511574` | The work that existed before Phase 1 (email verification overhaul, agent secret moved to a local file). Not part of the fixes below |
| `1c57df4` | The Phase 1 security fixes and their tests (11 files, +916 / −39) |

The tree of `1c57df4` was tested as committed: 77 tests passed on SQLite, MariaDB 10.4.32 and MySQL 8.4.8.

### 6.1 What changed

| Finding | Change | Files |
|---|---|---|
| C1 | `approve_request`, `decline_request`, `delete_session` and `export_request_pdf` now require login and the Admin or Lab In-Charge role. Anonymous visitors are redirected to login; other roles get 403. GET to the three state-changing endpoints only redirects; it changes nothing | `scheduling/views.py` |
| Reservation scope (policy decision, final review) | A Lab In-Charge manages reservations for **their assigned lab only**. This covers the pending list, request detail, edit, approve, decline, PDF export, and session edit and delete. Other labs' rows return 404, and the lab dropdown on edit forms offers only their lab. The schedule calendar still shows every lab, but other labs' sessions are view-only: no Edit or Delete, and no reservation code. The sidebar and page pending counts match. An In-Charge with no assigned lab manages none. Admins are unchanged (every lab) | `scheduling/views.py`, `accounts/context_processors.py`, `compulab/templates/scheduling/view_schedule.html` |
| H3 | Instructors can open or change only their own rosters: detail, edit, archive, generate sessions, add, remove, import and search. Another instructor's roster returns 404. On the create and edit forms, the instructor dropdown offers only themself. The roster availability lookup no longer returns another instructor's weekly timetable to an instructor; lab and section occupancy, which the conflict warning needs, are still shown | `scheduling/views.py` |
| M1 | Only a superuser may edit, reset, activate, deactivate or delete a superuser; bulk delete skips superusers with a message. The Users list and user detail page hide those controls (and the bulk-select box) on superuser rows for a non-superuser Admin. The server-side checks apply whether or not the buttons are shown | `accounts/views.py`, `compulab/templates/accounts/users.html`, `compulab/templates/accounts/user_detail.html` |
| M2 | Override and Manual Unlock `post()` refuse (403) a PC outside the In-Charge's lab. The pickers ignore another lab's `?lab=` value. PC status edit is limited to the In-Charge's lab. An In-Charge with no assigned lab can act on no lab, which is the rule the power actions already used | `labs/views.py` |
| L1 | `@login_required` added to `pc_force_release`, the power actions, `maintenance_complete` and `equipment_issue_resolve`. Roster function views redirect anonymous visitors to login instead of failing with a 500 | `labs/views.py`, `scheduling/views.py` |

No migrations. No settings, dependency or agent changes.

### 6.2 Tests added

| File | Covers |
|---|---|
| `scheduling/tests.py` | C1 (anonymous, CSRF-enforced anonymous, instructor, student, admin, In-Charge); In-Charge reservation scope (other lab 404, own lab works, list and count, lab dropdown, calendar Edit/Delete/code hidden, no-lab In-Charge, admin all labs); H3 (another roster 404 on every endpoint, own roster works, cannot file or hand a roster to another instructor, availability lookup) |
| `labs/tests.py` | M2 (another lab 403/404, own lab works, no-lab In-Charge refused, pickers, admin unaffected, anonymous redirected) |
| `accounts/test_permissions.py` | M1 (refused actions, bulk delete skips superusers, admin still manages others, superuser manages superusers, Users list hides controls, anonymous redirected) |
| `compulab/test_route_access.py` | Two anonymous sweeps. (1) Every route with URL parameters, filled with real object ids, by GET and POST. (2) Every route without parameters, by POST, except a short allowlist of routes that are public on purpose (login, password reset, the PC lock screen and the agent APIs that use the shared secret); allowlisted routes must still not crash. Both sweeps require 302, 403, 404 or 405 and fail if any application table changes. They run on the throwaway test database; PCs have no IP address, so no agent is contacted, and email goes to the in-memory backend |

### 6.3 Evidence

| Check | Result |
|---|---|
| Full suite, in-memory SQLite | **77 tests, OK** |
| Full suite, throwaway **MariaDB 10.4.32** (separate data folder, 127.0.0.1, non-default port) | **77 tests, OK** |
| Full suite, throwaway **MySQL 8.4.8** (same isolation) | **77 tests, OK** |
| `manage.py check` (project settings), `check --database default` (MySQL 8.4) | No issues |
| `makemigrations --check` | No changes |
| New tests against the code **before** the fixes | Original Phase 1 tests: 16 of 27 fail. Final-review tests: 7 of 10 fail against the earlier Phase 1 code. The others check allowed access, so they pass either way. The new POST sweep fails on pre-Phase-1 code (`pc_bulk_power_action` → 500) |
| Browser (headless Chrome via Playwright, local server on a throwaway SQLite file with seeded accounts) | **36 of 36 checks pass**: anonymous redirects; non-superuser Admin sees no Edit/Reset/Delete on superuser rows, and typed URLs return 403; superuser keeps them; In-Charge sees and approves only own-lab requests through the UI, gets 404 for another lab, sees other labs' calendar sessions without Edit/Delete/code, and the Override picker offers only their lab; In-Charge with no lab sees nothing; instructor's roster dropdown lists only themself, another roster is 404, PDF export is 403, and the availability lookup hides another instructor's timetable |

The user's local MySQL services (`mysql`, `MySQL84`) were not started or modified. Throwaway database servers were started from the installed binaries with their own data folders and shut down afterwards.

### 6.4 Still open after Phase 1

- **Deployment:** the hosted instance still has C1 (and H3, M1, M2) until commit `1c57df4` is deployed to it.
- Not covered by this phase: H1, H2, H4, M3 to M11, L2 to L12. From the roadmap's Phase 1 list: login and code throttling with `secrets` (M5, roadmap item 7), constant-time secret comparison (L2), and GET-accepting notification actions (L3).
- `RequestCreateView` still lets an In-Charge log a pending request for any lab. That grants nothing, because approval is lab-scoped, but whether to restrict it is a policy choice.
- The schedule exports (`view_schedule_export_pdf` and `_excel`) still list every lab for an In-Charge. They contain no reservation codes.
