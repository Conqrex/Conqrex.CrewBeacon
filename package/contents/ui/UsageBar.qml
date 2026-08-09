import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// A modern, color-coded usage bar: "<label> ........ <value>" over a rounded
// track with a gradient fill, soft glow and animated width, plus an optional
// reset line. Used when the gauge style is set to "Bars".
ColumnLayout {
    id: bar

    property string label: ""
    property int pct: 0
    property string valueText: pct + "%"
    property bool mono: false
    property color accentColor: Kirigami.Theme.highlightColor
    property string resetText: ""

    spacing: Math.round(Kirigami.Units.smallSpacing / 2)

    RowLayout {
        Layout.fillWidth: true
        PlasmaComponents.Label {
            text: bar.label
            Layout.fillWidth: true
            elide: Text.ElideRight
        }
        PlasmaComponents.Label {
            text: bar.valueText
            color: bar.accentColor
            font.bold: true
            font.family: bar.mono ? "monospace" : Kirigami.Theme.defaultFont.family
        }
    }

    Item {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 0.62)

        Rectangle {
            id: track
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(Kirigami.Theme.textColor.r,
                           Kirigami.Theme.textColor.g,
                           Kirigami.Theme.textColor.b, 0.12)
        }

        // soft glow under the fill
        Rectangle {
            height: parent.height
            width: fill.width
            radius: parent.height / 2
            opacity: 0.35
            color: bar.accentColor
        }

        Rectangle {
            id: fill
            height: parent.height
            width: Math.max(0, Math.min(1, bar.pct / 100)) * parent.width
            radius: parent.height / 2
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.lighter(bar.accentColor, 1.35) }
                GradientStop { position: 1.0; color: bar.accentColor }
            }
            Behavior on width {
                NumberAnimation { duration: Kirigami.Units.longDuration * 2; easing.type: Easing.OutCubic }
            }
        }
    }

    PlasmaComponents.Label {
        visible: bar.resetText !== ""
        text: bar.resetText
        opacity: 0.7
        font: Kirigami.Theme.smallFont
        Layout.fillWidth: true
        elide: Text.ElideRight
    }
}
