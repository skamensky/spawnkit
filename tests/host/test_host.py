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
from spawnkit_host import bootstrap_settings, guest_inventory, load_config, render_unattend, render_windows, selector


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

host = module('host_state', 'ansible/roles/base/files/host-state.py')
guard = module('gpu_guard', 'ansible/roles/gpu_handoff/files/gpu-guard.py')
cli = module('host_config', 'scripts/host-config.py')
watchdog = module('lg_watchdog', 'scripts/lg-watchdog.py')


def gpu_config():
    import yaml
    return load_config(ROOT, 'laptop-ubuntu', yaml.safe_load((ROOT / 'tests/host/gpu.yml').read_text()))



def holder(pid, name='python3', closable=True):
    return {'pid': pid, 'name': name, 'command': f'{name} job', 'uid': os.getuid(), 'closable': closable}

UNATTEND = '{urn:schemas-microsoft-com:unattend}'


class Guest(unittest.TestCase):
    def test_unattend_installs_the_edition_for_a_passwordless_administrator(self):
        cfg = gpu_config()
        tree = ET.fromstring(render_unattend(ROOT, cfg))
        self.assertEqual(tree.findtext(f'.//{UNATTEND}MetaData/{UNATTEND}Value'), 'Windows 11 Home')
        self.assertEqual(tree.findtext(f'.//{UNATTEND}ProductKey/{UNATTEND}Key'), 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7')
        self.assertEqual(tree.findtext(f'.//{UNATTEND}ComputerName'), 'ShmuelWIndows')
        account = tree.find(f'.//{UNATTEND}LocalAccount')
        self.assertEqual((account.findtext(f'{UNATTEND}Name'), account.findtext(f'{UNATTEND}Group')), ('shmuel', 'Administrators'))
        self.assertEqual(account.findtext(f'{UNATTEND}Password/{UNATTEND}Value'), '')
        keys = [e.get('{http://schemas.microsoft.com/WMIConfig/2002/State}keyValue') for e in tree.iter(f'{UNATTEND}PathAndCredentials')]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertIn('E:\\viostor\\w11\\amd64', [e.findtext(f'{UNATTEND}Path') for e in tree.iter(f'{UNATTEND}PathAndCredentials')])
        commands = [e.findtext(f'{UNATTEND}CommandLine') for e in tree.iter(f'{UNATTEND}SynchronousCommand')]
        self.assertTrue(commands[0].endswith('virtio-win-guest-tools.exe /install /quiet /norestart'))
        self.assertIn('spawnkit\\bootstrap.ps1', commands[1])

    def test_bootstrap_admits_only_the_vm_network(self):
        self.assertEqual(bootstrap_settings(gpu_config(), 'ssh-rsa AAAA user\n'),
                         {'authorized_key': 'ssh-rsa AAAA user', 'network': '192.168.123.0/24'})

    def test_guest_inventory_pins_the_host_key(self):
        cfg = gpu_config()
        host_vars = guest_inventory(cfg, '/run/known_hosts', (1000, 1000))['all']['hosts']['windows']
        self.assertEqual((host_vars['ansible_host'], host_vars['ansible_user'], host_vars['ansible_shell_type']), ('192.168.123.10', 'shmuel', 'powershell'))
        self.assertIn('UserKnownHostsFile=/run/known_hosts -o StrictHostKeyChecking=yes', host_vars['ansible_ssh_common_args'])
        self.assertEqual(host_vars['ansible_control_path_dir'], '/run')

    def test_known_host_comes_from_the_guest_agent(self):
        cfg = gpu_config()
        with patch.object(cli, 'guest_run', return_value=(0, 'ssh-ed25519 AAAAkey windows\r\n', '')):
            self.assertEqual(cli.guest_known_hosts(cfg), '192.168.123.10 ssh-ed25519 AAAAkey\n')
        with patch.object(cli, 'guest_run', return_value=(1, '', 'missing')), self.assertRaises(ValueError):
            cli.guest_known_hosts(cfg)

    def test_unattend_medium_is_attached_as_a_third_cd(self):
        tree = ET.fromstring(render_windows(ROOT, gpu_config() | {'windows_unattend_iso': '/var/lib/libvirt/images/unattend.iso'}))
        media = {d.find('target').get('dev'): d.find('source').get('file') for d in tree.iterfind("./devices/disk[@device='cdrom']")}
        self.assertEqual(media['sdc'], '/var/lib/libvirt/images/unattend.iso')

    @unittest.skipUnless(cli.shutil.which('xorriso'), 'xorriso is unavailable')
    def test_guest_media_carries_answer_file_and_bootstrap(self):
        with tempfile.TemporaryDirectory() as temp:
            key = Path(temp) / 'key.pub'
            key.write_text('ssh-ed25519 AAAAtest user\n')
            iso = Path(temp) / 'unattend.iso'
            cli.guest_media(ROOT, gpu_config() | {'windows_authorized_key': str(key)}, iso)
            subprocess.run(['xorriso', '-osirrox', 'on', '-indev', str(iso), '-extract', '/', f'{temp}/out'], check=True, capture_output=True)
            settings = json.loads(Path(temp, 'out/spawnkit/bootstrap.json').read_text())
            self.assertEqual(settings['authorized_key'], 'ssh-ed25519 AAAAtest user')
            self.assertTrue(Path(temp, 'out/autounattend.xml').is_file())
            self.assertTrue(Path(temp, 'out/spawnkit/bootstrap.ps1').is_file())


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
                         {'desktop_session': 'xorg'}, {'windows_mac': '52:54:00:AA:00:01'},
                         {'windows_address': '192.168.123.10'},
                         {'windows_mac': '52:54:00:aa:00:01', 'windows_address': '192.168.123.50'},
                         {'windows_share': 'relative/share'}, {'windows_vcpus': 7},
                         {'windows_edition': 'Windows 11 Ultimate'}, {'windows_computer_name': 'name-longer-than-15'},
                         {'windows_computer_name': 'bad name'}, {'windows_authorized_key': 'id_rsa.pub'}):
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

    def test_domain_exposes_agent_share_and_fixed_mac(self):
        cfg = gpu_config() | {'windows_mac': '52:54:00:aa:00:01', 'windows_share': '/home/shmuel/Shared'}
        tree = ET.fromstring(render_windows(ROOT, cfg))
        self.assertEqual(tree.find('./devices/interface/mac').get('address'), '52:54:00:aa:00:01')
        self.assertIsNotNone(tree.find("./devices/channel/target[@name='org.qemu.guest_agent.0']"))
        self.assertEqual(tree.find('./devices/filesystem/source').get('dir'), '/home/shmuel/Shared')
        self.assertEqual(tree.find('./memoryBacking/access').get('mode'), 'shared')
        self.assertIsNone(ET.fromstring(render_windows(ROOT, gpu_config() | {'windows_share': ''})).find('./devices/filesystem'))
        self.assertEqual(tree.find('./cpu/topology').attrib, {'sockets': '1', 'dies': '1', 'cores': '4', 'threads': '2'})

    def test_domain_passes_declared_usb_devices_and_a_microphone(self):
        cfg = gpu_config() | {'windows_usb_devices': [{'vendor': '0x30c9', 'product': '0x00ac'}]}
        tree = ET.fromstring(render_windows(ROOT, cfg))
        source = tree.find("./devices/hostdev[@type='usb']/source")
        self.assertEqual((source.get('startupPolicy'), source.find('vendor').get('id'), source.find('product').get('id')),
                         ('optional', '0x30c9', '0x00ac'))
        self.assertEqual(tree.find('./devices/sound/codec').get('type'), 'micro')
        self.assertTrue(guard.validate_domain(cfg, ET.tostring(tree)))
        with self.assertRaises(ValueError):
            load_config(ROOT, 'default', {'windows_usb_devices': [{'vendor': '30c9', 'product': '0x00ac'}]})

    def test_windows_without_rtx_reserves_nothing(self):
        cfg = gpu_config()
        tree = ET.fromstring(render_windows(ROOT, cfg))
        devices = tree.find('devices')
        for device in devices.findall("hostdev[@type='pci']") + devices.findall('shmem'):
            devices.remove(device)
        self.assertFalse(guard.validate_domain(cfg, ET.tostring(tree)))
        devices.append(ET.fromstring("<hostdev mode='subsystem' type='pci' managed='yes'><source>"
                                     "<address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/></source></hostdev>"))
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
    def setUp(self):
        # The live machine may hold a reservation (Windows running); these tests never see it.
        reservation = patch.object(cli, 'GPU_RESERVATION', Path('/nonexistent/spawnkit-gpu-owner.json'))
        reservation.start()
        self.addCleanup(reservation.stop)

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
                guard.desktop_seat(cfg, False, sysfs=root, rule=rule, stopped=root / 'services.json')
                lines = rule.read_text().splitlines()
                self.assertEqual(len(lines), sum(d['driver'] == 'nvidia' for d in cfg['gpu_devices']))
                self.assertIn('ENV{ID_SEAT}="spawnkit-gpu-handoff"', lines[0])
                self.assertIn(str(drm), run.call_args.args[0])
                guard.desktop_seat(cfg, True, sysfs=root, rule=rule, stopped=root / 'services.json')
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

    def test_a_helper_process_stands_for_its_program(self):
        exes = {'/proc/30/exe': '/opt/chrome', '/proc/31/exe': '/opt/chrome', '/proc/20/exe': '/opt/chrome',
                '/proc/10/exe': '/usr/bin/plasmashell'}
        parents = {30: 20, 31: 20, 20: 10}
        raw = [{'pid': p, 'name': 'chrome', 'command': 'chrome --type=gpu-process', 'uid': os.getuid()} for p in (30, 31)]
        with patch.object(cli.os, 'readlink', side_effect=exes.__getitem__), patch.object(cli, 'parent_pid', side_effect=parents.__getitem__), \
                patch.object(cli.subprocess, 'check_output', return_value=json.dumps(raw)), \
                patch.object(cli.Path, 'read_bytes', return_value=b'chrome\0--restore'):
            self.assertEqual(cli.guard_holders(), [raw[0] | {'pid': 20, 'command': 'chrome --restore', 'closable': True}])

    def test_holders_mark_session_and_foreign_processes_unclosable(self):
        raw = [{'pid': 1, 'name': 'Xorg', 'command': 'Xorg', 'uid': os.getuid()},
               {'pid': 2, 'name': 'python3', 'command': 'python3 a.py', 'uid': os.getuid() + 1},
               {'pid': 3, 'name': 'python3', 'command': 'python3 b.py', 'uid': os.getuid()}]
        with patch.object(cli.subprocess, 'check_output', return_value=json.dumps(raw)), \
                patch.object(cli, 'GPU_RESERVATION', Path('/nonexistent')):
            self.assertEqual([h['closable'] for h in cli.guard_holders()], [False, False, True])
        with patch.object(cli, 'GPU_RESERVATION', Path(__file__)):
            with self.assertRaisesRegex(ValueError, 'assigned to Windows'):
                cli.guard_holders()

    def test_release_refuses_unclosable_and_unknown_pids(self):
        held = [holder(10, closable=False)]
        with patch.object(cli, 'guard_holders', return_value=held), patch.object(cli.os, 'kill') as kill:
            with self.assertRaisesRegex(ValueError, 'not closable'):
                cli.release_holders([10], force=False)
            with self.assertRaisesRegex(ValueError, 'does not hold'):
                cli.release_holders([11], force=False)
        kill.assert_not_called()

    def test_release_force_kills_after_term(self):
        held = [holder(10)]
        with patch.object(cli, 'guard_holders', side_effect=[held, held, []]), patch.object(cli.os, 'kill') as kill, \
                patch.object(cli.time, 'monotonic', side_effect=[0, 11, 0]), patch.object(cli.time, 'sleep'):
            self.assertEqual(cli.release_holders([10], force=True), [])
        self.assertEqual([c.args for c in kill.call_args_list], [(10, cli.signal.SIGTERM), (10, cli.signal.SIGKILL)])

    def picker(self, *replies):
        """Patch the rtx-holders dialog with one that answers recv() from replies and records what it was sent."""
        sent = []

        class FakeUi:
            def __init__(self, name, data):
                sent.append(('open', name, data))
                self.replies = list(replies)

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                pass

            def send(self, message):
                sent.append(message)

            def recv(self):
                return self.replies.pop(0) if self.replies else None

            def progress(self, remaining):
                sent.append({'event': 'progress', 'left': [h['pid'] for h in remaining]})

        return patch.object(cli, 'UiDialog', FakeUi), sent

    def test_picker_lists_session_holders_and_leaves_them_to_logout(self):
        held = [holder(10, name='gnome-shell', closable=False), holder(11)]
        dialog, sent = self.picker({'action': 'close', 'pids': [10, 11]}, {'action': 'logout'})
        with dialog, patch.object(cli.os, 'kill') as kill, patch.object(cli, 'guard_holders', side_effect=[held, held[:1]]):
            self.assertEqual(cli.close_holders(held), (held[:1], True))
        shown = sent[0][2]['holders']
        self.assertEqual([(h['pid'], h['release']) for h in shown], [(10, 'logout'), (11, 'close')])
        kill.assert_called_once_with(11, cli.signal.SIGTERM)
        self.assertEqual([m['event'] for m in sent[1:]], ['closing', 'progress', 'done'])
        self.assertEqual(sent[-1]['left'], [{'pid': 10, 'name': 'gnome-shell', 'release': 'logout'}])

    def test_picker_can_start_without_the_rtx(self):
        held = [holder(10, name='gnome-shell', closable=False)]
        dialog, sent = self.picker({'action': 'without_rtx'})
        with dialog, patch.object(cli, 'run') as attach:
            self.assertEqual(cli.close_holders(held, offer_without_rtx=True), (None, False))
        attach.assert_not_called()
        self.assertTrue(sent[0][2]['without_rtx'])

    def test_start_refuses_to_wait_for_holders_a_logout_cannot_release(self):
        powerd = holder(10, name='nvidia-powerd', closable=False) | {'uid': 0}
        with patch.object(cli.subprocess, 'run', return_value=subprocess.CompletedProcess([], 3)), \
                patch.object(cli.subprocess, 'check_output', return_value=json.dumps([powerd])), \
                patch.object(cli, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'nvidia-powerd'):
                cli.start_windows('windows', notify=False, gui=False)
        self.assertIn('attach-desktop', run.call_args.args[0])

    def test_picker_closes_chosen_holders(self):
        held = [holder(10)]
        dialog, sent = self.picker({'action': 'close', 'pids': [10]}, {'action': 'started'})
        with dialog, patch.object(cli.os, 'kill') as kill, patch.object(cli, 'guard_holders', side_effect=[held, []]):
            self.assertEqual(cli.close_holders(held), ([], False))
        kill.assert_called_once_with(10, cli.signal.SIGTERM)
        self.assertEqual(sent[-1], {'event': 'done', 'left': []})

    def test_picker_force_kills_a_holder_that_ignores_close_once_confirmed(self):
        held = [holder(10)]
        dialog, sent = self.picker({'action': 'close', 'pids': [10]}, {'action': 'force'}, {'action': 'started'})
        with dialog, patch.object(cli, 'release_holders', side_effect=[held, []]) as release:
            self.assertEqual(cli.close_holders(held), ([], False))
        self.assertEqual([c.kwargs['force'] for c in release.call_args_list], [False, True])
        self.assertEqual([m['event'] for m in sent[1:]], ['closing', 'stuck', 'closing', 'done'])
        self.assertEqual(sent[2]['pids'], [10])

    def test_picker_keeps_waiting_when_asked(self):
        held = [holder(10)]
        dialog, sent = self.picker({'action': 'close', 'pids': [10]}, {'action': 'wait'}, {'action': 'later'})
        with dialog, patch.object(cli, 'release_holders', side_effect=[held, []]) as release:
            self.assertEqual(cli.close_holders(held), ([], False))
        self.assertEqual([c.kwargs['force'] for c in release.call_args_list], [False, False])

    def test_picker_dialogs_exist(self):
        dialogs = Path(cli.__file__).with_name('spawnkit-ui') / 'dialogs'
        self.assertTrue((dialogs / 'rtx-holders.qml').is_file() and (dialogs / 'confirm.qml').is_file())

    def test_picker_cancel_closes_nothing(self):
        held = [holder(10)]
        dialog, sent = self.picker()
        with dialog, patch.object(cli.os, 'kill') as kill:
            with self.assertRaisesRegex(cli.Cancelled, 'Cancelled'):
                cli.close_holders(held)
        kill.assert_not_called()

    def test_picker_cancel_while_stuck_stops_asking(self):
        held = [holder(10)]
        dialog, sent = self.picker({'action': 'close', 'pids': [10]})
        with dialog, patch.object(cli, 'release_holders', return_value=held):
            with self.assertRaisesRegex(cli.Cancelled, 'Cancelled'):
                cli.close_holders(held)
        self.assertEqual(sent[-1]['event'], 'stuck')

    def test_start_returns_the_gpu_to_the_desktop_whenever_the_dialog_ends_early(self):
        job = holder(10)
        for failure in (cli.Cancelled('Cancelled'), ValueError('The rtx-holders dialog failed (exit -15)')):
            with patch.object(cli.subprocess, 'run', return_value=subprocess.CompletedProcess([], 3)), \
                    patch.object(cli.subprocess, 'check_output', return_value=json.dumps([job])), \
                    patch.object(cli, 'guard_holders', return_value=[job]), \
                    patch.object(cli, 'close_holders', side_effect=failure), patch.object(cli, 'run') as run:
                with self.assertRaises(type(failure)):
                    cli.start_windows('windows', notify=False, gui=True)
            self.assertIn('attach-desktop', run.call_args.args[0])

    def test_gpu_services_are_stopped_for_the_detach_and_started_with_the_attach(self):
        with tempfile.TemporaryDirectory() as directory:
            stopped = Path(directory) / 'services.json'
            with patch.object(guard.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
                guard.gpu_services(False, stopped)
            self.assertEqual(json.loads(stopped.read_text()), sorted(guard.GPU_SERVICES))
            self.assertEqual(run.call_args.args[0][:2], ['/usr/bin/systemctl', 'stop'])
            with patch.object(guard.subprocess, 'run') as run:
                guard.gpu_services(True, stopped)
            self.assertEqual(run.call_args.args[0][:2], ['/usr/bin/systemctl', 'start'])
            self.assertFalse(stopped.exists())
            with patch.object(guard.subprocess, 'run', return_value=subprocess.CompletedProcess([], 3)) as run:
                guard.gpu_services(False, stopped)
                guard.gpu_services(True, stopped)
            self.assertFalse(stopped.exists())
            self.assertTrue(all(c.args[0][1] == 'is-active' for c in run.call_args_list))

    def test_start_logs_out_when_the_dialog_asked_for_it(self):
        shell = holder(10, name='kwin_wayland', closable=False)
        with patch.object(cli.subprocess, 'run', return_value=subprocess.CompletedProcess([], 3)) as run, \
                patch.object(cli.subprocess, 'check_output', side_effect=[json.dumps([shell]), json.dumps({'timeout': 600})]), \
                patch.object(cli, 'guard_holders', return_value=[shell]), \
                patch.object(cli, 'close_holders', return_value=([shell], True)), patch.object(cli.shutil, 'which', return_value=None):
            self.assertFalse(cli.start_windows('windows', notify=False, gui=True))
        self.assertEqual(run.call_args.args[0][:2], ['qdbus6', 'org.kde.Shutdown'])

    def test_ui_dialog_round_trip(self):
        with patch.object(cli.subprocess, 'Popen') as popen:
            popen.return_value.stdout.readline.side_effect = ['{"action": "confirm"}\n', '']
            popen.return_value.wait.return_value = 0
            popen.return_value.stdin.closed = False
            self.assertEqual(cli.ui_dialog('confirm', {'heading': 'x'}), {'action': 'confirm'})
        written = ''.join(c.args[0] for c in popen.return_value.stdin.write.call_args_list)
        self.assertEqual(json.loads(written), {'heading': 'x'})
        popen.return_value.stdin.close.assert_called()

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


class LookingGlassWatchdog(unittest.TestCase):
    def test_spice_channels_exclude_main_and_other_processes(self):
        ss = '\n'.join([
            'ESTAB 0 0 127.0.0.1:50274 127.0.0.1:5900 users:(("looking-glass-c",pid=7,fd=20))',
            '\t cubic bytes_sent:1746 bytes_acked:1746',
            'ESTAB 0 0 127.0.0.1:50262 127.0.0.1:5900 users:(("looking-glass-c",pid=7,fd=17))',
            '\t cubic bytes_sent:480 bytes_acked:480',
            'ESTAB 0 0 127.0.0.1:50270 127.0.0.1:5900 users:(("looking-glass-c",pid=7,fd=18))',
            '\t cubic bytes_sent:210 bytes_acked:210',
            'ESTAB 0 0 127.0.0.1:50300 127.0.0.1:5900 users:(("remote-viewer",pid=9,fd=17))',
            '\t cubic bytes_sent:999 bytes_acked:999',
        ])
        with patch.object(watchdog.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, ss, '')):
            self.assertEqual(watchdog.spice_sent(7, 5900), {'50270': 210, '50274': 1746})


if __name__ == '__main__':
    unittest.main()
