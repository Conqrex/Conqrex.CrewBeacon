import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// Panel representation. In all-weekly mode each visible provider contributes
// one ring; single-provider and hottest modes use the same delegate with one
// item. Provider marks can replace the percentage in the ring center.
MouseArea {
    id: compact

    property var items: []
    property bool mono: false
    property bool showValue: true
    property bool showProviderIcons: true

    property bool activityShow: false
    property color activityColor: "transparent"
    property bool activityPulse: false

    signal toggleRequested()

    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property bool horizontal: Plasmoid.formFactor === PlasmaCore.Types.Horizontal
    readonly property int providerCount: Math.max(1, items.length)
    readonly property int gap: 2
    readonly property int ringSide: Math.min(width, height)
    readonly property var displayItems: items.length > 0 ? items : [{
        id: "", label: i18n("No provider usage"), badge: "", pct: 0,
        accent: compact.trackColorMuted, valueText: "", icon: ""
    }]

    hoverEnabled: true
    onClicked: compact.toggleRequested()

    Layout.minimumWidth: horizontal
        ? Math.max(Kirigami.Units.iconSizes.small, height) * providerCount + gap * (providerCount - 1)
        : Kirigami.Units.iconSizes.small
    Layout.minimumHeight: vertical
        ? Math.max(Kirigami.Units.iconSizes.small, width) * providerCount + gap * (providerCount - 1)
        : Kirigami.Units.iconSizes.small
    Layout.preferredWidth: horizontal ? Layout.minimumWidth : width
    Layout.preferredHeight: vertical ? Layout.minimumHeight : height

    GridLayout {
        anchors.centerIn: parent
        columns: compact.horizontal ? compact.providerCount : 1
        rows: compact.vertical ? compact.providerCount : 1
        columnSpacing: compact.gap
        rowSpacing: compact.gap

        Repeater {
            model: compact.displayItems
            delegate: Item {
                id: providerRing
                required property var modelData
                readonly property bool hasIcon: compact.showProviderIcons
                    && (modelData.icon !== "" || modelData.badge !== "")
                Layout.preferredWidth: compact.ringSide
                Layout.preferredHeight: compact.ringSide

                Gauge {
                    anchors.fill: parent
                    value: providerRing.modelData.pct || 0
                    accentColor: providerRing.modelData.accent || compact.trackColorMuted
                    thickness: Math.max(2.5, compact.ringSide * 0.13)
                    mono: compact.mono
                    centerText: !providerRing.hasIcon && compact.showValue
                              && compact.ringSide >= (compact.mono ? 40 : 30)
                              ? providerRing.modelData.valueText : ""
                    caption: ""
                    showText: !providerRing.hasIcon
                }

                Image {
                    visible: providerRing.hasIcon && providerRing.modelData.icon !== ""
                    anchors.centerIn: parent
                    width: Math.max(12, compact.ringSide * 0.44)
                    height: width
                    source: providerRing.modelData.icon
                    sourceSize.width: 64
                    sourceSize.height: 64
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                }

                PlasmaComponents.Label {
                    visible: providerRing.hasIcon && providerRing.modelData.icon === ""
                    anchors.centerIn: parent
                    text: providerRing.modelData.badge || ""
                    font.bold: true
                    font.pixelSize: Math.max(9, compact.ringSide * 0.30)
                }

                HoverHandler { id: providerHover }

                PlasmaComponents.ToolTip {
                    visible: providerHover.hovered
                    text: providerRing.modelData.id
                        ? i18n("%1 · %2 %3%", providerRing.modelData.label,
                               providerRing.modelData.gaugeLabel || i18n("Usage"),
                               providerRing.modelData.pct)
                        : i18n("No provider usage available")
                }
            }
        }
    }

    readonly property color trackColorMuted: Qt.rgba(Kirigami.Theme.textColor.r,
                                                     Kirigami.Theme.textColor.g,
                                                     Kirigami.Theme.textColor.b, 0.35)

    Rectangle {
        id: activityDot
        visible: compact.activityShow
        width: Math.max(6, compact.ringSide * 0.30)
        height: width
        radius: width / 2
        color: compact.activityColor
        border.width: Math.max(1, Math.round(width * 0.16))
        border.color: Qt.rgba(Kirigami.Theme.backgroundColor.r,
                              Kirigami.Theme.backgroundColor.g,
                              Kirigami.Theme.backgroundColor.b, 0.92)
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        SequentialAnimation on opacity {
            running: compact.activityShow && compact.activityPulse
            loops: Animation.Infinite
            NumberAnimation { from: 1.0; to: 0.35; duration: 750; easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.35; to: 1.0; duration: 750; easing.type: Easing.InOutSine }
            onStopped: activityDot.opacity = 1.0
        }
    }
}
