"""spawnkit-stats: the machine's load and its processes as JSON, for the panel's stats widget and agents.

spawnkit-stats [--top N]      one snapshot of processor, graphics, memory, swap and disk use, with the
                              N busiest processes when asked
spawnkit-stats processes      every process, grouped by the app or service that owns it, with the
                              machine's CPU, memory, graphics and network use over the same interval
spawnkit-stats signal PID:START...  end processes with SIGTERM (--term) or SIGKILL (--kill) and report
                              which exited within --wait seconds
spawnkit-stats details PID:START...  what each process is: executable, parent, unit, start time and
                              memory, as JSON or (--text) as text to paste elsewhere, which --view
                              and --row open with where it was copied from
spawnkit-stats load           overall CPU use alone, a cheap reading for the panel's gauge

CPU (overall and per hardware thread), integrated-GPU load and network throughput are measured over
--interval seconds. Network throughput counts physical interfaces only (those backed by a device), so
bridges, VPN tunnels and the VM's virtual links do not count the same traffic twice. The integrated GPU's load is the
share of that time it spent out of its RC6 sleep state (i915's rc6_residency_ms). A discrete
NVIDIA GPU is reported as held by the Windows VM (bound to vfio-pci), asleep (runtime-suspended,
left asleep rather than woken by a query) or with nvidia-smi's utilisation and temperature.
"""
import argparse
import json
import os
import pwd
import re
import select
import shlex
import shutil
import signal as signals
import subprocess
import sys
import time
from functools import cache
from pathlib import Path

TICKS = os.sysconf("SC_CLK_TCK")
PAGE = os.sysconf("SC_PAGE_SIZE")
# Processes the desktop session cannot lose; the widget asks before ending them.
CRITICAL = {"systemd", "kwin_wayland", "kwin_x11", "plasmashell", "Xwayland", "Xorg", "ksmserver",
            "startplasma-wayland", "startplasma-x11", "plasma_session", "dbus-daemon", "dbus-broker",
            "pipewire", "wireplumber", "pipewire-pulse", "sddm", "gnome-shell", "polkitd", "login"}


def cpu_times():
    """{"cpu": (total, idle), "cpu0": ..., ...} from /proc/stat's aggregate and per-thread lines."""
    times = {}
    for line in Path("/proc/stat").read_text().splitlines():
        if not line.startswith("cpu"):
            break
        name, *values = line.split()
        fields = [int(v) for v in values]
        times[name] = (sum(fields[:8]), fields[3] + fields[4])  # idle + iowait
    return times


def busy(before, after):
    total, idle = after[0] - before[0], after[1] - before[1]
    return round(100 * (1 - idle / total), 1) if total > 0 else 0.0


def cpu_ranges(path):
    """CPU ids from a sysfs list such as "0-15,32"."""
    try:
        text = Path(path).read_text().strip()
    except OSError:
        return set()
    ids = set()
    for part in filter(None, text.split(",")):
        low, _, high = part.partition("-")
        ids.update(range(int(low), int(high or low) + 1))
    return ids


def threads(before, after):
    """Each hardware thread's load, physical core, clock and, on hybrid CPUs, core kind."""
    performance = cpu_ranges("/sys/devices/cpu_core/cpus")
    efficiency = cpu_ranges("/sys/devices/cpu_atom/cpus")
    result = []
    for name in sorted((n for n in after if n != "cpu" and n in before), key=lambda n: int(n[3:])):
        cpu = int(name[3:])
        base = Path(f"/sys/devices/system/cpu/{name}")
        khz = read_int(base / "cpufreq/scaling_cur_freq")
        result.append({
            "id": cpu,
            "core": read_int(base / "topology/core_id"),
            "kind": "performance" if cpu in performance else "efficiency" if cpu in efficiency else None,
            "usage_percent": busy(before[name], after[name]),
            "mhz": round(khz / 1000) if khz else None,
        })
    return result


def rc6_cards():
    """i915 cards and their RC6 residency counters."""
    cards = {}
    for counter in sorted(Path("/sys/class/drm").glob("card[0-9]*/gt/gt0/rc6_residency_ms")):
        card = counter.parents[2]
        cards[card.name] = (card, counter)
    return cards


