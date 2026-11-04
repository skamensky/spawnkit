#!/usr/bin/env python3
"""Inspect, preview and explicitly apply the selected Ubuntu host configuration."""

import argparse
import base64
import json
import os
from pathlib import Path
import pwd
import socket
import sys
import shutil
import signal
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

from spawnkit_host import bootstrap_settings, guest_inventory, inventory, load_config, read_overrides, render_unattend, render_windows, selector


GPU_RESERVATION = Path("/run/spawnkit/gpu-owner.json")
# Passwordless through the gpu_handoff sudoers rule, which lists these exact command lines.
GUARD = ["sudo", "/usr/bin/python3", "-I", "/usr/local/libexec/spawnkit/gpu-guard.py"]
# Holders only a logout releases; the picker never offers to kill them.
SESSION_HOLDERS = {"Xorg", "gnome-shell", "Xwayland", "kwin_wayland"}


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def guest_run(name, script):
    """Run PowerShell in the guest as SYSTEM through the QEMU guest agent; return exit code, stdout and stderr."""
    def agent(request):
        out = subprocess.check_output(["/usr/bin/virsh", "-c", "qemu:///system", "qemu-agent-command", name, json.dumps(request), "--timeout", "30"], text=True)
        return json.loads(out)["return"]
    encoded = base64.b64encode(("$ProgressPreference = 'SilentlyContinue'\n" + script).encode("utf-16-le")).decode()
    pid = agent({"execute": "guest-exec", "arguments": {
        "path": "powershell.exe", "arg": ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded], "capture-output": True}})["pid"]
    while not (status := agent({"execute": "guest-exec-status", "arguments": {"pid": pid}}))["exited"]:
        time.sleep(0.5)
    out, err = (base64.b64decode(status.get(key, "")).decode("utf-8", "replace") for key in ("out-data", "err-data"))
    return status.get("exitcode", 0), out, err


def guest_exec(name, script):
    code, out, err = guest_run(name, script)
    sys.stdout.write(out)
    sys.stderr.write(err)
    return code


def authorized_key(cfg):
    if not cfg["windows_authorized_key"]:
        raise ValueError("Set windows_authorized_key to the public key Linux uses for the guest")
    return Path(cfg["windows_authorized_key"]).read_text()


def guest_media(repo, cfg, output):
    """Write the unattended installation CD: autounattend.xml and the Spawnkit bootstrap."""
    with tempfile.TemporaryDirectory(prefix="spawnkit-unattend-") as temp:
        root = Path(temp)
        (root / "autounattend.xml").write_text(render_unattend(repo, cfg))
        (root / "spawnkit").mkdir()
        shutil.copy(repo / "ansible/roles/windows_guest/files/bootstrap.ps1", root / "spawnkit")
        (root / "spawnkit/bootstrap.json").write_text(json.dumps(bootstrap_settings(cfg, authorized_key(cfg))))
        run(["xorriso", "-as", "mkisofs", "-quiet", "-J", "-r", "-V", "SPAWNKIT_UNATTEND", "-o", str(output), str(root)])


def guest_bootstrap(repo, cfg):
    """Apply the first-access bootstrap to an installed guest through the QEMU guest agent."""
    settings = bootstrap_settings(cfg, authorized_key(cfg))
    quoted = {k: v.replace("'", "''") for k, v in settings.items()}
    script = (repo / "ansible/roles/windows_guest/files/bootstrap.ps1").read_text()
    return guest_exec(cfg["windows_name"], f"& {{\n{script}\n}} -AuthorizedKey '{quoted['authorized_key']}' -Network '{quoted['network']}'\n")


def guest_known_hosts(cfg):
    """The guest's SSH host key, read through the guest agent rather than trusted on first use."""
    code, out, _ = guest_run(cfg["windows_name"], r"Get-Content $env:ProgramData\ssh\ssh_host_ed25519_key.pub")
    fields = out.split()
    if code or fields[:1] != ["ssh-ed25519"]:
        raise ValueError("The guest has no OpenSSH host key; run guest-bootstrap first")
    return f"{cfg['windows_address']} {fields[0]} {fields[1]}\n"


