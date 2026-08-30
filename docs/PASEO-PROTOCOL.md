# CrewBeacon — Paseo protocol compatibility

**Verified:** 2026-08-20
**Supported direct adapter:** Paseo wire protocol `1`
**Concrete verification targets:** daemon `0.2.5` and `0.4.0`; current official protocol/client source

## Primary evidence

The implementation was verified against the locally installed official Paseo desktop bundle rather than inferred from UI output:

```text
/opt/Paseo/resources/app.asar
SHA-256 024e308ad6ca6ce3710a21f138f9e799cecf84378e9769f34cf2f35f10ab3271
bundle timestamp 2026-07-30T18:53:55+03:00
@getpaseo/protocol 0.2.5
Paseo CLI 0.2.5
Paseo daemon 0.2.5
```

Relevant packaged sources:

- `@getpaseo/protocol/dist/messages.js`
- `@getpaseo/protocol/dist/daemon-endpoints.js`
- `@getpaseo/protocol/dist/agent-lifecycle.js`
- `@getpaseo/protocol/dist/agent-state-bucket.js`
- `@getpaseo/client/dist/daemon-client.js`
- `@getpaseo/client/dist/daemon-client-websocket-transport.js`
- `@getpaseo/server/dist/server/server/agent/agent-manager.js`
- provider adapters under `@getpaseo/server/dist/server/server/agent/providers/`

A read-only connection to the running local daemon confirmed the handshake and the actual `server_info`, `fetch_agents_response`, and `fetch_workspaces_response` envelopes. The daemon was not restarted or changed.

## Transport and authentication

Direct daemon WebSockets use:

```text
ws://HOST:PORT/ws
wss://HOST:PORT/ws
```

The default daemon listens on `127.0.0.1:6767`. A direct password is sent as `Authorization: Bearer …` by Node clients and as the WebSocket subprotocol `paseo.bearer.PASSWORD` for browser-compatible clients.

CrewBeacon accepts direct `ws`/`wss` endpoints without embedded credentials. For a dedicated server, use a secure private network or an SSH forward to the server's loopback listener, for example a local endpoint such as `ws://127.0.0.1:16767/ws`. Do not expose port 6767 publicly.

## Official relay boundary

CrewBeacon also accepts an `https://app.paseo.sh/#offer=…` trust anchor through
a current-user `0600` file. It does not reimplement relay cryptography. The
installed official Paseo CLI consumes the offer through `PASEO_HOST` and
returns `paseo ls --json --global`; CrewBeacon polls that read-only directory
snapshot every 20 seconds. The offer itself is absent from KConfig, command-line
arguments, logs, SQLite, and QML host models. TLS verification is explicitly
enabled for the child process even when a user shell has disabled Node's normal
verification globally.

Live verification on 2026-08-09 used local CLI `0.2.5` against
`relay.paseo.sh:443` and dedicated server `srv_KNDdkMz9WAo6`, which was managed
by CLI `0.3.0`. The relay snapshot exposed running, idle, and closed sessions.
This CLI surface provides basic ID/title/provider/cwd/status fields, not direct
timeline, workspace, permission, branch, or usage events. CrewBeacon advertises
those relay capabilities as unavailable rather than fabricating them.

## Handshake

On WebSocket open the client sends:

```json
{
  "type": "hello",
  "clientId": "crewbeacon-<stable source id>",
  "clientType": "browser",
  "protocolVersion": 1,
  "appVersion": "0.1.0",
  "capabilities": {
    "projectUpdates": true,
    "selectiveAgentTimeline": true
  }
}
```

Connection is considered ready only after this wrapped server message:

```json
{
  "type": "session",
  "message": {
    "type": "status",
    "payload": {
      "status": "server_info",
      "serverId": "srv_…",
      "hostname": "server-01",
      "version": "0.2.5",
      "features": {}
    }
  }
}
```

CrewBeacon rejects a missing/malformed server identity. The product `version`
is informational: the official client contract keeps daemon/client releases
wire-compatible, with optional additions advertised through
`server_info.features`. A valid `server_info` response to CrewBeacon's
protocol-1 hello is therefore accepted across Paseo product releases.

## Read-only requests

Loopback sources are sampled through the official local Paseo CLI and
normalized in a short-lived helper process. This keeps large agent snapshots
out of plasmashell while preserving read-only behavior. Remote direct sources
use the WebSocket requests below; relay sources use the CLI offer-link flow.