def read_int(path):
    try:
        return int(Path(path).read_text().strip(), 0)
    except (OSError, ValueError):
        return None


def cpu_temperature():
    """Package temperature in °C from coretemp (Intel) or k10temp (AMD)."""
    for hwmon in Path("/sys/class/hwmon").glob("hwmon*"):
        try:
            name = (hwmon / "name").read_text().strip()
        except OSError:
            continue
        if name not in ("coretemp", "k10temp", "zenpower"):
            continue
        labels = {}
        for label in hwmon.glob("temp*_label"):
            labels[label.read_text().strip()] = label.name.removesuffix("_label")
        sensor = next((labels[k] for k in ("Package id 0", "Tctl", "Tdie") if k in labels), "temp1")
        value = read_int(hwmon / f"{sensor}_input")
        if value is not None:
            return round(value / 1000, 1)
    return None


@cache
def pci_name(device):
    try:
        out = subprocess.run(["lspci", "-s", device.name, "-mm"], capture_output=True, text=True, timeout=2).stdout
        fields = [f for f in shlex.split(out) if not f.startswith("-")]
        # Slot, class, vendor, device: prefer the marketing name in brackets ("GeForce RTX 4060 ...").
        return fields[3].split("[")[-1].rstrip("]") if len(fields) > 3 else device.name
    except (OSError, subprocess.SubprocessError):
        return device.name


