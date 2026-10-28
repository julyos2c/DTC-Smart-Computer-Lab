from django.contrib.auth.models import AbstractUser
from django.contrib.auth.base_user import BaseUserManager
from django.conf import settings
from django.db import models
from accounts.constants import DEPARTMENT_CHOICES, department_name, YEAR_LEVEL_LABELS


class UserManager(BaseUserManager):
    """Custom manager for the email-based User model (no username field).

    Admin, Lab In-Charge, and Instructor accounts are created with an
    email — that's their login credential. Student accounts are created
    with email=None — they never log into the web dashboard at all, so
    they don't need (and can't be required to have) one. See
    accounts/forms.py for the role-based rules enforced at the form level.
    """
    use_in_migrations = True

    def _create_user(self, email, password, **extra_fields):
        email = self.normalize_email(email) if email else None
        from accounts.email_rules import email_domain_error
        _err = email_domain_error(email)
        if _err:
            raise ValueError(f'{email}: {_err}')
        user = self.model(email=email, **extra_fields)
        user.set_password(password)
        user.save(using=self._db)
        return user

    def create_user(self, email=None, password=None, **extra_fields):
        extra_fields.setdefault('is_staff', False)
        extra_fields.setdefault('is_superuser', False)
        return self._create_user(email, password, **extra_fields)

    def create_superuser(self, email=None, password=None, **extra_fields):
        extra_fields.setdefault('is_staff', True)
        extra_fields.setdefault('is_superuser', True)
        extra_fields.setdefault('role', 'admin')
        extra_fields.setdefault('approval_status', 'approved')
        extra_fields.setdefault('approval_method', 'superuser_bootstrap')
        if not email:
            raise ValueError('Superuser must have an email address.')
        if extra_fields.get('is_staff') is not True:
            raise ValueError('Superuser must have is_staff=True.')
        if extra_fields.get('is_superuser') is not True:
            raise ValueError('Superuser must have is_superuser=True.')
        return self._create_user(email, password, **extra_fields)


