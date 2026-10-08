import SwiftUI

/// Finder-style tag strip for the workspace context menu — a clear slot then
/// one swatch per colour. The active swatch also clears when clicked, so the
/// strip toggles whichever way the user reaches for.
private struct ColorTagStrip: View {
    let current: WorkspaceTag?
    let onPick: (WorkspaceTag?) -> Void

    /// One slot per thing the strip can light, so "which is selected" and
    /// "which is hovered" are the same vocabulary. The clear slot used to be a
    /// nil inside an optional, which made every read spell the nesting.
    private enum Slot: Equatable {
        case clear
        case preset(WorkspaceColorTag)
        case custom
    }

    @State private var hovered: Slot?

    /// Keyed on how the tag was made, not on its colour — a picked colour that
    /// happens to equal a preset is still the user's tag and must not collapse
    /// into that preset's swatch, and asking "which preset is active" would
    /// answer nil for a custom tag and light the clear slot alongside it.
    private var lit: Slot {
        guard let current else { return .clear }
        return current.color.preset.map(Slot.preset) ?? .custom
    }

    var body: some View {
        HStack(spacing: 7) {
            clearSwatch
            ForEach(WorkspaceColorTag.allCases, id: \.self) { swatch($0) }
            if let current, lit == .custom {
                circle(current.swatchColor, slot: .custom, help: current.hashLabel ?? "Custom color") {
                    onPick(nil)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.space2 + 2)
        .padding(.vertical, 7)
    }

    private var clearSwatch: some View {
        circle(nil, slot: .clear, help: "No color") { onPick(nil) }
    }

    private func swatch(_ preset: WorkspaceColorTag) -> some View {
        // Picking the colour a row already carries clears it — the same gesture
        // both sets and unsets, so there's no dead click. A preset drops any
        // name the tag had: the swatches are the unnamed tags.
        circle(preset.color, slot: .preset(preset), help: preset.title) {
            onPick(lit == .preset(preset) ? nil : WorkspaceTag(preset: preset))
        }
    }

    /// One swatch. A nil fill draws the clear slot: an outlined circle with a
    /// slash through it. `line.diagonal` is the slash alone — `nosign` carries
    /// its own circle and would nest a second ring inside this one.
    @ViewBuilder
    private func circle(
        _ fill: Color?,
        slot: Slot,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Group {
            if let fill {
                Circle().fill(fill)
            } else {
                Circle()
                    .strokeBorder(Theme.chromeMuted, lineWidth: 1.5)
                    .overlay(
                        Image(systemName: "line.diagonal")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.chromeMuted)
                            // Mirrored: the stock glyph leans the other way.
                            .scaleEffect(x: -1)
                    )
            }
        }
        .modifier(SwatchChrome(isSelected: lit == slot, isHovered: hovered == slot))
        .onHover { hovered = $0 ? slot : nil }
        .onTapGesture(perform: action)
        .help(help)
    }
}

/// Shared swatch sizing + selection ring, so the clear slot and the colour
/// swatches can't drift apart in size or alignment.
private struct SwatchChrome: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: 15, height: 15)
            .overlay {
                if isSelected {
                    Circle()
                        .stroke(Theme.chromeForeground, lineWidth: 1.5)
                        .padding(-3)
                }
            }
            .opacity(isHovered ? 0.7 : 1)
            .contentShape(Circle().inset(by: -3))
    }
}

struct SidebarWorkspaceRow: View {
    /// Disclosure state for a source workspace that owns worktree children.
    /// `toggle` is wired by the sidebar's parent — the row only renders the
    /// chevron and forwards the click.
    struct WorktreeDisclosure {
        let isCollapsed: Bool
        let toggle: () -> Void
    }

    let workspace: Workspace
    let isActive: Bool
    let isCompact: Bool
    let canCloseOthers: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onDuplicate: () -> Void
    let onRename: (String) -> Void
    let onSetTag: (WorkspaceTag?) -> Void
    let onDetails: () -> Void
    var disclosure: WorktreeDisclosure? = nil
    /// Non-nil for source (top-level, non-worktree) workspaces — the
    /// right-click menu surfaces a "Create Worktree…" entry that the
    /// sidebar routes to a tab. Nil on worktree rows so worktree
    /// nesting stays disabled.
    var onCreateWorktree: (() -> Void)? = nil
    /// Non-nil for worktree rows — jumps the active selection back to the
    /// source workspace this worktree was forked from. Cheap navigation
    /// shortcut when the user is deep in a worktree and wants the main
    /// repo's tab back.
    var onGoToSource: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isContextMenuOpen = false

