"""Cloud intents and edge transaction receipts for reservation changes."""
import uuid
from datetime import timedelta
from django.db import models
from django.utils import timezone


def reservation_expiry():
    return timezone.now() + timedelta(hours=24)


class ReservationChange(models.Model):
    ACTIONS = [(x, x.title()) for x in ('create', 'update', 'approve', 'cancel')]
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    site_id = models.CharField(max_length=64)
    action = models.CharField(max_length=10, choices=ACTIONS)
    target_id = models.PositiveBigIntegerField(null=True, blank=True, editable=False)
    base_revision = models.CharField(max_length=64, blank=True, editable=False)
    payload = models.JSONField(default=dict, editable=False)
    requested_by = models.CharField(max_length=254, editable=False)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField(default=reservation_expiry)
    status = models.CharField(max_length=12, default='pending', editable=False)
    result = models.JSONField(default=dict, editable=False)
    completed_at = models.DateTimeField(null=True, editable=False)

    class Meta:
        ordering = ['-created_at']


class ReservationReceipt(models.Model):
    id = models.UUIDField(primary_key=True, editable=False)
    site_id = models.CharField(max_length=64)
    status = models.CharField(max_length=12)
    result = models.JSONField(default=dict)
    reported = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
