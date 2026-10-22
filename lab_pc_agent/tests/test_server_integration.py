"""End-to-end test: the real agent code against the real CompuLab server.

Starts `manage.py runserver` on a scratch SQLite database in a temporary
folder (never the configured database), registers a lab PC at 127.0.0.1,
and checks the agent's event delivery through outages:

  * an event sent while the server is down is queued, then delivered and
    acknowledged once the server is up;
  * re-sending an already delivered event (a lost reply) is acknowledged
    but applied only once (AgentEventReceipt);
  * an event that is older than the PC's current session is ignored, so it
    can't end a newer session;
  * after a server restart, queued events are delivered and applied.

Run from the project folder:
    venv\\Scripts\\python -m unittest lab_pc_agent.tests.test_server_integration -v
  or together with the queue tests:
    venv\\Scripts\\python -m unittest discover -s lab_pc_agent\\tests -v
"""
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

PROJECT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AGENT_DIR = os.path.join(PROJECT, 'lab_pc_agent')
TMP = tempfile.mkdtemp(prefix='compulab-integration-')
os.environ.setdefault('COMPULAB_AGENT_DATA_DIR', os.path.join(TMP, 'agent-data'))
sys.path.insert(0, AGENT_DIR)
import agent  # noqa: E402

SECRET = 'integration-test-secret'
DB = os.path.join(TMP, 'integration.sqlite3')
SETTINGS = f'''
from compulab.settings import *  # noqa
DATABASES = {{"default": {{"ENGINE": "django.db.backends.sqlite3", "NAME": r"{DB}"}}}}
CACHES = {{"default": {{"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}}}
RUN_BACKGROUND_TASKS = False
ALLOWED_HOSTS = ["127.0.0.1", "localhost"]
SECURE_SSL_REDIRECT = False
EMAIL_BACKEND = "django.core.mail.backends.locmem.EmailBackend"
LOG_DIR = r"{TMP}"
'''


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def django_env():
    env = dict(os.environ)
    env.update({
        'PYTHONPATH': TMP, 'DJANGO_SETTINGS_MODULE': 'integration_settings', 'DJANGO_DEBUG': 'True',
        'DJANGO_SECRET_KEY': 'integration-only-key', 'PC_AGENT_SHARED_SECRET': SECRET,
        'COMPULAB_BACKGROUND_TASKS': 'False', 'DJANGO_LOG_DIR': TMP,
    })
    return env


def manage(*args, check=True):
    return subprocess.run([sys.executable, 'manage.py', *args], cwd=PROJECT, env=django_env(),
                          capture_output=True, text=True, check=check, timeout=300)


def orm(code):
    """Run ORM code in the scratch database (as `manage.py shell -c`)."""
    return manage('shell', '-c', code).stdout


def query(sql, *params):
    with sqlite3.connect(DB) as con:
        return con.execute(sql, params).fetchall()