All session protocol messages are wrapped as:

```json
{"type":"session","message":{}}
```

CrewBeacon sends only these read/subscription requests:

```json
{
  "type": "fetch_agents_request",
  "requestId": "…",
  "filter": {"includeArchived": false},
  "sort": [{"key":"updated_at","direction":"desc"}],
  "page": {"limit": 200}
}
```

```json
{
  "type": "fetch_workspaces_request",
  "requestId": "…",
  "sort": [{"key":"activity_at","direction":"desc"}],
  "page": {"limit": 200}
}
```

When `server_info.features.selectiveAgentTimeline` is true, CrewBeacon subscribes to timeline events for the visible agent IDs:

```json
{
  "type": "agent.timeline.set_subscription.request",
  "agentIds": ["…"],
  "requestId": "…"
}
```

The adapter handles `fetch_agents_response`, `fetch_workspaces_response`, `agent_update`, `workspace_update`, `agent_stream`, `agent_permission_request`, `agent_permission_resolved`, and `agent_attention_required`. Unknown envelopes are ignored and counted diagnostically.

## Verified model fields

Agent snapshots expose:

```text
id, provider, cwd, workspaceId, model, createdAt, updatedAt,
lastUserMessageAt, status, capabilities, pendingPermissions,
runtimeInfo, lastUsage, lastError, title, labels,
requiresAttention, attentionReason, attentionTimestamp, archivedAt
```

Lifecycle statuses in `0.2.5` are exactly:

```text
initializing, idle, running, error, closed
```

Workspace descriptors expose stable project/workspace separation, paths, kind, status, activity timestamp, and Git runtime metadata. The project placement checkout includes `currentBranch`, `remoteUrl`, `worktreeRoot`, `isPaseoOwnedWorktree`, and `mainRepoRoot`.

## State mapping

External values are translated only in `paseo.js`:

| Paseo evidence | CrewBeacon state |
|---|---|
| `pendingPermissions[].kind == "question"` | `WaitingForInput` |
| another pending permission or `attentionReason == "permission"` | `WaitingForPermission` |
| `status == "error"` or `attentionReason == "error"` | `Failed` |
| `status == "initializing"` | `Connecting` |
| `status == "running"` | `Working` |
| explicit finished attention or `status == "closed"` | `Completed` |
| `status == "idle"` | `Idle` |
| disconnected source | last state retained with stale/disconnected source metadata |

Silence or elapsed time never produces `WaitingForInput`.

## Attention events

`agent_attention_required` and the equivalent `agent_stream.attention_required` event carry only these reasons:

```text
finished, error, permission
```

Permission requests separately carry `kind` values `tool`, `plan`, `question`, `mode`, or `other`. CrewBeacon uses `question` as explicit input-waiting evidence and treats the others as permission waiting. Notification dedup keys include source, agent, reason/request ID, and source timestamp.

## Usage accuracy

Paseo `turn_completed` may carry:

```text
inputTokens, cachedInputTokens, outputTokens, totalCostUsd,
contextWindowUsedTokens, contextWindowMaxTokens
```

CrewBeacon persists token/cost fields only from a deduplicated `turn_completed` event and classifies them as provider-reported event deltas. `contextWindowUsedTokens` and `contextWindowMaxTokens` are stored only as context snapshots and are excluded from historical token totals.

`AgentSnapshot.lastUsage` is not treated as a cumulative session counter. In the verified server it is overwritten/merged from the most recent usage update or completed turn, and provider adapters differ in semantics. It is suitable for a current-session detail line, not for summing history.

Provider support is capability-based. Missing token or cost fields remain null/unavailable.

## Known limitations

- Relay E2EE supports read-only directory polling through an installed official Paseo CLI; it does not yet stream direct-protocol timeline or usage events.
- Password-authenticated direct sockets are not configured in plain widget settings. Use an SSH-forwarded loopback endpoint or another secure password-free transport boundary for this slice.
- The protocol does not expose a historical stream of per-turn usage deltas through the directory snapshot. CrewBeacon never estimates usage from it. A separate local-only adapter can import deduplicated provider counters from Claude/Codex JSONL logs.
- The adapter displays the first 200 non-archived agents/workspaces per source. Pagination can be added without changing the normalization boundary.
- `WaitingForInput` is available only for explicit `question` permission requests in `0.2.5`; no state is inferred from inactivity.
