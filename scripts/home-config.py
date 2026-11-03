#!/usr/bin/env python3
"""Select a declared host profile, with a minimal default for unknown hosts."""

import argparse
import json
import os
from pathlib import Path
import platform
import socket
import subprocess


NIX = ["nix", "--extra-experimental-features", "nix-command flakes"]
SYSTEMS = {"x86_64": "x86_64-linux", "aarch64": "aarch64-linux"}
GPU_LINK = Path("/etc/tmpfiles.d/non-nixos-gpu.conf")


def default_repo():
    """The Spawnkit checkout containing the working directory, else the canonical checkout."""
    for directory in (Path.cwd(), *Path.cwd().parents):
        if (directory / "flake.nix").is_file() and (directory / "hosts/registry.json").is_file():
            return directory
    return Path.home() / "repos/skamensky/spawnkit"


def environment():
    if Path("/etc/NIXOS").exists():
        return "nixos"
    if "microsoft" in Path("/proc/sys/kernel/osrelease").read_text().lower():
        return "wsl"
    return "linux"


def link_gpu_drivers(generation, enabled=Path("/etc/spawnkit/enabled")):
    """Point /run/opengl-driver at this generation's drivers; GUI apps see no GPU otherwise."""
    setup = Path(generation) / "home-path/bin/non-nixos-gpu-setup"
    if not setup.exists():
        return
    wanted = setup.resolve().parent.parent / "lib/tmpfiles.d/non-nixos-gpu.conf"
    if GPU_LINK.is_symlink() and Path(os.readlink(GPU_LINK)) == wanted:
        return
    if not enabled.exists():
        print(f"Graphics drivers are not linked for this generation; run: sudo {setup}")
        return
    subprocess.run(["sudo", str(setup)], check=True)


def select_profile(registry, hostname, platform_kind, explicit=None):
    if explicit:
        if explicit not in registry:
            raise ValueError(f"Unknown explicit host profile: {explicit}")
        return explicit
    normalized = hostname.lower().split(".", 1)[0]
    for name, settings in registry.items():
        if normalized in settings["hostnames"] and platform_kind in settings["environments"]:
            return name
    return "default"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["select", "build", "switch", "check", "repos", "update-agents"])
    parser.add_argument("--repo", type=Path, default=default_repo(), help="Defaults to the enclosing checkout")
    parser.add_argument("--host", help="Explicit declared profile; unknown hostnames select default automatically")
    parser.add_argument("--hostname", default=socket.gethostname(), help="Override detection for inspection/testing")
    parser.add_argument("--environment", choices=["linux", "wsl", "nixos"], default=environment())
    parser.add_argument("--system", choices=sorted(SYSTEMS.values()), default=SYSTEMS.get(platform.machine()))
    parser.add_argument("--dry-run", action="store_true", help="Only valid with repos")
    args = parser.parse_args()
    if not args.system:
        parser.error(f"Unsupported architecture: {platform.machine()}")
    if args.dry_run and args.action != "repos":
        parser.error("--dry-run is only valid with repos")
    repo = args.repo.resolve()
    registry = json.loads((repo / "hosts/registry.json").read_text())
    try:
        profile = select_profile(registry, args.hostname, args.environment, args.host)
    except ValueError as error:
        parser.error(str(error))
    suffix = "-nixos" if args.environment == "nixos" else ""
    name = f"shmuel@{profile}-{args.system}{suffix}"
    reference = f"path:{repo}#homeConfigurations.\"{name}\".activationPackage"
    if args.action == "select":
        print(name)
        return
    if args.action == "check":
        # Build the entire native matrix and safety tests. Foreign systems are
        # evaluated separately in CI, without requiring cross-compilation here.
        subprocess.run(NIX + ["flake", "check", f"path:{repo}"], check=True)
        subprocess.run(NIX + ["eval", "--json", f"path:{repo}#homeConfigurations", "--apply",
            "configs: builtins.mapAttrs (_: cfg: cfg.activationPackage.drvPath) configs"],
            check=True, stdout=subprocess.DEVNULL)
        return
    if args.action == "repos":
        catalog = json.loads((repo / "config/repositories.json").read_text())
        names = json.loads(subprocess.check_output(NIX + ["eval", "--json",
            f"path:{repo}#homeConfigurations.\"{name}\".config.personal.repositories.names"], text=True))
        import importlib.util
        spec = importlib.util.spec_from_file_location("bootstrap", repo / "scripts/bootstrap-repos.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.bootstrap([catalog[n] for n in dict.fromkeys(names)], Path.home(), args.dry_run)
        return
    if args.action == "update-agents":
        # Moves only the fast-moving assistant CLIs; nixpkgs and the rest stay pinned.
        subprocess.run(NIX + ["flake", "update", "llm-agents", "--flake", f"path:{repo}"], check=True)
    command = NIX + ["build", "--no-link", "--print-out-paths", reference]
    result = subprocess.check_output(command, text=True).strip()
    if args.action == "build":
        print(result)
    elif args.action == "update-agents":
        print(f"Built {result}\nActivate with home-config switch, then commit and push flake.lock.")
    else:
        # Home Manager checks collisions before changing existing dotfiles.
        subprocess.run([str(Path(result) / "activate")], check=True)
        link_gpu_drivers(result)


if __name__ == "__main__":
    main()
