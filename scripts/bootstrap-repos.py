#!/usr/bin/env python3
"""Create missing pinned working copies, preserving every existing checkout."""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile


def validate(entry):
    relative = PurePosixPath(entry["path"])
    if relative.is_absolute() or len(relative.parts) != 2 or any(
        not re.fullmatch(r"[A-Za-z0-9_.-]+", part) or part in {".", ".."}
        for part in relative.parts
    ):
        raise ValueError(f"Expected owner/repository, got {relative}")
    if entry["url"] != f"git@github.com:{relative}.git":
        raise ValueError(f"Unexpected repository URL for {relative}")
    if not re.fullmatch(r"[0-9a-f]{40}", entry["revision"]):
        raise ValueError(f"A full pinned Git commit is required for {relative}")
    subprocess.run(["git", "check-ref-format", "--branch", entry["branch"]],
                   check=True, stdout=subprocess.DEVNULL)


def bootstrap(entries, home, dry_run=False, known_hosts=None):
    for entry in entries:
        validate(entry)
    env = os.environ.copy()
    if known_hosts and "GIT_SSH_COMMAND" not in env:
        # Pinned keys stand in for the global file; the user's own known_hosts still applies.
        env["GIT_SSH_COMMAND"] = f"ssh -o GlobalKnownHostsFile={known_hosts}"
    failed = []
    for entry in entries:
        target = home / "repos" / entry["path"]
        if os.path.lexists(target):
            # .git files are valid: worktrees and submodules must also survive.
            if not (target / ".git").exists():
                raise RuntimeError(f"Refusing to replace non-repository: {target}")
            actual = subprocess.check_output(
                ["git", "-C", str(target), "rev-parse", "--show-toplevel"], text=True
            ).strip()
            if Path(actual).resolve() != target.resolve():
                raise RuntimeError(f"Not a repository root: {target}")
            expected = entry["url"].removesuffix(".git").removeprefix("git@github.com:")
            remote = subprocess.check_output(
                ["git", "-C", str(target), "remote", "get-url", "origin"], text=True
            ).strip().removesuffix(".git")
            if remote not in {f"git@github.com:{expected}", f"https://github.com/{expected}"}:
                raise RuntimeError(f"Origin does not match declared repository: {target}")
            print(f"Preserving existing checkout: {target}")
            continue
        if dry_run:
            print(f"Would clone {entry['path']} at {entry['revision']}")
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        # Clone atomically. A failed clone never leaves a plausible final checkout.
        with tempfile.TemporaryDirectory(prefix=f".{target.name}-", dir=target.parent) as staging:
            clone = Path(staging) / "checkout"
            try:
                subprocess.run(["git", "clone", "--no-checkout", entry["url"], str(clone)], check=True, env=env)
                subprocess.run(["git", "-C", str(clone), "checkout", "-B", entry["branch"], entry["revision"]], check=True)
            except subprocess.CalledProcessError:
                failed.append(entry["path"])
                continue
            clone.rename(target)
        print(f"Created {target} at {entry['revision']}")
    if failed:
        raise RuntimeError(
            f"Could not clone {', '.join(failed)}. Establish GitHub SSH access for this user "
            "(docs/ubuntu-migration.md D2), then rerun the switch; existing checkouts were kept."
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--known-hosts", type=Path)
    args = parser.parse_args()
    bootstrap(json.loads(args.manifest.read_text()), args.home, args.dry_run, args.known_hosts)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError) as error:
        raise SystemExit(f"spawnkit-repos: {error}")
