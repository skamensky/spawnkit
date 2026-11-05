"""Unread-count badges and text tags on Plasma task manager icons.

serve           own tech.shmuel.Badges, publish counts through the Unity launcher API (which
                Plasma's task manager draws on the app's icon), publish tags in its Tags
                property (which Spawnkit's task manager fork draws under the icon) and poll the
                sources below
set APP COUNT   set APP's badge (a desktop file id without .desktop); 0 clears it
list            print the current counts as JSON
tags            print the current tags as JSON: {app: {"text": ..., "tone": "positive"|"neutral"}}

WhatsApp Web shows its unread count only inside the page, so its window runs a dedicated Chrome
profile with DevTools on a local port, and serve reads the count from the page every few seconds.

While the Windows VM runs, its launcher is tagged "RTX" when the VM holds the RTX (the GPU is
bound to vfio-pci) and "no RTX" when it runs without it; with the VM off there is no tag.
"""
import asyncio
import json
import os
import subprocess
import sys
import urllib.request

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
WINDOWS_CONFIG = "/etc/spawnkit/windows.json"
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


def windows_tag():
    """The Windows launcher's tag: whether the running VM holds the RTX, or None when it is off."""
    try:
        with open(WINDOWS_CONFIG) as f:
            config = json.load(f)
        if not config.get("windows_vm"):
            return None
        state = subprocess.run(["virsh", "-c", "qemu:///system", "domstate", config["windows_name"]],
                               capture_output=True, text=True, timeout=5).stdout.strip()
        if state != "running":
            return None
        gpu = config.get("gpu_devices", [{}])[0].get("address")
        driver = gpu and os.path.basename(os.readlink(f"/sys/bus/pci/devices/{gpu}/driver"))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        return None
    if driver == "vfio-pci":
        return {"text": "RTX", "tone": "positive"}
    return {"text": "no RTX", "tone": "neutral"}


async def poll(badges):
    while True:
        for app, (port, prefix, expression) in WEB_APPS.items():
            badges.set(app, await unread(port, prefix, expression))
        badges.set_tag(WINDOWS_APP, await asyncio.to_thread(windows_tag))
        await asyncio.sleep(POLL_SECONDS)


async def serve():
    bus = await MessageBus(bus_type=BusType.SESSION).connect()
    launcher = Launcher()
    badges = Badges(launcher)
    bus.export(PATH + "/launcher", launcher)
    bus.export(PATH, badges)
    await bus.request_name(NAME)
    await asyncio.gather(poll(badges), bus.wait_for_disconnect())


async def call(member, *args):
    bus = await MessageBus(bus_type=BusType.SESSION).connect()
    introspection = await bus.introspect(NAME, PATH)
    proxy = bus.get_proxy_object(NAME, PATH, introspection).get_interface(NAME)
    return await getattr(proxy, member)(*args)


def main(argv):
    if argv[:1] == ["serve"]:
        asyncio.run(serve())
    elif argv[:1] == ["set"] and len(argv) == 3:
        asyncio.run(call("call_set", argv[1], int(argv[2])))
    elif argv[:1] == ["list"]:
        print(asyncio.run(call("call_list")))
    elif argv[:1] == ["tags"]:
        print(asyncio.run(call("get_tags")))
    else:
        sys.exit(__doc__)


main(sys.argv[1:])
