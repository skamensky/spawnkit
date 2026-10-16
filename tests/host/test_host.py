"""Offline safety and persistence tests: never touch host services or devices."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(os.environ.get('SPAWNKIT_REPO', Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(ROOT / 'scripts'))
from spawnkit_host import load_config, render_windows, selector


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

host = module('host_state', 'ansible/roles/base/files/host-state.py')
guard = module('gpu_guard', 'ansible/roles/gpu_handoff/files/gpu-guard.py')


def gpu_config():
    import yaml
    return load_config(ROOT, 'laptop-ubuntu', yaml.safe_load((ROOT / 'tests/host/gpu.yml').read_text()))


class Configuration(unittest.TestCase):
    def test_unknown_hosts_have_base_only_profile(self):
        registry = json.loads((ROOT / 'hosts/registry.json').read_text())
        profile = selector().select_profile(registry, 'unknown-cloud', 'linux')
        self.assertEqual(profile, 'default')
        cfg = load_config(ROOT, profile)
        self.assertFalse(any(cfg[k] for k in ('docker', 'nvidia', 'virtualization', 'gpu_handoff', 'windows_vm')))

    def test_rejects_unsafe_or_misspelled_settings(self):
        for settings in ({'dokcer': True}, {'windows_vm': True}, {'gpu_handoff': True},
                         {'ssh': True}, {'ssh_port': 70000}, {'looking_glass_mib': 123},
                         {'windows_disk': '../disk'}, {'network_dhcp_start': '10.0.0.1'},
                         {'gpu_devices': [{'address': 'not-pci', 'driver': 'nvidia'}]}):
            with self.subTest(settings=settings), self.assertRaises(ValueError):
                load_config(ROOT, 'default', settings)

    def test_domain_preserves_identity_and_managed_devices(self):
        cfg = gpu_config()
        tree = ET.fromstring(render_windows(ROOT, cfg))
        self.assertEqual(tree.findtext('uuid'), gpu_config()['windows_uuid'])
        self.assertEqual(tree.find('./devices/tpm/backend').get('version'), '2.0')
        self.assertEqual(tree.find('./os').get('firmware'), 'efi')
        self.assertTrue(host.managed_domain(ET.tostring(tree)))
        self.assertTrue(guard.validate_domain(cfg, ET.tostring(tree)))
        tree.find('./devices/hostdev').set('managed', 'no')
        with self.assertRaises(RuntimeError):
            guard.validate_domain(cfg, ET.tostring(tree))

    def test_other_domain_cannot_take_reserved_gpu(self):
        cfg = gpu_config()
        tree = ET.fromstring(render_windows(ROOT, cfg))
        tree.find('name').text = 'other'
        with self.assertRaises(RuntimeError):
            guard.validate_domain(cfg, ET.tostring(tree))
        for dev in list(tree.findall('./devices/hostdev')):
            tree.find('devices').remove(dev)
        self.assertFalse(guard.validate_domain(cfg, ET.tostring(tree)))


class HostPersistence(unittest.TestCase):
    def test_docker_merge_is_idempotent_and_preserves_unknown_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'daemon.json'
            original = {'log-driver': 'local', 'runtimes': {'custom': {'path': '/custom'}}}
            path.write_text(json.dumps(original))
            requested = {'runtimes': {'nvidia': {'path': 'nvidia-container-runtime'}}}
            with patch.object(host, 'command', return_value=subprocess.CompletedProcess([], 0, '', '')):
                self.assertTrue(host.merge_docker(requested, path))
                self.assertFalse(host.merge_docker(requested, path))
            self.assertEqual(json.loads(path.read_text())['runtimes']['custom']['path'], '/custom')
            self.assertEqual(json.loads(path.with_name('daemon.json.before-spawnkit').read_text()), original)

    def test_busy_docker_is_not_reconfigured(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'daemon.json'
            path.write_text('{}')
            with patch.object(host.Path, 'exists', return_value=True), patch.object(host, 'command', return_value=subprocess.CompletedProcess([], 0, 'container-id', '')):
                with self.assertRaises(RuntimeError):
                    host.merge_docker({'debug': True}, path)
            self.assertEqual(path.read_text(), '{}')

    def test_existing_unmanaged_domain_is_never_replaced(self):
        cfg = gpu_config()
        with tempfile.TemporaryDirectory() as directory:
            xml = Path(directory) / 'vm.xml'
            xml.write_text(render_windows(ROOT, cfg))
            with patch.object(host, 'command', side_effect=[subprocess.CompletedProcess([], 0, 'windows\n', ''), subprocess.CompletedProcess([], 0, '<domain><name>windows</name></domain>', '')]) as invoke:
                with self.assertRaisesRegex(RuntimeError, 'unmanaged'):
                    host.define_windows(cfg, xml, Path(directory))
                self.assertEqual(invoke.call_count, 2)

    def test_uuid_change_cannot_replace_tpm_identity(self):
        cfg = gpu_config()
        xml_content = render_windows(ROOT, cfg)
        current = xml_content.replace(cfg['windows_uuid'], '00000000-0000-0000-0000-000000000001')
        with tempfile.TemporaryDirectory() as directory:
            xml = Path(directory) / 'vm.xml'
            xml.write_text(xml_content)
            with patch.object(host, 'command', side_effect=[subprocess.CompletedProcess([], 0, 'windows\n', ''), subprocess.CompletedProcess([], 0, current, '')]) as invoke:
                with self.assertRaisesRegex(RuntimeError, 'UUID'):
                    host.define_windows(cfg, xml, Path(directory))
                self.assertEqual(invoke.call_count, 2)


    def test_connection_failure_does_not_create_a_domain_or_disk(self):
        cfg = gpu_config()
        with tempfile.TemporaryDirectory() as directory:
            xml = Path(directory) / 'vm.xml'
            xml.write_text(render_windows(ROOT, cfg))
            with patch.object(host, 'command', side_effect=subprocess.CalledProcessError(1, ['virsh'])) as invoke:
                with self.assertRaises(subprocess.CalledProcessError):
                    host.define_windows(cfg, xml, Path(directory))
                self.assertEqual(invoke.call_count, 1)

    def test_running_vm_is_not_redefined(self):
        cfg = gpu_config()
        content = render_windows(ROOT, cfg)
        with tempfile.TemporaryDirectory() as directory:
            xml = Path(directory) / 'desired.xml'
            xml.write_text(content)
            answers = [subprocess.CompletedProcess([], 0, 'windows\n', ''),
                       subprocess.CompletedProcess([], 0, content, ''),
                       subprocess.CompletedProcess([], 0, 'running', '')]
            with patch.object(host, 'command', side_effect=answers) as invoke:
                with self.assertRaisesRegex(RuntimeError, 'Shut the VM down'):
                    host.define_windows(cfg, xml, Path(directory))
                self.assertEqual(invoke.call_count, 3)


    def test_manual_domain_drift_requires_shutdown_before_convergence(self):
        cfg = gpu_config()
        content = render_windows(ROOT, cfg)
        # Use parsed XML so this invariant does not depend on template whitespace.
        tree = ET.fromstring(content)
        tree.find('vcpu').text = '4'
        drifted = ET.tostring(tree, encoding='unicode')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            xml = root / 'desired.xml'
            xml.write_text(content)
            (root / 'windows.xml').write_text(content)
            (root / 'windows.resolved.xml').write_text(ET.canonicalize(content, strip_text=True))
            answers = [subprocess.CompletedProcess([], 0, 'windows\n', ''),
                       subprocess.CompletedProcess([], 0, drifted, ''),
                       subprocess.CompletedProcess([], 0, 'running', '')]
            with patch.object(host, 'command', side_effect=answers):
                with self.assertRaisesRegex(RuntimeError, 'Shut the VM down'):
                    host.define_windows(cfg, xml, root)


class GPUHandoff(unittest.TestCase):
    def test_busy_gpu_refuses_and_releases_its_reservation(self):
        cfg = gpu_config()
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'owner.json'
            with patch.object(guard, 'inspect_devices', return_value=['/dev/fake']), patch.object(guard, 'users', return_value=[os.getpid()]):
                with self.assertRaisesRegex(RuntimeError, 'GPU busy'):
                    guard.prepare(cfg, render_windows(ROOT, cfg), state=state)
            self.assertFalse(state.exists())

    def test_existing_reservation_is_not_stolen(self):
        cfg = gpu_config()
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'owner.json'
            state.write_text('protected')
            with self.assertRaises(FileExistsError):
                guard.prepare(cfg, render_windows(ROOT, cfg), state=state)
            self.assertEqual(state.read_text(), 'protected')

    def test_idle_prepare_sizes_shared_memory_and_keeps_reservation(self):
        cfg = gpu_config() | {'looking_glass_mib': 1}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'owner.json'
            shm = root / cfg['looking_glass_name']
            shm.touch()
            with patch.object(guard, 'inspect_devices', return_value=[]), patch.object(guard, 'users', return_value=[]):
                guard.prepare(cfg, render_windows(ROOT, cfg), state=state, shm_root=root)
            self.assertEqual(shm.stat().st_size, 2**20)
            self.assertEqual(json.loads(state.read_text())['uuid'], cfg['windows_uuid'])

    def test_failed_driver_restore_retains_reservation(self):
        cfg = gpu_config()
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'owner.json'
            state.write_text(json.dumps({'uuid': cfg['windows_uuid']}))
            with patch.object(guard, 'inspect_devices', side_effect=RuntimeError('still vfio-pci')):
                with self.assertRaisesRegex(RuntimeError, 'vfio-pci'):
                    guard.release(cfg, state=state)
            self.assertTrue(state.exists())

    def test_iommu_group_must_be_complete(self):
        cfg = gpu_config()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for device in cfg['gpu_devices']:
                path = root / device['address']
                path.mkdir()
                target = root / device['driver']
                target.mkdir(exist_ok=True)
                (path / 'driver').symlink_to(target)
                group = path / 'iommu_group/devices/0000:02:00.0'
                group.mkdir(parents=True)
                (group / 'class').write_text('0x020000')
            with self.assertRaisesRegex(RuntimeError, 'also contains'):
                guard.inspect_devices(cfg, root)


if __name__ == '__main__':
    unittest.main()
