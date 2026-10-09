import AppKit
import SwiftUI

@MainActor
enum AllSessionsLive {
    static func snapshot(monitor: AgentMonitor = .shared, external: ExternalSessionMonitor = .shared) -> [AllSessionItem] {
        let sessions = Dictionary(monitor.storesProvider().flatMap(\.allSessions).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = monitor.entries.map { entry in
            let session = sessions[entry.id]
            let status: AllSessionStatus = session?.hasCurrentAttentionFailure == true ? .error
                : entry.state == .attention ? .needsInput : entry.state == .running ? .working : entry.state == .failed ? .error : .idle
            let record = AgentSessionRecord(agentId: entry.agent.rosterId, conversationId: entry.conversationId ?? session?.resumedConversationId ?? "",
                title: entry.tabTitle, cwd: entry.directory, lastActivity: max(session?.hookStateAt ?? .distantPast, session?.catalogStartedAt ?? .distantPast))
            return AllSessionItem(id: "own:\(entry.id)", record: record, source: .own(entry.id), status: status, title: entry.tabTitle)
        }
        result += external.sessions.map { session in
            let record = AgentSessionRecord(agentId: AgentTemplate.claudeCodeID, conversationId: session.sessionId,
                title: session.displayTitle, cwd: session.cwd, lastActivity: session.statusSince ?? session.startedAt ?? .distantPast,
                automatic: session.kind == "background")
            let status: AllSessionStatus = session.monitorState == .attention ? .needsInput : session.monitorState == .running ? .working : .idle
            return AllSessionItem(id: "external:" + session.id, record: record, source: .external(session), status: status, title: session.displayTitle)
        }
        return result
    }
}

@MainActor
enum AllSessionsActions {
    static func activate(_ item: AllSessionItem, model: AllSessionsModel, store: WorkspaceStore, split: Bool = false,
                         monitor: AgentMonitor = .shared,
                         resolveClaude: @escaping @Sendable (String, URL, ChannelConversationFilter) -> Result<String, ClaudeSessionResume.Refusal> = {
                             ClaudeSessionResume.resolve($0, root: $1, visibility: $2)
                         }) async {
        guard !Task.isCancelled, !model.state.isClosed else { return }
        model.resumeError = nil
        switch item.source {
        case .own(let id):
            if monitor.storesProvider().contains(where: { $0.allSessions.contains { $0.id == id } }) {
                monitor.onActivate(id); return
            }
        case .external(let session):
            if let current = ExternalSessionMonitor.shared.sessions.first(where: { $0.id == session.id && $0.processStart == session.processStart }) {
                ExternalSessionActions.focus(current); return
            }
        case .disk: break
        }
        // A disk row can outlive a resume in another window until refilter finishes.
        // Look at the actual tabs, including their spawn-time ID before hooks arrive.
        func focusOpenConversation() -> Bool {
            guard store.conversationVisibility().allows(agentId: item.record.agentId, conversationId: item.record.conversationId) else { return false }
            for owner in ([store] + monitor.storesProvider()).filter({ !$0.isTerminated }) {
                if let session = owner.allSessions.first(where: {
                    $0.agent.rosterId == item.record.agentId
                        && ($0.conversationId ?? $0.resumedConversationId) == item.record.conversationId
                }) {
                    monitor.onActivate(session.id)
                    return true
                }
            }
            return false
        }
        if focusOpenConversation() { return }
        var claudeResolution: Result<String, ClaudeSessionResume.Refusal>?
        if item.record.agentId == AgentTemplate.claudeCodeID {
            let id = item.record.conversationId, root = store.claudeProjectsRoot, visibility = store.conversationVisibility()
            claudeResolution = await Task.detached(priority: .userInitiated) {
                resolveClaude(id, root, visibility)
            }.value
        }
        guard !Task.isCancelled, !model.state.isClosed else { return }
        guard !store.isTerminated else { model.resumeError = "This window is no longer available."; return }
        // Another action may have opened the conversation while resolution suspended.
        // This check and the spawn stay together on MainActor, with no intervening await.
        if focusOpenConversation() { return }
        switch store.resumeAgentSession(item.record, claudeResolution: claudeResolution) {
        case .failure(let refusal): model.resumeError = refusal.message(agentId: item.record.agentId, conversationId: item.record.conversationId)
        case .success(let session):
            if split, let location = store.location(ofSessionId: session.id),
               let pane = store.splitPane(location.pane, orientation: .horizontal, in: location.workspace) {
                _ = store.handleTabDrop(droppedId: session.id, to: pane, at: 0, in: location.workspace)
            }
        }
    }
}

struct AllSessionsTab: View {
    @Bindable var model: AllSessionsModel
    var autoload = true
    var liveSnapshot: () -> [AllSessionItem] = { AllSessionsLive.snapshot() }
    var owner: () -> WorkspaceStore? = { nil }
    @State private var folderPicker = false
    @FocusState private var focus: Focus?
    private enum Focus: Hashable { case search, list, rename(String) }

