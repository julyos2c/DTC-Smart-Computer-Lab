"""Transactional cloud reservation intents. Local DB remains authoritative."""
import logging
import uuid
from django.conf import settings
from django.db import transaction
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from cloud_receiver.models import ReservationReceipt
from cloud_sync import transport
from scheduling.write_lock import schedule_write_lock

logger = logging.getLogger(__name__)
FIELDS = ('requester_type', 'requester_name', 'requester_id_number', 'lab', 'subject',
          'date', 'start_time', 'end_time', 'student_count', 'pcs_requested', 'notes')


class Refused(Exception):
    def __init__(self, status, detail, **extra):
        self.status, self.result = status, dict(detail=detail, **extra)


def state(req):
    from cloud_sync.sync_payloads import snapshot
    return dict(snapshot('reservation', req), local_id=req.pk)


def publish(req):
    # Unlike best-effort on_commit signals, this outbox row is in the SAME
    # transaction as the receipt and reservation. Failure rolls everything back.
    from cloud_sync.models import SyncQueue
    SyncQueue.objects.create(object_type='reservation', local_id=req.pk,
                             record_key=f'reservation:{req.pk}', edge_id=uuid.uuid4(), payload=state(req))


def _future(obj):
    from scheduling.views import _session_started
    if _session_started(obj.date, obj.start_time):
        raise Refused('rejected', 'Reservation has started or passed; history cannot be changed remotely.')


def _validated_form(payload, req=None, *, check_capacity=True):
    from scheduling.forms import SessionRequestForm, SessionForm
    from scheduling.reservation_state import linked_session
    from scheduling.views import _slot_error
    from scheduling.utils import requested_pc_count
    session = linked_session(req) if req else None
    if req and req.status == 'approved' and session is None:
        raise Refused('conflict', 'Approved request has no linked session. Resolve on the edge.')
    instance = session or req
    if req:
        _future(instance)
    data = {k: getattr(instance, k, '') for k in FIELDS} if instance else {}
    if req and session:
        data['student_count'] = req.student_count
        data['pcs_requested'] = req.pcs_requested
    if instance:
        data['lab'] = instance.lab_id
    data.update(payload)
    if session:
        data['roster'] = session.roster_id or ''  # cannot change roster remotely
        form = SessionForm(data=data, instance=session)
    else:
        form = SessionRequestForm(data=data, instance=req)
    if not form.is_valid():
        raise Refused('rejected', 'Reservation validation failed.', errors=form.errors.get_json_data())
    obj = form.instance
    _future(obj)
    if obj.start_time >= obj.end_time:
        raise Refused('rejected', 'End time must be later than start time.')
    error = _slot_error(obj.requester_type, obj.lab, obj.date, obj.start_time, obj.end_time,
                        obj.pcs_requested, obj.student_count, exclude_pk=session.pk if session else None,
                        check_capacity=check_capacity)
    if error:
        raise Refused('rejected', error)
    if obj.roster_id:
        obj.student_count = obj.roster.students.count()
    obj.instructor = form.cleaned_data['_matched_account']
    return form, session


