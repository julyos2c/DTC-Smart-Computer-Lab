# Using CompuLab from outside the campus (optional)

CompuLab runs on the campus server and works on the campus network without any of this. Remote
access lets **authorized staff open the same CompuLab from home**, through **Tailscale**, a private
VPN. It is not cloud hosting and not cloud sync: the remote address reaches the campus server
itself.

**Never** forward ports on the campus router (8000, the database port 3306, or the agent port
5555). Tailscale needs no router changes.

## What to expect

| Situation | Campus network (LAN) | From home through Tailscale |
|---|---|---|
| Everything up | Works | Works |
| Campus internet down | **Works** | Does not work (the server can't reach Tailscale). The browser shows "can't reach" or the launcher says the server is unavailable. |
| Server switched off / CompuLab stopped | Does not work | Does not work |
| Remote access never configured | **Works** | — |
| Your home internet or Tailscale app off | — | Does not work: connect Tailscale first |

## Part 1 — the server (once, about 20 minutes)

You need: a Tailscale account for the college (free plan is enough for a few staff), and
Administrator rights on the server. These steps need a person; no script can sign in for you.

1. **Install Tailscale** on the CompuLab server: tailscale.com/download/windows.
2. **Sign in** from the Tailscale icon next to the clock, with the college's Tailscale account.
3. In the Tailscale icon menu, turn on **Run unattended** (so it connects at boot, before anyone
   signs in to Windows).
4. In the Tailscale admin console (login.tailscale.com/admin):
   - **Machines** → the server → **…** → **Disable key expiry** (otherwise it drops off the
     network after 180 days and remote access stops).
   - **DNS** → turn on **MagicDNS** and **HTTPS Certificates** (needed for the https address).
5. On the server, open PowerShell **as Administrator** in the CompuLab folder and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File installer\server\configure-remote-access.ps1
   ```

   It checks that Tailscale is connected, publishes CompuLab on the tailnet with HTTPS
   (`tailscale serve`), saves the address as `COMPULAB_REMOTE_URL` in `.env`, restarts CompuLab
   and checks the address from the server. At the end it prints the remote address, e.g.
   `https://compulab-server.tail1234.ts.net`. If a step fails it says which, and changes nothing
   else.

   *No HTTPS certificates possible?* Use `-Mode Direct` instead: the address is then
   `http://100.x.y.z:8000`. Traffic is still encrypted by Tailscale, but browsers show "Not
   secure". The script adds a firewall rule that allows the port from Tailscale addresses only.

6. The remote address now appears on **System status → How to reach this server**, next to the
   campus address.

To remove remote access: `configure-remote-access.ps1 -Mode Disable`.

### What the script changes (for reference)

| Item | Serve mode (default) | Direct mode |
|---|---|---|
| Tailscale | `tailscale serve --bg --https=443 http://127.0.0.1:<port>` (tailnet only; not Funnel) | `tailscale serve reset` |
| Windows Firewall | nothing extra: Tailscale connects to CompuLab on the server itself | rule *CompuLab Web (Tailscale)*: TCP `<port>` from `100.64.0.0/10` only |
| `.env` | `COMPULAB_REMOTE_URL=https://<name>.<tailnet>.ts.net` | `COMPULAB_REMOTE_URL=http://100.x.y.z:<port>` |
| CompuLab | accepts that host name (ALLOWED_HOSTS) and origin (CSRF) automatically; `SITE_URL` stays the campus address used in emails and by lab PCs | same |

Unchanged: Django sign-in, permissions, CSRF protection and sessions work exactly as on campus.
The database port is never opened.

## Part 2 — who may connect

In the Tailscale admin console:

1. **Users → Invite** only the staff who need remote access (Admins, Lab In-Charges).
2. Limit what they can reach with an **access control policy** (Access controls tab). Example,
   after tagging the server `tag:compulab-server` (Machines → server → Edit ACL tags):

   ```json
   {
     "groups":    { "group:compulab-staff": ["admin1@gmail.com", "incharge1@gmail.com"] },
     "tagOwners": { "tag:compulab-server": ["autogroup:admin"] },
     "acls": [
       { "action": "accept", "src": ["group:compulab-staff"], "dst": ["tag:compulab-server:443,8000"] }
     ]
   }
   ```

   Replace the emails with the real ones. Check the policy in the console's preview before saving:
   a wrong policy can cut off access.
3. When someone leaves: remove them from Tailscale **and** disable their CompuLab account.

## Part 3 — each staff laptop or phone (5 minutes)

1. Install Tailscale (tailscale.com/download) and sign in with the invitation.
2. Turn Tailscale **on** (the app shows *Connected*).
3. Open the remote address printed in Part 1 and sign in to CompuLab as usual.
4. Optional desktop shortcut that tries the campus address first and the remote one second
   (on a Windows laptop, PowerShell in the CompuLab folder):

   ```powershell
   powershell -ExecutionPolicy Bypass -File installer\launcher\install-launcher.ps1 -LanUrl http://192.168.1.10:8000 -RemoteUrl https://compulab-server.tail1234.ts.net
   ```

Lab PCs never use Tailscale: they always use the campus address.

## Troubleshooting (check in this order)

1. **Is Tailscale connected on the laptop?** The app must say *Connected*. In a terminal:
   `tailscale status` lists the server; `tailscale ping <server name>` must answer.
   If not: a Tailscale problem (sign-in, invitation, access policy), not CompuLab.
2. **Is the server on the tailnet?** Admin console → Machines: the server must show *Connected*
   (a recent "last seen"). If not: the server is off, its internet is down, or key expiry was not
   disabled. On campus, everything still works on the campus address.
3. **Does CompuLab run on the server?** On the server: `installer\server\server-status.ps1`.
   It checks the services, the website, the database, the worker and the remote address separately.
4. **"Bad Request (400)"** in the browser: the address you typed is not the one in
   `COMPULAB_REMOTE_URL`. Re-run `configure-remote-access.ps1` (it saves the current name).
5. **"Forbidden (403) CSRF verification failed"** when submitting a form: same cause as 4 (the
   address must match exactly, including `https://`), then restart the CompuLab services.
6. **Serve mode fails** with a certificate error: HTTPS Certificates are not enabled for the
   tailnet (Part 1, step 4), or use `-Mode Direct`.

## Notes

- With Serve mode, every remote user reaches CompuLab through Tailscale on the server itself, so
  CompuLab sees them all as the same address (127.0.0.1). Per-address limits (e.g. the activation
  code page's attempt limit) are then shared by all remote users. The server's own health details
  (`/healthz/ready`) still require an Admin sign-in from remote devices.
- Tailscale's free plan and its terms are set by Tailscale, not by CompuLab.
