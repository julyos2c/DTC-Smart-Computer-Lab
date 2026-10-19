"""
Background housekeeping tasks — currently just the periodic wipe of
PCActivityLog, which can otherwise grow forever since a row is written
every few seconds for every unlocked PC (see agent_config.json
'activity_report_interval_seconds'). Runs daily by default, or weekly if
PC_ACTIVITY_LOG_WIPE_WEEKDAY is set — see start_daily_activity_log_wipe().

Follows the same pattern as labs.network.start_background_status_checker:
a single daemon thread started once from LabsConfig.ready().
"""
import threading
import time
from datetime import timedelta

from django.utils import timezone


def _backup_then_wipe():
    """Saves every current PCActivityLog row to an .xlsx file under
    media/activity_log_backups/, then deletes all rows. The backup means
    the daily wipe isn't a hard data loss — Yan (or anyone with server
    file access) can still pull up a past day's log from that folder.

    Also prunes backup files older than PC_ACTIVITY_LOG_BACKUP_KEEP_DAYS,
    so the backup folder itself doesn't grow forever."""
    from django.conf import settings
    from labs.models import PCActivityLog

    logs = PCActivityLog.objects.select_related('pc', 'pc__lab', 'student', 'session').order_by('captured_at')
    count = logs.count()

    if count:
        from openpyxl import Workbook

        backup_dir = settings.MEDIA_ROOT / 'activity_log_backups'
        backup_dir.mkdir(parents=True, exist_ok=True)

        wb = Workbook()
        ws = wb.active
        ws.title = 'Activity Log'
        ws.append(['Time', 'PC', 'Student', 'Session', 'Active window title'])
        for log in logs.iterator():
            ws.append([
                timezone.localtime(log.captured_at).strftime('%Y-%m-%d %H:%M:%S'),
                f'{log.pc.lab.name} — {log.pc.pc_id}',
                (log.student.display_name) if log.student else '—',
                f'{log.session.requester_name} ({log.session.date} {log.session.start_time}-{log.session.end_time})' if log.session else '—',
                log.window_title or '—',
            ])
        filename = f'activity_log_{timezone.localtime().strftime("%Y-%m-%d")}.xlsx'
        wb.save(backup_dir / filename)

        # prune old backups
        keep_days = getattr(settings, 'PC_ACTIVITY_LOG_BACKUP_KEEP_DAYS', 30)
        cutoff = timezone.localtime() - timedelta(days=keep_days)
        for f in backup_dir.glob('activity_log_*.xlsx'):
            if f.stat().st_mtime < cutoff.timestamp():
                f.unlink(missing_ok=True)

    PCActivityLog.objects.all().delete()


def _seconds_until(hour=0, minute=0, weekday=None):
    """Seconds from right now until the next occurrence of hour:minute, in
    the local (settings.TIME_ZONE) clock.

    If `weekday` is None, targets the next daily occurrence (today if that
    time hasn't passed yet, otherwise tomorrow) — the original once-a-day
    behavior.

    If `weekday` is given (0=Monday ... 6=Sunday, matching
    date.weekday()), targets the next occurrence of that specific weekday
    at hour:minute — i.e. once a week — rolling forward a full 7 days if
    today already matches but the time has passed."""
    now = timezone.localtime()
    target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if weekday is None:
        if target <= now:
            target += timedelta(days=1)
        return (target - now).total_seconds()

    days_ahead = (weekday - now.weekday()) % 7
    target += timedelta(days=days_ahead)
    if target <= now:
        target += timedelta(days=7)
    return (target - now).total_seconds()


_wiper_started = False  # guards against starting the loop twice in one process


def start_daily_activity_log_wipe():
    """
    Starts a daemon thread that deletes ALL PCActivityLog rows on a
    schedule set by settings.PC_ACTIVITY_LOG_WIPE_HOUR (default: 0 =
    midnight, Asia/Manila since that's TIME_ZONE) and, optionally,
    settings.PC_ACTIVITY_LOG_WIPE_WEEKDAY.

    - PC_ACTIVITY_LOG_WIPE_WEEKDAY unset/None (default): wipes every day
      at PC_ACTIVITY_LOG_WIPE_HOUR — the original behavior.
    - PC_ACTIVITY_LOG_WIPE_WEEKDAY set to 0-6 (0=Monday ... 6=Sunday):
      wipes once a week, on that weekday, at PC_ACTIVITY_LOG_WIPE_HOUR.

    Either way this is a full wipe, not a rolling retention — every row
    is deleted at wipe time, no history is kept past it (aside from the
    .xlsx backup — see _backup_then_wipe).

    Safe to call more than once: only the first call actually starts a
    thread. Meant to be called once from labs.apps.LabsConfig.ready().
    """
    global _wiper_started
    if _wiper_started:
        return
    _wiper_started = True

    from django.conf import settings
    hour = getattr(settings, 'PC_ACTIVITY_LOG_WIPE_HOUR', 0)
    weekday = getattr(settings, 'PC_ACTIVITY_LOG_WIPE_WEEKDAY', None)

    def _loop():
        # Import here (not at module load time) so this only touches the DB
        # once Django is fully set up.
        from django.db import connections

        while True:
            time.sleep(_seconds_until(hour, weekday=weekday))
            try:
                _backup_then_wipe()
            except Exception:
                # A transient DB hiccup shouldn't kill the background loop —
                # just try again at the next scheduled time.
                pass
            finally:
                # Each Django DB connection is only meant to be used by the
                # thread/request that opened it; close it out here so this
                # long-lived thread doesn't hold a stale/broken connection.
                connections.close_all()

    thread = threading.Thread(target=_loop, name='pc-activity-log-daily-wipe', daemon=True)
    thread.start()
