"""
Central place that creates AUTO-GENERATED notifications for every system
event listed in the Notifications & Alerts spec (new/approved/rejected
reservations, session reminders, PC online/offline, maintenance, walk-in/
override approvals, failed logins, reservation conflicts).

Views/signals should call the small `notify_*` functions below instead of
calling Notification.objects.create() directly, so that:
  1. every auto notification respects the Admin's Alert Settings toggles
  2. every auto notification lands on the right people (Admins always get
     critical/system-wide events; a Lab In-Charge only gets events for
     their OWN assigned lab; an Instructor only gets events tied to their
     own reservations/sessions)
"""
import datetime

from django.contrib.auth import get_user_model
from notifications.models import Notification, AlertSettings
from notifications import outbox
from django.conf import settings
from django.templatetags.static import static
from django.urls import reverse
from django.utils import timezone

User = get_user_model()

# Which AlertSettings toggle gates each auto notification_type.
SETTING_FIELD_BY_TYPE = {
    'reservation_submitted': 'reservation_notifications',
    'reservation_allocation': 'reservation_notifications',
    'reservation_approved': 'reservation_notifications',
    'reservation_declined': 'reservation_notifications',
    'reservation_conflict': 'reservation_notifications',
    'reservation_cancelled': 'reservation_notifications',
    'walkin_override_approved': 'reservation_notifications',
    'roster_session_scheduled': 'reservation_notifications',
    'roster_submitted': 'reservation_notifications',
    'roster_approved': 'reservation_notifications',
    'roster_rejected': 'reservation_notifications',
    'roster_student_added': 'reservation_notifications',
    'session_reminder': 'session_reminders',
    'pc_offline': 'pc_status_alerts',
    'pc_online': 'pc_status_alerts',
    'pc_maintenance': 'maintenance_alerts',
    'maintenance_submitted': 'maintenance_alerts',
    'maintenance_completed': 'maintenance_alerts',
    'login_security_alert': 'login_security_alerts',
}


def _event_enabled(notification_type):
    field = SETTING_FIELD_BY_TYPE.get(notification_type)
    if not field:
        return True  # manual/composed types are never gated
    return getattr(AlertSettings.get_solo(), field)


def admins():
    return User.objects.filter(is_active=True, role='admin')


def incharge_for_lab(lab):
    if lab is None:
        return User.objects.none()
    return User.objects.filter(is_active=True, role='incharge', assigned_lab=lab)


def notify(users, title, message, notification_type, lab=None, send_plain_email=True):
    if not _event_enabled(notification_type):
        return []
    seen = set()
    created = []
    for user in users:
        if user is None or user.pk in seen:
            continue
        seen.add(user.pk)
        notification = Notification.objects.create(
            user=user, title=title, message=message,
            notification_type=notification_type, lab=lab, is_system_alert=True,
        )
        created.append(notification)
        # Cloud sync (when configured with "notification" in
        # CLOUD_SYNC_OBJECT_TYPES) picks this up from the post_save signal
        # in cloud_sync/signals.py.

        # Also email it (skipped when the caller sends its own styled email
        # instead, e.g. the reservation-code emails below). The email is only
        # queued here; the worker sends it, so a page never waits on SMTP and
        # nothing is lost while the internet is down.
        if send_plain_email and outbox.email_allowed_for(user):
            outbox.queue(
                user.email, title, message,
                category='security_alert' if notification_type == 'login_security_alert' else 'notification',
                user=user,
            )

    return created


def _session_end(date, end_time):
    """Aware datetime when a session ends — after that its code email is useless."""
    if not date or not end_time:
        return None
    return timezone.make_aware(datetime.datetime.combine(date, end_time))