def define_vm(repo, data, ask_become_pass):
    command = ["ansible-playbook", "-i", "INVENTORY", str(repo / "ansible/vm.yml")]
    if ask_become_pass:
        command.append("--ask-become-pass")
    playbook(repo, data, command)


def playbook(repo, inventory_data, command):
    """Run ansible-playbook with the inventory written to the INVENTORY placeholder."""
    with tempfile.TemporaryDirectory(prefix="spawnkit-inventory-") as temp:
        path = Path(temp) / "inventory.json"
        path.write_text(json.dumps(inventory_data))
        run([str(path) if part == "INVENTORY" else part for part in command],
            env=os.environ | {"ANSIBLE_CONFIG": str(repo / "ansible/ansible.cfg")}, cwd=repo / "ansible")


def configure_guest(repo, cfg, check):
    if not cfg["windows_address"]:
        raise ValueError("Set windows_mac and windows_address so Ansible can reach the guest")
    owner = pwd.getpwnam(cfg["user"])
    with tempfile.TemporaryDirectory(prefix="spawnkit-guest-") as temp:
        known_hosts = Path(temp) / "known_hosts"
        known_hosts.write_text(guest_known_hosts(cfg))
        command = ["ansible-playbook", "-i", "INVENTORY", str(repo / "ansible/windows-guest.yml")]
        if check:
            command += ["--check", "--diff"]
        playbook(repo, guest_inventory(cfg, known_hosts, (owner.pw_uid, owner.pw_gid)), command)


def virsh(*args, **kwargs):
    return subprocess.run(["/usr/bin/virsh", "-c", "qemu:///system", *args], check=True, text=True,
                          capture_output=True, env=os.environ | {"LC_ALL": "C"}, **kwargs).stdout.strip()


def install_windows(repo, profile, cfg, revision, args):
    """Install Windows unattended into a new VM and configure it, with no input on the guest side.

    The installation CD's loader waits for a key press, so Enter is sent once the VM runs.
    The unattended medium is ejected afterwards; the next vm-define no longer attaches it.
    """
    name = cfg["windows_name"]
    if not cfg["windows_vm"]:
        raise ValueError("Enable the Windows VM and record native GPU facts in the host configuration first")
    if not cfg["windows_iso"] or not cfg["virtio_iso"]:
        raise ValueError("vm-install requires --windows-iso and --virtio-iso")
    if subprocess.run(["/usr/bin/virsh", "-c", "qemu:///system", "dominfo", name], capture_output=True).returncode == 0:
        raise ValueError(f"Domain {name} already exists; vm-install only creates a new VM")
    # Keys go to the CD prompt from this process, so it cannot wait out a logout-scheduled start.
    held = guard_holders()
    if held and args.gui:
        held = close_holders(held)
    if held:
        raise ValueError("The RTX is open by " + ", ".join(sorted({h["name"] for h in held})) + "; close them (gpu-release) and rerun vm-install")
    authorized_key(cfg)
    media = Path(cfg["windows_iso"]).parent / f"{name}-unattend.iso"
    cfg = cfg | {"windows_unattend_iso": str(media)}
    with tempfile.TemporaryDirectory(prefix="spawnkit-unattend-iso-") as temp:
        built = Path(temp) / "unattend.iso"
        guest_media(repo, cfg, built)
        run(["sudo", "install", "-m", "0644", str(built), str(media)])
    define_vm(repo, inventory(repo, profile, cfg, revision), args.ask_become_pass)
    if not start_windows(name, args.notify, gui=False):
        raise ValueError("A program opened the RTX during definition; close it and run vm-start, then press Enter in vm-console")
    for _ in range(30):
        virsh("send-key", name, "KEY_ENTER")
        time.sleep(1)
    print("Installing Windows; waiting for its SSH server (usually 15-30 minutes)")
    wait_until(lambda: ssh_open(cfg["windows_address"]), 5400, "the guest's SSH server")
    configure_guest(repo, cfg, check=False)
    virsh("change-media", name, "sdc", "--eject", "--live", "--config")
    run(["sudo", "rm", "-f", str(media)])
    print("Windows is installed and configured. Clear windows_iso/virtio_iso and rerun vm-define when finished.")


