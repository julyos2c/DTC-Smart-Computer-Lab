# CompuLab plug-and-play and hybrid audit (23 October 2026)

Audit of the Windows installers and the local/online architecture, with what was changed and what
was verified. Starting point: branch `phase1-security-fixes`, commit `7e93677` (pushed), with
uncommitted installer fixes for database tools and other programs' databases on top. Nothing here is
committed, pushed, released or deployed.

**Status in one line:** the server setup can now install CompuLab completely offline with its own
Python and its own MariaDB, and this was verified end to end without administrator rights; the
administrator-only parts (Windows services, firewall, ACLs, reboot) and anything involving real
school PCs or a deployed cloud receiver are **not** verified. CompuLab is therefore **not** "fully
plug-and-play hybrid" yet (section 7).

## 1. Audit table

| Component | Existing implementation (before this work) | Verified evidence (this work) | Missing work | Changes made | Internet during install? |
|---|---|---|---|---|---|
| Server setup (Inno Setup 6.7.3) | `CompuLab-Server.iss`; payload = app files + WinSW + 19 wheels; runs `install-server.ps1` | interim candidate builds verified by `verify-dist.ps1`; packaged test builds installed by the e2e tests | code signing; admin-level run on a real PC | stops CompuLab **and its database** before replacing files (`stop-compulab.ps1`); `runtime\` replaced on update; data never deleted; database port default 3308; `/DBMODE` | no |
| Python runtime | **not bundled**: Python 3.11–3.13 had to be installed first; venv + pip from bundled wheels | bundled e2e: `OK: Python 3.13.16 with Django 5.2.18, bundled` | — | `runtime\python` = official embeddable 3.13.16 (SHA-256 pinned), packages pre-installed at build time, `.pyc` unchecked-hash; manifest-checked at install | no |
| Database server | **not bundled**: an existing MariaDB/MySQL + its root password were required | bundled e2e (fresh install, ports, repair, update, uninstall/reinstall) | admin-level service run on a real PC | `runtime\mariadb` = official MariaDB 11.4.13 Windows x64 files (subset, unmodified, SHA-256 pinned, GPL notice + source URL); own data dir, own `my.ini`, own service `CompuLabMariaDB` | no |
| Database client/server match | tools found by name; MySQL's tools could run against MariaDB | logic tests; e2e backup header `Distrib 11.4.x-MariaDB` | — | `Find-DbClient` takes tools from the folder of the server on `DB_PORT` | — |
| Other databases on the PC | external mode refused XAMPP / non-DB programs | logic test against this PC's real services (read-only); e2e "other database servers unchanged" | — | another program's database service (e.g. InventoryDatabase) refused untouched; port owner checked before any service is started/changed; the bundled DB skips busy ports | — |
| Django DB config | `DB_*` from `.env` | Django 112+ tests; e2e migrations | — | none (settings unchanged except the receiver) | — |
| Migrations | 22+ per app, applied by the installer after a backup (repair/update) | e2e: all project migrations applied on the bundled MariaDB | — | new `cloud_receiver 0001` (2 tables) | — |
| Authentication / sessions | Django auth in the local DB; Gmail-only rule; in-person activation and reset codes | existing tests | — | none | — |
| Database access paths | Django ORM (app user); installer (root/admin); backup/restore (app user + dump/client) | e2e: app user has rights on `compulab_db` only; root local only | — | bundled: root sign-in only via `data\db-admin.cnf` (Admins/SYSTEM) | — |
| Cloud sync sender | `cloud_sync`: durable `SyncQueue`, `edge_id` idempotency, sequence, coalescing, lease, backoff, pause on 401/403/404, conflicts with Admin decisions, `/system/cloud-sync/` | `cloud_receiver/tests.py` end-to-end | a deployed receiver | none | — |
| Cloud receiver | **did not exist** (PROTOCOL.md described it) | 23 receiver + end-to-end tests | deployment, HTTPS endpoint, keys (needs approval) | new app `cloud_receiver` (off by default) | — |
| Email | `EmailOutbox` queue, resumed when SMTP/internet returns | existing tests | — | none | — |
| Lab PC agent | packaged `CompuLabAgent.exe` (PyInstaller), per-PC secret, retry queue, student-only lock screen | agent e2e 16/16 (non-admin) | real lab PCs | none | no |
| LAN access | waitress on 0.0.0.0:port; firewall rule TCP port from private ranges, Private/Domain | logic tests (`New-NetFirewallRule -WhatIf`) | real-machine check | DB port explicitly never opened; bundled DB listens on 127.0.0.1 (e2e verified) | — |
| Startup / restart | WinSW services (delayed auto start, restart on failure, depend on the DB service); scheduled backup task | logic tests (definitions, not installed) | reboot test on a real PC | `CompuLabMariaDB`: auto start, own virtual account, SCM recovery; Web/Worker depend on it | — |
| Backups / restore | `backup.ps1` (mysqldump, retention, `-Log`), `restore.ps1` (safety backup first, confirmation) | bundled e2e: backup with the bundled `mariadb-dump`, restore into the dedicated instance | — | tools of the server on the port | — |
| Health / status | `/healthz`, `/healthz/ready`, System status, `server-status.ps1` | e2e `/healthz/ready` database OK | — | status: "Database port ... on 127.0.0.1 only" for the bundled DB | — |
| Permissions | `.env` ACL (names); program folder inherited `C:\` ACL (Authenticated Users: Modify) | logic tests (arguments) | applied on a real PC (admin) | ACLs by SID; `db-admin.cnf` protected; data dir: Admins/SYSTEM/service only; program folder: users read-only (when services are installed) | — |
| Release integrity | SHA256SUMS, BUILDINFO, manifest, clean-tree check | `verify-dist.ps1` | code signing certificate | runtime versions/hashes in BUILDINFO + manifest; per-file runtime manifests; `-AllowDirty` reports an UNAPPROVED CANDIDATE | — |

### What is bundled vs downloaded

- **In the server setup (offline):** CompuLab code, WinSW 2.12.0, Python 3.13.16 embeddable with
  Django 5.2.18 + mysqlclient 2.3.0 + Pillow + reportlab + openpyxl + waitress + whitenoise +
  python-dotenv, MariaDB 11.4.13 server (`mariadbd.exe` + `server.dll`), its client, dump, admin,
  install-db, upgrade, check tools, plugins (minus RocksDB/CONNECT/Spider), `share\` (error messages,
  charsets, system-table scripts), VC++ runtime DLLs, licences. The 19 wheels stay in the payload for
  the venv fallback (plain folder copies).
- **Downloaded only by the build (developer PC):** the MariaDB ZIP, the Python embeddable ZIP and
  WinSW, each checked against its pinned SHA-256 (`build-installers.ps1`), plus the wheels (pip).
- **Is the complete MariaDB server included?** Yes — the server program (`mariadbd.exe`, which is a
  13 KB launcher, and `server.dll`, the actual server, 19.8 MB) plus `mariadb-install-db.exe`,
  plugins and `share\`; not just a client. The bundled e2e test creates, starts, backs up, restores,
  upgrades and stops a server from exactly these files.
- **Licence:** MariaDB Server is GPL v2. The setup ships the unmodified binaries with `COPYING`,
  `THIRDPARTY` and `SOURCE.txt` (exact source URL). Distributing GPL binaries obliges the distributor
  to provide the corresponding source on request (or with the binaries): **decide whether to keep a
  copy of `mariadb-11.4.13.tar.gz` with each release** (recommended; not done automatically).
  Python: PSF licence (`runtime\python\LICENSE.txt`).

## 2. The dedicated database (as implemented)

| Requirement | Implementation | Verified by |
|---|---|---|
| own directory, data, config | `runtime\mariadb` (program), `data\mariadb` (data + `my.ini`, rewritten on repair) | bundled e2e |
| own service | `CompuLabMariaDB`, `NT SERVICE\CompuLabMariaDB`, auto start, recovery | logic test (definition); **not registered on this PC** |
| 127.0.0.1 only | `bind-address=127.0.0.1` in `[mysqld]` (whole file written: appending landed in `[client]` in a probe) | e2e listener check; installer refuses to continue otherwise |
| port 3308 or next free, never touching the occupier | `Select-DbPort` | logic tests (busy 3308/3309/3310; none free) + read-only check on this PC; e2e with two busy ports |
| never reuse another server | own data dir only; another program's DB service refused in external mode | logic + e2e |
| `compulab_db` + restricted user | `Get-DbSetupSql` via the admin sign-in; grants on `compulab_db.*` only | e2e `SHOW GRANTS` |
| strong random passwords | 32 characters from `New-RandomSecret` (.NET cryptographic `RandomNumberGenerator`, about 188 bits) for root and the app user | e2e |
| no passwords in logs / command lines | stdin only (UTF-8 **without BOM** — a real bug found and fixed), output masked | e2e scans every process command line and log; logic test reproduces the BOM case |
| root secured before listening | `--bootstrap` (no network): `FLUSH PRIVILEGES` (bootstrap runs with skip-grant-tables — a real bug found and fixed), root password, remove root@<computer name> (created passwordless by install-db) and anonymous users | probe + e2e account list |
| idempotent / no data loss | data never re-initialized; marker file; repair, update, uninstall + reinstall keep data | e2e |
| interrupted install | half-created data dir moved aside (kept); lost `db-admin.cnf` reset offline | e2e |
| start failure | reported with the database's own log; data unchanged | e2e (read-only `ibdata1`) |
| damaged/missing package | per-file SHA-256 manifest checked before any change | e2e + logic |
| invalid checksum at build | download with another hash refused and deleted | logic test (`Get-VerifiedDownload` with a stubbed download) |
| migrations only on the verified DB | migrate runs after the sign-in to CompuLab's own server succeeded | e2e |

## 3. Hybrid architecture (traced in code)

- **Local (campus server, authoritative for everything):** users and roles, labs, PCs and per-PC
  secrets, schedules, reservations, sessions, rosters, attendance, issues, inventory, PC activity
  logs, notifications, email outbox, sync queue. Lab PCs and staff use it over the LAN
  (`http://<server>:8000`).
