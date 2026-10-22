"""Tests for the lab PC agent's offline event queue (no server, no GUI).

Run from the project folder:
    venv\\Scripts\\python -m unittest discover -s lab_pc_agent\\tests -v

A small fake CompuLab server (http.server on 127.0.0.1) plays the server's
part: acknowledging, failing, refusing or being switched off. The agent
keeps its queue in a temporary folder (COMPULAB_AGENT_DATA_DIR), so nothing
on this computer is touched.
"""
import importlib
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = tempfile.mkdtemp(prefix='compulab-agent-test-')
os.environ['COMPULAB_AGENT_DATA_DIR'] = os.path.join(TMP, 'data')
os.environ['LOCALAPPDATA'] = os.path.join(TMP, 'localappdata')   # legacy queue location
sys.path.insert(0, AGENT_DIR)
import agent  # noqa: E402


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class FakeServer:
    """mode: 'ack' (normal), 'old' (ok without ack, like a pre-2.2 server),
    '500', '403', 'html' (200 but not JSON), 'notok' ({"ok": false})."""

    def __init__(self, port=None):
        self.port = port or free_port()
        self.mode = 'ack'
        self.received = []
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'ok')

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
                server.received.append((self.path, body))
                if server.mode in ('500', '403'):
                    self.send_response(int(server.mode))
                    self.end_headers()
                    self.wfile.write(b'{"ok": false}')
                    return
                self.send_response(200)
                self.end_headers()
                if server.mode == 'html':
                    self.wfile.write(b'<html>login</html>')
                elif server.mode == 'notok':
                    self.wfile.write(b'{"ok": false, "error": "PC not registered"}')
                elif server.mode == 'old':
                    self.wfile.write(b'{"ok": true}')
                else:
                    self.wfile.write(json.dumps({'ok': True, 'ack': body.get('event_id')}).encode())

        self.httpd = ThreadingHTTPServer(('127.0.0.1', self.port), Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    @property
    def url(self):
        return f'http://127.0.0.1:{self.port}'

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def tearDownModule():
    shutil.rmtree(TMP, ignore_errors=True)


class QueueTests(unittest.TestCase):
    def setUp(self):
        agent._save_pending([])
        for path in (agent.STATUS_PATH,):
            if os.path.exists(path):
                os.remove(path)
        self.down_url = f'http://127.0.0.1:{free_port()}'   # nothing listens here

    def send(self, url, reason='manual', path='/labs/api/pc-agent-end-session/'):
        agent.send_callback_reliably(url, 'test-secret', path, {'reason': reason}, timeout=2, block=True)

    def test_data_folder_is_the_configured_one(self):
        self.assertEqual(agent.DATA_DIR, os.environ['COMPULAB_AGENT_DATA_DIR'])
        self.assertTrue(agent._writable_dir(agent.DATA_DIR))

    def test_unreachable_server_queues_event_on_disk(self):
        self.send(self.down_url)
        with open(agent.PENDING_CALLBACKS_PATH, encoding='utf-8') as f:
            items = json.load(f)
        self.assertEqual(len(items), 1)
        self.assertTrue(items[0]['body']['event_id'])
        self.assertEqual(items[0]['body']['reason'], 'manual')
        status = agent._read_status()
        self.assertFalse(status['server_reachable'])
        self.assertEqual(status['pending_events'], 1)

    def test_queue_survives_agent_restart(self):
        self.send(self.down_url)
        event_id = agent._load_pending()[0]['body']['event_id']
        reloaded = importlib.reload(agent)   # a new agent process reads the same folder
        self.assertEqual([i['body']['event_id'] for i in reloaded._load_pending()], [event_id])

    def test_reconnect_delivers_everything_in_order_then_empties_queue(self):
        for reason in ('first', 'second', 'third'):
            self.send(self.down_url, reason)
        self.assertEqual(agent.pending_count(), 3)
        server = FakeServer()
        try:
            self.assertTrue(agent.flush_pending_callbacks(server.url, timeout=2))
            self.assertEqual([b['reason'] for _, b in server.received], ['first', 'second', 'third'])
            self.assertEqual(agent.pending_count(), 0)
            status = agent._read_status()
            self.assertTrue(status['server_reachable'])
            self.assertTrue(status['last_contact_at'])
            # Each event reports how long ago it really happened.
            self.assertTrue(all('queued_seconds_ago' in b for _, b in server.received))
        finally:
            server.stop()

    def test_server_error_keeps_event_and_stops_in_order(self):
        self.send(self.down_url, 'a')
        self.send(self.down_url, 'b')
        server = FakeServer()
        server.mode = '500'
        try:
            self.assertFalse(agent.flush_pending_callbacks(server.url, timeout=2))
            self.assertEqual(len(server.received), 1, 'stops at the first temporary failure')
            self.assertEqual([i['body']['reason'] for i in agent._load_pending()], ['a', 'b'])
        finally:
            server.stop()

    def test_reply_that_is_not_a_confirmation_is_retried(self):
        self.send(self.down_url)
        server = FakeServer()
        server.mode = 'html'   # e.g. a captive portal or proxy page
        try:
            agent.flush_pending_callbacks(server.url, timeout=2)
            self.assertEqual(agent.pending_count(), 1)
        finally:
            server.stop()

    def test_permanent_refusal_is_dropped_not_retried_forever(self):
        for mode in ('403', 'notok'):
            self.send(self.down_url)
            server = FakeServer()
            server.mode = mode
            try:
                self.assertTrue(agent.flush_pending_callbacks(server.url, timeout=2))
                self.assertEqual(agent.pending_count(), 0, mode)
            finally:
                server.stop()

    def test_older_server_without_ack_counts_as_delivered(self):
        self.send(self.down_url)
        server = FakeServer()
        server.mode = 'old'
        try:
            self.assertTrue(agent.flush_pending_callbacks(server.url, timeout=2))
            self.assertEqual(agent.pending_count(), 0)
        finally:
            server.stop()

    def test_direct_send_when_server_is_up_is_not_queued(self):
        server = FakeServer()
        try:
            self.send(server.url)
            self.assertEqual(len(server.received), 1)
            self.assertEqual(agent.pending_count(), 0)
        finally:
            server.stop()

    def test_new_event_waits_behind_older_queued_ones(self):
        self.send(self.down_url, 'old-event')
        server = FakeServer()
        try:
            self.send(server.url, 'new-event')   # server is up, but the queue is not empty
            self.assertEqual(server.received, [], 'must not overtake the queued event')
            self.assertEqual([i['body']['reason'] for i in agent._load_pending()], ['old-event', 'new-event'])
            agent.flush_pending_callbacks(server.url, timeout=2)
            self.assertEqual([b['reason'] for _, b in server.received], ['old-event', 'new-event'])
        finally:
            server.stop()

    def test_queue_is_bounded_and_expires_old_events(self):
        now = time.time()
        items = [{'path': '/x/', 'queued_at': now - 25 * 3600, 'body': {'event_id': 'expired'}}]
        items += [{'path': '/x/', 'queued_at': now - 10 + i * 0.001, 'body': {'event_id': f'e{i}'}} for i in range(250)]
        trimmed = agent._trim(items, now)
        self.assertEqual(len(trimmed), agent.PENDING_MAX_ITEMS)
        self.assertNotIn('expired', [i['body']['event_id'] for i in trimmed])
        self.assertEqual(trimmed[-1]['body']['event_id'], 'e249', 'the newest are kept')

    def test_legacy_per_user_queue_is_moved_into_the_shared_folder(self):
        os.makedirs(os.path.dirname(agent.LEGACY_PENDING_PATH), exist_ok=True)
        legacy = [{'path': '/x/', 'queued_at': time.time(), 'body': {'event_id': 'from-2.1'}}]
        with open(agent.LEGACY_PENDING_PATH, 'w', encoding='utf-8') as f:
            json.dump(legacy, f)
        agent.migrate_legacy_queue()
        self.assertEqual([i['body']['event_id'] for i in agent._load_pending()], ['from-2.1'])
        self.assertFalse(os.path.exists(agent.LEGACY_PENDING_PATH))
        agent.migrate_legacy_queue()   # running again changes nothing
        self.assertEqual(agent.pending_count(), 1)

    def test_corrupt_queue_file_does_not_crash_the_agent(self):
        with open(agent.PENDING_CALLBACKS_PATH, 'w', encoding='utf-8') as f:
            f.write('{not json')
        self.assertEqual(agent.pending_count(), 0)
        self.send(self.down_url)
        self.assertEqual(agent.pending_count(), 1)


class SelfTestTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(dir=TMP)
        self.saved = (agent.CONFIG_PATH, agent.LOCAL_CONFIG_PATH)
        agent.CONFIG_PATH = os.path.join(self.dir, 'agent_config.json')
        agent.LOCAL_CONFIG_PATH = os.path.join(self.dir, 'agent_config.local.json')
        with open(agent.CONFIG_PATH, 'w', encoding='utf-8') as f:
            json.dump({'secret': 'SET-IN-agent_config.local.json', 'port': 5555}, f)

    def tearDown(self):
        agent.CONFIG_PATH, agent.LOCAL_CONFIG_PATH = self.saved

    def run_self_test(self, local):
        if local is not None:
            with open(agent.LOCAL_CONFIG_PATH, 'w', encoding='utf-8-sig') as f:   # BOM, as PowerShell may write
                json.dump(local, f)
        report_path = os.path.join(self.dir, 'report.json')
        code = agent.self_test(report_path)
        with open(report_path, encoding='utf-8') as f:
            return code, json.load(f)

    def test_valid_config_and_reachable_server(self):
        server = FakeServer()
        try:
            code, report = self.run_self_test({'secret': 'a-real-secret-value', 'server_url': server.url + '/'})
        finally:
            server.stop()
        self.assertEqual(code, 0)
        self.assertTrue(report['config_ok'])
        self.assertTrue(report['server_reachable'])
        self.assertEqual(report['server_url'], server.url)

    def test_unreachable_server_is_reported_but_not_a_failure(self):
        code, report = self.run_self_test({'secret': 'a-real-secret-value', 'server_url': f'http://127.0.0.1:{free_port()}'})
        self.assertEqual(code, 0)
        self.assertFalse(report['server_reachable'])
        self.assertIn('unreachable', report['server_detail'])

    def test_placeholder_or_missing_secret_fails(self):
        code, report = self.run_self_test(None)
        self.assertEqual(code, 1)
        self.assertIn('secret', report['config_error'])

    def test_bad_server_address_fails(self):
        code, report = self.run_self_test({'secret': 'a-real-secret-value', 'server_url': '192.168.1.10:8000'})
        self.assertEqual(code, 1)
        self.assertIn('http://', report['config_error'])


class RetrierTests(unittest.TestCase):
    """Runs last: the retry thread lives until the test process ends."""

    def test_reconnect_signal_flushes_without_waiting_for_backoff(self):
        agent._save_pending([])
        down_port = free_port()
        agent.send_callback_reliably(f'http://127.0.0.1:{down_port}', 's', '/x/', {'reason': 'r'}, timeout=2, block=True)
        self.assertEqual(agent.pending_count(), 1)
        agent.start_pending_callback_retrier(f'http://127.0.0.1:{down_port}')
        time.sleep(0.5)
        server = FakeServer(port=down_port)   # the server comes back on the same address
        try:
            agent._flush_now.set()            # what the network check does when it sees the server again
            deadline = time.time() + 10
            while agent.pending_count() and time.time() < deadline:
                time.sleep(0.2)
            self.assertEqual(agent.pending_count(), 0)
            self.assertEqual(len(server.received), 1)
        finally:
            server.stop()


if __name__ == '__main__':
    unittest.main()
