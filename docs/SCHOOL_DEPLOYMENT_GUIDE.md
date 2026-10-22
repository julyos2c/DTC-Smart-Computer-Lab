# CompuLab — school deployment guide

For the person setting up CompuLab at the school (IT staff or the Lab In-Charge). No programming
needed. Plan about one hour for the server and ten minutes per lab PC.

You need two files (built with `installer\build\build-installers.ps1`, see the end of this guide):

| File | Where it goes |
|---|---|
| `CompuLab-Server-Setup-<version>.exe` | once, on the server computer |
| `CompuLab-Agent-Setup-<version>.exe` | on every student lab PC |

Both are unsigned: Windows shows "Windows protected your PC" → **More info** → **Run anyway**.

---

## Part 1 — the main server (once)

**Choose the computer.** An always-on desktop with Windows 10/11 (64-bit), 8 GB RAM, wired network.
Not a student PC. Give it a **fixed IP address** in the router (DHCP reservation), e.g.
`192.168.1.10`, and set its network to **Private** (Settings → Network).

**Install two free programs first** (needs internet once):

1. **Python 3.13** — python.org → Downloads → Windows installer (64-bit). Tick **Add python.exe to
   PATH** and choose **Customize → Install for all users**.
2. **MariaDB 11.4** — mariadb.org → Download → MariaDB Server (MSI). Choose a strong **root
   password** and write it down; keep **Install as service** ticked.

**Run `CompuLab-Server-Setup.exe`** and answer:

| Question | Answer |
|---|---|
| Install folder | keep `C:\CompuLab` |
| Campus IP address | the fixed IP from above, e.g. `192.168.1.10` (or leave empty to pick from a list) |
| Port | keep `8000` |
| MariaDB root password (console window) | the password from step 2 (not saved) |
| First Administrator (console window) | your Gmail address and a password you choose |

A console window shows each step and ends with **"CompuLab is installed"** and the address, e.g.
`http://192.168.1.10:8000`. Open it from another computer and sign in. If it stops with
**"Installation stopped: …"**, the line explains why; fix it and run the setup again (it continues
safely and never deletes data).

What it set up for you: the two Windows services **CompuLab Web** and **CompuLab Worker** (they start
automatically after every restart), the firewall rule (campus addresses only), a nightly backup at
1:30 AM to `C:\CompuLab\backups`, and Start-menu shortcuts (**CompuLab Server Status**, **Back Up
CompuLab Now**, **Repair CompuLab Server**).

**Recommended next:** point the nightly backups at a second disk or USB drive (run
`installer\server\install-server.ps1 -BackupRoot E:\CompuLabBackups` as Administrator), and set up
email (`installer\server\configure-email.ps1`) if you want emailed codes and alerts. Everything works
without email and without internet.

## Part 2 — each student lab PC

1. **Router:** give the PC a fixed IP address (DHCP reservation).
2. **CompuLab** (signed in as Admin): Manage labs → add the PC with that IP address. Then
   **PC status** → the PC's row → **Agent config** downloads `agent_config.local.json`. Save it to a
   USB stick **next to** `CompuLab-Agent-Setup.exe`. (It contains the agent secret: delete it from the
   stick when you are done.)
3. **On the lab PC** (signed in as a Windows administrator): run `CompuLab-Agent-Setup.exe` from the
   stick. It finds the config file by itself. A console window ends with **"The CompuLab agent is
   installed"** and the agent's self-test result.
4. Sign out of Windows and back in: the CompuLab lock screen appears. In CompuLab, PC status shows the
   PC as **Available**.

No Python is needed on lab PCs. Students should use a **standard** (non-administrator) Windows
account.

**Many PCs at once** (from an administrator command prompt, e.g. through your remote-management tool):

```
CompuLab-Agent-Setup.exe /VERYSILENT /CONFIG="\\server\share\agents\PC-01.json"
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
| Update / repair a lab PC | Run the newer `CompuLab-Agent-Setup.exe` (settings and queued events are kept). |
| Change the server address on a lab PC | `C:\Program Files\CompuLab Agent\tools\set-agent-server.ps1 -ServerUrl http://NEW-IP:8000` (as Administrator) |
| Restore the server from a backup | `installer\server\restore.ps1 -BackupFolder C:\CompuLab\backups\compulab-…` (as Administrator) |
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

Needs Python 3.13 and internet; writes the files to `installer\dist\` with a `SHA256SUMS` list.
Automated tests: `installer\tests\` (see `installer\README.md`).