def _send_reservation_code_email(user, title, intro, subject, lab, date, time_label, code,
                                 expires_at=None, dedupe_key=''):
    """Queues the branded 'reservation code' email (approval or roster
    upcoming-session reminder). Separate from notify()'s plain email
    because this one needs structured context (subject/lab/date/time/code
    laid out in a card) rather than a single message string. No-ops for
    users without an email on file. Expires when the session ends."""
    if not outbox.email_allowed_for(user):
        return None
    context = {
        'user': user, 'title': title, 'intro': intro, 'subject': subject,
        'lab': lab, 'date': date, 'time_label': time_label, 'code': code,
        'logo_url': f'{settings.SITE_URL}{static("img/logo.jpg")}',
    }
    return outbox.queue_template(
        user.email, title, 'emails/reservation_code', context, category='reservation_code',
        user=user, dedupe_key=dedupe_key, expires_at=expires_at,
    )


def _lab_recipients(lab, include_admins=True):
    recipients = list(incharge_for_lab(lab))
    if include_admins:
        recipients += list(admins())
    return recipients


# ---------------------------------------------------------------- #
# Reservations
# ---------------------------------------------------------------- #

def notify_reservation_submitted(session_request):
    req = session_request
    notify(
        _lab_recipients(req.lab),
        'New reservation request',
        f'{req.requester_name or "A requester"} submitted a request for {req.subject} '
        f'in {req.lab.name} on {req.date} ({req.start_time.strftime("%H:%M")}–{req.end_time.strftime("%H:%M")}).',
        'reservation_submitted', lab=req.lab,
    )


def notify_reservation_allocation(req, allocated, *, provisional=False):
    """Tell requester/staff about partial capacity or a declined zero-PC slot."""
    from scheduling.utils import requested_pc_count
    requested = requested_pc_count(req)
    if allocated >= requested and allocated > 0:
        return []
    if allocated == 0:
        title = 'Reservation declined — No available PCs'
        description = ('No available PCs for the selected date and time. '
                       'Your reservation was declined, not queued or kept pending. '
                       'Please select another schedule.')
    else:
        title = 'Reservation partially allocated'
        description = (f'Only {allocated} of your {requested} requested PCs '
                       f'{"are currently available (subject to approval)" if provisional else "have been approved"}.')
    message = (f'{req.subject} in {req.lab.name} on {req.date} '
               f'({req.start_time:%H:%M}–{req.end_time:%H:%M}): '
               f'{requested} requested, {allocated} allocated, '
               f'{max(0, requested - allocated)} unavailable. {description}')
    recipients = [req.instructor] if req.instructor_id else []
    # Staff must also see declined requests entered on behalf of students
    # without dashboard accounts.
    recipients += _lab_recipients(req.lab)
    return notify(recipients, title, message, 'reservation_allocation', lab=req.lab)


def notify_reservation_approved(session_request, code):
    req = session_request
    recipients = []
    if req.instructor:
        recipients.append(req.instructor)
    notify(
        recipients,
        'Lab request approved',
        f'Your request for {req.subject} on {req.date} has been approved. '
        f'Allocated PCs: {req.pcs_allocated}. Reservation code: {code}',
        'reservation_approved', lab=req.lab, send_plain_email=False,
    )
    if _event_enabled('reservation_approved'):
        _send_reservation_code_email(
            req.instructor, 'Lab request approved',
            'Your reservation request has been approved.',
            req.subject, req.lab.name, req.date,
            f'{req.start_time.strftime("%H:%M")}–{req.end_time.strftime("%H:%M")}',
            code,
            expires_at=_session_end(req.date, req.end_time),
            dedupe_key=f'code:request:{req.pk}:{req.instructor_id}',
        )


def notify_reservation_declined(session_request):
    req = session_request
    recipients = []
    if req.instructor:
        recipients.append(req.instructor)
    notify(
        recipients,
        'Lab request declined',
        f'Your request for {req.subject} on {req.date} was declined.',
        'reservation_declined', lab=req.lab,
    )


