"""Anonymous-access sweeps over every route.

compulab/tests.py only visits parameter-free URLs with GET, which is how
the unauthenticated reservation endpoints (audit finding C1) went
unnoticed. The first sweep fills every <param> with a real object's id and
sends both GET and POST; the second POSTs to every parameter-free route.
Both run as an anonymous visitor and check that nothing is served and
nothing in the database changes.

Safety: like every TestCase, these run against Django's throwaway test
database (test_<NAME>, created and destroyed by the test runner), never the
configured one. The objects are created in setUpTestData, PCs have no IP
address (so no agent is ever contacted) and the test runner swaps in the
in-memory email backend."""
import datetime
import re

from django.apps import apps
from django.contrib.auth import get_user_model
from django.core import serializers
from django.test import TestCase
from django.urls import URLPattern, URLResolver, get_resolver, reverse
from django.utils import timezone

from issues.models import Issue
from labs.models import EquipmentIssue, InventoryItem, Lab, MaintenanceLog, PC
from notifications.models import Notification
from scheduling.models import ClassRoster, RosterStudent, Session, SessionRequest

User = get_user_model()

# Parameterized routes that are public on purpose (token-protected links).
PUBLIC_PARAM_ROUTES = {'password_reset_confirm', 'verify_email'}
# Parameter-free routes that anonymous visitors (or the lab PC agent, which
# authenticates with its shared secret instead of a session) may POST to.
PUBLIC_ROUTES = {
    'home', 'login', 'logout', 'password_reset', 'password_reset_done', 'password_reset_complete',
    'resend_verification', 'pc_login', 'pc_agent_login_api', 'pc_agent_info_api',
    'pc_agent_activity_api', 'pc_agent_end_session_api', 'pc_agent_logout_api', 'manual_unlock_log_api',
}
LOCAL_APPS = ('accounts', 'labs', 'scheduling', 'issues', 'notifications', 'cloud_sync')
ALLOWED_STATUS = {302, 403, 404, 405}
PARAM = re.compile(r'<(?:\w+:)?(\w+)>')


def all_routes():
    """[(name, [param names])] for every named, non-admin route, once each."""
    def walk(patterns, prefix=''):
        for p in patterns:
            if isinstance(p, URLResolver):
                if str(p.pattern).startswith('admin/'):
                    continue
                yield from walk(p.url_patterns, prefix + str(p.pattern))
            elif isinstance(p, URLPattern) and p.name:
                yield p.name, PARAM.findall(prefix + str(p.pattern))
    seen, out = set(), []
    for name, params in walk(get_resolver().url_patterns):
        if name not in seen:
            seen.add(name)
            out.append((name, params))
    return out


def parameterized_routes():
    return [(n, p) for n, p in all_routes() if p and n not in PUBLIC_PARAM_ROUTES]


def parameter_free_routes():
    return [n for n, p in all_routes() if not p]


def database_snapshot():
    return {
        model._meta.label: serializers.serialize('json', model.objects.order_by('pk'))
        for app in LOCAL_APPS for model in apps.get_app_config(app).get_models()
    }


class AnonymousParameterizedRouteTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.lab = Lab.objects.create(name='Sweep Lab', opening_time=datetime.time(7), closing_time=datetime.time(21))
        cls.pc = PC.objects.create(lab=cls.lab, pc_id='S-01', status='online')
        cls.user = User.objects.create_user(
            email='sweep.instructor@gmail.com', password='Str0ng-Test-Pass!', role='instructor',
            email_verified=True, id_number='SWEEP-1',
        )
        cls.student = User.objects.create_user(email='sweep.student@gmail.com', role='student', id_number='SWEEP-S')
        day = timezone.localdate() + datetime.timedelta(days=2)
        cls.session = Session.objects.create(
            lab=cls.lab, instructor=cls.user, subject='Sweep', reservation_code='SWEEP1',
            date=day, start_time=datetime.time(9), end_time=datetime.time(10),
        )
        cls.request_obj = SessionRequest.objects.create(
            lab=cls.lab, instructor=cls.user, subject='Sweep request', requester_name='Sweep',
            requester_id_number='SWEEP-1', date=day, start_time=datetime.time(11), end_time=datetime.time(12),
        )
        cls.roster = ClassRoster.objects.create(course_code='SWEEP', subject='Sweep class', instructor=cls.user)
        cls.roster_student = RosterStudent.objects.create(roster=cls.roster, student=cls.student)
        cls.item = InventoryItem.objects.create(name='Monitor', category='Display', quantity=1, condition='good', lab=cls.lab)
        cls.maintenance = MaintenanceLog.objects.create(equipment=cls.item, maintenance_date=day)
        cls.equipment_issue = EquipmentIssue.objects.create(equipment=cls.item, description='Flickers')
        cls.issue = Issue.objects.create(lab=cls.lab, pc=cls.pc, title='No network', reported_by=cls.user)
        cls.notification = Notification.objects.create(user=cls.user, title='Hello')

    def setUp(self):
        # Report every failing route at once instead of stopping at the first 500.
        self.client.raise_request_exception = False

    def value_for(self, name, param):
        if param == 'student_pk':
            return self.roster_student.pk
        if param == 'roster_key':
            return str(self.roster.pk)
        if name in ('mark_read', 'mark_unread', 'toggle_pin', 'delete_notification'):
            return self.notification.pk
        if name == 'session_attendance_mark' or name.startswith('session_'):
            return self.session.pk
        if name.startswith(('request_', 'approve_request', 'decline_request')):
            return self.request_obj.pk
        prefixes = [
            ('user_', self.user), ('roster_', self.roster), ('pc_', self.pc), ('lab_', self.lab),
            ('inventory_', self.item), ('maintenance_', self.maintenance),
            ('equipment_issue_', self.equipment_issue), ('my_issue_', self.issue), ('issue_', self.issue),
        ]
        for prefix, obj in prefixes:
            if name.startswith(prefix):
                return obj.pk
        raise AssertionError(f'No test object mapped for route "{name}" — add one to value_for().')

    def test_every_parameterized_route_refuses_anonymous_visitors(self):
        routes = parameterized_routes()
        self.assertGreater(len(routes), 40)  # sanity: the sweep really found the routes
        before = database_snapshot()
        problems = []
        for name, params in routes:
            url = reverse(name, kwargs={p: self.value_for(name, p) for p in params})
            for method in ('get', 'post'):
                response = getattr(self.client, method)(url)
                if response.status_code not in ALLOWED_STATUS:
                    problems.append(f'{method.upper()} {name} {url} -> {response.status_code}')
        self.assertEqual(problems, [], 'routes that served or crashed for an anonymous visitor')
        after = database_snapshot()
        changed = [label for label in before if before[label] != after[label]]
        self.assertEqual(changed, [], 'anonymous requests changed these tables')

    def test_every_parameter_free_route_refuses_anonymous_posts(self):
        # compulab/tests.py already GETs these; this covers the POST side
        # (bulk deletes, override, manual unlock, create forms, ...).
        names = parameter_free_routes()
        self.assertGreater(len(names), 80)  # sanity: the sweep really found the routes
        self.assertEqual(PUBLIC_ROUTES - set(names), set(), 'stale names in PUBLIC_ROUTES')
        before = database_snapshot()
        problems = []
        for name in names:
            response = self.client.post(reverse(name), {'selected_ids': [self.user.pk, self.student.pk]})
            public = name in PUBLIC_ROUTES
            if (public and response.status_code >= 500) or (not public and response.status_code not in ALLOWED_STATUS):
                problems.append(f'POST {name} -> {response.status_code}')
        self.assertEqual(problems, [], 'routes that served or crashed for an anonymous POST')
        after = database_snapshot()
        changed = [label for label in before if before[label] != after[label]]
        self.assertEqual(changed, [], 'anonymous POSTs changed these tables')
