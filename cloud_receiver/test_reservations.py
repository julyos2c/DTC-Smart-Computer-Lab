"""Reservation intents, revision conflicts, local rules, and retry guarantees."""
import json
import uuid
from datetime import timedelta
from unittest.mock import patch
from django.test import TestCase, override_settings, Client
from django.utils import timezone
from cloud_receiver.models import ReservationChange, ReservationReceipt, ReplicaRecord
from cloud_receiver.receiver import key_hash
from cloud_sync.reservations import execute, run_once, state
from cloud_sync.models import SyncQueue
from scheduling.models import SessionRequest, Session
from scheduling.reservation_state import revision
from accounts.models import User
from labs.models import Lab, PC


@override_settings(CLOUD_RECEIVER_ENABLED=True, CLOUD_RESERVATIONS_ENABLED=True, CLOUD_RECEIVER_ALLOW_HTTP=False,
                   CLOUD_RECEIVER_SITES={'campus': key_hash('key')}, CLOUD_SYNC_SITE_ID='campus',
                   CLOUD_SYNC_API_KEY='key', CLOUD_SERVER_URL='https://cloud.example', CLOUD_SYNC_ENABLED=True,
                   CLOUD_SYNC_OBJECT_TYPES=('reservation', 'session'), EDGE_CLOUD_RESERVATIONS_ENABLED=True,
                   CLOUD_RESERVATION_EDGE_ACTOR_EMAIL='admin@gmail.com')
