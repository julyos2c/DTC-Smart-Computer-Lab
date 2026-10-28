# CompuLab cloud sync — protocol and rules (version 2)

CompuLab's campus server can publish selected records to a **cloud receiver**: a separate web
service run by the college, e.g. for a read-only copy reachable from outside the campus.
This repository contains **both sides**: the sender (`cloud_sync/`) and a receiver
(`cloud_receiver/`, off unless `CLOUD_RECEIVER_ENABLED=True`; then `/api/ping/` and `/api/sync/`
answer). The two are tested together (`cloud_receiver/tests.py`: offline queueing, resume,
lost replies, duplicates, conflicts, pauses), but **no receiver is deployed anywhere yet**, so on a
campus server sync stays off (nothing is queued) and System status says *"cloud synchronization
not configured"*. Local operation never depends on it. The college's public CompuLab website is a
separate installation with its own data: nothing is synchronized with it.

This document is the contract a receiver must implement (`cloud_receiver/` implements it).

**Turning it on (both sides, when approved):** on the cloud server, `python manage.py
cloud_receiver_key --site dtc-main` prints the `.env` lines for both servers (the cloud keeps only
the key's SHA-256: `CLOUD_RECEIVER_SITES=dtc-main:<sha256>`, `CLOUD_RECEIVER_ENABLED=True`, and runs
the `cloud_receiver` migration); the campus server gets `CLOUD_SERVER_URL` (HTTPS),
`CLOUD_SYNC_SITE_ID` and `CLOUD_SYNC_API_KEY`, then `cloud_sync_backfill --yes` once.

## 1. Direction and authority

- **Replicas are one-way: campus → cloud.** The campus server remains the only place where authoritative records are changed. Cloud admin actions for reservations, PC registration and inventory are separate authenticated **intents** that the Edge polls, validates and applies.
- Consequently there is no "merge": see the conflict policy in §6.

## 2. Configuration (campus side, `.env`)

| Setting | Meaning |
|---|---|
| `CLOUD_SERVER_URL` | Base URL of the receiver, e.g. `https://compulab-cloud.example.edu`. Blank = off. |
| `CLOUD_SYNC_API_KEY` | Shared secret, sent as `Authorization: Bearer <key>`. Blank = off. Never logged or shown. |
| `CLOUD_SYNC_SITE_ID` | Stable name of this campus server (default `dtc-main`). Never change it after the first sync. |
| `CLOUD_SYNC_OBJECT_TYPES` | Record types published: `reservation`, `session`, `issue`, `activity_log`, `notification`, `lab`, `pc`, `inventory`, `maintenance_log`, `equipment_issue` (default: reservation, session, issue and the five lab/inventory types). |
| `CLOUD_SYNC_TIMEOUT_SECONDS` | Per-request timeout (default 5). |

After enabling: restart both CompuLab services, then run `python manage.py cloud_sync_backfill --yes`
once to queue the records that existed before.

## 3. Endpoints the receiver must provide

### `GET {base}/api/ping/`
Returns any 2xx when the receiver is up. Used by the connectivity monitor every minute.
404/405/410 means "no receiver here" (wrong URL).

### `POST {base}/api/sync/`
Headers: `Authorization: Bearer <key>`, `Content-Type: application/json`,
`X-CompuLab-Site: <site_id>`, `X-CompuLab-Sync-Protocol: 2`.

Request body:

```json
{
  "protocol": 2,
  "site_id": "dtc-main",
  "sent_at": "2026-10-22T09:15:02+08:00",
  "records": [
    {
      "edge_id": "6f0c2e0e-...-uuid",
      "object_type": "session",
      "local_id": 42,
      "record_key": "session:42",
      "operation": "upsert",
      "schema_version": 1,
      "sequence": 1187,
      "force": false,
      "payload": { "...": "full snapshot, see sync_payloads.py" },
      "created_at": "2026-10-22T01:14:58.120000+00:00"
    }
  ]
}
```

Response (2xx, JSON):

```json
{
  "results": {
    "6f0c2e0e-...": {"status": "accepted"},
    "9a1b...":      {"status": "duplicate"},
    "c3d4...":      {"status": "conflict", "detail": "edited on the cloud at 09:01", "cloud_updated_at": "..."},
    "e5f6...":      {"status": "rejected", "detail": "payload.date is not a date"},
    "a7b8...":      {"status": "retry", "detail": "database busy"}
  },
  "accepted_edge_ids": ["6f0c2e0e-...", "9a1b..."]
}
```

`accepted_edge_ids` alone (the version 1 format) is also understood: listed ids count as accepted,
unlisted ones are retried.

## 4. Identifiers and versions

| Field | Meaning | Receiver rule |
|---|---|---|
| `(site_id, object_type, local_id)` | The record's **stable identity**. Local ids never change on the campus server. | Use as the unique key of the cloud copy. |
| `edge_id` | Unique id of **one change**: the idempotency key. | Store processed edge_ids. A repeat must answer `duplicate` and change nothing. |
| `sequence` | Increases with every queued change on this campus server. | Keep the highest sequence applied per record; answer `duplicate` for anything lower or equal (a late or repeated delivery). |
| `schema_version` | Layout version of `payload` for this object type (`SCHEMA_VERSIONS` in `sync_payloads.py`). | Reject (`rejected`) versions it does not understand, instead of guessing. |
| `operation` | `upsert` (payload is the full current record) or `delete` (payload is `{"deleted": true}`). | Upsert replaces the whole cloud copy; delete removes or tombstones it. |

