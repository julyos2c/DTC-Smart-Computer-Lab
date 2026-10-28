"""Regression tests: cloud stale status, safe sync, inventory CRUD intents."""
import json
import uuid
from datetime import timedelta
from unittest.mock import patch
from django.test import TestCase, override_settings
from django.utils import timezone
from accounts.models import User
from labs.models import Lab, PC, InventoryItem, MaintenanceLog, EquipmentIssue
from cloud_receiver.models import InventoryReceipt, ReplicaRecord
from cloud_receiver import receiver
from cloud_sync import sync_payloads, inventory_commands, live_status
from cloud_sync.models import SyncQueue

SITE='campus'
KEY='cloud-key-1234'
SETTINGS = dict(CLOUD_RECEIVER_ENABLED=True, CLOUD_INVENTORY_ENABLED=True,
                CLOUD_RECEIVER_ALLOW_HTTP=False,
                CLOUD_RECEIVER_SITES={SITE:receiver.key_hash(KEY)},
                CLOUD_SYNC_SITE_ID=SITE, CLOUD_SYNC_API_KEY=KEY,
                CLOUD_SERVER_URL='https://cloud.example.test', CLOUD_SYNC_ENABLED=True,
                CLOUD_SYNC_OBJECT_TYPES=('lab','pc','inventory','maintenance_log','equipment_issue'),
                CLOUD_INVENTORY_EDGE_ACTOR_EMAIL='admin@gmail.com', EDGE_CLOUD_INVENTORY_ENABLED=True,
                CLOUD_PC_REFRESH_SECONDS=30)


