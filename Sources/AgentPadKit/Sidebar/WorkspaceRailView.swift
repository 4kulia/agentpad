import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceRailView: View {
    @Bindable var store: WorkspaceStore
    let width: CGFloat
    let expanded: Bool
    @State private var entries: [WorkspaceRailEntry] = []
    @State private var draggingWorkspaceID: UUID?
    @State private var lastSelection: WorkspaceRailDestination?
    @State private var collapsedParents: Set<UUID> = []
    @FocusState private var selection: WorkspaceRailDestination?
    @FocusState private var searchFocused: Bool

    private var matches: [WorkspaceRailSearch.Match] {
        WorkspaceRailSearch.matches(entries, query: store.navigationPresentation.query, collapsedParents: collapsedParents)
    }
    private var destinations: [WorkspaceRailDestination] {
        expanded ? WorkspaceRailSearch.destinations(matches)
            : store.workspaces.map { WorkspaceRailDestination(workspaceID: $0.id) }
    }

    /// Only in-memory source fields and prepared titles are observed here.
    private var sourceStamp: [String] {
        store.workspaces.flatMap { workspace in
            [workspace.id.uuidString, workspace.title, workspace.workingDirectory.path]
                + workspace.root.allPanes.flatMap(\.tabs).flatMap {
                    [$0.id.uuidString, AttentionSidebarModel.shared.tabTitle($0)]
                }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded { searchField }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if expanded {
                            ForEach(matches) { match in
                                if let workspace = store.workspaces.first(where: { $0.id == match.id }) {
                                    item(workspace)
                                    ForEach(match.tabs) { tab in
                                        tabButton(tab, workspaceID: match.id)
                                    }
                                }
                            }
                            if matches.isEmpty { Text("No matching workspaces or tabs").font(Theme.display(11)).padding(12) }
                        } else {
                            ForEach(store.workspaces) { item($0) }
                        }
                    }.padding(.horizontal, expanded ? 6 : 9).padding(.vertical, 6)
                }
                .onChange(of: store.activeWorkspaceId, initial: true) { _, id in
                    if let id { proxy.scrollTo(WorkspaceRailDestination(workspaceID: id), anchor: .center) }
                }
                .onChange(of: selection) { _, target in
                    if let target { lastSelection = target; proxy.scrollTo(target, anchor: .center) }
                }
                .onChange(of: store.pendingRenameWorkspace?.id, initial: true) { _, id in
                    if let id {
                        searchFocused = false
                        if let parent = store.pendingRenameWorkspace?.worktreeParentId { collapsedParents.remove(parent) }
                        DispatchQueue.main.async { proxy.scrollTo(WorkspaceRailDestination(workspaceID: id), anchor: .center) }
                        store.pendingRenameWorkspace = nil
                    }
                }
            }
            footer
        }
        .frame(width: width)
        .background(Theme.chromeBackground)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.chromeSeparator).frame(width: 1) }
        .onDrop(of: [UTType.fileURL.identifier, UTType.text.identifier, InternalFileDrag.type.rawValue], delegate: RailSurfaceDrop(store: store))
        .onAppear { refreshEntries(); focusSearch() }
        .onChange(of: sourceStamp) { _, _ in refreshEntries() }
        .onChange(of: AttentionSidebarModel.shared.projection.tabs) { _, _ in refreshEntries() }
        .onChange(of: ChatOrgCurrent.identity()) { _, _ in refreshEntries() }
        .onChange(of: ChatOrgCurrent.shared.model?.channelsVisible) { _, _ in refreshEntries() }
        .onChange(of: ChatOrgCurrent.shared.model?.view.channels) { _, _ in refreshEntries() }
        .onChange(of: store.navigationPresentation.focusRevision) { _, _ in focusSearch() }
        .onChange(of: expanded) { _, expanded in
            if expanded { focusSearch() }
            else { lastSelection = nil }
        }
        .onChange(of: store.navigationPresentation.query) { _, _ in lastSelection = nil }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.escape) { store.closeNavigation(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspaces navigation")
    }

    private var header: some View {
        HStack(spacing: 6) {
            if expanded {
                Text("Workspaces").font(Theme.display(11, weight: .semibold))
                Text("\(store.workspaces.count)").font(Theme.display(10)).foregroundStyle(Theme.chromeMuted)
                Spacer(minLength: 0)
            }
            Button {
                if expanded { store.closeNavigation() } else { store.openWorkspaceList() }
            } label: {
                Image(systemName: expanded ? "chevron.left" : "list.bullet")
                    .frame(width: expanded ? 28 : 40, height: 40)
            }.buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Close workspace list" : "Find workspaces and tabs")
                .help(expanded ? "Close workspace list · Esc" : "Workspaces… · ⌥⌘0")
        }.padding(.horizontal, 9).padding(.top, 4)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").accessibilityHidden(true)
            TextField("Find workspace or tab", text: $store.navigationPresentation.query)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel("Search workspaces and tabs")
                .onSubmit {
                    if let target = selection ?? destinations.first { store.activateRailDestination(target) }
                }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        }.font(Theme.display(12)).padding(8)
            .background(Theme.chromeSelection, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8).padding(.bottom, 4)
    }

    private func item(_ workspace: Workspace) -> some View {
        let destination = WorkspaceRailDestination(workspaceID: workspace.id)
        let hasChildren = store.workspaces.contains { $0.worktreeParentId == workspace.id }
        return WorkspaceRailItem(store: store, workspace: workspace, expanded: expanded,
                                 draggingWorkspaceID: $draggingWorkspaceID,
                                 collapsed: collapsedParents.contains(workspace.id),
                                 disclosure: hasChildren ? {
                                     if collapsedParents.contains(workspace.id) { collapsedParents.remove(workspace.id) }
                                     else { collapsedParents.insert(workspace.id) }
                                 } : nil) {
                AttentionIndicatorView(indicator: AttentionSidebarModel.shared.workspaceIndicators[.init(window: store.windowID, workspace: workspace.id)])
            }
            .focused($selection, equals: destination)
            .id(destination)
    }

    private func tabButton(_ tab: WorkspaceRailEntry.Tab, workspaceID: UUID) -> some View {
        let destination = WorkspaceRailDestination(workspaceID: workspaceID, sessionID: tab.id)
        return Button { store.activateRailDestination(destination) } label: {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 10)).accessibilityHidden(true)
                AttentionIndicatorView(indicator: AttentionSidebarModel.shared.tabIndicators[tab.id])
                Text(tab.title).lineLimit(1)
                Spacer(minLength: 0)
            }.font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
                .padding(.leading, 38).padding(.trailing, 8).frame(minHeight: 28)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).chatFocusRing()
            .focused($selection, equals: destination).id(destination)
            .accessibilityLabel("\(tab.title), tab, \(tab.detail)")
            .help(tab.title + (AttentionSidebarModel.shared.tabIndicators[tab.id].map { "\n" + AttentionSidebarModel.shared.tooltip($0) } ?? ""))
            .accessibilityValue(AttentionSidebarModel.shared.tabIndicators[tab.id]?.accessibleSummary ?? "No new marks")
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if store.leftNavigation.railVisible {
                ChatSidebarModePicker(store: store, compact: !expanded, model: ChatOrgCurrent.shared.model, includesNewWorkspace: true)
            } else {
                HStack(spacing: 8) {
                    NewWorkspaceDropZone(store: store, isCompact: true).frame(width: 40)
                    Text("Rail hidden · ⌃⌘R to show").font(Theme.display(10)).foregroundStyle(Theme.chromeMuted)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 8)
            }
        }
    }

    private func refreshEntries() {
        // Refreshing titles, permissions or rows must never claim keyboard
        // focus. Resolve a missing selection only on explicit arrow navigation.
        entries = store.workspaceRailEntries()
    }

    private func focusSearch() {
        if expanded { refreshEntries() }
        if expanded && !store.navigationPresentation.dragPeek && store.pendingRenameWorkspace == nil
            && !store.workspaces.contains(where: { $0.nameEdit.isEditing }) {
            searchFocused = true
        }
    }
    private func moveSelection(_ delta: Int) {
        searchFocused = false
        selection = WorkspaceRailSearch.moved(selection ?? lastSelection, by: delta, in: destinations)
    }
}

