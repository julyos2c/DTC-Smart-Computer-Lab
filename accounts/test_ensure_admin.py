"""The installer's first-Administrator step (accounts/management/commands/ensure_admin.py)."""
import io
import os
from unittest import mock

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import TestCase

User = get_user_model()
GOOD_PASSWORD = 'Lab-Admin-Example-2026!'


def run(*args, password=None):
    """(exit code, last RESULT line) of ensure_admin."""
    env = {} if password is None else {'COMPULAB_ADMIN_PASSWORD': password}
    out = io.StringIO()
    code = 0
    with mock.patch.dict(os.environ, env, clear=False):
        if password is None:
            os.environ.pop('COMPULAB_ADMIN_PASSWORD', None)
        try:
            call_command('ensure_admin', *args, stdout=out)
        except SystemExit as e:
            code = e.code
    lines = [l for l in out.getvalue().splitlines() if l.startswith('RESULT: ')]
    return code, (lines[-1] if lines else '')


class EnsureAdminTests(TestCase):
    def test_check_reports_missing_admin(self):
        code, line = run('--check')
        self.assertEqual(code, 3)
        self.assertIn('NO_ADMIN', line)

    def test_creates_a_working_administrator(self):
        code, line = run('--email', 'lab.admin.example@gmail.com', password=GOOD_PASSWORD)
        self.assertEqual(code, 0, line)
        self.assertIn('CREATED', line)
        user = User.objects.get(email='lab.admin.example@gmail.com')
        self.assertTrue(user.is_superuser and user.is_staff and user.is_active)
        self.assertEqual(user.role, 'admin')
        self.assertTrue(user.check_password(GOOD_PASSWORD))
        self.assertTrue(self.client.login(email='lab.admin.example@gmail.com', password=GOOD_PASSWORD))
        self.assertEqual(run('--check')[0], 0)

    def test_output_never_contains_the_password(self):
        out = io.StringIO()
        with mock.patch.dict(os.environ, {'COMPULAB_ADMIN_PASSWORD': GOOD_PASSWORD}):
            call_command('ensure_admin', '--email', 'quiet.admin@gmail.com', stdout=out)
        self.assertNotIn(GOOD_PASSWORD, out.getvalue())

    def test_non_gmail_address_is_refused_with_a_reason_and_nothing_created(self):
        code, line = run('--email', 'admin@school.edu.ph', password=GOOD_PASSWORD)
        self.assertEqual(code, 2)
        self.assertIn('Gmail', line)
        self.assertFalse(User.objects.exists())

    def test_invalid_email_and_weak_or_missing_password_are_refused(self):
        self.assertEqual(run('--email', 'not-an-email', password=GOOD_PASSWORD)[0], 2)
        code, line = run('--email', 'weak.admin@gmail.com', password='12345678')
        self.assertEqual(code, 2)
        self.assertIn('password is not accepted', line)
        code, line = run('--email', 'nopass.admin@gmail.com')
        self.assertEqual(code, 2)
        self.assertIn('No password', line)
        self.assertFalse(User.objects.exists())

    def test_retry_after_failure_succeeds(self):
        self.assertEqual(run('--email', 'retry.admin@gmail.com', password='short')[0], 2)
        self.assertEqual(run('--check')[0], 3)
        code, line = run('--email', 'retry.admin@gmail.com', password=GOOD_PASSWORD)
        self.assertEqual(code, 0, line)
        self.assertEqual(run('--check')[0], 0)

    def test_creation_failure_is_reported_not_hidden(self):
        with mock.patch.object(User.objects, 'create_superuser', side_effect=RuntimeError('database is read-only')):
            code, line = run('--email', 'fail.admin@gmail.com', password=GOOD_PASSWORD)
        self.assertEqual(code, 1)
        self.assertIn('FAILED', line)
        self.assertIn('database is read-only', line)
        self.assertEqual(run('--check')[0], 3)

    def test_repair_with_an_existing_administrator_creates_no_duplicate(self):
        run('--email', 'first.admin@gmail.com', password=GOOD_PASSWORD)
        code, line = run('--email', 'second.admin@gmail.com', password=GOOD_PASSWORD)
        self.assertEqual(code, 0)
        self.assertIn('EXISTS', line)
        self.assertEqual(User.objects.filter(is_superuser=True).count(), 1)

    def test_existing_non_admin_account_with_that_email_is_not_promoted(self):
        User.objects.create_user(email='teacher.x@gmail.com', password=GOOD_PASSWORD, role='instructor', email_verified=True)
        code, line = run('--email', 'teacher.x@gmail.com', password=GOOD_PASSWORD)
        self.assertEqual(code, 2)
        self.assertIn('already exists', line)
        teacher = User.objects.get(email='teacher.x@gmail.com')
        self.assertFalse(teacher.is_superuser)

    def test_a_broken_superuser_is_not_counted_as_a_working_administrator(self):
        User.objects.create_superuser(email='old.admin@gmail.com', password=GOOD_PASSWORD)
        User.objects.filter(email='old.admin@gmail.com').update(is_active=False)
        code, line = run('--check')
        self.assertEqual(code, 3)
        self.assertIn('deactivated', line)
        code, line = run('--email', 'new.admin@gmail.com', password=GOOD_PASSWORD)
        self.assertEqual(code, 0, line)
        self.assertEqual(run('--check')[0], 0)
