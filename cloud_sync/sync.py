"""
Sends queued SyncQueue rows to the configured cloud receiver (PROTOCOL.md).

Called every worker tick (system/worker.py) through run_once(), which
returns immediately when there is nothing to do, when cloud sync is not
configured, or while the queue is backing off after a failure. Nothing in
the request/response cycle for a student, instructor, or admin depends on
it: the campus server keeps working whether or not the cloud is reachable.

Guarantees:
  * Rows survive restarts (they are database rows); a row left 'processing'
    by a crash goes back to 'pending' after STUCK_AFTER_SECONDS.
  * Only one process sends at a time (a lease on the SyncState row), and
    rows are sent in queue order, oldest first.
  * When one record changed several times before it could be sent, only
    its newest snapshot is sent (the older rows are marked 'superseded').
  * Every change carries a unique edge_id: the receiver must treat a repeat
    as already applied ("duplicate"), so a lost reply never applies twice.
  * Network errors, timeouts and 5xx/429 answers pause the whole queue with
    bounded exponential backoff (30 s doubling up to 30 min); rows are not
    charged an attempt for them, so an outage never fails local changes.
  * 401/403 (bad key) and 404/405/410 (no receiver at that address) pause
    sync until the settings change or an Admin presses "Retry now",
    instead of retrying a permanent error forever.
  * A record the receiver rejects ('rejected') becomes 'failed'; one it
    reports as changed on the cloud side ('conflict') waits for an Admin
    (System status > Cloud sync). Both can be retried from there.
"""
import datetime
import hashlib
import json
import logging
import time
import urllib.error
import urllib.request
import uuid

from django.conf import settings
from django.db import transaction
from django.db.models import Count, F, Max, Q
from django.utils import timezone

logger = logging.getLogger(__name__)

PROTOCOL_VERSION = 2
STUCK_AFTER_SECONDS = 600
LEASE_SECONDS = 300
MIN_BACKOFF_SECONDS = 30
MAX_BACKOFF_SECONDS = 1800
ROW_MAX_ATTEMPTS = 20          # receiver kept answering "retry" for this record
RUN_BUDGET_SECONDS = 20        # per worker tick, so email and jobs keep moving
MAX_ERROR_BODY = 300


# ------------------------------------------------------------------ #
# Configuration
# ------------------------------------------------------------------ #
def is_enabled():
    return bool(getattr(settings, 'CLOUD_SYNC_ENABLED', False))


def _base_url():
    return (getattr(settings, 'CLOUD_SERVER_URL', '') or '').rstrip('/')


def _timeout():
    return getattr(settings, 'CLOUD_SYNC_TIMEOUT_SECONDS', 5)


def config_fingerprint():
    """Identifies the current URL + key without revealing the key."""
    raw = f'{_base_url()}\n{getattr(settings, "CLOUD_SYNC_API_KEY", "")}'
    return hashlib.sha256(raw.encode('utf-8')).hexdigest()[:32]


def describe_endpoint():
    """The configured receiver address for display (never the key)."""
    return _base_url()


def _backoff_seconds(failures):
    return min(MAX_BACKOFF_SECONDS, MIN_BACKOFF_SECONDS * (2 ** max(0, failures - 1)))


# ------------------------------------------------------------------ #
# HTTP
# ------------------------------------------------------------------ #
class _Answer:
    """Outcome of one HTTP exchange: status None means not reached."""
    def __init__(self, status=None, body=None, error=''):
        self.status = status
        self.body = body
        self.error = error


