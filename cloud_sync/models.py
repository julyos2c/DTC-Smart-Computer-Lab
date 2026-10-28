"""One-way synchronization queue: the campus server (the only writable
copy) tells an optional cloud receiver about changes. See PROTOCOL.md for
the wire format, identifiers and the conflict policy."""
import logging

from django.conf import settings
from django.db import models
from django.db.models import F
from django.utils import timezone

logger = logging.getLogger(__name__)


class SyncQueue(models.Model):
    """
    Local outbox: one row per change that still needs to reach the cloud
    server. The edge server is always the source of truth — this table is
    just a to-do list of "things to tell the cloud about once we're online".

    Nothing reads this table to make decisions locally; it exists purely so
    the sync worker (see sync.py) knows what to send, and so nothing gets
    lost if the edge server restarts mid-sync (unsent rows stay pending, and
    rows left 'processing' by a crash go back to pending).
    """
    OBJECT_TYPES = [
        ('reservation', 'Reservation'),
        ('session', 'Session'),
        ('issue', 'Issue'),
        ('activity_log', 'PC Activity Log'),
        ('notification', 'Notification'),
        ('lab', 'Laboratory'),
        ('pc', 'PC Live Status'),
        ('inventory', 'Inventory Item'),
        ('maintenance_log', 'Maintenance Log'),
        ('equipment_issue', 'Equipment Issue'),
    ]
    OPERATIONS = [
        ('upsert', 'Created or changed'),
        ('delete', 'Deleted'),
    ]
    STATUS = [
        ('pending', 'Waiting to send'),
        ('processing', 'Sending'),
        ('synced', 'Synced'),
        ('failed', 'Failed (needs attention)'),
        ('conflict', 'Conflict (needs review)'),
        ('superseded', 'Replaced by a newer change'),
        ('resolved', 'Resolved (cloud copy kept)'),
    ]
    OPEN_STATUSES = ('pending', 'processing', 'failed', 'conflict')

    object_type = models.CharField(max_length=20, choices=OBJECT_TYPES)
    # The local primary key of the row this entry describes. The campus
    # server is authoritative, so (site, object_type, local_id) is the
    # record's stable identity on the cloud side too.
    local_id = models.PositiveIntegerField()
    # Stable "object_type:local_id"; every change to one record shares it.
    record_key = models.CharField(max_length=40, db_index=True, default='')
    # A stable, globally-unique id for this specific change, sent to the
    # cloud as the de-dupe (idempotency) key: re-sending it after a lost
    # reply must not apply it twice.
    edge_id = models.UUIDField(unique=True)
    operation = models.CharField(max_length=10, choices=OPERATIONS, default='upsert')
    # Version of the payload layout for this object_type (sync_payloads.py).
    schema_version = models.PositiveSmallIntegerField(default=1)

    # Full snapshot of the record at queue time, as plain JSON — the sync
    # worker sends this as-is, it never has to re-query the original model
    # (which may have changed again by the time sync actually runs).
    payload = models.JSONField()

    created_at = models.DateTimeField(auto_now_add=True)
    status = models.CharField(max_length=12, choices=STATUS, default='pending', db_index=True)
    # Kept in step with status == 'synced' (older code and reports use it).
    synced = models.BooleanField(default=False)
    synced_at = models.DateTimeField(null=True, blank=True)
    # Deliveries that reached the receiver (network failures don't count:
    # they pause the whole queue instead, see SyncState).
    attempts = models.PositiveIntegerField(default=0)
    next_attempt_at = models.DateTimeField(null=True, blank=True)
    last_error = models.TextField(blank=True, default='')
    claimed_at = models.DateTimeField(null=True, blank=True)
    claim_token = models.CharField(max_length=32, blank=True, default='')
    # An Admin chose "send ours again" for a conflict: the receiver is asked
    # to overwrite its copy.
    force = models.BooleanField(default=False)
    # What the receiver said about a conflict or rejection (no secrets).
    remote_detail = models.JSONField(default=dict, blank=True)
    resolved_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.SET_NULL, null=True, blank=True, related_name='+',
    )
    resolved_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        indexes = [
            models.Index(fields=['synced', 'created_at']),
            models.Index(fields=['status', 'id']),
        ]

    def __str__(self):
        return f'{self.object_type}:{self.local_id} ({self.status})'

    def mark_synced(self, now=None):
        self.status = 'synced'
        self.synced = True
        self.synced_at = now or timezone.now()
        self.last_error = ''


