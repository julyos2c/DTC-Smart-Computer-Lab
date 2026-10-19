from django.core.management.base import BaseCommand

from labs.models import PCActivityLog


class Command(BaseCommand):
    help = (
        "Backs up ALL PCActivityLog rows to an .xlsx file under "
        "media/activity_log_backups/, then deletes them all (full wipe, "
        "no rolling retention). This already runs automatically on the "
        "schedule set by PC_ACTIVITY_LOG_WIPE_HOUR / "
        "PC_ACTIVITY_LOG_WIPE_WEEKDAY (daily by default, or weekly if "
        "WIPE_WEEKDAY is set) via the background thread started in "
        "LabsConfig.ready() — this command is for manual runs (e.g. "
        "testing) or as a Windows Task Scheduler backup in case the "
        "server was down at the scheduled wipe time."
    )

    def handle(self, *args, **options):
        from labs.maintenance import _backup_then_wipe

        count = PCActivityLog.objects.count()
        _backup_then_wipe()
        self.stdout.write(self.style.SUCCESS(
            f"Backed up and deleted {count} PCActivityLog row(s)."
        ))
