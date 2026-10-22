"""Lab In-Charge lab-scoping tests (audit finding M2).

PCs here have no IP address, so unlock_pc() returns without any network
call (there is no agent to reach in tests)."""
import datetime

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse

from labs.models import Lab, PC
from scheduling.models import SessionCheckIn

User = get_user_model()


def make_user(role, email, **extra):
    return User.objects.create_user(
        email=email, password='Str0ng-Test-Pass!', role=role, email_verified=True,
        first_name=role.title(), last_name='Tester', **extra,
    )


class InchargeLabScopeTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        hours = {'opening_time': datetime.time(7), 'closing_time': datetime.time(21)}
        cls.lab_a = Lab.objects.create(name='Lab A', **hours)
        cls.lab_b = Lab.objects.create(name='Lab B', **hours)
        cls.admin = make_user('admin', 'admin.labs@gmail.com')
        cls.incharge_a = make_user('incharge', 'incharge.a@gmail.com', assigned_lab=cls.lab_a)
        cls.incharge_none = make_user('incharge', 'incharge.none@gmail.com')
        cls.student = make_user('student', 'student.labs@gmail.com', id_number='STU-L1')

    def setUp(self):
        self.pc_a = PC.objects.create(lab=self.lab_a, pc_id='A-01', status='online')
        self.pc_b = PC.objects.create(lab=self.lab_b, pc_id='B-01', status='online')

    def override(self, pc):
        return self.client.post(reverse('override_checkin'), {'pc': pc.pk, 'student_id': self.student.pk, 'lab': pc.lab_id})

    def manual_unlock(self, pc):
        return self.client.post(reverse('manual_unlock'), {'pc': pc.pk, 'guest_name': 'Walk-in Guest', 'lab': pc.lab_id})

    def assertUntouched(self, pc):
        pc.refresh_from_db()
        self.assertEqual(pc.status, 'online')
        self.assertIsNone(pc.current_user)
        self.assertEqual(pc.current_guest_name, '')
        self.assertFalse(SessionCheckIn.objects.filter(pc=pc).exists())

    def test_incharge_cannot_override_or_unlock_another_labs_pc(self):
        self.client.force_login(self.incharge_a)
        self.assertEqual(self.override(self.pc_b).status_code, 403)
        self.assertEqual(self.manual_unlock(self.pc_b).status_code, 403)
        self.assertUntouched(self.pc_b)

    def test_incharge_can_still_override_and_unlock_own_lab(self):
        self.client.force_login(self.incharge_a)
        self.assertEqual(self.override(self.pc_a).status_code, 302)
        self.pc_a.refresh_from_db()
        self.assertEqual(self.pc_a.status, 'in_use')
        self.assertEqual(self.pc_a.current_user, self.student)

        second = PC.objects.create(lab=self.lab_a, pc_id='A-02', status='online')
        self.assertEqual(self.manual_unlock(second).status_code, 302)
        second.refresh_from_db()
        self.assertEqual(second.current_guest_name, 'Walk-in Guest')

    def test_incharge_without_assigned_lab_cannot_act_on_any_lab(self):
        self.client.force_login(self.incharge_none)
        self.assertEqual(self.override(self.pc_a).status_code, 403)
        self.assertEqual(self.manual_unlock(self.pc_a).status_code, 403)
        self.assertUntouched(self.pc_a)

    def test_admin_can_act_on_any_lab(self):
        self.client.force_login(self.admin)
        self.assertEqual(self.manual_unlock(self.pc_b).status_code, 302)
        self.pc_b.refresh_from_db()
        self.assertEqual(self.pc_b.status, 'in_use')

    def test_pickers_only_offer_the_incharges_own_lab(self):
        self.client.force_login(self.incharge_a)
        for name in ('override_checkin', 'manual_unlock'):
            response = self.client.get(reverse(name), {'lab': self.lab_b.pk})
            self.assertEqual(response.status_code, 200)
            self.assertEqual(list(response.context['all_labs']), [self.lab_a])
            self.assertEqual(response.context['selected_lab'], '')
            self.assertNotIn('available_pcs', response.context)

            response = self.client.get(reverse(name), {'lab': self.lab_a.pk})
            self.assertEqual(response.context['selected_lab'], str(self.lab_a.pk))
            self.assertEqual(list(response.context['available_pcs']), [self.pc_a])

    def test_picker_ignores_a_non_numeric_lab_parameter(self):
        self.client.force_login(self.admin)
        response = self.client.get(reverse('override_checkin'), {'lab': 'abc'})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.context['selected_lab'], '')

    def test_incharge_cannot_change_another_labs_pc_status(self):
        self.client.force_login(self.incharge_a)
        response = self.client.post(reverse('pc_update', args=[self.pc_b.pk]), {'status': 'maintenance'})
        self.assertEqual(response.status_code, 404)
        self.pc_b.refresh_from_db()
        self.assertEqual(self.pc_b.status, 'online')

        response = self.client.post(reverse('pc_update', args=[self.pc_a.pk]), {'status': 'maintenance'})
        self.assertEqual(response.status_code, 302)
        self.pc_a.refresh_from_db()
        self.assertEqual(self.pc_a.status, 'maintenance')

    def test_anonymous_is_sent_to_login(self):
        for response in (self.override(self.pc_b), self.manual_unlock(self.pc_b),
                         self.client.post(reverse('pc_update', args=[self.pc_b.pk]), {'status': 'maintenance'}),
                         self.client.post(reverse('pc_force_release', args=[self.pc_b.pk])),
                         self.client.post(reverse('pc_lock', args=[self.pc_b.pk]))):
            self.assertEqual(response.status_code, 302)
            self.assertTrue(response['Location'].startswith(reverse('login')))
        self.assertUntouched(self.pc_b)
