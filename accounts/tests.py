"""Email verification: registration (Admin > Add user), signed links,
login blocking on every route, resend rate limits and SMTP failures.

Emails go through the durable outbox (notifications/outbox.py): views only
queue them and the worker sends them. flush() below runs the worker's
dispatch step so the tests can inspect what was actually sent."""
import datetime
import re
from smtplib import SMTPException
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.tokens import default_token_generator
from django.core import mail
from django.core.cache import cache
from django.core.mail.backends.base import BaseEmailBackend
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils.encoding import force_bytes
from django.utils.http import urlsafe_base64_encode

from accounts.verification import EmailVerificationTokenGenerator, email_verification_token
from notifications import outbox

User = get_user_model()


def flush():
    """Send everything queued, as the background worker would."""
    outbox.resume()
    outbox.dispatch_due(limit=100)
PASSWORD = 'Str0ng-Test-Pass!'
NEW_PASSWORD = 'An0ther-Str0ng-Pass!'


class FailingEmailBackend(BaseEmailBackend):
    def send_messages(self, email_messages):
        raise SMTPException('simulated SMTP outage')


def link_path(message):
    """Path of the verification link inside a sent email."""
    match = re.search(r'https://compulab\.example\.edu(/accounts/verify-email/[^/\s]+/[^/\s]+/)', message.body)
    return match.group(1)


