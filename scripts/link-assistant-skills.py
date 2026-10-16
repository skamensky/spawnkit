#!/usr/bin/env python3
"""Link personal skills discovered in the canonical checkout, preserving other skills."""

import argparse
from pathlib import Path


ASSISTANTS = ("claude", "codex")


def link_skills(source: Path, home: Path, dry_run: bool = False) -> list[str]:
    source = source.resolve()
    if not source.is_dir():
        raise RuntimeError(f"Canonical skill directory is missing: {source}")
    names = {
        entry.name
        for entry in source.iterdir()
        if not entry.name.startswith(".") and entry.is_dir() and (entry / "SKILL.md").is_file()
    }
    changes = []
    # Inspect both assistants before making any changes. Unrelated directories,
    # plugins and assistant-provided skills are outside our ownership.
    for assistant in ASSISTANTS:
        directory = home / f".{assistant}" / "skills"
        if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
            raise RuntimeError(f"Skills destination must be a real directory: {directory}")
        for name in sorted(names):
            target = directory / name
            if target.is_symlink() and target.resolve() == (source / name).resolve():
                continue
            if target.exists() or target.is_symlink():
                raise RuntimeError(f"Refusing to replace an unmanaged skill: {target}")
            changes.append(("link", target, source / name))
        if directory.exists():
            for target in sorted(directory.iterdir()):
                if target.name.startswith(".") or not target.is_symlink():
                    continue
                resolved = target.resolve()
                if resolved == source / target.name and target.name not in names:
                    changes.append(("unlink", target, None))

    descriptions = []
    for action, target, destination in changes:
        descriptions.append(f"{action}: {target}")
        if dry_run:
            continue
        if action == "link":
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(destination)
        else:
            target.unlink()
    return descriptions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    for change in link_skills(args.source, args.home, args.dry_run):
        print(change)


if __name__ == "__main__":
    main()
