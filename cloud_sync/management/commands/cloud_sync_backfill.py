import datetime

from django.apps import apps
from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

from cloud_sync import sync_payloads
from cloud_sync.models import enqueue


class Command(BaseCommand):
    help = (
        'Queues a current snapshot of existing records for cloud sync: use it once '
        'after configuring CLOUD_SERVER_URL / CLOUD_SYNC_API_KEY, or after changes '
        'made outside the app (bulk updates, a restored backup). The receiver '
        'applies snapshots idempotently, so running it twice is harmless. Shows '
        'the counts and changes nothing unless --yes is given.'
    )

    def add_arguments(self, parser):
        parser.add_argument('--types', default='', help='Comma-separated object types (default: CLOUD_SYNC_OBJECT_TYPES).')
        parser.add_argument('--days', type=int, default=0,
                            help='Only records created in the last N days (0 = all; ignored for types without a creation date).')
        parser.add_argument('--yes', action='store_true', help='Actually queue the snapshots.')

    def handle(self, *args, **options):
        if not getattr(settings, 'CLOUD_SYNC_ENABLED', False):
            raise CommandError('Cloud sync is not configured (CLOUD_SERVER_URL and CLOUD_SYNC_API_KEY in .env). Nothing to do.')
        enabled = set(getattr(settings, 'CLOUD_SYNC_OBJECT_TYPES', ()))
        types = [t.strip() for t in options['types'].split(',') if t.strip()] or sorted(enabled)
        unknown = [t for t in types if t not in sync_payloads.MODELS]
        if unknown:
            raise CommandError(f'Unknown object type(s): {", ".join(unknown)}')
        skipped = [t for t in types if t not in enabled]
        if skipped:
            raise CommandError(f'Not in CLOUD_SYNC_OBJECT_TYPES: {", ".join(skipped)}')

        since = timezone.now() - datetime.timedelta(days=options['days']) if options['days'] else None
        for object_type in types:
            model = apps.get_model(sync_payloads.MODELS[object_type])
            qs = model._default_manager.all().order_by('pk')
            date_field = 'captured_at' if object_type == 'activity_log' else 'created_at'
            if since is not None and any(f.name == date_field for f in model._meta.fields):
                qs = qs.filter(**{f'{date_field}__gte': since})
            count = qs.count()
            if not options['yes']:
                self.stdout.write(f'{object_type}: {count} record(s) would be queued.')
                continue
            queued = 0
            for obj in qs.iterator(chunk_size=500):
                if enqueue(object_type, obj.pk, sync_payloads.snapshot(object_type, obj)):
                    queued += 1
            self.stdout.write(self.style.SUCCESS(f'{object_type}: queued {queued} of {count}.'))
        if not options['yes']:
            self.stdout.write('Re-run with --yes to queue them.')
