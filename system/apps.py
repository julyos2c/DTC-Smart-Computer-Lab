from django.apps import AppConfig


class SystemConfig(AppConfig):
    """Server-side operations: the background worker loop (email outbox,
    durable jobs, connectivity monitor, heartbeat), health endpoints and the
    status badge shown in the footer."""
    name = 'system'
    verbose_name = 'System status and background worker'
    default_auto_field = 'django.db.models.BigAutoField'

    def ready(self):
        # Same gate as the other in-process loops (see compulab.background):
        # when the separate `manage.py run_worker` service is installed, the
        # web service runs with COMPULAB_BACKGROUND_TASKS=False and this
        # does nothing.
        from compulab.background import should_start_background_tasks
        if not should_start_background_tasks():
            return
        from system.worker import start_in_process_worker
        start_in_process_worker()
