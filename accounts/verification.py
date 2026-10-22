"""Email verification for Admin, Lab In-Charge and Instructor accounts.

Accounts are created by an Admin (Users > Add user) and can't sign in
until their owner clicks the emailed link. Superusers (created on the
server with `createsuperuser`) are exempt, and Students never sign in
with a password at all. The rule lives in requires_verification() and is
enforced for every login route by accounts.backends.VerifiedEmailBackend.
"""
import copy

from django.conf import settings
from django.contrib.auth.tokens import PasswordResetTokenGenerator
from django.utils import timezone
from django.utils.crypto import constant_time_compare
from django.utils.http import base36_to_int

VALID = 'valid'
EXPIRED = 'expired'
USED = 'used'        # a genuine link for an account that is already verified
INVALID = 'invalid'  # tampered, superseded by a newer link, or for another account


def requires_verification(user):
    """True if this account may not sign in until its email is verified."""
    return not (user.email_verified or user.is_superuser or user.role == 'student')


def resend_cooldown_remaining(user):
    """Seconds left before another verification email may go to this account."""
    if not user.email_verification_sent_at:
        return 0
    elapsed = (timezone.now() - user.email_verification_sent_at).total_seconds()
    return max(0, int(settings.EMAIL_VERIFICATION_RESEND_COOLDOWN - elapsed))


class EmailVerificationTokenGenerator(PasswordResetTokenGenerator):
    """Signed (HMAC with SECRET_KEY), time-limited verification token.

    Its own key_salt keeps it from ever being accepted as a password-reset
    token (or vice versa). The hash covers the email address, the verified
    flag and when the latest link was sent, so a link stops working once
    it has been used, once the email changes, or once a newer link is sent.
    """
    key_salt = 'accounts.verification.EmailVerificationTokenGenerator'

    def _make_hash_value(self, user, timestamp):
        sent_at = user.email_verification_sent_at
        # Full precision (DATETIME(6) keeps microseconds), so two links sent
        # within the same second still get different tokens.
        sent_at = '' if sent_at is None else sent_at.replace(tzinfo=None).isoformat()
        return f'{user.pk}|{user.email or ""}|{int(user.email_verified)}|{sent_at}|{timestamp}'

    def _signature_matches(self, user, token, ts):
        return any(
            constant_time_compare(self._make_token_with_timestamp(user, ts, secret), token)
            for secret in [self.secret, *self.secret_fallbacks]
        )

    def check_status(self, user, token):
        if not (user and token):
            return INVALID
        try:
            ts_b36, _ = token.split('-')
            ts = base36_to_int(ts_b36)
        except ValueError:
            return INVALID
        if not self._signature_matches(user, token, ts):
            # Only a link that was genuinely issued to this account (the
            # signature matches its pre-verification state) may learn that
            # the account is already verified.
            if user.email_verified:
                unverified = copy.copy(user)
                unverified.email_verified = False
                if self._signature_matches(unverified, token, ts):
                    return USED
            return INVALID
        if self._num_seconds(self._now()) - ts > settings.EMAIL_VERIFICATION_TIMEOUT:
            return EXPIRED
        return VALID

    def check_token(self, user, token):
        return self.check_status(user, token) == VALID


email_verification_token = EmailVerificationTokenGenerator()
