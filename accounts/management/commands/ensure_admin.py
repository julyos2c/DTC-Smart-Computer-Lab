"""Makes sure CompuLab has a working Administrator account (used by the
Windows installer, installer/server/install-server.ps1).

    python manage.py ensure_admin --check
    python manage.py ensure_admin --email admin@gmail.com     (password in COMPULAB_ADMIN_PASSWORD)

A "working Administrator" is an active superuser with role Admin, an email
address and a usable password - an account that can actually sign in to
the Admin dashboard.

--check   exit 0 if one exists, 3 if not (the reason is printed).
--email   creates one, unless a working Administrator already exists (then
          nothing is created: Repair/Update never make a second one).
          The password comes from the environment variable
          COMPULAB_ADMIN_PASSWORD, never from the command line, so it does
          not show up in process lists or logs. Exit 0 = created or already
          there, 2 = the details are not acceptable (reason printed; nothing
          was changed), 1 = creating the account failed.

The last line printed is always "RESULT: <CODE>: <message>" for the
installer; no password is ever printed.
"""
import os

from django.contrib.auth import get_user_model
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError
from django.core.management.base import BaseCommand
from django.core.validators import validate_email
from django.db import transaction

from accounts.email_rules import email_domain_error

PASSWORD_ENV = 'COMPULAB_ADMIN_PASSWORD'


def _mask(email):
    name, _, domain = (email or '').partition('@')
    return f'{name[:2]}***@{domain}' if domain else '***'


def admin_problems(user):
    """Why this account cannot work as the Administrator (empty = it can)."""
    problems = []
    if not user.is_active:
        problems.append('it is deactivated')
    if not user.is_superuser:
        problems.append('it is not a superuser')
    if user.role != 'admin':
        problems.append(f'its role is "{user.get_role_display()}", not Admin')
    if not user.email:
        problems.append('it has no email address to sign in with')
    if not user.has_usable_password():
        problems.append('it has no password')
    return problems


def working_admins():
    User = get_user_model()
    return [u for u in User.objects.filter(is_superuser=True).order_by('pk') if not admin_problems(u)]


class Command(BaseCommand):
    help = 'Checks for, or creates, the first working Administrator account (installer use).'

    def add_arguments(self, parser):
        parser.add_argument('--check', action='store_true', help='Only check; exit 3 if there is no working Administrator.')
        parser.add_argument('--email', default='', help='Email (sign-in name) of the Administrator to create.')

    def _result(self, code, message, exit_code):
        self.stdout.write(f'RESULT: {code}: {message}')
        if exit_code:
            raise SystemExit(exit_code)

    def handle(self, *args, **options):
        User = get_user_model()
        existing = working_admins()
        if options['check'] or not options['email']:
            if existing:
                return self._result('ADMIN_OK', f'Administrator account: {_mask(existing[0].email)}', 0)
            broken = list(User.objects.filter(is_superuser=True).order_by('pk')[:3])
            detail = '; '.join(f'{_mask(u.email)}: {", ".join(admin_problems(u))}' for u in broken)
            return self._result('NO_ADMIN', 'There is no working Administrator account'
                                + (f' ({detail})' if detail else '') + '.', 3)

        if existing:
            return self._result('EXISTS', f'An Administrator account already exists ({_mask(existing[0].email)}); '
                                          'no new account was created.', 0)

        email = User.objects.normalize_email(options['email'].strip())
        try:
            validate_email(email)
        except ValidationError:
            return self._result('INVALID', f'"{email}" is not a valid email address.', 2)
        domain_error = email_domain_error(email)
        if domain_error:
            return self._result('INVALID', f'{domain_error} (CompuLab signs everyone in with a Gmail address).', 2)

        password = os.environ.get(PASSWORD_ENV, '')
        if not password:
            return self._result('INVALID', f'No password given (environment variable {PASSWORD_ENV}).', 2)
        try:
            validate_password(password, user=User(email=email))
        except ValidationError as e:
            return self._result('INVALID', 'The password is not accepted: ' + ' '.join(e.messages), 2)

        other = User.objects.filter(email__iexact=email).first()
        if other is not None:
            problems = admin_problems(other)
            return self._result('INVALID', f'An account with the email {_mask(email)} already exists but cannot be the '
                                           f'Administrator ({", ".join(problems)}). Use another Gmail address.', 2)

        try:
            with transaction.atomic():
                user = User.objects.create_superuser(email=email, password=password)
        except Exception as e:   # database error, constraint, ...: report, never the password
            return self._result('FAILED', f'Creating the Administrator failed: {e.__class__.__name__}: {e}', 1)

        user.refresh_from_db()
        problems = admin_problems(user)
        if problems:
            return self._result('FAILED', f'The account was created but cannot sign in as Administrator ({", ".join(problems)}).', 1)
        return self._result('CREATED', f'Administrator {_mask(email)} created.', 0)
