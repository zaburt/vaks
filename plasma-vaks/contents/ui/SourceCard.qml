import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

// Card showing status and controls for one vaks source.
Kirigami.AbstractCard {
    id: card

    property var source:     null  // { id, name, host, port, token }
    property var state_:     null  // runtime state from root.sourceStates
    property var httpSource: null

    readonly property var    st:         state_ || {}
    readonly property var    src:        source || {}
    readonly property var    cfg:        st.vaksConfig || {}
    readonly property int    jobCount:   st.running ? st.running.length : 0
    readonly property bool   online:     st.connected || false
    readonly property var    queueJobs:  st.queueJobs || []
    readonly property var    watchList: {
        var list = (st.watchList || []).slice()
        // Enabled watches first, keeping relative order within each group (#17)
        list.sort(function(a, b) {
            var ea = a.enabled !== false, eb = b.enabled !== false
            if (ea === eb) return 0
            return ea ? -1 : 1
        })
        return list
    }

    readonly property bool   stopped:     st.stopped     || false
    readonly property bool   paused:      st.paused      || false
    readonly property string afterAction: st.afterAction || "none"

    // After-process behaviours selectable from the card (value → label)
    readonly property var afterOptions: [
        { value: "none",                  text: "Do nothing" },
        { value: "shutdown_after_current", text: "Shut down after current job(s)" },
        { value: "shutdown_after_all",     text: "Shut down after everything" },
        { value: "reboot_after_current",   text: "Reboot after current job(s)" },
        { value: "reboot_after_all",       text: "Reboot after everything" }
    ]

    property bool cfgExpanded:          false
    property bool queueExpanded:        false
    property bool watchesExpanded:      false
    property string outputExpandedPath: ""
    property var    outputLines:        []
    property string outputError:        ""
    property bool   pendingIdleShutdown: cfg.idle_shutdown         || false
    property int    pendingIdleTimeout:  cfg.idle_shutdown_timeout || 30
    property int    pendingWorkers:      cfg.workers               || 1

    onCfgChanged: {
        pendingIdleShutdown = cfg.idle_shutdown         || false
        pendingIdleTimeout  = cfg.idle_shutdown_timeout || 30
        pendingWorkers      = cfg.workers               || 1
    }

    // ── Header ────────────────────────────────────────────────────────────
    header: RowLayout {
        spacing: Kirigami.Units.smallSpacing

        // Pulsing dot — blinks when encoding
        Rectangle {
            width: 8; height: 8; radius: 4
            color: online ? Kirigami.Theme.positiveTextColor
                          : Kirigami.Theme.negativeTextColor

            SequentialAnimation on opacity {
                running: online && jobCount > 0
                loops:   Animation.Infinite
                NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
            }
        }

        PlasmaComponents3.Label {
            text:      src.name || ""
            font.bold: true
            elide:     Text.ElideRight
            Layout.fillWidth: true
        }

        PlasmaComponents3.Label {
            text:           (src.host || "") + ":" + (src.port || 6283)
            opacity:        0.5
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        }

        PlasmaComponents3.ToolButton {
            icon.name: "view-list-symbolic"
            checkable: true
            checked:   queueExpanded
            visible:   queueJobs.length > 0
            PlasmaComponents3.ToolTip.text:    "Queue order"
            PlasmaComponents3.ToolTip.visible: hovered
            onToggled: queueExpanded = checked
        }

        PlasmaComponents3.ToolButton {
            icon.name: "folder-open"
            checkable: true
            checked:   watchesExpanded
            visible:   watchList.length > 0
            PlasmaComponents3.ToolTip.text:    "Watched directories"
            PlasmaComponents3.ToolTip.visible: hovered
            onToggled: watchesExpanded = checked
        }

        PlasmaComponents3.ToolButton {
            icon.name: "configure"
            checkable: true
            checked:   cfgExpanded
            PlasmaComponents3.ToolTip.text:    "Daemon settings"
            PlasmaComponents3.ToolTip.visible: hovered
            onToggled: cfgExpanded = checked
        }
    }

    // Tick every second to keep "Xs ago" fresh
    Timer {
        interval: 1000
        running:  true
        repeat:   true
        onTriggered: card.updateAgo()
    }

    property string agoText: ""

    function updateAgo() {
        if (!st.lastUpdated) { agoText = ""; return }
        var secs = Math.round((new Date() - st.lastUpdated) / 1000)
        agoText = secs <= 1 ? "just now" : secs + "s ago"
    }

    onStChanged: updateAgo()

    // ── Content ───────────────────────────────────────────────────────────
    contentItem: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        // ── Offline row ───────────────────────────────────────────────────
        RowLayout {
            visible: !online
            spacing: Kirigami.Units.smallSpacing
            PlasmaComponents3.BusyIndicator {
                width:  Kirigami.Units.iconSizes.small
                height: width
                running: !online
            }
            PlasmaComponents3.Label {
                text:             st.error || "Connecting…"
                color:            st.error ? Kirigami.Theme.negativeTextColor
                                           : Kirigami.Theme.textColor
                font.pixelSize:   Kirigami.Theme.smallFont.pixelSize
                Layout.fillWidth: true
            }
        }

        // Last updated
        PlasmaComponents3.Label {
            visible:          online && agoText !== ""
            text:             "updated " + agoText
            opacity:          0.35
            font.pixelSize:   Kirigami.Theme.smallFont.pixelSize * 0.9
            Layout.alignment: Qt.AlignRight
        }

        // ── Stats row ─────────────────────────────────────────────────────
        RowLayout {
            visible:          online
            spacing:          Kirigami.Units.largeSpacing
            Layout.fillWidth: true

            Kirigami.Icon {
                source: "media-record"
                width:  Kirigami.Units.iconSizes.small
                height: width
            }
            PlasmaComponents3.Label {
                text:  jobCount + " encoding"
                color: jobCount > 0 ? Kirigami.Theme.positiveTextColor
                                    : Kirigami.Theme.textColor
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            }

            Kirigami.Icon {
                source: "view-list-symbolic"
                width:  Kirigami.Units.iconSizes.small
                height: width
            }
            PlasmaComponents3.Label {
                text:           (st.queued || 0) + " queued"
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            }

            Kirigami.Icon {
                source: "folder-open"
                width:  Kirigami.Units.iconSizes.small
                height: width
            }
            PlasmaComponents3.Label {
                text:           (st.watches || 0) + " watching"
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                Layout.fillWidth: true
            }
        }

        // ── Separator before jobs ─────────────────────────────────────────
        Kirigami.Separator {
            visible:          online && jobCount > 0
            Layout.fillWidth: true
        }

        // ── Running jobs ──────────────────────────────────────────────────
        Repeater {
            model: st.running || []

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Icon {
                        source: "media-playback-start"
                        width:  Kirigami.Units.iconSizes.small
                        height: width
                    }
                    PlasmaComponents3.Label {
                        text:             modelData.path ? modelData.path.split("/").pop() : ""
                        elide:            Text.ElideMiddle
                        Layout.fillWidth: true
                    }
                    PlasmaComponents3.Label {
                        visible:        !!modelData.paused
                        text:           "paused"
                        color:          Kirigami.Theme.neutralTextColor
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    }
                    PlasmaComponents3.Label {
                        visible:        card.runningEta(modelData) >= 0
                        text:           "~" + card.formatEta(card.runningEta(modelData)) + " left"
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        opacity:        0.8
                    }
                    PlasmaComponents3.Label {
                        text:           formatElapsed(modelData.elapsed)
                        font.family:    "monospace"
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        opacity:        0.8
                    }
                    PlasmaComponents3.ToolButton {
                        icon.name:  "view-list-text"
                        checkable:  true
                        checked:    card.outputExpandedPath === modelData.path
                        implicitWidth:  Kirigami.Units.iconSizes.small + 8
                        implicitHeight: implicitWidth
                        onClicked: card.toggleOutput(modelData.path)
                        PlasmaComponents3.ToolTip { text: "Show live output" }
                    }
                }

                // realtime output panel (#24)
                ColumnLayout {
                    visible:          card.outputExpandedPath === modelData.path
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing
                    spacing: 2

                    PlasmaComponents3.Label {
                        visible:        !!card.outputError
                        text:           card.outputError
                        color:          Kirigami.Theme.negativeTextColor
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    }

                    QQC2.ScrollView {
                        visible:           !card.outputError
                        Layout.fillWidth:  true
                        Layout.preferredHeight: 120
                        clip: true

                        QQC2.TextArea {
                            readOnly:       true
                            wrapMode:       TextEdit.NoWrap
                            font.family:    "monospace"
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            text:           card.outputExpandedPath === modelData.path ? card.outputLines.join("\n") : ""
                            background: Rectangle {
                                color: Qt.rgba(Kirigami.Theme.textColor.r,
                                               Kirigami.Theme.textColor.g,
                                               Kirigami.Theme.textColor.b, 0.05)
                            }
                        }
                    }
                }

                // fps / speed badges
                RowLayout {
                    Layout.leftMargin: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing
                    spacing:           Kirigami.Units.smallSpacing
                    visible:           !!modelData.fps || !!modelData.speed

                    Rectangle {
                        visible:        !!modelData.fps
                        radius:         3
                        color:          Qt.rgba(Kirigami.Theme.textColor.r,
                                                Kirigami.Theme.textColor.g,
                                                Kirigami.Theme.textColor.b, 0.1)
                        implicitWidth:  fpsLbl.implicitWidth + 8
                        implicitHeight: fpsLbl.implicitHeight + 2
                        PlasmaComponents3.Label {
                            id: fpsLbl
                            anchors.centerIn: parent
                            text:           Math.round(modelData.fps || 0) + " fps"
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            opacity:        0.7
                        }
                    }

                    Rectangle {
                        visible:        !!modelData.speed
                        radius:         3
                        color:          Qt.rgba(Kirigami.Theme.textColor.r,
                                                Kirigami.Theme.textColor.g,
                                                Kirigami.Theme.textColor.b, 0.1)
                        implicitWidth:  spdLbl.implicitWidth + 8
                        implicitHeight: spdLbl.implicitHeight + 2
                        PlasmaComponents3.Label {
                            id: spdLbl
                            anchors.centerIn: parent
                            text:           modelData.speed || ""
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            opacity:        0.7
                        }
                    }
                }
            }
        }

        // ── Total time remaining ──────────────────────────────────────────
        PlasmaComponents3.Label {
            visible: online && etaSummary.secs > 0
            text:    "Remaining ≈ " + formatEta(etaSummary.secs)
                     + (etaSummary.unknown > 0 ? "  (+" + etaSummary.unknown + " unknown)" : "")
            opacity: 0.8
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            PlasmaComponents3.ToolTip.text:    "Estimate: remaining media time ÷ current encode speed, spread over the workers"
            PlasmaComponents3.ToolTip.visible: remMouse.containsMouse
            MouseArea { id: remMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
        }

        // ── Idle placeholder ──────────────────────────────────────────────
        PlasmaComponents3.Label {
            visible:          online && jobCount === 0 && (st.queued || 0) === 0
            text:             "Idle — nothing in queue"
            opacity:          0.4
            font.pixelSize:   Kirigami.Theme.smallFont.pixelSize
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 2
        }

        // ── Action buttons ────────────────────────────────────────────────
        RowLayout {
            visible:         online
            spacing:         Kirigami.Units.smallSpacing
            Layout.topMargin: 2

            PlasmaComponents3.Button {
                text:      "Drain"
                icon.name: "process-stop"
                enabled:   !!httpSource
                onClicked: httpSource.publishDrain()
            }
            PlasmaComponents3.Button {
                text:      "Flush"
                icon.name: "edit-clear"
                enabled:   !!httpSource
                onClicked: httpSource.publishFlush()
            }
            PlasmaComponents3.Button {
                visible:   !stopped && !paused
                text:      "Pause"
                icon.name: "media-playback-pause"
                enabled:   !!httpSource && jobCount > 0
                PlasmaComponents3.ToolTip.text:    "Freeze ffmpeg in place — continue later without losing progress"
                PlasmaComponents3.ToolTip.visible: hovered
                onClicked: httpSource.publishPause()
            }
            PlasmaComponents3.Button {
                visible:   paused
                text:      "Continue"
                icon.name: "media-playback-start"
                enabled:   !!httpSource
                onClicked: httpSource.publishUnpause()
            }
            PlasmaComponents3.Button {
                visible:   !stopped
                text:      "Stop"
                icon.name: "media-playback-stop"
                enabled:   !!httpSource && (jobCount > 0 || queueJobs.length > 0)
                PlasmaComponents3.ToolTip.text:    "Kill ffmpeg immediately and hold the queue"
                PlasmaComponents3.ToolTip.visible: hovered
                onClicked: httpSource.publishStop({ all: true })
            }
            PlasmaComponents3.Button {
                visible:   stopped
                text:      "Start"
                icon.name: "media-playback-start"
                enabled:   !!httpSource
                PlasmaComponents3.ToolTip.text:    "Resume encoding — stopped files restart from scratch"
                PlasmaComponents3.ToolTip.visible: hovered
                onClicked: httpSource.publishResume()
            }
        }

        PlasmaComponents3.Label {
            visible: online && (stopped || paused)
            text:    stopped ? "Stopped — queue on hold" : "Paused — ffmpeg frozen, queue on hold"
            color:   Kirigami.Theme.neutralTextColor
            font.bold: true
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        }

        // ── After-process action (switchable at any time) ──────────────────
        RowLayout {
            visible: online
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                source: card.afterAction === "none" ? "system-suspend-hibernate-symbolic"
                      : card.afterAction.indexOf("reboot") === 0 ? "system-reboot" : "system-shutdown"
                width:  Kirigami.Units.iconSizes.small
                height: width
            }
            PlasmaComponents3.Label { text: "When finished:" }
            PlasmaComponents3.ComboBox {
                id: afterBox
                Layout.fillWidth: true
                enabled:     !!httpSource
                model:       card.afterOptions
                textRole:    "text"
                valueRole:   "value"
                currentIndex: card.afterIndex()
                onActivated: httpSource.publishPower(currentValue)

                // A user pick breaks the currentIndex binding, so re-sync on daemon updates
                Connections {
                    target: card
                    function onAfterActionChanged() { afterBox.currentIndex = card.afterIndex() }
                }
            }
        }
        PlasmaComponents3.Label {
            visible: online && !!st.powerError
            text:    "Power action failed: " + (st.powerError || "")
            color:   Kirigami.Theme.negativeTextColor
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        }

        // ── Queue reorder panel (#16) ──────────────────────────────────────
        ColumnLayout {
            visible:          queueExpanded && queueJobs.length > 0
            spacing:          2
            Layout.fillWidth: true

            Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: 4 }
            PlasmaComponents3.Label { text: "Queue order"; font.bold: true; opacity: 0.7 }

            Repeater {
                model: queueJobs
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    required property int index
                    required property var modelData

                    PlasmaComponents3.Label {
                        text: (index + 1) + ". " + (modelData.path ? modelData.path.split("/").pop() : "")
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    }
                    PlasmaComponents3.Label {
                        visible:        card.queuedEta(modelData) >= 0
                        text:           "~" + card.formatEta(card.queuedEta(modelData))
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        opacity:        0.7
                    }
                    PlasmaComponents3.ToolButton {
                        icon.name: "arrow-up"
                        enabled: index > 0 && !!httpSource
                        onClicked: card.moveQueueJob(index, index - 1)
                    }
                    PlasmaComponents3.ToolButton {
                        icon.name: "arrow-down"
                        enabled: index < queueJobs.length - 1 && !!httpSource
                        onClicked: card.moveQueueJob(index, index + 1)
                    }
                    PlasmaComponents3.ToolButton {
                        icon.name: "go-top"
                        enabled: index > 0 && !!httpSource
                        PlasmaComponents3.ToolTip.text:    "Prioritize — move to front of queue"
                        PlasmaComponents3.ToolTip.visible: hovered
                        onClicked: card.moveQueueJob(index, 0)
                    }
                }
            }
        }

        // ── Watches panel (#18 suspend/resume, #17 reorder-on-toggle) ──────
        ColumnLayout {
            visible:          watchesExpanded && watchList.length > 0
            spacing:          2
            Layout.fillWidth: true

            Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: 4 }
            PlasmaComponents3.Label { text: "Watched directories"; font.bold: true; opacity: 0.7 }

            Repeater {
                model: watchList
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents3.Label {
                        text: modelData.path ? modelData.path.split("/").pop() : ""
                        elide: Text.ElideMiddle
                        opacity: modelData.enabled === false ? 0.4 : 1.0
                        Layout.fillWidth: true
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    }
                    QQC2.Switch {
                        checked: modelData.enabled !== false
                        enabled: !!httpSource
                        PlasmaComponents3.ToolTip.text:    "Suspend/resume this watch"
                        PlasmaComponents3.ToolTip.visible: hovered
                        onToggled: httpSource.publishWatchToggle(modelData.path, checked)
                    }
                }
            }
        }

        // ── Idle-shutdown / worker count config panel ──────────────────────
        ColumnLayout {
            visible:          cfgExpanded
            spacing:          Kirigami.Units.smallSpacing
            Layout.fillWidth: true

            Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: 4 }

            RowLayout {
                PlasmaComponents3.Label { text: "Workers:" }
                QQC2.SpinBox {
                    id: workersBox
                    from: 0; to: 32
                    value: pendingWorkers
                    onValueModified: pendingWorkers = value
                }
            }
            RowLayout {
                PlasmaComponents3.Label { text: "Idle shutdown:" }
                QQC2.Switch {
                    id: idleSwitch
                    checked: pendingIdleShutdown
                    onToggled: pendingIdleShutdown = checked
                }
            }
            RowLayout {
                enabled: idleSwitch.checked
                opacity: idleSwitch.checked ? 1.0 : 0.5
                PlasmaComponents3.Label { text: "Timeout (s):" }
                QQC2.SpinBox {
                    id: timeoutBox
                    from: 10; to: 86400; stepSize: 60
                    value: pendingIdleTimeout
                    onValueModified: pendingIdleTimeout = value
                }
            }
            RowLayout {
                Item { Layout.fillWidth: true }
                PlasmaComponents3.Button {
                    text: "Apply"; icon.name: "dialog-ok-apply"
                    enabled: !!httpSource
                    onClicked: httpSource.publishConfig({
                        workers:               pendingWorkers,
                        idle_shutdown:         pendingIdleShutdown,
                        idle_shutdown_timeout: pendingIdleTimeout
                    })
                }
                PlasmaComponents3.Button {
                    text: "Cancel"; icon.name: "dialog-cancel"
                    onClicked: {
                        pendingWorkers      = cfg.workers               || 1
                        pendingIdleShutdown = cfg.idle_shutdown         || false
                        pendingIdleTimeout  = cfg.idle_shutdown_timeout || 30
                        cfgExpanded = false
                    }
                }
            }
        }
    }

    // ── Time-remaining estimates ──────────────────────────────────────────
    // ffmpeg reports speed as media-seconds per wall-second ("0.5x"); `duration` comes from the
    // daemon's ffprobe cache. Queued files are estimated with the average speed of the running
    // jobs, and the total divides the remaining work across the worker slots.
    function parseSpeed(s) {
        var v = parseFloat(s)
        return v > 0 ? v : 0
    }

    readonly property real avgSpeed: {
        var run = st.running || [], sum = 0, n = 0
        for (var i = 0; i < run.length; i++) {
            var v = parseSpeed(run[i].speed)
            if (v > 0) { sum += v; n++ }
        }
        return n > 0 ? sum / n : 0
    }

    // Seconds left for a running job, or -1 if unknown
    function runningEta(job) {
        var speed = parseSpeed(job.speed) || avgSpeed
        if (!job.duration || !speed) return -1
        return Math.max(0, job.duration - (job.elapsed || 0)) / speed
    }

    // Estimated encode seconds for a queued job, or -1 if unknown
    function queuedEta(job) {
        if (!job.duration || !avgSpeed) return -1
        return job.duration / avgSpeed
    }

    readonly property var etaSummary: {
        var run = st.running || [], total = 0, unknown = 0
        for (var i = 0; i < run.length; i++) {
            var r = runningEta(run[i])
            if (r < 0) unknown++; else total += r
        }
        for (var j = 0; j < queueJobs.length; j++) {
            var q = queuedEta(queueJobs[j])
            if (q < 0) unknown++; else total += q
        }
        var slots = Math.max(1, Math.min(cfg.workers || 1, run.length + queueJobs.length))
        return { secs: total / slots, unknown: unknown }
    }

    function formatEta(secs) {
        if (secs < 0) return ""
        var m = Math.round(secs / 60)
        if (m < 1) return "<1m"
        var h = Math.floor(m / 60)
        return h > 0 ? h + "h " + (m % 60) + "m" : m + "m"
    }

    function afterIndex() {
        for (var i = 0; i < afterOptions.length; i++)
            if (afterOptions[i].value === afterAction) return i
        return 0
    }

    // Moves the job at `from` to position `to` and pushes the new order to the daemon (#16)
    function moveQueueJob(from, to) {
        var paths = queueJobs.map(function(j) { return j.path })
        var moved = paths.splice(from, 1)[0]
        paths.splice(to, 0, moved)
        httpSource.publishQueueReorder(paths)
    }

    // Toggles the realtime output panel for a running job (#24)
    function toggleOutput(path) {
        if (outputExpandedPath === path) {
            outputExpandedPath = ""
            outputLines = []
            outputError = ""
        } else {
            outputExpandedPath = path
            outputLines = []
            outputError = ""
            refreshOutput()
        }
    }

    function refreshOutput() {
        if (!outputExpandedPath || !httpSource) return
        httpSource.fetchJobOutput(outputExpandedPath, function(lines, error) {
            if (outputExpandedPath === "") return
            outputLines = lines
            outputError = error || ""
        })
    }

    Timer {
        interval: 1500
        running:  card.outputExpandedPath !== ""
        repeat:   true
        onTriggered: card.refreshOutput()
    }

    function formatElapsed(secs) {
        if (!secs && secs !== 0) return "--:--"
        var h = Math.floor(secs / 3600)
        var m = Math.floor((secs % 3600) / 60)
        var s = Math.floor(secs % 60)
        if (h > 0)
            return pad(h) + ":" + pad(m) + ":" + pad(s)
        return pad(m) + ":" + pad(s)
    }

    function pad(n) { return String(n).padStart(2, "0") }
}
