#!/usr/bin/python3
"""Show one of Spawnkit's dialogs and print what the user chose.

Usage: spawnkit-ui.py <dialog> < input.json. The dialog is spawnkit-ui/dialogs/<dialog>.qml, built
from the shared components in spawnkit-ui/Spawnkit so every dialog looks alike and follows the
active Plasma theme through Kirigami. Runs under Ubuntu's Python so PySide6 uses Plasma's own Qt
and its theme plugins. Exit status 0 prints the result as JSON; 1 means the dialog was dismissed.
"""

import json
from pathlib import Path
import sys

from PySide6.QtCore import QObject, Property, Signal, Slot
from PySide6.QtGui import QGuiApplication, QIcon
from PySide6.QtQml import QJSValue, QQmlApplicationEngine

ROOT = Path(__file__).with_name("spawnkit-ui")


class Dialog(QObject):
    """The dialog's input, and the slot that ends it with a result."""

    changed = Signal()

    def __init__(self, data):
        super().__init__()
        self._data = data
        self.result = None

    @Property("QVariant", notify=changed)
    def input(self):
        return self._data

    @Slot("QVariant")
    def finish(self, result):
        self.result = result.toVariant() if isinstance(result, QJSValue) else result
        QGuiApplication.quit()

    @Slot()
    def dismiss(self):
        QGuiApplication.quit()


def main():
    if len(sys.argv) != 2 or not (ROOT / "dialogs" / f"{sys.argv[1]}.qml").is_file():
        raise SystemExit("usage: spawnkit-ui.py <dialog> < input.json; dialogs: "
                         + ", ".join(sorted(p.stem for p in (ROOT / "dialogs").glob("*.qml"))))
    app = QGuiApplication(sys.argv[:1])
    app.setApplicationName("spawnkit")
    app.setApplicationDisplayName("Spawnkit")
    app.setDesktopFileName("spawnkit-windows")
    app.setWindowIcon(QIcon.fromTheme("computer"))
    dialog = Dialog(json.load(sys.stdin))
    engine = QQmlApplicationEngine()
    engine.addImportPath(str(ROOT))
    engine.rootContext().setContextProperty("dialog", dialog)
    engine.load(str(ROOT / "dialogs" / f"{sys.argv[1]}.qml"))
    if not engine.rootObjects():
        raise SystemExit(f"spawnkit-ui: {sys.argv[1]} failed to load")
    app.exec()
    if dialog.result is None:
        sys.exit(1)
    json.dump(dialog.result, sys.stdout)


if __name__ == "__main__":
    main()
