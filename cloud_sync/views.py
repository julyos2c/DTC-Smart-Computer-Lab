"""Admin page for the cloud-sync queue: what is waiting, what failed, and
conflicts that need a decision. Linked from System status."""
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.core.exceptions import PermissionDenied
from django.db.models import Count
from django.shortcuts import get_object_or_404, redirect
from django.urls import reverse
from django.views.generic import ListView

from accounts.mixins import RoleRequiredMixin
from cloud_sync import sync
from cloud_sync.models import SyncQueue


class SyncQueueView(RoleRequiredMixin, ListView):
    allowed_roles = ['admin']
    template_name = 'cloud_sync/queue.html'
    context_object_name = 'rows'
    paginate_by = 25

    STATUS_FILTERS = {
        'waiting': ('pending', 'processing'),
        'problems': ('failed', 'conflict'),
        'synced': ('synced',),
        'other': ('superseded', 'resolved'),
    }

    def get_queryset(self):
        statuses = self.STATUS_FILTERS.get(self.request.GET.get('show', 'waiting'), self.STATUS_FILTERS['waiting'])
        order = '-id' if statuses == ('synced',) or statuses == ('superseded', 'resolved') else 'id'
        return SyncQueue.objects.filter(status__in=statuses).select_related('resolved_by').order_by(order)

    def get_context_data(self, **kwargs):
        from system.connectivity import get_summary
        ctx = super().get_context_data(**kwargs)
        counts = dict(SyncQueue.objects.values_list('status').annotate(n=Count('pk')))
        ctx['counts'] = {key: sum(counts.get(s, 0) for s in statuses) for key, statuses in self.STATUS_FILTERS.items()}
        ctx['show'] = self.request.GET.get('show', 'waiting')
        ctx['sync'] = sync.summary()
        ctx['summary'] = get_summary(use_cache=False)
        return ctx


def _require_admin_post(request):
    if request.user.role != 'admin':
        raise PermissionDenied
    return request.method == 'POST'


def _back(request):
    return redirect(f"{reverse('cloud_sync_queue')}?show={request.POST.get('show', 'waiting')}")


@login_required
def cloud_sync_retry_now(request):
    if _require_admin_post(request):
        if not sync.is_enabled():
            messages.info(request, 'Cloud sync is not configured, so there is nothing to send.')
        else:
            sync.retry_now()
            messages.success(request, 'Cloud sync will try again within a few seconds.')
    return _back(request)


@login_required
def cloud_sync_retry_failed(request):
    if _require_admin_post(request):
        n = sync.retry_all_failed()
        messages.success(request, f'{n} failed change{"s" if n != 1 else ""} will be sent again.')
    return _back(request)


@login_required
def cloud_sync_item_retry(request, pk):
    if _require_admin_post(request):
        row = get_object_or_404(SyncQueue, pk=pk)
        if row.status in ('failed', 'pending'):
            sync.retry_row(row)
            messages.success(request, f'{row.record_key} will be sent again.')
        else:
            messages.info(request, 'That change does not need a retry.')
    return _back(request)


@login_required
def cloud_sync_item_resolve(request, pk):
    if _require_admin_post(request):
        row = get_object_or_404(SyncQueue, pk=pk)
        keep = request.POST.get('keep')
        if row.status != 'conflict' or keep not in ('local', 'cloud'):
            messages.info(request, 'That conflict was already handled.')
        else:
            sync.resolve_conflict(row, keep, request.user)
            messages.success(request, (
                f'{row.record_key}: the campus copy will be sent and replace the cloud copy.' if keep == 'local'
                else f'{row.record_key}: the cloud copy was kept; this change will not be sent.'
            ))
    return _back(request)
