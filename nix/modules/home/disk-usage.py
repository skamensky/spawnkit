"""Index of the disk space every directory occupies, for Dolphin's Size column and for agents.

  refresh PATH [--max-age SECONDS]   recompute PATH's subtree with du, unless a scan covering it
                                     finished within SECONDS; waits for a covering scan in progress
  ls [--json] PATH...                PATH's total and its subdirectories' totals, from the index
  status [--json]                    scans in progress and finished

Sizes are allocated bytes (du -x -B1): one filesystem per scan, hard links counted once. A scan
replaces its subtree in one transaction and moves its ancestors' totals by the difference.
"""
import argparse
import json
import os
import pathlib
import signal
import sqlite3
import subprocess
import sys
import time

DU = os.environ.get("SPAWNKIT_DU", "du")
DATABASE = pathlib.Path(os.environ.get("XDG_CACHE_HOME", pathlib.Path.home() / ".cache")) / "spawnkit/disk-usage.db"
# Kernel views and network mounts: nothing du reports there is space on a local disk.
SKIPPED_FILESYSTEMS = ("proc", "sysfs", "devtmpfs", "devpts", "cgroup", "cgroup2", "debugfs", "tracefs", "securityfs",
                       "pstore", "bpf", "configfs", "efivarfs", "nfs", "nfs4", "cifs", "smb3", "9p", "autofs")
SCHEMA = """
CREATE TABLE IF NOT EXISTS usage (parent TEXT NOT NULL, name TEXT NOT NULL, bytes INTEGER NOT NULL,
                                  PRIMARY KEY (parent, name)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS scans (path TEXT PRIMARY KEY, pid INTEGER NOT NULL, started REAL NOT NULL,
                                  finished REAL) WITHOUT ROWID;
"""


def connect():
    DATABASE.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(DATABASE, timeout=120, isolation_level=None)
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript(SCHEMA)
    return db


def key(path):
    """A directory's (parent, name) row key; the root is ('', '/')."""
    return ("", "/") if path == "/" else (os.path.dirname(path), os.path.basename(path))


def ancestors(path):
    """PATH's ancestors, nearest first."""
    found = []
    while path != "/":
        path = os.path.dirname(path)
        found.append(path)
    return found


def below(path):
    """The half-open range of parent values that covers everything beneath PATH."""
    prefix = path.rstrip("/") + "/"
    return prefix, prefix[:-1] + "0"


def filesystem(path):
    """The type of the filesystem PATH is on, from the longest matching mount point."""
    best, kind = "", ""
    with open("/proc/self/mountinfo", encoding="utf-8", errors="surrogateescape") as mounts:
        for line in mounts:
            fields = line.split()
            mount = fields[4].encode().decode("unicode_escape")
            if (path == mount or path.startswith(mount.rstrip("/") + "/")) and len(mount) >= len(best):
                best, kind = mount, fields[fields.index("-") + 1]
    return kind


def scanning(pid):
    try:
        return b"spawnkit-disk-usage" in pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return False


def claim(db, path, max_age):
    """Decide what a refresh of PATH does: 'scan' (claimed), 'wait' or 'fresh'."""
    covering = [path] + ancestors(path)
    db.execute("BEGIN IMMEDIATE")
    try:
        rows = db.execute(f"SELECT pid, finished FROM scans WHERE path IN ({','.join('?' * len(covering))})", covering).fetchall()
        if any(finished is None and pid != os.getpid() and scanning(pid) for pid, finished in rows):
            return "wait"
        if any(finished is not None and finished > time.time() - max_age for _, finished in rows):
            return "fresh"
        db.execute("INSERT OR REPLACE INTO scans VALUES (?, ?, ?, NULL)", (path, os.getpid(), time.time()))
        return "scan"
    finally:
        db.execute("COMMIT")