/// Selection, focus, tags and drop
/// outlines remain independent; the slot itself is never an interactive target.
struct WorkspaceRailItem<Indicator: View>: View {
    let store: WorkspaceStore
    @Bindable var workspace: Workspace
    let expanded: Bool
    @Binding var draggingWorkspaceID: UUID?
    var collapsed = false
    var disclosure: (() -> Void)?
    @ViewBuilder var indicator: () -> Indicator
    @State private var targeted = false
    @State private var hovered = false
    @State private var menuOpen = false
    @State private var canCreateWorktree = false
    @State private var preview: WorkspaceRailEntry?
    @State private var previewKeyboard = false
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var indicatorReadout: AttentionIndicator? { AttentionSidebarModel.shared.workspaceIndicators[.init(window: store.windowID, workspace: workspace.id)] }
    private var active: Bool { workspace.id == store.activeWorkspaceId }
    private var index: Int { store.workspaces.firstIndex(where: { $0.id == workspace.id }) ?? 0 }
    private var acceptsTab: Bool { targeted && store.draggedTab.map { store.canDropTab($0.id, in: workspace) } == true }
    private var activityValue: String {
        let selection = active ? "Selected" : "Not selected"
        return selection + ", " + (indicatorReadout?.accessibleSummary ?? "No new marks")
    }
    private var activityHelp: String {
        if acceptsTab { return "Move tab to \(workspace.title)" }
        return "\(workspace.title)\n\(workspace.workingDirectory.path)" + (indicatorReadout.map { "\n" + $0.accessibleSummary } ?? "")
    }

