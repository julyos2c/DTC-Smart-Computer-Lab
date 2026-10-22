"""
Keeps 'session starting soon' notifications flowing automatically, the
same way labs/network.py keeps PC status flowing automatically: a daemon
thread that loops for as long as the server runs, so nobody has to run a
cron job or management command by hand.
"""
import logging
import time
import threading
from datetime import timedelta

logger = logging.getLogger('compulab.worker')

REMINDER_WINDOW_MIN_MINUTES = 10
REMINDER_WINDOW_MAX_MINUTES = 15
CHECK_INTERVAL_SECONDS = 60

# Sessions auto-generated from a Class Roster schedule don't get their
# reservation-code notification the instant they're created (that would be
# one big burst of notifications for the whole semester at roster-creation
# time) — instead it's held back and sent exactly ~1 hour before that
# specific session starts, same polling approach as the 10-15 minute
# "starting soon" window above.
ROSTER_CODE_WINDOW_MIN_MINUTES = 55
ROSTER_CODE_WINDOW_MAX_MINUTES = 60

_checker_started = False


def check_upcoming_sessions():
    """Finds today's Sessions starting within the next 15 minutes that
    haven't been reminded about yet, and fires the auto notification for
    each. Normally that is the 10-15 minute mark; if the server or worker
    was down then, the reminder goes out late (as long as the session
    hasn't started) rather than never."""
    from django.utils import timezone
    from scheduling.models import Session
    from notifications import services as notify_service

    now = timezone.localtime()
    window_start = now
    window_end = now + timedelta(minutes=REMINDER_WINDOW_MAX_MINUTES)

    if window_start.date() != window_end.date():
        return  # midnight edge case — window spans two dates, skip this tick

    sessions = Session.objects.filter(
        date=window_start.date(),
        start_time__gt=window_start.time(),
        start_time__lte=window_end.time(),
        reminder_sent=False,
    ).select_related('lab', 'instructor')

    for session in sessions:
        notify_service.notify_session_starting_soon(session)
        session.reminder_sent = True
        session.save(update_fields=['reminder_sent'])


def check_roster_code_reminders():
    """Finds today's roster-auto-generated Sessions starting 55-60 minutes
    from now that haven't had their reservation-code reminder sent yet, and
    sends it — this is how a Class Roster session's code actually reaches
    the instructor's notification panel, 1 hour ahead of that session."""
    from django.utils import timezone
    from scheduling.models import Session
    from notifications import services as notify_service

    now = timezone.localtime()
    # From now up to 60 minutes ahead: normally sent at the 55-60 minute
    # mark, but sent late (before the class starts) after a server outage.
    window_start = now
    window_end = now + timedelta(minutes=ROSTER_CODE_WINDOW_MAX_MINUTES)

    if window_start.date() != window_end.date():
        return  # midnight edge case — window spans two dates, skip this tick

    sessions = Session.objects.filter(
        date=window_start.date(),
        start_time__gt=window_start.time(),
        start_time__lte=window_end.time(),
        roster_code_reminder_sent=False,
        roster__isnull=False,
        reservation_code__isnull=False,
    ).select_related('lab', 'instructor', 'roster')

    for session in sessions:
        notify_service.notify_roster_session_scheduled(session, session.reservation_code)
        session.roster_code_reminder_sent = True
        session.save(update_fields=['roster_code_reminder_sent'])


def start_background_session_reminder_checker():
    global _checker_started
    if _checker_started:
        return
    _checker_started = True

    def _loop():
        time.sleep(10)  # let Django finish starting up first
        while True:
            from django.db import connections
            try:
                check_upcoming_sessions()
            except Exception:
                logger.exception('Session reminder check failed')  # never kills the loop
            try:
                check_roster_code_reminders()
            except Exception:
                logger.exception('Roster code reminder check failed')
            finally:
                connections.close_all()
            time.sleep(CHECK_INTERVAL_SECONDS)

    thread = threading.Thread(target=_loop, daemon=True)
    thread.start()