def notify_reservation_cancelled(lab, subject, date, start_time, end_time, cancelled_by, instructor=None):
    """A reservation was withdrawn. Lab In-Charge + Admins always hear about
    it (the slot is free again); the instructor too when someone else
    (e.g. the lab removing a scheduled session) did the cancelling."""
    when = f'{date} ({start_time.strftime("%H:%M")}–{end_time.strftime("%H:%M")})'
    who = cancelled_by.display_name if cancelled_by else 'Someone'
    recipients = [u for u in _lab_recipients(lab) if not cancelled_by or u.pk != cancelled_by.pk]
    notify(
        recipients, 'Reservation cancelled',
        f'{who} cancelled the reservation for {subject} in {lab.name} on {when}. The slot is free again.',
        'reservation_cancelled', lab=lab,
    )
    if instructor and (not cancelled_by or instructor.pk != cancelled_by.pk):
        notify(
            [instructor], 'Your reservation was cancelled',
            f'Your reservation for {subject} in {lab.name} on {when} was cancelled by {who}.',
            'reservation_cancelled', lab=lab,
        )


def notify_walkin_override_approved(session_request, code):
    req = session_request
    label = 'Walk-in' if req.requester_type == 'walk_in' else 'Override'
    notify(
        _lab_recipients(req.lab),
        f'{label} request approved',
        f'{label} access for {req.requester_name or "a requester"} in {req.lab.name} on {req.date} '
        f'({req.start_time.strftime("%H:%M")}–{req.end_time.strftime("%H:%M")}) was approved. Code: {code}',
        'walkin_override_approved', lab=req.lab,
    )


def notify_roster_session_scheduled(session, code):
    """Sent 1 hour before a roster-auto-generated Session starts (see
    notifications.reminders.check_roster_code_reminders) — this is how the
    instructor learns the reservation code for that specific date, since
    they never filed an individual request for it. Every enrolled student
    on that roster with a Gmail on file gets the same reservation code
    emailed to them directly too (no in-app Notification for them, since
    Students never log into the dashboard to see one)."""
    recipients = []
    if session.instructor:
        recipients.append(session.instructor)
    notify(
        recipients,
        'Upcoming class session — reservation code',
        f'{session.subject} in {session.lab.name} starts at {session.start_time.strftime("%H:%M")} '
        f'today ({session.date}), from your class roster schedule. Reservation code: {code}',
        'roster_session_scheduled', lab=session.lab, send_plain_email=False,
    )
    if _event_enabled('roster_session_scheduled'):
        expires_at = _session_end(session.date, session.end_time)
        _send_reservation_code_email(
            session.instructor, 'Upcoming class session — reservation code',
            'This class starts soon — from your class roster schedule.',
            session.subject, session.lab.name, session.date,
            session.start_time.strftime("%H:%M"),
            code, expires_at=expires_at,
            dedupe_key=f'code:session:{session.pk}:{session.instructor_id}',
        )
        if session.roster_id:
            roster_students = session.roster.students.exclude(student__isnull=True).select_related('student')
            for roster_student in roster_students:
                student = roster_student.student
                if student and student.email:
                    _send_reservation_code_email(
                        student, 'Upcoming class session — reservation code',
                        'This class starts soon — from your class roster schedule.',
                        session.subject, session.lab.name, session.date,
                        session.start_time.strftime("%H:%M"),
                        code, expires_at=expires_at,
                        dedupe_key=f'code:session:{session.pk}:{student.pk}',
                    )


def notify_roster_submitted(roster):
    """Sent to the relevant Lab In-Charge (if the roster already names a
    lab) plus all Admins whenever a class roster reaches/re-reaches
    'pending' — i.e. a new roster from an Instructor, or a Rejected one
    that's just been edited and resubmitted."""
    notify(
        _lab_recipients(roster.lab),
        'Class roster pending approval',
        f'{roster.instructor.get_full_name() if roster.instructor else "An instructor"} submitted '
        f'"{roster.name}" for approval.',
        'roster_submitted', lab=roster.lab,
    )


def notify_roster_approved(roster):
    recipients = []
    if roster.instructor:
        recipients.append(roster.instructor)
    notify(
        recipients,
        'Class roster approved',
        f'Your roster "{roster.name}" has been approved. Its schedule has been added to the official calendar.',
        'roster_approved', lab=roster.lab,
    )


