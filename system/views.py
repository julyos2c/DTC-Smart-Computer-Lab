import socket

from django.conf import settings
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.core.exceptions import PermissionDenied
from django.http import HttpResponse, JsonResponse
from django.shortcuts import redirect
from django.views.decorators.cache import never_cache
from django.views.generic import TemplateView

from accounts.mixins import RoleRequiredMixin
from system import connectivity

LOCAL_ADDRESSES = {'127.0.0.1', '::1'}
# Headers a local reverse proxy (e.g. `tailscale serve`) adds. A request
# carrying them came from another machine, even though the proxy itself
# connects from 127.0.0.1.
PROXY_HEADERS = ('HTTP_X_FORWARDED_FOR', 'HTTP_X_FORWARDED_HOST', 'HTTP_TAILSCALE_USER_LOGIN', 'HTTP_FORWARDED')


def _from_this_server(request):
    if request.META.get('REMOTE_ADDR') not in LOCAL_ADDRESSES:
        return False
    return not any(request.META.get(h) for h in PROXY_HEADERS)


@never_cache
def healthz(request):
    """Public liveness check: the web service is up and answering. Used by
    the installer, the staff launcher, lab PC agents and the page footer
    ("local server reachable from this computer")."""
    return HttpResponse('ok', content_type='text/plain')


def _iso(value):
    return value.isoformat() if value else None


@never_cache
def healthz_ready(request):
    """Readiness details for the installer / launcher / monitoring. Only
    from the server itself or for a signed-in Admin, since it reveals
    internal state."""
    is_admin = request.user.is_authenticated and request.user.role == 'admin'
    if not (_from_this_server(request) or is_admin):
        return JsonResponse({'detail': 'Only available on the server itself or to Admins.'}, status=403)

    db_ok, db_detail = connectivity.probe_database()
    s = connectivity.get_summary(use_cache=False)
    sync = s['sync']
    body = {
        'headline': s['headline'],
        'database': {'ok': db_ok, 'detail': db_detail},
        'worker': {'alive': s['worker_alive'], 'last_heartbeat': _iso(s['worker']['checked_at']),
                   'problems': s['worker_problems']},
        'smtp': {'ok': s['smtp']['ok'], 'configured': s['smtp_configured'], 'since': _iso(s['smtp']['since'])},
        'internet': {'ok': s['internet']['ok'], 'since': _iso(s['internet']['since'])},
        'cloud': {'ok': s['cloud']['ok'], 'configured': sync['enabled'], 'detail': s['cloud']['detail'],
                  'since': _iso(s['cloud']['since'])},
        'cloud_sync': {'pending': sync['pending'], 'processing': sync['processing'], 'failed': sync['failed'],
                       'conflicts': sync['conflict'], 'last_success': _iso(sync['last_success_at']),
                       'paused': sync['paused_reason'] or None},
        'email_outbox': {'waiting': s['emails_waiting'], 'dead': s['emails_dead']},
        'lab_agents': {'pcs': s['agents']['pcs'], 'recent': s['agents']['agents_recent'],
                       'offline': s['agents']['offline'], 'last_contact': _iso(s['agents']['last_agent_contact'])},
        'urls': {'lan': s['lan_url'], 'remote': s['remote_url'] or None},
    }
    return JsonResponse(body, status=200 if db_ok else 503)


def _lan_addresses():
    """Best-effort list of this server's IPv4 addresses, shown on the status
    page so staff know which address lab PCs and browsers should use."""
    addresses = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addresses.add(info[4][0])
    except OSError:
        pass
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(('10.255.255.255', 1))  # no packet is sent for UDP connect
            addresses.add(s.getsockname()[0])
    except OSError:
        pass
    return sorted(a for a in addresses if not a.startswith('127.'))


def _port_of(url, default='8000'):
    from urllib.parse import urlsplit
    try:
        return str(urlsplit(url).port or default)
    except ValueError:
        return default


class SystemStatusView(RoleRequiredMixin, TemplateView):
    """Admin page: what is running, what is reachable, and what is waiting —
    the place to look when the campus internet drops or emails don't arrive."""
    allowed_roles = ['admin']
    template_name = 'system/status.html'

    def get_context_data(self, **kwargs):
        from labs.models import PC
        from system.models import ScheduledJob
        ctx = super().get_context_data(**kwargs)
        s = connectivity.get_summary(use_cache=False)
        ctx['summary'] = s
        ctx['probes'] = [
            ('Database', s['database'], 'MariaDB on this server. If it is down nothing can be saved: start the MariaDB service.'),
            ('Internet', s['internet'], 'Only email and cloud sync need it. Everything on the campus network works without it.'),
            ('Email server (SMTP)', s['smtp'], 'Emails wait in the outbox while it is unreachable and are sent automatically later.'),
            ('Cloud sync receiver', s['cloud'], 'Optional. Changes wait in the sync queue while it is unreachable.'),
        ]
        ctx['email_hint'] = connectivity.email_error_hint(s['last_email_error'])
        ctx['recent_jobs'] = ScheduledJob.objects.order_by('-created_at')[:10]
        ctx['lan_addresses'] = _lan_addresses()
        ctx['lan_port'] = _port_of(settings.SITE_URL)
        ctx['site_url'] = settings.SITE_URL
        ctx['remote_url'] = getattr(settings, 'REMOTE_URL', '')
        ctx['hostname'] = socket.gethostname()
        ctx['background_mode'] = 'in-process' if settings.RUN_BACKGROUND_TASKS else 'separate worker service'
        ctx['cloud_sync_enabled'] = getattr(settings, 'CLOUD_SYNC_ENABLED', False)
        ctx['agent_pcs'] = (
            PC.objects.filter(ip_address__isnull=False).select_related('lab')   # blank IPs are stored as NULL
            .order_by('lab__name', 'pc_id')[:200]
        )
        from labs import agent_auth
        ctx['agent_secrets'] = agent_auth.summary(PC.objects.only('agent_secret', 'agent_secret_in_use'))
        return ctx


@login_required
def system_recheck(request):
    """Admin button: run the connectivity probes now (normally every
    minute on the worker) and resume the queues if something came back."""
    if request.user.role != 'admin':
        raise PermissionDenied
    if request.method == 'POST':
        from cloud_sync import sync
        from notifications import outbox
        came_back = connectivity.run_probes()
        if came_back & {'internet', 'smtp'}:
            outbox.resume()
        if came_back & {'internet', 'cloud'}:
            sync.resume()
        connectivity.get_summary(use_cache=False)
        messages.success(request, 'Checked again: ' + connectivity.get_summary()['headline'])
    return redirect('system_status')
