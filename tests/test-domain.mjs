import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const codeDir = path.join(here, "..", "package", "contents", "code");

function load(name) {
  const filename = path.join(codeDir, name);
  const source = fs.readFileSync(filename, "utf8").replace(/^\.pragma library\s*/, "");
  const context = { Date, JSON, Math, Number, Array, Object, String, RegExp, isFinite, isNaN };
  vm.createContext(context);
  vm.runInContext(source, context, { filename });
  return context;
}

const quota = load("quota.js");
const format = load("format.js");
const providers = load("providers.js");

const snapshot = quota.normalizeEnvelope("claude", {
  ok: true,
  label: "Claude",
  plan: "max",
  fetchedAt: "2026-08-09T10:00:00Z",
  gauges: [
    { id: "session", label: "Session", cap: "5H", pct: 19, reset: "2026-08-09T14:00:00Z" },
    { id: "weekly", label: "Weekly", cap: "7D", pct: 62, reset: "2026-08-12T00:00:00Z" }
  ]
});

assert.equal(snapshot.providerId, "claude");
assert.equal(snapshot.available, true);
assert.equal(snapshot.windows.length, 2);
assert.equal(snapshot.windows[0].usedRatio, 0.19);
assert.equal(snapshot.windows[0].remainingRatio, 0.81);
assert.equal(snapshot.windows[1].resetAt, "2026-08-12T00:00:00Z");

const missing = quota.normalizeEnvelope("codex", { ok: false, reason: "no_credentials" });
assert.equal(missing.available, false);
assert.equal(missing.error, "no_credentials");
assert.equal(missing.windows.length, 0);

const clamped = quota.normalizeEnvelope("test", { ok: true, gauges: [{ pct: 140 }, { pct: -5 }] });
assert.equal(clamped.windows[0].pct, 100);
assert.equal(clamped.windows[1].pct, 0);

assert.equal(format.clampPct(101), 100);
assert.equal(format.clampPct(-1), 0);
assert.equal(format.formatCountdown(3_661_000), "1h 1m");
assert.equal(format.formatCountdown(0), "now");
assert.equal(format.formatValue(36, "binary"), "0100100");

const compactRows = [
  {
    id: "claude", label: "Claude", badge: "✳", color: "#D97757", ok: true,
    gauges: [
      { id: "session", label: "Session", cap: "5H", pct: 92, usedPct: 92, extra: false },
      { id: "weekly", label: "Weekly", cap: "7D", pct: 53, usedPct: 53, extra: false },
      { id: "weeklyScoped-fable", label: "Weekly · Fable", cap: "7D", pct: 69, usedPct: 69, extra: false }
    ]
  },
  {
    id: "codex", label: "Codex", badge: "⌥", color: "#10A37F", ok: true,
    gauges: [{ id: "primary", label: "Weekly", cap: "7D", pct: 17, usedPct: 17, extra: false }]
  },
  {
    id: "copilot", label: "Copilot", badge: "❉", color: "#6E9BF4", ok: true,
    gauges: [{ id: "premium", label: "Premium requests", cap: "30D", pct: 50, usedPct: 50, extra: false }]
  }
];
const weeklyCompact = providers.compactItems(compactRows, "all-weekly");
assert.deepEqual(Array.from(weeklyCompact, item => item.id), ["claude", "codex"]);
assert.deepEqual(Array.from(weeklyCompact, item => item.pct), [53, 17]);
assert.equal(providers.compactItems(compactRows, "hottest")[0].id, "claude");
assert.equal(providers.compactItems(compactRows, "codex")[0].pct, 17);

console.log("quota/format domain tests: PASS");
