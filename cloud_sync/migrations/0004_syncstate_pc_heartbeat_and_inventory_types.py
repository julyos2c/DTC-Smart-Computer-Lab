from django.db import migrations, models

class Migration(migrations.Migration):
    dependencies = [('cloud_sync', '0003_fill_status_and_record_key')]
    operations = [
        migrations.AddField(model_name='syncstate', name='last_pc_snapshot_at',
                            field=models.DateTimeField(blank=True, null=True)),
        migrations.AlterField(model_name='syncqueue', name='object_type',
            field=models.CharField(max_length=20, choices=[
                ('reservation','Reservation'), ('session','Session'), ('issue','Issue'),
                ('activity_log','PC Activity Log'), ('notification','Notification'),
                ('lab','Laboratory'), ('pc','PC Live Status'), ('inventory','Inventory Item'),
                ('maintenance_log','Maintenance Log'), ('equipment_issue','Equipment Issue'),
            ])),
    ]
