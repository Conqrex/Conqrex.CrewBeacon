.pragma library

// Provider-neutral quota domain boundary. Acquisition adapters emit a common
// envelope; this module turns it into QuotaSnapshot / QuotaWindow concepts.

function clampRatio(value) {
    var number = Number(value)
    if (isNaN(number)) number = 0
    return Math.max(0, Math.min(1, number))
}

function normalizeEnvelope(providerId, envelope) {
    var raw = envelope && typeof envelope === "object" ? envelope : {}
    var windows = []
    var gauges = Array.isArray(raw.gauges) ? raw.gauges : []
    for (var i = 0; i < gauges.length; i++) {
        var gauge = gauges[i] || {}
        var pct = Math.round(clampRatio(Number(gauge.pct) / 100) * 100)
        windows.push({
            id: gauge.id || ("window-" + i),
            label: gauge.label || "Quota",
            cap: gauge.cap || "",
            usedRatio: pct / 100,
            remainingRatio: 1 - pct / 100,
            resetAt: gauge.reset || null,
            plan: raw.plan || null,
            extra: !!gauge.extra,
            pct: pct,
            reset: gauge.reset || null,
            remaining: gauge.remaining !== undefined ? gauge.remaining : null,
            entitlement: gauge.entitlement !== undefined ? gauge.entitlement : null,
            unlimited: !!gauge.unlimited
        })
    }
    return {
        providerId: providerId,
        accountLabel: raw.label || providerId,
        plan: raw.plan || null,
        windows: windows,
        capturedAt: raw.fetchedAt || null,
        source: "provider-metering-api",
        available: raw.ok === true,
        stale: !!raw.stale,
        error: raw.ok === true ? "" : (raw.reason || "unavailable")
    }
}

// QML var properties only notify bindings when assigned a different object.
// Provider fetches therefore update maps copy-on-write instead of mutating the
// existing object, which lets the first startup response replace "Loading".
function withProviderResult(current, providerId, result) {
    var next = {}
    var source = current && typeof current === "object" ? current : {}
    for (var key in source) next[key] = source[key]
    next[providerId] = result
    return next
}
