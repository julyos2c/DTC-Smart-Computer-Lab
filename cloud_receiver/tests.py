"""The cloud receiver, and the whole sync path campus -> cloud.

The end-to-end tests run the real sender (cloud_sync.sync.run_once) against
the real receiver view in one process: the sender's HTTP request is routed
into the Django test client instead of the network. "Offline" means that
route raises the same error urllib raises when the network is down."""
import datetime
import io
import json
import types
import urllib.error
import urllib.parse
import uuid
from unittest import mock

from django.contrib.admin.sites import AdminSite
from django.contrib.auth import get_user_model
from django.test import RequestFactory, TestCase, override_settings
from django.utils import timezone

from cloud_receiver import receiver
from cloud_receiver.admin import ReplicaRecordAdmin
from cloud_receiver.models import AppliedChange, ReplicaRecord
from cloud_sync import sync, sync_payloads
from cloud_sync.models import SyncQueue, SyncState, enqueue

KEY = 'campus-key-for-tests-0123456789abcdefghij'
SITE = 'dtc-test'
RECEIVER = dict(CLOUD_RECEIVER_ENABLED=True, CLOUD_RECEIVER_SITES={SITE: receiver.key_hash(KEY)},
                CLOUD_RECEIVER_ALLOW_HTTP=False, CLOUD_RECEIVER_MAX_RECORDS=500)
SENDER = dict(CLOUD_SERVER_URL='https://cloud.example.test', CLOUD_SYNC_API_KEY=KEY, CLOUD_SYNC_ENABLED=True,
              CLOUD_SYNC_SITE_ID=SITE, CLOUD_SYNC_OBJECT_TYPES=('reservation', 'session', 'issue'))


def make_record(seq=1, local_id=7, op='upsert', payload=None, edge=None, schema=1, object_type='session', force=False):
    return {
        'edge_id': str(edge or uuid.uuid4()), 'object_type': object_type, 'local_id': local_id,
        'record_key': f'{object_type}:{local_id}', 'operation': op, 'schema_version': schema, 'sequence': seq,
        'force': force, 'payload': {'subject': 'Math'} if payload is None else payload,
        'created_at': '2026-10-23T01:00:00+00:00',
    }


