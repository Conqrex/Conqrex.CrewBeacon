# CrewBeacon — Design

**Date:** 2026-08-09  
**Status:** Current architecture  
**Package ID:** `com.conqrex.crewbeacon`

## Problem

Quota answers how much subscription capacity remains, but it does not show what
coding agents are doing on a dedicated server, which repository they belong to,
or whether anything needs a person. CrewBeacon combines quota and a server-aware
agent cockpit without conflating quota, context occupancy, token consumption,
and agent state.

## Decisions

| Topic | Decision |
|---|---|
| Product scope | Standalone Plasma widget for provider quota, live agents, attention, source health, and daily usage history |
| UI | Plasma 6 QML/Kirigami; OctoPulse palette and geometry; Overview and Usage tabs |
| Paseo transport | Native Qt WebSockets for narrow `0.2.x` direct support; official CLI for E2EE offer-link relay polling |
| Source topology | Independent source objects merged at the root; direct and relay failures remain isolated |
| Remote control | Out of scope; only list/subscription/timeline-subscription requests are sent |
| Persistence | Small on-demand Python standard-library SQLite helper; no resident companion daemon |
| Usage policy | Persist only observed `turn_completed` provider-reported deltas; store context separately and exclude it from totals |
| Repository identity | Canonical remote first; Paseo project key second; host + root path fallback |
| Secrets | No endpoint passwords or offer URLs in KConfig; relay offers are user-owned `0600` files |
| Notifications | Explicit protocol evidence only, SQLite primary-key dedup across reconnects/restarts |

## Architecture

```text
┌──────────────────────── KDE Plasma / QML ────────────────────────┐
│ main.qml                                                         │
│  ├─ quota acquisition + normalized QuotaSnapshot                │
│  ├─ source/session/host aggregation                             │
│  ├─ notification gate                                            │
│  └─ CompactView / FullView                                       │
│      ├─ OverviewView: attention + agents + quota + sources       │
│      └─ UsageHistoryView: calendar + selected-day drill-down     │
│                                                                  │
│ PaseoSource × N                                                  │
│  ├─ direct: Qt WebSocket + hello/version gate                    │
│  ├─ relay: official Paseo CLI + private offer file               │
│  ├─ direct agent/workspace subscriptions                         │
│  ├─ capped reconnect                                             │
│  └─ paseo.js normalization                                       │
└───────────────────────────┬──────────────────────────────────────┘
                            │ short local process calls
┌───────────────────────────▼──────────────────────────────────────┐
│ crewbeacon_store.py                                              │
│  ├─ schema migration                                             │
│  ├─ host/session last-known snapshots                            │
│  ├─ usage event dedup + local time rollups                       │
│  └─ attention dedup                                              │
└───────────────────────────┬──────────────────────────────────────┘
                            ▼
                    crewbeacon.sqlite3
```

No blocking network request or SQLite work runs on the QML UI thread. Quota,
relay, and persistence helpers run through Plasma's asynchronous executable
data source. Direct Paseo uses an event stream; encrypted relay sources poll a
read-only CLI snapshot every 20 seconds.

## Domain boundaries

### Quota

Provider helpers emit the established common envelope. `quota.js` converts it
to a provider-neutral snapshot with windows, used/remaining ratios, reset time,
plan, source, availability, and stale state. The preserved quota view consumes
those windows.

### Agents and workspaces

`paseo.js` is the only place that translates Paseo lifecycle, permission,
project, worktree, capability, and usage fields. Views receive normalized
sessions and contain no Claude/Codex/Pi state branches.

### Usage

One observed completed-turn event becomes one immutable row identified by
source + agent + epoch/sequence. Input, output, cache, reasoning, context, and
reported cost remain independent columns. Historical token totals are input +
output; cache is a breakdown, and context is never part of the sum. A rolling
371-day local-time calendar opens any recorded day into repository,
provider/model, session, and individual-event views.

### Visual system

The popup deliberately shares OctoPulse's bounded `30 × 32` grid-unit canvas,
`#0d1526` default background, semantic blue/green/amber/red palette, pill tabs,
subtle text-alpha cards, small internal spacing, and optional Plasma-theme
override. Agent rows use two lines and one status ring; repository and host
metadata is not repeated to create height.

### Attention

Only explicit question, permission, error, and finish events enter the
attention pipeline. Initial directory snapshots seed UI state but do not emit a
notification storm. A database uniqueness constraint suppresses reconnect and
restart duplicates.

## Reliability

- Each source preserves its last session array when disconnected and marks it stale.
- Persisted snapshots restore useful state before a reconnect finishes.
- Reconnect starts at 1.5 seconds, doubles, caps at 30 seconds, and adds bounded jitter.
- A malformed/unknown message increments source diagnostics and is ignored.
- A non-`0.2.x` server is shown as unsupported and is not retried indefinitely.
- Usage and attention inserts are idempotent.
- Repository rollups calculate local day, calendar week, and calendar month boundaries then query UTC timestamps.

## Security and privacy

- Direct public daemon exposure is never recommended.
- The implementation sends no agent prompts, approvals, stops, or mutations.
- Raw provider credentials remain in the stores owned by their official tools.
- Attention previews are truncated at the protocol adapter and not persisted by default.
- Logs and database rows contain no auth secret.
- Relay E2EE is delegated to the official Paseo CLI. Its offer trust anchor is read only from a current-user `0600` file and passed through `PASEO_HOST`.
- Direct password handling remains unsupported until it can use a keyring-backed boundary.

## Known tradeoffs

The on-demand Python helper is intentionally smaller than a resident service
and avoids another lifecycle to package. If event frequency, background
backfill, or database concurrency grows materially, it can become a user
service behind the same JSON command boundary without changing the QML domain.

Paseo's directory snapshot does not provide historical per-turn deltas. The
store preserves all observed history but cannot safely invent or reconstruct
events missed while CrewBeacon was offline. Provider-specific backfill requires
versioned fixtures and is a later adapter.
