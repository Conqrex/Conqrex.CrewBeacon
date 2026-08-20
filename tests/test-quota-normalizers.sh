#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/package/contents/code/usage.sh"
FIXTURES="$ROOT/tests/fixtures"
CAPTURED_AT="2026-08-09T12:00:00Z"

detected="$(HOME=/nonexistent XDG_DATA_HOME="$FIXTURES" XDG_CACHE_HOME="$(mktemp -d)" \
  bash "$HELPER" detect)"
jq -e '.providers.opencode == {"detected":true,"reason":"ok"}' >/dev/null <<<"$detected"

claude="$(bash "$HELPER" _normalize-claude "$FIXTURES/claude-modern-usage.json" "$CAPTURED_AT")"
jq -e '
  [.gauges[].label] == ["Session", "Weekly", "Weekly · Fable"]
  and (.gauges[] | select(.label == "Weekly · Fable") | .pct == 69 and .cap == "7D")
' >/dev/null <<<"$claude"

codex="$(bash "$HELPER" _normalize-codex "$FIXTURES/codex-weekly-primary.json" "$CAPTURED_AT")"
jq -e '
  (.gauges | length) == 1
  and .gauges[0].label == "Weekly"
  and .gauges[0].cap == "7D"
  and .gauges[0].pct == 15
' >/dev/null <<<"$codex"

opencode="$(bash "$HELPER" _normalize-opencode "$FIXTURES/opencode-go-usage.json" "$CAPTURED_AT")"
jq -e '
  .provider == "opencode" and .plan == "Go"
  and [.gauges[].id] == ["session", "weekly", "monthly"]
  and [.gauges[].label] == ["5-hour", "Weekly", "Monthly"]
  and [.gauges[].cap] == ["5H", "7D", "1M"]
  and [.gauges[].pct] == [12, 58, 29]
  and .gauges[2].reset == "2026-09-17T13:07:26.731Z"
' >/dev/null <<<"$opencode"

printf '%s\n' "provider payload normalizers: PASS"
