import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

Item {
    id: overview

    property var providers: []
    property double nowMs: 0
    property string lastUpdated: ""
    property bool use24h: true
    property string numberStyle: "percent"
    property string usageDisplay: "used"
    property bool mono: false
    property bool showWeeklySonnet: false

    signal refreshRequested()
    signal openSessionRequested(string cwd)

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

    QQC2.ScrollView {
        id: scroll
        anchors.fill: parent
        clip: true
        contentWidth: availableWidth

        ColumnLayout {
            width: scroll.availableWidth
            spacing: Kirigami.Units.smallSpacing

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

            Item { Layout.preferredHeight: Kirigami.Units.smallSpacing }
        }
    }
}
