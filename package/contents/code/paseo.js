.pragma library

// Paseo wire-protocol 1 adapter boundary. External protocol values are translated here;
// QML views only consume CrewBeacon's normalized model.

var NORMALIZED_STATES = [
    "Unknown", "Connecting", "Idle", "Working", "WaitingForInput",
    "WaitingForPermission", "Completed", "Failed", "Disconnected"
];

var STATE_PRIORITY = {
    Failed: 0,
    WaitingForPermission: 1,
    WaitingForInput: 2,
    Working: 3,
    Connecting: 4,
    Completed: 5,
    Idle: 6,
    Unknown: 7,
    Disconnected: 8
};

function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function finiteNumber(value) {
    return typeof value === "number" && isFinite(value) ? value : null;
}

function stringValue(value) {
    return typeof value === "string" && value.trim() !== "" ? value.trim() : "";
}

// The daemon product version is informational. Paseo's supported client SDK
// keeps the wire protocol compatible across releases and gates additions via
// server_info.features, so rejecting a new 0.x release breaks valid clients.
// Receiving a well-formed server_info after our protocolVersion: 1 hello is the
// compatibility proof available on the wire.
function serverInfoCompatibility(payload) {
    if (!isObject(payload) || !stringValue(payload.serverId)) {
        return { compatible: false, error: "Paseo server_info is missing a server ID" };
    }
    return { compatible: true, error: "" };
}

function basename(path) {
    var value = stringValue(path).replace(/\/+$/, "");
    if (!value) return "";
    var parts = value.split("/");
    return parts[parts.length - 1] || value;
}

