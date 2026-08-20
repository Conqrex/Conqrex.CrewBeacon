import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

KCM.SimpleKCM {
    id: page

    property alias cfg_showPaseoAgents: paseoAgentsBox.checked
    property alias cfg_showLocalSessions: localSessionsBox.checked
    property alias cfg_recordLocalUsage: localUsageBox.checked
    property alias cfg_localUsageHistoryDays: localHistorySpin.value
    property alias cfg_agentRetentionHours: agentRetentionSpin.value
    property alias cfg_showActivity: activityBox.checked
    property alias cfg_persistMessagePreviews: previewBox.checked
    property alias cfg_sessionCommand: sessionCommandField.text

    readonly property string scriptPath:
        Qt.resolvedUrl("../code/usage.sh").toString().replace(/^file:\/\//, "")
    property string hookStatus: "unknown"

    function refreshHookStatus() {
        hookSource.run("bash '" + page.scriptPath + "' hooks-status")
    }

    function hookStatusText() {
        switch (page.hookStatus) {
        case "installed": return i18n("Hooks installed ✓")
        case "partial": return i18n("Hooks partially installed")
        case "foreign": return i18n("Hooks belong to another install")
        case "missing": return i18n("Hooks not set up")
        default: return ""
        }
    }

    Plasma5Support.DataSource {
        id: hookSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            if (source.indexOf("hooks-status") === -1) {
                disconnectSource(source)
                page.refreshHookStatus()
                return
            }
            if (data["exit code"] === 0) {
                try { page.hookStatus = JSON.parse(("" + data["stdout"]).trim()).status || "unknown" }
                catch (error) { page.hookStatus = "unknown" }
            }
            disconnectSource(source)
        }
        function run(command) { if (command) connectSource(command) }
    }

    Component.onCompleted: page.refreshHookStatus()

    Kirigami.FormLayout {
        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Agent sources") }

        QQC2.CheckBox {
            id: paseoAgentsBox
            text: i18n("Monitor configured Paseo sources")
        }
        QQC2.CheckBox {
            id: localSessionsBox
            text: i18n("Show local Claude/Codex sessions")
        }
        QQC2.CheckBox {
            id: localUsageBox
            text: i18n("Record local Claude/Codex usage history")
        }
        QQC2.SpinBox {
            id: localHistorySpin
            from: 1
            to: 30
            enabled: localUsageBox.checked
            Kirigami.FormData.label: i18n("Scan updated logs (days):")
        }
        QQC2.SpinBox {
            id: agentRetentionSpin
            from: 1
            to: 168
            Kirigami.FormData.label: i18n("Keep completed agents (h):")
        }
        QQC2.CheckBox {
            id: previewBox
            text: i18n("Persist sanitized attention previews")
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Local activity") }

        QQC2.CheckBox {
            id: activityBox
            text: i18n("Show local activity on the panel icon")
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Claude hooks:")
            QQC2.Button {
                text: i18n("Set up")
                icon.name: "install"
                onClicked: hookSource.run("bash '" + page.scriptPath + "' hooks-install")
            }
            QQC2.Button {
                text: i18n("Remove")
                icon.name: "edit-delete"
                enabled: page.hookStatus === "installed" || page.hookStatus === "partial"
                         || page.hookStatus === "foreign"
                onClicked: hookSource.run("bash '" + page.scriptPath + "' hooks-remove")
            }
            QQC2.Label {
                text: page.hookStatusText()
                color: page.hookStatus === "installed"
                    ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor
                font: Kirigami.Theme.smallFont
            }
        }

        QQC2.TextField {
            id: sessionCommandField
            Kirigami.FormData.label: i18n("Open session with:")
            Layout.minimumWidth: Kirigami.Units.gridUnit * 16
            placeholderText: "konsole --workdir %d"
        }

        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Claude hooks provide live working and needs-you state. Codex activity is inferred from recent local session logs. Prompt and response bodies are never stored.")
        }
    }
}
