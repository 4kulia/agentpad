import AppKit
import SwiftUI

/// The agents page as one list: our own agent tabs, live Claude Code sessions
/// in other terminals, and recent conversations on disk — grouped by what
/// they need from you (or by project), searchable from the top.
struct UnifiedSessionsView: View {
    let store: WorkspaceStore
    let showTags: Bool
    var monitor = AgentMonitor.shared
    var external = ExternalSessionMonitor.shared
    var history = AgentSessionHistory.shared

    @State private var query = ""
    @AppStorage("agentpad.sessions.groupByProject") private var groupByProject = false

    /// Recent conversations shown without a search; a search looks through all of them.
    static let recentLimit = 30
    static let searchLimit = 200

    var body: some View {
        let own = monitor.entries
        let ext = external.sessions
        // History is newest-first and can hold thousands of records; without
        // a search only the head can ever be shown, so don't touch the rest.
        let historyWindow = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? Array(history.records.prefix(Self.recentLimit + own.count + ext.count))
            : history.records
        let items = SessionListModel.items(own: own, external: ext, history: historyWindow)
        let filtered = SessionListModel.filter(items, query: query, recentLimit: Self.recentLimit, searchLimit: Self.searchLimit)
        let sections = groupByProject ? SessionListModel.byProject(filtered) : SessionListModel.byStatus(filtered)
        let liveCount = items.filter { $0.group != .recent }.count

        VStack(spacing: 0) {
            RightPanelHeader(title: "sessions", count: liveCount) {
                HoverableIconButton(
                    systemName: groupByProject ? "folder" : "list.bullet",
                    fontSize: 11,
                    size: 22,
                    help: groupByProject ? "Grouped by project — click to group by status" : "Grouped by status — click to group by project"
                ) { groupByProject.toggle() }
            }
            searchField
            // AgentPad: team requests waiting for a decision, above everything.
            TeamPanelSection()
            if sections.isEmpty {
                PanelEmptyState(
                    symbol: query.isEmpty ? "sparkles" : "magnifyingglass",
                    message: query.isEmpty ? "no sessions yet" : "nothing matches"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(sections) { section in
                            SessionSectionLabel(title: section.title, count: section.items.count)
                            ForEach(section.items) { item in row(item) }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { history.refresh() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.chromeMuted)
            TextField("Search sessions", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.display(12))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.chromeMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.chromeHover))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func row(_ item: SessionListItem) -> some View {
        switch item.kind {
        case .own(let entry):
            AgentOverviewRow(entry: entry, showTags: showTags)
                .onTapGesture {
                    ExternalTreeRoot.for(store).clear()
                    monitor.onActivate(entry.id)
                }
                .contextMenu {
                    TeamPublishMenu(
                        sessionId: (entry.agent.id == AgentTemplate.claudeCodeID || entry.agent.baseAgentId == AgentTemplate.claudeCodeID)
                            ? entry.conversationId : nil,
                        title: entry.tabTitle
                    )
                }
        case .external(let session):
            ExternalSessionRow(
                session: session,
                isTakingOver: external.takingOver.contains(session.id),
                onFocus: { ExternalSessionActions.focus(session) },
                onTakeOver: { ExternalSessionActions.takeOver(session, into: store) },
                onShowFiles: {
                    if store.sidebarMode != .full { store.setSidebarMode(.full) }
                    store.sidebarContent = .files
                    ExternalTreeRoot.for(store).show(session)
                }
            )
        case .recent(let record):
            RecentSessionRow(record: record) { resume(record) }
                .contextMenu {
                    TeamPublishMenu(
                        sessionId: record.agentId == AgentTemplate.claudeCodeID ? record.conversationId : nil,
                        title: record.title
                    )
                }
        }
    }

    private func resume(_ record: AgentSessionRecord) {
        if case .failure(let refusal) = store.resumeAgentSession(record) {
            ExternalSessionActions.showAlert(
                title: "Couldn't resume the conversation",
                message: refusal.message(agentId: record.agentId, conversationId: record.conversationId)
            )
        }
    }
}

// MARK: - Model

struct SessionListItem: Identifiable {
    enum Kind {
        case own(AgentMonitor.Entry)
        case external(ExternalAgentSession)
        case recent(AgentSessionRecord)
    }

    enum Group: Int, Comparable {
        case needsYou, running, idle, recent

        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .needsYou: return "Needs you"
            case .running: return "Running"
            case .idle: return "Idle"
            case .recent: return "Recent"
            }
        }
    }

    let id: String
    let kind: Kind
    let group: Group
    let title: String
    let directory: URL
    /// Newest activity first within a group; for "needs you", oldest first.
    let date: Date?

    var searchText: String {
        "\(title)\n\(directory.path)"
    }
}

/// Pure list logic, separate from the view so it can be tested.
enum SessionListModel {
    struct Section: Identifiable {
        let id: String
        let title: String
        let items: [SessionListItem]
    }

