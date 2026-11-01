"""Email outbox: queue now, send in the background, retry until it works.

Callers only ever INSERT a row (queue(), queue_verification(),
queue_password_reset()); nothing on a web request waits for SMTP. The
worker loop calls dispatch_due() every few seconds. Rules (see
docs/OFFLINE_ACCOUNT_VERIFICATION.md §6):

* Backoff 1, 2, 4, 8, 16, 32 minutes, then every 60 minutes, until the row
  expires. While the network/SMTP is failing, attempts pause for a while
  instead of hammering a dead connection.
* A recipient rejected with an SMTP 5xx code is 'dead' at once and Admins
  get an in-app notice to fix the address.
* Rows past expires_at become 'expired' and are never sent (a reservation
  code for a class that already ended is useless).
* Verification and password-reset emails are rendered at send time, so the
  link's validity starts when it is actually delivered.
* Delivery is at-least-once: a crash after the SMTP server accepted a
  message but before it is marked 'sent' can produce one duplicate.
"""
import datetime
import logging
import smtplib
import socket

from django.conf import settings
from django.contrib.auth.tokens import default_token_generator
from django.core.mail import EmailMultiAlternatives, get_connection
from django.db.models import F
from django.template.loader import render_to_string
from django.templatetags.static import static
from django.urls import reverse
from django.utils import timezone
from django.utils.encoding import force_bytes
from django.utils.http import urlsafe_base64_encode

logger = logging.getLogger(__name__)

BACKOFF_MINUTES = [1, 2, 4, 8, 16, 32]
MAX_BACKOFF_MINUTES = 60
NETWORK_PAUSE_SECONDS = 120
BATCH_SIZE = 3          # per worker tick (~5 s): about 36 emails a minute at most
STUCK_SENDING_MINUTES = 10

# How long a queued email stays worth sending, by category.
DEFAULT_LIFETIME = {
    'verification': datetime.timedelta(days=7),
    'password_reset': datetime.timedelta(hours=1),
    'password_changed': datetime.timedelta(days=3),
    'reservation_code': datetime.timedelta(days=2),   # callers pass the session end instead
    'notification': datetime.timedelta(days=3),
    'welcome': datetime.timedelta(days=14),
    'security_alert': datetime.timedelta(days=1),
}

_paused_until = None


# ------------------------------------------------------------------ #
# Policy
# ------------------------------------------------------------------ #
def email_allowed_for(user):
    """Automatic emails go to students, superusers and staff whose address
    is verified. A staff account approved in person but not yet email-
    verified gets in-app notifications only, until the address is proven
    (policy D3 in docs/IMPLEMENTATION_ROADMAP.md)."""
    if user is None or not user.email:
        return False
    return user.role == 'student' or user.is_superuser or user.email_verified


def _site_scheme():
    return settings.SITE_URL.split('://', 1)[0] if '://' in settings.SITE_URL else 'http'


def _logo_url():
    return f'{settings.SITE_URL}{static("img/logo.jpg")}'


# ------------------------------------------------------------------ #
# Queueing (called from views / services; never blocks)
# ------------------------------------------------------------------ #
def _active_duplicate(dedupe_key):
    from notifications.models import EmailOutbox
    if not dedupe_key:
        return None
    return EmailOutbox.objects.filter(dedupe_key=dedupe_key, status__in=EmailOutbox.ACTIVE_STATUSES).first()


def queue(to_email, subject, text_body, html_body='', category='notification', user=None,
          created_by=None, dedupe_key='', expires_at=None):
    """Queue an email with a stored body. Returns the row, or None if there
    is no address. Never raises: a queueing problem must not break the
    action that triggered the email."""
    from notifications.models import EmailOutbox
    if not to_email:
        return None
    try:
        if dedupe_key.startswith('reservation:event:'):
            existing = EmailOutbox.objects.filter(dedupe_key=dedupe_key).first()
        else:
            existing = _active_duplicate(dedupe_key)
        if existing:
            return existing
        now = timezone.now()
        return EmailOutbox.objects.create(
            category=category, to_email=to_email, subject=(subject or '')[:255],
            render_mode='stored', text_body=text_body or '', html_body=html_body or '',
            dedupe_key=dedupe_key or '', next_attempt_at=now,
            expires_at=expires_at or now + DEFAULT_LIFETIME.get(category, datetime.timedelta(days=3)),
            user=user, created_by=created_by,
        )
    except Exception:  # noqa: BLE001
        logger.exception('Could not queue %s email for %s', category, to_email)
        return None


def queue_template(to_email, subject, template_base, context, category, user=None, created_by=None,
                   dedupe_key='', expires_at=None):
    """Render emails/<template_base>.txt and .html now and queue them."""
    try:
        text_body = render_to_string(f'{template_base}.txt', context)
        html_body = render_to_string(f'{template_base}.html', context)
    except Exception:  # noqa: BLE001
        logger.exception('Could not render %s for %s', template_base, to_email)
        return None
    return queue(to_email, subject, text_body, html_body, category=category, user=user,
                 created_by=created_by, dedupe_key=dedupe_key, expires_at=expires_at)