def wait_until(ready, timeout, what):
    deadline = time.monotonic() + timeout
    while not ready():
        if time.monotonic() > deadline:
            raise ValueError(f"Timed out waiting for {what}")
        time.sleep(10)


def ssh_open(address):
    try:
        with socket.create_connection((address, 22), timeout=3):
            return True
    except OSError:
        return False


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


def release(holder):
    """How a holder lets go of the RTX: closed here, at logout, or by stopping its service."""
    if holder["closable"]:
        return "close"
    if holder["name"] in SESSION_HOLDERS:
        return "logout"
    return "service"


class Cancelled(Exception):
    """The user dismissed a dialog; nothing failed, so nothing is reported."""


def ui_dialog(name, data):
    """Show a Spawnkit dialog (scripts/spawnkit-ui) and return its result, or None if dismissed."""
    shown = subprocess.run(["/usr/bin/python3", "-I", str(Path(__file__).with_name("spawnkit-ui.py")), name],
                           input=json.dumps(data), capture_output=True, text=True)
    if shown.returncode == 1 and not shown.stdout:
        return None
    if shown.returncode != 0:
        raise ValueError(f"The {name} dialog failed: {shown.stderr.strip()}")
    return json.loads(shown.stdout)


def close_holders(held, offer_without_rtx=False):
    """Dialog front end for gpu-holders/gpu-release; returns the holders that remain.

    Every holder is listed with how it releases the RTX; only the user's own programs
    can be closed here, and display-server holders are left to the logout handoff.
    With offer_without_rtx, returns None when the user picks starting without the RTX.
    """
    holders = [{"pid": h["pid"], "name": h["name"], "command": h["command"], "closable": h["closable"],
                "release": release(h)} for h in held]
    picked = ui_dialog("rtx-holders", {"holders": holders, "without_rtx": offer_without_rtx})
    if picked is None:
        run([*GUARD, "attach-desktop"])
        raise Cancelled("Cancelled; the RTX stays with Linux")
    if picked["action"] == "without_rtx":
        return None
    closable = {h["pid"] for h in held if h["closable"]}
    chosen = [pid for pid in picked["pids"] if pid in closable]
    remaining = release_holders(chosen, force=False) if chosen else held
    if stubborn := [h for h in remaining if h["pid"] in chosen]:
        names = " and ".join(sorted({h["name"] for h in stubborn}))
        it = "it" if len(stubborn) == 1 else "them"
        if ui_dialog("confirm", {"heading": f"{names} didn't close",
                                 "text": f"Force-quit {it} so Windows can start? Anything unsaved in {it} is lost.",
                                 "confirm": "Force quit", "cancel": "Keep waiting", "destructive": True}):
            remaining = release_holders([h["pid"] for h in stubborn], force=True)
    return remaining


def view_looking_glass(command, port):
    """Run the viewer, restarting it when lg-watchdog finds it has stopped forwarding input."""
    state = Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state')) / 'spawnkit'
    state.mkdir(parents=True, exist_ok=True)
    restarts = []
    while True:
        with (state / 'looking-glass.log').open('a') as log:
            client = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        watchdog = subprocess.Popen(['/usr/bin/python3', '-I', str(Path(__file__).with_name('lg-watchdog.py')), '--pid', str(client.pid), '--port', str(port), '--log', str(state / 'looking-glass-stalls.jsonl')])
        client.wait()
        if watchdog.wait() != 75:
            return
        now = time.monotonic()
        restarts = [t for t in restarts if t > now - 60] + [now]
        if len(restarts) > 5:
            raise RuntimeError(f"Looking Glass stalled {len(restarts)} times in a minute; see {state / 'looking-glass-stalls.jsonl'}")


