"""Finds paired Bluetooth devices whose pairing changed on the device's side, and re-pairs them.

Some devices take a new address each time they pair again: a Logitech mouse does whenever one
of its channel buttons pairs. The old bond then never connects, and the device, advertising for
pairing at its new address, is not listed among the paired ones. A stale pairing is a paired,
disconnected device with an unpaired device beside it that advertises for pairing under the same
name and appearance.

  spawnkit-bluetooth stale [--scan SECONDS]     JSON list of {address, name, replacement}
  spawnkit-bluetooth repair OLD [NEW]           pairs NEW (found when omitted), then forgets OLD
"""

import argparse
import asyncio
import json
import sys

from dbus_next import BusType, Variant
from dbus_next.aio import MessageBus

BLUEZ = "org.bluez"
DEVICE = "org.bluez.Device1"
ADAPTER = "org.bluez.Adapter1"
# AdvertisingFlags bits for LE limited and general discoverable mode: the device is pairing.
DISCOVERABLE = 0x01 | 0x02


async def objects(bus):
    introspection = await bus.introspect(BLUEZ, "/")
    root = bus.get_proxy_object(BLUEZ, "/", introspection)
    manager = root.get_interface("org.freedesktop.DBus.ObjectManager")
    return await manager.call_get_managed_objects()


def value(props, key, default=None):
    item = props.get(key)
    return item.value if item is not None else default


def devices(managed):
    return {path: ifaces[DEVICE] for path, ifaces in managed.items() if DEVICE in ifaces}


def pairing(props):
    flags = bytes(value(props, "AdvertisingFlags", b""))
    return not value(props, "Paired", False) and any(f & DISCOVERABLE for f in flags)


def stale(managed):
    found = devices(managed)
    result = []
    for path, old in found.items():
        name = value(old, "Name")
        if not name or not value(old, "Paired", False) or value(old, "Connected", False):
            continue
        for new in found.values():
            if (
                pairing(new)
                and value(new, "Name") == name
                and value(new, "Adapter") == value(old, "Adapter")
                and value(new, "Appearance") == value(old, "Appearance")
            ):
                result.append({
                    "address": value(old, "Address"),
                    "name": name,
                    "replacement": value(new, "Address"),
                })
                break
    return result


async def interface(bus, path, name):
    introspection = await bus.introspect(BLUEZ, path)
    return bus.get_proxy_object(BLUEZ, path, introspection).get_interface(name)


async def scan(bus, seconds):
    """Discovers for a while, so that a device advertising for pairing is known to BlueZ."""
    if seconds <= 0:
        return
    managed = await objects(bus)
    adapters = [path for path, ifaces in managed.items() if ADAPTER in ifaces and value(ifaces[ADAPTER], "Powered", False)]
    started = []
    for path in adapters:
        adapter = await interface(bus, path, ADAPTER)
        try:
            await adapter.call_set_discovery_filter({"Transport": Variant("s", "le")})
            await adapter.call_start_discovery()
            started.append(adapter)
        except Exception:  # already discovering, or the adapter is busy: what is known suffices
            pass
    await asyncio.sleep(seconds)
    for adapter in started:
        try:
            await adapter.call_stop_discovery()
        except Exception:
            pass


def path_of(managed, address):
    for path, props in devices(managed).items():
        if value(props, "Address", "").upper() == address.upper():
            return path, props
    return None, None


async def repair(bus, old, new, seconds):
    managed = await objects(bus)
    old_path, old_props = path_of(managed, old)
    if old_path is None:
        raise SystemExit(f"no device {old}")
    if new is None or path_of(managed, new)[0] is None:
        await scan(bus, seconds)
        managed = await objects(bus)
    if new is None:
        match = next((s for s in stale(managed) if s["address"].upper() == old.upper()), None)
        if match is None:
            raise SystemExit(f"{old}: no device is pairing under its name; put it in pairing mode")
        new = match["replacement"]
    new_path, _ = path_of(managed, new)
    if new_path is None:
        raise SystemExit(f"no device {new}; put it in pairing mode")

    device = await interface(bus, new_path, DEVICE)
    props = await interface(bus, new_path, "org.freedesktop.DBus.Properties")
    await device.call_pair()
    await props.call_set(DEVICE, "Trusted", Variant("b", True))
    await device.call_connect()
    # Only once the new pairing works does the old one go.
    adapter = await interface(bus, value(old_props, "Adapter"), ADAPTER)
    await adapter.call_remove_device(old_path)
    return {"name": value(old_props, "Name"), "removed": old, "paired": new, "connected": True}


async def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    stale_parser = commands.add_parser("stale", help="paired devices that now pair at another address")
    stale_parser.add_argument("--scan", type=float, default=0, metavar="SECONDS", help="discover for this long first")
    repair_parser = commands.add_parser("repair", help="pair the device's new address, then forget the old one")
    repair_parser.add_argument("old")
    repair_parser.add_argument("new", nargs="?")
    repair_parser.add_argument("--scan", type=float, default=8, metavar="SECONDS", help="how long to look for the new address")
    args = parser.parse_args()

    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    try:
        if args.command == "stale":
            await scan(bus, args.scan)
            result = stale(await objects(bus))
        else:
            result = await repair(bus, args.old, args.new, args.scan)
    except SystemExit as error:
        print(json.dumps({"error": str(error)}))
        return 1
    except Exception as error:  # a D-Bus failure, such as a rejected pairing
        print(json.dumps({"error": getattr(error, "text", None) or str(error)}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
