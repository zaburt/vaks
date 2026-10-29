import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts

Item {
    id: page

    property string cfg_sources:       "[]"
    property bool   cfg_notifications: true
    property int    cfg_iconStyle:     0

    // Guard to avoid reloading the model from our own saveSources() write.
    property bool _internalUpdate: false

    ListModel { id: sourcesModel }

    Component.onCompleted: loadFromConfig()

    onCfg_sourcesChanged: {
        if (_internalUpdate) return
        loadFromConfig()
    }

    function loadFromConfig() {
        var arr = []
        try { arr = JSON.parse(cfg_sources) } catch (e) { arr = [] }
        sourcesModel.clear()
        for (var i = 0; i < arr.length; i++) {
            var s = arr[i]
            sourcesModel.append({
                id:    s.id    || ("src-" + Date.now() + "-" + i),
                name:  s.name  || "",
                host:  s.host  || "",
                port:  s.port  || 6283,
                token: s.token || ""
            })
        }
    }

    function saveSources() {
        var arr = []
        for (var i = 0; i < sourcesModel.count; i++) {
            var s = sourcesModel.get(i)
            var entry = { id: s.id, name: s.name, host: s.host, port: s.port }
            if (s.token && s.token !== "") entry.token = s.token
            arr.push(entry)
        }
        _internalUpdate = true
        cfg_sources = JSON.stringify(arr)
        _internalUpdate = false
    }

    implicitHeight: mainColumn.implicitHeight + 32

    ColumnLayout {
        id: mainColumn
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: 16 }
        spacing: 12

        QQC2.CheckBox {
            text: "Show notifications when a job completes or fails"
            checked: page.cfg_notifications
            onToggled: page.cfg_notifications = checked
        }

        RowLayout {
            spacing: 8
            QQC2.Label { text: "Icon style:" }
            QQC2.ComboBox {
                model: ["Bundled", "Follow icon theme"]
                currentIndex: page.cfg_iconStyle
                onActivated: page.cfg_iconStyle = currentIndex
            }
        }

        QQC2.Label { text: "Sources"; font.bold: true; font.pixelSize: 14 }

        Repeater {
            model: sourcesModel
            delegate: RowLayout {
                id: row
                Layout.fillWidth: true
                spacing: 6

                required property int    index
                required property string name
                required property string host
                required property int    port
                required property string token

                QQC2.Label {
                    text: row.name
                    font.bold: true
                }
                QQC2.Label {
                    text: row.host + ":" + row.port
                    opacity: 0.6
                    Layout.fillWidth: true
                }
                QQC2.ToolButton {
                    icon.name: "document-edit"
                    onClicked: {
                        editForm.editIndex = row.index
                        editForm.nameVal   = row.name
                        editForm.hostVal   = row.host
                        editForm.portVal   = row.port
                        editForm.tokenVal  = row.token
                        editForm.visible   = true
                    }
                }
                QQC2.ToolButton {
                    icon.name: "list-remove"
                    onClicked: {
                        sourcesModel.remove(row.index)
                        page.saveSources()
                    }
                }
            }
        }

        QQC2.Button {
            text: "Add source"
            icon.name: "list-add"
            visible: !editForm.visible
            onClicked: {
                editForm.editIndex = -1
                editForm.nameVal   = ""
                editForm.hostVal   = ""
                editForm.portVal   = 6283
                editForm.tokenVal  = ""
                editForm.visible   = true
            }
        }

        ColumnLayout {
            id: editForm
            visible: false
            Layout.fillWidth: true
            spacing: 6

            property int    editIndex: -1
            property string nameVal:  ""
            property string hostVal:  ""
            property int    portVal:  6283
            property string tokenVal: ""

            onVisibleChanged: {
                if (visible) {
                    nameField.text  = editForm.nameVal
                    hostField.text  = editForm.hostVal
                    portField.value = editForm.portVal
                    tokenField.text = editForm.tokenVal
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: "#aaaaaa" }

            QQC2.Label {
                text: editForm.editIndex === -1 ? "Add Source" : "Edit Source"
                font.bold: true
            }

            RowLayout {
                QQC2.Label { text: "Name:"; Layout.preferredWidth: 60 }
                QQC2.TextField { id: nameField; placeholderText: "desk"; Layout.fillWidth: true }
            }
            RowLayout {
                QQC2.Label { text: "Host:"; Layout.preferredWidth: 60 }
                QQC2.TextField { id: hostField; placeholderText: "hostname or IP"; Layout.fillWidth: true }
            }
            RowLayout {
                QQC2.Label { text: "Port:"; Layout.preferredWidth: 60 }
                QQC2.SpinBox {
                    id: portField
                    from: 1024; to: 65535; value: 6283
                    textFromValue: function(val) { return val.toString() }
                    valueFromText: function(text) { return parseInt(text, 10) }
                }
            }
            RowLayout {
                QQC2.Label { text: "Token:"; Layout.preferredWidth: 60 }
                QQC2.TextField { id: tokenField; echoMode: TextInput.Password; placeholderText: "optional"; Layout.fillWidth: true }
            }

            RowLayout {
                QQC2.Button {
                    text: "Save"
                    onClicked: {
                        var entry = {
                            id:    editForm.editIndex === -1
                                   ? ("src-" + Date.now())
                                   : sourcesModel.get(editForm.editIndex).id,
                            name:  nameField.text.trim(),
                            host:  hostField.text.trim(),
                            port:  portField.value,
                            token: tokenField.text.trim()
                        }
                        if (editForm.editIndex === -1) sourcesModel.append(entry)
                        else                           sourcesModel.set(editForm.editIndex, entry)
                        page.saveSources()
                        editForm.visible = false
                    }
                }
                QQC2.Button {
                    text: "Cancel"
                    onClicked: editForm.visible = false
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: "#aaaaaa" }
        }
    }
}
