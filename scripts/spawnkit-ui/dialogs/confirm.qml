// A yes-or-no question. Input: {heading, text, confirm, cancel, destructive}.
// Result: {action: "confirm"}.
import QtQuick
import org.kde.kirigami as Kirigami
import Spawnkit

DialogWindow {
    heading: dialog.input.heading
    subtitle: dialog.input.text
    preferredWidth: Kirigami.Units.gridUnit * 26

    actions: [
        ActionButton {
            text: dialog.input.cancel || "Cancel"
            onClicked: dialog.dismiss()
        },
        ActionButton {
            kind: dialog.input.destructive ? "danger" : "primary"
            text: dialog.input.confirm
            onClicked: dialog.finish({action: "confirm"})
        }
    ]
}