    var body: some View {
        actionButton
        .attentionPopover(isPresented: $menuOpen, arrowEdge: .trailing) { contextMenu }
        .attentionPopover(isPresented: Binding(get: { store.navigationPresentation.previewWorkspaceID == workspace.id },
            set: { if !$0 { closePreview() } }), arrowEdge: .trailing) {
                if let preview {
                    WorkspaceRailPreview(entry: preview, keyboard: previewKeyboard, activate: { destination in
                        store.activateRailDestination(destination)
                    }, close: { closePreview(); focused = true })
                    .onHover { inside in
                        hoverTask?.cancel()
                        if !inside { closePreview() }
                    }
                }
            }
        .tabDropHighlight(acceptsTab)
        .dropIndicator(active: targeted && draggingWorkspaceID != nil && draggingWorkspaceID != workspace.id,
                       on: dragMovesDown ? .bottom : .top)
        .dropDestination(for: String.self) { payload, _ in
            defer { targeted = false; draggingWorkspaceID = nil; store.finishNavigationDrag() }
            guard store.workspaces.contains(where: { $0 === workspace }),
                  let id = payload.first.flatMap(UUID.init) else { return false }
            if store.handleTabDrop(droppedId: id, in: workspace) {
                store.closeNavigation(restoreFocus: false)
                return true
            }
            guard draggingWorkspaceID == id,
                  let source = store.workspaces.firstIndex(where: { $0.id == id }) else { return false }
            store.moveWorkspace(from: source, to: index)
            return true
        } isTargeted: {
            targeted = $0
            store.setRailDragTarget(workspace.id.uuidString, entered: $0)
            if $0 { hoverTask?.cancel(); closePreview() }
        }
        .accessibilityLabel("\(workspace.title), workspace, \(index + 1) of \(store.workspaces.count)")
        .accessibilityValue(activityValue)
        .accessibilityIdentifier("workspace-rail-\(workspace.id)")
        .accessibilityAction(named: "Rename") { store.requestRenameWorkspace(workspace) }
        .accessibilityAction(named: "Show tabs") { openPreview(keyboard: true) }
        .accessibilityAction(named: "Move up") { move(-1) }
        .accessibilityAction(named: "Move down") { move(1) }
        .accessibilityAction(named: "Close workspace") { store.requestCloseWorkspace(workspace) }
        .help(activityHelp)
        .onDisappear { hoverTask?.cancel() }
        .onChange(of: workspace.nameEdit.isEditing) { wasEditing, editing in
            if wasEditing && !editing { focused = true }
        }
        .onChange(of: ChatOrgCurrent.identity()) { _, _ in closePreview(); preview = nil }
        .onChange(of: ChatOrgCurrent.shared.model?.channelsVisible) { _, _ in closePreview(); preview = nil }
        .onChange(of: AttentionSidebarModel.shared.projection.tabs) { _, _ in
            if preview != nil { preview = store.workspaceRailEntries().first { $0.id == workspace.id } }
        }
    }

