# Hybrid Online/Offline Architecture: Options and Recommendation

**Status:** proposal for review. Nothing here is implemented. Facts about the current code come from [SYSTEM_AUDIT.md](SYSTEM_AUDIT.md) and [EXISTING_BUSINESS_LOGIC.md](EXISTING_BUSINESS_LOGIC.md).

---

## 1. Requirements and the constraints that decide the design

**Stated requirements (from the brief)**

- **Online mode:** remote authorized access, email (verification, recovery, notifications), protected accounts.
- **Offline mode:** LAN users keep working; the local server keeps serving without internet services; online-only features fail with a clear message; deferred work is queued safely and resumes without duplicates.
- Losing the internet must not make a healthy local server inaccessible.

**Hard constraints found in the code**

1. **Lab PC control only works from inside the LAN.**
   - The server sends HTTP to `http://<pc-lan-ip>:5555` to unlock, lock, warn, shut down and restart.
   - It pings each PC's LAN IP every 20 s.
   - It identifies each PC by the source IP of the agent's requests.

   A server on the internet cannot do any of this. The college's PC infrastructure therefore needs a server **on the lab network**, whatever else exists.
2. **The only internet-dependent function is outgoing email** (plus cosmetic Google Fonts). Everything else is local database work.
3. **Today there is one database per deployment and no working synchronization.** If both the hosted (MochaHost) instance and an on-prem instance are used, they are two unrelated systems with diverging data.
4. **Background work lives in web-process threads.** It must become a single, supervised worker before offline queuing can be reliable.

**Three availability states that must be tracked separately**

| State | Meaning | What depends on it |
|---|---|---|
| Server healthy | Django and the database up | Everything |
| LAN path to each PC | Ping and agent port reachable | Unlock, lock, status, activity |
| Internet / SMTP reachable | Outbound to the mail server | Email; remote users (unless they arrive over a VPN that is itself up) |

Losing the internet changes only the third state.

---

## 2. Approaches compared

### Approach 1: Local LAN server plus a shared central online server, both writable, synchronized

Each campus runs an on-prem server; a hosted central server also accepts edits; the two synchronize in both directions.

| Aspect | Assessment |
|---|---|
| Advantages | Remote users always hit a fast hosted site; data visible centrally |
| Disadvantages | **Bidirectional sync of this data model is hard.** Integer primary keys collide; `reservation_code` is unique per database; capacity rules (`_slot_error`) are checked against one database's sessions, so two servers can each approve overlapping bookings offline; PC state is owned by the LAN and meaningless centrally |
| Complexity / maintenance | Very high: conflict rules per model, UUID migration of every table, schema-version coordination, two deployments to upgrade in lockstep |
| Data ownership and sync | Ambiguous: both write the same entities |
| Offline availability | Good locally |
| Remote access | Good (hosted) |
| Security | Two attack surfaces; synced data includes accounts and password hashes; the hosted instance becomes a way into on-prem data |
| Hosting | MochaHost plus an on-prem Windows server |
| Suitability | **Poor.** Highest risk for the least benefit at a single college |

### Approach 2: Standalone on-prem server, authoritative, independent; optional one-way publishing later

One on-prem CompuLab server is the only writable copy. Remote users connect *to it* through a VPN overlay. Optionally, later, it pushes a read-only subset to a hosted page.

| Aspect | Assessment |
|---|---|
| Advantages | Matches the code as it is (one database, LAN-side PC control); no conflict resolution; works fully offline; smallest change set; `DEPLOYMENT.md` topology A already recommends it |
| Disadvantages | Remote access requires the on-prem server and its uplink to be up; a server outage stops everything (mitigated by backups, a UPS and a documented restore); remote users need a VPN client |
| Complexity / maintenance | Low to moderate: one server to run, back up and update |
| Data ownership and sync | Unambiguous: the on-prem database owns everything. Optional mirror is one-way and disposable |
| Offline availability | Full, except email and remote access |
| Remote access | Through Tailscale or WireGuard to the on-prem server (see [LAN_AND_REMOTE_ACCESS.md](LAN_AND_REMOTE_ACCESS.md)) |
| Security | One system to secure. No inbound ports opened on the school router. Passwords never leave the campus |
| Hosting | One on-prem Windows machine (dedicated PC or small server) with a UPS |
| Suitability | **Best fit.** Recommended |

### Approach 3: Central hosted Django plus a local gateway on the LAN

Everything is hosted at MochaHost. A small on-prem gateway relays commands to PCs, or the agents poll the hosted server (`DEPLOYMENT.md` topology C).

