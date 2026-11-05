// The right-click menu of a process row.
import QtQuick
import QtQuick.Controls as QQC2

QQC2.Menu {
    id: menu
    property Item copier
    property string targets
    property string label
    property string view

    function show(rowTargets, rowLabel, rowView) {
        targets = rowTargets
        label = rowLabel
        view = rowView
        popup()
    }

    QQC2.MenuItem {
        text: i18n("Copy details")
        icon.name: "edit-copy"
        onTriggered: menu.copier.copy(menu.targets, menu.label, menu.view)
    }
}
