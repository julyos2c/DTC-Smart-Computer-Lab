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
