import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

KCM.SimpleKCM {
    id: page

    property string cfg_paseoSources: ""
    property bool syncing: false

    ListModel { id: hostsModel }

    function defaultSources() {
        return [{ id: "local", name: "Local Paseo", transport: "direct",
                  endpoint: "ws://127.0.0.1:6767/ws", offerFile: "", enabled: true }]
    }

    function loadSources() {
        if (syncing) return
        var parsed
        try { parsed = JSON.parse(cfg_paseoSources || "[]") }
        catch (error) { parsed = defaultSources() }
        if (!Array.isArray(parsed) || parsed.length === 0) parsed = defaultSources()
        syncing = true
        hostsModel.clear()
        for (var i = 0; i < parsed.length; i++) {
            var source = parsed[i] || {}
            hostsModel.append({
                sourceId: source.id || ("source-" + Date.now() + "-" + i),
                sourceName: source.name || i18n("Paseo host"),
                sourceTransport: source.transport === "relay" ? "relay" : "direct",
                endpoint: source.endpoint || "ws://127.0.0.1:6767/ws",
                offerFile: source.offerFile || "",
                sourceEnabled: source.enabled !== false
            })
        }
        syncing = false
    }

    function saveSources() {
        if (syncing) return
        var result = []
        for (var i = 0; i < hostsModel.count; i++) {
            var row = hostsModel.get(i)
            result.push({ id: row.sourceId, name: row.sourceName,
                          transport: row.sourceTransport, endpoint: row.endpoint,
                          offerFile: row.offerFile, enabled: row.sourceEnabled })
        }
        syncing = true
        cfg_paseoSources = JSON.stringify(result)
        syncing = false
    }

    function validEndpoint(value) {
        return /^(ws|wss):\/\/[^/]+\/ws(?:\?.*)?$/.test((value || "").trim())
    }

    onCfg_paseoSourcesChanged: loadSources()
    Component.onCompleted: loadSources()

    ColumnLayout {
        anchors.fill: parent
        spacing: Kirigami.Units.largeSpacing

        Kirigami.Heading {
            level: 3
            text: i18n("Paseo sources")
        }

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            opacity: 0.75
            text: i18n("Direct sources use read-only Paseo WebSockets. Relay sources use the official Paseo CLI and an end-to-end encrypted app.paseo.sh pairing offer. Pairing offers are secrets, so CrewBeacon reads them from a 0600 file instead of storing them in Plasma configuration.")
        }

        Repeater {
            model: hostsModel
            delegate: Rectangle {
                id: sourceCard
                required property int index
                required property string sourceId
                required property string sourceName
                required property string sourceTransport
                required property string endpoint
                required property string offerFile
                required property bool sourceEnabled

                Layout.fillWidth: true
                Layout.preferredHeight: sourceLayout.implicitHeight + Kirigami.Units.largeSpacing * 2
                radius: Kirigami.Units.smallSpacing
                color: Qt.rgba(Kirigami.Theme.textColor.r,
                               Kirigami.Theme.textColor.g,
                               Kirigami.Theme.textColor.b, 0.05)
                border.width: 1
                border.color: Qt.rgba(Kirigami.Theme.textColor.r,
                                      Kirigami.Theme.textColor.g,
                                      Kirigami.Theme.textColor.b, 0.12)

                ColumnLayout {
                    id: sourceLayout
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.largeSpacing
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        QQC2.Switch {
                            checked: sourceCard.sourceEnabled
                            onToggled: {
                                hostsModel.setProperty(sourceCard.index, "sourceEnabled", checked)
                                page.saveSources()
                            }
                        }
                        QQC2.TextField {
                            Layout.fillWidth: true
                            text: sourceCard.sourceName
                            placeholderText: i18n("Friendly host name")
                            onEditingFinished: {
                                hostsModel.setProperty(sourceCard.index, "sourceName", text.trim() || i18n("Paseo host"))
                                page.saveSources()
                            }
                        }
                        QQC2.ToolButton {
                            icon.name: "edit-delete"
                            enabled: hostsModel.count > 1
                            onClicked: {
                                hostsModel.remove(sourceCard.index)
                                page.saveSources()
                            }
                            QQC2.ToolTip { text: i18n("Remove source") }
                        }
                    }

                    QQC2.ComboBox {
                        Layout.fillWidth: true
                        model: [i18n("Direct WebSocket"), i18n("Encrypted Paseo relay")]
                        currentIndex: sourceCard.sourceTransport === "relay" ? 1 : 0
                        onActivated: (index) => {
                            hostsModel.setProperty(sourceCard.index, "sourceTransport",
                                                   index === 1 ? "relay" : "direct")
                            page.saveSources()
                        }
                    }

                    QQC2.TextField {
                        id: endpointField
                        Layout.fillWidth: true
                        visible: sourceCard.sourceTransport === "direct"
                        text: sourceCard.endpoint
                        placeholderText: "ws://127.0.0.1:6767/ws"
                        color: page.validEndpoint(text) ? Kirigami.Theme.textColor
                                                        : Kirigami.Theme.negativeTextColor
                        onEditingFinished: {
                            hostsModel.setProperty(sourceCard.index, "endpoint", text.trim())
                            page.saveSources()
                        }
                    }

                    QQC2.Label {
                        Layout.fillWidth: true
                        visible: sourceCard.sourceTransport === "direct"
                                 && !page.validEndpoint(endpointField.text)
                        color: Kirigami.Theme.negativeTextColor
                        text: i18n("Use ws://HOST:PORT/ws or wss://HOST:PORT/ws")
                        font: Kirigami.Theme.smallFont
                    }

                    QQC2.TextField {
                        id: offerFileField
                        Layout.fillWidth: true
                        visible: sourceCard.sourceTransport === "relay"
                        text: sourceCard.offerFile
                        placeholderText: "~/.local/share/crewbeacon/paseo.offer"
                        onEditingFinished: {
                            hostsModel.setProperty(sourceCard.index, "offerFile", text.trim())
                            page.saveSources()
                        }
                    }

                    QQC2.Label {
                        Layout.fillWidth: true
                        visible: sourceCard.sourceTransport === "relay"
                        wrapMode: Text.WordWrap
                        opacity: 0.7
                        text: i18n("The file must contain one complete https://app.paseo.sh/#offer=… URL and be readable only by your user (chmod 600). The secret URL is never copied into widget settings.")
                        font: Kirigami.Theme.smallFont
                    }

                    QQC2.Label {
                        Layout.fillWidth: true
                        opacity: 0.55
                        text: i18n("Source ID: %1", sourceCard.sourceId)
                        font: Kirigami.Theme.smallFont
                        elide: Text.ElideMiddle
                    }
                }
            }
        }

        QQC2.Button {
            text: i18n("Add source")
            icon.name: "list-add"
            onClicked: {
                var id = "source-" + Date.now()
                hostsModel.append({ sourceId: id, sourceName: i18n("Paseo host"),
                                    sourceTransport: "direct",
                                    endpoint: "ws://127.0.0.1:6767/ws", offerFile: "",
                                    sourceEnabled: true })
                page.saveSources()
            }
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: true
            type: Kirigami.MessageType.Information
            text: i18n("Relay setup: save the complete pairing link into a private file, run chmod 600 on it, then select Encrypted Paseo relay and enter that file path. Direct fallback: ssh -N -L 16767:127.0.0.1:6767 server.")
        }

        Item { Layout.fillHeight: true }
    }
}
