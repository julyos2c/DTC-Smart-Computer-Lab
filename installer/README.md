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
