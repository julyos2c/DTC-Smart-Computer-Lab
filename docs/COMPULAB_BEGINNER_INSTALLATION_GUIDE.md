# CompuLab beginner installation guide

This guide is for the person doing the **first, supervised installation** of CompuLab at the school.
It assumes no experience with Windows servers, Python, MariaDB, Windows services, scheduled tasks or
firewalls. Follow it from top to bottom; do not skip ahead.

The short version (a checklist to tick off) is [COMPULAB_QUICK_START.md](COMPULAB_QUICK_START.md).

> **Which release this guide is for**
>
> This guide describes the setups **built from the current source** (branch `phase1-security-fixes`,
> with the fixes of 23 October 2026: student-only lock screen, own agent secret per PC, backup folder
> kept by Repair/Update, database port field, verified first Administrator).
>
> **Release 2026.10.23.0537 does not contain these fixes. Do not install it at the school.** A new
> build is needed first (`installer\build\build-installers.ps1`, run by the developer). Its file
> names, sizes and SHA-256 hashes are in `DISTRIBUTION-MANIFEST-<version>.md` next to the setups; in
> this guide `<version>` stands for that version number (for example `2026.10.24.1000`).

> **Please read first — what this guide is and is not**
>
> - The setup programs were tested automatically **without administrator rights** (installer tests
>   in temporary folders, a throwaway database, the Django and agent tests). The parts that need
>   administrator rights — Windows services, firewall rules, scheduled tasks, the "CompuLab Students"
>   group, the lock screen at sign-in, behaviour after a reboot or a network outage — **have not
>   been tested on real school computers yet**. This first installation is where that happens.
>   Section T is the checklist for it.
> - The setup programs are **not code-signed**. Windows will warn about an "Unknown publisher"
>   (section F explains how to handle that safely).
> - Following this guide does not prove that the installation works. Only the checks in sections L,
>   O and Q do, when you actually see the expected results.
> - Do the first installation on **one server and one lab PC**. Add more lab PCs only after section Q
>   passed.

---

## ⚠ First-install warning checklist — read and tick BEFORE running any installer

Tick each box when you have understood it.

- [ ] **Use a new build, not release 2026.10.23.0537** (see the box above).
- [ ] **Not yet validated on real school PCs.** Services, firewall rules, scheduled tasks, the
      student group, the lock screen, reboot and network recovery have only been tested
      automatically, without administrator rights. The tests in section Q are the first real ones.
      Do them before entering real data.
- [ ] **Only student accounts get the lock screen.** On each lab PC you enter the Windows account(s)
      students sign in with; they are put in the local group **CompuLab Students**. Administrator
      accounts are refused for that group and are never locked. *Exception:* a lab PC updated from
      an older CompuLab agent keeps locking **every** account (administrators too) until you enter
      the student accounts once (section R).
- [ ] **Staff open a locked student session from CompuLab:** **PC power status** → **Manual Unlock
      (Guest)**. IT staff can also sign in to a lab PC with an administrator account (not locked).
- [ ] **Emergency unlock page: untested, Server PC only.** `C:\CompuLab\lab_pc_agent\manual_unlock.html`
      can only reach a lab PC from the **Server PC** (lab PCs accept commands from the server's IP
      only) and needs that PC's agent secret. It has never been tried on real machines. The reliable
      recovery is signing in with an administrator account (Ctrl+Alt+Del → Switch user / Sign out).
- [ ] **Database port: 3306 unless you choose another.** The setup never uses, stops or changes XAMPP
      or another database. If something else already uses port 3306, install MariaDB on another port
      (for example 3307) and enter that port in the setup's **Database port** field (section H4).
- [ ] **The first Administrator needs a `@gmail.com` address.** CompuLab accepts only Gmail addresses
      for every account (an application rule). If the Administrator cannot be created, the setup
      **stops and says why** — it never says "CompuLab is installed" without one. Run **Repair
      CompuLab Server** to try again.
- [ ] **Backups go to one folder.** The folder you choose (`-BackupRoot`, default
      `C:\CompuLab\backups`) is remembered: nightly backups, **Back Up CompuLab Now**, Repair, Update and
      restore all use it.
- [ ] **Each lab PC has its own agent secret.** It is inside that PC's `agent_config.local.json`
      (downloaded from CompuLab). Treat every such file like a password.
- [ ] **Students use standard accounts.** Never let students sign in with a Windows administrator
      account.
- [ ] **No internet exposure.** Never set up port forwarding on the router. The database (3306) and
      the agents (5555) must never be reachable from outside the campus network.
- [ ] **Not set up, and not needed:** Tailscale remote access is **not configured** by the setup (and
      not tested); **cloud sync is switched off** because no cloud receiver exists. Leave both alone.
- [ ] **Unsigned setups:** check the SHA-256 hash first (section E); only then allow the SmartScreen
      warning for that one file (section F). Never turn SmartScreen or the antivirus off.

---

## How to read this guide

Each step starts with a line like this:

> **PC:** Server PC · **Administrator:** yes · **Where:** Start menu

- **PC** — which computer you sit at: the *Server PC*, a *Lab PC* (a student computer), or *any PC*
  on the campus network with a web browser.
- **Administrator** — whether you must be signed in to Windows with an administrator account (or
  approve an administrator prompt).

**Opening PowerShell.** Some steps ask you to type commands.

- **Normal PowerShell:** Start → type `PowerShell` → click **Windows PowerShell**.
- **Elevated PowerShell** (administrator): Start → type `PowerShell` → right-click **Windows
  PowerShell** → **Run as administrator** → **Yes**. The window title starts with
  **Administrator:**. Commands marked **(elevated)** only work in this window.
- Type or paste a command, then press **Enter**. Commands in this guide were checked against the
  CompuLab scripts; do not change them except for the values described next to them.

**Example values used in this guide.** They are made up. Replace them with your own.

| In this guide | Meaning | Where your real value comes from |
|---|---|---|
| `<version>` | the release number in the setup file names | the new build's `DISTRIBUTION-MANIFEST-<version>.md` |
| `192.168.1.10` | the Server PC's fixed campus IP address | section J |
| `192.168.1.21` | a Lab PC's fixed IP address | section M |
| `192.168.1.1` | the router | `ipconfig` → "Default Gateway" |
| `8000` | the CompuLab web port | keep `8000` |
| `3306` | the MariaDB port | keep `3306` unless section H4 applies |
| `lab.admin.example@gmail.com` | the first CompuLab Administrator | your own Gmail address |
| `Ex4mple-Only-Pass!` | a password | choose your own; never use the examples |
| `student` | the Windows account students sign in with on a lab PC | section M1 |
| `PC-01`, `Computer Lab 1` | a lab PC's name and its lab | your choice |

**Never** write real passwords or agent secrets into documents, chat messages or email.

---

## A. What CompuLab does

CompuLab manages the school's computer laboratory: staff accounts, lab schedules and reservations,
class rosters, attendance, PC usage logs, reports — and a **lock screen on every student PC** that
opens only for a student with a valid reservation (Student ID + reservation code), or when staff
unlock it.

There are three kinds of computers:

| Computer | How many | What runs on it | Installed with |
|---|---|---|---|
| **Server PC** | exactly one | the CompuLab website, its database (MariaDB) and a background worker. Always on. | `CompuLab-Server-Setup-<version>.exe` |
| **Lab PCs** (student computers) | one per seat | the **CompuLab agent**: the lock screen for student accounts, which talks to the Server PC | `CompuLab-Agent-Setup-<version>.exe` |
| Staff computers | any | only a web browser: `http://192.168.1.10:8000` | nothing |

```
                     campus network (LAN), no internet needed
   +----------------------+        +-------------------+        +-------------------+
   | Server PC            | <----> | Lab PC 1..n       |        | Staff computer    |
   | website (port 8000)  |        | lock screen agent |        | web browser       |
   | MariaDB (local only) |        | (port 5555)       |        |                   |
   +----------------------+        +-------------------+        +-------------------+
```

Everything works on the campus network **without internet**. Internet is only needed once, to
download Python and MariaDB, and later only for optional email.

Not part of this installation (leave them alone):

- **Tailscale remote access** — not configured by the setup; optional for later, separate guide
  `installer\REMOTE_ACCESS.md`, not tested on real machines. System status shows "Remote address
  (Tailscale VPN): Not configured".
- **Cloud sync** — switched off, because there is no cloud receiver to send to. System status says
  "Cloud synchronization not configured. This server is the only copy of the data (back it up
  nightly)" — that is correct.

---

## B. Supported computers and Windows versions

**Server PC**

| | |
|---|---|
| Windows | **Windows 11 64-bit** Pro / Education / Enterprise (recommended); Windows Server 2016/2019/2022/2025; Windows 10 22H2 64-bit works but is out of Microsoft support since 14 Oct 2025; Windows 11 Home works but is not recommended for an always-on server |
| Not supported | 32-bit Windows, Windows 8.1 or older (the setup refuses to run). Windows on ARM: not tested — do not use |
| Hardware | 8 GB RAM or more, SSD, **wired** network cable, always switched on. A UPS and a second disk or USB drive for backups are strongly recommended |
| Not | a student PC or someone's laptop. Preferably not a PC that already runs XAMPP or another database (possible, see H4) |

