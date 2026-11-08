"""Rotates the Plasma wallpaper through the pinned nature photos (wallpapers.json).

daily    shows the next photo once per day, and otherwise reapplies today's
next     shows the next photo now (the desktop widget's buttons)
previous shows the previous photo now
current  prints today's photo
Each command prints the photo shown as JSON: title, author, license, source, url.
"""

import datetime
import json
import os
import pathlib
import subprocess
import sys

PHOTOS = json.loads(pathlib.Path(os.environ["SPAWNKIT_WALLPAPERS"]).read_text())
STATE = pathlib.Path(os.environ.get("XDG_STATE_HOME", pathlib.Path.home() / ".local/state")) / "spawnkit/wallpaper.json"


def load():
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {"index": -1, "date": ""}


def show(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state))
    tmp.replace(STATE)
    photo = PHOTOS[state["index"] % len(PHOTOS)]
    subprocess.run(["/usr/bin/plasma-apply-wallpaperimage", photo["path"]], check=True, stdout=subprocess.DEVNULL)


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "current"
    state = load()
    today = datetime.date.today().isoformat()
    step = {"next": 1, "previous": -1}.get(command, 1 if command == "daily" and state["date"] != today else 0)
    if step:
        show({"index": (state["index"] + step) % len(PHOTOS), "date": today})
        state = load()
    elif command == "daily":
        show(state)
    elif command != "current":
        sys.exit(f"usage: spawnkit-wallpaper daily|next|previous|current (not {command})")
    photo = PHOTOS[max(state["index"], 0) % len(PHOTOS)]
    print(json.dumps({k: photo[k] for k in ("title", "author", "license", "source", "url")}, ensure_ascii=False))


main()
