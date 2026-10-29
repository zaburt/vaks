import QtQuick
import QtQuick.Window
import org.kde.kirigami as Kirigami

// Shows `name` from the active icon theme when useTheme is set and the theme
// provides it; otherwise falls back to the bundled contents/icons/<name>.svg.
Item {
    id: ic

    property string name: ""
    property bool useTheme: false

    readonly property bool themed: useTheme && name !== "" && themedIcon.valid

    Kirigami.Icon {
        id: themedIcon
        anchors.fill: parent
        source: ic.useTheme ? ic.name : ""
        visible: ic.themed
    }

    Image {
        anchors.fill: parent
        visible: !ic.themed
        source: ic.name !== "" ? Qt.resolvedUrl("../icons/" + ic.name + ".svg") : ""
        sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
        smooth: true
    }
}
