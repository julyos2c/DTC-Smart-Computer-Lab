from django.db import migrations, models


def backfill_previous_approved_reservations(apps, schema_editor):
    """Old approved sessions had no allocated count; preserve their seats."""
    Session = apps.get_model('scheduling', 'Session')
    SessionRequest = apps.get_model('scheduling', 'SessionRequest')
    for row in Session.objects.all().iterator():
        allocated = (row.pcs_requested if row.requester_type in ('walk_in', 'override')
                     else row.student_count)
        row.pcs_allocated = max(allocated, 1)
        row.save(update_fields=['pcs_allocated'])
    for req in SessionRequest.objects.filter(status='approved').iterator():
        if req.reservation_code:
            session = Session.objects.filter(reservation_code=req.reservation_code).first()
            if session:
                req.pcs_allocated = session.pcs_allocated
                req.save(update_fields=['pcs_allocated'])


class Migration(migrations.Migration):
    dependencies = [('scheduling', '0022_alter_sessionrequest_status')]

    operations = [
        migrations.AddField(model_name='session', name='pcs_allocated',
                            field=models.PositiveIntegerField(default=0,
                                help_text='PCs actually granted at approval. Zero on pending requests.')),
        migrations.AddField(model_name='sessionrequest', name='pcs_allocated',
                            field=models.PositiveIntegerField(default=0,
                                help_text='PCs actually granted at approval. Zero on pending requests.')),
        migrations.RunPython(backfill_previous_approved_reservations, migrations.RunPython.noop),
    ]
