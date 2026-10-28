"""HTTPS, key-authenticated edge polling endpoint for cloud inventory intents."""
import json
import uuid
from django.conf import settings
from django.core.exceptions import RequestDataTooBig
from django.db import transaction
from django.http import JsonResponse
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt
from cloud_receiver import receiver
from cloud_receiver.models import InventoryChange


@csrf_exempt
def inventory_changes(request):
    if not receiver.is_enabled() or not settings.CLOUD_INVENTORY_ENABLED:
        return JsonResponse({'detail': 'Cloud inventory changes disabled'}, status=404)
    if request.method != 'POST':
        return JsonResponse({'detail': 'POST only'}, status=405)
    if not request.is_secure() and not settings.CLOUD_RECEIVER_ALLOW_HTTP:
        return JsonResponse({'detail': 'HTTPS required'}, status=403)
    auth = request.headers.get('Authorization', '')
    bearer = auth[7:].strip() if auth[:7].lower() == 'bearer ' else ''
    site = request.headers.get('X-CompuLab-Site', '')
    if not receiver.authenticate(site, bearer):
        return JsonResponse({'detail': 'Unauthorized'}, status=401)
    try:
        body = json.loads(request.body)
        if not isinstance(body, dict):
            raise ValueError()
        reports = body.get('results', [])
        if not isinstance(reports, list) or len(reports) > 50:
            raise ValueError()
        for item in reports:
            if (not isinstance(item, dict) or item.get('status') not in ('applied','rejected','conflict','expired')
                    or not isinstance(item.get('result'), dict)):
                raise ValueError()
            uuid.UUID(str(item.get('id')))
    except (ValueError, TypeError, UnicodeDecodeError, AttributeError):
        return JsonResponse({'detail': 'Invalid inventory report'}, status=400)
    except RequestDataTooBig:
        return JsonResponse({'detail': 'Report too large'}, status=413)
    acknowledged = []
    with transaction.atomic():
        for item in reports:
            obj = InventoryChange.objects.filter(pk=item['id'], site_id=site).first()
            if obj:
                InventoryChange.objects.filter(pk=obj.pk, status__in=['pending','expired']).update(
                    status=item['status'], result=item['result'], completed_at=timezone.now())
                acknowledged.append(str(obj.pk))
        now = timezone.now()
        InventoryChange.objects.filter(site_id=site, status='pending', expires_at__lte=now).update(
            status='expired', result={'detail': 'Expired before delivery.'}, completed_at=now)
        pending = list(InventoryChange.objects.filter(site_id=site, status='pending', expires_at__gt=now)
                       .order_by('created_at','id')[:10])
    return JsonResponse({'acknowledged': acknowledged, 'changes': [
        {'id':str(c.pk), 'site_id':c.site_id, 'action':c.action, 'object_type':c.object_type, 'target_id':c.target_id,
         'base_revision':c.base_revision, 'payload':c.payload,
         'requested_by':c.requested_by, 'expires_at':c.expires_at.isoformat()} for c in pending]})
