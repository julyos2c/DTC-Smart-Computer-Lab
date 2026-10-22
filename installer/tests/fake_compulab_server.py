"""A stand-in for the CompuLab server, for the agent installer tests.

    python fake_compulab_server.py <port> <events.jsonl>

Answers GET /healthz with "ok" and acknowledges every POSTed agent event
({"ok": true, "ack": <event_id>}), appending each one to the .jsonl file.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
LOG = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200 if self.path.startswith('/healthz') else 404)
        self.end_headers()
        self.wfile.write(b'ok')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        body.pop('secret', None)
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(json.dumps({'path': self.path, 'body': body}) + '\n')
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps({'ok': True, 'ack': body.get('event_id')}).encode())


ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
