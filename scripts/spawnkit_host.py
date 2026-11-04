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


# Microsoft's generic installation keys: they select an edition but never activate Windows.
WINDOWS_EDITIONS = {
    "Windows 11 Home": "YTMG3-N6DKC-DKB77-7M9GH-8HVX7",
    "Windows 11 Pro": "VK7JG-NPHTM-C97JM-9MPGT-3V66T",
}


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
    for key in ('gpu_devices', 'ssh_listen_addresses', 'base_packages', 'host_packages'):
        if not isinstance(cfg[key], list):
            raise ValueError(f'{key} must be a list')
    for key in ('windows_name', 'looking_glass_name', 'network_name', 'network_bridge', 'windows_disk', 'windows_iso', 'virtio_iso', 'nvidia_driver_package', 'nvidia_prime', 'desktop_session', 'windows_uuid', 'network_uuid', 'windows_mac', 'windows_address', 'windows_share', 'windows_unattend_iso', 'windows_edition', 'windows_computer_name', 'windows_timezone', 'windows_authorized_key', 'windows_display_gpu', 'windows_display_mode'):
        if not isinstance(cfg[key], str):
            raise ValueError(f'{key} must be a string')
    for key in ('base_packages', 'host_packages'):
        if any(not isinstance(v, str) or not re.fullmatch(r'[a-zA-Z0-9+.-]+', v) for v in cfg[key]):
            raise ValueError(f'{key} must contain Ubuntu package names')
    if cfg['nvidia_prime'] not in ('', 'on-demand', 'intel', 'nvidia'):
        raise ValueError('nvidia_prime must be empty, on-demand, intel or nvidia')
    if cfg['nvidia_prime'] and not cfg['nvidia']:
        raise ValueError('nvidia_prime requires nvidia')
    if cfg['desktop_session'] not in ('', 'x11', 'wayland'):
        raise ValueError('desktop_session must be empty, x11 or wayland')
    for key in ("docker", "tailscale", "ssh", "nvidia", "virtualization", "iommu", "gpu_handoff", "windows_vm", "webex", "nix_chrome"):
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
    if cfg["windows_vcpus"] % 2:
        # One socket of two-thread cores: Windows Home uses only one CPU socket.
        raise ValueError("windows_vcpus must be even")
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
    if cfg['windows_mac'] and not re.fullmatch(r'52:54:00(:[0-9a-f]{2}){3}', cfg['windows_mac']):
        raise ValueError('windows_mac must be a lowercase 52:54:00 libvirt address')
    if cfg['windows_address']:
        if not cfg['windows_mac']:
            raise ValueError('windows_address requires windows_mac')
        address = ipaddress.IPv4Address(cfg['windows_address'])
        if address not in net or address in (net.network_address, net.broadcast_address, ipaddress.IPv4Address(cfg['network_address'])):
            raise ValueError('windows_address must be a usable guest address within the declared network')
        if ipaddress.IPv4Address(cfg['network_dhcp_start']) <= address <= ipaddress.IPv4Address(cfg['network_dhcp_end']):
            raise ValueError('windows_address must lie outside the dynamic DHCP range')
    if cfg['windows_edition'] not in WINDOWS_EDITIONS:
        raise ValueError(f"windows_edition must be one of {', '.join(WINDOWS_EDITIONS)}")
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9-]{0,14}', cfg['windows_computer_name']) or cfg['windows_computer_name'].isdigit():
        raise ValueError('windows_computer_name must be a NetBIOS name of at most 15 letters, digits or hyphens')
    if not re.fullmatch(r'[1-9][0-9]{2,4}x[1-9][0-9]{2,4}@[1-9][0-9]{1,2}', cfg['windows_display_mode']):
        raise ValueError('windows_display_mode must look like 2560x1600@60')
    if any(c in cfg['windows_display_gpu'] for c in '<>&"\n\r\x00'):
        raise ValueError('windows_display_gpu must be a plain device name')
    for key in ("windows_disk", "windows_iso", "virtio_iso", "windows_share", "windows_unattend_iso", "windows_authorized_key"):
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


def guest_inventory(cfg, known_hosts, share_owner):
    """Ansible inventory reaching the Windows guest over SSH, its host key pinned in known_hosts.

    SSH connections are multiplexed beside known_hosts, so a run never reuses a master
    connected to an earlier boot of the guest, which hangs.
    """
    return {
        "all": {"hosts": {"windows": {
            "ansible_host": cfg["windows_address"], "ansible_user": cfg["user"],
            "ansible_connection": "ssh", "ansible_shell_type": "powershell",
            "ansible_ssh_common_args": f"-o UserKnownHostsFile={known_hosts} -o StrictHostKeyChecking=yes",
            "ansible_control_path_dir": str(Path(known_hosts).parent),
            "windows_share_uid": share_owner[0], "windows_share_gid": share_owner[1], "cfg": cfg,
        }}}
    }


def bootstrap_settings(cfg, authorized_key):
    net = ipaddress.IPv4Network(f"{cfg['network_address']}/{cfg['network_netmask']}", strict=False)
    return {"authorized_key": authorized_key.strip(), "network": str(net)}


def render_unattend(repo, cfg):
    env = Environment(
        loader=FileSystemLoader(str(repo / "ansible/roles/windows_guest/templates")),
        undefined=StrictUndefined, autoescape=True, keep_trailing_newline=True,
    )
    return env.get_template("autounattend.xml.j2").render(cfg=cfg, product_key=WINDOWS_EDITIONS[cfg["windows_edition"]])


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
