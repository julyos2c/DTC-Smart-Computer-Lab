"""Connectivity monitor: cheap probes for the database, the SMTP server,
the general internet and (when configured) the cloud sync receiver, stored
in SystemStatus so every page (and the installer / launcher via
/healthz/ready) can show the real state of the server instead of the
browser's own navigator.onLine.

Each status is kept separately, because they fail independently: the
internet can be down while the campus network (LAN), the database and every
local workflow keep working; the cloud receiver can be down while the
internet is up; SMTP can refuse a password while both are up.

The probes run on the background worker every minute with short timeouts;
pages only read the stored results (never wait on the network). They are
advisory: the email outbox and cloud sync still treat each real send
failure as authoritative, because a TCP connect can succeed while delivery
fails (bad credentials, provider throttling)."""
import datetime
import logging
import socket
import time

from django.conf import settings
from django.db import connection
from django.utils import timezone

logger = logging.getLogger(__name__)

PROBE_TIMEOUT_SECONDS = 3
# The worker heartbeat is written at the END of every completed tick, so a
# stuck loop goes stale even though its process still exists.
WORKER_STALE_SECONDS = 120
# Work that should have run this long ago but didn't means the worker is
# alive but not keeping up (or stuck on one step).
OVERDUE_JOB_SECONDS = 300
OVERDUE_EMAIL_SECONDS = 900
# A lab PC agent that has not called the server for this long is shown as
# "no recent agent contact" (agents call at start-up, at every lock and
# about every 8 s while a PC is in use).
AGENT_RECENT_SECONDS = 600
# "Internet restored; pending jobs are being processed" is shown this long.
RECOVERY_NOTICE_SECONDS = 600


def _tcp_ok(host, port, timeout=PROBE_TIMEOUT_SECONDS):
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True, ''
    except OSError as exc:
        return False, exc.__class__.__name__


def smtp_configured():
    return settings.EMAIL_BACKEND.endswith('smtp.EmailBackend') and bool(getattr(settings, 'EMAIL_HOST', ''))


def probe_database():
    try:
        with connection.cursor() as cursor:
            cursor.execute('SELECT 1')
            cursor.fetchone()
        return True, ''
    except Exception as exc:  # noqa: BLE001 - any DB error means "down"
        return False, exc.__class__.__name__


def probe_smtp():
    if not smtp_configured():
        return None, 'Not configured (emails are printed to the server console)'
    ok, err = _tcp_ok(settings.EMAIL_HOST, settings.EMAIL_PORT)
    return ok, (f'{settings.EMAIL_HOST}:{settings.EMAIL_PORT}' if ok else f'{settings.EMAIL_HOST}:{settings.EMAIL_PORT} unreachable ({err})')


def probe_internet():
    target = getattr(settings, 'INTERNET_PROBE_TARGET', '1.1.1.1:443')
    host, _, port = target.rpartition(':')
    if not host:
        host, port = target, '443'
    ok, err = _tcp_ok(host, port)
    return ok, ('' if ok else f'{target} unreachable ({err})')


def probe_cloud():
    from cloud_sync.sync import probe
    return probe()


def record(key, ok, detail=''):
    """Store one probe result; logs a line when the state flips."""
    from system.models import SystemStatus
    now = timezone.now()
    row, _ = SystemStatus.objects.get_or_create(key=key)
    changed = row.ok != ok
    if changed:
        row.previous_ok = row.ok
    row.ok = ok
    row.detail = (detail or '')[:255]
    row.checked_at = now
    if ok:
        row.last_ok_at = now
    if changed or row.last_change_at is None:
        row.last_change_at = now
        if key != 'worker':
            logger.info('Connectivity: %s is now %s %s', key, {True: 'OK', False: 'DOWN', None: 'n/a'}[ok], detail)
    row.save()
    return changed


def run_probes():
    """Run every probe once. Returns the set of services that just came
    back ('smtp', 'internet', 'cloud'), so the worker can resume the email
    outbox and cloud sync straight away instead of waiting out a backoff."""
    came_back = set()
    record('database', *probe_database())
    smtp_ok, smtp_detail = probe_smtp()
    if record('smtp', smtp_ok, smtp_detail) and smtp_ok:
        came_back.add('smtp')
    net_ok, net_detail = probe_internet()
    if record('internet', net_ok, net_detail) and net_ok:
        came_back.add('internet')
    # Only contact the cloud when the internet is up (or unknown): a failed
    # cloud probe during an internet outage would add nothing.
    if net_ok is False and getattr(settings, 'CLOUD_SYNC_ENABLED', False):
        cloud_ok, cloud_detail = False, 'Not checked: the internet is unavailable'
    else:
        cloud_ok, cloud_detail = probe_cloud()
    if record('cloud', cloud_ok, cloud_detail) and cloud_ok:
        came_back.add('cloud')
    return came_back


