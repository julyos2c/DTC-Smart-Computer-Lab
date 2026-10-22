"""Per-PC agent secrets (labs/agent_auth.py) and who may unlock a PC.

No network: commands to agents go through a patched urlopen."""
import datetime
import io
import json
import urllib.error
from unittest import mock

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import TestCase, override_settings
from django.urls import reverse

from labs import agent_auth, network
from labs.models import Lab, PC

User = get_user_model()
SHARED = 'shared-agent-secret-for-tests-0001'
IP_A, IP_B = '10.20.0.1', '10.20.0.2'


def make_user(role, email, **extra):
    return User.objects.create_user(email=email, password='Str0ng-Test-Pass!', role=role, email_verified=True,
                                    first_name=role.title(), last_name='Tester', **extra)


@override_settings(PC_AGENT_SHARED_SECRET=SHARED, PC_AGENT_REQUIRE_PER_PC_SECRET=False)
class PerPcSecretTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.lab = Lab.objects.create(name='Secret Lab', opening_time=datetime.time(0), closing_time=datetime.time(23, 59))
        cls.admin = make_user('admin', 'admin.secrets@gmail.com')
        cls.incharge = make_user('incharge', 'incharge.secrets@gmail.com', assigned_lab=cls.lab)

    def setUp(self):
        self.pc_a = PC.objects.create(lab=self.lab, pc_id='S-01', ip_address=IP_A, status='online')
        self.pc_b = PC.objects.create(lab=self.lab, pc_id='S-02', ip_address=IP_B, status='online')

    def info(self, secret, ip):
        return self.client.get(reverse('pc_agent_info_api'), {'secret': secret}, REMOTE_ADDR=ip)

    def download(self, pc):
        self.client.force_login(self.admin)
        response = self.client.get(reverse('pc_agent_config', args=[pc.pk]))
        self.client.logout()
        self.assertEqual(response.status_code, 200)
        return json.loads(response.content)

    def test_old_installs_keep_working_with_the_shared_secret(self):
        self.assertEqual(self.info(SHARED, IP_A).status_code, 200)
        self.assertEqual(self.info('wrong', IP_A).status_code, 403)
        self.assertEqual(self.info('', IP_A).status_code, 403)

    def test_agent_config_carries_a_unique_per_pc_secret_and_repeats_it(self):
        a, b = self.download(self.pc_a), self.download(self.pc_b)
        self.assertNotEqual(a['secret'], SHARED)
        self.assertNotEqual(a['secret'], b['secret'])
        self.assertGreaterEqual(len(a['secret']), 40)
        self.assertEqual(self.download(self.pc_a)['secret'], a['secret'], 'a second download must not break the first')
        self.assertEqual(a['pc_name'], 'S-01')

    def test_only_admins_download_agent_config(self):
        self.client.force_login(self.incharge)
        self.assertEqual(self.client.get(reverse('pc_agent_config', args=[self.pc_a.pk])).status_code, 403)
        self.pc_a.refresh_from_db()
        self.assertEqual(self.pc_a.agent_secret, '')

    def test_move_to_own_secret_without_breaking_the_installed_agent(self):
        own = self.download(self.pc_a)['secret']
        # Downloaded but not yet installed: the installed agent (shared secret) still works.
        self.assertEqual(self.info(SHARED, IP_A).status_code, 200)
        # The reinstalled agent uses its own secret: accepted, and from now on the shared one is refused for it.
        self.assertEqual(self.info(own, IP_A).status_code, 200)
        self.pc_a.refresh_from_db()
        self.assertTrue(self.pc_a.agent_secret_in_use)
        self.assertEqual(self.info(SHARED, IP_A).status_code, 403)
        # Other PCs are not affected.
        self.assertEqual(self.info(SHARED, IP_B).status_code, 200)

    def test_a_pcs_secret_does_not_work_for_another_pc(self):
        own_a = self.download(self.pc_a)['secret']
        self.assertEqual(self.info(own_a, IP_B).status_code, 403)
        body = {'secret': own_a, 'reason': 'manual', 'event_id': 'evt-x'}
        response = self.client.post(reverse('pc_agent_end_session_api'), json.dumps(body),
                                    content_type='application/json', REMOTE_ADDR=IP_B)
        self.assertEqual(response.status_code, 403)

    def test_offline_tool_log_is_checked_against_the_pc_it_names(self):
        own_a = self.download(self.pc_a)['secret']
        body = {'secret': own_a, 'pc_ip': IP_B, 'guest_name': 'Guest', 'incharge_name': 'Staff'}
        self.assertEqual(self.client.post(reverse('manual_unlock_log_api'), json.dumps(body),
                                          content_type='application/json').status_code, 403)
        body['pc_ip'] = IP_A
        self.assertEqual(self.client.post(reverse('manual_unlock_log_api'), json.dumps(body),
                                          content_type='application/json').status_code, 200)

    @override_settings(PC_AGENT_REQUIRE_PER_PC_SECRET=True)
    def test_shared_secret_can_be_switched_off_everywhere(self):
        own_a = self.download(self.pc_a)['secret']
        self.assertEqual(self.info(SHARED, IP_B).status_code, 403)
        self.assertEqual(self.info(own_a, IP_A).status_code, 200)
        self.assertEqual(agent_auth.secrets_for_command(self.pc_b), [])
        ok, message = network.unlock_pc(self.pc_b)
        self.assertFalse(ok)
        self.assertIn('Agent config', message)

    def test_rotation_refuses_the_old_secret_and_does_not_fall_back_to_shared(self):
        old = self.download(self.pc_a)['secret']
        self.info(old, IP_A)
        out = io.StringIO()
        call_command('agent_secret', '--rotate', str(self.pc_a.pk), stdout=out)
        self.pc_a.refresh_from_db()
        self.assertNotEqual(self.pc_a.agent_secret, old)
        self.assertNotIn(self.pc_a.agent_secret, out.getvalue())
        self.assertEqual(self.info(old, IP_A).status_code, 403)
        self.assertEqual(self.info(SHARED, IP_A).status_code, 403)
        self.assertEqual(self.info(self.pc_a.agent_secret, IP_A).status_code, 200)

    def test_listing_never_prints_secrets(self):
        own = self.download(self.pc_a)['secret']
        out = io.StringIO()
        call_command('agent_secret', stdout=out)
        self.assertNotIn(own, out.getvalue())
        self.assertNotIn(SHARED, out.getvalue())
        self.assertIn('S-01', out.getvalue())
        self.assertIn('0 of 2 PCs use their own secret', out.getvalue())


