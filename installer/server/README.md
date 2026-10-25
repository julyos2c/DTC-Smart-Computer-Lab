# Installing the CompuLab server (Windows)

Do this once, on the computer that will be the CompuLab server. Allow about an hour.

## 1. Choose the server computer

- An always-on desktop or small server, **not** a lab PC students use and not someone's laptop.
- Windows 10/11 Pro or Windows Server, 8 GB RAM or more, SSD, **wired** network.
- A UPS if possible, and a second disk or USB drive for backups.
- In the campus router, give it a **fixed IP address** (DHCP reservation), e.g. `192.168.1.10`.
- In Windows Settings → Network, set the connection to **Private**.

## 2. Prerequisites

**With `CompuLab-Server-Setup.exe` (builds that bundle their runtime): none.** The setup contains
its own Python 3.13 (`runtime\python`, all packages installed) and its own MariaDB 11.4 server
(`runtime\mariadb`, the official Windows x64 files, GPL v2: `runtime\mariadb\COPYING` and
`SOURCE.txt`). The installer then:

- checks every bundled file against the build (`COMPULAB-MANIFEST.txt`, SHA-256) and refuses a
  damaged or incomplete copy before changing anything;
- creates **CompuLab's own database server**: data in `data\mariadb`, its own `my.ini` (rewritten by
  every repair) with `bind-address=127.0.0.1` (never reachable from the LAN), port **3308** or the
  next free one (ports used by other programs are skipped, never touched; `-DbPort` sets the first
  port tried), the Windows service **CompuLabMariaDB** under its own virtual account
  (`NT SERVICE\CompuLabMariaDB`), started automatically at boot, before CompuLab Web and Worker;
- secures it before it ever listens: `mariadbd --bootstrap` (no network) sets a random root
  password and removes every root account except localhost/127.0.0.1/::1 and anonymous accounts. The
  root sign-in is saved in `data\db-admin.cnf` (Administrators and SYSTEM only) **before** it is set,
  so it is never lost; passwords travel only on stdin, never on a command line or in a log;
- creates `compulab_db` and the application user `compulab` (random password in `.env`, rights on
  that database only), then runs `mariadb-upgrade` (a no-op unless the MariaDB files were updated);
- is idempotent: Repair/Update reuse the data (never initialized again); a half-created data folder
  from an interrupted install is moved to `data\mariadb.incomplete-<date>` (kept) and made again; a
  lost `db-admin.cnf` is replaced offline without touching the data; database files an earlier
  installer left unreadable get their permissions repaired first (nothing is moved or deleted).

A silent setup (`/VERYSILENT`) whose CompuLab step (`install-server.ps1`) failed exits with code
**10**, not 0: the reason is in `logs\install-*.log`.

