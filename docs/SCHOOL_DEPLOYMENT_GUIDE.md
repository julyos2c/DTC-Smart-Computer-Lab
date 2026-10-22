# CompuLab — school deployment guide

For the person setting up CompuLab at the school (IT staff or the Lab In-Charge). No programming
needed. Plan about one hour for the server and ten minutes per lab PC.

You need two files (built with `installer\build\build-installers.ps1`, see the end of this guide):

| File | Where it goes |
|---|---|
| `CompuLab-Server-Setup-<version>.exe` | once, on the server computer |
| `CompuLab-Agent-Setup-<version>.exe` | on every student lab PC |

With them comes `DISTRIBUTION-MANIFEST-<version>.md`: sizes, SHA-256 hashes, supported Windows versions.

**Before running a setup:** copy it to the computer's own disk (not a mapped network drive) and check
its hash against the manifest: `certutil -hashfile CompuLab-Server-Setup-<version>.exe SHA256`. The
setups are **not code-signed**, so Windows shows "Windows protected your PC / Unknown publisher":
only when the hash matched, click **More info** → **Run anyway**. Do not turn SmartScreen or the
antivirus off.

The first installation should be supervised: tick the checklist in `docs\RELEASE_READINESS.md`.
Use a build newer than 2026.10.23.0537 (that release lacks the student-only lock screen, the per-PC
agent secrets and the other fixes described here). Step-by-step for beginners:
`docs\COMPULAB_BEGINNER_INSTALLATION_GUIDE.md`.

---

## Part 1 — the main server (once)

**Choose the computer.** An always-on desktop with Windows 11 (64-bit; Windows 10 22H2 or Windows
Server 2016+ also work), 8 GB RAM, wired network. Not a student PC. Give it a **fixed IP address** in
the router (DHCP reservation), e.g. `192.168.1.10`, and set its network to **Private** (Settings →
Network).

**Install two free programs first** (needs internet once). The CompuLab setup checks them and stops
with an explanation if one is missing or unsuitable; it never installs or replaces them itself.

1. **Python 3.13, 64-bit** — python.org → Downloads → "Windows installer (64-bit)". Choose
   **Customize installation**, tick **Install Python 3.13 for all users** and **Add Python to
   environment variables**. (3.14 and 32-bit Python are not supported.)
2. **MariaDB 11.4 LTS** (10.11 LTS also works) — mariadb.org → Download → MariaDB Server (MSI,
   64-bit). Choose a strong **root password** and write it down; keep **Install as service** ticked.
   MySQL 8.0.11 or newer works too; XAMPP's MariaDB is too old. If XAMPP (or another program) already
   uses port 3306, give MariaDB another port (e.g. 3307) — CompuLab never uses or changes XAMPP.

**Run `CompuLab-Server-Setup.exe`** and answer:

| Question | Answer |
|---|---|
| Install folder | keep `C:\CompuLab` |
| Campus IP address | the fixed IP from above, e.g. `192.168.1.10` (or leave empty to pick from a list) |
| Port | keep `8000` |
| Database port | `3306` (or the port you gave MariaDB) |
| MariaDB root password (console window) | the password from step 2 (not saved) |
| First Administrator (console window) | your Gmail address (CompuLab accepts only @gmail.com) and a password you choose, typed twice |

A console window shows each step and ends with **"CompuLab is installed"** and the address, e.g.
`http://192.168.1.10:8000`. Open it from another computer and sign in. If it stops with
**"Installation stopped: …"**, the line explains why; fix it and run the setup again (it continues
safely and never deletes data). It never reports "installed" without a working Administrator.

What it set up for you: the two Windows services **CompuLab Web** and **CompuLab Worker** (they start
automatically after every restart), the firewall rule (campus addresses only), a nightly backup at
1:30 AM to `C:\CompuLab\backups` (each run writes `C:\CompuLab\logs\backup-<time>.log`), and
Start-menu shortcuts (**CompuLab Server Status** — press F for the full report, **Back Up CompuLab
Now**, **Repair CompuLab Server**).

**Recommended next:** point the backups at a second disk or USB drive (run
`installer\server\install-server.ps1 -BackupRoot E:\CompuLabBackups` as Administrator, once: the
folder is remembered by nightly backups, Back Up CompuLab Now, Repair and Update), and set up email
(`installer\server\configure-email.ps1`) if you want emailed codes and alerts. Everything works
without email and without internet.

## Part 2 — each student lab PC

