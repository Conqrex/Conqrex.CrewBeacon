import QtQuick
import QtWebSockets
import org.kde.plasma.plasma5support as Plasma5Support
import "../code/paseo.js" as Paseo

// One read-only Paseo wire-protocol 1 source. It owns transport handling and
// emits only normalized CrewBeacon domain objects.
Item {
    id: sourceItem
    visible: false
    width: 0
    height: 0

    property var sourceConfig: ({})
    readonly property string sourceId: (sourceConfig && sourceConfig.id) || "local"
    readonly property string sourceName: (sourceConfig && sourceConfig.name) || "Paseo"
    readonly property string transport: (sourceConfig && sourceConfig.transport) || "direct"
    readonly property bool isRelay: transport === "relay"
    readonly property string endpoint: (sourceConfig && sourceConfig.endpoint) || "ws://127.0.0.1:6767/ws"
    readonly property string offerFile: (sourceConfig && sourceConfig.offerFile) || ""
    readonly property bool sourceEnabled: !sourceConfig || sourceConfig.enabled !== false
    property int retentionHours: 24
    readonly property string relayHelperPath:
        Qt.resolvedUrl("../code/crewbeacon_paseo_relay.py").toString().replace(/^file:\/\//, "")

    property string connectionState: sourceEnabled ? "Connecting" : "Disabled"
    property string connectionError: ""
    property bool compatible: true
    property bool socketWanted: false
    property int reconnectAttempt: 0
    property var serverInfo: ({})
    property var workspaceMap: ({})
    property var agentEntryMap: ({})
    property var sessionMap: ({})
    property var sessions: []
    property int unknownMessageCount: 0
    property var seenEventMap: ({})
    property var seenEventOrder: []
    property string agentsRequestId: ""
    property string workspacesRequestId: ""
    property string lastSeenAt: ""
    property var relayHost: ({})
    property bool relayBusy: false

    signal snapshotChanged(var snapshot)
    signal usageObserved(var event)
    signal attentionObserved(var event)

    function randomId(prefix) {
        return prefix + "-" + sourceId + "-" + Date.now() + "-" + Math.floor(Math.random() * 1000000)
    }

    function hostModel() {
        if (isRelay && relayHost && relayHost.id) {
            return {
                id: relayHost.id,
                name: relayHost.name || sourceName,
                endpoint: relayHost.endpoint || "relay://paseo",
                serverId: relayHost.serverId || "",
                hostname: relayHost.hostname || sourceName,
                version: relayHost.version || "CLI relay",
                connectionState: connectionState,
                lastSeenAt: lastSeenAt,
                error: connectionError,
                compatible: compatible,
                unknownMessages: 0,
                transport: "relay"
            }
        }
        return {
            id: sourceId,
            name: sourceName,
            endpoint: endpoint,
            serverId: serverInfo.serverId || "",
            hostname: serverInfo.hostname || sourceName,
            version: serverInfo.version || "",
            connectionState: connectionState,
            lastSeenAt: lastSeenAt,
            error: connectionError,
            compatible: compatible,
            unknownMessages: unknownMessageCount
        }
    }

    function sourceModel() {
        var host = hostModel()
        return {
            id: sourceId,
            name: sourceName,
            endpoint: endpoint,
            serverId: host.serverId,
            hostname: host.hostname,
            version: host.version,
            connectionState: connectionState
        }
    }

    function emitSnapshot() {
        snapshotChanged({ host: hostModel(), sessions: sessions })
    }

    function validEndpoint() {
        if (isRelay) return offerFile.trim() !== ""
        return /^(ws|wss):\/\/[^/]+\/ws(?:\?.*)?$/.test(endpoint)
    }

    function shq(value) {
        return "'" + ("" + value).replace(/'/g, "'\\''") + "'"
    }

    function relayCommand() {
        return "python3 " + shq(relayHelperPath) + " snapshot"
             + " --offer-file " + shq(offerFile)
             + " --source-id " + shq(sourceId)
             + " --source-name " + shq(sourceName)
    }

    function pollRelay() {
        if (!sourceEnabled || !isRelay || relayBusy) return
        if (!validEndpoint()) {
            connectionState = "Failed"
            connectionError = "Choose a 0600 file containing the Paseo offer URL"
            emitSnapshot()
            return
        }
        relayBusy = true
        if (connectionState !== "Connected") connectionState = "Connecting"
        relayExec.run(relayCommand())
    }

    function applyRelayResult(result) {
        if (!result || result.ok !== true || !result.host) {
            connectionState = "Disconnected"
            connectionError = (result && result.error) || "Paseo relay snapshot failed"
            markSessionsStale()
            return
        }
        relayHost = result.host
        serverInfo = { serverId: result.host.serverId || "", version: "CLI relay" }
        compatible = true
        reconnectAttempt = 0
        connectionState = "Connected"
        connectionError = ""
        lastSeenAt = new Date().toISOString()
        sessions = Paseo.sortSessions(Array.isArray(result.sessions) ? result.sessions : [])
        var map = {}
        for (var i = 0; i < sessions.length; i++) map[sessions[i].id] = sessions[i]
        sessionMap = map
        emitSnapshot()
    }

    function start() {
        reconnectTimer.stop()
        if (!sourceEnabled) {
            socketWanted = false
            connectionState = "Disabled"
            emitSnapshot()
            return
        }
        if (isRelay) {
            socketWanted = false
            compatible = true
            connectionError = ""
            connectionState = "Connecting"
            emitSnapshot()
            Qt.callLater(pollRelay)
            return
        }
        if (!validEndpoint()) {
            socketWanted = false
            connectionState = "Failed"
            connectionError = "Endpoint must be ws://HOST:PORT/ws or wss://HOST:PORT/ws"
            emitSnapshot()
            return
        }
        compatible = true
        connectionError = ""
        connectionState = "Connecting"
        socketWanted = false
        reconnectKick.restart()
    }

    function refresh() {
        if (isRelay) { pollRelay(); return }
        if (connectionState === "Connected") requestSnapshots()
        else start()
    }

    function scheduleReconnect(reason) {
        socketWanted = false
        if (isRelay) return
        if (!sourceEnabled || !compatible || reconnectTimer.running) return
        connectionState = "Disconnected"
        connectionError = reason || socket.errorString || "Connection closed"
        markSessionsStale()
        var delay = Paseo.reconnectDelay(reconnectAttempt, Math.random())
        reconnectAttempt += 1
        reconnectTimer.interval = delay
        reconnectTimer.restart()
    }

    function markSessionsStale() {
        var next = []
        var map = {}
        for (var i = 0; i < sessions.length; i++) {
            var old = sessions[i]
            var copy = {}
            for (var key in old) copy[key] = old[key]
            copy.stale = true
            copy.sourceConnectionState = "Disconnected"
            next.push(copy)
            map[copy.id] = copy
        }
        sessions = Paseo.sortSessions(next)
        sessionMap = map
        emitSnapshot()
    }

    function sendEnvelope(message) {
        if (socket.status !== WebSocket.Open) return false
        socket.sendTextMessage(JSON.stringify(message))
        return true
    }

    function sendSession(message) {
        return sendEnvelope({ type: "session", message: message })
    }

    function sendHello() {
        sendEnvelope({
            type: "hello",
            clientId: "crewbeacon-" + sourceId,
            clientType: "browser",
            protocolVersion: 1,
            appVersion: "0.1.3",
            capabilities: { projectUpdates: true, selectiveAgentTimeline: true }
        })
    }

    function requestSnapshots() {
        agentsRequestId = randomId("agents")
        workspacesRequestId = randomId("workspaces")
        sendSession({
            type: "fetch_agents_request",
            requestId: agentsRequestId,
            filter: { includeArchived: false },
            sort: [{ key: "updated_at", direction: "desc" }],
            page: { limit: 200 },
            subscribe: { subscriptionId: "crewbeacon-agents-" + sourceId }
        })
        sendSession({
            type: "fetch_workspaces_request",
            requestId: workspacesRequestId,
            sort: [{ key: "activity_at", direction: "desc" }],
            page: { limit: 200 },
            subscribe: { subscriptionId: "crewbeacon-workspaces-" + sourceId }
        })
    }

    function subscribeTimelines() {
        var features = serverInfo.features || {}
        if (features.selectiveAgentTimeline !== true) return
        var ids = []
        for (var id in agentEntryMap) ids.push(id)
        ids.sort()
        sendSession({
            type: "agent.timeline.set_subscription.request",
            agentIds: ids,
            requestId: randomId("timeline")
        })
    }

    function rebuildSessions() {
        var out = []
        var byId = {}
        var cutoff = Date.now() - Math.max(1, retentionHours) * 3600000
        var source = sourceModel()
        for (var id in agentEntryMap) {
            var normalized = Paseo.normalizeAgent(agentEntryMap[id], source, workspaceMap)
            if (!normalized) continue
            var updated = Date.parse(normalized.lastActivityAt || normalized.startedAt) || 0
            if (!Paseo.activeState(normalized.state) && !Paseo.isAttentionState(normalized.state)
                    && updated > 0 && updated < cutoff) continue
            out.push(normalized)
            byId[normalized.id] = normalized
        }
        sessions = Paseo.sortSessions(out)
        sessionMap = byId
        emitSnapshot()
        subscribeTimelines()
    }

    function rememberEvent(key) {
        if (!key) return false
        if (seenEventMap[key]) return false
        var map = seenEventMap
        var order = seenEventOrder.slice()
        map[key] = true
        order.push(key)
        while (order.length > 2048) {
            var dropped = order.shift()
            delete map[dropped]
        }
        seenEventMap = map
        seenEventOrder = order
        return true
    }

    function handleServerInfo(payload) {
        var result = Paseo.serverInfoCompatibility(payload)
        if (!result.compatible) {
            compatible = false
            connectionState = "Failed"
            connectionError = result.error
            socketWanted = false
            emitSnapshot()
            return
        }
        serverInfo = payload
        compatible = true
        reconnectAttempt = 0
        connectionState = "Connected"
        connectionError = ""
        lastSeenAt = new Date().toISOString()
        emitSnapshot()
        requestSnapshots()
    }

    function handleAgentEntries(entries) {
        var next = {}
        var list = Array.isArray(entries) ? entries : []
        for (var i = 0; i < list.length; i++) {
            var entry = list[i]
            if (entry && entry.agent && entry.agent.id) next[entry.agent.id] = entry
        }
        agentEntryMap = next
        rebuildSessions()
    }

    function handleWorkspaceEntries(entries) {
        var next = {}
        var list = Array.isArray(entries) ? entries : []
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].id) next[list[i].id] = list[i]
        }
        workspaceMap = next
        rebuildSessions()
    }

    function handleAgentUpdate(payload) {
        if (!payload || !payload.kind) return
        var next = agentEntryMap
        if (payload.kind === "upsert" && payload.agent && payload.agent.id) {
            next[payload.agent.id] = { agent: payload.agent, project: payload.project || null }
        } else if (payload.kind === "remove" && payload.agentId) {
            delete next[payload.agentId]
        }
        agentEntryMap = next
        rebuildSessions()
    }

    function handleWorkspaceUpdate(payload) {
        if (!payload || !payload.kind) return
        var next = workspaceMap
        if (payload.kind === "upsert" && payload.workspace && payload.workspace.id)
            next[payload.workspace.id] = payload.workspace
        else if (payload.kind === "remove" && payload.id)
            delete next[payload.id]
        workspaceMap = next
        rebuildSessions()
    }

    function handleStream(message) {
        var payload = message.payload || {}
        var session = sessionMap[payload.agentId] || {}
        var usage = Paseo.usageEventFromStream(sourceModel(), session, payload)
        if (usage && rememberEvent(usage.dedupKey)) usageObserved(usage)

        var attention = Paseo.attentionEventFromMessage(sourceModel(), message, sessionMap)
        if (attention && rememberEvent(attention.dedupKey)) attentionObserved(attention)
    }

    function handleMessage(message) {
        if (!message || !message.type) { unknownMessageCount += 1; return }
        if (message.type === "status" && message.payload && message.payload.status === "server_info") {
            handleServerInfo(message.payload)
            return
        }
        if (message.type === "fetch_agents_response" && message.payload
                && message.payload.requestId === agentsRequestId) {
            handleAgentEntries(message.payload.entries)
            return
        }
        if (message.type === "fetch_workspaces_response" && message.payload
                && message.payload.requestId === workspacesRequestId) {
            handleWorkspaceEntries(message.payload.entries)
            return
        }
        if (message.type === "agent_update") { handleAgentUpdate(message.payload); return }
        if (message.type === "workspace_update") { handleWorkspaceUpdate(message.payload); return }
        if (message.type === "agent_stream") { handleStream(message); return }
        if (message.type === "agent_permission_request" || message.type === "agent_attention_required") {
            var event = Paseo.attentionEventFromMessage(sourceModel(), message, sessionMap)
            if (event && rememberEvent(event.dedupKey)) attentionObserved(event)
            return
        }
        // Known request acknowledgements do not affect the observer model.
        if (message.type === "agent.timeline.set_subscription.response"
                || message.type === "agent_permission_resolved"
                || message.type === "providers_snapshot_update"
                || message.type === "pong") return
        unknownMessageCount += 1
        emitSnapshot()
    }

    function handleText(text) {
        var envelope
        try { envelope = JSON.parse(text) }
        catch (error) { unknownMessageCount += 1; return }
        if (envelope.type === "pong") return
        if (envelope.type !== "session" || !envelope.message) {
            unknownMessageCount += 1
            return
        }
        lastSeenAt = new Date().toISOString()
        handleMessage(envelope.message)
    }

    WebSocket {
        id: socket
        url: sourceItem.endpoint
        active: sourceItem.socketWanted && !sourceItem.isRelay
        requestedSubprotocols: []
        onTextMessageReceived: (message) => sourceItem.handleText(message)
        onStatusChanged: (status) => {
            if (status === WebSocket.Open) {
                sourceItem.connectionState = "Connecting"
                sourceItem.connectionError = ""
                sourceItem.sendHello()
            } else if (status === WebSocket.Error) {
                sourceItem.scheduleReconnect(errorString)
            } else if (status === WebSocket.Closed && sourceItem.socketWanted) {
                sourceItem.scheduleReconnect(errorString || "Connection closed")
            }
        }
    }

    Timer {
        id: reconnectKick
        interval: 1
        repeat: false
        onTriggered: sourceItem.socketWanted = true
    }

    Timer {
        id: reconnectTimer
        interval: 1500
        repeat: false
        onTriggered: {
            sourceItem.connectionState = "Connecting"
            sourceItem.socketWanted = true
            sourceItem.emitSnapshot()
        }
    }

    Plasma5Support.DataSource {
        id: relayExec
        engine: "executable"
        connectedSources: []
        property int serial: 0
        onNewData: (source, data) => {
            var parsed = null
            try { parsed = JSON.parse(("" + (data["stdout"] || "")).trim()) }
            catch (error) { parsed = { ok: false, error: "Relay helper returned invalid JSON" } }
            sourceItem.relayBusy = false
            sourceItem.applyRelayResult(parsed)
            disconnectSource(source)
        }
        function run(command) {
            serial += 1
            connectSource(command + " # crewbeacon-relay-" + serial)
        }
    }

    Timer {
        id: relayPoll
        interval: 20000
        repeat: true
        triggeredOnStart: true
        running: sourceItem.sourceEnabled && sourceItem.isRelay
        onTriggered: sourceItem.pollRelay()
    }

    onSourceConfigChanged: start()
    onSourceEnabledChanged: start()
    Component.onCompleted: start()
    Component.onDestruction: {
        reconnectTimer.stop()
        socketWanted = false
    }
}
