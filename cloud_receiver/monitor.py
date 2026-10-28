"""Permission-gated status/inventory dashboard showing edge snapshots, not LAN probes."""
from datetime import timedelta
from django.conf import settings
from django.contrib.auth.decorators import login_required
from django.http import JsonResponse, HttpResponseForbidden
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.cache import never_cache
from cloud_receiver.models import ReplicaRecord


def _authorized(request):
    user = request.user
    return (settings.CLOUD_RECEIVER_ENABLED and user.is_authenticated and
            user.is_active and user.is_staff and
            (user.is_superuser or getattr(user, 'role', '') == 'admin'))


@login_required
@never_cache
def monitor(request):
    if not _authorized(request):
        return HttpResponseForbidden('Cloud admin only')
    return render(request, 'cloud_receiver/monitor.html', {
        'poll_seconds': 10,
        'inventory_enabled': settings.CLOUD_INVENTORY_ENABLED,
    })


@login_required
@never_cache
def monitor_data(request):
    if not _authorized(request):
        return JsonResponse({'detail':'Cloud admin only'}, status=403)
    sites = list(settings.CLOUD_RECEIVER_SITES)
    site = request.GET.get('site', '').strip()
    if site and site not in sites:
        return JsonResponse({'detail':'Unknown site'}, status=400)
    qs = ReplicaRecord.objects.filter(deleted=False,
                  object_type__in=('lab','pc','inventory','maintenance_log','equipment_issue'))
    if site:
        qs = qs.filter(site_id=site)
    now = timezone.now()
    data = {'generated_at': now.isoformat(), 'sites': sites, 'pcs': [], 'labs': [],
            'inventory': [], 'maintenance_logs': [], 'equipment_issues': []}
    for record in qs.order_by('site_id','object_type','local_id').iterator():
        p = record.payload
        row = {'site_id':record.site_id, 'id':record.local_id,
               'synced_at': record.applied_at.isoformat() if record.applied_at else None,
               **{key:p.get(key) for key in (
                   ('name','location','opening_time','closing_time') if record.object_type == 'lab' else
                   ('pc_id','lab','ip_address','status','in_use','agent_version','agent_pending_events',
                    'last_seen_at','agent_last_contact_at','status_changed_at') if record.object_type == 'pc' else
                   ('name','category','lab','quantity','condition','status','last_checked','retired_at','revision') if record.object_type == 'inventory' else
                   ('equipment_id','maintenance_date','completed','notes') if record.object_type == 'maintenance_log' else
                   ('equipment_id','status','description')
               )}}
        if record.object_type == 'pc':
            # Two independent freshness checks: age of cloud sync and agent observation.
            source_time = p.get('agent_last_contact_at') or p.get('last_seen_at')
            from django.utils.dateparse import parse_datetime
            seen = parse_datetime(source_time) if isinstance(source_time,str) else None
            newest = p.get('last_seen_at')
            checked = parse_datetime(newest) if isinstance(newest,str) else None
            cloud_stale = not record.applied_at or record.applied_at < now - timedelta(seconds=90)
            agent_stale = checked is None or checked < now - timedelta(seconds=90)
            row['stale'] = cloud_stale or agent_stale
            row['effective_status'] = 'stale' if row['stale'] else p.get('status','offline')
            data['pcs'].append(row)
        elif record.object_type == 'lab':
            data['labs'].append(row)
        elif record.object_type == 'inventory':
            data['inventory'].append(row)
        elif record.object_type == 'maintenance_log':
            data['maintenance_logs'].append(row)
        else:
            data['equipment_issues'].append(row)
    return JsonResponse(data)
