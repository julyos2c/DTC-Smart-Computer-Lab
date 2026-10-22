"""Account approval and one-time codes (works with no internet).

Two ways in for a new Admin / Lab In-Charge / Instructor account:

1. Online: the owner clicks the emailed verification link
   (mark_email_verified(): verified email + approved via 'email_link').
2. Offline or no email: an Admin checks the person's identity (school ID)
   and issues an activation code (issue_code(..., 'activate')). The owner
   enters it with their own new password at /accounts/activate/
   (redeem_code()) and is approved via 'in_person_code'. The verification
   email still goes out later and then also marks the mailbox verified.

A forgotten password while offline works the same way with a
'reset_password' code. Codes are bound to one account, single-use,
expiring, revoked by a newer code, revoked after 5 wrong tries, and only
their HMAC is stored. They never change the account's role.

Who may issue codes / approve / reject (decision D4): Admins, for accounts
they are allowed to manage; an Admin-role account needs a superuser."""
import datetime
import hashlib
import hmac
import secrets

from django.conf import settings
from django.db import transaction
from django.utils import timezone

CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'  # no 0/O, 1/I
CODE_LENGTH = 10
MAX_FAILED_ATTEMPTS = 5


class CodeError(Exception):
    """Shown to the person entering the code; deliberately generic."""


def _hash(user_id, purpose, code):
    message = f'{user_id}:{purpose}:{code}'.encode()
    return hmac.new(settings.SECRET_KEY.encode(), message, hashlib.sha256).hexdigest()


def normalize_code(raw):
    return ''.join(ch for ch in (raw or '').upper() if ch in CODE_ALPHABET)


def format_code(code):
    return f'{code[:5]}-{code[5:]}'


def _log(actor, action, target, details):
    from accounts.models import ActivityLog
    ActivityLog.objects.create(
        actor=actor, action=action, target_identifier=target.email or target.id_number or str(target.pk),
        details=details,
    )


# ------------------------------------------------------------------ #
# Permissions
# ------------------------------------------------------------------ #
def can_manage_lifecycle(actor, target):
    """Admins approve/reject and issue codes; a superuser target needs a
    superuser actor (same rule as editing), and an Admin-role target needs
    a superuser too. Students never sign in, so they have no lifecycle."""
    if not (actor and actor.is_authenticated and actor.role == 'admin' and actor.is_active):
        return False
    if target.role == 'student' or not target.email or target.pk == actor.pk:
        return False
    if target.is_superuser or target.role == 'admin':
        return actor.is_superuser
    return True


# ------------------------------------------------------------------ #
# Codes
# ------------------------------------------------------------------ #
def issue_code(target, purpose, issued_by, ip=None):
    """Create a fresh code for `target`, revoking any earlier unused one for
    the same purpose. Returns the plain code ('XXXXX-XXXXX') to show once."""
    from accounts.models import AccountActionCode
    if purpose not in ('activate', 'reset_password'):
        raise ValueError(purpose)
    now = timezone.now()
    lifetime = (
        datetime.timedelta(hours=settings.ACTIVATION_CODE_HOURS) if purpose == 'activate'
        else datetime.timedelta(minutes=settings.RESET_CODE_MINUTES)
    )
    code = ''.join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
    with transaction.atomic():
        AccountActionCode.objects.filter(
            user=target, purpose=purpose, used_at__isnull=True, revoked_at__isnull=True,
        ).update(revoked_at=now)
        AccountActionCode.objects.create(
            user=target, purpose=purpose, code_hash=_hash(target.pk, purpose, code),
            issued_by=issued_by, issued_from_ip=ip, expires_at=now + lifetime,
        )
        if purpose == 'activate':
            _log(issued_by, 'issue_activation_code', target,
                 f'{issued_by.display_name} checked {target.display_name}\'s identity in person and issued an '
                 f'activation code (valid {settings.ACTIVATION_CODE_HOURS} h).')
        else:
            _log(issued_by, 'issue_reset_code', target,
                 f'{issued_by.display_name} checked {target.display_name}\'s identity in person and issued a '
                 f'password reset code (valid {settings.RESET_CODE_MINUTES} min).')
    return format_code(code), now + lifetime


def active_code(target, purpose):
    from accounts.models import AccountActionCode
    return AccountActionCode.objects.filter(
        user=target, purpose=purpose, used_at__isnull=True, revoked_at__isnull=True,
        expires_at__gt=timezone.now(),
    ).first()


