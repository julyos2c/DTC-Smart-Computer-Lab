# Manual verification guide — LAN, offline, recovery, remote access

These are checks for the owner to perform by hand on real machines. **None of them has been run
yet**: tick each one only after you have seen the expected result yourself. Record the date and
what you saw in the *Result* column of the checklist at the end.

## Prerequisites

| Item | Needed for |
|---|---|
| The CompuLab server installed with `installer\server\install-server.ps1` (both services running, migrations applied) | all |
| Two lab PCs on the same campus network, agent installed with `installer\agent\install-agent.ps1`, registered in CompuLab with their fixed IPs | 1, 4, 6, 7 |
| An Admin account, an Instructor account and a student with an ID number | 2, 4 |
| A way to cut the **server's internet without cutting the LAN**: unplug the router's WAN/uplink cable, or block the internet in the router (keep the switch/LAN up) | 3–5, 8 |
| Email configured (`configure-email.ps1`) — optional | 5, 8 |
| A cloud sync receiver implementing `cloud_sync/PROTOCOL.md` — optional; without one, do scenario 11 only | 8 (cloud part) |
| Tailscale on the server and on one laptop, a second internet connection for the laptop (e.g. phone hotspot) — optional | 12–14 |

Useful tools during the checks:

- **System status** page (Admin sidebar → System status) and its **Check again** button.
- On the server: `powershell -ExecutionPolicy Bypass -File installer\server\server-status.ps1`
- On a lab PC: `powershell -ExecutionPolicy Bypass -File "C:\Program Files\CompuLab Agent\tools\agent-status.ps1"`
- Logs on the server: `logs\compulab.log` (website), `logs\worker.log` (background worker).

---

## 1. Start the server and connect two lab PCs on the same LAN

**Steps**
1. Restart the server computer. Do not sign in to Windows on it.
2. From a staff computer, open the campus address (e.g. `http://192.168.1.10:8000`).
3. Switch on both lab PCs and sign in to Windows with the student account.

**Expected**
- The site opens within about 2 minutes of the server booting, without anyone signing in on the
  server (services start automatically).
- Both PCs show the CompuLab lock screen; NETWORK reads **Connected**.
- PC status shows both PCs **Available**; the Connection column shows a recent "Last contact" and
  the agent version (2.2.0); System status → Lab PC agents lists both with "Agent last called" a
  few seconds/minutes ago.

**If not**: `server-status.ps1` (which layer fails?). A PC that stays *Offline*: wrong IP in
CompuLab, PC firewall rule missing (`agent-status.ps1`), or the PC is on another network.

## 2. Local workflows while the internet is available

**Steps**: sign in as Admin, Instructor; create and approve a reservation for today; on lab PC 1
enter the student ID and reservation code; use the PC a minute; press **Lock Now**.

**Expected**: each step works; PC status shows PC 1 **In Use** by the student, then
**Available** after Lock Now; the activity log shows the unlock and the lock. The footer reads
*"Local system operational; cloud synchronization not configured."* (or *"Local system
operational."* when cloud sync is configured).

## 3. Disconnect the server's internet, keep the LAN

**Steps**: cut the internet (see prerequisites). Wait 1–2 minutes, or press **Check again** on
System status.

**Expected**: System status shows **Internet: Unavailable** (with "since" time), **Database: OK**,
**Background worker: Running**. The footer reads *"Local system operational; internet
unavailable."*. The site stays fast (pages do not wait for the internet; fonts fall back to the
system font).

**If not**: if the site itself stops answering, the LAN (not the internet) was cut — check the
switch/cable.

## 4. Local login, reservations, check-ins and session tracking continue offline

**Steps** (internet still off): sign out and sign in again; create, approve and cancel
reservations; check in a student on lab PC 2 with a reservation code; end the session with Lock
Now; open reports and the PC activity log; activate a new staff account with **Users → Approve in
person** and the one-time code at *Sign in → Have a one-time code?*.

**Expected**: all of these work exactly as in scenario 2. Pages that need the internet say so:
"Forgot password" explains that email is unavailable and points to an Admin reset code.

## 5. Email and cloud failures do not break local operations

**Steps** (internet still off): do something that sends email (create an Instructor, approve a
reservation). If cloud sync is configured, change a reservation.

**Expected**: the action completes immediately with "email queued"; **Email outbox** shows the
email *Waiting*; if cloud sync is on, **Cloud sync** shows the change *Waiting* and System status
shows "cloud server unreachable" / "internet unavailable". Nothing shows an error page.

## 6. Disconnect a lab client from the LAN: pending events are kept

**Steps**: unlock lab PC 1 for a student (scenario 2). Unplug PC 1's network cable (or disable its
Wi-Fi). Press **Lock Now** on PC 1. Wait 1 minute. Restart PC 1 (still unplugged) and sign in.

**Expected**: the lock screen shows NETWORK **Server offline · 1 queued** and a message that
sign-in with a reservation code is unavailable until the server is back (the internet is not
needed). `agent-status.ps1` on PC 1 shows *Queued events: 1* and the last contact time — also
after the restart. On the server, PC 1 still shows **In Use** (the server has not heard yet), or
*Offline* once its status check notices the PC is gone.

## 7. Reconnect the client: events delivered once, without duplicates

