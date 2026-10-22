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
}

# object_type -> 'app_label.ModelName'
MODELS = {
    'reservation': 'scheduling.SessionRequest',
    'session': 'scheduling.Session',
    'issue': 'issues.Issue',
    'activity_log': 'labs.PCActivityLog',
    'notification': 'notifications.Notification',
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


def reservation(obj):
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
        'status': obj.status,
        'created_at': _iso(obj.created_at),
    }


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


SERIALIZERS = {
    'reservation': reservation,
    'session': session,
    'issue': issue,
    'activity_log': activity_log,
    'notification': notification,
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
