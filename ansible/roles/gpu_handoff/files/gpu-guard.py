#!/usr/bin/python3
"""Root GPU lifecycle guard. Never calls libvirt, virsh, or a libvirt client."""
import json
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

SYSFS = Path('/sys/bus/pci/devices')
STATE = Path('/run/spawnkit/gpu-owner.json')
CONFIG = Path('/etc/spawnkit/windows.json')


def pci_addresses(tree):
    result = {}
    for hostdev in tree.findall('./devices/hostdev'):
        address = hostdev.find('./source/address')
        if hostdev.get('type') == 'pci' and address is not None:
            parts = [int(address.get(k, '0'), 0) for k in ('domain', 'bus', 'slot', 'function')]
            result['%04x:%02x:%02x.%x' % tuple(parts)] = hostdev.get('managed')
    return result


def validate_domain(cfg, xml):
    tree = ET.fromstring(xml)
    selected = {d['address'] for d in cfg['gpu_devices']}
    supplied = pci_addresses(tree)
    if tree.findtext('name') != cfg['windows_name']:
        if selected.intersection(supplied):
            raise RuntimeError('These GPU functions are reserved for the configured Windows domain')
        return False
    if tree.findtext('uuid') != cfg['windows_uuid']:
        raise RuntimeError('Windows UUID differs from the installed host configuration')
    if set(supplied) != selected or any(v != 'yes' for v in supplied.values()):
        raise RuntimeError('Windows must use exactly the declared PCI functions with managed=yes')
    shmem = tree.find('./devices/shmem')
    if shmem is None or shmem.get('name') != cfg['looking_glass_name']:
        raise RuntimeError('Unexpected Looking Glass shared memory configuration')
    return True


def inspect_devices(cfg, sysfs=SYSFS):
    selected = {d['address'] for d in cfg['gpu_devices']}
    nodes = set()
    for device in cfg['gpu_devices']:
        path = sysfs / device['address']
        if not path.is_dir():
            raise RuntimeError(f'Missing PCI function {path.name}')
        driver = path / 'driver'
        actual = driver.resolve().name if driver.exists() else None
        if actual != device['driver']:
            raise RuntimeError(f'{path.name}: expected {device["driver"]}, found {actual}; inspect host recovery')
        if (path / 'boot_vga').exists() and (path / 'boot_vga').read_text().strip() == '1':
            raise RuntimeError('The selected GPU is a boot display; move the Linux desktop to the iGPU first')
        group = path / 'iommu_group/devices'
        if not group.is_dir():
            raise RuntimeError(f'{path.name}: no IOMMU group; enable firmware virtualization/IOMMU and reboot')
        for member in group.iterdir():
            # PCI bridges do not need assigning; every other function must be included.
            klass = (member / 'class').read_text().strip()
            if not klass.startswith('0x0604') and member.name not in selected:
                raise RuntimeError(f'IOMMU group also contains {member.name}; do not use an ACS override to hide isolation')
        for node in (path / 'drm').glob('*'):
            nodes.add('/dev/dri/' + node.name)
        for node in (path / 'sound').glob('card*'):
            for sound in Path('/dev/snd').glob('*C' + node.name[4:] + '*'):
                nodes.add(str(sound))
    # NVIDIA control/UVM are shared across NVIDIA cards: conservative refusal.
    nodes.update(str(n) for n in Path('/dev').glob('nvidia*') if not n.is_dir())
    return sorted(n for n in nodes if Path(n).exists())


def users(nodes):
    if not nodes:
        return []
    result = subprocess.run(['/usr/bin/fuser', *nodes], capture_output=True, text=True, timeout=10)
    if result.returncode not in (0, 1):
        raise RuntimeError('Could not inspect GPU users: ' + result.stderr.strip())
    return sorted({int(pid) for pid in result.stdout.split()})


def require_idle(nodes):
    pids = users(nodes)
    if pids:
        descriptions = []
        for pid in pids:
            try:
                name = Path(f'/proc/{pid}/comm').read_text().strip()
            except OSError:
                name = 'exited'
            descriptions.append(f'{pid} ({name})')
        raise RuntimeError('GPU busy; close GPU jobs/containers/apps or explicitly stop the owning service: ' + ', '.join(descriptions))


def prepare(cfg, xml, state=STATE, sysfs=SYSFS, shm_root=Path('/dev/shm')):
    if not validate_domain(cfg, xml):
        return
    state.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    # Exclusive file survives the short-lived hook process. Never steal a stale reservation.
    descriptor = os.open(state, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump({'name': cfg['windows_name'], 'uuid': cfg['windows_uuid']}, stream)
    try:
        require_idle(inspect_devices(cfg, sysfs))
        shm = shm_root / cfg['looking_glass_name']
        if not shm.is_file() or shm.is_symlink():
            raise RuntimeError('Missing regular Looking Glass memory file; apply host configuration first')
        require_idle([str(shm)])
        with os.fdopen(os.open(shm, os.O_RDWR | os.O_NOFOLLOW), 'r+b') as memory:
            memory.truncate(cfg['looking_glass_mib'] * 2**20)
    except BaseException:
        state.unlink()
        raise


def release(cfg, state=STATE, sysfs=SYSFS):
    if not state.exists():
        return
    owner = json.loads(state.read_text())
    if owner.get('uuid') != cfg['windows_uuid']:
        raise RuntimeError('GPU reservation belongs to another domain; inspect manually')
    inspect_devices(cfg, sysfs)  # libvirt managed=yes should have restored all drivers.
    subprocess.run(['/usr/bin/nvidia-smi', '-L'], check=True, capture_output=True, timeout=20)
    state.unlink()


def main():
    if os.geteuid() != 0:
        raise RuntimeError('GPU inspection/handoff requires root')
    if not CONFIG.exists():
        return
    cfg = json.loads(CONFIG.read_text())
    if sys.argv[1:] == ['status']:
        devices = []
        for expected in cfg['gpu_devices']:
            driver = SYSFS / expected['address'] / 'driver'
            devices.append(expected | {'current_driver': driver.resolve().name if driver.exists() else None})
        print(json.dumps({'reservation': json.loads(STATE.read_text()) if STATE.exists() else None,
                          'devices': devices}, indent=2))
        return
    name, operation, phase = sys.argv[1:4]
    if operation == 'prepare' and phase == 'begin':
        prepare(cfg, sys.stdin.read())
    elif name == cfg['windows_name'] and operation == 'release' and phase == 'end':
        release(cfg)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Spawnkit GPU guard: {error}', file=sys.stderr)
        sys.exit(1)
