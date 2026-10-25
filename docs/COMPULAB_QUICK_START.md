# CompuLab quick start — first supervised installation

Tick each step in order. Every step links to the full explanation in
[COMPULAB_BEGINNER_INSTALLATION_GUIDE.md](COMPULAB_BEGINNER_INSTALLATION_GUIDE.md) (section letter in
brackets). Example addresses: server `192.168.1.10`, lab PC `192.168.1.21` — use your own.
`<version>` is the release number in the setup file names.

> **Use a new build.** Release 2026.10.23.0537 does **not** contain the fixes this checklist relies
> on (student-only lock screen, own secret per PC, kept backup folder, database port field, verified
> Administrator). Install the setups of a newer, clean build.
>
> The administrator-level behaviour (services, firewall, scheduled tasks, student group, lock screen,
> reboots, outages) has **not yet been tested on real school computers**. This installation is that
> test: do it on **one server and one lab PC** first, before real data.

## ⚠ Know these limits before running any installer

Read the full list in the guide ("First-install warning checklist") and tick it. In short:

- [ ] Not yet validated on real school PCs — the tests at the end of this list are the first real ones.
- [ ] Only the **student accounts** you enter get the lock screen (group **CompuLab Students**);
      administrators are never locked. A PC updated from an older agent locks every account until
      you enter the student accounts once.
- [ ] Staff open a locked student session with **PC power status** → **Manual Unlock (Guest)**; IT can
      also sign in with an administrator account.
- [ ] The emergency unlock page is **untested** and works **only from the Server PC**.
- [ ] **Setups with a bundled runtime** (manifest: "Bundled runtime: MariaDB 11.4.13 and Python
      3.13.16") bring their own Python and **their own database** (service `CompuLabMariaDB`, port
      **3308** or the next free one, 127.0.0.1 only): skip steps 5–6, no root password. Any MySQL,
      MariaDB or XAMPP already on the PC is never touched. *Older setups:* database port 3306 unless
      you enter another; with XAMPP on 3306 install MariaDB on another port (e.g. 3307).
- [ ] The first Administrator must be **@gmail.com**; if it cannot be created the setup **stops**
      (never a false "installed") — run **Repair CompuLab Server**.
- [ ] Backups go to one remembered folder: nightly, **Back Up CompuLab Now**, Repair, Update, restore.
- [ ] Each lab PC's `agent_config.local.json` holds **that PC's own secret**: keep it private.
- [ ] Students use **standard** Windows accounts. **No** router port forwarding, ever.
- [ ] Tailscale is **not configured**; cloud sync is **off** (a receiver exists in the code but is not
      deployed; the internet CompuLab site is a separate installation, nothing syncs with it). Leave
      both alone.
- [ ] Hash check first, then SmartScreen *Run anyway* for that file only; never turn SmartScreen off.

## Before the day

- [ ] Choose the **Server PC**: Windows 11 64-bit (or Windows Server 2016+), 8 GB RAM, wired network,
      always on, preferably no XAMPP or other database on it. [B]
- [ ] Have: an administrator account on every PC, a **Gmail address** for the first CompuLab
      Administrator, a USB stick, access to the router (or the network administrator). [C]
- [ ] Copy the six release files of the new build from `installer\dist\` to the USB stick:
      `CompuLab-Server-Setup-<version>.exe`, `CompuLab-Agent-Setup-<version>.exe`,
      `CompuLab-Agent-Package-<version>.zip`, `SHA256SUMS-<version>.txt`,
      `DISTRIBUTION-MANIFEST-<version>.md`, `BUILDINFO-<version>.json`. The manifest must say
      "clean". [D]
- [ ] Print the acceptance checklist (section T of the guide).

## Server PC

1. - [ ] Plug in the network cable. `ipconfig` → note the IPv4 address; `Get-NetAdapter` → note the
         MAC address. [J1]
2. - [ ] Reserve that IP for this MAC in the router (DHCP reservation); restart; `ipconfig` shows it. [J2]
3. - [ ] Settings → Network → Ethernet → **Private network**. [J3]
4. - [ ] Settings → Time & language → time zone (UTC+08:00) Kuala Lumpur, Singapore; set time automatically. [J4]
   - [ ] Note the database services already on the PC (compare after step 10): [L7]
         `Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'mysqld|mariadbd' } | Format-Table Name, State, ProcessId`
5. - [ ] *Older setups only:* install **Python 3.13 64-bit** from python.org: *Customize installation* → **Install for all
         users** + **Add Python to environment variables**. Check: `py -0p` shows
         `C:\Program Files\Python313\python.exe`. [G]
6. - [ ] *Older setups only:* check for an existing database (`Get-Service ... MariaDB|MySQL`, port 3306). Install **MariaDB
         11.4 LTS** (MSI): set and **write down the root password**, keep *Install as service* (name
         `MariaDB`) and *Enable networking* (port 3306 — or 3307 if XAMPP uses 3306). Check:
         `Get-Service MariaDB` → Running. [H]
7. - [ ] Copy `CompuLab-Server-Setup-<version>.exe` + `SHA256SUMS-<version>.txt` to the local disk;
         hash check → **OK**. [E]
8. - [ ] Run the setup (SmartScreen: *More info* → *Run anyway* only after the hash matched;
         administrator prompt: *Yes*). [F]
9. - [ ] Folder `C:\CompuLab`; campus address `192.168.1.10`; port `8000`; database port `3308`
         (older setups: `3306` or yours); Install. [I]
10. - [ ] Console: (older setups: type the **MariaDB root password**); create the Administrator
          (**@gmail.com** email + password, typed twice). Expect `OK: CompuLab's own database: ...
          port 3308 on 127.0.0.1 only`, `OK: Administrator account: ...` and **"CompuLab is
          installed."** → Enter → Finish. Then repeat the database-services check: unchanged, plus
          `CompuLabMariaDB`. [I, L7]
11. - [ ] From another PC: `http://192.168.1.10:8000` → sign in. **System status**: Database OK,
          Background worker Running. [L1, L2]
