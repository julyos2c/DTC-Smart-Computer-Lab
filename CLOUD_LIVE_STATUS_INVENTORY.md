# CompuLab Cloud monitoring and PC/equipment management

This builds on **CompuLab_No_Available_PCs_FULL**, retaining the capacity-based
partial reservation allocation and the zero-availability rejection behavior.

## What is implemented

| Feature | What it does | Authority |
|---|---|---|
| Cloud PC monitoring | Displays each Edge PC's reported state, lab, PC ID, latest observed/received times and agent version; refreshes browser every 10 seconds | PC Agent → Edge → Cloud |
| Offline/stale detection | Status says `stale` after 90 s without a recent Edge sync **or** PC observation. Does not falsely assert a PC is online | Cloud display-only |
| PC snapshot refresh | Edge worker republishes all PCs every 30 seconds by default, including changes saved with `QuerySet.update()` | Edge |
| PC inventory | Cloud can request create/change/delete of PC registration (lab, ID, LAN IP) | Edge validates |
| Equipment inventory | Cloud can request create/change/delete of equipment items, counts, condition, repair and retirement status | Edge validates |
| Related records | Lab names/hours, equipment maintenance logs and equipment issue records are replicated read-only | Edge |
| Outages | Local Edge operations continue; Cloud edits stay pending until Edge polls, or expire | Edge |
| Security | HTTPS API key, site identity, cloud admin permissions, verified local Edge audit account, revisions and idempotent receipts | Both |

This is **near-real-time polling**, not a direct Cloud LAN probe or WebSocket.
Data arrives after Edge polls/syncs. A disconnected PC or server is **never
shown as reliably live** from an old Cloud record. PC agent secrets,
reservation unlock codes, and student/guest identities are not included in
PC status snapshots.

## Cloud URLs

- `/cloud/monitor/` — Cloud monitor dashboard; only authenticated Cloud staff admins.
- `/cloud/api/pc-status/` — read-only filtered JSON, same access controls.
- `/admin/cloud_receiver/inventorychange/add/` — create an inventory or PC management request.
- `/admin/cloud_receiver/inventorychange/` — see request status and Edge result.
- `/admin/cloud_receiver/replicarecord/` — view read-only Cloud copies.

A Cloud admin creating a request must select **Equipment inventory** or
**PC registration**, then **Create**, **Update**, or **Delete**. Update/delete
must select a current synced replica; stale revisions are rejected so the
admin can refresh and retry. For PCs, *agent-reported availability/status
cannot be edited* through Cloud asset commands. Deleting a PC with an active
session or activity/check-in history is refused to protect audit data.

## Install both ends

1. Back up the running project, database, and `.env` on **both** servers.
2. Deploy this updated source on Edge **and** Cloud. Do not copy a live database
   or private `.env` from one server to the other.
3. In each install, activate its existing virtual environment and run:

   ```powershell
   python manage.py migrate
   python manage.py check
   ```

4. Configure an HTTPS Cloud hostname and a shared random key. On the Cloud:

   ```dotenv
   CLOUD_RECEIVER_ENABLED=True
   CLOUD_RECEIVER_SITES=dtc-main:<64-character-sha256-api-key-hash>
   CLOUD_INVENTORY_ENABLED=True
   ```

   To obtain a fresh key and Cloud digest run on a trusted host:

   ```powershell
   python manage.py cloud_receiver_key --site dtc-main
   ```

   Store the **raw API key only on Edge**. The Cloud stores only its hash.
   Preserve any existing enabled Cloud reservation/remote-control settings.

5. On **Edge**:

   ```dotenv
   CLOUD_SERVER_URL=https://your-cloud-domain.example
   CLOUD_SYNC_SITE_ID=dtc-main
   CLOUD_SYNC_API_KEY=<raw-key-from-step-4>
   CLOUD_SYNC_OBJECT_TYPES=reservation,session,issue,lab,pc,inventory,maintenance_log,equipment_issue
   CLOUD_PC_REFRESH_SECONDS=30
   EDGE_CLOUD_INVENTORY_ENABLED=True
   CLOUD_INVENTORY_EDGE_ACTOR_EMAIL=admin@your-college.example
   ```

   **Important:** `CLOUD_INVENTORY_EDGE_ACTOR_EMAIL` must match a local,
   active, approved, email-verified user with the `admin` role. Edge will
   reject all Cloud inventory/PC changes if it is missing/unverified.
   Keep `CLOUD_SYNC_SITE_ID` consistent with the Cloud receiver's site ID.
   If you also sync `activity_log` or `notification`, that is an additional
   opt-in privacy decision; these are excluded from the sample above.

6. Restart both web servers **and** the Edge background worker. Do not
   start a second redundant worker when the in-process worker is already
   enabled. The worker runs `cloud_sync.live_status.run_once`, then pushes
   queued records and polls Cloud inventory requests every tick.
7. On the **Edge** run the initial backfill once after enabling sync:

   ```powershell
   python manage.py cloud_sync_backfill
   python manage.py cloud_sync_backfill --yes
   ```

8. Sign into the Cloud as an authorized admin and open `/cloud/monitor/`.
   Confirm your lab, PC statuses and inventory. Submit one test inventory
   edit, verify `applied` in the Cloud inventory-change list, and confirm
   it in the local Edge UI. If not applied, check worker logs and command
   `result` field.

## Synchronization specifics and limits

- PC availability is from `PC.status`, but a PC reading is marked stale if
  `last_seen_at` or `applied_at` is more than 90 seconds old. A Cloud server
  cannot independently probe PC Agents behind the campus LAN.
- Equipment changes are queued on saves/deletes. Changes performed via
  raw SQL, `QuerySet.update()`, or restored backups need
  `cloud_sync_backfill --yes`; PC statuses receive a periodic refresh even
  when bulk updates bypass model signals.
- Cloud management is **asynchronous**, not direct database replication.
  Requests are durable and idempotent, but can expire; the Edge is the
  single authority for validation and actual changes.
- Other modules (e.g. roster membership, student identities, attendance,
  and account credentials) are **not enabled for full Cloud mirroring** by
  this change. This avoids uploading unnecessary personally identifiable
  student data without a college privacy policy. Existing reservation,
  session, issue, optional activity logs and notification mechanisms remain.
- Inventory records are edited through typed Cloud *commands*, **not**
  by editing the JSON of `ReplicaRecord`. The latter is blocked for
  Edge-managed record types.
- Browser polling is 10 seconds, Edge status refresh is 30 seconds by
  default, and delivery may take longer if sync is backlogged or offline.
- MySQL production deploy, multiple-worker race behavior and real Windows
  PC Agent connectivity have not been physically tested in this environment.

## Test results

- Targeted Cloud and PC/equipment tests: **12/12 passed**.
- Cloud and cloud-sync suite: **85/85 passed** before final PC CRUD addition;
  subsequent full test suite: **215/216 passed**.
- The one remaining failing test (`labs.test_agent_auth.SystemStatusSecretSummaryTests`
  `test_status_page_shows_secret_migration`) also fails in the original
  CompuLab build, before this change. This update did not alter that page.
- `python manage.py check`: no issues.
- `makemigrations --check --dry-run`: no unrecorded model changes.
