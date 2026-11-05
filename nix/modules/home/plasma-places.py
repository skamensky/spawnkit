"""Hide entries and sections of KDE's Places (Dolphin's panel and every KDE file dialog).

list                          print the places and sections as JSON, with whether each is hidden
hide [--section S]... [URL]...  hide the places with these URLs and these sections (Recent is
                              "RecentlySaved", Search is "SearchFor"); the rest stay as they are

KIO keeps Places in ~/.local/share/user-places.xbel and reloads it when it changes. A home that
has not opened a file manager yet has no such file; hide then does nothing.
"""
import json
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

PLACES = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "user-places.xbel"
NAMESPACES = {
    "bookmark": "http://www.freedesktop.org/standards/desktop-bookmarks",
    "kdepriv": "http://www.kde.org/kdepriv",
    "mime": "http://www.freedesktop.org/standards/shared-mime-info",
}
KDE = "http://www.kde.org"
for prefix, uri in NAMESPACES.items():
    ET.register_namespace(prefix, uri)


def kde_metadata(element):
    info = element.find("info")
    if info is None:
        info = ET.SubElement(element, "info")
    for metadata in info.findall("metadata"):
        if metadata.get("owner") == KDE:
            return metadata
    return ET.SubElement(info, "metadata", owner=KDE)


def set_flag(metadata, tag):
    flag = metadata.find(tag)
    if flag is None:
        flag = ET.SubElement(metadata, tag)
    changed = flag.text != "true"
    flag.text = "true"
    return changed


def is_true(metadata, tag):
    flag = metadata.find(tag)
    return flag is not None and flag.text == "true"


def main(argv):
    if argv == ["list"]:
        if not PLACES.exists():
            print(json.dumps({"places": [], "sections": {}}))
            return
        root = ET.parse(PLACES).getroot()
        sections = {
            child.tag[len("GroupState-"):-len("-IsHidden")]: child.text == "true"
            for child in kde_metadata(root)
            if child.tag.startswith("GroupState-")
        }
        places = [
            {"url": b.get("href"), "title": b.findtext("title"), "hidden": is_true(kde_metadata(b), "IsHidden")}
            for b in root.findall("bookmark")
        ]
        print(json.dumps({"places": places, "sections": sections}, indent=1))
    elif argv[:1] == ["hide"]:
        sections, urls, rest = [], [], argv[1:]
        while rest:
            if rest[0] == "--section" and len(rest) > 1:
                sections.append(rest[1])
                rest = rest[2:]
            else:
                urls.append(rest.pop(0))
        if not PLACES.exists():
            return
        tree = ET.parse(PLACES)
        root = tree.getroot()
        changed = False
        for section in sections:
            changed |= set_flag(kde_metadata(root), f"GroupState-{section}-IsHidden")
        for bookmark in root.findall("bookmark"):
            if bookmark.get("href") in urls:
                changed |= set_flag(kde_metadata(bookmark), "IsHidden")
        if changed:
            tmp = PLACES.with_suffix(".tmp")
            tree.write(tmp, encoding="UTF-8", xml_declaration=True)
            tmp.replace(PLACES)
    else:
        sys.exit(__doc__)


main(sys.argv[1:])
