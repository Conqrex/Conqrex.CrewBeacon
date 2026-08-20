import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support
import "../code/providers.js" as Providers

KCM.SimpleKCM {
    id: page

    property string cfg_providerClaude: "auto"
    property string cfg_providerCodex: "auto"
    property string cfg_providerOpencode: "auto"
    property string cfg_providerCopilot: "auto"
    property string cfg_providerGemini: "auto"
    property string cfg_hiddenQuotaWindows: "[]"
    property bool cfg_showWeeklySonnet: false
    property alias cfg_tokenSource: tokenField.text

    property var detectStatus: ({})
    property var quotaCatalog: ({})
    readonly property string scriptPath:
        Qt.resolvedUrl("../code/usage.sh").toString().replace(/^file:\/\//, "")

    function statusText(id) {
        var status = detectStatus[id]
        if (!status) return ""
        if (status.reason === "tier_retired") return i18n("Detected · tier retired")
        return status.detected ? i18n("Detected ✓") : i18n("Not found")
    }

    function statusColor(id) {
        var status = detectStatus[id]
        if (!status) return Kirigami.Theme.disabledTextColor
        if (status.reason === "tier_retired") return Kirigami.Theme.neutralTextColor
        return status.detected ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.disabledTextColor
    }

    function windowsFor(id) {
        var provider = quotaCatalog[id]
        return provider && Array.isArray(provider.gauges) ? provider.gauges : []
    }

    function windowVisible(providerId, gaugeId) {
        return Providers.gaugeVisible(providerId, gaugeId, cfg_hiddenQuotaWindows,
                                      cfg_showWeeklySonnet)
    }

    function setWindowVisible(providerId, gaugeId, visible) {
        if (gaugeId === "weeklySonnet") cfg_showWeeklySonnet = visible
        cfg_hiddenQuotaWindows = Providers.withWindowVisibility(
            cfg_hiddenQuotaWindows, providerId, gaugeId, visible)
    }

    Plasma5Support.DataSource {
        id: detectSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            if (data["exit code"] === 0) {
                try {
                    var parsed = JSON.parse(("" + data["stdout"]).trim())
                    if (source.indexOf("quota-catalog") !== -1)
                        page.quotaCatalog = parsed && parsed.providers ? parsed.providers : {}
                    else
                        page.detectStatus = parsed && parsed.providers ? parsed.providers : {}
                } catch (error) { /* ignore malformed helper output */ }
            }
            disconnectSource(source)
        }
        function run(command) { if (command) connectSource(command) }
    }

    Component.onCompleted: {
        detectSource.run("bash '" + page.scriptPath + "' detect")
        detectSource.run("bash '" + page.scriptPath + "' quota-catalog")
    }

    component ProviderCard: Kirigami.AbstractCard {
        id: providerCard
        required property string providerId
        required property string title
        property string mode: "auto"
        property bool limitsExpanded: false
        signal modePicked(string value)

        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                QQC2.Label {
                    Layout.fillWidth: true
                    text: providerCard.title
                    font.bold: true
                }
                QQC2.Label {
                    text: page.statusText(providerCard.providerId)
                    color: page.statusColor(providerCard.providerId)
                    font: Kirigami.Theme.smallFont
                }
                QQC2.ComboBox {
                    textRole: "label"
                    valueRole: "key"
                    model: [
                        { key: "auto", label: i18n("Auto") },
                        { key: "on", label: i18n("Always show") },
                        { key: "off", label: i18n("Hidden") }
                    ]
                    currentIndex: Math.max(0, indexOfValue(providerCard.mode))
                    onActivated: providerCard.modePicked(currentValue)
                }
            }

            QQC2.ToolButton {
                visible: page.windowsFor(providerCard.providerId).length > 0
                Layout.alignment: Qt.AlignLeft
                text: i18np("%1 quota window", "%1 quota windows",
                            page.windowsFor(providerCard.providerId).length)
                icon.name: providerCard.limitsExpanded ? "go-up" : "go-down"
                onClicked: providerCard.limitsExpanded = !providerCard.limitsExpanded
            }

            ColumnLayout {
                visible: providerCard.limitsExpanded
                Layout.fillWidth: true
                spacing: 0
                Repeater {
                    model: page.windowsFor(providerCard.providerId)
                    delegate: QQC2.CheckBox {
                        required property var modelData
                        Layout.fillWidth: true
                        text: modelData.label + (modelData.cap ? "  ·  " + modelData.cap : "")
                        checked: page.windowVisible(providerCard.providerId, modelData.id)
                        enabled: providerCard.mode !== "off"
                        font: Kirigami.Theme.smallFont
                        onToggled: page.setWindowVisible(providerCard.providerId,
                                                         modelData.id, checked)
                    }
                }
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            opacity: 0.7
            text: i18n("Providers appear automatically when their CLI is signed in. Expand a provider only when you want to change individual quota-window visibility.")
        }

        ProviderCard {
            providerId: "claude"; title: i18n("Claude"); mode: page.cfg_providerClaude
            onModePicked: (value) => page.cfg_providerClaude = value
        }
        ProviderCard {
            providerId: "codex"; title: i18n("Codex"); mode: page.cfg_providerCodex
            onModePicked: (value) => page.cfg_providerCodex = value
        }
        ProviderCard {
            providerId: "opencode"; title: i18n("OpenCode Go"); mode: page.cfg_providerOpencode
            onModePicked: (value) => page.cfg_providerOpencode = value
        }
        ProviderCard {
            providerId: "copilot"; title: i18n("GitHub Copilot"); mode: page.cfg_providerCopilot
            onModePicked: (value) => page.cfg_providerCopilot = value
        }
        ProviderCard {
            providerId: "gemini"; title: i18n("Gemini"); mode: page.cfg_providerGemini
            onModePicked: (value) => page.cfg_providerGemini = value
        }

        Kirigami.Separator { Layout.fillWidth: true }

        QQC2.TextField {
            id: tokenField
            Layout.fillWidth: true
            placeholderText: "auto"
        }
        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Claude token source: “auto” reads Claude Code's stored credentials. You may instead enter a file containing a long-lived setup token.")
        }

        Item { Layout.fillHeight: true }
    }
}
