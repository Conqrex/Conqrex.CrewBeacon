#!/usr/bin/env bash
# Backwards-compatible shim. The widget now uses usage.sh <provider>; this keeps
# the old Claude-only entrypoint working (e.g. `claude-usage.sh` or
# `claude-usage.sh /path/to/token`).
DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$DIR/usage.sh" claude "${1:-auto}"