def nvidia_gpus():
    gpus = []
    for device in sorted(Path("/sys/bus/pci/devices").iterdir()):
        if read_int(device / "vendor") != 0x10DE or not (read_int(device / "class") or 0) >> 16 == 0x03:
            continue
        driver = os.path.basename(os.readlink(device / "driver")) if (device / "driver").exists() else None
        gpu = {"name": pci_name(device), "kind": "discrete", "address": device.name}
        if driver == "vfio-pci":
            gpu["state"] = "windows"
        elif driver != "nvidia":
            gpu["state"] = "off"
        elif (device / "power/runtime_status").read_text().strip() == "suspended":
            gpu["state"] = "asleep"
        else:
            gpu["state"] = "active"
            if shutil.which("nvidia-smi"):
                out = subprocess.run(
                    ["nvidia-smi", f"--id={device.name}", "--query-gpu=utilization.gpu,temperature.gpu",
                     "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=5).stdout
                try:
                    usage, temperature = (float(v) for v in out.strip().split(","))
                    gpu["usage_percent"], gpu["temperature_c"] = usage, temperature
                except ValueError:
                    pass
        gpus.append(gpu)
    return gpus


def memory():
    info = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, value = line.split(":", 1)
        info[key] = int(value.split()[0]) * 1024
    return (
        {"used_bytes": info["MemTotal"] - info["MemAvailable"], "total_bytes": info["MemTotal"]},
        {"used_bytes": info["SwapTotal"] - info["SwapFree"], "total_bytes": info["SwapTotal"]},
    )


def disk(path):
    stat = os.statvfs(path)
    total = stat.f_blocks * stat.f_frsize
    return {"path": path, "used_bytes": total - stat.f_bfree * stat.f_frsize, "total_bytes": total}


def network_counters():
    """(received, sent) bytes so far over the physical network interfaces."""
    received = sent = 0
    for iface in Path("/sys/class/net").iterdir():
        if (iface / "device").exists():
            received += read_int(iface / "statistics/rx_bytes") or 0
            sent += read_int(iface / "statistics/tx_bytes") or 0
    return received, sent


class Interval:
    """Machine-wide counters read when it starts and again at end(), giving the CPU, integrated-GPU
    and network use in between."""

    def __init__(self):
        self.cards = rc6_cards()
        self.cpu_before = cpu_times()
        self.rc6 = {name: read_int(counter) for name, (_, counter) in self.cards.items()}
        self.network_before = network_counters()
        self.start = time.monotonic()

    def end(self):
        self.elapsed = time.monotonic() - self.start
        self.cpu_after = cpu_times()
        self.gpus = []
        for name, (card, counter) in self.cards.items():
            after = read_int(counter)
            if self.rc6[name] is None or after is None:
                continue
            load = max(0.0, min(100.0, 100 * (1 - (after - self.rc6[name]) / (self.elapsed * 1000))))
            self.gpus.append({"name": pci_name((card / "device").resolve()), "kind": "integrated",
                              "state": "active", "usage_percent": round(load, 1)})
        received, sent = network_counters()
        self.network = {
            "received_bytes_per_second": round(max(0, received - self.network_before[0]) / self.elapsed),
            "sent_bytes_per_second": round(max(0, sent - self.network_before[1]) / self.elapsed),
        }
        self.cpu_percent = busy(self.cpu_before["cpu"], self.cpu_after["cpu"])


def proc_sample():
    """{pid: (start, ticks)}: each process's start time and the CPU ticks it has used, from /proc/PID/stat."""
    sample = {}
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        try:
            with open(f"/proc/{entry.name}/stat") as f:
                fields = f.read().rpartition(")")[2].split()
        except OSError:
            continue
        # After the name: state is fields[0], ppid fields[1], utime fields[11], stime fields[12], starttime fields[19].
        sample[int(entry.name)] = (int(fields[19]), int(fields[11]) + int(fields[12]), int(fields[1]))
    return sample


def status(pid):
    """The fields of /proc/PID/status that describe a process."""
    values = {}
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            key, _, value = line.partition(":")
            if key in ("Name", "State", "PPid", "Uid", "Threads", "VmRSS", "RssAnon", "Kthread"):
                values[key] = value.strip()
    return values


def unit_of(pid):
    """The systemd unit that owns the process (its cgroup's last scope or service), or None."""
    try:
        path = Path(f"/proc/{pid}/cgroup").read_text().strip().rpartition("::")[2]
    except OSError:
        return None
    for part in reversed(path.split("/")):
        if part.endswith((".scope", ".service")):
            return part.encode().decode("unicode_escape")
    return None


class DesktopEntries:
    """Names and icons of installed applications, looked up by desktop file id."""

    def __init__(self):
        dirs = [os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))]
        dirs += os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":")
        self.dirs = [Path(d) / "applications" for d in dirs if d]
        self.cache = {}

    def __call__(self, desktop_id):
        if desktop_id not in self.cache:
            self.cache[desktop_id] = self.read(desktop_id)
        return self.cache[desktop_id]

    def read(self, desktop_id):
        for directory in self.dirs:
            path = directory / f"{desktop_id}.desktop"
            try:
                text = path.read_text(errors="replace")
            except OSError:
                continue
            entry = {}
            section = None
            for line in text.splitlines():
                if line.startswith("["):
                    section = line.strip()
                elif section == "[Desktop Entry]" and "=" in line:
                    key, _, value = line.partition("=")
                    entry.setdefault(key.strip(), value.strip())
            return entry.get("Name"), entry.get("Icon")
        return None, None


def group_of(unit, name, entries):
    """(key, name, icon, kind) of the app or service a process belongs to.

    Apps launched from Plasma run in app-<desktop id>-<n>.scope or app-<desktop id>@<id>.service,
    so all of one app's processes (a browser and its renderers) share one desktop id.
    """
    if unit is None:
        return "process:" + name, name, None, "system"
    stem = unit.rpartition(".")[0]
    if stem.startswith("app-"):
        desktop_id = re.sub(r"(@.*|-\d+)$", "", stem[4:])
        title, icon = entries(desktop_id)
        return "app:" + desktop_id, title or desktop_id.rpartition(".")[2] or desktop_id, icon, "app"
    if stem.startswith("machine-qemu-"):
        return "unit:" + unit, "Virtual machine " + re.sub(r"^machine-qemu-\d+-", "", stem), "computer", "service"
    kind = "session" if unit.startswith(("plasma-", "session-")) or "@" in unit else "service"
    return "unit:" + unit, stem, None, kind