def heartbeat(detail=''):
    record('worker', True, detail)


# ------------------------------------------------------------------ #
# Read side (pages, context processor, health endpoint)
# ------------------------------------------------------------------ #
_summary_cache = {'at': 0.0, 'value': None}
_SUMMARY_TTL = 10  # seconds; the footer is rendered on every page


def _row_dict(row):
    if row is None:
        return {'ok': None, 'previous_ok': None, 'detail': '', 'since': None, 'checked_at': None, 'last_ok_at': None}
    return {'ok': row.ok, 'previous_ok': row.previous_ok, 'detail': row.detail, 'since': row.last_change_at,
            'checked_at': row.checked_at, 'last_ok_at': row.last_ok_at}


def _worker_problems(now, worker_alive):
    """Reasons the worker needs attention even though its heartbeat is fresh."""
    problems = []
    if not worker_alive:
        return problems
    try:
        from system.models import ScheduledJob
        overdue = ScheduledJob.objects.filter(
            status='pending', run_at__lt=now - datetime.timedelta(seconds=OVERDUE_JOB_SECONDS),
        ).count()
        if overdue:
            problems.append(f'{overdue} background job{"s" if overdue != 1 else ""} overdue by more than 5 minutes')
    except Exception:  # noqa: BLE001
        pass
    try:
        from notifications.models import EmailOutbox
        stale = EmailOutbox.objects.filter(
            status__in=('pending', 'retry'),
            next_attempt_at__lt=now - datetime.timedelta(seconds=OVERDUE_EMAIL_SECONDS),
        ).count()
        if stale:
            problems.append(f'{stale} email{"s" if stale != 1 else ""} due more than 15 minutes ago were not attempted')
    except Exception:  # noqa: BLE001
        pass
    return problems


def _agent_summary(now):
    try:
        from django.db.models import Max
        from labs.models import PC
        # A blank IP is stored as NULL; .exclude(ip_address='') would compile
        # to "NOT ip_address = NULL" and drop every row.
        pcs = PC.objects.filter(ip_address__isnull=False)
        recent_cutoff = now - datetime.timedelta(seconds=AGENT_RECENT_SECONDS)
        return {
            'pcs': pcs.count(),
            'offline': pcs.filter(status='offline').count(),
            'agents_recent': pcs.filter(agent_last_contact_at__gte=recent_cutoff).count(),
            'last_agent_contact': pcs.aggregate(m=Max('agent_last_contact_at'))['m'],
            'pending_events': sum(pcs.values_list('agent_pending_events', flat=True)),
        }
    except Exception:  # noqa: BLE001 - before migrate
        return {'pcs': 0, 'offline': 0, 'agents_recent': 0, 'last_agent_contact': None, 'pending_events': 0}


def _headline(s, now):
    """(level, text) one-line description, e.g. for the footer and the
    status page: level is 'ok', 'info', 'warn' or 'bad'."""
    if s['database']['ok'] is False:
        return 'bad', 'Local database unavailable: changes cannot be saved. Check the MariaDB service on the server.'
    if not s['worker_alive']:
        return 'warn', 'Background worker requires attention: it is not running.'
    if s['worker_problems']:
        return 'warn', 'Background worker requires attention: ' + s['worker_problems'][0] + '.'
    internet = s['internet']
    if internet['ok'] is False:
        waiting = []
        if s['emails_waiting']:
            waiting.append(f'{s["emails_waiting"]} email{"s" if s["emails_waiting"] != 1 else ""}')
        if s['sync']['enabled'] and s['sync']['pending']:
            waiting.append(f'{s["sync"]["pending"]} change{"s" if s["sync"]["pending"] != 1 else ""} for the cloud')
        tail = f' {" and ".join(waiting)} will be sent when it returns.' if waiting else ''
        return 'warn', 'Local system operational; internet unavailable.' + tail
    if s['sync']['enabled']:
        if s['sync']['paused_reason']:
            return 'warn', 'Local system operational; cloud synchronization paused: ' + s['sync']['paused_detail']
        if s['cloud']['ok'] is False:
            return 'warn', 'Local system operational; cloud server unreachable. Changes wait and are sent automatically.'
    recovering = (
        internet['ok'] and internet['previous_ok'] is False and internet['since']
        and (now - internet['since']).total_seconds() < RECOVERY_NOTICE_SECONDS
        and (s['emails_waiting'] or (s['sync']['enabled'] and s['sync']['pending']))
    )
    if recovering:
        return 'info', 'Internet restored; pending jobs are being processed.'
    if s['emails_dead'] or s['sync']['failed'] or s['sync']['conflict']:
        return 'info', 'Local system operational; some queued items need an Admin (System status).'
    if not s['sync']['enabled']:
        return 'ok', 'Local system operational; cloud synchronization not configured.'
    return 'ok', 'Local system operational.'