class ReservationTests(TestCase):
    def setUp(self):
        self.admin = User.objects.create(email='admin@gmail.com', role='admin', is_staff=True,
                                         email_verified=True, approval_status='approved')
        self.student = User.objects.create(email=None, role='student', id_number='ST-1', first_name='Student')
        self.lab = Lab.objects.create(name='Lab')
        PC.objects.create(lab=self.lab, pc_id='PC1')
        PC.objects.create(lab=self.lab, pc_id='PC2')
        self.data = {'lab': self.lab.pk, 'requester_type': 'student', 'requester_name': 'Student',
                     'requester_id_number': 'ST-1', 'subject': 'Programming',
                     'date': (timezone.localdate()+timedelta(days=2)).isoformat(),
                     'start_time': '09:00', 'end_time': '10:00', 'student_count': 1}

    def item(self, action='create', req=None, **extra):
        obj = dict(id=str(uuid.uuid4()), site_id='campus', action=action,
                   target_id=req.pk if req else None, base_revision=revision(req) if req else '',
                   payload=dict(self.data) if action == 'create' else {}, requested_by='cloud-admin@gmail.com',
                   expires_at=(timezone.now()+timedelta(hours=1)).isoformat())
        obj.update(extra)
        return obj

    def create(self):
        receipt = execute(self.item())
        self.assertEqual(receipt.status, 'applied', receipt.result)
        return SessionRequest.objects.get(pk=receipt.result['snapshot']['local_id'])

    def post(self, body=None, site='campus', key='key', secure=True):
        return self.client.post('/api/reservation-changes/', json.dumps(body or {}), content_type='application/json',
                                HTTP_AUTHORIZATION='Bearer '+key, HTTP_X_COMPULAB_SITE=site, secure=secure)

    def test_create_pending_and_transactional_outbox_without_codes(self):
        req = self.create()
        self.assertEqual(req.status, 'pending')
        self.assertEqual(req.instructor_id, self.student.pk)
        self.assertIsNone(req.reservation_code)
        self.assertEqual(SyncQueue.objects.filter(local_id=req.pk, object_type='reservation').count(), 1)
        self.assertEqual(len(state(req)['revision']), 64)
        self.assertNotIn('reservation_code', state(req))
        self.assertNotIn('requester_id_number', state(req))

    def test_duplicate_create_after_lost_response_is_applied_once(self):
        item = self.item()
        first = execute(item)
        second = execute(item)
        self.assertEqual(first.pk, second.pk)
        self.assertEqual(SessionRequest.objects.count(), 1)
        self.assertEqual(SyncQueue.objects.count(), 1)

    def test_update_pending_and_approve(self):
        req = self.create()
        receipt = execute(self.item('update', req, payload={'subject': 'Updated'}))
        self.assertEqual(receipt.status, 'applied', receipt.result)
        req.refresh_from_db()
        self.assertEqual(req.subject, 'Updated')
        result = execute(self.item('approve', req))
        self.assertEqual(result.status, 'applied', result.result)
        req.refresh_from_db()
        self.assertEqual(req.status, 'approved')
        self.assertTrue(req.reservation_code)
        self.assertEqual(Session.objects.get().reservation_code, req.reservation_code)

    def test_update_approved_changes_request_and_session(self):
        req = self.create()
        execute(self.item('approve', req))
        req.refresh_from_db()
        result = execute(self.item('update', req, payload={'subject': 'New subject', 'start_time': '11:00', 'end_time': '12:00'}))
        self.assertEqual(result.status, 'applied', result.result)
        req.refresh_from_db()
        session = Session.objects.get()
        self.assertEqual(req.subject, session.subject)
        self.assertEqual(session.start_time.hour, 11)

    def test_cancel_pending(self):
        req = self.create()
        result = execute(self.item('cancel', req))
        self.assertEqual(result.status, 'applied', result.result)
        req.refresh_from_db()
        self.assertEqual(req.status, 'cancelled')

    def test_cancel_approved_removes_session_and_notifies_once(self):
        req = self.create()
        execute(self.item('approve', req))
        req.refresh_from_db()
        item = self.item('cancel', req)
        with patch('notifications.services.notify_reservation_cancelled') as notify:
            execute(item)
            execute(item)
        notify.assert_called_once()
        self.assertFalse(Session.objects.exists())
        req.refresh_from_db()
        self.assertEqual(req.status, 'cancelled')

    def test_stale_cloud_edit_conflicts_after_local_edit(self):
        req = self.create()
        item = self.item('update', req, payload={'subject': 'Cloud'})
        req.subject = 'Local newer'
        req.save()
        result = execute(item)
        self.assertEqual(result.status, 'conflict')
        req.refresh_from_db()
        self.assertEqual(req.subject, 'Local newer')
        self.assertEqual(result.result['snapshot']['subject'], 'Local newer')

    def test_local_session_edit_changes_request_revision_and_mirror(self):
        req = self.create()
        execute(self.item('approve', req))
        req.refresh_from_db()
        old = revision(req)
        session = Session.objects.get()
        session.subject = 'Edited locally'
        session.save()
        self.assertNotEqual(revision(req), old)
        self.assertEqual(state(req)['subject'], 'Edited locally')

    def test_overlapping_requests_share_capacity_and_zero_is_rejected(self):
        req = self.create()
        other = self.create()
        self.assertEqual(execute(self.item('approve', req)).status, 'applied')
        self.assertEqual(execute(self.item('approve', other)).status, 'applied')
        req.refresh_from_db()
        other.refresh_from_db()
        self.assertEqual((req.pcs_allocated, other.pcs_allocated), (1, 1))
        result = execute(self.item('create'))
        self.assertEqual(result.status, 'rejected')
        self.assertIn('No available PCs', result.result['detail'])
        self.assertEqual(SessionRequest.objects.count(), 2)
        self.assertEqual(Session.objects.count(), 2)

    def test_capacity_disappears_before_cloud_approval_declines_request(self):
        from notifications.models import Notification
        req = self.create()
        other = self.create()
        third = self.create()
        self.assertEqual(execute(self.item('approve', req)).status, 'applied')
        self.assertEqual(execute(self.item('approve', other)).status, 'applied')
        result = execute(self.item('approve', third))
        self.assertEqual(result.status, 'rejected', result.result)
        self.assertIn('No available PCs', result.result['detail'])
        self.assertEqual(result.result['snapshot']['status'], 'declined')
        third.refresh_from_db()
        self.assertEqual((third.status, third.pcs_allocated), ('declined', 0))
        self.assertIsNone(third.reservation_code)
        self.assertEqual(Session.objects.count(), 2)
        self.assertTrue(Notification.objects.filter(
            notification_type='reservation_allocation', title__contains='No available PCs').exists())

    def test_validation_account_hours_time_and_date(self):
        invalid = [dict(requester_id_number='missing'), dict(start_time='06:00'),
                   dict(end_time='08:00'), dict(date=(timezone.localdate()-timedelta(days=1)).isoformat())]
        for changes in invalid:
            result = execute(self.item(payload=dict(self.data, **changes)))
            self.assertEqual(result.status, 'rejected', result.result)
        self.assertFalse(SessionRequest.objects.exists())

    def test_more_than_available_is_partially_approved_and_notified(self):
        from notifications.models import Notification
        result = execute(self.item(payload=dict(self.data, student_count=10)))
        self.assertEqual(result.status, 'applied')
        req = SessionRequest.objects.get()
        self.assertEqual(req.student_count, 10)  # original request stays intact
        self.assertEqual(req.pcs_allocated, 0)  # provisional request is not a hold
        approval = execute(self.item('approve', req))
        self.assertEqual(approval.status, 'applied', approval.result)
        req.refresh_from_db()
        self.assertEqual(req.pcs_allocated, 2)
        self.assertEqual(Session.objects.get().student_count, 2)
        self.assertTrue(Notification.objects.filter(notification_type='reservation_allocation',
                                                   message__contains='10 requested, 2 allocated').exists())

    def test_expired_and_cross_site_commands(self):
        item = self.item(expires_at=(timezone.now()-timedelta(seconds=1)).isoformat())
        self.assertEqual(execute(item).status, 'expired')
        self.assertIsNone(execute(self.item(site_id='other')))
        self.assertFalse(SessionRequest.objects.exists())

    def test_field_allowlist_blocks_status_and_code_injection(self):
        for field in ('status', 'reservation_code', 'instructor', 'roster'):
            result = execute(self.item(payload=dict(self.data, **{field: 'injected'})))
            self.assertEqual(result.status, 'rejected')

    def test_configured_local_admin_required(self):
        with override_settings(CLOUD_RESERVATION_EDGE_ACTOR_EMAIL='missing@gmail.com'):
            self.assertEqual(execute(self.item()).status, 'rejected')
        self.admin.role = 'instructor'
        self.admin.save()
        self.assertEqual(execute(self.item()).status, 'rejected')

    def test_outbox_failure_rolls_back_receipt_and_reservation(self):
        item = self.item()
        with patch('cloud_sync.reservations.publish', side_effect=RuntimeError('disk full')):
            with self.assertRaises(RuntimeError):
                execute(item)
        self.assertFalse(ReservationReceipt.objects.filter(pk=item['id']).exists())
        self.assertFalse(SessionRequest.objects.exists())
        self.assertEqual(execute(item).status, 'applied')

    def test_started_reservation_not_editable_or_cancellable(self):
        req = self.create()
        req.date = timezone.localdate()-timedelta(days=1)
        req.save()
        self.assertEqual(execute(self.item('cancel', req)).status, 'rejected')
        self.assertEqual(execute(self.item('update', req, payload={'subject': 'No'})).status, 'rejected')

    def test_duplicate_approval_and_cancelled_reservation_not_revived(self):
        req = self.create()
        item = self.item('approve', req)
        execute(item)
        execute(item)
        self.assertEqual(Session.objects.count(), 1)
        req.refresh_from_db()
        execute(self.item('cancel', req))
        req.refresh_from_db()
        self.assertEqual(execute(self.item('approve', req)).status, 'rejected')

    def test_api_auth_tls_validation_and_site_scoping(self):
        command = ReservationChange.objects.create(site_id='campus', action='create', payload=self.data)
        ReservationChange.objects.create(site_id='other', action='create', payload=self.data)
        self.assertEqual(self.post(key='wrong').status_code, 401)
        self.assertEqual(self.post(site='other').status_code, 401)
        self.assertEqual(self.post(secure=False).status_code, 403)
        self.assertEqual(self.post({'results': 'bad'}).status_code, 400)
        self.assertEqual(self.post({'results': [{'id': 'bad', 'status': 'applied', 'result': {}}]}).status_code, 400)
        self.assertEqual([c['id'] for c in self.post().json()['changes']], [str(command.pk)])

    def test_expired_api_requests_not_delivered(self):
        command = ReservationChange.objects.create(site_id='campus', action='create', payload=self.data,
                                                   expires_at=timezone.now()-timedelta(seconds=1))
        self.assertEqual(self.post().json()['changes'], [])
        command.refresh_from_db()
        self.assertEqual(command.status, 'expired')

    def test_api_reports_idempotent_and_cross_site_refused(self):
        command = ReservationChange.objects.create(site_id='campus', action='create', payload=self.data)
        other = ReservationChange.objects.create(site_id='other', action='create', payload=self.data)
        report = {'id': str(command.pk), 'status': 'applied', 'result': {'detail': 'OK'}}
        self.assertEqual(self.post({'results': [report]}).json()['acknowledged'], [str(command.pk)])
        report['status'] = 'rejected'
        self.post({'results': [report]})
        command.refresh_from_db()
        self.assertEqual(command.status, 'applied')
        report['id'] = str(other.pk)
        self.assertEqual(self.post({'results': [report]}).json()['acknowledged'], [])

    @patch('cloud_sync.transport.post')
    def test_outage_keeps_intents_pending_and_receipts_unreported(self, post):
        execute(self.item())
        post.side_effect = OSError('offline')
        run_once()
        self.assertFalse(ReservationReceipt.objects.get().reported)

    @patch('cloud_sync.transport.post')
    def test_cloud_edge_round_trip_and_replica_sync(self, post):
        from cloud_receiver.receiver import apply_record
        command = ReservationChange.objects.create(site_id='campus', action='create', payload=self.data)
        post.side_effect = lambda path, body: self.post(body).json()
        run_once()
        self.assertEqual(SessionRequest.objects.count(), 1)
        run_once()
        command.refresh_from_db()
        self.assertEqual(command.status, 'applied')
        self.assertTrue(ReservationReceipt.objects.get().reported)
        row = SyncQueue.objects.first()
        result = apply_record('campus', {'edge_id': str(row.edge_id), 'object_type': 'reservation',
                                        'local_id': row.local_id, 'sequence': row.pk, 'schema_version': 1,
                                        'operation': 'upsert', 'payload': row.payload})
        self.assertEqual(result['status'], 'accepted')
        replica = ReplicaRecord.objects.get()
        self.assertEqual(replica.payload['revision'], revision(SessionRequest.objects.get()))

    def test_cloud_admin_form_submission_and_permissions(self):
        self.client.force_login(self.admin)
        url = '/admin/cloud_receiver/reservationchange/add/'
        self.assertEqual(self.client.get(url, secure=True).status_code, 200)
        expiry = timezone.localtime(timezone.now()+timedelta(hours=1))
        data = dict(self.data, site_id='campus', action='create',
                    expires_at_0=expiry.strftime('%Y-%m-%d'), expires_at_1=expiry.strftime('%H:%M:%S'), _save='Save')
        response = self.client.post(url, data, secure=True)
        self.assertEqual(response.status_code, 302)
        command = ReservationChange.objects.get()
        self.assertEqual(command.requested_by, self.admin.email)
        self.assertEqual(command.payload['subject'], self.data['subject'])
        self.assertEqual(self.client.post(f'/admin/cloud_receiver/reservationchange/{command.pk}/change/', data, secure=True).status_code, 403)
        self.admin.role = 'incharge'
        self.admin.save()
        self.assertEqual(self.client.get(url, secure=True).status_code, 403)

    def test_form_target_site_revision_and_partial_update(self):
        from cloud_receiver.reservation_admin import ReservationChangeForm
        req = self.create()
        replica = ReplicaRecord.objects.create(site_id='campus', object_type='reservation', local_id=req.pk, payload=state(req))
        form = ReservationChangeForm(data={'site_id': 'campus', 'action': 'update', 'reservation': replica.pk,
                                          'subject': 'Change', 'expires_at': timezone.now()+timedelta(hours=1)})
        self.assertTrue(form.is_valid(), form.errors)
        command = form.save(commit=False)
        self.assertEqual(command.base_revision, revision(req))
        self.assertEqual(command.payload, {'subject': 'Change'})
        replica.site_id = 'other'
        replica.save()
        bad = ReservationChangeForm(data={'site_id': 'campus', 'action': 'cancel', 'reservation': replica.pk,
                                         'expires_at': timezone.now()+timedelta(hours=1)})
        self.assertFalse(bad.is_valid())

    def test_cloud_disallows_direct_schedule_writes(self):
        self.client.force_login(self.admin)
        self.assertEqual(self.client.post('/schedule/requests/new/', {}).status_code, 409)
        self.assertEqual(self.client.post('/admin/scheduling/sessionrequest/add/', {}).status_code, 409)

    def test_cloud_admin_csrf(self):
        client = Client(enforce_csrf_checks=True)
        client.force_login(self.admin)
        self.assertEqual(client.post('/admin/cloud_receiver/reservationchange/add/', {}, secure=True).status_code, 403)

    @patch('cloud_sync.transport.post')
    def test_disabled_worker_and_api(self, post):
        with override_settings(EDGE_CLOUD_RESERVATIONS_ENABLED=False):
            run_once()
        post.assert_not_called()
        with override_settings(CLOUD_RESERVATIONS_ENABLED=False):
            self.assertEqual(self.post().status_code, 404)

    def test_late_result_after_cloud_expiry_is_preserved(self):
        command = ReservationChange.objects.create(site_id='campus', action='create', payload=self.data,
                                                   expires_at=timezone.now()-timedelta(seconds=1))
        self.post()
        report = {'id': str(command.pk), 'status': 'applied', 'result': {'detail': 'Applied before connection dropped'}}
        self.post({'results': [report]})
        command.refresh_from_db()
        self.assertEqual(command.status, 'applied')

    def test_local_session_save_enqueues_updated_reservation_snapshot(self):
        from cloud_sync.signals import _on_save
        req = self.create()
        execute(self.item('approve', req))
        session = Session.objects.get()
        with self.captureOnCommitCallbacks(execute=True):
            _on_save(Session, session, created=False)
        row = SyncQueue.objects.filter(object_type='reservation', local_id=req.pk).last()
        req.refresh_from_db()
        self.assertEqual(row.payload['revision'], revision(req))
        self.assertEqual(row.payload['status'], 'approved')

    def test_form_can_clear_existing_notes(self):
        from cloud_receiver.reservation_admin import ReservationChangeForm
        req = self.create()
        req.notes = 'Old note'
        req.save()
        replica = ReplicaRecord.objects.create(site_id='campus', object_type='reservation', local_id=req.pk, payload=state(req))
        form = ReservationChangeForm(data={'site_id': 'campus', 'action': 'update', 'reservation': replica.pk,
                                          'clear_notes': True, 'expires_at': timezone.now()+timedelta(hours=1)})
        self.assertTrue(form.is_valid(), form.errors)
        self.assertEqual(form.instance.payload, {'notes': ''})
        result = execute(self.item('update', req, payload=form.instance.payload))
        self.assertEqual(result.status, 'applied')
        req.refresh_from_db()
        self.assertEqual(req.notes, '')

    def test_revision_does_not_publish_a_reservation_code_digest(self):
        req = self.create()
        before = revision(req)
        req.reservation_code = 'SECRET-CODE'
        req.save()
        self.assertEqual(revision(req), before)  # pending state has no linked session
        self.assertNotIn('SECRET-CODE', json.dumps(state(req)))
