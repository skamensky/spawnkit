"""spawnkit-stats: one JSON snapshot of the machine's load, for the panel's stats widget and for agents.

CPU (overall and per hardware thread) and integrated-GPU load are measured over --interval seconds. The integrated GPU's load is the
share of that time it spent out of its RC6 sleep state (i915's rc6_residency_ms). A discrete
NVIDIA GPU is reported as held by the Windows VM (bound to vfio-pci), asleep (runtime-suspended,
left asleep rather than woken by a query) or with nvidia-smi's utilisation and temperature.
"""
import argparse
import json
import os
import shlex
import shutil
import subprocess
import time
from pathlib import Path


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


def snapshot(interval, disk_path):
    cards = rc6_cards()
    cpu0 = cpu_times()
    rc60 = {name: read_int(counter) for name, (_, counter) in cards.items()}
    start = time.monotonic()
    time.sleep(interval)
    elapsed_ms = (time.monotonic() - start) * 1000
    cpu1 = cpu_times()
    gpus = []
    for name, (card, counter) in cards.items():
        rc61 = read_int(counter)
        if rc60[name] is None or rc61 is None:
            continue
        load = max(0.0, min(100.0, 100 * (1 - (rc61 - rc60[name]) / elapsed_ms)))
        gpus.append({"name": pci_name((card / "device").resolve()), "kind": "integrated", "state": "active",
                     "usage_percent": round(load, 1)})
    ram, swap = memory()
    return {
        "cpu": {
            "usage_percent": busy(cpu0["cpu"], cpu1["cpu"]),
            "temperature_c": cpu_temperature(),
            "cores": os.cpu_count(),
            "threads": threads(cpu0, cpu1),
        },
        "gpus": gpus + nvidia_gpus(),
        "memory": ram,
        "swap": swap,
        "disk": disk(disk_path),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--interval", type=float, default=0.5, help="Seconds over which CPU and GPU load are measured")
    parser.add_argument("--disk", default="/", help="Filesystem whose space is reported")
    args = parser.parse_args()
    print(json.dumps(snapshot(args.interval, args.disk)))


if __name__ == "__main__":
    main()
