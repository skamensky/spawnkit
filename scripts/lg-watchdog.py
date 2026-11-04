#!/usr/bin/python3
"""Detect a Looking Glass client that stops forwarding input, record the evidence, then end it.

Runs under Ubuntu's Python so ctypes loads Ubuntu's Xlib. While the pointer is over the focused
client and the X server sees input, the client's SPICE inputs channel must send. After focus
returns (by click or Alt+Tab) the client can stop forwarding while it holds the pointer in place;
neither moving the pointer out and back nor toggling capture mode reliably clears that, so a stall
ends the client. Exit status 75 means the client was terminated so the launcher can restart it.
"""

import argparse
import collections
import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

TICK = 0.5
# Seconds of user input over the focused client with no SPICE input traffic.
STALL_SECONDS = 1.5
# A channel that keeps sending while the user is idle streams microphone audio, not input; it stays
# excluded for IDLE_MEMORY seconds after the last such streak of STREAM_TICKS ticks.
IDLE_MEMORY = 120
STREAM_TICKS = 4


class XScreenSaverInfo(ctypes.Structure):
    _fields_ = [("window", ctypes.c_ulong), ("state", ctypes.c_int), ("kind", ctypes.c_int),
                ("til_or_since", ctypes.c_ulong), ("idle", ctypes.c_ulong), ("eventMask", ctypes.c_ulong)]


class X:
    def __init__(self):
        self.x = ctypes.CDLL("libX11.so.6")
        self.xss = ctypes.CDLL("libXss.so.1")
        self.x.XOpenDisplay.restype = ctypes.c_void_p
        self.x.XDefaultRootWindow.restype = ctypes.c_ulong
        self.x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self.x.XInternAtom.restype = ctypes.c_ulong
        self.x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        self.x.XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long, ctypes.c_int, ctypes.c_ulong,
                                              ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong),
                                              ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p)]
        self.x.XFree.argtypes = [ctypes.c_void_p]
        self.x.XGetGeometry.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong)] + [ctypes.POINTER(ctypes.c_int)] * 2 + [ctypes.POINTER(ctypes.c_uint)] * 4
        self.x.XQueryPointer.argtypes = [ctypes.c_void_p, ctypes.c_ulong] + [ctypes.POINTER(ctypes.c_ulong)] * 2 + [ctypes.POINTER(ctypes.c_int)] * 4 + [ctypes.POINTER(ctypes.c_uint)]
        self.xss.XScreenSaverAllocInfo.restype = ctypes.POINTER(XScreenSaverInfo)
        self.xss.XScreenSaverQueryInfo.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(XScreenSaverInfo)]
        self.display = self.x.XOpenDisplay(None)
        if not self.display:
            raise SystemExit("lg-watchdog: cannot open the X display")
        self.root = self.x.XDefaultRootWindow(self.display)
        self.info = self.xss.XScreenSaverAllocInfo()
        self.active = self.x.XInternAtom(self.display, b"_NET_ACTIVE_WINDOW", False)
        self.wm_pid = self.x.XInternAtom(self.display, b"_NET_WM_PID", False)

    def idle_ms(self):
        self.xss.XScreenSaverQueryInfo(self.display, self.root, self.info)
        return self.info.contents.idle

    def _cardinal(self, window, atom):
        kind, fmt, count, after, data = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_void_p()
        if self.x.XGetWindowProperty(self.display, window, atom, 0, 1, False, 0, kind, fmt, count, after, data) != 0 or not data.value:
            return None
        value = ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))[0] if count.value else None
        self.x.XFree(data)
        return value

    def active_window(self):
        return self._cardinal(self.root, self.active)

    def window_pid(self, window):
        return self._cardinal(window, self.wm_pid) if window else None

    def pointer_inside(self, window):
        """Whether the pointer is within the window; the WM's frame, not the client, is the root's child."""
        root, child = ctypes.c_ulong(), ctypes.c_ulong()
        rx, ry, wx, wy = (ctypes.c_int() for _ in range(4))
        mask = ctypes.c_uint()
        if not self.x.XQueryPointer(self.display, window, root, child, rx, ry, wx, wy, mask):
            return False
        groot, gx, gy = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_int()
        width, height, border, depth = (ctypes.c_uint() for _ in range(4))
        self.x.XGetGeometry(self.display, window, groot, gx, gy, width, height, border, depth)
        return 0 <= wx.value < width.value and 0 <= wy.value < height.value


def spice_sent(pid, port):
    """Bytes each of the client's SPICE channels has sent, keyed by local port, without the main channel.

    The main channel is the client's first SPICE socket (lowest descriptor); it carries pings and
    clipboard data, so its traffic says nothing about input.
    """
    out = subprocess.run(["ss", "-tinpH", "dst", f"127.0.0.1:{port}"], capture_output=True, text=True).stdout.splitlines()
    channels = []
    for line, stats in zip(out[::2], out[1::2]):
        if f"pid={pid}," not in line:
            continue
        fd = int(line.split(f"pid={pid},fd=")[1].split(")")[0])
        local = line.split()[3].rsplit(":", 1)[1]
        channels.append((fd, local, next((int(f.split(":")[1]) for f in stats.split() if f.startswith("bytes_sent:")), 0)))
    return {local: sent for _, local, sent in sorted(channels)[1:]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    x = X()
    previous = spice_sent(args.pid, args.port)
    streaks = collections.Counter()
    background = {}
    stalled_since = None
    while os.path.exists(f"/proc/{args.pid}"):
        time.sleep(TICK)
        now = time.monotonic()
        current = spice_sent(args.pid, args.port)
        moved = {k for k, v in current.items() if v > previous.get(k, 0)}
        previous = current
        window = x.active_window()
        focused = x.window_pid(window) == args.pid
        over = focused and x.pointer_inside(window)
        idle = x.idle_ms()
        if idle > 3000:
            streaks = collections.Counter({k: streaks[k] + 1 for k in moved})
            background.update({k: now for k, n in streaks.items() if n >= STREAM_TICKS})
        else:
            streaks.clear()
        background = {k: t for k, t in background.items() if t > now - IDLE_MEMORY}
        if not (over and idle < 1000):
            stalled_since = None
            continue
        if moved - background.keys():
            stalled_since = None
            continue
        stalled_since = stalled_since or now
        if now - stalled_since < STALL_SECONDS:
            continue
        record = {"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "pid": args.pid, "spice_bytes_sent": current,
                  "background_channels": sorted(background), "x_idle_ms": idle}
        args.log.parent.mkdir(parents=True, exist_ok=True)
        with args.log.open("a") as f:
            f.write(json.dumps(record) + "\n")
        subprocess.run(["notify-send", "Looking Glass", "Input stopped reaching Windows; restarting the viewer."], check=False)
        os.kill(args.pid, signal.SIGTERM)
        sys.exit(75)


if __name__ == "__main__":
    main()
