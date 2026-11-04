#!/usr/bin/env python3
"""Inspect, preview and explicitly apply the selected Ubuntu host configuration."""

import argparse
import base64
import json
import os
from pathlib import Path
import socket
import sys
import shutil
import signal
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

from spawnkit_host import inventory, load_config, read_overrides, render_windows, selector


GPU_RESERVATION = Path("/run/spawnkit/gpu-owner.json")
# Passwordless through the gpu_handoff sudoers rule, which lists these exact command lines.
GUARD = ["sudo", "/usr/bin/python3", "-I", "/usr/local/libexec/spawnkit/gpu-guard.py"]
# Holders only a logout releases; the picker never offers to kill them.
SESSION_HOLDERS = {"Xorg", "gnome-shell", "Xwayland"}


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def guest_exec(name, script):
    """Run PowerShell in the guest as SYSTEM through the QEMU guest agent; return its exit code."""
    def agent(request):
        out = subprocess.check_output(["/usr/bin/virsh", "-c", "qemu:///system", "qemu-agent-command", name, json.dumps(request), "--timeout", "30"], text=True)
        return json.loads(out)["return"]
    encoded = base64.b64encode(("$ProgressPreference = 'SilentlyContinue'\n" + script).encode("utf-16-le")).decode()
    pid = agent({"execute": "guest-exec", "arguments": {
        "path": "powershell.exe", "arg": ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded], "capture-output": True}})["pid"]
    while not (status := agent({"execute": "guest-exec-status", "arguments": {"pid": pid}}))["exited"]:
        time.sleep(0.5)
    for key, stream in (("out-data", sys.stdout), ("err-data", sys.stderr)):
        if key in status:
            stream.write(base64.b64decode(status[key]).decode("utf-8", "replace"))
    return status.get("exitcode", 0)


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


def guard_holders():
    """RTX holders, each marked closable unless only a logout or another user can release it."""
    if GPU_RESERVATION.exists():
        raise ValueError("The RTX is assigned to Windows; no Linux program holds it")
    return [h | {"closable": h["name"] not in SESSION_HOLDERS and h["uid"] == os.getuid()}
            for h in json.loads(subprocess.check_output([*GUARD, "holders"], text=True))]


def release_holders(pids, force):
    """SIGTERM the chosen closable holders, SIGKILL them after 10 s with force; return the holders left."""
    held = {h["pid"]: h for h in guard_holders()}
    for pid in pids:
        if pid not in held:
            raise ValueError(f"PID {pid} does not hold the RTX")
        if not held[pid]["closable"]:
            raise ValueError(f"PID {pid} ({held[pid]['name']}) is not closable; it needs a logout or its owner")
    for sig in (signal.SIGTERM, signal.SIGKILL) if force else (signal.SIGTERM,):
        for pid in pids:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 10
        while (remaining := guard_holders()) and set(pids) & {h["pid"] for h in remaining} and time.monotonic() < deadline:
            time.sleep(1)
        if not set(pids) & {h["pid"] for h in remaining}:
            break
    return remaining


def close_holders(held):
    """Dialog front end for gpu-holders/gpu-release; returns the holders that remain.

    Display-server and other users' holders are left to the logout handoff.
    """
    if not all(h["closable"] for h in held):
        return held
    rows = [field for h in held for field in ("TRUE", str(h["pid"]), h["name"], h["command"][:150])]
    picked = subprocess.run(["zenity", "--list", "--checklist", "--title=Start Windows", "--width=1000", "--height=420",
                             "--text=These programs are using the RTX. Close the checked ones to hand it to Windows "
                             "(unsaved work in them is lost):",
                             "--column=Close", "--column=PID", "--column=Program", "--column=Command",
                             "--print-column=2", "--separator= ", "--ok-label=Close and start Windows", *rows],
                            capture_output=True, text=True)
    if picked.returncode != 0:
        run([*GUARD, "attach-desktop"])
        raise ValueError("Cancelled; the RTX stays with Linux")
    chosen = [int(pid) for pid in picked.stdout.split()]
    remaining = release_holders(chosen, force=False)
    if set(chosen) & {h["pid"] for h in remaining}:
        names = ", ".join(sorted({h["name"] for h in remaining}))
        if subprocess.run(["zenity", "--question", "--title=Start Windows", "--ok-label=Force-kill",
                           f"--text={names} did not exit. Force-kill?"]).returncode == 0:
            remaining = release_holders([h["pid"] for h in remaining if h["pid"] in chosen], force=True)
    return remaining


