# Setting up CompuLab on campus

CompuLab runs on **one computer on the campus network** (the *server*). Lab PCs and staff computers
connect to it over the network. Everything works **without internet**: signing in, reservations,
unlocking lab PCs, rosters, attendance and reports. Only email needs the internet; while it is down,
emails wait and are sent automatically later.

```
                    campus network (LAN)
   ┌────────────────────────┬──────────────────────┬──────────────────────┐
   │                        │                      │                      │
 CompuLab server       Lab PC 1..n            Staff computers      (optional) remote staff
 (website + worker)    lock-screen agent      browser / shortcut   via Tailscale VPN
 MariaDB database      port 5555              http://server:8000
```

**Short version for the school:** [../docs/SCHOOL_DEPLOYMENT_GUIDE.md](../docs/SCHOOL_DEPLOYMENT_GUIDE.md).

## Three ways to install (same result)

| | Server | Lab PC |
|---|---|---|
| **Setup program** (easiest) | `CompuLab-Server-Setup-<version>.exe` | `CompuLab-Agent-Setup-<version>.exe` (no Python needed on the PC) |
| **Double-click** in a copy of the CompuLab folder | `Install CompuLab Server.cmd` | `Install CompuLab Agent.cmd` (put the PC's `agent_config.local.json` next to it) |
| **PowerShell** (scripted, unattended) | `installer\server\install-server.ps1` | `installer\agent\install-agent.ps1` |

The setup programs run the same PowerShell installers. Every installer can be run again at any time
to repair or update; it keeps settings, data and queued events.

| Entry point | What it does |
|---|---|
| `Install CompuLab Server.cmd` | install / update / repair the server (asks for administrator rights) |
| `installer\server\Server Status.cmd` | checks every part of the server, changes nothing |
| `installer\server\Backup Now.cmd` | backup of database, uploads and settings |
| `installer\server\Uninstall CompuLab Server.cmd` | removes services, firewall rule and backup task; keeps all data |
| `Install CompuLab Agent.cmd` | install / repair the agent on a lab PC |
| `installer\agent\Agent Status.cmd` | the agent's server address, last contact and queued events |
| `installer\agent\Uninstall CompuLab Agent.cmd` | removes the agent; keeps queued events |

Sample settings without secrets: `installer\server\server-install.sample.json` (for
`install-server.ps1 -ConfigFile`) and `installer\agent\agent_config.local.sample.json` (shape of the
per-PC file CompuLab generates).

| What | Guide | Time |
|---|---|---|
| 1. The server (once) | [server/README.md](server/README.md) | about 1 hour |
| 2. Each lab PC | [agent/README.md](agent/README.md) | about 10 minutes per PC |
| 3. Staff computers (optional shortcut) | below | 2 minutes |
| 4. Using CompuLab from outside the campus (optional) | [REMOTE_ACCESS.md](REMOTE_ACCESS.md) | 30 minutes |
| 5. Check that it all works | [../docs/MANUAL_VERIFICATION.md](../docs/MANUAL_VERIFICATION.md) | 1–2 hours |

## The campus network (LAN) setup in short

1. Router: reserve a fixed IP for the server and for every lab PC (DHCP reservation).
2. Server: set its network to **Private**; run `install-server.ps1` and choose that fixed IP. The
   campus address is then e.g. `http://192.168.1.10:8000` (shown on System status).
3. CompuLab: register every lab PC with its fixed IP (Manage labs → PC).
4. Each lab PC: run `install-agent.ps1` with the PC's Agent config file (it contains the campus
   address).
5. Staff: bookmark the campus address, or install the launcher shortcut.

Nothing in this list needs the internet after the first package download, and no router port is
opened to the internet.

## Staff computers

Nothing has to be installed: open `http://<server address>:8000` in any browser and bookmark it.
For a desktop icon that also falls back to the remote (VPN) address:

```powershell
powershell -ExecutionPolicy Bypass -File installer\launcher\install-launcher.ps1 -LanUrl http://192.168.1.10:8000
```

## Day-to-day

| Situation | What to do |
|---|---|
| Internet is down | Nothing. Work continues. The footer shows "Local system operational; internet unavailable"; emails (and cloud changes, if configured) wait and are sent automatically when it returns. |
| The footer says "Local server unreachable from this computer" | This computer reaches its network but not the server: check the server is on, then the cable/Wi-Fi between them. |
| A lab PC shows "Server offline" | Campus network or server problem (not internet): `tools\agent-status.ps1` on the PC, `server-status.ps1` on the server. |
| A new staff member can't receive email | Users → (the person) → **Approve in person**. Check their school ID, hand them the one-time code; they enter it at *Sign in → Have a one-time code?* and choose their own password. |
| Someone forgot their password while offline | Users → (the person) → **Issue password reset code**, same as above. |
| A lab PC shows "Status may be out of date" | Check **System status** (is the worker running?) and that the PC is on. |
| Something looks wrong | **System status** page (Admins), then the files in `logs\` on the server. |
| Server was restarted | Nothing: both services start automatically; queued emails and Override switches continue. |

Backups run every night (see the server guide). Test a restore at least once a term.

## For developers: building and testing the installers

```powershell
# Build both setup programs into installer\dist (needs Python 3.13 + internet; no admin rights)
powershell -ExecutionPolicy Bypass -File installer\build\build-installers.ps1 -InstallInnoSetup

# Tests (no admin rights; nothing outside temporary folders is changed)
powershell -ExecutionPolicy Bypass -File installer\tests\test-installer-logic.ps1      # script logic
powershell -ExecutionPolicy Bypass -File installer\tests\test-server-install.ps1       # server setup end to end (needs a build + MySQL/MariaDB server files)
powershell -ExecutionPolicy Bypass -File installer\tests\test-agent-install.ps1        # agent setup end to end (needs a build)
venv\Scripts\python -m unittest discover -s lab_pc_agent\tests                          # agent queue + agent-to-server
venv\Scripts\python manage.py test                                                      # Django (includes system/tests.py)
```

The end-to-end tests compile a **test build** of each setup (`/DTestBuild`: per-user, skips the
Windows services, firewall rules and start-up task, which need administrator rights) and run it
silently into a temporary folder. The server test starts a throwaway MySQL/MariaDB server on a free
port from the installed server files. What they cannot cover is listed in
`docs/MANUAL_VERIFICATION.md`.
