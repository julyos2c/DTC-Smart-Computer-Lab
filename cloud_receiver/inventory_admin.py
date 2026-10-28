"""Typed, permission-gated inventory intents instead of editing JSON replicas."""
from datetime import timedelta
from django import forms
from django.conf import settings
from django.contrib import admin
from django.utils import timezone
from cloud_receiver.models import InventoryChange, ReplicaRecord


class InventoryReplicaField(forms.ModelChoiceField):
    def label_from_instance(self, obj):
        return f"{obj.site_id} / #{obj.local_id}: {obj.payload.get('name', '')} ({obj.payload.get('status', '')})"


class InventoryChangeForm(forms.ModelForm):
    inventory_record = InventoryReplicaField(
        queryset=ReplicaRecord.objects.filter(object_type__in=('inventory','pc'), deleted=False),
        required=False, label='Existing equipment / PC to edit or delete')
    pc_id = forms.CharField(max_length=10, required=False, label='PC label / ID')
    ip_address = forms.GenericIPAddressField(required=False, label='PC LAN IP address')
    name = forms.CharField(max_length=200, required=False)
    category = forms.CharField(max_length=100, required=False)
    quantity = forms.IntegerField(min_value=0, required=False)
    condition = forms.ChoiceField(choices=[('', '---'), ('good','Good'), ('fair','Fair'),
                                                ('needs_check','Needs check'), ('faulty','Faulty')], required=False)
    asset_status = forms.ChoiceField(choices=[('', '---'), ('operational','Operational'),
                                             ('under_repair','Under repair'), ('retired','Retired')], required=False)
    lab = forms.IntegerField(min_value=1, required=False, label='Campus lab ID')
    last_checked = forms.DateField(required=False, widget=forms.DateInput(attrs={'type': 'date'}))
    retirement_reason = forms.CharField(max_length=255, required=False)

    class Meta:
        model = InventoryChange
        fields = ('site_id', 'object_type', 'action', 'inventory_record', 'name', 'category', 'quantity', 'condition',
                  'asset_status', 'lab', 'last_checked', 'retirement_reason', 'pc_id',
                  'ip_address', 'expires_at')

    def clean(self):
        data = super().clean()
        site = data.get('site_id')
        if site not in settings.CLOUD_RECEIVER_SITES:
            self.add_error('site_id', 'Choose a configured site.')
        if data.get('expires_at') and not timezone.now() < data['expires_at'] <= timezone.now() + timedelta(days=7):
            self.add_error('expires_at', 'Expiry must be within the next seven days.')
        target = data.get('inventory_record')
        action = data.get('action')
        obj_type = data.get('object_type') or 'inventory'
        if target and target.object_type != obj_type:
            self.add_error('inventory_record', 'Choose a record of the selected type.')
        if action == 'create':
            if target:
                self.add_error('inventory_record', 'Leave blank when creating.')
            if obj_type == 'pc':
                for field in ('pc_id', 'ip_address', 'lab'):
                    if not data.get(field):
                        self.add_error(field, 'Required when adding a PC.')
            for field in (() if obj_type == 'pc' else ('name', 'category', 'condition', 'lab')):
                if not data.get(field):
                    self.add_error(field, 'Required when creating an item.')
            if obj_type == 'inventory' and data.get('quantity') is None:
                self.add_error('quantity', 'Required when creating an item.')
        else:
            if target is None:
                self.add_error('inventory_record', 'Select a synchronized item.')
            elif target.site_id != site:
                self.add_error('inventory_record', 'Item belongs to another site.')
            elif len(target.payload.get('revision', '')) != 64:
                self.add_error('inventory_record', 'Sync the latest inventory snapshot first.')
        if action == 'delete':
            self.instance.payload = {}
        else:
            fields = (('pc_id','ip_address','lab') if obj_type == 'pc' else
                      ('name','category','quantity','condition','asset_status','lab','last_checked','retirement_reason'))
            self.instance.payload = {('status' if key == 'asset_status' else key): value.isoformat() if hasattr(value,'isoformat') else value
                                     for key in fields if (value := data.get(key)) is not None and value != ''}
        self.instance.target_id = target.local_id if target else None
        self.instance.base_revision = target.payload.get('revision', '') if target else ''
        return data


@admin.register(InventoryChange)
class InventoryChangeAdmin(admin.ModelAdmin):
    form = InventoryChangeForm
    list_display = ('site_id','object_type','action','target_id','requested_by','status','created_at','completed_at')
    list_filter = ('site_id','action','status')
    readonly_fields = ('id','target_id','base_revision','payload','requested_by','created_at',
                       'status','result','completed_at')

    def has_view_permission(self, request, obj=None):
        return bool(settings.CLOUD_RECEIVER_ENABLED and settings.CLOUD_INVENTORY_ENABLED
                    and request.user.is_authenticated and request.user.is_active
                    and request.user.is_staff and
                    (request.user.is_superuser or getattr(request.user, 'role', '') == 'admin'))

    def has_module_permission(self, request):
        return self.has_view_permission(request)

    def has_add_permission(self, request):
        return self.has_view_permission(request)

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def save_model(self, request, obj, form, change):
        obj.requested_by = request.user.get_username()
        super().save_model(request, obj, form, change)
