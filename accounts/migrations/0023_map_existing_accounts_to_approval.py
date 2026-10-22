"""Give existing accounts an approval state, so nobody who can sign in today
is locked out after the upgrade (docs/OFFLINE_ACCOUNT_VERIFICATION.md §5.1):

* verified email  -> approved ('migrated'); email_verified_at = migration
  time (the real time was never recorded)
* superusers      -> approved ('migrated'), even if their email is unverified
* unverified staff-> stay 'pending' (same as today: they can't sign in yet)
* students        -> untouched (they never sign in to the website)

Only fills in the new columns; no existing data is changed or removed."""
from django.db import migrations
from django.utils import timezone


def forwards(apps, schema_editor):
    User = apps.get_model('accounts', 'User')
    now = timezone.now()
    User.objects.filter(email_verified=True, email_verified_at__isnull=True).update(email_verified_at=now)
    User.objects.exclude(role='student').filter(email_verified=True).update(
        approval_status='approved', approval_method='migrated', approved_at=now,
    )
    User.objects.filter(is_superuser=True).exclude(approval_status='approved').update(
        approval_status='approved', approval_method='migrated', approved_at=now,
    )


def backwards(apps, schema_editor):
    # The columns themselves are removed by reversing 0022; nothing to undo here.
    pass


class Migration(migrations.Migration):

    dependencies = [
        ('accounts', '0022_user_approval_method_user_approval_status_and_more'),
    ]

    operations = [
        migrations.RunPython(forwards, backwards),
    ]