Payloads are **complete snapshots**, never partial changes, so applying the newest one is always
enough. Payloads never include reservation codes, passwords or the lab PC agent secret.
References to other records (e.g. `roster_id`, `lab.local_id`) may point to records the receiver
has not received yet; the receiver must accept them as plain values, not enforced foreign keys.

## 5. Delivery guarantees (sending side)

- Changes are written to the `SyncQueue` table **after** the local transaction commits; a change
  that is rolled back is never published. Bulk `QuerySet.update()` calls send no signal: run
  `cloud_sync_backfill` after such maintenance.
- Rows survive internet outages and restarts. A row left `processing` by a crash returns to
  `pending` after 10 minutes.
- Only one process sends at a time (a lease on `SyncState`), oldest change first.
- If a record changed several times before it could be sent, only the newest snapshot is sent;
  the older rows are marked `superseded`.
- At-least-once delivery: a lost reply means the same `edge_id` is sent again. The receiver's
  duplicate rule makes this safe (effectively exactly-once application).

## 6. Error handling and conflict policy

| Receiver answer | What the campus server does |
|---|---|
| Network error, timeout, HTTP 429 or 5xx | Pauses the whole queue with backoff (30 s, doubling to 30 min). Rows are **not** charged an attempt. Resumes at once when the connectivity monitor sees the internet or the receiver come back. |
| HTTP 401/403 | **Paused** ("the cloud server refused the API key") until `.env` changes or an Admin presses *Retry now*. Not retried forever. |
| HTTP 404/405/410 | **Paused** ("no compatible sync receiver") until `.env` changes or *Retry now*. |
| HTTP 413 | Batch size halved, then retried. |
| HTTP 400/422/409 for a batch | Re-sent one record at a time to find the bad one; that record becomes `failed`. |
| `accepted` / `duplicate` | Row `synced`; *last successful sync* updated. |
| `retry` (or not mentioned) | Row retried with its own backoff; `failed` after 20 such answers. |
| `rejected` | Row `failed` (shown to Admins with the receiver's `detail`). |
| `conflict` | Row `conflict`, waits for an Admin. |

**Conflicts.** The cloud copy must never be edited directly. If it was (e.g. someone fixed a typo
on the cloud side), the receiver answers `conflict` instead of silently overwriting. An Admin
then chooses, on *System status → Cloud sync*:

- **Keep campus copy**: the row is sent again with `"force": true`; the receiver must then
  overwrite its copy.
- **Keep cloud copy**: the row is marked `resolved` and not sent. The next local change to the
  same record is sent normally (and may conflict again if the cloud copy is still edited).

Nothing on the campus server is ever overwritten by the cloud. Every decision is logged with the
Admin's name (`cloud_sync` logger) and kept on the row (`resolved_by`, `resolved_at`).

Failed rows are never deleted automatically; *Retry* / *Retry all failed* send them again.
Synced, superseded and resolved rows are deleted after 30 days (`manage.py prune_sync_queue`
can do it on demand).

## 7. Admin visibility

- **System status**: cloud receiver reachability, last successful sync, waiting / failed /
  conflict counts, pause reason, and the header line (e.g. *"Local system operational; cloud
  server unreachable. Changes wait and are sent automatically."*).
- **System status → Cloud sync** (`/system/cloud-sync/`): the queue itself, with Retry and
  conflict decisions.
- `/healthz/ready` (from the server itself, or for Admins): the same numbers as JSON.

## 8. Building a receiver (checklist; `cloud_receiver/receiver.py` follows it)

The included receiver stores one `ReplicaRecord` per `(site_id, object_type, local_id)` (a delete
keeps a tombstone) and one `AppliedChange` per applied `edge_id`. Conflicting or rejected changes are
not recorded as applied, so the campus server can send the same change again (forced after an Admin's
"Keep campus copy"). Editing a replica in the Django admin marks it as edited on the cloud: the next
campus change to it is answered `conflict`. Plain HTTP is refused (`CLOUD_RECEIVER_ALLOW_HTTP` only
for tests or a TLS proxy that does not set X-Forwarded-Proto).

1. HTTPS only; compare the bearer key in constant time; reject unknown `site_id`.
2. Tables: one per object type keyed by `(site_id, local_id)`, plus processed `edge_id`s and the
   last applied `sequence` per record.
3. In one transaction per record: duplicate check → schema_version check → conflict check (cloud
   copy edited since `last_applied_sequence`?) unless `force` → apply → store edge_id and sequence.
4. Answer per record as in §3. Never answer 2xx for a record that was not stored.

## Remote PC commands

Optional cloud-to-edge control is now separate from record replication. See
`docs/CLOUD_REMOTE_CONTROL.md` for migration, opt-in settings, the cloud Django
admin command form, expiry, result states, and at-most-once dispatch limits.

## Reservation changes in both directions
Cloud admins may now queue reservation intents through /api/reservation-changes/. The edge applies them under local validation and publishes confirmed snapshots with revisions. See docs/BIDIRECTIONAL_RESERVATIONS.md. This is separate from PC commands and preserves single-writer record replication.
