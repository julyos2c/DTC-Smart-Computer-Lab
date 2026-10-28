"""Periodic edge-to-cloud PC state refresh, including raw QuerySet.update changes.

The agent updates the *local* PC state; the cloud displays snapshots, never probes
campus PCs. State is marked stale on the cloud if delivery or agent contact stops.
"""
import datetime
import logging
from django.conf import settings
from django.db import transaction
from django.utils import timezone
from cloud_sync.models import SyncState, enqueue
from cloud_sync.sync_payloads import snapshot
from labs.models import PC

logger = logging.getLogger(__name__)


def run_once():
    if not (getattr(settings, 'CLOUD_SYNC_ENABLED', False)
            and 'pc' in getattr(settings, 'CLOUD_SYNC_OBJECT_TYPES', ())):
        return 0
    now = timezone.now()
    with transaction.atomic():
        state = SyncState.objects.select_for_update().get_or_create(pk=1)[0]
        if (state.last_pc_snapshot_at and now - state.last_pc_snapshot_at <
                datetime.timedelta(seconds=settings.CLOUD_PC_REFRESH_SECONDS)):
            return 0
        state.last_pc_snapshot_at = now
        state.save(update_fields=['last_pc_snapshot_at'])
    # Refresh all PC statuses periodically: ping updates using QuerySet.update()
    # do not fire post_save signals. Coalescing in sync.py limits queue traffic.
    count = 0
    for pc in PC.objects.select_related('lab').order_by('pk').iterator(chunk_size=200):
        if enqueue('pc', pc.pk, snapshot('pc', pc)):
            count += 1
    return count
