import uuid
from datetime import timedelta
from django.db import models
from django.utils import timezone


def command_expiry():
    return timezone.now() + timedelta(minutes=2)


class RemoteCommand(models.Model):
    ACTIONS = [(x, x.title()) for x in ('lock', 'unlock', 'shutdown', 'restart')]
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    site_id = models.CharField(max_length=64)
    pc_pk = models.PositiveBigIntegerField(help_text='Database primary key of the PC on the campus server.')
    action = models.CharField(max_length=10, choices=ACTIONS)
    requested_by = models.CharField(max_length=254, editable=False)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField(default=command_expiry)
    status = models.CharField(max_length=16, default='pending', editable=False)
    detail = models.TextField(blank=True, editable=False)
    completed_at = models.DateTimeField(null=True, editable=False)

    class Meta:
        ordering = ['-created_at']


class CommandReceipt(models.Model):
    # Stored on the edge before touching the network. Never automatically replay
    # an uncertain command after a crash: the agent API has no idempotency key.
    id = models.UUIDField(primary_key=True, editable=False)
    site_id = models.CharField(max_length=64)
    pc_pk = models.PositiveBigIntegerField()
    action = models.CharField(max_length=10)
    status = models.CharField(max_length=16, default='executing')
    detail = models.TextField(default='Execution interrupted or in progress; inspect the PC before issuing another command.')
    reported = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
