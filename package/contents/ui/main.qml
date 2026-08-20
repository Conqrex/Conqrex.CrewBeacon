import QtQuick
import QtQml.Models
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.notification
import "../code/format.js" as Fmt
import "../code/providers.js" as Providers
import "../code/paseo.js" as Paseo
import "../code/quota.js" as Quota

PlasmoidItem {
    id: root

    // --- state ------------------------------------------------------------
    // detectMap: id -> { detected: bool, reason: string }   (filesystem probe)
    // resultMap: id -> normalized envelope from usage.sh <provider>
    property var detectMap: ({})
    property var resultMap: ({})
    property double nowMs: Date.now()
    property string lastUpdated: ""

    // CrewBeacon observer state. Each PaseoSource owns one versioned read-only
    // connection; this root merges sources with the last durable snapshot.
    property var sourceSnapshots: ({})
    property var pendingSnapshots: ({})
    property var storedSnapshot: ({ sessions: [], hosts: [], usage: { ranges: {} } })
    property var usageDayDetail: ({ ok: true, date: "", repositories: [], providers: [], sessions: [], events: [] })
    property bool localImportRunning: false
    readonly property var configuredPaseoSources: parsePaseoSources(
        Plasmoid.configuration.showPaseoAgents,
        Plasmoid.configuration.paseoSources)
    readonly property var paseoAgentSessions: buildAgentSessions(sourceSnapshots,
                                                                  storedSnapshot.sessions || [])
    readonly property var localEditorSessions: buildLocalAgentSessions(
        assistantActivity && assistantActivity.sessions ? assistantActivity.sessions : [],
        paseoAgentSessions, Plasmoid.configuration.showLocalSessions)
    readonly property var agentSessions: Paseo.sortSessions(paseoAgentSessions.concat(localEditorSessions))
    readonly property var attentionSessions: buildAttentionSessions(agentSessions)
    readonly property var paseoHosts: buildHosts(sourceSnapshots, storedSnapshot.hosts || [])
    readonly property var repositoryUsage: usageForRange(storedSnapshot.usage,
                                                          Plasmoid.configuration.usageRange)
    readonly property var usageCalendar: (storedSnapshot.usage && storedSnapshot.usage.calendar)
                                           || ({ days: [], maxTokens: 0, maxEvents: 0 })

    function parsePaseoSources(enabled, raw) {
        if (!enabled) return []
        var parsed
        try { parsed = JSON.parse(raw || "[]") }
        catch (error) { parsed = [] }
        if (!Array.isArray(parsed)) return []
        var out = []
        var ids = {}
        for (var i = 0; i < parsed.length; i++) {
            var source = parsed[i] || {}
            var id = (source.id || "").trim()
            if (!id || ids[id]) continue
            ids[id] = true
            out.push({ id: id, name: source.name || id,
                       transport: source.transport === "relay" ? "relay" : "direct",
                       endpoint: source.endpoint || "ws://127.0.0.1:6767/ws",
                       offerFile: source.offerFile || "",
                       enabled: source.enabled !== false })
        }
        return out
    }

    function buildAgentSessions(liveSnapshots, storedSessions) {
        var out = []
        var seen = {}
        for (var sourceId in liveSnapshots) {
            var snapshot = liveSnapshots[sourceId] || {}
            var sessions = Array.isArray(snapshot.sessions) ? snapshot.sessions : []
            for (var i = 0; i < sessions.length; i++) {
                if (!sessions[i] || !sessions[i].key) continue
                out.push(sessions[i])
                seen[sessions[i].key] = true
            }
        }
        var stored = Array.isArray(storedSessions) ? storedSessions : []
        for (var j = 0; j < stored.length; j++) {
            if (stored[j] && stored[j].key && !seen[stored[j].key]
                    && Paseo.shouldRetainStoredSession(stored[j], liveSnapshots))
                out.push(stored[j])
        }
        return Paseo.sortSessions(out)
    }

    function normalizedDirectory(value) {
        return (value || "").replace(/\/+$/, "")
    }

    function buildLocalAgentSessions(activity, paseoSessions, enabled) {
        if (!enabled || !Array.isArray(activity)) return []
        var activePaseo = {}
        for (var p = 0; p < paseoSessions.length; p++) {
            var paseo = paseoSessions[p] || {}
            if (!paseo.workingDirectory || !paseo.providerId) continue
            activePaseo[(paseo.providerId + ":" + normalizedDirectory(paseo.workingDirectory)).toLowerCase()] = true
        }
        var out = []
        for (var i = 0; i < activity.length; i++) {
            var item = activity[i] || {}
            var provider = (item.provider || "agent").toLowerCase()
            var cwd = normalizedDirectory(item.cwd)
            if (cwd && activePaseo[(provider + ":" + cwd).toLowerCase()]) continue
            var state = item.state === "attention" ? "WaitingForInput"
                      : item.state === "working" ? "Working" : "Idle"
            var age = Math.max(0, Number(item.ageSec) || 0)
            var turn = Math.max(0, Number(item.turnSec) || 0)
            var lastActivity = new Date(Date.now() - age * 1000).toISOString()
            var started = turn > 0 ? new Date(Date.now() - turn * 1000).toISOString() : ""
            var surface = (item.surface || "").toLowerCase()
            var sourceLabel = surface.indexOf("vscode") !== -1 ? i18n("VS Code")
                            : surface.indexOf("desktop") !== -1 ? i18n("Desktop")
                            : i18n("Local editor / CLI")
            out.push({
                key: "local-activity:" + provider + ":" + (item.session || i),
                id: item.session || (provider + "-" + i),
                sourceId: "local-activity",
                sourceName: sourceLabel,
                hostId: "local",
                hostName: sourceLabel,
                providerId: provider,
                providerLabel: provider === "claude" ? "Claude" : provider === "codex" ? "Codex" : provider,
                modelId: item.model || "",
                title: item.name || i18n("Local session"),
                repositoryName: item.name || i18n("Local session"),
                workingDirectory: cwd,
                state: state,
                rawState: item.state || "idle",
                startedAt: started,
                lastActivityAt: lastActivity,
                endedAt: "",
                attentionReason: state === "WaitingForInput" ? i18n("Needs you") : "",
                deepLink: "",
                localActivity: true,
                stale: !!item.stale,
                sourceConnectionState: "Connected"
            })
        }
        return out
    }

    function buildAttentionSessions(sessions) {
        var out = []
        for (var i = 0; i < sessions.length; i++)
            if (Paseo.isAttentionState(sessions[i].state)) out.push(sessions[i])
        return out
    }

    function buildHosts(liveSnapshots, storedHosts) {
        var out = []
        var seen = {}
        for (var sourceId in liveSnapshots) {
            var host = liveSnapshots[sourceId] && liveSnapshots[sourceId].host
            if (!host) continue
            out.push(host)
            seen[host.id || sourceId] = true
        }
        var stored = Array.isArray(storedHosts) ? storedHosts : []
        for (var i = 0; i < stored.length; i++) {
            var id = stored[i] && (stored[i].id || stored[i].sourceId)
            if (id && !seen[id]) out.push(stored[i])
        }
        out.sort(function(a, b) {
            if (a.connectionState === "Connected" && b.connectionState !== "Connected") return -1
            if (b.connectionState === "Connected" && a.connectionState !== "Connected") return 1
            return (a.name || "").localeCompare(b.name || "")
        })
        return out
    }

    function usageForRange(usage, range) {
        var ranges = usage && usage.ranges ? usage.ranges : {}
        return ranges[range] || { totalTokens: 0, reportedCost: 0, repositories: [] }
    }

    // Assistant activity, polled from usage.sh activity. Claude is hook-backed;
    // Codex is inferred from recent local session logs.
    // { state: "working"|"idle"|"attention"|"none", sessions: [{provider, ...}] }
    property var assistantActivity: ({ state: "none", sessions: [] })
    readonly property string paseoActivityState: {
        if (!Plasmoid.configuration.showPaseoAgents || paseoAgentSessions.length === 0) return "none"
        for (var i = 0; i < paseoAgentSessions.length; i++)
            if (Paseo.isAttentionState(paseoAgentSessions[i].state)) return "attention"
        for (var j = 0; j < paseoAgentSessions.length; j++)
            if (paseoAgentSessions[j].state === "Working" || paseoAgentSessions[j].state === "Connecting") return "working"
        return "idle"
    }
    readonly property string activityState: paseoActivityState !== "none" ? paseoActivityState
        : ((Plasmoid.configuration.showActivity && assistantActivity && assistantActivity.state)
            ? assistantActivity.state : "none")
    readonly property var activitySessions:
        (Plasmoid.configuration.showActivity && assistantActivity && assistantActivity.sessions)
            ? assistantActivity.sessions : []
    readonly property bool activityVisible: activityState !== "none"

    readonly property int warnThreshold: Plasmoid.configuration.warnThreshold
    readonly property int criticalThreshold: Plasmoid.configuration.criticalThreshold
    readonly property string numberStyle: Plasmoid.configuration.numberStyle
    readonly property string usageDisplay: Plasmoid.configuration.usageDisplay
    readonly property bool monoText: numberStyle !== "percent"

    // --- helper command ---------------------------------------------------
    readonly property string scriptPath:
        Qt.resolvedUrl("../code/usage.sh").toString().replace(/^file:\/\//, "")
    readonly property string storeScriptPath:
        Qt.resolvedUrl("../code/crewbeacon_store.py").toString().replace(/^file:\/\//, "")
    readonly property string tokenArg: {
        var ts = (Plasmoid.configuration.tokenSource || "").trim();
        if (ts === "" || ts === "auto") return "auto";
        // POSIX single-quote escaping: a ' becomes '\'' so paths with quotes survive
        return "'" + ts.replace(/'/g, "'\\''") + "'";
    }
    function cmdFor(id) {
        var base = "bash '" + scriptPath + "' " + id;
        return id === "claude" ? base + " " + tokenArg : base;
    }
    readonly property string detectCmd: "bash '" + scriptPath + "' detect"
    readonly property string activityCmd: "bash '" + scriptPath + "' activity"

    function acceptSourceSnapshot(sourceId, snapshot) {
        var live = sourceSnapshots
        live[sourceId] = snapshot
        sourceSnapshots = live
        var pending = pendingSnapshots
        pending[sourceId] = snapshot
        pendingSnapshots = pending
        persistSnapshotsTimer.restart()
    }

    function applyStoredSnapshot(payload) {
        if (!payload || payload.ok === false) return
        storedSnapshot = {
            sessions: payload.sessions || storedSnapshot.sessions || [],
            hosts: payload.hosts || storedSnapshot.hosts || [],
            usage: payload.usage || storedSnapshot.usage || { ranges: {} }
        }
    }

    function storeCall(operation, payload, callback) {
        var command = "python3 " + shq(storeScriptPath) + " " + operation
        if (payload !== undefined && payload !== null)
            command += " " + shq(JSON.stringify(payload))
        storeExec.run(command, callback)
    }

    function loadUsageDay(dateKey) {
        if (!dateKey) return
        storeCall("usage-day", { date: dateKey }, function(result) {
            if (result && result.ok !== false) root.usageDayDetail = result
        })
    }

    function recordUsageEvent(event) {
        storeCall("record-usage", event, function(result) {
            if (!result || result.ok === false || !result.usage) return
            storedSnapshot = {
                sessions: storedSnapshot.sessions || [],
                hosts: storedSnapshot.hosts || [],
                usage: result.usage
            }
        })
    }

    function importLocalUsage() {
        if (!Plasmoid.configuration.recordLocalUsage || localImportRunning) return
        localImportRunning = true
        storeCall("import-local-usage", {
            historyDays: Plasmoid.configuration.localUsageHistoryDays
        }, function(result) {
            root.localImportRunning = false
            if (!result || result.ok === false || !result.usage) return
            root.storedSnapshot = {
                sessions: root.storedSnapshot.sessions || [],
                hosts: root.storedSnapshot.hosts || [],
                usage: result.usage
            }
            if (root.usageDayDetail && root.usageDayDetail.date)
                root.loadUsageDay(root.usageDayDetail.date)
        })
    }

    function agentNotificationEnabled(type) {
        switch (type) {
        case "WaitingForInput": return Plasmoid.configuration.notifyAgentInput
        case "WaitingForPermission": return Plasmoid.configuration.notifyAgentPermission
        case "Failed": return Plasmoid.configuration.notifyAgentFailed
        case "Completed": return Plasmoid.configuration.notifyAgentCompleted
        default: return false
        }
    }

    function recordAttentionEvent(event) {
        var stored = {}
        for (var key in event) stored[key] = event[key]
        if (!Plasmoid.configuration.persistMessagePreviews) stored.preview = ""
        storeCall("record-attention", stored, function(result) {
            if (!result || !result.inserted || !agentNotificationEnabled(event.type) || !canNotify()) return
            var title = (event.repositoryName || event.title || i18n("Agent"))
                      + " · " + (event.providerId || i18n("Agent"))
            var stateText = event.type === "WaitingForInput" ? i18n("Waiting for input")
                          : event.type === "WaitingForPermission" ? i18n("Waiting for permission")
                          : event.type === "Failed" ? i18n("Agent failed")
                          : i18n("Agent completed")
            var body = event.preview ? stateText + "\n" + event.preview : stateText
            fireNotification(title, body,
                event.type === "Completed" ? Notification.LowUrgency : Notification.HighUrgency)
        })
    }

    // --- config helpers ---------------------------------------------------
    function providerMode(id) {
        switch (id) {
        case "claude":  return Plasmoid.configuration.providerClaude;
        case "codex":   return Plasmoid.configuration.providerCodex;
        case "opencode": return Plasmoid.configuration.providerOpencode;
        case "copilot": return Plasmoid.configuration.providerCopilot;
        case "gemini":  return Plasmoid.configuration.providerGemini;
        }
        return "off";
    }

    // --- threshold / accent colors (unchanged behavior) -------------------
    function colorFor(pct) {
        if (pct >= criticalThreshold) return Kirigami.Theme.negativeTextColor;
        if (pct >= warnThreshold) return Kirigami.Theme.neutralTextColor;
        return Kirigami.Theme.positiveTextColor;
    }
    function accentBase(pct) {
        var a = Plasmoid.configuration.accent;
        if (a === "auto") return colorFor(pct);
        if (pct >= criticalThreshold) return Kirigami.Theme.negativeTextColor;
        switch (a) {
        case "cyan":   return Qt.rgba(0.20, 0.83, 0.92, 1);
        case "violet": return Qt.rgba(0.58, 0.46, 0.98, 1);
        case "lime":   return Qt.rgba(0.58, 0.86, 0.22, 1);
        case "amber":  return Qt.rgba(0.98, 0.73, 0.16, 1);
        case "rose":   return Qt.rgba(0.98, 0.44, 0.52, 1);
        case "mono":   return Kirigami.Theme.highlightColor;
        default:       return colorFor(pct);
        }
    }
    function fmt(pct) { return Fmt.formatValue(pct, root.numberStyle); }
    function displayPct(usedPct, displayMode) {
        var used = Fmt.clampPct(usedPct);
        return displayMode === "left" ? 100 - used : used;
    }

    // --- activity presentation --------------------------------------------
    function activityColor(state) {
        switch (state) {
        case "working":   return Qt.rgba(0.20, 0.83, 0.92, 1);     // cyan — generating
        case "idle":      return Kirigami.Theme.disabledTextColor; // muted — no action
        case "attention": return Kirigami.Theme.negativeTextColor; // red — needs you
        default:          return "transparent";
        }
    }
    function activityLabel(state) {
        switch (state) {
        case "working":   return i18n("working…");
        case "idle":      return i18n("idle");
        case "attention": return i18n("needs you");
        default:          return "";
        }
    }

    // --- notification gating ----------------------------------------------
    function parseHM(str) {
        var mt = /^\s*(\d{1,2}):(\d{2})\s*$/.exec(str || "");
        if (!mt) return null;
        var h = parseInt(mt[1], 10), mi = parseInt(mt[2], 10);
        if (h > 23 || mi > 59) return null;
        return h * 60 + mi;
    }
    function inQuietHours() {
        if (!Plasmoid.configuration.quietHoursEnabled) return false;
        var s = parseHM(Plasmoid.configuration.quietStart);
        var e = parseHM(Plasmoid.configuration.quietEnd);
        if (s === null || e === null || s === e) return false;
        var d = new Date();
        var m = d.getHours() * 60 + d.getMinutes();
        return (s < e) ? (m >= s && m < e)     // same-day window
                       : (m >= s || m < e);    // wraps past midnight
    }
    function canNotify() { return !inQuietHours(); }
    function fireNotification(title, text, urgency) {
        var props = { title: title, text: text }
        if (urgency !== undefined) props.urgency = urgency
        var n = resetNotifyComponent.createObject(root, props);
        if (n) n.sendEvent();
    }

    // --- which "extra" gauges the user opted into -------------------------
    function extraVisible(gaugeId) {
        if (gaugeId === "weeklySonnet") return Plasmoid.configuration.showWeeklySonnet;
        return false;
    }

    // ----------------------------------------------------------------------
    // Display model: an ordered array of provider rows, recomputed reactively
    // whenever the per-provider config, the detect probe, or a fetch result
    // changes. A row that is "auto" and undetected is omitted entirely; an
    // "on" row is always shown (as an error/loading row until data arrives).
    // ----------------------------------------------------------------------
    // Gauge accent colors recompute reactively on their own: enrichGauge() ->
    // accentBase() reads the accent/threshold config during this binding's
    // evaluation, so QML captures them as dependencies automatically.
    readonly property var providersList: buildProviders(
        Plasmoid.configuration.providerClaude,
        Plasmoid.configuration.providerCodex,
        Plasmoid.configuration.providerOpencode,
        Plasmoid.configuration.providerCopilot,
        Plasmoid.configuration.providerGemini,
        Plasmoid.configuration.usageDisplay,
        Plasmoid.configuration.hiddenQuotaWindows,
        Plasmoid.configuration.showWeeklySonnet,
        detectMap, resultMap)

    function enrichGauge(g, displayMode) {
        var usedPct = Fmt.clampPct(g.pct);
        var pct = displayPct(usedPct, displayMode);
        return {
            id: g.id, label: g.label, cap: g.cap, extra: !!g.extra,
            pct: pct, usedPct: usedPct, reset: g.reset || null, accent: accentBase(usedPct),
            // absolute counts (Copilot) passed straight through for the UI
            remaining: (g.remaining !== undefined ? g.remaining : null),
            entitlement: (g.entitlement !== undefined ? g.entitlement : null),
            unlimited: !!g.unlimited
        };
    }

    function buildProviders(mClaude, mCodex, mOpencode, mCopilot, mGemini, displayMode,
                            hiddenQuotaWindows, showWeeklySonnet, dmap, rmap) {
        var modes = { claude: mClaude, codex: mCodex, opencode: mOpencode,
                      copilot: mCopilot, gemini: mGemini };
        var out = [];
        for (var i = 0; i < Providers.ORDER.length; i++) {
            var id = Providers.ORDER[i];
            var providerSetting = Providers.mode(modes[id]);
            if (providerSetting === "off") continue;

            var det = dmap[id];
            var detected = det ? det.detected : false;
            if (providerSetting === "auto" && !detected) continue;   // auto: only when present

            var m = Providers.meta(id);
            var row = { id: id, label: m.label, badge: m.badge, color: m.color,
                        ok: false, reason: "", plan: null, gauges: [], loading: false,
                        stale: false, staleAgeSec: 0, bankedRefreshes: null };

            if (id === "gemini") {
                // detect-only: render an honest "tier retired" row, never fetched
                row.reason = det ? det.reason : "tier_retired";
            } else if (!detected) {
                row.reason = "no_credentials";          // forced on, but not signed in
            } else {
                var res = rmap[id];
                if (res) {
                    row.ok = !!res.ok;
                    row.reason = res.reason || "";
                    row.plan = res.plan || null;
                    row.stale = !!res.stale;
                    row.staleAgeSec = res.staleAgeSec || 0;
                    row.bankedRefreshes = (res.bankedRefreshes !== undefined) ? res.bankedRefreshes : null;
                    var quotaWindows = res.quotaSnapshot ? res.quotaSnapshot.windows : (res.gauges || []);
                    quotaWindows = Providers.visibleGauges(id, quotaWindows, hiddenQuotaWindows,
                                                          showWeeklySonnet);
                    row.gauges = quotaWindows.map(function(g) { return enrichGauge(g, displayMode); });
                } else {
                    row.loading = true;                  // detected, fetch in flight
                }
            }
            out.push(row);
        }
        return out;
    }

    // The set of providers that should actually be fetched over the network
    // (detected, live, and not disabled). Driven off the latest detect probe.
    function fetchTargets() {
        var ids = [];
        for (var i = 0; i < Providers.ORDER.length; i++) {
            var id = Providers.ORDER[i];
            if (providerMode(id) === "off") continue;
            if (!Providers.meta(id).live) continue;       // gemini is detect-only
            var det = detectMap[id];
            if (det && det.detected) ids.push(id);
        }
        return ids;
    }

    // --- compact (panel) gauge selection ----------------------------------
    function compactProviderIcon(providerId) {
        if (providerId === "claude") return Qt.resolvedUrl("../icons/providers/claude.svg")
        if (providerId === "codex") return Qt.resolvedUrl("../icons/providers/codex.svg")
        return ""
    }

    function decorateCompactItems(items) {
        var result = []
        for (var i = 0; i < items.length; i++) {
            var item = items[i]
            result.push({
                id: item.id,
                label: item.label,
                badge: item.badge,
                pct: item.pct,
                usedPct: item.usedPct,
                gaugeLabel: item.gaugeLabel,
                cap: item.cap,
                accent: accentBase(item.usedPct),
                valueText: fmt(item.pct),
                icon: compactProviderIcon(item.id)
            })
        }
        return result
    }

    readonly property var compactItems: decorateCompactItems(
        Providers.compactItems(providersList, Plasmoid.configuration.compactProvider))

    // ----------------------------------------------------------------------
    // Fetch plumbing
    // ----------------------------------------------------------------------
    function providerOfSource(src) {
        for (var i = 0; i < Providers.ORDER.length; i++) {
            var id = Providers.ORDER[i];
            if (new RegExp("usage\\.sh'\\s+" + id + "(\\s|$)").test(src)) return id;
        }
        return "";
    }

    function applyDetect(stdout) {
        try {
            var d = JSON.parse(stdout);
            root.detectMap = (d && d.providers) ? d.providers : {};
        } catch (e) {
            root.detectMap = {};
        }
        // now fetch everything that is detected + live + enabled
        var targets = fetchTargets();
        for (var i = 0; i < targets.length; i++) exec.run(cmdFor(targets[i]));
    }

    function applyResult(id, stdout) {
        var result;
        try {
            result = JSON.parse(stdout);
            result.quotaSnapshot = Quota.normalizeEnvelope(id, result);
        } catch (e) {
            result = { ok: false, reason: "parse_error", gauges: [] };
        }
        root.resultMap = Quota.withProviderResult(root.resultMap, id, result);
        root.lastUpdated = Qt.formatTime(new Date(),
            Plasmoid.configuration.timeFormat24h ? "HH:mm" : "h:mm AP");
        root.checkResets(id, result);
        root.checkThresholds(id, result);
        root.checkSignIn(id, result);
    }

    // ----------------------------------------------------------------------
    // Early-reset alerts
    // ----------------------------------------------------------------------
    // Watch the long (weekly/monthly) usage windows and raise a desktop
    // notification when one rolls over *before* its previously-known reset time
    // — i.e. an early reset initiated upstream, ahead of the user's normal
    // schedule. The 5-hour session windows are ignored (they roll constantly and
    // always on time), as is the optional Sonnet gauge (it tracks the weekly).
    //
    // Detection is drift-proof: we compare how far a window's reset time
    // advanced against the wall time elapsed between the two *fetches* (each
    // envelope carries `fetchedAt`). A window whose reset is reported relative
    // to "now" (e.g. Codex's reset_after_seconds) drifts forward in lockstep
    // with elapsed time, so its advance never exceeds elapsed+margin and never
    // counts. A genuine roll jumps a whole period forward at once, far faster
    // than the clock, so it does. State is kept in memory only — no config
    // churn — which means a reset during a Plasma restart isn't alerted (the
    // widget polls every ≤2 min while running, when it matters).
    readonly property int rollMarginMs: 10 * 60 * 1000     // reset must outrun the clock by >10 min
    readonly property int earlyMarginMs: 60 * 60 * 1000    // "early" = old reset was still >1h away

    // key ("provider:gaugeId") -> { reset: ms, seen: ms(fetchedAt) }
    property var resetWatch: ({})

    function isSessionWindow(gid) { return gid === "session" || gid === "primary"; }

    function checkResets(id, res) {
        if (!res || !res.ok || !res.gauges || res.gauges.length === 0) return;

        var fetchedMs = Date.parse(res.fetchedAt);
        if (isNaN(fetchedMs)) fetchedMs = Date.now();      // defensive; envelopes always set it
        var now = Date.now();
        var w = root.resetWatch;
        var early = [];                                    // windows that reset ahead of time

        for (var i = 0; i < res.gauges.length; i++) {
            var g = res.gauges[i];
            if (root.isSessionWindow(g.id) || g.extra) continue;   // long windows only
            var curReset = Date.parse(g.reset);
            if (isNaN(curReset)) continue;                 // need a schedule to judge timing

            var key = id + ":" + g.id;
            var prev = w[key];
            if (prev && fetchedMs > prev.seen) {           // only act on genuinely newer data
                var elapsed = fetchedMs - prev.seen;       // wall time between the two fetches
                var jump = curReset - prev.reset;          // how far the reset time advanced
                if (jump > elapsed + root.rollMarginMs     // advanced faster than the clock -> rolled
                        && (prev.reset - now) > root.earlyMarginMs)  // old reset was still ahead -> early
                    early.push({ label: g.label, due: prev.reset });
            }
            if (!prev || fetchedMs > prev.seen) w[key] = { reset: curReset, seen: fetchedMs };
        }

        if (early.length > 0 && Plasmoid.configuration.notifyResetEarly && root.canNotify())
            root.notifyEarlyReset(Providers.meta(id).label, early);
    }

    // --- threshold-crossing alerts ----------------------------------------
    // Fire once when a gauge first climbs past each configured milestone within
    // a window. Re-arms when the window's reset rolls over. A fresh observation
    // (widget start / new window) arms silently so a restart never alert-storms.
    property var thresholdState: ({})    // "provider:gaugeId" -> { reset, level }

    function thresholdMilestones() {
        var raw = ("" + (Plasmoid.configuration.thresholdLevels || "")).split(",");
        var out = [];
        for (var i = 0; i < raw.length; i++) {
            var v = parseInt(raw[i], 10);
            if (!isNaN(v) && v > 0 && v <= 100) out.push(v);
        }
        out.sort(function(a, b) { return a - b; });
        return out;
    }
    function checkThresholds(id, res) {
        if (!res || !res.ok || !res.gauges) return;
        var levels = thresholdMilestones();
        if (levels.length === 0) return;
        var st = root.thresholdState;
        var fired = [];
        for (var i = 0; i < res.gauges.length; i++) {
            var g = res.gauges[i];
            if (g.extra) continue;
            var key = id + ":" + g.id;
            var resetIso = g.reset || "";
            var prev = st[key];
            // A genuine window roll jumps the reset far forward; a window whose
            // reset is reported relative to "now" (Codex) drifts a little each
            // poll — treat only a >1h change as a new window, so drift doesn't
            // keep silently re-arming and suppressing every alert.
            var isNew;
            if (!prev) {
                isNew = true;
            } else {
                var a = Date.parse(prev.reset), b = Date.parse(resetIso);
                isNew = (isNaN(a) || isNaN(b)) ? (prev.reset !== resetIso)
                                               : (Math.abs(b - a) > 3600000);
            }
            var pct = Fmt.clampPct(g.pct);
            var hit = 0;
            for (var j = 0; j < levels.length; j++) if (pct >= levels[j]) hit = levels[j];
            if (isNew) {
                st[key] = { reset: resetIso, level: hit };          // arm silently
            } else {
                if (hit > prev.level) fired.push({ label: g.label, level: hit });
                st[key] = { reset: resetIso, level: Math.max(prev.level, hit) };
            }
        }
        if (fired.length > 0 && Plasmoid.configuration.notifyThresholds && root.canNotify())
            for (var k = 0; k < fired.length; k++)
                root.fireNotification(
                    i18n("%1 usage at %2%", Providers.meta(id).label, fired[k].level),
                    i18n("%1 has reached %2% of its limit.", fired[k].label, fired[k].level));
    }

    // --- sign-in-expired alerts -------------------------------------------
    // One notification on the ok -> expired transition per provider (cleared on
    // recovery), so a persistently-expired token doesn't re-alert every poll.
    property var signInState: ({})       // provider -> last reason

    function isExpiredReason(r) {
        return r === "token_expired" || r === "http_401" || r === "http_403";
    }
    function checkSignIn(id, res) {
        var reason = (res && res.ok) ? "" : (res ? (res.reason || "") : "");
        var prev = root.signInState[id] || "";
        if (isExpiredReason(reason) && !isExpiredReason(prev)
                && Plasmoid.configuration.notifySignIn && root.canNotify()) {
            var label = Providers.meta(id).label;
            root.fireNotification(i18n("%1 sign-in expired", label),
                i18n("Re-authenticate %1, then refresh the widget.", label));
        }
        root.signInState[id] = reason;
    }

    // --- "Claude needs you" alerts ----------------------------------------
    // Fire when a session enters the attention state (permission/question),
    // diffed across activity polls so each event alerts once.
    property var prevSessionState: ({})  // session id -> last state
    property bool activityArmed: false   // first poll seeds state silently (no restart storm)

    function checkActivityAlerts(act) {
        var sessions = (act && act.sessions) ? act.sessions : [];
        var armed = root.activityArmed;
        var seen = {};
        var newly = [];
        for (var i = 0; i < sessions.length; i++) {
            var s = sessions[i];
            var provider = s.provider || "claude";
            if (provider !== "claude") continue;
            var key = provider + ":" + s.session;
            seen[key] = true;
            var prev = root.prevSessionState[key] || "";
            if (armed && s.state === "attention" && prev !== "attention") newly.push(s);
            root.prevSessionState[key] = s.state;
        }
        for (var key in root.prevSessionState)
            if (!seen[key]) delete root.prevSessionState[key];   // forget ended sessions
        root.activityArmed = true;
        if (newly.length > 0 && Plasmoid.configuration.notifyNeedsYou && root.canNotify())
            for (var j = 0; j < newly.length; j++) {
                var nm = (newly[j].name && newly[j].name !== "") ? newly[j].name : i18n("Claude");
                root.fireNotification(i18n("Claude needs you"),
                    i18n("%1 is waiting for your input.", nm));
            }
    }

    function notifyEarlyReset(providerLabel, early) {
        var use24 = Plasmoid.configuration.timeFormat24h;
        var title = i18n("%1 usage reset early", providerLabel);
        var text;
        if (early.length === 1) {
            text = i18n("Your %1 limit reset ahead of schedule — it was due %2. Fresh quota is available.",
                        early[0].label, Fmt.formatResetTime(new Date(early[0].due), use24));
        } else {
            var lines = [];
            for (var i = 0; i < early.length; i++)
                lines.push(i18n("%1 — was due %2", early[i].label,
                                Fmt.formatResetTime(new Date(early[i].due), use24)));
            text = lines.join("\n");
        }
        var n = resetNotifyComponent.createObject(root, { title: title, text: text });
        if (n) n.sendEvent();
    }

    // A fresh KNotification per alert, so two windows that reset early in the
    // same poll don't overwrite each other (each gets its own notification id).
    Component {
        id: resetNotifyComponent
        Notification {
            componentName: "plasma_workspace"
            eventId: "notification"
            iconName: "crewbeacon"
            flags: Notification.Persistent
            urgency: Notification.HighUrgency
            autoDelete: false
            onClosed: destroy()
        }
    }

    Instantiator {
        id: sourceInstantiator
        model: root.configuredPaseoSources
        delegate: PaseoSource {
            required property var modelData
            sourceConfig: modelData
            retentionHours: Math.max(1, Plasmoid.configuration.agentRetentionHours)
            onSnapshotChanged: (snapshot) => root.acceptSourceSnapshot(sourceId, snapshot)
            onUsageObserved: (event) => root.recordUsageEvent(event)
            onAttentionObserved: (event) => root.recordAttentionEvent(event)
        }
    }

    function refreshPaseoSources() {
        for (var i = 0; i < sourceInstantiator.count; i++) {
            var source = sourceInstantiator.objectAt(i)
            if (source) source.refresh()
        }
    }

    Timer {
        id: persistSnapshotsTimer
        interval: 500
        repeat: false
        onTriggered: {
            var snapshots = root.pendingSnapshots
            root.pendingSnapshots = ({})
            for (var sourceId in snapshots)
                root.storeCall("sync-snapshot", snapshots[sourceId], function() {})
        }
    }

    Plasma5Support.DataSource {
        id: storeExec
        engine: "executable"
        connectedSources: []
        property var callbacks: ({})
        property int serial: 0
        onNewData: (source, data) => {
            var callback = callbacks[source]
            delete callbacks[source]
            var parsed = null
            try { parsed = JSON.parse(("" + (data["stdout"] || "")).trim()) }
            catch (error) { parsed = { ok: false, error: "store_parse_error" } }
            if (callback) callback(parsed, data["exit code"])
            disconnectSource(source)
        }
        function run(command, callback) {
            if (!command) return
            serial += 1
            var unique = command + " # crewbeacon-store-" + serial
            callbacks[unique] = callback || function() {}
            connectSource(unique)
        }
    }

    Component.onCompleted: storeCall("snapshot", null, function(result) {
        root.applyStoredSnapshot(result)
        root.importLocalUsage()
    })

    Plasma5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            var out = ("" + data["stdout"]).trim();
            if (providerOfSource(source) === "" && source.indexOf(" detect") !== -1) {
                if (data["exit code"] === 0) root.applyDetect(out);
                disconnectSource(source);
                return;
            }
            var id = providerOfSource(source);
            if (id !== "") {
                if (data["exit code"] === 0) root.applyResult(id, out);
                else root.resultMap = Quota.withProviderResult(root.resultMap, id,
                    { ok: false, reason: "exec_error", gauges: [] });
            }
            disconnectSource(source);
        }
        function run(cmd) { if (cmd) connectSource(cmd); }
    }

    function refresh() { exec.run(root.detectCmd); }
    function refreshAll() {
        root.refresh()
        root.refreshPaseoSources()
        root.storeCall("snapshot", null, function(result) {
            root.applyStoredSnapshot(result)
            root.importLocalUsage()
        })
    }

    // poll: re-detect (cheap, filesystem-only) then fetch the enabled providers.
    // Re-detecting each tick means a fresh `codex login` shows up automatically.
    Timer {
        interval: Math.max(30, Plasmoid.configuration.refreshInterval) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        interval: Math.max(120, Plasmoid.configuration.refreshInterval) * 1000
        running: Plasmoid.configuration.recordLocalUsage
        repeat: true
        onTriggered: root.importLocalUsage()
    }

    // keep reset countdowns live without re-fetching
    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.nowMs = Date.now()
    }

    // --- activity poll ------------------------------------------------------
    // A lightweight read of Claude hook state and recent Codex session logs.
    // Runs while local rows, the panel indicator, or local alerts are enabled.
    Plasma5Support.DataSource {
        id: activityExec
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            if (data["exit code"] === 0) {
                try {
                    var act = JSON.parse(("" + data["stdout"]).trim());
                    root.assistantActivity = act;
                    root.checkActivityAlerts(act);
                } catch (e) { /* keep previous state on a transient parse error */ }
            }
            disconnectSource(source);
        }
        function run(cmd) { if (cmd) connectSource(cmd); }
    }
    // Local session rows and alerts work even when the panel dot is hidden.
    Timer {
        interval: 3000
        running: Plasmoid.configuration.showLocalSessions
              || Plasmoid.configuration.showActivity
              || Plasmoid.configuration.notifyNeedsYou
        repeat: true
        triggeredOnStart: true
        onTriggered: activityExec.run(root.activityCmd)
    }

    // --- actions: launch / clipboard / context menu -----------------------
    // Fire-and-forget runner for xdg-open and the session-open command.
    Plasma5Support.DataSource {
        id: launcher
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => disconnectSource(source)
        function run(cmd) { if (cmd) connectSource(cmd); }
    }
    // Hidden editor used only to put text on the clipboard (works on X11 and
    // Wayland without wl-copy/xclip, which aren't always installed).
    TextEdit { id: clipHelper; visible: false }

    function shq(s) { return "'" + ("" + s).replace(/'/g, "'\\''") + "'"; }
    function openUrl(url) { if (url) launcher.run("xdg-open " + shq(url)); }
    function copyToClipboard(text) {
        clipHelper.text = text; clipHelper.selectAll(); clipHelper.copy(); clipHelper.text = "";
    }
    function copySummary() { copyToClipboard(tooltipText()); }
    function openSession(cwd) {
        if (!cwd) return;
        var tmpl = Plasmoid.configuration.sessionCommand || "konsole --workdir %d";
        var cmd = (tmpl.indexOf("%d") !== -1) ? tmpl.replace(/%d/g, shq(cwd))
                                              : tmpl + " " + shq(cwd);
        launcher.run(cmd);
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh now")
            icon.name: "view-refresh"
            onTriggered: root.refreshAll()
        },
        PlasmaCore.Action {
            text: i18n("Copy CrewBeacon summary")
            icon.name: "edit-copy"
            onTriggered: root.copySummary()
        },
        PlasmaCore.Action {
            text: i18n("Open Claude dashboard")
            icon.name: "internet-web-browser"
            onTriggered: root.openUrl(Providers.meta("claude").dash)
        }
    ]

    // --- tooltip ----------------------------------------------------------
    function tooltipReason(reason) {
        switch (reason) {
        case "tier_retired":   return i18n("unavailable");
        case "no_credentials":
        case "no_token":       return i18n("not signed in");
        case "token_expired":
        case "http_401":
        case "http_403":       return i18n("sign-in expired");
        default:               return i18n("unavailable");
        }
    }
    function tooltipText() {
        var parts = [];
        if (Plasmoid.configuration.showPaseoAgents) {
            var working = 0, waiting = 0, failed = 0
            for (var a = 0; a < agentSessions.length; a++) {
                if (agentSessions[a].state === "Working" || agentSessions[a].state === "Connecting") working++
                else if (agentSessions[a].state === "WaitingForInput"
                         || agentSessions[a].state === "WaitingForPermission") waiting++
                else if (agentSessions[a].state === "Failed") failed++
            }
            parts.push(i18n("Agents: %1 working · %2 waiting · %3 failed", working, waiting, failed))
            for (var h = 0; h < paseoHosts.length; h++)
                if (paseoHosts[h].connectionState !== "Connected")
                    parts.push(i18n("%1: %2", paseoHosts[h].name || paseoHosts[h].hostname,
                                    paseoHosts[h].connectionState || i18n("offline")))
            if (repositoryUsage.totalTokens > 0)
                parts.push(i18n("Repository usage: %1 tokens", repositoryUsage.totalTokens))
        }
        for (var i = 0; i < providersList.length; i++) {
            var r = providersList[i];
            if (r.ok && r.gauges && r.gauges.length > 0) {
                var segs = [];
                for (var j = 0; j < r.gauges.length; j++) {
                    if (r.gauges[j].extra && !extraVisible(r.gauges[j].id)) continue;
                    segs.push(r.gauges[j].cap + " " + Fmt.clampPct(r.gauges[j].pct) + "%"
                              + (root.usageDisplay === "left" ? " " + i18n("left") : " " + i18n("used")));
                }
                parts.push(r.label + "  " + segs.join(" · "));
            } else if (r.loading) {
                parts.push(r.label + "  " + i18n("loading…"));
            } else {
                parts.push(r.label + "  " + tooltipReason(r.reason));
            }
        }
        return parts.length ? parts.join("\n") : i18n("No usage sources detected");
    }

    toolTipMainText: i18n("CrewBeacon")
    toolTipSubText: tooltipText()

    compactRepresentation: CompactView {
        items: root.compactItems
        mono: root.monoText
        showValue: Plasmoid.configuration.showCompactValue
        showProviderIcons: Plasmoid.configuration.compactUseProviderIcons
        activityShow: root.activityVisible
        activityColor: root.activityColor(root.activityState)
        activityPulse: root.activityState === "working"
        onToggleRequested: root.expanded = !root.expanded
    }

    fullRepresentation: FullView {
        providers: root.providersList
        agentSessions: root.agentSessions
        attentionSessions: root.attentionSessions
        hosts: root.paseoHosts
        repositoryUsage: root.repositoryUsage
        usageCalendar: root.usageCalendar
        usageDayDetail: root.usageDayDetail
        usageRange: Plasmoid.configuration.usageRange
        nowMs: root.nowMs
        lastUpdated: root.lastUpdated
        use24h: Plasmoid.configuration.timeFormat24h
        numberStyle: root.numberStyle
        usageDisplay: root.usageDisplay
        mono: root.monoText
        gaugeStyle: Plasmoid.configuration.gaugeStyle
        showWeeklySonnet: Plasmoid.configuration.showWeeklySonnet
        activityShow: root.activityVisible
        activitySessions: root.activitySessions
        onRefreshRequested: root.refreshAll()
        onOpenSessionRequested: (cwd) => root.openSession(cwd)
        onUsageDayRequested: (dateKey) => root.loadUsageDay(dateKey)
        onOpenAgentRequested: (deepLink) => root.openUrl(deepLink)
    }
}