def apply_change(item, actor):
    from scheduling.models import SessionRequest, Session
    from scheduling.reservation_state import revision, linked_session
    from scheduling.utils import generate_reservation_code, requested_pc_count, allocate_pcs
    from notifications import services as notify
    action, payload = item['action'], item['payload']
    req = None
    if action != 'create':
        req = SessionRequest.objects.select_for_update().filter(pk=item['target_id']).first()
        if req is None:
            raise Refused('conflict', 'Reservation no longer exists on the edge.')
        if revision(req) != item['base_revision']:
            raise Refused('conflict', 'Reservation changed on the edge. Refresh the cloud copy before submitting again.',
                          snapshot=state(req))
        if req.status not in ('pending', 'approved'):
            raise Refused('rejected', 'Only pending or approved reservations can be changed.')
    if action == 'create':
        form, _ = _validated_form(payload)
        req = form.save(commit=False)
        req.status = 'pending'
        req.save()
        notify.notify_reservation_submitted(req)
        granted, note, _ = allocate_pcs(req.lab, req.date, req.start_time, req.end_time,
                                        requested_pc_count(req))
        if note:
            notify.notify_reservation_allocation(req, granted, provisional=True)
    elif action == 'update':
        form, session = _validated_form(payload, req)
        updated = form.save(commit=False)
        requested = requested_pc_count(updated)
        granted = 0
        if session:
            granted, note, _ = allocate_pcs(
                updated.lab, updated.date, updated.start_time, updated.end_time,
                requested, exclude_pk=session.pk)
            if not granted:
                raise Refused('rejected', 'No PCs available at the edited time. Existing approved session unchanged.')
            updated.pcs_allocated = granted
            if updated.requester_type in ('walk_in', 'override'):
                updated.pcs_requested = granted
            else:
                updated.student_count = granted
            updated.reminder_sent = updated.roster_code_reminder_sent = False
        updated.save()
        if session:
            # Keep original requested count on SessionRequest, not the capped
            # number used for session access control/check-in.
            for field in FIELDS:
                if field not in ('notes', 'student_count', 'pcs_requested'):
                    setattr(req, field, getattr(updated, field))
            req.student_count = form.cleaned_data['student_count']
            req.pcs_requested = form.cleaned_data['pcs_requested']
            req.pcs_allocated = granted
            req.instructor = updated.instructor
            if 'notes' in payload:
                req.notes = payload['notes']
            req.save()
            if granted < requested:
                notify.notify_reservation_allocation(req, granted)
        else:
            granted, note, _ = allocate_pcs(req.lab, req.date, req.start_time, req.end_time,
                                            requested_pc_count(req))
            if note:
                notify.notify_reservation_allocation(req, granted, provisional=True)
    elif action == 'approve':
        if req.status != 'pending':
            raise Refused('rejected', 'Only pending reservations can be approved.')
        # Allow validation to reach the capacity decision below: if the
        # slot filled up since submission, decline rather than waitlist.
        form, _ = _validated_form({}, req, check_capacity=False)
        req = form.save(commit=False)
        requested = requested_pc_count(req)
        granted, note, _ = allocate_pcs(req.lab, req.date, req.start_time, req.end_time, requested)
        if not granted:
            req.status = 'declined'
            req.pcs_allocated = 0
            req.reservation_code = None
            req.save(update_fields=['status', 'pcs_allocated', 'reservation_code'])
            notify.notify_reservation_allocation(req, 0)
            publish(req)
            return {'detail': note, 'snapshot': state(req), '_receipt_status': 'rejected'}
        req.reservation_code = generate_reservation_code()
        req.status = 'approved'
        req.pcs_allocated = granted
        req.save()
        Session.objects.create(**{k: getattr(req, k) for k in FIELDS if k != 'notes' and k not in ('student_count', 'pcs_requested')},
                               student_count=granted if req.requester_type not in ('walk_in', 'override') else req.student_count,
                               pcs_requested=granted if req.requester_type in ('walk_in', 'override') else req.pcs_requested,
                               pcs_allocated=granted, instructor=req.instructor, roster=req.roster,
                               reservation_code=req.reservation_code)
        notify.notify_reservation_approved(req, req.reservation_code)
        if granted < requested:
            notify.notify_reservation_allocation(req, granted)
        if req.requester_type in ('walk_in', 'override'):
            notify.notify_walkin_override_approved(req, req.reservation_code)
    elif action == 'cancel':
        session = linked_session(req)
        _future(session or req)
        if req.status == 'approved' and not session:
            raise Refused('conflict', 'Approved request has no linked session. Resolve on the edge.')
        if session:
            session.delete()
        req.status = 'cancelled'
        req.save(update_fields=['status'])
        from scheduling.views import _log_cancellation
        _log_cancellation(actor, req.subject, req.lab, req.date, req.start_time, req.end_time)
        notify.notify_reservation_cancelled(req.lab, req.subject, req.date, req.start_time,
                                            req.end_time, actor, instructor=req.instructor)
    publish(req)
    return {'detail': 'Change applied on the edge.', 'snapshot': state(req)}


