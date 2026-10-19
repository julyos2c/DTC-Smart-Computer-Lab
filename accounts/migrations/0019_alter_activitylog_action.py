from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('accounts', '0018_alter_activitylog_action'),
    ]

    operations = [
        migrations.AlterField(
            model_name='activitylog',
            name='action',
            field=models.CharField(choices=[('register', 'User Registered'), ('activate', 'Account Activated'), ('deactivate', 'Account Deactivated'), ('delete', 'User Deleted'), ('reset_password', 'Password Reset'), ('change_password', 'Password Changed'), ('pc_unlock', 'Lab PC Unlocked'), ('pc_lock', 'Lab PC Locked'), ('pc_shutdown', 'Lab PC Shutdown'), ('pc_restart', 'Lab PC Restarted')], max_length=20),
        ),
    ]
