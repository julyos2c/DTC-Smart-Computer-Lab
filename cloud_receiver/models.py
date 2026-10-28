"""Cloud copies of campus records (cloud_sync/PROTOCOL.md section 8).

The campus server is the only place where records are created or changed;
these rows are replicas. A replica edited here (Django admin) is marked
cloud_modified_at, and the next change from the campus server for that
record is answered 'conflict' instead of silently overwriting the edit
(no silent last-write-wins)."""
from django.db import models


class ReplicaRecord(models.Model):
    """The newest snapshot of one campus record, keyed by its stable identity
    (site_id, object_type, local_id)."""
    site_id = models.CharField(max_length=64)
    object_type = models.CharField(max_length=20)
    local_id = models.PositiveBigIntegerField()
    schema_version = models.PositiveSmallIntegerField(default=1)
    # The full snapshot as sent (complete records, never partial changes).
    payload = models.JSONField(default=dict, blank=True)
    # operation 'delete': kept as a tombstone, payload emptied.
    deleted = models.BooleanField(default=False)
    # Highest campus sequence applied: anything lower or equal arriving later
    # is a late or repeated delivery and changes nothing.
    last_sequence = models.PositiveBigIntegerField(default=0)
    last_edge_id = models.UUIDField(null=True, blank=True)
    applied_at = models.DateTimeField(null=True, blank=True)
    # Set when someone edits this copy on the cloud side; cleared when a
    # campus change is applied (forced or not).
    cloud_modified_at = models.DateTimeField(null=True, blank=True)
    cloud_modified_by = models.CharField(max_length=150, blank=True, default='')

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=['site_id', 'object_type', 'local_id'], name='replica_record_identity'),
        ]
        indexes = [models.Index(fields=['site_id', 'object_type'])]
        ordering = ['site_id', 'object_type', 'local_id']

    def __str__(self):
        return f'{self.site_id}/{self.object_type}:{self.local_id}{" (deleted)" if self.deleted else ""}'


class AppliedChange(models.Model):
    """Every change (edge_id) that was applied: the idempotency record. A
    repeated edge_id is answered 'duplicate' and applies nothing again.
    Conflicting or rejected changes are not stored, so the campus server
    can send the same change again (e.g. forced after an Admin's decision)."""
    edge_id = models.UUIDField(unique=True)
    site_id = models.CharField(max_length=64)
    record = models.ForeignKey(ReplicaRecord, on_delete=models.CASCADE, related_name='changes')
    sequence = models.PositiveBigIntegerField()
    operation = models.CharField(max_length=10)
    forced = models.BooleanField(default=False)
    applied_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-applied_at']

    def __str__(self):
        return f'{self.edge_id} -> {self.record}'

from .command_models import RemoteCommand, CommandReceipt  # noqa: F401

from .reservation_models import ReservationChange, ReservationReceipt  # noqa: F401

from .inventory_models import InventoryChange, InventoryReceipt  # noqa: F401,E402
