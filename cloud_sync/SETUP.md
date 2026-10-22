# cloud_sync — setup

Cloud sync is **optional** and **off by default**. CompuLab works fully on the campus network
without it. Turn it on only when the college runs a cloud receiver that implements
[PROTOCOL.md](PROTOCOL.md); this repository does not contain one.

The app is already installed (`INSTALLED_APPS`) and queues changes automatically through model
signals (`signals.py`), so no code has to be changed or hooked in.

## Turn it on

1. Make sure the receiver is running and answers `GET <url>/api/ping/`.
2. In the server's `.env`:

   ```
   CLOUD_SERVER_URL=https://compulab-cloud.example.edu
   CLOUD_SYNC_API_KEY=<the long random key the receiver expects>
   # optional:
   # CLOUD_SYNC_SITE_ID=dtc-main
   # CLOUD_SYNC_OBJECT_TYPES=reservation,session,issue
   ```

3. Restart both services (Services app → CompuLab Web and CompuLab Worker).
4. Queue the records that already exist (shows counts first, then queues with `--yes`):

   ```
   venv\Scripts\python manage.py cloud_sync_backfill
   venv\Scripts\python manage.py cloud_sync_backfill --yes
   ```

5. Check **System status → Cloud sync**: "Last successful sync" should be recent and the waiting
   count should fall to 0.

## Turn it off

Clear `CLOUD_SERVER_URL` (or the key) in `.env` and restart both services. Nothing new is queued.
Rows already queued stay in the table; `manage.py prune_sync_queue --yes` deletes them.

## Remote access is a different thing

Opening CompuLab from home goes through Tailscale to the campus server itself, not through cloud
sync: see [installer/REMOTE_ACCESS.md](../installer/REMOTE_ACCESS.md).
