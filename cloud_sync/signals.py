"""Queue a cloud-sync row whenever a synced model is saved or deleted.

Connected from CloudSyncConfig.ready() only when cloud sync is configured,
and only for the object types in CLOUD_SYNC_OBJECT_TYPES. The row is
written after the surrounding transaction commits, so a change that is
rolled back is never published.

Not covered: QuerySet.update() calls (Django sends no signal for them).
`manage.py cloud_sync_backfill` re-queues current snapshots, which the
receiver applies idempotently (PROTOCOL.md)."""
from django.apps import apps
from django.db import transaction
from django.db.models.signals import post_delete, post_save

from cloud_sync import sync_payloads


def _queue_upsert(object_type, model, pk):
    from cloud_sync.models import enqueue
    instance = model._default_manager.filter(pk=pk).first()
    if instance is None:
        return  # deleted again before the commit; the delete signal covers it
    enqueue(object_type, pk, sync_payloads.snapshot(object_type, instance))


def _on_save(sender, instance, created, raw=False, **kwargs):
    if raw:
        return  # loaddata
    object_type = sync_payloads.object_type_for(sender)
    if object_type == 'notification' and not created:
        return  # only new notifications are published, not read/pin toggles
    pk = instance.pk
    transaction.on_commit(lambda: _queue_upsert(object_type, sender, pk))


def _on_delete(sender, instance, **kwargs):
    from cloud_sync.models import enqueue
    object_type = sync_payloads.object_type_for(sender)
    pk = instance.pk
    transaction.on_commit(lambda: enqueue(object_type, pk, {'deleted': True}, operation='delete'))


def connect(object_types):
    for object_type in object_types:
        label = sync_payloads.MODELS.get(object_type)
        if not label:
            continue
        model = apps.get_model(label)
        uid = f'cloud_sync:{object_type}'
        post_save.connect(_on_save, sender=model, dispatch_uid=uid + ':save', weak=False)
        post_delete.connect(_on_delete, sender=model, dispatch_uid=uid + ':delete', weak=False)