| Aspect | Assessment |
|---|---|
| Advantages | One hosted system; remote access trivial; hosting provider handles the server |
| Disadvantages | **Offline mode fails the core requirement.** With the internet down, nobody on the LAN can log in, reserve or unlock, because the database is remote. Making the gateway serve the app offline turns it into Approach 1. Requires reworking the agent (polling, token identity) and the whole unlock flow |
| Complexity / maintenance | High (agent and protocol rewrite) |
| Data ownership | Hosted |
| Offline availability | **None**, except agents keeping their current lock state |
| Remote access | Excellent |
| Security | Agents hold credentials that reach a public server; the shared-hosting cPanel account is shared with other college sites |
| Hosting | MochaHost shared hosting (Passenger workers start and stop on demand, so long-running loops are not supported) |
| Suitability | **Unsuitable** given the offline requirement |

---

## 3. Recommendation

**Adopt Approach 2:**

1. **One on-prem CompuLab server per independent lab network** is the single source of truth. For DTC this is one server, assuming all labs share one routed campus LAN (to be confirmed).
2. **No bidirectional synchronization.** No second writable database.
3. **Remote access** is a VPN overlay to the same server (Tailscale recommended, WireGuard as the self-hosted alternative).
4. **The MochaHost instance** gets one of these roles (decision needed):
   - **(a) Retire** it and point `compulab.<college-domain>` at a static page saying "CompuLab is available on campus or over the VPN". Recommended for now.
   - **(b) Keep** a read-only public status page fed by one-way publishing (§7), as a later optional phase.
   - **(c) Use it only as an SMTP relay identity**: the on-prem server keeps sending through the same college mailbox, which already works from anywhere.
5. **Email** goes through a durable outbox, so internet loss delays mail instead of breaking pages or losing messages.
6. **Background work** moves to one supervised worker service with durable jobs.

**Assumptions to confirm**

- Single campus, one routed LAN reaching all lab PCs.
- A machine can be dedicated as the server: always on, with a UPS.
- The college accepts a VPN client for remote staff.

**If more campuses are added later:** each campus runs its own authoritative server for its own labs. Cross-campus views come from one-way publishing into a reporting store, never from merging writes.

---

## 4. Connectivity awareness (online vs offline behavior)

### 4.1 Detection

A **connectivity monitor** in the worker runs every 60 s:

| Probe | How | Timeout |
|---|---|---|
| Database | `SELECT 1` | 2 s |
| SMTP | DNS lookup of `EMAIL_HOST`, then TCP connect to `EMAIL_HOST:EMAIL_PORT` (no login) | 3 s |
| Internet (general) | TCP connect to a well-known host:443, configurable | 3 s |
| Remote overlay (optional) | `tailscale status --json` or WireGuard handshake age | n/a |

**Storage:** each probe's result goes in a small `SystemStatus` table (one row per probe: `ok`, `checked_at`, `last_ok_at`, `last_change_at`, `detail` without secrets). A state change writes an `ActivityLog`-style audit entry and, when coming back online, wakes the outbox dispatcher.

**Use:** the monitor is advisory. The outbox still treats each real send failure as authoritative, because a probe can pass while delivery fails.

### 4.2 What users see

- **A server-reported status badge** replaces the `navigator.onLine` footer. Sample text: "Local server: OK · Internet: offline since 09:42 · 3 emails waiting".
- **Online-only actions show a clear message instead of a spinner**, for example: "Email can't be sent right now. The message is queued and will go out automatically when the internet is back. You can also give the person this activation code in person."
- **The self-service password reset page shows when the internet is down:** "Password reset by email is unavailable while the campus is offline. Ask a Lab Administrator for a one-time reset code."
- **Health endpoints:**
  - `/healthz` is a public liveness check returning only `ok`;
  - `/healthz/ready` is restricted to localhost or Admins and reports database, worker heartbeat and probe states, for the installer, the client launcher and monitoring.

---

## 5. Background processing redesign

**Today:** daemon threads inside the web process, exceptions swallowed silently, an in-memory sleep for override grants, and a reminder window that is missed if the server is down.

**Proposed:** a separate Windows service, `CompuLab Worker`, running `manage.py run_worker`. The web service runs with `COMPULAB_BACKGROUND_TASKS=False`.

