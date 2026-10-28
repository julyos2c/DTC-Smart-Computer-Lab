"""A content revision detects edits since the cloud last saw the reservation."""
import hashlib
import json


def linked_session(request):
    from scheduling.models import Session
    if request.status != 'approved' or not request.reservation_code:
        return None
    return Session.objects.filter(reservation_code=request.reservation_code).first()


def revision(request):
    def values(obj):
        return {f.attname: getattr(obj, f.attname) for f in obj._meta.concrete_fields if f.name != 'reservation_code'}
    session = linked_session(request)
    data = {'request': values(request), 'session': values(session) if session else None}
    return hashlib.sha256(json.dumps(data, sort_keys=True, default=str).encode()).hexdigest()