class User(AbstractUser):
    # No username field anywhere in the system — Email (Gmail) is the login
    # credential for Admin/Lab In-Charge/Instructor accounts instead.
    # Students don't authenticate here at all (they sign in at the lab PC
    # with their Student ID Number + a reservation code — see
    # labs.views.ReservationPCLoginView), so email is optional for them:
    # null=True/blank=True lets a Student's email stay empty without
    # tripping the unique constraint (multiple NULLs are allowed; multiple
    # empty strings would collide, so accounts/forms.py always stores None,
    # never '', for Students).
    username = None
    email = models.EmailField(
        'email address', max_length=254, unique=True, null=True, blank=True,
        error_messages={'unique': 'A user with that email address already exists.'},
        help_text='Required and unique for every account. Login credential for Admin, '
                   'Lab In-Charge, and Instructor accounts. Students never log in with it '
                   '(they sign in at the lab PC with their Student ID Number and a '
                   'reservation code instead) — for them this is instead where '
                   'roster/reservation notifications get sent. null=True/blank=True stays '
                   'set at the DB level only so pre-existing Student rows saved before '
                   'this was required don\'t break; every form now requires it going forward.'
    )
    USERNAME_FIELD = 'email'
    REQUIRED_FIELDS = []

    objects = UserManager()

    ROLE_CHOICES = [
        ('admin', 'Admin'),
        ('incharge', 'Lab In-charge'),
        ('instructor', 'Instructor'),
        ('student', 'Student'),
    ]
    role = models.CharField(max_length=20, choices=ROLE_CHOICES, default='instructor')
    id_number = models.CharField(
        max_length=50, blank=True, default='',
        help_text='Student/Instructor ID — used to match this account to reservation requests and lab PC check-ins. For Students, this doubles as their login credential at the lab PC (paired with a reservation code).'
    )
    department = models.CharField(
        max_length=100, blank=True, default='', choices=DEPARTMENT_CHOICES,
        help_text='Instructors and students — which department/college this account belongs to. '
                   'Shown wherever this user\'s details are displayed, and determines the year levels '
                   'available below for students.'
    )
    year_level = models.PositiveSmallIntegerField(
        null=True, blank=True, choices=list(YEAR_LEVEL_LABELS.items()),
        help_text='Student year level (1-4).'
    )
    assigned_lab = models.ForeignKey(
        'labs.Lab',
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name='assigned_users'
    )
    avatar = models.ImageField(upload_to='avatars/', blank=True, null=True)
    THEME_CHOICES = [
        ('dark', 'Dark'),
        ('light', 'Light'),
    ]
    theme = models.CharField(
        max_length=5, choices=THEME_CHOICES, default='dark',
        help_text='Dark/Light interface preference — saved per account so it follows the user to any PC they log in on.'
    )
    email_verified = models.BooleanField(
        default=False,
        help_text='True once this account has clicked the verification link sent to its email. '
                   'Admin, Lab In-Charge, and Instructor accounts cannot log in until this is True. '
                   'Not used by Students (they never have an email or log in here).'
    )
    email_verification_sent_at = models.DateTimeField(
        null=True, blank=True, editable=False,
        help_text='When the latest verification email was sent. Only the link in that email '
                   'is valid, and it rate-limits resends (see accounts/verification.py).'
    )
    email_verified_at = models.DateTimeField(
        null=True, blank=True, editable=False,
        help_text='When the owner proved they control this mailbox (clicked the emailed link).',
    )

    # Administrator approval is recorded separately from email ownership, so
    # an account can be activated in person while the campus is offline
    # (accounts/lifecycle.py). Signing in needs a verified email OR approval.
    APPROVAL_CHOICES = [
        ('pending', 'Pending'),
        ('approved', 'Approved'),
        ('rejected', 'Rejected'),
    ]
    APPROVAL_METHOD_CHOICES = [
        ('email_link', 'Email verification link'),
        ('in_person_code', 'In person (activation code)'),
        ('superuser_bootstrap', 'Created on the server'),
        ('migrated', 'Existing account'),
    ]
    approval_status = models.CharField(max_length=10, choices=APPROVAL_CHOICES, default='pending')
    approval_method = models.CharField(max_length=20, choices=APPROVAL_METHOD_CHOICES, blank=True, default='')
    approved_by = models.ForeignKey(
        'self', null=True, blank=True, on_delete=models.SET_NULL, related_name='approved_accounts',
    )
    approved_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        verbose_name = 'user'
        verbose_name_plural = 'users'
        abstract = False
        constraints = [
            models.CheckConstraint(
                check=models.Q(year_level__isnull=True) | models.Q(year_level__gte=1, year_level__lte=4),
                name='user_year_level_1_to_4',
            ),
        ]

    def __str__(self):
        return f'{self.display_name} ({self.role})'

    def clean(self):
        # Deliberately does NOT call super().clean(): AbstractUser.clean()
        # unconditionally runs self.email through
        # UserManager.normalize_email(), which coerces a blank/None email
        # into '' — that would silently undo the None (never '') this
        # model relies on for Student accounts (see the email field's
        # help text above): multiple '' values collide against the
        # unique constraint, multiple None values don't. Only normalize
        # when there's an actual email to normalize.
        if self.email:
            self.email = self.__class__.objects.normalize_email(self.email)

    @property
    def display_name(self):
        """Best available human-readable identifier for this account, used
        everywhere the system used to fall back to `username`. Full name
        first; if that's blank, fall back to Email, then Student/Instructor
        ID, then a generic placeholder — there's always something to show."""
        return self.get_full_name() or self.email or self.id_number or f'Account #{self.pk}'

    @property
    def department_display(self):
        """Human-readable department name — falls back to the raw stored
        value for any legacy/free-text department that predates the
        Department dropdown, so old records don't just show blank."""
        return department_name(self.department) or self.department

    @property
    def year_level_display(self):
        if not self.year_level:
            return ''
        return YEAR_LEVEL_LABELS.get(self.year_level, f'Year {self.year_level}')

    @property
    def program_year_display(self):
        """Combined 'Department — Year Level' summary (e.g. 'BSIS — 1st
        Year') used anywhere the old free-text Course & Year/Section field
        used to be shown, now derived from the two structured fields
        instead so it always stays in sync with them."""
        parts = [p for p in [self.department_display, self.year_level_display] if p]
        return ' — '.join(parts)


