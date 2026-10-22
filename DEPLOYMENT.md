# CompuLab — Deployment & Operations

> **Installing on the campus (topology A)?** Use the step-by-step installer instead of the manual
> procedure below: [installer/README.md](installer/README.md) — server
> ([installer/server/README.md](installer/server/README.md)), lab PCs
> ([installer/agent/README.md](installer/agent/README.md)) and remote access
> ([installer/REMOTE_ACCESS.md](installer/REMOTE_ACCESS.md)). It installs two Windows services:
> **CompuLab Web** (waitress, `COMPULAB_BACKGROUND_TASKS=False`) and **CompuLab Worker**
> (`manage.py run_worker`: PC status, email outbox, optional cloud sync, reminders, durable jobs,
> connectivity monitor). After installing, work through
> [docs/MANUAL_VERIFICATION.md](docs/MANUAL_VERIFICATION.md).
> The sections below remain the reference for manual and cPanel deployments.

## 1. Where this app can run

CompuLab controls lab PCs on the school LAN. Three parts of it only work when
the Django server is **on the same network as the lab PCs**:

| Feature | Why it needs the LAN |
|---|---|
| Unlock / override warning / lock / power actions | Server sends HTTP to `http://<pc.ip_address>:5555` (`labs/network.py`) — private 192.168.x.x addresses are unreachable from the internet. |
| PC status checker | Server runs `ping` against each PC's LAN IP every 20 s. |
| PC identification on agent APIs and `/labs/pc-login/` | PC is looked up by `REMOTE_ADDR == pc.ip_address`. From a cloud host every PC behind the school NAT shows the same public IP. |
| Background loops (auto-lock, stale-session release, log wipe, reminders) | Long-running threads; shared-hosting/Passenger workers are started and killed on demand. |

**Supported topologies**

- **A. On-premises server (recommended, works today).** Run Django on a school
  machine (the current edge server). Make it reachable remotely with Tailscale
  (see `installer/REMOTE_ACCESS.md`) — no public hosting needed.
- **B. On-premises edge + MochaHost "cloud" mirror.** Edge server as in A; a
  public read-only/dashboard instance receives data through `cloud_sync`
  (one-way, protocol in `cloud_sync/PROTOCOL.md`). Note: the cloud receiver
  (`/api/ping/`, `/api/sync/`) is **not implemented** in this repo; the
  sending side stays off until one exists and is configured.
- **C. Everything on MochaHost.** Only viable if the PC agents are reworked to
  *poll* the server (instead of being pushed to) and identify themselves by a
  per-PC token instead of IP. That is a feature rewrite, not a deployment.

## 2. Requirements

- Python 3.10–3.12 recommended (tested on 3.11.16).
- MySQL/MariaDB with `utf8mb4`. Current pin: Django 5.0.14 (EOL) because the
  XAMPP database is MariaDB 10.4. **Upgrade path:** MariaDB ≥ 10.5 or
  MySQL ≥ 8.0.11, then set `Django>=5.2.8,<5.3` in `requirements.txt`
  (the test suite passes on 5.2.18).
- `mysqlclient` needs MySQL client headers on Linux hosts
  (`libmysqlclient-dev`/`mariadb-devel`) — on cPanel ask the host or use
  their prebuilt wheel.

## 3. Configuration

All deployment values live in `.env` next to `manage.py` (template:
`.env.example`). Production must have at least:

```
DJANGO_DEBUG=False
DJANGO_SECRET_KEY=<50+ random chars>
DJANGO_ALLOWED_HOSTS=<hostnames/IPs>
DJANGO_CSRF_TRUSTED_ORIGINS=<full origins>
DB_NAME= / DB_USER= / DB_PASSWORD= / DB_HOST=
PC_AGENT_SHARED_SECRET=<same value as every agent_config.json "secret">
```

The app refuses to start with `DJANGO_DEBUG=False` and no secret key or agent
secret. Set `DJANGO_SECURE_SSL=True` (and `DJANGO_BEHIND_PROXY=True` behind
Apache/nginx/Passenger) **only after** HTTPS works.

## 4. Deploy / update procedure (on-premises, Windows)

```powershell
# 0. Backup first (see section 6)
python -m venv venv
venv\Scripts\pip install -r requirements.txt waitress
venv\Scripts\python manage.py check --deploy
venv\Scripts\python manage.py migrate --plan      # review before applying
venv\Scripts\python manage.py migrate
venv\Scripts\python manage.py collectstatic --noinput
venv\Scripts\python manage.py test
venv\Scripts\waitress-serve --listen=0.0.0.0:8000 compulab.wsgi:application
```

Run waitress as a Windows service (e.g. NSSM) so it restarts on boot. Do not
use `runserver` in production.

## 5. cPanel / MochaHost (topology B cloud instance only)

1. cPanel → *Setup Python App*: Python 3.11, app root = project folder,
   startup file `passenger_wsgi.py`, entry point `application`.
2. Create the MySQL database + user in cPanel; put credentials in `.env`.
3. In the app's virtualenv: `pip install -r requirements.txt`.
4. `.env`: `COMPULAB_BACKGROUND_TASKS=False`, `DJANGO_BEHIND_PROXY=True`,
   `DJANGO_STATIC_ROOT=<public_html>/static`, then `collectstatic`, `migrate`.
5. Enable AutoSSL, then `DJANGO_SECURE_SSL=True`; restart the app
   (`touch tmp/restart.txt`).

## 6. Backup & rollback

Before every deployment:

```powershell
mysqldump -u <user> -p --single-transaction --routines compulab_db > backup_YYYYMMDD.sql
# copy media/ (avatars + activity_log_backups) and the current code folder
```

Verify the dump: `mysql -u <user> -p -e "CREATE DATABASE compulab_restore_test"`,
import it there, compare row counts, drop the test DB.

- **Code rollback:** restore the previous code folder (or git checkout the
  previous tag), reinstall its `requirements.txt`, restart the server.
- **Database rollback:** only if a migration damaged data. Restoring the dump
  discards every record written after it was taken — export those first.
  All migrations in this release are additive or metadata-only
  (`accounts.0020` changes help text only; no SQL).

## 7. Tests

`python manage.py test` — authorization sweep over every URL (anonymous and
per role), PC-agent secret checks, calendar XSS escaping, media exposure, and
production-settings guards.