def notify_roster_rejected(roster):
    recipients = []
    if roster.instructor:
        recipients.append(roster.instructor)
    message = f'Your roster "{roster.name}" was rejected.'
    if roster.rejection_reason:
        message += f' Reason: {roster.rejection_reason}'
    message += ' You can edit and resubmit it.'
    notify(
        recipients,
        'Class roster rejected',
        message,
        'roster_rejected', lab=roster.lab,
    )


def notify_student_added_to_roster(roster, student):
    """Sent the moment a Student gets added to a Class Roster (from the
    search-and-add box or the bulk Import Students flow) — lets them know
    which class they're now enrolled in, and its lab/schedule, ahead of
    the per-session reservation-code reminder (see
    notify_roster_session_scheduled). No-ops quietly for a student with
    no Gmail on file, same as every other auto notification here."""
    lab_name = roster.lab.name if roster.lab else 'a lab'
    schedule = f' Schedule: {roster.schedule}.' if roster.schedule else ''
    notify(
        [student],
        'Added to a class roster',
        f'You were added to "{roster.name}" in {lab_name}'
        f'{f" by {roster.instructor.get_full_name()}" if roster.instructor else ""}.'
        f'{schedule} Reservation codes for upcoming sessions will be emailed here '
        f'about an hour before each class.',
        'roster_student_added', lab=roster.lab,
    )


def notify_reservation_conflict(lab, description):
    notify(
        _lab_recipients(lab),
        'Reservation conflict detected',
        description,
        'reservation_conflict', lab=lab,
    )


def notify_session_starting_soon(session):
    recipients = list(incharge_for_lab(session.lab))
    if session.instructor:
        recipients.append(session.instructor)
    notify(
        recipients,
        'Lab session starting soon',
        f'{session.subject} in {session.lab.name} starts at {session.start_time.strftime("%H:%M")} today.',
        'session_reminder', lab=session.lab,
    )


# ---------------------------------------------------------------- #
# PCs
# ---------------------------------------------------------------- #

def notify_pc_offline(pc):
    notify(
        _lab_recipients(pc.lab),
        f'{pc.pc_id} is offline',
        f'The computer {pc.pc_id} in {pc.lab.name} has gone offline unexpectedly.',
        'pc_offline', lab=pc.lab,
    )


def notify_pc_online(pc):
    notify(
        _lab_recipients(pc.lab),
        f'{pc.pc_id} is back online',
        f'The computer {pc.pc_id} in {pc.lab.name} is back online.',
        'pc_online', lab=pc.lab,
    )


def notify_pc_maintenance(pc, reason=''):
    detail = f' ({reason})' if reason else ''
    notify(
        _lab_recipients(pc.lab),
        f'{pc.pc_id} needs maintenance',
        f'{pc.pc_id} in {pc.lab.name} was flagged for maintenance{detail}.',
        'pc_maintenance', lab=pc.lab,
    )


# ---------------------------------------------------------------- #
# Maintenance / equipment
# ---------------------------------------------------------------- #

def notify_maintenance_submitted(log):
    notify(
        _lab_recipients(log.equipment.lab),
        'Maintenance request submitted',
        f'A maintenance task for {log.equipment.name} was scheduled for {log.maintenance_date}.',
        'maintenance_submitted', lab=log.equipment.lab,
    )


def notify_maintenance_completed(log):
    notify(
        _lab_recipients(log.equipment.lab),
        'Maintenance completed',
        f'Maintenance for {log.equipment.name} was marked as completed.',
        'maintenance_completed', lab=log.equipment.lab,
    )


def notify_equipment_issue_reported(issue):
    notify(
        _lab_recipients(issue.equipment.lab),
        'Equipment issue reported',
        f'{issue.equipment.name} in {issue.equipment.lab.name} was reported faulty/needs maintenance: {issue.description[:120]}',
        'pc_maintenance', lab=issue.equipment.lab,
    )