| Responsibility | Change |
|---|---|
| PC status / stale release / after-hours lock | Same logic. Exceptions logged. Notification email goes through the outbox (no network wait in the loop) |
| Reminders | Query "sessions starting within N minutes **and not yet reminded**". If the worker was down during the window but the session hasn't started, send late rather than never |
| Override grant | `ScheduledJob` row (`run_at`, `kind='override_grant'`, payload, `status`, `attempts`, `locked_until`). Survives restarts; runs once (status transition inside a transaction) |
| Email outbox dispatch | See [OFFLINE_ACCOUNT_VERIFICATION.md §6](OFFLINE_ACCOUNT_VERIFICATION.md#6-email-outbox-durable-queue) |
| Activity-log retention | Same, but configurable through `.env` |
| Connectivity monitor | §4 |
| Heartbeat | Worker writes `worker_heartbeat_at` every loop; the web UI warns Admins if it is older than 2 minutes |

**No new infrastructure** (no Redis or Celery): the database is the queue, which suits a single Windows server. A small library such as `django-q2` could replace the hand-written loop if preferred (decision).

**Duplicate protection:**
- only one worker service is installed;
- jobs are claimed with `UPDATE … WHERE status='pending' AND id=…`, using `select_for_update(skip_locked=True)` on MariaDB ≥ 10.6, so a second worker cannot run the same job.

---

## 6. Integrity rules for deferred and concurrent work

1. **Transactions.** Wrap check-in, override, manual unlock, approval and roster generation in `transaction.atomic()`. Lock the `PC` row, and the `Session` row for cap checks, with `select_for_update()`. Send the network signal to the agent *outside* the transaction. Commit the "in use" state only after the agent acknowledges it, or record it as "pending unlock" and reconcile.
2. **Idempotency.**
   - Outbox entries carry a `dedupe_key`, for example `verify:{user_id}:{sent_at}` or `reservation_code:{session_id}:{user_id}`; a unique constraint prevents double-queuing.
   - Agent callbacks (`end-session`, `logout`) carry an agent-generated `event_id`; the server ignores repeats.
   - The agent keeps unsent callbacks in a small local file and retries them, instead of the current best-effort single attempt.
3. **Double-submit protection** on high-impact forms (approve, import, override): a one-time form token or a status precondition (`UPDATE … WHERE status='pending'`) so a second click is a no-op.
4. **Never mark something done before it is done.** For example, `email_verification_sent_at` should mean "queued at" plus a separate "delivered to SMTP at", rather than being rolled back on failure as today.

---

## 7. Synchronization specification (Deliverable 7)

### 7.1 Default: no synchronization

With the recommended architecture there is nothing to synchronize. **Do not build this until a concrete need is approved** (see the decision list). The existing `cloud_sync` app should stop enqueuing in the meantime (audit M10).

### 7.2 If a hosted read-only view is wanted: one-way publishing

**Direction:** on-prem → hosted only. The hosted side never edits published entities. Requests that originate online (for example a future "request a reservation from home" form) travel as **commands** that the on-prem server pulls, validates and accepts or rejects. They never arrive as row merges.

**What may be published** (minimum necessary; subject to the college's data-privacy rules under the Philippine Data Privacy Act, RA 10173):

| Publish | Do **not** publish |
|---|---|
| Labs (name, hours) | User accounts, password hashes, emails, ID numbers |
| PC counts by status per lab (aggregates) | Reservation codes |
| Upcoming sessions without codes or student data | `PCActivityLog` (window titles, URLs) |
| Open issue counts | Agent secrets or tokens, PC IP addresses |

**Stable identifiers.** Add `public_id = UUIDField(unique=True, default=uuid4, editable=False)` to each published model. Backfill existing rows with a data migration (additive and reversible). Payloads and the mirror use `public_id`, never integer primary keys.

**Change capture** (transactional outbox, extending the existing `SyncQueue`):

| Field | Purpose |
|---|---|
| `entity_type`, `entity_public_id` | What changed |
| `op` | `upsert` or `delete` (tombstone) |
| `entity_version` | Monotonic integer per entity, incremented on each change |
| `payload` | Snapshot at commit time |
| `schema_version` | Lets the receiver refuse payloads it does not understand |
| `status`, `attempts`, `next_attempt_at`, `last_error` | Delivery state |
| `created_at`, `acked_at` | Audit |

The queue row is written **in the same database transaction** as the change, so a committed change is never missed. Multiple pending changes to one entity are coalesced: only the latest version is sent.

**Transport:**
- the on-prem server initiates outbound HTTPS only (no inbound port);
- authentication is a bearer token, plus an HMAC of the body with a timestamp, rejected if more than 5 minutes off;
- batches of at most 100 items.

**Receiver rules (idempotent):**
- upsert by (`entity_type`, `public_id`) only if the incoming `entity_version` is greater than the stored one; an older or equal version is acknowledged and ignored;
- tombstones delete or hide;
- the response lists acknowledged ids;
- an unknown `schema_version` gets a 409 response for that item.

**Delivery states**

```
pending ──send──► sending ──2xx ack──► acked
   ▲                 │
   │            network error / 5xx
   └──backoff────────┘  (1 min, 2, 4 … capped at 1 h)
                     │
                409 / 400 / attempts > 20
                     ▼
                   dead ──► Admin review screen (retry / discard / full resync)
```

**Failure handling:**

| Failure | Handling |
|---|---|
| Internet down | Items stay `pending`; nothing blocks local work |
| Partial batch | Only acknowledged ids are marked |
| Receiver data loss | Admin runs `manage.py sync_full_resync`, which re-enqueues the current state of every published entity (safe because of versions) |
| On-prem restore from backup | The versions go backwards. Run a full resync with a new `epoch` value; the receiver accepts a higher epoch as authoritative |
| Schema migration on-prem | Bump `schema_version`; deploy the receiver first |

**Conflict resolution:** not needed by construction (single writer). Inbound commands from the hosted side are processed on-prem with the same validation as local requests (`_slot_error`, permissions) and acknowledged with accept or reject. Duplicate commands are recognized by their `command_id` (UUID).

**Audit:** every dead item, resync and command decision is written to the audit log.

### 7.3 Synchronization test plan (only if 7.2 is approved)

1. Unit: each published model change creates exactly one queue row inside the same transaction (rolled-back changes create none).
2. Coalescing: 5 edits before a send → one item with the latest version.
3. Idempotency: send the same batch twice → the receiver state is identical; the second response acknowledges everything.
4. Ordering: deliver version 3 before version 2 → the receiver keeps version 3.
5. Offline: block outbound traffic for 24 h, make 500 changes, restore → all acknowledged; no duplicates; no local slowdown.
6. Receiver 500 errors, timeouts and truncated responses → retried with backoff; nothing marked acknowledged wrongly.
7. Schema mismatch → `dead` with a readable reason; the Admin screen shows it.
8. Restore the on-prem database from an older backup, then resync → the mirror converges to the restored state.
9. Security: wrong token, stale timestamp or a modified body → rejected.

### 7.4 Questions to answer before any sync work

- Who would use a hosted view, and for what (public lab availability? management dashboards?)
- Is any **write** from outside the campus required (online reservation requests)? If yes, it must be designed as commands.
- What data may legally and ethically leave the campus server?

---

## 8. Target system map (recommended)

```
                        Internet
   ┌───────────────────────────────────────────────────────────────┐
   │  College SMTP mailbox        Tailscale coordination (control)  │
   │  (optional) hosted status page ◄── one-way HTTPS publish ──┐   │
   └────────▲───────────────────────────────▲───────────────────┼───┘
            │ SMTP from the outbox          │ WireGuard tunnel  │
            │ (when online)                 │ (encrypted)       │
 ┌──────────┼───────────── Campus LAN ──────┼───────────────────┼───────┐
 │          │                               │                   │       │
 │   ┌──────┴───────────────────────────────┴───────────────────┴──┐    │
 │   │ CompuLab Server (Windows, static IP / DHCP reservation, UPS)│    │
 │   │  • CompuLab Web     (waitress, :8000, Windows service)      │    │
 │   │  • CompuLab Worker  (PC checker, outbox, jobs, monitor)     │    │
 │   │  • MariaDB 10.11/11.4 LTS (localhost only)                  │    │
 │   │  • Backup task → external disk / NAS (+ offsite when online)│    │
 │   │  • Tailscale (remote staff only)                            │    │
 │   └──────▲──────────────────────────────────▲───────────────────┘    │
 │          │ HTTP/HTTPS :8000                 │ agent API (per-PC token)│
 │   Staff PCs / laptops                 Lab PCs: CompuLab Agent service│
 │   (browser or launcher)               (lock screen, :5555 from server│
 │                                        only via Windows Firewall)    │
 └──────────────────────────────────────────────────────────────────────┘
   Remote staff ── Tailscale client ── tunnel ── CompuLab Server :8000
```

Installers and network details: [LAN_AND_REMOTE_ACCESS.md](LAN_AND_REMOTE_ACCESS.md). Phasing: [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md).
