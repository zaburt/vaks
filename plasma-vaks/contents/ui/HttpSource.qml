import QtQuick

// Manages the HTTP connection for one vaks source.
// Prefers a persistent Server-Sent Events stream (/api/events) pushed by the
// daemon so the UI updates immediately without polling three endpoints on a
// timer. Falls back to the legacy poll-every-N-seconds behavior automatically
// if the daemon doesn't support /api/events (e.g. an older vaksd) or the
// stream drops and can't be re-established.

Item {
    id: httpSource

    property var source: null   // { id, name, host, port, token }

    readonly property string srcId:   source ? source.id   : ""
    readonly property string srcName: source ? source.name : ""
    readonly property string baseUrl: source ? "http://" + source.host + ":" + (source.port || 6283) : ""

    property int  pollInterval:      3000
    property bool _connected:        false
    property bool useLegacyPolling:  false   // true once SSE is deemed unsupported/unreliable
    property int  _sseFailCount:     0
    property var  _sseXhr:           null
    property int  _ssePos:           0
    property string _sseTail:        ""
    readonly property int _maxSseFailures: 3
    readonly property int _sseReconnectDelay: 2000
    readonly property int _sseRetryBackoffMax: 30000

    Component.onCompleted: connectSSE()

    // ── Legacy poll timer (fallback only) ───────────────────────────────────
    Timer {
        interval: httpSource.pollInterval
        running:  httpSource.useLegacyPolling
        repeat:   true
        triggeredOnStart: true
        onTriggered: httpSource.pollStatus()
    }

    Timer {
        id: sseReconnectTimer
        interval: httpSource._sseReconnectDelay
        repeat:   false
        onTriggered: httpSource.connectSSE()
    }

    // Even after we've fallen back to legacy polling (repeated SSE failures), keep
    // trying to re-establish the push connection in the background every 30s so the
    // widget recovers to low-latency updates automatically once the daemon/network
    // comes back, instead of being stuck polling forever (#websocket-reconnect).
    Timer {
        interval: 30000
        running:  httpSource.useLegacyPolling
        repeat:   true
        onTriggered: {
            httpSource._sseFailCount = 0
            httpSource.useLegacyPolling = false
            httpSource.connectSSE()
        }
    }

    // History poll — independent of the SSE/legacy transport, since /api/history
    // backs the failed-count badge and stats view rather than the live status panel.
    Timer {
        interval: 5000
        running:  !!httpSource.source
        repeat:   true
        triggeredOnStart: true
        onTriggered: httpSource.pollHistory()
    }

    // ── Public API ───────────────────────────────────────────────────────────

    function publishConfig(params)      { post("/api/config",       params) }
    function publishDrain()             { post("/api/drain",        {})     }
    function publishPause()             { post("/api/pause",        { all: true }) }
    function publishUnpause()           { post("/api/unpause",      {})     }
    function publishResume()            { post("/api/resume",       {})     }
    function publishPower(action)       { post("/api/power",        { action: action }) }
    function publishFlush()             { post("/api/flush-queue",  {})     }
    function publishStop(params)        { post("/api/stop-job",     params) }
    function publishQueueReorder(paths) { post("/api/queue-reorder", { paths: paths }) }
    function publishWatchToggle(path, enabled) { post("/api/watch-toggle", { path: path, enabled: enabled }) }
    function publishRetry(path)         { post("/api/retry-job",    { path: path }) }

    function fetchJobOutput(path, callback) {
        if (!source) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", baseUrl + "/api/job-output?path=" + encodeURIComponent(path))
        if (source.token)
            xhr.setRequestHeader("Authorization", "Bearer " + source.token)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText)
                    callback(data.output || [], data.error || null)
                } catch(e) {
                    callback([], "" + e)
                }
            } else {
                callback([], "HTTP " + xhr.status)
            }
        }
        xhr.onerror = function() { callback([], "Connection error") }
        xhr.send()
    }

    // ── SSE (preferred transport) ────────────────────────────────────────────

    function connectSSE() {
        if (!source || httpSource.useLegacyPolling) return
        if (_sseXhr) { try { _sseXhr.abort() } catch(e) {} }

        _ssePos  = 0
        _sseTail = ""

        var xhr = new XMLHttpRequest()
        _sseXhr = xhr
        xhr.open("GET", baseUrl + "/api/events")
        if (source.token)
            xhr.setRequestHeader("Authorization", "Bearer " + source.token)

        xhr.onreadystatechange = function() {
            if (xhr !== _sseXhr) return  // superseded by a newer connection attempt

            if (xhr.readyState === XMLHttpRequest.LOADING || xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 200 || xhr.status === 0) {
                    processSSEChunk(xhr.responseText)
                }
            }

            if (xhr.readyState === XMLHttpRequest.DONE) {
                _sseXhr = null
                if (xhr.status === 200 && _connected) {
                    // Stream ended cleanly after having worked — just reconnect.
                    sseReconnectTimer.restart()
                } else {
                    onSSEFailure()
                }
            }
        }
        xhr.onerror = function() {
            if (xhr !== _sseXhr) return
            _sseXhr = null
            onSSEFailure()
        }
        xhr.send()
    }

    function onSSEFailure() {
        _sseFailCount += 1
        if (_sseFailCount >= _maxSseFailures) {
            console.warn("vaks: SSE unavailable for", srcName, "— falling back to polling")
            useLegacyPolling = true
            pollStatus()
            return
        }
        markDisconnected("Reconnecting…")
        sseReconnectTimer.restart()
    }

    function processSSEChunk(fullText) {
        if (fullText.length <= _ssePos) return
        var delta = fullText.substring(_ssePos)
        _ssePos   = fullText.length

        var combined = _sseTail + delta
        var events   = combined.split("\n\n")
        _sseTail = events.pop() || ""

        for (var i = 0; i < events.length; i++) {
            var lines = events[i].split("\n")
            for (var j = 0; j < lines.length; j++) {
                if (lines[j].indexOf("data:") === 0) {
                    var payload = lines[j].substring(5).trim()
                    handleSSESnapshot(payload)
                }
            }
        }
    }

    function handleSSESnapshot(json) {
        try {
            var data = JSON.parse(json)
        } catch(e) {
            return
        }
        _sseFailCount = 0
        if (!_connected) {
            _connected = true
            root.onSourceConnected(srcId)
        }
        if (data.status)   root.onStatusMessage(srcId, srcName, data.status)
        if (data.queue)     root.onQueueMessage(srcId, data.queue.jobs || [])
        if (data.watches)   root.onWatchesMessage(srcId, data.watches.watches || [])
    }

    // ── Legacy polling (fallback) ────────────────────────────────────────────

    function pollStatus() {
        if (!source) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", baseUrl + "/api/status")
        if (source.token)
            xhr.setRequestHeader("Authorization", "Bearer " + source.token)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText)
                    if (!_connected) {
                        _connected = true
                        root.onSourceConnected(srcId)
                    }
                    root.onStatusMessage(srcId, srcName, data)
                    pollQueue()
                    pollWatches()
                } catch(e) {
                    markDisconnected("Parse error: " + e)
                }
            } else {
                markDisconnected(xhr.status === 401 ? "Unauthorized (check token)"
                                                     : "HTTP " + xhr.status)
            }
        }
        xhr.onerror = function() { markDisconnected("Connection refused") }
        xhr.send()
    }

    function pollQueue() {
        if (!source || !_connected) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", baseUrl + "/api/queue")
        if (source.token)
            xhr.setRequestHeader("Authorization", "Bearer " + source.token)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText)
                    root.onQueueMessage(srcId, data.jobs || [])
                } catch(e) { /* ignore */ }
            }
        }
        xhr.send()
    }

    function pollWatches() {
        if (!source || !_connected) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", baseUrl + "/api/watches")
        if (source.token)
            xhr.setRequestHeader("Authorization", "Bearer " + source.token)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText)
                    root.onWatchesMessage(srcId, data.watches || [])
                } catch(e) { /* ignore */ }
            }
        }
        xhr.send()
    }

    function pollHistory() {
        if (!source) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", baseUrl + "/api/history")
        if (source.token)
            xhr.setRequestHeader("Authorization", "Bearer " + source.token)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText)
                    root.onHistoryMessage(srcId, data.stats || null, data.events || [])
                } catch(e) { /* ignore — history is a best-effort side channel */ }
            }
        }
        xhr.onerror = function() { /* ignore */ }
        xhr.send()
    }

    function post(path, params) {
        if (!source) return
        var xhr = new XMLHttpRequest()
        xhr.open("POST", baseUrl + path)
        xhr.setRequestHeader("Content-Type", "application/json")
        if (source.token)
            xhr.setRequestHeader("Authorization", "Bearer " + source.token)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status !== 200)
                console.warn("vaks POST", path, "failed:", xhr.status, xhr.responseText)
        }
        xhr.onerror = function() { console.warn("vaks POST", path, "error") }
        xhr.send(JSON.stringify(params))
    }

    function markDisconnected(reason) {
        _connected = false
        root.onSourceDisconnected(srcId, reason || "Disconnected")
    }

    Component.onDestruction: {
        _connected = false
        if (_sseXhr) { try { _sseXhr.abort() } catch(e) {} }
    }
}
