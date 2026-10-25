from django.apps import AppConfig


class CloudReceiverConfig(AppConfig):
    """The cloud side of cloud sync (cloud_sync/PROTOCOL.md): stores the
    records campus servers publish. Off unless CLOUD_RECEIVER_ENABLED."""
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'cloud_receiver'
    verbose_name = 'Cloud receiver (replicas from campus servers)'
