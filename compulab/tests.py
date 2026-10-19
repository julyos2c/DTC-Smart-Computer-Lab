"""Cross-app regression tests for production readiness: authorization on
every URL, no server errors per role, PC-agent API secret checks, XSS
escaping of user text on the calendars, and media exposure rules.

Run with: python manage.py test
"""
import datetime
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from django.conf import settings
from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings
from django.urls import URLPattern, URLResolver, get_resolver, reverse
from django.utils import timezone

from labs.models import Lab
from scheduling.models import Session
from scheduling.utils import json_for_script

User = get_user_model()

# Pages meant to be reachable without logging in.
PUBLIC_URL_NAMES = {
    'login', 'password_reset', 'password_reset_done', 'password_reset_complete',
    'pc_login',
}


def _iter_patterns(patterns, prefix=''):
    for p in patterns:
        if isinstance(p, URLResolver):
            yield from _iter_patterns(p.url_patterns, prefix + str(p.pattern))
        elif isinstance(p, URLPattern):
            yield prefix + str(p.pattern), p.name


def param_free_urls():
    """(url, name) for every app route that takes no URL arguments."""
    urls = []
    for pattern, name in _iter_patterns(get_resolver().url_patterns):
        if '<' in pattern or '(?P' in pattern or pattern.startswith('admin/'):
            continue
        url = '/' + pattern.lstrip('^').rstrip('$').replace('\\', '')
        urls.append((url, name))
    return urls


class BaseFixture(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.lab = Lab.objects.create(
            name='Lab A', opening_time=datetime.time(7, 0), closing_time=datetime.time(21, 0),
        )
        cls.users = {}
        for role in ('admin', 'incharge', 'instructor'):
            cls.users[role] = User.objects.create_user(
                email=f'{role}.test@gmail.com', password='Str0ng-Test-Pass!',
                role=role, email_verified=True, first_name=role.title(), last_name='Tester',
                assigned_lab=cls.lab if role == 'incharge' else None,
            )


class AuthorizationTests(BaseFixture):
    def setUp(self):
        # Report every failing URL at once instead of stopping at the first.
        self.client.raise_request_exception = False

    def test_anonymous_users_cannot_reach_private_pages(self):
        leaks, errors = [], []
        for url, name in param_free_urls():
            if name in PUBLIC_URL_NAMES:
                continue
            response = self.client.get(url)
            if response.status_code == 200:
                leaks.append(f'{name} {url}')
            elif response.status_code >= 500:
                errors.append(f'{name} {url}')
        self.assertEqual(leaks, [], 'pages served to anonymous users')
        self.assertEqual(errors, [], 'server errors for anonymous users')

    def test_public_pages_load(self):
        for name in ('login', 'password_reset'):
            self.assertEqual(self.client.get(reverse(name)).status_code, 200, name)

    def test_no_server_errors_for_any_role(self):
        # Exports/agent endpoints may legitimately answer 4xx; nothing may 500.
        errors = []
        for role, user in self.users.items():
            self.client.force_login(user)
            for url, name in param_free_urls():
                if name == 'logout':
                    continue
                response = self.client.get(url)
                if response.status_code >= 500:
                    errors.append(f'{role}: {name} {url}')
            self.client.logout()
        self.assertEqual(errors, [])

    def test_instructor_is_blocked_from_admin_pages(self):
        self.client.force_login(self.users['instructor'])
        self.assertEqual(self.client.get(reverse('view_schedule')).status_code, 403)

    def test_login_and_logout(self):
        response = self.client.post(reverse('login'), {
            'username': 'admin.test@gmail.com', 'password': 'Str0ng-Test-Pass!',
        })
        self.assertEqual(response.status_code, 302)
        self.assertIn('_auth_user_id', self.client.session)
        self.client.post(reverse('logout'))
        self.assertNotIn('_auth_user_id', self.client.session)

    def test_wrong_password_is_rejected(self):
        self.client.post(reverse('login'), {'username': 'admin.test@gmail.com', 'password': 'wrong'})
        self.assertNotIn('_auth_user_id', self.client.session)


class PCAgentApiTests(BaseFixture):
    AGENT_ENDPOINTS = (
        'pc_agent_login_api', 'pc_agent_activity_api', 'pc_agent_end_session_api',
        'pc_agent_logout_api', 'manual_unlock_log_api',
    )

    def test_wrong_secret_is_rejected(self):
        for name in self.AGENT_ENDPOINTS:
            response = self.client.post(reverse(name), '{"secret": "nope"}', content_type='application/json')
            self.assertEqual(response.status_code, 403, name)
        response = self.client.get(reverse('pc_agent_info_api'), {'secret': 'nope'})
        self.assertEqual(response.status_code, 403)

    def test_correct_secret_from_unregistered_ip_is_handled(self):
        response = self.client.get(reverse('pc_agent_info_api'), {'secret': settings.PC_AGENT_SHARED_SECRET})
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()['ok'])