def scan(db, path):
    """Run du over PATH and replace its subtree in the index. Returns PATH's total."""
    db.execute("CREATE TEMP TABLE found (parent TEXT, name TEXT, bytes INTEGER)")
    # du exits 1 when it could not read something (other users' directories); what it could read still counts.
    du = subprocess.Popen([DU, "-x", "-0", "-B1", "--", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        pending = b""
        db.execute("BEGIN")
        while chunk := du.stdout.read(1 << 20):
            *records, pending = (pending + chunk).split(b"\0")
            rows = []
            for record in records:
                size, _, name = record.partition(b"\t")
                try:
                    rows.append((*key(name.decode()), int(size)))
                except UnicodeDecodeError:
                    pass  # counted in its parent's total; SQLite text cannot hold the name
            db.executemany("INSERT INTO found VALUES (?, ?, ?)", rows)
        db.execute("COMMIT")
    finally:
        du.kill()
        du.wait()
    total = db.execute("SELECT bytes FROM found WHERE parent = ? AND name = ?", key(path)).fetchone()
    if total is None:
        raise SystemExit(f"du reported nothing for {path}")
    device = os.stat(path).st_dev
    db.execute("BEGIN IMMEDIATE")
    previous = db.execute("SELECT bytes FROM usage WHERE parent = ? AND name = ?", key(path)).fetchone()
    db.execute("DELETE FROM usage WHERE (parent = ? AND name = ?) OR parent = ? OR (parent >= ? AND parent < ?)",
               (*key(path), path, *below(path)))
    db.execute("INSERT OR REPLACE INTO usage SELECT parent, name, bytes FROM found")
    if previous is not None:
        for ancestor in ancestors(path):
            # A mount point's space is not its parent filesystem's.
            if os.stat(ancestor).st_dev != device:
                break
            db.execute("UPDATE usage SET bytes = max(0, bytes + ?) WHERE parent = ? AND name = ?",
                       (total[0] - previous[0], *key(ancestor)))
    db.execute("DELETE FROM scans WHERE path >= ? AND path < ?", below(path))
    db.execute("UPDATE scans SET finished = ? WHERE path = ?", (time.time(), path))
    db.execute("COMMIT")
    db.execute("DROP TABLE found")
    return total[0]


def refresh(args):
    path = os.path.realpath(args.path)
    if not os.path.isdir(path):
        raise SystemExit(f"{path} is not a directory")
    kind = filesystem(path)
    if kind in SKIPPED_FILESYSTEMS or kind.startswith("fuse."):
        print(json.dumps({"path": path, "result": "skipped"}))
        return
    db = connect()
    while (action := claim(db, path, args.max_age)) == "wait":
        time.sleep(0.3)
    if action == "scan":
        print(json.dumps({"path": path, "result": "scanned", "bytes": scan(db, path)}))
    else:
        print(json.dumps({"path": path, "result": "fresh"}))


def listing(db, path):
    real = os.path.realpath(path)
    own = db.execute("SELECT bytes FROM usage WHERE parent = ? AND name = ?", key(real)).fetchone()
    covering = [real] + ancestors(real)
    scanned = db.execute(f"SELECT max(finished) FROM scans WHERE path IN ({','.join('?' * len(covering))})", covering).fetchone()
    children = dict(db.execute("SELECT name, bytes FROM usage WHERE parent = ?", (real,)))
    return {"path": real, "bytes": own and own[0], "scanned": scanned[0], "children": children}


def human(size):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if size < 1024 or unit == "TiB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{size} B"
        size /= 1024


def ls(args):
    db = connect()
    listings = {path: listing(db, path) for path in args.paths}
    if args.json:
        print(json.dumps({"directories": listings}, ensure_ascii=False))
        return
    for found in listings.values():
        age = "never scanned" if found["scanned"] is None else f"scanned {time.strftime('%Y-%m-%d %H:%M', time.localtime(found['scanned']))}"
        print(f"{human(found['bytes']) if found['bytes'] is not None else 'unknown':>11}  {found['path']}  ({age})")
        for name, size in sorted(found["children"].items(), key=lambda child: -child[1]):
            print(f"{human(size):>11}    {name}")


def status(args):
    db = connect()
    scans = [{"path": path, "running": finished is None and scanning(pid), "started": started, "finished": finished}
             for path, pid, started, finished in db.execute("SELECT path, pid, started, finished FROM scans ORDER BY started")]
    scans = [entry for entry in scans if entry["running"] or entry["finished"] is not None]
    if args.json:
        print(json.dumps({"database": str(DATABASE), "scans": scans}, ensure_ascii=False))
        return
    for entry in scans:
        when = "running" if entry["running"] else time.strftime("%Y-%m-%d %H:%M", time.localtime(entry["finished"]))
        print(f"{when:>16}  {entry['path']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("refresh")
    command.add_argument("path")
    command.add_argument("--max-age", type=float, default=30, help="seconds a covering scan stays fresh (0: always scan)")
    command.set_defaults(run=refresh)
    command = commands.add_parser("ls")
    command.add_argument("paths", nargs="+")
    command.add_argument("--json", action="store_true")
    command.set_defaults(run=ls)
    command = commands.add_parser("status")
    command.add_argument("--json", action="store_true")
    command.set_defaults(run=status)
    # Dolphin ends a refresh it no longer wants with SIGTERM; unwind so du stops too.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