- **Online:** the public site `compulab.danaotechnologicalcollege.com` (MochaHost) is a **separate,
  independent CompuLab installation** with its own database and accounts. Nothing is synchronized
  between it and a campus server. It is not authoritative for any campus data.
- **Sync engine:** one-way campus → cloud (`cloud_sync`), designed for a read-only cloud copy. Now
  with a receiver (`cloud_receiver`) — **implemented and tested, not deployed**; the online site does
  not run it and no campus server is configured to send. There is no cloud → campus direction (by
  design: no merge, no silent last-write-wins).
- **Offline queueing:** yes (`SyncQueue` rows, durable; sent after the transaction commits).
- **Retry/backoff:** 30 s doubling to 30 min; network errors never charge a row; 401/403 and
  404/405/410 pause until settings change or an Admin retries; 413 halves the batch; per-record
  rejected/conflict.
- **Duplicates:** `edge_id` idempotency + per-record sequence; a lost reply is resent and answered
  `duplicate` (tested).
- **Conflicts:** a cloud copy edited on the cloud side answers `conflict`; the Admin chooses "keep
  campus copy" (sent again forced) or "keep cloud copy" (not sent) — tested.
- **Connectivity checks:** TCP probe to `COMPULAB_INTERNET_PROBE` (default 1.1.1.1:443) and
  `GET <receiver>/api/ping/` — the actual endpoint, not the adapter state; recovery triggers
  `sync.resume()` and `outbox.resume()` (`system/worker.py`).
