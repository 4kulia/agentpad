import SwiftUI
import AgentPadHookKit



/// Places a full wordmark so the measured centre of its first glyph lands on
/// a caller-provided horizontal axis. The second subview is an invisible copy
/// of that glyph using the exact same SwiftUI font; keeping the visible word
/// intact preserves its native kerning and accessibility value.
private struct FirstGlyphCenteredLayout: Layout {
    let axisX: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let word = subviews[0].sizeThatFits(.unspecified)
        let glyph = subviews[1].sizeThatFits(.unspecified)
        return CGSize(
            width: axisX - glyph.width / 2 + word.width,
            height: max(word.height, glyph.height)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        let word = subviews[0].sizeThatFits(.unspecified)
        let glyph = subviews[1].sizeThatFits(.unspecified)
        let origin = CGPoint(
            x: bounds.minX + axisX - glyph.width / 2,
            y: bounds.midY - word.height / 2
        )
        subviews[0].place(at: origin, anchor: .topLeading, proposal: .unspecified)
        subviews[1].place(at: origin, anchor: .topLeading, proposal: .unspecified)
    }
}

struct SidebarView: View {
    static let fullWidth: CGFloat = 220
    static let compactWidth: CGFloat = 52
    /// Ceiling for the user-draggable full-mode width (`fullWidth` is the
    /// floor — the sidebar only grows from its design width).
    static let maxWidth: CGFloat = 480

