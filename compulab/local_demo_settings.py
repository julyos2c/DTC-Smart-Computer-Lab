"""Isolated local demo settings. Never use for a deployed installation."""
import os
from pathlib import Path
from compulab.settings import *  # noqa: F403

DEMO_ROLE = os.environ.get('COMPULAB_DEMO_ROLE', 'edge')
if DEMO_ROLE not in ('cloud', 'edge'):
    raise ValueError('Invalid demo role')
DEMO_DIR = BASE_DIR / '.local_remote_demo'
DEMO_DIR.mkdir(exist_ok=True)
DEBUG = True
SECRET_KEY = os.environ['COMPULAB_DEMO_SECRET']
DATABASES = {'default': {'ENGINE': 'django.db.backends.sqlite3', 'NAME': DEMO_DIR / (DEMO_ROLE + '.sqlite3')}}
ALLOWED_HOSTS = ['127.0.0.1', 'localhost', 'testserver']
CSRF_TRUSTED_ORIGINS = ['http://127.0.0.1:8000', 'http://127.0.0.1:8001']
SECURE_SSL_REDIRECT = False
SESSION_COOKIE_SECURE = False
CSRF_COOKIE_SECURE = False
# Different ports on the same host otherwise share the same login cookie.
SESSION_COOKIE_NAME = 'compulab_demo_' + DEMO_ROLE
CSRF_COOKIE_NAME = 'compulab_demo_csrf_' + DEMO_ROLE
SECURE_PROXY_SSL_HEADER = None
RUN_BACKGROUND_TASKS = False
EMAIL_BACKEND = 'django.core.mail.backends.locmem.EmailBackend'
SITE_URL = 'http://127.0.0.1:' + ('8001' if DEMO_ROLE == 'cloud' else '8000')
CLOUD_RECEIVER_ENABLED = DEMO_ROLE == 'cloud'
CLOUD_REMOTE_CONTROL_ENABLED = DEMO_ROLE == 'cloud'
CLOUD_RECEIVER_ALLOW_HTTP = True
import hashlib
CLOUD_RECEIVER_SITES = {'local-demo': hashlib.sha256(os.environ['COMPULAB_DEMO_KEY'].encode()).hexdigest()}
CLOUD_SERVER_URL = 'http://127.0.0.1:8001'
CLOUD_SYNC_SITE_ID = 'local-demo'
CLOUD_SYNC_API_KEY = os.environ['COMPULAB_DEMO_KEY']
CLOUD_SYNC_ENABLED = DEMO_ROLE == 'edge'
CLOUD_SYNC_OBJECT_TYPES = ('reservation', 'session')
EDGE_REMOTE_CONTROL_ENABLED = DEMO_ROLE == 'edge'
EDGE_REMOTE_CONTROL_ALLOW_LOCAL_HTTP = True
PC_AGENT_PORT = 5556
PC_AGENT_SHARED_SECRET = os.environ['COMPULAB_DEMO_AGENT_KEY']
PC_AGENT_REQUIRE_PER_PC_SECRET = False

CLOUD_RESERVATIONS_ENABLED = DEMO_ROLE == 'cloud'
EDGE_CLOUD_RESERVATIONS_ENABLED = DEMO_ROLE == 'edge'
CLOUD_RESERVATION_EDGE_ACTOR_EMAIL = 'localdemo@gmail.com'

# Read edited templates on each request during the local demo.
from copy import deepcopy
TEMPLATES = deepcopy(TEMPLATES)
for _backend in TEMPLATES:
    if _backend['BACKEND'] == 'django.template.backends.django.DjangoTemplates':
        _backend['APP_DIRS'] = False
        _backend.setdefault('OPTIONS', {})['loaders'] = [
            'django.template.loaders.filesystem.Loader',
            'django.template.loaders.app_directories.Loader',
        ]
