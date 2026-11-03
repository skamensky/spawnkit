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
                         {'gpu_devices': [{'address': 'not-pci', 'driver': 'nvidia'}]},
                         {'host_packages': ['bad;name']}, {'nvidia_prime': 'hybrid'}, {'nvidia_prime': 'on-demand'},
                         {'desktop_session': 'xorg'}):
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
    def test_stale_ssh_listener_is_detected(self):
        # Observed on Ubuntu 24.04: the socket-activated sshd kept port 22 after the restart.
        ss = ('LISTEN 0 128 100.86.106.55:2222 0.0.0.0:* users:(("sshd",pid=10907,fd=3))\n'
              'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1059,fd=3))\n'
              'LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=1,fd=3))\n')
        with self.assertRaisesRegex(RuntimeError, 'stale listener'):
            host.verify_ssh_listening(2222, ['100.86.106.55'], ss)
        host.verify_ssh_listening(2222, ['100.86.106.55'], ss.replace('0.0.0.0:22 ', '127.0.0.53:22 ').replace('"sshd",pid=1059', '"other",pid=1059'))

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


class Selection(unittest.TestCase):
    def test_commands_default_to_the_enclosing_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            (checkout / 'hosts').mkdir()
            (checkout / 'hosts/registry.json').write_text('{}')
            (checkout / 'flake.nix').write_text('{}')
            (checkout / 'nested').mkdir()
            with patch.object(Path, 'cwd', return_value=checkout / 'nested'):
                self.assertEqual(selector().default_repo(), checkout)

    def test_laptop_declares_tailnet_ssh_and_ubuntu_solaar(self):
        cfg = load_config(ROOT, 'laptop-ubuntu')
        self.assertTrue(cfg['ssh'])
        self.assertEqual(cfg['ssh_listen_addresses'], ['100.86.106.55'])
        self.assertIn('solaar', cfg['host_packages'])
        self.assertIn('build-essential', cfg['base_packages'])


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
            with self.assertRaisesRegex(RuntimeError, 'gpu-guard.py reclaim'):
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
                    guard.release(cfg, state=state, delay=0)
            self.assertTrue(state.exists())

    def test_release_retries_a_slow_driver_before_clearing_reservation(self):
        cfg = gpu_config()
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'owner.json'
            state.write_text(json.dumps({'uuid': cfg['windows_uuid']}))
            slow = [subprocess.CalledProcessError(9, 'nvidia-smi'), subprocess.CompletedProcess([], 0)]
            with patch.object(guard, 'inspect_devices', return_value=[]), patch.object(guard.subprocess, 'run', side_effect=slow), \
                    patch.object(guard, 'desktop_seat') as seat:
                guard.release(cfg, state=state, delay=0)
            self.assertFalse(state.exists())
            seat.assert_called_once_with(cfg, True, guard.SYSFS)

    def test_detached_seat_rule_covers_only_the_nvidia_function_and_is_removed_on_attach(self):
        cfg = gpu_config()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rule = root / 'rules.d/72-spawnkit-gpu-handoff.rules'
            drm = root / cfg['gpu_devices'][0]['address'] / 'drm/card9'
            drm.mkdir(parents=True)
            with patch.object(guard.subprocess, 'run') as run:
                guard.desktop_seat(cfg, False, sysfs=root, rule=rule)
                lines = rule.read_text().splitlines()
                self.assertEqual(len(lines), sum(d['driver'] == 'nvidia' for d in cfg['gpu_devices']))
                self.assertIn('ENV{ID_SEAT}="spawnkit-gpu-handoff"', lines[0])
                self.assertIn(str(drm), run.call_args.args[0])
                guard.desktop_seat(cfg, True, sysfs=root, rule=rule)
            self.assertFalse(rule.exists())

    def test_awaiting_holders_returns_the_gpu_to_the_desktop_on_timeout(self):
        cfg = gpu_config()
        with patch.object(guard, 'inspect_devices', return_value=['/dev/fake']), \
                patch.object(guard, 'users', return_value=[os.getpid()]), patch.object(guard, 'desktop_seat') as seat:
            with self.assertRaisesRegex(RuntimeError, 'GPU busy'):
                guard.await_idle(cfg, 0, delay=0)
        seat.assert_called_once_with(cfg, True)

    def test_known_desktop_holders_get_specific_advice(self):
        with patch.object(guard, 'users', return_value=[os.getpid()]), \
                patch.object(guard.Path, 'read_text', return_value='nvidia-persistenced\n'):
            with self.assertRaisesRegex(RuntimeError, 'systemctl stop nvidia-persistenced'):
                guard.require_idle(['/dev/nvidia0'])

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