def start_without_rtx(name):
    """Start the persistent domain once from its definition minus the RTX, leaving the definition intact.

    A virtio display replaces the RTX. Looking Glass cannot capture without a GPU, so its shared memory goes
    too; at boot the guest's display selection task moves the desktop off the virtual monitor.
    """
    tree = ET.fromstring(subprocess.check_output(["/usr/bin/virsh", "-c", "qemu:///system", "dumpxml", "--inactive", name], text=True))
    devices = tree.find("devices")
    for device in devices.findall("hostdev[@type='pci']") + devices.findall("shmem"):
        devices.remove(device)
    for video in devices.findall("video"):
        devices.remove(video)
    ET.SubElement(ET.SubElement(devices, "video"), "model", type="virtio")
    with tempfile.NamedTemporaryFile("w", suffix=".xml") as definition:
        definition.write(ET.tostring(tree, encoding="unicode"))
        definition.flush()
        run(["/usr/bin/virsh", "-c", "qemu:///system", "create", definition.name], capture_output=True, text=True)


def start_windows(name, notify, gui):
    """Detach the RTX from the desktop, then start Windows now or once its holders exit.

    With gui, user-owned holders can be closed from a dialog first. Returns False when
    the start waits for the user to log out.
    """
    if subprocess.run(["systemctl", "is-active", "--quiet", "spawnkit-windows-handoff.service"]).returncode == 0:
        raise ValueError("Windows already starts once you log out; to cancel, run "
                         "sudo systemctl stop spawnkit-windows-handoff, then host-config vm-view again")
    held = json.loads(subprocess.check_output([*GUARD, "detach-desktop"], text=True))
    if held and gui:
        held = close_holders(guard_holders(), offer_without_rtx=True)
        if held is None:
            run([*GUARD, "attach-desktop"])
            start_without_rtx(name)
            return True
    if stuck := sorted({h["name"] for h in held if not h["closable"] and h["name"] not in SESSION_HOLDERS}):
        # A logout cannot release these, so waiting for one would only time out.
        run([*GUARD, "attach-desktop"])
        raise ValueError("A logout does not release the RTX from " + ", ".join(stuck) + "; stop it (a service: "
                         "sudo systemctl stop <name>) or start Windows without the RTX")
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
    parser.add_argument("action", choices=["select", "inventory", "check", "render", "plan", "apply", "facts", "vm-define", "vm-start", "vm-stop", "vm-view", "vm-console", "vm-exec", "gpu-status", "gpu-holders", "gpu-release", "vm-install", "guest-media", "guest-bootstrap", "guest-plan", "guest-apply"])
    parser.add_argument("--repo", type=Path, default=selector().default_repo(), help="Defaults to the enclosing checkout")
    parser.add_argument("--host", help="Explicit profile; normal selection shares the Home Manager registry")
    parser.add_argument("--hostname", default=socket.gethostname())
    parser.add_argument("--environment", choices=["linux", "wsl", "nixos"], default=selector().environment())
    parser.add_argument("--vars-file", type=Path, help="Local host setting overrides, e.g. installation media paths")
    parser.add_argument("--output", type=Path, help="Output directory for render; ISO file for guest-media")
    parser.add_argument("--ask-become-pass", action="store_true")
    parser.add_argument("--notify", action="store_true", help="Also display desktop notifications for command failures and vm-stop progress")
    parser.add_argument("--gui", action="store_true", help="vm-start/vm-view/vm-install: offer to close programs holding the RTX")
    parser.add_argument("--without-rtx", action="store_true", help="vm-start/vm-view: start Windows with a virtio display and leave the RTX on Ubuntu")
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
        elif args.action == "guest-media":
            if not args.output:
                parser.error("guest-media requires --output")
            guest_media(repo, cfg, args.output)
            print(args.output)
        elif args.action == "guest-bootstrap":
            native_only()
            raise SystemExit(guest_bootstrap(repo, cfg))
        elif args.action in ("guest-plan", "guest-apply"):
            native_only()
            configure_guest(repo, cfg, check=args.action == "guest-plan")
        elif args.action == "vm-install":
            native_only()
            install_windows(repo, profile, cfg, revision, args)
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
                notify = args.notify and shutil.which("notify-send")
                if state != "shut off":
                    if notify:
                        subprocess.run(["notify-send", "Spawnkit Windows VM", "Shutting down Windows…"], check=False)
                    run(["/usr/bin/virsh", "-c", "qemu:///system", "shutdown", name])
                wait_for_gpu_return(name, args.timeout)
                if notify:
                    subprocess.run(["notify-send", "Spawnkit Windows VM", "Windows is off and the RTX is back on Ubuntu."], check=False)
            elif state == "shut off":
                network = active['network_name']
                info = subprocess.check_output(['/usr/bin/virsh', '-c', 'qemu:///system', 'net-info', network], text=True, env=os.environ | {'LC_ALL': 'C'})
                if not any(line.split(':', 1)[0].strip() == 'Active' and line.split(':', 1)[1].strip() == 'yes' for line in info.splitlines()):
                    run(['/usr/bin/virsh', '-c', 'qemu:///system', 'net-start', network])
                if args.without_rtx:
                    start_without_rtx(name)
                elif not start_windows(name, args.notify, args.gui):
                    return
            elif state != "running":
                raise ValueError(f"VM is {state}; inspect it explicitly rather than forcing a reset")
            if args.action == "vm-view":
                live = ET.fromstring(subprocess.check_output(['/usr/bin/virsh', '-c', 'qemu:///system', 'dumpxml', name], text=True))
                if live.find('./devices/shmem') is None:
                    # Started without the RTX: Looking Glass has no frames to show, so use the SPICE display.
                    os.execvp("virt-manager", ["virt-manager", "--connect", "qemu:///system", "--show-domain-console", name])
                spice = live.find('./devices/graphics[@type="spice"]')
                if spice is None or int(spice.get('port', '-1')) < 1:
                    raise ValueError('The running VM has no active local SPICE port')
                # Calls in Windows open the microphone without a prompt; Looking Glass still shows its indicator.
                # While focused, the keyboard belongs to Windows (Alt+Tab, Super); Insert is the escape key (the laptop has no Right Ctrl).
                view_looking_glass(['looking-glass-client', '-f', f"/dev/shm/{active['looking_glass_name']}", 'spice:host=127.0.0.1', f"spice:port={spice.get('port')}", 'audio:micDefault=allow', 'input:grabKeyboardOnFocus=yes', 'input:escapeKey=KEY_INSERT', 'win:fullScreen=yes'], int(spice.get('port')))
        else:
            if args.action == "vm-define" or (args.action in ("plan", "apply") and any(cfg[k] for k in ("nvidia", "virtualization", "gpu_handoff", "windows_vm"))):
                native_only()
            if args.action == "vm-define" and not cfg["windows_vm"]:
                raise ValueError("Enable the Windows VM and record native GPU facts in the host configuration first")
            playbooks = ["site.yml", "vm.yml", "windows-guest.yml"] if args.action == "check" else ["vm.yml" if args.action == "vm-define" else "site.yml"]
            for name in playbooks:
                command = ["ansible-playbook", "-i", "INVENTORY", str(repo / "ansible" / name)]
                if args.action == "check":
                    command.append("--syntax-check")
                elif args.action == "plan":
                    command += ["--check", "--diff"]
                if args.ask_become_pass:
                    command.append("--ask-become-pass")
                playbook(repo, data, command)
    except Cancelled as cancelled:
        parser.exit(1, f"host-config: {cancelled}\n")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        details = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        if args.notify and shutil.which('notify-send'):
            subprocess.run(['notify-send', '--urgency=critical', 'Spawnkit Windows VM', details[:4000]], check=False)
        parser.exit(1, f"host-config: {details}\n")


if __name__ == "__main__":
    main()
