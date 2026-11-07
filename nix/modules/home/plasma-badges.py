"""Unread-count badges and text tags on Plasma task manager icons.

serve           own tech.shmuel.Badges, publish counts through the Unity launcher API (which
                Plasma's task manager draws on the app's icon), publish tags in its Tags
                property (which Spawnkit's task manager fork draws under the icon) and poll the
                sources below
set APP COUNT   set APP's badge (a desktop file id without .desktop); 0 clears it
list            print the current counts as JSON
tags            print the current tags as JSON: {app: {"text": ..., "tone": ...}}, tone one of
                "positive", "neutral", "starting" or "stopping"
chrome-profile TITLE
                print whose Chrome profile the window titled TITLE belongs to, or nothing if
                that can't be told

WhatsApp Web shows its unread count only inside the page, so its window runs a dedicated Chrome
profile with DevTools on a local port, and serve reads the count from the page every few seconds.

The Windows VM's launcher is tagged "starting" while it boots, "RTX" when the running VM holds the
RTX (the GPU is bound to vfio-pci), "no RTX" when it runs without it and "stopping" while it shuts
down and the RTX returns; with the VM off there is no tag.
"""
import asyncio
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

import websockets
from dbus_next import BusType, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import PropertyAccess, ServiceInterface, dbus_property, method, signal

NAME = "tech.shmuel.Badges"
PATH = "/tech/shmuel/Badges"
POLL_SECONDS = 5
# app id -> (DevTools port, page URL prefix, expression returning the unread count)
WEB_APPS = {
    "chrome-web.whatsapp.com__-Default": (
        9333,
        "https://web.whatsapp.com",
        """[...document.querySelectorAll('#pane-side [aria-label]')]
             .map(e => /^(\\d+) unread message/.exec(e.getAttribute('aria-label')))
             .reduce((n, m) => n + (m ? Number(m[1]) : 0), 0)""",
    ),
}
WINDOWS_POLL_SECONDS = 1
WINDOWS_CONFIG = "/etc/spawnkit/windows.json"
WINDOWS_PHASE = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "spawnkit/windows-phase.json"
GPU_RESERVATION = Path("/run/spawnkit/gpu-owner.json")
STARTING = {"text": "starting", "tone": "starting"}
STOPPING = {"text": "stopping", "tone": "stopping"}
WINDOWS_APP = "spawnkit-windows"


def props(count):
    return {"count": Variant("x", count), "count-visible": Variant("b", count > 0)}


def uri(app):
    return f"application://{app}.desktop"


class Launcher(ServiceInterface):
    def __init__(self):
        super().__init__("com.canonical.Unity.LauncherEntry")
        self.counts = {}

    @signal()
    def Update(self, uri, properties) -> "sa{sv}":
        return [uri, properties]

    @method()
    def Query(self) -> "a(sa{sv})":
        return [[uri(app), props(n)] for app, n in self.counts.items()]


class Badges(ServiceInterface):
    def __init__(self, launcher):
        super().__init__(NAME)
        self.launcher = launcher
        self.tags = {}

    def set_tag(self, app, tag):
        if self.tags.get(app) == tag:
            return
        if tag:
            self.tags[app] = tag
        else:
            self.tags.pop(app, None)
        self.emit_properties_changed({"Tags": json.dumps(self.tags)})

    @dbus_property(access=PropertyAccess.READ)
    def Tags(self) -> "s":
        return json.dumps(self.tags)

    def set(self, app, count):
        if self.launcher.counts.get(app, 0) == count:
            return
        if count:
            self.launcher.counts[app] = count
        else:
            self.launcher.counts.pop(app, None)
        self.launcher.Update(uri(app), props(count))

    @method()
    def Set(self, app: "s", count: "i"):
        self.set(app, max(count, 0))

    @method()
    def List(self) -> "s":
        return json.dumps(self.launcher.counts)


def page_socket(port, prefix):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=2) as response:
        pages = json.load(response)
    return next((p["webSocketDebuggerUrl"] for p in pages if p["type"] == "page" and p["url"].startswith(prefix)), None)


async def unread(port, prefix, expression):
    """The page's unread count, or 0 when the window is closed or the page is not ready."""
    try:
        socket = await asyncio.to_thread(page_socket, port, prefix)
        if not socket:
            return 0
        async with websockets.connect(socket, max_size=None, open_timeout=3) as ws:
            await ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": expression, "returnByValue": True}}))
            reply = json.loads(await asyncio.wait_for(ws.recv(), 3))
        value = reply.get("result", {}).get("result", {}).get("value")
        return value if isinstance(value, int) and value > 0 else 0
    except (OSError, asyncio.TimeoutError, websockets.WebSocketException, ValueError):
        return 0