@override_settings(**SETTINGS)
class LiveInventoryTests(TestCase):
    def setUp(self):
        self.admin = User.objects.create(email='admin@gmail.com', role='admin', is_staff=True,
                                         email_verified=True, approval_status='approved')
        self.lab = Lab.objects.create(name='Lab One')
        self.pc = PC.objects.create(lab=self.lab, pc_id='PC01', status='in_use',
                                    last_seen_at=timezone.now(), agent_version='2.2')
        self.item = InventoryItem.objects.create(name='Keyboard', category='Peripheral',
                         quantity=8, condition='good', status='operational', lab=self.lab)

    def command(self, action='create', target=None, payload=None, **extra):
        return dict(id=str(uuid.uuid4()), site_id=SITE, action=action,
                    target_id=target.pk if target else None,
                    base_revision=(sync_payloads.pc_revision(target) if isinstance(target, PC) else
                                   sync_payloads.inventory_revision(target)) if target else '',
                    payload=payload if payload is not None else
                            {'name':'Mouse','category':'Peripheral','quantity':3,
                             'condition':'good','lab':self.lab.pk},
                    requested_by='cloud-admin',
                    expires_at=(timezone.now()+timedelta(hours=1)).isoformat(), **extra)

    def test_no_agent_secrets_or_user_details_in_pc_snapshot(self):
        self.pc.agent_secret = 'sensitive-secret'
        self.pc.save()
        value=sync_payloads.snapshot('pc', self.pc)
        self.assertNotIn('agent_secret', value)
        self.assertNotIn('current_guest_name', value)
        self.assertEqual(value['status'],'in_use')
        self.assertEqual(value['lab']['name'],'Lab One')

    def test_periodic_refresh_sees_queryset_update_and_is_rate_limited(self):
        PC.objects.filter(pk=self.pc.pk).update(status='offline')
        self.assertEqual(live_status.run_once(),1)
        rows=SyncQueue.objects.filter(object_type='pc',local_id=self.pc.pk)
        self.assertEqual(rows.count(),1)
        self.assertEqual(rows.get().payload['status'],'offline')
        self.assertEqual(live_status.run_once(),0)

    def test_create_command_idempotent_and_publishes(self):
        c=self.command()
        r=inventory_commands.execute(c)
        self.assertEqual(r.status,'applied',r.result)
        self.assertEqual(inventory_commands.execute(c).pk,r.pk)
        self.assertEqual(InventoryItem.objects.filter(name='Mouse').count(),1)
        self.assertEqual(SyncQueue.objects.filter(object_type='inventory',local_id=r.result['local_id']).count(),1)

    def test_stale_revision_conflict_and_no_mutation(self):
        oldrev=sync_payloads.inventory_revision(self.item)
        self.item.quantity=6
        self.item.save()
        cmd=self.command('update', self.item, payload={'quantity':4})
        cmd['base_revision']=oldrev
        r=inventory_commands.execute(cmd)
        self.assertEqual(r.status,'conflict')
        self.item.refresh_from_db()
        self.assertEqual(self.item.quantity,6)

    def test_update_and_delete_tombstone(self):
        r=inventory_commands.execute(self.command('update', self.item, payload={'quantity':4}))
        self.assertEqual(r.status,'applied',r.result)
        self.item.refresh_from_db()
        self.assertEqual(self.item.quantity,4)
        r=inventory_commands.execute(self.command('delete', self.item, payload={}))
        self.assertEqual(r.status,'applied',r.result)
        self.assertFalse(InventoryItem.objects.filter(pk=self.item.pk).exists())
        self.assertTrue(SyncQueue.objects.filter(object_type='inventory',local_id=self.item.pk,operation='delete').exists())

    def test_invalid_lab_rejected_and_rolled_back(self):
        c=self.command(payload={'name':'Bad','category':'Other','quantity':1,'condition':'good','lab':9999})
        r=inventory_commands.execute(c)
        self.assertEqual(r.status,'rejected',r.result)
        self.assertFalse(InventoryItem.objects.filter(name='Bad').exists())

    def test_cloud_endpoint_requires_https_and_valid_key(self):
        url='/api/inventory-changes/'
        body=json.dumps({'results':[]})
        kwargs={'content_type':'application/json', 'HTTP_AUTHORIZATION':'Bearer '+KEY,
                'HTTP_X_COMPULAB_SITE':SITE}
        self.assertEqual(self.client.post(url,body,secure=False,**kwargs).status_code,403)
        self.assertEqual(self.client.post(url,body,secure=True,**{**kwargs,'HTTP_AUTHORIZATION':'Bearer nope'}).status_code,401)
        self.assertEqual(self.client.post(url,body,secure=True,**kwargs).status_code,200)

    def test_monitor_requires_staff_and_flags_stale(self):
        p=sync_payloads.snapshot('pc', self.pc)
        ReplicaRecord.objects.create(site_id=SITE, object_type='pc', local_id=self.pc.pk,
                                     payload=p, applied_at=timezone.now())
        url='/cloud/api/pc-status/'
        self.assertEqual(self.client.get(url).status_code,302)
        self.client.force_login(self.admin)
        page=self.client.get('/cloud/monitor/')
        self.assertEqual(page.status_code, 200)
        self.assertContains(page, 'CompuLab Cloud Monitor')
        fresh=self.client.get(url)
        self.assertEqual(fresh.status_code,200)
        self.assertEqual(fresh.json()['pcs'][0]['effective_status'],'in_use')
        self.assertNotIn('agent_secret', json.dumps(fresh.json()))
        ReplicaRecord.objects.filter(object_type='pc').update(applied_at=timezone.now()-timedelta(minutes=5))
        stale=self.client.get(url).json()['pcs'][0]
        self.assertEqual(stale['effective_status'],'stale')

    def test_pc_create_update_and_safe_delete(self):
        c=self.command(payload={'lab':self.lab.pk, 'pc_id':'PC-NEW', 'ip_address':'192.168.1.21'})
        c['object_type']='pc'
        r=inventory_commands.execute(c)
        self.assertEqual(r.status,'applied',r.result)
        new=PC.objects.get(pc_id='PC-NEW')
        self.assertEqual(new.status,'offline')
        self.assertTrue(SyncQueue.objects.filter(object_type='pc',local_id=new.pk).exists())
        cmd=self.command('update',new,payload={'ip_address':'192.168.1.22'})
        cmd['object_type']='pc'; cmd['base_revision']=sync_payloads.pc_revision(new)
        r=inventory_commands.execute(cmd)
        self.assertEqual(r.status,'applied',r.result)
        new.refresh_from_db()
        self.assertEqual(new.ip_address,'192.168.1.22')
        cmd=self.command('delete',new,payload={})
        cmd['object_type']='pc'; cmd['base_revision']=sync_payloads.pc_revision(new)
        r=inventory_commands.execute(cmd)
        self.assertEqual(r.status,'applied',r.result)
        self.assertFalse(PC.objects.filter(pk=new.pk).exists())

    def test_pc_does_not_allow_remote_status_edits(self):
        cmd=self.command('update',self.pc,payload={'status':'online'})
        cmd['object_type']='pc'
        cmd['base_revision']=sync_payloads.pc_revision(self.pc)
        r=inventory_commands.execute(cmd)
        self.assertEqual(r.status,'rejected',r.result)
        self.pc.refresh_from_db()
        self.assertEqual(self.pc.status,'in_use')

    def test_inventory_and_pc_admin_form_revisions(self):
        from cloud_receiver.inventory_admin import InventoryChangeForm
        now=(timezone.localtime()+timedelta(hours=1)).strftime('%Y-%m-%d %H:%M:%S')
        row=ReplicaRecord.objects.create(site_id=SITE,object_type='pc', local_id=self.pc.pk,
                                         payload=sync_payloads.snapshot('pc',self.pc))
        form=InventoryChangeForm({'site_id':SITE,'object_type':'pc','action':'update',
                                 'inventory_record':row.pk,'ip_address':'192.168.1.31',
                                 'expires_at':now})
        self.assertTrue(form.is_valid(),form.errors)
        self.assertEqual(form.instance.base_revision,sync_payloads.pc_revision(self.pc))
        self.assertEqual(form.instance.payload,{'ip_address':'192.168.1.31'})

    def test_receiver_accepts_inventory_and_pc_schema(self):
        items=[dict(edge_id=str(uuid.uuid4()),object_type=obj_type,local_id=1,
                    sequence=idx+1,operation='upsert',schema_version=1,payload={'name':'x'})
               for idx,obj_type in enumerate(('lab','pc','inventory','maintenance_log','equipment_issue'))]
        result=receiver.process_batch(SITE, {'protocol':2,'site_id':SITE,'records':items})
        self.assertEqual(result[0],200)
        self.assertEqual(len(result[1]['accepted_edge_ids']),5)
