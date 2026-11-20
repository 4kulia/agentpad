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

    var attention = AttentionSidebarModel.shared
    /// Width the tab strip assigned (TabStripLayout); nil keeps the natural width.
    var width: CGFloat? = nil
    /// Narrower than its natural width: compact paddings; an inactive tab's
    /// close button overlays the title end on hover instead of taking space.
    var compressed = false
    private var indicator: AttentionIndicator? { attention.tabIndicators[tab.id] }
    private var title: String { attention.tabTitle(tab) }

    @State private var isHovered = false
    @State private var isContextMenuOpen = false

    private var gap: CGFloat { compressed ? TabStripMetrics.compactGap : TabStripMetrics.gap }
    private var overlaysClose: Bool { compressed && !isActive && !tab.nameEdit.isEditing }

    var body: some View {
        #if DEBUG
        let _ = TabStripRenderCount.rows += 1
        #endif
        HStack(spacing: gap) {
            HStack(spacing: gap) {
                AttentionIndicatorView(indicator: indicator)
                // AgentPad: saved chat lists have their own navigation symbols.
                AgentIconView(asset: tab.hasProcess ? tab.displayAgent.iconAsset : nil,
                              fallbackSymbol: tab.toolRoute?.symbol ?? tab.inbox?.kind.symbol ?? tab.displayAgent.symbol, size: 15)
                if tab.nameEdit.isEditing {
                    InlineNameField(edit: tab.nameEdit, label: "Tab title") { text in
                        onRename(text); return nil
                    }.frame(minWidth: 100)
                } else {
                    Text(title)
                    .font(Theme.display(12, weight: isActive ? .medium : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: width == nil ? nil : .infinity, alignment: .leading)
                    .mask { titleMask }
                }
            }
            .overlay { if !tab.nameEdit.isEditing { TabDragSource(session: tab, store: store, onActivate: onActivate) } }
            // AgentPad: show why an export is unavailable instead of hiding it.
            if AgentAnswerSource.supports(tab), isActive {
                HoverableIconButton(systemName: "arrowshape.turn.up.right", fontSize: 11, size: 18,
                                    help: AgentAnswerSource.problem(tab)?.rawValue ?? "Forward last agent answer…") { onLastAnswer(false) }
                    .disabled(!CompositionTabs.available(tab))
            }
            if !overlaysClose {
                closeButton
                    .opacity(isHovered || isActive ? 1 : 0)
                    .allowsHitTesting(isHovered || isActive)
            }
        }
        .foregroundStyle(isActive ? Theme.chromeForeground : Theme.chromeForeground.opacity(0.62))
        .padding(.horizontal, compressed ? TabStripMetrics.compactPadding : TabStripMetrics.padding)
        .padding(.vertical, 8)
        .frame(width: width, alignment: .leading)
        .overlay(alignment: .trailing) {
            // A compressed inactive tab has no room for its close button: it
            // appears over the title end on hover (mockup f2 c, f5).
            if overlaysClose {
                closeButton
                    .background {
                        // Mockup: surface mixed with 7 % foreground.
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(nsColor: Theme.terminalSurface))
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.chromeForeground.opacity(0.09)))
                    }
                    .padding(.trailing, 6)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
        }
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chromeSelectionCornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityLabel("\(title), tab")
        .accessibilityValue((isActive ? "Selected, " : "Not selected, ") + (indicator?.accessibleSummary ?? "No new marks"))
        .help(title + (indicator.map { "\n" + attention.tooltip($0) } ?? ""))
        .accessibilityIdentifier("workspace-tab-" + tab.id.uuidString)
        .task(id: isActive) {
            guard isActive else { return }
            // Polling also observes foreground changes the terminal core does
            // not publish through Observation. Hook/activation requests debounce.
            while !Task.isCancelled {
                try? await AgentAnswerSource.refresh(tab)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
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
        .attentionPopover(isPresented: $isContextMenuOpen, arrowEdge: .bottom) {
            // AgentPad: keep the export explanation inside a bounded tab menu.
            AgentPadTabMenu(tab: tab, canCloseToRight: canCloseToRight,
                dismiss: { isContextMenuOpen = false }, onClose: onClose,
                onCloseOthers: onCloseOthers, onCloseToRight: onCloseToRight,
                onDuplicate: onDuplicate, onRename: {
                    onActivate()
                    if tab.hasProcess { tab.nameEdit.begin(tab.explicitName ?? tab.title) }
                },
                onSplit: onSplit, onMoveToNewWindow: onMoveToNewWindow, onLastAnswer: onLastAnswer)
        }
    }

    private var closeButton: some View {
        HoverableIconButton(
            systemName: "xmark",
            fontSize: 9,
            size: 16,
            help: "Close tab",
            action: onClose
        )
    }

    /// Fades the title end under the overlaid close button (100 % − 20 pt →
    /// 100 % − 4 pt), only while that button shows.
    @ViewBuilder private var titleMask: some View {
        if overlaysClose && isHovered {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                Color.clear.frame(width: 4)
            }
        } else {
            Rectangle()
        }
    }

    private var rowBackground: Color {
        if isActive { return Theme.chromeSelection }
        if isHovered { return Theme.chromeHover }
        return .clear
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