def revoke_codes(target, actor=None):
    from accounts.models import AccountActionCode
    return AccountActionCode.objects.filter(
        user=target, used_at__isnull=True, revoked_at__isnull=True,
    ).update(revoked_at=timezone.now())


def redeem_code(email, raw_code, new_password):
    """Check the code for the account with this email and, if it matches,
    set the new password (and approve the account for an activation code).
    Returns (user, purpose). Raises CodeError with a generic message."""
    from django.contrib.auth import get_user_model
    from accounts.models import AccountActionCode

    generic = CodeError('That code is not valid for this email address, or it has expired or already been used. '
                        'Ask a Lab Administrator for a new code.')
    User = get_user_model()
    code = normalize_code(raw_code)
    user = User.objects.filter(email__iexact=(email or '').strip()).exclude(role='student').first()
    if user is None or len(code) != CODE_LENGTH or not user.is_active:
        raise generic

    now = timezone.now()
    with transaction.atomic():
        candidates = list(
            AccountActionCode.objects.select_for_update().filter(
                user=user, used_at__isnull=True, revoked_at__isnull=True, expires_at__gt=now,
            )
        )
        match = next(
            (c for c in candidates if hmac.compare_digest(c.code_hash, _hash(user.pk, c.purpose, code))),
            None,
        )
        if match is None:
            # Count the wrong guess against every live code for this account
            # (committed before raising, so the limit really holds).
            for c in candidates:
                c.failed_attempts += 1
                if c.failed_attempts >= MAX_FAILED_ATTEMPTS:
                    c.revoked_at = now
                c.save(update_fields=['failed_attempts', 'revoked_at'])
    if match is None or (match.purpose == 'activate' and user.approval_status == 'rejected'):
        raise generic

    with transaction.atomic():
        match = AccountActionCode.objects.select_for_update().get(pk=match.pk)
        if match.used_at or match.revoked_at:
            raise generic
        match.used_at = now
        match.save(update_fields=['used_at'])
        user = User.objects.select_for_update().get(pk=user.pk)
        user.set_password(new_password)
        fields = ['password']
        if match.purpose == 'activate':
            user.approval_status = 'approved'
            user.approval_method = 'in_person_code'
            user.approved_by = match.issued_by
            user.approved_at = now
            fields += ['approval_status', 'approval_method', 'approved_by', 'approved_at']
        user.save(update_fields=fields)

        if match.purpose == 'activate':
            _log(user, 'redeem_activation_code', user,
                 f'{user.display_name} activated their account with an in-person code issued by '
                 f'{match.issued_by.display_name if match.issued_by else "an Admin"} and set their own password.')
        else:
            _log(user, 'redeem_reset_code', user,
                 f'{user.display_name} reset their password with an in-person code issued by '
                 f'{match.issued_by.display_name if match.issued_by else "an Admin"}.')
    return user, match.purpose


# ------------------------------------------------------------------ #
# Approval state
# ------------------------------------------------------------------ #
def mark_email_verified(user):
    """The owner clicked a valid verification link. Records mailbox
    ownership and, if the account was still pending, approves it the way
    it always worked online."""
    now = timezone.now()
    user.email_verified = True
    user.email_verified_at = now
    fields = ['email_verified', 'email_verified_at']
    if user.approval_status == 'pending':
        user.approval_status = 'approved'
        user.approval_method = 'email_link'
        user.approved_at = now
        fields += ['approval_status', 'approval_method', 'approved_at']
    user.save(update_fields=fields)
    _log(user, 'email_verified', user, f'{user.display_name} verified their email address ({user.email}).')


def reject(target, actor, reason=''):
    from notifications import outbox
    target.approval_status = 'rejected'
    target.approved_by = actor
    target.approved_at = timezone.now()
    target.save(update_fields=['approval_status', 'approved_by', 'approved_at'])
    revoke_codes(target)
    outbox.cancel_for_user(target, 'verification')
    _log(actor, 'reject_account', target,
         f'{actor.display_name} rejected {target.display_name}\'s account.' + (f' Reason: {reason}' if reason else ''))


def reopen(target, actor):
    """Undo a rejection: back to pending so it can be approved again."""
    target.approval_status = 'pending'
    target.approved_by = None
    target.approved_at = None
    target.save(update_fields=['approval_status', 'approved_by', 'approved_at'])
    _log(actor, 'approve_account', target, f'{actor.display_name} reopened {target.display_name}\'s account for approval.')
