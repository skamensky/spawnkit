#!/usr/bin/python3
"""Show one of Spawnkit's dialogs and talk to it over JSON lines.

Usage: spawnkit-ui.py <dialog> < input.json. The dialog is spawnkit-ui/dialogs/<dialog>.qml, built
from the shared components in spawnkit-ui/Spawnkit so every dialog looks alike and follows the
active Plasma colour scheme through Kirigami. Runs under Ubuntu's Python so PySide6 uses Plasma's
own Qt and its theme plugins.

The first line of stdin is the dialog's input. Every further line is a message delivered to the
dialog's `received` signal, so a caller can keep the window open and report progress. The dialog
prints each message it sends as one JSON line on stdout; `finish` sends a last one and exits 0,
`dismiss` exits 1 without printing.
"""

import json
from pathlib import Path
import sys
import threading

from PySide6.QtCore import QObject, Property, Signal, Slot
from PySide6.QtGui import QGuiApplication, QIcon
from PySide6.QtQml import QJSValue, QQmlApplicationEngine

ROOT = Path(__file__).with_name("spawnkit-ui")


def plain(value):
    return value.toVariant() if isinstance(value, QJSValue) else value


class Dialog(QObject):
    """The dialog's input, the messages it receives, and the slots that answer or end it."""

    changed = Signal()
    received = Signal("QVariant")

    def __init__(self, data):
        super().__init__()
        self._data = data
        self.result = None

    @Property("QVariant", notify=changed)
    def input(self):
        return self._data

    @Slot("QVariant")
    def send(self, message):
        print(json.dumps(plain(message)), flush=True)

    @Slot("QVariant")
    def finish(self, result):
        self.result = plain(result)
        self.send(self.result)
        QGuiApplication.quit()

    @Slot()
    def dismiss(self):
        QGuiApplication.quit()

    @Slot(str)
    def copy(self, text):
        QGuiApplication.clipboard().setText(text)

    @Slot(str, result=bool)
    def hasIcon(self, name):
        return QIcon.hasThemeIcon(name)

    def listen(self, stream):
        """Deliver each further JSON line on stream to the dialog, from a thread so the UI never blocks."""
        def pump():
            for line in stream:
                if line.strip():
                    self.received.emit(json.loads(line))
        threading.Thread(target=pump, daemon=True).start()


def main():
    if len(sys.argv) != 2 or not (ROOT / "dialogs" / f"{sys.argv[1]}.qml").is_file():
        raise SystemExit("usage: spawnkit-ui.py <dialog> < input.json; dialogs: "
                         + ", ".join(sorted(p.stem for p in (ROOT / "dialogs").glob("*.qml"))))
    app = QGuiApplication(sys.argv[:1])
    app.setApplicationName("spawnkit")
    app.setApplicationDisplayName("Spawnkit")
    app.setDesktopFileName("spawnkit-windows")
    app.setWindowIcon(QIcon.fromTheme("computer"))
    dialog = Dialog(json.loads(sys.stdin.readline()))
    engine = QQmlApplicationEngine()
    engine.addImportPath(str(ROOT))
    engine.rootContext().setContextProperty("dialog", dialog)
    engine.load(str(ROOT / "dialogs" / f"{sys.argv[1]}.qml"))
    if not engine.rootObjects():
        raise SystemExit(f"spawnkit-ui: {sys.argv[1]} failed to load")
    dialog.listen(sys.stdin)
    app.exec()
    if dialog.result is None:
        sys.exit(1)


if __name__ == "__main__":
    main()