**Lab PCs:** Windows 10 22H2 or Windows 11, 64-bit (x64), any edition. No Python needed.

Check a computer's Windows version: press **Windows key + R**, type `winver`, press Enter. Check
64-bit: Start → **Settings** → **System** → **About** → "System type" must say **64-bit operating
system, x64-based processor**.

Both setups need Windows PowerShell 5.1, which is built into every supported Windows.

---

## C. What you need — installed by you, installed automatically, not needed

**You must prepare these yourself (once):**

| Item | For | Section |
|---|---|---|
| A Windows **administrator account** on the Server PC and on every Lab PC | running the setups | — |
| **Python 3.13, 64-bit, for all users** | Server PC only | G |
| **MariaDB 11.4 LTS** (or 10.11 LTS; or MySQL 8.0.11+) as a Windows service, with a root password you know | Server PC only | H |
| A **fixed IP address** for the Server PC and for every Lab PC (DHCP reservation in the router) | all | J, M |
| The Server PC's network set to **Private** | Server PC | J |
| A **Gmail address** for the first CompuLab Administrator (CompuLab accepts only `@gmail.com`) | Server setup | I |
| A **standard (non-administrator)** Windows account for students on each Lab PC, and its name | Lab PCs | M1 |
| A USB stick | copying the setups and each PC's settings file | D, M |
| The correct **date, time and time zone** on the Server PC (UTC+08:00 — reservations depend on it) | Server PC | J |

**Installed automatically by the setups (you do not install these):**

- Server setup: the CompuLab program in `C:\CompuLab`, its own Python packages (included, no internet
  needed), the service wrapper (WinSW), the settings file `.env` with new random secrets, the
  CompuLab database and database user, the first Administrator (with your details), the two Windows
  services **CompuLab Web** and **CompuLab Worker**, the firewall rule **CompuLab Web**, the scheduled
  task **CompuLab nightly backup**, and Start-menu shortcuts.
- Agent setup: the packaged agent `CompuLabAgent.exe` (contains its own Python — none needed on the
  PC) in `C:\Program Files\CompuLab Agent`, the local group **CompuLab Students** (with the accounts
  you enter), the scheduled task **CompuLab Agent**, the firewall rules **CompuLab Agent** and
  **CompuLab ping**, and the data folder `C:\ProgramData\CompuLab Agent`.

**Not needed:** Python on Lab PCs, internet for daily use, email (optional, later), Tailscale,
a cloud receiver, XAMPP.

**The setups never install, upgrade or replace Python or MariaDB/MySQL, and never change XAMPP or
another database.** If one is missing or unsuitable, the server setup stops and says what to do.

---

## D. Identify the correct files

> **PC:** the PC where the release was built (or wherever you received it) · **Administrator:** no

On the build PC the files are in the project folder under `installer\dist\`. Copy **all six** to a
folder on a USB stick, e.g. `E:\CompuLab-<version>\`:

| File | What it is | Needed on |
|---|---|---|
| `CompuLab-Server-Setup-<version>.exe` | server setup | Server PC |
| `CompuLab-Agent-Setup-<version>.exe` | lab PC agent setup | every Lab PC |
| `CompuLab-Agent-Package-<version>.zip` | the same agent as a zip (only a fallback; normally not used) | — |
| `SHA256SUMS-<version>.txt` | the correct SHA-256 fingerprints | with the setups |
| `DISTRIBUTION-MANIFEST-<version>.md` | file list, sizes, hashes, supported Windows | for reference |
| `BUILDINFO-<version>.json` | which source commit was built | for reference |

All six names must contain **the same `<version>`**. Do not mix files of different versions. Open the
manifest (Notepad is fine): "Working tree" must say **clean**. Do not use a build marked "NOT
CLEAN", and do not use 2026.10.23.0537 (it lacks the fixes this guide describes).

---

## E. Verify the SHA-256 hashes (is the file exactly the one that was built?)

A SHA-256 hash is a fingerprint of a file. If even one byte changed (damaged copy, wrong version,
tampering), the fingerprint is completely different. Check every setup **on the computer where you
will run it, after copying it there**. The correct values are in `SHA256SUMS-<version>.txt` and in
the manifest's "Files" table.

> **PC:** the PC that will run the setup · **Administrator:** no · **Where:** the folder holding the files

1. Copy the setup **and** `SHA256SUMS-<version>.txt` into one folder on the local disk, e.g.
   `C:\Users\<you>\Downloads\CompuLab\` (not a network drive — see F).
2. Open that folder in File Explorer. Click the address bar, type `powershell`, press Enter. A
   **normal PowerShell** opens in that folder.
3. **Option 1 — check every file listed in SHA256SUMS automatically.** Replace `<version>`, paste,
   press Enter:

   ```powershell
   Get-Content .\SHA256SUMS-<version>.txt | ForEach-Object { $h, $f = $_ -split '\s+', 2; if (Test-Path $f) { '{0}  {1}' -f $f, $(if ((Get-FileHash $f -Algorithm SHA256).Hash -eq $h) { 'OK' } else { 'MISMATCH' }) } else { "$f  (not in this folder)" } }
   ```

   **Expected:** `OK` after each file in the folder (files you did not copy show "not in this folder").

4. **Option 2 — one file by hand**, in PowerShell:

   ```powershell
   Get-FileHash -Algorithm SHA256 .\CompuLab-Server-Setup-<version>.exe
   ```

   or in PowerShell or Command Prompt:

   ```
   certutil -hashfile CompuLab-Server-Setup-<version>.exe SHA256
   ```

   Compare the long value with the manifest, character by character. Upper/lower case does not
   matter (`Get-FileHash` prints capitals, `certutil` small letters).

**If you see `MISMATCH` or a different value:** do not run the file. Copy it again from the original
`installer\dist` folder and check again. If it still differs, the release is damaged — stop and
obtain it again.

---

## F. The "Windows protected your PC" warning (unsigned setups)

The setups are **not code-signed** (the school has no code-signing certificate yet). Windows
therefore cannot show a publisher name. Handle it per file — **never turn SmartScreen or the
antivirus off**.

> **PC:** the PC that runs the setup · **Administrator:** yes

1. **Hash first.** Only continue if the hash check in section E said **OK** for this file. If you
   skipped it, stop and do it now — the SmartScreen warning is the moment Windows asks you to vouch
   for the file, and the hash is your proof.
2. Double-click the setup. One of these happens:
   - **"Windows protected your PC"** (blue window) → click **More info** → check that "App" shows
     the exact file name, e.g. `CompuLab-Server-Setup-<version>.exe`, and "Publisher" shows
     **Unknown publisher** → click **Run anyway**.
   - No blue window (common for files copied from a USB stick) → continue.
3. Then the **User Account Control** prompt appears: "Do you want to allow this app from an unknown
   publisher to make changes to your device?" → **Yes**. (On a standard account it asks for an
   administrator's user name and password.)

"Run anyway" applies only to this one file. Do **not** change anything under Windows Security → App
& browser control, do not switch off SmartScreen, Smart App Control or the antivirus, and do not
"allow all apps".

**If there is no "Run anyway" button** or a message says the app was **blocked** by your organisation
or by **Smart App Control**: the school's policy blocks unsigned programs. Do not try to get around
it. Ask the school's IT administrator to allow these exact files (by their SHA-256 hash), or to sign
them with the school's code-signing certificate. (After signing, the hashes change; whoever signs
them runs `installer\build\verify-dist.ps1 -Rehash` on the build PC to produce new hash files.)

**Do not run the setups from a mapped network drive** (e.g. `Z:\`). After the administrator prompt,
Windows no longer sees mapped drive letters. Always copy to the local disk first.

---

## J. Fixed IP address and Private network for the Server PC

*(Done before G, H and I, because the server setup asks for this address.)*

The lab PCs find the server by its IP address. It must **never change**.

### J1. Find the Server PC's current IPv4 address and MAC address

> **PC:** Server PC · **Administrator:** no · **Where:** normal PowerShell

1. Connect the Server PC with a network **cable** to the campus network.
2. Type:

   ```powershell
   ipconfig
   ```

   Find the section of the wired adapter (usually **Ethernet adapter Ethernet**). Write down:
   - **IPv4 Address**, e.g. `192.168.1.10`
   - **Default Gateway**, e.g. `192.168.1.1` (the router)
3. Type:

   ```powershell
   Get-NetAdapter | Format-Table Name, Status, MacAddress
   ```

   Write down the **MacAddress** of the adapter with Status **Up**, e.g. `AA-BB-CC-11-22-33`.

**If** there is no IPv4 address starting with `10.`, `172.16.`–`172.31.` or `192.168.`, the PC is not
on the campus network — check the cable. If it starts with `169.254.`, the network gave it no address.

### J2. Reserve the address in the router (DHCP reservation)

> **PC:** any PC · **Administrator:** the router's administrator login

The device that hands out addresses (usually the router, sometimes a school server) must always give
the Server PC the same address.

1. If someone else manages the school network, give them the MAC address and ask for a **DHCP
   reservation** (also called "static lease" or "address reservation") for it. Ask them which
   address it got.
2. If you manage the router yourself: open its web page (often `http://192.168.1.1` — the Default
   Gateway), sign in, find **DHCP** → **Address Reservation** (names differ per brand), add the MAC
   address with the IP address you want (e.g. `192.168.1.10`), save.
