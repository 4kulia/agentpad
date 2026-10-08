#!/bin/bash
# A separate AppKit process and temporary profile; no XCTest window host.
set -euo pipefail
cd "$(dirname "$0")/.."
if rg -n 'AgentPadSettingsWindowController|AboutWindowController|UpdatePromptWindowController|InboxWindowController|DeepLinkFailurePresenter' Sources; then
    echo 'No-modals UI/AX: FAIL: obsolete presenter is still reachable'
    exit 1
fi
if rg -n 'NSAlert\(|NSWindow\(|NSPanel\(|\.runModal\(|\.sheet\(|\.confirmationDialog\(' \
    Sources/AgentPadKit/App/{AgentPadSettingsUI,AboutWindow,UpdatePromptUI,AgentInbox,DeepLink}.swift \
    Sources/AgentPadKit/Tabs/SupportTabs.swift Sources/AgentPadKit/AgentPad/Chat/ChatDebugMenu.swift; then
    echo 'No-modals UI/AX: FAIL: migrated screen creates a forbidden surface'
    exit 1
fi
test_log=$(mktemp /tmp/agentpad-no-modals-ui.XXXXXX)
if ! swift build -j 1 >"$test_log" 2>&1; then
    rg 'error:|failed' "$test_log" || true
    exit 1
fi
test_binary="$(swift build --show-bin-path)/AgentPad"
if "$test_binary" --self-check-no-modals >>"$test_log" 2>&1; then
    rg 'No-modals UI/AX:|UI profile and screenshots:' "$test_log"
else
    tail -30 "$test_log"
    exit 1
fi
