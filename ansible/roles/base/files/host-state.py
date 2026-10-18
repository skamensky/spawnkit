#!/usr/bin/python3
"""Privileged host operations. Never invoked from a libvirt lifecycle hook."""

import argparse
import grp
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET


OWNER = "https://github.com/skamensky/spawnkit"
VIRSH = ["/usr/bin/virsh", "-c", "qemu:///system"]


def command(args, check=True):
    return subprocess.run(args, text=True, capture_output=True, check=check, env=os.environ | {'LC_ALL': 'C'})


def facts(sysfs=Path("/sys/bus/pci/devices")):
    result = {"kernel": platform.release(), "os": platform.freedesktop_os_release(),
              "spawnkit_enabled": Path("/etc/spawnkit/enabled").is_file(), "pci_devices": []}
    for device in sorted(sysfs.glob("*")):
        try:
            vendor = (device / "vendor").read_text().strip()
            klass = (device / "class").read_text().strip()
            if vendor != "0x10de" and not klass.startswith("0x03"):
                continue
            group = device / "iommu_group"
            result["pci_devices"].append({
                "address": device.name, "vendor": vendor, "class": klass,
                "driver": (device / "driver").resolve().name if (device / "driver").exists() else None,
                "boot_vga": (device / "boot_vga").read_text().strip() if (device / "boot_vga").exists() else None,
                "iommu_group": group.resolve().name if group.exists() else None,
                "group_members": sorted(p.name for p in (group / "devices").glob("*")),
            })
        except OSError:
            continue
    nvidia = Path("/proc/driver/nvidia/version")
    result["nvidia_driver"] = nvidia.read_text() if nvidia.exists() else None
    return result


def merge(existing, requested):
    if not isinstance(existing, dict):
        raise ValueError("Cannot merge a mapping into an existing non-mapping Docker setting")
    result = dict(existing)
    for key, value in requested.items():
        result[key] = merge(result.get(key, {}), value) if isinstance(value, dict) else value
    return result


def merge_docker(requested, destination=Path("/etc/docker/daemon.json")):
    existing = json.loads(destination.read_text()) if destination.exists() else {}
    desired = merge(existing, requested)
    if desired == existing:
        return False
    # Refuse to restart a daemon with live containers as an incidental config edit.
    if Path("/usr/bin/docker").exists():
        active = command(["/usr/bin/docker", "ps", "-q"], check=False)
        if active.returncode == 0 and active.stdout.strip():
            raise RuntimeError("Stop running containers before applying Docker daemon changes")
    if destination.exists():
        backup = destination.with_name(destination.name + ".before-spawnkit")
        if not backup.exists():
            shutil.copy2(destination, backup)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=destination.parent, delete=False) as temp:
        json.dump(desired, temp, indent=2)
        temp.write("\n")
        os.chmod(temp.name, 0o644)
    daemon = next((p for p in ('/usr/sbin/dockerd', '/usr/bin/dockerd') if Path(p).is_file()), None)
    if daemon:
        try:
            command([daemon, '--validate', '--config-file', temp.name])
        except BaseException:
            Path(temp.name).unlink()
            raise
    os.replace(temp.name, destination)
    return True


def managed_domain(xml):
    return ET.fromstring(xml).find(f"./metadata/{{{OWNER}}}managed") is not None


def define_windows(cfg, filename, state_dir=Path("/var/lib/spawnkit")):
    desired = filename.read_bytes()
    tree = ET.fromstring(desired)
    name = tree.findtext("name")
    digest = hashlib.sha256(desired).hexdigest()
    domains = command(VIRSH + ['list', '--all', '--name']).stdout.splitlines()
    exists = name in domains
    current = command(VIRSH + ["dumpxml", "--inactive", name]) if exists else None
    if exists and not managed_domain(current.stdout):
        raise RuntimeError("Refusing to replace an existing unmanaged Windows domain")
    saved = state_dir / f"{name}.xml"
    resolved = state_dir / f"{name}.resolved.xml"
    actual = ET.canonicalize(current.stdout, strip_text=True) if exists else None
    changed = (not exists or not saved.exists() or saved.read_bytes() != desired
               or not resolved.exists() or resolved.read_text() != actual)
    if exists:
        if ET.fromstring(current.stdout).findtext("uuid") != cfg["windows_uuid"]:
            raise RuntimeError("Existing domain UUID differs; preserve its TPM/NVRAM identity")
        state = command(VIRSH + ["domstate", name]).stdout.strip()
        if changed and state != "shut off":
            raise RuntimeError("Shut the VM down before changing its definition")
    disk = Path(cfg["windows_disk"])
    if not exists and disk.exists():
        raise RuntimeError("Refusing to adopt an existing disk without its managed domain definition")
    if not exists and (not cfg["windows_iso"] or not cfg["virtio_iso"]):
        raise RuntimeError("First definition requires Windows and VirtIO installation ISOs")
    for media in (cfg["windows_iso"], cfg["virtio_iso"]):
        if media:
            path = Path(media).resolve()
            if not path.is_file() or not path.is_relative_to(Path("/var/lib/libvirt/images")):
                raise RuntimeError("Stage installation ISOs beneath /var/lib/libvirt/images so QEMU can read them")
            if path.stat().st_mode & 0o004 == 0:
                raise RuntimeError("Installation media must be readable by the unprivileged QEMU account")
    command(["/usr/bin/virt-xml-validate", str(filename), "domain"])
    if disk.exists():
        info = json.loads(command(["/usr/bin/qemu-img", "info", "--output=json", str(disk)]).stdout)
        if info["format"] != "qcow2" or info["virtual-size"] < cfg["windows_disk_gib"] * 2**30:
            raise RuntimeError("Existing disk format/size differs; resizing or conversion must be deliberate")
    else:
        disk.parent.mkdir(parents=True, exist_ok=True)
        command(["/usr/bin/qemu-img", "create", "-f", "qcow2", str(disk), f"{cfg['windows_disk_gib']}G"])
        os.chown(disk, pwd.getpwnam("libvirt-qemu").pw_uid, grp.getgrnam("kvm").gr_gid)
        os.chmod(disk, 0o660)
    if changed:
        define_path = filename
        if exists:
            # Firmware selection fills loader/NVRAM paths on first definition.
            # Retain them on edits instead of asking libvirt to reselect firmware.
            current_tree = ET.fromstring(current.stdout)
            for tag in ('loader', 'nvram'):
                previous = current_tree.find('./os/' + tag)
                if previous is not None and tree.find('./os/' + tag) is None:
                    tree.find('os').append(previous)
            previous_mac = current_tree.find('./devices/interface/mac')
            target_interface = tree.find('./devices/interface')
            if previous_mac is not None and target_interface is not None and target_interface.find('mac') is None:
                target_interface.insert(0, previous_mac)
            with tempfile.NamedTemporaryFile(dir=filename.parent, suffix='.xml', delete=False) as temp:
                temp.write(ET.tostring(tree))
                define_path = Path(temp.name)
        try:
            command(VIRSH + ["define", "--validate", str(define_path)])
        finally:
            if define_path != filename:
                define_path.unlink()
        state_dir.mkdir(parents=True, exist_ok=True)
        saved.write_bytes(desired)
        live_xml = command(VIRSH + ['dumpxml', '--inactive', name]).stdout
        resolved.write_text(ET.canonicalize(live_xml, strip_text=True))
    command(VIRSH + ["autostart", "--disable", name])
    print("changed" if changed else "unchanged", digest)