function canonicalizeRemote(remote) {
    var value = stringValue(remote);
    if (!value) return "";

    value = value.replace(/[?#].*$/, "").replace(/\/+$/, "");
    var host = "";
    var path = "";

    // SCP-like SSH form: git@github.com:owner/repo.git
    var scp = /^(?:[^@/]+@)?([^:/]+):(.+)$/.exec(value);
    if (scp && value.indexOf("://") === -1) {
        host = scp[1];
        path = scp[2];
    } else {
        var url = /^(?:[a-z][a-z0-9+.-]*):\/\/(?:[^@/]+@)?(\[[^\]]+\]|[^/:]+)(?::\d+)?\/(.+)$/i.exec(value);
        if (!url) return "";
        host = url[1];
        path = url[2];
    }

    host = host.replace(/^\[|\]$/g, "").toLowerCase();
    path = path.replace(/^\/+|\/+$/g, "").replace(/\.git$/i, "");
    if (!host || !path) return "";
    if (host === "github.com") path = path.toLowerCase();
    return host + "/" + path;
}

function repositoryNameFromRemote(remote) {
    var canonical = canonicalizeRemote(remote);
    if (!canonical) return "";
    return basename(canonical);
}

function explicitQuestion(pendingPermissions) {
    var pending = Array.isArray(pendingPermissions) ? pendingPermissions : [];
    for (var i = 0; i < pending.length; i++) {
        if (pending[i] && pending[i].kind === "question") return pending[i];
    }
    return null;
}

function normalizeState(agent) {
    agent = isObject(agent) ? agent : {};
    var pending = Array.isArray(agent.pendingPermissions) ? agent.pendingPermissions : [];
    if (explicitQuestion(pending)) return "WaitingForInput";
    if (pending.length > 0 || agent.attentionReason === "permission")
        return "WaitingForPermission";
    if (agent.status === "error" || agent.attentionReason === "error") return "Failed";
    if (agent.status === "initializing") return "Connecting";
    if (agent.status === "running") return "Working";
    if (agent.attentionReason === "finished" && agent.requiresAttention) return "Completed";
    if (agent.status === "closed") return "Completed";
    if (agent.status === "idle") return "Idle";
    return "Unknown";
}

function isLiveOnlyState(state) {
    return state === "Connecting" || state === "Working"
        || state === "WaitingForInput" || state === "WaitingForPermission";
}

// A durable snapshot is useful while a host is unreachable. Once that source
// has delivered a fresh connected snapshot, however, an absent live-only
// session must not remain visibly active just because its last persisted state
// was Working or Waiting.
function shouldRetainStoredSession(session, liveSnapshots) {
    session = isObject(session) ? session : {};
    liveSnapshots = isObject(liveSnapshots) ? liveSnapshots : {};
    var sourceId = stringValue(session.sourceId);
    var snapshot = sourceId ? liveSnapshots[sourceId] : null;
    var host = isObject(snapshot) && isObject(snapshot.host) ? snapshot.host : {};
    if (host.connectionState === "Connected" && isLiveOnlyState(session.state)) return false;
    return true;
}

function attentionReason(agent, state) {
    if (state === "WaitingForInput") {
        var question = explicitQuestion(agent.pendingPermissions);
        return stringValue(question && (question.title || question.description || question.name))
                || "Waiting for input";
    }
    if (state === "WaitingForPermission") {
        var pending = Array.isArray(agent.pendingPermissions) ? agent.pendingPermissions : [];
        var request = pending.length ? pending[pending.length - 1] : null;
        return stringValue(request && (request.title || request.description || request.name))
                || "Waiting for permission";
    }
    if (state === "Failed") return stringValue(agent.lastError) || "Agent failed";
    if (state === "Completed") return "Agent completed";
    return "";
}

function usageSnapshot(usage) {
    if (!isObject(usage)) return null;
    var value = {
        inputTokens: finiteNumber(usage.inputTokens),
        outputTokens: finiteNumber(usage.outputTokens),
        cacheReadTokens: finiteNumber(usage.cachedInputTokens),
        cacheWriteTokens: null,
        reasoningTokens: null,
        contextUsedTokens: finiteNumber(usage.contextWindowUsedTokens),
        contextMaxTokens: finiteNumber(usage.contextWindowMaxTokens),
        reportedCost: finiteNumber(usage.totalCostUsd),
        currency: finiteNumber(usage.totalCostUsd) !== null ? "USD" : "",
        provenance: "paseo:lastUsage",
        quality: "provider-reported",
        historical: false
    };
    var present = false;
    for (var key in value) {
        if (typeof value[key] === "number") { present = true; break; }
    }
    return present ? value : null;
}

function repositoryIdentity(project, workspace, hostId, fallbackCwd) {
    project = isObject(project) ? project : {};
    workspace = isObject(workspace) ? workspace : {};
    var checkout = isObject(project.checkout) ? project.checkout
                 : (isObject(workspace.project) && isObject(workspace.project.checkout)
                    ? workspace.project.checkout : {});
    var gitRuntime = isObject(workspace.gitRuntime) ? workspace.gitRuntime : {};
    var remote = stringValue(checkout.remoteUrl) || stringValue(gitRuntime.remoteUrl);
    var canonical = canonicalizeRemote(remote);
    var name = stringValue(project.projectName)
            || stringValue(workspace.projectDisplayName)
            || repositoryNameFromRemote(remote)
            || basename(workspace.projectRootPath || fallbackCwd)
            || "Unknown repository";

    if (canonical) {
        return { id: "remote:" + canonical, name: name, remote: canonical, quality: "canonical-remote" };
    }

    var explicit = stringValue(project.projectKey);
    if (explicit && explicit.indexOf("remote:") === 0) {
        return { id: explicit, name: name, remote: explicit.slice(7), quality: "paseo-project-key" };
    }

    var root = stringValue(workspace.projectRootPath) || stringValue(checkout.mainRepoRoot)
             || stringValue(checkout.cwd) || stringValue(fallbackCwd);
    return {
        id: "host:" + stringValue(hostId || "unknown") + ":" + root,
        name: name,
        remote: "",
        quality: "host-path-fallback"
    };
}

function capabilityModel(agent, repo, workspace, usage, source) {
    var raw = isObject(agent.capabilities) ? agent.capabilities : {};
    return {
        canListSessions: true,
        canStreamSessionState: true,
        canReadRepository: !!repo.id,
        canReadBranch: !!(workspace && workspace.branch),
        canReadContextUsage: !!(usage && (usage.contextUsedTokens !== null || usage.contextMaxTokens !== null)),
        canReadTokenUsage: !!(usage && (usage.inputTokens !== null || usage.outputTokens !== null)),
        canReadCost: !!(usage && usage.reportedCost !== null),
        canOpenSession: !!(source && source.serverId),
        canSendMessage: false,
        canApprovePermission: false,
        providerStreaming: raw.supportsStreaming === true,
        providerSessionPersistence: raw.supportsSessionPersistence === true
    };
}

function normalizeAgent(entry, source, workspaceMap) {
    entry = isObject(entry) ? entry : {};
    source = isObject(source) ? source : {};
    workspaceMap = isObject(workspaceMap) ? workspaceMap : {};
    var agent = isObject(entry.agent) ? entry.agent : entry;
    if (!stringValue(agent.id)) return null;
    var workspace = stringValue(agent.workspaceId) ? workspaceMap[agent.workspaceId] : null;
    workspace = isObject(workspace) ? workspace : {};
    var project = isObject(entry.project) ? entry.project
                : (isObject(workspace.project) ? workspace.project : {});
    var checkout = isObject(project.checkout) ? project.checkout : {};
    var gitRuntime = isObject(workspace.gitRuntime) ? workspace.gitRuntime : {};
    var repo = repositoryIdentity(project, workspace, source.serverId || source.id, agent.cwd);
    var state = normalizeState(agent);
    var usage = usageSnapshot(agent.lastUsage);
    var branch = stringValue(checkout.currentBranch) || stringValue(gitRuntime.currentBranch);
    var worktree = stringValue(checkout.worktreeRoot)
                || (workspace.workspaceKind === "worktree" ? stringValue(workspace.workspaceDirectory) : "");
    var provider = stringValue(agent.provider) || "unknown";
    var model = stringValue(agent.runtimeInfo && agent.runtimeInfo.model) || stringValue(agent.model);
    var hostId = stringValue(source.serverId) || stringValue(source.id);
    var workspaceId = stringValue(agent.workspaceId) || stringValue(workspace.id);
    var title = stringValue(agent.title) || stringValue(workspace.name) || repo.name;

    var normalizedWorkspace = {
        id: workspaceId,
        name: stringValue(workspace.name) || basename(agent.cwd),
        kind: stringValue(workspace.workspaceKind),
        cwd: stringValue(agent.cwd) || stringValue(workspace.workspaceDirectory),
        branch: branch,
        worktree: worktree
    };

    return {
        key: stringValue(source.id) + ":" + agent.id,
        id: agent.id,
        sourceId: stringValue(source.id),
        sourceName: stringValue(source.name) || stringValue(source.hostname) || "Paseo",
        hostId: hostId,
        hostName: stringValue(source.hostname) || stringValue(source.name) || hostId,
        providerId: provider,
        providerLabel: provider.charAt(0).toUpperCase() + provider.slice(1),
        modelId: model,
        title: title,
        repositoryId: repo.id,
        repositoryName: repo.name,
        repositoryRemote: repo.remote,
        repositoryQuality: repo.quality,
        workspaceId: workspaceId,
        workspaceName: normalizedWorkspace.name,
        workingDirectory: normalizedWorkspace.cwd,
        branch: branch,
        worktree: worktree,
        state: state,
        rawState: stringValue(agent.status),
        startedAt: stringValue(agent.createdAt),
        lastActivityAt: stringValue(agent.updatedAt),
        endedAt: agent.status === "closed" ? stringValue(agent.updatedAt) : "",
        attentionReason: attentionReason(agent, state),
        attentionTimestamp: stringValue(agent.attentionTimestamp),
        usage: usage,
        capabilities: capabilityModel(agent, repo, normalizedWorkspace, usage, source),
        deepLink: source.serverId ? "paseo:/h/" + encodeURIComponent(source.serverId)
                                   + "/agent/" + encodeURIComponent(agent.id) : "",
        stale: source.connectionState !== "Connected",
        sourceConnectionState: stringValue(source.connectionState) || "Unknown"
    };
}

function usageEventFromStream(source, session, payload) {
    source = isObject(source) ? source : {};
    session = isObject(session) ? session : {};
    payload = isObject(payload) ? payload : {};
    var event = isObject(payload.event) ? payload.event : {};
    if (event.type !== "turn_completed" || !isObject(event.usage)) return null;

    var u = event.usage;
    var input = finiteNumber(u.inputTokens);
    var output = finiteNumber(u.outputTokens);
    var cacheRead = finiteNumber(u.cachedInputTokens);
    var cost = finiteNumber(u.totalCostUsd);
    var contextUsed = finiteNumber(u.contextWindowUsedTokens);
    var contextMax = finiteNumber(u.contextWindowMaxTokens);
    if (input === null && output === null && cacheRead === null && cost === null
            && contextUsed === null && contextMax === null) return null;

    var identity = stringValue(payload.epoch) && finiteNumber(payload.seq) !== null
                 ? payload.epoch + ":" + payload.seq
                 : stringValue(payload.timestamp) + ":" + stringValue(event.turnId || event.type);
    var hasDelta = input !== null || output !== null || cacheRead !== null || cost !== null;
    return {
        dedupKey: "paseo:" + source.id + ":" + payload.agentId + ":" + identity,
        capturedAt: stringValue(payload.timestamp) || new Date().toISOString(),
        sourceId: stringValue(source.id),
        hostId: stringValue(source.serverId) || stringValue(source.id),
        sessionId: stringValue(payload.agentId),
        repositoryId: stringValue(session.repositoryId),
        repositoryName: stringValue(session.repositoryName) || "Unknown repository",
        repositoryRemote: stringValue(session.repositoryRemote),
        workspaceId: stringValue(session.workspaceId),
        workspaceName: stringValue(session.workspaceName),
        workingDirectory: stringValue(session.workingDirectory),
        branch: stringValue(session.branch),
        worktree: stringValue(session.worktree),
        providerId: stringValue(event.provider) || stringValue(session.providerId),
        modelId: stringValue(session.modelId),
        inputTokens: input,
        outputTokens: output,
        cacheReadTokens: cacheRead,
        cacheWriteTokens: null,
        reasoningTokens: null,
        contextUsedTokens: contextUsed,
        contextMaxTokens: contextMax,
        reportedCost: cost,
        currency: cost !== null ? "USD" : "",
        provenance: "paseo:protocol-1:turn_completed",
        quality: "provider-reported",
        metricKind: hasDelta ? "event_delta" : "context_snapshot"
    };
}

function timelineAgentIds(sessions) {
    var ids = [];
    var seen = {};
    var list = Array.isArray(sessions) ? sessions : [];
    for (var i = 0; i < list.length; i++) {
        var session = list[i] || {};
        var id = stringValue(session.id);
        if (!id || seen[id]) continue;
        if (!activeState(session.state) && !isAttentionState(session.state)) continue;
        seen[id] = true;
        ids.push(id);
    }
    ids.sort();
    return ids;
}

// Agent timelines contain high-volume token/output chunks that CrewBeacon does
// not display. Reject those before JSON.parse so plasmashell does not build a
// large temporary object graph for every streamed fragment.
function shouldParseEnvelopeText(text) {
    if (typeof text !== "string" || text.indexOf('"agent_stream"') === -1) return true;
    return text.indexOf('"turn_completed"') !== -1
        || text.indexOf('"attention_required"') !== -1;
}

function isLoopbackEndpoint(endpoint) {
    var value = stringValue(endpoint).toLowerCase();
    return /^wss?:\/\/(localhost|127(?:\.\d{1,3}){3}|\[::1\])(?::\d+)?(?:\/|$)/.test(value);
}

function attentionEventFromMessage(source, message, sessionMap) {
    source = isObject(source) ? source : {};
    message = isObject(message) ? message : {};
    sessionMap = isObject(sessionMap) ? sessionMap : {};
    var agentId = "";
    var reason = "";
    var type = "";
    var timestamp = "";
    var sourceEventId = "";
    var preview = "";

    if (message.type === "agent_permission_request" && isObject(message.payload)) {
        agentId = stringValue(message.payload.agentId);
        var request = isObject(message.payload.request) ? message.payload.request : {};
        type = request.kind === "question" ? "WaitingForInput" : "WaitingForPermission";
        reason = type === "WaitingForInput" ? "Waiting for input" : "Waiting for permission";
        timestamp = stringValue(request.metadata && request.metadata.timestamp) || new Date().toISOString();
        sourceEventId = stringValue(request.id);
        preview = stringValue(request.title) || stringValue(request.description) || stringValue(request.name);
    } else if (message.type === "agent_attention_required" && isObject(message.payload)) {
        agentId = stringValue(message.payload.agentId);
        reason = stringValue(message.payload.reason);
        timestamp = stringValue(message.payload.timestamp) || new Date().toISOString();
        sourceEventId = reason + ":" + timestamp;
        type = reason === "error" ? "Failed"
             : reason === "permission" ? "WaitingForPermission" : "Completed";
        preview = stringValue(message.payload.notification && message.payload.notification.body);
    } else if (message.type === "agent_stream" && isObject(message.payload)
               && isObject(message.payload.event)
               && message.payload.event.type === "attention_required") {
        agentId = stringValue(message.payload.agentId);
        var streamEvent = message.payload.event;
        reason = stringValue(streamEvent.reason);
        timestamp = stringValue(streamEvent.timestamp) || stringValue(message.payload.timestamp)
                  || new Date().toISOString();
        sourceEventId = stringValue(message.payload.epoch) + ":" + message.payload.seq
                      + ":" + reason;
        type = reason === "error" ? "Failed"
             : reason === "permission" ? "WaitingForPermission" : "Completed";
        preview = stringValue(streamEvent.notification && streamEvent.notification.body);
    } else {
        return null;
    }

    if (!agentId || !type) return null;
    var session = sessionMap[agentId] || {};
    return {
        dedupKey: "paseo:" + source.id + ":" + agentId + ":" + (sourceEventId || timestamp + ":" + type),
        sourceId: stringValue(source.id),
        hostId: stringValue(source.serverId) || stringValue(source.id),
        sessionId: agentId,
        repositoryId: stringValue(session.repositoryId),
        repositoryName: stringValue(session.repositoryName) || stringValue(session.title) || "Agent",
        providerId: stringValue(session.providerId) || "agent",
        type: type,
        createdAt: timestamp,
        title: stringValue(session.repositoryName) || stringValue(session.title) || "Agent",
        preview: preview.slice(0, 220),
        sourceEventId: sourceEventId
    };
}

function statePriority(state) {
    return STATE_PRIORITY[state] !== undefined ? STATE_PRIORITY[state] : STATE_PRIORITY.Unknown;
}

function reconnectDelay(attempt, jitterRatio) {
    var count = Math.max(0, Math.floor(Number(attempt) || 0));
    var ratio = Math.max(0, Math.min(1, Number(jitterRatio) || 0));
    var base = Math.min(1500 * Math.pow(2, count), 30000);
    return Math.round(base + ratio * Math.min(750, base * 0.25));
}

function sortSessions(sessions) {
    var copy = Array.isArray(sessions) ? sessions.slice() : [];
    copy.sort(function(a, b) {
        var state = statePriority(a.state) - statePriority(b.state);
        if (state !== 0) return state;
        var ad = Date.parse(a.lastActivityAt || a.startedAt || 0) || 0;
        var bd = Date.parse(b.lastActivityAt || b.startedAt || 0) || 0;
        return bd - ad;
    });
    return copy;
}

function isAttentionState(state) {
    return state === "Failed" || state === "WaitingForPermission"
        || state === "WaitingForInput";
}

function activeState(state) {
    return state === "Working" || state === "Connecting"
        || state === "WaitingForPermission" || state === "WaitingForInput";
}

function totalHistoricalTokens(event) {
    if (!event || event.metricKind !== "event_delta") return null;
    var input = finiteNumber(event.inputTokens);
    var output = finiteNumber(event.outputTokens);
    if (input === null && output === null) return null;
    return (input || 0) + (output || 0);
}
