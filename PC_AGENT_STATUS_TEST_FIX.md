# PC Agent Status Page Test Fix

This update is based on **CompuLab_Cloud_Live_PC_Inventory_FULL.zip** and retains the Cloud live PC monitoring, inventory synchronization, and partial/no-capacity reservation changes.

## Failure resolved

Previously, `labs.test_agent_auth.SystemStatusSecretSummaryTests.test_status_page_shows_secret_migration` failed because the System Status HTML had been redesigned but the existing test still expected a detailed agent-secret migration summary and pending-migration text.

The System Status page now shows:

- `Agent secrets: X of Y PCs use their own secret` in the PC agents section.
- `Setup pending — agent not yet reinstalled or authenticated with its individual key` when an individual key exists but the agent has not authenticated with it yet.
- `Individual key` when the device has authenticated with its own key.
- `Shared key` when the device has not yet been issued its own key.

No secrets are shown in the response, and agent authentication rules were **not** changed.

## Files changed

- `compulab/templates/system/status.html` — user-facing summary and migration status description.
- `labs/test_agent_auth.py` — new regression test for mixed agent key states and non-disclosure of credentials.

No database migrations or `.env` modifications are required.

## Install on Windows / PowerShell

1. Back up your CompuLab directory and database before updating.
2. Extract the patch ZIP into the **parent directory** containing `DTC-Smart-Computer-Lab` and allow replacement of the two files. (If your project folder has a different name, copy the two files to their matching paths manually.)
3. Leave your existing `.env`, virtual environment, and database untouched.
4. Inside your CompuLab directory, run:

```powershell
.\.venv\Scripts\Activate.ps1
python manage.py check
python manage.py test labs.test_agent_auth
```

5. Restart the Django web server; restart the worker as part of your normal deployment procedure.

## Validation

- Focused status summary tests: **3/3 passed**.
- Entire Django test suite: **217/217 passed** on isolated SQLite test configuration.
- No deployment or physical-PC-Agent tests were performed on school hardware.