def _queue_render_at_send(category, user, created_by=None):
    from notifications.models import EmailOutbox
    if not user or not user.email:
        return None
    dedupe_key = f'{category}:{user.pk}'
    existing = _active_duplicate(dedupe_key)
    if existing:
        # Same pending message: just make sure it goes out on the next tick.
        if existing.status == 'retry':
            existing.next_attempt_at = timezone.now()
            existing.save(update_fields=['next_attempt_at', 'updated_at'])
        return existing
    now = timezone.now()
    return EmailOutbox.objects.create(
        category=category, to_email=user.email, render_mode='render_at_send',
        dedupe_key=dedupe_key, next_attempt_at=now,
        expires_at=now + DEFAULT_LIFETIME[category], user=user, created_by=created_by,
    )


def queue_verification(user, created_by=None):
    """Queue the 'verify your email' message for a staff account. The link
    is generated when the worker sends it (see _render_verification)."""
    return _queue_render_at_send('verification', user, created_by=created_by)


def queue_password_reset(user):
    return _queue_render_at_send('password_reset', user)


def cancel_for_user(user, category):
    from notifications.models import EmailOutbox
    return EmailOutbox.objects.filter(
        user=user, category=category, status__in=EmailOutbox.ACTIVE_STATUSES,
    ).update(status='cancelled', updated_at=timezone.now())


# ------------------------------------------------------------------ #
# Render-at-send
# ------------------------------------------------------------------ #
class _Skip(Exception):
    """The message is no longer needed (e.g. already verified)."""


def _render_verification(row):
    from accounts.verification import email_verification_token
    user = row.user
    if user is None or not user.is_active or not user.email or user.email.lower() != row.to_email.lower():
        raise _Skip('account changed or removed')
    if user.email_verified:
        raise _Skip('already verified')

    previous_sent_at = user.email_verification_sent_at
    sent_at = timezone.now()
    if previous_sent_at and sent_at <= previous_sent_at:
        sent_at = previous_sent_at + datetime.timedelta(microseconds=1)
    # The token covers email_verification_sent_at, so setting it here makes
    # this link the only valid one ("only the newest link works").
    user.email_verification_sent_at = sent_at
    user.save(update_fields=['email_verification_sent_at'])

    def _restore():
        user.email_verification_sent_at = previous_sent_at
        user.save(update_fields=['email_verification_sent_at'])

    uid = urlsafe_base64_encode(force_bytes(user.pk))
    token = email_verification_token.make_token(user)
    context = {
        'user': user,
        'verify_url': settings.SITE_URL + reverse('verify_email', kwargs={'uidb64': uid, 'token': token}),
        'resend_url': settings.SITE_URL + reverse('resend_verification'),
        'expiry_hours': settings.EMAIL_VERIFICATION_TIMEOUT // 3600,
        'site_url': settings.SITE_URL,
        'logo_url': _logo_url(),
    }
    return (
        'Verify your CompuLab email address',
        render_to_string('emails/verify_email.txt', context),
        render_to_string('emails/verify_email.html', context),
        _restore,
    )


def _render_password_reset(row):
    user = row.user
    if (user is None or not user.is_active or not user.has_usable_password() or not user.email
            or user.email.lower() != row.to_email.lower()):
        raise _Skip('account changed or removed')
    context = {
        'email': user.email,
        'domain': settings.SITE_DOMAIN,
        'site_name': 'CompuLab',
        'uid': urlsafe_base64_encode(force_bytes(user.pk)),
        'user': user,
        'token': default_token_generator.make_token(user),
        'protocol': _site_scheme(),
        'logo_url': _logo_url(),
        'header_bg_url': f'{settings.SITE_URL}{static("img/login-bg.jpg")}',
    }
    subject = ''.join(render_to_string('registration/password_reset_subject.txt', context).splitlines())
    return (
        subject,
        render_to_string('registration/password_reset_email.txt', context),
        render_to_string('registration/password_reset_email.html', context),
        None,
    )


RENDERERS = {
    'verification': _render_verification,
    'password_reset': _render_password_reset,
}


# ------------------------------------------------------------------ #
# Dispatch (worker)
# ------------------------------------------------------------------ #
def _classify(exc):
    """-> (outcome, error_text, pause). outcome is 'dead' or 'retry'."""
    name = exc.__class__.__name__
    if isinstance(exc, smtplib.SMTPRecipientsRefused):
        codes = [code for code, _ in exc.recipients.values()]
        code = codes[0] if codes else ''
        if codes and all(500 <= c < 600 for c in codes):
            return 'dead', f'{name} {code}', False
        return 'retry', f'{name} {code}', False
    if isinstance(exc, smtplib.SMTPResponseException):
        code = exc.smtp_code
        if isinstance(exc, smtplib.SMTPDataError) and code in (550, 551, 553):
            return 'dead', f'{name} {code}', False
        # Authentication/sender problems affect every message: pause.
        return 'retry', f'{name} {code}', True
    if isinstance(exc, (smtplib.SMTPServerDisconnected, smtplib.SMTPConnectError, socket.timeout, OSError)):
        return 'retry', name, True
    return 'retry', name, False


