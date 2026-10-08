import SwiftUI

struct TabBarItem: View {
    @Bindable var tab: Session
    let store: WorkspaceStore
    let isActive: Bool
    let canCloseToRight: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseToRight: () -> Void
    let onDuplicate: () -> Void
    let onRename: (String) -> Void
    let onSplit: (SplitOrientation) -> Void
    let onMoveToNewWindow: () -> Void
    var onLastAnswer: (Bool) -> Void = { _ in }

    @State private var isHovered = false
    @State private var isContextMenuOpen = false

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                commandStatusDot
                // AgentPad: saved chat lists have their own navigation symbols.
                AgentIconView(asset: tab.hasProcess ? tab.displayAgent.iconAsset : nil,
                              fallbackSymbol: tab.toolRoute?.symbol ?? tab.inbox?.kind.symbol ?? tab.displayAgent.symbol, size: 15)
                if tab.nameEdit.isEditing {
                    InlineNameField(edit: tab.nameEdit, label: "Tab title") { text in
                        onRename(text); return nil
                    }.frame(minWidth: 100)
                } else {
                    Text(tab.title)
                    .font(Theme.display(12, weight: isActive ? .medium : .regular))
                    .lineLimit(1)
                }
            }
            .overlay { if !tab.nameEdit.isEditing { TabDragSource(session: tab, store: store, onActivate: onActivate) } }
            // AgentPad: show why an export is unavailable instead of hiding it.
            if AgentAnswerSource.supports(tab), isActive {
                HoverableIconButton(systemName: "arrowshape.turn.up.right", fontSize: 11, size: 18,
                                    help: AgentAnswerSource.problem(tab)?.rawValue ?? "Forward last agent answer…") { onLastAnswer(false) }
                    .disabled(!CompositionTabs.available(tab))
            }
            HoverableIconButton(
                systemName: "xmark",
                fontSize: 9,
                size: 16,
                help: "Close tab",
                action: onClose
            )
            .opacity(isHovered || isActive ? 1 : 0)
            .allowsHitTesting(isHovered || isActive)
        }
        .foregroundStyle(isActive ? Theme.chromeForeground : Theme.chromeForeground.opacity(0.62))
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chromeSelectionCornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("workspace-tab-" + tab.id.uuidString)
        .onTapGesture(perform: onActivate)
        .onHover { isHovered = $0 }
        // Selection is a discrete navigation state, not a layout transition.
        // Animating it delays the visual handoff while the terminal surface is
        // already being switched underneath.
        .transaction { transaction in
            if isActive { transaction.animation = nil }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .overlay(RightClickCatcher { _ in isContextMenuOpen = true })
        .overlay(MiddleClickCatcher { onClose() })
        .popover(isPresented: $isContextMenuOpen, arrowEdge: .bottom) {
            // AgentPad: keep the export explanation inside a bounded tab menu.
            AgentPadTabMenu(tab: tab, canCloseToRight: canCloseToRight,
                dismiss: { isContextMenuOpen = false }, onClose: onClose,
                onCloseOthers: onCloseOthers, onCloseToRight: onCloseToRight,
                onDuplicate: onDuplicate, onRename: {
                    onActivate()
                    if tab.hasProcess { tab.nameEdit.begin(tab.customTitle ?? tab.title) }
                },
                onSplit: onSplit, onMoveToNewWindow: onMoveToNewWindow, onLastAnswer: onLastAnswer)
        }
    }

    private var rowBackground: Color {
        if isActive { return Theme.chromeSelection }
        if isHovered { return Theme.chromeHover }
        return .clear
    }

    /// Shows only on non-zero exit. Successful runs intentionally leave the
    /// row clean — a green dot on every command would dominate the chrome.
    @ViewBuilder
    private var commandStatusDot: some View {
        if let exit = tab.lastCommandExit, exit != 0 {
            Circle()
                .fill(Theme.activityFailure)
                .frame(width: 5, height: 5)
                .help(Self.statusTooltip(exit: exit, duration: tab.lastCommandDuration))
        }
    }

    private static func statusTooltip(exit: Int, duration: TimeInterval?) -> String {
        guard let duration else {
            return String.localizedStringWithFormat(
                String(localized: "exit %d", bundle: .agentPadResources),
                exit
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "exit %d · %@", bundle: .agentPadResources),
            exit,
            formatDuration(duration)
        )
    }

    /// Internal: the Session Info inspector renders the same OSC 133;D
    /// duration — one formatter, or the tab tooltip and the inspector drift
    /// on the next tier tweak. (`ToolCallActivityPill.formatElapsed` stays a
    /// deliberately distinct style — see M5.bbbb.)
    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds / 60)
        let rem = Int(seconds.truncatingRemainder(dividingBy: 60).rounded())
        return "\(minutes)m \(rem)s"
    }
}