def headline_for(summary, is_admin):
    """The footer line for one viewer: problems only an Admin can act on
    (worker, rejected emails, sync conflicts) are shown to Admins only."""
    if is_admin:
        return summary['headline_level'], summary['headline']
    if summary['database']['ok'] is False or summary['internet']['ok'] is False:
        return summary['headline_level'], summary['headline']
    if summary['headline_level'] == 'info' and summary['headline'].startswith('Internet restored'):
        return summary['headline_level'], summary['headline']
    return 'ok', 'Local system operational.'


def get_summary(use_cache=True):
    """Dict describing server state for templates and /healthz/ready."""
    now_mono = time.monotonic()
    if use_cache and _summary_cache['value'] is not None and now_mono - _summary_cache['at'] < _SUMMARY_TTL:
        return _summary_cache['value']

    from system.models import SystemStatus
    try:
        rows = {r.key: r for r in SystemStatus.objects.all()}
    except Exception:  # noqa: BLE001 - table missing before migrate
        rows = {}
    worker = rows.get('worker')
    now = timezone.now()
    worker_alive = bool(
        worker and worker.checked_at and (now - worker.checked_at).total_seconds() < WORKER_STALE_SECONDS
    )
    try:
        from notifications.models import EmailOutbox
        emails_waiting = EmailOutbox.objects.filter(status__in=('pending', 'retry', 'sending')).count()
        emails_dead = EmailOutbox.objects.filter(status='dead').count()
        last_email_error = (
            EmailOutbox.objects.filter(status__in=('retry', 'dead')).exclude(last_error='')
            .order_by('-updated_at').values_list('last_error', flat=True).first() or ''
        )
    except Exception:  # noqa: BLE001
        emails_waiting = emails_dead = 0
        last_email_error = ''
    from cloud_sync.sync import summary as sync_summary

    summary = {
        'database': _row_dict(rows.get('database')),
        'smtp': _row_dict(rows.get('smtp')),
        'internet': _row_dict(rows.get('internet')),
        'cloud': _row_dict(rows.get('cloud')),
        'worker': _row_dict(worker),
        'worker_alive': worker_alive,
        'worker_problems': _worker_problems(now, worker_alive),
        'smtp_configured': smtp_configured(),
        'emails_waiting': emails_waiting,
        'emails_dead': emails_dead,
        'last_email_error': last_email_error,
        'sync': sync_summary(),
        'agents': _agent_summary(now),
        'lan_url': settings.SITE_URL,
        'remote_url': getattr(settings, 'REMOTE_URL', ''),
    }
    summary['worker_attention'] = (not worker_alive) or bool(summary['worker_problems'])
    summary['headline_level'], summary['headline'] = _headline(summary, now)
    _summary_cache.update(at=now_mono, value=summary)
    return summary


def email_probably_unavailable():
    """True when the last probes say email can't go out right now (internet
    or SMTP down). Used to word messages ("queued, will send when the
    internet is back") and to refuse self-service email password resets
    while offline. Unknown (no probe yet) counts as available."""
    s = get_summary()
    if not s['smtp_configured']:
        return False  # console backend: "sending" always succeeds locally
    return s['smtp']['ok'] is False or s['internet']['ok'] is False


def email_error_hint(error_text):
    """Plain-language next step for the last SMTP error, or ''."""
    text = error_text or ''
    if 'SMTPAuthenticationError' in text or ' 535' in text or ' 534' in text:
        return ('The mail server refused the username or password. Run installer\\server\\configure-email.ps1 '
                'again (for Gmail use an App Password), then press Retry in the Email outbox.')
    if 'SMTPSenderRefused' in text:
        return 'The mail server refused the sender address: DEFAULT_FROM_EMAIL must be the signed-in mailbox.'
    if 'SMTPRecipientsRefused' in text:
        return 'A recipient address was refused: fix that email address on the user account, then Retry.'
    if any(name in text for name in ('timeout', 'ConnectionRefused', 'SMTPConnectError', 'SMTPServerDisconnected', 'OSError', 'gaierror')):
        return 'The mail server could not be reached: check the internet connection and EMAIL_HOST / EMAIL_PORT.'
    return ''