def _request(path, payload=None):
    url = _base_url() + path
    headers = {
        'Accept': 'application/json',
        'Authorization': f'Bearer {getattr(settings, "CLOUD_SYNC_API_KEY", "")}',
        'X-CompuLab-Site': getattr(settings, 'CLOUD_SYNC_SITE_ID', ''),
        'X-CompuLab-Sync-Protocol': str(PROTOCOL_VERSION),
    }
    data = None
    if payload is not None:
        data = json.dumps(payload).encode('utf-8')
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, data=data, headers=headers, method='POST' if data is not None else 'GET')
    try:
        with urllib.request.urlopen(req, timeout=_timeout()) as resp:
            raw = resp.read(2 * 1024 * 1024)
            try:
                body = json.loads(raw.decode('utf-8')) if raw else {}
            except ValueError:
                return _Answer(resp.status, None, 'the reply was not JSON (a proxy or login page in between?)')
            return _Answer(resp.status, body)
    except urllib.error.HTTPError as exc:
        text = ''
        try:
            text = exc.read(MAX_ERROR_BODY).decode('utf-8', 'replace')
        except Exception:  # noqa: BLE001
            pass
        detail = text
        try:
            parsed = json.loads(text)
            detail = parsed.get('detail') or parsed.get('error') or text
        except (ValueError, AttributeError):
            pass
        return _Answer(exc.code, None, f'HTTP {exc.code} {str(detail)[:MAX_ERROR_BODY]}'.strip())
    except (urllib.error.URLError, OSError) as exc:
        reason = getattr(exc, 'reason', exc)
        return _Answer(None, None, f'unreachable ({reason.__class__.__name__}: {reason})'[:MAX_ERROR_BODY])


def probe():
    """(ok, detail) for the connectivity monitor. ok is None when sync is
    not configured, True when the receiver answers its ping, else False."""
    if not is_enabled():
        if _base_url() and not getattr(settings, 'CLOUD_SYNC_API_KEY', ''):
            return None, 'CLOUD_SERVER_URL is set but CLOUD_SYNC_API_KEY is empty: sync is off'
        return None, 'Not configured'
    answer = _request('/api/ping/')
    if answer.status is None:
        return False, f'{_base_url()} {answer.error}'
    if 200 <= answer.status < 300:
        return True, _base_url()
    if answer.status in (404, 405, 410):
        return False, f'{_base_url()} answers, but has no sync receiver (HTTP {answer.status})'
    return False, f'{_base_url()} {answer.error or f"HTTP {answer.status}"}'


# ------------------------------------------------------------------ #
# Queue maintenance
# ------------------------------------------------------------------ #
def recover_stuck():
    """Rows left 'processing' by a process that died go back to pending."""
    from cloud_sync.models import SyncQueue
    cutoff = timezone.now() - datetime.timedelta(seconds=STUCK_AFTER_SECONDS)
    return SyncQueue.objects.filter(status='processing', claimed_at__lt=cutoff).update(
        status='pending', claim_token='', claimed_at=None,
    )


def coalesce():
    """For a record with several unsent changes, keep only the newest one
    (each row is a full snapshot, so the older ones add nothing)."""
    from cloud_sync.models import SyncQueue
    dupes = (
        SyncQueue.objects.filter(status='pending').values('record_key')
        .annotate(n=Count('id'), newest=Max('id')).filter(n__gt=1)
    )
    for d in dupes:
        older = SyncQueue.objects.filter(status='pending', record_key=d['record_key'], id__lt=d['newest'])
        if older.filter(force=True).exists():
            SyncQueue.objects.filter(pk=d['newest']).update(force=True)
        older.update(status='superseded', last_error='Replaced by a newer change to the same record')


def _due_rows_q(now):
    return Q(status='pending') & (Q(next_attempt_at__isnull=True) | Q(next_attempt_at__lte=now))


def _acquire_lease(state_model, token, now):
    return state_model.objects.filter(pk=1).filter(
        Q(lease_until__isnull=True) | Q(lease_until__lt=now) | Q(lease_owner=token)
    ).update(lease_owner=token, lease_until=now + datetime.timedelta(seconds=LEASE_SECONDS))


def _release_lease(state_model, token):
    state_model.objects.filter(pk=1, lease_owner=token).update(lease_owner='', lease_until=None)


def _claim(token, limit):
    from cloud_sync.models import SyncQueue
    now = timezone.now()
    ids = list(SyncQueue.objects.filter(_due_rows_q(now)).order_by('id').values_list('id', flat=True)[:limit])
    if not ids:
        return []
    SyncQueue.objects.filter(id__in=ids, status='pending').update(
        status='processing', claim_token=token, claimed_at=now,
    )
    return list(SyncQueue.objects.filter(claim_token=token, status='processing').order_by('id'))


