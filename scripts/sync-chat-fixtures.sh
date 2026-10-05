#!/usr/bin/env bash
# AgentPad: copies the server's API samples (agentpad-server docs/api/fixtures)
# into the client's tests, which decode every one of them with the client's
# types (docs/agentpad/CHAT-PLAN.md C2). Run after the server's API changes.
#   AGENTPAD_SERVER_DIR  the server checkout (default: ../agentpad-server)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${AGENTPAD_SERVER_DIR:-$ROOT/../agentpad-server}"
SRC="$SERVER/docs/api/fixtures"
DST="$ROOT/Tests/AgentPadKitTests/Fixtures/chat"
[ -d "$SRC" ] || { echo "sync-chat-fixtures.sh: no $SRC" >&2; exit 1; }
mkdir -p "$DST"
rm -f "$DST"/*.json
cp "$SRC"/*.json "$DST"/
( cd "$SERVER" && git rev-parse HEAD 2>/dev/null || echo unknown ) > "$DST/SOURCE"
echo "copied $(ls "$DST"/*.json | wc -l | tr -d ' ') samples from $SRC"