def _backoff(attempts):
    minutes = BACKOFF_MINUTES[attempts - 1] if 0 < attempts <= len(BACKOFF_MINUTES) else MAX_BACKOFF_MINUTES
    return datetime.timedelta(minutes=minutes)


def _notify_admins_dead(row):
    from django.contrib.auth import get_user_model
    from notifications.models import Notification
    who = row.user.display_name if row.user else row.to_email
    for admin in get_user_model().objects.filter(is_active=True, role='admin'):
        Notification.objects.create(
            user=admin, is_system_alert=True, notification_type='general',
            title='Email address rejected',
            message=(f'The mail server rejected the {row.get_category_display().lower()} email to {row.to_email} '
                     f'({who}). Fix the email address on the account, then use Retry in the Email outbox.'),
        )


def resume():
    """Called by the worker when connectivity comes back."""
    global _paused_until
    _paused_until = None


def dispatch_due(limit=BATCH_SIZE):
    """Send up to `limit` due emails. Returns how many were sent."""
    global _paused_until
    from notifications.models import EmailOutbox

    now = timezone.now()
    EmailOutbox.objects.filter(
        status='sending', updated_at__lt=now - datetime.timedelta(minutes=STUCK_SENDING_MINUTES),
    ).update(status='retry', next_attempt_at=now, updated_at=now)
    EmailOutbox.objects.filter(
        status__in=('pending', 'retry'), expires_at__isnull=False, expires_at__lte=now,
    ).update(status='expired', updated_at=now)

    if _paused_until and now < _paused_until:
        return 0

    due = list(
        EmailOutbox.objects.filter(status__in=('pending', 'retry'), next_attempt_at__lte=now)
        .order_by('next_attempt_at', 'pk').values_list('pk', flat=True)[:limit]
    )
    if not due:
        return 0

    sent = 0
    connection = None
    try:
        for pk in due:
            claimed = EmailOutbox.objects.filter(pk=pk, status__in=('pending', 'retry')).update(
                status='sending', attempts=F('attempts') + 1, updated_at=timezone.now(),
            )
            if not claimed:
                continue
            row = EmailOutbox.objects.select_related('user').get(pk=pk)
            restore = None
            try:
                if row.render_mode == 'render_at_send':
                    subject, text_body, html_body, restore = RENDERERS[row.category](row)
                else:
                    subject, text_body, html_body = row.subject, row.text_body, row.html_body
                if connection is None:
                    connection = get_connection(fail_silently=False)
                message = EmailMultiAlternatives(
                    subject=subject, body=text_body, from_email=settings.DEFAULT_FROM_EMAIL,
                    to=[row.to_email], connection=connection,
                )
                if html_body:
                    message.attach_alternative(html_body, 'text/html')
                message.send(fail_silently=False)
            except _Skip as skip:
                row.status = 'cancelled'
                row.last_error = str(skip)[:255]
                row.save(update_fields=['status', 'last_error', 'updated_at'])
                continue
            except Exception as exc:  # noqa: BLE001
                if restore:
                    restore()
                outcome, error_text, pause = _classify(exc)
                row.last_error = error_text[:255]
                if outcome == 'dead':
                    row.status = 'dead'
                    row.save(update_fields=['status', 'last_error', 'updated_at'])
                    _notify_admins_dead(row)
                else:
                    row.status = 'retry'
                    row.next_attempt_at = timezone.now() + _backoff(row.attempts)
                    row.save(update_fields=['status', 'last_error', 'next_attempt_at', 'updated_at'])
                logger.warning('Email #%s (%s) not sent: %s', row.pk, row.category, error_text)
                if pause:
                    _paused_until = timezone.now() + datetime.timedelta(seconds=NETWORK_PAUSE_SECONDS)
                    break
                connection = None  # start a fresh SMTP session after an error
                continue
            row.status = 'sent'
            row.sent_at = timezone.now()
            row.last_error = ''
            row.save(update_fields=['status', 'sent_at', 'last_error', 'updated_at'])
            sent += 1
    finally:
        if connection is not None:
            try:
                connection.close()
            except Exception:  # noqa: BLE001
                pass
    return sent


def retry_now(row):
    row.status = 'pending'
    row.next_attempt_at = timezone.now()
    now = timezone.now()
    if row.expires_at and row.expires_at <= now:
        # An explicit retry gets one more day of life.
        row.expires_at = now + datetime.timedelta(days=1)
    row.save(update_fields=['status', 'next_attempt_at', 'expires_at', 'updated_at'])
    resume()


def housekeeping():
    """Drop stored bodies 30 days after sending; delete very old rows."""
    from notifications.models import EmailOutbox
    now = timezone.now()
    EmailOutbox.objects.filter(status='sent', sent_at__lt=now - datetime.timedelta(days=30)).exclude(
        text_body='', html_body='',
    ).update(text_body='', html_body='')
    EmailOutbox.objects.filter(
        status__in=('sent', 'expired', 'cancelled', 'dead'), created_at__lt=now - datetime.timedelta(days=180),
    ).delete()
