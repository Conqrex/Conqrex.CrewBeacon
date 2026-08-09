.pragma library

// Canonical provider registry. Single source of truth shared by main.qml,
// FullView.qml and the config page so the QML, the settings and the usage.sh
// dispatcher all agree on ids, order and presentation.

// Render order (top-to-bottom in the popup, and the tri-state combo order).
var ORDER = ["claude", "codex", "copilot", "gemini"];

// Per-provider presentation. `badge` + `color` draw the little heading chip;
// `live` marks whether a usable free usage read exists (gemini is detect-only).
var REGISTRY = {
    claude:  { label: "Claude",  badge: "✳", color: "#D97757", live: true,
               dash: "https://claude.ai/settings/usage" },
    codex:   { label: "Codex",   badge: "⌥", color: "#10A37F", live: true,
               dash: "https://chatgpt.com/#settings/Account" },
    copilot: { label: "Copilot", badge: "❉", color: "#6E9BF4", live: true,
               dash: "https://github.com/settings/copilot" },
    gemini:  { label: "Gemini",  badge: "✦", color: "#8E7CFF", live: false,
               dash: "https://aistudio.google.com" }
};

function meta(id) {
    return REGISTRY[id] || { label: id, badge: "•", color: "#888888", live: false };
}

function label(id) { return meta(id).label; }

// Pick a provider's primary weekly window. Claude exposes both a general
// weekly window and optional scoped weekly windows; only the general one is a
// panel headline. Codex currently reports its 7-day limit as `primary`.
function primaryWeeklyGauge(row) {
    if (!row || !row.ok || !row.gauges) return null;
    var i, gauge;
    for (i = 0; i < row.gauges.length; i++) {
        gauge = row.gauges[i];
        if (gauge.id === "weekly") return gauge;
    }
    for (i = 0; i < row.gauges.length; i++) {
        gauge = row.gauges[i];
        if (gauge.extra || (gauge.id || "").indexOf("weeklyScoped") === 0) continue;
        if ((gauge.cap || "").toUpperCase() === "7D"
                || (gauge.label || "").toLowerCase() === "weekly") return gauge;
    }
    return null;
}

function headlineGauge(row) {
    if (!row || !row.ok || !row.gauges || row.gauges.length === 0) return null;
    for (var i = 0; i < row.gauges.length; i++)
        if (!row.gauges[i].extra) return row.gauges[i];
    return row.gauges[0];
}

function compactItem(row, gauge) {
    if (!row || !gauge) return null;
    return {
        id: row.id,
        label: row.label,
        badge: row.badge,
        color: row.color,
        pct: gauge.pct,
        usedPct: gauge.usedPct,
        gaugeId: gauge.id,
        gaugeLabel: gauge.label,
        cap: gauge.cap
    };
}

// `all-weekly` returns one ring for every visible provider with a trustworthy
// weekly window. Other modes retain the historical single-ring behavior.
function compactItems(rows, preference) {
    var available = [];
    var i, item, gauge;
    for (i = 0; i < rows.length; i++) {
        gauge = preference === "all-weekly"
              ? primaryWeeklyGauge(rows[i]) : headlineGauge(rows[i]);
        item = compactItem(rows[i], gauge);
        if (item) available.push(item);
    }
    if (preference === "all-weekly") return available;
    if (available.length === 0) return [];
    if (preference && preference !== "first" && preference !== "hottest") {
        for (i = 0; i < available.length; i++)
            if (available[i].id === preference) return [available[i]];
        return [];
    }
    if (preference === "hottest") {
        var best = available[0];
        for (i = 1; i < available.length; i++)
            if (available[i].usedPct > best.usedPct) best = available[i];
        return [best];
    }
    return [available[0]];
}