    var body: some View {
        let live = liveSnapshot()
        VStack(spacing: 0) {
            header
            filters
            Divider()
            HStack(spacing: 0) {
                results.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let selected = model.selected {
                    Divider()
                    preview(selected).frame(minWidth: 230, idealWidth: 290, maxWidth: 350)
                }
            }
        }.background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground).tint(ChatAppearance.accent)
            .task { if autoload { await model.start() } }
            .onChange(of: live, initial: true) { _, value in model.updateLive(value) }
            .onChange(of: model.catalog.revision) { _, _ in model.refilter() }
            .onChange(of: model.names.values) { _, _ in model.refilter() }
            .onChange(of: model.query) { _, _ in model.refilter(debounce: true) }
            .onChange(of: model.renamingID) { _, id in focus = id.map(Focus.rename) }
            .onKeyPress(characters: CharacterSet(charactersIn: "f")) { press in
                guard press.modifiers == .command else { return .ignored }; focus = .search; return .handled
            }
            .onKeyPress(.escape) {
                if model.renamingID != nil { model.cancelRename() }
                else if folderPicker { folderPicker = false }
                else { model.select(nil) }
                return .handled
            }
            .onKeyPress(.return) {
                guard model.renamingID == nil, let selected = model.selected else { return .ignored }
                activate(selected); return .handled
            }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock").font(.system(size: 18)).foregroundStyle(ChatAppearance.accent)
                .frame(width: 34, height: 34).background(ChatAppearance.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("All sessions").font(Theme.display(18, weight: .semibold))
                Text("All folders on this Mac · Available offline").font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary)
            }
            Spacer()
            Label("Only you", systemImage: "lock").font(.caption).foregroundStyle(ChatAppearance.secondary)
            Button { model.catalog.refresh(force: true); Task { await model.names.load() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan").accessibilityLabel("Rescan").disabled(model.catalog.isScanning)
        }.padding(18)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(ChatAppearance.secondary)
                TextField("Search names, first prompts and folders", text: $model.query).textFieldStyle(.plain).focused($focus, equals: .search)
                Text("⌘F").font(.caption).foregroundStyle(ChatAppearance.secondary)
            }.padding(9).background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.chromeSeparator))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { filterControls }
                VStack(alignment: .leading, spacing: 8) { filterControls }
            }
            if folderPicker { folderChoices }
            HStack {
                Toggle("Hide automatic", isOn: Binding(get: { model.filters.hideAutomatic }, set: { model.filters.hideAutomatic = $0 }))
                    .toggleStyle(.switch).controlSize(.small).fixedSize()
                Text("\(model.result.hiddenAutomatic) hidden").font(.caption).foregroundStyle(ChatAppearance.secondary)
                Spacer()
                Text("Group by").font(.caption).foregroundStyle(ChatAppearance.secondary).fixedSize()
                Picker("Group", selection: Binding(get: { model.filters.grouping }, set: { model.filters.grouping = $0 })) {
                    Text("By day").tag(AllSessionsFilterState.Grouping.day)
                    Text("By folder").tag(AllSessionsFilterState.Grouping.folder)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
        }.padding(.horizontal, 18).padding(.bottom, 14)
    }

    @ViewBuilder private var filterControls: some View {
        Menu {
            Button("All tools") { model.filters.tool = nil }
            ForEach(model.result.tools, id: \.self) { id in Button(toolName(id)) { model.filters.tool = id } }
        } label: { Label(model.filters.tool.map(toolName) ?? "Tool: All", systemImage: "terminal") }
        Button { folderPicker.toggle() } label: {
            Label(model.filters.folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Folder: All", systemImage: "folder")
        }
        Menu {
            Button("All statuses") { model.filters.status = nil }
            ForEach(AllSessionStatus.allCases, id: \.self) { status in Button(status.title) { model.filters.status = status } }
        } label: { Text(model.filters.status?.title ?? "Status: All") }
        Menu {
            ForEach(AllSessionsFilterState.Period.allCases, id: \.self) { period in Button(period.title) { model.filters.period = period } }
        } label: { Text(model.filters.period.title) }
    }

    private var folderChoices: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Find folder", text: $model.folderQuery).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Button("All folders") { model.filters.folder = nil; folderPicker = false }
                    ForEach(model.result.folders.filter { model.folderQuery.isEmpty || $0.localizedStandardContains(model.folderQuery) }, id: \.self) { folder in
                        Button((folder as NSString).abbreviatingWithTildeInPath) { model.filters.folder = folder; folderPicker = false }
                    }
                }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 130)
        }.padding(10).background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 7))
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.result.shown) sessions of \(model.result.total)").font(Theme.display(11, weight: .semibold))
                Spacer()
                Text("Newest first").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
            }.padding(14)
            if let problem = model.names.problem { inlineError(problem) }
            if let error = model.resumeError { inlineError(error) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if model.result.shown == 0 {
                            Text(model.catalog.isScanning ? "Looking for sessions…" : model.query.isEmpty ? "No sessions match these filters." : "No matching sessions.")
                                .foregroundStyle(ChatAppearance.secondary).frame(maxWidth: .infinity).padding(30)
                        }
                        ForEach(model.result.sections) { section in
                            Text(section.title).font(Theme.display(10, weight: .semibold)).foregroundStyle(ChatAppearance.secondary)
                                .padding(.horizontal, 10).padding(.top, 8)
                            ForEach(section.items) { item in row(item).id(item.id) }
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 12)
                }.focusable().focused($focus, equals: .list)
                    .onChange(of: model.renamingID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    .onMoveCommand { direction in
                        guard direction == .up || direction == .down else { return }
                        let items = model.result.items
                        guard !items.isEmpty else { return }
                        let index = items.firstIndex { $0.id == model.selectedID } ?? (direction == .up ? items.count : -1)
                        let item = items[max(0, min(items.count - 1, index + (direction == .up ? -1 : 1)))]
                        model.select(item); proxy.scrollTo(item.id)
                    }
            }
            Divider()
            HStack {
                if model.catalog.isScanning { Text("Scanning \(model.catalog.scanned) of \(model.catalog.total)…") }
                else if model.catalog.skipped > 0 { Text("\(model.catalog.skipped) files skipped") }
                else { Text("Click to preview · Double-click to open") }
                Spacer()
                Text("↑↓ · Enter to open")
            }.font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).padding(10)
        }
    }

    private func row(_ item: AllSessionItem) -> some View {
        HStack(spacing: 10) {
            ContactAvatar(stableID: item.record.agentId, name: toolName(item.record.agentId), kind: .agent, size: 28)
            VStack(alignment: .leading, spacing: 5) {
                if model.renamingID == item.id { renameField(item) }
                else { Text(item.title).font(Theme.display(12, weight: .semibold)).lineLimit(1) }
                Text("\(toolName(item.record.agentId)) · \((item.record.cwdPath as NSString).abbreviatingWithTildeInPath)")
                    .font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text(item.record.lastActivity, style: .time).font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                status(item.status)
            }
        }.padding(10).contentShape(Rectangle())
            .background(model.selectedID == item.id ? ChatAppearance.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(model.selectedID == item.id ? ChatAppearance.accent.opacity(0.3) : .clear))
            .onTapGesture(count: 2) { activate(item) }
            .onTapGesture { model.select(item); focus = .list }
            .accessibilityElement(children: .contain).accessibilityLabel("\(item.title), \(item.status.title), \(toolName(item.record.agentId))")
            .accessibilityAction { model.select(item) }
            .contextMenu { contextMenu(item) }
    }

    private func renameField(_ item: AllSessionItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("Session name", text: $model.renameText).textFieldStyle(.roundedBorder)
                .focused($focus, equals: .rename(item.id)).disabled(model.savingName)
                .onSubmit { Task { await model.saveName(item) } }
            if let error = model.renameError { Text(error).font(.caption).foregroundStyle(ChatAppearance.failure) }
        }
    }

    private func preview(_ item: AllSessionItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Conversation preview", systemImage: "text.bubble").font(Theme.display(11))
                Spacer()
                Button { model.select(nil) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close preview")
            }
            Divider()
            Text(toolName(item.record.agentId)).font(.caption).foregroundStyle(ChatAppearance.secondary)
            if model.renamingID != item.id {
                Text(item.title).font(Theme.display(16, weight: .semibold)).onTapGesture(count: 2) { model.beginRename(item) }
            } else { Text("Edit the name in the list.").font(.caption).foregroundStyle(ChatAppearance.secondary) }
            Label((item.record.cwdPath as NSString).abbreviatingWithTildeInPath, systemImage: "folder").font(.caption).textSelection(.enabled)
            HStack { status(item.status); Text(item.record.lastActivity, style: .date).font(.caption).foregroundStyle(ChatAppearance.secondary) }
            ViewThatFits(in: .horizontal) {
                HStack { previewActions(item) }
                VStack(alignment: .leading) { previewActions(item) }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.previewLoading { ProgressView().controlSize(.small) }
                    else if ![AgentTemplate.claudeCodeID, AgentTemplate.codex.id].contains(item.record.agentId) {
                        Text("Preview isn't available for \(toolName(item.record.agentId)).").font(.caption).foregroundStyle(ChatAppearance.secondary)
                    } else if model.preview.isEmpty {
                        Text("No messages available in the local preview.").font(.caption).foregroundStyle(ChatAppearance.secondary)
                    } else {
                        Text("Last 3 messages").font(.caption).foregroundStyle(ChatAppearance.secondary)
                        ForEach(model.preview) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role == "user" ? "You" : toolName(item.record.agentId)).font(.caption.weight(.semibold))
                                Text(message.text).font(Theme.display(12)).textSelection(.enabled)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16).frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private func previewActions(_ item: AllSessionItem) -> some View {
        Button(primaryTitle(item)) { activate(item) }.buttonStyle(.borderedProminent)
        if !item.isLive { Button("Open in split") { activate(item, split: true) } }
    }
    @ViewBuilder private func contextMenu(_ item: AllSessionItem) -> some View {
        Button(primaryTitle(item)) { activate(item) }
        if !item.isLive { Button("Open in split") { activate(item, split: true) } }
        if case .external(let session) = item.source {
            Button("Move here") { if let store = owner() { ExternalSessionActions.takeOver(session, into: store) } }.disabled(!session.canTakeOver)
        }
        Button("Rename") { model.beginRename(item) }.disabled(!item.canRename)
        Button("Open folder") { NSWorkspace.shared.open(item.record.cwd) }
        if let file = item.record.fileURL { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
        Button("Copy conversation ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.record.conversationId, forType: .string) }.disabled(!item.canRename)
        Divider()
        if let key = ChatService.shared.connection?.orgKey, ChatAttention.personalAllowed(key, .shared) {
            TeamPublishMenu(sessionId: item.record.agentId == AgentTemplate.claudeCodeID ? item.record.conversationId : nil, title: item.title)
        } else { Button("Connect a team…") { ConnectionTabs.shared.show() } }
    }
    private func activate(_ item: AllSessionItem, split: Bool = false) {
        guard let store = owner() else { model.resumeError = "This window is no longer available."; return }
        model.resume { await AllSessionsActions.activate(item, model: model, store: store, split: split) }
    }
    private func primaryTitle(_ item: AllSessionItem) -> String {
        switch item.source { case .own: "Open tab"; case .external: "Focus"; case .disk: "Resume" }
    }
    private func status(_ status: AllSessionStatus) -> some View {
        let color = status == .needsInput ? ChatAppearance.attention : status == .error ? ChatAppearance.failure
            : status == .working ? ChatAppearance.accent : status == .finished ? ChatAppearance.success : ChatAppearance.secondary
        return HStack(spacing: 4) { Circle().fill(color).frame(width: 5, height: 5); Text(status.title).font(Theme.display(10)) }.foregroundStyle(color)
    }
    private func toolName(_ id: String) -> String { AgentTemplate.builtin(id: id)?.title ?? id }
    private func inlineError(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(ChatAppearance.failure).frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }
}

struct AllSessionsSidebarLink: View {
    let store: WorkspaceStore
    var body: some View {
        let count = SessionCatalog.shared.count(including: AllSessionsLive.snapshot())
        Button { SupportTabs.shared.navigation.open(.allSessions, from: store) } label: {
            HStack(spacing: 7) {
                Image(systemName: "clock")
                Text("All sessions")
                Text("· \(count)").monospacedDigit().foregroundStyle(ChatAppearance.secondary)
                Spacer(minLength: 0)
                Text("⌘⇧H").font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary)
            }.font(Theme.display(12, weight: .medium)).padding(9).contentShape(Rectangle())
        }.buttonStyle(.plain).background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 8).padding(.bottom, 8)
            .accessibilityLabel("All sessions").help("All sessions on this Mac (⌘⇧H)")
    }
}
