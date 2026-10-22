# LAN, Remote Access, and Server/Client Installation Design

**Status:** proposal for review, based on the recommended architecture in [HYBRID_ARCHITECTURE.md](HYBRID_ARCHITECTURE.md) (one authoritative on-prem server). Windows is assumed for the server and the lab PCs, because the agent and its hardening are Windows-specific. Please confirm.

---

## 1. Components

| Component | Role |
|---|---|
| **CompuLab server** | One always-on Windows machine on the campus LAN. Runs the web service, worker service, MariaDB (local only), backups, and the optional VPN endpoint |
| **Staff clients** | Any browser on the LAN (Admin, In-Charge, Instructor), or remotely through the VPN |
| **Lab PCs** | Each runs the CompuLab Agent (lock screen, unlock listener, activity reporting) |
| **Switch / router / Wi-Fi** | Must route between the server, staff devices and lab PCs. No client isolation between them |
| **Local database** | MariaDB on the server, bound to `127.0.0.1` only |
| **Internet uplink** | Needed only for email, remote access and (optional) publishing |
| **VPN overlay** | Tailscale (recommended) or WireGuard. Gives remote staff a private path to the server |
| **Optional hosted page** | Static notice or read-only status page at the public domain |

## 2. Network architecture (Deliverable 6)

```
                                   INTERNET
        ┌───────────────────────────────────────────────────────────────┐
        │   College SMTP mailbox      Tailscale coordination servers    │
        │   (optional) hosted read-only status page                     │
        └───────▲───────────────────────────▲──────────────────▲────────┘
                │ SMTP 465/587 (outbound)   │ WireGuard UDP    │ Remote staff laptop/phone
                │ from server worker        │ (outbound only,  │ with Tailscale client
                │                           │  NAT-traversed)  │   ── encrypted tunnel ──┐
        ┌───────┴───────────────────────────┴──────────────────┴─────┐                  │
        │                     School router / firewall               │  NO port forwards│
        └───────────────────────────▲────────────────────────────────┘                  │
                                    │                                                   │
                      ┌─────────────┴──────────────┐                                    │
                      │   Core switch (Ethernet)   │──── Wi-Fi AP (staff SSID, no       │
                      └──┬─────────┬───────────┬───┘     client isolation to server)    │
                         │         │           │                                         │
         ┌───────────────┴──┐  ┌───┴──────┐  ┌─┴───────────────────────────────┐        │
         │ CompuLab SERVER  │  │ Staff PC │  │ Lab switch(es)                  │        │
         │ 192.168.x.10     │  │ browser  │  │  ├─ Lab PC 01  Agent :5555      │        │
         │  Web  :8000 ◄────┼──┤──HTTP────┘  │  ├─ Lab PC 02  Agent :5555      │        │
         │  Worker          │  │             │  └─ …                           │        │
         │  MariaDB 127.0.0.1:3306           └──────▲───────────┬──────────────┘        │
         │  Backups → NAS/USB│                       │           │                       │
         │  Tailscale 100.x ◄┼───────────────────────┼───────────┼───────────────────────┘
         └───▲──────────┬────┘                       │           │
             │          └── unlock/lock/power :5555 ─┘           │
             └──────────── agent login/heartbeat :8000 ──────────┘
```

### Traffic flows

| From | To | Port / protocol | Purpose | Allowed when internet is down? |
|---|---|---|---|---|
| Staff browser (LAN) | Server | TCP 8000 HTTP (or 443 if TLS added) | Use CompuLab | Yes |
| Lab PC agent | Server | TCP 8000 | Login, info, activity heartbeat, logout/end-session | Yes |
| Server | Lab PC agent | TCP 5555 | Unlock, lock, override warning, shutdown, restart | Yes |
| Server | Lab PCs | ICMP echo | Status checker | Yes |
| Server worker | SMTP host | TCP 465/587 outbound | Email outbox | No (queued) |
| Server | Tailscale | UDP outbound | Remote access tunnel | No |
| Remote staff | Server (via tunnel) | TCP 8000 over WireGuard | Use CompuLab remotely | No |
| Anything | Server MariaDB | TCP 3306 | **Never.** Local only | n/a |

