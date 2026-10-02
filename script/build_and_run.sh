#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AgentPad"
BUNDLE_ID="com.4kulia.agentpad"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${ROOT_DIR}/dist/${APP_NAME}.app"
APP_BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

stop_existing_app() {
    pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
    for _ in {1..30}; do
        pgrep -x "${APP_NAME}" >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    pkill -KILL -x "${APP_NAME}" >/dev/null 2>&1 || true
}

launch_app() {
    # Strip agent-session proxy vars (both cases): a Codex/Claude shell's
    # temporary localhost proxy would otherwise be inherited by AgentPad and
    # every shell it spawns — a fake proxy pill, and dead network requests
    # once the agent session ends. Same lesson as CLAUDE.md's dev-launch note.
    env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        -u http_proxy -u https_proxy -u all_proxy \
        /usr/bin/open -n "${APP_BUNDLE}"
}

verify_app() {
    for _ in {1..50}; do
        if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
            return
        fi
        sleep 0.1
    done
    echo "${APP_NAME} did not start within 5 seconds" >&2
    exit 1
}

stop_existing_app

# Fresh checkouts lack the gitignored Vendor/ framework and Package.swift's
# binary target can't resolve without it; the setup script is idempotent,
# so a self-heal on miss makes Run work out of the box on a new machine.
if [ ! -d "${ROOT_DIR}/Vendor/GhosttyKit.xcframework" ]; then
    "${ROOT_DIR}/scripts/setup-libghostty.sh"
fi

"${ROOT_DIR}/scripts/build-app.sh"

case "${MODE}" in
    run)
        launch_app
        ;;
    --debug|debug)
        # Same proxy-var strip as launch_app: lldb (and the AgentPad it spawns)
        # must not inherit an agent session's temporary localhost proxy.
        env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
            -u http_proxy -u https_proxy -u all_proxy \
            lldb -- "${APP_BINARY}"
        ;;
    --logs|logs)
        launch_app
        /usr/bin/log stream --info --style compact \
            --predicate "process == \"${APP_NAME}\""
        ;;
    --telemetry|telemetry)
        launch_app
        /usr/bin/log stream --info --style compact \
            --predicate "subsystem == \"${BUNDLE_ID}\""
        ;;
    --verify|verify)
        launch_app
        verify_app
        echo "${APP_NAME} is running from ${APP_BUNDLE}"
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
