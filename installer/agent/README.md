# Installing the CompuLab agent on a lab PC

The agent shows the CompuLab lock screen. Students unlock the PC with their Student ID and
reservation code; staff can lock, unlock, restart or shut it down from **PC power status**.

About 10 minutes per PC.

## Before you start (once per PC)

1. **Fixed IP address:** in the campus router, reserve an IP for this PC (DHCP reservation).
2. **Register the PC in CompuLab:** Manage labs → Add PC (or PC import), with that IP address.
3. **Download its settings:** PC power status → the PC's row → **Agent config**. Save
   `agent_config.local.json` to a USB stick. It contains **this PC's own agent secret** (created on
   the first download, the same on later ones): don't email it, and delete it from the stick
   afterwards. A file for one PC is refused on another PC.
4. Students use a **standard (non-administrator)** Windows account. Note its name: only the
   accounts you give the installer get the lock screen.

## Install

**Easiest (no Python needed):** put `CompuLab-Agent-Setup-<version>.exe` and the PC's
`agent_config.local.json` side by side on the USB stick and run the setup on the PC (as a Windows
administrator). It picks up the config file by itself, asks for the **student Windows account(s)**,
installs the packaged `CompuLabAgent.exe` and shows the result of the agent's self-test. Many PCs at
once, silently:

```
CompuLab-Agent-Setup.exe /VERYSILENT /CONFIG="\\server\share\agents\PC-01.json" /STUDENTS="student"
```

**From a CompuLab folder copy:** put `agent_config.local.json` next to **Install CompuLab Agent.cmd**
and double-click it, or open PowerShell **as Administrator** (USB stick is `E:` here):

```powershell
cd E:\CompuLab
powershell -ExecutionPolicy Bypass -File installer\agent\install-agent.ps1 -ConfigFile E:\agent_config.local.json -StudentAccounts student
```

A folder copy runs `agent.py`, so it needs **Python 3.11-3.13** on the PC (python.org installer,
*Add to PATH*, *Install for all users*). Without `-StudentAccounts` it asks (and lists the standard
accounts); `-NonInteractive` for scripts (no questions); `-AllUsers` locks **every** account,
administrators included (the old behaviour — not recommended).

If the settings file is unusable (placeholder or missing secret, bad address), or a student account
does not exist or is an administrator, the installer stops **before changing anything** and says
what is wrong.

Sign in with the student account: the lock screen appears. Administrators are not locked (staff
unlock a student session with PC power status → Manual Unlock (Guest)). In CompuLab, PC power status
(after **Check now**) should show the PC as **Available** with "Last contact" a few seconds ago.

If the server can't be reached during the install (e.g. it is switched off), the installer warns
and continues; the agent keeps trying by itself once it runs. Use `-ServerUrl http://<server>:8000`
to set or override the address.

## What the installer does

- Copies the agent to `C:\Program Files\CompuLab Agent` (the packaged `CompuLabAgent.exe`, or
  `agent.py` with its own Python environment), and the helper scripts to
  `C:\Program Files\CompuLab Agent\tools`.
- Runs the installed agent's self-test (`--self-test`: settings readable, queue folder writable,
  server reachable) and shows the result; the install log is in
  `C:\ProgramData\CompuLab Agent\install-<time>.log`.
- Saves `agent_config.local.json` there (students can read but not change it). The server address
  in it is fixed by you; there is no automatic server discovery.
- Creates `C:\ProgramData\CompuLab Agent`, where the agent keeps events waiting to be sent and its
  last-contact status (shared by every Windows account on the PC, kept across updates and
  reinstalls).
- Opens port 5555 and ping **only for the CompuLab server's IP**.
- Creates the local group **CompuLab Students** (if needed) and adds the student account(s);
  administrator accounts are refused.
- Registers the task **CompuLab Agent** for that group: starts when a student signs in (so also
  after a restart). While the student is signed in the task repeats every minute and does nothing
  if the agent is running, so a closed or crashed lock screen is back within about a minute. (The
  lock screen must run in the signed-in desktop, so it is a logon task, not a Windows service.)
  A repair/update keeps the installed setting; an agent installed by an older version (every
  account locked) stays so until the setup is run with the student account(s).
- Needs no Python: the setup and the packaged agent run on a PC without Python.

## Checking a PC and changing its server address

```powershell
# What is configured, last successful contact, queued events, does the server answer now:
powershell -ExecutionPolicy Bypass -File "C:\Program Files\CompuLab Agent\tools\agent-status.ps1"

# Show the server address / change it (as Administrator; keeps the secret, updates the firewall):
powershell -ExecutionPolicy Bypass -File "C:\Program Files\CompuLab Agent\tools\set-agent-server.ps1"
powershell -ExecutionPolicy Bypass -File "C:\Program Files\CompuLab Agent\tools\set-agent-server.ps1" -ServerUrl http://192.168.1.10:8000
```

The lab PCs only ever talk to the campus server; they never need the internet.

## When the campus network or the server is down

- The lock screen shows NETWORK **Server offline** and explains that sign-in with a reservation code
  is unavailable until the server is back (the internet is not needed). IT staff sign in with an
  administrator account (Ctrl+Alt+Del → Switch user), which is never locked. The emergency tool
  `manual_unlock.html` (see `lab_pc_agent\README.md`) only works from the server PC (the firewall
  rule) with that PC's own agent secret, and has not been tested on real machines.
- When a session ends while the server is unreachable, the agent keeps the "session ended" event on
  disk (also across restarts) and re-sends it — every 15 seconds at first, slowing to every 5
  minutes, and at once when the server answers again — until the server **confirms** it. The server
  applies each event only once, and ignores one that arrives after the PC was already in use again.
  NETWORK shows how many are queued (e.g. *Server offline · 2 queued*).
- Limits: events older than 24 hours are dropped (they no longer mean anything), and at most 200 are
  kept. Activity samples (window titles) are not queued: they are skipped while offline.

## Update or remove

- **Update:** run the newer setup (or `install-agent.ps1` from the new CompuLab copy): settings, the
  PC's secret, the student accounts and queued events are kept unless you pass a new `-ConfigFile`
  or new student accounts. System status lists each PC's agent version and whether it uses its own
  secret.
- **Student accounts:** add one with `net localgroup "CompuLab Students" student2 /add` (elevated
  Command Prompt) or by running the setup with it; it applies from that account's next sign-in.
- **Send queued events now** (e.g. after fixing the network): `start /wait "" "C:\Program Files\CompuLab Agent\CompuLabAgent.exe" --flush`
  in a Command Prompt, then `echo %errorlevel%` (0 = all delivered, 2 = server still unreachable, events kept).
- **Remove:** Settings → Apps → *CompuLab Agent* (setup program), or
  `installer\agent\uninstall-agent.ps1`, which removes the start-up task, the firewall rules
  and the program folder. It keeps `C:\ProgramData\CompuLab Agent` (queued events) unless you add
  `-RemoveData`; `-KeepFiles` keeps the program folder too. The **CompuLab Students** group is kept.
- **Server address changed:** `tools\set-agent-server.ps1 -ServerUrl ...` (above), or download the
  PC's Agent config again and re-run the installer with `-ConfigFile`.
