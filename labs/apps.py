from django.apps import AppConfig


class LabsConfig(AppConfig):
    name = 'labs'

    def ready(self):
        # See compulab.background for when the loops run (only once per real
        # server process, never for migrate/test/collectstatic).
        from compulab.background import should_start_background_tasks
        if not should_start_background_tasks():
            return

        from labs.network import start_background_status_checker
        from labs.maintenance import start_daily_activity_log_wipe
        start_background_status_checker()
        start_daily_activity_log_wipe()