def processes(before, after, elapsed, top=None, sort="cpu"):
    """Every user-space process with its share of the whole machine's CPU over the interval and its
    private memory, sorted by sort; with top, only the busiest that many."""
    cpus = os.cpu_count() or 1
    own_uid = os.getuid()
    users = {}
    result = []
    for pid, (start, ticks, ppid) in after.items():
        if pid in (0, 2) or ppid == 2:
            continue  # kernel threads
        try:
            info = status(pid)
            command = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
        except OSError:
            continue  # exited meanwhile
        if info.get("Kthread") == "1":
            continue
        uid = int(info.get("Uid", "0").split()[0])
        if uid not in users:
            try:
                users[uid] = pwd.getpwuid(uid).pw_name
            except KeyError:
                users[uid] = str(uid)
        earlier = before.get(pid)
        used = ticks - earlier[1] if earlier and earlier[0] == start else 0
        rss_anon = info.get("RssAnon", "0 kB").split()[0]
        name = info.get("Name", str(pid))
        result.append({
            "pid": pid,
            "start": start,
            "ppid": ppid,
            "name": name,
            "command": command or f"[{name}]",
            "user": users[uid],
            "own": uid == own_uid,
            "critical": pid == 1 or name in CRITICAL,
            "cpu_percent": round(100 * used / TICKS / elapsed / cpus, 1) if elapsed > 0 else 0.0,
            "memory_bytes": int(rss_anon) * 1024,
        })
    result.sort(key=sort_key(sort))
    return result[:top] if top else result


def sort_key(sort):
    if sort == "user":
        # root first, then the other users alphabetically; within a user the busiest first.
        return lambda p: (p["user"] != "root", p["user"].lower(), -p["cpu_percent"], p["name"].lower())
    if sort == "name":
        return lambda p: (p["name"].lower(), p.get("pid", 0))
    field = "cpu_percent" if sort == "cpu" else "memory_bytes"
    return lambda p: (-p[field], p["name"].lower())


def grouped(procs, sort):
    """Processes gathered under the app or service owning them, each group with its totals."""
    entries = DesktopEntries()
    groups = {}
    for proc in procs:
        key, name, icon, kind = group_of(unit_of(proc["pid"]), proc["name"], entries)
        group = groups.setdefault(key, {"id": key, "name": name, "icon": icon, "kind": kind,
                                        "user": proc["user"], "cpu_percent": 0.0, "memory_bytes": 0, "own": True,
                                        "critical": False, "processes": []})
        group["cpu_percent"] = round(group["cpu_percent"] + proc["cpu_percent"], 1)
        group["memory_bytes"] += proc["memory_bytes"]
        group["own"] = group["own"] and proc["own"]
        group["critical"] = group["critical"] or proc["critical"]
        group["processes"].append(proc)
    result = sorted(groups.values(), key=sort_key(sort))
    for group in result:
        group["processes"].sort(key=sort_key(sort))
    return result


def measure_processes(interval, sort, flat):
    window = Interval()
    before = proc_sample()
    time.sleep(interval)
    after = proc_sample()
    window.end()
    procs = processes(before, after, window.elapsed, sort=sort)
    ram, swap = memory()
    out = {
        "cpus": os.cpu_count(),
        "memory_total_bytes": ram["total_bytes"],
        "sort": sort,
        "machine": {
            "cpu_percent": window.cpu_percent,
            "memory": ram,
            "swap": swap,
            "gpus": window.gpus + nvidia_gpus(),
            "network": window.network,
        },
    }
    if flat:
        out["processes"] = procs
    else:
        out["groups"] = grouped(procs, sort)
    return out


