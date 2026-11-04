"""Keep a local copy of the Google calendars that Google Calendar shows, for the panel clock.

sync fetches them through the personal-secrets Google wrapper; events and status read the
local copy, so the clock never waits on the network or touches credentials.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
from pathlib import Path

ACCOUNT = os.environ["SPAWNKIT_CALENDAR_ACCOUNT"]
HELPER = Path.home() / "repos/skamensky/personal-gcp/scripts/personal-secrets.py"
STORE = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "spawnkit/calendar/events.json"
PAST_DAYS = 31
FUTURE_DAYS = 92


def google(*args):
    result = subprocess.run(
        [sys.executable, str(HELPER), "google", "--account", ACCOUNT, "--", "--json", *args],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise SystemExit(f"google-automation {' '.join(args[:3])} failed: {result.stderr.strip()[-500:]}")
    return json.loads(result.stdout)


def when(point):
    """An event boundary as (ISO string, all-day flag)."""
    return (point["date"], True) if "date" in point else (point["dateTime"], False)


def sync(_args):
    today = datetime.date.today()
    since = (today - datetime.timedelta(days=PAST_DAYS)).isoformat()
    until = (today + datetime.timedelta(days=FUTURE_DAYS)).isoformat()
    events = []
    calendars = [c for c in google("calendar", "calendars", "list") if c.get("selected") or c.get("primary")]
    for calendar in calendars:
        for event in google("calendar", "events", "list", "--calendar-id", calendar["id"],
                            "--from", since, "--to", until, "--limit", "2500"):
            if event.get("status") == "cancelled":
                continue
            start, all_day = when(event["start"])
            end, _ = when(event["end"])
            events.append({
                "calendar": calendar.get("summaryOverride") or calendar["summary"],
                "color": event.get("backgroundColor") or calendar.get("backgroundColor", "#4285f4"),
                "summary": event.get("summary", "(No title)"),
                "start": start,
                "end": end,
                "allDay": all_day,
                "link": event.get("htmlLink", ""),
                "meet": event.get("hangoutLink", ""),
            })
    events.sort(key=lambda e: (e["start"][:10], not e["allDay"], e["start"]))
    STORE.parent.mkdir(parents=True, exist_ok=True)
    temporary = STORE.with_suffix(".tmp")
    temporary.write_text(json.dumps({
        "synced": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "calendars": [c.get("summaryOverride") or c["summary"] for c in calendars],
        "events": events,
    }))
    temporary.replace(STORE)
    print(json.dumps({"synced": True, "calendars": len(calendars), "events": len(events)}))


def load():
    try:
        return json.loads(STORE.read_text())
    except FileNotFoundError:
        return {"synced": None, "calendars": [], "events": []}


def last_day(event):
    """The last day an event covers; Google gives all-day events an exclusive end date."""
    end = datetime.date.fromisoformat(event["end"][:10])
    return (end - datetime.timedelta(days=event["allDay"])).isoformat()


def events(args):
    data = load()
    picked = [e for e in data["events"]
              if (not args.since or last_day(e) >= args.since) and (not args.until or e["start"][:10] <= args.until)]
    print(json.dumps({"synced": data["synced"], "events": picked}))


def status(_args):
    data = load()
    print(json.dumps({"store": str(STORE), "synced": data["synced"],
                      "calendars": data["calendars"], "events": len(data["events"])}))


def main():
    parser = argparse.ArgumentParser(prog="spawnkit-calendar", description=__doc__)
    commands = parser.add_subparsers(required=True)
    commands.add_parser("sync", help="fetch the shown Google calendars into the local copy").set_defaults(run=sync)
    listing = commands.add_parser("events", help="print the local copy's events as JSON")
    listing.add_argument("--from", dest="since", help="first day, YYYY-MM-DD")
    listing.add_argument("--to", dest="until", help="last day, YYYY-MM-DD")
    listing.set_defaults(run=events)
    commands.add_parser("status", help="print when the local copy was synced, as JSON").set_defaults(run=status)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
