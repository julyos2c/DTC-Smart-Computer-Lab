"""Inventory CRUD intentions from Cloud. Edge validates and applies atomically.

Never apply changes to ReplicaRecord on the Cloud. Only locally-authorized
edge admins may authorize the worker; the Cloud supplies no user ID or role.
"""
import logging
import uuid
from django.conf import settings
from django.db import transaction
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from cloud_receiver.models import InventoryReceipt
from cloud_sync import transport, sync_payloads

logger = logging.getLogger(__name__)
FIELDS = frozenset(('name','category','quantity','condition','status','lab',
                    'last_checked','retirement_reason'))


class Refused(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def _apply(item, actor):
    from labs.models import Lab, InventoryItem
    if item.get('object_type', 'inventory') == 'pc':
        return _apply_pc(item)
    if item.get('object_type', 'inventory') != 'inventory':
        raise Refused('rejected', 'Unknown record type.')
    action, values = item['action'], item['payload']
    if set(values) - FIELDS:
        raise Refused('rejected', 'Unknown inventory fields.')
    if action == 'create':
        if item.get('target_id') is not None or item.get('base_revision'):
            raise Refused('rejected', 'Create cannot have an existing item.')
        obj = InventoryItem()
    else:
        target = item.get('target_id')
        if not isinstance(target, int) or isinstance(target, bool) or target <= 0:
            raise Refused('rejected', 'Invalid item ID.')
        obj = InventoryItem.objects.select_for_update().filter(pk=target).first()
        if obj is None:
            raise Refused('conflict', 'Item no longer exists on the edge.')
        if sync_payloads.inventory_revision(obj) != item.get('base_revision'):
            raise Refused('conflict', 'Inventory was modified on the edge. Refresh the cloud replica.')
        if action == 'delete':
            if values:
                raise Refused('rejected', 'Delete must not contain field edits.')
            pk = obj.pk
            obj.delete()
            _publish('inventory', pk, 'delete', {'deleted': True})
            return {'detail': 'Inventory item deleted on the edge.', 'local_id': pk}

    for key, value in values.items():
        if key == 'lab':
            if not isinstance(value, int) or isinstance(value, bool) or value < 1 or not Lab.objects.filter(pk=value).exists():
                raise Refused('rejected', 'Choose an existing campus lab ID.')
            obj.lab_id = value
        elif key == 'last_checked':
            from datetime import date
            if value is not None and (not isinstance(value, str) or len(value) != 10):
                raise Refused('rejected', 'Invalid last checked date.')
            try:
                obj.last_checked = date.fromisoformat(value) if value else None
            except (TypeError, ValueError):
                raise Refused('rejected', 'Invalid last checked date.')
        else:
            setattr(obj, key, value)
    if action == 'create':
        missing = [key for key in ('lab','name','category','quantity','condition') if key not in values]
        if missing:
            raise Refused('rejected', 'Missing required fields: ' + ', '.join(missing))
    if obj.condition in ('faulty','needs_check') and obj.status == 'operational':
        obj.status = 'under_repair'
    if obj.status == 'retired' and (action == 'create' or not obj.retired_at):
        if not obj.retirement_reason.strip():
            raise Refused('rejected', 'Retirement reason is required.')
        obj.retired_at = timezone.now()
        obj.retired_by = actor
    elif obj.status != 'retired' and obj.retired_at:
        obj.retired_at = None
        obj.retired_by = None
        obj.retirement_reason = ''
    try:
        obj.full_clean()
    except Exception as exc:
        from django.core.exceptions import ValidationError
        if isinstance(exc, ValidationError):
            raise Refused('rejected', '; '.join(exc.messages)[:500])
        raise
    obj.save()
    _publish('inventory', obj.pk, 'upsert', sync_payloads.snapshot('inventory', obj))
    return {'detail': 'Inventory change applied on edge.', 'local_id': obj.pk,
            'snapshot': sync_payloads.snapshot('inventory', obj)}


def _apply_pc(item):
    """Only PC registration/configuration fields; never override agent status."""
    from labs.models import PC
    from labs.forms import PCForm
    action, values = item['action'], item['payload']
    if set(values) - {'lab', 'pc_id', 'ip_address'}:
        raise Refused('rejected', 'Only lab, PC ID and LAN IP can be edited remotely.')
    if action == 'create':
        if item.get('target_id') is not None or item.get('base_revision'):
            raise Refused('rejected', 'Create cannot have an existing PC.')
        obj = PC()
    else:
        target = item.get('target_id')
        if not isinstance(target, int) or isinstance(target, bool) or target < 1:
            raise Refused('rejected', 'Invalid PC ID.')
        obj = PC.objects.select_for_update().filter(pk=target).first()
        if obj is None:
            raise Refused('conflict', 'PC was deleted on the edge.')
        if sync_payloads.pc_revision(obj) != item.get('base_revision'):
            raise Refused('conflict', 'PC settings changed on the edge. Refresh cloud copy.')
        if action == 'delete':
            if values:
                raise Refused('rejected', 'Delete must not contain field edits.')
            if (obj.current_session_id or obj.current_user_id or obj.current_guest_name or
                    obj.activity_logs.exists() or obj.checkins.exists()):
                raise Refused('rejected', 'PC has active use or historical logs; preserve records by managing locally.')
            pk = obj.pk
            obj.delete()
            _publish('pc', pk, 'delete', {'deleted': True})
            return {'detail': 'PC removed on edge.', 'local_id': pk}
    data = {key:getattr(obj, key) if key != 'lab' else obj.lab_id
            for key in ('lab','pc_id','ip_address')} if obj.pk else {}
    data.update(values)
    data['status'] = obj.status or 'offline'
    form = PCForm(data=data, instance=obj)
    if not form.is_valid():
        raise Refused('rejected', 'PC validation: ' + str(form.errors.get_json_data())[:700])
    pc = form.save()
    _publish('pc', pc.pk, 'upsert', sync_payloads.snapshot('pc', pc))
    return {'detail': 'PC configuration applied on edge.', 'local_id':pc.pk,
            'snapshot':sync_payloads.snapshot('pc',pc)}


def _publish(object_type, pk, operation, payload):
    """Write to outbox inside the same DB transaction as the inventory edit."""
    from cloud_sync.models import SyncQueue
    SyncQueue.objects.create(object_type=object_type, local_id=pk,
                             record_key=f'{object_type}:{pk}', edge_id=uuid.uuid4(),
                             operation=operation, payload=payload)


def execute(item):
    if not isinstance(item, dict):
        return
    try:
        command_id = uuid.UUID(str(item['id']))
        expiry = parse_datetime(item['expires_at'])
        if (item['site_id'] != settings.CLOUD_SYNC_SITE_ID or
                item['action'] not in ('create','update','delete') or
                not isinstance(item['payload'], dict) or
                expiry is None or timezone.is_naive(expiry)):
            return
    except (KeyError, ValueError, TypeError, AttributeError):
        return
    with transaction.atomic():
        receipt, created = InventoryReceipt.objects.get_or_create(
            pk=command_id, defaults={'site_id': settings.CLOUD_SYNC_SITE_ID, 'status':'rejected'})
        if not created:
            return receipt
        try:
            if expiry <= timezone.now():
                raise Refused('expired', 'Inventory command expired.')
            object_type = item.get('object_type', 'inventory')
            if object_type not in ('inventory','pc') or not settings.CLOUD_SYNC_ENABLED or object_type not in settings.CLOUD_SYNC_OBJECT_TYPES:
                raise Refused('rejected', 'Selected record type sync must be enabled on the edge.')
            from accounts.models import User
            from accounts.backends import VerifiedEmailBackend
            actor = User.objects.filter(email=settings.CLOUD_INVENTORY_EDGE_ACTOR_EMAIL,
                                        role='admin', is_active=True).first()
            if not actor or not VerifiedEmailBackend().user_can_authenticate(actor):
                raise Refused('rejected', 'Configure a verified local admin inventory audit account.')
            with transaction.atomic():
                result = _apply(item, actor)
            receipt.status, receipt.result = 'applied', result
        except Refused as exc:
            receipt.status, receipt.result = exc.status, {'detail':exc.message}
        receipt.result.update(object_type=item.get('object_type', 'inventory'), action=item.get('action'), requested_by=str(item.get('requested_by',''))[:254])
        receipt.save(update_fields=['status','result'])
        return receipt


def run_once():
    if not (getattr(settings, 'EDGE_CLOUD_INVENTORY_ENABLED', False)
            and getattr(settings, 'CLOUD_SYNC_ENABLED', False)):
        return
    pending = list(InventoryReceipt.objects.filter(reported=False,
                        site_id=settings.CLOUD_SYNC_SITE_ID).order_by('created_at')[:50])
    try:
        data = transport.post('/api/inventory-changes/', {'results': [
            {'id':str(p.pk), 'status':p.status, 'result':p.result} for p in pending]})
        if not isinstance(data, dict) or not isinstance(data.get('acknowledged'),list) or not isinstance(data.get('changes'),list):
            return
        ack = {str(x) for x in data['acknowledged']}
        InventoryReceipt.objects.filter(pk__in=[p.pk for p in pending if str(p.pk) in ack]).update(reported=True)
        for item in data['changes'][:10]:
            execute(item)
    except Exception:
        logger.warning('Cloud inventory command poll failed; local operations continue', exc_info=True)
