"""Entry point for cPanel "Setup Python App" (Phusion Passenger).

Passenger imports `application` from this file. Settings and secrets come
from .env next to manage.py, exactly as for any other WSGI server.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'compulab.settings')

from compulab.wsgi import application  # noqa: E402,F401
