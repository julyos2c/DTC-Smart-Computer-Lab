"""
CompuLab Lab PC Agent (with built-in lock screen)
===================================================

Runs on EVERY lab PC (not on the server). Two jobs in one small program:

  1. Shows a fullscreen "PC Locked" overlay the moment it starts, blocking
     the desktop underneath — no separate kiosk software needed.
  2. Listens on a local port for signed requests from the CompuLab server.
     When a student is verified, the server sends "/unlock" and this agent
     hides the overlay. The server can also send "/lock" to re-lock the PC
     remotely (e.g. when a reservation/session ends).

Honesty check, please read: this is an APPLICATION-level lock (a window
sitting on top of everything), not real OS-level security. Someone who
knows to press Ctrl+Alt+Delete and open Task Manager can still end the
`python.exe`/`agent.exe` process and get to the desktop. This is the same
limitation basic kiosk lock tools have out of the box — if you need it to
be harder to bypass, that requires additional Windows admin/group-policy
lockdown (disabling Task Manager, restricting Ctrl+Alt+Del options, running
as a locked-down standard user account, etc.), which is a separate,
site-specific hardening step beyond what a script alone can do.

Requires only the Python standard library (tkinter ships with the normal
Windows Python installer) — nothing to `pip install`, EXCEPT for one
optional feature: reading the browser's address bar (so the PC Activity
Log can identify sites like ChatGPT/Claude that never put their own name
in the window title). That needs:
     pip install uiautomation
If you skip this, the agent still runs fine — window-title tracking keeps
working exactly as before, just without the extra URL-based accuracy.

--------------------------------------------------------------------------
SETUP ON EACH LAB PC
--------------------------------------------------------------------------
1. Copy this whole `lab_pc_agent` folder to the PC (e.g. C:\\CompuLabAgent).
2. (Optional, for accurate site detection in the PC Activity Log)
   Run:  pip install uiautomation
3. Create `agent_config.local.json` (never committed) next to agent.py:
       {"secret": "<EXACTLY the server's PC_AGENT_SHARED_SECRET from its .env>"}
   The agent refuses to start without it. Then edit `agent_config.json`:
     - "port"    -> must match PC_AGENT_PORT on the server (default 5555)
     - "lock_title" / "lock_subtitle" -> the text shown on the lock screen
4. Test manually first:  python agent.py
   A fullscreen "PC Locked" screen should appear immediately.
5. Once it works, set it to run automatically at every startup — see
   "RUNNING AS A STARTUP SERVICE" below.
6. Allow inbound connections on the chosen port (default 5555) for
   python.exe through Windows Firewall, at least on the lab's network.
--------------------------------------------------------------------------
RUNNING AUTOMATICALLY
--------------------------------------------------------------------------
Use the installer: installer\\agent\\install-agent.ps1 (see
installer\\agent\\README.md). It copies the agent to Program Files, writes
the per-PC settings, opens the firewall for the server only, and registers
a Task Scheduler task that starts pythonw.exe agent.py "At log on" and
restarts it if it stops.

The lock screen is a desktop window, so it must run in the signed-in
user's session ("At log on"). Do NOT run it as a Windows service (NSSM,
"Run whether user is logged on or not"): services run in Session 0 and
cannot show the lock screen to the person at the PC.
--------------------------------------------------------------------------
"""
import datetime
import json
import os
import queue
import random
import subprocess
import threading
import time
import tkinter as tk
import tkinter.font as tkfont
from tkinter import messagebox
import urllib.request
import urllib.error
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import hardening

try:
    from PIL import Image, ImageTk, ImageEnhance, ImageDraw, ImageChops, ImageFilter, ImageOps
    _PIL_AVAILABLE = True
except Exception:
    _PIL_AVAILABLE = False

import sys

# The folder agent.py lives in, or - for the packaged CompuLabAgent.exe built
# by installer\build\build-installers.ps1 (PyInstaller) - the folder of the
# .exe, so the config files and assets sit next to whichever one runs.
APP_DIR = (os.path.dirname(os.path.abspath(sys.executable)) if getattr(sys, 'frozen', False)
           else os.path.dirname(os.path.abspath(__file__)))
CONFIG_PATH = os.path.join(APP_DIR, 'agent_config.json')
# Per-PC values that must never be committed (above all "secret"). Gitignored;
# any key in it overrides the same key in agent_config.json.
LOCAL_CONFIG_PATH = os.path.join(APP_DIR, 'agent_config.local.json')

# Secrets that are public (placeholder, or published in git history) and so
# must never be accepted: anyone could send them to this PC's port.
REJECTED_SECRETS = {'', 'SET-IN-agent_config.local.json', 'danao_technological_college', 'PASTE-PC_AGENT_SHARED_SECRET-HERE'}

# Reported to the server on every call, so the PC status page shows which
# agent version each lab PC runs (useful after an update roll-out).
AGENT_VERSION = '2.2.0-ui1'

# Session-end callbacks that could not reach the server (network down,
# server restarting) are kept here and re-sent until the server confirms
# them, instead of being lost. Survives an agent restart, a reboot and an
# agent update/reinstall (the folder is outside the install folder).
def _writable_dir(path):
    try:
        os.makedirs(path, exist_ok=True)
        probe = os.path.join(path, '.write-test')
        with open(probe, 'w', encoding='utf-8') as f:
            f.write('ok')
        os.remove(probe)
        return True
    except OSError:
        return False


def _agent_data_dir():
    """Writable folder for the agent's own state. The installer puts the
    agent under Program Files, which the (non-admin) lab account can't write
    to, and creates C:\\ProgramData\\CompuLab Agent writable for every
    Windows user instead, so the queue is shared by whichever account is
    signed in. Falls back to that account's local app data, then the
    script folder."""
    candidates = [os.environ.get('COMPULAB_AGENT_DATA_DIR', '')]
    if os.environ.get('PROGRAMDATA'):
        candidates.append(os.path.join(os.environ['PROGRAMDATA'], 'CompuLab Agent'))
    if os.environ.get('LOCALAPPDATA'):
        candidates.append(os.path.join(os.environ['LOCALAPPDATA'], 'CompuLab Agent'))
    for path in candidates:
        if path and _writable_dir(path):
            return path
    return APP_DIR


DATA_DIR = _agent_data_dir()
PENDING_CALLBACKS_PATH = os.path.join(DATA_DIR, 'pending_callbacks.json')
# Written after every contact attempt; read by installer\agent\agent-status.ps1
# and `python agent.py --status`.
STATUS_PATH = os.path.join(DATA_DIR, 'agent_status.json')
# Older versions (2.1.x) kept the queue in the signed-in user's app data.
LEGACY_PENDING_PATH = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'CompuLab Agent', 'pending_callbacks.json')
# Retry backoff while the server is unreachable: 15 s doubling to 5 min.
PENDING_RETRY_MIN_SECONDS = 15
PENDING_RETRY_MAX_SECONDS = 300
PENDING_MAX_AGE_SECONDS = 24 * 3600   # a day-old "session ended" means nothing
PENDING_MAX_ITEMS = 200               # bounded: the oldest are dropped beyond this
_pending_lock = threading.Lock()
_status_lock = threading.Lock()
_flush_now = threading.Event()

# Commands passed between threads and the Tk main thread — Tk widgets can
# only safely be touched from the thread that created them, so neither the
# HTTP handler nor the login-submission thread ever calls into the UI
# directly; they drop a message here and the UI thread picks it up on its
# own polling loop. Kinds of messages:
#   'unlock' / 'lock'            -> from the HTTP server (remote lock/unlock)
#   ('login_result', dict)       -> from the on-screen login form's network call
#   ('pc_info', dict)            -> from fetch_pc_info_in_background (server-assigned pc_id/lab_name)
#   ('network_status', bool)     -> from check_network_in_background (can we reach the CompuLab server right now?)
#   ('override_warning', int, str) -> from the HTTP server (Admin/In-Charge Override); (seconds, admin_name)
_command_queue = queue.Queue()


def load_config():
    with open(CONFIG_PATH, 'r', encoding='utf-8') as f:
        config = json.load(f)
    if os.path.exists(LOCAL_CONFIG_PATH):
        with open(LOCAL_CONFIG_PATH, 'r', encoding='utf-8-sig') as f:
            config.update(json.load(f))
    if config.get('secret', '') in REJECTED_SECRETS:
        raise SystemExit(
            'CompuLab agent: no valid "secret" configured. Put the server\'s '
            'PC_AGENT_SHARED_SECRET in agent_config.local.json next to agent.py: '
            '{"secret": "..."}'
        )
    return config


class UnlockHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        if os.environ.get('COMPULAB_AGENT_VERBOSE'):
            super().log_message(fmt, *args)

    def _send(self, status, body):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Private-Network', 'true')
        self.end_headers()
        self.wfile.write(json.dumps(body).encode('utf-8'))

    def do_OPTIONS(self):
        # CORS preflight, needed so a browser-based control page (e.g. opened
        # from a phone) is allowed to call this agent's API.
        #
        # Access-Control-Allow-Private-Network is required on top of the
        # normal CORS headers because of Chrome's newer "Private Network
        # Access" (PNA) check: when a page (especially one opened from
        # file://, like manual_unlock.html) tries to fetch() a private/
        # local-network IP (like a lab PC's 192.168.x.x address), Chrome
        # sends this same OPTIONS preflight but ALSO requires this specific
        # header in the response before it'll let the real request through.
        # Without it, Chrome silently aborts the connection right after
        # connecting — which shows up here as the client resetting the
        # socket before sending any request line, and in the browser as a
        # generic "Failed to fetch" with no other explanation.
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Access-Control-Allow-Private-Network', 'true')
        self.end_headers()

    def _handle_signal(self, action):
        try:
            length = int(self.headers.get('Content-Length', 0))
            raw = self.rfile.read(length) if length else b''
            data = json.loads(raw or b'{}')
        except Exception:
            self._send(400, {'ok': False, 'error': 'bad request body'})
            return

        config = load_config()
        if data.get('secret') != config.get('secret'):
            self._send(403, {'ok': False, 'error': 'invalid secret'})
            return

        _command_queue.put(action)
        self._send(200, {'ok': True})

    def _handle_override_warning(self):
        try:
            length = int(self.headers.get('Content-Length', 0))
            raw = self.rfile.read(length) if length else b''
            data = json.loads(raw or b'{}')
        except Exception:
            self._send(400, {'ok': False, 'error': 'bad request body'})
            return

        config = load_config()
        if data.get('secret') != config.get('secret'):
            self._send(403, {'ok': False, 'error': 'invalid secret'})
            return

        try:
            seconds = int(data.get('seconds', 15))
        except (TypeError, ValueError):
            seconds = 15
        admin_name = str(data.get('admin_name') or 'An admin')

        _command_queue.put(('override_warning', seconds, admin_name))
        self._send(200, {'ok': True})

    def do_POST(self):
        if self.path == '/unlock':
            self._handle_signal('unlock')
        elif self.path == '/lock':
            self._handle_signal('lock')
        elif self.path == '/override-warning':
            self._handle_override_warning()
        elif self.path == '/shutdown':
            self._handle_signal('shutdown')
        elif self.path == '/restart':
            self._handle_signal('restart')
        else:
            self._send(404, {'ok': False, 'error': 'not found'})

    def do_GET(self):
        if self.path == '/ping':
            self._send(200, {'ok': True, 'status': 'agent running'})
        else:
            self._send(404, {'ok': False, 'error': 'not found'})


def start_http_server(port):
    server = ThreadingHTTPServer(('0.0.0.0', port), UnlockHandler)
    thread = threading.Thread(target=server.serve_forever, name='compulab-agent-http', daemon=True)
    thread.start()
    return server


# ---------------------------------------------------------------------------
# Connection status (shown on the lock screen and by agent-status.ps1)
# ---------------------------------------------------------------------------
def _now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec='seconds')


def _read_status():
    try:
        with open(STATUS_PATH, 'r', encoding='utf-8') as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def update_status(server_url, reachable, error='', **extra):
    """Persist the latest contact result. Never raises."""
    with _status_lock:
        data = _read_status()
        data.update(extra)
        data.update({
            'agent_version': AGENT_VERSION,
            'server_url': server_url,
            'server_reachable': bool(reachable),
            'checked_at': _now_iso(),
            'pending_events': pending_count(),
            'data_dir': DATA_DIR,
        })
        if reachable:
            data['last_contact_at'] = data['checked_at']
            data['last_error'] = ''
        else:
            data['last_error'] = str(error)[:300]
            data.setdefault('last_contact_at', None)
        tmp = STATUS_PATH + '.tmp'
        try:
            with open(tmp, 'w', encoding='utf-8') as f:
                json.dump(data, f, indent=2)
            os.replace(tmp, STATUS_PATH)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Reliable session-end callbacks
# ---------------------------------------------------------------------------
def _load_pending():
    try:
        with open(PENDING_CALLBACKS_PATH, 'r', encoding='utf-8') as f:
            items = json.load(f)
        return items if isinstance(items, list) else []
    except (OSError, ValueError):
        return []


def _save_pending(items):
    tmp = PENDING_CALLBACKS_PATH + '.tmp'
    try:
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(items, f)
        os.replace(tmp, PENDING_CALLBACKS_PATH)
    except OSError as e:
        print(f'[agent] Could not save pending callbacks: {e}')


def pending_count():
    return len(_load_pending())


def _trim(items, now=None):
    """Drop expired items and keep at most PENDING_MAX_ITEMS (oldest go)."""
    now = now or time.time()
    fresh = [i for i in items if now - i.get('queued_at', now) <= PENDING_MAX_AGE_SECONDS]
    expired = len(items) - len(fresh)
    if expired:
        print(f'[agent] Dropped {expired} queued event(s) older than 24 hours.')
    if len(fresh) > PENDING_MAX_ITEMS:
        print(f'[agent] Queue full: dropped the {len(fresh) - PENDING_MAX_ITEMS} oldest event(s).')
        fresh = fresh[-PENDING_MAX_ITEMS:]
    return fresh


def migrate_legacy_queue():
    """Move events queued by agent 2.1.x (per-user folder) into DATA_DIR."""
    if not LEGACY_PENDING_PATH or os.path.abspath(LEGACY_PENDING_PATH) == os.path.abspath(PENDING_CALLBACKS_PATH):
        return
    try:
        with open(LEGACY_PENDING_PATH, 'r', encoding='utf-8') as f:
            legacy = json.load(f)
    except (OSError, ValueError):
        return
    if isinstance(legacy, list) and legacy:
        with _pending_lock:
            items = _load_pending()
            known = {i.get('body', {}).get('event_id') for i in items}
            items.extend(i for i in legacy if i.get('body', {}).get('event_id') not in known)
            items.sort(key=lambda i: i.get('queued_at', 0))
            _save_pending(_trim(items))
    try:
        os.remove(LEGACY_PENDING_PATH)
    except OSError:
        pass


DELIVERED, RETRY, DROP = 'delivered', 'retry', 'drop'


