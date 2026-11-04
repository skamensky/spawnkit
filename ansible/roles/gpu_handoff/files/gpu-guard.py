#!/usr/bin/python3
"""Root GPU lifecycle guard. Never calls libvirt, virsh, or a libvirt client."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

SYSFS = Path('/sys/bus/pci/devices')
STATE = Path('/run/spawnkit/gpu-owner.json')
CONFIG = Path('/etc/spawnkit/windows.json')
# Seconds a deferred start waits for the desktop session to release the RTX.
LOGOUT_TIMEOUT = 900
# Runtime-only (cleared at boot), so the Linux desktop owns the RTX by default.
SEAT_RULE = Path('/run/udev/rules.d/72-spawnkit-gpu-handoff.rules')
# Holders that are not ordinary GPU jobs get specific advice instead of a bare PID.
ADVICE = {
    'gnome-shell': 'the desktop compositor opened the RTX; drive all Linux displays from the Intel iGPU '
                   '(dGPU-wired outputs cannot stay in use) and log out/in, see docs/windows-vm.md',
    'Xwayland': 'Xwayland opened the RTX (usually a PRIME-offloaded X11 app); close it or log out/in',
    'Xorg': 'the X session uses the RTX; host-config vm-start detaches it and starts Windows after you log out',
    'nvidia-persistenced': 'run: sudo systemctl stop nvidia-persistenced (disable it to make this permanent)',
    'nvidia-powerd': 'run: sudo systemctl stop nvidia-powerd',
}


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
    if not selected.intersection(supplied):
        # Started without the RTX (host-config --without-rtx): nothing to reserve.
        return False
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


def desktop_seat(cfg, attached, sysfs=SYSFS, rule=SEAT_RULE):
    """Attach the handoff GPU to the desktop seat or move it to a seat with no master device.

    Xorg opens every seat0 DRM device through logind at startup and keeps it until the
    session ends. A detached GPU is hidden from new display servers, logind and session
    ACLs; already open descriptors stay until their owners exit (logout).
    """
    if attached:
        rule.unlink(missing_ok=True)
    else:
        rule.parent.mkdir(parents=True, exist_ok=True)
        rule.write_text(''.join(
            f'SUBSYSTEM=="drm", KERNELS=="{d["address"]}", ENV{{ID_SEAT}}="spawnkit-gpu-handoff", TAG-="master-of-seat"\n'
            for d in cfg['gpu_devices'] if d['driver'] == 'nvidia'))
    nodes = [str(n) for d in cfg['gpu_devices'] for n in (sysfs / d['address'] / 'drm').glob('*')]
    subprocess.run(['/usr/bin/udevadm', 'control', '--reload'], check=True, timeout=30)
    if nodes:
        subprocess.run(['/usr/bin/udevadm', 'trigger', '--action=change', '--settle', *nodes], check=True, timeout=60)


def holders(nodes):
    descriptions = []
    for pid in users(nodes):
        proc = Path(f'/proc/{pid}')
        try:
            name = (proc / 'comm').read_text().strip()
            command = (proc / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace').strip()
            uid = proc.stat().st_uid
        except OSError:
            name, command, uid = 'exited', '', -1
        descriptions.append({'pid': pid, 'name': name, 'command': command, 'uid': uid})
    return descriptions


def await_idle(cfg, timeout, delay=2):
    """Wait for the detached GPU's remaining holders to exit; reattach on timeout."""
    deadline = time.monotonic() + timeout
    while holders(inspect_devices(cfg)):
        if time.monotonic() > deadline:
            desktop_seat(cfg, True)
            require_idle(inspect_devices(cfg))
        time.sleep(delay)


def users(nodes):
    if not nodes:
        return []
    result = subprocess.run(['/usr/bin/fuser', *nodes], capture_output=True, text=True, timeout=10)
    if result.returncode not in (0, 1):
        raise RuntimeError('Could not inspect GPU users: ' + result.stderr.strip())
    return sorted({int(pid) for pid in result.stdout.split()})


def require_idle(nodes):
    found = holders(nodes)
    if found:
        descriptions = []
        for holder in found:
            hint = ADVICE.get(holder['name'])
            descriptions.append(f'{holder["pid"]} ({holder["name"]}' + (f': {hint})' if hint else ')'))
        raise RuntimeError('GPU busy; nothing was stopped. Close GPU jobs/containers/apps or explicitly stop '
                           'the owning service: ' + ', '.join(descriptions))


def prepare(cfg, xml, state=STATE, sysfs=SYSFS, shm_root=Path('/dev/shm')):
    if not validate_domain(cfg, xml):
        return
    state.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    # Exclusive file survives the short-lived hook process. Never steal a stale reservation.
    try:
        descriptor = os.open(state, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise RuntimeError(f'{state} remains from an earlier start whose GPU return was not verified. '
                           'Run host-config gpu-status; when the devices show their Linux drivers, run '
                           'sudo /usr/local/libexec/spawnkit/gpu-guard.py reclaim') from None
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


def release(cfg, state=STATE, sysfs=SYSFS, attempts=5, delay=2):
    if not state.exists():
        return
    owner = json.loads(state.read_text())
    if owner.get('uuid') != cfg['windows_uuid']:
        raise RuntimeError('GPU reservation belongs to another domain; inspect manually')
    # libvirt managed=yes rebinds the drivers; the NVIDIA module can need a moment to answer.
    for attempt in range(attempts):
        try:
            inspect_devices(cfg, sysfs)
            subprocess.run(['/usr/bin/nvidia-smi', '-L'], check=True, capture_output=True, timeout=20)
            break
        except (RuntimeError, subprocess.SubprocessError):
            if attempt == attempts - 1:
                raise
            time.sleep(delay)
    state.unlink()
    desktop_seat(cfg, True, sysfs)


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
    if sys.argv[1:] == ['detach-desktop']:
        desktop_seat(cfg, False)
        print(json.dumps(holders(inspect_devices(cfg))))
        return
    if sys.argv[1:] == ['holders']:
        print(json.dumps(holders(inspect_devices(cfg))))
        return
    if sys.argv[1:] == ['attach-desktop']:
        desktop_seat(cfg, True)
        return
    if sys.argv[1:] == ['schedule-start']:
        # A root unit survives logout; a failed start returns the RTX to the desktop seat.
        # The unit, not this hook-reachable process, calls virsh.
        guard = f'/usr/bin/python3 -I {Path(__file__).resolve()}'
        script = (f"{guard} await-idle {LOGOUT_TIMEOUT} && "
                  f"/usr/bin/virsh -c qemu:///system start {cfg['windows_name']} || "
                  f"{{ {guard} attach-desktop; exit 1; }}")
        subprocess.run(['systemd-run', '--unit=spawnkit-windows-handoff', '--collect',
                        '--description=Start Windows once the desktop releases the RTX', '/bin/sh', '-c', script],
                       check=True)
        print(json.dumps({'timeout': LOGOUT_TIMEOUT}))
        return
    if sys.argv[1:2] == ['await-idle']:
        await_idle(cfg, int(sys.argv[2]))
        return
    if sys.argv[1:] == ['reclaim']:
        # Manual recovery: clears a stale reservation only after verifying the GPU is back on Linux.
        release(cfg)
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
