import Foundation
import Observation

enum AllSessionStatus: String, CaseIterable, Codable, Sendable {
    case working, needsInput, idle, finished, error
    var title: String {
        switch self { case .needsInput: "Needs input"; default: rawValue.capitalized }
    }
}

struct AllSessionsFilterState: Codable, Equatable, Hashable, Sendable {
    enum Period: String, CaseIterable, Codable, Sendable {
        case today, week, month, all
        var title: String {
            switch self { case .today: "Today"; case .week: "7 days"; case .month: "30 days"; case .all: "All time" }
        }
    }
    enum Grouping: String, CaseIterable, Codable, Sendable { case day, folder }
    var tool: String?
    var folder: String?
    var status: AllSessionStatus?
    var period: Period = .all
    var hideAutomatic = true
    var grouping: Grouping = .day
}

struct AllSessionItem: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable { case own(UUID), external(ExternalAgentSession), disk }
    var id: String
    var record: AgentSessionRecord
    var source: Source
    var status: AllSessionStatus
    var title: String
    var isLive: Bool { source != .disk }
    var critical: Bool { isLive && (status == .needsInput || status == .error) }
    var canRename: Bool { !record.conversationId.isEmpty }
}

enum AllSessionsList {
    struct Section: Identifiable, Equatable, Sendable { var id: String; var title: String; var items: [AllSessionItem] }
    struct Result: Equatable, Sendable {
        var sections: [Section] = []
        var total = 0
        var shown = 0
        var hiddenAutomatic = 0
        var tools: [String] = []
        var folders: [String] = []
        var items: [AllSessionItem] { sections.flatMap(\.items) }
    }

    static func filter(records: [AgentSessionRecord], live: [AllSessionItem], names: [SessionNameKey: String],
                       query: String, filters: AllSessionsFilterState, now: Date = Date(), calendar: Calendar = .current) -> Result {
        let byKey = Dictionary(records.map { ($0.nameKey, $0) }, uniquingKeysWith: { a, b in a.lastActivity >= b.lastActivity ? a : b })
        var liveKeys = Set<SessionNameKey>()
        var items = live.map { item in
            var item = item
            if item.canRename { liveKeys.insert(item.record.nameKey) }
            if let disk = byKey[item.record.nameKey] {
                let date = item.record.lastActivity
                item.record = disk; item.record.lastActivityOverride(date)
                item.title = disk.resolvedTitle(manual: names[disk.nameKey])
            } else { item.title = item.record.resolvedTitle(manual: names[item.record.nameKey]) }
            return item
        }
        items += records.filter { !liveKeys.contains($0.nameKey) }.map {
            AllSessionItem(id: "disk:" + $0.id, record: $0, source: .disk, status: .finished, title: $0.resolvedTitle(manual: names[$0.nameKey]))
        }
        var result = Result(total: items.count, tools: Set(items.map { $0.record.agentId }).sorted(), folders: Set(items.map { $0.record.cwdPath }).sorted())
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let days: Int?
        switch filters.period { case .all: days = nil; case .today: days = 0; case .week: days = 6; case .month: days = 29 }
        let start = days.flatMap { calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: now)) }
        result.hiddenAutomatic = filters.hideAutomatic ? items.filter { $0.record.automatic && !$0.critical }.count : 0
        items = items.filter { item in
            guard !Task.isCancelled,
                  filters.tool.map({ $0 == item.record.agentId }) ?? true,
                  filters.folder.map({ $0 == item.record.cwdPath }) ?? true,
                  filters.status.map({ $0 == item.status }) ?? true,
                  start.map({ item.record.lastActivity >= $0 }) ?? true,
                  !filters.hideAutomatic || !item.record.automatic || item.critical else { return false }
            if words.isEmpty { return true }
            let metadata = fold([item.title, names[item.record.nameKey] ?? "", item.record.agentTitle ?? "",
                                 item.record.summary ?? "", item.record.firstPrompt ?? "", item.record.cwdPath].joined(separator: "\n"))
            return words.allSatisfy { metadata.contains($0) }
        }
        items.sort { a, b in
            if filters.grouping == .folder && a.record.cwdPath != b.record.cwdPath { return a.record.cwdPath < b.record.cwdPath }
            if a.record.lastActivity != b.record.lastActivity { return a.record.lastActivity > b.record.lastActivity }
            if a.record.agentId != b.record.agentId { return a.record.agentId < b.record.agentId }
            if a.record.conversationId != b.record.conversationId { return a.record.conversationId < b.record.conversationId }
            return a.id < b.id
        }
        for item in items {
            let day = calendar.startOfDay(for: item.record.lastActivity)
            let key = filters.grouping == .folder ? item.record.cwdPath : String(day.timeIntervalSince1970)
            if result.sections.last?.id == key { result.sections[result.sections.count - 1].items.append(item) }
            else {
                let title = filters.grouping == .folder ? (item.record.cwdPath as NSString).abbreviatingWithTildeInPath
                    : calendar.isDate(item.record.lastActivity, inSameDayAs: now) ? "Today"
                    : DateFormatter.localizedString(from: day, dateStyle: .medium, timeStyle: .none)
                result.sections.append(.init(id: key, title: title, items: [item]))
            }
        }
        result.shown = items.count
        return result
    }
    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