def notify_equipment_issue_resolved(issue):
    notify(
        _lab_recipients(issue.equipment.lab),
        'Equipment issue resolved',
        f'{issue.equipment.name} in {issue.equipment.lab.name} has been repaired/resolved.',
        'maintenance_completed', lab=issue.equipment.lab,
    )


# ---------------------------------------------------------------- #
# Issue reports (issues app)
# ---------------------------------------------------------------- #

def notify_issue_reported(issue, reporter=None):
    """A new issue was logged. Goes to the Lab In-Charge of THAT lab (via
    incharge_for_lab) plus all Admins -- not just Admins. The reporter is
    left out so an Admin/In-Charge who logs an issue themselves doesn't get
    an alert about their own report."""
    reporter = reporter or issue.reported_by
    where = f'{issue.lab.name} \u2014 {issue.pc.pc_id}' if issue.pc else f'{issue.lab.name} (general lab issue)'
    lines = [
        f'Reported by {reporter.display_name} ({reporter.get_role_display()}) at {where}.' if reporter
        else f'Reported at {where}.',
        f'Type: {issue.get_issue_type_display()} \u00b7 Priority: {issue.get_priority_display()}',
    ]
    if (issue.description or '').strip():
        lines.append(issue.description.strip())
    recipients = [u for u in _lab_recipients(issue.lab) if not reporter or u.pk != reporter.pk]
    notify(
        recipients,
        f'New issue: {issue.title}',
        '\n'.join(lines),
        'issue_reported', lab=issue.lab,
    )


def notify_issue_status_changed(issue, actor=None):
    """Tell whoever reported the issue (normally an Instructor) that its
    status changed -- Assigned, In Progress or Resolved. No-ops when there
    is no reporter (account deleted) or when the reporter is the one who
    made the change."""
    reporter = issue.reported_by
    if reporter is None or issue.hidden_by_reporter or (actor is not None and reporter.pk == actor.pk):
        return []
    status_label = issue.get_status_display()
    lines = [f'Your report "{issue.title}" ({issue.lab.name}) is now: {status_label}.']
    if issue.status == 'assigned' and issue.assigned_technician:
        lines.append(f'Assigned to {issue.assigned_technician.display_name}.')
    if issue.status == 'resolved' and (issue.resolution_notes or '').strip():
        lines.append(f'Resolution: {issue.resolution_notes.strip()}')
    if issue.status == 'resolved':
        title, n_type = f'Issue resolved: {issue.title}', 'issue_resolved'
    else:
        title, n_type = f'Issue update: {issue.title} is {status_label}', 'issue_status_changed'
    return notify(
        [reporter], title, '\n'.join(lines), n_type, lab=issue.lab,
    )


# ---------------------------------------------------------------- #
# Security
# ---------------------------------------------------------------- #

def notify_failed_login(identifier, attempt_count):
    notify(
        admins(),
        'Multiple failed login attempts',
        f'{attempt_count} failed login attempts were detected for account "{identifier}".',
        'login_security_alert',
    )


def send_password_changed_email(user):
    """Sends the branded 'Password Change Confirmed' email — fired after
    ANY successful password change, however it happened (self-service
    reset via the Forgot Password flow, or an admin resetting it from
    User & Role Management). This is a security notification, not a
    toggleable one, so unlike notify() above it's not gated by
    AlertSettings and always fires as long as the account has an email
    on file (Students never do, so this is a no-op for them). Failures
    are swallowed the same way notify()'s email step is, so a bad SMTP
    config never blocks the password change itself from succeeding.
    Queued through the outbox like every other email."""
    if not outbox.email_allowed_for(user):
        return None
    context = {
        'user': user,
        'login_url': f'{settings.SITE_URL}{reverse("login")}',
        'logo_url': f'{settings.SITE_URL}{static("img/logo.jpg")}',
    }
    return outbox.queue_template(
        user.email, 'Password Change Confirmed — SCLAMS', 'emails/password_changed', context,
        category='password_changed', user=user,
    )