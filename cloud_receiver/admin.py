from django.conf import settings
from django.contrib import admin
from django.utils import timezone

from cloud_receiver.models import AppliedChange, ReplicaRecord


@admin.register(ReplicaRecord)
class ReplicaRecordAdmin(admin.ModelAdmin):
    """Cloud copies. Editing one here marks it as edited on the cloud: the
    next campus change to it is answered 'conflict' and waits for an Admin
    on the campus server (System status > Cloud sync)."""
    list_display = ('site_id', 'object_type', 'local_id', 'deleted', 'last_sequence', 'applied_at', 'cloud_modified_at')
    list_filter = ('site_id', 'object_type', 'deleted')
    search_fields = ('local_id',)
    readonly_fields = ('site_id', 'object_type', 'local_id', 'schema_version', 'deleted', 'last_sequence',
                       'last_edge_id', 'applied_at', 'cloud_modified_at', 'cloud_modified_by')

    def has_add_permission(self, request):
        return False   # records come only from campus servers

    def has_change_permission(self, request, obj=None):
        if obj and obj.object_type in ('reservation', 'inventory', 'pc', 'lab',
                                        'maintenance_log', 'equipment_issue'):
            return False  # Edge-owned replicas; changes use verified intent endpoints
        return super().has_change_permission(request, obj)

    def save_model(self, request, obj, form, change):
        obj.cloud_modified_at = timezone.now()
        obj.cloud_modified_by = request.user.get_username()
        super().save_model(request, obj, form, change)


@admin.register(AppliedChange)
class AppliedChangeAdmin(admin.ModelAdmin):
    list_display = ('edge_id', 'site_id', 'record', 'sequence', 'operation', 'forced', 'applied_at')
    list_filter = ('site_id', 'operation', 'forced')
    readonly_fields = [f.name for f in AppliedChange._meta.fields]

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

from django import forms
from django.conf import settings
from cloud_receiver.models import RemoteCommand


class RemoteCommandForm(forms.ModelForm):
    class Meta:
        model = RemoteCommand
        fields = ('site_id', 'pc_pk', 'action', 'expires_at')

    def clean(self):
        data = super().clean()
        from datetime import timedelta
        if data.get('site_id') not in settings.CLOUD_RECEIVER_SITES:
            raise forms.ValidationError('Choose a configured campus site.')
        expiry = data.get('expires_at')
        if expiry and not timezone.now() < expiry <= timezone.now() + timedelta(minutes=5):
            raise forms.ValidationError('Expiry must be within the next five minutes.')
        return data


@admin.register(RemoteCommand)
class RemoteCommandAdmin(admin.ModelAdmin):
    form = RemoteCommandForm
    list_display = ('id', 'site_id', 'pc_pk', 'action', 'requested_by', 'status', 'created_at', 'expires_at')
    list_filter = ('site_id', 'status', 'action')
    readonly_fields = ('id', 'requested_by', 'created_at', 'status', 'detail', 'completed_at')

    def has_module_permission(self, request):
        return self.has_view_permission(request)

    def has_view_permission(self, request, obj=None):
        return (settings.CLOUD_RECEIVER_ENABLED and settings.CLOUD_REMOTE_CONTROL_ENABLED
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

from . import reservation_admin  # noqa: F401,E402
from . import inventory_admin  # noqa: F401,E402