    /// Single source for the width policy — floor `fullWidth`, ceiling
    /// `maxWidth`, and whole points (fractional widths land row text on
    /// per-frame-shifting sub-pixel boundaries → the mono diff badges
    /// visibly shimmer during a drag). Shared by the drag gesture and the
    /// state.json restore path so the two can't diverge.
    static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, fullWidth), maxWidth).rounded()
    }

    // Trailing-edge resize drag (full mode only). Mirrors the split
    // divider's suspend pattern: begin once per drag (gated), capture the
    // engines so onEnded / the handle's onDisappear end the SAME set.
    @State private var resizeDragStartWidth: CGFloat?
    @State private var sidebarResizeSuspended = false
    @State private var sidebarSuspendedEngines: [any TerminalEngine] = []
    @Bindable var store: WorkspaceStore
    /// Passed as a parameter (not read live off the store) so the exiting
    /// view keeps its LAST VISIBLE mode during the hide transition: a
    /// compact→hidden switch otherwise re-evaluates `isCompact` against the
    /// already-`.hidden` store value → false → the sidebar snaps to full
    /// width while fading out (the "flash of full mode"). Mirrors
    /// `AgentOverviewSidebar(mode:)`, which never had this flash.
    let mode: SidebarMode
    /// Id of the workspace currently being dragged. Set by `.onDrag`, cleared
    /// on drop. Lets each row compute whether the drag origin is above or
    /// below it so the drop indicator can flip edges.
    @State private var draggingWorkspaceId: UUID?
    /// True while a Finder folder drag is hovering the sidebar — gates the
    /// drop-zone outline so the user sees that releasing here opens a new
    /// workspace.
    @State private var isFolderDropTargeted = false
    /// Source workspace ids whose worktree subtree the user collapsed.
    /// Default behaviour is expanded — only ids the user explicitly closed
    /// land here. Ephemeral by design: a AgentPad relaunch always shows every
    /// worktree on first paint so nothing is hidden by stale state.
    @State private var collapsedParents: Set<UUID> = []


    /// Invisible trailing-edge strip that widens the sidebar by drag —
    /// full mode only (compact is fixed, hidden is hidden). A width drag
    /// re-frames every libghostty NSView per frame → SIGWINCH storm (conda
    /// scrollback-wipe, issue #29) without the divider-style suspension.
    private var resizeHandle: some View {
        DividerHandle(orientation: .horizontal)
            .frame(width: 7)
            .gesture(resizeGesture)
            .onDisappear {
                // Backstop: ⌘⌃S mid-drag unmounts the handle before onEnded
                // can fire — end the captured engines so the suspension
                // refcount stays balanced (mirrors the split divider).
                resizeDragStartWidth = nil
                if sidebarResizeSuspended {
                    sidebarResizeSuspended = false
                    for engine in sidebarSuspendedEngines { engine.endSizePropagationSuspension() }
                    sidebarSuspendedEngines = []
                }
                store.endSidebarResize()
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if resizeDragStartWidth == nil {
                    resizeDragStartWidth = store.sidebarDisplayWidth
                    store.beginSidebarResize()
                }
                let proposed = (resizeDragStartWidth ?? store.sidebarDisplayWidth) + value.translation.width
                let clamped = store.sidebarContent == .chat
                    ? CGFloat(ChatSidebarPreferences.clampWidth(Double(proposed))) : Self.clampWidth(proposed)
                guard abs(clamped - store.sidebarDisplayWidth) > .ulpOfOne else { return }
                if !sidebarResizeSuspended {
                    sidebarResizeSuspended = true
                    sidebarSuspendedEngines = store.active?.root.allEngines ?? []
                    for engine in sidebarSuspendedEngines { engine.beginSizePropagationSuspension() }
                }
                store.setSidebarDisplayWidth(clamped)
            }
            .onEnded { _ in
                resizeDragStartWidth = nil
                // End + flush once — only when the engine's refcount hits 0
                // (a concurrent zoom / status-bar suspension flushes on ITS
                // own release).
                if sidebarResizeSuspended {
                    sidebarResizeSuspended = false
                    for engine in sidebarSuspendedEngines {
                        engine.endSizePropagationSuspension()
                        if !engine.suspendsSizePropagation { engine.flushSize() }
                    }
                    sidebarSuspendedEngines = []
                }
                store.endSidebarResize()
                store.flushPersistence()
            }
    }

    /// Whether the file tree is the mounted middle surface (files mode, full
    /// width — compact can't fit a tree and falls back to the icon list).
    /// Single source for the body's content switch and the folder-drop
    /// rejection below: the drop zone must reject exactly while the tree —
    /// whose rows vend `public.file-url` drags — is what's on screen.
    private var fileTreeIsMounted: Bool {
        store.sidebarContent == .files && mode != .compact
    }

    var body: some View {
        let isCompact = mode == .compact
        VStack(spacing: 0) {
            brand(isCompact: isCompact)
            sidebarContent(isCompact: isCompact)
            Spacer(minLength: 0)
            ChatSidebarModePicker(store: store, compact: isCompact, model: ChatOrgCurrent.shared.model)
        }
        .frame(width: isCompact ? Self.compactWidth : store.sidebarDisplayWidth)
        .glassChromeBackground()
        .overlay(alignment: .trailing) {
            if !isCompact { resizeHandle }
        }
        .overlay {
            // Drop affordance: tinted fill + hairline stroke, inset from the
            // sidebar edges so the splitter / titlebar don't clip it. Always
            // in the view tree (alpha-driven) so `easeOut(0.12)` can animate.
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.chromeActive)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.chromeForeground.opacity(0.55), lineWidth: 1)
            }
            .padding(Theme.space2)
            .opacity(isFolderDropTargeted ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isFolderDropTargeted)
            .allowsHitTesting(false)
        }
        // Files are silently ignored — `GhosttySurfaceView` already handles
        // "drop a file path at the cursor" inside a pane (M5.kk). The outline
        // lights up for any URL drag (SwiftUI's `.dropDestination` can't
        // pre-filter file-vs-folder); file drags release as no-ops.
        .dropDestination(for: URL.self) { urls, _ in
            // The file tree's rows vend public.file-url drags (a folder row
            // looks exactly like a Finder drag) and the tree renders inside
            // this very drop zone — reject drops while it's mounted so a
            // tree drag released over the sidebar bounces back instead of
            // minting a workspace. Everywhere the workspace LIST shows —
            // workspaces mode, compact (the tree never mounts there), any
            // window — Finder folders still land.
            guard !fileTreeIsMounted else { return false }
            let folders = urls.filter(isDirectory)
            guard !folders.isEmpty else { return false }
            for folder in folders {
                store.addWorkspace(workingDirectory: folder)
            }
            return true
        } isTargeted: { isFolderDropTargeted = $0 && !fileTreeIsMounted }
    }

    @ViewBuilder
    private func sidebarContent(isCompact: Bool) -> some View {
        // Compact can't fit a tree in 52pt, so it always shows the icon
        // list; the file tree (and its footer toggle) are full-mode only.
        if fileTreeIsMounted {
            FileTreeView(store: store, model: store.fileTree)
        } else if store.sidebarContent == .team && !isCompact {
            // AgentPad: team calls (Team/TeamCallsSidebar.swift).
            TeamCallsSidebar()
        } else if store.sidebarContent == .chat && !isCompact {
            ChatSidebarView(store: store, navigation: store.chatNavigation, model: ChatOrgCurrent.shared.model)
        } else {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    list(isCompact: isCompact, proxy: proxy)
                }
                NewWorkspaceDropZone(store: store, isCompact: isCompact)
            }
        }
    }





    /// True when `workspace` is a top-level source workspace *and* its
    /// cwd is inside a git repo. Worktree rows are excluded (worktree
    /// nesting isn't supported); non-git workspaces (e.g. `~/Downloads`
    /// opened as a workspace) hide the menu item so users never see an
    /// option that can only error.
    private func canCreateWorktree(from workspace: Workspace) -> Bool {
        guard workspace.worktreeParentId == nil else { return false }
        return GitWatcher.findGitDir(near: workspace.workingDirectory) != nil
    }

    @ViewBuilder
    private func brand(isCompact: Bool) -> some View {
        Group {
            if isCompact {
                HoverableIconButton(
                    systemName: "plus",
                    fontSize: 12,
                    size: Theme.chromeToolbarButtonSize,
                    help: "New workspace"
                ) {
                    store.addWorkspace()
                }
            } else {
                HStack(spacing: 0) {
                    FirstGlyphCenteredLayout(axisX: Theme.sidebarLeadingIconCenterX) {
                        Text(AppIdentity.appName)
                            .font(Theme.display(15.5, weight: .semibold))
                            .foregroundStyle(Theme.chromeForeground)
                        Text("A")
                            .font(Theme.display(15.5, weight: .semibold))
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    .fixedSize()
                    Spacer()
                    HoverableIconButton(
                        systemName: "plus",
                        fontSize: 12,
                        size: Theme.chromeToolbarButtonSize,
                        help: "New workspace"
                    ) {
                        store.addWorkspace()
                    }
                }
                // The layout owns the leading space required to centre its
                // measured first glyph; the trailing action keeps the regular
                // 16pt content gutter.
                .padding(.trailing, Theme.sidebarContentLeadingX)
            }
        }
        // A source-list title sits on the lower side of its 40pt header: the
        // first row's own vertical inset otherwise makes a geometrically
        // centred title read too high. Keep the whole title/action group on
        // the 4pt spacing grid instead of applying a text-only pixel offset.
        .padding(.bottom, Theme.space1)
        .frame(maxWidth: .infinity)
        .frame(height: Theme.contentHeaderHeight, alignment: .bottom)
    }

    private func list(isCompact: Bool, proxy: ScrollViewProxy) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 3) {
                if isCompact {
                    // 52pt-wide sidebar can't fit a disclosure triangle next
                    // to a 28pt icon — fall back to a flat list. The order
                    // is stable: store.workspaces already places worktrees
                    // after their source by virtue of being appended at
                    // creation time.
                    ForEach(Array(store.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        // canCreateWorktree walks the fs (`findGitDir`) —
                        // hoist once per workspace so the two row callbacks
                        // don't each stat the same ancestor chain.
                        let canCreate = canCreateWorktree(from: workspace)
                        let goToSource: (() -> Void)? = workspace.worktreeParentId
                            .flatMap { id in store.workspaces.first { $0.id == id } }
                            .map { parent in { store.activateWorkspace(parent) } }
                        DraggableWorkspaceRow(
                            workspace: workspace,
                            store: store,
                            myIndex: index,
                            isCompact: isCompact,
                            draggingId: $draggingWorkspaceId,
                            onCreateWorktree: canCreate ? { presentCreateWorktree(workspace) } : nil,
                            onGoToSource: goToSource
                        )
                    }
                } else {
                    // A workspace is "top-level" either because it has no
                    // parent, or because its parent is gone — defensive
                    // fallback so a bug that strands a worktree (parent
                    // closed while child kept) still surfaces the row in
                    // the sidebar instead of vanishing it entirely.
                    let parentIds = Set(store.workspaces.map(\.id))
                    let topLevel = store.workspaces.enumerated().filter { _, ws in
                        guard let parentId = ws.worktreeParentId else { return true }
                        return !parentIds.contains(parentId)
                    }
                    ForEach(Array(topLevel), id: \.element.id) { index, workspace in
                        workspaceTree(parent: workspace, parentIndex: index)
                    }
                }
            }
            // Source-list rows use an 8pt hover-fill inset. Their own 8pt
            // content inset then places the 20pt mark at x = 16...36. The
            // 40pt header already owns the vertical separation above the
            // source list, so don't double that gap with extra top padding.
            .padding(.horizontal, Theme.space2)
            .padding(.bottom, Theme.space2)
        }
        // ⌘⇧R parks the active workspace on the store; reveal its row so the
        // row's inline editor is visible, including a virtualized row.
        .onChange(of: store.pendingRenameWorkspace?.id) { _, _ in
            revealWorkspaceForRename(using: proxy)
        }
        .onAppear { revealWorkspaceForRename(using: proxy) }
    }

    @ViewBuilder
    private func workspaceTree(parent: Workspace, parentIndex: Int) -> some View {
        let worktrees = store.workspaces.filter { $0.worktreeParentId == parent.id }
        let hasWorktrees = !worktrees.isEmpty
        let isCollapsed = collapsedParents.contains(parent.id)

        // canCreateWorktree walks the fs (`findGitDir`) — hoist once so
        // the two callbacks don't each stat the same ancestor chain.
        let canCreate = canCreateWorktree(from: parent)
        DraggableWorkspaceRow(
            workspace: parent,
            store: store,
            myIndex: parentIndex,
            isCompact: false,
            draggingId: $draggingWorkspaceId,
            disclosure: hasWorktrees
                ? SidebarWorkspaceRow.WorktreeDisclosure(
                    isCollapsed: isCollapsed,
                    toggle: { toggleCollapsed(parent.id) }
                )
                : nil,
            onCreateWorktree: canCreate ? { presentCreateWorktree(parent) } : nil
        )

        if hasWorktrees && !isCollapsed {
            ForEach(worktrees) { worktree in
                SidebarWorkspaceRow(
                    workspace: worktree,
                    isActive: worktree.id == store.activeWorkspaceId,
                    isCompact: false,
                    canCloseOthers: store.workspaces.count > 1,
                    onActivate: { store.activateWorkspace(worktree) },
                    onClose: { store.requestCloseWorkspace(worktree) },
                    onCloseOthers: { store.closeOtherWorkspaces(keeping: worktree) },
                    onDuplicate: { store.duplicateWorkspace(worktree) },
                    onRename: { store.renameWorkspace(worktree, to: $0) },
                    onSetTag: { store.setTag($0, for: worktree) },
                    onDetails: { LocalFormTabs.shared.details(worktree, from: store) },
                    onGoToSource: { store.activateWorkspace(parent) }
                )
                // Source-list hierarchy should be visible without decoding a
                // badge: worktree children sit one rhythm step inside their
                // source workspace while keeping the row itself lightweight.
                .padding(.leading, Theme.space3)
                .workspaceTabDropTarget(store: store, workspace: worktree)
            }
        }
    }

    private func toggleCollapsed(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.12)) {
            if collapsedParents.contains(id) {
                collapsedParents.remove(id)
            } else {
                collapsedParents.insert(id)
            }
        }
    }

    /// Bring the active workspace's row into the view hierarchy so its rename
    /// editor is visible even under a collapsed worktree parent or outside
    /// the LazyVStack's realized window.
    private func revealWorkspaceForRename(using proxy: ScrollViewProxy) {
        guard let workspace = store.pendingRenameWorkspace else { return }
        store.pendingRenameWorkspace = nil
        if let parentId = workspace.worktreeParentId, collapsedParents.contains(parentId) {
            collapsedParents.remove(parentId)
        }
        // Defer so a just-expanded subtree is laid out before scrolling to a
        // row that may have only now been inserted.
        DispatchQueue.main.async {
            proxy.scrollTo(workspace.id, anchor: .center)
        }
    }

    private func presentCreateWorktree(_ workspace: Workspace) {
        store.requestCreateWorktree(workspace)
    }
}

