import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

KCM.SimpleKCM {
    id: page

    // alias-backed entries
    property alias cfg_refreshInterval: intervalSpin.value
    property alias cfg_warnThreshold: warnSpin.value
    property alias cfg_criticalThreshold: critSpin.value
    property alias cfg_showCompactValue: compactValueBox.checked
    property alias cfg_compactUseProviderIcons: compactIconsBox.checked
    property alias cfg_useSystemTheme: sysThemeBox.checked
    property alias cfg_showWeeklySonnet: sonnetBox.checked
    property alias cfg_timeFormat24h: time24Box.checked
    property alias cfg_notifyResetEarly: notifyResetBox.checked
    property alias cfg_notifyThresholds: thresholdsBox.checked
    property alias cfg_thresholdLevels: thresholdField.text
    property alias cfg_notifySignIn: signInBox.checked
    property alias cfg_notifyNeedsYou: needsYouBox.checked
    property alias cfg_quietHoursEnabled: quietBox.checked
    property alias cfg_quietStart: quietStartField.text
    property alias cfg_quietEnd: quietEndField.text
    property alias cfg_showActivity: activityBox.checked
    property alias cfg_showLocalSessions: localSessionsBox.checked
    property alias cfg_recordLocalUsage: localUsageBox.checked
    property alias cfg_localUsageHistoryDays: localHistorySpin.value
    property alias cfg_sessionCommand: sessionCommandField.text
    property alias cfg_tokenSource: tokenField.text
    property alias cfg_showPaseoAgents: paseoAgentsBox.checked
    property alias cfg_agentRetentionHours: agentRetentionSpin.value
    property alias cfg_notifyAgentInput: agentInputBox.checked
    property alias cfg_notifyAgentPermission: agentPermissionBox.checked
    property alias cfg_notifyAgentFailed: agentFailedBox.checked
    property alias cfg_notifyAgentCompleted: agentCompletedBox.checked
    property alias cfg_persistMessagePreviews: previewBox.checked

    // combo-backed entries (plain string properties the config system reads)
    property string cfg_gaugeStyle: "ring"
    property string cfg_numberStyle: "percent"
    property string cfg_usageDisplay: "used"
    property string cfg_accent: "auto"
    property string cfg_providerClaude: "auto"
    property string cfg_providerCodex: "auto"
    property string cfg_providerCopilot: "auto"
    property string cfg_providerGemini: "auto"
    property string cfg_compactProvider: "all-weekly"
    property string cfg_usageRange: "today"

    // --- live auto-detect status (filesystem probe, no secrets) ------------
    property var detectStatus: ({})
    readonly property string scriptPath:
        Qt.resolvedUrl("../code/usage.sh").toString().replace(/^file:\/\//, "")

    function statusText(id) {
        var s = detectStatus[id];
        if (!s) return "";
        if (s.reason === "tier_retired") return i18n("Detected · tier retired");
        return s.detected ? i18n("Detected ✓") : i18n("Not found");
    }
    function statusColor(id) {
        var s = detectStatus[id];
        if (!s) return Kirigami.Theme.disabledTextColor;
        if (s.reason === "tier_retired") return Kirigami.Theme.neutralTextColor;
        return s.detected ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor;
    }

    Plasma5Support.DataSource {
        id: detectSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            if (data["exit code"] === 0) {
                try {
                    var d = JSON.parse(("" + data["stdout"]).trim());
                    page.detectStatus = (d && d.providers) ? d.providers : {};
                } catch (e) { /* ignore */ }
            }
            disconnectSource(source);
        }
        function run(cmd) { if (cmd) connectSource(cmd); }
    }
    Component.onCompleted: {
        detectSource.run("bash '" + page.scriptPath + "' detect")
        page.refreshHookStatus()
    }

    // --- Claude Code activity-hook install status -------------------------
    property string hookStatus: "unknown"
    function refreshHookStatus() { hookSource.run("bash '" + page.scriptPath + "' hooks-status") }
    function hookStatusText() {
        switch (page.hookStatus) {
        case "installed": return i18n("Hooks installed ✓")
        case "partial":   return i18n("Hooks partially installed")
        case "foreign":   return i18n("Hooks set up for a different install")
        case "missing":   return i18n("Hooks not set up")
        default:          return ""
        }
    }
    function hookStatusColor() {
        switch (page.hookStatus) {
        case "installed": return Kirigami.Theme.positiveTextColor
        case "partial":
        case "foreign":   return Kirigami.Theme.neutralTextColor
        default:          return Kirigami.Theme.disabledTextColor
        }
    }
    Plasma5Support.DataSource {
        id: hookSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            if (source.indexOf("hooks-status") === -1) {
                // an install/remove finished — re-read the status
                disconnectSource(source)
                page.refreshHookStatus()
                return
            }
            if (data["exit code"] === 0) {
                try { page.hookStatus = (JSON.parse(("" + data["stdout"]).trim()).status) || "unknown" }
                catch (e) { page.hookStatus = "unknown" }
            }
            disconnectSource(source)
        }
        function run(cmd) { if (cmd) connectSource(cmd) }
    }

    // a tri-state provider combo + live status, sharing one form row
    component ProviderRow: RowLayout {
        property string pid
        property string value
        signal picked(string v)
        spacing: Kirigami.Units.smallSpacing

        QQC2.ComboBox {
            textRole: "label"
            valueRole: "key"
            model: [
                { key: "auto", label: i18n("Auto (show if detected)") },
                { key: "on",   label: i18n("Always show") },
                { key: "off",  label: i18n("Hidden") }
            ]
            currentIndex: Math.max(0, indexOfValue(value))
            onActivated: picked(currentValue)
        }
        QQC2.Label {
            text: page.statusText(pid)
            color: page.statusColor(pid)
            font: Kirigami.Theme.smallFont
        }
    }

    Kirigami.FormLayout {

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Providers") }

        ProviderRow {
            Kirigami.FormData.label: i18n("Claude:")
            pid: "claude"; value: page.cfg_providerClaude
            onPicked: (v) => page.cfg_providerClaude = v
        }
        ProviderRow {
            Kirigami.FormData.label: i18n("Codex:")
            pid: "codex"; value: page.cfg_providerCodex
            onPicked: (v) => page.cfg_providerCodex = v
        }
        ProviderRow {
            Kirigami.FormData.label: i18n("GitHub Copilot:")
            pid: "copilot"; value: page.cfg_providerCopilot
            onPicked: (v) => page.cfg_providerCopilot = v
        }
        ProviderRow {
            Kirigami.FormData.label: i18n("Gemini:")
            pid: "gemini"; value: page.cfg_providerGemini
            onPicked: (v) => page.cfg_providerGemini = v
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Each provider appears automatically when its CLI is signed in. Gemini's free tier was retired, so it shows as unavailable.")
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("CrewBeacon agents") }

        QQC2.CheckBox {
            id: paseoAgentsBox
            text: i18n("Monitor configured Paseo sources")
        }

        QQC2.CheckBox {
            id: localSessionsBox
            text: i18n("Show local Claude/Codex editor and CLI sessions")
        }

        QQC2.CheckBox {
            id: localUsageBox
            text: i18n("Record local Claude/Codex usage history")
        }

        QQC2.SpinBox {
            id: localHistorySpin
            from: 1; to: 30
            enabled: localUsageBox.checked
            Kirigami.FormData.label: i18n("Scan updated logs (days):")
        }

        QQC2.SpinBox {
            id: agentRetentionSpin
            from: 1; to: 168
            Kirigami.FormData.label: i18n("Keep completed agents (h):")
        }

        QQC2.ComboBox {
            id: usageRangeCombo
            Kirigami.FormData.label: i18n("Usage summary:")
            textRole: "label"
            valueRole: "key"
            model: [
                { key: "today", label: i18n("Today") },
                { key: "week", label: i18n("This week") },
                { key: "month", label: i18n("This month") }
            ]
            currentIndex: Math.max(0, indexOfValue(page.cfg_usageRange))
            onActivated: page.cfg_usageRange = currentValue
        }

        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Paseo sources are read-only. Local history reads only provider-reported usage counters and session metadata from Claude/Codex JSONL logs; prompts and responses are never stored. Imports are incremental and bounded. Context-window occupancy is never counted as consumed tokens.")
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Agent alerts") }

        QQC2.CheckBox { id: agentInputBox; text: i18n("Agent explicitly waits for input") }
        QQC2.CheckBox { id: agentPermissionBox; text: i18n("Agent requests permission") }
        QQC2.CheckBox { id: agentFailedBox; text: i18n("Agent fails") }
        QQC2.CheckBox { id: agentCompletedBox; text: i18n("Agent completes") }
        QQC2.CheckBox {
            id: previewBox
            text: i18n("Persist sanitized attention previews")
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Preview persistence is off by default. Repository, provider, host, state, and deduplication metadata are stored locally in SQLite so reconnects do not repeat notifications.")
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.CheckBox {
            id: sysThemeBox
            text: i18n("Use Plasma system colors")
        }

        QQC2.ComboBox {
            id: styleCombo
            Kirigami.FormData.label: i18n("Visual style:")
            textRole: "label"
            valueRole: "key"
            model: [
                { key: "ring", label: i18n("Ring gauges") },
                { key: "bar",  label: i18n("Bars") }
            ]
            currentIndex: Math.max(0, indexOfValue(page.cfg_gaugeStyle))
            onActivated: page.cfg_gaugeStyle = currentValue
        }

        QQC2.ComboBox {
            id: numberCombo
            Kirigami.FormData.label: i18n("Number style:")
            textRole: "label"
            valueRole: "key"
            model: [
                { key: "percent", label: i18n("Percent  —  36%") },
                { key: "binary",  label: i18n("Binary  —  0100100") },
                { key: "blocks",  label: i18n("Blocks  —  ▰▰▰▰▱▱▱▱▱▱") }
            ]
            currentIndex: Math.max(0, indexOfValue(page.cfg_numberStyle))
            onActivated: page.cfg_numberStyle = currentValue
        }

        QQC2.ComboBox {
            id: usageDisplayCombo
            Kirigami.FormData.label: i18n("Usage shows:")
            textRole: "label"
            valueRole: "key"
            model: [
                { key: "used", label: i18n("Used quota") },
                { key: "left", label: i18n("Quota left") }
            ]
            currentIndex: Math.max(0, indexOfValue(page.cfg_usageDisplay))
            onActivated: page.cfg_usageDisplay = currentValue
        }

        QQC2.ComboBox {
            id: accentCombo
            Kirigami.FormData.label: i18n("Accent:")
            textRole: "label"
            valueRole: "key"
            model: [
                { key: "auto",   label: i18n("Auto (green → amber → red)") },
                { key: "cyan",   label: i18n("Cyan") },
                { key: "violet", label: i18n("Violet") },
                { key: "lime",   label: i18n("Lime") },
                { key: "amber",  label: i18n("Amber") },
                { key: "rose",   label: i18n("Rose") },
                { key: "mono",   label: i18n("Theme highlight") }
            ]
            currentIndex: Math.max(0, indexOfValue(page.cfg_accent))
            onActivated: page.cfg_accent = currentValue
        }

        QQC2.ComboBox {
            id: compactCombo
            Kirigami.FormData.label: i18n("Panel shows:")
            textRole: "label"
            valueRole: "key"
            model: [
                { key: "all-weekly", label: i18n("All visible weekly providers") },
                { key: "first",   label: i18n("First enabled provider") },
                { key: "hottest", label: i18n("Busiest gauge") },
                { key: "claude",  label: i18n("Claude") },
                { key: "codex",   label: i18n("Codex") },
                { key: "copilot", label: i18n("GitHub Copilot") }
            ]
            currentIndex: Math.max(0, indexOfValue(page.cfg_compactProvider))
            onActivated: page.cfg_compactProvider = currentValue
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.CheckBox {
            id: compactIconsBox
            text: i18n("Show provider icons inside panel rings")
        }
        QQC2.CheckBox {
            id: compactValueBox
            text: i18n("Show percentage when an icon is unavailable")
        }
        QQC2.CheckBox {
            id: sonnetBox
            text: i18n("Show Claude weekly Sonnet gauge")
        }
        QQC2.CheckBox {
            id: time24Box
            text: i18n("Use 24-hour time")
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Alerts") }

        QQC2.CheckBox {
            id: notifyResetBox
            text: i18n("Notify me when a limit resets early")
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Pops a desktop notification when a weekly or monthly limit resets before its scheduled time — e.g. when your Claude quota is reset ahead of your normal weekly reset. Normal on-time resets stay silent, and the rolling 5-hour session window is ignored.")
        }

        RowLayout {
            spacing: Kirigami.Units.smallSpacing
            QQC2.CheckBox {
                id: thresholdsBox
                text: i18n("Notify when usage crosses")
            }
            QQC2.TextField {
                id: thresholdField
                enabled: thresholdsBox.checked
                Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                placeholderText: "80,95"
            }
            QQC2.Label { text: i18n("%"); opacity: 0.7 }
        }

        QQC2.CheckBox {
            id: signInBox
            text: i18n("Notify when a provider's sign-in expires")
        }
        QQC2.CheckBox {
            id: needsYouBox
            text: i18n("Notify when a Claude session needs you")
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Fires when a chat hits a permission prompt or asks you a question. Requires the activity hooks (set up below).")
        }

        QQC2.CheckBox {
            id: quietBox
            text: i18n("Quiet hours (mute all alerts)")
        }
        RowLayout {
            enabled: quietBox.checked
            spacing: Kirigami.Units.smallSpacing
            QQC2.TextField {
                id: quietStartField
                Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                placeholderText: "23:00"
            }
            QQC2.Label { text: i18n("to"); opacity: 0.7 }
            QQC2.TextField {
                id: quietEndField
                Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                placeholderText: "07:00"
            }
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Local activity") }

        QQC2.CheckBox {
            id: activityBox
            text: i18n("Show local activity on the panel icon")
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("The Agents list can show local sessions independently. This option also adds their aggregate working, idle, or needs-you state to the panel icon. Claude uses hooks for live state; Codex is inferred from recent local session logs.")
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Claude hooks:")
            spacing: Kirigami.Units.smallSpacing
            QQC2.Button {
                text: i18n("Set up")
                icon.name: "install"
                onClicked: hookSource.run("bash '" + page.scriptPath + "' hooks-install")
            }
            QQC2.Button {
                text: i18n("Remove")
                icon.name: "edit-delete"
                enabled: page.hookStatus === "installed" || page.hookStatus === "partial" || page.hookStatus === "foreign"
                onClicked: hookSource.run("bash '" + page.scriptPath + "' hooks-remove")
            }
            QQC2.Label {
                text: page.hookStatusText()
                color: page.hookStatusColor()
                font: Kirigami.Theme.smallFont
            }
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Writes the six Claude activity hooks into ~/.claude/settings.json (your other settings are kept, and a .crewbeacon-bak backup is made). New Claude sessions pick them up automatically. Codex does not need hook setup.")
        }

        QQC2.TextField {
            id: sessionCommandField
            Kirigami.FormData.label: i18n("Open session with:")
            Layout.minimumWidth: Kirigami.Units.gridUnit * 16
            placeholderText: "konsole --workdir %d"
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Clicking a session row in the popup runs this, with %d replaced by the project folder. E.g. \"code %d\", \"alacritty --working-directory %d\".")
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.SpinBox {
            id: intervalSpin
            from: 30; to: 3600; stepSize: 10
            Kirigami.FormData.label: i18n("Refresh interval (s):")
        }
        QQC2.SpinBox {
            id: warnSpin
            from: 1; to: 100
            Kirigami.FormData.label: i18n("Warn at (%):")
        }
        QQC2.SpinBox {
            id: critSpin
            from: 1; to: 100
            Kirigami.FormData.label: i18n("Critical at (%):")
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.TextField {
            id: tokenField
            Kirigami.FormData.label: i18n("Claude token source:")
            placeholderText: "auto"
            Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            wrapMode: Text.WordWrap
            opacity: 0.8
            font: Kirigami.Theme.smallFont
            text: i18n("\"auto\" reads the token Claude Code stores in ~/.claude/.credentials.json. Or enter the path to a file containing a long-lived token from 'claude setup-token' (works even when Claude Code is idle).")
        }
    }
}
