#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/package/contents/code/usage.sh"
FIXTURES="$ROOT/tests/fixtures"
CAPTURED_AT="2026-08-09T12:00:00Z"

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

printf '%s\n' "provider payload normalizers: PASS"
