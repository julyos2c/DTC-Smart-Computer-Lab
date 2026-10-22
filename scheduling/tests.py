"""Authorization tests for reservations (audit finding C1, plus Lab
In-Charge lab scoping) and class rosters (audit finding H3)."""
import datetime
import json

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from labs.models import Lab
from scheduling.models import ClassRoster, RosterStudent, Session, SessionRequest

User = get_user_model()
PASSWORD = 'Str0ng-Test-Pass!'


def make_user(role, email, **extra):
    return User.objects.create_user(
        email=email, password=PASSWORD, role=role, email_verified=True,
        first_name=role.title(), last_name='Tester', **extra,
    )


class Fixture(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.lab = Lab.objects.create(name='Lab A', opening_time=datetime.time(7), closing_time=datetime.time(21))
        cls.admin = make_user('admin', 'admin.sched@gmail.com')
        cls.incharge = make_user('incharge', 'incharge.sched@gmail.com', assigned_lab=cls.lab)
        cls.instructor_a = make_user('instructor', 'instructor.a@gmail.com', id_number='INS-A')
        cls.instructor_b = make_user('instructor', 'instructor.b@gmail.com', id_number='INS-B')
        cls.student = make_user('student', 'student.one@gmail.com', id_number='STU-1')
        cls.day = timezone.localdate() + datetime.timedelta(days=3)

    def assertRedirectsToLogin(self, response):
        self.assertEqual(response.status_code, 302)
        self.assertTrue(response['Location'].startswith(reverse('login')), response['Location'])


class ReservationEndpointAuthorizationTests(Fixture):
    """C1: approve, decline, delete and export used to work for anyone."""

    def setUp(self):
        self.pending = SessionRequest.objects.create(
            lab=self.lab, instructor=self.instructor_a, requester_type='instructor',
            requester_name='Instructor A', requester_id_number='INS-A', subject='Networking',
            date=self.day, start_time=datetime.time(9), end_time=datetime.time(10),
        )
        self.other_pending = SessionRequest.objects.create(
            lab=self.lab, instructor=self.instructor_a, requester_type='instructor',
            requester_name='Instructor A', requester_id_number='INS-A', subject='Databases',
            date=self.day, start_time=datetime.time(11), end_time=datetime.time(12),
        )
        self.session = Session.objects.create(
            lab=self.lab, instructor=self.instructor_b, subject='Programming', reservation_code='TESTC1',
            date=self.day, start_time=datetime.time(14), end_time=datetime.time(15),
        )

    def urls(self):
        return {
            'approve': reverse('approve_request', args=[self.pending.pk]),
            'decline': reverse('decline_request', args=[self.other_pending.pk]),
            'delete': reverse('session_delete', args=[self.session.pk]),
            'export': reverse('request_export_pdf', args=[self.pending.pk]),
        }

    def assertNothingChanged(self):
        self.pending.refresh_from_db()
        self.other_pending.refresh_from_db()
        self.assertEqual(self.pending.status, 'pending')
        self.assertIsNone(self.pending.reservation_code)
        self.assertEqual(self.other_pending.status, 'pending')
        self.assertTrue(Session.objects.filter(pk=self.session.pk).exists())
        self.assertEqual(Session.objects.count(), 1)

    def test_anonymous_is_sent_to_login_and_nothing_changes(self):
        urls = self.urls()
        for name in ('approve', 'decline', 'delete'):
            self.assertRedirectsToLogin(self.client.post(urls[name]))
        self.assertRedirectsToLogin(self.client.get(urls['export']))
        self.assertNothingChanged()

    def test_anonymous_with_csrf_enforced_still_cannot_approve(self):
        client = self.client_class(enforce_csrf_checks=True)
        client.get(reverse('login'))
        token = client.cookies['csrftoken'].value
        response = client.post(self.urls()['approve'], {'csrfmiddlewaretoken': token})
        self.assertRedirectsToLogin(response)
        self.assertNothingChanged()

    def test_instructor_and_student_roles_are_forbidden(self):
        # A student account has no usable password, so it is logged in directly.
        for user in (self.instructor_a, self.student):
            self.client.force_login(user)
            urls = self.urls()
            for name in ('approve', 'decline', 'delete'):
                self.assertEqual(self.client.post(urls[name]).status_code, 403, (user.role, name))
            self.assertEqual(self.client.get(urls['export']).status_code, 403, (user.role, 'export'))
            self.client.logout()
        self.assertNothingChanged()

    def test_admin_can_approve_and_delete(self):
        self.client.force_login(self.admin)
        self.client.post(self.urls()['approve'])
        self.pending.refresh_from_db()
        self.assertEqual(self.pending.status, 'approved')
        self.assertTrue(self.pending.reservation_code)
        self.assertTrue(Session.objects.filter(reservation_code=self.pending.reservation_code).exists())
        self.client.post(self.urls()['delete'])
        self.assertFalse(Session.objects.filter(pk=self.session.pk).exists())

    def test_incharge_can_decline_and_export(self):
        self.client.force_login(self.incharge)
        self.client.post(self.urls()['decline'])
        self.other_pending.refresh_from_db()
        self.assertEqual(self.other_pending.status, 'declined')
        response = self.client.get(self.urls()['export'])
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response['Content-Type'], 'application/pdf')

    def test_get_does_not_change_state_for_allowed_roles(self):
        self.client.force_login(self.admin)
        urls = self.urls()
        for name in ('approve', 'decline', 'delete'):
            self.assertEqual(self.client.get(urls[name]).status_code, 302, name)
        self.assertNothingChanged()