    private var actionButton: some View {
        Button { activate() } label: {
            HStack(spacing: 9) {
                tile
                if expanded {
                    VStack(alignment: .leading, spacing: 3) {
                        if workspace.nameEdit.isEditing {
                            InlineNameField(edit: workspace.nameEdit, label: "Workspace title") { text in
                                store.renameWorkspace(workspace, to: text); return nil
                            }
                        } else {
                            Text(workspace.title).font(Theme.display(12, weight: .medium)).lineLimit(1)
                        }
                        Text(workspace.workingDirectory.path).font(Theme.display(10))
                            .foregroundStyle(Theme.chromeMuted).lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                    if index < 9 { Text("\(index + 1)").font(Theme.display(10)).foregroundStyle(Theme.chromeMuted) }
                    if disclosure != nil { Color.clear.frame(width: 24) }
                }
            }
            .padding(.horizontal, expanded ? 6 : 5)
            .padding(.leading, expanded && workspace.worktreeParentId != nil ? 12 : 0)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(active || hovered ? Theme.chromeSelection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focused($focused).chatFocusRing()
        .overlay(alignment: .leading) {
            if active && !expanded {
                RoundedRectangle(cornerRadius: 2).fill(Theme.chromeForeground).frame(width: 3, height: 22).offset(x: -9)
            }
        }
        .overlay {
            if !workspace.nameEdit.isEditing {
                NavigationDragSource(title: workspace.title, writers: { [workspace.id.uuidString as NSString] },
                    click: { _ in activate() }, began: { draggingWorkspaceID = workspace.id },
                    ended: { draggingWorkspaceID = nil })
                    .padding(.trailing, expanded && disclosure != nil ? 24 : 0)
            }
        }
        .overlay(alignment: .trailing) {
            if expanded, let disclosure {
                Button(action: disclosure) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10)).frame(width: 24, height: 40)
                }.buttonStyle(.plain).accessibilityLabel(collapsed ? "Show worktrees" : "Hide worktrees")
            }
        }
        .onHover { value in
            hovered = value
            guard !expanded && !menuOpen && store.draggedTab == nil && draggingWorkspaceID == nil else { return }
            hoverTask?.cancel()
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(value ? 450 : 280))
                guard !Task.isCancelled else { return }
                if value { openPreview(keyboard: false) }
                else if store.navigationPresentation.previewWorkspaceID == workspace.id { closePreview() }
            }
        }
        .onKeyPress(.rightArrow) {
            if expanded, collapsed, let disclosure { disclosure() }
            else { openPreview(keyboard: true) }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard expanded, !collapsed, let disclosure else { return .ignored }
            disclosure(); return .handled
        }
        .onKeyPress(.escape) { closePreview(); return .handled }
        .overlay(RightClickCatcher { _ in openMenu() })
        .onKeyPress(characters: CharacterSet(charactersIn: "\u{F70D}")) { key in
            guard key.modifiers == .shift else { return .ignored }
            openMenu(); return .handled
        }
    }

    private var tile: some View {
        Text(String(workspace.title.prefix(2)).uppercased()).font(Theme.display(11, weight: .semibold))
            .foregroundStyle(workspace.tag?.swatchColor ?? Theme.chromeForeground)
            .frame(width: 30, height: 30)
            .background(Theme.chromeActive, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? Theme.chromeForeground : Theme.chromeHairline, lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                if workspace.worktreeParentId != nil {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                        .padding(2).background(Theme.chromeBackground, in: Circle()).offset(x: 3, y: 3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if indicatorReadout != nil {
                    indicator().frame(width: 14, height: 14).padding(2)
                        .background(Theme.chromeBackground, in: Circle()).offset(x: 5, y: -5)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .accessibilityHidden(true)
    }
    private var dragMovesDown: Bool {
        draggingWorkspaceID.flatMap { id in store.workspaces.firstIndex { $0.id == id } }.map { $0 < index } ?? false
    }
    private func activate() { store.activateRailDestination(WorkspaceRailDestination(workspaceID: workspace.id)) }
    private func openPreview(keyboard: Bool) {
        guard !expanded else { return }
        preview = store.workspaceRailEntries().first { $0.id == workspace.id }
        previewKeyboard = keyboard
        store.captureNavigationFocus()
        store.navigationPresentation.narrowPanelOpen = false
        store.navigationPresentation.previewWorkspaceID = workspace.id
    }
    private func closePreview() {
        guard store.navigationPresentation.previewWorkspaceID == workspace.id else { return }
        store.closeNavigation()
        if previewKeyboard { focused = true }
    }
    private func openMenu() {
        hoverTask?.cancel(); closePreview()
        canCreateWorktree = workspace.worktreeParentId == nil && GitWatcher.findGitDir(near: workspace.workingDirectory) != nil
        menuOpen = true
    }
    private func move(_ direction: Int) {
        let root = workspace.worktreeParentId ?? workspace.id
        let candidates = store.workspaces.indices.filter {
            store.workspaces[$0].id != root && store.workspaces[$0].worktreeParentId != root
        }
        let target = direction < 0 ? candidates.last(where: { $0 < index }) : candidates.first(where: { $0 > index })
        if let target { store.moveWorkspace(from: index, to: target) }
    }
    private var contextMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            menu("Rename Workspace…") { store.requestRenameWorkspace(workspace) }
            menu("Duplicate Workspace") { store.duplicateWorkspace(workspace) }
            menu("Move Up") { move(-1) }
            menu("Move Down") { move(1) }
            if canCreateWorktree { menu("Create Worktree…") { store.requestCreateWorktree(workspace) } }
            if let parent = store.workspaces.first(where: { $0.id == workspace.worktreeParentId }) {
                menu("Go to Source Workspace") { store.activateWorkspace(parent) }
            }
            AgentPadMenuDivider()
            ColorTagStrip(current: workspace.tag) { tag in menuOpen = false; store.setTag(tag, for: workspace) }
            menu(workspace.tag == nil ? "Custom Tag…" : "Edit Tag…") { LocalFormTabs.shared.details(workspace, from: store) }
            menu("Workspace details…") { LocalFormTabs.shared.details(workspace, from: store) }
            AgentPadMenuDivider()
            menu(workspace.worktreeParentId == nil ? "Close Workspace" : "Close Worktree…") { store.requestCloseWorkspace(workspace) }
            menu("Close Other Workspaces") { store.closeOtherWorkspaces(keeping: workspace) }
            RevealInFinderMenuRow(url: workspace.workingDirectory) { menuOpen = false }
        }.padding(4).frame(minWidth: 230).background(Theme.chromeBackground)
    }
    private func menu(_ title: String, action: @escaping () -> Void) -> some View {
        AgentPadMenuRow(title: title) { menuOpen = false; action() }
    }
}

private struct WorkspaceRailPreview: View {
    let entry: WorkspaceRailEntry
    let keyboard: Bool
    let activate: (WorkspaceRailDestination) -> Void
    let close: () -> Void
    @FocusState private var selected: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.title).font(Theme.display(13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(entry.path).font(Theme.display(10)).foregroundStyle(Theme.chromeMuted).textSelection(.enabled)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.tabs) { tab in
                        let title = AttentionSidebarModel.shared.tabTitle(tab.id) ?? tab.title
                        Button { activate(.init(workspaceID: entry.id, sessionID: tab.id)) } label: {
                            HStack {
                                AttentionIndicatorView(indicator: AttentionSidebarModel.shared.tabIndicators[tab.id])
                                Text(title).lineLimit(2)
                                Spacer(minLength: 8)
                                Text(tab.detail).font(Theme.display(10)).foregroundStyle(Theme.chromeMuted)
                            }.padding(6).contentShape(Rectangle())
                        }.buttonStyle(.plain).focused($selected, equals: tab.id).chatFocusRing()
                            .accessibilityLabel("Open \(title), tab")
                            .accessibilityValue(AttentionSidebarModel.shared.tabIndicators[tab.id]?.accessibleSummary ?? "No new marks")
                            .help(title + (AttentionSidebarModel.shared.tabIndicators[tab.id].map { "\n" + AttentionSidebarModel.shared.tooltip($0) } ?? ""))
                    }
                }
            }.frame(maxHeight: 280)
        }.font(Theme.display(12)).padding(14).frame(width: 268)
            .background(Theme.chromeBackground)
            .onAppear { if keyboard { selected = entry.tabs.first?.id } }
            .onKeyPress(.escape) { close(); return .handled }
            .onMoveCommand { direction in
                guard direction == .up || direction == .down, !entry.tabs.isEmpty else { return }
                let index = entry.tabs.firstIndex { $0.id == selected } ?? 0
                selected = entry.tabs[min(entry.tabs.count - 1, max(0, index + (direction == .down ? 1 : -1)))].id
            }
    }
}