3. Restart the Server PC and run `ipconfig` again. **Expected:** the reserved address.

Never set up **port forwarding** on the router for CompuLab: CompuLab must not be reachable from the
internet.

### J3. Set the network to Private

> **PC:** Server PC · **Administrator:** yes

CompuLab's firewall rule only opens the web port on **Private** (or school **Domain**) networks.

1. Start → **Settings** → **Network & internet** → **Ethernet** (Windows 10: Network & Internet →
   Ethernet → click the connection).
2. **Network profile type** → select **Private network**.
3. Check in a **normal PowerShell**:

   ```powershell
   Get-NetConnectionProfile
   ```

   **Expected:** `NetworkCategory : Private` (or `DomainAuthenticated` on a school domain — that is
   fine too, leave it).

**If the setting is greyed out:** use an **elevated PowerShell** (replace `Ethernet` with the
InterfaceAlias shown by `Get-NetConnectionProfile`):

```powershell
Set-NetConnectionProfile -InterfaceAlias 'Ethernet' -NetworkCategory Private
```

### J4. Date, time and time zone

> **PC:** Server PC · **Administrator:** yes

Start → **Settings** → **Time & language** → **Date & time**: time zone **(UTC+08:00) Kuala Lumpur,
Singapore** (the zone Windows uses for the Philippines), **Set time automatically** on. CompuLab
itself always works in Manila time; the Windows clock must be correct because reservations and
automatic locking depend on it.

---

## G. Install Python 3.13 (64-bit, for all users) on the Server PC

The server needs Python. The setup **requires a 64-bit Python 3.11, 3.12 or 3.13; 3.13 is
recommended**. It refuses 3.14, 32-bit Python, and gives a warning for a Python installed "just for
me". Lab PCs do **not** need Python.

> **PC:** Server PC · **Administrator:** yes · **Needs internet:** yes (once)

1. Open `https://www.python.org/downloads/windows/` in a browser.
2. Under **Stable Releases**, find the newest **Python 3.13.x** and click **Windows installer
   (64-bit)**. (Not "32-bit", not "ARM64", not 3.14. If the page pushes a "Python install manager",
   ignore it and use the 3.13 "Windows installer (64-bit)" link — the install manager installs for
   one user only.)
3. Run the downloaded `python-3.13.x-amd64.exe`.
4. On the first screen tick **Use admin privileges when installing py.exe** and **Add python.exe to
   PATH**, then click **Customize installation** (not "Install Now").
5. **Optional Features:** leave everything ticked → **Next**.
6. **Advanced Options:** tick **Install Python 3.13 for all users** (the install location changes to
   `C:\Program Files\Python313`) and **Add Python to environment variables** → **Install** → **Yes**
   to the administrator prompt.
7. "Setup was successful" → **Close**. (You may click "Disable path length limit"; it is not required.)

**Check it** — open a **new** normal PowerShell:

```powershell
py -0p
```

**Expected:** a line with `-V:3.13` and the path `C:\Program Files\Python313\python.exe`.

**If** `py` is "not recognized": the installer was run without the py launcher — run it again,
choose **Modify**, and make sure "py launcher" and "for all users" are ticked. **If** the path is under
`C:\Users\...`: Python was installed for one user only — run the installer again with **Customize
installation** → **Install for all users**.

Another Python version already on the PC (e.g. 3.14) can stay; the setup picks 3.13 itself.

---

## H. Install MariaDB (or check an existing MariaDB/MySQL)

CompuLab stores its data in MariaDB (MySQL works too). The setup **does not install it**; it creates
its own database `compulab_db` and its own database user `compulab` inside the server you install,
and leaves every other database alone.

Supported: **MariaDB 11.4 LTS (recommended)** or 10.11 LTS (any 10.5 or newer), or **MySQL 8.0.11 or
newer** (8.4 LTS). **Not supported:** XAMPP's MariaDB 10.4.

### H1. Check first: is a database server already installed?

> **PC:** Server PC · **Administrator:** no · **Where:** normal PowerShell

```powershell
Get-Service | Where-Object { $_.Name -match 'MariaDB|MySQL' } | Format-Table Name, Status, StartType
Get-NetTCPConnection -LocalPort 3306 -State Listen -ErrorAction SilentlyContinue
```

- **No service, nothing on port 3306** → H2 (install MariaDB on port 3306).
- **A `MariaDB...`/`MySQL...` service that the school installed for CompuLab** → H3.
- **A service named `mysql` that belongs to XAMPP**, or a database another program on this PC uses
  (something listens on 3306) → **do not remove, stop or change it** → H4.

### H2. Install MariaDB 11.4 LTS

> **PC:** Server PC · **Administrator:** yes · **Needs internet:** yes (once)

1. Open `https://mariadb.org/download/` → **MariaDB Server** → version **11.4** (LTS), OS **Windows**,
   architecture **x86_64**, package **MSI** → Download.
2. Run the `.msi`. The screens (wording may differ slightly between versions):
   - License → accept → **Next**.
   - Custom Setup → leave the defaults → **Next**.
   - **Default instance properties:** tick **Modify password for database user 'root'** and type a
     strong root password twice. **Write it down and keep it safe** — the CompuLab setup asks for
     it once. Leave **Enable access from remote machines for 'root' user** **unticked**. Tick **Use
     UTF8 as default server's character set** if offered.
   - Next screen: keep **Install as service** ticked, Service Name **MariaDB**, keep **Enable
     networking** ticked with TCP port **3306** (or the port from H4). CompuLab connects through it
     on this PC itself.
   - **Install** → **Yes** to the administrator prompt → **Finish**.
3. Check (normal PowerShell):

   ```powershell
   Get-Service MariaDB
   ```

   **Expected:** `Status: Running`.

### H3. Check an existing MariaDB/MySQL

> **PC:** Server PC · **Administrator:** no · **Where:** normal PowerShell

Find the version (adjust the folder to what exists under `C:\Program Files`, e.g. `MariaDB 11.4` or
`MySQL\MySQL Server 8.4`):

```powershell
& 'C:\Program Files\MariaDB 11.4\bin\mysql.exe' -u root -p -e 'SELECT VERSION();'
```

Type the root password when asked. **Expected:** e.g. `11.4.x-MariaDB` or `8.4.x`. Version 10.4 or
older (MariaDB) or below 8.0.11 (MySQL) is not supported. If you do not know the root password, stop
and find it — the setup needs it.