class InchargeReservationScopeTests(Fixture):
    """A Lab In-Charge manages reservations for their assigned lab only;
    an Admin manages every lab."""

    def setUp(self):
        self.lab_b = Lab.objects.create(name='Lab B', opening_time=datetime.time(7), closing_time=datetime.time(21))
        self.incharge_none = make_user('incharge', 'incharge.nolab@gmail.com')
        self.request_a = self.make_request(self.lab, 'Own lab')
        self.request_b = self.make_request(self.lab_b, 'Other lab')
        self.session_b = Session.objects.create(
            lab=self.lab_b, instructor=self.instructor_b, subject='Other lab session', reservation_code='TESTB1',
            date=self.day, start_time=datetime.time(14), end_time=datetime.time(15),
        )

    def make_request(self, lab, subject):
        return SessionRequest.objects.create(
            lab=lab, instructor=self.instructor_a, requester_type='instructor',
            requester_name='Instructor A', requester_id_number='INS-A', subject=subject,
            date=self.day, start_time=datetime.time(9), end_time=datetime.time(10),
        )

    def assertOtherLabUntouched(self):
        self.request_b.refresh_from_db()
        self.assertEqual(self.request_b.status, 'pending')
        self.assertIsNone(self.request_b.reservation_code)
        self.session_b.refresh_from_db()
        self.assertEqual(self.session_b.subject, 'Other lab session')

    def test_incharge_cannot_manage_another_labs_reservations(self):
        self.client.force_login(self.incharge)
        rb, sb = self.request_b.pk, self.session_b.pk
        for name in ('approve_request', 'decline_request'):
            self.assertEqual(self.client.post(reverse(name, args=[rb])).status_code, 404, name)
        for name in ('request_detail', 'request_edit', 'request_export_pdf'):
            self.assertEqual(self.client.get(reverse(name, args=[rb])).status_code, 404, name)
        self.assertEqual(self.client.get(reverse('session_edit', args=[sb])).status_code, 404)
        self.assertEqual(self.client.post(reverse('session_delete', args=[sb])).status_code, 404)
        self.assertOtherLabUntouched()

    def test_incharge_still_manages_own_lab(self):
        self.client.force_login(self.incharge)
        self.assertEqual(self.client.get(reverse('request_detail', args=[self.request_a.pk])).status_code, 200)
        self.client.post(reverse('approve_request', args=[self.request_a.pk]))
        self.request_a.refresh_from_db()
        self.assertEqual(self.request_a.status, 'approved')

    def test_incharge_lists_and_counts_only_own_lab(self):
        self.client.force_login(self.incharge)
        response = self.client.get(reverse('manage_requests'))
        self.assertEqual(list(response.context['pending_requests']), [self.request_a])
        self.assertEqual(response.context['pending_requests_count'], 1)  # sidebar badge

    def test_incharge_lab_choice_is_limited_to_own_lab(self):
        self.client.force_login(self.incharge)
        response = self.client.get(reverse('request_edit', args=[self.request_a.pk]))
        self.assertEqual(list(response.context['form'].fields['lab'].queryset), [self.lab])

    def test_calendar_shows_other_labs_without_edit_or_delete(self):
        self.client.force_login(self.incharge)
        own = Session.objects.create(
            lab=self.lab, instructor=self.instructor_a, subject='Own lab session', reservation_code='TESTA1',
            date=self.day, start_time=datetime.time(16), end_time=datetime.time(17),
        )
        events = {e['id']: e['extendedProps'] for e in json.loads(
            self.client.get(reverse('view_schedule')).context['calendar_events_json'])}
        self.assertEqual(events[self.session_b.pk]['editUrl'], '')
        self.assertEqual(events[self.session_b.pk]['deleteUrl'], '')
        self.assertEqual(events[self.session_b.pk]['code'], '')  # the code unlocks Lab B's PCs
        self.assertEqual(events[own.pk]['deleteUrl'], reverse('session_delete', args=[own.pk]))
        self.assertEqual(events[own.pk]['code'], 'TESTA1')

    def test_incharge_without_assigned_lab_manages_no_reservations(self):
        self.client.force_login(self.incharge_none)
        self.assertEqual(list(self.client.get(reverse('manage_requests')).context['pending_requests']), [])
        for req in (self.request_a, self.request_b):
            self.assertEqual(self.client.post(reverse('approve_request', args=[req.pk])).status_code, 404)
        self.assertOtherLabUntouched()

    def test_admin_manages_every_lab(self):
        self.client.force_login(self.admin)
        self.assertEqual(len(self.client.get(reverse('manage_requests')).context['pending_requests']), 2)
        self.client.post(reverse('decline_request', args=[self.request_b.pk]))
        self.request_b.refresh_from_db()
        self.assertEqual(self.request_b.status, 'declined')


