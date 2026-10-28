"""Remote control regression tests; all agent calls are mocked."""
import json
import uuid
from datetime import timedelta
from unittest.mock import patch
from django.test import TestCase, override_settings, Client
from django.utils import timezone
from accounts.models import User
from cloud_receiver.receiver import key_hash
from cloud_receiver.models import RemoteCommand, CommandReceipt
from cloud_sync.remote_control import execute, run_once
from labs.models import Lab, PC


@override_settings(CLOUD_RECEIVER_ENABLED=True, CLOUD_REMOTE_CONTROL_ENABLED=True,
                   CLOUD_RECEIVER_ALLOW_HTTP=False, CLOUD_RECEIVER_SITES={'campus': key_hash('test-key')},
                   CLOUD_SYNC_SITE_ID='campus', CLOUD_SYNC_API_KEY='test-key',
                   CLOUD_SERVER_URL='https://cloud.example', EDGE_REMOTE_CONTROL_ENABLED=True)
class RemoteControlTests(TestCase):
    def setUp(self):
        self.lab = Lab.objects.create(name='Lab')
        self.pc = PC.objects.create(lab=self.lab, pc_id='PC-01', ip_address='192.168.1.20')
        self.command = RemoteCommand.objects.create(site_id='campus', pc_pk=self.pc.pk,
                                                    action='lock', requested_by='Admin')

    def post(self, body=None, site='campus', key='test-key', secure=True):
        return self.client.post('/api/commands/', json.dumps(body or {}), content_type='application/json',
                                HTTP_AUTHORIZATION='Bearer ' + key, HTTP_X_COMPULAB_SITE=site, secure=secure)

    def item(self, **extra):
        result = dict(id=str(self.command.pk), site_id='campus', pc_pk=self.pc.pk,
                      action='lock', expires_at=self.command.expires_at.isoformat())
        result.update(extra)
        return result

    def test_poll_authentication_tls_and_site_isolation(self):
        self.assertEqual(self.post(key='wrong').status_code, 401)
        self.assertEqual(self.post(site='other').status_code, 401)
        self.assertEqual(self.post(secure=False).status_code, 403)
        RemoteCommand.objects.create(site_id='other', pc_pk=1, action='restart')
        self.assertEqual(len(self.post().json()['commands']), 1)

    def test_disabled(self):
        with override_settings(CLOUD_REMOTE_CONTROL_ENABLED=False):
            self.assertEqual(self.post().status_code, 404)

    def test_invalid_body_and_methods(self):
        self.assertEqual(self.post({'results': 'bad'}).status_code, 400)
        self.assertEqual(self.post({'results': [{'id': 'bad', 'status': 'accepted'}]}).status_code, 400)
        self.assertEqual(self.client.get('/api/commands/').status_code, 405)
        self.assertEqual(self.client.post('/api/commands/', '[]', content_type='application/json', secure=True,
                         HTTP_AUTHORIZATION='Bearer test-key', HTTP_X_COMPULAB_SITE='campus').status_code, 400)

    def test_expired_never_delivered(self):
        RemoteCommand.objects.filter(pk=self.command.pk).update(expires_at=timezone.now()-timedelta(seconds=1))
        self.assertEqual(self.post().json()['commands'], [])
        self.command.refresh_from_db()
        self.assertEqual(self.command.status, 'expired')

    @patch('labs.network.lock_pc', return_value=(True, 'ok'))
    def test_duplicate_delivery_calls_agent_once(self, send):
        execute(self.item())
        execute(self.item())
        send.assert_called_once()
        self.assertEqual(CommandReceipt.objects.get().status, 'accepted')

    @patch('labs.network.restart_pc', return_value=(False, 'timeout'))
    def test_uncertain_agent_result_not_replayed(self, send):
        item = self.item(action='restart')
        execute(item)
        execute(item)
        send.assert_called_once()
        self.assertEqual(CommandReceipt.objects.get().status, 'unknown')

    @patch('labs.network.lock_pc')
    def test_expiry_rechecked_on_edge(self, send):
        execute(self.item(expires_at=(timezone.now()-timedelta(seconds=1)).isoformat()))
        send.assert_not_called()
        self.assertEqual(CommandReceipt.objects.get().status, 'expired')

    @patch('labs.network.unlock_pc')
    def test_unlock_requires_local_session(self, send):
        execute(self.item(action='unlock'))
        send.assert_not_called()
        self.assertEqual(CommandReceipt.objects.get().status, 'failed')

    @patch('labs.network.unlock_pc', return_value=(True, 'ok'))
    def test_unlock_existing_valid_session(self, send):
        from scheduling.models import Session
        now = timezone.localtime()
        session = Session.objects.create(lab=self.lab, subject='Test', date=now.date(),
                                        start_time=(now-timedelta(minutes=1)).time(),
                                        end_time=(now+timedelta(minutes=1)).time())
        self.pc.current_session = session
        self.pc.current_guest_name = 'Guest'
        self.pc.status = 'in_use'
        self.pc.save()
        execute(self.item(action='unlock'))
        send.assert_called_once()

    @patch('labs.network.lock_pc')
    def test_wrong_site_unknown_action_invalid_pc(self, send):
        for extra in ({'site_id': 'other'}, {'action': 'shell'}, {'pc_pk': True}):
            execute(self.item(**extra))
        send.assert_not_called()
        self.assertEqual(CommandReceipt.objects.count(), 0)

    def test_result_retries_are_idempotent_and_scoped(self):
        body = {'results': [{'id': str(self.command.pk), 'status': 'accepted', 'detail': 'Signal accepted'}]}
        self.assertEqual(self.post(body).json()['acknowledged'], [str(self.command.pk)])
        self.assertEqual(self.post(body).json()['acknowledged'], [str(self.command.pk)])
        self.command.refresh_from_db()
        self.assertEqual(self.command.status, 'accepted')
        other = RemoteCommand.objects.create(site_id='other', pc_pk=1, action='lock')
        body['results'][0]['id'] = str(other.pk)
        self.assertEqual(self.post(body).json()['acknowledged'], [])
        other.refresh_from_db()
        self.assertEqual(other.status, 'pending')

    def test_admin_access_and_immutable_commands(self):
        user = User.objects.create(email='admin@example.com', role='admin', is_staff=True, is_active=True, email_verified=True, approval_status='approved')
        self.client.force_login(user)
        self.assertEqual(self.client.get('/admin/cloud_receiver/remotecommand/add/', secure=True).status_code, 200)
        self.assertEqual(self.client.post(f'/admin/cloud_receiver/remotecommand/{self.command.pk}/change/',
                                        {'action': 'restart'}, secure=True).status_code, 403)
        user.role = 'incharge'
        user.save()
        self.assertEqual(self.client.get('/admin/cloud_receiver/remotecommand/add/', secure=True).status_code, 403)

    def test_admin_csrf_and_submission(self):
        user = User.objects.create(email='admin@example.com', role='admin', is_staff=True, is_active=True, email_verified=True, approval_status='approved')
        strict = Client(enforce_csrf_checks=True)
        strict.force_login(user)
        self.assertEqual(strict.post('/admin/cloud_receiver/remotecommand/add/', {}, secure=True).status_code, 403)
        self.client.force_login(user)
        expiry = timezone.localtime(timezone.now()+timedelta(minutes=2))
        response = self.client.post('/admin/cloud_receiver/remotecommand/add/', {
            'site_id': 'campus', 'pc_pk': self.pc.pk, 'action': 'restart',
            'expires_at_0': expiry.strftime('%Y-%m-%d'), 'expires_at_1': expiry.strftime('%H:%M:%S'), '_save': 'Save'}, secure=True)
        self.assertEqual(response.status_code, 302)
        self.assertEqual(RemoteCommand.objects.filter(action='restart', requested_by=user.email).count(), 1)

    @patch('urllib.request.build_opener')
    def test_offline_does_not_lose_receipts(self, opener):
        CommandReceipt.objects.create(id=self.command.pk, site_id='campus', pc_pk=self.pc.pk,
                                      action='lock', status='accepted')
        opener.return_value.open.side_effect = OSError('offline')
        run_once()
        self.assertFalse(CommandReceipt.objects.get().reported)

    @patch('urllib.request.build_opener')
    def test_crash_receipt_is_reported_unknown_without_reexecution(self, opener):
        CommandReceipt.objects.create(id=self.command.pk, site_id='campus', pc_pk=self.pc.pk, action='lock')
        CommandReceipt.objects.update(created_at=timezone.now()-timedelta(minutes=3))
        opener.return_value.open.side_effect = OSError('offline')
        with patch('labs.network.lock_pc') as send:
            run_once()
            execute(self.item())
            send.assert_not_called()
        self.assertEqual(CommandReceipt.objects.get().status, 'unknown')

    @patch('labs.network.lock_pc', return_value=(True, 'ok'))
    @patch('urllib.request.build_opener')
    def test_end_to_end_edge_poll_execute_and_report(self, opener, send):
        def transport(request, **kwargs):
            response = self.post(json.loads(request.data))
            class Reply:
                def __enter__(self): return self
                def __exit__(self, *args): pass
                def read(self, limit): return response.content
            return Reply()
        opener.return_value.open.side_effect = transport
        run_once()
        self.assertFalse(CommandReceipt.objects.get().reported)
        run_once()
        send.assert_called_once()
        self.assertTrue(CommandReceipt.objects.get().reported)
        self.command.refresh_from_db()
        self.assertEqual(self.command.status, 'accepted')

    @patch('urllib.request.build_opener')
    def test_edge_disabled_and_plain_http_never_connect(self, opener):
        with override_settings(EDGE_REMOTE_CONTROL_ENABLED=False): run_once()
        with override_settings(CLOUD_SERVER_URL='http://cloud.example'): run_once()
        opener.assert_not_called()

    def test_form_rejects_unknown_site_and_stale_expiry(self):
        from cloud_receiver.admin import RemoteCommandForm
        for site, expiry in [('other', timezone.now()+timedelta(minutes=1)),
                             ('campus', timezone.now()-timedelta(seconds=1)),
                             ('campus', timezone.now()+timedelta(minutes=10))]:
            form = RemoteCommandForm(data={'site_id': site, 'pc_pk': self.pc.pk,
                                          'action': 'lock', 'expires_at': expiry})
            self.assertFalse(form.is_valid())

    @patch('urllib.request.build_opener')
    def test_redirects_are_refused_and_inflight_receipts_not_reported(self, opener):
        CommandReceipt.objects.create(id=self.command.pk, site_id='campus', pc_pk=self.pc.pk, action='lock')
        opener.return_value.open.return_value.__enter__.return_value.read.return_value = b'{"commands":[],"acknowledged":[]}'
        run_once()
        request = opener.return_value.open.call_args.args[0]
        self.assertEqual(json.loads(request.data)['results'], [])
        handler = opener.call_args.args[0]
        self.assertIsNone(handler().redirect_request(None, None, 302, '', {}, 'https://other.example'))


    @patch('urllib.request.build_opener')
    @override_settings(EDGE_REMOTE_CONTROL_ALLOW_LOCAL_HTTP=True)
    def test_http_opt_in_accepts_only_loopback_hosts(self, opener):
        opener.return_value.open.return_value.__enter__.return_value.read.return_value = b'{"commands":[],"acknowledged":[]}'
        for host in ('127.0.0.1', 'localhost', '[::1]'):
            with override_settings(CLOUD_SERVER_URL='http://' + host + ':8001'):
                run_once()
        self.assertEqual(opener.call_count, 3)
        opener.reset_mock()
        for url in ('http://192.168.1.20:8001', 'http://cloud.example', 'http://user:pass@localhost:8001',
                    'http://localhost.example:8001'):
            with override_settings(CLOUD_SERVER_URL=url):
                run_once()
        opener.assert_not_called()

    @patch('urllib.request.build_opener')
    @override_settings(EDGE_REMOTE_CONTROL_ALLOW_LOCAL_HTTP=False, CLOUD_SERVER_URL='http://127.0.0.1:8001')
    def test_loopback_http_still_requires_explicit_opt_in(self, opener):
        run_once()
        opener.assert_not_called()
