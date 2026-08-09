import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "../code/format.js" as Fmt

// Provider quota view: one section per enabled+detected provider. Each section is
// a row of animated ring-gauge cards (or modern bars) for that provider's usage
// windows. Single-provider setups render with no provider heading, identical to
// the original Claude-only layout.
ColumnLayout {
    id: full

    property var providers: []           // array of provider rows (see main.qml buildProviders)
    property double nowMs: 0
    property string lastUpdated: ""
    property bool use24h: true
    property string numberStyle: "percent"
    property string usageDisplay: "used"
    property bool mono: false
    property string gaugeStyle: "ring"
    property bool showWeeklySonnet: false
    property bool showHeader: true
    property bool showFooter: true
    property bool compact: false

    // Assistant activity (see main.qml): one colored dot + label per live
    // session, so concurrent chats show separately under their provider row.
    property bool activityShow: false
    property var activitySessions: []

    signal refreshRequested()
    signal openSessionRequested(string cwd)

    // Copilot-style absolute counts ("142 / 300 left") when the gauge carries them.
    function countLine(g) {
        if (!g) return "";
        if (g.unlimited) return i18n("unlimited");
        if (g.remaining !== null && g.remaining !== undefined && g.entitlement) {
            if (full.usageDisplay === "left")
                return i18n("%1 / %2 left", g.remaining, g.entitlement);
            return i18n("%1 / %2 used", Math.max(0, g.entitlement - g.remaining), g.entitlement);
        }
        return "";
    }
    // Elapsed turn time, e.g. 2m14s / 1h03m.
    function formatTurn(sec) {
        if (!sec || sec <= 0) return "";
        var s = Math.floor(sec), m = Math.floor(s / 60), h = Math.floor(m / 60);
        s = s % 60; m = m % 60;
        if (h > 0) return h + "h" + (m < 10 ? "0" : "") + m + "m";
        if (m > 0) return m + "m" + (s < 10 ? "0" : "") + s + "s";
        return s + "s";
    }

    function activityColor(state) {
        switch (state) {
        case "working":   return Qt.rgba(0.20, 0.83, 0.92, 1);     // cyan — generating
        case "idle":      return Kirigami.Theme.disabledTextColor; // muted — no action
        case "attention": return Kirigami.Theme.negativeTextColor; // red — needs you
        default:          return "transparent";
        }
    }
    function activityLabel(state) {
        switch (state) {
        case "working":   return i18n("working…");
        case "idle":      return i18n("idle");
        case "attention": return i18n("needs you");
        default:          return "";
        }
    }
    function activitySessionsFor(providerId) {
        var out = [];
        for (var i = 0; i < full.activitySessions.length; i++) {
            var s = full.activitySessions[i];
            if ((s.provider || "claude") === providerId) out.push(s);
        }
        return out;
    }

    readonly property bool multi: providers.length > 1

    Layout.preferredWidth: Kirigami.Units.gridUnit * 20
    Layout.minimumWidth: Kirigami.Units.gridUnit * 16
    spacing: full.compact ? 2 : Kirigami.Units.smallSpacing

    function extraVisible(gaugeId) {
        if (gaugeId === "weeklySonnet") return full.showWeeklySonnet;
        return false;
    }
    function visibleGauges(row) {
        var out = [];
        if (!row || !row.gauges) return out;
        for (var i = 0; i < row.gauges.length; i++) {
            var g = row.gauges[i];
            if (g.extra && !extraVisible(g.id)) continue;
            out.push(g);
        }
        return out;
    }
    function resetLine(iso) {
        if (!iso) return "";
        var d = (iso instanceof Date) ? iso : new Date(iso);
        if (isNaN(d.getTime())) return "";
        return i18n("resets in %1  ·  %2",
                    Fmt.formatCountdown(d.getTime() - full.nowMs),
                    Fmt.formatResetTime(d, full.use24h));
    }
    function reasonText(id, reason) {
        switch (reason) {
        case "tier_retired":
            return i18n("Free tier retired — usage unavailable");
        case "no_credentials":
        case "no_token":
            return i18n("Not signed in");
        case "token_expired":
        case "http_401":
        case "http_403":
            return i18n("Sign-in expired — re-authenticate, then Refresh");
        case "http_404":
            return i18n("Usage endpoint unavailable");
        case "bad_json":
        case "parse_error":
            return i18n("Usage response changed — refresh later");
        case "":
            return i18n("Loading…");
        default:
            return i18n("Unavailable (%1)", reason);
        }
    }

    // --- a single ring card -------------------------------------------------
    component GaugeCard: ColumnLayout {
        property string title
        property string cap
        property int pct
        property var resetIso: null
        property color accent
        property string countText: ""

        Layout.alignment: Qt.AlignHCenter
        spacing: Math.round(Kirigami.Units.smallSpacing / 2)

        Gauge {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: Kirigami.Units.gridUnit * 6.4
            Layout.preferredHeight: Kirigami.Units.gridUnit * 6.4
            value: pct
            accentColor: accent
            centerText: Fmt.formatValue(pct, full.numberStyle)
            caption: cap
            mono: full.mono
        }
        PlasmaComponents.Label {
            Layout.alignment: Qt.AlignHCenter
            text: title
            font.bold: true
        }
        PlasmaComponents.Label {
            Layout.alignment: Qt.AlignHCenter
            visible: countText !== ""
            text: countText
            opacity: 0.8
            font: Kirigami.Theme.smallFont
        }
        PlasmaComponents.Label {
            Layout.alignment: Qt.AlignHCenter
            visible: text !== ""
            text: full.resetLine(resetIso)
            opacity: 0.65
            font: Kirigami.Theme.smallFont
        }
    }

    // --- header -------------------------------------------------------------
    RowLayout {
        Layout.fillWidth: true
        visible: full.showHeader
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            source: "speedometer"
            Layout.preferredWidth: Kirigami.Units.iconSizes.medium
            Layout.preferredHeight: Kirigami.Units.iconSizes.medium
        }
        Kirigami.Heading {
            level: 3
            text: i18n("Quota")
            Layout.fillWidth: true
        }
        PlasmaComponents.ToolButton {
            icon.name: "view-refresh"
            onClicked: full.refreshRequested()
            PlasmaComponents.ToolTip { text: i18n("Refresh now") }
        }
    }

    // --- empty state --------------------------------------------------------
    PlasmaComponents.Label {
        visible: full.providers.length === 0
        Layout.fillWidth: true
        Layout.topMargin: Kirigami.Units.smallSpacing
        wrapMode: Text.WordWrap
        opacity: 0.8
        text: i18n("No AI usage sources detected. Sign in with Claude Code, Codex or GitHub Copilot, or enable a provider in settings.")
    }

    // --- one section per provider ------------------------------------------
    Repeater {
        model: full.providers
        delegate: ColumnLayout {
            id: section
            required property var modelData
            readonly property var gauges: full.visibleGauges(modelData)

            Layout.fillWidth: true
            Layout.topMargin: full.compact ? 0 : Kirigami.Units.smallSpacing
            spacing: full.compact ? 2 : Kirigami.Units.smallSpacing

            // provider heading (only when more than one provider is shown)
            RowLayout {
                Layout.fillWidth: true
                visible: full.multi
                spacing: Kirigami.Units.smallSpacing

                Rectangle {
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    radius: height * 0.3
                    color: section.modelData.color
                    Text {
                        anchors.centerIn: parent
                        text: section.modelData.badge
                        color: "white"
                        font.bold: true
                        font.pixelSize: parent.height * 0.62
                    }
                }
                PlasmaComponents.Label {
                    text: section.modelData.label
                    font.bold: true
                }
                PlasmaComponents.Label {
                    visible: !!section.modelData.plan
                    text: section.modelData.plan ? ("· " + section.modelData.plan) : ""
                    opacity: 0.6
                    font: Kirigami.Theme.smallFont
                }
                Item { Layout.fillWidth: true }
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: full.compact ? 1 : 2
                radius: 1
                visible: full.multi
                color: section.modelData.color
                opacity: 0.5
            }

            // plan + stale-data line (plan shown for single-provider too, where
            // there's no heading to carry it; stale = last good data, refresh failing)
            RowLayout {
                Layout.fillWidth: true
                spacing: full.compact ? 2 : Kirigami.Units.smallSpacing
                visible: (!full.multi && !!section.modelData.plan && section.modelData.ok)
                         || section.modelData.bankedRefreshes !== null
                         || !!section.modelData.stale
                PlasmaComponents.Label {
                    visible: !full.multi && !!section.modelData.plan && section.modelData.ok
                    text: i18n("Plan: %1", section.modelData.plan || "")
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
                }
                PlasmaComponents.Label {
                    visible: section.modelData.bankedRefreshes !== null
                    text: i18n("Banked refreshes: %1", section.modelData.bankedRefreshes)
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.Label {
                    visible: !!section.modelData.stale
                    text: i18n("⚠ stale")
                    color: Kirigami.Theme.neutralTextColor
                    opacity: 0.85
                    font: Kirigami.Theme.smallFont
                    PlasmaComponents.ToolTip {
                        text: i18n("Showing last known data — refresh is failing")
                    }
                }
            }

            // Assistant activity — one row per live session (concurrent chats split)
            ColumnLayout {
                id: activityBlock

                property var providerSessions: full.activitySessionsFor(section.modelData.id)

                visible: full.activityShow && activityBlock.providerSessions.length > 0
                Layout.fillWidth: true
                spacing: Math.round(Kirigami.Units.smallSpacing / 2)

                Repeater {
                    model: activityBlock.providerSessions
                    delegate: Rectangle {
                        id: sessRow
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: sessLay.implicitHeight
                                                + Math.round(Kirigami.Units.smallSpacing / 2)
                        radius: 3
                        color: sessMouse.containsMouse
                               ? Qt.rgba(Kirigami.Theme.highlightColor.r,
                                         Kirigami.Theme.highlightColor.g,
                                         Kirigami.Theme.highlightColor.b, 0.12)
                               : "transparent"

                        RowLayout {
                            id: sessLay
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Kirigami.Units.smallSpacing

                            Rectangle {
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small * 0.55
                                Layout.preferredHeight: Layout.preferredWidth
                                radius: height / 2
                                color: full.activityColor(sessRow.modelData.state)
                            }
                            PlasmaComponents.Label {
                                text: (sessRow.modelData.name && sessRow.modelData.name !== "")
                                      ? sessRow.modelData.name : section.modelData.label
                                opacity: 0.9
                                elide: Text.ElideRight
                                Layout.maximumWidth: Kirigami.Units.gridUnit * 8
                                font: Kirigami.Theme.smallFont
                            }
                            PlasmaComponents.Label {
                                text: "· " + full.activityLabel(sessRow.modelData.state)
                                opacity: 0.7
                                font: Kirigami.Theme.smallFont
                            }
                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                visible: !!sessRow.modelData.tool
                                text: sessRow.modelData.tool ? ("· " + sessRow.modelData.tool) : ""
                                opacity: 0.55
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                            }
                            Item { Layout.fillWidth: true; visible: !sessRow.modelData.tool }
                            PlasmaComponents.Label {
                                visible: full.formatTurn(sessRow.modelData.turnSec) !== ""
                                text: full.formatTurn(sessRow.modelData.turnSec)
                                opacity: 0.55
                                font: Kirigami.Theme.smallFont
                            }
                        }

                        MouseArea {
                            id: sessMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (sessRow.modelData.cwd)
                                           full.openSessionRequested(sessRow.modelData.cwd)
                            PlasmaComponents.ToolTip {
                                text: sessRow.modelData.cwd
                                      ? i18n("Open %1", sessRow.modelData.cwd) : ""
                                visible: sessMouse.containsMouse && !!sessRow.modelData.cwd
                            }
                        }
                    }
                }
            }

            // not-ok / loading row
            PlasmaComponents.Label {
                visible: !section.modelData.ok
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                opacity: 0.7
                text: section.modelData.loading
                      ? i18n("Loading…")
                      : full.reasonText(section.modelData.id, section.modelData.reason)
            }

            // ring layout
            GridLayout {
                visible: section.modelData.ok && full.gaugeStyle === "ring" && section.gauges.length > 0
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                columns: 2
                columnSpacing: Kirigami.Units.largeSpacing * 2
                rowSpacing: Kirigami.Units.largeSpacing

                Repeater {
                    model: section.gauges
                    delegate: GaugeCard {
                        required property var modelData
                        required property int index
                        title: modelData.label
                        cap: modelData.cap
                        pct: modelData.pct
                        resetIso: modelData.reset
                        accent: modelData.accent
                        countText: full.countLine(modelData)
                        // center a lone trailing card across both columns
                        Layout.columnSpan: (index === section.gauges.length - 1
                                            && section.gauges.length % 2 === 1) ? 2 : 1
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
            }

            // bar layout
            ColumnLayout {
                visible: section.modelData.ok && full.gaugeStyle === "bar" && section.gauges.length > 0
                Layout.fillWidth: true
                spacing: full.compact ? 2 : Kirigami.Units.smallSpacing

                Repeater {
                    model: section.gauges
                    delegate: UsageBar {
                        required property var modelData
                        Layout.fillWidth: true
                        label: modelData.label
                        pct: modelData.pct
                        valueText: Fmt.formatValue(modelData.pct, full.numberStyle)
                        mono: full.mono
                        accentColor: modelData.accent
                        resetText: {
                            var c = full.countLine(modelData);
                            var r = full.resetLine(modelData.reset);
                            return c && r ? (c + "  ·  " + r) : (c || r);
                        }
                    }
                }
            }
        }
    }

    // --- footer -------------------------------------------------------------
    PlasmaComponents.Label {
        visible: full.showFooter && full.lastUpdated !== "" && full.providers.length > 0
        Layout.fillWidth: true
        Layout.topMargin: Kirigami.Units.smallSpacing
        horizontalAlignment: Text.AlignRight
        opacity: 0.6
        font: Kirigami.Theme.smallFont
        text: i18n("Updated %1", full.lastUpdated)
    }
}
