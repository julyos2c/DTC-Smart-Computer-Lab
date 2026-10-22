import signal
import threading

from django.conf import settings
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = (
        'Runs every CompuLab background task in this one process: PC status '
        'checks, stale-session release and after-hours locking, session and '
        'roster-code reminders, the nightly activity-log wipe, the email '
        'outbox, durable jobs (Override grants), optional cloud sync and the '
        'connectivity monitor. '
        'Install it as the "CompuLab Worker" service and run the web service '
        'with COMPULAB_BACKGROUND_TASKS=False so the loops never run twice.'
    )

    def handle(self, *args, **options):
        from labs.network import start_background_status_checker
        from labs.maintenance import start_daily_activity_log_wipe
        from notifications.reminders import start_background_session_reminder_checker
        from system.worker import run_forever

        if getattr(settings, 'RUN_BACKGROUND_TASKS', True):
            self.stderr.write(self.style.WARNING(
                'COMPULAB_BACKGROUND_TASKS is True: if the web server is also running '
                'with that setting, its in-process loops run alongside this worker. '
                'Set COMPULAB_BACKGROUND_TASKS=False in .env for the web service.'
            ))

        start_background_status_checker()
        start_daily_activity_log_wipe()
        start_background_session_reminder_checker()
        # Cloud sync (when configured) runs inside run_forever's loop.

        stop = threading.Event()

        def _stop(*_):
            stop.set()

        for sig in (signal.SIGINT, signal.SIGTERM, getattr(signal, 'SIGBREAK', None)):
            if sig is not None:
                try:
                    signal.signal(sig, _stop)
                except (ValueError, OSError):
                    pass

        self.stdout.write(self.style.SUCCESS('CompuLab worker running. Press Ctrl+C to stop.'))
        run_forever(stop_event=stop, mode='service')
