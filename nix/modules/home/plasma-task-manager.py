"""spawnkit-task-manager: Windows' Ctrl+Shift+Esc, which minimizes every window and shows the
stats widget's process window.

show    minimize every window and open the process window; prints {"shown": true} as JSON, or
        {"shown": false, "reason": ...} when a show ran under a second ago
watch   catch Ctrl+Shift+Esc from the keyboards themselves and run show

KWin drops every global shortcut while the focused window holds the keyboard: Citrix's XWayland
grab and the shortcuts inhibitor of Looking Glass or virt-viewer. watch therefore reads the
keyboards' evdev devices (a udev rule from the base host role lets the seat's user read them),
without grabbing them, so the keys still reach the focused window: Windows opens its own Task
Manager too, behind the minimized VM. KWin's hotkey for the same keys covers every other window,
and since both fire on one press, show ignores a second call within a second.
"""
import json
import os
import selectors
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import evdev
import pyudev
from evdev import ecodes

STATE = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "spawnkit-task-manager"
DEBOUNCE = 1.0

# Every normal window but plasmashell's own, which includes the process window being shown.
MINIMIZE_ALL = """
for (const w of workspace.windowList()) {
    if (w.normalWindow && w.minimizable && !w.minimized && w.resourceClass !== "plasmashell")
        w.minimized = true;
}
"""

STATS_WIDGETS = """
var ids = [];
panels().forEach(function (p) { p.widgets("tech.shmuel.stats").forEach(function (w) { ids.push(w.id) }) });
print(ids.join(" "));
"""


def busctl(*args):
    out = subprocess.run(["busctl", "--user", "--json=short", "call", *args],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)["data"] if out.strip() else []


def minimize_all():
    with tempfile.NamedTemporaryFile("w", suffix=".js", dir=STATE.parent, delete=False) as script:
        script.write(MINIMIZE_ALL)
    name = "spawnkit-minimize-all"
    try:
        busctl("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "unloadScript", "s", name)
        number = busctl("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "loadScript", "ss", script.name, name)[0]
        busctl("org.kde.KWin", f"/Scripting/Script{number}", "org.kde.kwin.Script", "run")
        busctl("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "unloadScript", "s", name)
    finally:
        os.unlink(script.name)


def open_process_window():
    # The stats widget opens its process window when activated (main.qml); kglobalaccel invokes
    # its activation action, which the widget registers without keys.
    ids = busctl("org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell", "evaluateScript", "s", STATS_WIDGETS)[0].split()
    if not ids:
        raise SystemExit("spawnkit-task-manager: no System stats widget on any panel")
    busctl("org.kde.kglobalaccel", "/component/plasmashell", "org.kde.kglobalaccel.Component",
           "invokeShortcut", "s", f"activate widget {ids[0]}")


def show():
    now = time.time()
    try:
        last = float(STATE.read_text())
    except (OSError, ValueError):
        last = 0
    if 0 <= now - last < DEBOUNCE:
        return {"shown": False, "reason": "shown under a second ago"}
    STATE.write_text(str(now))
    minimize_all()
    open_process_window()
    return {"shown": True}


CTRL = {ecodes.KEY_LEFTCTRL, ecodes.KEY_RIGHTCTRL}
SHIFT = {ecodes.KEY_LEFTSHIFT, ecodes.KEY_RIGHTSHIFT}
OTHER = {ecodes.KEY_LEFTALT, ecodes.KEY_RIGHTALT, ecodes.KEY_LEFTMETA, ecodes.KEY_RIGHTMETA}


def is_keyboard(device):
    keys = device.capabilities().get(ecodes.EV_KEY, [])
    return ecodes.KEY_ESC in keys and ecodes.KEY_LEFTCTRL in keys


def watch():
    sel = selectors.DefaultSelector()
    devices = {}
    held = set()

    def add(path):
        if path in devices or not path.startswith("/dev/input/event"):
            return
        try:
            device = evdev.InputDevice(path)
        except OSError as err:
            print(f"skipping {path}: {err}", file=sys.stderr, flush=True)
            return
        if not is_keyboard(device):
            device.close()
            return
        devices[path] = device
        sel.register(device, selectors.EVENT_READ)
        print(f"watching {path} ({device.name})", flush=True)

    def remove(path):
        device = devices.pop(path, None)
        if device:
            sel.unregister(device)
            device.close()
            held.clear()

    monitor = pyudev.Monitor.from_netlink(pyudev.Context())
    monitor.filter_by("input")
    monitor.start()
    sel.register(monitor, selectors.EVENT_READ)
    for path in evdev.list_devices():
        add(path)
    if not devices:
        print("no readable keyboard: is the base host role's udev rule applied?", file=sys.stderr, flush=True)

    while True:
        for key, _ in sel.select():
            if key.fileobj is monitor:
                while (event := monitor.poll(0)) is not None:
                    if event.device_node:
                        if event.action == "add":
                            # udev applies the access rule after the node appears.
                            time.sleep(0.2)
                            add(event.device_node)
                        elif event.action == "remove":
                            remove(event.device_node)
                continue
            device = key.fileobj
            try:
                events = list(device.read())
            except OSError:
                remove(device.path)
                continue
            for event in events:
                if event.type != ecodes.EV_KEY:
                    continue
                if event.value == 0:
                    held.discard(event.code)
                elif event.value == 1:
                    held.add(event.code)
                    if event.code == ecodes.KEY_ESC and held & CTRL and held & SHIFT and not held & OTHER:
                        try:
                            print(json.dumps(show()), flush=True)
                        except (subprocess.CalledProcessError, SystemExit) as err:
                            print(f"show failed: {err}", file=sys.stderr, flush=True)


def main():
    command = sys.argv[1] if len(sys.argv) == 2 else ""
    if command == "show":
        print(json.dumps(show()))
    elif command == "watch":
        watch()
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