def start_windows(name, notify, gui):
    """Detach the RTX from the desktop, then start Windows now or once its holders exit.

    With gui, user-owned holders can be closed from a dialog first. Returns False when
    the start waits for the user to log out.
    """
    held = json.loads(subprocess.check_output([*GUARD, "detach-desktop"], text=True))
    if held and gui:
        held = close_holders(guard_holders())
    if not held:
        try:
            run(["/usr/bin/virsh", "-c", "qemu:///system", "start", name], capture_output=True, text=True)
        except subprocess.CalledProcessError:
            run([*GUARD, "attach-desktop"])
            raise
        return True
    timeout = json.loads(subprocess.check_output([*GUARD, "schedule-start"], text=True))["timeout"]
    names = ", ".join(sorted({h["name"] for h in held}))
    message = (f"The RTX is still open by: {names}. Log out now; Windows starts once they exit "
               f"(limit {timeout // 60} min). Log back in and open Windows (Looking Glass). "
               "Progress: journalctl -u spawnkit-windows-handoff")
    print(message)
    if notify and shutil.which("notify-send"):
        subprocess.run(["notify-send", "Spawnkit Windows VM", message], check=False)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["select", "inventory", "check", "render", "plan", "apply", "facts", "vm-define", "vm-start", "vm-stop", "vm-view", "vm-console", "vm-exec", "gpu-status", "gpu-holders", "gpu-release"])
    parser.add_argument("--repo", type=Path, default=selector().default_repo(), help="Defaults to the enclosing checkout")
    parser.add_argument("--host", help="Explicit profile; normal selection shares the Home Manager registry")
    parser.add_argument("--hostname", default=socket.gethostname())
    parser.add_argument("--environment", choices=["linux", "wsl", "nixos"], default=selector().environment())
    parser.add_argument("--vars-file", type=Path, help="Local host setting overrides, e.g. installation media paths")
    parser.add_argument("--output", type=Path, help="Output directory for render")
    parser.add_argument("--ask-become-pass", action="store_true")
    parser.add_argument("--notify", action="store_true", help="Also display desktop notifications for command failures")
    parser.add_argument("--gui", action="store_true", help="vm-start/vm-view: offer to close programs holding the RTX")
    parser.add_argument("--pid", type=int, action="append", default=[], help="gpu-release: holder to close (repeatable)")
    parser.add_argument("--force", action="store_true", help="gpu-release: SIGKILL holders still running after SIGTERM")
    parser.add_argument("--timeout", type=int, default=300, help="vm-stop: seconds to wait for guest shutdown and GPU return")
    parser.add_argument("--command", help="vm-exec: PowerShell to run as SYSTEM; read from stdin when omitted")
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
        elif args.action == "gpu-holders":
            print(json.dumps(guard_holders(), indent=2))
        elif args.action == "gpu-release":
            if not args.pid:
                parser.error("gpu-release requires --pid")
            remaining = release_holders(args.pid, args.force)
            print(json.dumps(remaining, indent=2))
            if set(args.pid) & {h["pid"] for h in remaining}:
                raise ValueError("Some chosen holders are still running; retry with --force")
        elif args.action in ("vm-start", "vm-stop", "vm-view", "vm-console", "vm-exec", "gpu-status"):
            native_only()
            installed = Path("/etc/spawnkit/windows.json")
            if not installed.is_file():
                raise ValueError("Apply native host GPU configuration before using VM commands")
            active = json.loads(installed.read_text())
            if args.action == "gpu-status":
                run([*GUARD, "status"])
                return
            name = active["windows_name"]
            if args.action == "vm-console":
                os.execvp("virt-manager", ["virt-manager", "--connect", "qemu:///system", "--show-domain-console", name])
            if args.action == "vm-exec":
                raise SystemExit(guest_exec(name, args.command if args.command is not None else sys.stdin.read()))
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
                if not start_windows(name, args.notify, args.gui):
                    return
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
