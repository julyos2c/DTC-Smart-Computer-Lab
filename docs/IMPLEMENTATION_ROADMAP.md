# Implementation Roadmap

**Status (updated 2026-10-22):** Phase 1 is implemented on branch `phase1-security-fixes`: C1, H3, M1, M2, L1 and In-Charge reservation scoping. It is **committed locally as `1c57df4` but not pushed or deployed**. See [SYSTEM_AUDIT.md §6](SYSTEM_AUDIT.md#6-phase-1-remediation-branch-phase1-security-fixes). Later phases are proposals and are not started. Finding IDs (C1, H2, …) refer to [SYSTEM_AUDIT.md §3](SYSTEM_AUDIT.md#3-prioritized-findings).

### Implementation status (working tree, 2026-10-22, not committed, not tested)

| # | Improvement | Status |
|---|---|---|
| 1 | Authorization gaps | Done in `1c57df4` (L3 GET-state-changes left: security hardening, out of scope) |
| 2 | Account lifecycle | **Implemented:** approval fields + data migration (`accounts` 0022/0023), `AccountActionCode`, in-person activation/reset codes, `/accounts/activate/`, approve/reject/reopen, offline-aware messages. Defaults used: D3 recommended (approved-unverified may sign in, emails held), D4 Admins (superuser for Admin-role targets), D5 admin-typed reset kept *and* reset codes added |
| 3 | Durable email outbox | **Implemented:** `EmailOutbox`, `notifications/outbox.py` (render-at-send for verification/reset, backoff, expiry, dead-letter notice), Admin page `/notifications/email-outbox/`; every email now queued |
| 4 | Worker + durable jobs | **Implemented:** `system` app, `manage.py run_worker`, `ScheduledJob` (Override grant), reminder catch-up, heartbeat, logged loop failures |
| 5 | Connectivity monitor + status UI | **Implemented:** separate probes (database, internet, SMTP, cloud receiver), worker health from completed cycles + overdue work, lab-agent contact, plain-language headline, footer with a per-browser "local server reachable" check, `/healthz`, `/healthz/ready`, Admin **System status** page with *Check again* |
| 6 | Transactions / row locks | **Partly:** reservation check-in claims its slot under a row lock before unlocking; approve/decline refuse non-pending requests. Override/manual unlock not wrapped |
| 7 | Login and code throttling | Not done (security hardening, out of scope); only the activation page has a per-IP attempt limit |
| 8 | Per-PC agent credentials | Not done (security hardening, out of scope). Agent config download per PC added |
| 9 | Agent reliability | **Implemented:** session-end events queued in `C:\ProgramData\CompuLab Agent` (bounded, 24 h, kept across updates), delivered only on server acknowledgement, backoff 15 s–5 min; server dedupes in the database (`AgentEventReceipt`) and ignores late events; lock screen explains a server outage; `agent-status.ps1` / `set-agent-server.ps1` |
| 10 | Platform upgrade | Server installer uses Django 5.2 (`requirements-production.txt`); dev `requirements.txt` unchanged (XAMPP MariaDB 10.4) |
| 11 | Installers, backups, update | **Implemented as PowerShell scripts** in `installer/` (needs Python, MariaDB, WinSW downloaded by hand): prerequisite and version checks, campus-address prompt, boot-time services with database dependency, `server-status.ps1` diagnostics |
| 12 | Remote access | **Implemented:** `configure-remote-access.ps1` (Tailscale Serve with HTTPS, or Direct), `COMPULAB_REMOTE_URL` accepted automatically, shown on System status; `installer/REMOTE_ACCESS.md`; staff launcher with LAN/VPN fallback. Tailscale sign-in is manual |
| 13 | LAN TLS | Not done (optional) |
| 14 | One-way publishing | **Sending side implemented** (`cloud_sync`, protocol v2 in `cloud_sync/PROTOCOL.md`: durable ordered queue, idempotency keys, backoff, pause on auth/address errors, conflict review, backfill). **No receiver exists**; off until one is configured (decisions D1/D14) |
| — | Manual verification | `docs/MANUAL_VERIFICATION.md` (16 scenarios, not yet performed) |
| 15 | Repository hygiene | Not done (no functional effect) |

Also added: reservation cancellation (instructors withdraw/cancel their own; lab deletions notify the instructor), M11 per-student code-email status on roster pages.

---

## 1. Proposed improvements (Deliverable 9)

Every item is tied to a finding or a stated requirement. Items marked *Future* are optional.

| # | Improvement | Problem it solves | How it would work | Modules / models changed | DB changes | Needs internet? | How to test |
|---|---|---|---|---|---|---|---|
| 1 | Close authorization gaps | C1, H3, M1, M2, L1, L3 | Login + role checks on the four scheduling views; ownership-scoped querysets for instructors; superuser-only edits of superusers; In-Charge lab check in Override/Manual Unlock POST; `@login_required` before role reads; POST-only state changes | `scheduling/views.py`, `accounts/views.py`, `labs/views.py`, `notifications/views.py` | None | No | Extend `compulab/tests.py` to sweep **every** route (with `pk` fixtures) anonymously and per role, GET and POST |
| 2 | Account lifecycle (approval ≠ email verification) | H2; brief §4 | See [OFFLINE_ACCOUNT_VERIFICATION.md](OFFLINE_ACCOUNT_VERIFICATION.md) | `accounts/models.py`, `backends.py`, `verification.py`, `forms.py`, `views.py`, `urls.py`, templates, `admin.py` | `User` + 6 fields; new `AccountActionCode`; `ActivityLog` choices | No | Decision-table tests (OFFLINE doc §9) |
| 3 | Durable email outbox | H4, M11 | All email becomes an `INSERT`; the worker sends with backoff; render-at-send for token emails; admin outbox screen | `notifications/services.py`, `accounts/views.py`, new `mailer` module (or inside `notifications`) | New `EmailOutbox` | Sending only | SMTP mocked: success, timeout, 4xx, 5xx; response time independent of SMTP |
| 4 | Separate worker service + durable jobs | M3 | `manage.py run_worker` runs all loops; `ScheduledJob` for override grants; reminder catch-up; heartbeat; logged exceptions | `labs/network.py`, `labs/maintenance.py`, `notifications/reminders.py`, `labs/views.py` (override), `compulab/background.py` | New `ScheduledJob`, `SystemStatus` | No | Kill the worker mid-override → grant still happens after restart; two workers → each job runs once |
| 5 | Connectivity monitor + status UI | Brief §3B ("understandable messages"); L5 | Probes database, SMTP and internet; badge from server state; clear messages on online-only actions; `/healthz` | New `compulab/health.py`, `accounts/context_processors.py`, `footer.html`, password-reset templates | `SystemStatus` | No | Simulated probe failures → correct badge and messages |
| 6 | Transactions and row locks on PC/session state | M4 | `atomic()` + `select_for_update()` on PC and Session in check-in, override, manual unlock, approve, generate | `labs/views.py`, `scheduling/views.py`, `scheduling/models.py` | None | No | Concurrent check-ins (threads) against MariaDB cannot exceed caps or double-assign |
| 7 | Login and code throttling | M5 | Per-account + per-IP lockout with backoff; `secrets` for codes; throttle the agent login per PC/ID | `accounts/views.py`, `labs/views.py`, `scheduling/utils.py` | None (cache) | No | Lockout after N failures; unlock after the window; admin alert queued once |
| 8 | Per-PC agent credentials + signed commands | H1, M6 | Enrollment code → per-PC token (hashed); HMAC with timestamp and nonce both ways; firewall to the server IP; drop CORS `*`; token identifies the PC (IP becomes a hint) | `labs/models.py` (`PCCredential`), agent APIs, `labs/network.py`, `lab_pc_agent/agent.py`, `manual_unlock.html` | New `PCCredential`; `PC.agent_version`, `last_seen_ip` | No | Wrong, replayed or stale signatures rejected; revoked token rejected; IP change keeps identity |
| 9 | Agent reliability | Business logic §2.8 end-of-session best-effort | Agent persists unsent callbacks with `event_id` and retries; the server dedupes | `lab_pc_agent/agent.py`, end-session/logout APIs | `AgentEvent` (dedupe) or a unique key on `ActivityLog` | No | Disconnect during logout → server converges once reconnected, without duplicates |
| 10 | Platform upgrade | M8 | MariaDB LTS on the server; Django 5.2 LTS in **one** `requirements.txt` | `requirements*.txt`, `DEPLOYMENT.md` | None (Django migrations only, if any) | No | Full test suite on MariaDB 10.11/11.4 |
| 11 | Server and agent installers, backups, restore, update | Brief §5; M9 | See [LAN_AND_REMOTE_ACCESS.md §7](LAN_AND_REMOTE_ACCESS.md#7-installation-and-setup-design-deliverable-5) | New `installer/` folder (Inno Setup scripts, WinSW XML, PowerShell) | None | No (offline install) | Clean-machine install; upgrade; rollback; restore drill |
| 12 | Remote access | Brief §6 | Tailscale on the server; ACL to staff; launcher detects local vs VPN | Docs, launcher | None | Yes | Remote device reaches the server only when in the ACL |
| 13 | LAN TLS (*Future*) | M7 | Caddy internal CA; trusted root installed on staff PCs | installer | None | No | `check --deploy` clean in TLS mode |
| 14 | One-way publishing (*Future*, only if approved) | M10; brief §3A "central server if required" | [HYBRID_ARCHITECTURE.md §7](HYBRID_ARCHITECTURE.md#7-synchronization-specification-deliverable-7) | `cloud_sync/`, published models | `public_id` UUIDs; `SyncQueue` v2 | Yes | Sync test plan (HYBRID §7.3) |
| 15 | Repository hygiene | L8, L6, L10 | Remove `labs/views-old.py`, `static.zip`, `structure.txt`; move `data*.json` out of the project; templates use `SITE_URL`; empty defaults for hosts | various | None | No | Tests still pass |

---

## 2. Before and after

### 2.1 Account verification: new instructor during an internet outage

| | |
|---|---|
| **Current behavior** | Admin creates the account → the page waits for the SMTP timeout → "could not be sent". The account cannot sign in. "Reset password" leaves it blocked. Editing it forces the admin to invent a password. The instructor cannot work until the internet returns *and* someone clicks Resend |
| **Weakness** | No offline activation; the admin learns passwords; slow pages; no record of who vouched for the account |
| **Proposed behavior** | Admin creates the account → returns instantly ("Internet unavailable: verification email queued"). Admin checks the instructor's school ID and clicks **Approve in person** → a one-time code is shown → the instructor enters it at `/accounts/activate/` and chooses their own password → can sign in immediately. When the internet returns, the queued verification email is sent (freshly generated); clicking it records email ownership |
| **Benefit** | Work continues offline; the password is known only to its owner; the audit trail shows approver, time and method; email ownership is still proven later |

### 2.2 LAN / offline workflow: internet drops at 10:00 during classes

| | |
|---|---|
| **Current behavior** (on-prem server) | Student unlocks keep working. Every notification (PC offline/online alerts, approvals, roster reminders) blocks its thread on SMTP. The PC status loop slows down exactly when it matters, and after-hours locks and stale releases run late. Emails are silently dropped. Footer still says "System operational". (On the MochaHost instance, nothing works at all from the lab.) |
| **Weakness** | Silent loss, cascading slowness, misleading status |
| **Proposed behavior** | Badge turns to "Internet: offline since 10:00 · 12 emails waiting". Notifications are created in-app instantly; emails are queued. The PC loop is unaffected. Roster students who did not receive their code email are visible to the instructor, who reads codes from their calendar. At 13:00 the internet returns → the worker sends still-relevant emails; reservation codes for sessions that already ended are expired, not sent |
| **Benefit** | No slowdown, no loss, honest status, no stale emails |

### 2.3 Override across a server restart

| | |
|---|---|
| **Current** | Override on an occupied PC → the outgoing user is warned and ended → the grant sleeps in a thread for 32 s. If the service restarts during that time, the new user never gets the PC and nothing records the failure |
| **Proposed** | A `ScheduledJob(override_grant, run_at=now+32s)` row is created in the same transaction as the check-out; the worker executes it after a restart too, exactly once; the outcome is logged |

### 2.4 Reservation approval security

| | |
|---|---|
| **Current** | Anyone who can reach the site can POST `/schedule/request/<id>/approve/` and get a working unlock code (Tested) |
| **Proposed** | Admin/In-Charge only (In-Charge scoped to their lab); POST-only; covered by an all-routes authorization test |

### 2.5 Two students using one group code at the same moment

| | |
|---|---|
| **Current** | Both requests read "others checked in = cap − 1" and both succeed, exceeding the cap |
| **Proposed** | The `Session` row is locked during the cap check and check-in; the second request sees the updated count and is refused with the existing message |

---

## 3. Phased plan

Each phase is shippable on its own and keeps existing features working. Rules for every phase: work on a branch; back up before migrations; do not apply migrations to production without approval and a verified backup; add tests with the change.

### Phase 0: Preparation (mandatory, small)

- **Back up** the production database and media (hosted instance) and record the backup location.
- **Source control:** put the current uncommitted work under version control on a branch, so deployments come from a known commit rather than streamed files. *Status: done locally. The earlier work is commit `f511574` on branch `phase1-security-fixes`; not pushed.*
- **Test settings:** a `compulab/settings_test.py` option (SQLite) so the suite runs without MySQL. Keep MariaDB CI runs for the database-specific code.
- **Confirm** which instance(s) hold real data today (decision D1).

### Phase 1: Security blockers (mandatory; ship first, to every running instance)

- **Fixes:** items 1 and 7 (partial: login lockout, `secrets` codes), and L2.
- **Files:** `scheduling/views.py`, `accounts/views.py`, `labs/views.py`, `notifications/views.py`, `scheduling/utils.py`, `compulab/tests.py`, new tests in `scheduling/tests.py` and `labs/tests.py`.
- **Migrations:** none.
- **Done when:** the all-routes authorization test passes; the C1 probe returns 302 to login / 403, with nothing changed.
- **Status (2026-10-22):**
  - **Done in commit `1c57df4`** on branch `phase1-security-fixes` (committed locally; not pushed or deployed): item 1 for C1, H3, M1, M2 and L1, plus Lab In-Charge reservation scoping. The all-routes anonymous sweeps pass. 77 tests pass on SQLite, MariaDB 10.4 and MySQL 8.4.
  - **Not yet done from this phase:** item 7 (throttling, `secrets` codes), L2 and L3. These were outside the approved scope.

### Phase 2: Account lifecycle + email outbox (mandatory for offline)

- **Fixes:** items 2 and 3 (H2, H4, M11).
- **Models and migrations:** `User` fields; `AccountActionCode`; `EmailOutbox`; `ActivityLog` choices. All additive, plus a data migration mapping existing users (§5.1 of the OFFLINE doc).
- **Services:** `accounts/lifecycle.py` (approve, issue/redeem code, policy functions); `notifications/outbox.py` (queue, render-at-send, dispatch).
- **Views and templates:** Approve-in-person, activation page, outbox admin page, offline-aware password reset page.
- **Tests:** OFFLINE doc §9.
- **Depends on:** Phase 1. The dispatcher can initially run inside the existing background thread, then moves to the worker in Phase 3.

### Phase 3: Worker, durable jobs, connectivity, integrity (mandatory)

- **Fixes:** items 4, 5 and 6 (M3, M4, L5).
- **New:** `ScheduledJob`, `SystemStatus` models; `manage.py run_worker`; `/healthz`; status badge.
- **Refactor:** loops out of `AppConfig.ready()`; transactions in check-in, override and approval.
- **Tests:** restart and concurrency tests (MariaDB required for `select_for_update`).
- **Depends on:** Phase 2 (the outbox dispatcher lives here).

### Phase 4: Server platform and server installer (mandatory)

- **Fixes:** items 10 and 11 (server part) (M8, M9).
- **Work:**
  - MariaDB LTS, Django 5.2 LTS, a single requirements file with pinned versions (plus hashes, optionally);
  - Inno Setup + WinSW + PowerShell scripts in `installer/server/`;
  - backup and restore scripts with a restore drill;
  - update and rollback procedure;
  - `compulab-config` helper (set address, SMTP);
  - updated `DEPLOYMENT.md`.
- **Depends on:** Phase 3 (two services to install).

### Phase 5: Agent security, agent installer, staff launcher (mandatory for LAN production)

- **Fixes:** items 8, 9 and 11 (client part) (H1, M6).
- **Models and migrations:** `PCCredential`; enrollment API; HMAC signing on both sides; firewall rules; replacement of the shared secret and of the `manual_unlock.html` design (D9).
- **Packaging:** PyInstaller build; `installer/agent/`. Service/UI split as a follow-up if not done here.
- **Migration path:** a release that accepts both the old shared secret and tokens, then a release that removes the shared secret once every PC is enrolled.
- **Depends on:** Phase 4 for the installer pattern; it can start in parallel with Phase 4 on code.

### Phase 6: Remote access (mandatory if remote use is required)

- **Fixes:** item 12.
- **Work:** Tailscale (or the D7 alternative) on the server; ACLs; launcher LAN/VPN detection; a runbook for adding and removing remote users.
- **Depends on:** Phases 1 and 4.

### Phase 7: Optional enhancements

- Item 13 (LAN TLS), after Phase 5.
- Item 14 (one-way publishing), only after D1 and D14 are answered.
- Retire or repurpose the MochaHost instance per D1.

### Phase 8: Reliability, security and recovery testing (mandatory before go-live)

- **Load:** about 40 lab PCs heartbeating every 8 s plus 10 staff users; measure response times and database growth.
- **Failure drills:**
  - unplug the uplink for 4 hours (offline mode);
  - power-cut the server (UPS and auto-start);
  - kill the worker;
  - restore yesterday's backup onto a spare machine.
- **Security:** re-run the all-routes authorization test; check agent signature tests; scan for open ports from a lab PC and from outside the campus; `check --deploy`; dependency audit (`pip-audit`).
- **Acceptance:** the [EXISTING_BUSINESS_LOGIC.md §5](EXISTING_BUSINESS_LOGIC.md#5-feature-matrix-online-vs-offline) matrix re-verified, with "Expected" entries replaced by test results.

### Dependencies

```
P0 ─► P1 ─► P2 ─► P3 ─► P4 ─► P6
              │           │
              │           └─► P5 ─► P7 (LAN TLS)
              └───────────────────► P7 (publishing, only if approved)
P8 runs at the end, and its drills are repeated after each later change.
```

---

## Decisions needed before implementation

| # | Decision | Options (recommendation first) | Affects |
|---|---|---|---|
| D1 | Role of the MochaHost instance; which instance holds real data today | Retire it and show a notice page / keep it for a read-only mirror later / keep it as the main system (conflicts with the offline requirement) | Phase 0, 7 |
| D2 | Topology facts | One routed campus LAN for all labs? Number of labs and PCs? Which machine can be the dedicated server? UPS available? Is there Active Directory? | Phases 4 and 5 sizing |
| D3 | Accounts approved in person but with unverified email | May sign in, with email reset and notifications held (recommended) / must wait for email verification | Phase 2 |
| D4 | Who may approve accounts and issue codes | Admins (with a superuser required for Admin-role accounts) (recommended) / also Lab In-Charge | Phase 2 |
| D5 | Keep "admin types a temporary password"? | Replace it with reset codes (recommended) / keep it with forced change at next login | Phase 2 |
| D6 | Staff session lifetime | 12 hours (recommended) / browser-session only / Django default (2 weeks) | Phase 2 |
| D7 | Remote access method and audience | Tailscale for Admins and In-Charges (recommended) / WireGuard self-hosted / Cloudflare Tunnel + Access / instructors too? | Phase 6 |
| D8 | HTTPS on the LAN | Later, via Caddy internal CA (recommended) / now / never (wired VLAN only) | Phase 7 |
| D9 | Emergency unlock when the server is down | Pre-printed signed one-time codes per PC / per-In-Charge emergency PIN on the agent / keep a shared secret (not recommended) | Phase 5 |
| D10 | Gmail-only email rule | Allow the college's own domain as well / keep Gmail-only | Phase 2 |
| D11 | Activity-monitoring retention and notice | Current: nightly wipe, 14-day spreadsheets. Confirm with the college's data-privacy policy and confirm students are informed (the README recommends a disclosure) | Phase 3 |
| D12 | How students get roster codes when email is down | Instructor reads codes from their calendar (works today) / also show on the lock screen's lab info / printed sheet | Phase 2 |
| D13 | Background job implementation | Small built-in database queue (recommended, no new services) / `django-q2` | Phase 3 |
| D14 | Is any write from off-campus needed (e.g. reservation requests from home)? | No (recommended for now) / yes, via the command pattern in HYBRID §7.2 | Phase 7 |
| D15 | Release process | Git-based releases with tags and the installer (recommended) / continue copying files to the server | Phase 0 |
| D16 | Lab PC Windows accounts | Students use a standard (non-admin) account (required for the agent hardening to mean anything) / currently admin? (Unverified) | Phase 5 |
