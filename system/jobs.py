"""Durable, run-once background jobs (the ScheduledJob table).

schedule() writes a row; the worker loop (system/worker.py) runs it when
due. A job is claimed with UPDATE ... WHERE status='pending', so it runs at
most once even when the web process and the worker both look at it.

If no worker is running (single-process installs, or the worker service is
stopped), schedule() also arms a short in-process timer for the same job,
so behaviour never regresses below the old "sleeping thread" approach; the
claim rule still guarantees a single run."""
import datetime
import logging
import threading

from django.db.models import F
from django.utils import timezone
from django.utils.module_loading import import_string

logger = logging.getLogger(__name__)

HANDLERS = {
    'override_grant': 'labs.views._finish_override_grant',
}
RETRY_DELAY_SECONDS = 30
STUCK_AFTER_SECONDS = 600


def schedule(kind, run_at, payload=None, max_attempts=3):
    from system.models import ScheduledJob
    from system.connectivity import get_summary

    job = ScheduledJob.objects.create(kind=kind, run_at=run_at, payload=payload or {}, max_attempts=max_attempts)
    if not get_summary(use_cache=False)['worker_alive']:
        delay = max(0.0, (run_at - timezone.now()).total_seconds())
        _arm_local_timer(job.pk, delay)
    return job


def _arm_local_timer(job_pk, delay):
    def _run():
        from django.db import connections
        try:
            run_job(job_pk)
        finally:
            connections.close_all()
    timer = threading.Timer(delay, _run)
    timer.daemon = True
    timer.start()


def run_job(job_pk):
    """Claim and run one job if it is still pending. Returns True if it ran."""
    from system.models import ScheduledJob

    now = timezone.now()
    claimed = ScheduledJob.objects.filter(pk=job_pk, status='pending').update(
        status='running', started_at=now, attempts=F('attempts') + 1,
    )
    if not claimed:
        return False
    job = ScheduledJob.objects.get(pk=job_pk)
    try:
        handler = import_string(HANDLERS[job.kind])
        handler(**job.payload)
    except Exception as exc:  # noqa: BLE001 - recorded, retried, never kills the loop
        logger.exception('Scheduled job #%s (%s) failed', job.pk, job.kind)
        job.last_error = f'{exc.__class__.__name__}: {exc}'[:255]
        if job.attempts < job.max_attempts:
            job.status = 'pending'
            job.run_at = timezone.now() + datetime.timedelta(seconds=RETRY_DELAY_SECONDS)
        else:
            job.status = 'failed'
            job.finished_at = timezone.now()
        job.save(update_fields=['status', 'run_at', 'last_error', 'finished_at'])
        return True
    job.status = 'done'
    job.finished_at = timezone.now()
    job.save(update_fields=['status', 'finished_at'])
    return True


def run_due_jobs(limit=20):
    from system.models import ScheduledJob

    now = timezone.now()
    # A job left 'running' by a process that died mid-run goes back to the queue.
    ScheduledJob.objects.filter(
        status='running', started_at__lt=now - datetime.timedelta(seconds=STUCK_AFTER_SECONDS),
    ).update(status='pending')
    due = list(
        ScheduledJob.objects.filter(status='pending', run_at__lte=now)
        .order_by('run_at').values_list('pk', flat=True)[:limit]
    )
    ran = 0
    for pk in due:
        if run_job(pk):
            ran += 1
    return ran


def prune_finished(days=30):
    from system.models import ScheduledJob
    cutoff = timezone.now() - datetime.timedelta(days=days)
    ScheduledJob.objects.filter(status__in=('done', 'failed', 'cancelled'), created_at__lt=cutoff).delete()
