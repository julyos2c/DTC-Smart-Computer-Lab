import cloud_receiver.inventory_models
import uuid
from django.db import migrations, models

class Migration(migrations.Migration):
    dependencies = [('cloud_receiver', '0003_reservationchange_reservationreceipt')]
    operations = [
        migrations.CreateModel(name='InventoryChange', fields=[
            ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
            ('site_id', models.CharField(max_length=64)),
            ('object_type', models.CharField(choices=[('inventory', 'Equipment inventory'), ('pc', 'PC registration')], default='inventory', max_length=20)),
            ('action', models.CharField(choices=[('create','Create'),('update','Update'),('delete','Delete')], max_length=10)),
            ('target_id', models.PositiveBigIntegerField(blank=True, editable=False, null=True)),
            ('base_revision', models.CharField(blank=True, editable=False, max_length=64)),
            ('payload', models.JSONField(default=dict, editable=False)),
            ('requested_by', models.CharField(editable=False, max_length=254)),
            ('created_at', models.DateTimeField(auto_now_add=True)),
            ('expires_at', models.DateTimeField(default=cloud_receiver.inventory_models.inventory_expiry)),
            ('status', models.CharField(default='pending', editable=False, max_length=12)),
            ('result', models.JSONField(default=dict, editable=False)),
            ('completed_at', models.DateTimeField(editable=False, null=True)),
        ], options={'ordering':['-created_at']}),
        migrations.CreateModel(name='InventoryReceipt', fields=[
            ('id', models.UUIDField(editable=False, primary_key=True, serialize=False)),
            ('site_id', models.CharField(max_length=64)),
            ('status', models.CharField(max_length=12)),
            ('result', models.JSONField(default=dict)),
            ('reported', models.BooleanField(default=False)),
            ('created_at', models.DateTimeField(auto_now_add=True)),
        ]),
    ]