12. - [ ] Start → CompuLab → **CompuLab Server Status** → **F** (full report) → no `[FAIL]`. [L4]
13. - [ ] Task Scheduler → **CompuLab nightly backup** → Actions show the backup folder. [L5]
14. - [ ] Firewall: rule **CompuLab Web** = TCP 8000, campus ranges, Private/Domain; **no** open rule
          for the database port; no port forwarding on the router. [K]

## First lab PC

15. - [ ] Fixed IP for the lab PC (router reservation); a **standard** Windows account for students —
          note its name (e.g. `student`). [M1]
16. - [ ] CompuLab → **Manage labs** → **Add Laboratory**; then **Add PC** (PC ID `PC-01`, IP
          `192.168.1.21`). [M2, M3]
17. - [ ] **PC power status** → row PC-01 → **Agent config** → save `agent_config.local.json` (this PC's
          own secret) next to the agent setup on the USB stick. [M4, N]
18. - [ ] On the lab PC (administrator account): copy setup + `SHA256SUMS` + `agent_config.local.json`
          into one local folder; hash check → OK. [E, O1]
19. - [ ] Run `CompuLab-Agent-Setup-<version>.exe` → config file is filled in → **Student Windows
          accounts**: `student` → Install → **"The CompuLab agent is installed."**, self-test "server:
          answers". Delete loose copies of the config file. [O1]
20. - [ ] From a campus PC: `Test-NetConnection 192.168.1.10 -Port 8000` → True, `-Port 3308` (older
          setups: 3306) → False. [K3]
21. - [ ] Sign in as the student → lock screen, NETWORK **Connected**. Sign in as administrator → **no**
          lock screen. [O2]
22. - [ ] **PC power status** → **Check now** → PC-01 **Available**; **System status** → agent 2.2.0,
          recent contact, Agent secret **own**. [O3]
23. - [ ] **Manual Unlock (Guest)** unlocks PC-01; **Lock** locks it; **PC activity log** shows both. [O3]

## Tests before real use

24. - [ ] Restart the server without signing in → site back within ~3 minutes. [Q1]
25. - [ ] End the CompuLab Web process on the server (`python.exe` running `-m waitress`; older setups
          `waitress-serve.exe`) → site back within ~1 minute. [Q2]
26. - [ ] Restart the lab PC → lock screen at student sign-in, none for the administrator. [Q3]
27. - [ ] In the unlocked student session, end `CompuLabAgent.exe` → lock screen back within ~2 minutes. [Q4]
28. - [ ] Unplug PC-01's cable, **Lock Now** → "Server offline · 1 queued"; plug in → delivered once. [Q6]
29. - [ ] Task Scheduler → **CompuLab nightly backup** → Run, and **Back Up CompuLab Now** → both 0x0 /
          "Backup saved in", both in the same folder, logs "Done". Check the 1:30 AM run next morning. [Q7]
30. - [ ] Restore test with `restore.ps1` (type `RESTORE`) → the lab created after the backup is gone. [Q8]
31. - [ ] Locked student session: Ctrl+Alt+Del → Switch user → administrator works. Optional: the
          emergency page on the Server PC (record the result). [Q9]
32. - [ ] Fill in the acceptance checklist; then add the other lab PCs one by one. [T, P]

Problems: the troubleshooting table, section S of the guide. Maintenance (repair, update, backup
folder, restore, student accounts, agent secrets, uninstall): section R.