class LiveServerAgentTests(unittest.TestCase):
    server = None

    @classmethod
    def setUpClass(cls):
        # Own queue folder, also when the queue tests ran first in this process.
        data_dir = os.path.join(TMP, 'agent-data')
        os.makedirs(data_dir, exist_ok=True)
        agent.DATA_DIR = data_dir
        agent.PENDING_CALLBACKS_PATH = os.path.join(data_dir, 'pending_callbacks.json')
        agent.STATUS_PATH = os.path.join(data_dir, 'agent_status.json')
        with open(os.path.join(TMP, 'integration_settings.py'), 'w', encoding='utf-8') as f:
            f.write(SETTINGS)
        manage('migrate', '--noinput')
        orm(
            'import datetime; from django.utils import timezone; from labs.models import Lab, PC\n'
            'lab = Lab.objects.create(name="Integration Lab", opening_time=datetime.time(0, 0), closing_time=datetime.time(23, 59))\n'
            'PC.objects.create(lab=lab, pc_id="INT-01", ip_address="127.0.0.1", status="in_use", '
            'current_guest_name="First Guest", last_active=timezone.now() - datetime.timedelta(minutes=10))'
        )
        cls.port = free_port()
        cls.url = f'http://127.0.0.1:{cls.port}'

    @classmethod
    def tearDownClass(cls):
        cls.stop_server()
        shutil.rmtree(TMP, ignore_errors=True)

    @classmethod
    def start_server(cls):
        cls.server = subprocess.Popen(
            [sys.executable, 'manage.py', 'runserver', f'127.0.0.1:{cls.port}', '--noreload'],
            cwd=PROJECT, env=django_env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + 60
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(cls.url + '/healthz', timeout=2) as r:
                    if r.read().strip() == b'ok':
                        return
            except OSError:
                time.sleep(0.5)
        raise RuntimeError('the CompuLab test server did not start')

    @classmethod
    def stop_server(cls):
        if cls.server is not None:
            cls.server.terminate()
            cls.server.wait(timeout=30)
            cls.server = None

    def pc(self):
        return query('SELECT status, current_guest_name FROM labs_pc WHERE pc_id = ?', 'INT-01')[0]

    def receipts(self):
        return query('SELECT kind, outcome FROM labs_agenteventreceipt ORDER BY id')

    def test_outage_delivery_duplicates_late_events_and_restart(self):
        agent._save_pending([])

        # 1. Server down: the session-end event is queued on disk.
        agent.send_callback_reliably(self.url, SECRET, '/labs/api/pc-agent-end-session/', {'reason': 'manual'},
                                     timeout=2, block=True)
        self.assertEqual(agent.pending_count(), 1)
        queued_item = agent._load_pending()[0]

        # 2. Server comes up: the event is delivered, acknowledged and applied.
        self.start_server()
        self.assertTrue(agent.flush_pending_callbacks(self.url, timeout=10))
        self.assertEqual(agent.pending_count(), 0)
        self.assertEqual(self.pc(), ('online', ''))
        self.assertEqual(self.receipts(), [('end_session', '')])
        locks = query("SELECT COUNT(*) FROM accounts_activitylog WHERE action = 'pc_lock'")[0][0]

        # 3. The same event again (as after a lost reply): acknowledged, not applied twice.
        outcome, detail = agent._post_callback(self.url, queued_item, timeout=10)
        self.assertEqual(outcome, agent.DELIVERED)
        self.assertEqual(detail, 'duplicate')
        self.assertEqual(len(self.receipts()), 1)
        self.assertEqual(query("SELECT COUNT(*) FROM accounts_activitylog WHERE action = 'pc_lock'")[0][0], locks)

        # 4. A newer session starts; an event from 2 minutes ago arrives late:
        #    acknowledged but ignored, the newer session stays active.
        orm('from django.utils import timezone; from labs.models import PC\n'
            'PC.objects.filter(pc_id="INT-01").update(status="in_use", current_guest_name="Newer Guest", last_active=timezone.now())')
        late = {'path': '/labs/api/pc-agent-end-session/', 'queued_at': time.time() - 120,
                'body': {'reason': 'expired', 'secret': SECRET, 'event_id': 'late-event-0001', 'agent_version': 'test'}}
        outcome, detail = agent._post_callback(self.url, late, timeout=10)
        self.assertEqual(outcome, agent.DELIVERED)
        self.assertIn('in use again', detail)
        self.assertEqual(self.pc(), ('in_use', 'Newer Guest'))

        # 5. Server restart with an event queued in between: delivered afterwards.
        self.stop_server()
        agent.send_callback_reliably(self.url, SECRET, '/labs/api/pc-agent-logout/', {'reason': 'manual'},
                                     timeout=2, block=True)
        self.assertEqual(agent.pending_count(), 1)
        self.start_server()
        self.assertTrue(agent.flush_pending_callbacks(self.url, timeout=10))
        self.assertEqual(self.pc(), ('online', ''))
        self.assertEqual([k for k, _ in self.receipts()], ['end_session', 'end_session', 'logout'])
        self.assertTrue(agent._read_status()['server_reachable'])

        # 6. The server recorded the agent's contact (shown on PC status / System status).
        contact = query('SELECT agent_last_contact_at, agent_version FROM labs_pc WHERE pc_id = ?', 'INT-01')[0]
        self.assertIsNotNone(contact[0])
        self.assertEqual(contact[1], agent.AGENT_VERSION)

    def test_per_pc_secret_replaces_the_shared_one(self):
        """An agent reinstalled with its PC's own secret (Agent config) is
        accepted, and from then on the shared secret no longer works for it."""
        agent._save_pending([])
        if self.server is None:
            self.start_server()
        own = 'own-secret-for-INT-01-' + 'x' * 30
        orm('from labs.models import PC\n'
            f'PC.objects.filter(pc_id="INT-01").update(agent_secret="{own}", agent_secret_in_use=False)')

        def post(secret, event_id):
            item = {'path': '/labs/api/pc-agent-end-session/', 'queued_at': time.time(),
                    'body': {'reason': 'manual', 'secret': secret, 'event_id': event_id, 'agent_version': 'test'}}
            return agent._post_callback(self.url, item, timeout=10)[0]

        self.assertEqual(post(SECRET, 'shared-before-move'), agent.DELIVERED)   # still on the old file
        self.assertEqual(post(own, 'own-secret-1'), agent.DELIVERED)             # reinstalled with the new file
        self.assertEqual(query("SELECT agent_secret_in_use FROM labs_pc WHERE pc_id = 'INT-01'")[0][0], 1)
        self.assertEqual(post(SECRET, 'shared-after-move'), agent.DROP)
        self.assertEqual(query("SELECT COUNT(*) FROM labs_agenteventreceipt WHERE event_id = 'shared-after-move'")[0][0], 0)

    def test_wrong_secret_is_refused_and_dropped(self):
        agent._save_pending([])
        if self.server is None:
            self.start_server()
        item = {'path': '/labs/api/pc-agent-end-session/', 'queued_at': time.time(),
                'body': {'reason': 'manual', 'secret': 'wrong', 'event_id': 'bad-secret-1'}}
        outcome, _ = agent._post_callback(self.url, item, timeout=10)
        self.assertEqual(outcome, agent.DROP)
        self.assertEqual(query("SELECT COUNT(*) FROM labs_agenteventreceipt WHERE event_id = 'bad-secret-1'")[0][0], 0)


if __name__ == '__main__':
    unittest.main()