class WindowsTag:
    """The Windows launcher's tag, from host-config's phase file, libvirt and the guest agent.

    "starting" from vm-start until the guest agent first answers, "stopping" from vm-stop or from
    the agent going quiet (a shutdown inside Windows) until the RTX is back on Linux; then "RTX"
    or "no RTX" while it runs, "paused" while suspended, and an empty tag while it is off. The
    tag's actions name the launcher's desktop actions the task manager offers on right click.
    """

    OFF = ["Open in a window", "Start without the RTX"]
    RUNNING = ["Open in a window", "Pause", "Restart", "Shut down"]
    PAUSED = ["Resume", "Shut down"]
    STOPPING_RUNNING = ["Force power off"]  # the domain still runs, so a stuck shutdown can be cut

    def __init__(self):
        self.up = None  # the domain id whose guest agent has answered
        self.stopping = False

    def __call__(self):
        try:
            with open(WINDOWS_CONFIG) as f:
                config = json.load(f)
        except (OSError, ValueError):
            return None
        if not config.get("windows_vm"):
            return None
        phase = host_config_phase()
        name = config["windows_name"]
        state = virsh("domstate", name)
        if state == "paused" and not phase:
            return {"text": "paused", "tone": "neutral", "actions": self.PAUSED}
        if state == "running":
            domain = virsh("domid", name)
            if phase != "stopping" and virsh("qemu-agent-command", name, '{"execute":"guest-ping"}', "--timeout", "1") is not None:
                self.up, self.stopping = domain, False
            elif phase == "stopping" or self.up == domain:
                self.stopping = True
            if self.stopping:
                return STOPPING | {"actions": self.STOPPING_RUNNING}
            if self.up != domain:
                return STARTING
        elif phase:
            return STOPPING if phase == "stopping" else STARTING
        elif state == "shut off" and self.stopping and GPU_RESERVATION.exists():
            return STOPPING  # the release hook is returning the RTX to Linux
        else:
            self.up, self.stopping = None, False
            return {"text": "", "tone": "neutral", "actions": self.OFF}
        gpu = config.get("gpu_devices", [{}])[0].get("address")
        try:
            driver = gpu and os.path.basename(os.readlink(f"/sys/bus/pci/devices/{gpu}/driver"))
        except OSError:
            driver = None
        if driver == "vfio-pci":
            return {"text": "RTX", "tone": "positive", "actions": self.RUNNING}
        return {"text": "no RTX", "tone": "neutral", "actions": self.RUNNING}


def virsh(*args):
    """virsh's output on the system connection, or None when it fails."""
    try:
        result = subprocess.run(["virsh", "-c", "qemu:///system", *args], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def host_config_phase():
    """The phase a running host-config vm-start or vm-stop published, or None."""
    try:
        with open(WINDOWS_PHASE) as f:
            phase = json.load(f)
        os.kill(phase["pid"], 0)
        return phase["phase"]
    except (OSError, ValueError, KeyError, TypeError):
        return None


async def poll(badges):
    while True:
        for app, (port, prefix, expression) in WEB_APPS.items():
            badges.set(app, await unread(port, prefix, expression))
        await asyncio.sleep(POLL_SECONDS)


async def poll_windows(badges):
    tag = WindowsTag()
    while True:
        badges.set_tag(WINDOWS_APP, await asyncio.to_thread(tag))
        await asyncio.sleep(WINDOWS_POLL_SECONDS)


async def serve():
    bus = await MessageBus(bus_type=BusType.SESSION).connect()
    launcher = Launcher()
    badges = Badges(launcher)
    bus.export(PATH + "/launcher", launcher)
    bus.export(PATH, badges)
    await bus.request_name(NAME)
    await asyncio.gather(poll(badges), poll_windows(badges), bus.wait_for_disconnect())


async def call(member, *args):
    bus = await MessageBus(bus_type=BusType.SESSION).connect()
    introspection = await bus.introspect(NAME, PATH)
    proxy = bus.get_proxy_object(NAME, PATH, introspection).get_interface(NAME)
    return await getattr(proxy, member)(*args)


def chrome_profile(window_title):
    """Chrome keeps the profile out of a window's title, app id and process, so look for the
    title among the tabs each open profile has saved. Two profiles with the tab give no answer."""
    title = re.sub("[\u200e\u200f\u202a-\u202e]", "", window_title)
    title = re.sub(r"\s*<\d+>$", "", title).removesuffix(" - Google Chrome").encode("utf-16-le")
    root = Path.home() / ".config/google-chrome"
    profiles = json.loads((root / "Local State").read_text())["profile"]
    owners = []
    for directory in profiles.get("last_active_profiles", []):
        sessions = list((root / directory / "Sessions").glob("Session_*"))
        if sessions and title in max(sessions, key=lambda path: path.stat().st_mtime).read_bytes():
            owners.append(profiles["info_cache"][directory])
    if len(owners) != 1:
        return ""
    owner = owners[0]
    return (not owner.get("is_using_default_name") and owner.get("name")) or owner.get("gaia_name") or owner.get("user_name", "")


def main(argv):
    if argv[:1] == ["serve"]:
        asyncio.run(serve())
    elif argv[:1] == ["set"] and len(argv) == 3:
        asyncio.run(call("call_set", argv[1], int(argv[2])))
    elif argv[:1] == ["list"]:
        print(asyncio.run(call("call_list")))
    elif argv[:1] == ["tags"]:
        print(asyncio.run(call("get_tags")))
    elif argv[:1] == ["chrome-profile"] and len(argv) == 2:
        print(chrome_profile(argv[1]))
    else:
        sys.exit(__doc__)


main(sys.argv[1:])