class FakeResponse:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def agent_that_accepts(accepted_secret, seen):
    def urlopen(request, timeout=None):
        body = json.loads(request.data)
        seen.append(body['secret'])
        if body['secret'] != accepted_secret:
            raise urllib.error.HTTPError(request.full_url, 403, 'Forbidden', {}, None)
        return FakeResponse()
    return urlopen


@override_settings(PC_AGENT_SHARED_SECRET=SHARED, PC_AGENT_REQUIRE_PER_PC_SECRET=False)
class CommandSigningTests(TestCase):
    def setUp(self):
        lab = Lab.objects.create(name='Cmd Lab', opening_time=datetime.time(0), closing_time=datetime.time(23, 59))
        self.pc = PC.objects.create(lab=lab, pc_id='C-01', ip_address='10.30.0.1', status='online')

    def test_unmigrated_pc_gets_the_shared_secret(self):
        seen = []
        with mock.patch('urllib.request.urlopen', agent_that_accepts(SHARED, seen)):
            ok, message = network.unlock_pc(self.pc)
        self.assertTrue(ok, message)
        self.assertEqual(seen, [SHARED])

    def test_reinstalled_agent_is_reached_with_its_own_secret_and_then_only_that(self):
        own = agent_auth.ensure_secret(self.pc)
        seen = []
        with mock.patch('urllib.request.urlopen', agent_that_accepts(own, seen)):
            ok, message = network.lock_pc(self.pc)
        self.assertTrue(ok, message)
        self.assertEqual(seen, [SHARED, own], 'shared first, then its own secret after the 403')
        self.pc.refresh_from_db()
        self.assertTrue(self.pc.agent_secret_in_use)
        self.assertEqual(agent_auth.secrets_for_command(self.pc), [(own, True)])

    def test_rejected_by_agent_gives_advice_without_the_secret(self):
        agent_auth.ensure_secret(self.pc)
        with mock.patch('urllib.request.urlopen', agent_that_accepts('something-else', [])):
            ok, message = network.send_override_warning(self.pc, 'Admin', 30)
        self.assertFalse(ok)
        self.assertIn('Agent config', message)
        self.assertNotIn(SHARED, message)
        self.assertNotIn(self.pc.agent_secret, message)