No Python, no MariaDB/MySQL, no root password and no internet are needed, and any other database on
the computer (MySQL, XAMPP, another program's MariaDB) is never stopped, changed, reused or
initialized. `COMPULAB_DB_MODE=bundled` is recorded in `.env`.

**An existing MariaDB/MySQL instead** (`/DBMODE=external` for the setup, `-DbMode external` for the
script), **a plain folder copy** (no `runtime\`), and **installations made before the bundled
runtime** (they keep their database on Repair/Update) need these prerequisites (internet once):

| Program | Where | Notes |
|---|---|---|
| Python 3.13, 64-bit (3.12 / 3.11 64-bit also accepted) | python.org → Downloads → Windows installer (64-bit) | **Customize installation**: tick **Install for all users** and **Add Python to environment variables**. 3.14 and 32-bit Python are refused; a per-user Python gets a warning (the services would depend on that account). |
| MariaDB 11.4 LTS (or 10.11 LTS; 10.5+; or MySQL 8.0.11+) | mariadb.org → Download → MariaDB Server, MSI | Choose a strong **root password** and write it down safely. Keep "Install as service" ticked. Do *not* enable remote root access. |
| WinSW-x64.exe | github.com/winsw/winsw/releases (v2.12.0) | **Only for a plain folder copy**: save it as `installer\server\bin\WinSW-x64.exe`. `CompuLab-Server-Setup.exe` already contains it (and the Python packages, so the install needs no internet). |

Do **not** use XAMPP for the server: it is not a supervised service and its MariaDB is too old for
the current Django version. If XAMPP must stay on the computer, install MariaDB on another port
(e.g. 3307) and give that port to the installer (setup field **Database port**, or `-DbPort 3307`).

To move an installation from an external server to CompuLab's own database (Repair, elevated):
`install-server.ps1 -DbMode bundled`. It refuses when the external database already holds CompuLab
data (then: backup.ps1, `-DbMode bundled -LeaveOldDatabase`, restore.ps1 with that backup); the old
database is never changed or deleted.

In external mode the CompuLab installer never installs, upgrades, replaces or stops Python or a
database server, and never touches XAMPP. Before changing anything it checks which program listens on the database port
and refuses XAMPP or anything that is not MariaDB/MySQL. It uses the database service that owns the
port: if that service is stopped it starts it, and if it is not set to start automatically it
changes that (CompuLab needs it at boot) and says so. With several MariaDB/MySQL services and none on
the port it asks for `-DbServiceName` instead of guessing.

## 3-4. Install

**Easiest:** run `CompuLab-Server-Setup-<version>.exe` (it copies CompuLab to `C:\CompuLab` and runs
the installer in a console window). Then continue with step 3 of the list below.

**From a folder copy:** copy the whole CompuLab folder to e.g. `C:\CompuLab` (or `git clone` it
there), then double-click **Install CompuLab Server.cmd** in it (it asks for administrator rights),
or:

1. Click Start, type **PowerShell**, right-click **Windows PowerShell** → **Run as administrator**.
2. Run:

   ```powershell
   cd C:\CompuLab
   powershell -ExecutionPolicy Bypass -File installer\server\install-server.ps1
   ```

   Unattended: `-NonInteractive -ServerAddress 192.168.1.10` with the MariaDB root password in the
   environment variable `COMPULAB_DB_ROOT_PASSWORD` and, on a new installation, the first
   Administrator in `DJANGO_SUPERUSER_EMAIL` (@gmail.com) / `DJANGO_SUPERUSER_PASSWORD` (required:
   it stops without them), or settings from `-ConfigFile installer\server\server-install.sample.json`
   (a copy with your values).

3. When asked, choose the server's **campus address** from the list it shows (the fixed IP you
   reserved in step 1). Press Enter to accept the first one. (Or pass it:
   `install-server.ps1 -ServerAddress 192.168.1.10`; another web port: `-Port 8080`; another
   database port: `-DbPort 3307`; backups elsewhere: `-BackupRoot E:\CompuLabBackups`.)
4. When asked, type the MariaDB root password (used once, not saved). Click into the window first: a
   `*` appears for each character. A refused or empty password is explained (with the database
   server's own message) and asked again, up to 3 times; any other sign-in problem (server stopped,
   wrong port) stops the installer with that message.
5. When asked, create the first Administrator account: a @gmail.com address (CompuLab accepts only
   Gmail addresses for every account) and a password typed twice. A refused value is explained and
   asked again; if no working Administrator exists at the end, the installer stops ("The first
   Administrator account was not created: ...") instead of reporting success. A repair never
   creates a second one.

At the end it prints the address, e.g. `http://192.168.1.10:8000`. Open it from another computer
on the campus network and sign in.

The installer:
- checks Windows, the CompuLab files, Python, the MariaDB version (10.5 or newer; it refuses
  XAMPP's 10.4) and WinSW, and stops with a clear message if one is missing;
- checks who owns the database port before it starts or changes any database service: XAMPP's
  database and a database another program installed as its own service (e.g. an inventory
  system's bundled MariaDB) are refused untouched. The database tools (`mariadb.exe` /
  `mysql.exe`, `mariadb-dump.exe` / `mysqldump.exe`) are taken from the folder of the server on
  that port, so MariaDB 11 (which may ship only the `mariadb*` names) works next to MySQL;
- on a Repair/Update, first checks that the existing `.env` has all five database settings
  (`DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_HOST`, `DB_PORT`): it never invents credentials for
  existing data, and refuses a `.env` it did not write (e.g. a developer copy of CompuLab) before
  changing anything;
- creates `venv\` and installs the packages (needs internet the first time). An existing `venv\`
  made with another Python (another version, or another Python installation) is not reused: it is
  renamed `venv.old-<date>` (delete it once CompuLab works) and a new one is made;
- writes `.env` with random secrets (only Administrators can read it);
- creates the `compulab_db` database and a `compulab` database user;
- applies the database migrations;
- installs and starts two Windows services that start at boot (after the database service) and
  restart themselves if they stop: **CompuLab Web** (the website) and **CompuLab Worker** (lab PC
  checks, email, cloud sync, reminders);
- opens the web port for private campus/VPN addresses only (never the database port);
- schedules a nightly backup at 1:30 AM (as SYSTEM; a missed night runs at the next start-up; each
  run writes `logs\backup-<time>.log`, and a failure shows as Last Run Result 0x1 in Task Scheduler)
  to the backup folder (`-BackupRoot`, default `C:\CompuLab\backups`), which it checks is writable
  and records as `COMPULAB_BACKUP_ROOT` in `.env`. Repair, Update, **Back Up CompuLab Now** and
  restore keep using that folder until `-BackupRoot` is given again.

It works without internet (after the packages are installed), email, Tailscale or a cloud
server: those are optional and added later. Running it again later is safe (it keeps your
settings and data): that is also how to **repair** an installation. If it stops, the message says
why ("Installation stopped: ...") and everything shown is in `logs\install-<time>.log`.

**Uninstall:** Settings → Apps → *CompuLab Server* (setup program), or **Uninstall CompuLab
Server.cmd** in `installer\server`: removes the services, firewall rules and backup task, and keeps
the database, `.env`, uploads, backups and logs (the script's help explains how to remove those too).

### Values only you can provide

| Value | Where it goes | Needed? |
|---|---|---|
| MariaDB root password | typed during install (not saved) | yes |
| First Administrator email + password | typed during install | yes |
| Server's fixed campus IP (router DHCP reservation) | router; then chosen during install | yes |
| Email account + app password | `configure-email.ps1` | optional |
| Tailscale sign-in and admin-console settings | `installer\REMOTE_ACCESS.md` | optional |
| Cloud receiver URL + API key (only if the college runs one) | `.env`: `CLOUD_SERVER_URL`, `CLOUD_SYNC_API_KEY` (`cloud_sync\SETUP.md`) | optional |

## 5. Optional: email

Without email CompuLab works fully; messages are only written to `logs\worker.log`.
To send real email (verification links, reservation codes, alerts):

```powershell
powershell -ExecutionPolicy Bypass -File installer\server\configure-email.ps1
```

For Gmail use an **App Password** (Google account → Security → 2-Step Verification → App passwords).

## 6. Lab PCs

See [../agent/README.md](../agent/README.md). In CompuLab, PC power status → **Agent config**
downloads a ready file per PC with **that PC's own agent secret** (`labs/agent_auth.py`).
`PC_AGENT_SHARED_SECRET` in `.env` only keeps agents installed with an older file working; System
status shows which PCs still use it. When none do, set `PC_AGENT_REQUIRE_PER_PC_SECRET=True` in
`.env` and restart both services. Replace one PC's secret (e.g. a stolen PC):
`runtime\python\python.exe manage.py agent_secret` (list; `venv\Scripts\python` without a bundled
runtime) and `... agent_secret --rotate <id>`, then
reinstall that PC with its new Agent config.

## Maintenance

| Task | Command (as Administrator, in the CompuLab folder) |
|---|---|
| Backup now | Start → CompuLab → **Back Up CompuLab Now**, or `powershell -ExecutionPolicy Bypass -File installer\server\backup.ps1 -Log` (to the configured folder) |
| Change where backups go | re-run `install-server.ps1 -BackupRoot E:\CompuLabBackups` (once; remembered) |
| Restore a backup | `... installer\server\restore.ps1 -BackupFolder E:\CompuLabBackups\compulab-20261022-013000` |
| Install a new CompuLab version | run the newer setup; or replace the files (or `git pull`), then `... installer\server\update.ps1` |
| Is everything working? | Start → CompuLab → **CompuLab Server Status** → F, or `... installer\server\server-status.ps1` (add `-StartServices` to start stopped services) |
| First Administrator missing / broken | `runtime\python\python.exe manage.py ensure_admin --check` (or `venv\Scripts\python`); re-run the installer (Repair) to create one |
| CompuLab's own database | `Get-Service CompuLabMariaDB`; its log `data\mariadb\compulab-mariadb.err`; `server-status.ps1` shows "Database port ... on 127.0.0.1 only". Stop everything cleanly: `stop-compulab.ps1` |
| Server IP changed | `... installer\server\set-server-address.ps1 -Primary 192.168.1.10`, then `installer\agent\set-agent-server.ps1` on each lab PC |
| Remote access (Tailscale) | `... installer\server\configure-remote-access.ps1` (see `installer\REMOTE_ACCESS.md`) |
| Stop / start | Services app → CompuLab Web / CompuLab Worker, or `Stop-Service CompuLabWeb,CompuLabWorker` |
| Test run without services | `... installer\server\run-foreground.ps1` |
| Logs | `logs\compulab.log` (website), `logs\worker.log` (background), `logs\CompuLab*.log` (service wrapper), `logs\install-*.log`, `logs\backup-*.log` (nightly backups) |
| Health | `http://<server>:8000/healthz` answers `ok`; Admins: **System status** page |
| Manual checks after installing | `docs\MANUAL_VERIFICATION.md` |

**Restore drill:** once a term, restore last night's backup onto a spare PC (install the server there
with the same steps, then `restore.ps1`) and check that you can sign in.

## Moving to a new server computer

1. Install the new machine with steps 1–4 (it gets its own empty database).
2. Copy the latest backup folder to it and run `restore.ps1 -BackupFolder ...`.
3. Lab PCs on their own agent secret keep working (the secrets are in the restored database). For
   PCs still on the shared secret, copy `PC_AGENT_SHARED_SECRET` (and email settings) from the old
   `.env` (`env.txt` in the backup) into the new `.env`, then restart both services.
4. Give the new machine the old IP address in the router, so lab PCs and bookmarks keep working.

## What this does not do automatically

- Install Python, MariaDB or WinSW (download links above).
- Reserve IP addresses in the router, or set the network to Private.
- Copy backups off the server: point `-BackupRoot` at a second disk, USB drive or network share.
- HTTPS on the campus network: the site is plain HTTP on the LAN. Use it only on the campus network
  and the VPN (never forward port 8000 on the router). Remote access through Tailscale can use
  HTTPS (Serve mode, see `installer\REMOTE_ACCESS.md`).
- Sign in to Tailscale or set up a cloud receiver: both need a person (see the table above).
