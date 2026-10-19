import os
import sys


def should_start_background_tasks():
    """Shared gate for the background loops started from AppConfig.ready()
    (PC status checker, activity-log wipe, session reminders, cloud sync).

    - Off entirely when settings.RUN_BACKGROUND_TASKS is False
      (COMPULAB_BACKGROUND_TASKS=False in .env).
    - Under `runserver`, Django's autoreloader launches a parent "watcher"
      process plus a child process that actually serves requests — only the
      child has RUN_MAIN=true, so only it starts the loops.
    - Any other manage.py command (migrate, test, collectstatic, shell, ...)
      is short-lived and must not start them.
    - Anything else (waitress, gunicorn, Passenger importing wsgi.py) is a
      real server process and starts them normally.
    """
    from django.conf import settings

    if not getattr(settings, 'RUN_BACKGROUND_TASKS', True):
        return False
    is_manage_py = bool(sys.argv) and os.path.basename(sys.argv[0]) in ('manage.py', 'django-admin')
    if not is_manage_py:
        return True
    if len(sys.argv) > 1 and sys.argv[1] == 'runserver':
        return os.environ.get('RUN_MAIN') == 'true' or '--noreload' in sys.argv
    return False
