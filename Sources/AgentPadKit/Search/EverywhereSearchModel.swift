import Foundation
import Observation

enum SearchSource: String, CaseIterable, Sendable { case all = "All", messages = "Messages", sessions = "Agent sessions" }

@MainActor @Observable
final class SearchIndexController {
    static let shared = SearchIndexController()
    let index: ConversationIndex
    private(set) var status = SearchIndexStatus()
    private(set) var actionError: String?
    @ObservationIgnored private var polling: Task<Void, Never>?
    init(index: ConversationIndex = .shared) { self.index = index }
    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let index = self?.index else { return }
                let status = await index.snapshot()
                self?.status = status
                if status.state.enabled && !status.state.paused && !status.scanning { Task { await index.refresh() } }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    deinit { polling?.cancel() }
    func updateStatus() async { status = await index.snapshot() }
    func enable(rebuild: Bool = false) async {
        guard await action({ try await self.index.enable(rebuild: rebuild) }) else { return }
        Task { await index.refresh(force: true) }
    }
    func disable() async { await action { try await self.index.disable() } }
    func clear() async { await action { try await self.index.clear() } }
    func pause(_ value: Bool) async { await action { try await self.index.pause(value) } }
    @discardableResult private func action(_ work: () async throws -> Void) async -> Bool {
        actionError = nil
        let succeeded: Bool
        do { try await work(); succeeded = true } catch { actionError = error.localizedDescription; succeeded = false }
        status = await index.snapshot()
        return succeeded
    }
}

