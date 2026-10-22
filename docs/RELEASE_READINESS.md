# CompuLab Windows installers: release readiness

For whoever does the **first, supervised installation** at the school, and for whoever builds and
hands out the setup files.

**Status:** ready for a *supervised* first installation. **Not** yet verified as plug-and-play:
nothing that needs administrator rights (Windows services, firewall rules, scheduled tasks, the lock
screen at sign-in) has been run on a real machine yet. Tick the checklist below during the first
installation; only when every row has a result can the setups be called plug-and-play.

The files of a release and their hashes are listed in `installer\dist\DISTRIBUTION-MANIFEST-<version>.md`
(created by the build). `installer\build\verify-dist.ps1` re-checks them at any time, including on a
copy on a USB stick.

## 1. What is verified automatically (no administrator rights)

| Check | Command | What it proves |
|---|---|---|
| Build provenance | `installer\build\build-installers.ps1` | Refuses uncommitted changes; records the commit, tools and file counts in `BUILDINFO.json` (installed next to each program too). |
| Payload contents | (part of the build) | No `.env`, secret value from the build PC's `.env` / agent config, database, dump, log, queue file, per-PC config or developer test module is packaged; the build stops otherwise. |
| Distribution files | `installer\build\verify-dist.ps1` | Files present, SHA-256 equal to `SHA256SUMS` and the manifest, signature state reported as it is, agent zip contents, build from a clean tree. |
| Installer logic | `installer\tests\test-installer-logic.ps1` | Settings and `.env` handling, Python/MariaDB/MySQL version rules, database service choice, script file rules; and the **administrator-only configuration as definitions**: WinSW service XML (WinSW loads it), Windows service recovery arguments, both firewall rules (accepted by `New-NetFirewallRule -WhatIf`), the nightly backup task and the agent start-up task (built as `New-ScheduledTask` objects, never registered). |
| Server setup end to end | `installer\tests\test-server-install.ps1` | A per-user **test build** of the server setup installs into a temporary folder against a throwaway MySQL/MariaDB: offline packages, `.env`, database, migrations, first Administrator, site answers, update to a newer version keeps secrets and makes a backup first, restore, nightly backup command logs success and failure, invalid settings stop it before any change, uninstall keeps data, no test modules installed. |
| Agent setup end to end | `installer\tests\test-agent-install.ps1` | A per-user test build of the agent setup installs **with no Python on PATH**: packaged agent, self-test, settings ACL, repair and update to a newer version keep the PC's settings and queued events, invalid config refused, offline queue + `--flush`, server address change, status tool, uninstall keeps queued events. |
| Agent program | `venv\Scripts\python -m unittest discover -s lab_pc_agent\tests` | Queue, retry, delivery-once and agent-to-server behaviour. |
| Django | `venv\Scripts\python manage.py test` | Application tests, including the worker and status pages. |

**What these do not prove:** that Windows accepts and runs the services, firewall rules and tasks on
a real machine, that the lock screen appears at sign-in and comes back after it is closed, and how it
all behaves across reboots and network outages. The test builds skip exactly those steps
(`-SkipServices -SkipFirewall -SkipBackupTask`, `-SkipFirewall -SkipTask`).

## 2. Administrator checks for the first installation (not done yet)

Do these on the real server and on one or two real lab PCs. Write the date and what you saw.

### Server

| # | Do | Expected | Result |
|---|---|---|---|
| S1 | Copy `CompuLab-Server-Setup-<v>.exe` to the server's disk, check its hash (manifest), run it. | UAC prompt; SmartScreen "Unknown publisher" (unsigned); the console window ends with "CompuLab is installed". | |
| S2 | `sc qc CompuLabWeb`, `sc qc CompuLabWorker`, `sc qfailure CompuLabWeb` | `AUTO_START (DELAYED)`, depends on the MariaDB/MySQL service, restart actions 10 s / 30 s / 60 s. | |
| S3 | Restart the server; do **not** sign in. From a lab PC open the campus address. | The site answers within about 2 minutes. | |
| S4 | Task Manager (as administrator): end the `waitress-serve.exe` process. | The site answers again within about a minute (`logs\CompuLabWeb*.log` shows the restart). | |
| S5 | `Get-NetFirewallRule -DisplayName 'CompuLab Web' \| Get-NetFirewallAddressFilter` | Remote addresses = the campus/VPN ranges; profiles Private + Domain; nothing for port 3306. A lab PC can open the site. | |
| S6 | Task Scheduler > "CompuLab nightly backup" > Run. Next morning, check again. | Last Run Result `0x0`; a new `backups\compulab-*` folder; `logs\backup-*.log` ends with "Done". | |
| S7 | Run the same setup again (repair). | Ends with "CompuLab is installed"; `.env` unchanged; services running. | |
| S8 | `installer\server\server-status.ps1` | Every row OK. | |