class RosterOwnershipTests(Fixture):
    """H3: an instructor may only open or change their own rosters."""

    def setUp(self):
        self.roster_a = ClassRoster.objects.create(course_code='CS-A', subject='Own class', instructor=self.instructor_a)
        self.roster_b = ClassRoster.objects.create(course_code='CS-B', subject='Other class', instructor=self.instructor_b)
        self.entry_b = RosterStudent.objects.create(roster=self.roster_b, student=self.student)
        self.extra_student = make_user('student', 'student.two@gmail.com', id_number='STU-2')

    def roster_form_data(self, instructor, **overrides):
        data = {'course_code': 'CS-NEW', 'subject': 'New class', 'section': '', 'lab': '',
                'instructor': instructor.pk, 'semester': '', 'academic_year': '', 'status': 'active'}
        data.update(overrides)
        return data

    def test_instructor_cannot_open_or_change_another_instructors_roster(self):
        self.client.force_login(self.instructor_a)
        pk = self.roster_b.pk
        gets = ['roster_detail', 'roster_edit', 'roster_import_students']
        for name in gets:
            self.assertEqual(self.client.get(reverse(name, args=[pk])).status_code, 404, name)
        self.assertEqual(self.client.get(reverse('roster_search_students', args=[pk]), {'q': 'Stu'}).status_code, 404)
        posts = {
            'roster_edit': self.roster_form_data(self.instructor_a, course_code='HIJACK'),
            'roster_archive': {},
            'roster_generate_sessions': {},
            'roster_add_student': {'student_id': self.extra_student.pk},
            'roster_import_students': {},
        }
        for name, data in posts.items():
            self.assertEqual(self.client.post(reverse(name, args=[pk]), data).status_code, 404, name)
        remove = reverse('roster_remove_student', args=[pk, self.entry_b.pk])
        self.assertEqual(self.client.post(remove).status_code, 404)

        self.roster_b.refresh_from_db()
        self.assertEqual(self.roster_b.course_code, 'CS-B')
        self.assertEqual(self.roster_b.status, 'active')
        self.assertEqual(self.roster_b.instructor, self.instructor_b)
        self.assertEqual(list(self.roster_b.students.values_list('pk', flat=True)), [self.entry_b.pk])

    def test_instructor_keeps_full_access_to_own_roster(self):
        self.client.force_login(self.instructor_a)
        pk = self.roster_a.pk
        self.assertEqual(self.client.get(reverse('roster_detail', args=[pk])).status_code, 200)
        self.assertEqual(self.client.get(reverse('roster_edit', args=[pk])).status_code, 200)
        self.client.post(reverse('roster_add_student', args=[pk]), {'student_id': self.extra_student.pk})
        self.assertTrue(self.roster_a.students.filter(student=self.extra_student).exists())
        self.client.post(reverse('roster_archive', args=[pk]))
        self.roster_a.refresh_from_db()
        self.assertEqual(self.roster_a.status, 'inactive')

    def test_admin_and_incharge_can_still_open_every_roster(self):
        for user in (self.admin, self.incharge):
            self.client.force_login(user)
            for roster in (self.roster_a, self.roster_b):
                self.assertEqual(self.client.get(reverse('roster_detail', args=[roster.pk])).status_code, 200)
            self.client.logout()

    def test_instructor_cannot_create_a_roster_under_another_instructor(self):
        self.client.force_login(self.instructor_a)
        response = self.client.post(reverse('roster_create'), self.roster_form_data(self.instructor_b))
        self.assertEqual(response.status_code, 200)  # form redisplayed with an error
        self.assertIn('instructor', response.context['form'].errors)
        self.assertFalse(ClassRoster.objects.filter(course_code='CS-NEW').exists())

    def test_instructor_cannot_hand_own_roster_to_another_instructor(self):
        self.client.force_login(self.instructor_a)
        url = reverse('roster_edit', args=[self.roster_a.pk])
        response = self.client.post(url, self.roster_form_data(self.instructor_b, course_code='CS-A'))
        self.assertEqual(response.status_code, 200)
        self.assertIn('instructor', response.context['form'].errors)
        self.roster_a.refresh_from_db()
        self.assertEqual(self.roster_a.instructor, self.instructor_a)

    def test_instructor_can_create_own_roster(self):
        self.client.force_login(self.instructor_a)
        self.client.post(reverse('roster_create'), self.roster_form_data(self.instructor_a))
        roster = ClassRoster.objects.get(course_code='CS-NEW')
        self.assertEqual(roster.instructor, self.instructor_a)
        self.assertEqual(roster.approval_status, 'pending')

    def test_availability_lookup_never_returns_another_instructors_timetable(self):
        ClassRoster.objects.filter(pk=self.roster_b.pk).update(
            schedule_days='mon', schedule_start_time=datetime.time(8), schedule_end_time=datetime.time(9))
        url = reverse('roster_check_availability')
        self.client.force_login(self.instructor_a)
        data = self.client.get(url, {'instructor': self.instructor_b.pk}).json()
        self.assertEqual(data['instructor_schedule'], [])
        self.client.force_login(self.admin)
        data = self.client.get(url, {'instructor': self.instructor_b.pk}).json()
        self.assertEqual([r['name'] for r in data['instructor_schedule']], [self.roster_b.name])

    def test_anonymous_is_sent_to_login_for_roster_actions(self):
        for name in ('roster_archive', 'roster_generate_sessions', 'roster_approve', 'roster_reject'):
            self.assertRedirectsToLogin(self.client.post(reverse(name, args=[self.roster_b.pk])))
        self.roster_b.refresh_from_db()
        self.assertEqual(self.roster_b.status, 'active')
        self.assertEqual(self.roster_b.approval_status, 'pending')