@MainActor @Observable
final class EverywhereSearchModel {
    var query = "" {
        didSet {
            if query != oldValue { focusState.queryChanged(isEmpty: query.isEmpty) }
        }
    }
    var source = SearchSource.all
    var filter = LocalSearchFilter()
    var scope = ChatSearchRequest.Scope.all
    var target: String?
    var person: String?
    private var focusState = SearchSuggestionsState()
    var suggestions: Bool { focusState.visible }
    var fieldFocused: Bool { focusState.fieldFocused }
    var focusRequest: Int { focusState.focusRequest }
    @ObservationIgnored let fieldFocus = SearchFieldFocus()
    var selected: String?
    var scrollID: String?
    var returnAvailable = false
    var period = SearchDatePeriod.all
    var firstDay = Date()
    var lastDay = Date()
    var metadataLimit = 20
    var quick: [PaletteItem] {
        access(keyPath: \.quick)
        let query = query
        if let quickMatches, quickMatches.query == query { return quickMatches.items }
        if allowedQuickIndex == nil {
            allowedQuickIndex = withObservationTracking {
                let allowed = quickAllowedIDs(quickIndex)
                return quickIndex.filter { allowed.contains($0.id) }
            } onChange: { [weak self] in
                // All permission/window dependencies are MainActor state. Drop
                // both caches synchronously, before another read or activation.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.withMutation(keyPath: \.quick) {
                        self.allowedQuickIndex = nil; self.quickMatches = nil
                    }
                }
            }
        }
        let items = matchQuick(query, allowedQuickIndex ?? [])
        quickMatches = (query, items)
        return items
    }
    private var quickIndex: [PaletteItem] = []
    @ObservationIgnored private var allowedQuickIndex: [PaletteItem]?
    @ObservationIgnored private var quickMatches: (query: String, items: [PaletteItem])?
    private var localStorage: [LocalSearchHit] = []
    private(set) var local: [LocalSearchHit] {
        get { indexing.status.state.enabled ? localStorage.filter { $0.epoch == indexing.status.state.epoch } : [] }
        set { localStorage = newValue }
    }
    private(set) var metadata: [AgentSessionRecord] = []
    private(set) var localNext: LocalSearchCursor?
    private(set) var localLoading = false
    var localError: String?
    var selectedHit: LocalSearchHit?
    var selectedRecord: AgentSessionRecord?
    var context: [ConversationTurn] = []
    var contextLoading = false
    var navigationError: String?
    let messages: ChatSearchModel
    let indexing: SearchIndexController
    let catalog: SessionCatalog
    let names: SessionNames
    @ObservationIgnored let visibility: @Sendable () -> ChannelConversationFilter
    @ObservationIgnored var quickItems: @Sendable () -> [PaletteItem] = { [] }
    var quickAllowedIDs: ([PaletteItem]) -> Set<String> = { Set($0.map(\.id)) }
    @ObservationIgnored var matchQuick: (String, [PaletteItem]) -> [PaletteItem] = { PaletteIndex.match(query: $0, in: $1, limit: 6) }
    @ObservationIgnored var activateQuick: (PaletteItem) -> Void = { _ in }
    @ObservationIgnored var openResults: () -> Void = {}
    @ObservationIgnored var openMessage: (ChatSearchHit) -> Void = { _ in }
    @ObservationIgnored private var localTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var quickTask: Task<Void, Never>?
    @ObservationIgnored private var serial = UUID()
    init(messages: ChatSearchModel = ChatSearchModel(), indexing: SearchIndexController = .shared,
         catalog: SessionCatalog = .shared, names: SessionNames = .shared,
         visibility: @escaping @Sendable () -> ChannelConversationFilter = { .current() }) {
        self.messages = messages; self.indexing = indexing; self.catalog = catalog; self.names = names
        self.visibility = visibility
        messages.onInvalidation = { [weak self] in self?.serverSearch(debounce: true) }
        observeIndex(); indexing.start()
    }
    var hasTeam: Bool { messages.availability() != .noTeam }
    var serverRequest: ChatSearchRequest {
        .init(query: query, scope: scope, targetID: target, authorAccountID: person,
              from: filter.from.map { ISO8601DateFormatter().string(from: $0) }, to: filter.to.map { ISO8601DateFormatter().string(from: $0) })
    }
    func connectionChanged() {
        messages.invalidate(); scope = .all; target = nil; person = nil
        if !hasTeam, source == .messages { source = .all }
        update()
    }
    func begin() {
        if !focusState.requested {
            quickTask?.cancel(); quickIndex = []
            let build = quickItems
            quickTask = Task { [weak self] in
                let items = await Task.detached(priority: .utility, operation: build).value
                guard !Task.isCancelled else { return }
                self?.quickIndex = items
            }
        }
        indexing.start(); catalog.refresh(); Task { await indexing.index.refresh() }
        Task { await names.load(); update() }
        focusState.requestFocus(); update()
        fieldFocus.field?.focusIfRequested()
    }
    func toggle() {
        if suggestions { dismiss() }
        else { begin() }
    }
    func updateFieldFocus(ownsFirstResponder: Bool, isKeyWindow: Bool) {
        focusState.updateFocus(ownsFirstResponder: ownsFirstResponder, isKeyWindow: isKeyWindow)
        if !fieldFocused { selected = nil }
    }
    func dismiss(restoreFocus: Bool = true) {
        focusState.dismiss(); selected = nil
        if restoreFocus { fieldFocus.field?.endSearchEditing() }
    }
    func update(debounce: Bool = true) {
        selected = nil; scrollID = nil
        localSearch(debounce: debounce); serverSearch(debounce: debounce)
    }
    func serverSearch(debounce: Bool) {
        guard source != .sessions, (try? SearchQuery(query)) != nil else { messages.invalidate(); return }
        messages.search(serverRequest, debounce: debounce)
    }
    func localSearch(more: Bool = false, debounce: Bool = true) {
        localTask?.cancel(); serial = UUID(); let id = serial
        if !more { local = []; metadata = []; localNext = nil }
        localError = nil
        guard source != .messages, let parsed = try? SearchQuery(query) else { localLoading = false; return }
        let index = indexing.index, filter = filter, cursor = more ? localNext : nil
        let records = catalog.records, names = names.values, metadataLimit = metadataLimit, visibility = visibility
        localLoading = true
        localTask = Task { [weak self] in
            guard let self else { return }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(150)) }
                let result = try await index.search(parsed, filter: filter, cursor: cursor)
                let metadata = await Task.detached(priority: .utility) {
                    let policy = visibility()
                    return Self.metadataMatches(records: policy.apply(records), names: names, query: parsed.text, filter: filter, limit: metadataLimit)
                }.value
                guard !Task.isCancelled, serial == id else { return }
                let state = await index.snapshot()
                guard serial == id, result.hits.allSatisfy({ $0.epoch == state.state.epoch }) else { return }
                let old = Set(local.map(\.id)); local += result.hits.filter { !old.contains($0.id) }; localNext = result.next
                self.metadata = metadata; localLoading = false
            } catch {
                guard serial == id, !Task.isCancelled else { return }; localLoading = false; localError = error.localizedDescription
            }
        }
    }
    nonisolated static func metadataMatches(records: [AgentSessionRecord], names: [SessionNameKey: String], query: String, filter: LocalSearchFilter, limit: Int = 20) -> [AgentSessionRecord] {
        guard filter.from == nil, filter.to == nil else { return [] }
        var filters = AllSessionsFilterState(); filters.hideAutomatic = false; filters.tool = filter.agent; filters.folder = nil
        let records = records.filter { record in filter.normalizedFolder.map { $0 == record.cwd.standardizedFileURL.resolvingSymlinksInPath().path } ?? true }
        return Array(AllSessionsList.filter(records: records, live: [], names: names, query: query, filters: filters).items.prefix(limit).map(\.record))
    }
    var choices: [String] {
        quick.map { "q:" + $0.id } + messages.hits.prefix(3).map { "m:" + $0.id } + local.prefix(3).map { "l:" + $0.id } + metadata.prefix(3).map { "d:" + $0.id }
    }
    func move(_ delta: Int) {
        let values = choices; guard !values.isEmpty else { selected = nil; return }
        let position = selected.flatMap { values.firstIndex(of: $0) } ?? (delta > 0 ? -1 : values.count)
        selected = values[min(values.count - 1, max(0, position + delta))]
    }
    func activate(_ id: String? = nil) {
        let id = id ?? selected
        dismiss()
        if let item = quick.first(where: { "q:" + $0.id == id }) { activateQuick(item) }
        else if let item = messages.hits.first(where: { "m:" + $0.id == id }) { openMessage(item) }
        else if let item = local.first(where: { "l:" + $0.id == id }) { show(item); openResults() }
        else if let item = metadata.first(where: { "d:" + $0.id == id }) { selectedHit = nil; selectedRecord = item; context = []; openResults() }
        else { showResults() }
    }
    func showResults() { dismiss(); selectedHit = nil; selectedRecord = nil; openResults() }
    func show(_ hit: LocalSearchHit) {
        historyTask?.cancel(); selectedHit = hit; selectedRecord = hit.record; context = []; navigationError = nil; contextLoading = true
        historyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let turns = try await indexing.index.context(hit)
                guard !Task.isCancelled, selectedHit?.id == hit.id else { return }; context = turns; contextLoading = false
            } catch {
                guard !Task.isCancelled else { return }; contextLoading = false; navigationError = error.localizedDescription
                local.removeAll { $0.id == hit.id }
            }
        }
    }
    private func observeIndex() {
        withObservationTracking { _ = indexing.status.revision } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeIndex(); self.indexChanged()
            }
        }
    }
    private func clearHistory() {
        historyTask?.cancel(); validationTask?.cancel()
        selectedHit = nil; selectedRecord = nil; context = []; contextLoading = false; selected = nil
    }
    func indexChanged() {
        validationTask?.cancel()
        if !indexing.status.state.enabled || selectedHit.map({ $0.epoch != indexing.status.state.epoch }) == true {
            clearHistory()
        } else if let hit = selectedHit {
            validationTask = Task { [weak self] in
                guard let self else { return }
                let valid = (try? await indexing.index.contains(hit)) == true
                guard !Task.isCancelled, selectedHit == hit else { return }
                if !valid { clearHistory(); navigationError = SearchProblem.changed.localizedDescription }
            }
        }
        localSearch(debounce: indexing.status.scanning)
    }

}

extension WorkspaceStore {
    var search: EverywhereSearchModel {
        if let searchModel { return searchModel }
        let model = EverywhereSearchModel(); searchModel = model
        model.openMessage = { [weak self, weak model] hit in
            guard let self, let model else { return }
            Task { await SearchNavigation.open(hit, model: model, from: self) }
        }
        model.openResults = { [weak self] in guard let self else { return }; SupportTabs.shared.navigation.open(.search, from: self) }
        return model
    }
}
