"""Exactly-once handling of session-end / logout events from lab PC agents.

The agent (lab_pc_agent/agent.py) keeps each such event on disk and re-sends
it until the server acknowledges it ({"ok": true, "ack": "<event_id>"}).
This module makes those re-sends safe:

  * duplicate:  an event_id seen before is acknowledged again, not applied
                (AgentEventReceipt, in the database, so it survives restarts);
  * late:       an event that happened before the PC was in use again (the
                agent says how long ago, measured on its own clock) is
                acknowledged but ignored, so a delayed "session ended" can
                never end a newer session;
  * failure:    if applying the event fails, the receipt is rolled back with
                it, so the agent's next re-send is applied normally.
"""
import datetime

from django.db import IntegrityError, transaction
from django.utils import timezone

RECEIPT_KEEP_DAYS = 7
LATE_AFTER_SECONDS = 15


def clean_event_id(data):
    return str((data or {}).get('event_id') or '').strip()[:64]


def late_reason(pc, data):
    """Why this event must be ignored because it is out of date, or None."""
    try:
        age = int((data or {}).get('queued_seconds_ago') or 0)
    except (TypeError, ValueError):
        age = 0
    if (age > LATE_AFTER_SECONDS and pc.status == 'in_use' and pc.last_active
            and pc.last_active > timezone.now() - datetime.timedelta(seconds=age)):
        return 'the PC has been in use again since this event'
    return None


def process(pc, kind, data, apply):
    """Apply one agent event at most once. `apply(pc)` does the real work
    on a row-locked, freshly loaded PC. Returns the JSON body to answer."""
    from labs.models import AgentEventReceipt, PC

    event_id = clean_event_id(data)
    reason = None
    try:
        with transaction.atomic():
            locked = PC.objects.select_for_update().select_related('lab').get(pk=pc.pk)
            receipt = None
            if event_id:
                receipt = AgentEventReceipt.objects.create(event_id=event_id, pc=locked, kind=kind)
            reason = late_reason(locked, data)
            if reason:
                if receipt is not None:
                    receipt.outcome = reason[:120]
                    receipt.save(update_fields=['outcome'])
            else:
                apply(locked)
    except IntegrityError:
        if event_id and AgentEventReceipt.objects.filter(event_id=event_id).exists():
            return {'ok': True, 'ack': event_id, 'duplicate': True, 'ignored': 'duplicate'}
        raise
    body = {'ok': True}
    if event_id:
        body['ack'] = event_id
    if reason:
        body['ignored'] = reason
    return body


def prune_receipts():
    from labs.models import AgentEventReceipt
    cutoff = timezone.now() - datetime.timedelta(days=RECEIPT_KEEP_DAYS)
    AgentEventReceipt.objects.filter(received_at__lt=cutoff).delete()
