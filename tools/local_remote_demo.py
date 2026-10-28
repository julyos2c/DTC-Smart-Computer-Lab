"""Start an isolated cloud, edge and simulated PC agent. Ctrl+C stops them.

python tools/local_remote_demo.py
python tools/local_remote_demo.py --smoke-test

No Windows lock, shutdown or restart is performed by the simulated agent.
"""
import argparse
from datetime import timedelta
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]


def configure():
    os.chdir(ROOT)
    sys.path.insert(0, str(ROOT))
    os.environ['DJANGO_SETTINGS_MODULE'] = 'compulab.local_demo_settings'
    # base settings are imported first; prevent .env production checks/backgrounds.
    os.environ['DJANGO_SECRET_KEY'] = os.environ['COMPULAB_DEMO_SECRET']
    os.environ['COMPULAB_BACKGROUND_TASKS'] = 'False'
    os.environ['DJANGO_DEBUG'] = 'True'
    os.environ['PC_AGENT_SHARED_SECRET'] = os.environ['COMPULAB_DEMO_AGENT_KEY']


def seed(role):
    configure()
    import django
    django.setup()
    from django.core.management import call_command
    from accounts.models import User
    from cloud_receiver.models import RemoteCommand, CommandReceipt, ReservationChange
    call_command('migrate', interactive=False, verbosity=0)
    user, _ = User.objects.get_or_create(email='localdemo@gmail.com')
    user.is_active = user.is_staff = user.is_superuser = user.email_verified = True
    user.role, user.approval_status = 'admin', 'approved'
    user.set_password(os.environ['COMPULAB_DEMO_PASSWORD'])
    user.save()
    # Cancel prior pending demo commands before rotating the demo's agent key.
    RemoteCommand.objects.filter(status='pending').update(status='expired', detail='Previous demo run ended.')
    ReservationChange.objects.filter(status='pending').update(status='expired', result={'detail': 'Previous demo run ended.'})
    if role == 'edge':
        from labs.models import Lab, PC
        lab, _ = Lab.objects.get_or_create(name='Local demo lab')
        pc, _ = PC.objects.get_or_create(lab=lab, pc_id='DEMO-PC', defaults={'ip_address': '127.0.0.1'})
        pc.ip_address, pc.agent_secret, pc.agent_secret_in_use = '127.0.0.1', os.environ['COMPULAB_DEMO_AGENT_KEY'], True
        pc.save()
        (ROOT / '.local_remote_demo' / 'pc.json').write_text(json.dumps({'pc_pk': pc.pk}))
        student, _ = User.objects.get_or_create(id_number='DEMO-STUDENT', defaults={'role': 'student', 'first_name': 'Demo', 'last_name': 'Student', 'email': None})
        student.is_active = True
        student.save()
        print('Demo PC database ID:', pc.pk)
        print('Reservation test: lab ID =', lab.pk, '; requester type = student; ID = DEMO-STUDENT')


def worker():
    configure()
    import django
    django.setup()
    from django.db import connections
    from cloud_sync.remote_control import run_once
    from cloud_sync import reservations, sync
    while True:
        try:
            run_once()
            reservations.run_once()
            sync.run_once()
        finally:
            connections.close_all()
        time.sleep(1)


