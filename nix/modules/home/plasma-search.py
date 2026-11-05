"""Application search for Plasma (the Start menu and KRunner) that learns from what you launch.

serve                   run the tech.shmuel.apps KRunner D-Bus runner
query TEXT              print the ranked matches for TEXT as JSON
launch APP [--query Q]  launch APP (a desktop file id) and, with Q, learn that Q led to it
history                 print the learned launches as JSON

An application scores by how its name matches the query (whole name, name prefix, word prefix,
initials, letters in order from a word's start, substring, then keywords, generic name and command, then a fuzzy subsequence), plus
what it has learned: apps launched after typing this query, or one it extends or shortens, rank
higher, and so, a little, do apps launched often and recently.
"""
import configparser
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

NAME = "tech.shmuel.apps"
PATH = "/runner"
STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "spawnkit/search.json"
LIMIT = 12
HALF_LIFE_DAYS = 14


def data_dirs():
    home = os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))
    rest = os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":")
    return [Path(d) / "applications" for d in [home, *rest] if d]


def words(text):
    return [w for w in re.split(r"[^\w]+", text.lower()) if w]


class App:
    def __init__(self, app_id, entry, path):
        self.id = app_id
        self.path = path
        self.name = entry.get("Name", app_id)
        self.icon = entry.get("Icon", "application-x-executable")
        self.comment = entry.get("Comment", "")
        self.generic = entry.get("GenericName", "")
        self.keywords = [k for k in entry.get("Keywords", "").split(";") if k]
        command = entry.get("Exec", "").split()
        self.command = os.path.basename(command[0]) if command else ""
        self.lname = self.name.lower()
        self.name_words = words(self.name)
        self.initials = "".join(w[0] for w in self.name_words)
        self.extra_words = words(" ".join([self.generic, self.command, *self.keywords]))


def read_entry(path):
    parser = configparser.RawConfigParser(strict=False, interpolation=None)
    parser.optionxform = str
    try:
        parser.read(path, encoding="utf-8")
        return dict(parser["Desktop Entry"])
    except (configparser.Error, KeyError, UnicodeDecodeError, OSError):
        return None


def shown(entry):
    desktops = set(os.environ.get("XDG_CURRENT_DESKTOP", "KDE").split(":"))
    only = set(filter(None, entry.get("OnlyShowIn", "").split(";")))
    hidden = set(filter(None, entry.get("NotShowIn", "").split(";")))
    try_exec = entry.get("TryExec")
    return (
        entry.get("Type") == "Application"
        and entry.get("NoDisplay", "").lower() != "true"
        and entry.get("Hidden", "").lower() != "true"
        and (not only or only & desktops)
        and not hidden & desktops
        and (not try_exec or shutil.which(try_exec))
    )


class Catalog:
    """The visible desktop entries, rescanned whenever an applications directory changes."""

    def __init__(self):
        self.stamp = None
        self.apps = {}

    def current(self):
        stamp = tuple(d.stat().st_mtime_ns if d.is_dir() else 0 for d in data_dirs())
        if stamp != self.stamp:
            self.stamp, self.apps = stamp, self.scan()
        return self.apps

    @staticmethod
    def scan():
        apps, seen, names = {}, set(), set()
        for root in data_dirs():
            if not root.is_dir():
                continue
            for path in sorted(root.rglob("*.desktop")):
                app_id = str(path.relative_to(root)).replace("/", "-")
                if app_id in seen:  # an earlier directory overrides later ones
                    continue
                seen.add(app_id)
                entry = read_entry(path)
                if entry and shown(entry):
                    app = App(app_id, entry, path)
                    # One result per name: Firefox from the profile hides the snap's Firefox.
                    if app.lname not in names:
                        names.add(app.lname)
                        apps[app_id] = app
        return apps


def subsequence(query, text):
    position = 0
    for char in query:
        position = text.find(char, position) + 1
        if not position:
            return False
    return True


def term_score(term, app):
    """0-100 for how one query term matches the app, or 0."""
    if app.lname == term:
        return 100
    if app.lname.startswith(term):
        return 92
    for index, word in enumerate(app.name_words):
        if word.startswith(term):
            return 84 - 2 * index
    if len(term) > 1 and app.initials.startswith(term):
        return 76
    if len(term) > 1 and any(w.startswith(term[0]) and subsequence(term[1:], w[1:]) for w in app.name_words):
        return 68  # "wa" for WhatsApp, before "wa" inside Software
    if term in app.lname:
        return 64
    for word in app.extra_words:
        if word.startswith(term):
            return 56
    if any(term in word for word in app.extra_words):
        return 44
    if len(term) > 2 and subsequence(term, app.lname):
        return 30
    return 0


