# Account Verification, Activation and Recovery: Online and Offline

**Status:** proposal for review. §1 describes current behavior (Observed); everything after it is proposed.

---

## 1. Current behavior

- **Accounts are created only by an Admin.** There is no public sign-up.
  - Admin-role accounts get a password typed by the creating admin.
  - In-Charge and Instructor accounts get **no password**.
  - Students never sign in to the website.
- **A non-superuser, non-student account cannot sign in until `email_verified=True`.** This is enforced in `accounts.backends.VerifiedEmailBackend` for every login route and for existing sessions.
- **The only way to set `email_verified=True` is clicking the emailed link.** The link is HMAC-signed, expires after 72 hours, works once, and is superseded by any newer link or an email change. On first use it also lets an In-Charge or Instructor choose their own password.
- **Offline (no SMTP):**
  - the verification email fails after the SMTP timeout;
  - the account can never be activated;
  - admin "Reset password" does not help, because the account stays unverified and the admin now knows the password;
  - editing the pending account forces the admin to set a password (audit H2).
- **One boolean carries too much.** `email_verified` stands for "owns this mailbox", "is allowed in" and "has activated" all at once. There is no record of who approved an account or how.

---

## 2. Four different things that must not be confused

| Concept | Question it answers | How it is proven | Today |
|---|---|---|---|
| **Authentication** | Is this the account holder signing in now? | Password, at every login | Yes (Django password hashing, PBKDF2) |
| **Email ownership verification** | Does this person control this mailbox? | Clicking a link or code sent *to that mailbox* | Yes, the link (online only) |
| **Identity verification** | Is this person who they claim to be (a real DTC instructor)? | An authorized person checks them, for example in person with a school ID | Not recorded. Implicit in "an Admin created the account" |
| **Administrator approval** | Is this person allowed to use CompuLab, in this role? | An Admin's recorded decision | Implicit in account creation; not recorded |

An Admin approving someone in person proves identity and approval. It does **not** prove the email address is correct or reachable. An emailed link proves mailbox control. It does **not** prove identity: anyone could have typed their own address. The proposal records each fact separately.

---

## 3. Options evaluated

### Option 1: Local administrator approval

The Admin confirms the person's identity (for example, school ID in person) and approves the account; the system records approver, time and method.

| Fit | Notes |
|---|---|
| Works offline | Yes |
| Security | Strong for identity, if the admin follows a written procedure. A malicious or careless admin is the main risk, so it must be audited |
| Weakness | Does not verify the email; the admin must not choose the user's password |

### Option 2: Deferred email verification

The verification email is queued and sent when connectivity returns; only low-risk actions are allowed before then.

| Fit | Notes |
|---|---|
| Works offline | Partly: it delays, it does not activate |
| Security | Proves mailbox control once delivered |
| Weakness | On its own, an offline-created account waits hours or days with nothing useful it can do. The current role model has no "low-risk" pre-activation actions worth allowing |

### Option 3: Institution-managed invitation or activation code

An Admin generates a code; codes expire, are single-use and rate-limited; issuance and redemption are recorded.

| Fit | Notes |
|---|---|
| Works offline | Yes: the code lives on the local server and is handed over on paper or screen |
| Security | Good if the code is bound to **one specific account**, long enough, stored hashed, single-use, short-lived and attempt-limited |
| Weakness | Generic, reusable "invitation codes" (one code, many accounts) are guessable and shareable. **Not recommended** |
| Best use | As the *delivery mechanism* for Option 1: it lets the owner set their own password, so the admin never knows it |

### Option 4: Pre-provisioned accounts

Accounts are created and activated before an offline period (for example, at the start of term, while online).

| Fit | Notes |
|---|---|
| Works offline | Yes, for already-activated accounts (they only need the local database) |
| Security | Same as normal online activation |
| Weakness | Doesn't help new hires mid-term or during an outage |

---

## 4. Recommendation: combine 1 + 3 + 2 + 4