    static func group(for state: AgentMonitor.State) -> SessionListItem.Group {
        switch state {
        case .attention, .failed: return .needsYou
        case .running: return .running
        case .idle: return .idle
        }
    }

    /// Own tabs keep `AgentMonitor`'s order; external sessions keep the
    /// monitor's order; recent conversations exclude anything alive.
    static func items(
        own: [AgentMonitor.Entry],
        external: [ExternalAgentSession],
        history: [AgentSessionRecord]
    ) -> [SessionListItem] {
        var live = Set<String>()
        var result: [SessionListItem] = []
        for entry in own {
            if let id = entry.conversationId { live.insert(id) }
            result.append(SessionListItem(
                id: "own:\(entry.id.uuidString)",
                kind: .own(entry),
                group: group(for: entry.state),
                title: entry.tabTitle,
                directory: entry.directory,
                date: nil
            ))
        }
        for session in external {
            live.insert(session.sessionId)
            result.append(SessionListItem(
                id: "ext:\(session.id)",
                kind: .external(session),
                group: group(for: session.monitorState),
                title: session.displayTitle,
                directory: session.cwd,
                date: session.statusSince
            ))
        }
        for record in history where !live.contains(record.conversationId) {
            result.append(SessionListItem(
                id: "rec:\(record.id)",
                kind: .recent(record),
                group: .recent,
                title: record.title,
                directory: record.cwd,
                date: record.lastActivity
            ))
        }
        return result
    }

    /// Without a query: every live item plus the newest `recentLimit` recent
    /// ones. With a query: case- and diacritic-insensitive match on title and
    /// path, all words required, recent capped at `searchLimit`.
    static func filter(_ items: [SessionListItem], query: String, recentLimit: Int, searchLimit: Int) -> [SessionListItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = words.isEmpty ? items : items.filter { item in
            words.allSatisfy { item.searchText.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        let live = matching.filter { $0.group != .recent }
        let recent = matching.filter { $0.group == .recent }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(words.isEmpty ? recentLimit : searchLimit)
        return live + recent
    }

    /// Stable order inside a group: the input order (each source already sorts
    /// its own items), own tabs before external sessions.
    static func byStatus(_ items: [SessionListItem]) -> [Section] {
        let groups: [SessionListItem.Group] = [.needsYou, .running, .idle, .recent]
        return groups.compactMap { group in
            let members = items.filter { $0.group == group }
            guard !members.isEmpty else { return nil }
            return Section(id: "status:\(group.rawValue)", title: group.title, items: members)
        }
    }

    /// One section per folder, the folder needing you most (then most recently
    /// active) first; inside a folder, by status.
    static func byProject(_ items: [SessionListItem]) -> [Section] {
        let grouped = Dictionary(grouping: items) { $0.directory.standardizedFileURL.path }
        let sections = grouped.map { path, members -> (Section, SessionListItem.Group, Date) in
            let sorted = members.enumerated().sorted { a, b in
                a.element.group != b.element.group ? a.element.group < b.element.group : a.offset < b.offset
            }.map(\.element)
            let best = sorted.first?.group ?? .recent
            let latest = members.compactMap(\.date).max() ?? .distantPast
            let title = (path as NSString).abbreviatingWithTildeInPath
            return (Section(id: "project:\(path)", title: title, items: sorted), best, latest)
        }
        return sections.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 > b.2 }
            return a.0.id < b.0.id
        }.map(\.0)
    }
}

// MARK: - Recent row

private struct RecentSessionRow: View {
    let record: AgentSessionRecord
    let onResume: () -> Void
    @State private var isHovered = false

    var body: some View {
        let agent = AgentTemplate.builtin(id: record.agentId)
        HStack(spacing: 10) {
            AgentIconView(
                asset: agent?.iconAsset ?? AgentTemplate.claudeCode.iconAsset,
                fallbackSymbol: agent?.symbol ?? AgentTemplate.claudeCode.symbol,
                size: 16
            )
            .opacity(0.6)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.title.isEmpty ? "untitled" : record.title)
                    .font(Theme.display(12.5))
                    .foregroundStyle(Theme.chromeForeground.opacity(0.85))
                    .lineLimit(1)
                Text((record.cwdPath as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            if isHovered {
                Text("resume")
                    .font(Theme.display(10, weight: .medium))
                    .foregroundStyle(Theme.chromeForeground)
            } else {
                Text(relativeActivityLabel(record.lastActivity))
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.75))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Theme.sidebarRowVerticalPadding)
        .background(isHovered ? Theme.chromeHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chromeSelectionCornerRadius, style: .continuous))
        .padding(.horizontal, Theme.space2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onResume)
        .help("\(singleLine(record.title))\n\(record.cwdPath)\nClick to resume in a new tab")
    }
}
