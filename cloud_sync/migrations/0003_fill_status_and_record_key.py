"""Give rows queued before 0002 their new status and record_key.

Rows already marked synced become 'synced'; everything else stays
'pending' (the default from 0002). Nothing is deleted. Reversing this
migration changes nothing (0002's reversal drops the columns)."""
from django.db import migrations
from django.db.models import F, Value
from django.db.models.functions import Cast, Concat
from django.db.models import CharField


def forwards(apps, schema_editor):
    SyncQueue = apps.get_model('cloud_sync', 'SyncQueue')
    SyncQueue.objects.filter(synced=True).update(status='synced')
    SyncQueue.objects.filter(record_key='').update(
        record_key=Concat(F('object_type'), Value(':'), Cast(F('local_id'), output_field=CharField())),
    )


class Migration(migrations.Migration):

    dependencies = [
        ('cloud_sync', '0002_syncstate_syncqueue_claim_token_syncqueue_claimed_at_and_more'),
    ]

    operations = [
        migrations.RunPython(forwards, migrations.RunPython.noop),
    ]
