# Cloud <-> edge reservation workflow

This update adds reservation management from either location. Cloud users submit a change; the edge validates and commits it; the result and latest reservation snapshot return to the cloud. Edge-originated changes continue to publish through the existing record-sync queue. PC remote commands are still supported.

Supported cloud actions: **Create, Update, Approve, Cancel**. Create produces a normal pending `SessionRequest`; Approve creates its official `Session` and reservation code on the edge. Update supports pending requests and their approved sessions. Cancellation preserves the request with cancelled status and removes its future session.

This manages reservations represented by `SessionRequest` and its linked `Session`. Accounts, labs, inventory, and roster definitions are not merged between databases. Roster-generated sessions without a request remain managed locally.

## Update your existing local demo

1. In the running demo terminal, press **Ctrl+C**.
2. Extract `DTC-Smart-Computer-Lab-bidirectional.zip` into a new folder.
3. Open a terminal in the extracted `DTC-Smart-Computer-Lab` folder (the folder containing `manage.py`).
4. Prepare the same Python 3.13 environment, or use your existing compatible interpreter:

```powershell
py -3.13 -m venv .venv-demo
.\.venv-demo\Scripts\python.exe -m pip install -r tools\requirements-local-demo.txt
.\.venv-demo\Scripts\python.exe tools\local_remote_demo.py
```

The launcher automatically migrates both demo databases, creates the approved demo admin, enables the reservation workflow and record sync on the appropriate side, and registers a local student with ID `DEMO-STUDENT`. It prints the lab ID and login password. No MySQL server or manual `.env` setup is needed for this demo.

You can also update an existing extracted source folder after stopping the demo: back it up, replace application source with the updated source, and **keep `.local_remote_demo` and your virtual environment**. The launcher migrates existing demo databases. Pending commands from the preceding demo run are expired when starting a new run; do not use the demo launcher as a production installer.

## Test cloud -> edge

Open the cloud reservation changes page:

http://127.0.0.1:8001/admin/cloud_receiver/reservationchange/

Login with `localdemo@gmail.com` and the current password printed in the terminal.

Click **Add reservation change**, then use:

| Field | Value |
|---|---|
| Site id | `local-demo` |
| Action | `Create` |
| Reservation to change | Leave empty |
| Campus lab database ID | Lab ID printed in the terminal (normally `1`) |
| Requester type | Student |
| Requester name | Demo Student |
| Requester id number | `DEMO-STUDENT` |
| Subject | Example: Programming test |
| Date | A future date |
| Start time | `09:00` |
| End time | `10:00` |
| Student count | `1` |
| Pcs requested | Empty or `0` for Student; positive count for Walk-in |
| Expires at | Keep the default, 24 hours from creation |

Save, wait a few seconds and refresh. The **change request** status should become `applied`. Its result contains a snapshot whose **reservation** status is `pending`. These are different states: the request was successfully created, but it has not yet been approved into the official schedule.

Open the edge database's reservation requests:

http://127.0.0.1:8000/admin/scheduling/sessionrequest/

The new request should be there. On the cloud, its mirrored snapshot is under **Cloud receiver -> Replica records**. If it is not there yet, wait for the next sync cycle and refresh; inspect `.local_remote_demo/worker.log` for errors.

## Approve, edit or cancel from cloud

Create another **Reservation change**:

- Keep Site id `local-demo`.
- Choose action **Approve**, **Update**, or **Cancel**.
- Select the reservation under **Reservation to change**. Labels show campus, numeric reservation ID, subject, date, and status.
- For Update, fill only the fields you want to change. Empty fields retain their current value; **Clear existing notes** explicitly removes notes.
- For Approve/Cancel, leave edit fields empty.
- Save and refresh for the result.

After Approve: the edge request is approved and a session appears under the edge's official sessions. Reservation codes are generated and retained on the edge; the cloud snapshots continue to exclude those codes. The existing local notification/email flow is used.

After Cancel: the request becomes cancelled on both sides; its future session is removed on the edge. Started/past reservations cannot be edited or cancelled through this workflow, preserving their attendance history.

If you receive `conflict`, wait for the latest replica, inspect the local changes and submit a **new** change request. Saved change requests are immutable and cannot be retried as a way to overwrite newer data.

## Test edge -> cloud

