# Installing the CompuLab agent on a lab PC

The agent shows the CompuLab lock screen. Students unlock the PC with their Student ID and
reservation code; staff can lock, unlock, restart or shut it down from **PC status**.

About 10 minutes per PC.

## Before you start (once per PC)

1. **Fixed IP address:** in the campus router, reserve an IP for this PC (DHCP reservation).
2. **Register the PC in CompuLab:** Manage labs → Add PC (or PC import), with that IP address.
3. **Download its settings:** PC status → the PC's row → **Agent config**. Save
   `agent_config.local.json` to a USB stick. It contains the agent secret: don't email it, and
   delete it from the stick afterwards.
4. **Python 3.12** (or 3.11+) on the PC: python.org installer, tick *Add to PATH* and
   *Install for all users*.
5. Students should use a **standard (non-administrator)** Windows account.

## Install

On the lab PC, open PowerShell **as Administrator**, then (USB stick is `E:` here):

```powershell
cd E:\CompuLab
powershell -ExecutionPolicy Bypass -File installer\agent\install-agent.ps1 -ConfigFile E:\agent_config.local.json
```

Optional: `-LabUser LAB\student` to start it only for the students' Windows account.

Sign out of Windows and back in: the lock screen appears. In CompuLab, PC status should show the PC
as **Available** with "Last contact" a few seconds ago.

If the server can't be reached during the install (e.g. it is switched off), the installer warns
and continues; the agent keeps trying by itself once it runs. Use `-ServerUrl http://<server>:8000`
to set or override the address.

## What the installer does

- Copies the agent to `C:\Program Files\CompuLab Agent` with its own Python environment, and the
  helper scripts to `C:\Program Files\CompuLab Agent\tools`.
- Saves `agent_config.local.json` there (students can read but not change it). The server address
  in it is fixed by you; there is no automatic server discovery.
- Creates `C:\ProgramData\CompuLab Agent`, where the agent keeps events waiting to be sent and its
  last-contact status (shared by every Windows account on the PC, kept across updates and
  reinstalls).
- Opens port 5555 and ping **only for the CompuLab server's IP**.
- Registers the task **CompuLab Agent**: starts at every Windows sign-in (so also after a restart),
  restarts within a minute if it is closed or crashes. (The lock screen must run in the signed-in
  desktop, so it is a logon task, not a Windows service.)

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
  is unavailable until the server is back (the internet is not needed). Staff can still use the
  emergency tool `manual_unlock.html` (see `lab_pc_agent\README.md`).
- When a session ends while the server is unreachable, the agent keeps the "session ended" event on
  disk (also across restarts) and re-sends it — every 15 seconds at first, slowing to every 5
  minutes, and at once when the server answers again — until the server **confirms** it. The server
  applies each event only once, and ignores one that arrives after the PC was already in use again.
  NETWORK shows how many are queued (e.g. *Server offline · 2 queued*).
- Limits: events older than 24 hours are dropped (they no longer mean anything), and at most 200 are
  kept. Activity samples (window titles) are not queued: they are skipped while offline.

## Update or remove

- **Update:** run `install-agent.ps1` again from the new CompuLab copy (settings and queued events
  are kept unless you pass a new `-ConfigFile`). PC status shows each PC's agent version.
- **Remove:** `installer\agent\uninstall-agent.ps1` removes the start-up task, the firewall rules
  and the program folder. It keeps `C:\ProgramData\CompuLab Agent` (queued events) unless you add
  `-RemoveData`; `-KeepFiles` keeps the program folder too.
- **Server address changed:** `tools\set-agent-server.ps1 -ServerUrl ...` (above), or download the
  PC's Agent config again and re-run the installer with `-ConfigFile`.
