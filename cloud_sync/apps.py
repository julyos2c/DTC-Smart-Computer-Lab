from django.apps import AppConfig


class CloudSyncConfig(AppConfig):
    name = 'cloud_sync'
    default_auto_field = 'django.db.models.BigAutoField'

    def ready(self):
        # Sending is done by the CompuLab worker loop (system/worker.py ->
        # cloud_sync.sync.run_once), so it runs wherever the worker runs and
        # recovers with it. Here we only start recording changes, and only
        # when a cloud receiver is configured.
        from django.conf import settings
        if not getattr(settings, 'CLOUD_SYNC_ENABLED', False):
            return
        from cloud_sync import signals
        signals.connect(getattr(settings, 'CLOUD_SYNC_OBJECT_TYPES', ()))
