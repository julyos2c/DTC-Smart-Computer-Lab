from django.db import migrations, models
from notifications.models import Notification


class Migration(migrations.Migration):
    dependencies = [('notifications', '0010_alter_notification_notification_type')]
    operations = [
        migrations.AlterField(model_name='notification', name='notification_type',
                              field=models.CharField(max_length=30, default='general',
                                                     choices=Notification.TYPE_CHOICES)),
    ]
