from django.db import models


class SystemStatus(models.Model):
    """One row per health probe (database, smtp, internet, cloud) plus the
    worker heartbeat. Written by the worker loop (system/worker.py), read by
    the footer status badge and /healthz/ready. `detail` never contains
    secrets."""
    KEY_CHOICES = [
        ('database', 'Database'),
        ('smtp', 'Email server (SMTP)'),
        ('internet', 'Internet'),
        ('cloud', 'Cloud sync receiver'),
        ('worker', 'Background worker'),
    ]

    key = models.CharField(max_length=20, choices=KEY_CHOICES, unique=True)
    # None = not applicable / not configured (e.g. no SMTP server set up).
    ok = models.BooleanField(null=True)
    # The state before the last change, so "restored" can be told apart from
    # "first check after start-up".
    previous_ok = models.BooleanField(null=True)
    detail = models.CharField(max_length=255, blank=True, default='')
    checked_at = models.DateTimeField(null=True, blank=True)
    last_ok_at = models.DateTimeField(null=True, blank=True)
    last_change_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        verbose_name = 'System status'
        verbose_name_plural = 'System status'

    def __str__(self):
        state = 'unknown' if self.ok is None else ('OK' if self.ok else 'DOWN')
        return f'{self.get_key_display()}: {state}'


class ScheduledJob(models.Model):
    """A unit of deferred work that must survive a server restart — e.g. the
    Override grant that runs ~30 s after the outgoing user's on-screen
    warning (it used to sleep on a thread and was lost on restart). Claimed
    with a status-preconditioned UPDATE so it runs exactly once even if two
    processes look at it."""
    KIND_CHOICES = [
        ('override_grant', 'Override: grant PC to new user'),
    ]
    STATUS_CHOICES = [
        ('pending', 'Pending'),
        ('running', 'Running'),
        ('done', 'Done'),
        ('failed', 'Failed'),
        ('cancelled', 'Cancelled'),
    ]

    kind = models.CharField(max_length=30, choices=KIND_CHOICES)
    payload = models.JSONField(default=dict, blank=True)
    run_at = models.DateTimeField(db_index=True)
    status = models.CharField(max_length=12, choices=STATUS_CHOICES, default='pending', db_index=True)
    attempts = models.PositiveSmallIntegerField(default=0)
    max_attempts = models.PositiveSmallIntegerField(default=3)
    last_error = models.CharField(max_length=255, blank=True, default='')
    started_at = models.DateTimeField(null=True, blank=True)
    finished_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['run_at']

    def __str__(self):
        return f'{self.get_kind_display()} @ {self.run_at:%Y-%m-%d %H:%M:%S} ({self.status})'
