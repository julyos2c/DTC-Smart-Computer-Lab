> **2026 Cloud monitoring + inventory:** [CLOUD_LIVE_STATUS_INVENTORY.md](CLOUD_LIVE_STATUS_INVENTORY.md) — Cloud PC live snapshots, stale status, and secure Edge-approved equipment/PC inventory edits.

# CompuLab — DTC Smart Computer Laboratory

CompuLab manages a school computer laboratory: staff accounts and roles, lab schedules and
reservations, class rosters and attendance, PC usage logs, inventory, issue reports and reports —
plus a **lock screen on every student PC** that opens only for a student with a valid reservation
(Student ID + reservation code) or when staff unlock it.

It runs on **one server computer on the campus network**. Lab PCs and staff computers connect to it
over the LAN; daily work does not need the internet.

| Part | Runs on | Installed with |
|---|---|---|
| Website, MariaDB database, background worker | the **Server PC** (Windows) | `CompuLab-Server-Setup-<version>.exe` |
| Lock-screen agent (`CompuLabAgent.exe`, no Python needed) for the students' Windows accounts | every **Lab PC** | `CompuLab-Agent-Setup-<version>.exe` |
| — | staff computers | nothing: a web browser |

## Where to start

**Installing at the school (no programming needed):**

1. [docs/COMPULAB_QUICK_START.md](docs/COMPULAB_QUICK_START.md) — the ordered checklist.
2. [docs/COMPULAB_BEGINNER_INSTALLATION_GUIDE.md](docs/COMPULAB_BEGINNER_INSTALLATION_GUIDE.md) —
   every step explained: prerequisites, hash check, SmartScreen, Python, MariaDB, server setup,
   firewall, lab PCs, tests, maintenance, troubleshooting, acceptance checklist.
3. [docs/RELEASE_READINESS.md](docs/RELEASE_READINESS.md) — what has been tested automatically and the
   administrator checks still to do on real machines.

**Release status:** the current source (branch `phase1-security-fixes`) adds a student-only lock
screen, an own agent secret per lab PC, a remembered backup folder, a database port field and a
verified first Administrator (details in `docs/RELEASE_READINESS.md`). **The last built release,
2026.10.23.0537, does not contain these fixes — a new installer build is required before the school
installation.** A build's files, sizes and SHA-256 hashes are listed in
`installer/dist/DISTRIBUTION-MANIFEST-<version>.md` on the build PC (`installer/dist` is not stored
in git).

After the new build: ready for a *supervised* first installation. The Windows services, firewall
rules, scheduled tasks, student group, lock screen and recovery after reboots/outages have not yet
been verified on real school computers, and the setup programs are not code-signed.

## More documentation

| Topic | File |
|---|---|
| Installer details (server) | [installer/server/README.md](installer/server/README.md) |
| Installer details (lab PC agent) | [installer/agent/README.md](installer/agent/README.md) |
| Overview of all installers, building and testing them | [installer/README.md](installer/README.md) |
| LAN / offline / recovery checks on real machines | [docs/MANUAL_VERIFICATION.md](docs/MANUAL_VERIFICATION.md) |
| Shorter deployment guide | [docs/SCHOOL_DEPLOYMENT_GUIDE.md](docs/SCHOOL_DEPLOYMENT_GUIDE.md) |
| Optional remote access (Tailscale; not tested on real machines) | [installer/REMOTE_ACCESS.md](installer/REMOTE_ACCESS.md) |
| Design and audit notes | `docs/SYSTEM_AUDIT.md`, `docs/HYBRID_ARCHITECTURE.md`, `docs/IMPLEMENTATION_ROADMAP.md` |

Optional cloud synchronisation (`cloud_sync/`) has only a sending side; no receiver exists, so it
stays switched off.

## For developers

- Django 5.2 (see `requirements-production.txt`), Python 3.13 in production, MariaDB/MySQL.
- Settings come from `.env` (template: `.env.example`; never commit the real one).
- Apps: `accounts`, `labs`, `scheduling`, `issues`, `notifications`, `system`, `cloud_sync`; the lab PC
  agent is in `lab_pc_agent/`; Windows installers in `installer/`.
- Tests: `python manage.py test`, `python -m unittest discover -s lab_pc_agent\tests`, and the
  installer tests in `installer/tests/` (see `installer/README.md`; `stage-test-payload.ps1` tests
  uncommitted installer changes without a release build).
- Lab PC agents authenticate with a per-PC secret (`labs/agent_auth.py`); `manage.py agent_secret`
  lists or rotates them. The installer's first-Administrator step is `manage.py ensure_admin`.
- Building the setups: `installer\build\build-installers.ps1` (needs a clean, committed working tree);
  checking a build: `installer\build\verify-dist.ps1`.

Remote PC control setup: [docs/CLOUD_REMOTE_CONTROL.md](docs/CLOUD_REMOTE_CONTROL.md).

One-laptop simulated cloud demo: [docs/LOCAL_REMOTE_DEMO.md](docs/LOCAL_REMOTE_DEMO.md).

Cloud/edge reservation management: [docs/BIDIRECTIONAL_RESERVATIONS.md](docs/BIDIRECTIONAL_RESERVATIONS.md).


## Reservation change — no capacity

See `NO_AVAILABLE_PC_UPDATE.md`. If zero PCs remain, new local or Cloud reservations are rejected with **No available PCs** instead of being saved as Pending. Requests that become full before approval are marked Declined. Partial PC allocation remains enabled when at least one PC is free.
