#!/usr/bin/python3
"""Find and reset wedged USB audio devices.

A USB microphone (seen with a NexiGo N60 webcam) can stop answering control requests:
the kernel logs `usb 1-3: 3:1: usb_set_interface failed (-110)` every five seconds while
PipeWire retries it, and PipeWire's main loop blocks on each attempt, so every sound on
the machine (the Windows VM's included) stutters or stops and volume keys and settings
cannot reach it. Unplugging the device clears it; `reset` does the same in software.

  status        JSON list of USB audio devices and their recent timeout count
  reset PORT    reset the device on a USB port (as `status` reports it, e.g. 1-3)
  watch         follow the kernel log and reset a device after repeated timeouts
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

USB = Path("/sys/bus/usb/devices")
TIMEOUT = re.compile(r"usb (\S+): \d+:\d+: usb_set_interface failed \(-110\)")
USBDEVFS_RESET = ord("U") << 8 | 20
# Three timeouts within 30 s: PipeWire retries every 5 s, so this is about 15 s of
# blocked audio, while one stray timeout is tolerated.
STRIKES, WINDOW, COOLDOWN = 3, 30, 120


def read(path):
    try:
        return path.read_text().strip()
    except OSError:
        return None


def audio_devices():
    for device in sorted(USB.glob("[0-9]*-*")):
        if ":" in device.name:
            continue
        if any(read(i / "bInterfaceClass") == "01" for i in device.glob(f"{device.name}:*")):
            yield device


def kernel_timeouts(since="-10min"):
    out = subprocess.run(["journalctl", "-k", "-o", "cat", "--no-pager", "--since", since],
                         text=True, capture_output=True).stdout
    counts = {}
    for match in TIMEOUT.finditer(out):
        counts[match[1]] = counts.get(match[1], 0) + 1
    return counts


def status():
    timeouts = kernel_timeouts()
    return [{"port": d.name, "id": f"{read(d / 'idVendor')}:{read(d / 'idProduct')}",
             "product": read(d / "product"), "power_control": read(d / "power/control"),
             "timeouts_10min": timeouts.get(d.name, 0)} for d in audio_devices()]


def reset(port):
    device = USB / port
    if not (device / "busnum").exists():
        raise SystemExit(f"no USB device on port {port}")
    node = f"/dev/bus/usb/{int(read(device / 'busnum')):03d}/{int(read(device / 'devnum')):03d}"
    try:
        # A port reset, as a replug does: the drivers rebind and PipeWire sees a new device.
        with open(node, "wb") as handle:
            fcntl.ioctl(handle, USBDEVFS_RESET, 0)
        method = "port-reset"
    except OSError as error:
        # A device too wedged to reset is logically disconnected and enumerated again.
        print(f"{port}: port reset failed ({error}); re-authorizing", file=sys.stderr)
        (device / "authorized").write_text("0")
        time.sleep(1)
        (device / "authorized").write_text("1")
        method = "reauthorize"
    return {"port": port, "product": read(device / "product"), "method": method}


def watch():
    strikes, last_reset = {}, {}
    log = subprocess.Popen(["journalctl", "-k", "-f", "-n", "0", "-o", "cat"],
                           text=True, stdout=subprocess.PIPE)
    for line in log.stdout:
        match = TIMEOUT.search(line)
        if not match:
            continue
        port, now = match[1], time.monotonic()
        recent = [t for t in strikes.get(port, []) if now - t < WINDOW] + [now]
        strikes[port] = recent
        if len(recent) < STRIKES or now - last_reset.get(port, -COOLDOWN) < COOLDOWN:
            continue
        strikes[port], last_reset[port] = [], now
        try:
            print(json.dumps({"event": "reset", **reset(port)}), flush=True)
        except (OSError, SystemExit) as error:
            print(json.dumps({"event": "reset-failed", "port": port, "error": str(error)}), flush=True)
    return log.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("reset").add_argument("port")
    sub.add_parser("watch")
    args = parser.parse_args()
    if args.command != "status" and os.geteuid() != 0:
        raise SystemExit(f"{args.command} needs root: sudo spawnkit-usb-audio {args.command}")
    if args.command == "status":
        print(json.dumps(status(), indent=2))
    elif args.command == "reset":
        print(json.dumps(reset(args.port)))
    else:
        sys.exit(watch())


if __name__ == "__main__":
    main()
