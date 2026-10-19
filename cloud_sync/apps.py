from django.apps import AppConfig


class CloudSyncConfig(AppConfig):
    name = 'cloud_sync'
    default_auto_field = 'django.db.models.BigAutoField'

    def ready(self):
        from compulab.background import should_start_background_tasks
        if not should_start_background_tasks():
            return

        from cloud_sync.sync import start_cloud_sync_worker
        start_cloud_sync_worker()