---

## 3. LAN connection workflow

1. **Install and start the server** (§7). The installer creates the services and firewall rules and prints the server's URL.
2. **Give the server a stable address.** Preferred: a **DHCP reservation** on the router (bound to the server's MAC), because it survives NIC re-imaging and stays in the router's records. Alternative: a static IP outside the DHCP pool. Optional: a local DNS name (e.g. `compulab.lan`) if the router or AD DNS supports it, so a later IP change needs no client changes.
3. **Check that server, staff devices and lab PCs can reach each other.** Being plugged into the same switch is not enough. Check:
   - same subnet, or VLANs routed with rules allowing 8000, 5555 and ICMP;
   - Wi-Fi **client/AP isolation** disabled for the staff SSID (isolation blocks reaching the server);
   - Windows network profile set to **Private** on the server and lab PCs (the Public profile blocks inbound rules by default);
   - no third-party antivirus firewall overriding Windows Firewall rules.
4. **Firewall rules** (created by the installers):

   | Machine | Rule |
   |---|---|
   | Server | Allow inbound TCP 8000 from campus staff subnets, lab subnets and the Tailscale interface. Block 3306 inbound (MariaDB bound to localhost anyway) |
   | Lab PC | Allow inbound TCP 5555 and ICMP echo **only from the server's IP**. Outbound to the server's 8000 |

5. **Clients find the server:** they enter the address, or use the connection file from the installer (§6).
6. **Connect** through `http://<server>:8000/` (or the HTTPS name, if adopted).
7. **Authenticate and authorize:** staff sign in (role permissions enforced server-side); agents authenticate with their per-PC token.

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| Staff browser shows "Bad Request (400)" | The server address is missing from `ALLOWED_HOSTS` (installer tool must add it) |
| Form submit gives "CSRF verification failed" | The origin is missing from `CSRF_TRUSTED_ORIGINS` |
| Lock screen: "This computer isn't registered (server sees this PC's IP as …)" | The PC's IP changed (DHCP), or the record has the wrong IP |
| PC shows "Offline" while it is on | ICMP blocked on the PC, or the Public network profile |
| Unlock fails: "Could not reach agent" | Port 5555 blocked, the agent is not running, or the agent runs in the wrong Windows session (§7.3) |

---

## 4. Server identity, discovery and IP changes

**Discovery options**

| Option | Assessment |
|---|---|
| Manual entry of the URL | Always available. Required fallback |
| **Connection file** from the server installer (`compulab-connection.json`: server URL(s), server certificate fingerprint if TLS, optional one-time enrollment code) | **Recommended.** Admin-controlled, no spoofing risk; copy it by USB or a share |
| LAN broadcast discovery (UDP beacon or mDNS) | Convenient, but any device can answer and impersonate the server. Use only to *suggest* an address, then require the fingerprint or admin enrollment code to match before trusting it |

**If the server's IP changes**
- Agents show "server unreachable" on the lock screen (they already probe connectivity every 10 s).
- Staff bookmarks fail.
- Fix: restore the DHCP reservation, or update the local DNS name.
- Proposed tool: `compulab-config set-address <new-ip>` updates `ALLOWED_HOSTS` and `CSRF_TRUSTED_ORIGINS` in `.env`, restarts the web service, and regenerates the connection file.
- Agents need a new `server_url` unless a DNS name is used. **A DNS name avoids touching every PC.**

**Lab PC IP changes** (DHCP): today this breaks identification (audit M6). Use DHCP reservations for lab PCs too, until per-PC tokens replace IP-based identity. With tokens, the server can update the recorded IP from the token-authenticated request.

---

## 5. HTTPS on the LAN

Plain HTTP exposes passwords, session cookies and activation codes to anyone who can capture traffic: shared Wi-Fi, a compromised lab PC on a hub or mirrored port. Options:

| Option | Pros | Cons |
|---|---|---|
| A. HTTP, restricted to wired staff VLAN + VPN for everything else | No certificate work; matches today | Weak on shared Wi-Fi; depends on network segmentation the college may not have |
| B. **Caddy reverse proxy with an internal CA** (`tls internal`); the staff launcher installer adds Caddy's root CA to Windows' trust store | Real TLS on the LAN; automatic renewal; small single binary | Proxy changes `REMOTE_ADDR`. The agent API must either use per-PC tokens (planned) or bypass the proxy on a separate port. Each staff device must trust the root CA |
| C. Staff use Tailscale even on campus; `tailscale serve` provides HTTPS with a `*.ts.net` certificate | End-to-end encryption everywhere; one access path | Every staff device needs Tailscale, even on site; dependent on Tailscale's plan limits |

**Recommendation:** Option A plus the VPN in the first phases (no regression from today). Move to **Option B** once agent authentication is token-based. Then set `DJANGO_SECURE_SSL=True` and `DJANGO_BEHIND_PROXY=True`, with `SECURE_PROXY_SSL_HEADER` trusted only from `127.0.0.1`. Decision D8.

---

## 6. Remote access over the internet

| Approach | Security | Practicality | Fit |
|---|---|---|---|
| Hosted HTTPS central deployment | Good TLS, but the data lives off-campus and cannot control PCs | Already exists (MochaHost) | Only as an optional read-only mirror (see HYBRID §7) |
| **Tailscale** (managed WireGuard mesh) | End-to-end WireGuard encryption; no inbound ports; device and user ACLs (e.g. only the `staff` group may reach `server:8000`); SSO login | Install a client on the server and each remote device; free tier limits users, so check current plan terms (a paid or education plan may be needed). Self-hostable control server: Headscale | **Recommended** |
| WireGuard (self-hosted) | Same cryptography, full control | Needs one UDP port forwarded on the school router (or a public IP) and manual key management per device | Good if a managed service is not allowed and IT can open one UDP port |
| Reverse tunnel (e.g. Cloudflare Tunnel + Cloudflare Access) | No inbound ports; an identity gate (email one-time PIN or SSO) in front of Django; browser-only for users | TLS terminates at the provider, which can see the traffic; adds a dependency | Reasonable alternative if staff cannot install a VPN client. The college domain's DNS is reportedly already on Cloudflare (Assumption, from deployment notes) |
| Direct port forwarding of 8000 to the server | Exposes Django and waitress to internet scanning and brute force; plain HTTP unless TLS is added; one bug (like audit C1) is directly exploitable worldwide | Easy | **Do not use.** Never forward 3306 (database) or 5555 (agents) under any circumstances |

### How local and remote users interact (failure cases)

- **Normal:** LAN users and remote users use the **same server and database**, so everyone sees the same data immediately. There is nothing to synchronize.
- **Internet down:** LAN users are unaffected; remote users are cut off (the tunnel needs the internet); email waits in the outbox.
- **Server loses power or crashes:** **nobody** can use CompuLab, locally or remotely.
  - Lab PCs keep their current state: unlocked sessions continue until the agent's own timer ends; locked PCs stay locked.
  - The In-Charge can use the emergency manual-unlock tool.
  - Mitigate with a **UPS**, auto-restart services, and a tested restore procedure.
- **Remote access to the local server ≠ access to a separate hosted server.** The VPN reaches the *on-prem* machine, so it works only while that machine and the campus uplink are up. A separately hosted site would stay reachable during a campus outage, but it is a *different system with different data* unless a sync design is approved. That trade-off is why the hosted site is proposed only as a read-only mirror, if at all.

---

## 7. Installation and setup design (Deliverable 5)

### 7.1 Which computer is the server

- A dedicated, always-on machine, **not** a lab PC students use and not someone's daily laptop.
- Windows 10/11 Pro or Windows Server.
- 8 GB RAM or more; SSD; wired Ethernet.
- A UPS with enough runtime for a clean shutdown.
- A second disk, USB drive or NAS for backups.

### 7.2 Server installer

**Packaging:** an Inno Setup (or WiX) installer named `CompuLab-Server-<version>.exe`. It bundles:
- the app code;
- a fixed Python runtime (embeddable distribution);
- pre-built wheels for every dependency, including Windows wheels for `mysqlclient` and `waitress`;
- WinSW service wrappers;
- the MariaDB LTS MSI.

It works **offline**: no `pip` download during installation.

| Step | What it does |
|---|---|
| Pre-checks | Windows version, admin rights, free disk, port 8000 free, existing installation (→ upgrade mode) |
| Database | Installs **MariaDB 10.11 or 11.4 LTS** as a Windows service bound to `127.0.0.1`, or reuses an existing compatible server. Creates the database (`utf8mb4`) and a least-privilege app user with a random password. Loads time-zone tables (optional; the code already avoids `CONVERT_TZ`) |
| Configuration | Writes `.env`: random `DJANGO_SECRET_KEY`; DB credentials; `DJANGO_DEBUG=False`; `ALLOWED_HOSTS` and `CSRF_TRUSTED_ORIGINS` from detected LAN IPs and an optional DNS name; `SITE_URL`; agent enrollment key; SMTP settings (optional at install time; entered through a later admin page or wizard). File ACL: Administrators + SYSTEM only |
| Application | `manage.py migrate` (upgrade mode: backup first, then `migrate --plan` shown and logged), `collectstatic`, `check --deploy` (HTTPS warnings accepted in HTTP mode) |
| Services | `CompuLab Web` (waitress, `--listen=0.0.0.0:8000 --threads=8`, `COMPULAB_BACKGROUND_TASKS=False`) and `CompuLab Worker` (`manage.py run_worker`). Both start automatically and restart on failure with backoff. **Not** `runserver` |
| Firewall | Inbound TCP 8000 for the Private profile from configured subnets; nothing for 3306 |
| First admin | First-run wizard creates the superuser (interactive; password never written to logs) |
| Backups | Scheduled task (§7.5) |
| Health | Waits for `/healthz` to return OK; shows the URL, QR code and connection file location |
| Optional | Installs Tailscale and prompts for login; (later) Caddy for LAN TLS |

**Database choice: keep MariaDB/MySQL.** The models, migrations and the MySQL-specific workarounds in the code target MySQL; production already runs MariaDB 11.4. PostgreSQL would require a data migration and retesting for no feature this system needs. Retire XAMPP: it runs as a desktop app, not a supervised service, and its MariaDB 10.4 is what pins Django to the end-of-life 5.0. Standardize on **Django 5.2 LTS** everywhere (audit M8).

**Static and media:** WhiteNoise serves static files and Django serves `media/avatars/`. No IIS or nginx is needed for the LAN.

**Logging:** `logs/compulab.log` (rotating, already configured) plus service wrapper logs. Service start and stop failures go to the Windows Event Log.

### 7.3 Client installers

**There are two kinds of "client".** The important one already exists: the lab PC agent.

**(a) `CompuLab-Agent-<version>.exe`, for each lab PC**

| Item | Design |
|---|---|
| Runtime | Agent frozen with PyInstaller (or bundled embeddable Python). Installs to `C:\Program Files\CompuLab Agent`. No Python needed on the PC |
| Server address | Entered during setup, or read from `compulab-connection.json`; verified with `/healthz` before finishing |
| Enrollment | The Admin generates a one-time **enrollment code** for a specific PC record. The installer calls `POST /labs/api/agent/enroll` → the server returns a **per-PC token** (stored hashed server-side). The shared secret is retired |
| How it runs | The lock screen is a desktop window, so it **must run in the interactive user session**. A Windows service runs in Session 0 and cannot show UI. The NSSM option suggested in the current `agent.py` docstring would therefore not display the lock screen (Assumption, based on standard Windows session isolation; not tested with this agent). Interim: Task Scheduler "At log on" for the lab's standard (non-admin) account, restarted on failure. **Target:** split into a small privileged *service* (holds the token, talks to the server, listens on 5555) and an unprivileged *UI process* in the user session that talks to the service over a local pipe. The student account then cannot read the token |
| Firewall | Inbound 5555 and ICMP from the server IP only |
| Config protection | Token and config readable by SYSTEM and Administrators only (target design) |
| Updates | The installer upgrades in place, keeping the enrollment. The server can show each agent's version (reported on heartbeat) |
| Uninstall | Removes the task or service and the firewall rules; the Admin revokes the token |

**(b) `CompuLab-Launcher` for staff PCs (optional)**

- **Recommended:** the simplest reliable option, a tiny installer that saves the approved server URL and creates a Start-menu or desktop shortcut.
- An optional launcher executable checks `/healthz` on the LAN address first, then the Tailscale address. It shows "Connected (local)", "Connected (remote via VPN)" or "Server unavailable — retrying", then opens the default browser.
- It retries with backoff after interruptions and supports manual address entry.
- If LAN TLS (Option B) is adopted, it also installs the internal root CA.
- **Not recommended:**
  - an embedded-webview desktop app (adds a browser engine to maintain for no gain);
  - a full desktop client (duplicates the backend logic).

### 7.4 Updates

1. Download the new server installer (signed, versioned).
2. It stops the services, takes a **backup** (database + media + `.env` + current app folder), replaces the app, installs bundled wheels, shows and applies migrations, runs `collectstatic`, starts the services, and checks health.
3. **If health fails:** it restores the previous app folder automatically. The database is restored only with explicit admin confirmation, because restoring discards newer data.
4. Agents: deploy the new agent installer to lab PCs (manually, by USB or share, or by GPO if the college has AD). The server tolerates older agent versions for at least one release.

### 7.5 Backup and restore

- **Nightly** (Task Scheduler, as a low-privilege backup account): `mysqldump --single-transaction --routines` → compressed file + `media/` archive + `.env` copy, written to a second disk or NAS.
- **Retention:** 14 daily + 8 weekly + 6 monthly.
- **Optional:** an encrypted offsite copy when online.
- **Verification:** a weekly automatic restore into a scratch database (`compulab_restore_test`), comparing row counts per table; the result goes to the worker's status page. Alert if the last good backup is older than 36 h.
- **Restore tool** (`compulab-restore.ps1`): stop services → restore the chosen dump into the database → restore media → start → health check. A written runbook goes with it.

### 7.6 Recovering from a server crash

| Failure | Recovery |
|---|---|
| Process crash | Services auto-restart; durable jobs and the outbox resume |
| OS crash or power loss | MariaDB InnoDB crash recovery on boot; services start automatically; UPS to avoid it |
| Hardware failure | Install the server package on a replacement machine → restore the latest backup → move the DHCP reservation (or DNS name) to the new machine. Lab PCs and staff clients need no change if they use the DNS name, or if the IP is kept |

### 7.7 Preventing unauthorized devices and users

- **Staff:** access is controlled by accounts and roles, not devices. Optionally restrict port 8000 to staff and lab subnets with Windows Firewall.
- **Lab PCs:** only enrolled PCs (one-time enrollment code from an Admin → per-PC token) can call agent APIs. The Admin can revoke a PC's token. Unknown devices are rejected even if they know the server URL.
- **Agents** accept commands only from the server's IP (firewall), only with a valid signature from the server (HMAC with the per-PC key, timestamp and nonce), and never from browsers (drop CORS `*`).
- **Remote:** Tailscale ACL limits which users and devices can reach `server:8000`. Remove departed staff from the tailnet as well as from CompuLab.
- **Emergency tool:** `manual_unlock.html` must stop relying on a shared secret. Replace it with a per-In-Charge emergency code, or a signed one-time unlock code per PC printed in advance (decision D9).
