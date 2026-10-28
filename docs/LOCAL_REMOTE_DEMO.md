# Local demo on one laptop (no cloud deployment)

This demo starts two Django servers, two separate SQLite databases, and a simulated PC agent. It does not lock Windows, block hotkeys, restart, or shut down the laptop. The edge polls the cloud through the actual command transport.

## 1. Extract and open PowerShell

Extract `DTC-Smart-Computer-Lab-local-demo.zip`. Open PowerShell inside the extracted `DTC-Smart-Computer-Lab` folder, where `manage.py` is located. Python 3.11-3.13 is supported for this demo with the project's Django 5.0 dependency. Prefer Python 3.13; if `py -3.13` cannot be found, install that interpreter first.

## 2. Prepare the environment (one time)

```powershell
py -3.13 -m venv .venv-demo
.\.venv-demo\Scripts\python.exe -m pip install -r tools\requirements-local-demo.txt
```

This demo uses SQLite, so MySQL/XAMPP is not needed. You do not need to create or edit `.env`. Existing production databases are not used. The launcher creates its own settings and random temporary credentials.

## 3. Start the demo

```powershell
.\.venv-demo\Scripts\python.exe tools\local_remote_demo.py
```

Leave this PowerShell window open. It displays the admin email and a randomly generated password. A new password is generated whenever the demo starts.

Services:

| Component | Address |
|---|---|
| Simulated cloud admin | http://127.0.0.1:8001/admin/cloud_receiver/remotecommand/ |
| Edge admin | http://127.0.0.1:8000/admin/ |
| Simulated PC agent | 127.0.0.1:5556 |

The launcher binds these services only on the laptop's loopback address. It checks that their ports are free before starting. Stop another local server first if you see `Port ... is busy`.

## 4. Send a command

1. Open the cloud admin address in your browser.
2. Login using email `localdemo@gmail.com` and the password printed in PowerShell.
3. Click **Add remote command**.
4. Fill in **Site id** = `local-demo`.
5. Fill in **Pc pk** using the **Demo PC database ID** printed by the launcher (normally `1`). This is not the text `DEMO-PC`.
6. Choose **Lock**. Keep the default expiry, then click **Save**.
7. Wait a few seconds and refresh the command list.
8. Expect **accepted**, and a PowerShell message like:

```text
[SIMULATED AGENT] LOCK received; no Windows action performed.
```

That proves cloud queue -> edge -> agent -> cloud result. `accepted` means the simulated agent acknowledged the signal. Your actual screen stays available because this demo does not run a real lock screen.

The demo worker polls every second. Shutdown and restart also just print messages in this simulated agent. Unlock is normally `failed` in this fresh demo because no active local session/user is assigned; the code keeps its local session validation.

## 5. Optional automatic smoke test

Stop the running demo with Ctrl+C, then run:

```powershell
.\.venv-demo\Scripts\python.exe tools\local_remote_demo.py --smoke-test
```

This starts the same components, creates one lock command, waits for `accepted`, prints a PASS line if successful, and stops the services automatically. A nonzero exit means the test failed; inspect the logs.

## 6. Stop and inspect

Press **Ctrl+C** in the launcher window to stop its cloud, edge, worker, and simulated agent. The launcher does not install Windows services or scheduled tasks.

The demo stores its databases and logs under `.local_remote_demo` in the extracted project folder:

- `cloud.sqlite3` and `edge.sqlite3`: separate demo databases.
- `cloud.log`, `edge.log`, `worker.log`: startup and connection troubleshooting.
- `pc.json`: the demo PC's numeric ID.

Pending commands from a previous demo run are expired on startup. The demo settings use distinct browser session/CSRF cookie names for cloud and edge to avoid logins interfering with each other on the same hostname.

## How this differs from a real PC test

This is an end-to-end **command transport demo with a simulated agent**. To validate actual screen locking, use the real agent on a separate test machine and follow `docs/CLOUD_REMOTE_CONTROL.md`. Do not point an unrestricted local HTTP exception at LAN/public cloud servers: the new `EDGE_REMOTE_CONTROL_ALLOW_LOCAL_HTTP` option permits only loopback hosts and is off in normal settings. The demo opts in automatically. A remote/cloud deployment still requires HTTPS.

## Verification of this update

Regression tests cover loopback opt-in, rejection of LAN/public HTTP URLs even when the option is on, disabled-by-default behavior, and the existing remote-command/authentication/worker tests. The current coding environment blocks local socket connections, so a live HTTP smoke-test result could not be confirmed here. Run the optional smoke test above on your laptop.
