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


def environment():
    if Path("/etc/NIXOS").exists():
        return "nixos"
    if "microsoft" in Path("/proc/sys/kernel/osrelease").read_text().lower():
        return "wsl"
    return "linux"


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
    parser.add_argument("action", choices=["select", "build", "switch", "check", "repos"])
    parser.add_argument("--repo", type=Path, default=Path.home() / "repos/skamensky/nix-config")
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
        catalog = json.loads((repo / "repositories.json").read_text())
        names = json.loads(subprocess.check_output(NIX + ["eval", "--json",
            f"path:{repo}#homeConfigurations.\"{name}\".config.personal.repositories.names"], text=True))
        import importlib.util
        spec = importlib.util.spec_from_file_location("bootstrap", repo / "scripts/bootstrap-repos.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.bootstrap([catalog[n] for n in dict.fromkeys(names)], Path.home(), args.dry_run)
        return
    command = NIX + ["build", "--no-link", "--print-out-paths", reference]
    result = subprocess.check_output(command, text=True).strip()
    if args.action == "build":
        print(result)
    else:
        # Home Manager checks collisions before changing existing dotfiles.
        os.execv(str(Path(result) / "activate"), [str(Path(result) / "activate")])


if __name__ == "__main__":
    main()
