import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock,patch
import json
import tempfile
import xml.etree.ElementTree as ET

SOURCE=Path(__file__).resolve().parents[2]/'ansible/roles/ci_vms/files/ci-vm.py'
spec=importlib.util.spec_from_file_location('ci_vm',SOURCE)
ci=importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class IsolationTests(unittest.TestCase):
    def test_incomplete_builder_cannot_replace_the_accepted_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            (root/'build-name').write_text('ci-'+('a'*32))
            accepted=root/'runner-base.qcow2'
            accepted.write_bytes(b'accepted image')
            with patch.object(ci,'ROOT',root),patch.object(ci,'run',return_value='running') as run,patch.object(ci,'guest_exec',return_value={'exitcode':127}):
                with self.assertRaisesRegex(RuntimeError,'not ready'):
                    ci.finalize_image()
            self.assertEqual(accepted.read_bytes(),b'accepted image')
            self.assertEqual(run.call_count,1)

    def test_guest_reservations_cannot_overcommit_host_memory_or_disk(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            state={'slot':1,'memory_mib':8192,'name':'ci-'+('a'*32)}
            (root/'ci-state.json').write_text(json.dumps(state))
            c={'ci_guest_memory_mib':8192,'ci_guest_disk_gib':40}
            with patch.object(ci,'STATE',root),patch.object(ci,'ROOT',root),patch.object(ci.shutil,'disk_usage',return_value=Mock(free=500*(1024**3))):
                with self.assertRaises(RuntimeError):
                    ci.require_capacity(c,1)
                ci.require_capacity(c,2)
                c['ci_guest_memory_mib']=18000
                with self.assertRaises(RuntimeError):
                    ci.require_capacity(c,2)
            with patch.object(ci,'STATE',root),patch.object(ci,'ROOT',root),patch.object(ci.shutil,'disk_usage',return_value=Mock(free=100*(1024**3))):
                c['ci_guest_memory_mib']=4096
                with self.assertRaises(RuntimeError):
                    ci.require_capacity(c,2)

    def test_api_failure_cannot_keep_a_vm_alive_or_lose_its_revocation_receipt(self):
        calls=[]
        app=Mock()
        app.request.side_effect=lambda *_: (_ for _ in ()).throw(RuntimeError('API unavailable'))
        receipt=Mock()
        with patch.object(ci,'destroy',side_effect=lambda *a,**kw:calls.append((a,kw))):
            with self.assertRaises(RuntimeError):
                ci.retire_registered(app,'repos/owner/repo/actions/runners',
                    {'name':'ci-'+('a'*32),'runner_id':7},receipt)
        self.assertEqual(calls,[(('ci-'+('a'*32),),{'keep_state':True})])
        receipt.unlink.assert_not_called()

    def test_effective_qemu_placement_and_quota_are_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            name='ci-'+('a'*32)
            def virtual_path(*parts):
                return root/str(Path(*parts)).lstrip('/')
            files={
                '/run/libvirt/qemu/'+name+'.pid':'123',
                '/proc/123/task/123/cgroup':'0::/machine.slice/machine-qemu.scope/libvirt/emulator',
                '/proc/123/task/124/cgroup':'0::/machine.slice/machine-qemu.scope/libvirt/vcpu0',
                '/sys/fs/cgroup/machine.slice/cpu.max':'560000 100000',
                '/sys/fs/cgroup/machine.slice/memory.max':str(26*1024**3)}
            for namepath,value in files.items():
                path=virtual_path(namepath);path.parent.mkdir(parents=True,exist_ok=True);path.write_text(value)
            c={'ci_cpu_quota_percent':560}
            with patch.object(ci,'Path',side_effect=virtual_path):
                ci.require_vm_budget(name,c)
                virtual_path('/sys/fs/cgroup/machine.slice/cpu.max').write_text('max 100000')
                with self.assertRaises(RuntimeError):ci.require_vm_budget(name,c)
                virtual_path('/sys/fs/cgroup/machine.slice/cpu.max').write_text('560000 100000')
                virtual_path('/proc/123/task/124/cgroup').write_text('0::/other.slice/vcpu0')
                with self.assertRaises(RuntimeError):ci.require_vm_budget(name,c)

    def test_libvirt_outage_cannot_delete_potentially_live_disks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            name='ci-'+('a'*32)
            directory=root/name
            directory.mkdir()
            (directory/'disk.qcow2').write_bytes(b'protected guest dependency')
            with patch.object(ci,'ROOT',root),patch.object(ci,'run',side_effect=RuntimeError('libvirt unavailable')):
                with self.assertRaises(RuntimeError):
                    ci.destroy(name)
            self.assertTrue((directory/'disk.qcow2').exists())

    def test_expired_guest_stops_locally_before_provider_is_contacted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            name='ci-'+('a'*32)
            receipt=root/(name+'.json')
            receipt.write_text(json.dumps({'name':name,'created':0,'runner_id':7}))
            with patch.object(ci,'STATE',root),patch.object(ci,'destroy') as destroy:
                ci.reap_expired({'ci_job_timeout_seconds':60})
            destroy.assert_called_once_with(name,keep_state=True)
            self.assertTrue(receipt.exists())

    def test_production_rejects_the_old_host_kernel(self):
        with patch.object(ci.platform,'release',return_value='5.15.0-91-generic'):
            with self.assertRaises(RuntimeError):
                ci.require_current_kernel({'ci_min_host_kernel':'5.15.0-198'})
        with patch.object(ci.platform,'release',return_value='5.15.0-198-generic'):
            ci.require_current_kernel({'ci_min_host_kernel':'5.15.0-198'})

    def test_only_managed_names_can_be_deleted(self):
        for bad in ['../shmuel','ci-../../etc','ubuntu-base.qcow2','ci-'+('a'*31)]:
            with self.assertRaises(ValueError):
                ci.vm_name(bad)

    def test_domain_exposes_only_guest_disks_and_network(self):
        name='ci-'+('a'*32)
        xml=ET.fromstring(ci.domain_xml(name,Path('/images')/name,1,
            {'ci_guest_memory_mib':4096,'ci_guest_vcpus':2,'ci_network':'spawnkit-ci','ci_subnet':'192.168.251'}))
        self.assertEqual(xml.findtext('resource/partition'),'/machine')
        self.assertEqual(len(xml.findall('devices/disk')),2)
        self.assertIsNone(xml.find('devices/filesystem'))
        self.assertIsNone(xml.find('devices/hostdev'))
        self.assertIsNone(xml.find('devices/graphics'))
        self.assertEqual(xml.find('cpu/feature[@name="vmx"]').get('policy'),'disable')
        self.assertEqual(xml.find('devices/interface/port').get('isolated'),'yes')
        self.assertEqual(xml.find('devices/interface/filterref').get('filter'),'clean-traffic')
        self.assertEqual(xml.find('devices/channel/target').get('name'),'org.qemu.guest_agent.0')

    def test_jit_is_guest_only_and_shell_metacharacters_are_rejected(self):
        with self.assertRaises(ValueError):
            ci.runner_user_data('abc; touch /host')
        data=ci.runner_user_data('YWJjZA==')
        self.assertEqual(data['write_files'][0]['path'],'/run/ci-jit')
        self.assertEqual(data['write_files'][0]['permissions'],'0600')
        self.assertEqual(data['runcmd'][0],['systemctl','start','--no-block','ci-runner.service'])

    def test_queue_ignores_hosted_benchmark_and_incompatible_jobs(self):
        class App:
            def request(self,path):
                if 'status=queued' in path:
                    return {'workflow_runs':[{'id':1}]}
                if 'status=in_progress' in path:
                    return {'workflow_runs':[]}
                return {'jobs':[
                    {'status':'queued','labels':['ubuntu-latest']},
                    {'status':'queued','labels':['self-hosted','home-server-benchmark','supa-crm']},
                    {'status':'queued','labels':['self-hosted','home-server','gpu']},
                    {'status':'queued','labels':['self-hosted','LINUX','X64','home-server','supa-crm']},
                    {'status':'completed','labels':['self-hosted','home-server']} ]}
        self.assertEqual(ci.queued_jobs(App(),{'ci_slots':6,'ci_repository':'owner/repo',
            'ci_labels':['home-server','supa-crm']}),1)


if __name__=='__main__':
    unittest.main()
