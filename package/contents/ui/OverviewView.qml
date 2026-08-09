import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

Item {
    id: overview

    property var providers: []
    property var agentSessions: []
    property var attentionSessions: []
    property var hosts: []
    property double nowMs: 0
    property string lastUpdated: ""
    property bool use24h: true
    property string numberStyle: "percent"
    property string usageDisplay: "used"
    property bool mono: false
    property bool showWeeklySonnet: false
    property string agentFilter: "all"

    signal refreshRequested()
    signal openSessionRequested(string cwd)
    signal openAgentRequested(string deepLink)

    function finite(value) {
        return typeof value === "number" && isFinite(value)
    }

    function formatTokens(value) {
        if (!finite(value)) return ""
        if (value >= 1000000) return (value / 1000000).toFixed(value >= 10000000 ? 0 : 1) + "M"
        if (value >= 1000) return (value / 1000).toFixed(value >= 100000 ? 0 : 1) + "K"
        return "" + Math.round(value)
    }

    function formatCost(value) {
        return finite(value) ? "$" + value.toFixed(value < 0.1 ? 3 : 2) : ""
    }

    function duration(start, end) {
        var from = Date.parse(start || "")
        if (isNaN(from)) return ""
        var to = Date.parse(end || "")
        if (isNaN(to)) to = overview.nowMs
        var sec = Math.max(0, Math.floor((to - from) / 1000))
        var days = Math.floor(sec / 86400)
        var hours = Math.floor((sec % 86400) / 3600)
        var minutes = Math.floor((sec % 3600) / 60)
        if (days > 0) return days + "d " + hours + "h"
        if (hours > 0) return hours + "h " + minutes + "m"
        return Math.max(1, minutes) + "m"
    }

    function needsAttention(state) {
        return state === "WaitingForInput" || state === "WaitingForPermission" || state === "Failed"
    }

    function isActive(state) {
        return state === "Working" || state === "Connecting"
    }

    function isDone(state) {
        return state === "Completed"
    }

    function filteredSessions() {
        var result = []
        for (var i = 0; i < overview.agentSessions.length; i++) {
            var session = overview.agentSessions[i]
            if (overview.agentFilter === "active" && !overview.isActive(session.state)) continue
            if (overview.agentFilter === "attention" && !overview.needsAttention(session.state)) continue
            if (overview.agentFilter === "done" && !overview.isDone(session.state)) continue
            result.push(session)
        }
        return result
    }

    function countSessions(mode) {
        if (mode === "all") return overview.agentSessions.length
        var count = 0
        for (var i = 0; i < overview.agentSessions.length; i++) {
            var state = overview.agentSessions[i].state
            if ((mode === "active" && overview.isActive(state))
                    || (mode === "attention" && overview.needsAttention(state))
                    || (mode === "done" && overview.isDone(state))) count++
        }
        return count
    }

    function stateLabel(state) {
        switch (state) {
        case "WaitingForInput": return i18n("Needs input")
        case "WaitingForPermission": return i18n("Needs permission")
        case "Working": return i18n("Working")
        case "Connecting": return i18n("Connecting")
        case "Completed": return i18n("Completed")
        case "Failed": return i18n("Failed")
        case "Disconnected": return i18n("Disconnected")
        case "Idle": return i18n("Idle")
        default: return i18n("Unknown")
        }
    }

    function stateColor(state, stale) {
        if (stale) return Kirigami.Theme.disabledTextColor
        switch (state) {
        case "Failed": return Kirigami.Theme.negativeTextColor
        case "WaitingForInput":
        case "WaitingForPermission": return Kirigami.Theme.neutralTextColor
        case "Working": return Qt.rgba(0.20, 0.83, 0.92, 1)
        case "Completed": return Kirigami.Theme.positiveTextColor
        case "Connecting": return Kirigami.Theme.highlightColor
        default: return Kirigami.Theme.disabledTextColor
        }
    }

    function sessionSubtitle(session) {
        var parts = []
        parts.push(session.providerLabel || session.providerId || i18n("Agent"))
        if (session.modelId) parts.push(session.modelId)
        if (session.hostName || session.sourceName) parts.push(session.hostName || session.sourceName)
        if (session.branch) parts.push(session.branch + (session.worktree ? " · worktree" : ""))
        return parts.join(" · ")
    }

    readonly property var visibleSessions: filteredSessions()

    component SectionTitle: RowLayout {
        property string iconName: ""
        property string label: ""
        property int count: -1
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing
        Kirigami.Icon {
            source: parent.iconName
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
            opacity: 0.75
        }
        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: parent.label.toUpperCase()
            font.bold: true
            font.letterSpacing: 0.7
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.72
        }
        PlasmaComponents.Label {
            visible: parent.count >= 0
            text: parent.count
            opacity: 0.55
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }
    }

    component AgentCard: Rectangle {
        id: card
        required property var session
        Layout.fillWidth: true
        implicitHeight: cardRow.implicitHeight + Kirigami.Units.smallSpacing * 2
        radius: Kirigami.Units.cornerRadius
        color: cardMouse.containsMouse
            ? Qt.alpha(Kirigami.Theme.highlightColor, 0.10)
            : Qt.alpha(Kirigami.Theme.textColor, 0.045)
        border.width: overview.needsAttention(session.state) ? 1 : 0
        border.color: Qt.alpha(overview.stateColor(session.state, session.stale), 0.65)

        RowLayout {
            id: cardRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Kirigami.Units.smallSpacing
            anchors.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Item {
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: Qt.alpha(overview.stateColor(card.session.state, card.session.stale), 0.12)
                    border.width: 2
                    border.color: overview.stateColor(card.session.state, card.session.stale)
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: 7
                    height: 7
                    radius: 3.5
                    color: overview.stateColor(card.session.state, card.session.stale)
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        text: card.session.repositoryName || card.session.title || i18n("Unknown repository")
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    PlasmaComponents.Label {
                        text: overview.stateLabel(card.session.state)
                        color: overview.stateColor(card.session.state, card.session.stale)
                        font.bold: overview.needsAttention(card.session.state)
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    PlasmaComponents.Label {
                        visible: text !== ""
                        text: overview.duration(card.session.startedAt, card.session.endedAt)
                        opacity: 0.5
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: overview.sessionSubtitle(card.session)
                    opacity: 0.62
                    elide: Text.ElideMiddle
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            }
        }

        MouseArea {
            id: cardMouse
            anchors.fill: parent
            enabled: !!card.session.deepLink
            hoverEnabled: true
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: overview.openAgentRequested(card.session.deepLink)
            PlasmaComponents.ToolTip {
                visible: cardMouse.containsMouse && cardMouse.enabled
                text: i18n("Open this agent in Paseo")
            }
        }
    }

    QQC2.ScrollView {
        id: scroll
        anchors.fill: parent
        clip: true
        contentWidth: availableWidth

        ColumnLayout {
            width: scroll.availableWidth
            spacing: Kirigami.Units.smallSpacing

            Rectangle {
                visible: overview.attentionSessions.length > 0
                Layout.fillWidth: true
                implicitHeight: attentionRow.implicitHeight + Kirigami.Units.smallSpacing * 1.5
                radius: Kirigami.Units.cornerRadius
                color: Qt.alpha(Kirigami.Theme.neutralTextColor, 0.13)
                border.width: 1
                border.color: Qt.alpha(Kirigami.Theme.neutralTextColor, 0.45)
                RowLayout {
                    id: attentionRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Kirigami.Units.smallSpacing
                    anchors.rightMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing
                    Kirigami.Icon {
                        source: "dialog-warning-symbolic"
                        color: Kirigami.Theme.neutralTextColor
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    }
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        text: i18np("%1 agent needs your attention", "%1 agents need your attention",
                                    overview.attentionSessions.length)
                        color: Kirigami.Theme.neutralTextColor
                        font.bold: true
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    PlasmaComponents.Label {
                        text: i18n("Show")
                        color: Kirigami.Theme.highlightColor
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: overview.agentFilter = "attention"
                }
            }

            SectionTitle {
                iconName: "system-run"
                label: i18n("Agents")
                count: overview.agentSessions.length
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Repeater {
                    model: [
                        { key: "all", label: i18n("All") },
                        { key: "active", label: i18n("Active") },
                        { key: "attention", label: i18n("Needs you") },
                        { key: "done", label: i18n("Done") }
                    ]
                    delegate: Rectangle {
                        id: filterChip
                        required property var modelData
                        readonly property bool active: overview.agentFilter === modelData.key
                        implicitHeight: filterRow.implicitHeight + 6
                        implicitWidth: filterRow.implicitWidth + 14
                        radius: height / 2
                        color: active
                            ? Qt.alpha(Kirigami.Theme.highlightColor, 0.22)
                            : Qt.alpha(Kirigami.Theme.textColor, 0.06)
                        border.width: active ? 1 : 0
                        border.color: Qt.alpha(Kirigami.Theme.highlightColor, 0.6)
                        RowLayout {
                            id: filterRow
                            anchors.centerIn: parent
                            spacing: 4
                            PlasmaComponents.Label {
                                text: filterChip.modelData.label
                                font.bold: filterChip.active
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            PlasmaComponents.Label {
                                text: overview.countSessions(filterChip.modelData.key)
                                opacity: 0.55
                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: overview.agentFilter = filterChip.modelData.key
                        }
                    }
                }
                Item { Layout.fillWidth: true }
            }

            PlasmaComponents.Label {
                visible: overview.visibleSessions.length === 0
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                Layout.bottomMargin: Kirigami.Units.smallSpacing
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: overview.agentSessions.length === 0
                    ? i18n("No recent agents. Check the source status below or add a Paseo source in settings.")
                    : i18n("No agents match this filter.")
                opacity: 0.58
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }

            Repeater {
                model: overview.visibleSessions
                delegate: AgentCard {
                    required property var modelData
                    session: modelData
                }
            }

            SectionTitle {
                Layout.topMargin: Kirigami.Units.smallSpacing
                iconName: "speedometer"
                label: i18n("Quota")
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: quotaColumn.implicitHeight + Kirigami.Units.smallSpacing * 2
                radius: Kirigami.Units.cornerRadius
                color: Qt.alpha(Kirigami.Theme.textColor, 0.035)

                ColumnLayout {
                    id: quotaColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Kirigami.Units.smallSpacing
                    anchors.rightMargin: Kirigami.Units.smallSpacing
                    spacing: 2

                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        text: i18n("Remaining provider capacity; separate from recorded token history.")
                        opacity: 0.55
                        wrapMode: Text.WordWrap
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }

                    QuotaView {
                        Layout.fillWidth: true
                        providers: overview.providers
                        nowMs: overview.nowMs
                        lastUpdated: overview.lastUpdated
                        use24h: overview.use24h
                        numberStyle: overview.numberStyle
                        usageDisplay: overview.usageDisplay
                        mono: overview.mono
                        gaugeStyle: "bar"
                        showWeeklySonnet: overview.showWeeklySonnet
                        activityShow: false
                        activitySessions: []
                        showHeader: false
                        showFooter: false
                        compact: true
                        onRefreshRequested: overview.refreshRequested()
                        onOpenSessionRequested: (cwd) => overview.openSessionRequested(cwd)
                    }
                }
            }

            SectionTitle {
                Layout.topMargin: Kirigami.Units.smallSpacing
                iconName: "network-server"
                label: i18n("Sources")
                count: overview.hosts.length
            }

            PlasmaComponents.Label {
                visible: overview.hosts.length === 0
                Layout.fillWidth: true
                text: i18n("No Paseo sources configured.")
                opacity: 0.58
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }

            Repeater {
                model: overview.hosts
                delegate: Rectangle {
                    id: hostCard
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: hostRow.implicitHeight + Kirigami.Units.smallSpacing
                    radius: Kirigami.Units.cornerRadius
                    color: Qt.alpha(Kirigami.Theme.textColor, 0.035)
                    RowLayout {
                        id: hostRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Kirigami.Units.smallSpacing
                        anchors.rightMargin: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.smallSpacing
                        Rectangle {
                            width: 7
                            height: 7
                            radius: 3.5
                            color: hostCard.modelData.connectionState === "Connected"
                                ? Kirigami.Theme.positiveTextColor
                                : hostCard.modelData.connectionState === "Connecting"
                                  ? Kirigami.Theme.neutralTextColor
                                  : Kirigami.Theme.negativeTextColor
                        }
                        PlasmaComponents.Label {
                            Layout.fillWidth: true
                            text: hostCard.modelData.name || hostCard.modelData.hostname || i18n("Paseo source")
                            font.bold: true
                            elide: Text.ElideRight
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        PlasmaComponents.Label {
                            text: (hostCard.modelData.connectionState || i18n("Unknown"))
                                + (hostCard.modelData.version ? " · " + hostCard.modelData.version : "")
                            opacity: 0.58
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: Kirigami.Units.smallSpacing }
        }
    }
}
