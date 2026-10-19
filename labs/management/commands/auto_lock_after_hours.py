from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = (
        "Locks every PC still logged in past its lab's closing time. This "
        "already runs automatically every PC_STATUS_CHECK_INTERVAL_SECONDS "
        "(default 60s) via the background thread started in "
        "LabsConfig.ready() (see labs.network.start_background_status_checker) "
        "— this command is for manual runs (e.g. testing) or as a cron/"
        "Windows Task Scheduler backup in case the server was down.\n\n"
        "Only touches normal, reservation-based logins — PCs whose current "
        "session started via Override Check-In or a Guest walk-in (Manual "
        "Unlock) are deliberately left alone. See "
        "labs.network.auto_lock_after_hours for the full explanation."
    )

    def handle(self, *args, **options):
        from labs.network import auto_lock_after_hours

        locked = auto_lock_after_hours()
        self.stdout.write(self.style.SUCCESS(f'Locked {locked} PC(s) past their lab\'s closing time.'))