1. **Pre-provision (Option 4)** all staff accounts at the start of each term, while online, using normal email activation. This keeps offline activation the exception.
2. **In-person activation code (Options 1 + 3)** whenever email is unavailable or unreliable. Approval is recorded as an identity check by a named admin; the code lets the owner set their own password.
3. **Deferred email verification (Option 2)** runs in the background for every account whose email is not yet verified. When delivered and clicked, it adds "email verified"; it never removes access granted by an in-person approval.
4. **Policy for "approved in person, email not yet verified"** (recommended default; decision D3):
   - the account may sign in and use its role;
   - email-based password reset is **disabled** for it until the email is verified;
   - automatic notification emails are held until the address is verified, except the verification email itself;
   - the profile shows "Email not verified yet — check your inbox when the campus is online";
   - Admins see a list of such accounts.
5. **Higher bar for Admin-role accounts:** an Admin-role account can only be approved by a **superuser**, online or offline.

---

## 5. Proposed data model (all additive migrations, no data removed)

### 5.1 `User` additions

| Field | Type | Meaning |
|---|---|---|
| `email_verified_at` | DateTime, null | When mailbox control was proven. `email_verified` stays (kept in sync) for compatibility during the transition |
| `approval_status` | `pending` / `approved` / `rejected` | Whether the account is allowed to sign in (besides `is_active`) |
| `approved_by` | FK User, null, `SET_NULL` | Who approved |
| `approved_at` | DateTime, null | When |
| `approval_method` | `email_link` / `in_person_code` / `superuser_bootstrap` / `migrated` | How |
| `must_change_password` | Bool | For the fallback "admin-typed temporary password" path, if kept |

**Migration of existing rows**, recorded as `approval_method='migrated'`:

| Existing state | Migrated to |
|---|---|
| `email_verified=True` | `approval_status='approved'`, `email_verified_at` = migration time. The real time is unknown; this is documented |
| Superusers | Approved |
| Unverified staff | Pending |
| Students | Untouched (they still never sign in) |

### 5.2 `AccountActionCode` (new)

| Field | Notes |
|---|---|
| `user` | FK, the one account this code is valid for |
| `purpose` | `activate` / `reset_password` |
| `code_hash` | HMAC-SHA256(SECRET_KEY, `user_id:purpose:code`). The plaintext is shown once and never stored, logged or emailed |
| `issued_by`, `issued_at`, `issued_from_ip` | Audit |
| `expires_at` | `activate`: 72 h. `reset_password`: 60 min (configurable) |
| `used_at`, `revoked_at` | Single use. Issuing a new code revokes the previous one for the same user and purpose |
| `failed_attempts` | The code is revoked after 5 failures |

**Code format:** 10 characters from the existing unambiguous 32-character alphabet, shown as `XXXXX-XXXXX`. That is 50 bits; with 5 attempts per code plus per-IP throttling, guessing is infeasible. Generated with `secrets`, not `random`.

**Replay and misuse protections:**
- `used_at` is set in the same transaction as the password change, under `select_for_update()`;
- the code is bound to one account;
- it expires;
- issuing a new code revokes the old one;
- it never changes the role;
- Admin-role accounts require a superuser issuer.

### 5.3 Audit events (extend `ActivityLog.ACTION_CHOICES`)

`approve_account`, `reject_account`, `issue_activation_code`, `redeem_activation_code`, `issue_reset_code`, `redeem_reset_code`, `code_revoked`, `email_verified`, `email_delivery_failed`. Each records the actor, the target account, the method, and never the code.

### 5.4 Sign-in rule (replaces `requires_verification`)

```
can_sign_in(user) =
    user.is_active
    and user.role != 'student'
    and (user.is_superuser or user.approval_status == 'approved')

email_features_allowed(user) = user.email_verified_at is not None
```

Clicking an email link sets **both** `email_verified_at` and (if still pending) approval with `approval_method='email_link'`. This preserves today's online behavior exactly.

---

## 6. Email outbox (durable queue)

### 6.1 Model `EmailOutbox`

