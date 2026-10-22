"""Background work and agent-event handling (no network: probes are patched)."""
import datetime
import json
from unittest import mock

from django.core import mail
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone

from labs import agent_events
from labs.models import AgentEventReceipt, Lab, PC

SECRET = 'system-test-secret'


def no_network():
    """Patch the connectivity probes so tests never touch the network."""
    return mock.patch.multiple(
        'system.connectivity',
        probe_internet=mock.Mock(return_value=(True, '')),
        probe_smtp=mock.Mock(return_value=(None, 'Not configured')),
        probe_cloud=mock.Mock(return_value=(None, 'Not configured')),
    )


@override_settings(PC_AGENT_SHARED_SECRET=SECRET)
class AgentEventTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        lab = Lab.objects.create(name='Lab', opening_time=datetime.time(0), closing_time=datetime.time(23, 59))
        cls.pc = PC.objects.create(lab=lab, pc_id='EV-01', ip_address='10.9.9.9', status='in_use',
                                   current_guest_name='Guest', last_active=timezone.now() - datetime.timedelta(hours=1))

    def post(self, event_id, ago=0, path='pc_agent_end_session_api'):
        body = {'secret': SECRET, 'reason': 'manual', 'event_id': event_id, 'queued_seconds_ago': ago,
                'agent_version': '9.9.9', 'pending_events': 2}
        return self.client.post(reverse(path), json.dumps(body), content_type='application/json',
                                REMOTE_ADDR='10.9.9.9').json()

    def test_event_is_acknowledged_and_applied_once(self):
        first = self.post('evt-1')
        self.assertEqual(first, {'ok': True, 'ack': 'evt-1'})
        self.pc.refresh_from_db()
        self.assertEqual(self.pc.status, 'online')
        self.assertEqual(self.pc.agent_pending_events, 2)
        self.assertEqual(self.pc.agent_version, '9.9.9')
        self.assertIsNotNone(self.pc.agent_last_contact_at)
        # A newer session starts; the same event arrives again (lost reply).
        PC.objects.filter(pk=self.pc.pk).update(status='in_use', current_guest_name='Next')
        again = self.post('evt-1')
        self.assertEqual(again['ack'], 'evt-1')
        self.assertTrue(again['duplicate'])
        self.pc.refresh_from_db()
        self.assertEqual(self.pc.status, 'in_use', 'a repeat must not end the newer session')
        self.assertEqual(AgentEventReceipt.objects.filter(event_id='evt-1').count(), 1)

    def test_late_event_is_acknowledged_but_ignored(self):
        PC.objects.filter(pk=self.pc.pk).update(last_active=timezone.now())
        reply = self.post('evt-late', ago=300)
        self.assertEqual(reply['ack'], 'evt-late')
        self.assertIn('in use again', reply['ignored'])
        self.pc.refresh_from_db()
        self.assertEqual(self.pc.status, 'in_use')

    def test_failed_apply_leaves_no_receipt_so_the_retry_is_applied(self):
        def boom(pc):
            raise RuntimeError('database hiccup')
        with self.assertRaises(RuntimeError):
            agent_events.process(self.pc, 'end_session', {'event_id': 'evt-retry'}, boom)
        self.assertFalse(AgentEventReceipt.objects.filter(event_id='evt-retry').exists())
        reply = self.post('evt-retry')
        self.assertEqual(reply, {'ok': True, 'ack': 'evt-retry'})
        self.pc.refresh_from_db()
        self.assertEqual(self.pc.status, 'online')

    def test_old_receipts_are_pruned(self):
        receipt = AgentEventReceipt.objects.create(event_id='old', pc=self.pc, kind='logout')
        AgentEventReceipt.objects.filter(pk=receipt.pk).update(received_at=timezone.now() - datetime.timedelta(days=8))
        AgentEventReceipt.objects.create(event_id='new', pc=self.pc, kind='logout')
        agent_events.prune_receipts()
        self.assertEqual(list(AgentEventReceipt.objects.values_list('event_id', flat=True)), ['new'])


@override_settings(EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend')
class CronCycleTests(TestCase):
    def test_one_cycle_sends_queued_email_and_records_a_heartbeat(self):
        from notifications import outbox
        from system import connectivity
        from system.models import SystemStatus
        from system.worker import run_once
        for i in range(5):
            outbox.queue(f'cron.check{i}@gmail.com', 'Cron check', 'body')
        with no_network():
            run_once(mode='cron')
        self.assertEqual(len(mail.outbox), 5)
        worker = SystemStatus.objects.get(key='worker')
        self.assertTrue(worker.ok)
        self.assertIn('cron', worker.detail)
        summary = connectivity.get_summary(use_cache=False)
        self.assertTrue(summary['worker_alive'])
        self.assertEqual(summary['headline'], 'Local system operational; cloud synchronization not configured.')

    def test_management_command_once_exits(self):
        from django.core.management import call_command
        with no_network():
            call_command('run_worker', '--once')
        from system.models import SystemStatus
        self.assertTrue(SystemStatus.objects.filter(key='worker', ok=True).exists())

    def test_internet_outage_is_reported_separately_from_the_local_system(self):
        from system import connectivity
        with no_network(), mock.patch('system.connectivity.probe_internet', return_value=(False, 'timeout')):
            connectivity.run_probes()
            connectivity.heartbeat('test')
        s = connectivity.get_summary(use_cache=False)
        self.assertTrue(s['database']['ok'])
        self.assertFalse(s['internet']['ok'])
        self.assertEqual(s['headline'], 'Local system operational; internet unavailable.')
        with no_network():
            self.assertIn('internet', connectivity.run_probes(), 'coming back is reported so queues resume')


class HealthEndpointTests(TestCase):
    def test_healthz_is_public_and_ready_is_local_only(self):
        self.assertEqual(self.client.get('/healthz').content, b'ok')
        with no_network():
            self.assertEqual(self.client.get('/healthz/ready', REMOTE_ADDR='127.0.0.1').status_code, 200)
            self.assertEqual(self.client.get('/healthz/ready', REMOTE_ADDR='10.1.1.1').status_code, 403)
            # Through a local proxy (tailscale serve) the request comes from elsewhere.
            self.assertEqual(self.client.get('/healthz/ready', REMOTE_ADDR='127.0.0.1',
                                             HTTP_X_FORWARDED_FOR='100.101.1.2').status_code, 403)
