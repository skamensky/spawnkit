#!/usr/bin/env python3
"""Fail on launchers whose Nix app would silently miss the desktop's integration.

Nix apps load only plugins from their own closure, so a missing wrapper does not error: a GTK app
ignores dconf settings (button layout, fonts, dark mode) and a Qt 6 app draws with Fusion instead of
Plasma's style, fonts and file dialogs. This checks every launcher in a Home Manager profile:

  exec    Exec names a /nix/store program that does not exist (TryExec-hidden launchers are skipped)
  gtk     the program links GTK but its wrappers do not add dconf's GIO module
  qt      the program links Nix Qt 6 but its wrappers do not add plasma-integration (plasma-qt.nix)

Programs that bundle their own Qt (Zoom) and names that resolve outside the profile (Ubuntu's own
programs) are not checked. Prints one JSON object per problem with --json, and exits 1 on any.
"""
import argparse
import configparser
import json
import os
import re
import shlex
import sys
from pathlib import Path

STORE = re.compile(rb"/nix/store/[a-z0-9]{32}-[^\s\"'\x00:;$`]+")
QT = ("libQt6Gui.so.6",)
GTK = ("libgtk-3.so.0", "libgtk-4.so.1")
# Chromium, Electron and Python apps load GTK at run time, so their wrappers or run paths name it.
GTK_STORE = re.compile(rb"/nix/store/[a-z0-9]{32}-gtk(\+3|4)-")


def entry(path):
    parser = configparser.RawConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    try:
        parser.read(path, encoding="utf-8")
        return dict(parser["Desktop Entry"])
    except (configparser.Error, KeyError, UnicodeDecodeError):
        return None


def program(exec_line):
    words = shlex.split(exec_line)
    if words and words[0] == "env":
        words.pop(0)
        while words and (words[0].startswith("-") or "=" in words[0]):
            del words[:2 if words[0] == "-u" else 1]
    return words[0] if words else None


def resolve(name, profile):
    if name.startswith("/"):
        return Path(name)
    return profile / "bin" / name


def elf_needed(data):
    """The DT_NEEDED names and run paths of a 64-bit little-endian ELF, or None."""
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return None
    u = lambda off, n: int.from_bytes(data[off:off + n], "little")
    phoff, phentsize, phnum = u(32, 8), u(54, 2), u(56, 2)
    segments = [(u(phoff + i * phentsize, 4), u(phoff + i * phentsize + 8, 8),
                 u(phoff + i * phentsize + 16, 8), u(phoff + i * phentsize + 32, 8))
                for i in range(phnum)]
    dynamic = next((s for s in segments if s[0] == 2), None)
    if not dynamic:
        return [], []
    loads = [s for s in segments if s[0] == 1]

    def offset(vaddr):
        for _, off, start, size in loads:
            if start <= vaddr < start + size:
                return off + vaddr - start
        return None

    tags = []
    pos = dynamic[1]
    while pos + 16 <= len(data):
        tag, value = u(pos, 8), u(pos + 8, 8)
        if tag == 0:
            break
        tags.append((tag, value))
        pos += 16
    strtab = offset(next((v for t, v in tags if t == 5), 0))
    if strtab is None:
        return [], []
    text = lambda at: data[strtab + at:data.index(b"\0", strtab + at)].decode()
    needed = [text(v) for t, v in tags if t == 1]
    paths = [p for t, v in tags if t in (15, 29) for p in text(v).split(":")]
    return needed, paths


def chain(start):
    """The files from a launcher's program through its wrappers to the real executable."""
    files, seen = [], set()
    current = Path(os.path.realpath(start))
    while current not in seen:
        seen.add(current)
        data = current.read_bytes()
        files.append(data)
        found = elf_needed(data)
        if found and any(lib in found[0] for lib in QT + GTK):
            return files, found
        nxt = None
        for match in STORE.findall(data):
            candidate = Path(os.fsdecode(match))
            if (candidate != current and candidate.is_file() and os.access(candidate, os.X_OK)
                    and ("/bin/" in str(candidate) or "-wrapped" in candidate.name)
                    and Path(os.path.realpath(candidate)) not in seen):
                nxt = Path(os.path.realpath(candidate))
                if "-wrapped" in candidate.name or candidate.name.lstrip(".") == current.name.lstrip("."):
                    break
        if not nxt:
            return files, found
        current = nxt
    return files, None


def problems(profile):
    applications = profile / "share/applications"
    for desktop in sorted(applications.glob("*.desktop")):
        fields = entry(desktop)
        if not fields or fields.get("Type", "Application") != "Application" or "Exec" not in fields:
            continue
        try_exec = fields.get("TryExec")
        if try_exec and not resolve(try_exec, profile).exists() and "/" not in try_exec:
            continue
        name = program(fields["Exec"])
        if not name:
            yield {"launcher": desktop.name, "kind": "exec", "detail": "empty Exec"}
            continue
        if name.startswith("/") and not name.startswith("/nix/store/"):
            continue
        target = resolve(name, profile)
        if not target.exists():
            if name.startswith("/nix/store/"):
                yield {"launcher": desktop.name, "kind": "exec", "detail": f"{name} does not exist"}
            continue
        files, found = chain(target)
        needed, paths = found or ([], [])
        text = b"\n".join(files)
        if any(lib in needed for lib in QT) and any("qtbase" in p for p in paths):
            if b"plasma-integration" not in text:
                yield {"launcher": desktop.name, "kind": "qt", "program": name,
                       "detail": "Nix Qt 6 without plasma-integration; wrap it with plasma-qt.nix"}
        if any(lib in needed for lib in GTK) or GTK_STORE.search(text + ":".join(paths).encode()):
            if not re.search(rb"dconf[^\s:;\"']*/lib/gio/modules", text):
                yield {"launcher": desktop.name, "kind": "gtk", "program": name,
                       "detail": "GTK without dconf's GIO module; dconf settings are ignored"}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("profile", type=Path, help="A Home Manager profile (home-path), e.g. ~/.nix-profile")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    found = list(problems(args.profile.resolve()))
    for problem in found:
        if args.json:
            print(json.dumps(problem))
        else:
            print(f"{problem['launcher']}: {problem['kind']}: {problem['detail']}")
    sys.exit(1 if found else 0)


if __name__ == "__main__":
    main()