class CalendarEscapingTests(BaseFixture):
    PAYLOAD = '</script><img src=x onerror=alert(1)>'

    def setUp(self):
        Session.objects.create(
            lab=self.lab, instructor=self.users['instructor'], subject=self.PAYLOAD,
            requester_name=self.PAYLOAD, date=timezone.localdate(),
            start_time=datetime.time(9, 0), end_time=datetime.time(10, 0),
        )

    def test_json_for_script_escapes_markup(self):
        out = json_for_script({'t': self.PAYLOAD})
        self.assertNotIn('<', out)
        self.assertNotIn('>', out)

    def test_admin_calendar_does_not_emit_raw_payload(self):
        self.client.force_login(self.users['admin'])
        body = self.client.get(reverse('view_schedule')).content.decode()
        self.assertNotIn(self.PAYLOAD, body)

    def test_instructor_calendar_does_not_emit_raw_payload(self):
        self.client.force_login(self.users['instructor'])
        body = self.client.get(reverse('inst_schedule')).content.decode()
        self.assertNotIn(self.PAYLOAD, body)


class MediaExposureTests(TestCase):
    def setUp(self):
        self.media = Path(tempfile.mkdtemp())
        (self.media / 'avatars').mkdir()
        (self.media / 'avatars' / 'a.png').write_bytes(b'png')
        (self.media / 'activity_log_backups').mkdir()
        (self.media / 'activity_log_backups' / 'activity_log_2026-01-01.xlsx').write_bytes(b'xlsx')

    def tearDown(self):
        shutil.rmtree(self.media, ignore_errors=True)

    def test_avatars_served_but_activity_backups_are_not(self):
        with override_settings(MEDIA_ROOT=self.media):
            # urls.py captured MEDIA_ROOT at import; reload it for this root.
            import importlib
            import compulab.urls
            from django.urls import clear_url_caches
            importlib.reload(compulab.urls)
            clear_url_caches()
            try:
                self.assertEqual(self.client.get('/media/avatars/a.png').status_code, 200)
                self.assertEqual(
                    self.client.get('/media/activity_log_backups/activity_log_2026-01-01.xlsx').status_code, 404,
                )
            finally:
                importlib.reload(compulab.urls)
                clear_url_caches()


class ProductionSettingsTests(TestCase):
    def _import_settings(self, **env):
        base = {k: v for k, v in os.environ.items() if not k.startswith(('DJANGO_', 'PC_AGENT_'))}
        base.update(env)
        # python-dotenv never overrides variables that are already set, so
        # these values win over anything in a local .env file.
        return subprocess.run(
            [sys.executable, '-c', 'import compulab.settings as s; print(s.DEBUG)'],
            cwd=settings.BASE_DIR, env=base, capture_output=True, text=True,
        )

    def test_production_requires_secret_key(self):
        result = self._import_settings(DJANGO_DEBUG='False', DJANGO_SECRET_KEY='', PC_AGENT_SHARED_SECRET='x')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('DJANGO_SECRET_KEY', result.stderr)

    def test_production_requires_agent_secret(self):
        result = self._import_settings(DJANGO_DEBUG='False', DJANGO_SECRET_KEY='k' * 60, PC_AGENT_SHARED_SECRET='')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PC_AGENT_SHARED_SECRET', result.stderr)

    def test_production_settings_load(self):
        result = self._import_settings(DJANGO_DEBUG='False', DJANGO_SECRET_KEY='k' * 60, PC_AGENT_SHARED_SECRET='x')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'False')