@MainActor @Observable
final class AllSessionsModel {
    let state: TabState
    let catalog: SessionCatalog
    let names: SessionNames
    var query = ""
    var folderQuery = ""
    private(set) var result = AllSessionsList.Result()
    var selectedID: String?
    private(set) var preview: [SessionPreview.Message] = []
    private(set) var previewLoading = false
    var resumeError: String?
    var renamingID: String?
    var renameText = ""
    var renameError: String?
    var savingName = false
    @ObservationIgnored private var filtering: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private(set) var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var live: [AllSessionItem] = []
    @ObservationIgnored var visibility: @Sendable () -> ChannelConversationFilter = { .current() }
    @ObservationIgnored var filterWork: @Sendable ([AgentSessionRecord], [AllSessionItem], [SessionNameKey: String], String, AllSessionsFilterState) -> AllSessionsList.Result = {
        AllSessionsList.filter(records: $0, live: $1, names: $2, query: $3, filters: $4)
    }
    init(state: TabState, catalog: SessionCatalog = .shared, names: SessionNames = .shared) {
        self.state = state; self.catalog = catalog; self.names = names
    }
    var filters: AllSessionsFilterState {
        get { state.navigation.allSessions ?? .init() }
        set { state.navigation.allSessions = newValue; state.changed(); refilter() }
    }
    var selected: AllSessionItem? { result.items.first { $0.id == selectedID } }
    func start() async { catalog.refresh(); await names.load(); refilter() }
    func updateLive(_ value: [AllSessionItem]) { live = value; refilter() }
    func refilter(debounce: Bool = false) {
        filtering?.cancel()
        let records = catalog.records, live = live, names = names.values, query = query, filters = filters, work = filterWork, visibility = visibility
        filtering = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                let policy = visibility()
                return work(policy.apply(records), live.filter { policy.allows(agentId: $0.record.agentId, conversationId: $0.record.conversationId) }, names, query, filters)
            }
            let value = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, !Task.isCancelled, !state.isClosed else { return }
            let previous = selected
            result = value
            if let previous, selected == nil {
                // A terminated external process becomes its disk record without losing the preview.
                selectedID = value.items.first { $0.record.nameKey == previous.record.nameKey }?.id
            }
            if selected?.record.fileURL != previous?.record.fileURL { loadPreview() }
        }
    }
    func select(_ item: AllSessionItem?) { selectedID = item?.id; resumeError = nil; loadPreview() }
    func loadPreview() {
        previewTask?.cancel(); preview = []
        guard let record = selected?.record else { previewLoading = false; return }
        previewLoading = true
        previewTask = Task { [weak self] in
            let messages = await Task.detached(priority: .utility) { SessionPreview.read(record) }.value
            guard let self, !Task.isCancelled else { return }
            preview = messages; previewLoading = false
        }
    }
    func beginRename(_ item: AllSessionItem) {
        guard item.canRename else { return }
        renamingID = item.id; renameText = names.values[item.record.nameKey] ?? item.title; renameError = nil
    }
    func cancelRename() { guard !savingName else { return }; renamingID = nil; renameError = nil }
    func saveName(_ item: AllSessionItem) async {
        guard !savingName, renamingID == item.id else { return }
        savingName = true; defer { savingName = false }
        do { try await names.rename(renameText, for: item.record.nameKey); renamingID = nil; renameError = nil; refilter() }
        catch { renameError = "Session name could not be saved: \(error.localizedDescription)" }
    }
    func resume(_ operation: @escaping @MainActor () async -> Void) {
        guard !state.isClosed else { return }
        resumeTask?.cancel()
        resumeTask = Task { await operation() }
    }
    func stop() { filtering?.cancel(); previewTask?.cancel(); resumeTask?.cancel(); resumeTask = nil }
}

extension AgentSessionRecord {
    mutating func lastActivityOverride(_ date: Date) {
        self = AgentSessionRecord(agentId: agentId, conversationId: conversationId, title: title, cwd: cwd,
            lastActivity: max(lastActivity, date), agentTitle: agentTitle, summary: summary, firstPrompt: firstPrompt,
            automatic: automatic, startedAt: startedAt, fileURL: fileURL)
    }
}