| Field | Notes |
|---|---|
| `category` | `verification`, `password_reset`, `password_changed`, `reservation_code`, `notification`, `welcome`, `security_alert` |
| `to`, `subject` | |
| `render_mode` | `stored` (body saved at queue time) or `render_at_send` (template name + `user_id`; the body, **including any token, is generated only when sending**) |
| `text_body`, `html_body` | Only for `stored`. Purged 30 days after sending |
| `dedupe_key` | Unique, nullable, for example `verify:{user_id}` while pending, or `code:{session_id}:{user_id}` |
| `status` | `pending` → `sending` → `sent`, or `retry`, `dead`, `expired`, `cancelled` |
| `attempts`, `next_attempt_at`, `last_error` | `last_error` is the SMTP code and exception class only (no body, no token) |
| `expires_at` | For example, reservation-code emails expire at session end; verification at queue time + 7 days |
| `user`, `created_by`, `created_at`, `sent_at` | Audit |

### 6.2 Rules

- **Queueing never blocks a page.** Callers (`notify()`, `send_verification_email()`, imports, the reset form) only `INSERT` a row, inside the caller's transaction where there is one.
- **Token-bearing messages are rendered at send time.**
  - Verification and password-reset links are generated when the worker actually sends, so a link's 72-hour validity starts at delivery, not at queueing.
  - No usable token sits in the database waiting for days.
  - The "only the latest link works" rule still holds (`email_verification_sent_at` is set at send time).
- **Retry with backoff:** 1, 2, 4, 8, 16, 32, then every 60 minutes. While the connectivity monitor reports SMTP down, attempts pause, with one probe send every 10 minutes.
- **Permanent failures:** an SMTP 5xx recipient rejection becomes `dead` immediately. The admin gets an in-app notice ("address rejected: fix the email on the account"). 4xx responses and network errors retry.
- **Expiry:** queued messages past `expires_at` become `expired` and are not sent. A reservation code for a session that has ended is useless; a stale verification is replaced by a fresh one on request.
- **Duplicate prevention:** `dedupe_key` uniqueness; the worker claims rows with a status transition under a row lock. A crash after SMTP accepted the message but before it is marked `sent` can cause **one** duplicate. That is acceptable (at-least-once delivery) and documented.
- **Delivery honesty:** "sent" means *accepted by the SMTP server*, not "in the inbox". The current host has no delivery tracking (cPanel EmailTrack is not installed), so bounce messages arriving in the sending mailbox must be checked; a later phase could read bounces over IMAP.
- **Admin view** (`/accounts/email-outbox/`, Admin only):
  - counts by status;
  - a list with recipient, category, status, attempts, last error and age;
  - actions: Retry now, Cancel, and (for `verification`) "Issue in-person code instead";
  - **bodies of token-bearing categories are never displayed.**

---

## 7. Password reset and authentication security

| Situation | Available path |
|---|---|
| Online | Existing email reset link, delivered through the outbox. The form returns immediately; generic answer whether or not the account exists. Only for accounts with `email_verified_at` set |
| Offline (or email not verified) | The reset page states that email reset is unavailable and points to an Admin. **Admin-assisted reset:** the Admin confirms identity in person → issues a `reset_password` code (60 min) → the user enters email + code + new password at `/accounts/activate/` and chooses their own password. Audited |
| Fallback (decision D5) | Keep "admin types a temporary password" only with `must_change_password=True`, forcing a change at next login. Otherwise remove it |

**Controls that apply in every mode** (offline accounts cannot bypass any of them):

- **Rate limiting:**
  - staff login: per-account and per-IP failure counters in the shared file cache; after 5 failures in 15 minutes, a 15-minute lockout per account+IP, growing with repeats. The admin alert stays, but is queued rather than sent inline;
  - code redemption: 5 attempts per code, plus a per-IP limit;
  - reservation-code login at lab PCs: per-PC and per-ID throttle.
