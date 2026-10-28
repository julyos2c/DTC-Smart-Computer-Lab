"""What is sent to the cloud for each object type.

Each serializer returns a plain-JSON snapshot of one record, using an
explicit whitelist of fields: reservation codes (they unlock lab PCs),
password data and the agent secret are never included. Bump the type's
SCHEMA_VERSIONS entry whenever its layout changes, so a receiver can tell
old and new snapshots apart (PROTOCOL.md, "Payload versions")."""
from django.utils import timezone

SCHEMA_VERSIONS = {
    'reservation': 1,
    'session': 1,
    'issue': 1,
    'activity_log': 1,
    'notification': 1,
    'lab': 1,
    'pc': 1,
    'inventory': 1,
    'maintenance_log': 1,
    'equipment_issue': 1,
}

# object_type -> 'app_label.ModelName'
MODELS = {
    'reservation': 'scheduling.SessionRequest',
    'session': 'scheduling.Session',
    'issue': 'issues.Issue',
    'activity_log': 'labs.PCActivityLog',
    'notification': 'notifications.Notification',
    'lab': 'labs.Lab',
    'pc': 'labs.PC',
    'inventory': 'labs.InventoryItem',
    'maintenance_log': 'labs.MaintenanceLog',
    'equipment_issue': 'labs.EquipmentIssue',
}


def _iso(value):
    if value is None:
        return None
    if hasattr(value, 'tzinfo') and value.tzinfo is not None:
        return timezone.localtime(value).isoformat()
    return value.isoformat()


def _person(user):
    if user is None:
        return None
    return {'local_id': user.pk, 'name': getattr(user, 'display_name', '') or user.get_full_name(), 'role': user.role}


def _lab(lab):
    return {'local_id': lab.pk, 'name': lab.name} if lab is not None else None


from scheduling.utils import requested_pc_count


def reservation(obj):
    from scheduling.reservation_state import revision, linked_session
    effective = linked_session(obj) or obj
    data = {
        'lab': _lab(effective.lab),
        'instructor': _person(effective.instructor),
        'requester_type': effective.requester_type,
        'requester_name': effective.requester_name,
        'roster_id': effective.roster_id,
        'subject': effective.subject,
        'date': _iso(effective.date),
        'start_time': _iso(effective.start_time),
        'end_time': _iso(effective.end_time),
        'student_count': effective.student_count,
        'pcs_requested': effective.pcs_requested,
        'pcs_allocated': effective.pcs_allocated,
        'requested_pcs': requested_pc_count(obj),
        'status': obj.status,
        'created_at': _iso(obj.created_at),
    }

    data['revision'] = revision(obj)
    return data


def session(obj):
    return {
        'lab': _lab(obj.lab),
        'instructor': _person(obj.instructor),
        'requester_type': obj.requester_type,
        'requester_name': obj.requester_name,
        'roster_id': obj.roster_id,
        'subject': obj.subject,
        'date': _iso(obj.date),
        'start_time': _iso(obj.start_time),
        'end_time': _iso(obj.end_time),
        'student_count': obj.student_count,
        'pcs_requested': obj.pcs_requested,
        'pcs_allocated': obj.pcs_allocated,
        'created_at': _iso(obj.created_at),
    }


def issue(obj):
    return {
        'lab': _lab(obj.lab),
        'pc': {'local_id': obj.pc_id, 'pc_id': obj.pc.pc_id} if obj.pc_id else None,
        'reported_by': _person(obj.reported_by),
        'assigned_technician': _person(obj.assigned_technician),
        'title': obj.title,
        'description': obj.description,
        'issue_type': obj.issue_type,
        'priority': obj.priority,
        'status': obj.status,
        'resolution_notes': obj.resolution_notes,
        'created_at': _iso(obj.created_at),
        'resolved_at': _iso(obj.resolved_at),
    }


def activity_log(obj):
    return {
        'pc': {'local_id': obj.pc_id, 'pc_id': obj.pc.pc_id},
        'student': _person(obj.student),
        'guest_name': obj.guest_name,
        'session_id': obj.session_id,
        'window_title': obj.window_title,
        'page_url': obj.page_url,
        'via_override': obj.via_override,
        'captured_at': _iso(obj.captured_at),
    }


