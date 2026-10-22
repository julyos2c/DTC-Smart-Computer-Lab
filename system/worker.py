"""The CompuLab background worker loop.

Runs either
  * as its own Windows service: `python manage.py run_worker` (recommended
    for the on-premises server; the web service then runs with
    COMPULAB_BACKGROUND_TASKS=False), or
  * inside the web process on a daemon thread, when
    COMPULAB_BACKGROUND_TASKS=True (the default, so a single-process install
    keeps working without extra setup).

Each tick: email outbox dispatch, due ScheduledJobs, cloud sync (only when
configured), then the heartbeat — written last, so a loop stuck in one step
shows as "not running" even though its process still exists. Every minute:
connectivity probes; when the internet, SMTP or the cloud receiver comes
back, the email outbox and cloud sync are resumed at once (independently of
each other). Every hour: housekeeping. Every step is wrapped so one failure
is logged and never stops the loop."""
import logging
import threading
import time

logger = logging.getLogger('compulab.worker')

TICK_SECONDS = 5
PROBE_EVERY_SECONDS = 60
HOUSEKEEPING_EVERY_SECONDS = 3600


def _step(name, func, *args, **kwargs):
    try:
        return func(*args, **kwargs)
    except Exception:  # noqa: BLE001
        logger.exception('Worker step "%s" failed', name)
        return None


def run_forever(stop_event=None, mode='service'):
    from django.db import connections
    from system import connectivity, jobs
    from notifications import outbox
    from cloud_sync import sync
    from labs.agent_events import prune_receipts

    stop_event = stop_event or threading.Event()
    last_probe = last_housekeeping = 0.0
    logger.info('CompuLab worker started (%s mode)', mode)
    # Anything a previous run left half-done goes back to its queue first.
    _step('recover cloud sync', sync.recover_stuck)
    while not stop_event.is_set():
        started = time.monotonic()
        try:
            if started - last_probe >= PROBE_EVERY_SECONDS:
                last_probe = started
                came_back = _step('connectivity probes', connectivity.run_probes) or set()
                if came_back & {'internet', 'smtp'}:
                    logger.info('Connectivity restored (%s): resuming the email outbox', ', '.join(sorted(came_back)))
                    outbox.resume()
                if came_back & {'internet', 'cloud'}:
                    logger.info('Connectivity restored (%s): resuming cloud sync', ', '.join(sorted(came_back)))
                    _step('resume cloud sync', sync.resume)
            _step('email outbox', outbox.dispatch_due)
            _step('scheduled jobs', jobs.run_due_jobs)
            _step('cloud sync', sync.run_once)
            if started - last_housekeeping >= HOUSEKEEPING_EVERY_SECONDS:
                last_housekeeping = started
                _step('outbox housekeeping', outbox.housekeeping)
                _step('job pruning', jobs.prune_finished)
                _step('cloud sync housekeeping', sync.housekeeping)
                _step('agent event receipts', prune_receipts)
            _step('heartbeat', connectivity.heartbeat, f'{mode}; last tick {time.monotonic() - started:.1f}s')
        finally:
            # Long-lived thread: never keep a stale DB connection between ticks.
            connections.close_all()
        stop_event.wait(TICK_SECONDS)
    logger.info('CompuLab worker stopped')


def run_once(mode='cron'):
    """One full cycle, then return: for hosts where nothing may run in the
    background (cPanel/Passenger), started every minute by cron with
    `manage.py run_worker --once`. Covers the queue work only (email,
    durable jobs, reminders, cloud sync, probes); the lab-network loops
    (PC pings, after-hours locking) need the campus LAN and are not run.
    Emails are sent in a few batches so a backlog drains within minutes."""
    from django.db import connections
    from django.utils import timezone
    from system import connectivity, jobs
    from notifications import outbox
    from notifications.reminders import check_roster_code_reminders, check_upcoming_sessions
    from cloud_sync import sync
    from labs.agent_events import prune_receipts

    started = time.monotonic()
    try:
        came_back = _step('connectivity probes', connectivity.run_probes) or set()
        if came_back & {'internet', 'smtp', 'cloud'}:
            outbox.resume()
            _step('resume cloud sync', sync.resume)
        _step('session reminders', check_upcoming_sessions)
        _step('roster code reminders', check_roster_code_reminders)
        for _ in range(10):
            if not _step('email outbox', outbox.dispatch_due):
                break
        _step('scheduled jobs', jobs.run_due_jobs)
        _step('cloud sync', sync.run_once)
        if timezone.localtime().minute == 0:
            _step('outbox housekeeping', outbox.housekeeping)
            _step('job pruning', jobs.prune_finished)
            _step('cloud sync housekeeping', sync.housekeeping)
            _step('agent event receipts', prune_receipts)
        _step('heartbeat', connectivity.heartbeat, f'{mode}; last cycle {time.monotonic() - started:.1f}s')
    finally:
        connections.close_all()


_started = False


def start_in_process_worker():
    """Start run_forever() on a daemon thread inside the web process. Safe
    to call more than once."""
    global _started
    if _started:
        return
    _started = True

    def _run():
        time.sleep(5)  # let Django finish starting up
        run_forever(mode='in-process')

    threading.Thread(target=_run, name='compulab-worker', daemon=True).start()
