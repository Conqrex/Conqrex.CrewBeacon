import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

KCM.SimpleKCM {
    id: page

    property alias cfg_useSystemTheme: sysThemeBox.checked
    property alias cfg_showCompactValue: compactValueBox.checked
    property alias cfg_compactUseProviderIcons: compactIconsBox.checked
    property alias cfg_timeFormat24h: time24Box.checked
    property alias cfg_warnThreshold: warnSpin.value
    property alias cfg_criticalThreshold: critSpin.value
    property string cfg_gaugeStyle: "ring"
    property string cfg_numberStyle: "percent"
    property string cfg_usageDisplay: "used"
    property string cfg_accent: "auto"
    property string cfg_compactProvider: "all-weekly"

    Kirigami.FormLayout {
        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Popup") }

        QQC2.CheckBox { id: sysThemeBox; text: i18n("Use Plasma system colors") }

        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Gauge style:")
            textRole: "label"; valueRole: "key"
            model: [{key:"ring",label:i18n("Ring gauges")},{key:"bar",label:i18n("Bars")}]
            currentIndex: Math.max(0, indexOfValue(page.cfg_gaugeStyle))
            onActivated: page.cfg_gaugeStyle = currentValue
        }
        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Number style:")
            textRole: "label"; valueRole: "key"
            model: [
                {key:"percent",label:i18n("Percent — 36%")},
                {key:"binary",label:i18n("Binary — 0100100")},
                {key:"blocks",label:i18n("Blocks — ▰▰▰▰▱▱▱▱▱▱")}
            ]
            currentIndex: Math.max(0, indexOfValue(page.cfg_numberStyle))
            onActivated: page.cfg_numberStyle = currentValue
        }
        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Quota display:")
            textRole: "label"; valueRole: "key"
            model: [{key:"used",label:i18n("Used")},{key:"left",label:i18n("Remaining")}]
            currentIndex: Math.max(0, indexOfValue(page.cfg_usageDisplay))
            onActivated: page.cfg_usageDisplay = currentValue
        }
        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Accent:")
            textRole: "label"; valueRole: "key"
            model: [
                {key:"auto",label:i18n("Automatic")},{key:"cyan",label:i18n("Cyan")},
                {key:"violet",label:i18n("Violet")},{key:"lime",label:i18n("Lime")},
                {key:"amber",label:i18n("Amber")},{key:"rose",label:i18n("Rose")},
                {key:"mono",label:i18n("Theme highlight")}
            ]
            currentIndex: Math.max(0, indexOfValue(page.cfg_accent))
            onActivated: page.cfg_accent = currentValue
        }

        QQC2.SpinBox { id: warnSpin; from: 1; to: 100; Kirigami.FormData.label: i18n("Warn at (%):") }
        QQC2.SpinBox { id: critSpin; from: 1; to: 100; Kirigami.FormData.label: i18n("Critical at (%):") }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Panel") }

        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Panel shows:")
            textRole: "label"; valueRole: "key"
            model: [
                {key:"all-weekly",label:i18n("All visible weekly providers")},
                {key:"first",label:i18n("First enabled provider")},
                {key:"hottest",label:i18n("Busiest gauge")},
                {key:"claude",label:i18n("Claude")},{key:"codex",label:i18n("Codex")},
                {key:"opencode",label:i18n("OpenCode Go")},{key:"copilot",label:i18n("GitHub Copilot")}
            ]
            currentIndex: Math.max(0, indexOfValue(page.cfg_compactProvider))
            onActivated: page.cfg_compactProvider = currentValue
        }
        QQC2.CheckBox { id: compactIconsBox; text: i18n("Show provider icons inside panel rings") }
        QQC2.CheckBox { id: compactValueBox; text: i18n("Show percentage when an icon is unavailable") }
        QQC2.CheckBox { id: time24Box; text: i18n("Use 24-hour time") }
    }
}
