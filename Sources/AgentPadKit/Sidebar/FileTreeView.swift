import SwiftUI

/// Sidebar files mode: a header naming the active workspace's root, then the
/// flattened file tree. Mounted by `SidebarView` in place of the workspace
/// list while `store.sidebarContent == .files` (full mode only — 52pt can't
/// fit a tree).
struct FileTreeView: View {
    let store: WorkspaceStore
    let model: FileTreeModel

    @State private var activationToken = 0
    /// AgentPad: the dotfile setting is shared by every window; each tree
    /// re-lists itself when it flips, not just the one whose button was hit.
    @AppStorage(FileTreePreferences.showHiddenKey) private var showHiddenFiles = true
    /// AgentPad: find-a-file query; non-empty swaps the tree for results.
    @State private var fileQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            if let root = model.rootURL {
                header(root: root)
                Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            }
            content
                // AgentPad: empty space anywhere in the tree — including an
                // empty or still-loading root — takes drops into the root.
                .fileTreeDropTarget(directory: model.rootURL, root: model.rootURL)
        }
        .onAppear {
            activationToken = model.activate(root: effectiveRoot)
            store.refreshFileTreeGitDiff()
        }
        // Tokened: an animated unmount's late onDisappear must not deactivate
        // the model a newer mount just activated (frozen-tree race).
        .onDisappear { model.deactivate(token: activationToken) }
        // Follows the active workspace, and — for plain workspaces, where
        // `diskPath == workingDirectory` — OSC 7 cwd drift; worktrees stay
        // pinned via `worktreePath`.
        .onChange(of: store.fileTreeRoot?.path) { _, newPath in
            // AgentPad: switching tabs/workspaces leaves an external session's folder.
            ExternalTreeRoot.for(store).clear()
            model.setRoot(newPath.map { URL(fileURLWithPath: $0) })
            store.refreshFileTreeGitDiff()
        }
        .onChange(of: showHiddenFiles) { _, _ in
            if let root = model.rootURL { model.refresh(dirPath: root.path) }
        }
        .onChange(of: ExternalTreeRoot.for(store).url) { _, _ in
            model.setRoot(effectiveRoot)
        }
    }

    /// AgentPad: an external session's folder when one is shown, else AgentPad's own root.
    private var effectiveRoot: URL? {
        ExternalTreeRoot.for(store).url ?? store.fileTreeRoot
    }

    private func header(root: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.chromeForeground.opacity(0.6))
                    .frame(width: Theme.sidebarPrimaryIconSize)
                Text(root.lastPathComponent)
                    .font(Theme.display(13, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text((root.path as NSString).abbreviatingWithTildeInPath)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.chromeFaint)
                .lineLimit(1)
                .truncationMode(.head)
            // AgentPad: which external session this is, actions on the root
            // folder itself, and file search.
            if let label = ExternalTreeRoot.for(store).label {
                HStack(spacing: 4) {
                    Text("Session in another terminal: \(label)")
                        .font(Theme.display(10.5))
                        .foregroundStyle(Theme.chromeMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    HoverableIconButton(systemName: "xmark", fontSize: 9, size: 18, help: "Back to the active tab's folder") {
                        ExternalTreeRoot.for(store).clear()
                    }
                }
            }
            FileTreeRootActions(root: root)
            FileSearchField(query: $fileQuery)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Theme.sidebarContentLeadingX)
        .padding(.trailing, Theme.space3)
        .padding(.top, Theme.space1)
        .padding(.bottom, Theme.space2)
        .help(root.path)
    }

    @ViewBuilder
    private var content: some View {
        if let root = model.rootURL, !fileQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            FileSearchResults(root: root, query: fileQuery) { url in
                model.selectedId = url.standardizedFileURL.path
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                    FilePreviewModel.for(store).open(url)
                }
            }
        } else if store.active == nil {
            emptyState("square.dashed", "No active workspace")
        } else if model.isLoading {
            loadingState
        } else if model.rootError {
            emptyState("folder.badge.questionmark", "Folder unavailable")
        } else if model.rows.isEmpty {
            emptyState("folder", "Empty folder")
        } else {
            ScrollView(showsIndicators: false) {
                // spacing 0 keeps the indent guides visually continuous down
                // the column; each row carries its own hover/selected fill.
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        FileTreeRowView(row: row, model: model, store: store)
                    }
                }
                .padding(.horizontal, Theme.space2)
                .padding(.top, Theme.space1)
                .padding(.bottom, Theme.space2)
            }
            // Fresh scroll position when the tree re-roots — offsets from
            // the previous workspace's tree are meaningless here.
            .id(model.rootURL?.path)
        }
    }

    private var loadingState: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ symbol: String, _ message: String) -> some View {
        VStack(spacing: Theme.space2) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.chromeFaint)
            Text(message)
                .font(Theme.display(12))
                .foregroundStyle(Theme.chromeMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Theme.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One flattened tree row — indent guides by depth, chevron for directories,
/// icon, name. Single click selects (and toggles a directory); double click
/// opens a file with its default app; drag carries the file/folder URL so a
/// drop onto a terminal pane inserts its escaped path (same path as a Finder
/// drag — the pane's `performDragOperation` reads the same `.fileURL`); right
/// click opens the AgentPad popover menu.
private struct FileTreeRowView: View {
    let row: FileTreeRow
    let model: FileTreeModel
    let store: WorkspaceStore

    @State private var isHovered = false
    @State private var isContextMenuOpen = false
    @State private var lastDirectoryToggle: Date = .distantPast

    /// Per-level indent. 14pt keeps ~10 levels readable inside the sidebar's
    /// full width. The folder/file mark owns the 20pt primary column while a
    /// directory chevron sits just to its left; nested rows shift both by one
    /// indent step. Names beyond depth truncate middle and the row tooltip
    /// carries the full path.
    private static let indentPerLevel: CGFloat = 14
    private static let chevronColumn: CGFloat = 8
    private static let iconColumn = Theme.sidebarPrimaryIconSize

    var body: some View {
        switch row.kind {
        case .entry(let node):
            entryRow(node)
        case .placeholder:
            placeholderRow()
        }
    }

    /// One 1pt guide per ancestor level, full row height. The first guide is
    /// on the root chevron axis and every additional guide advances 14pt, so
    /// each nested chevron lands directly below its parent's guide.
    @ViewBuilder
    private func indentGuides(_ depth: Int) -> some View {
        ZStack(alignment: .leading) {
            ForEach(0..<depth, id: \.self) { index in
                Rectangle()
                    .fill(Theme.chromeHairline)
                    .frame(width: 1)
                    .offset(
                        x: Theme.sidebarContentLeadingX - Theme.space2
                            + CGFloat(index) * Self.indentPerLevel
                    )
            }
        }
    }

    /// The shared row frame: the caller's leading columns + label (the label
    /// fills the remaining width itself), depth indentation, and the common
    /// padding recipe. The indent
    /// guides draw in a full-height *background* — as HStack siblings they'd
    /// stop at the content height and leave a gap across the vertical
    /// padding of every row, rendering as dashes instead of continuous
    /// lines. Row-kind-specific modifiers (hover fill, gestures, drag) chain
    /// onto the result at the `entryRow` call site.
    private func rowShell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(.leading, CGFloat(row.depth) * Self.indentPerLevel)
        .padding(.vertical, 3.5)
        .padding(.leading, Theme.sidebarContentLeadingX - Theme.space2)
        .padding(.trailing, Theme.space2)
        .background(alignment: .leading) { indentGuides(row.depth) }
    }

    private func entryRow(_ node: FileNode) -> some View {
        let isSelected = model.selectedId == row.id
        return rowShell {
            ZStack(alignment: .leading) {
                Image(systemName: FileTreeLister.symbolName(for: node))
                    .font(.system(size: 11))
                    .foregroundStyle(iconColor(node, selected: isSelected))
                    .frame(width: Self.iconColumn)
                if node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isSelected || isHovered ? Theme.chromeMuted : Theme.chromeFaint)
                        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                        .frame(width: Self.chevronColumn)
                        .offset(x: -Self.chevronColumn / 2)
                }
            }
            .frame(width: Self.iconColumn)
            // The name takes ALL remaining width (truncating internally) and
            // the badge is fixedSize — during a sidebar-width drag every
            // frame's layout is then a pure function of the row width. A
            // Spacer + two negotiating Texts re-split compression per frame,
            // which visibly judders the right-pinned badge.
            Text(node.name)
                .font(Theme.display(12.5))
                .foregroundStyle(nameColor(selected: isSelected))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            diffBadge(node)
        }
        .animation(.easeOut(duration: 0.15), value: row.isExpanded)
        .hoverableRowBackground(isActive: isSelected, isHovered: isHovered)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        // Drag carries the raw file URL (public.file-url). The terminal pane's
        // `performDragOperation` reads exactly this and backslash-escapes the
        // path, so a tree drag lands identically to a Finder drag.
        .onDrag {
            NSItemProvider(object: node.url as NSURL)
        } preview: {
            dragPreview(node)
        }
        // AgentPad: drop files onto a folder row (file rows aren't targets, so
        // the highlight never points somewhere the files won't go).
        .fileTreeDropTarget(directory: node.isDirectory ? node.url : nil, root: model.rootURL)
        // count:2 must attach before count:1 or the double never recognizes.
        // A double-click on a file also fires the single handler on its
        // first click — select-then-open, same as Finder.
        .onTapGesture(count: 2) {
            if !node.isDirectory { NSWorkspace.shared.open(node.url) }
        }
        .onTapGesture {
            model.selectedId = row.id
            // AgentPad: a file click previews it under the terminal.
            if !node.isDirectory { FilePreviewModel.for(store).open(node.url) }
            guard node.isDirectory else { return }
            // Whether the single-tap fires once or twice for a double-click
            // varies across macOS releases; swallow a second toggle inside
            // the double-click window so a Finder-habit double-click reads
            // as "expand", never an open-shut flicker.
            let now = Date()
            guard now.timeIntervalSince(lastDirectoryToggle) > NSEvent.doubleClickInterval else { return }
            lastDirectoryToggle = now
            withAnimation(.easeOut(duration: 0.12)) {
                model.toggleExpanded(node)
            }
        }
        .onHover { isHovered = $0 }
        .overlay(RightClickCatcher { _ in isContextMenuOpen = true })
        .popover(isPresented: $isContextMenuOpen, arrowEdge: .trailing) {
            contextMenu(node)
        }
        .help(node.url.path)
    }

    /// File/folder icon tint — a single-colour hierarchy: folders read as
    /// containers (more solid), files as leaves (muted), the selected row
    /// promotes to full foreground. No hue; AgentPad's chrome stays monochrome.
    private func iconColor(_ node: FileNode, selected: Bool) -> Color {
        if selected { return Theme.chromeForeground }
        if node.isDirectory { return Theme.chromeForeground.opacity(0.6) }
        return isHovered ? Theme.chromeForeground.opacity(0.72) : Theme.chromeMuted
    }

    private func nameColor(selected: Bool) -> Color {
        if selected { return Theme.chromeForeground }
        return Theme.chromeForeground.opacity(isHovered ? 0.95 : 0.82)
    }

    /// Compact chip shown under the cursor while dragging — icon + name on the
    /// chrome surface, so the drag reads as "this file" rather than a snapshot
    /// of the whole hover-highlighted row.
    private func dragPreview(_ node: FileNode) -> some View {
        HStack(spacing: Theme.space1) {
            Image(systemName: FileTreeLister.symbolName(for: node))
                .font(.system(size: 11))
                .foregroundStyle(Theme.chromeForeground.opacity(0.8))
            Text(node.name)
                .font(Theme.display(12))
                .foregroundStyle(Theme.chromeForeground)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.space2)
        .padding(.vertical, Theme.space1)
        .background(Theme.chromeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.chromeHairline, lineWidth: 1))
    }

    private func contextMenu(_ node: FileNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !node.isDirectory {
                AgentPadMenuRow(title: "Open") {
                    isContextMenuOpen = false
                    NSWorkspace.shared.open(node.url)
                }
            }
            RevealInFinderMenuRow(url: node.url) { isContextMenuOpen = false }
            AgentPadMenuDivider()
            AgentPadMenuRow(title: "Copy Path") {
                isContextMenuOpen = false
                writeToGeneralPasteboard(node.url.path)
            }
            // Same escape + paste path as dropping a file from Finder onto a
            // pane, so the two can't drift.
            AgentPadMenuRow(
                title: "Insert Path into Terminal",
                // AgentPad: not into a channel tab (DESIGN-F2).
                isDisabled: store.active?.activeSession == nil || store.active?.activeSession?.isChat == true
            ) {
                isContextMenuOpen = false
                store.active?.activeSession?.engine
                    .paste(AgentPadShellIntegration.backslashEscape(node.url.path))
            }
            // AgentPad: file operations.
            FileTreeOperationRows(node: node, close: { isContextMenuOpen = false })
        }
        .padding(Theme.space1)
        .frame(minWidth: 220)
        .background(Theme.chromeBackground)
    }

    /// Muted, non-interactive note under an expanded-but-unlistable
    /// directory, indented to match its parent's children.
    private func placeholderRow() -> some View {
        rowShell {
            Color.clear.frame(width: Self.iconColumn, height: 1)
            Text(String(localized: "no access", bundle: .agentPadResources))
                .font(Theme.display(11.5))
                .foregroundStyle(Theme.chromeFaint)
                .lineLimit(1)
                .padding(.leading, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Trailing `+X −Y` for a changed file — same tokens and typographic
    /// minus as the status bar's diff segment, so the two read as one
    /// system (the per-file numbers sum to the bar's totals). Collapsed
    /// directories show their subtree total; expanded ones stay quiet and
    /// let the visible children carry the numbers. Binary files (numstat
    /// reports no line counts) show a muted ±.
    @ViewBuilder
    private func diffBadge(_ node: FileNode) -> some View {
        let counts = node.isDirectory
            ? (row.isExpanded ? nil : model.gitDiffDirTotals[row.id])
            : model.gitDiff[row.id]
        if let counts {
            DiffCountBadge(insertions: counts.insertions, deletions: counts.deletions, fontSize: 10)
                .padding(.leading, Theme.space1)
        }
    }
}