class ManualUnlockAuthorizationTests(TestCase):
    """Manual Unlock (Guest) is for Admins and Lab In-Charges only."""

    @classmethod
    def setUpTestData(cls):
        cls.lab = Lab.objects.create(name='Unlock Lab', opening_time=datetime.time(0), closing_time=datetime.time(23, 59))
        cls.instructor = make_user('instructor', 'instructor.unlock@gmail.com')

    def setUp(self):
        self.pc = PC.objects.create(lab=self.lab, pc_id='U-01', status='online')

    def test_instructor_cannot_unlock(self):
        self.client.force_login(self.instructor)
        response = self.client.post(reverse('manual_unlock'), {'pc': self.pc.pk, 'guest_name': 'Guest', 'lab': self.lab.pk})
        self.assertEqual(response.status_code, 403)
        self.pc.refresh_from_db()
        self.assertEqual(self.pc.current_guest_name, '')

    def test_agent_apis_refuse_unknown_secrets_before_doing_anything(self):
        for name in ('pc_agent_login_api', 'pc_agent_activity_api', 'pc_agent_end_session_api',
                     'pc_agent_logout_api', 'manual_unlock_log_api'):
            response = self.client.post(reverse(name), json.dumps({'secret': 'guess'}), content_type='application/json')
            self.assertEqual(response.status_code, 403, name)


@override_settings(PC_AGENT_SHARED_SECRET=SHARED)
class SystemStatusSecretSummaryTests(TestCase):
    def test_status_page_shows_secret_migration(self):
        lab = Lab.objects.create(name='Sum Lab', opening_time=datetime.time(0), closing_time=datetime.time(23, 59))
        pc = PC.objects.create(lab=lab, pc_id='M-01', ip_address='10.40.0.1', status='online')
        agent_auth.ensure_secret(pc)
        admin = make_user('admin', 'admin.summary@gmail.com')
        self.client.force_login(admin)
        with mock.patch.multiple('system.connectivity', probe_internet=mock.Mock(return_value=(True, '')),
                                 probe_smtp=mock.Mock(return_value=(None, 'x')), probe_cloud=mock.Mock(return_value=(None, 'x'))):
            response = self.client.get(reverse('system_status'))
        self.assertContains(response, 'Agent secrets: 0 of 1 PCs use their own secret')
        self.assertContains(response, 'agent not yet reinstalled')
        self.assertContains(response, 'M-01')
        self.assertNotContains(response, pc.agent_secret)

    def test_agent_summary_counts_pcs_with_an_ip(self):
        """Regression: .exclude(ip_address='') became "NOT ip_address = NULL"
        and hid every PC from System status and /healthz/ready."""
        import django.utils.timezone as tz
        from system import connectivity
        lab = Lab.objects.create(name='Count Lab', opening_time=datetime.time(0), closing_time=datetime.time(23, 59))
        PC.objects.create(lab=lab, pc_id='N-01', ip_address='10.50.0.1', status='offline')
        PC.objects.create(lab=lab, pc_id='N-02', status='online')   # no IP: not counted
        summary = connectivity._agent_summary(tz.now())
        self.assertEqual(summary['pcs'], 1)
        self.assertEqual(summary['offline'], 1)
