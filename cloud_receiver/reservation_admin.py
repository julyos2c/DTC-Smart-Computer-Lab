"""Typed cloud forms: edits are intents, not writes to replica payloads."""
from datetime import timedelta
from django import forms
from django.conf import settings
from django.contrib import admin
from django.utils import timezone
from cloud_receiver.models import ReservationChange, ReplicaRecord


class ReservationReplicaChoice(forms.ModelChoiceField):
    def label_from_instance(self, obj):
        p = obj.payload
        return f"{obj.site_id} / #{obj.local_id}: {p.get('subject', '')} - {p.get('date', '')} ({p.get('status', '')})"


class ReservationChangeForm(forms.ModelForm):
    reservation = ReservationReplicaChoice(queryset=ReplicaRecord.objects.filter(object_type='reservation', deleted=False),
                                           required=False, label='Reservation to change')
    lab = forms.IntegerField(required=False, min_value=1, label='Campus lab database ID')
    requester_type = forms.ChoiceField(required=False, choices=[('', '---------'), ('student', 'Student'),
                                                                ('instructor', 'Instructor'), ('walk_in', 'Walk-in')])
    requester_name = forms.CharField(required=False, max_length=150)
    requester_id_number = forms.CharField(required=False, max_length=50)
    subject = forms.CharField(required=False, max_length=200)
    date = forms.DateField(required=False, widget=forms.DateInput(attrs={'type': 'date'}))
    start_time = forms.TimeField(required=False, widget=forms.TimeInput(attrs={'type': 'time'}))
    end_time = forms.TimeField(required=False, widget=forms.TimeInput(attrs={'type': 'time'}))
    student_count = forms.IntegerField(required=False, min_value=0)
    pcs_requested = forms.IntegerField(required=False, min_value=0)
    notes = forms.CharField(required=False, widget=forms.Textarea(attrs={'rows': 3}))
    clear_notes = forms.BooleanField(required=False, label='Clear existing notes')

    class Meta:
        model = ReservationChange
        fields = ('site_id', 'action', 'reservation', 'lab', 'requester_type', 'requester_name',
                  'requester_id_number', 'subject', 'date', 'start_time', 'end_time',
                  'student_count', 'pcs_requested', 'notes', 'clear_notes', 'expires_at')

    def clean(self):
        data = super().clean()
        if data.get('site_id') not in settings.CLOUD_RECEIVER_SITES:
            self.add_error('site_id', 'Choose a configured campus site.')
        expiry = data.get('expires_at')
        if expiry and not timezone.now() < expiry <= timezone.now() + timedelta(days=7):
            self.add_error('expires_at', 'Expiry must be within the next seven days.')
        target = data.get('reservation')
        if data.get('action') == 'create':
            if target:
                self.add_error('reservation', 'Leave this empty when creating a reservation.')
            for key in ('lab', 'requester_type', 'requester_name', 'requester_id_number', 'subject', 'date', 'start_time', 'end_time'):
                if not data.get(key):
                    self.add_error(key, 'Required for a new reservation.')
        else:
            if not target:
                self.add_error('reservation', 'Choose the latest campus reservation copy.')
            elif target.site_id != data.get('site_id'):
                self.add_error('reservation', 'Reservation belongs to a different campus.')
            elif not isinstance(target.payload.get('revision'), str) or len(target.payload['revision']) != 64:
                self.add_error('reservation', 'This copy needs a fresh sync from the updated edge first.')
        payload = {}
        if data.get('action') in ('create', 'update'):
            from cloud_sync.reservations import FIELDS
            for key in FIELDS:
                value = data.get(key)
                if value not in (None, ''):
                    payload[key] = value.isoformat() if hasattr(value, 'isoformat') else value
            if data.get('action') == 'create':
                payload.setdefault('student_count', 0)
                payload.setdefault('pcs_requested', 0)
        if data.get('action') == 'update' and data.get('clear_notes'):
            payload['notes'] = ''
        self.instance.payload = payload
        self.instance.target_id = target.local_id if target else None
        self.instance.base_revision = target.payload.get('revision', '') if target else ''
        return data


@admin.register(ReservationChange)
class ReservationChangeAdmin(admin.ModelAdmin):
    form = ReservationChangeForm
    list_display = ('id', 'site_id', 'action', 'target_id', 'requested_by', 'status', 'created_at')
    list_filter = ('site_id', 'action', 'status')
    readonly_fields = ('id', 'target_id', 'base_revision', 'payload', 'requested_by', 'created_at',
                       'status', 'result', 'completed_at')

    def has_module_permission(self, request):
        return self.has_view_permission(request)

    def has_view_permission(self, request, obj=None):
        return (settings.CLOUD_RECEIVER_ENABLED and settings.CLOUD_RESERVATIONS_ENABLED
                and request.user.is_active and request.user.is_staff
                and (request.user.is_superuser or request.user.role == 'admin'))

    def has_add_permission(self, request):
        return self.has_view_permission(request)

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def save_model(self, request, obj, form, change):
        obj.requested_by = request.user.get_username()
        super().save_model(request, obj, form, change)