If more than one MariaDB/MySQL service exists (other than XAMPP's), the setup uses the one that owns
the database port; if it cannot tell, it asks you (section S, "Several database services").

### H4. Port 3306 is already used (XAMPP or another database)

The setup checks who listens on the database port. If it is XAMPP or a program that is not
MariaDB/MySQL, it **stops without changing anything** and says so. CompuLab never uses, stops or
changes that program. What to do:

1. Best: use another Server PC without XAMPP.
2. Otherwise: install MariaDB 11.4 (H2) and choose a **different port** on its networking screen,
   for example **3307**. Check: `Get-NetTCPConnection -LocalPort 3307 -State Listen` shows a line.
3. In the server setup (section I, step 4), enter **3307** in the **Database port** field.

*Verification status:* a database on a non-standard port is covered by the automatic installer
tests (MySQL 8.4 on a random port). Running next to a real XAMPP on 3306 has not been tested on a
real PC.

---

## I. Run the server setup

> **PC:** Server PC · **Administrator:** yes · **Takes:** 10–20 minutes

Before you start: Python (G) and MariaDB (H) are installed, the Server PC has its fixed IP (J), and
you have the MariaDB root password and a Gmail address for the first Administrator.

1. Copy `CompuLab-Server-Setup-<version>.exe` and `SHA256SUMS-<version>.txt` to
   `C:\Users\<you>\Downloads\CompuLab\` and check the hash (section E).
2. Double-click the setup → SmartScreen / administrator prompt as in section F.
3. **Select Destination Location:** keep `C:\CompuLab` → **Next**. (Only shown on the first install.)
4. **Campus address** page (only shown on the first install):
   - **Campus IP address or computer name:** the Server PC's fixed IP, e.g. `192.168.1.10`. Only the
     address — no `http://`, no `:8000`. (If you leave it empty, the console asks later and lists
     this PC's addresses.)
   - **Port:** keep `8000`.
   - **Database port:** keep `3306` (or the port from H4).
   - **Next.** If a message says "Enter only the address" or "... must be a number", correct it.
5. **Ready to Install** → **Install**. The files are copied to `C:\CompuLab`.
6. A **console window** (black/blue text window) opens and runs the real installation. Watch it.
   Lines starting with `==>` are steps, `OK:` means done, yellow lines are notes. It goes through:

   | Console step | What happens | What you do |
   |---|---|---|
   | Checking Windows and the CompuLab files | | nothing |
   | Checking the settings | validates the address and ports; checks that the backup folder can be written (`backups in C:\CompuLab\backups`) | nothing (or pick the address if you left it empty) |
   | Checking Python | finds Python 3.13 64-bit | nothing |
   | Checking the database server | finds MariaDB and its service, starts it if stopped and sets it to start automatically (and says so); `OK: Port 3306 is served by the MariaDB service` | nothing |
   | Checking the service wrapper (WinSW) | | nothing |
   | Installing the Python environment | creates `C:\CompuLab\venv` from the included packages | wait (a few minutes) |
   | Configuring settings (.env) | creates `C:\CompuLab\.env` with **new random secrets** | nothing |
   | Preparing the database | asks **`MariaDB/MySQL root password (used once, not saved):`** | type the MariaDB root password (nothing appears while typing — that is normal), press **Enter** |
   | Updating the database structure | creates all tables | wait (a few minutes) |
   | Checking the Administrator account | there is none yet on a new installation | nothing |
   | Create the first Administrator account | asks **`Administrator email (@gmail.com)`**, **`Password`**, **`Password (again)`** | see step 7 |
   | Installing the Windows services | creates CompuLab Web and CompuLab Worker | nothing |
   | Opening the firewall for the campus network | creates the rule CompuLab Web | nothing |
   | Scheduling the nightly backup | creates the task CompuLab nightly backup | nothing |
   | Checking that CompuLab answers | waits up to 90 seconds for the website | nothing |

7. **First Administrator account** (this is the CompuLab sign-in, not a Windows account):
   - **Administrator email (@gmail.com):** your Gmail address, e.g. `lab.admin.example@gmail.com`.
     CompuLab accepts only `@gmail.com` addresses (for every account — an application rule).
   - **Password** and **Password (again):** at least 8 characters, not only digits, not a common
     password, not similar to the email. Nothing appears while typing.
   - A problem (not Gmail, passwords different, password too weak) is explained in a yellow line and
     you are asked again (up to four tries).
   - **Expected:** `OK: Administrator account: la***@gmail.com` (the address is shortened on purpose).
   - If it still cannot be created, the console ends with **`Installation stopped: The first
     Administrator account was not created: <reason>`** — nothing is lost: fix the reason and run
     Start → CompuLab → **Repair CompuLab Server** (or the same setup); it asks again. It never
     creates a second Administrator on a Repair or Update.
8. **Expected end of the console:**

   ```
   CompuLab is installed.
     Campus address (lab PCs, staff): http://192.168.1.10:8000
     Server status page (Admins):     http://192.168.1.10:8000/system/status/
   ```

   followed by next steps (including the backup folder) and `Press Enter to close this window`.
   Press **Enter**.
9. The setup shows its last page → **Finish**.

**If the console says `Installation stopped: ...`:** read the line — it says what is wrong. The full
text is in `C:\CompuLab\logs\install-<date-time>.log`. Fix the cause (section S), then run the same
setup again; it continues safely and keeps what was already done.

**About the secrets.** You typed only two secrets: the MariaDB root password (used once, never
saved) and the Administrator password (stored only as a hash; passed to CompuLab without appearing on
screen or in the log). Everything else is generated: `C:\CompuLab\.env` holds the website's secret
key and the `compulab` database user's password, and the **shared agent secret**
(`PC_AGENT_SHARED_SECRET`) kept only for lab PCs from older installations. Each lab PC gets **its own**
agent secret when you download its Agent config (section M4); those are stored in the CompuLab
database. Only Administrators can read `.env`. Do not edit, copy, email or print it.

---

## K. Firewall: only the web port, never the database

> **PC:** Server PC · **Administrator:** yes · **Where:** elevated PowerShell

What the setup created on the **Server PC**:

| Rule | Allows | From | On networks |
|---|---|---|---|
| **CompuLab Web** | TCP port **8000** inbound | private campus/VPN ranges only: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10` | Private, Domain |

The database port is **not opened** by CompuLab. Do not add rules yourself and do not turn the
firewall off.

**K1. Check the CompuLab Web rule (elevated):**

```powershell
Get-NetFirewallRule -DisplayName 'CompuLab Web' | Format-List DisplayName, Enabled, Direction, Action, Profile
Get-NetFirewallRule -DisplayName 'CompuLab Web' | Get-NetFirewallPortFilter | Format-List Protocol, LocalPort
Get-NetFirewallRule -DisplayName 'CompuLab Web' | Get-NetFirewallAddressFilter | Format-List RemoteAddress
```

**Expected:** Enabled `True`, Direction `Inbound`, Action `Allow`, Profile `Private, Domain`, Protocol
`TCP`, LocalPort `8000`, RemoteAddress the four ranges above.

**K2. Check that no rule opens the database port (elevated)** — use `3307` instead of `3306` if H4
applied:

```powershell
Get-NetFirewallPortFilter -Protocol TCP | Where-Object { $_.LocalPort -eq '3306' } | Get-NetFirewallRule | Format-Table DisplayName, Enabled, Direction, Action, Profile
```

**Expected:** no output, or only rules with Enabled `False` or Action `Block`.

**If an enabled inbound Allow rule for the database port is listed** (the MySQL installer creates one
when "Open Windows Firewall ports for network access" was ticked): make sure no program on another
computer uses this database, then **disable** it (it can be re-enabled later; this changes nothing
else about the database):

```powershell
Disable-NetFirewallRule -DisplayName '<the DisplayName shown above>'
```

**K3. Test from a Lab PC** (or any other campus PC) after it is connected — **normal PowerShell**:

```powershell
Test-NetConnection 192.168.1.10 -Port 8000
Test-NetConnection 192.168.1.10 -Port 3306
```

**Expected:** port 8000 → `TcpTestSucceeded : True`; port 3306 → `TcpTestSucceeded : False` (a
warning "TCP connect ... failed" is the good result here).

**K4. Internet:** in the router, make sure there is **no port forwarding** to the Server PC (neither
8000 nor the database port) and none to any lab PC (5555). CompuLab is for the campus network only.

---

## L. Check the server: website, database, services, background work, backups, logs

### L1. The website

> **PC:** any campus PC (and the Server PC) · **Administrator:** no · **Where:** web browser

1. Open `http://192.168.1.10:8000` (your server address). **Expected:** the CompuLab sign-in page.
2. Sign in with the Administrator email and password from step I-7. **Expected:** the Admin
   dashboard with a sidebar (Dashboard, PC power status, PC activity log, Manage labs, User & role
   management, …, System status).
3. Open `http://192.168.1.10:8000/healthz`. **Expected:** the word `ok`.

**If** the page does not open from another PC but does on the server (`http://127.0.0.1:8000`):
network profile (J3) or firewall (K1). **If** it shows "Bad Request (400)": you used an address the
server was not set up for — use exactly the campus address the setup printed.

### L2. System status page

> **PC:** any campus PC · **Administrator:** CompuLab Admin login

Sidebar → **System status**. **Expected:**

- Database **OK**, Background worker **Running**.
- Internet: OK or Unavailable (both fine — CompuLab does not need internet).
- Email: not configured (fine). Cloud: "Cloud synchronization not configured" (correct). Remote
  address (Tailscale VPN): "Not configured" (correct).
- The campus address shown is `http://192.168.1.10:8000`.
- Under "Lab PC agents": "Agent secrets: 0 of 0 PCs ..." until PCs are added (section O).

### L3. Windows services

> **PC:** Server PC · **Administrator:** no · **Where:** normal PowerShell (note: type `sc.exe`, not `sc`)

```powershell
Get-Service CompuLabWeb, CompuLabWorker
sc.exe qc CompuLabWeb
sc.exe qfailure CompuLabWeb
```

**Expected:** both `Running`; `START_TYPE : 2 AUTO_START (DELAYED)`; `DEPENDENCIES : MariaDB` (your
database service name); failure actions `RESTART -- Delay = 10000`, `30000`, `60000` milliseconds.
The same is visible in the **Services** app (Windows key + R → `services.msc`): "CompuLab Web" and
"CompuLab Worker", Status Running, Startup Type **Automatic (Delayed Start)**.

### L4. Whole-server check

> **PC:** Server PC · **Administrator:** yes

Start → CompuLab → **CompuLab Server Status**. If the window says "Without administrator rights
some checks are skipped", press **F** for the full report (Windows shows the normal administrator
prompt → **Yes**) — or **L** for a limited report that marks the skipped lines "needs administrator".
The same full report from an **elevated PowerShell**:

```powershell
powershell -ExecutionPolicy Bypass -File C:\CompuLab\installer\server\server-status.ps1
```

**Expected (full report):** `[OK  ]` on the Windows services, website, campus address, firewall rule,
database, background worker, **Nightly backup task** and (from the next day) **Newest backup**.
`[--  ]` lines are informational (email, cloud sync, Tailscale: "not configured"; Backup folder).
Any `[FAIL]` line says what to check.

### L5. The nightly backup task and the backup folder

> **PC:** Server PC · **Administrator:** yes

Start → type `Task Scheduler` → open it → **Task Scheduler Library** → **CompuLab nightly backup**.
**Expected:** trigger "At 1:30 AM every day", runs as **SYSTEM**; **Actions** shows
`... backup.ps1" -BackupRoot "C:\CompuLab\backups" -Log` (or your folder). The same folder is
written to `.env` as `COMPULAB_BACKUP_ROOT` and shown as "Backup folder" by the status report.
(It is tested in section Q.)

### L6. Logs