    var body: some View {
        let readout = workspace.sidebarReadout
        let dotColor = Self.activityDotColor(state: readout.state, hasFailure: readout.hasCommandFailure)
        Group {
            if isCompact {
                compactBody(agents: readout.agents, dotColor: dotColor)
            } else {
                fullBody(agents: readout.agents, dotColor: dotColor)
            }
        }
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chromeSelectionCornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovered = $0 }
        .overlay(RightClickCatcher { _ in isContextMenuOpen = true })
        .popover(isPresented: $isContextMenuOpen, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                AgentPadMenuRow(
                    title: workspace.worktreeParentId == nil ? "Close Workspace" : "Close Worktree…",
                    shortcut: workspace.worktreeParentId == nil ? "⌘⇧W" : nil
                ) {
                    isContextMenuOpen = false
                    onClose()
                }
                AgentPadMenuRow(title: "Close Other Workspaces", isDisabled: !canCloseOthers) {
                    isContextMenuOpen = false
                    onCloseOthers()
                }
                AgentPadMenuDivider()
                AgentPadMenuRow(title: "Rename Workspace…", shortcut: "⌘⇧R") {
                    isContextMenuOpen = false
                    if isCompact { onActivate(); workspace.nameEdit.begin(workspace.customTitle ?? workspace.title) }
                    else { workspace.nameEdit.begin(workspace.customTitle ?? workspace.title) }
                }
                AgentPadMenuRow(title: "Duplicate Workspace") {
                    isContextMenuOpen = false
                    onDuplicate()
                }
                if let onCreateWorktree {
                    AgentPadMenuRow(title: "Create Worktree…") {
                        isContextMenuOpen = false
                        // Let the menu finish closing before focusing the tab.
                        DispatchQueue.main.async { onCreateWorktree() }
                    }
                }
                if let onGoToSource {
                    AgentPadMenuRow(title: "Go to Source Workspace") {
                        isContextMenuOpen = false
                        onGoToSource()
                    }
                }
                AgentPadMenuDivider()
                ColorTagStrip(current: workspace.tag) { tag in
                    isContextMenuOpen = false
                    onSetTag(tag)
                }
                AgentPadMenuRow(title: workspace.tag == nil ? "Custom Tag…" : "Edit Tag…") {
                    isContextMenuOpen = false
                    onDetails()
                }
                AgentPadMenuRow(title: "Workspace details…") {
                    isContextMenuOpen = false
                    onDetails()
                }
                AgentPadMenuDivider()
                RevealInFinderMenuRow(url: workspace.workingDirectory) { isContextMenuOpen = false }
            }
            .padding(Theme.space1)
            .frame(minWidth: 240)
            .background(Theme.chromeBackground)
        }
        .help(workspace.sidebarTooltip(agents: readout.agents))
    }

    private func fullBody(agents: [AgentTemplate], dotColor: Color?) -> some View {
        HStack(spacing: Theme.space2) {
            agentIcons(agents: agents)
                .padding(.trailing, 3)
            VStack(alignment: .leading, spacing: 2) {
                if workspace.nameEdit.isEditing {
                    InlineNameField(edit: workspace.nameEdit, label: "Workspace title") { text in
                        onRename(text); return nil
                    }
                } else {
                    Text(workspace.title)
                    .font(Theme.display(13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Theme.chromeForeground : Theme.chromeForeground.opacity(0.78))
                    .lineLimit(1)
                }
                subtitleRow
            }
            Spacer(minLength: 0)
            // Activity dot lives at the trailing edge — visible at all times
            // when not idle, eats the close-button slot only on hover.
            HStack(spacing: Theme.chromeControlSpacing) {
                if let disclosure {
                    HoverableIconButton(
                        systemName: "chevron.right",
                        fontSize: 10,
                        size: Theme.chromeContextButtonSize,
                        help: disclosure.isCollapsed ? "Show worktrees" : "Hide worktrees",
                        action: disclosure.toggle,
                        rotation: disclosure.isCollapsed ? 0 : 90
                    )
                    // Hierarchy is a primary interaction, so keep the
                    // disclosure affordance discoverable even off-hover.
                    .opacity(isHovered ? 1 : 0.48)
                }
                if let onCreateWorktree {
                    HoverableIconButton(
                        systemName: "arrow.triangle.branch",
                        fontSize: 10,
                        size: Theme.chromeContextButtonSize,
                        help: "Create worktree",
                        action: onCreateWorktree
                    )
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                }
                ZStack {
                    if let dotColor {
                        Circle().fill(dotColor).frame(width: 6, height: 6)
                            .opacity(isHovered ? 0 : 1)
                    }
                    HoverableIconButton(
                        systemName: "xmark",
                        fontSize: 10,
                        size: Theme.chromeContextButtonSize,
                        help: workspace.worktreeParentId == nil ? "Close workspace" : "Close worktree",
                        action: onClose
                    )
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                }
                .frame(width: 20, alignment: .trailing)
            }
            .frame(minWidth: trailingHoverMinWidth, alignment: .trailing)
        }
        // The list's 8pt row inset plus this 8pt content inset creates the
        // shared 16pt sidebar gutter without letting the hover fill touch the
        // window edge.
        .padding(.leading, Theme.sidebarContentLeadingX - Theme.space2)
        .padding(.trailing, Theme.space3)
        .padding(.vertical, Theme.sidebarRowVerticalPadding)
    }

    private func compactBody(agents: [AgentTemplate], dotColor: Color?) -> some View {
        // Icon-only row — activity dot floats over the icon as a small badge
        // since there's no trailing slot in the narrowed column.
        ZStack(alignment: .topTrailing) {
            agentIcons(agents: agents)
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .offset(x: 3, y: -3)
            }
        }
        // A 52pt compact rail centres this 20pt mark on the same x = 26pt
        // axis without a special offset.
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
    }

    /// Subtitle below the workspace title. Source workspaces show their
    /// cwd path (tilde-abbreviated); worktree rows show the branch glyph
    /// + branch name — more informative than the path (which is usually
    /// `<repo>-<branch>` and just repeats the title) and the inline glyph
    /// makes the worktree-vs-source distinction obvious without any
    /// extra chrome. Cwd path still reaches the user via the row-level
    /// `.help(...)` tooltip.
    @ViewBuilder
    private var subtitleRow: some View {
        if let branch = workspace.worktreeBranch, !branch.isEmpty {
            // Worktree row's brand mark — a solid-filled rounded square
            // with the branch glyph reverse-cut in `chromeBackground`.
            // The solid-fill-over-tint approach reads cleanly against
            // both light and dark themes (no opacity haze on the glyph)
            // and gives the worktree row the same visual weight a tab
            // pill carries — distinct from source rows without needing
            // an extra column or stripe.
            subtitleBadge(glyph: "arrow.triangle.branch", glyphSize: 6, text: branch)
        } else if let host = workspace.sshRemoteHost {
            // SSH workspace — same badge language, network glyph. The host
            // replaces the local path: these tabs live on the remote.
            subtitleBadge(glyph: "network", glyphSize: 7, text: host)
        } else {
            Text((workspace.workingDirectory.path as NSString).abbreviatingWithTildeInPath)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.chromeMuted)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    /// Shared subtitle badge: solid rounded tile with a reverse-cut glyph +
    /// mono label — the worktree-branch and ssh-host rows differ only in
    /// glyph and text.
    private func subtitleBadge(glyph: String, glyphSize: CGFloat, text: String) -> some View {
        let badgeColor = Theme.chromeForeground.opacity(0.82)
        return HStack(spacing: 6) {
            Image(systemName: glyph)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(Theme.chromeBackground)
                .frame(width: 12, height: 12)
                .background(badgeColor, in: RoundedRectangle(cornerRadius: 3))
            Text(text)
                .font(Theme.mono(10.5, weight: .medium))
                .foregroundStyle(badgeColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Trailing hover icon strip min width — accommodates each optional
    /// hover button (chevron, create-worktree) plus the always-present
    /// close × slot so the trailing edge doesn't shift when a hover
    /// icon appears.
    private var trailingHoverMinWidth: CGFloat {
        var width: CGFloat = 20
        if disclosure != nil { width += 22 }
        if onCreateWorktree != nil { width += 22 }
        return width
    }

    @ViewBuilder
    private func agentIcons(agents: [AgentTemplate]) -> some View {
        // Single leading mark: first non-terminal agent's brand icon, or the
        // Terminal SF Symbol when the workspace only runs plain shells.
        // Multi-agent workspaces get a `+N` badge showing the additional
        // distinct agents — first agent stays the dominant mark.
        if let agent = agents.first {
            ZStack(alignment: .bottomTrailing) {
                AgentIconView(asset: agent.iconAsset, fallbackSymbol: agent.symbol, size: 20)
                if agents.count > 1 {
                    Text("+\(agents.count - 1)")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.chromeBackground)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(Theme.chromeForeground.opacity(0.92)))
                        .offset(x: 6, y: 4)
                }
            }
            .opacity(isActive ? 1 : 0.85)
        } else {
            Image(systemName: AgentTemplate.terminal.symbol)
                .font(.system(size: 16))
                .foregroundStyle(Theme.chromeMuted)
                .frame(width: 20, height: 20)
        }
    }

    /// Precedence: attention (agent literally waits on you) > failure
    /// (last shell command non-zero, look when free) > running (agent in
    /// flight, FYI) > idle (quiet).
    private static func activityDotColor(state: SessionActivityState, hasFailure: Bool) -> Color? {
        if state == .attention { return Theme.activityAttention }
        if hasFailure { return Theme.activityFailure }
        if state == .running { return Theme.activityRunning }
        return nil
    }

    /// Row fill plus the user's colour tag, drawn in both sidebar modes so
    /// collapsing the sidebar never drops a marker the user placed.
    private var rowBackground: some View {
        rowFill.workspaceTagStripe(workspace.tag)
    }

    private var rowFill: Color {
        if isActive { return Theme.chromeSelection }
        if isHovered { return Theme.chromeHover }
        return .clear
    }
}
