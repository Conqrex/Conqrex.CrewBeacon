.pragma library

// Clamp an arbitrary number to an integer 0..100.
function clampPct(x) {
    var v = Math.round(Number(x));
    if (isNaN(v)) v = 0;
    return Math.max(0, Math.min(100, v));
}

function pad(n) { return n < 10 ? "0" + n : "" + n; }

// Milliseconds remaining -> "3d 4h" / "2h 13m" / "5m" / "<1m" / "now".
function formatCountdown(ms) {
    if (ms === null || ms === undefined || isNaN(ms)) return "";
    var s = Math.floor(ms / 1000);
    if (s <= 0) return "now";
    var d = Math.floor(s / 86400); s -= d * 86400;
    var h = Math.floor(s / 3600);  s -= h * 3600;
    var m = Math.floor(s / 60);
    if (d > 0) return d + "d " + h + "h";
    if (h > 0) return h + "h " + m + "m";
    if (m > 0) return m + "m";
    return "<1m";
}

// ISO-8601 string -> local "Wed 14:00" (24h) or "Wed 2:00 PM" (12h).
function formatResetTime(iso, use24h) {
    if (!iso) return "";
    var dt = (iso instanceof Date) ? iso : new Date(iso);
    if (isNaN(dt.getTime())) return "";
    var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    var hh = dt.getHours();
    var mm = dt.getMinutes();
    var dayPart = days[dt.getDay()];
    if (use24h) {
        return dayPart + " " + pad(hh) + ":" + pad(mm);
    }
    var ap = hh >= 12 ? "PM" : "AM";
    var h12 = hh % 12; if (h12 === 0) h12 = 12;
    return dayPart + " " + h12 + ":" + pad(mm) + " " + ap;
}

// --- display styles --------------------------------------------------------

// Percent as a 7-bit binary string, e.g. 36 -> "0100100".
function toBinary(pct) {
    var v = clampPct(pct);
    var s = v.toString(2);
    while (s.length < 7) s = "0" + s;
    return s;
}

// Percent as an n-segment block meter, e.g. 36 -> "▰▰▰▰▱▱▱▱▱▱".
function toBlocks(pct, n) {
    n = n || 10;
    var filled = Math.round(clampPct(pct) / 100 * n);
    if (filled < 0) filled = 0;
    if (filled > n) filled = n;
    return "▰".repeat(filled) + "▱".repeat(n - filled);
}

// Format a percentage according to the chosen style.
//   "percent" -> "36%"   "binary" -> "0100100"   "blocks" -> "▰▰▰▰▱▱▱▱▱▱"
function formatValue(pct, style, blockCount) {
    switch (style) {
    case "binary": return toBinary(pct);
    case "blocks": return toBlocks(pct, blockCount || 10);
    default:       return clampPct(pct) + "%";
    }
}