For a straightforward demo, edit a pending request on the **edge** admin:

http://127.0.0.1:8000/admin/scheduling/sessionrequest/

Change its subject and Save. Then refresh its cloud **Replica record**; its subject and revision should update through the normal sync path. For ordinary lab operations, keep using the edge's existing scheduling pages, which apply the business rules. Direct Django admin edits are intended for administrators and do not provide the scheduling forms' complete validation.

To test an edit conflict: open/submit a cloud update based on an older copy while the edge has already changed it. The edge will report `conflict` and keep its newer data. The internal revision comparison is automatic; there is no revision value to type into the form.

In cloud reservation mode, direct POSTs to the cloud's normal `/schedule/` and `/admin/scheduling/` routes are refused, preventing independent cloud-only bookings. Use **Reservation changes** instead. Replica reservation records are read-only in the cloud admin.

## Real deployment configuration

Deploy the updated code to **both** servers and run in each environment:

```powershell
python manage.py migrate
python manage.py check
```

New migration: `cloud_receiver/0003_reservationchange_reservationreceipt.py` (both sides need it).

Cloud `.env` additions, alongside the existing receiver/key configuration:

```dotenv
CLOUD_RECEIVER_ENABLED=True
CLOUD_RESERVATIONS_ENABLED=True
EDGE_CLOUD_RESERVATIONS_ENABLED=False
```

Edge `.env`, alongside the existing HTTPS cloud URL, matching key, and site ID:

```dotenv
CLOUD_RESERVATIONS_ENABLED=False
EDGE_CLOUD_RESERVATIONS_ENABLED=True
CLOUD_RESERVATION_EDGE_ACTOR_EMAIL=your-existing-local-admin@gmail.com
CLOUD_SYNC_OBJECT_TYPES=reservation,session,issue
COMPULAB_BACKGROUND_TASKS=False
```

`CLOUD_RESERVATION_EDGE_ACTOR_EMAIL` must resolve to an active local admin that passes the application's account approval/verification rules. It is the local audit/authorization account; the original cloud requester's email is also preserved in the cloud change and edge receipt. Cloud users allowed to submit changes are active staff admins or superusers; in-charge/instructor accounts are not granted cross-campus management here.

Restart the cloud web process and the edge web/worker services. Run one supervised edge worker (`python manage.py run_worker`). Backfill pre-existing reservation snapshots so they receive revisions:

```powershell
python manage.py cloud_sync_backfill --yes
```

For standalone testing, the launcher enables these settings automatically. Production remote servers still need HTTPS. The HTTP exception remains loopback-only and opt-in.

## Offline operation and delivery rules

- Cloud can keep accepting intents while the edge is disconnected. They stay pending; do not treat that as an approved booking.
- Default intent expiry is 24 hours (cloud form allows at most seven days). After reconnection the edge rechecks the actual date, account, capacity, overlap, lab hours, state and revision.
- Two approvals targeting overlapping exclusive bookings cannot both pass the same edge scheduling checks. Local scheduling writes and cloud intents share a transaction/lock on lab rows in a deterministic order.
- A request ID is processed once: the edge reservation update, receipt and outgoing reservation snapshot are in one database transaction. A lost cloud reply can be retried without issuing another booking/code or duplicate notifications.
- A stale edit/approval/cancellation returns `conflict`; it does not silently replace a local change.
- Local and cloud workers must use their own database and matching `site_id`/API key. Do not point both installations at the same database.
- Database bulk updates that bypass Django signals still require the existing `cloud_sync_backfill` maintenance command. Preserve edge receipt tables across ordinary restarts/upgrades to retain duplicate protection.

The existing schema-1 reservation snapshot gains an additive `revision` field; the bundled receiver accepts it. Update both installations before enabling changes. Old snapshots without a revision can still be viewed but cannot be selected for an edit until backfilled.

## Verification

See the accompanying verification summary for the test counts. Regression tests exercise validation, permissions/CSRF, both direction workflows, stale revisions, approval conflicts, expiry, outage retries, rollback and duplicate protection. A separate verification uses two actual SQLite databases with JSON transport simulated between processes. The coding environment blocks local socket connections, so live HTTP and the actual school network still need a test on your laptop. No real PC was restarted, locked or shut down during automated verification.
