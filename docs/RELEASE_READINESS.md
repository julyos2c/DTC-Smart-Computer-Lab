# CompuLab Windows installers: release readiness

For whoever does the **first, supervised installation** at the school, and for whoever builds and
hands out the setup files.

**Status (23 Oct 2026):** the source on branch `phase1-security-fixes` contains the fixes below and
passes every automated check (section 2). **A new installer build is required**: release
2026.10.23.0537 (commit `6563f42`) does not contain them and must not be installed at the school.
After the new build: ready for a *supervised* first installation. **Not** yet verified as
plug-and-play: nothing that needs administrator rights (Windows services, firewall rules, scheduled
tasks, the CompuLab Students group, the lock screen at sign-in) has been run on a real machine.

The files of a release and their hashes are listed in `installer\dist\DISTRIBUTION-MANIFEST-<version>.md`
(created by the build). `installer\build\verify-dist.ps1` re-checks them at any time, including on a
copy on a USB stick.

Step-by-step instructions for the installation itself, including every check below, are in
[COMPULAB_BEGINNER_INSTALLATION_GUIDE.md](COMPULAB_BEGINNER_INSTALLATION_GUIDE.md) (checklist version:
[COMPULAB_QUICK_START.md](COMPULAB_QUICK_START.md)).

## 1. What changed since 2026.10.23.0537

| Problem | Fix (where) | How the parts fit together |
|---|---|---|
| Repair/Update reset the nightly backups to `C:\CompuLab\backups`; "Back Up CompuLab Now" ignored a custom folder | The folder is recorded as `COMPULAB_BACKUP_ROOT` in `.env` and checked (writable, drive present) before anything changes (`installer\server\common.ps1`: `Get-ConfiguredBackupRoot`, `Test-BackupRoot`; `install-server.ps1`) | `install-server.ps1` (new install, Repair, Update), `backup.ps1` (nightly task, Back Up Now with `-Log`), `update.ps1` and `restore.ps1` all read the same value; installations from before it was recorded fall back to the nightly task's own `-BackupRoot`. A backup never writes into an existing folder and never deletes the one it just made. `server-status.ps1` shows the folder and flags a task that disagrees |
| The installer said "installed" when the first Administrator was not created (e.g. non-Gmail address) | New `manage.py ensure_admin` (`accounts/management/commands/ensure_admin.py`) checks for a *working* Administrator (active superuser, role Admin, email, password) and creates one only if none exists; the password reaches it only through an environment variable | `install-server.ps1` asks (email checked first, password twice), shows the reason for any refusal, re-asks, then verifies with `ensure_admin --check`; without a working Administrator the install **stops** with the reason. Repair/Update never create a second one. Gmail-only is an application rule (`accounts/email_rules.py`) and is kept and stated |
| Database fixed at 3306; a repair ignored `-DbPort`; XAMPP on 3306 unsupported | The setup has a **Database port** field; before any change the installer checks who listens on the port and refuses XAMPP or any non-MariaDB/MySQL program (it never touches them); the service that owns the port is chosen | `.env` keeps `DB_PORT`; an explicitly given `-DbPort`/`-DbHost` on a repair is applied only after the new endpoint is checked; changing `DbName`/`DbUser` on an existing install is refused. Django, backups, restore and the services all read `.env` |
| The lock screen started for **every** Windows account, administrators included | The start-up task targets the local group **CompuLab Students** (`installer\agent\agent-common.ps1`, `install-agent.ps1`, agent setup page "Student accounts", `/STUDENTS=`) | Accounts are checked before any change (must exist, must not be administrators). Repair/Update keep the installed setting; an older all-accounts install stays so until student accounts are given (no surprise unlocking). `agent-status.ps1` shows who is locked |
| All lab PCs shared one agent secret | Each PC gets its own secret when its Agent config is downloaded (`labs/agent_auth.py`, migration `labs 0022`) | The server checks a PC's secret against the PC registered for the caller's IP; the shared secret keeps older agents working until that PC's agent has used its own secret once; commands to agents try the right secret; `PC_AGENT_REQUIRE_PER_PC_SECRET=True` switches the shared one off; `manage.py agent_secret` lists / rotates. **No agent program change**, so agents in the field keep working |
| System status / `/healthz/ready` showed **no** lab PCs (query `.exclude(ip_address='')` matched nothing) | `PC.objects.filter(ip_address__isnull=False)` in `system/views.py`, `system/connectivity.py`, `labs/views.py` (duplicate-IP warning) | regression test `labs/test_agent_auth.py` |
| "CompuLab Server Status" could not read admin-only items and did not say so | `Server Status.cmd` offers **F** (full report, normal UAC prompt) or **L** (limited); `server-status.ps1` labels skipped lines "needs administrator" and adds a backup section | no silent elevation |
| "PC status" in setup texts and docs | "PC power status" everywhere the operator is told where to click | test checks installer files and user docs |