def notification(obj):
    return {
        'user': _person(obj.user),
        'title': obj.title,
        'message': obj.message,
        'notification_type': obj.notification_type,
        'lab_id': obj.lab_id,
        'created_at': _iso(obj.created_at),
    }


def lab(obj):
    return {'name': obj.name, 'location': obj.location,
            'opening_time': _iso(obj.opening_time), 'closing_time': _iso(obj.closing_time)}


def pc_revision(obj):
    """Revision excludes agent health so a heartbeat never blocks PC configuration edits."""
    import hashlib
    import json
    fields = {'lab': obj.lab_id, 'pc_id': obj.pc_id, 'ip_address': obj.ip_address}
    return hashlib.sha256(json.dumps(fields, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def pc(obj):
    # Never publish agent_secret, access codes, current account details or URLs.
    return {'lab': _lab(obj.lab), 'revision': pc_revision(obj), 'pc_id': obj.pc_id,
            'ip_address': obj.ip_address, 'status': obj.status,
            'last_seen_at': _iso(obj.last_seen_at), 'last_active': _iso(obj.last_active),
            'status_changed_at': _iso(obj.status_changed_at),
            'agent_last_contact_at': _iso(obj.agent_last_contact_at),
            'agent_version': obj.agent_version, 'agent_pending_events': obj.agent_pending_events,
            'in_use': bool(obj.current_session_id or obj.current_user_id or obj.current_guest_name)}


INVENTORY_FIELDS = ('name', 'category', 'quantity', 'condition', 'status',
                    'lab', 'last_checked', 'retirement_reason')


def inventory_revision(obj):
    """Stable version identifier for editing inventory on the cloud."""
    import hashlib
    import json
    fields = {k: (obj.lab_id if k == 'lab' else _iso(getattr(obj, k))
                  if k == 'last_checked' else getattr(obj, k)) for k in INVENTORY_FIELDS}
    return hashlib.sha256(json.dumps(fields, sort_keys=True, separators=(',', ':'),
                                     ensure_ascii=True).encode()).hexdigest()


def inventory(obj):
    return {'lab': _lab(obj.lab), 'name': obj.name, 'category': obj.category,
            'quantity': obj.quantity, 'condition': obj.condition, 'status': obj.status,
            'last_checked': _iso(obj.last_checked), 'created_at': _iso(obj.created_at),
            'updated_at': _iso(obj.updated_at), 'retired_at': _iso(obj.retired_at),
            'retirement_reason': obj.retirement_reason,
            'revision': inventory_revision(obj)}


def maintenance_log(obj):
    return {'equipment_id': obj.equipment_id, 'maintenance_date': _iso(obj.maintenance_date),
            'assigned_technician': _person(obj.assigned_technician),
            'notes': obj.notes, 'completed': obj.completed,
            'completion_notes': obj.completion_notes, 'completed_at': _iso(obj.completed_at),
            'created_at': _iso(obj.created_at)}


def equipment_issue(obj):
    return {'equipment_id': obj.equipment_id, 'reporter': _person(obj.reporter),
            'description': obj.description, 'date_reported': _iso(obj.date_reported),
            'status': obj.status, 'resolution_notes': obj.resolution_notes,
            'resolved_at': _iso(obj.resolved_at)}


SERIALIZERS = {
    'reservation': reservation,
    'session': session,
    'issue': issue,
    'activity_log': activity_log,
    'notification': notification,
    'lab': lab,
    'pc': pc,
    'inventory': inventory,
    'maintenance_log': maintenance_log,
    'equipment_issue': equipment_issue,
}


def snapshot(object_type, instance):
    """Full payload for one record, stamped with when it was taken."""
    data = SERIALIZERS[object_type](instance)
    data['snapshot_at'] = _iso(timezone.now())
    return data


def object_type_for(model):
    label = model._meta.label
    for object_type, model_label in MODELS.items():
        if model_label == label:
            return object_type
    return None
