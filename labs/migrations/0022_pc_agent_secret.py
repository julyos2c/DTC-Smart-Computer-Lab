# Per-PC agent secrets (labs/agent_auth.py). Additive: existing PCs get an
# empty secret and keep using PC_AGENT_SHARED_SECRET until their Agent config
# is downloaded again and the agent is reinstalled with it.

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('labs', '0021_pc_agent_last_contact_at_pc_agent_pending_events_and_more'),
    ]

    operations = [
        migrations.AddField(
            model_name='pc',
            name='agent_secret',
            field=models.CharField(blank=True, default='', editable=False, max_length=64),
        ),
        migrations.AddField(
            model_name='pc',
            name='agent_secret_in_use',
            field=models.BooleanField(default=False, editable=False, help_text='The agent on this PC authenticated with its own secret; the shared secret is no longer accepted for it.'),
        ),
    ]