- **Secrets never in logs:** codes, tokens and reset links are never logged, never stored in `ActivityLog`, and never shown in the outbox UI.
- **Sessions:** keep Django's session rotation on login. Shorten the staff session lifetime (for example 12 h, decision D6). Invalidate sessions on password change; this already happens, except for the current session.
- **CSRF:** unchanged (already enforced). All state-changing views POST-only (audit L3).
- **Authorization:** fix audit C1, H3, M1 and M2 first. Approval never grants more than the role the Admin assigned.
- **Password storage:** Django PBKDF2 (current default) is acceptable. Argon2 is optional (adds the `argon2-cffi` dependency).
- **Transport:** see the HTTPS discussion in [LAN_AND_REMOTE_ACCESS.md](LAN_AND_REMOTE_ACCESS.md#5-https-on-the-lan). Codes and passwords crossing plain HTTP on Wi-Fi are exposed.

---

## 8. Decision flow (Deliverable 4)

| # | Situation | System behavior | User experience | Admin experience / audit |
|---|---|---|---|---|
| 1 | Admin creates a staff account **while online** | Account `pending`; verification email queued (`render_at_send`); the worker sends within seconds | Gets the email, clicks, sets own password (In-Charge, Instructor) or confirms (Admin role) → `approved` via `email_link`, `email_verified_at` set → can sign in | Users list shows "Pending — email sent 10:02". Audit: `register`, `email_verified` |
| 2 | Admin creates a staff account **while offline** | Account `pending`; email queued (waits) | Option A (recommended): the Admin checks the person's school ID and clicks **Approve in person** → a code is shown once → the user activates at `/accounts/activate/` and sets a password → can sign in now; the email link arrives later and marks the email verified. Option B: wait for the email | The page shows "Internet unavailable: email queued. Approve in person instead?" Audit: `issue_activation_code`, `redeem_activation_code` (method `in_person_code`, approved_by) |
| 3 | Internet up but **SMTP fails** (bad credentials, provider down) | The send fails; the row goes to `retry` with backoff; the connectivity monitor shows "SMTP failing"; 5xx recipient errors become `dead` | User sees nothing new; same choices as #2 | Outbox shows the error class and SMTP code; Admin banner "Email delivery failing since …". Audit: `email_delivery_failed` on `dead` |
| 4 | Local server running, **no internet** | All LAN features work; email rows accumulate; status badge "Internet: offline" | Online-only actions say so plainly (e.g. password reset page) | Badge plus queue counts; in-person codes available |
| 5 | Internet returns **after hours or days** | The worker resumes; expired items are marked `expired` and not sent; valid ones are sent oldest-first, rate-limited (e.g. 30 per minute) to avoid provider throttling; token emails are rendered fresh at send time | Users receive only still-relevant emails, with links valid from that moment | Outbox shows sent / expired counts |
| 6 | Verification link **expired** | `check_status` → `expired` (unchanged) | Result page offers "Send a new link" (if online) **or** "Ask your Lab Administrator for an activation code" | If resent: a new row in the outbox. Audit as today |
| 7 | Verification link **reused** | First use verified; later uses → `used` (unchanged, already tested) | "Your email is already verified, sign in" | none |
| 8 | **Local admin approves** an account | Requires the Admin role; Admin-role targets require a superuser; code issued (hashed), previous code revoked | User activates with the code, sets own password | Code shown once, printable. Audit with approver, time, method |
| 9 | Existing verified user **logs in while offline** | Password check against the local database; no internet involved | Signs in normally | none (normal session) |
| 10 | **Password reset requested while offline** | Self-service form answers "email reset unavailable offline" and creates no queued reset email (a reset link would be useless hours later) | Told to see an Admin | Admin issues a `reset_password` code after an in-person identity check; the user sets their own password. Audit: `issue_reset_code`, `redeem_reset_code` |

---

## 9. Tests to add with the implementation

1. Every row of the decision table as a test, with SMTP mocked to succeed, raise `SMTPServerDisconnected`, return 5xx, or time out.
2. Code security: wrong code ×5 revokes the code; a code for user A does not work for user B; expired codes fail; a used code cannot be reused; issuing a new code invalidates the old one; codes never appear in logs, `ActivityLog.details` or rendered templates after issuance.
3. Policy: approved-but-unverified accounts can sign in; email reset is refused; notifications are held.
4. Migration test: existing verified, unverified, superuser and student rows map as in §5.1.
5. Outbox: page response time does not depend on SMTP; dedupe keys; backoff timing; expiry; render-at-send produces a link that is valid for 72 h from the send time.
6. Authorization: only a superuser can approve an Admin-role account; an In-Charge cannot issue codes (decision D4).