def _release(rows):
    from cloud_sync.models import SyncQueue
    SyncQueue.objects.filter(id__in=[r.id for r in rows], status='processing').update(
        status='pending', claim_token='', claimed_at=None,
    )


# ------------------------------------------------------------------ #
# State changes
# ------------------------------------------------------------------ #
def _state_failure(state, error, pause_reason=''):
    now = timezone.now()
    state.consecutive_failures += 1
    state.last_error = error[:255]
    state.last_error_at = now
    if pause_reason:
        state.paused_reason = pause_reason
        state.paused_detail = error[:255]
        state.next_attempt_at = None
        logger.warning('Cloud sync paused (%s): %s', pause_reason, error)
    else:
        state.next_attempt_at = now + datetime.timedelta(seconds=_backoff_seconds(state.consecutive_failures))
        logger.info('Cloud sync will retry at %s: %s', timezone.localtime(state.next_attempt_at), error)
    state.save(update_fields=[
        'consecutive_failures', 'last_error', 'last_error_at', 'paused_reason', 'paused_detail', 'next_attempt_at',
    ])


def _state_success(state):
    now = timezone.now()
    state.last_success_at = now
    if state.consecutive_failures or state.last_error:
        logger.info('Cloud sync is working again')
    state.consecutive_failures = 0
    state.last_error = ''
    state.next_attempt_at = None
    state.save(update_fields=['last_success_at', 'consecutive_failures', 'last_error', 'next_attempt_at'])


def _record_payload(row):
    return {
        'edge_id': str(row.edge_id),
        'object_type': row.object_type,
        'local_id': row.local_id,
        'record_key': row.record_key or f'{row.object_type}:{row.local_id}',
        'operation': row.operation,
        'schema_version': row.schema_version,
        # Monotonic per campus server: a receiver keeps the highest sequence
        # applied per record and ignores anything older (late duplicates).
        'sequence': row.id,
        'force': row.force,
        'payload': row.payload,
        'created_at': row.created_at.isoformat(),
    }


def _apply_results(rows, body):
    """Mark each row by what the receiver said. Returns (accepted, unanswered)."""
    from cloud_sync.models import SyncQueue
    results = body.get('results') if isinstance(body.get('results'), dict) else {}
    accepted_ids = {str(x) for x in (body.get('accepted_edge_ids') or [])}
    now = timezone.now()
    accepted = unanswered = 0
    for row in rows:
        key = str(row.edge_id)
        result = results.get(key) if isinstance(results.get(key), dict) else None
        verdict = (result or {}).get('status') or ('accepted' if key in accepted_ids else None)
        detail = str((result or {}).get('detail') or '')[:MAX_ERROR_BODY]
        row.claim_token = ''
        row.claimed_at = None
        if verdict in ('accepted', 'duplicate'):
            row.mark_synced(now)
            row.force = False
            accepted += 1
        elif verdict == 'conflict':
            row.status = 'conflict'
            row.last_error = detail or 'The cloud copy was changed since it was last synced'
            row.remote_detail = {k: v for k, v in (result or {}).items() if k != 'status'}
            row.attempts = F('attempts') + 1
        elif verdict == 'rejected':
            row.status = 'failed'
            row.last_error = detail or 'Rejected by the cloud server'
            row.remote_detail = {k: v for k, v in (result or {}).items() if k != 'status'}
            row.attempts = F('attempts') + 1
        else:
            # 'retry', or the receiver did not mention this record.
            if verdict is None:
                unanswered += 1
            row.attempts = F('attempts') + 1
            row.status = 'pending'
            row.last_error = detail or 'The cloud server did not confirm this change; it will be sent again'
            row.next_attempt_at = now  # adjusted below once attempts is known
        row.save()
        if row.status == 'pending':
            row.refresh_from_db(fields=['attempts'])
            if row.attempts >= ROW_MAX_ATTEMPTS:
                SyncQueue.objects.filter(pk=row.pk).update(
                    status='failed', last_error=f'Gave up after {row.attempts} attempts: {row.last_error}'[:1000],
                )
            else:
                SyncQueue.objects.filter(pk=row.pk).update(
                    next_attempt_at=now + datetime.timedelta(seconds=_backoff_seconds(row.attempts)),
                )
    return accepted, unanswered