def text_score(query, app):
    if app.lname == query:
        return 100
    scores = [term_score(term, app) for term in query.split()]
    if not scores or not all(scores):
        return 0
    # Shorter names win ties: "System Settings" before "NVIDIA X Server Settings".
    return sum(scores) / len(scores) - min(len(app.name), 40) / 20


class History:
    def __init__(self):
        try:
            self.data = json.loads(STATE.read_text())
        except (OSError, ValueError):
            self.data = {}
        self.data.setdefault("apps", {})
        self.data.setdefault("queries", {})

    def learn(self, query, app_id):
        now = time.time()
        app = self.data["apps"].setdefault(app_id, {"count": 0, "last": now})
        app["count"] += 1
        app["last"] = now
        if query:
            picks = self.data["queries"].setdefault(query, {})
            picks[app_id] = picks.get(app_id, 0) + 1
        STATE.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data, indent=1, sort_keys=True))
        tmp.replace(STATE)

    def boost(self, query, app_id):
        """0-1 for apps picked after this query or one it extends or shortens."""
        weight = 0.0
        for typed, picks in self.data["queries"].items():
            count = picks.get(app_id)
            if not count:
                continue
            if typed == query:
                weight += 2 * count
            elif typed.startswith(query) or query.startswith(typed):
                weight += count
        return min(weight / 4, 1.0)

    def frecency(self, app_id):
        """0-1 from how often and how recently the app was launched through search."""
        app = self.data["apps"].get(app_id)
        if not app:
            return 0.0
        age_days = (time.time() - app["last"]) / 86400
        return min(app["count"] * 0.5 ** (age_days / HALF_LIFE_DAYS) / 10, 1.0)


def search(catalog, history, text):
    query = " ".join(text.lower().split())
    if not query:
        return []
    results = []
    for app in catalog.current().values():
        base = text_score(query, app)
        if base:
            learned = history.boost(query, app.id)
            score = base + 40 * learned + 10 * history.frecency(app.id)
            results.append((score, learned, app))
    results.sort(key=lambda r: (-r[0], r[2].lname))
    return results[:LIMIT]


def launch(app_id, query, history, catalog):
    app = catalog.current().get(app_id)
    if app is None:
        return
    # kioclient starts D-Bus-activated apps (Ptyxis, most GNOME apps); `kstart --application`
    # waits forever on them without starting anything.
    subprocess.Popen(["kioclient", "exec", str(app.path)], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Plasma's recent and frequent lists read this usage database.
    subprocess.run(["qdbus6", "org.kde.ActivityManager", "/ActivityManager/Resources",
                    "org.kde.ActivityManager.Resources.RegisterResourceEvent",
                    "org.kde.krunner", "0", f"applications:{app_id}", "0"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    history.learn(" ".join(query.lower().split()), app_id)


def serve():
    import asyncio

    from dbus_next import BusType, Variant
    from dbus_next.aio import MessageBus
    from dbus_next.service import ServiceInterface, method

    catalog, history = Catalog(), History()

    class Runner(ServiceInterface):
        def __init__(self):
            super().__init__("org.kde.krunner1")
            self.query = ""

        @method()
        def Actions(self) -> "a(sss)":
            return []

        @method()
        def Match(self, query: "s") -> "a(sssida{sv})":
            self.query = query
            matches = []
            for score, learned, app in search(catalog, history, query):
                category = 100 if score >= 80 or learned else 70
                properties = {"category": Variant("s", "Applications")}
                if app.comment or app.generic:
                    properties["subtext"] = Variant("s", app.comment or app.generic)
                matches.append([app.id, app.name, app.icon, category, min(score / 150, 1.0), properties])
            return matches

        @method()
        def Run(self, match_id: "s", action_id: "s"):
            launch(match_id, self.query, history, catalog)

    async def main():
        bus = await MessageBus(bus_type=BusType.SESSION).connect()
        bus.export(PATH, Runner())
        await bus.request_name(NAME)
        await bus.wait_for_disconnect()

    asyncio.run(main())


def main(argv):
    if argv == ["serve"]:
        serve()
    elif len(argv) == 2 and argv[0] == "query":
        history = History()
        print(json.dumps([
            {"id": app.id, "name": app.name, "score": round(score, 1), "learned": round(learned, 2)}
            for score, learned, app in search(Catalog(), history, argv[1])
        ], indent=1))
    elif len(argv) in (2, 4) and argv[0] == "launch" and (len(argv) == 2 or argv[2] == "--query"):
        launch(argv[1], argv[3] if len(argv) == 4 else "", History(), Catalog())
    elif argv == ["history"]:
        print(json.dumps(History().data, indent=1, sort_keys=True))
    else:
        sys.exit(__doc__)


main(sys.argv[1:])
