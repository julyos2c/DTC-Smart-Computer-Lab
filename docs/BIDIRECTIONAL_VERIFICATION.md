# Verification - bidirectional reservations

- 126 regression tests passed; Django system checks passed without silenced checks.
- Migration consistency: no changes detected.
- Runtime used for verification: Python 3.12, Django 5.0.14, SQLite.
- Tested cloud/edge intent validation, account and admin permissions, CSRF, overlap/capacity/hours/past-date checks, revision conflicts, duplicate create/approve/cancel, transactional rollback, durable outbox, expiry, outage retry, and existing scheduling/PC-command/authentication behavior.
- Separate-process verification used distinct cloud.sqlite3 and edge.sqlite3 files: cloud create, edge-local edit to cloud, cloud update, cloud approve, and cloud cancel all passed. It exercised real Django endpoints, serializers and persistence with JSON transport simulated between processes.
- Live HTTP and a MySQL/MariaDB deployment were not exercised in this restricted coding environment. Test the provided local launcher on your machine before school deployment. PC agent actions in automated tests were simulated.

Regression command (using an isolated SQLite settings module for this environment):

    python manage.py test cloud_receiver cloud_sync system.tests labs.test_agent_auth scheduling.tests accounts.test_permissions

The included new reservation tests are cloud_receiver/test_reservations.py. The demo launcher auto-configures separate databases, keys and a sample student; see docs/BIDIRECTIONAL_RESERVATIONS.md.
