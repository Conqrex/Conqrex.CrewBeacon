import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// OctoPulse-aligned shell with focused overview, agent, and usage workspaces.
Item {
    id: full

    property var providers: []
    property var agentSessions: []
    property var attentionSessions: []
    property var hosts: []
    property var repositoryUsage: ({ totalTokens: 0, reportedCost: 0, repositories: [] })
    property var usageCalendar: ({ days: [], maxTokens: 0, maxEvents: 0 })
    property var usageDayDetail: ({ ok: true, date: "", repositories: [], providers: [], sessions: [], events: [] })
    property string usageRange: "today"
    property double nowMs: 0
    property string lastUpdated: ""
    property bool use24h: true
    property string numberStyle: "percent"
    property string usageDisplay: "used"
    property bool mono: false
    property string gaugeStyle: "ring"
    property bool showWeeklySonnet: false
    property bool activityShow: false
    property var activitySessions: []
    property int currentTab: 0

    signal refreshRequested()
    signal openSessionRequested(string cwd)
    signal openAgentRequested(string deepLink)
    signal usageDayRequested(string dateKey)

    implicitWidth: Kirigami.Units.gridUnit * 30
    implicitHeight: Kirigami.Units.gridUnit * 32
    Layout.minimumWidth: Kirigami.Units.gridUnit * 24
    Layout.minimumHeight: Kirigami.Units.gridUnit * 24
    Layout.preferredWidth: Kirigami.Units.gridUnit * 30
    Layout.preferredHeight: Kirigami.Units.gridUnit * 32

    // Keep the same dark banner palette as OctoPulse. The optional switch lets
    // users return both widgets to their Plasma color scheme together.
    readonly property bool sysTheme: Plasmoid.configuration.useSystemTheme
    Kirigami.Theme.inherit: sysTheme
    Kirigami.Theme.colorSet: Kirigami.Theme.View
    Kirigami.Theme.backgroundColor: "#0d1526"
    Kirigami.Theme.textColor: "#e6edf3"
    Kirigami.Theme.disabledTextColor: "#8b96a5"
    Kirigami.Theme.highlightColor: "#3b82f6"
    Kirigami.Theme.positiveTextColor: "#3fb950"
    Kirigami.Theme.negativeTextColor: "#f85149"
    Kirigami.Theme.neutralTextColor: "#d29922"

    Rectangle {
        anchors.fill: parent
        anchors.margins: -Kirigami.Units.smallSpacing
        visible: !full.sysTheme
        radius: Kirigami.Units.cornerRadius
        color: "#0d1526"
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Image {
                source: Qt.resolvedUrl("../icons/crewbeacon.svg")
                sourceSize.width: 64
                sourceSize.height: 64
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                fillMode: Image.PreserveAspectFit
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                PlasmaComponents.Label {
                    text: i18n("CrewBeacon")
                    font.bold: true
                }
                PlasmaComponents.Label {
                    text: full.currentTab === 0
                        ? i18n("Provider quota at a glance")
                        : full.currentTab === 1
                          ? i18n("Live agents and source health")
                          : i18n("Recorded daily usage history")
                    opacity: 0.58
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            }

            Rectangle {
                radius: height / 2
                implicitHeight: liveRow.implicitHeight + 6
                implicitWidth: liveRow.implicitWidth + 14
                color: Qt.alpha(Kirigami.Theme.textColor, 0.07)
                RowLayout {
                    id: liveRow
                    anchors.centerIn: parent
                    spacing: 5
                    Rectangle {
                        width: 7
                        height: 7
                        radius: 3.5
                        color: full.agentSessions.length > 0
                            ? Kirigami.Theme.positiveTextColor
                            : Kirigami.Theme.disabledTextColor
                    }
                    PlasmaComponents.Label {
                        text: i18np("%1 agent", "%1 agents", full.agentSessions.length)
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }

            PlasmaComponents.ToolButton {
                icon.name: "view-refresh"
                onClicked: full.refreshRequested()
                PlasmaComponents.ToolTip { text: i18n("Refresh all sources") }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Repeater {
                model: [
                    { label: i18n("Overview"), icon: "view-dashboard", count: 0 },
                    { label: i18n("Agents"), icon: "system-run", count: full.attentionSessions.length },
                    { label: i18n("Usage"), icon: "office-chart-bar", count: 0 }
                ]
                delegate: Rectangle {
                    id: tabChip
                    required property var modelData
                    required property int index
                    readonly property bool active: full.currentTab === index
                    Layout.fillWidth: true
                    implicitHeight: tabRow.implicitHeight + 8
                    radius: height / 2
                    color: active
                        ? Qt.alpha(Kirigami.Theme.highlightColor, 0.22)
                        : Qt.alpha(Kirigami.Theme.textColor, 0.06)
                    border.width: active ? 1 : 0
                    border.color: Qt.alpha(Kirigami.Theme.highlightColor, 0.6)

                    RowLayout {
                        id: tabRow
                        anchors.centerIn: parent
                        spacing: 5
                        Kirigami.Icon {
                            source: tabChip.modelData.icon
                            color: tabChip.active
                                ? Kirigami.Theme.highlightColor
                                : Kirigami.Theme.textColor
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        }
                        PlasmaComponents.Label {
                            text: tabChip.modelData.label
                            font.bold: tabChip.active
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        Rectangle {
                            visible: tabChip.modelData.count > 0
                            radius: height / 2
                            implicitHeight: tabCount.implicitHeight + 2
                            implicitWidth: Math.max(implicitHeight, tabCount.implicitWidth + 8)
                            color: Qt.alpha(Kirigami.Theme.neutralTextColor, 0.35)
                            PlasmaComponents.Label {
                                id: tabCount
                                anchors.centerIn: parent
                                text: tabChip.modelData.count
                                color: Kirigami.Theme.neutralTextColor
                                font.bold: true
                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: full.currentTab = tabChip.index
                    }
                }
            }
        }

        Kirigami.Separator { Layout.fillWidth: true }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: full.currentTab

            OverviewView {
                providers: full.providers
                nowMs: full.nowMs
                lastUpdated: full.lastUpdated
                use24h: full.use24h
                numberStyle: full.numberStyle
                usageDisplay: full.usageDisplay
                mono: full.mono
                showWeeklySonnet: full.showWeeklySonnet
                onRefreshRequested: full.refreshRequested()
                onOpenSessionRequested: (cwd) => full.openSessionRequested(cwd)
            }

            AgentsView {
                agentSessions: full.agentSessions
                attentionSessions: full.attentionSessions
                hosts: full.hosts
                nowMs: full.nowMs
                onOpenSessionRequested: (cwd) => full.openSessionRequested(cwd)
                onOpenAgentRequested: (deepLink) => full.openAgentRequested(deepLink)
            }

            UsageHistoryView {
                calendar: full.usageCalendar
                dayDetail: full.usageDayDetail
                onDayRequested: (dateKey) => full.usageDayRequested(dateKey)
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 5
            Rectangle {
                width: 7
                height: 7
                radius: 3.5
                color: full.hosts.length > 0
                    ? Kirigami.Theme.positiveTextColor
                    : Kirigami.Theme.disabledTextColor
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: full.hosts.length > 0
                    ? i18np("%1 Paseo source", "%1 Paseo sources", full.hosts.length)
                    : i18n("No Paseo source connected")
                opacity: 0.58
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            PlasmaComponents.Label {
                visible: full.lastUpdated !== ""
                text: i18n("Updated %1", full.lastUpdated)
                opacity: 0.58
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }
    }
}
