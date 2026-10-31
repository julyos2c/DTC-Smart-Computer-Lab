"""Compatibility heartbeat endpoint for the standalone PC Agent."""

import json

from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt

from . import agent_auth
from .models import PC


@csrf_exempt
def pc_agent_heartbeat_api(request):
    if request.method != "POST":
        return JsonResponse(
            {"ok": False, "error": "POST only"},
            status=405,
        )

    if len(request.body) > 16384:
        return JsonResponse(
            {"ok": False, "error": "payload too large"},
            status=413,
        )

    try:
        payload = json.loads(request.body or b"{}")
    except (ValueError, UnicodeDecodeError, TypeError):
        return JsonResponse(
            {"ok": False, "error": "invalid JSON"},
            status=400,
        )

    if not isinstance(payload, dict):
        return JsonResponse(
            {"ok": False, "error": "JSON object required"},
            status=400,
        )

    # Same registered-IP authentication approach as existing Agent APIs.
    remote_ip = request.META.get("REMOTE_ADDR", "")
    pc = (
        PC.objects.select_related("lab")
        .filter(ip_address=remote_ip)
        .first()
    )

    if pc is None:
        return JsonResponse(
            {"ok": False, "error": "unregistered PC"},
            status=403,
        )

    if not agent_auth.authenticate(pc, payload.get("secret")):
        return JsonResponse(
            {"ok": False, "error": "invalid secret"},
            status=403,
        )

    # Reject a heartbeat that claims a different registered PC.
    claimed_pc = str(payload.get("pc_id") or "").strip()
    claimed_lab = str(payload.get("lab_name") or "").strip()

    if claimed_pc and claimed_pc != pc.pc_id:
        return JsonResponse(
            {"ok": False, "error": "PC identity mismatch"},
            status=403,
        )

    if claimed_lab and claimed_lab != pc.lab.name:
        return JsonResponse(
            {"ok": False, "error": "laboratory mismatch"},
            status=403,
        )

    # Reuse existing contact tracking instead of creating a new model.
    from .views import _touch_from_agent

    _touch_from_agent(pc, payload)

    # Do not overwrite reservation/current-user state from a heartbeat.
    return JsonResponse({
        "ok": True,
        "pc_id": pc.pc_id,
    })
