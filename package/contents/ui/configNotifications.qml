import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

KCM.SimpleKCM {
    id: page

    property alias cfg_notifyResetEarly: notifyResetBox.checked
    property alias cfg_notifyThresholds: thresholdsBox.checked
    property alias cfg_thresholdLevels: thresholdField.text
    property alias cfg_notifySignIn: signInBox.checked
    property alias cfg_notifyNeedsYou: needsYouBox.checked
    property alias cfg_notifyAgentInput: agentInputBox.checked
    property alias cfg_notifyAgentPermission: agentPermissionBox.checked
    property alias cfg_notifyAgentFailed: agentFailedBox.checked
    property alias cfg_notifyAgentCompleted: agentCompletedBox.checked
    property alias cfg_quietHoursEnabled: quietBox.checked
    property alias cfg_quietStart: quietStartField.text
    property alias cfg_quietEnd: quietEndField.text

    Kirigami.FormLayout {
        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Quota alerts") }

        QQC2.CheckBox {
            id: notifyResetBox
            text: i18n("Limit resets earlier than scheduled")
        }
        RowLayout {
            QQC2.CheckBox {
                id: thresholdsBox
                text: i18n("Usage crosses")
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
            text: i18n("Provider sign-in expires")
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Agent alerts") }

        QQC2.CheckBox { id: agentInputBox; text: i18n("Agent explicitly waits for input") }
        QQC2.CheckBox { id: agentPermissionBox; text: i18n("Agent requests permission") }
        QQC2.CheckBox { id: agentFailedBox; text: i18n("Agent fails") }
        QQC2.CheckBox { id: agentCompletedBox; text: i18n("Agent completes") }
        QQC2.CheckBox { id: needsYouBox; text: i18n("Local Claude session needs you") }

        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Local Claude needs-you alerts require the activity hooks configured on the Agents page.")
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Quiet hours") }

        QQC2.CheckBox {
            id: quietBox
            text: i18n("Mute all CrewBeacon notifications")
        }
        RowLayout {
            enabled: quietBox.checked
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
    }
}