All in `C:\CompuLab\logs\` (open with Notepad; administrator rights may be needed):

| File | Contains |
|---|---|
| `install-<date-time>.log` | everything the setup console showed (no passwords) |
| `compulab.log` | the website |
| `worker.log` | background work (lab PC online/offline checks, emails, reminders) |
| `CompuLabWeb.*.log`, `CompuLabWorker.*.log` | the service wrapper (starts/stops/crashes) |
| `backup-<date-time>.log` | each nightly backup and each "Back Up CompuLab Now" |

---

## M. Register the first Lab PC in CompuLab

### M1. Give the Lab PC a fixed IP address and a student account

> **PC:** the Lab PC · **Administrator:** yes (for creating the account)

1. Same as J1–J2: run `ipconfig` and `Get-NetAdapter | Format-Table Name, Status, MacAddress` on the
   Lab PC, reserve its address in the router (e.g. `192.168.1.21`), restart it and confirm with
   `ipconfig`.
2. The Lab PC needs a **standard (non-administrator)** Windows account that students sign in with
   (Settings → Accounts → Other users → Add account; account type **Standard User**). Write down its
   exact **account name** (e.g. `student`; for a school domain account, `DOMAIN\name`). You enter it
   in the agent setup (section O1). Students must never use an administrator account.
3. Check the account type in a normal PowerShell: `Get-LocalGroupMember -SID S-1-5-32-544` lists the
   administrator accounts — the student account must **not** be in that list.

### M2. Create the lab (once per lab)

> **PC:** any campus PC · **Administrator:** CompuLab Admin login · **Where:** browser

Sidebar → **Manage labs** → **Add Laboratory** → Name (e.g. `Computer Lab 1`), Location, opening
and closing time → save. **Expected:** the lab appears as a card.

### M3. Add the PC

Sidebar → **Manage labs** → on the lab's card click **Add PC**:

| Field | What to enter |
|---|---|
| Lab | the lab from M2 |
| PC ID | the name students see on the lock screen, max 10 characters, e.g. `PC-01` |
| IP address | the Lab PC's fixed IP from M1, e.g. `192.168.1.21` (required — the server uses it to reach the PC, and it is part of how the PC's own secret is checked) |
| Status | leave the default |

**Add PC** → **Yes, add**. (Many PCs at once: **Manage labs** → **Import Computers**, with the
template offered on that page.)

### M4. Download this PC's settings file

1. Sidebar → **PC power status** → find the row **PC-01** → in **Actions** click **Agent config**
   (only Admins see this button).
2. The browser downloads **`agent_config.local.json`**. The first download creates **this PC's own
   agent secret**; later downloads give the same one. Save the file on the USB stick **in the same
   folder as** `CompuLab-Agent-Setup-<version>.exe`.
3. The name must be exactly `agent_config.local.json`. If your browser saved it as
   `agent_config.local (1).json`, rename it (or choose it by hand in the setup, section O).

This file contains **this PC's agent secret** — treat it like a password: carry it on the USB stick
only, do not email it, and delete loose copies after installing. A file for one PC does not work on
another PC.

---

## N. The agent settings file `agent_config.local.json`

You normally **do not edit it** — CompuLab generates it correctly. This section explains it so you can
check it. Open it with Notepad (right-click → Open with → Notepad). It looks like this (example values;
your secret is a different, long random text):

```json
{
  "secret": "EXAMPLE-ONLY-not-a-real-secret-0000000000",
  "server_url": "http://192.168.1.10:8000",
  "port": 5555,
  "pc_name": "PC-01",
  "lab_name": "Computer Lab 1",
  "_comment": "CompuLab agent settings for PC-01 (Computer Lab 1). Place next to agent.py (the installer does this). Contains the agent secret: keep it private."
}
```

| Key | Meaning | Comes from | Rules |
|---|---|---|---|
| `secret` | proves that a lock/unlock command really comes from the CompuLab server, and that the PC's messages to the server really come from this PC | **this PC's own secret**, created by the server the first time you click Agent config (stored in the CompuLab database) | accepted only from this PC's IP address; placeholders are refused; never share |
| `server_url` | how the Lab PC reaches the server | the server's campus address (`SITE_URL`, set by the server setup) | must be `http://<server IP>:8000` — no path, no trailing text |
| `port` | the port the agent listens on for commands from the server | `PC_AGENT_PORT` (default 5555) | keep `5555` |
| `pc_name` | name shown on the lock screen until the server answers | the PC ID from M3 | display only |
| `lab_name` | lab shown on the lock screen until the server answers | the lab from M2 | display only |
| `_comment` | a note; ignored | | |

**Check:** `server_url` must show your Server PC's real address. If it shows `http://127.0.0.1:8000`
or an old address, the server was set up with the wrong campus address: fix it on the server
(section R, "Server IP address changed"), then download the file again. Do not hand-edit the
secret.

---

## O. Install the agent on the first Lab PC and check it

### O1. Install

> **PC:** the Lab PC · **Administrator:** yes (sign in with an administrator account) · **Takes:** 5 minutes

1. Copy the folder from the USB stick to the Lab PC, e.g. `C:\Users\<admin>\Downloads\CompuLab\`,
   containing `CompuLab-Agent-Setup-<version>.exe`, `SHA256SUMS-<version>.txt` and
   `agent_config.local.json` side by side.
2. Check the hash (section E).
3. Double-click the setup → SmartScreen / administrator prompt as in section F.
4. **Agent settings — Choose this PC's Agent config file:** the field **Agent config file:** already
   shows `...\agent_config.local.json` (picked up from the same folder). If empty, click **Browse**
   and choose the file. → **Next**.
   *(Leave it empty only when re-installing a PC that already has its settings.)*
5. **Student accounts — Which Windows accounts get the CompuLab lock screen:** in **Student Windows
   accounts** type the account name(s) from M1, separated by commas, e.g. `student`. → **Next**.
   Only these accounts get the lock screen; administrator accounts are refused here and are never
   locked. *(On an update you may leave it empty to keep the PC's current setting.)*
6. **Ready to Install** → **Install**.
7. A console window runs the installation:

   | Console step | Expected |
   |---|---|
   | Checking Windows and the agent files | `OK: Packaged agent (no Python needed): ...` |
   | Checking this PC's agent settings | `OK: Server: http://192.168.1.10:8000, agent port 5555` |
   | Checking which Windows accounts get the lock screen | `OK: Lock screen for the members of 'CompuLab Students' (student accounts given); administrators are not locked` |
   | Installing the agent in C:\Program Files\CompuLab Agent | `OK: Agent files and settings installed` |
   | Preparing the agent data folder | `OK: C:\ProgramData\CompuLab Agent (0 queued event(s) kept)` |
   | Checking the CompuLab server | `OK: Server answers at http://192.168.1.10:8000` |
   | Firewall | `OK: Port 5555 and ping accept the CompuLab server (192.168.1.10) only` |
   | Starting the agent when a student signs in | `OK: Created the local group 'CompuLab Students'`, `OK: Added student to 'CompuLab Students'`, `OK: Scheduled task "CompuLab Agent" registered for 'CompuLab Students': ...` |
   | Testing the installed agent | `OK: Agent 2.2.0 starts, reads its settings and can write its queue; server: answers` |

   It ends with `The CompuLab agent is installed.` and `It starts the next time a student account
   (CompuLab Students) signs in to Windows. Administrators are not locked.`, then `Press Enter to
   close this window` → **Enter** → **Finish**.
8. Delete `agent_config.local.json` from the Downloads folder and from the USB stick (the installed
   copy in `C:\Program Files\CompuLab Agent` is protected: students can read it but not change it).

**If** it stops with `The student accounts are not usable: Windows account 'x' does not exist on this
PC` or `'x' is an administrator account`: correct the name in M1 and run the setup again. **If** it
says `Could not reach http://... right now`: the installation continues, but the Lab PC cannot reach
the server — fix that before going on (section S). **If** it says `Installation stopped: The agent
settings are not usable`: the settings file is wrong or a placeholder — download it again (M4).

### O2. See the lock screen (student) — and no lock screen (administrator)

> **PC:** the Lab PC · **Administrator:** no

1. Sign out of Windows (Start → your name → **Sign out**) and sign in with the **student** account.
2. **Expected:** the full-screen CompuLab lock screen with the PC name, the lab, and **NETWORK:
   Connected**.
3. Press **Ctrl+Alt+Del** → **Sign out**. Sign in with your **administrator** account.
4. **Expected:** the normal Windows desktop, **no** CompuLab lock screen.

**If** NETWORK says **Server offline**: the Lab PC cannot reach the server (section S). **If** no lock
screen appears for the student within a minute: see section S, "Lock screen does not appear". **If**
the administrator gets the lock screen: section S, "Administrator gets the lock screen".

### O3. Check from the server side, and that the agent sends events

> **PC:** any campus PC · **Administrator:** CompuLab Admin login

(Sign in on PC-01 with the student account first.)

1. Sidebar → **PC power status** → **Check now**. **Expected:** PC-01 Status **Available**, the
   **Connection** column shows a recent contact.
