"""Unread-count badges on Plasma task manager icons.

serve           own tech.shmuel.Badges, publish counts through the Unity launcher API (which
                Plasma's task manager draws on the app's icon) and poll the web apps below
set APP COUNT   set APP's badge (a desktop file id without .desktop); 0 clears it
list            print the current counts as JSON

WhatsApp Web shows its unread count only inside the page, so its window runs a dedicated Chrome
profile with DevTools on a local port, and serve reads the count from the page every few seconds.
"""
import asyncio
import json
import sys
import urllib.request

import websockets
from dbus_next import BusType, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method, signal

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


async def poll(badges):
    while True:
        for app, (port, prefix, expression) in WEB_APPS.items():
            badges.set(app, await unread(port, prefix, expression))
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
    return await getattr(proxy, "call_" + member.lower())(*args)


def main(argv):
    if argv[:1] == ["serve"]:
        asyncio.run(serve())
    elif argv[:1] == ["set"] and len(argv) == 3:
        asyncio.run(call("Set", argv[1], int(argv[2])))
    elif argv[:1] == ["list"]:
        print(asyncio.run(call("List")))
    else:
        sys.exit(__doc__)


main(sys.argv[1:])
