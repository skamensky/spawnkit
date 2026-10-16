"""Shared host configuration, inventory and offline rendering for Spawnkit."""

import importlib.util
import ipaddress
import json
from pathlib import Path
import re
import uuid

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined


def selector():
    spec = importlib.util.spec_from_file_location("home_config", Path(__file__).with_name("home-config.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_config(repo, profile, overrides=None):
    defaults = yaml.safe_load((repo / "hosts/default/system.yml").read_text())
    specific = repo / f"hosts/{profile}/system.yml"
    values = yaml.safe_load(specific.read_text()) if specific.is_file() else {}
    values = values or {}
    if overrides:
        values.update(overrides)
    unknown = values.keys() - defaults.keys()
    if unknown:
        raise ValueError(f"Unknown host settings: {', '.join(sorted(unknown))}")
    cfg = defaults | values
    for key in ('gpu_devices', 'ssh_listen_addresses', 'base_packages'):
        if not isinstance(cfg[key], list):
            raise ValueError(f'{key} must be a list')
    for key in ('windows_name', 'looking_glass_name', 'network_name', 'network_bridge', 'windows_disk', 'windows_iso', 'virtio_iso', 'nvidia_driver_package', 'windows_uuid', 'network_uuid'):
        if not isinstance(cfg[key], str):
            raise ValueError(f'{key} must be a string')
    if any(not isinstance(v, str) or not re.fullmatch(r'[a-zA-Z0-9+.-]+', v) for v in cfg['base_packages']):
        raise ValueError('base_packages must contain Ubuntu package names')
    for key in ("docker", "tailscale", "ssh", "nvidia", "virtualization", "iommu", "gpu_handoff", "windows_vm"):
        if not isinstance(cfg[key], bool):
            raise ValueError(f"{key} must be a boolean")
    if cfg["user"] != "shmuel":
        raise ValueError("The current Home Manager identity is shmuel; do not silently substitute another account")
    for key in ("windows_name", "looking_glass_name", "network_name", "network_bridge"):
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}", cfg[key]):
            raise ValueError(f"Invalid {key}")
    for key in ("windows_memory_mib", "windows_vcpus", "windows_disk_gib", "looking_glass_mib", "ssh_port"):
        if type(cfg[key]) is not int or cfg[key] < 1:
            raise ValueError(f"{key} must be a positive integer")
    if cfg["ssh_port"] > 65535:
        raise ValueError("Invalid SSH port")
    size = cfg["looking_glass_mib"]
    if size & (size - 1):
        raise ValueError("Looking Glass shared memory size must be a power of two")
    for address in cfg["ssh_listen_addresses"]:
        ipaddress.ip_address(address)
    if cfg["ssh"] and not cfg["ssh_listen_addresses"]:
        raise ValueError("SSH requires explicit listener addresses")
    if cfg["windows_video"] not in ("vga", "none"):
        raise ValueError("windows_video must be vga for installation or none after GPU display setup")
    if cfg["windows_vm"] and not (cfg["virtualization"] and cfg["gpu_handoff"]):
        raise ValueError("Windows GPU VM requires virtualization and gpu_handoff")
    if cfg["gpu_handoff"] and not (cfg["virtualization"] and cfg["nvidia"] and cfg["iommu"]):
        raise ValueError("GPU handoff requires virtualization, NVIDIA and IOMMU setup")
    if cfg["gpu_handoff"] and not cfg["gpu_devices"]:
        raise ValueError("Record GPU PCI functions and original drivers from native host-config facts first")
    if len(cfg['network_bridge']) > 15:
        raise ValueError('Linux bridge names must fit 15 characters')
    cfg['network_uuid'] = str(uuid.UUID(cfg['network_uuid']))
    net = ipaddress.IPv4Network(f"{cfg['network_address']}/{cfg['network_netmask']}", strict=False)
    for key in ('network_address', 'network_dhcp_start', 'network_dhcp_end'):
        address = ipaddress.IPv4Address(cfg[key])
        if address not in net or address in (net.network_address, net.broadcast_address):
            raise ValueError(f'{key} must be a usable address within the declared network')
    if not (ipaddress.IPv4Address(cfg['network_dhcp_start']) <= ipaddress.IPv4Address(cfg['network_dhcp_end'])):
        raise ValueError('DHCP range is reversed')
    if ipaddress.IPv4Address(cfg['network_dhcp_start']) <= ipaddress.IPv4Address(cfg['network_address']) <= ipaddress.IPv4Address(cfg['network_dhcp_end']):
        raise ValueError('DHCP range must not include the gateway')
    devices = set()
    for device in cfg["gpu_devices"]:
        if not isinstance(device, dict) or set(device) != {"address", "driver"}:
            raise ValueError("Each GPU function needs exactly address and driver")
        address = device["address"]
        if not isinstance(address, str) or not re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-1][0-9a-f]\.[0-7]", address):
            raise ValueError(f"Invalid PCI address: {address}")
        if address in devices or not re.fullmatch(r"[a-zA-Z0-9_-]+", device["driver"]):
            raise ValueError("Duplicate PCI function or invalid driver")
        devices.add(address)
    if cfg["gpu_handoff"] and not any(d["driver"] == "nvidia" for d in cfg["gpu_devices"]):
        raise ValueError("GPU handoff must include the NVIDIA graphics function")
    for key in ("windows_disk", "windows_iso", "virtio_iso"):
        if cfg[key] and (not Path(cfg[key]).is_absolute() or any(c in cfg[key] for c in "\n\r\x00<>\"'&") or ".." in Path(cfg[key]).parts):
            raise ValueError(f"{key} must be an absolute local path")
    if not cfg['windows_disk'].startswith('/var/lib/libvirt/images/'):
        raise ValueError('Windows disk must live beneath /var/lib/libvirt/images/')
    if not isinstance(cfg["docker_daemon"], dict):
        raise ValueError("docker_daemon must be a mapping")
    if cfg["nvidia_driver_package"] and not re.fullmatch(r"nvidia-driver-[a-zA-Z0-9-]+", cfg["nvidia_driver_package"]):
        raise ValueError("Use an Ubuntu nvidia-driver package name")
    cfg["windows_uuid"] = str(uuid.UUID(cfg["windows_uuid"])) if cfg["windows_uuid"] else str(
        uuid.uuid5(uuid.NAMESPACE_URL, f"https://github.com/skamensky/spawnkit/{profile}/{cfg['windows_name']}")
    )
    return cfg


def inventory(repo, profile, cfg, revision):
    return {
        "all": {"hosts": {"localhost": {
            "ansible_connection": "local",
            "ansible_python_interpreter": "/usr/bin/python3",
            "spawnkit_repo": str(repo), "spawnkit_profile": profile,
            "spawnkit_revision": revision, "cfg": cfg,
        }}}
    }


def render_windows(repo, cfg):
    env = Environment(
        loader=FileSystemLoader(str(repo / "ansible/roles/windows_vm/templates")),
        undefined=StrictUndefined, autoescape=True, keep_trailing_newline=True,
    )
    return env.get_template("windows.xml.j2").render(cfg=cfg)


def read_overrides(filename):
    if not filename:
        return {}
    result = yaml.safe_load(filename.read_text())
    if not isinstance(result, dict):
        raise ValueError("Host override file must contain a mapping")
    return result
