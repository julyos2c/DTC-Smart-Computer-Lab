# Installing the CompuLab server (Windows)

Do this once, on the computer that will be the CompuLab server. Allow about an hour.

## 1. Choose the server computer

- An always-on desktop or small server, **not** a lab PC students use and not someone's laptop.
- Windows 10/11 Pro or Windows Server, 8 GB RAM or more, SSD, **wired** network.
- A UPS if possible, and a second disk or USB drive for backups.
- In the campus router, give it a **fixed IP address** (DHCP reservation), e.g. `192.168.1.10`.
- In Windows Settings → Network, set the connection to **Private**.

## 2. Install the three prerequisites (needs internet once)

| Program | Where | Notes |
|---|---|---|
| Python 3.12 (or 3.11+) | python.org → Downloads → Windows installer (64-bit) | Tick **Add python.exe to PATH** and **Install for all users** |
| MariaDB 11.4 LTS (or 10.11 LTS) | mariadb.org → Download → MariaDB Server, MSI | Choose a strong **root password** and write it down safely. Keep "Install as service" ticked. Do *not* enable remote root access. |
| WinSW-x64.exe | github.com/winsw/winsw/releases (v2.12.0) | **Only for a plain folder copy**: save it as `installer\server\bin\WinSW-x64.exe`. `CompuLab-Server-Setup.exe` already contains it (and the Python packages, so the install needs no internet). |

Do **not** use XAMPP for the server: it is not a supervised service and its MariaDB is too old for
the current Django version.

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
   environment variable `COMPULAB_DB_ROOT_PASSWORD` (and optionally `DJANGO_SUPERUSER_EMAIL` /
   `DJANGO_SUPERUSER_PASSWORD` for the first Administrator), or settings from
   `-ConfigFile installer\server\server-install.sample.json` (a copy with your values).

3. When asked, choose the server's **campus address** from the list it shows (the fixed IP you
   reserved in step 1). Press Enter to accept the first one. (Or pass it:
   `install-server.ps1 -ServerAddress 192.168.1.10`; another port: `-Port 8080`.)
4. When asked, type the MariaDB root password (used once, not saved).
5. When asked, create the first Administrator account (email + password).

At the end it prints the address, e.g. `http://192.168.1.10:8000`. Open it from another computer
on the campus network and sign in.

The installer:
- checks Windows, the CompuLab files, Python, the MariaDB version (10.5 or newer; it refuses
  XAMPP's 10.4) and WinSW, and stops with a clear message if one is missing;
- creates `venv\` and installs the packages (needs internet the first time);
- writes `.env` with random secrets (only Administrators can read it);
- creates the `compulab_db` database and a `compulab` database user;
- applies the database migrations;
- installs and starts two Windows services that start at boot (after the database service) and
  restart themselves if they stop: **CompuLab Web** (the website) and **CompuLab Worker** (PC
  status, email, cloud sync, reminders);
- opens the web port for private campus/VPN addresses only (never the database port);
- schedules a nightly backup at 1:30 AM.

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

See [../agent/README.md](../agent/README.md). The agent secret they need is `PC_AGENT_SHARED_SECRET`
in `.env`; easier: in CompuLab, PC status → **Agent config** downloads a ready file per PC.

## Maintenance

| Task | Command (as Administrator, in the CompuLab folder) |
|---|---|
| Backup now | `powershell -ExecutionPolicy Bypass -File installer\server\backup.ps1 -BackupRoot E:\CompuLabBackups` |
| Change where nightly backups go | re-run `install-server.ps1 -BackupRoot E:\CompuLabBackups` |
| Restore a backup | `... installer\server\restore.ps1 -BackupFolder E:\CompuLabBackups\compulab-20261022-013000` |
| Install a new CompuLab version | replace the files (or `git pull`), then `... installer\server\update.ps1` |
| Is everything working? | `... installer\server\server-status.ps1` (add `-StartServices` to start stopped services) |
| Server IP changed | `... installer\server\set-server-address.ps1 -Primary 192.168.1.10`, then `installer\agent\set-agent-server.ps1` on each lab PC |
| Remote access (Tailscale) | `... installer\server\configure-remote-access.ps1` (see `installer\REMOTE_ACCESS.md`) |
| Stop / start | Services app → CompuLab Web / CompuLab Worker, or `Stop-Service CompuLabWeb,CompuLabWorker` |
| Test run without services | `... installer\server\run-foreground.ps1` |
| Logs | `logs\compulab.log` (website), `logs\worker.log` (background), `logs\CompuLab*.log` (service wrapper) |
| Health | `http://<server>:8000/healthz` answers `ok`; Admins: **System status** page |
| Manual checks after installing | `docs\MANUAL_VERIFICATION.md` |

**Restore drill:** once a term, restore last night's backup onto a spare PC (install the server there
with the same steps, then `restore.ps1`) and check that you can sign in.

## Moving to a new server computer

1. Install the new machine with steps 1–4 (it gets its own empty database).
2. Copy the latest backup folder to it and run `restore.ps1 -BackupFolder ...`.
3. Copy `PC_AGENT_SHARED_SECRET` (and email settings) from the old `.env` (`env.txt` in the backup) into the new `.env`, then restart both services.
4. Give the new machine the old IP address in the router, so lab PCs and bookmarks keep working.

## What this does not do automatically

- Install Python, MariaDB or WinSW (download links above).
- Reserve IP addresses in the router, or set the network to Private.
- Copy backups off the server: point `-BackupRoot` at a second disk, USB drive or network share.
- HTTPS on the campus network: the site is plain HTTP on the LAN. Use it only on the campus network
  and the VPN (never forward port 8000 on the router). Remote access through Tailscale can use
  HTTPS (Serve mode, see `installer\REMOTE_ACCESS.md`).
- Sign in to Tailscale or set up a cloud receiver: both need a person (see the table above).