class SyncState(models.Model):
    """Single row (pk=1) describing the sync connection as a whole: when it
    last worked, why it is paused, and the lease that makes sure only one
    process sends at a time (so rows always go out in order)."""
    PAUSE_REASONS = [
        ('', 'Not paused'),
        ('auth', 'The cloud server refused the API key'),
        ('incompatible', 'No compatible sync receiver at the configured address'),
        ('admin', 'Paused by an Admin'),
    ]

    lease_owner = models.CharField(max_length=32, blank=True, default='')
    lease_until = models.DateTimeField(null=True, blank=True)
    last_attempt_at = models.DateTimeField(null=True, blank=True)
    last_success_at = models.DateTimeField(null=True, blank=True)
    last_pc_snapshot_at = models.DateTimeField(null=True, blank=True)
    last_error = models.CharField(max_length=255, blank=True, default='')
    last_error_at = models.DateTimeField(null=True, blank=True)
    consecutive_failures = models.PositiveIntegerField(default=0)
    next_attempt_at = models.DateTimeField(null=True, blank=True)
    batch_size = models.PositiveSmallIntegerField(default=50)
    paused_reason = models.CharField(max_length=20, choices=PAUSE_REASONS, blank=True, default='')
    paused_detail = models.CharField(max_length=255, blank=True, default='')
    # Hash of the configured URL + key (never the key itself): a pause for a
    # bad key or address is lifted automatically once the settings change.
    config_fingerprint = models.CharField(max_length=64, blank=True, default='')
    enqueue_failures = models.PositiveIntegerField(default=0)
    last_enqueue_failure_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        verbose_name = 'Sync state'
        verbose_name_plural = 'Sync state'

    @classmethod
    def get(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj


def enabled_object_types():
    return set(getattr(settings, 'CLOUD_SYNC_OBJECT_TYPES', ()))


def enqueue(object_type, local_id, payload, operation='upsert'):
    """
    Record one change for the cloud. Called from the model signals in
    cloud_sync/signals.py (after the transaction commits). Never raises and
    never blocks on the network.

    Does nothing unless cloud sync is configured (settings.CLOUD_SYNC_ENABLED)
    and this object type is selected (CLOUD_SYNC_OBJECT_TYPES), so a
    standalone server doesn't accumulate rows nothing will ever send. Once
    sync is configured, `manage.py cloud_sync_backfill` queues a snapshot of
    records that changed before.
    """
    import uuid
    if not getattr(settings, 'CLOUD_SYNC_ENABLED', False) or object_type not in enabled_object_types():
        return None
    from cloud_sync.sync_payloads import SCHEMA_VERSIONS
    try:
        return SyncQueue.objects.create(
            object_type=object_type,
            local_id=local_id,
            record_key=f'{object_type}:{local_id}',
            edge_id=uuid.uuid4(),
            operation=operation,
            schema_version=SCHEMA_VERSIONS.get(object_type, 1),
            payload=payload,
        )
    except Exception:  # noqa: BLE001
        # Queueing must never break the actual operation (the reservation
        # still got approved, the log still got written). It is not silent:
        # the failure is logged and counted on the System status page, and
        # cloud_sync_backfill re-queues the record from the local database.
        logger.exception('Could not queue %s #%s for cloud sync', object_type, local_id)
        try:
            SyncState.get()
            SyncState.objects.filter(pk=1).update(
                enqueue_failures=F('enqueue_failures') + 1, last_enqueue_failure_at=timezone.now(),
            )
        except Exception:  # noqa: BLE001
            pass
        return None