### Since 2026.10.23.0716 (server installer; found on a real test install)

Release 2026.10.23.0716 (commit `2b689ea`) has the fixes above but not these. Release 2026.10.23.1050
(commit `7e93677`) has the `.env`, sign-in error and venv fixes, but not the two database-server rows
(another program's database, database tools); use a later build, above all on a PC with more than one
database server.

| Problem | Fix (where) | Tests |
|---|---|---|
| Started in a folder whose `.env` lacks the database settings (a developer copy), the installer went on as a repair and tried to sign in to MariaDB/MySQL with an empty port, then blamed the password | Repair/Update first check that the existing `.env` has `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_HOST`, `DB_PORT` and stop otherwise, before any question, package install or `.env` change; credentials are never invented, a missing host/port only taken from an explicit `-DbHost`/`-DbPort` (`common.ps1` `Test-ExistingDbSettings`; `install-server.ps1`). The sign-in file refuses an empty host/port | logic tests; end-to-end "existing .env without database settings" |
| Every sign-in failure was reported as "wrong password, or the database service is not running", including an empty password that never reached the installer | `Get-DbSignIn` keeps mysql's own message; `ConvertTo-DbErrorText` says what it means (empty password, wrong password, no server on host:port, unknown host, empty port, sign-in method, host not allowed) followed by `Database server said: ...` (password and temporary file path removed). A typed root password that is refused is asked again (3 tries), with a hint to click into the window first | logic tests (each message, plus a real `mysql.exe` against a port with no server); end-to-end "wrong root password" (message shown, password not in output or log) |
| A database that another program installed as its own service (an inventory system's MariaDB on 3307) was accepted, and the installer suggested `-DbServiceName` for it; with XAMPP or such a database on the port, a MariaDB/MySQL service could be started or set to Automatic before the port was refused | `Test-DbListener` refuses a server whose service is not a MariaDB/MySQL installation unless named with `-DbServiceName`; the port owner is checked before any database service is started or changed; the service of MySQL 8.4's child `mysqld` is found through its parent (`common.ps1`, `install-server.ps1`) | logic tests, including a read-only check of the real servers on the PC |
| Database tools were found by name (`mysql.exe` / `mysqldump.exe` first, MariaDB folders before MySQL's): MariaDB 11 may ship only `mariadb.exe` / `mariadb-dump.exe`, and MySQL's `mysqldump` could then run against MariaDB (backups before every Repair) | `Find-DbClient` takes the client / dump program from the folder of the server on `DB_PORT`, preferring the `mariadb*` names, else the first installed (`install-server.ps1`, `backup.ps1`, `restore.ps1`) | logic tests; end-to-end (install, backup, restore) |
| An existing `venv\` was reused whatever Python made it (a 3.11 venv with the 3.13 packages) | `pyvenv.cfg` must show the Python the setup chose (same version and installation); otherwise the CompuLab services are stopped, the old `venv\` is renamed `venv.old-<date>` (kept) and a new one is made (`common.ps1` `Test-VenvMatchesPython`, `Move-VenvAside`) | logic tests; end-to-end repair over a real Python 3.11 venv |

**Upgrade notes (existing installations):**

- Database migration `labs 0022_pc_agent_secret` adds two columns (`agent_secret`, `agent_secret_in_use`) to `labs_pc`. Additive; applied by the setup after its automatic backup. Rollback: restore that backup (`restore.ps1`) and reinstall the previous setup.
- Lab PCs keep working with the shared secret. To move a PC: download its Agent config again and re-run the agent setup on it (System status → "Agent secret" shows progress). Only when all show "own": `PC_AGENT_REQUIRE_PER_PC_SECRET=True`.
- A lab PC updated from 2026.10.23.0537 keeps locking every account until the agent setup is run once with its student account(s).
- `.env` gains `COMPULAB_BACKUP_ROOT` on the first Repair/Update (taken from the existing nightly task).
- Unattended server installs now need `DJANGO_SUPERUSER_EMAIL` / `DJANGO_SUPERUSER_PASSWORD` when no Administrator exists (they stop otherwise).

## 2. Verification status

### 2a. Tested automatically (no administrator rights; disposable folders and databases only)

| Suite | Command | Result (23 Oct 2026, working tree) |
|---|---|---|
| Installer logic, incl. admin-only definitions | `installer\tests\test-installer-logic.ps1` | 55 / 55 passed |
| Server setup end to end (test build, throwaway MySQL 8.4 on a random port, payload staged from the working tree with `installer\tests\stage-test-payload.ps1`) | `installer\tests\test-server-install.ps1 -Payload ...` | see the final report of this change (all must pass before building) |
| Agent setup end to end (no Python on PATH, update 0.0.0 → 0.0.1) | `installer\tests\test-agent-install.ps1 -Payload ...` | 16 / 16 passed |
| Agent program + live Django server (incl. per-PC secret) | `venv\Scripts\python -m unittest discover -s lab_pc_agent\tests` | 21 / 21 passed |
| Django 5.0.14 and 5.2.18 (SQLite) | `manage.py test` | 112 / 112 passed on each |
| Migrations complete | `manage.py makemigrations --check --dry-run` | no changes |
| Build provenance, payload scan, distribution files | `build-installers.ps1`, `verify-dist.ps1` | run at the next build |

What the automated end-to-end tests cover: new install, Update to a newer version (secrets, database
port and **custom backup folder kept**, backup made first), restore, Back Up Now in the configured
folder, same-second backup names, backup failure logging, invalid settings / busy web port / no
database on the port / non-database on the port refused before any change, **no working
Administrator → install stops** (also for a non-Gmail address), no second Administrator on Repair,
uninstall keeps data; agent install / repair / update / uninstall keeping settings and queued
events, no Python needed.

### 2b. Source-code reviewed, not executed

- The scheduled task, firewall rules, services and the CompuLab Students group are built as
  definitions and checked (`New-ScheduledTask`, `New-NetFirewallRule -WhatIf`, WinSW loading its XML,
  account validation) — **not registered** on any machine.
- Interactive console prompts (Administrator, student accounts) — the logic is tested, the typing is not.
- Lockdown behaviour of the agent (key blocking, Task Manager policy), unchanged in this release.

### 2c. Needs an elevated test on a real Windows PC (section 3)

Services at boot and after a crash, firewall rules, backup task as SYSTEM, the CompuLab Students
group and the start-up task restricted to it, administrators not locked, agent restart after being
closed, setup elevation and SmartScreen.

### 2d. Needs the school LAN and physical lab PCs

Lock/unlock from the server, per-PC secrets on real PCs, cable outage and recovery, server restart
with lab PCs connected, the emergency page from the Server PC, IP addressing and the Private network
profile (`docs\MANUAL_VERIFICATION.md`).

## 3. Administrator checks for the first installation (not done yet)

Do these on the real server and on one or two real lab PCs. Write the date and what you saw.

### Server

| # | Do | Expected | Result |
|---|---|---|---|
| S1 | Copy `CompuLab-Server-Setup-<v>.exe` to the server's disk, check its hash (manifest), run it. | UAC prompt; SmartScreen "Unknown publisher" (unsigned); `OK: Port 3306 is served by the MariaDB service`; `OK: Administrator account: ...`; "CompuLab is installed". | |
| S2 | `sc.exe qc CompuLabWeb`, `sc.exe qc CompuLabWorker`, `sc.exe qfailure CompuLabWeb` | `AUTO_START (DELAYED)`, depends on the MariaDB/MySQL service, restart actions 10 s / 30 s / 60 s. | |
| S3 | Restart the server; do **not** sign in. From a lab PC open the campus address. | The site answers within about 2–3 minutes. | |
| S4 | Task Manager (as administrator): end the `waitress-serve.exe` process. | The site answers again within about a minute (`logs\CompuLabWeb*.log` shows the restart). | |
| S5 | `Get-NetFirewallRule -DisplayName 'CompuLab Web' \| Get-NetFirewallAddressFilter` | Remote addresses = the campus/VPN ranges; profiles Private + Domain; nothing for the database port. A lab PC can open the site. | |
| S6 | Task Scheduler > "CompuLab nightly backup" > Run; Start > CompuLab > Back Up CompuLab Now. Next morning, check again. | Last Run Result `0x0`; both backups in the **same** folder; `logs\backup-*.log` end with "Done". | |
| S7 | `install-server.ps1 -BackupRoot E:\CompuLabBackups` (elevated), then **Repair CompuLab Server**. | After the repair the task's action and `.env` still say `E:\CompuLabBackups`. | |
| S8 | Start > CompuLab > CompuLab Server Status > **F**. | Every row OK (or informational). With **L**: limited report, skipped rows say "needs administrator". | |

### Lab PC (agent)

| # | Do | Expected | Result |
|---|---|---|---|
| A1 | Copy `CompuLab-Agent-Setup-<v>.exe` and the PC's `agent_config.local.json` to the PC, check the hash, run the setup, enter the student account. | UAC prompt; SmartScreen "Unknown publisher"; console ends with "The CompuLab agent is installed" and the self-test result. | |
| A2 | Task Scheduler > "CompuLab Agent"; Computer Management (or `net localgroup "CompuLab Students"`). | "At log on of any user", repeat every 1 minute indefinitely; "Do not start a new instance"; runs as **CompuLab Students**; the group contains the student account only. | |
| A3 | Sign in with the student account; then with an administrator account. | Student: lock screen, **PC power status** (after **Check now**) shows the PC Available. Administrator: **no** lock screen. | |
| A4 | Unlock the PC (Manual Unlock (Guest)), then in the student session end `CompuLabAgent.exe` in Task Manager > Details. | The lock screen is back within about a minute (allow 2). | |
| A5 | **PC power status** > **Manual Unlock (Guest)** for the PC, then **Lock** in its row. | The PC unlocks, then locks (firewall allows the server only). From another PC, port 5555 does not answer. | |
| A6 | As the student, try to edit `C:\Program Files\CompuLab Agent\agent_config.local.json`. | Access denied. | |
| A7 | Unplug the PC's network, end a session, plug back in (`docs\MANUAL_VERIFICATION.md` 6-7). | Event queued, then delivered once. | |
| A8 | Run a newer agent setup (or the same one) without config file or student accounts. | Settings, own secret, student group and queued events kept; lock screen back at the next student sign-in. | |
| A9 | System status > Lab PC agents. | "Agent secret: own" for the PC. | |
| A10 | Locked student session: Ctrl+Alt+Del > Switch user > administrator. | Normal desktop (IT recovery path). | |
| A11 | Server PC: open `C:\CompuLab\lab_pc_agent\manual_unlock.html`, enter the lab PC's IP, port 5555 and **that PC's** agent secret, Unlock. | Record whether the lab PC unlocks (emergency path; untested so far). | |

After these: the LAN/offline/recovery scenarios in `docs\MANUAL_VERIFICATION.md`.

## 4. First-time setup that cannot be automated

- **Python 3.13, 64-bit, for all users** on the server (python.org installer > Customize installation >
  "Install for all users", "Add Python to environment variables"). The setup refuses 3.14, 32-bit and
  missing Python, and warns about a per-user Python. It never installs Python.
- **MariaDB 11.4 LTS (or 10.11 LTS, any 10.5+) or MySQL 8.0.11+**, as a Windows service, with a known
  root password (typed once during setup, not saved), on port 3306 or another free port entered in
  the setup. The setup never installs, upgrades, replaces or stops a database server; it only starts
  CompuLab's own database service if stopped and sets it to start automatically, and says so.
- **Fixed IP addresses** (router DHCP reservations) for the server and every lab PC; the server's
  network set to **Private**.
- The **first Administrator** account (a Gmail address and password) during the server setup.
- A **standard** Windows account for students on every lab PC, and its name for the agent setup.
- Each lab PC registered in CompuLab and its **Agent config** file downloaded (contains that PC's own
  secret: carry it on a USB stick, delete it afterwards).
- An administrator account on every PC to run the setups.
- **SmartScreen:** the setups are not code-signed. After checking the hash, *More info > Run anyway*.
  Do not turn SmartScreen or antivirus off. Where Group Policy, AppLocker or Smart App Control blocks
  unsigned programs, IT must allow these files by hash, or sign them with the school's certificate
  (`signtool sign ...`, then `installer\build\verify-dist.ps1 -Rehash`).
- Run the setups from the **local disk**, not a mapped network drive (mapped drive letters are not
  visible after the administrator prompt).

## 5. Known limits and remaining risks

- Windows 10 is out of Microsoft support since 14 Oct 2025: it works, but use Windows 11 or Windows
  Server for a new server. Windows on ARM: not tested.
- The agent comes back after being closed through the start-up task repeating every minute (check A4).
  It assumes one signed-in student per PC.
- Ctrl+Alt+Del cannot be blocked by any program; students can sign out or switch user (which does not
  open CompuLab). Stronger Windows kiosk policies (Assigned Access, Shell Launcher) are not configured
  or tested by CompuLab.
- The emergency page `lab_pc_agent\manual_unlock.html` works only from the server PC and needs the
  PC's own agent secret (download its Agent config — which needs the server). It has not been
  tested. The reliable IT recovery is signing in with an administrator account.
- Per-PC secrets are stored in the database (and therefore in `database.sql` backups) in readable
  form, because the server must send them to the agents; backups are restricted to Administrators
  and SYSTEM. The shared secret stays accepted for PCs not yet moved until
  `PC_AGENT_REQUIRE_PER_PC_SECRET=True`.
- The agent's own HTTP port (5555) relies on the agent secret plus the firewall rule (server IP
  only); traffic on the LAN is plain HTTP.
- The first Administrator must use a `@gmail.com` address (application rule for all accounts).
- Tailscale remote access is not configured by the setups and is untested; cloud sync stays off
  because no receiver exists.
- The site is plain HTTP on the campus network (see `installer\server\README.md`).