@override_settings(**RECEIVER)
class ReceiverTests(TestCase):
    def post(self, records, key=KEY, site=SITE, secure=True, body_site=None, protocol=2):
        body = {'protocol': protocol, 'site_id': site if body_site is None else body_site, 'sent_at': '', 'records': records}
        return self.client.post('/api/sync/', data=json.dumps(body), content_type='application/json', secure=secure,
                                HTTP_AUTHORIZATION=f'Bearer {key}', HTTP_X_COMPULAB_SITE=site)

    @override_settings(CLOUD_RECEIVER_ENABLED=False)
    def test_off_by_default_answers_404_like_no_receiver(self):
        self.assertEqual(self.client.get('/api/ping/').status_code, 404)
        self.assertEqual(self.post([make_record()]).status_code, 404)

    def test_ping(self):
        r = self.client.get('/api/ping/', secure=True)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()['protocol'], 2)

    def test_authentication(self):
        self.assertEqual(self.post([make_record()], key='').status_code, 401)
        self.assertEqual(self.post([make_record()], key='wrong-key').status_code, 401)
        self.assertEqual(self.post([make_record()], site='other-campus').status_code, 401)
        r = self.post([make_record()])
        self.assertEqual(r.status_code, 200)
        self.assertNotIn(KEY, r.content.decode())

    def test_https_required(self):
        self.assertEqual(self.post([make_record()], secure=False).status_code, 403)
        self.assertEqual(ReplicaRecord.objects.count(), 0)

    def test_batch_level_errors(self):
        self.assertEqual(self.post([make_record()], body_site='someone-else').status_code, 400)
        self.assertEqual(self.post([make_record()], protocol=1).status_code, 400)
        with self.settings(CLOUD_RECEIVER_MAX_RECORDS=2):
            self.assertEqual(self.post([make_record(local_id=i) for i in (1, 2, 3)]).status_code, 413)
        self.assertEqual(ReplicaRecord.objects.count(), 0)

    def test_accept_then_duplicate_edge_changes_nothing(self):
        rec = make_record(seq=5, payload={'subject': 'Math'})
        self.assertEqual(self.post([rec]).json()['results'][rec['edge_id']]['status'], 'accepted')
        again = dict(rec, payload={'subject': 'changed in transit?'})
        body = self.post([again]).json()
        self.assertEqual(body['results'][rec['edge_id']]['status'], 'duplicate')
        self.assertIn(rec['edge_id'], body['accepted_edge_ids'])
        self.assertEqual(AppliedChange.objects.count(), 1)
        self.assertEqual(ReplicaRecord.objects.get().payload, {'subject': 'Math'})

    def test_late_older_change_is_a_duplicate(self):
        self.post([make_record(seq=10, payload={'v': 10})])
        old = make_record(seq=3, payload={'v': 3})
        self.assertEqual(self.post([old]).json()['results'][old['edge_id']]['status'], 'duplicate')
        self.assertEqual(ReplicaRecord.objects.get().payload, {'v': 10})

    def test_delete_keeps_a_tombstone(self):
        self.post([make_record(seq=1)])
        self.post([make_record(seq=2, op='delete', payload={'deleted': True})])
        r = ReplicaRecord.objects.get()
        self.assertTrue(r.deleted)
        self.assertEqual(r.payload, {})
        self.assertEqual(r.last_sequence, 2)

    def test_invalid_records_are_rejected_not_stored_and_can_be_sent_again(self):
        bad = [make_record(schema=99), make_record(object_type='grade'), make_record(payload=['x']),
               make_record(op='merge'), dict(make_record(), local_id=-1), dict(make_record(), sequence='1')]
        body = self.post(bad).json()
        self.assertTrue(all(body['results'][b['edge_id']]['status'] == 'rejected' for b in bad))
        self.assertEqual(body['accepted_edge_ids'], [])
        self.assertEqual(ReplicaRecord.objects.count() + AppliedChange.objects.count(), 0)
        fixed = dict(bad[0], schema_version=1)
        self.assertEqual(self.post([fixed]).json()['results'][fixed['edge_id']]['status'], 'accepted')

    def test_cloud_edit_conflicts_until_the_campus_server_forces_its_copy(self):
        self.post([make_record(seq=1, payload={'v': 1})])
        ReplicaRecord.objects.update(cloud_modified_at=timezone.now(), cloud_modified_by='cloud-admin')
        change = make_record(seq=2, payload={'v': 2})
        answer = self.post([change]).json()['results'][change['edge_id']]
        self.assertEqual(answer['status'], 'conflict')
        self.assertIn('cloud-admin', answer['detail'])
        self.assertEqual(ReplicaRecord.objects.get().payload, {'v': 1})   # never silently overwritten
        forced = dict(change, force=True)                                  # same edge_id, Admin chose "keep campus copy"
        self.assertEqual(self.post([forced]).json()['results'][change['edge_id']]['status'], 'accepted')
        r = ReplicaRecord.objects.get()
        self.assertEqual(r.payload, {'v': 2})
        self.assertIsNone(r.cloud_modified_at)
        self.assertTrue(AppliedChange.objects.get(edge_id=change['edge_id']).forced)

    def test_mixed_batch_answers_per_record(self):
        good, bad = make_record(local_id=1), make_record(local_id=2, schema=7)
        body = self.post([good, bad]).json()
        self.assertEqual(body['results'][good['edge_id']]['status'], 'accepted')
        self.assertEqual(body['results'][bad['edge_id']]['status'], 'rejected')
        self.assertEqual(body['accepted_edge_ids'], [good['edge_id']])

    def test_editing_a_copy_in_the_admin_marks_it_as_edited_on_the_cloud(self):
        self.post([make_record()])
        user = get_user_model().objects.create_superuser(email='cloud.admin@gmail.com', password='x-Long-Passw0rd-1')
        request = RequestFactory().post('/admin/')
        request.user = user
        obj = ReplicaRecord.objects.get()
        ReplicaRecordAdmin(ReplicaRecord, AdminSite()).save_model(request, obj, form=None, change=True)
        obj.refresh_from_db()
        self.assertIsNotNone(obj.cloud_modified_at)
        self.assertEqual(obj.cloud_modified_by, user.get_username())


class _Response:
    def __init__(self, status, content):
        self.status = status
        self._content = content

    def read(self, n=-1):
        return self._content if n < 0 else self._content[:n]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


