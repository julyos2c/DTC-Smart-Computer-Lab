"""GET /api/ping/ and POST /api/sync/ (cloud_sync/PROTOCOL.md section 3).

Both answer 404 while CLOUD_RECEIVER_ENABLED is off, which a campus server
reads as "no sync receiver at this address" and pauses instead of retrying."""
import json

from django.conf import settings
from django.core.exceptions import RequestDataTooBig
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt

from cloud_receiver import receiver


def _not_here():
    return JsonResponse({'detail': 'no sync receiver here'}, status=404)


@csrf_exempt
def ping(request):
    if not receiver.is_enabled():
        return _not_here()
    if request.method != 'GET':
        return JsonResponse({'detail': 'GET only'}, status=405)
    return JsonResponse({'ok': True, 'protocol': receiver.PROTOCOL_VERSION})


@csrf_exempt
def sync(request):
    if not receiver.is_enabled():
        return _not_here()
    if request.method != 'POST':
        return JsonResponse({'detail': 'POST only'}, status=405)
    # The API key travels in a header: never over plain HTTP in production.
    if not request.is_secure() and not getattr(settings, 'CLOUD_RECEIVER_ALLOW_HTTP', False):
        return JsonResponse({'detail': 'HTTPS is required'}, status=403)
    auth = request.META.get('HTTP_AUTHORIZATION', '')
    bearer = auth[7:].strip() if auth[:7].lower() == 'bearer ' else ''
    site_id = request.META.get('HTTP_X_COMPULAB_SITE', '').strip()
    if not receiver.authenticate(site_id, bearer):
        return JsonResponse({'detail': 'unknown site or wrong API key'}, status=401)
    try:
        raw = request.body
    except RequestDataTooBig:
        return JsonResponse({'detail': 'the batch is too large'}, status=413)
    try:
        body = json.loads(raw.decode('utf-8'))
    except (ValueError, UnicodeDecodeError):
        return JsonResponse({'detail': 'the body is not JSON'}, status=400)
    status, answer = receiver.process_batch(site_id, body)
    return JsonResponse(answer, status=status)