def network(filename):
    desired = ET.parse(filename).getroot()
    name = desired.findtext("name")
    networks = command(VIRSH + ['net-list', '--all', '--name']).stdout.splitlines()
    if name in networks:
        current = command(VIRSH + ["net-dumpxml", "--inactive", name])
        tree = ET.fromstring(current.stdout)
        if tree.findtext("uuid") != desired.findtext("uuid"):
            raise RuntimeError("Refusing to change an unmanaged network with the same name")
        # Libvirt adds runtime/default attributes. Compare the declared network.
        for tag in ("bridge", "forward", "ip"):
            old, new = tree.find(tag), desired.find(tag)
            for key, value in new.attrib.items():
                if old is None or old.get(key) != value:
                    raise RuntimeError("Existing network differs; shut its guests down and review the network change explicitly")
        old_range = tree.find('./ip/dhcp/range')
        new_range = desired.find('./ip/dhcp/range')
        if old_range is None or old_range.attrib != new_range.attrib:
            raise RuntimeError('Existing DHCP range differs; review the network change explicitly')
        command(VIRSH + ["net-autostart", "--disable", name])
        print("unchanged")
        return
    command(VIRSH + ["net-define", str(filename)])
    command(VIRSH + ["net-autostart", "--disable", name])
    print("changed")


def verify_ssh(port, addresses):
    output = command(["/usr/sbin/sshd", "-T"]).stdout.splitlines()
    ports = {line.split()[1] for line in output if line.startswith("port ")}
    listeners = {line.split()[1] for line in output if line.startswith("listenaddress ")}
    expected = {f"[{address}]:{port}" if ":" in address else f"{address}:{port}" for address in addresses}
    if ports != {str(port)} or listeners != expected:
        raise RuntimeError("Existing sshd settings add other ports/listeners; reconcile them before restarting SSH")


def verify_ssh_listening(port, addresses, output=None):
    if output is None:
        output = command(["/usr/bin/ss", "-H", "-tlnp"]).stdout
    actual = {line.split()[3] for line in output.splitlines() if '"sshd"' in line}
    expected = {f"[{address}]:{port}" if ":" in address else f"{address}:{port}" for address in addresses}
    if actual != expected:
        raise RuntimeError(f"sshd listens on {sorted(actual)}, expected {sorted(expected)}; "
                           "a stale listener survives until it is stopped or the host reboots")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["facts", "merge-docker", "define-windows", "network", "verify-ssh", "verify-ssh-listening"])
    parser.add_argument("arguments", nargs="*")
    args = parser.parse_args()
    if args.action == "facts":
        print(json.dumps(facts(), indent=2))
        return
    if os.geteuid() != 0:
        parser.error("This host operation requires root")
    if args.action == "merge-docker":
        print("changed" if merge_docker(json.loads(args.arguments[0])) else "unchanged")
    elif args.action == "define-windows":
        define_windows(json.loads(Path(args.arguments[0]).read_text()), Path(args.arguments[1]))
    elif args.action == "network":
        network(Path(args.arguments[0]))
    elif args.action == "verify-ssh":
        verify_ssh(int(args.arguments[0]), args.arguments[1:])
    elif args.action == "verify-ssh-listening":
        verify_ssh_listening(int(args.arguments[0]), args.arguments[1:])


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        details = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        raise SystemExit(f"spawnkit host operation: {details}")
