#!/usr/bin/env python3
"""Inspect, preview and explicitly apply the selected Ubuntu host configuration."""

import argparse
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

from spawnkit_host import inventory, load_config, read_overrides, render_windows, selector


GPU_RESERVATION = Path("/run/spawnkit/gpu-owner.json")


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def native_only():
    if "microsoft" in Path("/proc/sys/kernel/osrelease").read_text().lower():
        raise ValueError("Native host/VM operations are unavailable under WSL; use check/render for offline validation")
    if Path("/etc/NIXOS").exists():
        raise ValueError("Use Spawnkit's NixOS modules on NixOS, not Ubuntu Ansible roles")


def wait_for_gpu_return(name, timeout):
    """Wait for guest shutdown and the release hook's verified GPU return, never forcing either."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = subprocess.check_output(["/usr/bin/virsh", "-c", "qemu:///system", "domstate", name], text=True, env=os.environ | {'LC_ALL': 'C'}).strip()
        if state == "shut off" and not GPU_RESERVATION.exists():
            print("Windows is shut off and the GPU return to Linux was verified")
            return
        time.sleep(2)
    if state != "shut off":
        raise ValueError(f"Windows is still {state} after {timeout}s; finish shutdown inside the guest (no forced power-off was sent)")
    raise ValueError("Windows is off but the GPU return was not verified; run host-config gpu-status, then gpu-guard.py reclaim once the Linux drivers are bound")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["select", "inventory", "check", "render", "plan", "apply", "facts", "vm-define", "vm-start", "vm-stop", "vm-view", "vm-console", "gpu-status"])
    parser.add_argument("--repo", type=Path, default=selector().default_repo(), help="Defaults to the enclosing checkout")
    parser.add_argument("--host", help="Explicit profile; normal selection shares the Home Manager registry")
    parser.add_argument("--hostname", default=socket.gethostname())
    parser.add_argument("--environment", choices=["linux", "wsl", "nixos"], default=selector().environment())
    parser.add_argument("--vars-file", type=Path, help="Local host setting overrides, e.g. installation media paths")
    parser.add_argument("--output", type=Path, help="Output directory for render")
    parser.add_argument("--ask-become-pass", action="store_true")
    parser.add_argument("--notify", action="store_true", help="Also display desktop notifications for command failures")
    parser.add_argument("--timeout", type=int, default=300, help="vm-stop: seconds to wait for guest shutdown and GPU return")
    parser.add_argument("--windows-iso", type=Path)
    parser.add_argument("--virtio-iso", type=Path)
    args = parser.parse_args()
    repo = args.repo.resolve()
    try:
        registry = json.loads((repo / "hosts/registry.json").read_text())
        profile = selector().select_profile(registry, args.hostname, args.environment, args.host)
        overrides = read_overrides(args.vars_file)
        for flag in ("windows_iso", "virtio_iso"):
            value = getattr(args, flag)
            if value:
                overrides[flag] = str(value.resolve())
        cfg = load_config(repo, profile, overrides)
        revision = os.environ.get("SPAWNKIT_SOURCE_REVISION")
        if not revision:
            revision = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
        if (repo / '.git').exists() and subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
            revision += '+dirty'
        data = inventory(repo, profile, cfg, revision)
        if args.action == "select":
            print(profile)
        elif args.action == "inventory":
            print(json.dumps(data, indent=2))
        elif args.action == "facts":
            run(["/usr/bin/python3", str(repo / "ansible/roles/base/files/host-state.py"), "facts"])
        elif args.action == "render":
            if not args.output:
                parser.error("render requires --output")
            xml = render_windows(repo, cfg)
            ET.fromstring(xml)
            args.output.mkdir(parents=True, exist_ok=True)
            (args.output / "windows.xml").write_text(xml)
            (args.output / "windows.json").write_text(json.dumps(cfg, indent=2) + "\n")
            print(args.output)
        elif args.action in ("vm-start", "vm-stop", "vm-view", "vm-console", "gpu-status"):
            native_only()
            installed = Path("/etc/spawnkit/windows.json")
            if not installed.is_file():
                raise ValueError("Apply native host GPU configuration before using VM commands")
            active = json.loads(installed.read_text())
            if args.action == "gpu-status":
                run(["sudo", "/usr/bin/python3", "/usr/local/libexec/spawnkit/gpu-guard.py", "status"])
                return
            name = active["windows_name"]
            if args.action == "vm-console":
                os.execvp("virt-manager", ["virt-manager", "--connect", "qemu:///system", "--show-domain-console", name])
            state = subprocess.check_output(["/usr/bin/virsh", "-c", "qemu:///system", "domstate", name], text=True, env=os.environ | {'LC_ALL': 'C'}).strip()
            if args.action == "vm-stop":
                if state != "shut off":
                    run(["/usr/bin/virsh", "-c", "qemu:///system", "shutdown", name])
                wait_for_gpu_return(name, args.timeout)
            elif state == "shut off":
                network = active['network_name']
                info = subprocess.check_output(['/usr/bin/virsh', '-c', 'qemu:///system', 'net-info', network], text=True, env=os.environ | {'LC_ALL': 'C'})
                if not any(line.split(':', 1)[0].strip() == 'Active' and line.split(':', 1)[1].strip() == 'yes' for line in info.splitlines()):
                    run(['/usr/bin/virsh', '-c', 'qemu:///system', 'net-start', network])
                run(["/usr/bin/virsh", "-c", "qemu:///system", "start", name], capture_output=True, text=True)
            elif state != "running":
                raise ValueError(f"VM is {state}; inspect it explicitly rather than forcing a reset")
            if args.action == "vm-view":
                live = ET.fromstring(subprocess.check_output(['/usr/bin/virsh', '-c', 'qemu:///system', 'dumpxml', name], text=True))
                spice = live.find('./devices/graphics[@type="spice"]')
                if spice is None or int(spice.get('port', '-1')) < 1:
                    raise ValueError('The running VM has no active local SPICE port')
                os.execvp("looking-glass-client", ["looking-glass-client", "-f", f"/dev/shm/{active['looking_glass_name']}", 'spice:host=127.0.0.1', f"spice:port={spice.get('port')}"])
        else:
            if args.action == "vm-define" or (args.action in ("plan", "apply") and any(cfg[k] for k in ("nvidia", "virtualization", "gpu_handoff", "windows_vm"))):
                native_only()
            if args.action == "vm-define" and not cfg["windows_vm"]:
                raise ValueError("Enable the Windows VM and record native GPU facts in the host configuration first")
            playbooks = ["site.yml", "vm.yml"] if args.action == "check" else ["vm.yml" if args.action == "vm-define" else "site.yml"]
            env = os.environ | {"ANSIBLE_CONFIG": str(repo / "ansible/ansible.cfg")}
            with tempfile.TemporaryDirectory(prefix="spawnkit-inventory-") as temp:
                path = Path(temp) / "inventory.json"
                path.write_text(json.dumps(data))
                for playbook in playbooks:
                    command = ["ansible-playbook", "-i", str(path), str(repo / "ansible" / playbook)]
                    if args.action == "check":
                        command.append("--syntax-check")
                    elif args.action == "plan":
                        command += ["--check", "--diff"]
                    if args.ask_become_pass:
                        command.append("--ask-become-pass")
                    run(command, env=env, cwd=repo / "ansible")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        details = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        if args.notify and shutil.which('notify-send'):
            subprocess.run(['notify-send', '--urgency=critical', 'Spawnkit Windows VM', details[:4000]], check=False)
        parser.exit(1, f"host-config: {details}\n")


if __name__ == "__main__":
    main()