@override_settings(**RECEIVER, **SENDER)
class EndToEndSyncTests(TestCase):
    """Campus server (sender) -> cloud receiver, both real."""

    def setUp(self):
        self.mode = 'online'
        self.requests = 0
        patcher = mock.patch('cloud_sync.sync.urllib.request.urlopen', side_effect=self.route)
        patcher.start()
        self.addCleanup(patcher.stop)

    def route(self, req, timeout=None):
        self.requests += 1
        if self.mode == 'offline':
            raise urllib.error.URLError(OSError('Network is unreachable'))
        if self.mode == 'down':
            raise urllib.error.HTTPError(req.full_url, 503, 'Service Unavailable', None, io.BytesIO(b'{"detail": "maintenance"}'))
        path = urllib.parse.urlsplit(req.full_url).path
        response = self.client.generic(
            req.get_method(), path, data=req.data or b'', content_type='application/json', secure=True,
            HTTP_AUTHORIZATION=req.get_header('Authorization', ''), HTTP_X_COMPULAB_SITE=req.get_header('X-compulab-site', ''),
            HTTP_X_COMPULAB_SYNC_PROTOCOL=req.get_header('X-compulab-sync-protocol', ''),
        )
        if self.mode == 'lost-reply':
            # The receiver stored the batch, but the answer never arrived.
            raise urllib.error.URLError(TimeoutError('timed out'))
        if response.status_code >= 400:
            raise urllib.error.HTTPError(req.full_url, response.status_code, 'error', None, io.BytesIO(response.content))
        return _Response(response.status_code, response.content)

    def queue(self, object_type, local_id, **payload):
        return enqueue(object_type, local_id, dict(payload, snapshot_at=timezone.now().isoformat()))

    def test_offline_changes_wait_durably_and_are_sent_when_the_internet_returns(self):
        rows = [self.queue('session', 1, subject='A'), self.queue('reservation', 2, subject='B'), self.queue('issue', 3, title='C')]
        self.mode = 'offline'
        sync.run_once()
        state = SyncState.get()
        self.assertEqual(set(SyncQueue.objects.values_list('status', flat=True)), {'pending'})
        self.assertEqual(sum(SyncQueue.objects.values_list('attempts', flat=True)), 0)   # an outage never fails a change
        self.assertEqual(state.consecutive_failures, 1)
        self.assertIsNotNone(state.next_attempt_at)                                       # backoff, no busy loop
        self.assertIn('unreachable', state.last_error)
        self.assertEqual(ReplicaRecord.objects.count(), 0)
        before = self.requests
        sync.run_once()                                                                  # still backing off: no request
        self.assertEqual(self.requests, before)
        self.mode = 'online'
        sync.resume()                                                                    # connectivity monitor: internet back
        sync.run_once()
        self.assertEqual(set(SyncQueue.objects.values_list('status', flat=True)), {'synced'})
        self.assertEqual(ReplicaRecord.objects.count(), 3)
        self.assertEqual(ReplicaRecord.objects.get(object_type='session').payload['subject'], 'A')
        self.assertEqual(SyncState.get().consecutive_failures, 0)
        self.assertEqual(len(rows), 3)

    def test_a_lost_reply_sends_again_without_a_duplicate(self):
        self.queue('session', 1, subject='A')
        self.queue('session', 2, subject='B')
        self.mode = 'lost-reply'
        sync.run_once()
        self.assertEqual(ReplicaRecord.objects.count(), 2)                               # stored on the cloud...
        self.assertEqual(set(SyncQueue.objects.values_list('status', flat=True)), {'pending'})   # ...not confirmed here
        self.mode = 'online'
        sync.resume()
        sync.run_once()
        self.assertEqual(set(SyncQueue.objects.values_list('status', flat=True)), {'synced'})
        self.assertEqual(AppliedChange.objects.count(), 2)                               # applied once each
        self.assertEqual(ReplicaRecord.objects.count(), 2)

    def test_transient_server_error_backs_off_then_recovers(self):
        self.queue('issue', 9, title='Broken PC')
        self.mode = 'down'
        sync.run_once()
        row = SyncQueue.objects.get()
        self.assertEqual((row.status, row.attempts), ('pending', 0))
        self.assertIn('503', SyncState.get().last_error)
        self.mode = 'online'
        sync.resume()
        sync.run_once()
        self.assertEqual(SyncQueue.objects.get().status, 'synced')

    def test_wrong_api_key_pauses_instead_of_retrying_forever(self):
        self.queue('session', 1, subject='A')
        with self.settings(CLOUD_SYNC_API_KEY='not-the-key'):
            sync.run_once()
            self.assertEqual(SyncState.get().paused_reason, 'auth')
            requests = self.requests
            sync.resume()
            sync.run_once()
            self.assertEqual(self.requests, requests)                                    # paused: nothing sent
        sync.run_once()                                                                  # key fixed: pause lifted
        self.assertEqual(SyncQueue.objects.get().status, 'synced')
        self.assertEqual(SyncState.get().paused_reason, '')

    def test_receiver_switched_off_pauses_as_incompatible(self):
        self.queue('session', 1, subject='A')
        with self.settings(CLOUD_RECEIVER_ENABLED=False):
            sync.run_once()
        self.assertEqual(SyncState.get().paused_reason, 'incompatible')
        self.assertEqual(SyncQueue.objects.get().status, 'pending')

    def test_conflict_waits_for_an_admin_and_never_overwrites_silently(self):
        self.queue('session', 4, subject='v1')
        sync.run_once()
        ReplicaRecord.objects.update(cloud_modified_at=timezone.now(), cloud_modified_by='cloud-admin')
        self.queue('session', 4, subject='v2')
        sync.run_once()
        row = SyncQueue.objects.order_by('-id').first()
        self.assertEqual(row.status, 'conflict')
        self.assertIn('cloud-admin', row.last_error)
        self.assertEqual(ReplicaRecord.objects.get().payload['subject'], 'v1')
        admin = get_user_model().objects.create_superuser(email='campus.admin@gmail.com', password='x-Long-Passw0rd-1')
        sync.resolve_conflict(row, 'local', admin)                                       # "Keep campus copy"
        sync.run_once()
        row.refresh_from_db()
        self.assertEqual(row.status, 'synced')
        self.assertEqual(ReplicaRecord.objects.get().payload['subject'], 'v2')

    def test_keep_cloud_copy_is_not_sent(self):
        self.queue('session', 5, subject='v1')
        sync.run_once()
        ReplicaRecord.objects.update(cloud_modified_at=timezone.now())
        self.queue('session', 5, subject='v2')
        sync.run_once()
        row = SyncQueue.objects.get(status='conflict')
        admin = get_user_model().objects.create_superuser(email='campus.admin@gmail.com', password='x-Long-Passw0rd-1')
        sync.resolve_conflict(row, 'cloud', admin)
        requests = self.requests
        sync.run_once()
        self.assertEqual(self.requests, requests)
        self.assertEqual(ReplicaRecord.objects.get().payload['subject'], 'v1')

    def test_restart_with_work_in_flight_resumes(self):
        self.queue('session', 1, subject='A')
        # A crash while sending: the row stayed 'processing' with an old claim.
        SyncQueue.objects.update(status='processing', claim_token='dead', claimed_at=timezone.now() - datetime.timedelta(hours=1))
        sync.run_once()
        self.assertEqual(SyncQueue.objects.get().status, 'synced')

    def test_only_the_newest_snapshot_of_a_record_is_sent(self):
        for subject in ('v1', 'v2', 'v3'):
            self.queue('session', 6, subject=subject)
        sync.run_once()
        self.assertEqual(sorted(SyncQueue.objects.values_list('status', flat=True)), ['superseded', 'superseded', 'synced'])
        replica = ReplicaRecord.objects.get()
        self.assertEqual(replica.payload['subject'], 'v3')
        self.assertEqual(replica.last_sequence, SyncQueue.objects.get(status='synced').id)

    @override_settings(CLOUD_SYNC_ENABLED=False, CLOUD_SERVER_URL='', CLOUD_SYNC_API_KEY='')
    def test_nothing_is_queued_while_sync_is_not_configured(self):
        self.assertIsNone(self.queue('session', 1, subject='A'))
        self.assertEqual(SyncQueue.objects.count(), 0)
        self.assertEqual(sync.run_once(), 0)


class PayloadPrivacyTests(TestCase):
    def test_reservation_snapshot_never_contains_codes_or_secrets(self):
        from labs.models import Lab
        from scheduling.models import SessionRequest
        obj = SessionRequest.objects.create(
            lab=Lab.objects.create(name='Privacy test'), requester_type='instructor', requester_name='T',
            subject='Math', date=datetime.date(2026, 10, 23), start_time=datetime.time(8),
            end_time=datetime.time(9), student_count=30, pcs_requested=30,
            status='approved', reservation_code='SECRET-CODE',
        )
        obj.code = 'SECRET-CODE'
        data = sync_payloads.snapshot('reservation', obj)
        self.assertNotIn('SECRET-CODE', json.dumps(data))
        self.assertFalse({k for k in data if 'code' in k or 'password' in k or 'secret' in k})
