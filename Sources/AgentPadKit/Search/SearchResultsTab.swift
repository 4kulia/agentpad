import AppKit
import SwiftUI
import GRDB

enum SearchDatePeriod: String, CaseIterable {
    case all = "All time", today = "Today", week = "7 days", month = "30 days", custom = "Custom range"
    func range(now: Date, first: Date, last: Date, calendar: Calendar = .current) -> (Date?, Date?) {
        if self == .all { return (nil, nil) }
        if self == .custom { let range = LocalSearchFilter.dayRange(first, last, calendar: calendar); return (range.0, range.1) }
        let days = self == .today ? 0 : self == .week ? 6 : 29
        return (calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)), calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
    }
}

struct SearchResultsTab: View {
    @Bindable var model: EverywhereSearchModel
    let state: TabState
    let store: WorkspaceStore
    @State private var resuming = false
    private var org: ChatOrgModel? { ChatOrgCurrent.shared.model }
    private var channels: [ChatSidebarSnapshot.Channel] { ChatSidebarSnapshot(model: org, active: nil).teams.flatMap(\.channels) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let record = model.selectedRecord { history(record) }
            else {
                header
                filters
                Divider()
                results
            }
            Divider()
            HStack {
                Label("Agent conversations are indexed only on this Mac and never uploaded.", systemImage: "lock")
                Spacer(); Text(model.selectedRecord == nil ? "Newest first" : "Local history · Read only")
            }.font(.caption).foregroundStyle(ChatAppearance.secondary).padding(12)
        }.background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground).tint(ChatAppearance.accent)
            .onKeyPress(characters: CharacterSet(charactersIn: "f")) { press in
                guard press.modifiers == .command else { return .ignored }; model.focusRequest += 1; return .handled
            }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(ChatAppearance.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Search results").font(Theme.display(20, weight: .semibold))
                Text(model.query.isEmpty ? "Type in Search everywhere above." : "Results for “\(model.query)”").font(.caption).foregroundStyle(ChatAppearance.secondary).lineLimit(2)
            }
            Spacer()
            Button { model.update(debounce: false); Task { await model.indexing.index.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("Refresh search")
        }.padding(20)
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Source", selection: $model.source) {
                    Text("All").tag(SearchSource.all)
                    if model.hasTeam { Text("Messages").tag(SearchSource.messages) }
                    Text("Agent sessions").tag(SearchSource.sessions)
                }.pickerStyle(.segmented).frame(maxWidth: 360)
                Spacer()
                Picker("Date", selection: $model.period) { ForEach(SearchDatePeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.fixedSize()
                Button("Clear filters") {
                    model.source = .all; model.period = .all; model.filter = .init(); model.scope = .all; model.target = nil; model.person = nil; model.update()
                }.buttonStyle(.plain).font(.caption)
            }
            if model.period == .custom {
                HStack {
                    DatePicker("From", selection: $model.firstDay, displayedComponents: .date)
                    DatePicker("Through", selection: $model.lastDay, in: model.firstDay..., displayedComponents: .date)
                    Text("Mac time zone").font(.caption).foregroundStyle(ChatAppearance.secondary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { sourceFilters }
                VStack(alignment: .leading, spacing: 10) { sourceFilters }
            }
        }.padding(.horizontal, 20).padding(.bottom, 16)
            .onChange(of: model.source) { _, _ in model.update() }
            .onChange(of: model.filter) { _, _ in model.update() }
            .onChange(of: model.period) { _, _ in dateChanged() }
            .onChange(of: model.firstDay) { _, _ in dateChanged() }
            .onChange(of: model.lastDay) { _, _ in dateChanged() }
            .onChange(of: model.person) { _, _ in model.serverSearch(debounce: true) }
    }
    @ViewBuilder private var sourceFilters: some View {
        if model.hasTeam, model.source != .sessions {
            Picker("Place", selection: Binding(get: { model.scope.rawValue + ":" + (model.target ?? "") }, set: { value in
                let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                model.scope = ChatSearchRequest.Scope(rawValue: String(parts[0])) ?? .all
                model.target = parts.count == 2 && !parts[1].isEmpty ? String(parts[1]) : nil
                model.serverSearch(debounce: true)
            })) {
                Text("All places").tag("all:"); Text("All channels").tag("channel:"); Text("All direct messages").tag("dm:")
                ForEach(channels) { Text("# " + $0.card.name).tag("channel:" + $0.id) }
                if let key = ChatService.shared.connection?.orgKey, ChatService.shared.dmAllowed(key), let list = ChatService.shared.dmList(key) {
                    ForEach(list.entries) { Text("DM · " + $0.card.peer.name).tag("dm:" + $0.id) }
                }
            }.frame(maxWidth: 240)
            Picker("Person", selection: $model.person) {
                Text("Anyone").tag(nil as String?)
                ForEach(org?.members ?? []) { Text($0.name).tag(Optional($0.accountId)) }
            }.frame(maxWidth: 210)
        }
        if model.source != .messages {
            Picker("Agent type", selection: $model.filter.agent) {
                Text("All agents").tag(nil as String?)
                ForEach(AgentSessionScanner.supportedAgentIds.sorted(), id: \.self) { id in Text(AgentTemplate.builtin(id: id)?.title ?? id).tag(Optional(id)) }
            }.frame(maxWidth: 220)
            Picker("Folder", selection: $model.filter.folder) {
                Text("All folders").tag(nil as String?)
                ForEach(Set(model.catalog.records.map(\.cwdPath)).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }.frame(maxWidth: 280)
        }
    }
    private func dateChanged() {
        let range = model.period.range(now: Date(), first: model.firstDay, last: max(model.firstDay, model.lastDay))
        model.filter.from = range.0; model.filter.to = range.1
    }
    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let error = model.navigationError { Text(error).foregroundStyle(ChatAppearance.failure).padding(10) }
                if !model.hasTeam {
                    HStack {
                        Text("Local results only.").foregroundStyle(ChatAppearance.secondary)
                        Button("Connect a team…") { ConnectionTabs.shared.show() }
                    }.font(.caption)
                }
                if model.hasTeam, model.source != .sessions { messageResults }
                if model.source != .messages { localResults }
                if model.query.isEmpty { Text("Search session names, messages and saved conversations.").foregroundStyle(ChatAppearance.secondary).padding(.vertical, 30) }
                else if (try? SearchQuery(model.query)) == nil { Text(SearchProblem.invalidQuery.localizedDescription).foregroundStyle(ChatAppearance.secondary) }
            }.scrollTargetLayout().padding(20)
        }.scrollPosition(id: $model.scrollID)
    }
    @ViewBuilder private var messageResults: some View {
        groupHeading("Messages", count: model.messages.hits.count)
        if model.messages.loadedHistoryOnly { Label("Loaded history only", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(ChatAppearance.attention) }
        if let error = model.messages.error {
            HStack { Text("Partial results · " + error).font(.caption); Button("Retry") { model.serverSearch(debounce: false) } }
        } else if let notice = model.messages.availability().message {
            Text(notice).font(.caption).foregroundStyle(ChatAppearance.secondary)
            if model.messages.availability() == .unsupported { Button("Search loaded history") { loadedHistory() } }
            else if model.messages.availability() == .offline { Button("Retry") { model.serverSearch(debounce: false) } }
        }
        if model.messages.loading { ProgressView().controlSize(.small) }
        ForEach(model.messages.hits) { hit in
            Button { model.openMessage(hit) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(messagePlace(hit), systemImage: hit.kind == .dm ? "person.2" : "number").font(.caption.weight(.medium))
                        Text(org?.members.first { $0.accountId == hit.authorAccountID }?.name ?? "Member").font(.caption).foregroundStyle(ChatAppearance.secondary)
                        if hit.threadRootID != nil { Text("Thread reply").font(.caption).foregroundStyle(ChatAppearance.secondary) }
                        Spacer(); date(hit.createdAt.flatMapDate)
                    }
                    SearchSnippetText(text: hit.snippet, query: model.query)
                }.resultCard()
            }.buttonStyle(.plain).id("m:" + hit.id)
        }
        if model.messages.next != nil { Button("Load more messages") { model.messages.search(model.serverRequest, more: true, debounce: false) }.disabled(model.messages.loading) }
        if model.messages.availability() == .ready, !model.messages.loading, model.messages.error == nil, model.messages.hits.isEmpty, (try? SearchQuery(model.query)) != nil {
            Text("No matching messages.").font(.caption).foregroundStyle(ChatAppearance.secondary)
        }
    }
    @ViewBuilder private var localResults: some View {
        groupHeading("Agent sessions", count: model.local.count + model.metadata.count)
        Text("Claude Code and Codex: conversation text · Other agents: names, first prompts and folders").font(.caption).foregroundStyle(ChatAppearance.secondary)
        SearchIndexNotice(controller: model.indexing)
        if model.localLoading { ProgressView().controlSize(.small) }
        if let error = model.localError { Text(error).font(.caption).foregroundStyle(ChatAppearance.failure) }
        ForEach(model.local) { hit in
            Button { model.show(hit) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(hit.record.resolvedTitle(manual: model.names.values[hit.record.nameKey])).font(Theme.display(13, weight: .semibold)).lineLimit(1)
                        Spacer(); date(hit.turn.date)
                    }
                    SearchSnippetText(text: hit.turn.text, query: model.query)
                    Text("\(tool(hit.record.agentId)) · Turn \(hit.turn.ordinal) · \(hit.record.cwdPath)\(hit.record.automatic ? " · Automatic" : "")").font(.caption).foregroundStyle(ChatAppearance.secondary).lineLimit(1)
                    if hit.turn.truncated { Text("Turn text truncated · Partial results").font(.caption).foregroundStyle(ChatAppearance.attention) }
                }.resultCard()
            }.buttonStyle(.plain).id("l:" + hit.id)
        }
        if model.localNext != nil { Button("Load more session matches") { model.localSearch(more: true, debounce: false) }.disabled(model.localLoading) }
        ForEach(model.metadata) { record in
            Button { model.selectedRecord = record; model.selectedHit = nil; model.context = []; model.navigationError = nil } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.resolvedTitle(manual: model.names.values[record.nameKey])).font(Theme.display(13, weight: .medium))
                    Text("Metadata match · \(tool(record.agentId)) · \(record.cwdPath)").font(.caption).foregroundStyle(ChatAppearance.secondary).lineLimit(1)
                }.resultCard()
            }.buttonStyle(.plain).id("d:" + record.id)
        }
        if model.metadata.count == model.metadataLimit { Button("Load more metadata matches") { model.metadataLimit += 20; model.localSearch(debounce: false) } }
        if !model.localLoading, model.local.isEmpty, model.metadata.isEmpty, model.indexing.status.state.enabled,
           !model.indexing.status.partial, !model.indexing.status.scanning, !model.indexing.status.state.paused,
           model.localError == nil, (try? SearchQuery(model.query)) != nil {
            Text("No matching sessions in the available index.").font(.caption).foregroundStyle(ChatAppearance.secondary)
        }
    }
    private func history(_ record: AgentSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { model.selectedRecord = nil; model.selectedHit = nil; model.context = []; model.navigationError = nil } label: { Label("Back to results", systemImage: "arrow.left") }
                Spacer()
                Button(resumeTitle(record)) { resume(record) }.buttonStyle(.borderedProminent).disabled(resuming)
            }
            Text(record.resolvedTitle(manual: model.names.values[record.nameKey])).font(Theme.display(22, weight: .semibold))
            Text("\(tool(record.agentId)) · \(record.cwdPath)\(record.automatic ? " · Automatic" : "")").font(.caption).foregroundStyle(ChatAppearance.secondary).textSelection(.enabled)
            if let error = model.navigationError { Text(error).foregroundStyle(ChatAppearance.failure) }
            if model.contextLoading { ProgressView().controlSize(.small) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.selectedHit == nil {
                            Text("Metadata match. Choose a text match to open a saved turn. Conversation text is available for Claude Code and Codex.")
                                .foregroundStyle(ChatAppearance.secondary).padding(.vertical, 20)
                        }
                        ForEach(model.context) { turn in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(turn.role == "user" ? "You" : tool(record.agentId)).font(.caption.weight(.semibold))
                                    Text("Turn \(turn.ordinal)").font(.caption).foregroundStyle(ChatAppearance.secondary)
                                    Spacer(); date(turn.date)
                                }
                                Text(turn.text).font(Theme.display(13)).textSelection(.enabled)
                                if turn.truncated { Text("Only the first 64 KiB of this turn are shown.").font(.caption) }
                            }.resultCard()
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(turn.id == model.selectedHit?.turn.id ? ChatAppearance.accent : .clear, lineWidth: 2))
                                .id(turn.id)
                        }
                    }.padding(2)
                }.onChange(of: model.context) { _, _ in if let id = model.selectedHit?.turn.id { proxy.scrollTo(id, anchor: .center) } }
            }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func resumeTitle(_ record: AgentSessionRecord) -> String {
        switch AllSessionsLive.snapshot().first(where: { $0.record.nameKey == record.nameKey })?.source {
        case .own: "Go to live session"
        case .external: "Focus"
        default: "Resume session"
        }
    }
    private func resume(_ record: AgentSessionRecord) {
        resuming = true
        let helper = AllSessionsModel(state: state)
        let item = AllSessionsLive.snapshot().first { $0.record.nameKey == record.nameKey }
            ?? AllSessionItem(id: record.id, record: record, source: .disk, status: .finished, title: record.resolvedTitle())
        Task { await AllSessionsActions.activate(item, model: helper, store: store); model.navigationError = helper.resumeError; resuming = false }
    }
    private func loadedHistory() {
        guard let key = ChatService.shared.connection?.orgKey, ChatAttention.personalAllowed(key, .shared), let cache = ChatService.shared.orgSessions[key]?.store else { return }
        let channelIDs = channels.map(\.id)
        let dmIDs = ChatService.shared.dmAllowed(key) ? ChatService.shared.dmList(key)?.entries.map(\.id) ?? [] : []
        let request = model.serverRequest, connection = ChatService.shared.connection
        Task {
            let hits = await Task.detached(priority: .utility) { () -> [ChatSearchHit] in
                (try? SearchCache.read(cache.queue) { db in
                    var messages: [ChatMessage] = []
                    for channel in channelIDs { messages += try Row.fetchAll(db, sql: "\(ChatMessages.select) WHERE m.channel_id=?", arguments: [channel]).map(ChatMessage.init(row:)) }
                    for dm in dmIDs { messages += try ChatDMStore.messages(db, dm) }
                    return SearchLoadedHistory.matches(messages, request: request)
                }) ?? []
            }.value
            guard ChatService.shared.connection == connection, ChatAttention.personalAllowed(key, .shared), model.serverRequest == request else { return }
            model.messages.useLoadedHistory(hits, key: key, store: cache, allowed: {
                ChatService.shared.connection == connection && ChatAttention.personalAllowed(key, .shared)
                    && channelIDs.allSatisfy { ChatNotifications.allowed(.shared, key, channel: $0) }
                    && dmIDs.allSatisfy { ChatService.shared.dmAllowed(key, $0) }
            })
        }
    }
    private func messagePlace(_ hit: ChatSearchHit) -> String {
        if hit.kind == .channel { return channels.first { $0.id == hit.targetID }?.card.name ?? "Channel" }
        if let key = ChatService.shared.connection?.orgKey, ChatService.shared.dmAllowed(key, hit.targetID) {
            return ChatService.shared.dmList(key)?.entries.first { $0.id == hit.targetID }?.card.peer.name ?? "Direct message"
        }
        return "Direct message"
    }
    private func groupHeading(_ title: String, count: Int) -> some View {
        HStack { Text(title).font(Theme.display(15, weight: .semibold)); Spacer(); Text("Loaded \(count)").font(.caption).foregroundStyle(ChatAppearance.secondary) }.padding(.top, 10)
    }
    private func date(_ value: Date?) -> some View {
        Text(value.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "Time unavailable").font(.caption).foregroundStyle(ChatAppearance.secondary)
    }
    private func tool(_ id: String) -> String { AgentTemplate.builtin(id: id)?.title ?? id }
}

private extension View {
    func resultCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.chromeSeparator)).contentShape(Rectangle())
    }
}
private extension String { var flatMapDate: Date? { ChatStore.date(self) } }
