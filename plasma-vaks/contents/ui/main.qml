import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

// Root plasmoid — owns all HTTP source connections and shared state.
PlasmoidItem {
    id: root

    toolTipMainText: root.anyStopped ? "vaks — on hold" : "vaks"
    toolTipSubText:  totalJobs === 0 && totalFailed === 0
                     ? "Idle"
                     : totalActive + " encoding, " + totalQueued + " queued"
                       + (totalFailed > 0 ? ", " + totalFailed + " failed" : "")

    preferredRepresentation: compactRepresentation
    compactRepresentation:   CompactRepresentation {}
    fullRepresentation:      FullRepresentation {}

    readonly property var configuredSources: {
        try { return JSON.parse(plasmoid.configuration.sources) }
        catch (e) { return [] }
    }

    // Runtime state map: source.id → { connected, running[], queued, watches, vaksConfig, error }
    property var sourceStates: ({})

    // Temporary, session-only mute — vaksd keeps processing, only the widget
    // stops firing notifications while this is true. Not persisted to config (#notif-mute).
    property bool notificationsMuted: false

    readonly property int totalActive: {
        var n = 0
        for (var k in sourceStates) {
            var s = sourceStates[k]
            if (s && s.connected) n += (s.running || []).length
        }
        return n
    }

    readonly property int totalQueued: {
        var n = 0
        for (var k in sourceStates) {
            var s = sourceStates[k]
            if (s && s.connected) n += (s.queued || 0)
        }
        return n
    }

    // True if any connected source has been stopped or paused by the user (queue on hold)
    readonly property bool anyStopped: {
        for (var k in sourceStates) {
            var s = sourceStates[k]
            if (s && s.connected && (s.stopped || s.paused)) return true
        }
        return false
    }

    // Icon file for the pending after-done power action ("" when none); shutdown wins over reboot
    readonly property string afterActionIcon: {
        var found = ""
        for (var k in sourceStates) {
            var s = sourceStates[k]
            if (!s || !s.connected) continue
            var a = s.afterAction || "none"
            if (a === "none") continue
            var icon = "vaks-" + (a.indexOf("reboot") === 0 ? "reboot" : "shutdown")
                     + (a.indexOf("_all") > 0 ? "-all" : "-current") + ".svg"
            if (a.indexOf("shutdown") === 0) return icon
            found = icon
        }
        return found
    }

    // Mean progress (0..1) of running jobs from media time done ÷ duration, or -1 if unknown
    readonly property real overallProgress: {
        var sum = 0, n = 0
        for (var k in sourceStates) {
            var s = sourceStates[k]
            if (!s || !s.connected) continue
            var run = s.running || []
            for (var i = 0; i < run.length; i++) {
                var j = run[i]
                var sp = parseFloat(j.speed)
                if (!j.duration || !sp) continue
                sum += Math.min(1, (j.elapsed || 0) * sp / j.duration)
                n++
            }
        }
        return n > 0 ? sum / n : -1
    }

    // Total = currently running + still queued
    readonly property int totalJobs: totalActive + totalQueued

    // Aggregate failed-job count across all connected sources, from each source's
    // pushed history stats (see HttpSource.handleSSESnapshot / onHistoryMessage).
    readonly property int totalFailed: {
        var n = 0
        for (var k in sourceStates) {
            var s = sourceStates[k]
            if (s && s.connected && s.historyStats) n += (s.historyStats.failed || 0)
        }
        return n
    }

    onConfiguredSourcesChanged: syncSourceStates()
    Component.onCompleted:      syncSourceStates()

    function syncSourceStates() {
        var next = {}
        for (var i = 0; i < configuredSources.length; i++) {
            var src  = configuredSources[i]
            var prev = sourceStates[src.id] || {}
            next[src.id] = {
                id:           src.id,
                connected:    prev.connected    || false,
                running:      prev.running      || [],
                queued:       prev.queued       || 0,
                watches:      prev.watches      || 0,
                vaksConfig:   prev.vaksConfig   || null,
                error:        prev.error        || "",
                prevRunning:  prev.prevRunning  || [],
                queueJobs:    prev.queueJobs    || [],
                watchList:    prev.watchList    || [],
                historyStats: prev.historyStats || null,
                stopped:      prev.stopped      || false,
                paused:       prev.paused       || false,
                afterAction:  prev.afterAction  || "none",
                powerError:   prev.powerError   || ""
            }
        }
        sourceStates = next
    }

    function onStatusMessage(srcId, srcName, data) {
        var states   = Object.assign({}, sourceStates)
        var state    = Object.assign({}, states[srcId] || {})
        var newPaths = (data.running || []).map(function(j) { return j.path })
        var prev     = state.prevRunning || []

        if (plasmoid.configuration.notifications && !root.notificationsMuted) {
            prev.forEach(function(p) {
                if (newPaths.indexOf(p) === -1)
                    notification.fire(srcName, "✓ " + p.split("/").pop(), p, srcId, false)
            })
        }

        state.connected   = true
        state.error       = ""
        state.running     = data.running  || []
        state.queued      = data.queued   || 0
        state.watches     = data.watches  || 0
        state.vaksConfig  = data.config   || null
        state.stopped     = !!data.stopped
        state.paused      = !!data.paused
        state.afterAction = data.after_action || "none"
        state.powerError  = data.power_error  || ""
        state.lastUpdated = new Date()
        state.prevRunning = newPaths
        states[srcId]     = state
        sourceStates      = states
    }

    function onSourceConnected(srcId) {
        var states      = Object.assign({}, sourceStates)
        var state       = Object.assign({}, states[srcId] || {})
        state.connected = true
        state.error     = ""
        states[srcId]   = state
        sourceStates    = states
    }

    function onQueueMessage(srcId, jobs) {
        var states     = Object.assign({}, sourceStates)
        var state       = Object.assign({}, states[srcId] || {})
        state.queueJobs = jobs || []
        states[srcId]   = state
        sourceStates    = states
    }

    function onWatchesMessage(srcId, watches) {
        var states      = Object.assign({}, sourceStates)
        var state        = Object.assign({}, states[srcId] || {})
        state.watchList  = watches || []
        states[srcId]    = state
        sourceStates     = states
    }

    // History/stats push (polled from /api/history) — backs the compact-representation
    // failed-count badge and the stats view, and fires failure notifications with
    // "Open folder"/"Retry" actions for jobs that weren't seen as failed before.
    function onHistoryMessage(srcId, stats, events) {
        var states        = Object.assign({}, sourceStates)
        var state          = Object.assign({}, states[srcId] || {})
        var srcName        = state.name || srcId
        var prevFailedKeys  = state.failedKeys || {}
        var nextFailedKeys  = {}

        ;(events || []).forEach(function(e) {
            if (!e.success) {
                var key = e.path + ":" + e.finished_at
                nextFailedKeys[key] = true
                if (!prevFailedKeys[key] && plasmoid.configuration.notifications && !root.notificationsMuted) {
                    notification.fire(srcName, "✗ " + e.path.split("/").pop() + " failed", e.path, srcId, true)
                }
            }
        })

        state.historyStats = stats || null
        state.failedKeys   = nextFailedKeys
        states[srcId]      = state
        sourceStates        = states
    }

    function onSourceDisconnected(srcId, errMsg) {
        var states      = Object.assign({}, sourceStates)
        var state       = Object.assign({}, states[srcId] || {})
        state.connected = false
        state.error     = errMsg || "Disconnected"
        state.running   = []
        state.queued    = 0
        state.queueJobs = []
        state.watchList = []
        states[srcId]   = state
        sourceStates    = states
    }

    // One HttpSource delegate per configured source
    Repeater {
        id: httpSources
        model: root.configuredSources
        HttpSource { source: modelData }
    }

    // Shared notification helper
    property QtObject notifObj: Qt.createQmlObject('
        import org.kde.notification
        Notification {
            componentName: "plasma_workspace"
            eventId: "notification"
            iconName: "video-x-generic"
        }', root, "notifObj")

    QtObject {
        id: notification
        // Actions created for the previous fire() — destroyed before creating new ones
        // so we don't leak NotificationAction objects across repeated notifications.
        property var _actionObjs: []

        // path/srcId are optional — when present, "Open folder" and "Retry" action
        // buttons are attached to the toast instead of a plain notification.
        function fire(title, body, path, srcId, isFailure) {
            if (!root.notifObj) return
            root.notifObj.title = title
            root.notifObj.text  = body

            _actionObjs.forEach(function(a) { a.destroy() })
            _actionObjs = []

            if (path) {
                var folder = path.substring(0, path.lastIndexOf("/"))

                var openAction = Qt.createQmlObject(
                    'import org.kde.notification\nNotificationAction { label: "Open folder" }',
                    root.notifObj, "openAction")
                openAction.activated.connect(function() { Qt.openUrlExternally("file://" + folder) })
                _actionObjs.push(openAction)

                if (isFailure) {
                    var retryAction = Qt.createQmlObject(
                        'import org.kde.notification\nNotificationAction { label: "Retry" }',
                        root.notifObj, "retryAction")
                    retryAction.activated.connect(function() {
                        var hs = getHttpSourceById(srcId)
                        if (hs) hs.publishRetry(path)
                    })
                    _actionObjs.push(retryAction)
                }
            }

            root.notifObj.actions = _actionObjs
            root.notifObj.sendEvent()
        }
    }

    function getHttpSourceById(id) {
        for (var i = 0; i < httpSources.count; i++) {
            var item = httpSources.itemAt(i)
            if (item && item.srcId === id) return item
        }
        return null
    }
}
