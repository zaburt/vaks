import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasmoid
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

PlasmaExtras.Representation {
    id: fullRep

    implicitWidth:  Kirigami.Units.gridUnit * 26
    implicitHeight: Kirigami.Units.gridUnit * 18

    header: PlasmaExtras.PlasmoidHeading {
        RowLayout {
            anchors.fill: parent

            Kirigami.Icon {
                source: Qt.resolvedUrl("../icons/vaks.svg")
                width:  Kirigami.Units.iconSizes.small
                height: width
            }

            PlasmaExtras.Heading {
                level: 3
                text:  root.anyStopped
                       ? "vaks — on hold"
                       : root.totalActive > 0
                         ? "vaks — " + root.totalActive + " encoding"
                         : "vaks"
                Layout.fillWidth: true
            }

            PlasmaComponents3.ToolButton {
                icon.name: "view-refresh"
                PlasmaComponents3.ToolTip.text:    "Poll now"
                PlasmaComponents3.ToolTip.visible: hovered
                onClicked: {
                    for (var i = 0; i < httpSources.count; i++) {
                        var s = httpSources.itemAt(i)
                        if (s) s.pollStatus()
                    }
                }
            }

            PlasmaComponents3.ToolButton {
                icon.name: root.notificationsMuted ? "notifications-disabled" : "notifications"
                text:      root.notificationsMuted ? "Enable notifications" : "Suspend notifications"
                display:   PlasmaComponents3.AbstractButton.TextBesideIcon
                checkable: true
                checked:   root.notificationsMuted
                PlasmaComponents3.ToolTip.text:    root.notificationsMuted
                                                    ? "Notifications are suspended — vaksd keeps encoding, click to re-enable"
                                                    : "Temporarily suspend widget notifications (vaksd keeps encoding)"
                PlasmaComponents3.ToolTip.visible: hovered
                onToggled: root.notificationsMuted = checked
            }

            PlasmaComponents3.ToolButton {
                icon.name: "chart-line"
                PlasmaComponents3.ToolTip.text:    "History & stats"
                PlasmaComponents3.ToolTip.visible: hovered
                onClicked: historyDialog.open()
            }

            PlasmaComponents3.ToolButton {
                icon.name: "configure"
                PlasmaComponents3.ToolTip.text:    "Settings"
                PlasmaComponents3.ToolTip.visible: hovered
                onClicked: {
                    var act = Plasmoid.internalAction("configure")
                    if (act) act.trigger()
                }
            }
        }
    }

    contentItem: QQC2.ScrollView {
        contentWidth: availableWidth

        ColumnLayout {
            width: parent.width
            spacing: Kirigami.Units.smallSpacing

            Repeater {
                model: root.configuredSources
                SourceCard {
                    Layout.fillWidth: true
                    source:     modelData || null
                    state_:     (modelData && root.sourceStates[modelData.id]) || null
                    httpSource: modelData ? getHttpSource(modelData.id) : null
                }
            }

            PlasmaExtras.PlaceholderMessage {
                Layout.fillWidth: true
                visible:     root.configuredSources.length === 0
                iconName:    "video-x-generic"
                text:        "No sources configured"
                explanation: "Open settings to add a vaks source"
            }

            Item { height: Kirigami.Units.smallSpacing }
        }
    }

    function getHttpSource(id) {
        for (var i = 0; i < httpSources.count; i++) {
            var item = httpSources.itemAt(i)
            if (item && item.srcId === id) return item
        }
        return null
    }

    // History/stats view — total files processed, space saved, and average encode
    // duration, aggregated across all connected sources (and per-source below).
    Kirigami.OverlaySheet {
        id: historyDialog

        header: PlasmaExtras.Heading {
            level: 3
            text:  "History & Stats"
        }

        ColumnLayout {
            spacing: Kirigami.Units.smallSpacing
            Layout.preferredWidth: Kirigami.Units.gridUnit * 20

            QQC2.Label {
                text: "Total processed: " + fullRep.aggTotal
                       + "  •  Failed: " + fullRep.aggFailed
                       + "  •  Space saved: " + fullRep.formatBytes(fullRep.aggSpaceSaved)
            }

            Repeater {
                model: root.configuredSources
                delegate: ColumnLayout {
                    Layout.fillWidth: true
                    required property var modelData
                    readonly property var stats: (root.sourceStates[modelData.id] && root.sourceStates[modelData.id].historyStats) || null

                    Kirigami.Separator { Layout.fillWidth: true }
                    QQC2.Label { text: modelData.name; font.bold: true }
                    QQC2.Label {
                        visible: !!stats
                        text: stats
                              ? ("Processed " + stats.total + " (" + stats.failed + " failed) — saved "
                                 + fullRep.formatBytes(stats.space_saved) + " — avg " + stats.avg_duration.toFixed(1) + "s")
                              : ""
                    }
                    QQC2.Label {
                        visible: !stats
                        opacity: 0.6
                        text: "No history yet"
                    }
                }
            }
        }
    }

    readonly property int aggTotal: {
        var n = 0
        for (var k in root.sourceStates) {
            var s = root.sourceStates[k].historyStats
            if (s) n += s.total
        }
        return n
    }
    readonly property int aggFailed: {
        var n = 0
        for (var k in root.sourceStates) {
            var s = root.sourceStates[k].historyStats
            if (s) n += s.failed
        }
        return n
    }
    readonly property real aggSpaceSaved: {
        var n = 0
        for (var k in root.sourceStates) {
            var s = root.sourceStates[k].historyStats
            if (s) n += s.space_saved
        }
        return n
    }

    function formatBytes(n) {
        var units = ["B", "KB", "MB", "GB", "TB"]
        var i = 0
        var f = n || 0
        while (f >= 1024 && i < units.length - 1) { f /= 1024; i++ }
        return f.toFixed(1) + units[i]
    }
}
