"""Cloud inventory edit requests; campus owns all authoritative records."""
import uuid
from datetime import timedelta
from django.db import models
from django.utils import timezone


def inventory_expiry():
    return timezone.now() + timedelta(hours=24)


class InventoryChange(models.Model):
    OBJECT_TYPES = [('inventory', 'Equipment inventory'), ('pc', 'PC registration')]
    object_type = models.CharField(max_length=20, choices=OBJECT_TYPES, default='inventory')
    ACTIONS = [('create', 'Create'), ('update', 'Update'), ('delete', 'Delete')]
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    site_id = models.CharField(max_length=64)
    action = models.CharField(max_length=10, choices=ACTIONS)
    target_id = models.PositiveBigIntegerField(null=True, blank=True, editable=False)
    base_revision = models.CharField(max_length=64, blank=True, editable=False)
    payload = models.JSONField(default=dict, editable=False)
    requested_by = models.CharField(max_length=254, editable=False)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField(default=inventory_expiry)
    status = models.CharField(max_length=12, default='pending', editable=False)
    result = models.JSONField(default=dict, editable=False)
    completed_at = models.DateTimeField(null=True, editable=False)

    class Meta:
        ordering = ['-created_at']


class InventoryReceipt(models.Model):
    id = models.UUIDField(primary_key=True, editable=False)
    site_id = models.CharField(max_length=64)
    status = models.CharField(max_length=12)
    result = models.JSONField(default=dict)
    reported = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
