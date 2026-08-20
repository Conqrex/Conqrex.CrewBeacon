import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

KCM.SimpleKCM {
    id: page

    property alias cfg_refreshInterval: intervalSpin.value
    property string cfg_usageRange: "today"

    Kirigami.FormLayout {
        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Refresh") }

        QQC2.SpinBox {
            id: intervalSpin
            from: 30
            to: 3600
            stepSize: 10
            Kirigami.FormData.label: i18n("Refresh interval (s):")
        }

        QQC2.ComboBox {
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
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Provider visibility and quota windows, agent behavior, appearance, and notifications each have their own settings page.")
        }
    }
}
