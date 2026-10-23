import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import QtQuick.Window
import org.kde.kirigami as Kirigami

// System-tray compact view: video-frame icon + active-job/failed badges.
MouseArea {
    property bool wasExpanded: false
    onPressed: wasExpanded = root.expanded
    onClicked: root.expanded = !wasExpanded

    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property real unit: vertical ? width : height

    Layout.minimumWidth:  vertical ? Kirigami.Units.iconSizes.small : content.implicitWidth
    Layout.minimumHeight: vertical ? content.implicitHeight : Kirigami.Units.iconSizes.small

    GridLayout {
        id: content
        anchors.centerIn: parent
        flow: vertical ? GridLayout.TopToBottom : GridLayout.LeftToRight
        rowSpacing: 0
        columnSpacing: Math.round(unit * 0.12)

    // Full-colour video frame with a progress bar underneath: real progress while encoding
    // (indeterminate sweep when durations are unknown), grey with pause bars when on hold.
    Item {
        id: iconBox
        implicitWidth:  vertical ? unit : unit * 60 / 56
        implicitHeight: vertical ? unit * 56 / 60 : unit

        Image {
            anchors.fill: parent
            source: Qt.resolvedUrl("../icons/" + (root.anyStopped ? "vaks-stopped.svg" : root.totalActive > 0 ? "vaks-encoding.svg" : "vaks.svg"))
            sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
            smooth: true
        }

        Image {
            visible: root.notificationsMuted
            width: parent.height * 0.42
            height: width
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: -height * 0.15
            source: Qt.resolvedUrl("../icons/vaks-muted.svg")
            sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
            smooth: true
        }

        Image {
            visible: root.afterActionIcon !== ""
            height: parent.height * 0.42
            width: height * 28 / 24
            anchors.left: parent.left
            anchors.bottom: track.top
            anchors.bottomMargin: -height * 0.15
            source: root.afterActionIcon !== "" ? Qt.resolvedUrl("../icons/" + root.afterActionIcon) : ""
            sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
            smooth: true
        }

        Item {
            id: track
            x: parent.width * 3 / 64
            y: parent.height * 53 / 64
            width:  parent.width * 58 / 64
            height: parent.height * 6 / 64
            visible: root.totalActive > 0 && !root.anyStopped
            clip: true

            Rectangle {
                id: fill
                height: parent.height
                radius: height / 2
                width:  root.overallProgress >= 0 ? parent.width * root.overallProgress : parent.width * 0.35
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "#fbbf24" }
                    GradientStop { position: 1; color: "#f43f5e" }
                }
                Behavior on width { enabled: root.overallProgress >= 0; NumberAnimation { duration: 400 } }

                SequentialAnimation on x {
                    running: track.visible && root.overallProgress < 0
                    loops: Animation.Infinite
                    NumberAnimation { from: -fill.width; to: track.width; duration: 1400 }
                }
            }
        }
    }

        // Active/queued count, compact but readable
        PlasmaComponents3.Label {
            visible: root.totalJobs > 0
            Layout.alignment: Qt.AlignCenter
            text:  root.totalActive + "/" + root.totalJobs
            color: Kirigami.Theme.textColor
            font.pixelSize: Math.max(9, unit * (vertical ? 0.28 : 0.42))
            font.bold: true
        }

        // Failed-job count — distinct from the active/queued count so failures stand out
        PlasmaComponents3.Label {
            visible: root.totalFailed > 0
            Layout.alignment: Qt.AlignCenter
            text:  "✕" + root.totalFailed
            color: Kirigami.Theme.negativeTextColor
            font.pixelSize: Math.max(9, unit * (vertical ? 0.28 : 0.42))
            font.bold: true
        }
    }
}