def start_time(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return int(f.read().rpartition(")")[2].split()[19])
    except (OSError, IndexError, ValueError):
        return None


def send(targets, sig, wait):
    """Signal each PID:START, through a pidfd so a recycled PID is never hit, then wait for exits."""
    results, pending = [], {}
    for target in targets:
        pid_text, _, start_text = target.partition(":")
        pid = int(pid_text)
        entry = {"pid": pid, "signal": sig.name, "sent": False, "exited": False}
        results.append(entry)
        try:
            fd = os.pidfd_open(pid)
        except ProcessLookupError:
            entry["exited"], entry["error"] = True, "no such process"
            continue
        except OSError as err:
            entry["error"] = err.strerror
            continue
        if start_text and start_time(pid) != int(start_text):
            os.close(fd)
            entry["exited"], entry["error"] = True, "process already exited (its PID was reused)"
            continue
        try:
            signals.pidfd_send_signal(fd, sig)
            entry["sent"] = True
            pending[fd] = entry
        except OSError as err:
            entry["error"] = "permission denied" if err.errno == 1 else err.strerror
            os.close(fd)
    deadline = time.monotonic() + wait
    while pending:
        # A pidfd turns readable when its process exits.
        ready, _, _ = select.select(list(pending), [], [], max(0.0, deadline - time.monotonic()))
        for fd in ready:
            pending.pop(fd)["exited"] = True
            os.close(fd)
        if not ready:
            break
    for fd in pending:
        os.close(fd)
    return results


def link(path):
    try:
        return os.readlink(path)
    except OSError:
        return None  # another user's process, or gone


def boot_time():
    for line in Path("/proc/stat").read_text().splitlines():
        if line.startswith("btime "):
            return int(line.split()[1])
    raise RuntimeError("/proc/stat has no btime")


def details(target):
    """Everything worth knowing about one PID[:START], or an error when it has gone."""
    pid, _, start = target.partition(":")
    pid = int(pid)
    started = start_time(pid)
    if started is None or (start and started != int(start)):
        return {"pid": pid, "error": "no such process"}
    try:
        info = status(pid)
        command = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
    except OSError:
        return {"pid": pid, "error": "no such process"}
    ppid = int(info.get("PPid", "0"))
    try:
        parent = status(ppid).get("Name") if ppid else None
    except OSError:
        parent = None
    uid = int(info.get("Uid", "0").split()[0])
    try:
        user = pwd.getpwuid(uid).pw_name
    except KeyError:
        user = str(uid)
    return {
        "pid": pid,
        "name": info.get("Name", str(pid)),
        "command": command,
        "executable": link(f"/proc/{pid}/exe"),
        "working_directory": link(f"/proc/{pid}/cwd"),
        "ppid": ppid,
        "parent": parent,
        "user": user,
        "unit": unit_of(pid),
        "started": time.strftime("%Y-%m-%d %H:%M:%S %z", time.localtime(boot_time() + started / TICKS)),
        "state": info.get("State"),
        "threads": int(info.get("Threads", "0")),
        "memory_bytes": int(info.get("RssAnon", "0 kB").split()[0]) * 1024,
        "resident_bytes": int(info.get("VmRSS", "0 kB").split()[0]) * 1024,
    }


def details_text(item):
    if "error" in item:
        return f"PID {item['pid']}: {item['error']}"
    fields = [
        ("Command", item["command"]),
        ("Executable", item["executable"]),
        ("Working directory", item["working_directory"]),
        ("Parent", f"{item['parent']} (PID {item['ppid']})" if item["parent"] else None),
        ("User", item["user"]),
        ("Systemd unit", item["unit"]),
        ("Started", item["started"]),
        ("State", item["state"]),
        ("Threads", item["threads"]),
        ("Memory", f"{item['memory_bytes'] // 1048576} MiB private, {item['resident_bytes'] // 1048576} MiB resident"),
    ]
    lines = [f"{item['name']} (PID {item['pid']})"]
    lines += [f"  {label}: {value}" for label, value in fields if value]
    return "\n".join(lines)


# The places a process is shown, for readers of copied details who have never seen them.
VIEWS = {
    "apps": "the process window's Apps view, which groups processes by the app or service that owns them",
    "all": "the process window's All processes view, a flat list of every process",
    "busiest": "the Busiest processes list on the stats card, the top CPU users at 1% or more",
}


def details_source(view, row, count):
    """What a reader without Spawnkit's context needs to know about pasted details."""
    copied = time.strftime("%Y-%m-%d %H:%M:%S %Z")
    lines = [
        f"Source: Spawnkit's process manager, part of the KDE Plasma panel stats widget on {os.uname().nodename}, copied {copied}.",
        f"Viewed in: {VIEWS[view]}.",
    ]
    if row:
        lines.append(f"Row: {row}" + (f" ({count} processes, all listed below)" if count > 1 else ""))
    lines.append("Live data: `spawnkit-stats processes` lists every process as JSON and `spawnkit-stats details PID` "
                 "describes one. These PIDs may have exited since.")
    return "\n".join(lines)


def load(interval):
    before = cpu_times()
    time.sleep(interval)
    return {"usage_percent": busy(before["cpu"], cpu_times()["cpu"])}


def snapshot(interval, disk_path, top=0):
    procs0 = proc_sample() if top else None
    window = Interval()
    time.sleep(interval)
    window.end()
    procs1 = proc_sample() if top else None
    ram, swap = memory()
    result = {
        "cpu": {
            "usage_percent": window.cpu_percent,
            "temperature_c": cpu_temperature(),
            "cores": os.cpu_count(),
            "threads": threads(window.cpu_before, window.cpu_after),
        },
        "gpus": window.gpus + nvidia_gpus(),
        "memory": ram,
        "swap": swap,
        "disk": disk(disk_path),
        "network": window.network,
    }
    if top:
        result["processes"] = processes(procs0, procs1, window.elapsed, top=top)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--interval", type=float, default=0.5, help="Seconds over which CPU and GPU load are measured")
    parser.add_argument("--disk", default="/", help="Filesystem whose space is reported")
    parser.add_argument("--top", type=int, default=0, help="Also list this many of the busiest processes")
    commands = parser.add_subparsers(dest="command")
    listing = commands.add_parser("processes", help="List every process, grouped by app or service")
    listing.add_argument("--interval", type=float, default=0.5, help="Seconds over which CPU use is measured")
    listing.add_argument("--sort", choices=("cpu", "memory", "name", "user"), default="cpu")
    listing.add_argument("--flat", action="store_true", help="One list of processes instead of groups")
    ending = commands.add_parser("signal", help="End processes; exits 1 unless every one exited")
    ending.add_argument("targets", nargs="+", metavar="PID[:START]",
                        help="START (from the listing) guards against a reused PID")
    kind = ending.add_mutually_exclusive_group(required=True)
    kind.add_argument("--term", dest="sig", action="store_const", const=signals.SIGTERM, help="Ask to exit (SIGTERM)")
    kind.add_argument("--kill", dest="sig", action="store_const", const=signals.SIGKILL, help="Force exit (SIGKILL)")
    ending.add_argument("--wait", type=float, default=3, help="Seconds to wait for the processes to exit")
    describing = commands.add_parser("details", help="Describe processes")
    describing.add_argument("targets", nargs="+", metavar="PID[:START]",
                            help="START (from the listing) guards against a reused PID")
    describing.add_argument("--text", action="store_true", help="Text to paste elsewhere, instead of JSON")
    describing.add_argument("--view", choices=VIEWS, help="With --text, open with this view as the source")
    describing.add_argument("--row", help="With --view, the row it was copied from")
    gauge = commands.add_parser("load", help="Overall CPU use alone")
    gauge.add_argument("--interval", type=float, default=1, help="Seconds over which CPU use is measured")
    args = parser.parse_args()
    if args.command in ("signal", "details") and not all(re.fullmatch(r"\d+(:\d+)?", t) for t in args.targets):
        parser.error("targets are PID or PID:START")
    if args.command == "processes":
        print(json.dumps(measure_processes(args.interval, args.sort, args.flat)))
    elif args.command == "signal":
        results = send(args.targets, args.sig, args.wait)
        print(json.dumps({"results": results}))
        sys.exit(0 if all(r["exited"] for r in results) else 1)
    elif args.command == "details":
        items = [details(t) for t in args.targets]
        if args.text:
            source = [details_source(args.view, args.row, len(items))] if args.view else []
            print("\n\n".join(source + [details_text(item) for item in items]))
        else:
            print(json.dumps({"processes": items}))
    elif args.command == "load":
        print(json.dumps(load(args.interval)))
    else:
        print(json.dumps(snapshot(args.interval, args.disk, args.top)))


if __name__ == "__main__":
    main()