def _send_batch(state, rows):
    """Send one batch. Returns True to keep going, False to stop this run."""
    from cloud_sync.models import SyncQueue
    body = {
        'protocol': PROTOCOL_VERSION,
        'site_id': getattr(settings, 'CLOUD_SYNC_SITE_ID', ''),
        'sent_at': timezone.now().isoformat(),
        'records': [_record_payload(r) for r in rows],
    }
    state.last_attempt_at = timezone.now()
    state.save(update_fields=['last_attempt_at'])
    answer = _request('/api/sync/', body)

    if answer.status is None or answer.status == 429 or (answer.status and answer.status >= 500):
        _release(rows)
        _state_failure(state, answer.error or f'HTTP {answer.status}')
        return False
    if answer.status in (401, 403):
        _release(rows)
        _state_failure(state, f'The cloud server refused the API key ({answer.error}). '
                              'Check CLOUD_SYNC_API_KEY.', pause_reason='auth')
        return False
    if answer.status in (404, 405, 410):
        _release(rows)
        _state_failure(state, f'No sync receiver at {_base_url()}/api/sync/ ({answer.error}). '
                              'Check CLOUD_SERVER_URL.', pause_reason='incompatible')
        return False
    if answer.status == 413:
        _release(rows)
        state.batch_size = max(1, len(rows) // 2)
        state.save(update_fields=['batch_size'])
        return True
    if answer.status in (400, 409, 422):
        if len(rows) > 1:
            # Find the record the receiver objects to: send one at a time.
            _release(rows)
            state.batch_size = 1
            state.save(update_fields=['batch_size'])
            return True
        row = rows[0]
        SyncQueue.objects.filter(pk=row.pk).update(
            status='failed', attempts=F('attempts') + 1, claim_token='', claimed_at=None,
            last_error=(answer.error or f'HTTP {answer.status}')[:1000],
        )
        return True
    if not (200 <= answer.status < 300) or not isinstance(answer.body, dict):
        _release(rows)
        _state_failure(state, answer.error or f'Unexpected answer HTTP {answer.status}')
        return False

    accepted, unanswered = _apply_results(rows, answer.body)
    if accepted:
        _state_success(state)
        if state.batch_size < 50 and len(rows) == state.batch_size:
            state.batch_size = min(50, state.batch_size * 2)
            state.save(update_fields=['batch_size'])
    elif unanswered == len(rows):
        _state_failure(state, 'The cloud server answered but confirmed none of the changes')
        return False
    return True


def run_once():
    """One sync pass. Safe to call every few seconds from any process."""
    if not is_enabled():
        return 0
    from cloud_sync.models import SyncQueue, SyncState

    state = SyncState.get()
    fingerprint = config_fingerprint()
    if state.config_fingerprint != fingerprint:
        # New address or key: lift pauses caused by the old ones.
        state.config_fingerprint = fingerprint
        state.paused_reason = ''
        state.paused_detail = ''
        state.next_attempt_at = None
        state.consecutive_failures = 0
        state.save(update_fields=['config_fingerprint', 'paused_reason', 'paused_detail',
                                  'next_attempt_at', 'consecutive_failures'])
    recover_stuck()
    now = timezone.now()
    if state.paused_reason or (state.next_attempt_at and now < state.next_attempt_at):
        return 0
    if not SyncQueue.objects.filter(_due_rows_q(now)).exists():
        return 0

    token = uuid.uuid4().hex
    if not _acquire_lease(SyncState, token, now):
        return 0  # another process is sending
    sent_rows = 0
    started = time.monotonic()
    try:
        coalesce()
        while time.monotonic() - started < RUN_BUDGET_SECONDS:
            state.refresh_from_db()
            with transaction.atomic():
                rows = _claim(token, state.batch_size or 50)
            if not rows:
                break
            keep_going = _send_batch(state, rows)
            sent_rows += len(rows)
            if not keep_going:
                break
    finally:
        _release_lease(SyncState, token)
    return sent_rows


def resume():
    """Connectivity came back: try again now instead of waiting out the
    backoff. Pauses for a bad key / wrong address stay until fixed."""
    if not is_enabled():
        return
    from cloud_sync.models import SyncQueue, SyncState
    SyncState.get()
    SyncState.objects.filter(pk=1, paused_reason='').update(next_attempt_at=None)
    SyncQueue.objects.filter(status='pending', next_attempt_at__gt=timezone.now()).update(next_attempt_at=None)


# ------------------------------------------------------------------ #
# Admin actions (System status > Cloud sync)
# ------------------------------------------------------------------ #
def retry_now():
    """Lift any pause and backoff and send at the next worker tick."""
    from cloud_sync.models import SyncState
    SyncState.get()
    SyncState.objects.filter(pk=1).update(paused_reason='', paused_detail='', next_attempt_at=None,
                                          consecutive_failures=0)
    resume()


def retry_row(row):
    row.status = 'pending'
    row.attempts = 0
    row.next_attempt_at = None
    row.claim_token = ''
    row.claimed_at = None
    row.save(update_fields=['status', 'attempts', 'next_attempt_at', 'claim_token', 'claimed_at'])


def retry_all_failed():
    from cloud_sync.models import SyncQueue
    return SyncQueue.objects.filter(status='failed').update(
        status='pending', attempts=0, next_attempt_at=None, claim_token='', claimed_at=None,
    )


def resolve_conflict(row, keep, user):
    """keep='local': send our snapshot again and ask the receiver to
    overwrite its copy. keep='cloud': leave the cloud copy as it is."""
    if keep == 'local':
        row.force = True
        retry_row(row)
        row.save(update_fields=['force'])
    else:
        row.status = 'resolved'
        row.resolved_by = user
        row.resolved_at = timezone.now()
        row.save(update_fields=['status', 'resolved_by', 'resolved_at'])
    logger.info('Cloud sync conflict on %s resolved by %s: kept the %s copy', row.record_key, user, keep)


def housekeeping(days=30):
    """Delete synced/superseded/resolved rows after `days` days. Open rows
    (pending, failed, conflict) are never deleted automatically."""
    from cloud_sync.models import SyncQueue
    cutoff = timezone.now() - datetime.timedelta(days=days)
    SyncQueue.objects.filter(status__in=('synced', 'superseded', 'resolved'), created_at__lt=cutoff).delete()


def summary():
    """Counts and timestamps for the status page / footer."""
    from cloud_sync.models import SyncQueue, SyncState
    data = {
        'enabled': is_enabled(),
        'endpoint': describe_endpoint() if is_enabled() else '',
        'object_types': sorted(getattr(settings, 'CLOUD_SYNC_OBJECT_TYPES', ())),
        'pending': 0, 'processing': 0, 'failed': 0, 'conflict': 0,
        'oldest_pending_at': None, 'last_success_at': None, 'last_attempt_at': None,
        'last_error': '', 'last_error_at': None, 'paused_reason': '', 'paused_detail': '',
        'next_attempt_at': None, 'enqueue_failures': 0,
    }
    try:
        counts = {
            row['status']: row['n']
            for row in SyncQueue.objects.filter(status__in=('pending', 'processing', 'failed', 'conflict'))
            .values('status').annotate(n=Count('id')).order_by()
        }
        data.update({k: counts.get(k, 0) for k in ('pending', 'processing', 'failed', 'conflict')})
        oldest = SyncQueue.objects.filter(status__in=('pending', 'processing')).order_by('id').first()
        data['oldest_pending_at'] = oldest.created_at if oldest else None
        state = SyncState.objects.filter(pk=1).first()
        if state:
            data.update(
                last_success_at=state.last_success_at, last_attempt_at=state.last_attempt_at,
                last_error=state.last_error, last_error_at=state.last_error_at,
                paused_reason=state.paused_reason, paused_detail=state.paused_detail,
                next_attempt_at=state.next_attempt_at, enqueue_failures=state.enqueue_failures,
            )
    except Exception:  # noqa: BLE001 - tables missing before migrate
        pass
    return data


def start_cloud_sync_worker():
    """Kept for compatibility with older start-up code: sending now happens
    in the CompuLab worker loop (system/worker.py), so this does nothing."""
    return None
