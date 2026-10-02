#!/usr/bin/env bash
# AgentPad performance benchmarks — run after any change that might affect a
# measured path, compare against the last lines of bench-history.jsonl.
# Synthetic numbers are fixed-load and comparable run-over-run on one
# machine; the "real" number is context only (it grows with real usage).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Running benchmarks (AGENTPAD_BENCH=1)…"
# Release build: debug (-Onone) inflates exactly the Swift-side loops the
# scanner optimizations target, distorting before/after ratios.
set +e
raw=$(AGENTPAD_BENCH=1 swift test -c release --filter PerformanceBenchmarks 2>&1)
status=$?
set -e
out=$(grep "^BENCH" <<< "$raw" || true)
# A run can print BENCH lines and STILL fail (e.g. the catastrophic-guard
# assertion after the numbers) — never record a failed run as a result.
if [ $status -ne 0 ]; then
  echo "swift test failed (exit $status) — not recording results. Tail:"
  tail -20 <<< "$raw"
  exit $status
fi
if [ -z "$out" ]; then
  echo "No BENCH output — re-run verbosely:"
  echo "  AGENTPAD_BENCH=1 swift test -c release --filter PerformanceBenchmarks"
  exit 1
fi

echo "$out"

ts=$(date +%Y-%m-%dT%H:%M:%S)
commit=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
while IFS= read -r line; do
  printf '{"ts":"%s","commit":"%s","config":"release","bench":"%s"}\n' "$ts" "$commit" "$line" >> bench-history.jsonl
done <<< "$out"

echo
echo "History (bench-history.jsonl, last 6 entries):"
tail -6 bench-history.jsonl
