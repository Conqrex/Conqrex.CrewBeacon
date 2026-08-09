import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

Item {
    id: usage

    property var calendar: ({ days: [], maxTokens: 0, maxEvents: 0 })
    property var dayDetail: ({ ok: true, date: "", repositories: [], providers: [], sessions: [], events: [] })
    property date currentMonth: new Date(new Date().getFullYear(), new Date().getMonth(), 1)
    property string selectedDate: dateKey(new Date())
    property string detailMode: "repositories"

    signal dayRequested(string dateKey)

    function finite(value) {
        return typeof value === "number" && isFinite(value)
    }

    function formatTokens(value) {
        if (!finite(value)) return "—"
        if (value >= 1000000) return (value / 1000000).toFixed(value >= 10000000 ? 0 : 1) + "M"
        if (value >= 1000) return (value / 1000).toFixed(value >= 100000 ? 0 : 1) + "K"
        return "" + Math.round(value)
    }

    function formatCost(value) {
        return finite(value) && value > 0 ? "$" + value.toFixed(value < 0.1 ? 3 : 2) : "$0"
    }

    function twoDigits(number) {
        return number < 10 ? "0" + number : "" + number
    }

    function dateKey(value) {
        return value.getFullYear() + "-" + twoDigits(value.getMonth() + 1) + "-" + twoDigits(value.getDate())
    }

    function dayForCell(index) {
        var first = new Date(currentMonth.getFullYear(), currentMonth.getMonth(), 1)
        var mondayOffset = (first.getDay() + 6) % 7
        return new Date(first.getFullYear(), first.getMonth(), 1 - mondayOffset + index)
    }

    function dataForDate(key) {
        var days = calendar && Array.isArray(calendar.days) ? calendar.days : []
        for (var i = 0; i < days.length; i++)
            if (days[i].date === key) return days[i]
        return null
    }

    function monthMaxTokens() {
        var max = 0
        for (var i = 0; i < 42; i++) {
            var value = dayForCell(i)
            if (value.getMonth() !== currentMonth.getMonth()) continue
            var item = dataForDate(dateKey(value))
            if (item && item.totalTokens > max) max = item.totalTokens
        }
        return max
    }

    function monthStats() {
        var result = { days: 0, tokens: 0, events: 0, cost: 0 }
        var values = calendar && Array.isArray(calendar.days) ? calendar.days : []
        for (var i = 0; i < values.length; i++) {
            var parsed = new Date(values[i].date + "T12:00:00")
            if (parsed.getFullYear() !== currentMonth.getFullYear()
                    || parsed.getMonth() !== currentMonth.getMonth()) continue
            result.days++
            result.tokens += values[i].totalTokens || 0
            result.events += values[i].eventCount || 0
            result.cost += values[i].reportedCost || 0
        }
        return result
    }

    function heatAlpha(item) {
        if (!item) return 0
        var max = monthMaxTokens()
        if (max > 0 && item.totalTokens > 0)
            return 0.16 + 0.54 * Math.min(1, item.totalTokens / max)
        if (item.eventCount > 0 || item.reportedCost > 0) return 0.18
        return 0
    }

    function chooseDate(value) {
        if (value.getTime() > new Date().getTime()) return
        selectedDate = dateKey(value)
        if (value.getMonth() !== currentMonth.getMonth()
                || value.getFullYear() !== currentMonth.getFullYear())
            currentMonth = new Date(value.getFullYear(), value.getMonth(), 1)
        dayRequested(selectedDate)
    }

    function moveMonth(delta) {
        var candidate = new Date(currentMonth.getFullYear(), currentMonth.getMonth() + delta, 1)
        var today = new Date()
        var newest = new Date(today.getFullYear(), today.getMonth(), 1)
        if (candidate.getTime() > newest.getTime()) return
        currentMonth = candidate
        var selected = candidate.getFullYear() === today.getFullYear()
                    && candidate.getMonth() === today.getMonth()
                    ? today : new Date(candidate.getFullYear(), candidate.getMonth(), 1)
        chooseDate(selected)
    }

    function prettyDate(key) {
        var parsed = new Date(key + "T12:00:00")
        if (isNaN(parsed.getTime())) return key
        return parsed.toLocaleDateString(Qt.locale(), "dddd, d MMMM yyyy")
    }

    function timeLabel(iso) {
        var parsed = new Date(iso || "")
        if (isNaN(parsed.getTime())) return ""
        return parsed.toLocaleTimeString(Qt.locale(), "HH:mm")
    }

    readonly property bool detailReady: dayDetail && dayDetail.date === selectedDate
    readonly property var selectedCalendarDay: dataForDate(selectedDate)
    readonly property var visibleDetail: detailReady ? dayDetail : ({
        date: selectedDate, totalTokens: 0, inputTokens: 0, outputTokens: 0,
        cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: 0,
        reportedCost: 0, eventCount: 0,
        repositories: [], providers: [], sessions: [], events: []
    })
    readonly property var activeMonthStats: monthStats()

    component StatTile: Rectangle {
        property string label: ""
        property string value: ""
        property color accent: Kirigami.Theme.highlightColor
        Layout.fillWidth: true
        implicitHeight: statColumn.implicitHeight + Kirigami.Units.smallSpacing * 1.5
        radius: Kirigami.Units.cornerRadius
        color: Qt.alpha(accent, 0.10)
        ColumnLayout {
            id: statColumn
            anchors.centerIn: parent
            spacing: 0
            PlasmaComponents.Label {
                Layout.alignment: Qt.AlignHCenter
                text: parent.parent.value
                color: parent.parent.accent
                font.bold: true
            }
            PlasmaComponents.Label {
                Layout.alignment: Qt.AlignHCenter
                text: parent.parent.label
                opacity: 0.55
                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
            }
        }
    }

    component UsageRow: Rectangle {
        id: usageRow
        property string title: ""
        property string subtitle: ""
        property double tokens: 0
        property double share: 0
        property double cost: 0
        Layout.fillWidth: true
        implicitHeight: rowColumn.implicitHeight + Kirigami.Units.smallSpacing * 1.5
        radius: Kirigami.Units.cornerRadius
        color: Qt.alpha(Kirigami.Theme.textColor, 0.045)
        ColumnLayout {
            id: rowColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Kirigami.Units.smallSpacing
            anchors.rightMargin: Kirigami.Units.smallSpacing
            spacing: 2
            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: usageRow.title
                    font.bold: true
                    elide: Text.ElideMiddle
                }
                PlasmaComponents.Label {
                    text: usage.formatTokens(usageRow.tokens)
                    color: Kirigami.Theme.highlightColor
                    font.bold: true
                }
                PlasmaComponents.Label {
                    visible: usageRow.cost > 0
                    text: usage.formatCost(usageRow.cost)
                    opacity: 0.62
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 4
                radius: 2
                color: Qt.alpha(Kirigami.Theme.textColor, 0.08)
                Rectangle {
                    height: parent.height
                    width: parent.width * Math.max(0, Math.min(1, usageRow.share))
                    radius: parent.radius
                    color: Kirigami.Theme.highlightColor
                }
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: usageRow.subtitle
                opacity: 0.55
                elide: Text.ElideRight
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
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

            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.ToolButton {
                    icon.name: "go-previous"
                    onClicked: usage.moveMonth(-1)
                    PlasmaComponents.ToolTip { text: i18n("Previous month") }
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: usage.currentMonth.toLocaleDateString(Qt.locale(), "MMMM yyyy")
                    font.bold: true
                }
                PlasmaComponents.ToolButton {
                    icon.name: "go-next"
                    enabled: {
                        var today = new Date()
                        return usage.currentMonth.getFullYear() < today.getFullYear()
                            || usage.currentMonth.getMonth() < today.getMonth()
                    }
                    onClicked: usage.moveMonth(1)
                    PlasmaComponents.ToolTip { text: i18n("Next month") }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                StatTile {
                    label: i18n("tokens")
                    value: usage.formatTokens(usage.activeMonthStats.tokens)
                    accent: Kirigami.Theme.highlightColor
                }
                StatTile {
                    label: i18n("turns")
                    value: usage.activeMonthStats.events
                    accent: Kirigami.Theme.positiveTextColor
                }
                StatTile {
                    label: i18n("recorded days")
                    value: usage.activeMonthStats.days
                    accent: Kirigami.Theme.neutralTextColor
                }
                StatTile {
                    label: i18n("cost")
                    value: usage.formatCost(usage.activeMonthStats.cost)
                    accent: Qt.rgba(0.58, 0.46, 0.98, 1)
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: calendarColumn.implicitHeight + Kirigami.Units.smallSpacing * 2
                radius: Kirigami.Units.cornerRadius
                color: Qt.alpha(Kirigami.Theme.textColor, 0.035)
                ColumnLayout {
                    id: calendarColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Kirigami.Units.smallSpacing
                    anchors.rightMargin: Kirigami.Units.smallSpacing
                    spacing: 4

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 7
                        columnSpacing: 4
                        Repeater {
                            model: [i18n("Mon"), i18n("Tue"), i18n("Wed"), i18n("Thu"), i18n("Fri"), i18n("Sat"), i18n("Sun")]
                            delegate: PlasmaComponents.Label {
                                required property string modelData
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: modelData
                                opacity: 0.48
                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            }
                        }
                    }

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 7
                        columnSpacing: 4
                        rowSpacing: 4
                        Repeater {
                            model: 42
                            delegate: Rectangle {
                                id: dayCell
                                required property int index
                                readonly property date cellDate: usage.dayForCell(index)
                                readonly property string key: usage.dateKey(cellDate)
                                readonly property var dayData: usage.dataForDate(key)
                                readonly property bool inMonth: cellDate.getMonth() === usage.currentMonth.getMonth()
                                    && cellDate.getFullYear() === usage.currentMonth.getFullYear()
                                readonly property bool selected: usage.selectedDate === key
                                readonly property bool today: key === usage.dateKey(new Date())
                                readonly property bool future: cellDate.getTime() > new Date().getTime()
                                Layout.fillWidth: true
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 2.25
                                radius: Kirigami.Units.cornerRadius
                                color: dayData
                                    ? Qt.alpha(Kirigami.Theme.highlightColor, usage.heatAlpha(dayData))
                                    : Qt.alpha(Kirigami.Theme.textColor, inMonth ? 0.035 : 0.014)
                                border.width: selected ? 2 : (today ? 1 : 0)
                                border.color: selected
                                    ? Kirigami.Theme.highlightColor
                                    : Qt.alpha(Kirigami.Theme.positiveTextColor, 0.75)
                                opacity: inMonth ? (future ? 0.35 : 1) : 0.38

                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: 0
                                    PlasmaComponents.Label {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: dayCell.cellDate.getDate()
                                        font.bold: dayCell.selected || dayCell.today
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    PlasmaComponents.Label {
                                        visible: !!dayCell.dayData
                                        Layout.alignment: Qt.AlignHCenter
                                        text: dayCell.dayData ? usage.formatTokens(dayCell.dayData.totalTokens) : ""
                                        color: Kirigami.Theme.highlightColor
                                        font.bold: true
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize - 2
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !dayCell.future
                                    hoverEnabled: true
                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: usage.chooseDate(dayCell.cellDate)
                                    PlasmaComponents.ToolTip {
                                        visible: parent.containsMouse && !!dayCell.dayData
                                        text: dayCell.dayData
                                            ? i18n("%1 tokens · %2 turns", usage.formatTokens(dayCell.dayData.totalTokens), dayCell.dayData.eventCount)
                                            : ""
                                    }
                                }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 5
                        Rectangle {
                            width: 8
                            height: 8
                            radius: 2
                            color: Qt.alpha(Kirigami.Theme.highlightColor, 0.55)
                        }
                        PlasmaComponents.Label {
                            Layout.fillWidth: true
                            text: i18n("Darker days recorded more provider-reported tokens")
                            opacity: 0.48
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                        }
                        PlasmaComponents.Label {
                            text: i18n("Local time")
                            opacity: 0.48
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                        }
                    }
                }
            }

            Kirigami.Separator {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
            }

            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: usage.prettyDate(usage.selectedDate)
                    font.bold: true
                }
                PlasmaComponents.Label {
                    visible: usage.detailReady
                    text: i18np("%1 recorded turn", "%1 recorded turns", usage.visibleDetail.eventCount || 0)
                    opacity: 0.55
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            }

            RowLayout {
                visible: usage.detailReady && (usage.visibleDetail.eventCount > 0 || usage.visibleDetail.reportedCost > 0)
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                StatTile {
                    label: i18n("total")
                    value: usage.formatTokens(usage.visibleDetail.totalTokens)
                    accent: Kirigami.Theme.highlightColor
                }
                StatTile {
                    label: i18n("input")
                    value: usage.formatTokens(usage.visibleDetail.inputTokens)
                    accent: Kirigami.Theme.positiveTextColor
                }
                StatTile {
                    label: i18n("output")
                    value: usage.formatTokens(usage.visibleDetail.outputTokens)
                    accent: Kirigami.Theme.neutralTextColor
                }
                StatTile {
                    label: i18n("cache read")
                    value: usage.formatTokens(usage.visibleDetail.cacheReadTokens)
                    accent: Qt.rgba(0.58, 0.46, 0.98, 1)
                }
            }

            PlasmaComponents.Label {
                visible: !usage.detailReady
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.largeSpacing
                horizontalAlignment: Text.AlignHCenter
                text: i18n("Loading daily history…")
                opacity: 0.58
            }

            Rectangle {
                visible: usage.detailReady && usage.visibleDetail.eventCount === 0
                    && usage.visibleDetail.reportedCost === 0
                Layout.fillWidth: true
                implicitHeight: emptyColumn.implicitHeight + Kirigami.Units.largeSpacing * 2
                radius: Kirigami.Units.cornerRadius
                color: Qt.alpha(Kirigami.Theme.textColor, 0.035)
                ColumnLayout {
                    id: emptyColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Kirigami.Units.largeSpacing
                    anchors.rightMargin: Kirigami.Units.largeSpacing
                    Kirigami.Icon {
                        Layout.alignment: Qt.AlignHCenter
                        source: "office-chart-line"
                        color: Kirigami.Theme.disabledTextColor
                        Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    }
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: i18n("No recorded usage for this day")
                        font.bold: true
                    }
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: i18n("History includes only provider-reported turn events observed by CrewBeacon. Relay-only snapshots are not estimated or added as consumed usage.")
                        opacity: 0.55
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }

            RowLayout {
                visible: usage.detailReady && usage.visibleDetail.eventCount > 0
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Repeater {
                    model: [
                        { key: "repositories", label: i18n("Repos"), count: usage.visibleDetail.repositories.length },
                        { key: "providers", label: i18n("Models"), count: usage.visibleDetail.providers.length },
                        { key: "sessions", label: i18n("Sessions"), count: usage.visibleDetail.sessions.length },
                        { key: "events", label: i18n("Turns"), count: usage.visibleDetail.events.length }
                    ]
                    delegate: Rectangle {
                        id: detailChip
                        required property var modelData
                        readonly property bool active: usage.detailMode === modelData.key
                        implicitHeight: detailChipRow.implicitHeight + 6
                        implicitWidth: detailChipRow.implicitWidth + 12
                        radius: height / 2
                        color: active
                            ? Qt.alpha(Kirigami.Theme.highlightColor, 0.22)
                            : Qt.alpha(Kirigami.Theme.textColor, 0.06)
                        border.width: active ? 1 : 0
                        border.color: Qt.alpha(Kirigami.Theme.highlightColor, 0.6)
                        RowLayout {
                            id: detailChipRow
                            anchors.centerIn: parent
                            spacing: 3
                            PlasmaComponents.Label {
                                text: detailChip.modelData.label
                                font.bold: detailChip.active
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            PlasmaComponents.Label {
                                text: detailChip.modelData.count
                                opacity: 0.5
                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: usage.detailMode = detailChip.modelData.key
                        }
                    }
                }
                Item { Layout.fillWidth: true }
            }

            ColumnLayout {
                visible: usage.detailReady && usage.detailMode === "repositories"
                Layout.fillWidth: true
                spacing: 3
                Repeater {
                    model: usage.visibleDetail.repositories || []
                    delegate: UsageRow {
                        required property var modelData
                        title: modelData.repositoryName || i18n("Unattributed")
                        tokens: modelData.totalTokens || 0
                        share: modelData.share || 0
                        cost: modelData.reportedCost || 0
                        subtitle: i18n("%1 in · %2 out · %3 cache read · %4 cache write · %5 turns",
                                       usage.formatTokens(modelData.inputTokens),
                                       usage.formatTokens(modelData.outputTokens),
                                       usage.formatTokens(modelData.cacheReadTokens),
                                       usage.formatTokens(modelData.cacheWriteTokens),
                                       modelData.eventCount || 0)
                    }
                }
            }

            ColumnLayout {
                visible: usage.detailReady && usage.detailMode === "providers"
                Layout.fillWidth: true
                spacing: 3
                Repeater {
                    model: usage.visibleDetail.providers || []
                    delegate: UsageRow {
                        required property var modelData
                        title: (modelData.providerId || i18n("Unknown provider"))
                            + (modelData.modelId ? " · " + modelData.modelId : "")
                        tokens: modelData.totalTokens || 0
                        share: modelData.share || 0
                        cost: modelData.reportedCost || 0
                        subtitle: i18n("%1 in · %2 out · %3 cache read · %4 reasoning · %5 turns",
                                       usage.formatTokens(modelData.inputTokens),
                                       usage.formatTokens(modelData.outputTokens),
                                       usage.formatTokens(modelData.cacheReadTokens),
                                       usage.formatTokens(modelData.reasoningTokens),
                                       modelData.eventCount || 0)
                    }
                }
            }

            ColumnLayout {
                visible: usage.detailReady && usage.detailMode === "sessions"
                Layout.fillWidth: true
                spacing: 3
                Repeater {
                    model: usage.visibleDetail.sessions || []
                    delegate: UsageRow {
                        required property var modelData
                        title: modelData.sessionId || i18n("Unknown session")
                        tokens: modelData.totalTokens || 0
                        share: modelData.share || 0
                        cost: modelData.reportedCost || 0
                        subtitle: (modelData.providerId || i18n("Unknown provider"))
                            + i18n(" · %1 in · %2 out · %3 turns",
                                   usage.formatTokens(modelData.inputTokens),
                                   usage.formatTokens(modelData.outputTokens),
                                   modelData.eventCount || 0)
                    }
                }
            }

            ColumnLayout {
                visible: usage.detailReady && usage.detailMode === "events"
                Layout.fillWidth: true
                spacing: 3
                Repeater {
                    model: usage.visibleDetail.events || []
                    delegate: Rectangle {
                        id: eventRow
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: eventColumn.implicitHeight + Kirigami.Units.smallSpacing * 1.5
                        radius: Kirigami.Units.cornerRadius
                        color: Qt.alpha(Kirigami.Theme.textColor, 0.045)
                        ColumnLayout {
                            id: eventColumn
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Kirigami.Units.smallSpacing
                            anchors.rightMargin: Kirigami.Units.smallSpacing
                            spacing: 0
                            RowLayout {
                                Layout.fillWidth: true
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    text: eventRow.modelData.repositoryName || i18n("Unattributed")
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                PlasmaComponents.Label {
                                    text: usage.formatTokens((eventRow.modelData.inputTokens || 0)
                                                               + (eventRow.modelData.outputTokens || 0))
                                    color: Kirigami.Theme.highlightColor
                                    font.bold: true
                                }
                                PlasmaComponents.Label {
                                    text: usage.timeLabel(eventRow.modelData.capturedAt)
                                    opacity: 0.5
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                            }
                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                text: (eventRow.modelData.providerId || i18n("Unknown provider"))
                                    + (eventRow.modelData.modelId ? " · " + eventRow.modelData.modelId : "")
                                    + i18n(" · %1 in · %2 out · %3 cache read · %4 cache write",
                                           usage.formatTokens(eventRow.modelData.inputTokens || 0),
                                           usage.formatTokens(eventRow.modelData.outputTokens || 0),
                                           usage.formatTokens(eventRow.modelData.cacheReadTokens || 0),
                                           usage.formatTokens(eventRow.modelData.cacheWriteTokens || 0))
                                opacity: 0.55
                                elide: Text.ElideRight
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: Kirigami.Units.smallSpacing }
        }
    }

    Component.onCompleted: usage.dayRequested(usage.selectedDate)
}
