"""Batch compatibility endpoint for the older standalone CompuLab Agent."""

import json
import logging

from django.http import JsonResponse
from django.test import RequestFactory
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from django.views.decorators.csrf import csrf_exempt

from . import agent_auth, agent_events, views
from .models import PC

log = logging.getLogger(__name__)


@csrf_exempt
def pc_agent_events_api(request):
    if request.method != "POST":
        return JsonResponse({"ok": False}, status=405)

    if len(request.body) > 65536:
        return JsonResponse({"ok": False, "error": "too large"}, status=413)

    try:
        data = json.loads(request.body)
    except (ValueError, TypeError, UnicodeDecodeError):
        return JsonResponse({"ok": False, "error": "bad JSON"}, status=400)

    if not isinstance(data, dict):
        return JsonResponse({"ok": False, "error": "bad payload"}, status=400)

    remote_ip = request.META.get("REMOTE_ADDR", "")
    pc = PC.objects.select_related("lab").filter(
        ip_address=remote_ip
    ).first()

    if pc is None or not agent_auth.authenticate(
        pc, data.get("secret")
    ):
        return JsonResponse({"ok": False, "error": "forbidden"}, status=403)

    if data.get("pc_id") and str(data["pc_id"]) != pc.pc_id:
        return JsonResponse({"ok": False, "error": "PC mismatch"}, status=403)

    if data.get("lab_name") and str(data["lab_name"]) != pc.lab.name:
        return JsonResponse({"ok": False, "error": "lab mismatch"}, status=403)

    batch = data.get("events")
    if not isinstance(batch, list) or len(batch) > 50:
        return JsonResponse(
            {"ok": False, "error": "invalid events list"},
            status=400,
        )

    accepted = []
    factory = RequestFactory()

    for event in batch:
        if not isinstance(event, dict):
            break

        event_id = event.get("event_id")
        kind = event.get("kind")
        inner = event.get("payload")
        occurred_at = event.get("occurred_at")

        if (
            not isinstance(event_id, str)
            or not 1 <= len(event_id) <= 64
            or kind not in ("logout", "end_session")
            or not isinstance(inner, dict)
            or not isinstance(occurred_at, str)
        ):
            break

        when = parse_datetime(occurred_at)
        if when is None or timezone.is_naive(when):
            break

        age = (timezone.now() - when).total_seconds()
        if age < -300:
            break

        body = dict(inner)
        body.update({
            "secret": data["secret"],
            "event_id": event_id,
            "queued_seconds_ago": max(0, int(age)),
        })

        handler = (
            views.pc_agent_logout_api
            if kind == "logout"
            else views.pc_agent_end_session_api
        )

        try:
            fresh = PC.objects.get(pk=pc.pk)

            # Already available with no active user/session:
            # record the receipt without creating a phantom logout.
            if (
                fresh.status == "online"
                and not fresh.current_user_id
                and not fresh.current_session_id
                and not fresh.current_guest_name
            ):
                answer = agent_events.process(
                    fresh, kind, body, lambda locked: None
                )
            else:
                internal_request = factory.post(
                    "/labs/api/pc-agent-" + kind.replace("_", "-") + "/",
                    data=json.dumps(body),
                    content_type="application/json",
                    REMOTE_ADDR=remote_ip,
                )
                response = handler(internal_request)

                if response.status_code != 200:
                    break

                answer = json.loads(response.content)

            if not (
                answer.get("ok") is True
                and answer.get("ack") == event_id
            ):
                break

            accepted.append(event_id)

        except Exception:
            log.exception("Failed to process PC agent event")
            return JsonResponse(
                {"ok": False, "error": "processing failed"},
                status=503,
            )

    return JsonResponse({
        "ok": True,
        "accepted": accepted,
    })