@override_settings(
    SITE_URL='https://compulab.example.edu',
    EMAIL_BACKEND='django.core.mail.backends.locmem.EmailBackend',
    CACHES={'default': {'BACKEND': 'django.core.cache.backends.locmem.LocMemCache'}},
    EMAIL_VERIFICATION_TIMEOUT=72 * 3600,
    EMAIL_VERIFICATION_RESEND_COOLDOWN=120,
)
class EmailVerificationTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.admin = User.objects.create_user(
            email='admin.test@gmail.com', password=PASSWORD, role='admin', email_verified=True,
        )

    def setUp(self):
        cache.clear()
        outbox.resume()

    # --- helpers -------------------------------------------------------
    def register(self, email='new.instructor@gmail.com', role='instructor', **extra):
        self.client.force_login(self.admin)
        data = {'first_name': 'New', 'last_name': 'User', 'email': email, 'role': role, 'id_number': ''}
        data.update(extra)
        response = self.client.post(reverse('user_create'), data, follow=True)
        self.client.logout()
        flush()
        return response

    def unverified_admin(self, email='pending.admin@gmail.com'):
        return User.objects.create_user(email=email, password=PASSWORD, role='admin')

    def login(self, email, password=PASSWORD):
        return self.client.post(reverse('login'), {'username': email, 'password': password})

    def send_link(self, user):
        from accounts.views import send_verification_email
        mail.outbox.clear()
        self.assertTrue(send_verification_email(user))
        flush()
        return link_path(mail.outbox[-1])

    # --- registration ----------------------------------------------------
    def test_registration_sends_verification_email_and_leaves_account_unverified(self):
        response = self.register()
        user = User.objects.get(email='new.instructor@gmail.com')
        self.assertFalse(user.email_verified)
        self.assertFalse(user.has_usable_password())
        self.assertIsNotNone(user.email_verification_sent_at)
        self.assertEqual(len(mail.outbox), 1)
        message = mail.outbox[0]
        self.assertEqual(message.to, ['new.instructor@gmail.com'])
        self.assertIn('CompuLab', message.subject)
        self.assertIn('https://compulab.example.edu/accounts/verify-email/', message.body)
        self.assertIn('expires in 72 hours', message.body)
        self.assertIn('/accounts/verify-email/resend/', message.body)
        html = message.alternatives[0][0]
        self.assertIn('Verify Email Address', html)
        self.assertNotIn(PASSWORD, message.body + html)
        self.assertContains(response, 'A verification email to new.instructor@gmail.com is queued')

    def test_students_get_no_verification_email(self):
        from accounts.constants import DEPARTMENT_CHOICES
        self.register(email='student.one@gmail.com', role='student', id_number='S-1',
                      department=DEPARTMENT_CHOICES[0][0], year_level=1)
        self.assertTrue(User.objects.filter(email='student.one@gmail.com').exists())
        for message in mail.outbox:
            self.assertNotIn('/verify-email/', message.body)

    # --- verification link -----------------------------------------------
    def test_valid_link_sets_password_verifies_and_allows_login(self):
        self.register()
        user = User.objects.get(email='new.instructor@gmail.com')
        path = link_path(mail.outbox[0])
        self.assertEqual(self.login(user.email, NEW_PASSWORD).status_code, 200)  # no password yet

        self.assertContains(self.client.get(path), 'Set your password')
        user.refresh_from_db()
        self.assertFalse(user.email_verified)  # viewing the link alone verifies nothing

        response = self.client.post(path, {'password1': NEW_PASSWORD, 'password2': NEW_PASSWORD})
        self.assertContains(response, 'Password Set')
        user.refresh_from_db()
        self.assertTrue(user.email_verified)
        self.assertEqual(self.login(user.email, NEW_PASSWORD).status_code, 302)

    def test_valid_link_verifies_account_with_existing_password(self):
        user = self.unverified_admin()
        response = self.client.get(self.send_link(user))
        self.assertContains(response, 'Email Verified')
        user.refresh_from_db()
        self.assertTrue(user.email_verified)

    def test_used_link_reports_already_verified(self):
        user = self.unverified_admin()
        path = self.send_link(user)
        self.client.get(path)
        self.assertContains(self.client.get(path), 'Already Verified')

    def test_used_set_password_link_cannot_set_password_again(self):
        self.register()
        user = User.objects.get(email='new.instructor@gmail.com')
        path = link_path(mail.outbox[0])
        self.client.post(path, {'password1': NEW_PASSWORD, 'password2': NEW_PASSWORD})
        self.client.post(path, {'password1': 'Hij4cked-Pass-123', 'password2': 'Hij4cked-Pass-123'})
        user.refresh_from_db()
        self.assertTrue(user.check_password(NEW_PASSWORD))

    def test_expired_link_does_not_verify(self):
        user = self.unverified_admin()
        path = self.send_link(user)
        later = datetime.datetime.now() + datetime.timedelta(hours=73)
        with mock.patch.object(EmailVerificationTokenGenerator, '_now', return_value=later):
            response = self.client.get(path)
        self.assertContains(response, 'Link Expired')
        self.assertContains(response, 'Send New Link')
        user.refresh_from_db()
        self.assertFalse(user.email_verified)

    def test_tampered_or_garbage_links_are_invalid(self):
        user = self.unverified_admin()
        path = self.send_link(user)
        uid, token = path.rstrip('/').split('/')[-2:]
        bad_paths = [
            reverse('verify_email', kwargs={'uidb64': uid, 'token': token[:-1] + ('0' if token[-1] != '0' else '1')}),
            reverse('verify_email', kwargs={'uidb64': uid, 'token': 'not-a-token'}),
            reverse('verify_email', kwargs={'uidb64': 'garbage', 'token': token}),
        ]
        for bad in bad_paths:
            self.assertContains(self.client.get(bad), 'Invalid Link')
        user.refresh_from_db()
        self.assertFalse(user.email_verified)

    def test_token_for_one_account_cannot_verify_another(self):
        victim = self.unverified_admin('victim@gmail.com')
        attacker = self.unverified_admin('attacker@gmail.com')
        _, token = self.send_link(attacker).rstrip('/').split('/')[-2:]
        victim_uid = urlsafe_base64_encode(force_bytes(victim.pk))
        response = self.client.get(reverse('verify_email', kwargs={'uidb64': victim_uid, 'token': token}))
        self.assertContains(response, 'Invalid Link')
        victim.refresh_from_db()
        self.assertFalse(victim.email_verified)

    def test_newer_link_supersedes_older_one(self):
        user = self.unverified_admin()
        old_path = self.send_link(user)
        new_path = self.send_link(user)
        self.assertContains(self.client.get(old_path), 'Invalid Link')
        self.assertContains(self.client.get(new_path), 'Email Verified')

    def test_changing_email_invalidates_pending_link(self):
        user = self.unverified_admin()
        path = self.send_link(user)
        user.email = 'changed.address@gmail.com'
        user.save(update_fields=['email'])
        self.assertContains(self.client.get(path), 'Invalid Link')

    def test_verification_and_password_reset_tokens_are_not_interchangeable(self):
        user = self.unverified_admin()
        self.send_link(user)
        user.refresh_from_db()
        self.assertFalse(default_token_generator.check_token(user, email_verification_token.make_token(user)))
        self.assertFalse(email_verification_token.check_token(user, default_token_generator.make_token(user)))

    # --- login blocking ------------------------------------------------------
    def test_login_blocked_before_verification_with_helpful_message(self):
        user = self.unverified_admin()
        response = self.login(user.email)
        self.assertNotIn('_auth_user_id', self.client.session)
        self.assertContains(response, 'Please verify your email address first')

    def test_wrong_password_for_unverified_account_gets_generic_error(self):
        user = self.unverified_admin()
        response = self.login(user.email, 'wrong-password')
        self.assertNotContains(response, 'verify your email')
        self.assertNotIn('_auth_user_id', self.client.session)

    def test_login_allowed_after_verification(self):
        user = self.unverified_admin()
        self.client.get(self.send_link(user))
        self.assertEqual(self.login(user.email).status_code, 302)
        self.assertIn('_auth_user_id', self.client.session)

    def test_admin_site_login_also_blocks_unverified_staff(self):
        user = self.unverified_admin()
        user.is_staff = True
        user.save(update_fields=['is_staff'])
        self.client.post(reverse('admin:login'), {'username': user.email, 'password': PASSWORD})
        self.assertNotIn('_auth_user_id', self.client.session)

    def test_existing_session_is_dropped_when_account_becomes_unverified(self):
        user = User.objects.create_user(email='was.verified@gmail.com', password=PASSWORD,
                                        role='admin', email_verified=True)
        self.client.force_login(user)
        self.assertEqual(self.client.get(reverse('admin_dashboard')).status_code, 200)
        user.email_verified = False
        user.save(update_fields=['email_verified'])
        self.assertEqual(self.client.get(reverse('admin_dashboard')).status_code, 302)

    def test_verified_accounts_and_unverified_superusers_keep_access(self):
        self.assertEqual(self.login(self.admin.email).status_code, 302)
        self.client.logout()
        superuser = User.objects.create_superuser(email='owner@gmail.com', password=PASSWORD)
        self.assertFalse(superuser.email_verified)
        self.assertEqual(self.login(superuser.email).status_code, 302)
        self.client.logout()
        self.client.post(reverse('admin:login'), {'username': superuser.email, 'password': PASSWORD})
        self.assertIn('_auth_user_id', self.client.session)

    # --- resending -----------------------------------------------------------
    def test_public_resend_sends_new_link_then_rate_limits(self):
        user = self.unverified_admin()
        response = self.client.post(reverse('resend_verification'), {'email': user.email.upper()})
        self.assertContains(response, 'Check Your Inbox')
        flush()
        self.assertEqual(len(mail.outbox), 1)
        self.client.post(reverse('resend_verification'), {'email': user.email})
        flush()
        self.assertEqual(len(mail.outbox), 1)  # within the cooldown

    def test_public_resend_daily_cap_per_account(self):
        user = self.unverified_admin()
        for _ in range(7):
            User.objects.filter(pk=user.pk).update(email_verification_sent_at=None)
            self.client.post(reverse('resend_verification'), {'email': user.email})
            flush()
        self.assertEqual(len(mail.outbox), 5)

    def test_public_resend_gives_same_answer_and_sends_nothing_for_other_addresses(self):
        User.objects.create_user(email='student.x@gmail.com', role='student')
        for email in ('nobody@gmail.com', self.admin.email, 'student.x@gmail.com'):
            response = self.client.post(reverse('resend_verification'), {'email': email})
            self.assertContains(response, 'Check Your Inbox')
        flush()
        self.assertEqual(mail.outbox, [])

    def test_resend_page_loads(self):
        self.assertContains(self.client.get(reverse('resend_verification')), 'Resend Verification Email')

    def test_admin_resend_respects_cooldown(self):
        user = self.unverified_admin()
        self.client.force_login(self.admin)
        url = reverse('user_resend_verification', args=[user.pk])
        self.client.post(url)
        flush()
        response = self.client.post(url, follow=True)
        flush()
        self.assertEqual(len(mail.outbox), 1)
        self.assertContains(response, 'Please wait')

    # --- SMTP failures -------------------------------------------------------
    @override_settings(EMAIL_BACKEND='accounts.tests.FailingEmailBackend')
    def test_registration_with_smtp_failure_queues_and_retries(self):
        from notifications.models import EmailOutbox
        response = self.register()
        user = User.objects.get(email='new.instructor@gmail.com')
        self.assertContains(response, 'is queued')  # never claims it was sent
        self.assertFalse(user.email_verified)
        # The failed attempt must not leave a "sent" timestamp behind (that
        # would start a resend cooldown for an email that never left).
        self.assertIsNone(user.email_verification_sent_at)
        row = EmailOutbox.objects.get(user=user, category='verification')
        self.assertEqual(row.status, 'retry')
        self.assertEqual(row.attempts, 1)
        self.assertIn('SMTPException', row.last_error)

    @override_settings(EMAIL_BACKEND='accounts.tests.FailingEmailBackend')
    def test_public_resend_with_smtp_failure_is_kept_for_retry(self):
        from notifications.models import EmailOutbox
        user = self.unverified_admin()
        response = self.client.post(reverse('resend_verification'), {'email': user.email})
        self.assertContains(response, 'Check Your Inbox')
        flush()
        user.refresh_from_db()
        self.assertIsNone(user.email_verification_sent_at)
        self.assertEqual(EmailOutbox.objects.get(user=user).status, 'retry')

    def test_page_never_waits_for_smtp(self):
        """Registering only queues the email: nothing is sent until the
        worker runs, so a slow or dead mail server can't hold up the page."""
        self.client.force_login(self.admin)
        self.client.post(reverse('user_create'), {
            'first_name': 'Q', 'last_name': 'User', 'email': 'queued.only@gmail.com',
            'role': 'instructor', 'id_number': '',
        })
        self.assertEqual(mail.outbox, [])
        flush()
        self.assertEqual(len(mail.outbox), 1)