/// Drag source + drop target with a direction-aware edge indicator —
/// `top` when origin is below (dragging up), `bottom` when origin is above
/// (dragging down), so the line always shows where the dropped row will land.
private struct DraggableWorkspaceRow: View {
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    let myIndex: Int
    let isCompact: Bool
    @Binding var draggingId: UUID?
    /// Non-nil only for source workspaces that own at least one worktree.
    /// Worktree rows themselves render via `SidebarWorkspaceRow` directly,
    /// without this wrapper, so they don't pick up drag/drop handlers.
    var disclosure: SidebarWorkspaceRow.WorktreeDisclosure? = nil
    var onCreateWorktree: (() -> Void)? = nil
    var onGoToSource: (() -> Void)? = nil

    @State private var isTargeted = false

    var body: some View {
        let originIndex: Int? = {
            guard let id = draggingId, id != workspace.id else { return nil }
            return store.workspaces.firstIndex(where: { $0.id == id })
        }()
        let dragsDownward = (originIndex ?? Int.max) < myIndex
        let edge: Alignment = dragsDownward ? .bottom : .top
        let isSelfDrag = draggingId == workspace.id

        SidebarWorkspaceRow(
            workspace: workspace,
            isActive: workspace.id == store.activeWorkspaceId,
            isCompact: isCompact,
            canCloseOthers: store.workspaces.count > 1,
            onActivate: { store.activateWorkspace(workspace) },
            onClose: { store.requestCloseWorkspace(workspace) },
            onCloseOthers: { store.closeOtherWorkspaces(keeping: workspace) },
            onDuplicate: { store.duplicateWorkspace(workspace) },
            onRename: { store.renameWorkspace(workspace, to: $0) },
            onSetTag: { store.setTag($0, for: workspace) },
            onDetails: { LocalFormTabs.shared.details(workspace, from: store) },
            disclosure: disclosure,
            onCreateWorktree: onCreateWorktree,
            onGoToSource: onGoToSource
        )
        .dropIndicator(active: isTargeted && draggingId != nil && !isSelfDrag, on: edge)
        .tabDropHighlight(isTargeted && store.draggedTab.map { store.canDropTab($0.id, in: workspace) } == true)
        .onDrag {
            draggingId = workspace.id
            return NSItemProvider(object: workspace.id.uuidString as NSString)
        }
        .dropDestination(for: String.self) { dropped, _ in
            defer {
                draggingId = nil
                store.draggingTabId = nil
            }
            guard let id = dropped.first.flatMap(UUID.init) else { return false }
            if store.handleTabDrop(droppedId: id, in: workspace) { return true }
            guard let from = store.workspaces.firstIndex(where: { $0.id == id }) else { return false }
            withAnimation(.easeInOut(duration: 0.18)) {
                store.moveWorkspace(from: from, to: myIndex)
            }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
