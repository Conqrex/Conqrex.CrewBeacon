import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const adapterPath = path.join(here, "..", "package", "contents", "code", "paseo.js");
const source = fs.readFileSync(adapterPath, "utf8").replace(/^\.pragma library\s*/, "");
const adapter = { Date, JSON, Math, Number, Array, Object, String, RegExp, isFinite, encodeURIComponent };
vm.createContext(adapter);
vm.runInContext(source, adapter, { filename: adapterPath });

const fixture = JSON.parse(fs.readFileSync(path.join(here, "fixtures", "paseo-0.2.5.json"), "utf8"));
const workspaces = Object.fromEntries(fixture.workspaces.map(workspace => [workspace.id, workspace]));

assert.equal(
  adapter.canonicalizeRemote("git@github.com:Conqrex/Conqrex.Engine.git"),
  "github.com/conqrex/conqrex.engine"
);
assert.equal(
  adapter.canonicalizeRemote("https://github.com/Conqrex/Conqrex.Engine.git"),
  "github.com/conqrex/conqrex.engine"
);
assert.equal(adapter.canonicalizeRemote("not a remote"), "");

const normalized = adapter.normalizeAgent(fixture.agents[0], fixture.source, workspaces);
assert.equal(normalized.state, "Working");
assert.equal(normalized.repositoryId, "remote:github.com/conqrex/conqrex.engine");
assert.equal(normalized.repositoryName, "Conqrex.Engine");
assert.equal(normalized.branch, "feat/rhi");
assert.equal(normalized.workspaceId, "wks_engine_feature");
assert.equal(normalized.capabilities.canReadTokenUsage, true);
assert.match(normalized.deepLink, /^paseo:\/h\/srv_fixture\/agent\/agent_working$/);

assert.equal(adapter.normalizeState({ status: "initializing", pendingPermissions: [] }), "Connecting");
assert.equal(adapter.normalizeState({ status: "running", pendingPermissions: [] }), "Working");
assert.equal(adapter.normalizeState({ status: "idle", pendingPermissions: [] }), "Idle");
assert.equal(adapter.normalizeState({ status: "closed", pendingPermissions: [] }), "Completed");
assert.equal(adapter.normalizeState({ status: "error", pendingPermissions: [] }), "Failed");
assert.equal(adapter.normalizeState({
  status: "idle", pendingPermissions: [{ id: "q", kind: "question" }]
}), "WaitingForInput");
assert.equal(adapter.normalizeState({
  status: "idle", pendingPermissions: [{ id: "p", kind: "tool" }]
}), "WaitingForPermission");

const usage = adapter.usageEventFromStream(fixture.source, normalized, fixture.turnCompleted);
assert.equal(usage.metricKind, "event_delta");
assert.equal(usage.dedupKey, "paseo:server-01:agent_working:epoch-a:42");
assert.equal(adapter.totalHistoricalTokens(usage), 1820);
assert.equal(usage.cacheReadTokens, 900, "cache reads are retained independently");

const contextOnly = adapter.usageEventFromStream(fixture.source, normalized, {
  agentId: "agent_working",
  timestamp: "2026-08-09T10:22:00Z",
  seq: 43,
  epoch: "epoch-a",
  event: { type: "turn_completed", provider: "claude",
           usage: { contextWindowUsedTokens: 22000, contextWindowMaxTokens: 200000 } }
});
assert.equal(contextOnly.metricKind, "context_snapshot");
assert.equal(adapter.totalHistoricalTokens(contextOnly), null,
             "context occupancy must never become cumulative token history");

const sessionMap = { agent_working: normalized };
const attention = adapter.attentionEventFromMessage(fixture.source, fixture.question, sessionMap);
assert.equal(attention.type, "WaitingForInput");
assert.match(attention.dedupKey, /question-1$/);
assert.equal(adapter.attentionEventFromMessage(fixture.source, { type: "future_message" }, sessionMap), null);
assert.equal(adapter.usageEventFromStream(fixture.source, normalized, { event: { type: "future" } }), null);

assert.equal(adapter.reconnectDelay(0, 0), 1500);
assert.equal(adapter.reconnectDelay(1, 0), 3000);
assert.equal(adapter.reconnectDelay(99, 0), 30000);
assert.equal(adapter.reconnectDelay(99, 1), 30750);

const connectedEmpty = { local: { host: { connectionState: "Connected" }, sessions: [] } };
assert.equal(adapter.shouldRetainStoredSession({ sourceId: "local", state: "Working" }, connectedEmpty), false,
             "a fresh empty source must clear a persisted active state");
assert.equal(adapter.shouldRetainStoredSession({ sourceId: "local", state: "WaitingForInput" }, connectedEmpty), false);
assert.equal(adapter.shouldRetainStoredSession({ sourceId: "local", state: "Completed" }, connectedEmpty), true,
             "terminal history remains available after reconnect");
assert.equal(adapter.shouldRetainStoredSession(
  { sourceId: "remote", state: "Working" },
  { remote: { host: { connectionState: "Disconnected" }, sessions: [] } }
), true, "offline hosts retain their last known state, visibly marked stale");

const firstFallback = adapter.repositoryIdentity({}, { projectRootPath: "/srv/a/src" }, "one", "/srv/a/src");
const secondFallback = adapter.repositoryIdentity({}, { projectRootPath: "/srv/b/src" }, "two", "/srv/b/src");
assert.notEqual(firstFallback.id, secondFallback.id,
                "same folder basename on different hosts must not merge repositories");

console.log("paseo adapter tests: PASS");