def smoke():
    configure()
    import django
    django.setup()
    from cloud_receiver.models import RemoteCommand
    command = RemoteCommand.objects.create(site_id='local-demo', pc_pk=json.loads((ROOT / '.local_remote_demo' / 'pc.json').read_text())['pc_pk'], action='lock', requested_by='Local smoke test')
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        command.refresh_from_db()
        if command.status != 'pending':
            if command.status != 'accepted':
                raise RuntimeError('Smoke test failed: ' + command.status + ': ' + command.detail)
            print('PASS: real HTTP cloud queue -> edge worker -> simulated agent -> cloud accepted result', flush=True)
            return
        time.sleep(0.25)
    raise RuntimeError('Smoke test timed out')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', choices=['cloud', 'edge'], help=argparse.SUPPRESS)
    parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--verify', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--smoke-test', action='store_true')
    args = parser.parse_args()
    if args.seed:
        seed(args.seed)
        return
    if args.worker:
        worker()
        return
    if args.verify:
        smoke()
        return
    if not (3, 11) <= sys.version_info[:2] <= (3, 13):
        raise SystemExit('Use Python 3.11-3.13 with this project Django 5.0 installation.')
    # Fail before starting if another app already owns a demo port.
    for port in (8000, 8001, 5556):
        with socket.socket() as sock:
            try:
                sock.bind(('127.0.0.1', port))
            except OSError:
                raise SystemExit(f'Port {port} is busy. Stop its existing local process first.')
    env = dict(os.environ)
    for name in ('SECRET', 'KEY', 'AGENT_KEY', 'PASSWORD'):
        env['COMPULAB_DEMO_' + name] = secrets.token_urlsafe(24)
    env['DJANGO_SECRET_KEY'] = env['COMPULAB_DEMO_SECRET']
    env['COMPULAB_BACKGROUND_TASKS'] = 'False'
    env['DJANGO_DEBUG'] = 'True'
    env['PC_AGENT_SHARED_SECRET'] = env['COMPULAB_DEMO_AGENT_KEY']
    env['DJANGO_SETTINGS_MODULE'] = 'compulab.local_demo_settings'
    env['PYTHONUNBUFFERED'] = '1'
    demo_dir = ROOT / '.local_remote_demo'
    demo_dir.mkdir(exist_ok=True)
    processes, streams = [], []
    server = None
    def role_env(role):
        return dict(env, COMPULAB_DEMO_ROLE=role)
    def launch(arguments, role, label):
        stream = (demo_dir / (label + '.log')).open('w', encoding='utf-8')
        streams.append(stream)
        proc = subprocess.Popen([sys.executable] + arguments, cwd=ROOT, env=role_env(role),
                                stdout=stream, stderr=subprocess.STDOUT)
        processes.append(proc)
        return proc
    try:
        for role in ('cloud', 'edge'):
            subprocess.run([sys.executable, str(Path(__file__).resolve()), '--seed', role],
                           cwd=ROOT, env=role_env(role), check=True)
        class Agent(BaseHTTPRequestHandler):
            def do_POST(self):
                try:
                    data = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
                except (ValueError, TypeError):
                    self.send_error(400)
                    return
                if not secrets.compare_digest(str(data.get('secret', '')), env['COMPULAB_DEMO_AGENT_KEY']):
                    self.send_error(403)
                    return
                if self.path not in ('/lock', '/unlock', '/shutdown', '/restart'):
                    self.send_error(404)
                    return
                print(f'[SIMULATED AGENT] {self.path[1:].upper()} received; no Windows action performed.', flush=True)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"ok":true,"simulated":true}')
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 5556), Agent)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        for role, port in [('cloud', 8001), ('edge', 8000)]:
            launch(['manage.py', 'runserver', f'127.0.0.1:{port}', '--noreload'], role, role)
        deadline = time.monotonic() + 30
        for port in (8001, 8000):
            while True:
                if any(p.poll() is not None for p in processes):
                    raise RuntimeError('A server exited. See .local_remote_demo logs.')
                try:
                    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(
                            f'http://127.0.0.1:{port}/healthz', timeout=1):
                        break
                except OSError:
                    if time.monotonic() > deadline:
                        raise RuntimeError('Server startup timeout. See .local_remote_demo logs.')
                    time.sleep(0.25)
        launch([str(Path(__file__).resolve()), '--worker'], 'edge', 'worker')
        print('\nCloud admin: http://127.0.0.1:8001/admin/cloud_receiver/remotecommand/', flush=True)
        print('Edge admin:  http://127.0.0.1:8000/admin/', flush=True)
        print('Cloud reservations: http://127.0.0.1:8001/admin/cloud_receiver/reservationchange/', flush=True)
        print('Email: localdemo@gmail.com\nPassword: ' + env['COMPULAB_DEMO_PASSWORD'], flush=True)
        pc_pk = json.loads((demo_dir / 'pc.json').read_text())['pc_pk']
        print(f'Add command: site_id=local-demo, pc_pk={pc_pk}, action=lock. Save then refresh the command.', flush=True)
        print('Agent is simulated. No real lock/restart/shutdown. Ctrl+C stops all demo processes.', flush=True)
        if args.smoke_test:
            subprocess.run([sys.executable, str(Path(__file__).resolve()), '--verify'],
                           cwd=ROOT, env=role_env('cloud'), check=True)
            return
        while True:
            if any(p.poll() is not None for p in processes):
                raise RuntimeError('A demo process stopped. See .local_remote_demo logs.')
            time.sleep(0.5)
    except KeyboardInterrupt:
        print('\nStopping local demo...')
    finally:
        for proc in processes:
            if proc.poll() is None:
                proc.terminate()
        for proc in processes:
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        if server:
            server.shutdown()
            server.server_close()
        for stream in streams:
            stream.close()


if __name__ == '__main__':
    main()