def execute(item):
    if not isinstance(item, dict):
        return
    try:
        command_id = uuid.UUID(str(item['id']))
        if item['site_id'] != settings.CLOUD_SYNC_SITE_ID:
            return
        expiry = parse_datetime(item['expires_at'])
        if expiry is None or timezone.is_naive(expiry):
            return
    except (KeyError, ValueError, TypeError, AttributeError):
        return
    # Receipts and all DB changes commit together. A crash either commits both
    # or neither, so a lost response can be retried without duplicate effects.
    with schedule_write_lock():
        receipt, created = ReservationReceipt.objects.get_or_create(
            pk=command_id, defaults={'site_id': item['site_id'], 'status': 'rejected'})
        if not created:
            return receipt
        try:
            if expiry <= timezone.now():
                raise Refused('expired', 'Request expired before edge execution.')
            if (item.get('action') not in ('create', 'update', 'approve', 'cancel')
                    or not isinstance(item.get('payload'), dict)
                    or set(item['payload']) - set(FIELDS)):
                raise Refused('rejected', 'Unknown action or invalid fields.')
            if item['action'] != 'create':
                if (not isinstance(item.get('target_id'), int) or isinstance(item['target_id'], bool)
                        or item['target_id'] <= 0 or not isinstance(item.get('base_revision'), str)
                        or len(item['base_revision']) != 64):
                    raise Refused('rejected', 'Target and current revision are required.')
            if item['action'] in ('approve', 'cancel') and item['payload']:
                raise Refused('rejected', 'Approve/cancel cannot carry field edits.')
            if (not settings.CLOUD_SYNC_ENABLED or 'reservation' not in settings.CLOUD_SYNC_OBJECT_TYPES):
                raise Refused('rejected', 'Enable reservation record sync on the edge first.')
            from accounts.models import User
            from accounts.backends import VerifiedEmailBackend
            actor = User.objects.filter(email=settings.CLOUD_RESERVATION_EDGE_ACTOR_EMAIL, role='admin', is_active=True).first()
            if not actor or not VerifiedEmailBackend().user_can_authenticate(actor):
                raise Refused('rejected', 'Configured edge audit account must be an active approved admin.')
            # Nested savepoint: failed validation rolls back any partial domain writes.
            with transaction.atomic():
                result = apply_change(item, actor)
            # A denied approval can persist status=declined and still report
            # rejected to the Cloud without rolling back that state change.
            receipt.status = result.pop('_receipt_status', 'applied')
            receipt.result = result
        except Refused as exc:
            receipt.status, receipt.result = exc.status, exc.result
        receipt.result.update(action=item.get('action'), requested_by=str(item.get('requested_by', ''))[:254])
        receipt.save(update_fields=['status', 'result'])
        logger.info('Cloud reservation %s: %s', command_id, receipt.status)
        return receipt


def run_once():
    if not getattr(settings, 'EDGE_CLOUD_RESERVATIONS_ENABLED', False):
        return
    pending = list(ReservationReceipt.objects.filter(reported=False, site_id=settings.CLOUD_SYNC_SITE_ID)
                   .order_by('created_at')[:50])
    try:
        answer = transport.post('/api/reservation-changes/', {'results': [
            {'id': str(r.pk), 'status': r.status, 'result': r.result} for r in pending]})
        if (not isinstance(answer, dict) or not isinstance(answer.get('acknowledged'), list)
                or not isinstance(answer.get('changes'), list)):
            raise ValueError('Invalid cloud response')
        acknowledged = {str(x) for x in answer['acknowledged']}
        ReservationReceipt.objects.filter(pk__in=[r.pk for r in pending if str(r.pk) in acknowledged]).update(reported=True)
        for item in answer['changes'][:10]:
            execute(item)
    except Exception:
        logger.warning('Cloud reservation exchange failed; pending changes will retry', exc_info=True)
