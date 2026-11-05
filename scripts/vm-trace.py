#!/usr/bin/env python3
"""Record the Windows VM's QEMU and Looking Glass state twice a second.

Each sample is one JSON line: QEMU's anonymous memory, CPU time and memory cgroup
usage, the SPICE sockets' queues, Looking Glass's CPU and memory, and any new
Looking Glass log lines (mouse-motion spam counted, not copied). Run it while
reproducing a freeze; read QEMU's memory through sudo because it runs as
libvirt-qemu.
"""
import argparse
import json
import os
import subprocess
import time
from pathlib import Path

STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "spawnkit"
TICK = os.sysconf("SC_CLK_TCK")


def pid_of(name):
    out = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def proc(pid, sudo):
    if not pid:
        return None
    try:
        status = subprocess.run((["sudo", "-n"] if sudo else []) + ["cat", f"/proc/{pid}/status", f"/proc/{pid}/stat", f"/proc/{pid}/cgroup"], capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError:
        return None
    fields = {line.split(":")[0]: line.split(":", 1)[1].split()[0] for line in status.splitlines() if line.startswith(("VmRSS", "RssAnon", "RssShmem", "VmSwap", "Threads"))}
    stat = next(line for line in status.splitlines() if line.startswith(f"{pid} ("))
    rest = stat.rsplit(")", 1)[1].split()
    cgroup = next((line.split("::", 1)[1] for line in status.splitlines() if line.startswith("0::")), None)
    result = {key: int(value) for key, value in fields.items()}
    result["cpu_s"] = (int(rest[11]) + int(rest[12])) / TICK
    if cgroup:
        base = Path("/sys/fs/cgroup") / cgroup.lstrip("/")
        for parent in (base, base.parent):
            current = parent / "memory.current"
            if current.exists():
                result["cgroup_mb"] = int(current.read_text()) >> 20
                swap = parent / "memory.swap.current"
                result["cgroup_swap_mb"] = int(swap.read_text()) >> 20 if swap.exists() else None
                break
    return result


def spice_sockets(port):
    out = subprocess.run(["ss", "-tnH", "state", "established", f"( sport = :{port} or dport = :{port} )"], capture_output=True, text=True).stdout
    return [{"recv_q": int(cols[0]), "send_q": int(cols[1]), "local": cols[2], "peer": cols[3]} for cols in (line.split() for line in out.splitlines()) if len(cols) >= 4]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=5900)
    parser.add_argument("--out", type=Path, default=STATE / f"vm-trace-{time.strftime('%Y%m%d-%H%M%S')}.jsonl")
    parser.add_argument("--interval", type=float, default=0.5)
    args = parser.parse_args()
    lg_log = STATE / "looking-glass.log"
    offset = lg_log.stat().st_size if lg_log.exists() else 0
    print(f"Recording to {args.out}", flush=True)
    with args.out.open("a") as out:
        while True:
            lines, spam = [], 0
            if lg_log.exists():
                size = lg_log.stat().st_size
                if size < offset:
                    offset = 0
                with lg_log.open("rb") as log:
                    log.seek(offset)
                    for raw in log.read(size - offset).decode(errors="replace").splitlines():
                        if "failed to send mouse motion" in raw:
                            spam += 1
                        else:
                            lines.append(raw[:240])
                offset = size
            sample = {
                "t": round(time.time(), 2),
                "qemu": proc(pid_of("qemu-system-x86"), sudo=True),
                "looking_glass": proc(pid_of("looking-glass-c"), sudo=False),
                "spice": spice_sockets(args.port),
                "lg_log": lines,
                "lg_motion_failures": spam,
            }
            out.write(json.dumps(sample) + "\n")
            out.flush()
            time.sleep(args.interval)


if __name__ == "__main__":
    main()
