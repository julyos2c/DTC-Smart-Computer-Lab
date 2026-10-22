from django.conf import settings
from django.core.management.base import BaseCommand

from cloud_sync.models import SyncQueue


class Command(BaseCommand):
    help = (
        'Deletes cloud-sync queue rows that need nothing more. With cloud sync on, '
        'only rows that are synced, superseded by a newer change, or resolved are '
        'removed (waiting, failed and conflict rows are kept). With cloud sync off, '
        'every row is a leftover nothing will ever send. Shows the counts and '
        'changes nothing unless --yes is given.'
    )

    def add_arguments(self, parser):
        parser.add_argument('--yes', action='store_true', help='Actually delete the rows.')

    def handle(self, *args, **options):
        enabled = getattr(settings, 'CLOUD_SYNC_ENABLED', False)
        if enabled:
            rows = SyncQueue.objects.filter(status__in=('synced', 'superseded', 'resolved'))
            scope = 'finished rows (synced, superseded or resolved)'
        else:
            rows = SyncQueue.objects.all()
            scope = 'rows (cloud sync is off)'
        count = rows.count()
        if not options['yes']:
            self.stdout.write(f'{count} {scope} would be deleted. Re-run with --yes to delete them.')
            return
        rows.delete()
        self.stdout.write(self.style.SUCCESS(f'Deleted {count} {scope}.'))
