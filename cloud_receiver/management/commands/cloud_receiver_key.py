"""Makes a new API key for one campus server and prints the two .env lines.

    python manage.py cloud_receiver_key --site dtc-main

The key is shown once, here, and stored nowhere: the cloud server keeps only
its SHA-256 (CLOUD_RECEIVER_SITES), the campus server the key itself
(CLOUD_SYNC_API_KEY). Run it where nobody else can see the screen."""
import re
import secrets

from django.core.management.base import BaseCommand, CommandError

from cloud_receiver.receiver import key_hash


class Command(BaseCommand):
    help = "Create an API key for a campus server's cloud sync and print the .env lines for both sides."

    def add_arguments(self, parser):
        parser.add_argument('--site', default='dtc-main', help="The campus server's CLOUD_SYNC_SITE_ID (default dtc-main).")

    def handle(self, *args, **options):
        site = options['site'].strip()
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', site):
            raise CommandError('The site id may only contain letters, digits, ".", "_" and "-" (at most 64).')
        key = secrets.token_urlsafe(32)
        self.stdout.write('Cloud server .env (add the site to CLOUD_RECEIVER_SITES, comma separated):')
        self.stdout.write('  CLOUD_RECEIVER_ENABLED=True')
        self.stdout.write(f'  CLOUD_RECEIVER_SITES={site}:{key_hash(key)}')
        self.stdout.write('Campus server .env (then restart its CompuLab services):')
        self.stdout.write('  CLOUD_SERVER_URL=https://<the cloud server address>')
        self.stdout.write(f'  CLOUD_SYNC_SITE_ID={site}')
        self.stdout.write(f'  CLOUD_SYNC_API_KEY={key}')
        self.stdout.write('The key is not stored anywhere else: copy it now.')
