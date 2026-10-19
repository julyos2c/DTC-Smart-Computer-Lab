from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('accounts', '0017_user_email_verified'),
    ]

    operations = [
        migrations.AlterField(
            model_name='activitylog',
            name='action',
            field=models.CharField(choices=[('register', 'User Registered'), ('activate', 'Account Activated'), ('deactivate', 'Account Deactivated'), ('delete', 'User Deleted'), ('reset_password', 'Password Reset'), ('change_password', 'Password Changed'), ('pc_unlock', 'Lab PC Unlocked')], max_length=20),
        ),
    ]
