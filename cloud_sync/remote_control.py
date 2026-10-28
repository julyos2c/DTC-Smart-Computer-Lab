"""Edge polls outbound HTTPS; local receipts prevent repeated PC commands."""
from datetime import timedelta
import json
import logging
import uuid
import urllib.request
from urllib.parse import urlsplit
from django.conf import settings
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from cloud_receiver.models import CommandReceipt

logger = logging.getLogger(__name__)


def execute(item):
    from labs.models import PC
    from labs import network
    site = settings.CLOUD_SYNC_SITE_ID
    try:
        command_id = uuid.UUID(str(item['id']))
        action = item['action']
        pc_pk = item['pc_pk']
        expiry = parse_datetime(item['expires_at'])
        if (item['site_id'] != site or action not in ('lock', 'unlock', 'shutdown', 'restart')
                or not isinstance(pc_pk, int) or isinstance(pc_pk, bool) or pc_pk <= 0
                or expiry is None or timezone.is_naive(expiry)):
            raise ValueError('Invalid command')
    except (KeyError, ValueError, TypeError, AttributeError):
        logger.warning('Ignored malformed remote command')
        return
    receipt, created = CommandReceipt.objects.get_or_create(
        pk=command_id, defaults={'site_id': site, 'pc_pk': pc_pk, 'action': action})
    if not created:
        return
    # Never repeat this command even if the process dies during agent delivery.
    status, detail = 'failed', 'PC not found or has no LAN IP.'
    if expiry <= timezone.now():
        status, detail = 'expired', 'Expired before edge execution.'
    else:
        pc = PC.objects.select_related('current_session').filter(pk=pc_pk).first()
        if pc and pc.ip_address:
            allowed = True
            if action == 'unlock':
                now = timezone.localtime()
                session = pc.current_session
                allowed = bool(session and session.lab_id == pc.lab_id
                               and session.date == now.date()
                               and session.start_time <= now.time() < session.end_time
                               and (pc.current_user_id or pc.current_guest_name)
                               and pc.status not in ('offline', 'maintenance', 'issue'))
                detail = 'Unlock refused: no current valid local session. Check in locally first.'
            if allowed:
                try:
                    ok, _ = getattr(network, action + '_pc')(pc)
                    status = 'accepted' if ok else 'unknown'
                    detail = ('Agent accepted the signal; physical completion is not confirmed.' if ok
                              else 'Agent delivery failed or is uncertain. Inspect the PC before retrying.')
                except Exception:
                    logger.exception('Remote agent delivery failed: %s', command_id)
                    status, detail = 'unknown', 'Agent delivery uncertain; inspect the PC before retrying.'
    receipt.status, receipt.detail = status, detail
    receipt.save(update_fields=['status', 'detail'])
    logger.info('Cloud command %s site=%s pc=%s action=%s result=%s', command_id, site, pc_pk, action, status)


def run_once():
    if not getattr(settings, 'EDGE_REMOTE_CONTROL_ENABLED', False):
        return
    base = settings.CLOUD_SERVER_URL.rstrip('/')
    parsed = urlsplit(base)
    local_http = (getattr(settings, 'EDGE_REMOTE_CONTROL_ALLOW_LOCAL_HTTP', False)
                  and parsed.scheme == 'http'
                  and parsed.hostname in ('localhost', '127.0.0.1', '::1')
                  and not parsed.username and not parsed.password)
    if (parsed.scheme != 'https' and not local_http) or not settings.CLOUD_SYNC_API_KEY:
        logger.error('Remote control requires HTTPS (or explicitly enabled loopback HTTP) and an API key')
        return
    CommandReceipt.objects.filter(status='executing', created_at__lt=timezone.now() - timedelta(minutes=2)).update(status='unknown')
    pending = list(CommandReceipt.objects.filter(reported=False, site_id=settings.CLOUD_SYNC_SITE_ID).exclude(status='executing').order_by('created_at')[:50])
    data = {'results': [{'id': str(r.pk), 'status': r.status, 'detail': r.detail} for r in pending]}
    request = urllib.request.Request(base + '/api/commands/', data=json.dumps(data).encode(), headers={
        'Content-Type': 'application/json', 'Authorization': 'Bearer ' + settings.CLOUD_SYNC_API_KEY,
        'X-CompuLab-Site': settings.CLOUD_SYNC_SITE_ID}, method='POST')
    # Reject redirects so the campus bearer key cannot be forwarded elsewhere.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    handlers = [NoRedirect]
    if local_http:
        handlers.append(urllib.request.ProxyHandler({}))  # Keep loopback demo traffic local.
    try:
        with urllib.request.build_opener(*handlers).open(request, timeout=settings.CLOUD_SYNC_TIMEOUT_SECONDS) as response:
            body = json.loads(response.read(65537))
        if not isinstance(body, dict) or not isinstance(body.get('commands'), list) or not isinstance(body.get('acknowledged'), list):
            return
        acknowledged = {str(x) for x in body['acknowledged']}
        CommandReceipt.objects.filter(pk__in=[r.pk for r in pending if str(r.pk) in acknowledged]).update(reported=True)
        for item in body['commands'][:10]:
            if isinstance(item, dict):
                execute(item)
    except Exception:
        logger.warning('Cloud command poll failed; local operation continues', exc_info=True)
