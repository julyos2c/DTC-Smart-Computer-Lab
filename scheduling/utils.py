import json
import random
import string

from django.db.models import Q


def json_for_script(value):
    """json.dumps() output that is safe to drop into an inline <script> via
    |safe: a user-entered '</script>' (e.g. in a session subject) can't
    close the tag early. The escapes are still valid JSON/JS strings."""
    return (json.dumps(value)
            .replace('<', '\\u003c')
            .replace('>', '\\u003e')
            .replace('&', '\\u0026'))

CODE_CHARS = string.ascii_uppercase.replace('O', '').replace('I', '') + string.digits.replace('0', '').replace('1', '')

# All regular reservations now consume only the number of PCs granted.
# The requested quantity is retained on SessionRequest (student_count for
# ordinary bookings; pcs_requested for walk-in/override), while pcs_allocated
# records the approved quantity. Pending requests are not capacity holds.
CAPACITY_BASED_TYPES = ('instructor', 'student', 'group', 'walk_in', 'override')


def requested_pc_count(obj):
    """The quantity asked for, never silently replaced by an allocated count."""
    if obj.requester_type in ('walk_in', 'override'):
        return max(obj.pcs_requested or 0, 0)
    return max(obj.student_count or 0, 1)


def allocated_pc_count(obj):
    """Existing rows created before migration count their original booking."""
    count = getattr(obj, 'pcs_allocated', 0)
    if count:
        return count
    # An approved Session with zero PCs is not valid under the new flow.
    # Old Session rows had pcs_allocated=0, so fall back to legacy fields.
    return requested_pc_count(obj)


def allocate_pcs(lab, date, start_time, end_time, requested, exclude_pk=None):
    """Return (grant, message, available) using approved overlapping sessions.

    Call this within schedule_write_lock when allocating an official Session.
    Never reserve more than the remaining capacity. A zero-PC request
    must be rejected, not placed on a pending/waiting list.
    """
    total, used, available = lab_pc_capacity(lab, date, start_time, end_time, exclude_pk=exclude_pk)
    granted = min(max(0, int(requested)), available)
    if granted < requested:
        msg = (f'Partial allocation: requested {requested} PC(s), but only {granted} '
               f'PC(s) available in {lab.name} for this schedule.'
               if granted else
               f'No available PCs in {lab.name} for the selected date and time. Please choose another schedule.')
    else:
        msg = None
    return granted, msg, available


def generate_reservation_code(length=6):
    """
    Generates a short, human-typeable reservation code (avoids ambiguous
    characters like O/0 and I/1) that's unique across both pending requests
    and the official schedule.
    """
    from scheduling.models import Session, SessionRequest

    while True:
        code = ''.join(random.choices(CODE_CHARS, k=length))
        if not SessionRequest.objects.filter(reservation_code=code).exists() and \
           not Session.objects.filter(reservation_code=code).exists():
            return code


def lab_pc_capacity(lab, date, start_time, end_time, exclude_pk=None):
    """(total usable PCs, used PCs, free PCs) for an entire time interval.

    PCs under maintenance or with a reported issue are not schedulable.
    Offline PCs are still counted for advance booking: they may be powered
    on before the future reservation. Actual PC unlock remains gated by
    agent availability. Overlapping approved sessions each consume only
    their actual granted quantity (not an exclusive lab hold).
    """
    from scheduling.models import Session

    total_pcs = lab.pcs.exclude(status__in=('maintenance', 'issue')).count()
    qs = Session.objects.filter(
        lab=lab, date=date, start_time__lt=end_time, end_time__gt=start_time,
    )
    if exclude_pk:
        qs = qs.exclude(pk=exclude_pk)
    used = sum(allocated_pc_count(s) for s in qs)
    used = min(used, total_pcs)
    return total_pcs, used, max(total_pcs - used, 0)


def cap_student_count(lab, student_count):
    """Legacy convenience for old callers; uses physical lab capacity only.

    New reservation paths MUST use allocate_pcs() with the requested slot.
    """
    total_pcs = lab.pcs.exclude(status__in=('maintenance', 'issue')).count()
    assigned = min(max(0, student_count), total_pcs)
    return assigned, (f'Only {assigned} of {student_count} students can fit in {lab.name}.'
                      if assigned < student_count else None)


def roster_schedule_conflicts(lab, instructor, section, schedule_days, start_time, end_time,
                               valid_from, valid_until, exclude_pk=None):
    """Checks a Class Roster's proposed weekly schedule (day(s) + time
    range, repeating over [valid_from, valid_until]) for conflicts against
    every OTHER active, still-relevant roster (approval_status is 'pending'
    or 'approved' — a Rejected or Archived roster's old schedule no longer
    holds a slot) on three fronts, per the roster approval rules:

      - the INSTRUCTOR's schedule (same instructor, another class at an
        overlapping day/time)
      - the CLASSROOM's schedule (same lab, another class at an
        overlapping day/time)
      - the SECTION's schedule (same section — a section can't be in two
        classes at once)

    Returns a list of dicts, one per conflicting roster/front:
      {'kind': 'Instructor' | 'Classroom' | 'Section', 'roster': <ClassRoster>,
       'shared_days': ['mon', ...]}
    Empty list means the slot is free on all three fronts.
    """
    from scheduling.models import ClassRoster

    days = set(d for d in (schedule_days or '').split(',') if d)
    if not (days and start_time and end_time and valid_from and valid_until):
        return []

    candidates = ClassRoster.objects.filter(
        status='active', approval_status__in=('pending', 'approved'),
    ).exclude(schedule_days='')
    if exclude_pk:
        candidates = candidates.exclude(pk=exclude_pk)

    lookups = [('Classroom', Q(lab_id=lab.pk) if lab else None)]
    if instructor is not None:
        lookups.append(('Instructor', Q(instructor_id=instructor.pk)))
    if section:
        lookups.append(('Section', Q(section=section)))

    conflicts = []
    for kind, filt in lookups:
        if filt is None:
            continue
        for other in candidates.filter(filt):
            other_days = set(d for d in other.schedule_days.split(',') if d)
            shared_days = days & other_days
            if not shared_days:
                continue
            if not (other.schedule_start_time and other.schedule_end_time and
                    other.schedule_valid_from and other.schedule_valid_until):
                continue
            time_overlap = start_time < other.schedule_end_time and end_time > other.schedule_start_time
            date_overlap = valid_from <= other.schedule_valid_until and valid_until >= other.schedule_valid_from
            if time_overlap and date_overlap:
                conflicts.append({'kind': kind, 'roster': other, 'shared_days': sorted(shared_days)})
    return conflicts


def capacity_error(requester_type, lab, date, start_time, end_time, pcs_requested, exclude_pk=None):
    """Block new requests if every schedulable PC is already booked.

    If at least one PC remains, submission proceeds even if fewer PCs
    are available than requested; allocation is finalized at approval.
    """
    _, _, available = lab_pc_capacity(lab, date, start_time, end_time, exclude_pk=exclude_pk)
    if available == 0:
        return f'No available PCs in {lab.name} for the selected date and time. Please choose another schedule.'
    return None