- **Never sent:** reservation codes, passwords, agent secrets (payload whitelists; tested).
- **Authentication offline:** local Django auth; staff activation and password reset have in-person
  one-time codes; email verification links need SMTP (wait in the outbox).

### Offline-supported functions

Supported with the internet down (local server + LAN): sign-in, all lab/schedule/reservation/
session/roster/attendance/issue/inventory/report functions, lab PC lock/unlock/agents, activity logs,
backups, System status, in-person account activation and password reset codes.

Not available offline (and shown as such on System status): sending email (queued), the cloud copy
(queued, if ever configured), Tailscale remote access, anything on the separate public website.

## 4. Server and client PCs

- Services start at boot: `CompuLabMariaDB` (auto) → `CompuLab Web` / `CompuLab Worker` (delayed
  auto, depend on it), restart on failure; scheduled nightly backup as SYSTEM (also after a missed
  run). Definitions tested; **not run on a real PC**.
- LAN: firewall rule for the web port only, private ranges, Private/Domain; the database port is
  never opened and the bundled DB listens on 127.0.0.1. No router port forwarding needed.
- Clients: browsers at the documented campus address; lab PC agents reconnect and send queued events
  when the server answers again (agent tests).

## 5. Startup, repair, backups

See the guide (sections I, L, Q, R). New: `stop-compulab.ps1`; Repair re-applies the database
configuration and ACLs without touching data; `mariadb-upgrade` after updates; the setup stops
CompuLab and its database before replacing files; uninstall stops the database and keeps `data\`.

## 6. Tests

Totals are in the final report of this work and in `docs/RELEASE_READINESS.md` ("Bundled runtime").
Everything ran on the development PC **without administrator rights**, with disposable folders on
D: and disposable MariaDB/MySQL processes (no service registered, no MySQL84/InventoryDatabase
change — verified by the bundled e2e test).

## 7. Not verified / blockers

1. **Administrator-level behaviour on a real Windows PC:** registering and starting `CompuLabMariaDB`
   under its virtual account, data-folder and program-folder ACLs, service dependencies and recovery,
   firewall rule, scheduled task, reboot and power-failure recovery. Untestable here without
   installing services on this PC (not allowed); the definitions are unit-tested.
2. **Real LAN clients** (staff browsers, lab PCs) against a server installed with this setup.
3. **Online synchronization** is implemented on both sides but **not deployed**: it needs an HTTPS
   receiver (deploying `cloud_receiver` to a server, its migration, keys) — a production change that
   needs approval — and a decision on what the public site should show (the replica has only Django
   admin views).
4. **Code signing:** the setups are unsigned (SmartScreen "Unknown publisher").
5. **GPL source availability** for the bundled MariaDB (section 1).
6. **Disk space:** the server setup grows to about 70 MB; the installed program with runtime is
   about 400 MB.
