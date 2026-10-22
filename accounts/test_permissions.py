"""Superuser protection tests (audit finding M1): an Admin-role account
that is not a superuser must not be able to take over a superuser."""
from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse

User = get_user_model()
PASSWORD = 'Str0ng-Test-Pass!'
NEW_PASSWORD = 'Vx9-unique-Pass-2026'


class SuperuserProtectionTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.superuser = User.objects.create_superuser(email='root.owner@gmail.com', password=PASSWORD)
        cls.superuser_2 = User.objects.create_superuser(email='root.second@gmail.com', password=PASSWORD)
        cls.admin = User.objects.create_user(
            email='plain.admin@gmail.com', password=PASSWORD, role='admin', email_verified=True,
            first_name='Plain', last_name='Admin',
        )
        cls.instructor = User.objects.create_user(
            email='some.instructor@gmail.com', password=PASSWORD, role='instructor', email_verified=True,
            first_name='Some', last_name='Instructor', id_number='INS-M1',
        )

    def assertSuperuserUntouched(self):
        self.superuser.refresh_from_db()
        self.assertTrue(self.superuser.is_active)
        self.assertTrue(self.superuser.check_password(PASSWORD))
        self.assertEqual(self.superuser.email, 'root.owner@gmail.com')

    def test_plain_admin_cannot_reset_edit_deactivate_or_delete_a_superuser(self):
        self.client.force_login(self.admin)
        pk = self.superuser.pk
        reset = reverse('user_reset_password', args=[pk])
        self.assertEqual(self.client.get(reset).status_code, 403)
        self.assertEqual(self.client.post(reset, {'password1': NEW_PASSWORD, 'password2': NEW_PASSWORD}).status_code, 403)

        edit = reverse('user_update', args=[pk])
        self.assertEqual(self.client.get(edit).status_code, 403)
        self.assertEqual(self.client.post(edit, {'email': 'plain.admin.takeover@gmail.com', 'first_name': 'X'}).status_code, 403)

        for name in ('user_deactivate', 'user_activate', 'user_delete'):
            self.assertEqual(self.client.post(reverse(name, args=[pk])).status_code, 403, name)
        self.assertEqual(self.client.get(reverse('user_delete', args=[pk])).status_code, 403)
        self.assertSuperuserUntouched()

    def test_plain_admin_bulk_delete_skips_superusers(self):
        self.client.force_login(self.admin)
        self.client.post(reverse('users_bulk_delete'), {'selected_ids': [self.superuser.pk, self.instructor.pk]})
        self.assertTrue(User.objects.filter(pk=self.superuser.pk).exists())
        self.assertFalse(User.objects.filter(pk=self.instructor.pk).exists())

    def test_plain_admin_still_manages_non_superusers(self):
        self.client.force_login(self.admin)
        response = self.client.post(reverse('user_reset_password', args=[self.instructor.pk]),
                                    {'password1': NEW_PASSWORD, 'password2': NEW_PASSWORD})
        self.assertEqual(response.status_code, 302)
        self.instructor.refresh_from_db()
        self.assertTrue(self.instructor.check_password(NEW_PASSWORD))
        self.client.post(reverse('user_deactivate', args=[self.instructor.pk]))
        self.instructor.refresh_from_db()
        self.assertFalse(self.instructor.is_active)

    def test_superuser_can_manage_another_superuser(self):
        self.client.force_login(self.superuser)
        response = self.client.post(reverse('user_reset_password', args=[self.superuser_2.pk]),
                                    {'password1': NEW_PASSWORD, 'password2': NEW_PASSWORD})
        self.assertEqual(response.status_code, 302)
        self.superuser_2.refresh_from_db()
        self.assertTrue(self.superuser_2.check_password(NEW_PASSWORD))
        self.assertEqual(self.client.get(reverse('user_update', args=[self.superuser_2.pk])).status_code, 200)

    def row_controls(self, viewer, target):
        """Which management URLs the Users list renders for `target`."""
        self.client.force_login(viewer)
        html = self.client.get(reverse('users'), {'q': target.email}).content.decode()
        names = ('user_update', 'user_reset_password', 'user_deactivate', 'user_delete')
        return {name for name in names if reverse(name, args=[target.pk]) in html}

    def test_users_list_hides_superuser_controls_from_plain_admin(self):
        self.assertEqual(self.row_controls(self.admin, self.superuser), set())
        self.assertEqual(self.row_controls(self.admin, self.instructor),
                         {'user_update', 'user_reset_password', 'user_deactivate', 'user_delete'})
        self.assertEqual(self.row_controls(self.superuser, self.superuser_2),
                         {'user_update', 'user_reset_password', 'user_deactivate', 'user_delete'})

    def test_anonymous_is_sent_to_login(self):
        for name in ('user_reset_password', 'user_update', 'user_delete', 'user_deactivate'):
            response = self.client.post(reverse(name, args=[self.superuser.pk]))
            self.assertEqual(response.status_code, 302, name)
            self.assertTrue(response['Location'].startswith(reverse('login')), name)
        self.assertSuperuserUntouched()