**Steps**: plug PC 1 back in. Wait up to 30 seconds.

**Expected**: NETWORK returns to **Connected**; `agent-status.ps1` shows *Queued events: 0*; PC
status shows PC 1 **Available**; the activity log has **exactly one** lock entry for that session.

**Extra check (no duplicates)**: repeat scenarios 6–7 three times, including once where you
restart CompuLab Web on the server while PC 1 is unplugged. Each session must leave exactly one
lock entry in the activity log.

*Not staged here:* the rule that a "session ended" delivered late never ends a newer session on
the same PC (labs/agent_events.py). It needs the server to mark the PC in use by someone else
while the old event is still queued on the disconnected PC, which can't be arranged reliably by
hand; if it ever happens in real use, the newer session simply stays active.

## 8. Restore the internet: email and cloud sync resume independently

**Steps**: reconnect the internet. Wait up to 2 minutes (or press **Check again**).

**Expected**: System status shows **Internet: OK**; the footer briefly reads *"Internet restored;
pending jobs are being processed."*; the Email outbox empties (emails *Sent*) and, if configured,
the Cloud sync queue empties and *Last successful sync* updates. Each queue moves on its own: if
the email password is wrong, emails stay *Retry* with a hint on System status while cloud sync
still completes (and the other way round).

## 9. Restart the web server and the worker while jobs are pending

**Steps**: cut the internet again so emails (and cloud changes) queue up (scenario 5). Then, as
Administrator on the server: `Restart-Service CompuLabWeb, CompuLabWorker` (or restart the whole
server). Also start an **Override** on an in-use PC and restart the services within its 30-second
warning.

## 10. Recovery without losing queued jobs

**Expected after 9**: the same queued emails and cloud changes are still listed after the restart
and are sent once the internet is back (scenario 8); the Override still completes after the
restart (System status → Recent background jobs shows it *Done*). No email is listed twice in
*Sent* for a single action. (SMTP itself can, rarely, deliver the same email twice if the
connection drops at the exact moment of sending; that is a limit of email, not a lost job.)

## 11. Cloud synchronization unconfigured: local operation unaffected

**Steps**: with `CLOUD_SERVER_URL` and `CLOUD_SYNC_API_KEY` blank in `.env` (the default), use
CompuLab normally for a while.

**Expected**: System status shows *Cloud sync receiver: Not configured* and the Queues table says
"Cloud synchronization not configured … nothing is queued"; **Cloud sync** page shows the same
notice and no rows; everything else works.

## 12. Connect the server and an authorized laptop to Tailscale

**Steps**: follow `installer\REMOTE_ACCESS.md` Parts 1–3.

**Expected**: `configure-remote-access.ps1` ends with *"<remote address> answers."*; System status
shows the remote address next to the campus address; the laptop's Tailscale app says
*Connected* and lists the server.

## 13. Access the application from outside the school network

**Steps**: connect the laptop to a different internet connection (phone hotspot), Tailscale on.
Open the remote address; sign in; open PC status; submit any form (e.g. mark a notification read).

**Expected**: the site opens (with a padlock in Serve mode); sign-in, pages and form submissions
work exactly as on campus; the account's role limits still apply (e.g. an Instructor still cannot
open Admin pages).

## 14. Remote access fails gracefully when the server or school internet is unavailable

**Steps**: (a) stop the CompuLab Web service; open the remote address from the laptop.
(b) Start it again, then cut the school's internet; open the remote address. (c) Use the desktop
shortcut from the launcher in both cases.

**Expected**: (a) and (b) the browser cannot reach the site; the launcher shows *"The CompuLab
server is not answering right now"* with what to check. Nothing is changed on the server. On
campus during (b), the campus address keeps working.

## 15. Local LAN access works without remote access configured

**Steps**: run `configure-remote-access.ps1 -Mode Disable` (or never configure it). Use the campus
address from a staff computer and the lab PCs.

**Expected**: everything works; System status shows *Remote address: Not configured*.

## 16. The administration page shows accurate connectivity and queue states

**Steps**: during scenarios 3–15, keep System status open and press **Check again** after each
change. Compare with `server-status.ps1` on the server.

**Expected**: each row changes to match reality within about a minute: Internet, Email server,
Cloud receiver (or *Not configured*), Database, Background worker, queue counts (email, cloud,
events queued on PCs), last successful sync, campus and remote addresses. Stop the **CompuLab
Worker** service: within 2 minutes System status and the Admin footer say *"Background worker
requires attention: it is not running."*; start it again and the warning clears.

---

## Checklist

| # | Scenario | Result (date, what you saw) |
|---|---|---|
| 1 | Server start + two lab PCs | |
| 2 | Local workflows online | |
| 3 | Internet cut, LAN up | |
| 4 | Local workflows offline | |
| 5 | Email / cloud failures harmless | |
| 6 | Lab PC offline keeps events | |
| 7 | Reconnect: delivered once; late event ignored | |
| 8 | Internet back: queues resume independently | |
| 9 | Restart web + worker with pending jobs | |
| 10 | Nothing lost after restart | |
| 11 | Cloud sync unconfigured | |
| 12 | Server + laptop on Tailscale | |
| 13 | Access from outside | |
| 14 | Remote access fails gracefully | |
| 15 | LAN without remote access | |
| 16 | Status page accurate | |
