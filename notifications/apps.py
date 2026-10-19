from django.apps import AppConfig


class NotificationsConfig(AppConfig):
    name = 'notifications'

    def ready(self):
        # Same gate as labs.apps.LabsConfig.ready() — see compulab.background.
        from compulab.background import should_start_background_tasks
        if not should_start_background_tasks():
            return

        from notifications.reminders import start_background_session_reminder_checker
        start_background_session_reminder_checker()
