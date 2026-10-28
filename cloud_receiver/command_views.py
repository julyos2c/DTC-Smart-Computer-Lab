"""Authenticated edge-only command transport; browser writes use CSRF-protected admin."""
import json
from django.conf import settings
from django.core.exceptions import RequestDataTooBig
from django.http import JsonResponse
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt
from cloud_receiver import receiver
from cloud_receiver.models import RemoteCommand


@csrf_exempt
def commands(request):
    if not receiver.is_enabled() or not getattr(settings, 'CLOUD_REMOTE_CONTROL_ENABLED', False):
        return JsonResponse({'detail': 'Remote control disabled'}, status=404)
    if request.method != 'POST':
        return JsonResponse({'detail': 'POST only'}, status=405)
    if not request.is_secure() and not settings.CLOUD_RECEIVER_ALLOW_HTTP:
        return JsonResponse({'detail': 'HTTPS required'}, status=403)
    auth = request.headers.get('Authorization', '')
    key = auth[7:].strip() if auth[:7].lower() == 'bearer ' else ''
    site = request.headers.get('X-CompuLab-Site', '')
    if not receiver.authenticate(site, key):
        return JsonResponse({'detail': 'Unauthorized'}, status=401)
    try:
        body = json.loads(request.body)
        if not isinstance(body, dict):
            raise ValueError()
        results = body.get('results', [])
        if not isinstance(results, list) or len(results) > 50:
            raise ValueError()
        # Validate the entire report before applying any updates.
        import uuid
        for item in results:
            if not isinstance(item, dict) or item.get('status') not in ('accepted', 'failed', 'unknown', 'expired'):
                raise ValueError()
            uuid.UUID(str(item.get('id')))
            if not isinstance(item.get('detail', ''), str):
                raise ValueError()
    except (ValueError, TypeError, UnicodeDecodeError, AttributeError):
        return JsonResponse({'detail': 'Invalid command report'}, status=400)
    except RequestDataTooBig:
        return JsonResponse({'detail': 'Report too large'}, status=413)
    acknowledged = []
    for item in results:
        command = RemoteCommand.objects.filter(pk=item['id'], site_id=site).first()
        if command is None:
            continue
        # A late genuine result may replace expiry, but never another result.
        RemoteCommand.objects.filter(pk=command.pk, status__in=['pending', 'expired']).update(
            status=item['status'], detail=item.get('detail', '')[:2000], completed_at=timezone.now())
        acknowledged.append(str(command.pk))
    now = timezone.now()
    RemoteCommand.objects.filter(site_id=site, status='pending', expires_at__lte=now).update(
        status='expired', detail='Expired before delivery.', completed_at=now)
    pending = RemoteCommand.objects.filter(site_id=site, status='pending', expires_at__gt=now).order_by('created_at')[:10]
    return JsonResponse({'acknowledged': acknowledged, 'commands': [
        {'id': str(c.pk), 'site_id': c.site_id, 'pc_pk': c.pc_pk, 'action': c.action,
         'expires_at': c.expires_at.isoformat()} for c in pending]})