class AccountActionCode(models.Model):
    """A one-time code an Admin hands to one specific person, in person, so
    they can set their own password without email: 'activate' for a new
    staff account (also approves it), 'reset_password' for a forgotten
    password. Only an HMAC of the code is stored; the plain code is shown
    once to the Admin and never stored, logged or emailed."""
    PURPOSE_CHOICES = [
        ('activate', 'Account activation'),
        ('reset_password', 'Password reset'),
    ]
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='action_codes')
    purpose = models.CharField(max_length=20, choices=PURPOSE_CHOICES)
    code_hash = models.CharField(max_length=64)
    issued_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, null=True, on_delete=models.SET_NULL, related_name='issued_action_codes',
    )
    issued_at = models.DateTimeField(auto_now_add=True)
    issued_from_ip = models.GenericIPAddressField(null=True, blank=True)
    expires_at = models.DateTimeField()
    used_at = models.DateTimeField(null=True, blank=True)
    revoked_at = models.DateTimeField(null=True, blank=True)
    failed_attempts = models.PositiveSmallIntegerField(default=0)

    class Meta:
        ordering = ['-issued_at']

    def __str__(self):
        return f'{self.get_purpose_display()} code for {self.user}'


class ActivityLog(models.Model):
    ACTION_CHOICES = [
        ('register', 'User Registered'),
        ('activate', 'Account Activated'),
        ('deactivate', 'Account Deactivated'),
        ('delete', 'User Deleted'),
        ('reset_password', 'Password Reset'),
        ('change_password', 'Password Changed'),
        ('pc_unlock', 'Lab PC Unlocked'),
        ('pc_lock', 'Lab PC Locked'),
        ('pc_shutdown', 'Lab PC Shutdown'),
        ('pc_restart', 'Lab PC Restarted'),
        ('approve_account', 'Account Approved'),
        ('reject_account', 'Account Rejected'),
        ('issue_activation_code', 'Activation Code Issued'),
        ('redeem_activation_code', 'Account Activated with Code'),
        ('issue_reset_code', 'Reset Code Issued'),
        ('redeem_reset_code', 'Password Reset with Code'),
        ('email_verified', 'Email Verified'),
        ('reservation_cancelled', 'Reservation Cancelled'),
    ]
    actor = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        on_delete=models.SET_NULL,
        related_name='actions_performed'
    )
    action = models.CharField(max_length=30, choices=ACTION_CHOICES)
    target_identifier = models.CharField(
        max_length=150,
        help_text='Email (Admin/Lab In-Charge/Instructor) or Student/Instructor ID '
                   '(Student) of the account this log entry is about — kept as plain '
                   'text so the log entry survives even if the account is later '
                   'edited or deleted.'
    )
    details = models.TextField(blank=True)
    pc = models.ForeignKey(
        'labs.PC',
        null=True, blank=True,
        on_delete=models.SET_NULL,
        related_name='usage_logs',
        help_text='The lab PC this event happened on, set for pc_unlock events. Lets us answer "which PC was used on date X" reliably.',
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f'{self.get_action_display()} — {self.target_identifier}'

    @property
    def actor_display(self):
        """Safe display name for `actor` — templates should use this instead
        of chaining `log.actor.get_full_name|default:log.actor.email`,
        since actor is null=True/SET_NULL (the account may have since been
        deleted) and that chained lookup blows up with
        VariableDoesNotExist when actor is None."""
        if not self.actor:
            return '—'
        return self.actor.display_name