2. Sidebar → **System status** → "Lab PC agents" table. **Expected:** PC-01, "Agent last called" a
   few seconds or minutes ago, Agent version **2.2.0**, Queued on PC **0**, **Agent secret: own**
   (the agent has used its own secret once; until then it says "own secret downloaded, agent not yet
   reinstalled").
3. **Unlock from the server:** **PC power status** → **Manual Unlock (Guest)** → Laboratory: your
   lab → Available computer: **PC-01** → Guest Full Name: `Test Guest` → **Unlock for Guest** →
   confirm. **Expected:** within seconds the lock screen on PC-01 disappears; PC power status shows
   PC-01 **In Use**.
4. **Lock from the server:** in the PC-01 row click **Lock** → OK. **Expected:** the lock screen
   returns on PC-01; status becomes **Available** again.
5. Sidebar → **PC activity log**. **Expected:** entries for PC-01 from the unlock and lock you just did.

### O4. Check on the Lab PC itself

> **PC:** the Lab PC (signed in as administrator) · **Administrator:** no for the report · **Where:** normal PowerShell

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Program Files\CompuLab Agent\tools\agent-status.ps1"
```

**Expected:** `Server address : http://192.168.1.10:8000`, `Start-up task : Ready` or `Running`,
`Lock screen for : members of 'CompuLab Students': <PC>\student`, a recent `Last contact`,
`Queued events : 0`, `Live check : server answers`. (Double-clicking
`C:\Program Files\CompuLab Agent\tools\Agent Status.cmd` shows the same.)

---

## P. Install agents on more Lab PCs

Only after section Q passed on the first Lab PC. For **each** additional PC:

1. Fixed IP in the router and a standard student account (M1).
2. **Add PC** in CompuLab with its own PC ID and IP (M3).
3. **Agent config** for **that** PC (M4) — every PC needs its own file (its own secret). Keep the
   files apart, e.g. one USB folder per PC, each named `agent_config.local.json`.
4. Install with the student account name (O1), sign in as student (O2), **Check now** in PC power
   status (O3-1).

**Many PCs silently** (optional, from an **elevated Command Prompt** on each PC, after copying the
files to it):

```
C:\Setup\CompuLab-Agent-Setup-<version>.exe /VERYSILENT /CONFIG="C:\Setup\agent_config.local.json" /STUDENTS="student"
```

No windows appear; the result is in `C:\ProgramData\CompuLab Agent\install-<date-time>.log`.
Without `/STUDENTS` on a new installation the log says `No student account given` and nothing is
installed. Check each PC in **PC power status** afterwards.

---

## Q. Tests for the first installation (the real proof)

Do all of these during the supervised installation, **before** entering real school data. Write the
result into the checklist in section T. These are exactly the behaviours that could not be tested
without real machines.

### Q1. Server restarts by itself

> **PC:** Server PC, then any campus PC · **Administrator:** yes

1. Restart the Server PC. **Do not sign in** to Windows on it.
2. Wait 3 minutes (the services start "delayed", about 2 minutes after boot).
3. From another PC open `http://192.168.1.10:8000`.

**Expected:** the sign-in page; System status shows Database OK and Background worker Running.
**If not:** sign in on the server, run L4 and look at `C:\CompuLab\logs\CompuLabWeb.*.log`.

### Q2. Website recovers after a crash (optional but recommended)

> **PC:** Server PC · **Administrator:** yes

Task Manager (Ctrl+Shift+Esc) → **Details** → right-click **waitress-serve.exe** → **End task**.
**Expected:** within about a minute `http://192.168.1.10:8000` answers again.

### Q3. Lab PC after a restart

Restart the Lab PC, sign in as student. **Expected:** lock screen, NETWORK Connected, PC power status
**Available** after **Check now**. Then sign in as administrator: no lock screen.

### Q4. Agent comes back after being closed

> **PC:** the Lab PC, signed in as the student · **Administrator:** no

While the lock screen is shown, Task Manager is disabled on purpose. So:

1. Unlock PC-01 with **Manual Unlock (Guest)** (O3-3).
2. On PC-01 (still the student's session) open Task Manager (Ctrl+Shift+Esc) → **Details** →
   **CompuLabAgent.exe** → **End task**.
3. Wait up to 2 minutes.

**Expected:** the CompuLab lock screen appears again by itself (the start-up task re-checks every
minute). **If not:** sign in as administrator, Task Scheduler → **CompuLab Agent** → Triggers must
say "At log on of any user" with "repeat every 1 minute indefinitely" and the task's user must be
"CompuLab Students"; write the result in T — this is one of the unverified behaviours.

### Q5. Lock and unlock

Done in O3-3 and O3-4. Optional: create a real reservation for a test student and unlock PC-01 on
its lock screen with **Student ID + Reservation Code** (see `docs\MANUAL_VERIFICATION.md`, scenario 2).

### Q6. Lab PC network outage and recovery

> **PC:** the Lab PC and any campus PC

1. Unlock PC-01 (Manual Unlock (Guest)).
2. Unplug PC-01's network cable.
3. On PC-01 click **🔒 Lock Now** (small panel on the screen). **Expected:** the lock screen shows
   **NETWORK: Server offline · 1 queued** and a message that sign-in needs the server.
4. Wait a minute, plug the cable back in. Wait up to 30 seconds.

**Expected:** NETWORK returns to **Connected**; `agent-status.ps1` (O4) shows `Queued events : 0`;
PC power status shows PC-01 **Available**; PC activity log has **one** lock entry for that session.
(More scenarios, including the server's internet outage: `docs\MANUAL_VERIFICATION.md`.)

### Q7. Backup works (nightly task and "Back Up CompuLab Now")

> **PC:** Server PC · **Administrator:** yes

1. Task Scheduler → **Task Scheduler Library** → right-click **CompuLab nightly backup** → **Run**.
2. Wait 1–2 minutes, press **F5** (refresh).
3. Start → CompuLab → **Back Up CompuLab Now** → **Yes**. The window shows `Backup folder: <folder>`
   and ends with `Backup saved in <folder>\compulab-<date>-<time>`.

**Expected:**
- **Last Run Result:** "The operation completed successfully. (0x0)".
- Two new folders `compulab-<date>-<time>\` **in the same backup folder** (`C:\CompuLab\backups`
  unless you chose another), each with `database.sql`, `env.txt` (and `media.zip` once photos/files
  were uploaded).
- `C:\CompuLab\logs\backup-<date-time>.log` (one per run) ends with `Done. Backups kept: ...`.

**If** the result is `(0x1)` or the window says `The backup FAILED`: open the newest `backup-*.log`;
the line `Backup FAILED: ...` says why. Check again the next morning that the 1:30 AM run also
succeeded.

`env.txt` in each backup contains the server's secrets: keep backups private.

### Q8. Restore works (do this now, while there is no real data)

> **PC:** Server PC · **Administrator:** yes · **Where:** elevated PowerShell

1. Make sure Q7 produced a backup. Note its folder, e.g. `C:\CompuLab\backups\compulab-20261024-093000`.
2. In CompuLab create a test lab named `Restore test` (Manage labs → Add Laboratory).
3. In the elevated PowerShell (use your folder):

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\CompuLab\installer\server\restore.ps1 -BackupFolder C:\CompuLab\backups\compulab-20261024-093000
   ```

4. It warns that the current data will be replaced and asks `Type RESTORE to continue` → type
   `RESTORE` → Enter.

**Expected:** "Safety backup of the current data", "Database restored", "CompuLab is running again".
In CompuLab the lab `Restore test` is gone (it was created after the backup). A safety copy of the
data before the restore is in `<backup folder>\before-restore\`.

### Q9. IT recovery of a locked lab PC

> **PC:** the Lab PC · **Administrator:** yes

1. Sign in on PC-01 as the student (lock screen shows).
2. Press **Ctrl+Alt+Del** → **Switch user** (or **Sign out**) → sign in with an administrator
   account. **Expected:** normal desktop, no lock screen — this is how IT reaches a locked PC, also
   when the server is down.
3. *Optional, untested so far:* the emergency page. On the **Server PC** open
   `C:\CompuLab\lab_pc_agent\manual_unlock.html` in a browser, enter PC-01's IP, port 5555 and
   PC-01's agent secret (from its `agent_config.local.json`: download it again from **PC power status
   → Agent config**, read the `secret` line, then delete the file), click unlock. Write down whether
   it unlocked PC-01. It cannot work from any other computer.

---

## R. Repair, update, back up, restore, uninstall — keeping the data

All server data lives in `C:\CompuLab` (`.env`, `media\`, `logs\`), the backup folder, and the
MariaDB database `compulab_db`. Lab PC data lives in `C:\Program Files\CompuLab Agent`
(`agent_config.local.json`) and `C:\ProgramData\CompuLab Agent` (queued events). None of the actions
below deletes them.

| Task | PC / rights | How | Notes |
|---|---|---|---|
| **Repair the server** | Server, admin | Start → CompuLab → **Repair CompuLab Server** (or run the same server setup again) | keeps settings, secrets, data, the database port and the **backup folder**; backs up first; checks the Administrator (asks for one only if none works; never a second one) |
| **Update the server** | Server, admin | check the hash, run the newer `CompuLab-Server-Setup-<version>.exe` | stops the services, backs up (to the backup folder), updates the database, starts the services; address page is skipped; same things kept as Repair. If it stops, the console says the services are stopped until it completes |
| **Back up now** | Server, admin | Start → CompuLab → **Back Up CompuLab Now** | writes to the **configured backup folder** (same as nightly) and `logs\backup-*.log`; shows where |
| **Choose another backup folder** (e.g. a second disk) | Server, admin, elevated PowerShell | `powershell -ExecutionPolicy Bypass -File C:\CompuLab\installer\server\install-server.ps1 -BackupRoot E:\CompuLabBackups` | runs a full repair once (the website stops for a minute); from then on nightly, manual, Repair/Update and restore use `E:\CompuLabBackups`. It refuses a folder it cannot write to. Old backups stay where they are |
| **Copy backups off the server** | Server, admin | copy the newest `compulab-*` folder to a USB drive regularly | contains secrets: keep private |
| **Restore** | Server, admin, elevated PowerShell | `restore.ps1 -BackupFolder <folder>` as in Q8 | replaces the current data; a safety copy is made first |
| **Server IP address changed** | Server, admin, elevated PowerShell | `powershell -ExecutionPolicy Bypass -File C:\CompuLab\installer\server\set-server-address.ps1 -Primary 192.168.1.10`, then on **every** Lab PC (elevated): `powershell -ExecutionPolicy Bypass -File "C:\Program Files\CompuLab Agent\tools\set-agent-server.ps1" -ServerUrl http://192.168.1.10:8000` | better: keep the reservation so it never changes |
| **Repair / update a Lab PC** | Lab PC, admin | run the (newer) agent setup; leave **Agent config file** and **Student accounts** empty | keeps the PC's settings, its own secret, the student accounts and queued events |
| **Add or change student accounts on a Lab PC** | Lab PC, admin | run the agent setup again with the account(s) in **Student accounts**, or in an elevated Command Prompt: `net localgroup "CompuLab Students" student2 /add` | takes effect at that account's next sign-in. A PC updated from an older agent locks every account until this is done once |
| **Replace a Lab PC's secret** (e.g. the PC was stolen or tampered with) | Server, admin, elevated PowerShell in `C:\CompuLab` | `venv\Scripts\python manage.py agent_secret` (list, shows each PC's id) then `venv\Scripts\python manage.py agent_secret --rotate <id>` | that PC's agent is refused until you download its Agent config again and re-run the agent setup on it. Secrets are never printed |
| **Switch off the old shared secret** | Server, admin | when System status says every PC uses its own secret: add `PC_AGENT_REQUIRE_PER_PC_SECRET=True` to `C:\CompuLab\.env` (Notepad as administrator), then restart CompuLab Web and CompuLab Worker | PCs still on the shared secret stop working, so check the table first |
| **Send queued events now** | Lab PC, no admin needed | in a Command Prompt: `start /wait "" "C:\Program Files\CompuLab Agent\CompuLabAgent.exe" --flush` then `echo %errorlevel%` | 0 = all sent, 2 = server still unreachable (events kept). The agent also does this by itself |
| **Uninstall the agent** | Lab PC, admin | Settings → Apps → **CompuLab Agent** → Uninstall | removes task, firewall rules, program **and this PC's settings file**; keeps `C:\ProgramData\CompuLab Agent` (queued events) and the **CompuLab Students** group. To reinstall, download its **Agent config** again |
| **Uninstall the server** | Server, admin | Settings → Apps → **CompuLab Server** → Uninstall | removes services, firewall rule, backup task and program files; **keeps** the database, `.env`, uploads, backups and logs. Removing those too is a separate manual step (`installer\server\README.md`) — only after a final backup |
| **Optional email** | Server, admin, elevated PowerShell | `powershell -ExecutionPolicy Bypass -File C:\CompuLab\installer\server\configure-email.ps1` | not needed for the first installation; use a Gmail **App Password** |

Never uninstall or "clean up" MariaDB to fix a CompuLab problem: the data is in it.

### What a backup contains — and what is kept elsewhere

| Item | Where it lives | In the server backup? | How it is preserved |
|---|---|---|---|
| Database (accounts, labs, PCs, **each PC's own agent secret**, reservations, logs) | MariaDB `compulab_db` | yes: `database.sql` | restore with `restore.ps1` |
| Uploaded files (photos, spreadsheets) | `C:\CompuLab\media` | yes: `media.zip` | restore with `restore.ps1` |
| Settings and secrets (`.env`: secret key, database password and port, shared agent secret, backup folder) | `C:\CompuLab\.env` | yes: `env.txt` (a copy) | kept by Repair/Update/Uninstall. `restore.ps1` does **not** apply `env.txt` (it is never applied automatically) — on the same server the existing `.env` stays |
| Program, Python environment, static files | `C:\CompuLab` | no | recreated by Repair / the setup |
| Each lab PC's settings (`agent_config.local.json`) | `C:\Program Files\CompuLab Agent` on the lab PC | no (but its secret is in the database) | kept by agent Repair/Update; downloaded again any time from **PC power status → Agent config** (same secret) |
| Each lab PC's student accounts | the local group **CompuLab Students** on the lab PC | no | kept by agent Repair/Update/Uninstall |
| Each lab PC's queued events | `C:\ProgramData\CompuLab Agent` on the lab PC | no | kept by agent Repair/Update/Uninstall; sent automatically when the server answers |

**Restoring onto a new server computer:** install the server there (sections G–I), then `restore.ps1`
with the latest backup. The lab PCs' own secrets come back with the database, so PCs that use their
own secret keep working. PCs still on the old shared secret need `PC_AGENT_SHARED_SECRET` copied from
`env.txt` into the new `C:\CompuLab\.env` (Notepad as administrator; then restart both services) — or
download their Agent config again and re-run the agent setup. Give the new server the old IP address.
Details: `installer\server\README.md`, "Moving to a new server computer".

### How the lab PC lockdown works — and what it does not do

Source-code reviewed, partly tested automatically, **not yet tested on real lab PCs**:

- The lock screen runs in the signed-in **student's** session (it must: a Windows service cannot show
  a window there). The start-up task starts it for members of **CompuLab Students** at sign-in and
  brings it back within about a minute if it is closed.
- While locked it blocks the Windows key, Alt+Tab, Alt+Esc and Ctrl+Esc, and Task Manager is
  disabled for that student.
- **Ctrl+Alt+Del cannot be blocked by any program** (Windows reserves it). From there a student can
  sign out, lock or switch user — none of that opens CompuLab: signing in again shows the lock screen,
  and another account needs its own password.
- Students cannot change the agent's settings or the start-up task (standard accounts).
- While a PC is unlocked for a student, the student can close the agent; it comes back locked within
  about a minute (Q4).
- Optional, **not configured or tested by CompuLab**: Windows offers stronger kiosk lockdowns —
  *Assigned Access / kiosk mode* (Windows 10/11 Pro, Education, Enterprise: one app only, not suitable
  for normal lab work) and *Shell Launcher* (Enterprise/Education). Group Policy "Hide entry points
  for Fast User Switching" (Pro/Education/Enterprise) affects every account on the PC. Ask IT before
  using any of these, and never remove administrators' access.

---

## S. Troubleshooting

| What you see | Where | Likely cause | What to do |
|---|---|---|---|
| Hash `MISMATCH` / different value | E | damaged or wrong file | copy again from `installer\dist`; never run it |
| No "Run anyway", "blocked by your organization" or Smart App Control | F | policy blocks unsigned programs | ask IT to allow the files by hash or sign them; do not disable protection |
| `The install folder ... is a junction or symbolic link` | server/agent setup | unusual install folder | keep the default folder `C:\CompuLab` |
| `Installation stopped: A 64-bit Python 3.13 (or 3.12 / 3.11) is required. Found instead: ...` | server console | no Python, 32-bit Python, or only 3.14 | install Python as in G, run the setup again |
| Note `This Python is installed for one Windows account only` | server console | "Install Now" was used | works, but reinstall Python "for all users" (G) and run **Repair** |
| `No MariaDB or MySQL database server was found` | server console | MariaDB not installed | H2, then run the setup again |
| `No database server is listening on port 3306 of this computer` | server console | MariaDB stopped, or it uses another port | `Get-Service MariaDB` must be Running; if it uses another port, run the setup again with that **Database port** (first install) or, elevated: `powershell -ExecutionPolicy Bypass -File C:\CompuLab\installer\server\install-server.ps1 -DbPort 3307` |
| `Port 3306 is used by XAMPP's database (...)` | server console | XAMPP on 3306 | nothing was changed. H4: MariaDB on another port, enter that **Database port** |
| `Port 3306 is used by '...', which is not a MariaDB/MySQL server` | server console | another program on the port | free the port, or use another port as in H4 |
| `Port 3306 belongs to the service 'X', not to 'Y'` | server console | the service given does not own the port | run the setup with `-DbServiceName X` (elevated PowerShell, as above) |
| `No password was given, but the database server needs one for 'root'` (asked again, up to 3 times) | server console | Enter was pressed with nothing typed, or the typing went to another window | click into the black window, type the root password (a `*` appears for each character), press Enter |
| `The password for 'root' was not accepted` (asked again, up to 3 times) | server console | wrong root password | type the right one; test it alone first: `& "C:\Program Files\MariaDB 11.4\bin\mysql.exe" -u root -p -h 127.0.0.1 -P 3306 -e "SELECT VERSION();"` |
| `Could not sign in to the database server as root. No database server answered on 127.0.0.1:3306` | server console | MariaDB stopped, or it uses another port | `Get-Service MariaDB` must be Running; the line ends with the database server's own message (`Database server said: ...`) |
| `The existing .env (...) has no DB_NAME, DB_USER, DB_PASSWORD ...` | server console | the setup was started in a folder whose `.env` was not made by this installer (for example a developer copy of CompuLab) | nothing was changed. Install into an empty folder (the setup's default `C:\CompuLab`) |
| Note `The existing Python environment (venv) is not reused: it uses Python 3.11 ...` | server console | the folder had a Python environment made with another Python | nothing to do: it is moved to `venv.old-<date>` and a new one is made; delete `venv.old-...` once CompuLab works |
| `MariaDB 10.4.x is too old ...` | server console | an old MariaDB answers on the port | H4 (use MariaDB 11.4 on another port) |
| `Several database services are installed (...)` | server console | more than one MariaDB/MySQL service and none owns the port | elevated PowerShell: `powershell -ExecutionPolicy Bypass -File C:\CompuLab\installer\server\install-server.ps1 -DbServiceName MariaDB` (the name of the right service) |
| `DbName cannot be changed on an existing installation` | server console | a different database name was given on a repair | leave `-DbName`/`-DbUser` out; to move data use backup/restore |
| `Port 8000 is already used by '<program>'` | server console | another program uses port 8000 | stop that program, or ask for help to use another port |
| `Installing packages failed` | server console | the offline packages did not fit this Python | make sure it is Python 3.13 64-bit (G), run the setup again |
| Yellow note `... is not a @gmail.com address` and the question again | server console | non-Gmail address | type a Gmail address |
| `Installation stopped: The first Administrator account was not created: ...` | server console | details refused four times, or (unattended) missing `DJANGO_SUPERUSER_EMAIL`/`PASSWORD` | Start → CompuLab → **Repair CompuLab Server**; it asks again |
| `Installation stopped` after an update, and "The CompuLab services are stopped" | server console | the update could not finish | fix the cause shown, run the setup again; the site is offline until then |
| `Cannot write to the backup folder ...` / `Drive E: ... does not exist` | server console or backup log | backup disk missing or no permission | plug the disk in, or choose another folder with `-BackupRoot` (R) |
| Site opens on the server but not from other PCs | browser | network is Public, firewall rule missing, wrong IP | J3, K1, L4; `Test-NetConnection 192.168.1.10 -Port 8000` from the other PC |
| "Bad Request (400)" or "Forbidden (403) CSRF" in the browser | browser | opened with an address the server was not set up for, or the server IP changed | use the printed campus address; if the IP changed: `set-server-address.ps1` (R) |
| System status: Background worker **not running** | System status | CompuLab Worker service stopped | Services app → CompuLab Worker → Start; read `logs\worker.log` |
| Status report lines say `needs administrator` | CompuLab Server Status | limited report (L was pressed, or no admin rights) | run it again and press **F** |
| Backup **Last Run Result (0x1)** / "The backup FAILED" | Task Scheduler / Back Up Now | backup failed | newest `<C:\CompuLab>\logs\backup-*.log`, line `Backup FAILED:` |
| Status report: `the task writes to X` (Task backup folder FAIL) | CompuLab Server Status | the task and `.env` disagree (e.g. edited by hand) | run the `-BackupRoot` command (R) with the folder you want |
| Agent setup: `The agent settings are not usable: secret is missing or still a placeholder` | Lab PC console | sample or edited settings file | download **Agent config** again (M4) |
| Agent setup: `No student account given` | Lab PC console / install log | the Student accounts field was empty on a new installation (or `/STUDENTS` missing) | run the setup again and enter the account(s) |
| Agent setup: `Windows account 'x' does not exist on this PC` / `'x' is an administrator account` | Lab PC console | wrong name, or an admin account | M1: create/check the standard account, run the setup again |
| Agent setup: `Could not reach http://... right now` | Lab PC console | server off, wrong `server_url`, firewall | check from the Lab PC: `Test-NetConnection 192.168.1.10 -Port 8000`; then L1/K |
| Lock screen shows **Server offline** | Lab PC | Lab PC cannot reach the server | cable, server running, `agent-status.ps1` (O4) |
| PC power status: `rejected the request: its agent secret does not match` | browser | the PC has an old settings file, or its secret was rotated | download its **Agent config** again and re-run the agent setup on that PC |
| PC stays **Offline** in PC power status | browser | wrong IP in Add PC, agent not running, agent firewall rule missing | Manage labs → PC → Edit (IP); sign in on the Lab PC as student; `agent-status.ps1` → "Firewall rule"; **Check now** |
| Lock screen does not appear after a student signs in | Lab PC | account not in CompuLab Students, start-up task missing, or agent failing | `agent-status.ps1` → "Lock screen for" (is the account listed?) and "Start-up task"; add the account (R); sign the student out and in again |
| Administrator gets the lock screen | Lab PC | an older agent setting (every account), or an admin account was added to the group | `agent-status.ps1` → "Lock screen for"; run the agent setup again with the student account(s); remove admins from CompuLab Students (`net localgroup "CompuLab Students" <name> /delete`, elevated) |
| A student session is locked and the server is down | Lab PC | expected: unlocking needs the server | IT: Ctrl+Alt+Del → Switch user → administrator account (Q9). The emergency page (Server PC only, untested) is optional |
| Installed agent self-test failed | Lab PC console | settings or data folder problem | the line says which; run the agent setup again |

Still stuck: collect `C:\CompuLab\logs\install-*.log` (server) or
`C:\ProgramData\CompuLab Agent\install-*.log` (Lab PC). They contain no passwords, but check before
sharing them.

---

## T. Final acceptance checklist (print this page)

Date: ____________  Done by: ______________________  Release: ______________ (not 2026.10.23.0537)

Server PC name/IP: ______________________  Lab PC tested: ______________________

| # | Check | Section | OK? | Notes |
|---|---|---|---|---|
| 1 | The warning checklist (top of this guide) was read and ticked | top | ☐ | |
| 2 | Manifest says "clean"; hashes of both setups say OK | D, E | ☐ | |
| 3 | Server has a fixed IP (reservation), network Private, correct time zone | J | ☐ | |
| 4 | `py -0p` shows Python 3.13 64-bit in `C:\Program Files\Python313` | G | ☐ | |
| 5 | MariaDB/MySQL service Running, supported version, root password known; database port noted | H | ☐ | |
| 6 | Server setup ended with "CompuLab is installed." and `OK: Administrator account:` | I | ☐ | |
| 7 | Administrator can sign in at `http://<server>:8000` from another PC | L1 | ☐ | |
| 8 | System status: Database OK, Background worker Running | L2 | ☐ | |
| 9 | Services Running, Automatic (Delayed Start), restart actions set | L3 | ☐ | |
| 10 | Full status report (F) shows no [FAIL] | L4 | ☐ | |
| 11 | Backup task action and "Backup folder" show the same folder | L5 | ☐ | |
| 12 | Firewall rule CompuLab Web: TCP 8000, campus ranges, Private/Domain | K1 | ☐ | |
| 13 | No open rule for the database port; from a Lab PC port 3306 fails, 8000 succeeds | K2, K3 | ☐ | |
| 14 | No port forwarding on the router | K4 | ☐ | |
| 15 | Lab PC registered with fixed IP; standard student account exists; Agent config downloaded | M | ☐ | |
| 16 | Agent setup ended with "The CompuLab agent is installed." and self-test "server: answers" | O1 | ☐ | |
| 17 | Student sign-in shows the lock screen, NETWORK Connected | O2 | ☐ | |
| 18 | Administrator sign-in on the Lab PC: **no** lock screen | O2 | ☐ | |
| 19 | PC power status: Available; System status: agent 2.2.0, recent contact, Agent secret "own" | O3 | ☐ | |
| 20 | Manual Unlock (Guest) unlocks; Lock locks; activity log shows both | O3 | ☐ | |
| 21 | Server restart: site back within ~3 minutes without signing in | Q1 | ☐ | |
| 22 | Ended waitress-serve.exe: site back within ~1 minute | Q2 | ☐ | |
| 23 | Lab PC restart: lock screen at student sign-in, none for the administrator | Q3 | ☐ | |
| 24 | Ended CompuLabAgent.exe in the student session: lock screen back within ~2 minutes | Q4 | ☐ | |
| 25 | Cable unplugged: "Server offline · 1 queued"; reconnected: delivered once | Q6 | ☐ | |
| 26 | Backup task and Back Up CompuLab Now: result 0x0, both in the same folder, logs "Done" | Q7 | ☐ | |
| 27 | Next morning's 1:30 AM backup also succeeded | Q7 | ☐ | |
| 28 | Restore test: "Restore test" lab gone after restore | Q8 | ☐ | |
| 29 | IT recovery: Switch user to an administrator on a locked PC works | Q9 | ☐ | |
| 30 | Emergency page on the Server PC unlocks PC-01 (record the result either way) | Q9 | ☐ | |
| 31 | Students cannot change `agent_config.local.json`; loose copies deleted; root password stored safely | O1, H | ☐ | |

When every row is ticked, also tick the matching rows in `docs\RELEASE_READINESS.md` (section 2).
Only then can the installers be called tested on real school computers.
