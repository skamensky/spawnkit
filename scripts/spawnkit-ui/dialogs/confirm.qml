// A yes-or-no question. Input: {heading, text, confirm, cancel, destructive}.
// Result: {action: "confirm"}.
import QtQuick
import Spawnkit

DialogWindow {
    id: root
    heading: dialog.input.heading
    subtitle: dialog.input.text
    preferredWidth: 480

    actions: [
        Button {
            text: dialog.input.cancel || "Cancel"
            onClicked: root.reject()
        },
        Button {
            kind: dialog.input.destructive ? "danger" : "primary"
            defaultButton: !dialog.input.destructive
            text: dialog.input.confirm
            onClicked: root.accept({action: "confirm"})
        }
    ]
}
