from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('labs', '0017_alter_lab_closing_time_alter_lab_opening_time'),
    ]

    operations = [
        migrations.AddField(
            model_name='pc',
            name='current_login_via_override',
            field=models.BooleanField(default=False, help_text="True if the current session started via an Admin/In-Charge Override Check-In (see OverrideCheckInView) rather than a normal student unlock or a Manual Unlock guest walk-in. Set at grant time on every login/unlock path, then copied onto each PCActivityLog sample taken while this session is active so the PC Activity Log's Search/User filter can distinguish 'Override' sessions after the fact."),
        ),
        migrations.AddField(
            model_name='pcactivitylog',
            name='via_override',
            field=models.BooleanField(default=False, help_text='Copied from pc.current_login_via_override at capture time — True if this sample belongs to a session that started via an Admin/In-Charge Override Check-In.'),
        ),
    ]
