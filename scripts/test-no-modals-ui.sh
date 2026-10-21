#!/bin/bash
# A separate AppKit process and isolated in-memory credentials; no app services.
set -euo pipefail
cd "$(dirname "$0")/.."
if rg -n 'AgentPadSettingsWindowController|AboutWindowController|UpdatePromptWindowController|InboxWindowController|DeepLinkFailurePresenter' Sources; then
    echo 'No-modals UI/AX: FAIL: obsolete presenter is still reachable'
    exit 1
fi
popup_sources=(
    Sources/AgentPadKit/App/{AgentPadSettings,AgentPadSettingsUI,AboutWindow,UpdatePromptUI,AgentInbox,DeepLink}.swift
    Sources/AgentPadKit/Tabs/{SupportTabs,PopupHost,ClaudeAccountViews,CompositionViews,ConnectionTabs,LocalFormViews,NewAgentFormView,PublicationView,RequestTabView,OrganizationTabs,ProcessTabs,FileOperationTab,ImportSessionTab}.swift
    Sources/AgentPadKit/Sidebar/{FoldersSheet,AddToFolderChooser,SidebarFolderActions}.swift
    Sources/AgentPadKit/Telegram/{TelegramConversationView,TelegramSponsoredCard,TelegramSettingsView}.swift
    Sources/AgentPadKit/AgentPad/Chat/ChatDebugMenu.swift
)
if rg -n 'NSAlert\(|NSWindow\(|NSPanel\(|\.runModal\(|\.sheet\(|\.alert\(|\.confirmationDialog\(' "${popup_sources[@]}"; then
    echo 'No-modals UI/AX: FAIL: migrated screen creates a forbidden surface'
    exit 1
fi
# These three exact panel calls are the Inventory's unchanged macOS file pickers.
if rg -n '\.beginSheet' "${popup_sources[@]}" \
    | rg -v '^Sources/AgentPadKit/Tabs/(NewAgentFormView|SupportTabs|CompositionViews)\.swift:[0-9]+: +panel\.beginSheetModal\(for: window\)'; then
    echo 'No-modals UI/AX: FAIL: migrated screen creates an unclassified sheet'
    exit 1
fi
if rg -n 'NSAlert\(|NSPanel\(|\.runModal\(|\.beginSheet|\.sheet\(|\.alert\(|\.confirmationDialog\(' \
    Sources/AgentPadKit/Telegram/TelegramSponsoredVideoWindow.swift; then
    echo 'No-modals UI/AX: FAIL: video confirmation creates a forbidden surface'
    exit 1
fi
# Startup owns the approved main NSWindow container and hosts its choice in PopupHost.
if rg -n 'NSAlert\(|NSPanel\(|\.runModal\(|\.beginSheet|\.sheet\(|\.alert\(|\.confirmationDialog\(' \
    Sources/AgentPadKit/App/AgentPadWindowController.swift; then
    echo 'No-modals UI/AX: FAIL: startup choice creates a forbidden surface'
    exit 1
fi
batch="${AGENTPAD_POPUP_PHASE3_BATCH:-}"
if [[ -n "$batch" ]]; then
    case "$batch" in
        settings|local|connection|composition|publication|organization|operations|folders|telegram|video|fallback) ;;
        *) echo 'No-modals UI/AX: FAIL: unknown phase-three batch'; exit 1 ;;
    esac
fi
mkdir -p .build/tmp .build/test-home .build/ModuleCache
export TMPDIR="$PWD/.build/tmp"
export CFFIXED_USER_HOME="${CFFIXED_USER_HOME:-$PWD/.build/test-home}"
export AGENTPAD_DEBUG_STATE_PATH="${AGENTPAD_DEBUG_STATE_PATH:-$PWD/.build/test-home/state-v2.json}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/ModuleCache}"
test_log=$(mktemp "$PWD/.build/pop-no-modals-${batch:-all}.XXXXXX")
echo "No-modals UI log: $test_log"
export AGENTPAD_POPUP_SHOTS="${AGENTPAD_POPUP_SHOTS:-$PWD/.build/pop1-shots}"
if [[ "${AGENTPAD_NO_MODALS_SKIP_BUILD:-0}" != 1 ]] && ! swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -j 1 >"$test_log" 2>&1; then
    rg 'error:|failed' "$test_log" || true
    exit 1
fi
test_binary="$(swift build --show-bin-path)/AgentPad"
# Each quiet process owns its home/state and firstResponder model. Native events
# stay in its offscreen windows, so the independent batches can run concurrently.
python3 scripts/run-no-modals-ui.py "$test_binary"