def _post_callback(server_url, item, timeout):
    """POST one queued callback. Returns (outcome, detail):
      DELIVERED - the server confirmed it (its reply names this event_id,
                  also when it already had it or ignored it as out of date);
      RETRY     - not reached, timed out, or a temporary server error
                  (5xx, 429, or a reply that is not a confirmation);
      DROP      - the server answered that it can never accept it (bad
                  request, wrong secret, PC not registered): retrying the
                  same event would not help, and the reason is logged."""
    body = dict(item['body'])
    # How long ago the event really happened, measured on this PC's own
    # clock (no clock sync needed): the server uses it to ignore a late
    # callback if the PC has been in use again since then.
    body['queued_seconds_ago'] = max(0, int(time.time() - item['queued_at']))
    body['pending_events'] = pending_count()
    request = urllib.request.Request(
        server_url.rstrip('/') + item['path'], data=json.dumps(body).encode('utf-8'),
        headers={'Content-Type': 'application/json'}, method='POST',
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(65536)
    except urllib.error.HTTPError as e:
        if e.code == 429 or e.code >= 500:
            return RETRY, f'server error {e.code}'
        return DROP, f'server refused it (HTTP {e.code})'
    except Exception as e:
        return RETRY, f'server unreachable ({e.__class__.__name__})'
    try:
        reply = json.loads(raw.decode('utf-8'))
    except (ValueError, UnicodeDecodeError):
        return RETRY, 'unexpected reply (not CompuLab?)'
    event_id = body.get('event_id')
    if reply.get('ok') and (reply.get('ack') == event_id or not event_id):
        return DELIVERED, reply.get('ignored', '')
    if reply.get('ok'):
        # A server older than agent 2.2 answers ok without "ack"; it did
        # apply the event, so treat that as delivered too.
        return DELIVERED, 'confirmed by an older server version'
    return DROP, str(reply.get('error') or 'rejected')


def send_callback_reliably(server_url, secret, path, fields, timeout=3, block=False):
    """Send a session-end style callback now; if the server can't be
    reached, keep it in pending_callbacks.json and retry with backoff until
    the server confirms it (see start_pending_callback_retrier). Each
    callback carries an event_id so the server never applies it twice."""
    import uuid
    item = {
        'path': path,
        'queued_at': time.time(),
        'body': dict(fields, secret=secret, event_id=uuid.uuid4().hex, agent_version=AGENT_VERSION),
    }

    def attempt():
        # Keep the order: if older events are still waiting, queue behind them.
        with _pending_lock:
            queued_before = bool(_load_pending())
            if queued_before:
                items = _load_pending()
                items.append(item)
                _save_pending(_trim(items))
        if queued_before:
            _flush_now.set()
            return
        outcome, detail = _post_callback(server_url, item, timeout)
        if outcome == RETRY:
            with _pending_lock:
                items = _load_pending()
                items.append(item)
                _save_pending(_trim(items))
            print(f'[agent] {detail}; {path} will be re-sent automatically.')
            update_status(server_url, False, detail)
        else:
            if outcome == DROP:
                print(f'[agent] {path} not accepted: {detail}')
            update_status(server_url, True, last_event_result=f'{path}: {outcome} {detail}'.strip())

    if block:
        attempt()
    else:
        threading.Thread(target=attempt, daemon=True).start()


def flush_pending_callbacks(server_url, timeout=5):
    """Send queued events oldest first. Returns True if the queue is empty
    afterwards, False if the server could not be reached (stop and keep the
    rest in order)."""
    with _pending_lock:
        items = _trim(_load_pending())
        if not items:
            _save_pending([])
            return True
        remaining = list(items)
        reached = True
        last_error = ''
        while remaining:
            item = remaining[0]
            outcome, detail = _post_callback(server_url, item, timeout)
            if outcome == RETRY:
                reached = False
                last_error = detail
                break
            if outcome == DROP:
                print(f'[agent] Queued {item.get("path")} not accepted by the server: {detail}')
            remaining.pop(0)
        _save_pending(remaining)
    update_status(server_url, reached, last_error)
    return reached and not remaining


def start_pending_callback_retrier(server_url):
    """Re-send queued events: right away when the server becomes reachable
    again (check_network_in_background sets _flush_now), otherwise with a
    backoff from 15 s up to 5 minutes while it stays unreachable."""
    def worker():
        delay = PENDING_RETRY_MIN_SECONDS
        while True:
            _flush_now.wait(delay)
            _flush_now.clear()
            try:
                if not _load_pending():
                    delay = PENDING_RETRY_MIN_SECONDS
                    continue
                if flush_pending_callbacks(server_url):
                    delay = PENDING_RETRY_MIN_SECONDS
                else:
                    delay = min(PENDING_RETRY_MAX_SECONDS, delay * 2)
            except Exception as e:
                print(f'[agent] Retrying pending callbacks failed: {e}')
                delay = min(PENDING_RETRY_MAX_SECONDS, delay * 2)

    threading.Thread(target=worker, name='compulab-agent-retry', daemon=True).start()


def notify_end_session_sync(server_url, secret, reason, timeout=3):
    """
    Tells the server the session on this PC ended. Tries once right away
    (blocking briefly, so the status page updates at once); if the server
    can't be reached it is queued on disk and re-sent until it arrives,
    instead of being lost as before.
    """
    send_callback_reliably(
        server_url, secret, '/labs/api/pc-agent-end-session/', {'reason': reason},
        timeout=timeout, block=True,
    )


def execute_power_command(action):
    """
    Runs the actual Windows shutdown/restart, called once poll_queue picks
    up a 'shutdown' or 'restart' item (from a remote /shutdown or /restart
    signal sent by the CompuLab server — see labs/network.py's
    shutdown_pc()/restart_pc()).

    Uses a 30-second OS-level grace period (`/t 30`) instead of an instant
    `/t 0` so whoever is at the PC sees Windows' own countdown/notification
    and has a moment to save work — matches the confirm-then-wait feel of
    the existing local Restart/Power Off buttons on this same lock screen
    (see restart_clicked/power_off_clicked above), just triggered remotely
    instead of by a click.
    """
    try:
        if action == 'restart':
            subprocess.run(['shutdown', '/r', '/t', '30'], check=True)
        else:
            subprocess.run(['shutdown', '/s', '/t', '30'], check=True)
    except Exception as e:
        print(f'[agent] Remote {action} command failed: {e}')


def submit_login_in_background(server_url, secret, id_number, reservation_code):
    """
    Runs on a throwaway background thread (started by the Submit button) so
    the UI never freezes while waiting on the network. Never touches Tk
    directly — it only ever puts its result on the queue for the main
    thread's poll_queue to pick up.
    """
    def worker():
        url = server_url.rstrip('/') + '/labs/api/pc-agent-login/'
        payload = json.dumps({
            'secret': secret,
            'id_number': id_number,
            'reservation_code': reservation_code,
        }).encode('utf-8')
        request = urllib.request.Request(
            url, data=payload, headers={'Content-Type': 'application/json'}, method='POST',
        )
        try:
            with urllib.request.urlopen(request, timeout=8) as response:
                result = json.loads(response.read().decode('utf-8'))
        except urllib.error.HTTPError as e:
            try:
                result = json.loads(e.read().decode('utf-8'))
            except Exception:
                result = {'ok': False, 'error': f'Server error ({e.code}).'}
        except urllib.error.URLError as e:
            result = {'ok': False, 'error': (
                f"Can't reach the CompuLab server on the campus network ({e.reason}). "
                "Signing in with a reservation code needs the server (the internet is not needed). "
                "Ask your Lab In-Charge: they can unlock this PC with Manual PC Control."
            )}
        except Exception as e:
            result = {'ok': False, 'error': f'Unexpected error: {e}'}

        _command_queue.put(('login_result', result))

    threading.Thread(target=worker, daemon=True).start()


def submit_logout_in_background(server_url, secret, reason):
    """
    Tells the server this PC is no longer in use (student clicked "Log Out",
    or the reservation's end_time was reached). Fire-and-forget: the agent
    has already decided to re-lock locally by the time this is called, so
    we don't block the UI waiting on the server's reply — this just keeps
    the admin dashboard / PC status view in sync with reality.
    """
    send_callback_reliably(
        server_url, secret, '/labs/api/pc-agent-logout/', {'reason': reason}, timeout=8,
    )


def fetch_pc_info_in_background(server_url, secret):
    """Asks the server which pc_id / lab_name are actually assigned to THIS
    machine in the admin panel (Manage PCs -> Add/Edit), instead of trusting
    whatever was hand-typed into agent_config.json's "pc_name"/"lab_name" —
    which can drift out of sync if the admin renames the PC later. The
    server resolves the PC by this machine's LAN IP address, the same way
    it already does for the other pc-agent-* endpoints (see
    labs/views.py:pc_agent_info_api).

    Runs on a background thread and drops the result on the same
    _command_queue the login flow uses, so LockScreen.apply_pc_info() runs
    safely back on the Tk main thread. Best-effort/fire-and-forget: on any
    failure (server unreachable, PC has no IP on file / isn't registered
    yet, wrong secret) the lock screen just keeps showing agent_config.json's
    values — nothing crashes and nothing blocks the UI.
    """
    def worker():
        query = urllib.parse.urlencode({
            'secret': secret, 'agent_version': AGENT_VERSION, 'pending_events': pending_count(),
        })
        url = server_url.rstrip('/') + '/labs/api/pc-agent-info/?' + query
        request = urllib.request.Request(url, method='GET')
        try:
            with urllib.request.urlopen(request, timeout=6) as response:
                result = json.loads(response.read().decode('utf-8'))
        except Exception:
            result = {'ok': False}
        _command_queue.put(('pc_info', result))

    threading.Thread(target=worker, daemon=True).start()


def check_network_in_background(server_url, interval=10):
    """Runs forever on its own daemon thread (started once from main() at
    startup): every `interval` seconds, tries to reach the CompuLab
    server and drops the result on _command_queue as ('network_status',
    bool), so LockScreen.apply_network_status() can update the NETWORK
    status pill to match reality instead of the old hardcoded 'Connected'
    text that never changed.

    "Connected" here specifically means "can this PC reach the CompuLab
    server" — that's what actually matters for this kiosk (login/unlock
    won't work otherwise), not general internet access. A short timeout
    is used so one slow/unreachable check doesn't leave the status stuck
    for a long time before the next attempt.
    """
    def worker():
        was_connected = None
        while True:
            error = ''
            try:
                # /healthz answers "ok" as soon as the CompuLab web service
                # runs; it needs no internet, only the campus network.
                request = urllib.request.Request(server_url.rstrip('/') + '/healthz', method='GET')
                urllib.request.urlopen(request, timeout=4).close()
                connected = True
            except urllib.error.HTTPError as e:
                # Server answered — even an error page means the network
                # path to it is up, which is what we're actually checking.
                connected = True
                if e.code >= 500:
                    error = f'server error {e.code}'
            except Exception as e:
                connected = False
                error = f'{e.__class__.__name__}: {getattr(e, "reason", e)}'
            if connected and was_connected is False:
                _flush_now.set()  # send queued events right away
            was_connected = connected
            update_status(server_url, connected, error)
            _command_queue.put(('network_status', connected))
            time.sleep(interval)

    threading.Thread(target=worker, name='compulab-agent-netcheck', daemon=True).start()



def get_foreground_hwnd():
    """The raw Win32 handle of whatever window currently has focus, or None.
    Fetched once per sample and reused for both title and URL capture below
    so they're always describing the exact same window — using two
    different "what's foreground" lookups (GetForegroundWindow vs UI
    Automation's own foreground-control lookup) can disagree, especially
    for browsers, and that mismatch is what caused a real mislabeling bug:
    the URL lookup would silently fail to find the address bar, and the
    server would fall back to guessing the site from title keywords —
    which is wrong whenever the page title just happens to contain another
    site's name (e.g. a ChatGPT conversation titled "Upload Video to
    GitHub" was mislabeled "GitHub" instead of "ChatGPT")."""
    if os.name != 'nt':
        return None
    try:
        import ctypes
        hwnd = ctypes.windll.user32.GetForegroundWindow()
        return hwnd or None
    except Exception:
        return None


def get_active_window_title(hwnd=None):
    """Returns the foreground window's title bar text, or None if it can't
    be read (non-Windows OS, no window focused, permissions issue, etc).
    Uses only ctypes + the standard library — no pywin32/extra installs.
    Pass an hwnd from get_foreground_hwnd() to describe a specific window;
    if omitted, looks up the current foreground window itself.

    NOTE: this reads whatever text Windows puts in the title bar of the
    currently focused window. For a browser that's normally the page
    title (e.g. "Facebook - Google Chrome"), not the address bar's URL —
    see get_active_window_url() below for that.
    """
    if os.name != 'nt':
        return None  # only meaningful on the actual Windows lab PCs
    try:
        import ctypes
        user32 = ctypes.windll.user32
        hwnd = hwnd or user32.GetForegroundWindow()
        if not hwnd:
            return None
        length = user32.GetWindowTextLengthW(hwnd)
        if length <= 0:
            return None
        buf = ctypes.create_unicode_buffer(length + 1)
        user32.GetWindowTextW(hwnd, buf, length + 1)
        return buf.value
    except Exception:
        return None


# Optional dependency — only needed for get_active_window_url() below. Not
# part of the Python standard library, so it must be installed separately
# on every lab PC: `pip install uiautomation`. If it isn't installed, the
# agent still runs fine and just reports window_title without page_url
# (server falls back to guessing the site from title text, same as before).
try:
    import uiautomation as _uia
except Exception:
    _uia = None

# ClassName of the address bar element. Chromium browsers (Chrome, Edge,
# Brave, Opera) all use 'OmniboxViewViews' internally — confirmed by
# inspecting the live control tree (its AutomationId turned out to be a
# session-dependent value like 'view_1012', not a stable identifier, so
# ClassName is what we match on instead). Firefox's address bar uses the
# AutomationId 'urlbar-input', which IS stable there.
_ADDRESS_BAR_CLASS_NAMES = ('OmniboxViewViews',)
_ADDRESS_BAR_AUTOMATION_IDS = ('urlbar-input',)


def get_active_window_url(hwnd=None):
    """Best-effort read of the given window's (or the foreground window's,
    if hwnd is omitted) address bar text via Windows UI Automation. Returns
    None for any non-browser window, if the `uiautomation` package isn't
    installed, or if the address bar element can't be found (browser UI
    changes, unsupported browser, etc) — callers must treat this as
    "unavailable", not an error.

    Always pass the SAME hwnd used for get_active_window_title() in the
    same sampling cycle — see get_foreground_hwnd()'s docstring for why
    that matters.

    NOTE: requires `pip install uiautomation` on the lab PC (see module
    docstring). This is the only extra, non-standard-library dependency
    this agent uses, and only for this one feature — everything else
    still runs with zero installs.
    """
    if os.name != 'nt' or _uia is None:
        return None
    try:
        hwnd = hwnd or get_foreground_hwnd()
        if not hwnd:
            return None
        window = _uia.ControlFromHandle(hwnd)
        if window is None:
            return None
        for class_name in _ADDRESS_BAR_CLASS_NAMES:
            bar = window.EditControl(ClassName=class_name, searchDepth=20)
            if bar.Exists(1.5, 0.3):
                value = bar.GetValuePattern().Value if bar.GetValuePattern() else bar.Name
                return (value or '').strip() or None
        for automation_id in _ADDRESS_BAR_AUTOMATION_IDS:
            bar = window.EditControl(AutomationId=automation_id, searchDepth=20)
            if bar.Exists(1.5, 0.3):
                value = bar.GetValuePattern().Value if bar.GetValuePattern() else bar.Name
                return (value or '').strip() or None
        return None
    except Exception:
        return None


def report_activity_in_background(server_url, secret, window_title, page_url=''):
    """Fire-and-forget POST of one active-window-title sample. Same pattern
    as submit_logout_in_background — never blocks the UI thread, and a
    failed/slow request here just means one missed sample, not a problem
    worth surfacing to the student."""
    def worker():
        url = server_url.rstrip('/') + '/labs/api/pc-agent-activity/'
        payload = json.dumps({
            'secret': secret,
            'window_title': window_title or '',
            'page_url': page_url or '',
            'agent_version': AGENT_VERSION,
            'pending_events': pending_count(),
        }).encode('utf-8')
        request = urllib.request.Request(
            url, data=payload, headers={'Content-Type': 'application/json'}, method='POST',
        )
        try:
            urllib.request.urlopen(request, timeout=5).close()
        except Exception:
            pass  # best-effort; next interval will just try again

    threading.Thread(target=worker, daemon=True).start()


class StatusBar:
    """Small floating widget shown only while the PC is unlocked — a
    reminder of when the reservation ends, plus a manual 'Log Out' button
    for when the student finishes early. Sits in a corner, stays on top,
    but is deliberately unobtrusive (no fullscreen, no input blocking)."""

    def __init__(self, root, end_dt, on_logout):
        self.root = root
        self.end_dt = end_dt
        self.on_logout = on_logout
        self._tick_id = None

        self.win = tk.Toplevel(root)
        self.win.overrideredirect(True)
        self.win.attributes('-topmost', True)
        self.win.configure(bg='#0a1522')

        w, h = 300, 64
        x = self.win.winfo_screenwidth() - w - 24
        y = self.win.winfo_screenheight() - h - 24
        self.win.geometry(f'{w}x{h}+{x}+{y}')

        border = tk.Frame(self.win, bg='#22d3f5', bd=0)
        border.pack(fill='both', expand=True, padx=1, pady=1)
        inner = tk.Frame(border, bg='#0a1522')
        inner.pack(fill='both', expand=True, padx=1, pady=1)

        left = tk.Frame(inner, bg='#0a1522')
        left.pack(side='left', fill='both', expand=True, padx=(14, 6))
        tk.Label(left, text='SESSION ACTIVE', font=('Consolas', 9, 'bold'), fg='#5b7a94', bg='#0a1522').pack(anchor='w', pady=(10, 0))
        self.countdown_label = tk.Label(left, text='', font=('Consolas', 13, 'bold'), fg='#22d3f5', bg='#0a1522')
        self.countdown_label.pack(anchor='w')

        logout_btn = tk.Button(
            inner, text='LOG OUT', font=('Consolas', 10, 'bold'),
            bg='#ff3b3b', fg='#2b0007', activebackground='#ff6b6b', activeforeground='#2b0007',
            relief='flat', bd=0, cursor='hand2', command=self._logout_clicked,
        )
        logout_btn.pack(side='right', fill='y', padx=(6, 0))

        self._tick()

    def _logout_clicked(self):
        self.on_logout()

    def _tick(self):
        remaining = self.end_dt - datetime.datetime.now()
        if remaining.total_seconds() <= 0:
            self.countdown_label.config(text='Ending now...')
        else:
            total = int(remaining.total_seconds())
            mins, secs = divmod(total, 60)
            hrs, mins = divmod(mins, 60)
            if hrs:
                text = f'{hrs}h {mins}m left'
            elif mins:
                text = f'{mins}m {secs}s left'
            else:
                text = f'{secs}s left'
            self.countdown_label.config(text=text)
        self._tick_id = self.root.after(1000, self._tick)

    def destroy(self):
        if self._tick_id is not None:
            try:
                self.root.after_cancel(self._tick_id)
            except Exception:
                pass
        try:
            self.win.destroy()
        except Exception:
            pass


class MiniPanel:
    """
    Small always-on-top floating widget shown ONLY while the PC is
    unlocked. Gives the student a way to end their session early (before
    the reservation's end_time) without having to find a Start Menu /
    taskbar shortcut — there isn't one, since the desktop is otherwise a
    completely normal Windows session.

    Draggable (via the top strip) and minimizable (via the "–" button, which
    collapses it down to just that strip so it stays out of the way without
    fully hiding — click "+" to expand it again).
    """

    NORMAL_ACCENT = '#22d3f5'
    WARNING_ACCENT = '#ffb020'
    W = 260
    HEADER_H = 26
    BODY_H = 66  # fallback only — actual height is computed from real content in __init__

    def __init__(self, on_lock_now):
        self.win = tk.Toplevel()
        self.win.overrideredirect(True)
        self.win.attributes('-topmost', True)
        self.win.configure(bg=self.NORMAL_ACCENT)
        screen_w = self.win.winfo_screenwidth()
        self._x = screen_w - self.W - 16
        self._y = 16
        self.win.geometry(f'{self.W}x{self.HEADER_H + self.BODY_H}+{self._x}+{self._y}')

        self.border = tk.Frame(self.win, bg=self.NORMAL_ACCENT, bd=0)
        self.border.pack(fill='both', expand=True, padx=1, pady=1)
        content = tk.Frame(self.border, bg='#0a1522')
        content.pack(fill='both', expand=True, padx=1, pady=1)

        # --- Drag handle / header strip ---------------------------------
        self.header = tk.Frame(content, bg='#0a1522', cursor='fleur')
        self.header.pack(fill='x', side='top')

        self.header_label = tk.Label(
            self.header, text='🔒  SESSION', font=('Consolas', 9, 'bold'),
            fg=self.NORMAL_ACCENT, bg='#0a1522', cursor='fleur',
        )
        self.header_label.pack(side='left', padx=(8, 0), pady=4)

        self.minimize_btn = tk.Button(
            self.header, text='–', font=('Consolas', 10, 'bold'), width=2,
            bg='#0a1522', fg='#5b7a94', activebackground='#173049', activeforeground='#eaf6ff',
            relief='flat', bd=0, cursor='hand2', command=self.toggle_minimize,
        )
        self.minimize_btn.pack(side='right', padx=(0, 4), pady=2)

        # Dragging binds to the header strip so it never fights with the
        # "Lock Now" button's own click handler below.
        for widget in (self.header, self.header_label):
            widget.bind('<ButtonPress-1>', self._start_drag)
            widget.bind('<B1-Motion>', self._on_drag)

        # --- Collapsible body ---------------------------------------------
        self.body = tk.Frame(content, bg='#0a1522')
        self.body.pack(fill='both', expand=True, side='top')

        self.status_text = tk.Label(
            self.body, text='SESSION ACTIVE', font=('Consolas', 10, 'bold'),
            fg=self.NORMAL_ACCENT, bg='#0a1522',
        )
        self.status_text.pack(pady=(6, 2))

        self.countdown_text = tk.Label(
            self.body, text='', font=('Consolas', 9), fg='#5b7a94', bg='#0a1522',
        )
        self.countdown_text.pack()

        btn = tk.Button(
            self.body, text='🔒 Lock Now', font=('Segoe UI', 9, 'bold'),
            bg='#173049', fg='#eaf6ff', activebackground='#20496b', activeforeground='#eaf6ff',
            relief='flat', cursor='hand2', bd=0, command=on_lock_now,
        )
        btn.pack(pady=(6, 8), ipady=3, ipadx=6)

        # The BODY_H constant above is only a rough guess — real widget
        # sizes depend on the actual fonts/DPI of the machine this runs on,
        # and if the guess is too small the window clips its own content
        # (the Lock Now button was getting cut off below the window's
        # bottom edge on some machines). Measure the real required size
        # after everything is packed and resize to match, with a small
        # safety margin.
        self.win.update_idletasks()
        real_header_h = self.header.winfo_reqheight()
        real_body_h = self.body.winfo_reqheight() + 4
        self.HEADER_H = real_header_h
        self.BODY_H = real_body_h
        self.win.geometry(f'{self.W}x{real_header_h + real_body_h}+{self._x}+{self._y}')

        self._minimized = False
        self.win.withdraw()

    def _start_drag(self, event):
        self._drag_offset = (event.x, event.y)

    def _on_drag(self, event):
        dx, dy = self._drag_offset
        self._x = self.win.winfo_x() + (event.x - dx)
        self._y = self.win.winfo_y() + (event.y - dy)
        self.win.geometry(f'+{self._x}+{self._y}')

    def toggle_minimize(self):
        if self._minimized:
            self.body.pack(fill='both', expand=True, side='top')
            self.minimize_btn.config(text='–')
            self.win.geometry(f'{self.W}x{self.HEADER_H + self.BODY_H}+{self._x}+{self._y}')
        else:
            self.body.pack_forget()
            self.minimize_btn.config(text='+')
            self.win.geometry(f'{self.W}x{self.HEADER_H}+{self._x}+{self._y}')
        self._minimized = not self._minimized

    def show(self):
        self.win.deiconify()
        self.win.attributes('-topmost', True)

    def hide(self):
        self.win.withdraw()

    def set_countdown(self, text):
        self.countdown_text.config(text=text)

    def set_warning(self, is_warning):
        accent = self.WARNING_ACCENT if is_warning else self.NORMAL_ACCENT
        self.win.configure(bg=accent)
        self.border.configure(bg=accent)
        self.header_label.configure(fg=accent)
        self.status_text.configure(
            fg=accent,
            text='ENDING SOON' if is_warning else 'SESSION ACTIVE',
        )


class WarningBanner:
    """
    Prominent centered "SYSTEM WARNING" banner (black background, red
    warning-triangle icon) that appears 2–3 minutes before a reservation's
    end_time, so the student notices even if they never look at the small
    corner MiniPanel. Has its own 'OK' button so the student can dismiss
    it early if it's blocking their work — dismissing it does NOT cancel
    the countdown, it just hides this banner (the MiniPanel still shows
    the countdown, and the banner will still be force-hidden automatically
    once the session actually ends).
    """

    RED = '#ff3b3b'

    def __init__(self):
        self.win = tk.Toplevel()
        self.win.overrideredirect(True)
        self.win.attributes('-topmost', True)
        w, h = 460, 130  # fallback only — real height is measured below
        screen_w = self.win.winfo_screenwidth()
        screen_h = self.win.winfo_screenheight()
        self.win.geometry(f'{w}x{h}+{(screen_w - w) // 2}+{(screen_h - h) // 2 - 160}')

        self.win.configure(bg=self.RED)
        inner = tk.Frame(self.win, bg='#000000')
        inner.pack(fill='both', expand=True, padx=1, pady=1)

        # Red warning-triangle icon, drawn to match the provided design.
        icon = tk.Canvas(inner, width=64, height=54, bg='#000000', highlightthickness=0)
        icon.pack(pady=(14, 2))
        icon.create_polygon(32, 4, 60, 50, 4, 50, outline=self.RED, fill='#000000', width=3, joinstyle='round')
        icon.create_line(32, 20, 32, 36, fill=self.RED, width=4, capstyle='round')
        icon.create_oval(29, 41, 35, 47, fill=self.RED, outline=self.RED)

        self.title_label = tk.Label(
            inner, text='SYSTEM WARNING', font=('Consolas', 14, 'bold'),
            fg=self.RED, bg='#000000',
        )
        self.title_label.pack(pady=(0, 2))

        self.detail_label = tk.Label(
            inner, text='', font=('Segoe UI', 9), fg='#e0a0a0', bg='#000000',
            justify='center', wraplength=w - 40,
        )
        self.detail_label.pack()

        ok_btn = tk.Button(
            inner, text='OK', font=('Consolas', 9, 'bold'), width=8,
            bg='#1a0000', fg=self.RED, activebackground='#3a0000', activeforeground=self.RED,
            relief='flat', bd=0, cursor='hand2', command=self.hide,
        )
        ok_btn.pack(pady=(8, 10))

        # Same fix as MiniPanel: the 130px guess above doesn't account for
        # the detail_label wrapping to 2 lines, or for font/DPI differences
        # on the actual lab PC — either of which pushed the OK button below
        # the window's fixed bottom edge, clipping it off. Measure the real
        # required height once everything is packed and resize to fit.
        self.win.update_idletasks()
        real_h = inner.winfo_reqheight() + 4
        self.win.geometry(f'{w}x{real_h}+{(screen_w - w) // 2}+{(screen_h - real_h) // 2 - 160}')

        self.win.withdraw()

    def show(self):
        self.win.deiconify()
        self.win.attributes('-topmost', True)

    def hide(self):
        self.win.withdraw()

    def set_detail(self, text):
        self.detail_label.config(text=text)
        # Re-measure: a longer message can wrap to more lines than the one
        # the window was originally sized for, which would clip the OK
        # button again if we didn't resize here too.
        self.win.update_idletasks()
        w = self.win.winfo_width()
        screen_w = self.win.winfo_screenwidth()
        screen_h = self.win.winfo_screenheight()
        real_h = self.win.winfo_reqheight()
        self.win.geometry(f'{w}x{real_h}+{(screen_w - w) // 2}+{(screen_h - real_h) // 2 - 160}')


class RichLabel(tk.Frame):
    """Centered, word-wrapped text block that can colour chosen phrases.

    tk.Label can only use a single colour, so this wraps a read-only tk.Text
    instead. It understands .config(text=..., fg=...) just like a Label, so
    the rest of the agent doesn't need to know the difference. Phrases in
    `highlights` are coloured with `highlight_fg` — but only while the label
    is in its normal colour (an error message in red stays fully red)."""

    def __init__(self, parent, text, font, fg, bg, width, height, highlights=(), highlight_fg=None):
        super().__init__(parent, bg=bg, width=width, height=height)
        self.pack_propagate(False)
        self._default_fg = fg
        self._fg = fg
        self._highlights = tuple(highlights)
        self._current = ''
        self._text = tk.Text(
            self, font=font, bg=bg, fg=fg, relief='flat', bd=0, highlightthickness=0,
            wrap='word', cursor='arrow', padx=0, pady=0, takefocus=0, height=3,
            insertwidth=0, spacing1=0, spacing3=2,
        )
        self._text.pack(fill='both', expand=True)
        self._text.tag_configure('center', justify='center')
        self._text.tag_configure('hl', foreground=highlight_fg or fg)
        self._text.bind('<Button-1>', lambda e: 'break')
        self._text.bind('<B1-Motion>', lambda e: 'break')
        self._set_text(text)

    def _set_text(self, text):
        self._current = text
        t = self._text
        t.configure(state='normal')
        t.delete('1.0', 'end')
        t.insert('1.0', text, ('center',))
        if self._fg == self._default_fg:
            for phrase in self._highlights:
                start = '1.0'
                while True:
                    pos = t.search(phrase, start, stopindex='end')
                    if not pos:
                        break
                    end = f'{pos}+{len(phrase)}c'
                    t.tag_add('hl', pos, end)
                    start = end
        t.configure(state='disabled')

    def configure(self, cnf=None, **kw):
        text = kw.pop('text', None)
        fg = kw.pop('fg', None)
        if fg is not None:
            self._fg = fg
            self._text.configure(fg=fg)
        if text is not None or fg is not None:
            self._set_text(self._current if text is None else text)
        if cnf or kw:
            super().configure(cnf, **kw)

    config = configure


class DotLabel(tk.Label):
    """tk.Label that always starts with a '●' in its own colour — used for
    the green/red values in the STATUS / NETWORK / LABORATORY row, so the
    dot follows whatever colour the agent sets (green = ok, red = offline)."""

    def __init__(self, parent, text='', **kw):
        super().__init__(parent, **kw)
        self.configure(text=text)

    def configure(self, cnf=None, **kw):
        if 'text' in kw:
            kw['text'] = '\u25cf ' + kw['text']
        return super().configure(cnf, **kw)

    config = configure


class CanvasLabel:
    """Duck-types the small part of tk.Label the agent uses (.config(text=,
    fg=)) for a text item living on a Canvas, so things drawn straight onto
    the lock screen's canvas can still be updated like normal labels."""

    def __init__(self, canvas, item_id):
        self.canvas = canvas
        self.item_id = item_id

    def config(self, **kw):
        if 'text' in kw:
            self.canvas.itemconfig(self.item_id, text=kw['text'])
        if 'fg' in kw:
            self.canvas.itemconfig(self.item_id, fill=kw['fg'])

    configure = config


class LockScreen:
    """Fullscreen overlay window that blocks the desktop until unlocked.

    Includes a built-in login form (ID Number + Reservation Code) so
    students can check in directly on the locked PC — no separate
    reception/kiosk computer required. Styled per the approved lock-screen
    design: top header bar with the college name and a live clock/date,
    chamfered-corner card with a glowing padlock badge, "ACCESS REQUIRED"
    heading, icon-prefixed input fields, a gold "UNLOCK COMPUTER" button, a
    COMPUTER STATUS / NETWORK / LABORATORY status row, and Restart /
    Power Off controls under it.

    Also owns the session timer: once a login succeeds, it schedules an
    automatic re-lock for when that reservation's end_time is reached, and
    shows a small MiniPanel with a "Lock Now" button for ending early.
    """

    BG = '#030a18'
    GRID = '#08182c'
    CIRCUIT = '#0f2436'
    CIRCUIT_NODE = '#1c4d5e'
    CARD_BG = '#061529'
    FIELD_BG = '#0a2038'
    FIELD_BORDER = '#1d4b7c'
    STATUS_BG = '#071b33'
    ACCENT = '#27c6ff'
    ACCENT_BRIGHT = '#8aeaff'
    ACCENT_DIM = '#14608a'
    BLUE_GLOW = '#2f8cff'
    # Gold/amber accent — PC-name line highlights, the unlock button and the
    # small "call to action" HUD accents (see the approved login design).
    GOLD = '#f5a623'
    GOLD_BRIGHT = '#ffc960'
    GOLD_DIM = '#8a5a10'
    # Unlock button gradient (left -> right) and its hover state.
    BTN_L = '#f1a208'
    BTN_R = '#ffcb33'
    BTN_HOVER_L = '#ffb524'
    BTN_HOVER_R = '#ffdc66'
    STATUS_GREEN = '#2fe27c'
    TEXT = '#f2f8ff'
    MUTED = '#8aa6c1'
    ERROR = '#ff5470'
    SUCCESS = '#39ff8f'
    FONT_MONO = 'Consolas'
    FONT_UI = 'Segoe UI'

    CARD_W = 410
    # Tall enough for: college seal + name, padlock badge with circuit
    # lines, heading, 2-line subtitle, both input fields, the unlock button,
    # status row, restart/power buttons and the footer — with a little
    # headroom, because the content is vertically centred and any overflow
    # would be clipped equally off the top and bottom.
    CARD_H = 626
    BTN_H = 42
    HEADER_H = 78
    WARNING_LEAD_SECONDS = 150  # show the "ending soon" warning 2.5 min before end_time

    def __init__(self, root, config):
        self.root = root
        self.config = config
        self.visible = False
        self.submitting = False
        self._pulse_on = True
        self._relock_after_id = None
        self._countdown_after_id = None
        self._warning_after_id = None
        self._warning_shown = False
        self._session_end_dt = None
        self._override_after_id = None
        self._override_tick_after_id = None
        self.mini_panel = None  # created after root exists; see main()
        self.warning_banner = None  # created after root exists; see main()
        self.status_bar = None
        self.relock_after_id = None
        self._activity_stop_event = threading.Event()
        self._activity_thread = None
        self._icons = {}  # keeps PhotoImage refs alive — Tk garbage-collects them otherwise

        root.title('CompuLab')
        try:
            small_logo = tk.PhotoImage(file=os.path.join(
                APP_DIR, 'assets', 'icon_college_logo_small.png'))
            root.iconphoto(True, small_logo)
            self._icons['_taskbar_logo_ref'] = small_logo  # keep alive
        except Exception:
            pass
        root.configure(bg=self.BG)
        root.overrideredirect(True)  # no title bar / close button
        # NOTE: we deliberately do NOT use attributes('-fullscreen', True)
        # together with overrideredirect(True) — on some Tk/Windows builds
        # combining both raises "can't set fullscreen attribute: override-
        # redirect flag is set". Sizing the window to the screen manually
        # gets the same visual result without that conflict.
        self.screen_w = root.winfo_screenwidth()
        self.screen_h = root.winfo_screenheight()
        root.geometry(f'{self.screen_w}x{self.screen_h}+0+0')
        root.attributes('-topmost', True)

        # Swallow Alt+F4 so a casual attempt to close the window doesn't work.
        root.protocol('WM_DELETE_WINDOW', lambda: None)
        root.bind('<Alt-F4>', lambda e: 'break')

        config = self.config
        self.pc_name = (config.get('pc_name') or 'PC').strip()
        # True until proven otherwise by the server (see apply_pc_info /
        # _apply_lab_open_state) — assume open so the form is usable
        # immediately, rather than flashing a "closed" state on every
        # startup before the first pc-agent-info reply comes back.
        self.lab_open = True
        self._net_ok = True

        # Scale fixed pixel sizes with the display's DPI scaling (fonts
        # already scale by themselves; pixel sizes don't), so the card is
        # never too narrow for its text on a 125%/150% Windows display.
        s = self._s = min(2.0, max(1.0, root.winfo_fpixels('1i') / 96.0))
        self.CARD_W = int(self.CARD_W * s)
        self.BTN_H = int(round(self.BTN_H * s))
        self.FIELD_BOX_H = int(round(self.FIELD_BOX_H * s))
        self.FIELD_ICON_HOLDER_W = int(round(self.FIELD_ICON_HOLDER_W * s))

        self._load_icons()

        self.canvas = tk.Canvas(root, bg=self.BG, highlightthickness=0, width=self.screen_w, height=self.screen_h)
        self.canvas.place(x=0, y=0)

        # The card is built FIRST and measured, then the background/border
        # are drawn around it (see "Fit the card to its content" below).
        # Fixed pixel sizes broke on real Windows PCs: Segoe UI and the
        # display's DPI scaling make the text taller than in a fixed-height
        # card, which clipped the seal at the top and the footer at the bottom.
        cx, cy = self.screen_w // 2, self.screen_h // 2 + 4
        inner_w = self.CARD_W - int(60 * s)
        lh9 = tkfont.Font(family=self.FONT_UI, size=9).metrics('linespace')
        lh8 = tkfont.Font(family=self.FONT_UI, size=8, weight='bold').metrics('linespace')

        frame = tk.Frame(root, bg=self.CARD_BG)
        frame.place(x=cx, y=cy, anchor='center', width=self.CARD_W - 36, height=self.CARD_H - 36)

        inner = tk.Frame(frame, bg=self.CARD_BG)
        inner.place(relx=0.5, rely=0.5, anchor='center')

        # --- College seal + name -----------------------------------------
        seal = tk.Canvas(inner, width=70, height=70, bg=self.CARD_BG, highlightthickness=0)
        seal.pack(pady=(0, 3))
        seal.create_oval(3, 3, 67, 67, outline=self.GOLD, width=2)
        card_logo = self._icons.get('card_logo')
        if card_logo is not None:
            seal.create_image(35, 35, image=card_logo)

        college_name = config.get('college_name', 'Danao Technological College')
        tk.Label(
            inner, text=college_name.upper(), font=(self.FONT_UI, 11, 'bold'),
            fg=self.TEXT, bg=self.CARD_BG,
        ).pack()
        tk.Label(
            inner, text=config.get('card_subtitle', 'COMPUTER LABORATORY MANAGEMENT SYSTEM'),
            font=(self.FONT_UI, 7), fg=self.MUTED, bg=self.CARD_BG,
        ).pack(pady=(1, 4))

        # --- Padlock badge flanked by circuit traces ------------------------
        badge_h = 70
        badge = tk.Canvas(inner, width=inner_w, height=badge_h, bg=self.CARD_BG, highlightthickness=0)
        badge.pack(pady=(0, 2))
        self._draw_badge_circuit(badge, inner_w, badge_h)
        self._glow_ring_ids = self._draw_glow_rings(badge, inner_w // 2, badge_h // 2, max_r=33)
        if self._icons.get('lock_badge') is not None:
            badge.create_image(inner_w // 2, badge_h // 2, image=self._icons['lock_badge'])
        self._pulse_dot()

        # Big heading: an explicit lock_title always wins; otherwise this is
        # the fixed "ACCESS REQUIRED" heading from the approved design.
        # Kept on self.* because _apply_lab_open_state() swaps it to
        # "LABORATORY CLOSED" outside operating hours, then restores it.
        self._default_title_text = config.get('lock_title') or 'ACCESS REQUIRED'
        self._default_subtitle_text = config.get(
            'lock_subtitle', 'Enter your Student ID and Reservation Code to use this PC.',
        )
        self.title_label = tk.Label(
            inner, text=self._default_title_text, font=(self.FONT_UI, 18, 'bold'),
            fg=self.TEXT, bg=self.CARD_BG, wraplength=self.CARD_W - 60, justify='center',
        )
        self.title_label.pack(pady=(0, 4))

        self.subtitle_label = RichLabel(
            inner, self._default_subtitle_text, font=(self.FONT_UI, 9), fg=self.MUTED, bg=self.CARD_BG,
            width=inner_w - 10, height=lh9 * 2 + 8,
            highlights=('Student ID and Reservation Code',), highlight_fg=self.ACCENT,
        )
        self.subtitle_label.pack(pady=(0, 8))

        self.form = form = tk.Frame(inner, bg=self.CARD_BG)
        form.pack()

        field_w = inner_w
        self.id_box, self.id_entry = self._build_field(
            form, 'user', 'Student / Instructor ID', width=field_w)
        self.id_box.grid(row=0, column=0, sticky='we', pady=(0, 9))

        self.code_box, self.code_entry = self._build_field(
            form, 'lock', 'Reservation Code', show='\u2022', toggle=True, width=field_w)
        self.code_box.grid(row=1, column=0, sticky='we', pady=(0, 11))

        form.grid_columnconfigure(0, weight=1)

        self._unlock_button_w = field_w
        self.submit_canvas, self._submit_text_id = self._build_unlock_button(form, width=field_w, height=self.BTN_H)
        self.submit_canvas.grid(row=2, column=0, sticky='we')

        self.status_label = tk.Label(
            inner, text='', font=(self.FONT_UI, 9), fg=self.ERROR, bg=self.CARD_BG,
            wraplength=field_w, justify='center',
        )
        self.status_label.pack(pady=(6, 4))

        # --- Status row: STATUS / NETWORK / LABORATORY ---------------------
        status_w = self.CARD_W - int(52 * s)
        status_row = tk.Frame(
            inner, bg=self.STATUS_BG, width=status_w, height=lh8 * 3 + 16,
            highlightthickness=1, highlightbackground=self.FIELD_BORDER,
        )
        status_row.pack(pady=(0, 10))
        status_row.grid_propagate(False)
        for i in range(3):
            status_row.grid_columnconfigure(i, weight=1, uniform='status_col')
        status_row.grid_rowconfigure(0, weight=1)
        self.computer_status_value = self._build_status_col(
            status_row, 'computer_status', 'STATUS', 'Ready for Login', 0,
        )
        self.network_status_value = self._build_status_col(
            status_row, 'network_status', 'NETWORK', 'Connected', 1,
        )
        self.lab_status_value = self._build_status_col(
            status_row, 'lab_status', 'LABORATORY', config.get('lab_name', 'Computer Lab 1'), 2,
        )
        for rel in (1 / 3, 2 / 3):
            tk.Frame(status_row, bg=self.FIELD_BORDER, width=1).place(relx=rel, rely=0.2, relheight=0.6)

        # --- Restart / Power off ----------------------------------------------
        power_row = tk.Frame(inner, bg=self.CARD_BG)
        power_row.pack(pady=(0, 10))

        def _power_btn(icon_key, text, command):
            holder = tk.Frame(power_row, bg=self.CARD_BG, width=int(136 * s), height=int(34 * s))
            holder.pack_propagate(False)
            btn = tk.Button(
                holder, text=f'  {text}', image=self._icons.get(icon_key), compound='left',
                font=(self.FONT_UI, 9, 'bold'), bg=self.STATUS_BG, fg=self.ACCENT_BRIGHT,
                activebackground='#0d2a4a', activeforeground=self.TEXT,
                relief='flat', bd=0, cursor='hand2', command=command,
                highlightthickness=1, highlightbackground=self.ACCENT_DIM, highlightcolor=self.ACCENT,
            )
            btn.pack(fill='both', expand=True)
            return holder

        _power_btn('restart', 'RESTART', self.restart_clicked).pack(side='left', padx=(0, 12))
        _power_btn('power', 'POWER OFF', self.power_off_clicked).pack(side='left')

        # --- Footer: authorized-use disclaimer ------------------------------
        footer = tk.Frame(inner, bg=self.CARD_BG)
        footer.pack()
        if self._icons.get('shield') is not None:
            tk.Label(footer, image=self._icons['shield'], bg=self.CARD_BG).pack(side='left', padx=(0, 6))
        tk.Label(
            footer, justify='center', bg=self.CARD_BG, fg=self.MUTED, font=(self.FONT_UI, 7),
            text='Authorized users only. Unauthorized access is prohibited.',
        ).pack(side='left')

        self.id_entry.bind('<Return>', lambda e: self.code_entry.focus_set())
        self.code_entry.bind('<Return>', lambda e: self.on_submit())

        # --- Fit the card to its content ------------------------------------
        root.update_idletasks()
        self.CARD_H = max(540, inner.winfo_reqheight() + 52)
        self._layout_geometry()
        self._draw_background()
        self._draw_chrome_accents()
        self._draw_header()
        self._draw_card_border()
        self._tick_clock()
        frame.place(x=cx, y=cy, anchor='center', width=self.CARD_W - 36, height=self.CARD_H - 36)
        frame.lift()  # widgets must sit above everything just drawn on the canvas

        self._frame = frame
        self.show()

    # Size (px) of the round header logo — bumped up from the old 32x32
    # square icon so it reads clearly next to the bigger college name text.
    HEADER_LOGO_SIZE = 52

    def _make_circular_logo(self, path, size):
        """Loads the higher-res college seal, resizes it, and crops it into
        a circle (masking to the *intersection* of its own alpha and a
        circle, so it works whether the source already has a transparent
        background or an opaque square one). The mask is drawn at 4x scale
        and downsampled with LANCZOS so the circle edge is smooth/anti-
        aliased instead of blocky. Returns None if Pillow isn't available
        or the file can't be read — caller falls back to the plain square
        icon in that case."""
        if not _PIL_AVAILABLE:
            return None
        try:
            img = Image.open(path).convert('RGBA')
            img = img.resize((size, size), Image.LANCZOS)
            supersample = 4
            big = size * supersample
            circle_mask_big = Image.new('L', (big, big), 0)
            ImageDraw.Draw(circle_mask_big).ellipse((0, 0, big, big), fill=255)
            circle_mask = circle_mask_big.resize((size, size), Image.LANCZOS)
            combined_alpha = ImageChops.darker(img.split()[-1], circle_mask)
            img.putalpha(combined_alpha)
            return ImageTk.PhotoImage(img)
        except Exception:
            return None

    # Fixed pixel size for the small icons inside the ID/code input fields.
    # icon_user.png (28x28) and icon_lock.png (24x24) come in at different
    # native sizes — resizing both to the same fixed size keeps them
    # visually consistent AND guarantees they're small enough to fit inside
    # the compact field height with room to spare (no clipping/overflow).
    FIELD_ICON_SIZE = 16

    def _resize_icon(self, path, size):
        """Resizes a PNG icon to a fixed size with anti-aliasing. Returns
        None if Pillow isn't available or the file can't be read — caller
        falls back to the icon's native/original size in that case."""
        if not _PIL_AVAILABLE:
            return None
        try:
            img = Image.open(path).convert('RGBA')
            img = img.resize((size, size), Image.LANCZOS)
            return ImageTk.PhotoImage(img)
        except Exception:
            return None

    def _make_icon(self, kind, size, color):
        """Draws a crisp line icon with Pillow (6x supersampled, then
        downsampled) and returns it as a PhotoImage, or None if Pillow isn't
        available — callers fall back to no icon / the old PNG in that case.
        All icons are drawn on a 24x24 grid."""
        if not _PIL_AVAILABLE:
            return None
        try:
            S = 6
            n = size * S
            u = n / 24.0
            w = max(int(S * 1.4), int(round(size * 0.1 * S)))
            img = Image.new('RGBA', (n, n), (0, 0, 0, 0))
            d = ImageDraw.Draw(img)

            def P(x, y):
                return (x * u, y * u)

            def box(x0, y0, x1, y1):
                return [x0 * u, y0 * u, x1 * u, y1 * u]

            def line(*pts):
                d.line([P(x, y) for x, y in pts], fill=color, width=w, joint='curve')
                for x, y in (pts[0], pts[-1]):  # round caps
                    px, py = P(x, y)
                    d.ellipse([px - w / 2, py - w / 2, px + w / 2, py + w / 2], fill=color)

            def dot(x, y, r):
                d.ellipse(box(x - r, y - r, x + r, y + r), fill=color)

            if kind == 'user':
                d.ellipse(box(8, 3.5, 16, 11.5), outline=color, width=w)
                d.arc(box(4, 14, 20, 30), 180, 360, fill=color, width=w)
            elif kind == 'lock':
                d.rounded_rectangle(box(5, 11, 19, 22), radius=2.2 * u, outline=color, width=w)
                d.arc(box(8, 4, 16, 12), 180, 360, fill=color, width=w)
                line((8, 8), (8, 11))
                line((16, 8), (16, 11))
                dot(12, 16.5, 1.5)
            elif kind in ('eye', 'eye_off'):
                d.ellipse(box(2, 7, 22, 17), outline=color, width=w)
                dot(12, 12, 2.6)
                if kind == 'eye_off':
                    line((4.5, 19.5), (19.5, 4.5))
            elif kind == 'monitor':
                d.rounded_rectangle(box(3, 4, 21, 16), radius=1.6 * u, outline=color, width=w)
                line((12, 16), (12, 20))
                line((8, 20.5), (16, 20.5))
            elif kind == 'wifi':
                for r in (4, 8, 12):
                    d.arc(box(12 - r, 19 - r, 12 + r, 19 + r), 225, 315, fill=color, width=w)
                dot(12, 19, 1.6)
            elif kind == 'calendar':
                d.rounded_rectangle(box(3, 5, 21, 21), radius=2 * u, outline=color, width=w)
                line((3, 10), (21, 10))
                line((8, 2.5), (8, 7))
                line((16, 2.5), (16, 7))
                for x, y in ((8, 14), (12, 14), (16, 14), (8, 18), (12, 18)):
                    dot(x, y, 1.0)
            elif kind == 'clock':
                d.ellipse(box(3, 3, 21, 21), outline=color, width=w)
                line((12, 7), (12, 12), (16, 14.5))
            elif kind == 'restart':
                bb = box(4.5, 4.5, 19.5, 19.5)
                d.arc(bb, 330, 360, fill=color, width=w)
                d.arc(bb, 0, 270, fill=color, width=w)
                d.polygon([P(11, 0.8), P(11, 8.2), P(16.5, 4.5)], fill=color)
            elif kind == 'power':
                bb = box(4, 5, 20, 21)
                d.arc(bb, 300, 360, fill=color, width=w)
                d.arc(bb, 0, 240, fill=color, width=w)
                line((12, 2.5), (12, 12))
            elif kind == 'shield':
                d.line([P(12, 2.5), P(20, 5.5), P(20, 12), P(12, 21.5), P(4, 12), P(4, 5.5), P(12, 2.5)],
                       fill=color, width=w, joint='curve')
                line((8.5, 12), (11, 14.5), (15.5, 9.5))
            elif kind == 'chevron':
                line((9, 5), (16, 12), (9, 19))
            else:
                return None

            img = img.resize((size, size), Image.LANCZOS)
            return ImageTk.PhotoImage(img)
        except Exception as e:
            print(f'[agent] Could not draw icon {kind}: {e}')
            return None

    def _load_icons(self):
        assets_dir = os.path.join(APP_DIR, 'assets')
        names = {
            'lock_badge': 'icon_lock_badge_sm.png',
            'user': 'icon_user.png',
            'lock': 'icon_lock.png',
            'lock_dark': 'icon_lock_dark.png',
            'shield': 'icon_shield.png',
            'college_logo': 'icon_college_logo.png',
        }
        for key, filename in names.items():
            path = os.path.join(assets_dir, filename)
            try:
                self._icons[key] = tk.PhotoImage(file=path)
            except Exception:
                self._icons[key] = None  # missing/corrupt asset shouldn't crash the lock screen

        # Header logo + the bigger seal on the card: round, built from the
        # full-res icon_college_logo.png so they stay sharp. Falls back to
        # the old square small icon if Pillow isn't installed.
        big_logo_path = os.path.join(assets_dir, 'icon_college_logo.png')
        circular = self._make_circular_logo(big_logo_path, self.HEADER_LOGO_SIZE)
        if circular is not None:
            self._icons['college_logo_small'] = circular
        else:
            try:
                self._icons['college_logo_small'] = tk.PhotoImage(
                    file=os.path.join(assets_dir, 'icon_college_logo_small.png'))
            except Exception:
                self._icons['college_logo_small'] = None
        self._icons['card_logo'] = (
            self._make_circular_logo(big_logo_path, 62) or self._icons.get('college_logo_small'))

        # Line icons drawn in code (so no extra asset files are needed).
        # Each one replaces the matching PNG when Pillow is available.
        dark = '#2a1a00'
        drawn = {
            'user': ('user', 18, self.ACCENT),
            'lock': ('lock', 18, self.ACCENT),
            'eye': ('eye', 18, self.MUTED),
            'eye_off': ('eye_off', 18, self.MUTED),
            'hdr_clock': ('clock', 26, self.ACCENT),
            'hdr_cal': ('calendar', 24, self.ACCENT),
            'hdr_wifi': ('wifi', 26, self.ACCENT),
            'hdr_wifi_off': ('wifi', 26, self.ERROR),
            'btn_monitor': ('monitor', 20, dark),
            'btn_chevron': ('chevron', 16, dark),
            'st_user': ('user', 14, self.ACCENT),
            'st_wifi': ('wifi', 14, self.ACCENT),
            'st_monitor': ('monitor', 14, self.ACCENT),
            'restart': ('restart', 16, self.ACCENT),
            'power': ('power', 16, self.ACCENT),
            'shield': ('shield', 15, self.ACCENT),
            'panel_monitor': ('monitor', 28, self.ACCENT),
        }
        for key, (kind, size, color) in drawn.items():
            img = self._make_icon(kind, size, color)
            if img is not None:
                self._icons[key] = img

    def _layout_geometry(self):
        """Decides where the baked-in HUD panels go (top-right clock/network
        panel, bottom-left college panel, bottom-right motto panel) and
        where the login card sits. Both _draw_background (which bakes the
        panels into the photo) and the canvas text/icons drawn over them
        read these numbers, so they always line up."""
        sw, sh = self.screen_w, self.screen_h
        self._card_cy = sh // 2 + 4
        k = self._s
        hr_w, hr_h = int(372 * k), int(52 * k)
        self._hr_box = (sw - 24 - hr_w, 12, sw - 24, 12 + hr_h)
        self._hr_cy = 12 + hr_h // 2
        pw, ph = int(300 * k), int(46 * k)
        self._bl_box = (24, sh - 18 - ph, 24 + pw, sh - 18)
        self._br_box = (sw - 24 - pw, sh - 18 - ph, sw - 24, sh - 18)
        self._panel_boxes = [self._hr_box, self._bl_box, self._br_box]

    def _card_points(self, inset=0, c=22):
        cx = self.screen_w // 2
        left, right = cx - self.CARD_W // 2 + inset, cx + self.CARD_W // 2 - inset
        top, bottom = self._card_cy - self.CARD_H // 2 + inset, self._card_cy + self.CARD_H // 2 - inset
        return [
            left + c, top,       right - c, top,
            right, top + c,      right, bottom - c,
            right - c, bottom,   left + c, bottom,
            left, bottom - c,    left, top + c,
        ]

    def _draw_glow_rings(self, canvas, cx, cy, max_r=50):
        """Soft concentric rings behind the padlock badge — Tkinter has no
        real blur, so this fakes a glow by fading the ring colour toward the
        card background as the radius grows. Returns the ring item ids so
        _pulse_dot() can make them breathe."""
        ids = []
        for r in (max_r, max_r * 0.84, max_r * 0.68):
            ids.append(canvas.create_oval(cx - r, cy - r, cx + r, cy + r, outline=self.ACCENT_DIM, width=1))
        self._badge_canvas = canvas
        return ids

    def _draw_badge_circuit(self, canvas, bw, bh):
        """Thin circuit-board traces running out to the left and right of
        the padlock, like the approved design."""
        cy = bh // 2
        traces = [
            [(10, cy), (96, cy)],
            [(34, cy - 12), (70, cy - 12), (82, cy)],
            [(34, cy + 12), (70, cy + 12), (82, cy)],
        ]
        for pts in traces:
            for mirror in (False, True):
                flat = []
                for x, y in pts:
                    flat += [(bw - x) if mirror else x, y]
                canvas.create_line(*flat, fill=self.ACCENT_DIM, width=1)
                ex, ey = flat[0], flat[1]
                canvas.create_oval(ex - 2, ey - 2, ex + 2, ey + 2, fill=self.ACCENT, outline='')

    def _pulse_dot(self):
        """Gentle breathing glow on the padlock's rings (replaces the old
        blinking 'COMPUTER LABORATORY' eyebrow text)."""
        self._pulse_on = not self._pulse_on
        base = 0.45 if self._pulse_on else 0.7
        try:
            for i, item in enumerate(getattr(self, '_glow_ring_ids', [])):
                color = self._lerp_color(self.ACCENT, self.CARD_BG, min(0.95, base + 0.14 * i))
                self._badge_canvas.itemconfig(item, outline=color)
        except tk.TclError:
            pass
        self.root.after(900, self._pulse_dot)

    # -- background photo + baked HUD chrome ---------------------------------

    def _compose_scene(self, base):
        """Bakes the translucent HUD chrome onto the (already brightness-
        adjusted) photo: a navy fade under the header and along the bottom,
        the three glass panels (clock/network, college, motto) with thin
        blue outlines, and the soft blue glow around the login card. Done
        once with Pillow at startup, because Tk canvases can't do alpha."""
        sw, sh = base.size
        img = base.convert('RGBA')

        def band(height, from_top, strength):
            grad = Image.linear_gradient('L').resize((sw, height))
            if from_top:
                grad = ImageChops.invert(grad)
            layer = Image.new('RGBA', (sw, height), (2, 8, 20, 255))
            layer.putalpha(grad.point(lambda v: int(v * strength)))
            return layer

        img.alpha_composite(band(130, True, 0.92), (0, 0))
        img.alpha_composite(band(150, False, 0.88), (0, sh - 150))

        def chamfer(box, c):
            x0, y0, x1, y1 = box
            return [x0 + c, y0, x1 - c, y0, x1, y0 + c, x1, y1 - c,
                    x1 - c, y1, x0 + c, y1, x0, y1 - c, x0, y0 + c]

        glow = Image.new('RGBA', (sw, sh), (0, 0, 0, 0))
        fill = Image.new('RGBA', (sw, sh), (0, 0, 0, 0))
        edge = Image.new('RGBA', (sw, sh), (0, 0, 0, 0))
        gd, fd, ed = ImageDraw.Draw(glow), ImageDraw.Draw(fill), ImageDraw.Draw(edge)

        for box in self._panel_boxes:
            pts = chamfer(box, 10)
            fd.polygon(pts, fill=(6, 22, 46, 208))
            gd.line(pts + pts[:2], fill=(40, 150, 255, 200), width=4)
            ed.line(pts + pts[:2], fill=(64, 168, 255, 255), width=1)

        card = self._card_points()
        gd.line(card + card[:2], fill=(47, 140, 255, 255), width=12)

        img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(13)))
        img = Image.alpha_composite(img, fill)
        img = Image.alpha_composite(img, edge)
        return img.convert('RGB')

    def _draw_background(self):
        """Full-screen backdrop: the school building photo
        (assets/bg_building.jpg), cropped to fit (not stretched), lightly
        darkened, with the HUD panels and card glow baked in by
        _compose_scene(). Needs Pillow (`pip install Pillow`); without it the
        screen falls back to a plain dark background so the agent still runs
        on the standard library alone.

        Also pre-renders a second, blurred + much darker copy that
        _apply_lab_open_state() swaps in while the lab is closed, so the
        "LABORATORY CLOSED" heading reads as the focal point.
        self._bg_image_id is kept so that swap is a cheap itemconfig()."""
        self._bg_photo = None
        self._bg_photo_blurred = None
        self._bg_image_id = None
        bg_path = os.path.join(APP_DIR, 'assets', 'bg_building.jpg')
        if _PIL_AVAILABLE and os.path.exists(bg_path):
            try:
                img = Image.open(bg_path).convert('RGB')
                img = ImageOps.fit(img, (self.screen_w, self.screen_h), Image.LANCZOS)

                normal_img = ImageEnhance.Brightness(img).enhance(0.7)
                # cool blue grade so it matches the HUD colours
                tint = Image.new('RGB', img.size, (8, 28, 70))
                normal_img = Image.blend(normal_img, tint, 0.16)
                self._bg_photo = ImageTk.PhotoImage(self._compose_scene(normal_img))  # keep a ref — Tk drops unreferenced images

                closed_img = img.filter(ImageFilter.GaussianBlur(radius=14))
                closed_img = ImageEnhance.Brightness(closed_img).enhance(0.25)
                self._bg_photo_blurred = ImageTk.PhotoImage(self._compose_scene(closed_img))

                self._bg_image_id = self.canvas.create_image(0, 0, anchor='nw', image=self._bg_photo)
                return
            except Exception as e:
                print(f'[agent] Could not load background photo: {e}')

    def _draw_chrome_accents(self):
        """Thin blue rule + gold slashes: the little diagonal accents from
        the design (under the college name, and in the bottom-right corner)."""
        c, sw, sh = self.canvas, self.screen_w, self.screen_h
        hy = self.HEADER_H + 10
        c.create_line(0, hy + 6, 112, hy + 6, fill=self.BLUE_GLOW, width=1)
        c.create_line(112, hy + 6, 124, hy, 178, hy, fill=self.GOLD, width=3)
        # bottom-right corner slashes
        c.create_line(sw - 46, sh - 86, sw - 18, sh - 118, fill=self.GOLD, width=3)
        c.create_line(sw - 62, sh - 86, sw - 52, sh - 98, fill=self.GOLD, width=3)
        c.create_line(sw - 18, sh - 118, sw - 18, sh - 124, fill=self.BLUE_GLOW, width=1)
        # bottom-left tiny accent
        c.create_line(24, sh - 70, 24 + 46, sh - 70, fill=self.BLUE_GLOW, width=1)

    def _draw_header(self):
        """Everything drawn straight onto the canvas around the card: the
        college logo + name (top-left), the LEARN / GROW / SUCCEED tagline,
        the clock / date / network panel (top-right), and the two bottom
        panels. The panel backgrounds themselves are baked into the photo
        (see _compose_scene); only text and icons are drawn here."""
        c, cfg = self.canvas, self.config
        sw, sh = self.screen_w, self.screen_h
        S = lambda v: int(round(v * self._s))

        # --- top-left: logo + college name ---------------------------------
        lx, ly = 56, 40
        text_x = 28
        logo = self._icons.get('college_logo_small')
        if logo is not None:
            c.create_oval(lx - 29, ly - 29, lx + 29, ly + 29, outline=self.GOLD, width=2)
            c.create_image(lx, ly, image=logo)
            text_x = lx + 29 + 16
        college_name = cfg.get('college_name', 'Danao Technological College')
        college_subtitle = cfg.get('college_subtitle', 'A Smart Computer Laboratory Management System')
        c.create_text(text_x, ly - 11, anchor='w', text=college_name.upper(),
                      font=(self.FONT_UI, 15, 'bold'), fill=self.TEXT)
        c.create_text(text_x, ly + 11, anchor='w', text=college_subtitle,
                      font=(self.FONT_UI, 10), fill='#b9cde3')

        # --- left tagline ----------------------------------------------------
        ty = int(sh * 0.23)
        c.create_line(68, ty - 10, 68, ty + 26, fill=self.GOLD, width=2)
        c.create_text(82, ty, anchor='w', text=cfg.get('tagline', 'LEARN  /  GROW  /  SUCCEED'),
                      font=(self.FONT_UI, 11), fill=self.ACCENT)
        c.create_text(82, ty + S(22), anchor='w', text=cfg.get('tagline_sub', 'Through Technology and Innovation'),
                      font=(self.FONT_UI, 9), fill='#d3e4f6')

        # --- top-right panel: clock | date | calendar | network --------------
        pl, cy = self._hr_box[0], self._hr_cy

        def icon(key, x):
            if self._icons.get(key) is not None:
                return c.create_image(x, cy, image=self._icons[key])
            return None

        icon('hdr_clock', pl + S(28))
        self._time_id = c.create_text(pl + S(50), cy - 9, anchor='w', text='',
                                      font=(self.FONT_UI, 13, 'bold'), fill=self.TEXT)
        self._date_id = c.create_text(pl + S(50), cy + 11, anchor='w', text='',
                                      font=(self.FONT_UI, 8), fill='#a9c7e6')
        icon('hdr_cal', pl + S(214))
        c.create_line(pl + S(244), cy - 16, pl + S(244), cy + 16, fill=self.FIELD_BORDER, width=1)
        self._net_icon_id = icon('hdr_wifi', pl + S(274))
        c.create_text(pl + S(294), cy - 9, anchor='w', text='Network',
                      font=(self.FONT_UI, 8), fill='#a9c7e6')
        self._net_text_id = c.create_text(pl + S(294), cy + 9, anchor='w', text='Connected',
                                          font=(self.FONT_UI, 9, 'bold'), fill=self.TEXT)

        # --- bottom-left panel: college + PC name -----------------------------
        bl = self._bl_box
        bcy = (bl[1] + bl[3]) // 2
        if self._icons.get('panel_monitor') is not None:
            c.create_image(bl[0] + S(30), bcy, image=self._icons['panel_monitor'])
        c.create_text(bl[0] + S(58), bcy - 9, anchor='w', text=college_name.upper(),
                      font=(self.FONT_UI, 8, 'bold'), fill=self.TEXT)
        pc_id = c.create_text(bl[0] + S(58), bcy + 9, anchor='w',
                              text=f'Computer Laboratory  \u2022  {self.pc_name}',
                              font=(self.FONT_UI, 8), fill=self.ACCENT)
        # apply_pc_info() updates this like a normal label
        self.pc_name_label = CanvasLabel(c, pc_id)

        # --- bottom-right panel: motto -----------------------------------------
        br = self._br_box
        mcy = (br[1] + br[3]) // 2
        motto = cfg.get('footer_motto', 'Technology Today, Better Tomorrow')
        if ',' in motto:
            first, second = [p.strip() for p in motto.split(',', 1)]
            first += ','
        else:
            first, second = motto, ''
        rx = br[2] - S(26)
        c.create_text(rx, mcy - 9 if second else mcy, anchor='e', text=first,
                      font=(self.FONT_UI, 10, 'italic'), fill=self.TEXT)
        if second:
            sid = c.create_text(rx, mcy + 9, anchor='e', text=second,
                                font=(self.FONT_UI, 10, 'italic'), fill=self.TEXT)
            bx = c.bbox(sid)
            c.create_line(bx[0], bx[3] + 2, bx[2], bx[3] + 2, fill=self.GOLD, width=2)

    def _draw_header_right(self, time_str, date_str, day_str):
        """Updates the clock/date text in the top-right panel (called once
        a second by _tick_clock). The panel's icons and static text are
        created once in _draw_header."""
        if getattr(self, '_time_id', None) is None:
            return
        self.canvas.itemconfig(self._time_id, text=time_str)
        self.canvas.itemconfig(self._date_id, text=date_str)

    def _set_header_network(self, is_connected):
        """Mirrors the NETWORK status into the top-right panel."""
        self._net_ok = bool(is_connected)
        if getattr(self, '_net_text_id', None) is None:
            return
        self.canvas.itemconfig(
            self._net_text_id,
            text='Connected' if is_connected else 'Offline',
            fill=self.TEXT if is_connected else self.ERROR,
        )
        key = 'hdr_wifi' if is_connected else 'hdr_wifi_off'
        if getattr(self, '_net_icon_id', None) is not None and self._icons.get(key) is not None:
            self.canvas.itemconfig(self._net_icon_id, image=self._icons[key])

    def _tick_clock(self):
        now = datetime.datetime.now()
        time_str = now.strftime('%I:%M %p').lstrip('0')
        date_str = now.strftime('%B %d, %Y')
        day_str = now.strftime('%A')
        self._draw_header_right(time_str, date_str, day_str)
        self.root.after(1000, self._tick_clock)

    def _draw_card_border(self):
        """Glowing blue chamfered (cut-corner) border around the login card.
        The soft outer glow is baked into the photo (_compose_scene); this
        draws the crisp card body and outlines on top of it."""
        c = self.canvas
        outer = self._card_points()
        c.create_polygon(outer, outline=self.BLUE_GLOW, fill=self.CARD_BG, width=2, joinstyle='miter')
        c.create_polygon(self._card_points(inset=6, c=18), outline=self.FIELD_BORDER, fill='', width=1)

        # bright accents: top-centre notch + a short tick off each chamfer
        cx = self.screen_w // 2
        top = outer[1]
        c.create_line(cx - 46, top, cx + 46, top, fill=self.ACCENT, width=3)
        tick = 14
        for x, y, dx, dy in (
            (outer[0], outer[1], -1, -1), (outer[2], outer[3], 1, -1),
            (outer[8], outer[9], 1, 1), (outer[10], outer[11], -1, 1),
        ):
            c.create_line(x, y, x + tick * dx, y + tick * dy, fill=self.ACCENT_DIM, width=1)

    # Fixed width for the icon area inside each input field, and a fixed
    # overall height for the field box (locked with pack_propagate(False) so
    # the box can never auto-size smaller than its icon and clip it).
    FIELD_ICON_HOLDER_W = 36
    FIELD_BOX_H = 40

    def _build_field(self, parent, icon_key, placeholder, show=None, toggle=False, width=None):
        """One icon-prefixed input box with simulated placeholder text
        (Tkinter Entry has no native placeholder support). With
        toggle=True an eye icon on the right shows/hides the typed text
        (used for the Reservation Code, which starts hidden)."""
        box = tk.Frame(parent, bg=self.FIELD_BG, highlightthickness=1,
                       highlightbackground=self.FIELD_BORDER, highlightcolor=self.ACCENT,
                       height=self.FIELD_BOX_H, width=width or 300)
        box.pack_propagate(False)
        icon_holder = tk.Frame(box, bg=self.FIELD_BG, width=self.FIELD_ICON_HOLDER_W)
        icon_holder.pack(side='left', fill='y', padx=(6, 0))
        icon_holder.pack_propagate(False)
        icon_img = self._icons.get(icon_key)
        if icon_img is not None:
            tk.Label(icon_holder, image=icon_img, bg=self.FIELD_BG).place(relx=0.5, rely=0.5, anchor='center')

        entry = tk.Entry(
            box, font=(self.FONT_UI, 10), bg=self.FIELD_BG, fg=self.MUTED,
            insertbackground=self.ACCENT, relief='flat', bd=0, show='', highlightthickness=0,
            disabledbackground=self.FIELD_BG, disabledforeground=self.MUTED,
        )
        if toggle:
            eye = tk.Label(box, bg=self.FIELD_BG, cursor='hand2', fg=self.MUTED, font=(self.FONT_UI, 11))
            if self._icons.get('eye') is not None:
                eye.config(image=self._icons['eye'])
            else:
                eye.config(text='\u25c9')
            eye.pack(side='right', padx=(0, 10))
        entry.pack(side='left', fill='both', expand=True, padx=(0, 8), pady=5)
        entry.insert(0, placeholder)
        entry._placeholder = placeholder
        entry._is_placeholder = True
        entry._real_show = show

        def clear_placeholder():
            if entry._is_placeholder:
                entry.delete(0, 'end')
                entry.config(fg=self.TEXT, show=entry._real_show or '')
                entry._is_placeholder = False

        def on_focus_in(_e):
            if entry._is_placeholder:
                entry.icursor(0)  # cursor sits in front of the hint text
            box.config(highlightbackground=self.ACCENT, highlightthickness=2)

        def on_key(e):
            if not entry._is_placeholder:
                return None
            if e.keysym in ('BackSpace', 'Delete', 'Left', 'Right', 'Home', 'End'):
                return 'break'  # nothing real to delete/move over yet
            if e.char and e.char.isprintable() and not (e.state & 0x4):  # printable, no Ctrl
                clear_placeholder()
            return None

        def on_paste(_e):
            clear_placeholder()
            return None

        def on_click(_e):
            if entry._is_placeholder:
                entry.after_idle(lambda: entry.icursor(0))

        def on_focus_out(_e):
            if not entry.get():
                entry.config(show='')
                entry.insert(0, entry._placeholder)
                entry.config(fg=self.MUTED)
                entry._is_placeholder = True
            box.config(highlightbackground=self.FIELD_BORDER, highlightthickness=1)

        entry.bind('<FocusIn>', on_focus_in)
        entry.bind('<Key>', on_key)
        entry.bind('<<Paste>>', on_paste)
        entry.bind('<Button-1>', on_click, add='+')
        entry.bind('<FocusOut>', on_focus_out)

        if toggle:
            def flip(_e=None):
                entry._real_show = '' if entry._real_show else '\u2022'
                if not entry._is_placeholder:
                    entry.config(show=entry._real_show)
                key = 'eye' if entry._real_show else 'eye_off'
                if self._icons.get(key) is not None:
                    eye.config(image=self._icons[key])
                else:
                    eye.config(text='\u25c9' if entry._real_show else '\u25cb')
            eye.bind('<Button-1>', flip)
        return box, entry

    def _reset_entry(self, entry):
        """Clears an input field AND puts its placeholder text back (a bare
        entry.delete() leaves the field blank with no hint until it's
        focused and un-focused once)."""
        prev_state = str(entry.cget('state'))
        entry.config(state='normal')
        entry.delete(0, 'end')
        entry.insert(0, entry._placeholder)
        entry.config(fg=self.MUTED, show='')
        entry._is_placeholder = True
        if prev_state == 'disabled':
            entry.config(state='disabled')

    def _build_status_col(self, parent, key, label, value, col_index):
        """One column of the status row: a small icon + label on top, the
        current value (green when healthy, with a leading dot) underneath,
        gridded into column `col_index` of an equal-width 3-column row.
        Returns the value label so callers can update it later (e.g. STATUS
        flipping between 'Ready for Login' and 'Verifying...')."""
        icon_key = {'computer_status': 'st_user', 'network_status': 'st_wifi', 'lab_status': 'st_monitor'}.get(key)
        col = tk.Frame(parent, bg=self.STATUS_BG)
        col.grid(row=0, column=col_index, sticky='nsew')

        label_row = tk.Frame(col, bg=self.STATUS_BG)
        label_row.pack(anchor='center', pady=(8, 2))
        icon_img = self._icons.get(icon_key)
        if icon_img is not None:
            tk.Label(label_row, image=icon_img, bg=self.STATUS_BG).pack(side='left', padx=(0, 5))
        tk.Label(
            label_row, text=label, font=(self.FONT_UI, 8, 'bold'), fg=self.TEXT, bg=self.STATUS_BG,
        ).pack(side='left')

        value_label = DotLabel(
            col, text=value, font=(self.FONT_UI, 8, 'bold'), fg=self.STATUS_GREEN, bg=self.STATUS_BG,
            wraplength=int(116 * self._s), justify='center',
        )
        value_label.pack(anchor='center')
        return value_label

    @staticmethod
    def field_value(entry):
        """Real typed value, or '' if the field still shows its placeholder."""
        return '' if getattr(entry, '_is_placeholder', False) else entry.get().strip()

    @staticmethod
    def _lerp_color(c1, c2, t):
        c1, c2 = c1.lstrip('#'), c2.lstrip('#')
        r1, g1, b1 = int(c1[0:2], 16), int(c1[2:4], 16), int(c1[4:6], 16)
        r2, g2, b2 = int(c2[0:2], 16), int(c2[2:4], 16), int(c2[4:6], 16)
        r = int(r1 + (r2 - r1) * t)
        g = int(g1 + (g2 - g1) * t)
        b = int(b1 + (b2 - b1) * t)
        return f'#{r:02x}{g:02x}{b:02x}'

    def _build_unlock_button(self, parent, width, height=42):
        canvas = tk.Canvas(parent, width=width, height=height, bg=self.CARD_BG, highlightthickness=0, cursor='hand2')
        text_id = self._paint_button(canvas, width, height, self.BTN_L, self.BTN_R, 'UNLOCK COMPUTER')
        canvas.bind('<Enter>', lambda e: None if (self.submitting or not self.lab_open) else self._paint_button(canvas, width, height, self.BTN_HOVER_L, self.BTN_HOVER_R, 'UNLOCK COMPUTER'))
        canvas.bind('<Leave>', lambda e: None if (self.submitting or not self.lab_open) else self._paint_button(canvas, width, height, self.BTN_L, self.BTN_R, 'UNLOCK COMPUTER'))
        canvas.bind('<Button-1>', lambda e: self.on_submit())
        return canvas, text_id

    def _paint_button(self, canvas, width, height, left_color, right_color, label):
        """Paints the big gold gradient button: monitor icon + label in the
        middle, a chevron at the right edge. When called with the
        FIELD_BORDER colours (the 'VERIFYING...' / 'LAB CLOSED' states) it
        draws a flat, muted, disabled-looking button instead."""
        canvas.delete('all')
        disabled = (left_color == self.FIELD_BORDER)
        step = 2
        for x in range(0, width, step):
            t = x / max(1, width)
            canvas.create_rectangle(x, 0, x + step, height,
                                    fill=self._lerp_color(left_color, right_color, t), outline='')
        if not disabled:
            canvas.create_line(0, 1, width, 1, fill=self._lerp_color(right_color, '#ffffff', 0.4))
            canvas.create_line(0, height - 1, width, height - 1, fill=self._lerp_color(left_color, '#000000', 0.25))
        fg = self.MUTED if disabled else '#2a1a00'
        font = (self.FONT_UI, 10, 'bold')
        is_unlock = (label == 'UNLOCK COMPUTER')
        icon_img = self._icons.get('btn_monitor') if (is_unlock and not disabled) else None

        # Measure the label's real rendered width instead of guessing from
        # its character count, then lay out icon + gap + text as one
        # centred group so they can never collide.
        text_id = canvas.create_text(0, height / 2, anchor='w', text=label, font=font, fill=fg)
        bb = canvas.bbox(text_id)
        text_w = bb[2] - bb[0]
        icon_w = icon_img.width() if icon_img is not None else 0
        gap = 10 if icon_img is not None else 0
        group_w = icon_w + gap + text_w
        start_x = (width - group_w) / 2
        if icon_img is not None:
            canvas.create_image(start_x + icon_w / 2, height / 2, image=icon_img)
        canvas.coords(text_id, start_x + icon_w + gap, height / 2)
        chevron = self._icons.get('btn_chevron')
        if chevron is not None and is_unlock and not disabled:
            canvas.create_image(width - 22, height / 2, image=chevron)
        return text_id

    def restart_clicked(self):
        if not messagebox.askyesno(
            'Restart PC',
            'Restart this computer now?\n\nAny unsaved work on this PC will be lost.',
            parent=self.root,
        ):
            return
        try:
            subprocess.run(['shutdown', '/r', '/t', '0'], check=True)
        except Exception as e:
            print(f'[agent] Restart command failed: {e}')
            messagebox.showerror('Restart failed', f"Couldn't restart this PC: {e}", parent=self.root)

    def power_off_clicked(self):
        if not messagebox.askyesno(
            'Power Off PC',
            'Turn off this computer now?\n\nAny unsaved work on this PC will be lost.',
            parent=self.root,
        ):
            return
        try:
            subprocess.run(['shutdown', '/s', '/t', '0'], check=True)
        except Exception as e:
            print(f'[agent] Power off command failed: {e}')
            messagebox.showerror('Power off failed', f"Couldn't power off this PC: {e}", parent=self.root)

    def on_submit(self):
        if self.submitting:
            return
        if not self.lab_open:
            # Belt-and-suspenders: the button already looks disabled and
            # the fields are grayed out (see _apply_lab_open_state), but
            # the canvas's <Button-1> binding itself is unconditional, so
            # this stops a click from firing off a doomed login attempt.
            return
        id_number = self.field_value(self.id_entry)
        code = self.field_value(self.code_entry)

        if not id_number or not code:
            self.status_label.config(fg=self.ERROR, text='Please fill in both ID and Reservation Code.')
            return

        self._pending_id = id_number  # remembered for the heartbeat: who is on this PC
        self.submitting = True
        self._paint_button(self.submit_canvas, self.submit_canvas.winfo_width(), self.BTN_H, self.FIELD_BORDER, self.FIELD_BORDER, 'VERIFYING...')
        self.status_label.config(fg=self.MUTED, text='Confirming your reservation...')
        if getattr(self, 'computer_status_value', None) is not None:
            self.computer_status_value.config(text='Verifying...', fg=self.GOLD)

        submit_login_in_background(
            self.config.get('server_url', 'http://127.0.0.1:8000'),
            self.config.get('secret', ''),
            id_number,
            code,
        )

    def handle_login_result(self, result):
        self.submitting = False
        self._paint_button(self.submit_canvas, self.submit_canvas.winfo_width(), self.BTN_H, self.BTN_L, self.BTN_R, 'UNLOCK COMPUTER')

        if result.get('ok'):
            self.status_label.config(fg=self.SUCCESS, text=f"Welcome, {result.get('student_name', '')}!")
            self._reset_entry(self.id_entry)
            self._reset_entry(self.code_entry)
            # Unlock either way — if unlock_success is False that only means
            # this agent's own local unlock step reported a problem, which
            # in practice can't really happen since hiding the screen IS
            # that step; still, don't leave the student stuck on a verified
            # login.
            self._session_user = (getattr(self, '_pending_id', None), result.get('student_name'))
            self.unlock_for_session(result.get('session_end_time'), result.get('server_time'))
        else:
            self.status_label.config(fg=self.ERROR, text=result.get('error', 'Something went wrong, please try again.'))
            self.code_entry.delete(0, 'end')
            self.code_entry.focus_set()

    def unlock_for_session(self, session_end_time_str, server_time_str=None):
        """Hides the lock screen and, if we know when the reservation ends,
        schedules an automatic re-lock for that moment (plus a warning
        shortly before). Also brings up the MiniPanel with its 'Lock Now'
        button for ending the session early.

        `server_time_str` (HH:MM:SS, Asia/Manila) is the server's own clock
        at the moment it handled the login. We use it to compute this PC's
        clock offset/drift and schedule everything against the SERVER's
        idea of "now", not this lab PC's own (possibly wrong) system clock.
        Without this, a lab PC whose Windows clock is off by even a few
        minutes fires the warning/auto-relock at the wrong real-world
        moment — or seemingly "never", if the PC thinks it's earlier than
        it actually is.

        `session_end_time_str` can be None — this is the path used for a
        manual/remote unlock triggered from the CompuLab web control page
        (Lab In-Charge pressing "Unlock PC"), where there's no reservation
        tied to the unlock. In that case no auto-relock timer or warning
        banner is scheduled (there's no end time to count down to), but the
        MiniPanel with its "Lock Now" button still appears — the student is
        the one who decides when to end the session, exactly like the
        normal login flow, just without a countdown clock.
        """
        self.hide()  # login API call already updated server state
        self.start_activity_reporting()

        self._session_end_dt = None
        self._warning_shown = False
        self._clock_offset = datetime.timedelta(0)

        local_now = datetime.datetime.now()

        if server_time_str:
            try:
                server_time = datetime.datetime.strptime(server_time_str, '%H:%M:%S').time()
                server_now = datetime.datetime.combine(datetime.date.today(), server_time)
                # offset = how far ahead the server's clock is vs ours;
                # add this to our own datetime.now() readings from now on.
                self._clock_offset = server_now - local_now
            except ValueError:
                self._clock_offset = datetime.timedelta(0)

        if session_end_time_str:
            try:
                end_time = datetime.datetime.strptime(session_end_time_str, '%H:%M:%S').time()
                self._session_end_dt = datetime.datetime.combine(datetime.date.today(), end_time)
            except ValueError:
                self._session_end_dt = None

        if self.mini_panel:
            self.mini_panel.set_warning(False)
            self.mini_panel.show()
            self._tick_countdown()

        if self._session_end_dt:
            remaining = (self._session_end_dt - self._server_synced_now()).total_seconds()
            ms = max(int(remaining * 1000), 0)
            self._relock_after_id = self.root.after(ms, self._auto_relock)

            warning_delay = remaining - self.WARNING_LEAD_SECONDS
            if warning_delay > 0:
                self._warning_after_id = self.root.after(int(warning_delay * 1000), self._show_warning)
            else:
                # Less than the warning window remains right from login —
                # show the warning immediately instead of skipping it.
                self._show_warning()
        # else: no session_end_time known (manual/remote unlock) — no
        # auto-relock timer, no warning banner. MiniPanel's countdown label
        # just stays blank (see _tick_countdown below) until the student
        # presses "Lock Now" themselves, or the server sends a /lock signal.

    def start_activity_reporting(self):
        """Kicks off a background loop that samples the active window's
        title every `activity_report_interval_seconds` and reports it to
        the server, for as long as the PC stays unlocked. No-op if the
        interval is configured to 0/blank (feature disabled) or a loop is
        already running."""
        interval = self.config.get('activity_report_interval_seconds', 8)
        try:
            interval = float(interval)
        except (TypeError, ValueError):
            interval = 0
        if interval <= 0 or self._activity_thread is not None:
            return

        self._activity_stop_event.clear()
        server_url = self.config.get('server_url', 'http://127.0.0.1:8000')
        secret = self.config.get('secret', '')

        def loop():
            # UI Automation requires each thread that uses it to initialize
            # its own COM apartment first — this thread is not the main
            # thread, so without this, every get_active_window_url() call
            # below fails silently (caught by its own try/except) and we
            # always fall back to guessing the site from title keywords,
            # which is exactly the bug that caused ChatGPT tabs with
            # "GitHub" in the conversation title to be mislabeled.
            uia_ctx = _uia.UIAutomationInitializerInThread() if _uia else None
            if uia_ctx:
                uia_ctx.__enter__()
            try:
                while not self._activity_stop_event.is_set():
                    hwnd = get_foreground_hwnd()
                    title = get_active_window_title(hwnd)
                    if title:
                        page_url = get_active_window_url(hwnd)
                        report_activity_in_background(server_url, secret, title, page_url)
                    self._activity_stop_event.wait(interval)
            finally:
                if uia_ctx:
                    uia_ctx.__exit__(None, None, None)

        self._activity_thread = threading.Thread(target=loop, name='compulab-agent-activity', daemon=True)
        self._activity_thread.start()

    def stop_activity_reporting(self):
        self._activity_stop_event.set()
        self._activity_thread = None

    def _server_synced_now(self):
        """This PC's best estimate of the server's current wall-clock time:
        our own clock reading plus the offset measured at login. Used
        everywhere we'd otherwise call datetime.datetime.now() for session
        timing, so a lab PC with a drifted/wrong system clock still tracks
        the reservation end time correctly."""
        return datetime.datetime.now() + getattr(self, '_clock_offset', datetime.timedelta(0))

    def _show_warning(self):
        self._warning_shown = True
        self._warning_after_id = None
        if self.mini_panel:
            self.mini_panel.set_warning(True)
        if self.warning_banner:
            self.warning_banner.show()

    def _tick_countdown(self):
        if not self.mini_panel:
            return
        # NOTE: previously this returned here (without re-arming the next
        # tick) whenever the panel wasn't viewable, which silently killed
        # the countdown display forever the first time that happened. We
        # still skip the UI update in that case, but always reschedule.
        if self.mini_panel.win.winfo_viewable():
            if self._session_end_dt:
                remaining = self._session_end_dt - self._server_synced_now()
                total_seconds = max(int(remaining.total_seconds()), 0)
                mins, secs = divmod(total_seconds, 60)
                countdown_text = f'Time left: {mins:02d}:{secs:02d}'
                self.mini_panel.set_countdown(countdown_text)
                if self.warning_banner and self._warning_shown:
                    self.warning_banner.set_detail(
                        f'Please save your work — automatic logout in {mins:02d}:{secs:02d}.'
                    )
            else:
                # Manual/remote unlock with no known end time — no
                # countdown to show, just leave the label blank so the
                # panel reads as "SESSION ACTIVE" with only the Lock Now
                # button, no bogus/leftover timer text.
                self.mini_panel.set_countdown('')
        self._countdown_after_id = self.root.after(1000, self._tick_countdown)

    def _auto_relock(self):
        self._relock_after_id = None
        self.show(reason='expired')

    def start_override_countdown(self, seconds, admin_name):
        """
        Triggered by a '/override-warning' signal from the server: an
        Admin/In-Charge has confirmed taking this PC over for a different
        student. Shows the same red WarningBanner used for the normal
        "session ending soon" notice, ticking down each second, then
        auto-locks (reason='override') once time is up — same as if the
        current student had pressed 'Lock Now' themselves, except this one
        can't be dismissed/cancelled from this side.
        """
        # Cancel any prior override countdown so a second override signal
        # (shouldn't normally happen, but be safe) restarts cleanly instead
        # of stacking timers.
        if self._override_after_id is not None:
            try:
                self.root.after_cancel(self._override_after_id)
            except Exception:
                pass
            self._override_after_id = None
        if self._override_tick_after_id is not None:
            try:
                self.root.after_cancel(self._override_tick_after_id)
            except Exception:
                pass
            self._override_tick_after_id = None

        if not self.warning_banner:
            self._override_after_id = self.root.after(max(0, int(seconds)) * 1000, self._override_auto_lock)
            return

        self._override_seconds_left = max(0, int(seconds))
        self._override_admin_name = admin_name

        def _tick():
            self.warning_banner.set_detail(
                f'{self._override_admin_name} is taking over this PC. '
                f'Save your work now — locking in {self._override_seconds_left} second'
                f'{"s" if self._override_seconds_left != 1 else ""}.'
            )
            if self._override_seconds_left <= 0:
                self._override_tick_after_id = None
                return
            self._override_seconds_left -= 1
            self._override_tick_after_id = self.root.after(1000, _tick)

        self.warning_banner.title_label.config(text='ADMIN OVERRIDE')
        self.warning_banner.show()
        _tick()
        self._override_after_id = self.root.after(max(0, int(seconds)) * 1000, self._override_auto_lock)

    def _override_auto_lock(self):
        self._override_after_id = None
        if self._override_tick_after_id is not None:
            try:
                self.root.after_cancel(self._override_tick_after_id)
            except Exception:
                pass
            self._override_tick_after_id = None
        if self.warning_banner:
            self.warning_banner.hide()
            # Reset the title back to the normal wording for the next time
            # this banner is used for an ordinary reservation-ending warning.
            self.warning_banner.title_label.config(text='SYSTEM WARNING')
        self.show(reason='override')

    def lock_now_clicked(self):
        """The student pressed 'Lock Now' on the MiniPanel — end the session early."""
        self.show(reason='manual')

    def _cancel_timers(self):
        if self._relock_after_id is not None:
            try:
                self.root.after_cancel(self._relock_after_id)
            except Exception:
                pass
            self._relock_after_id = None
        if self._countdown_after_id is not None:
            try:
                self.root.after_cancel(self._countdown_after_id)
            except Exception:
                pass
            self._countdown_after_id = None
        if self._warning_after_id is not None:
            try:
                self.root.after_cancel(self._warning_after_id)
            except Exception:
                pass
            self._warning_after_id = None
        self._warning_shown = False
        if self.warning_banner:
            self.warning_banner.hide()

    def show(self, reason=None):
        """Ends the session. `reason` is 'expired' (auto timer), 'manual'
        (student clicked Lock Now), 'remote_lock' (Lab In-Charge sent a
        /lock signal, e.g. via the offline Manual PC Control tool),
        'override' (Admin/In-Charge Override countdown ran out — see
        start_override_countdown()), or None (startup, before any session
        has ever started).

        None of these sign the student out of Windows anymore — all of
        them just re-show this overlay over the SAME still-signed-in
        Windows session. This matches how the PC behaves before the very
        first login of the day (locked overlay, desktop untouched
        underneath). If a clean desktop is needed for the next student,
        use the Restart button on this screen."""
        self._session_user = None
        self.stop_activity_reporting()
        self._cancel_timers()
        self._session_end_dt = None
        if self.mini_panel:
            self.mini_panel.hide()

        self.root.deiconify()
        screen_w = self.root.winfo_screenwidth()
        screen_h = self.root.winfo_screenheight()
        self.root.geometry(f'{screen_w}x{screen_h}+0+0')
        self.root.attributes('-topmost', True)
        self.status_label.config(text='')
        if getattr(self, 'computer_status_value', None) is not None:
            self.computer_status_value.config(text='Ready for Login', fg=self.STATUS_GREEN)
        self._reset_entry(self.id_entry)
        self._reset_entry(self.code_entry)
        self.root.focus_force()
        self.id_entry.focus_set()
        self.visible = True
        hardening.apply_lock_hardening()

        # Re-check the server for this machine's real pc_id/lab_name every
        # time the lock screen (re)appears — including at startup — so a
        # rename made later in the admin panel shows up here on the very
        # next lock, with no need to re-run the agent or hand-edit
        # agent_config.json on the PC itself.
        fetch_pc_info_in_background(
            self.config.get('server_url', 'http://127.0.0.1:8000'),
            self.config.get('secret', ''),
        )

        if reason in ('expired', 'manual', 'remote_lock', 'override'):
            notify_end_session_sync(
                self.config.get('server_url', 'http://127.0.0.1:8000'),
                self.config.get('secret', ''),
                reason,
            )
            # None of 'expired', 'manual', or 'remote_lock' sign the student
            # out of Windows anymore — all three just re-lock this overlay
            # over the same still-signed-in session. The next student is
            # expected to use the Restart button on this screen (see the
            # Power/Restart buttons below) if a clean desktop is needed
            # before their turn.

    def hide(self):
        self.root.withdraw()
        self.visible = False
        hardening.remove_lock_hardening()

    def apply_pc_info(self, result):
        """Applies the pc_id / lab_name the server says are actually
        registered for this machine (see fetch_pc_info_in_background),
        replacing whatever agent_config.json's fallback "pc_name"/
        "lab_name" values were showing.

        Silently does nothing on failure — e.g. no network yet, or this
        PC hasn't been given an IP address / added in the admin panel —
        so the config.json fallback stays on screen instead of the label
        going blank or showing an error."""
        if not result or not result.get('ok'):
            return

        pc_id = (result.get('pc_id') or '').strip()
        if pc_id:
            self.pc_name = pc_id
            self.pc_name_label.config(text=f'Computer Laboratory  •  {self.pc_name}')

        lab_name = (result.get('lab_name') or '').strip()
        if lab_name and getattr(self, 'lab_status_value', None) is not None:
            self.lab_status_value.config(text=lab_name)

        # 'lab_is_open' only appears once the server actually resolves this
        # PC to a registered Lab (see labs/views.py:pc_agent_info_api) — a
        # missing key (older server, or PC not registered yet) leaves
        # whatever open/closed state is already on screen alone rather than
        # guessing.
        if 'lab_is_open' in result:
            self._apply_lab_open_state(bool(result.get('lab_is_open')), result.get('lab_hours') or '')

    def _apply_lab_open_state(self, is_open, hours_text):
        """Switches the whole lock screen between its normal "ACCESS
        REQUIRED" login state and a prominent "LABORATORY CLOSED" state —
        called whenever a fresh pc-agent-info reply comes in (on every lock
        screen show, and again every 60s via poll_pc_info_in_background)
        with a different lab_is_open value than what's currently on screen.

        Previously, "outside lab hours" only ever showed up as a small red
        line under the Unlock button (result['error'] from an actual login
        attempt, in on_submit -> handle_login_result) — easy to miss, and
        only appeared after someone tried to log in. This makes the closed
        state impossible to miss the moment it's true: the background photo
        blurs and darkens further (see _draw_background's pre-rendered
        self._bg_photo_blurred), the "ACCESS REQUIRED" heading itself
        becomes a bold red "LABORATORY CLOSED", and the ID/Reservation
        fields plus the Unlock button are disabled and grayed out — since
        self-service login can't succeed outside operating hours anyway
        (see verify_reservation_and_check_in on the server), there's
        nothing honest for them to do while closed except show the Lab
        In-Charge if access is really needed.
        """
        self.lab_open = is_open
        self._lab_hours_text = hours_text

        if is_open:
            if self._bg_photo is not None and self._bg_image_id is not None:
                self.canvas.itemconfig(self._bg_image_id, image=self._bg_photo)
            self.title_label.config(text=self._default_title_text, fg=self.TEXT)
            self.subtitle_label.config(text=self._default_subtitle_text, fg=self.MUTED)
            for entry, box in ((self.id_entry, self.id_box), (self.code_entry, self.code_box)):
                entry.config(state='normal')
                box.config(highlightbackground=self.FIELD_BORDER)
            self._paint_button(self.submit_canvas, self._unlock_button_w, self.BTN_H, self.BTN_L, self.BTN_R, 'UNLOCK COMPUTER')
            self.submit_canvas.config(cursor='hand2')
        else:
            if self._bg_photo_blurred is not None and self._bg_image_id is not None:
                self.canvas.itemconfig(self._bg_image_id, image=self._bg_photo_blurred)
            self.title_label.config(text='LABORATORY CLOSED', fg=self.ERROR)
            hours_note = f' Open {hours_text}.' if hours_text else ''
            self.subtitle_label.config(
                text=f'This lab is closed right now.{hours_note} See the Lab In-Charge if you need access.',
                fg=self.ERROR,
            )
            for entry, box in ((self.id_entry, self.id_box), (self.code_entry, self.code_box)):
                entry.config(state='disabled')
                box.config(highlightbackground=self.FIELD_BORDER)
            self._paint_button(self.submit_canvas, self._unlock_button_w, self.BTN_H, self.FIELD_BORDER, self.FIELD_BORDER, 'LAB CLOSED')
            self.submit_canvas.config(cursor='arrow')
            self.status_label.config(text='')

    def apply_network_status(self, is_connected):
        """Updates the NETWORK status pill with the result of the latest
        check_network_in_background probe. Was previously never called at
        all — the pill's text was set once at build time to a hardcoded
        'Connected' and simply never touched again, so it kept showing
        'Connected' even with no network path to the server."""
        self._set_header_network(is_connected)
        if getattr(self, 'network_status_value', None) is None:
            return
        queued = pending_count()
        if is_connected:
            self.network_status_value.config(
                text='Connected' if not queued else f'Connected · sending {queued}', fg=self.STATUS_GREEN,
            )
            if getattr(self, '_offline_notice_shown', False) and not self.submitting:
                self.status_label.config(text='')
            self._offline_notice_shown = False
        else:
            self.network_status_value.config(
                text='Server offline' if not queued else f'Server offline · {queued} queued', fg=self.ERROR,
            )
            # Explain what does and doesn't work, unless the student is in
            # the middle of a sign-in (its own error message wins).
            if self.visible and not self.submitting and (
                    not self.status_label.cget('text') or getattr(self, '_offline_notice_shown', False)):
                self.status_label.config(fg=self.ERROR, text=(
                    'This PC cannot reach the CompuLab server on the campus network right now. '
                    'Sign-in with a reservation code is unavailable until it is back (the internet is not needed). '
                    'Ask your Lab In-Charge for help.'
                ))
                self._offline_notice_shown = True


def poll_queue(root, lock_screen):
    """Runs on the Tk main thread; applies lock/unlock/login-result actions as they arrive.

    IMPORTANT: the re-scheduling call at the bottom must ALWAYS run, no matter
    what happens above. Previously it sat outside the try/except, so a single
    unexpected exception while handling one item (e.g. inside
    handle_login_result/unlock_for_session) would silently kill this polling
    loop forever — no more mini panel updates from here, warning banner,
    auto-relock, or even future /lock /unlock signals, with nothing printed
    to explain why. Each item is now handled in its own try/except so one bad
    item can't take out the rest of the queue either, and the traceback is
    printed so failures are visible in the console instead of invisible.
    """
    try:
        while True:
            item = _command_queue.get_nowait()
            try:
                if item == 'unlock':
                    # CHANGED: a remote/manual unlock (e.g. Lab In-Charge
                    # pressing "Unlock PC" on the phone/web control page)
                    # now goes through the SAME unlock_for_session() path
                    # as a normal student login, instead of a bare
                    # lock_screen.hide(). This is what actually makes the
                    # floating MiniPanel ("SESSION ACTIVE" + "Lock Now"
                    # button) appear on the PC's screen — hide() alone just
                    # hid the overlay with no way for the student to lock
                    # it again themselves.
                    #
                    # session_end_time_str=None because a manual unlock has
                    # no reservation tied to it, so there's nothing to auto-
                    # relock/count down to — the student (or another /lock
                    # signal) is what ends the session.
                    lock_screen.unlock_for_session(session_end_time_str=None)
                elif item == 'lock':
                    # CHANGED: previously called show() with no reason,
                    # which meant a remote /lock signal (e.g. Lab In-Charge
                    # pressing "Lock PC" on the offline Manual PC Control
                    # tool) never told the CompuLab server the session had
                    # ended — pc.current_user/current_session/
                    # current_guest_name stayed pointed at the previous
                    # student, and no 'pc_lock' entry was written to the
                    # Activity Log. Passing 'remote_lock' here makes this
                    # path notify the server too, same as 'expired'/'manual'.
                    lock_screen.show(reason='remote_lock')
                elif isinstance(item, tuple) and item[0] == 'login_result':
                    lock_screen.handle_login_result(item[1])
                elif isinstance(item, tuple) and item[0] == 'pc_info':
                    lock_screen.apply_pc_info(item[1])
                elif isinstance(item, tuple) and item[0] == 'network_status':
                    lock_screen.apply_network_status(item[1])
                elif isinstance(item, tuple) and item[0] == 'override_warning':
                    lock_screen.start_override_countdown(item[1], item[2])
                elif item in ('shutdown', 'restart'):
                    # Same server notification path as a remote /lock —
                    # clears pc.current_user/current_session on the
                    # CompuLab server so it doesn't stay stuck showing
                    # "in use" for a machine that's about to power off —
                    # then actually runs the OS-level command.
                    lock_screen.show(reason='remote_lock')
                    execute_power_command(item)
            except Exception:
                import traceback
                print('[agent] Error while handling queued item — continuing anyway:')
                traceback.print_exc()
    except queue.Empty:
        pass
    finally:
        _schedule_lab_hours_refresh(root, config)
    root.after(200, poll_queue, root, lock_screen)



def _schedule_lab_hours_refresh(root, config):
    """Keep lab OPEN/CLOSED state accurate even when a PC stays locked for hours."""
    def update():
        try:
            fetch_pc_info_in_background(
                config.get('server_url', 'http://127.0.0.1:8000'),
                config.get('secret', ''),
            )
        finally:
            root.after(60_000, update)
    root.after(60_000, update)


def print_status():
    """`python agent.py --status`: configured server, last contact, queued
    events, and a live check of the server. Does not start the lock screen."""
    import sys
    try:
        config = load_config()
        server_url = config.get('server_url', '')
    except SystemExit as e:
        print(e)
        server_url = ''
    status = _read_status()
    print(f'CompuLab agent {AGENT_VERSION}')
    print(f'  Server address : {server_url or "(not configured)"}')
    print(f'  Data folder    : {DATA_DIR}')
    print(f'  Last contact   : {status.get("last_contact_at") or "never"}')
    print(f'  Last check     : {status.get("checked_at") or "never"} '
          f'({"reachable" if status.get("server_reachable") else "unreachable"})')
    if status.get('last_error'):
        print(f'  Last error     : {status["last_error"]}')
    print(f'  Queued events  : {pending_count()} (sent automatically once the server confirms them)')
    if server_url:
        try:
            with urllib.request.urlopen(server_url.rstrip('/') + '/healthz', timeout=5) as r:
                ok = r.read(16).decode('utf-8', 'replace').strip() == 'ok'
            print(f'  Live check     : {"server answers" if ok else "something answered, but not CompuLab"}')
        except Exception as e:
            print(f'  Live check     : server unreachable ({e}). This is a campus network / server problem, '
                  'not an internet problem.')
            sys.exit(2)


def self_test(report_path):
    """`agent.py --self-test <file>` / `CompuLabAgent.exe --self-test <file>`:
    checks what the agent needs without starting the lock screen and writes
    a JSON report (the installer runs this right after installing). Exit
    code 0 when the configuration is valid and the data folder writable;
    an unreachable server is reported but is not a failure (the agent
    keeps retrying once it runs)."""
    report = {
        'agent_version': AGENT_VERSION, 'frozen': bool(getattr(sys, 'frozen', False)),
        'app_dir': APP_DIR, 'data_dir': DATA_DIR, 'data_dir_writable': _writable_dir(DATA_DIR),
        'config_ok': False, 'config_error': '', 'server_url': '', 'server_reachable': False,
        'server_detail': '', 'pending_events': pending_count(),
    }
    try:
        config = load_config()
        url = str(config.get('server_url') or '').rstrip('/')
        if not url.startswith(('http://', 'https://')):
            raise ValueError('server_url must start with http:// or https://')
        int(config.get('port', 5555))
        report.update(config_ok=True, server_url=url)
    except SystemExit as e:
        report['config_error'] = str(e)
    except Exception as e:
        report['config_error'] = f'{e.__class__.__name__}: {e}'
    if report['server_url']:
        try:
            with urllib.request.urlopen(report['server_url'] + '/healthz', timeout=5) as r:
                body = r.read(16).decode('utf-8', 'replace').strip()
            report['server_reachable'] = body == 'ok'
            report['server_detail'] = 'answers' if body == 'ok' else 'something answered, but not CompuLab'
        except Exception as e:
            report['server_detail'] = f'unreachable ({e.__class__.__name__}: {getattr(e, "reason", e)})'
    report['ok'] = report['config_ok'] and report['data_dir_writable']
    with open(report_path, 'w', encoding='utf-8') as f:
        json.dump(report, f, indent=2)
    return 0 if report['ok'] else 1


def _attach_console():
    """The packaged agent is a windowed program: give --status somewhere to print."""
    if getattr(sys, 'frozen', False) and sys.stdout is None and os.name == 'nt':
        import ctypes
        if ctypes.windll.kernel32.AttachConsole(-1) or ctypes.windll.kernel32.AllocConsole():
            sys.stdout = open('CONOUT$', 'w', encoding='utf-8', errors='replace')
            sys.stderr = sys.stdout


def flush_once():
    """`agent.py --flush` / `CompuLabAgent.exe --flush`: send the queued
    events now (oldest first) and exit, without the lock screen. Exit code
    0 when the queue is empty afterwards, 2 when the server is unreachable
    (the events stay queued)."""
    config = load_config()
    return 0 if flush_pending_callbacks(config.get('server_url', 'http://127.0.0.1:8000')) else 2


def main():
    if '--flush' in sys.argv:
        sys.exit(flush_once())
    if '--self-test' in sys.argv:
        idx = sys.argv.index('--self-test')
        path = sys.argv[idx + 1] if len(sys.argv) > idx + 1 else os.path.join(DATA_DIR, 'self_test.json')
        sys.exit(self_test(path))
    if '--status' in sys.argv:
        _attach_console()
        print_status()
        return
    config = load_config()
    port = config.get('port', 5555)

    migrate_legacy_queue()
    start_http_server(port)
    hardening.install_keyboard_hook()
    check_network_in_background(config.get('server_url', 'http://127.0.0.1:8000'))
    start_pending_callback_retrier(config.get('server_url', 'http://127.0.0.1:8000'))
    _flush_now.set()  # send anything left from before a restart
    print(f'CompuLab agent {AGENT_VERSION} listening on port {port} — lock screen active.')

    root = tk.Tk()
    lock_screen = LockScreen(root, config)
    lock_screen.mini_panel = MiniPanel(on_lock_now=lock_screen.lock_now_clicked)
    lock_screen.warning_banner = WarningBanner()
    root.after(200, poll_queue, root, lock_screen)
    root.mainloop()


if __name__ == '__main__':
    main()