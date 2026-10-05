#!/bin/bash
# Y3-lite: the boundary of the profiles without a shell ("Read", "Edit files
# (no shell)"). Usage: run-nobash.sh REPO. Everything the runs touch lives in
# a fresh temporary tree; each run's results go to a new folder
# results-nobash-<claude version>-<time>/ that is never overwritten.
# Exit 0 only when every mandatory cell holds.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="${1:?usage: run-nobash.sh REPO}"
scratch="${Y1_SCRATCH:-${TMPDIR:-/tmp}}"
claude="$HOME/.local/bin/claude"   # what ClaudeCodeRunner.locateClaude picks first
version="$("$claude" --version | awk '{print $1}')"
root="$(mktemp -d "$scratch/y3l.XXXXXX")"
results="$here/results-nobash-$version-$(date +%Y%m%d-%H%M%S)"
mkdir "$results"
source_session="$(uuidgen | tr 'A-Z' 'a-z')"

# The dump holds the launch environment (the user's identity and locale);
# it stays in the temporary tree, 0600, and is removed after the run.
( cd "$repo" && Y1_PROBE_DUMP="$root/dump.json" Y1_PROBE_FOLDER="$root/proj" Y1_PROBE_EXTRA="$root/extra
$root/Archive (2026)
$root/[work]" \
  Y1_PROBE_CLAUDE="$claude" Y1_PROBE_SOURCE_SESSION="$source_session" \
  swift test --filter TeamExecutorProbeArgsTests 2>&1 | grep -E "error:|Executed 1 test" | tail -1 )
test -s "$root/dump.json"
python3 "$here/selftest_nobash.py" > "$results/selftest.txt"

set +e
python3 "$here/probe_nobash.py" "$root" "$root/dump.json" "$claude" "$results" "$source_session"
code=$?
set -e
rm -f "$root/dump.json"
git -C "$repo" rev-parse HEAD > "$results/client-commit.txt"
echo "root: $root"
echo "results: $results"
cat "$results/status.txt"
exit $code