1. **Router:** give the PC a fixed IP address (DHCP reservation). **Windows:** a **standard**
   (non-administrator) account for students; note its name (e.g. `student`).
2. **CompuLab** (signed in as Admin): Manage labs → add the PC with that IP address. Then
   **PC power status** → the PC's row → **Agent config** downloads `agent_config.local.json` with
   **this PC's own agent secret**. Save it to a USB stick **next to** `CompuLab-Agent-Setup.exe`.
   (Delete it from the stick when you are done.)
3. **On the lab PC** (signed in as a Windows administrator): run `CompuLab-Agent-Setup.exe` from the
   stick. It finds the config file by itself and asks for the **student Windows account(s)**. A
   console window ends with **"The CompuLab agent is installed"** and the agent's self-test result.
4. Sign in with the student account: the CompuLab lock screen appears. Sign in as administrator: no
   lock screen. In CompuLab, **PC power status** (after **Check now**) shows the PC as **Available**.
   If the lock screen is ever closed or crashes, it should come back within about a minute (not yet
   tested on real PCs).

Only the student accounts (local group **CompuLab Students**) get the lock screen; administrators are
never added. Staff open a locked student session with **PC power status** → **Manual Unlock
(Guest)**. Install one PC first and test it before the others (see
`docs\COMPULAB_BEGINNER_INSTALLATION_GUIDE.md`, sections O and Q).

No Python is needed on lab PCs.

**Many PCs at once** (from an administrator command prompt, e.g. through your remote-management tool):

```
CompuLab-Agent-Setup.exe /VERYSILENT /CONFIG="\\server\share\agents\PC-01.json" /STUDENTS="student"
```

## Every day

| Situation | What happens / what to do |
|---|---|
| Internet down | Nothing to do: everything on campus keeps working. Emails wait and are sent later. |
| Server restarted | Nothing to do: both services start by themselves. |
| A lab PC can't reach the server | Its lock screen says **Server offline**; session-end events wait on the PC and are sent automatically when it reconnects. Check the cable, then **Agent Status** (Start → run `C:\Program Files\CompuLab Agent\tools\agent-status.ps1`). |
| Something looks wrong | Start menu → **CompuLab Server Status** (checks every part), or the **System status** page in CompuLab (Admins). |

## Update, repair, uninstall

| Task | How |
|---|---|
| Update the server | Run the newer `CompuLab-Server-Setup.exe`. It backs up first, keeps all data and settings. |
| Repair the server | Start menu → **Repair CompuLab Server** (or run the same setup again). |
| Update / repair a lab PC | Run the newer `CompuLab-Agent-Setup.exe` (settings, its secret, student accounts and queued events are kept). A PC updated from an older agent locks every account until you enter the student account(s) once. |
| Add a student account on a lab PC | elevated Command Prompt: `net localgroup "CompuLab Students" student2 /add` (or run the agent setup with it) |
| Change the server address on a lab PC | `C:\Program Files\CompuLab Agent\tools\set-agent-server.ps1 -ServerUrl http://NEW-IP:8000` (as Administrator) |
| Restore the server from a backup | `installer\server\restore.ps1 -BackupFolder <backup folder>\compulab-…` (as Administrator) |
| Uninstall the server | Settings → Apps → **CompuLab Server**. Removes the services, firewall rule and backup task; **keeps** the database, settings, uploads and backups. |
| Uninstall from a lab PC | Settings → Apps → **CompuLab Agent**. Keeps unsent events in `C:\ProgramData\CompuLab Agent`. |

## Optional

- **Access from home** (Tailscale VPN): `installer\REMOTE_ACCESS.md`.
- **Desktop shortcut for staff computers:** `installer\launcher\install-launcher.ps1 -LanUrl http://192.168.1.10:8000`.
- **Checks to do after installing:** `docs\MANUAL_VERIFICATION.md`.

## Building the two setup files (developer PC)

```
powershell -ExecutionPolicy Bypass -File installer\build\build-installers.ps1 -InstallInnoSetup
```

Needs Python 3.13, internet and a committed working tree (it refuses uncommitted changes); writes the
setups, the agent zip, `SHA256SUMS-<version>.txt`, `BUILDINFO-<version>.json` and
`DISTRIBUTION-MANIFEST-<version>.md` to `installer\dist\`. Check a copy of them at any time with
`installer\build\verify-dist.ps1 -Dist <folder>`. Automated tests: `installer\tests\` (see
`installer\README.md`).
