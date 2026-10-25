"""Applies batches from campus servers (cloud_sync/PROTOCOL.md, version 2).

Rules (PROTOCOL.md sections 4 and 8), per record, in its own transaction:
  duplicate check (edge_id already applied, or a sequence not newer than the
  one applied) -> validation (object type, schema_version, operation,
  payload) -> conflict check (the cloud copy was edited here since the last
  campus change, unless the campus server forces it after an Admin's
  decision) -> apply -> remember the edge_id and sequence.
A record is answered 'accepted' only after it was stored."""
import hashlib
import hmac
import logging
import uuid

from django.conf import settings
from django.db import IntegrityError, transaction
from django.utils import timezone

from cloud_receiver.models import AppliedChange, ReplicaRecord

logger = logging.getLogger(__name__)

PROTOCOL_VERSION = 2
# Payload layouts this receiver understands (cloud_sync/sync_payloads.py,
# SCHEMA_VERSIONS). A newer layout is rejected, never guessed.
SUPPORTED_SCHEMAS = {
    'reservation': {1},
    'session': {1},
    'issue': {1},
    'activity_log': {1},
    'notification': {1},
}
OPERATIONS = ('upsert', 'delete')


def is_enabled():
    return bool(getattr(settings, 'CLOUD_RECEIVER_ENABLED', False))


def key_hash(key):
    """What CLOUD_RECEIVER_SITES stores for a key: its SHA-256, hex."""
    return hashlib.sha256(key.encode('utf-8')).hexdigest()


def authenticate(site_id, bearer):
    """True when site_id is configured and bearer is its API key. Compared as
    SHA-256 digests in constant time; the key itself is never stored here."""
    expected = (getattr(settings, 'CLOUD_RECEIVER_SITES', {}) or {}).get(site_id or '')
    if not expected or not bearer:
        return False
    return hmac.compare_digest(key_hash(bearer), expected.lower())


def _positive_int(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def validate_record(item):
    """(clean dict, None) for a usable record, else (None, why)."""
    if not isinstance(item, dict):
        return None, 'the record is not a JSON object'
    try:
        edge_id = uuid.UUID(str(item.get('edge_id')))
    except (ValueError, TypeError, AttributeError):
        return None, 'edge_id is not a UUID'
    object_type = item.get('object_type')
    if object_type not in SUPPORTED_SCHEMAS:
        return None, f'object_type {object_type!r} is not known to this receiver'
    if not _positive_int(item.get('local_id')):
        return None, 'local_id must be a positive integer'
    if not _positive_int(item.get('sequence')):
        return None, 'sequence must be a positive integer'
    schema = item.get('schema_version')
    if schema not in SUPPORTED_SCHEMAS[object_type]:
        return None, f'schema_version {schema!r} of {object_type} is not supported by this receiver (update it first)'
    operation = item.get('operation')
    if operation not in OPERATIONS:
        return None, f'operation {operation!r} is not upsert or delete'
    payload = item.get('payload')
    if not isinstance(payload, dict):
        return None, 'payload must be a JSON object'
    return {
        'edge_id': edge_id, 'object_type': object_type, 'local_id': item['local_id'],
        'sequence': item['sequence'], 'schema_version': schema, 'operation': operation,
        'payload': payload, 'force': item.get('force') is True,
    }, None


def apply_record(site_id, item):
    """Applies one record; returns its answer ({'status': ..., 'detail': ...})."""
    clean, problem = validate_record(item)
    if problem:
        return {'status': 'rejected', 'detail': problem}
    try:
        with transaction.atomic():
            if AppliedChange.objects.filter(edge_id=clean['edge_id']).exists():
                return {'status': 'duplicate'}
            record, created = ReplicaRecord.objects.select_for_update().get_or_create(
                site_id=site_id, object_type=clean['object_type'], local_id=clean['local_id'],
            )
            if not created and clean['sequence'] <= record.last_sequence:
                # A late or repeated delivery: something as new or newer is here.
                return {'status': 'duplicate', 'detail': 'an equal or newer change of this record was already applied'}
            if record.cloud_modified_at and not clean['force']:
                # Never overwrite an edit made here without an Admin's decision
                # on the campus server ("Keep campus copy" sends it forced).
                who = f' by {record.cloud_modified_by}' if record.cloud_modified_by else ''
                return {
                    'status': 'conflict',
                    'detail': f'the cloud copy was edited at {timezone.localtime(record.cloud_modified_at):%Y-%m-%d %H:%M}{who}',
                    'cloud_updated_at': record.cloud_modified_at.isoformat(),
                }
            record.schema_version = clean['schema_version']
            if clean['operation'] == 'delete':
                record.deleted = True
                record.payload = {}
            else:
                record.deleted = False
                record.payload = clean['payload']
            record.last_sequence = clean['sequence']
            record.last_edge_id = clean['edge_id']
            record.applied_at = timezone.now()
            record.cloud_modified_at = None
            record.cloud_modified_by = ''
            record.save()
            AppliedChange.objects.create(
                edge_id=clean['edge_id'], site_id=site_id, record=record, sequence=clean['sequence'],
                operation=clean['operation'], forced=clean['force'],
            )
            return {'status': 'accepted'}
    except IntegrityError:
        # The same change or record stored at the same moment by a parallel
        # delivery: nothing was applied by this one; the campus server retries.
        return {'status': 'retry', 'detail': 'stored concurrently by another delivery; send again'}


def process_batch(site_id, body):
    """(http_status, response_body) for one POST /api/sync/ body."""
    if not isinstance(body, dict):
        return 400, {'detail': 'the body must be a JSON object'}
    if body.get('protocol') != PROTOCOL_VERSION:
        return 400, {'detail': f'protocol {body.get("protocol")!r} is not supported (this receiver speaks {PROTOCOL_VERSION})'}
    if body.get('site_id') != site_id:
        return 400, {'detail': 'site_id in the body differs from the X-CompuLab-Site header'}
    records = body.get('records')
    if not isinstance(records, list):
        return 400, {'detail': 'records must be a list'}
    if len(records) > getattr(settings, 'CLOUD_RECEIVER_MAX_RECORDS', 500):
        return 413, {'detail': 'too many records in one batch'}
    results = {}
    for item in records:
        key = str(item.get('edge_id')) if isinstance(item, dict) else ''
        results[key] = apply_record(site_id, item)
    counts = {}
    for answer in results.values():
        counts[answer['status']] = counts.get(answer['status'], 0) + 1
    logger.info('cloud receiver: %s sent %s record(s): %s', site_id, len(records), counts)
    accepted = [k for k, v in results.items() if v['status'] in ('accepted', 'duplicate')]
    return 200, {'results': results, 'accepted_edge_ids': accepted}
