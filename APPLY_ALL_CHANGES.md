# Apply all project changes

This update contains only files added or changed since your original DTC-Smart-Computer-Lab.zip. Paths in the ZIP are relative to the project folder containing manage.py.

Included: cloud remote PC commands, cloud reservation create/update/approve/cancel validated by the edge, edge-to-cloud snapshot updates with revision conflict protection, duplicate receipts and durable outbox, scheduling write locks, cloud admin controls, cleaner Cloud sync page, and the PC-delete popup text fix. Local demo tools/settings are optional. Email verification itself was not changed; the login issue was diagnosed as using an email absent from the demo database.

## Apply

1. Back up your actual application folder and database.
2. Stop the existing Django web server and worker.
3. Extract this ZIP into the actual project folder where manage.py is located. Replace matching source files. Keep your real .env, database, uploads, and existing virtual environment: none are included in the ZIP. Apply the production source update to both the cloud and edge installations.
4. Configure the settings below in the existing .env files. Do not replace your .env with .env.example.
5. In both project environments run:

```powershell
python manage.py migrate
python manage.py check
```

6. Restart both web servers and the edge worker. Use one supervised edge worker running `python manage.py run_worker`. When it runs separately, use `COMPULAB_BACKGROUND_TASKS=False` in the web installation.
7. On the configured edge run `python manage.py cloud_sync_backfill --yes` to publish existing reservations with revisions.
8. Browser: Ctrl+F5, close old popups and reopen them.

New migrations (both installations):
- cloud_receiver/0002_commandreceipt_remotecommand.py
- cloud_receiver/0003_reservationchange_reservationreceipt.py

## Production .env configuration

Generate a matching site key/digest with `python manage.py cloud_receiver_key --site dtc-main` if you do not already have one. Use the raw key only on the edge, and its generated SHA-256 digest on the cloud. Retain existing site IDs/keys if already configured.

Cloud:

```dotenv
CLOUD_RECEIVER_ENABLED=True
CLOUD_RECEIVER_SITES=dtc-main:<generated SHA-256 digest>
CLOUD_REMOTE_CONTROL_ENABLED=True
CLOUD_RESERVATIONS_ENABLED=True
EDGE_REMOTE_CONTROL_ENABLED=False
EDGE_CLOUD_RESERVATIONS_ENABLED=False
```

Edge:

```dotenv
CLOUD_RECEIVER_ENABLED=False
CLOUD_SERVER_URL=https://your-actual-cloud-domain
CLOUD_SYNC_SITE_ID=dtc-main
CLOUD_SYNC_API_KEY=<matching raw API key>
CLOUD_SYNC_OBJECT_TYPES=reservation,session,issue
CLOUD_REMOTE_CONTROL_ENABLED=False
CLOUD_RESERVATIONS_ENABLED=False
EDGE_REMOTE_CONTROL_ENABLED=True
EDGE_CLOUD_RESERVATIONS_ENABLED=True
CLOUD_RESERVATION_EDGE_ACTOR_EMAIL=<existing active approved local admin email>
EDGE_REMOTE_CONTROL_ALLOW_LOCAL_HTTP=False
COMPULAB_BACKGROUND_TASKS=False
```

Replace placeholders with real configuration. Real cloud URLs require HTTPS; 127.0.0.1:8001 is for the single-machine demo only. Preserve your deployment's current DB, SMTP, agent-secret, and security settings.

## Screens

Cloud `/admin/`:
- Remote commands: lock, unlock, shutdown, restart.
- Reservation changes: create, update, approve, cancel.
- Replica records: confirmed campus snapshots.

Edge: continue using the existing lab and scheduling pages. Approved reservations use their linked official Session for subject/schedule data. In cloud reservation mode, direct cloud schedule writes are blocked; submit Reservation changes instead.

Only reservations/linked sessions have the new cloud change workflow. This is not unrestricted two-way merging of every database table. Accounts, inventory and roster definitions are not synchronized in both directions. Remote PC actions still require reachable real PC agents; the optional local demo simulates those actions.

## Optional demo files

compulab/local_demo_settings.py and tools/local_remote_demo.py are used only when launching the local demo. Do not change a production DJANGO_SETTINGS_MODULE to local_demo_settings. Production keeps compulab.settings (and its existing web-server entry point). Demo template caching was disabled to show edits after one restart; normal deployment caching remains unchanged.

## Verification

126 regression tests passed. Separate cloud/edge SQLite verification passed for create, local edit publishing, update, approve and cancel with simulated JSON transport. UI templates were rendered after their edits. Actual network/production MySQL deployment still needs your deployment verification. See docs/BIDIRECTIONAL_VERIFICATION.md and docs/BIDIRECTIONAL_RESERVATIONS.md.

## Changed/new files

- .env.example
- .gitignore
- README.md
- cloud_receiver/admin.py
- cloud_receiver/command_models.py
- cloud_receiver/command_views.py
- cloud_receiver/migrations/0002_commandreceipt_remotecommand.py
- cloud_receiver/migrations/0003_reservationchange_reservationreceipt.py
- cloud_receiver/models.py
- cloud_receiver/reservation_admin.py
- cloud_receiver/reservation_models.py
- cloud_receiver/reservation_views.py
- cloud_receiver/test_remote_control.py
- cloud_receiver/test_reservations.py
- cloud_receiver/tests.py
- cloud_receiver/urls.py
- cloud_sync/PROTOCOL.md
- cloud_sync/remote_control.py
- cloud_sync/reservations.py
- cloud_sync/signals.py
- cloud_sync/sync.py
- cloud_sync/sync_payloads.py
- cloud_sync/transport.py
- compulab/local_demo_settings.py
- compulab/settings.py
- compulab/templates/cloud_sync/queue.html
- compulab/templates/labs/pc_edit_form.html
- docs/BIDIRECTIONAL_RESERVATIONS.md
- docs/BIDIRECTIONAL_VERIFICATION.md
- docs/CLOUD_REMOTE_CONTROL.md
- docs/LOCAL_REMOTE_DEMO.md
- scheduling/reservation_state.py
- scheduling/views.py
- scheduling/write_lock.py
- system/worker.py
- tools/local_remote_demo.py
- tools/requirements-local-demo.txt