### Lab PC (agent)

| # | Do | Expected | Result |
|---|---|---|---|
| A1 | Copy `CompuLab-Agent-Setup-<v>.exe` and the PC's `agent_config.local.json` to the PC, check the hash, run the setup. | UAC prompt; SmartScreen "Unknown publisher"; console ends with "The CompuLab agent is installed" and the self-test result. | |
| A2 | Task Scheduler > "CompuLab Agent" > Triggers / Settings. | "At log on of any user", repeat every 1 minute indefinitely; "Do not start a new instance"; runs as Users. | |
| A3 | Sign in with the students' **standard** account. | The lock screen appears; PC status shows the PC Available. | |
| A4 | As administrator, end `CompuLabAgent.exe` in Task Manager while the student is signed in. | The lock screen is back within about a minute. | |
| A5 | From CompuLab (PC status), lock and unlock the PC. | Commands work (firewall allows the server only). From another PC, port 5555 does not answer. | |
| A6 | As the student, try to edit `C:\Program Files\CompuLab Agent\agent_config.local.json`. | Access denied. | |
| A7 | Unplug the PC's network, end a session, plug back in (`docs\MANUAL_VERIFICATION.md` 6-7). | Event queued, then delivered once. | |
| A8 | Run a newer agent setup (or the same one). | Settings and queued events kept; lock screen back at the next sign-in. | |

After these: the LAN/offline/recovery scenarios in `docs\MANUAL_VERIFICATION.md`.

## 3. First-time setup that cannot be automated

- **Python 3.13, 64-bit, for all users** on the server (python.org installer > Customize installation >
  "Install for all users", "Add Python to environment variables"). The setup refuses 3.14, 32-bit and
  missing Python, and warns about a per-user Python. It never installs Python.
- **MariaDB 11.4 LTS (or 10.11 LTS, any 10.5+) or MySQL 8.0.11+**, as a Windows service, with a known
  root password (typed once during setup, not saved). The setup never installs, upgrades or replaces
  the database server; it only starts its service if stopped and sets it to start automatically,
  and says so when it does.
- **Fixed IP addresses** (router DHCP reservations) for the server and every lab PC; the server's
  network set to **Private**.
- The **first Administrator** account (a Gmail address and password) during the server setup.
- Each lab PC registered in CompuLab and its **Agent config** file downloaded (contains the agent
  secret: carry it on a USB stick, delete it afterwards).
- An administrator account on every PC to run the setups; a **standard** account for students.
- **SmartScreen:** the setups are not code-signed. After checking the hash, *More info > Run anyway*.
  Do not turn SmartScreen or antivirus off. Where Group Policy, AppLocker or Smart App Control blocks
  unsigned programs, IT must allow these files by hash, or sign them with the school's certificate
  (`signtool sign ...`, then `installer\build\verify-dist.ps1 -Rehash`).
- Run the setups from the **local disk**, not a mapped network drive (mapped drive letters are not
  visible after the administrator prompt).

## 4. Known limits

- Windows 10 is out of Microsoft support since 14 Oct 2025: it works, but use Windows 11 or Windows
  Server for a new server.
- Windows on ARM: not tested.
- The agent comes back after being closed through the start-up task repeating every minute (check A4).
  It assumes one signed-in student per PC (no fast user switching).
- The site is plain HTTP on the campus network (see `installer\server\README.md`).
