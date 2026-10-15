import AgentPadTelegram
import Foundation
import Observation

struct SidebarFolderEntry: Identifiable, Equatable {
    enum Kind: Equatable { case team(String), people, myAgents, teamAgents, custom(UUID), telegram(TelegramListKey), connect }
    var id: String
    var title: String
    var kind: Kind
    var symbol = "folder"
    var count = 0
    var unread = 0
    var unmuted = 0
    var attention = false
    var provisional = false
    var visible = true
    var connected = true
    var foreign = 0
    var tag: String? {
        switch kind { case .telegram: "TG"; case .custom: "MINE"; default: nil }
    }
    var moveID: String { if case .telegram = kind { "telegram" } else { id } }
    var kindLabel: String {
        switch kind {
        case .telegram: "Telegram folder"
        case .custom: "Your folder"
        case .connect: "Telegram"
        default: "AgentPad"
        }
    }
    var badgeCount: Int { unmuted > 0 ? unmuted : unread }
    var accessibilityLabel: String {
        "\(title), \(kindLabel), \(provisional ? "at least " : "")\(badgeCount) unread" + (attention ? ", needs attention" : "") + (foreign > 0 ? ", +\(foreign) from another team" : "")
    }
    static func telegramID(_ key: TelegramListKey) -> String { "telegram:\(key.rawValue)" }
}

@MainActor @Observable
final class SidebarFoldersModel {
    let store: SidebarFoldersStore
    private(set) var snapshot = SidebarFoldersSnapshot()
    private(set) var custom: [UUID:SidebarCustomProjection] = [:]
    private(set) var summaryMembers: Set<SidebarAgentPadReference> = []
    @ObservationIgnored private(set) var summarySource: SidebarFolderSummarySource?
    var sheetPresented = false
    var editing: UUID?
    var deleting: SidebarCustomFolder?
    var error: String?
    struct FailedOperation {
        let id = UUID()
        let operation: SidebarFoldersStore.Operation
        let binding: TelegramProfileBinding?
        var message: String
    }
    private(set) var failures: [FailedOperation] = []
    private(set) var retrying = false
    var hiddenToast: SidebarFolderEntry?
    var limits: [String:Int] = [:]
    @ObservationIgnored private var observation: Task<Void,Never>?
    @ObservationIgnored private var refreshTask: Task<Void,Never>?
    @ObservationIgnored private var toastTask: Task<Void,Never>?
    @ObservationIgnored private var scope: String?
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var telegramOpen = false
    @ObservationIgnored private var ranges: [UUID:Range<Int>] = [:]
    init(store: SidebarFoldersStore = SidebarFoldersService.store) { self.store = store }
    deinit { observation?.cancel(); refreshTask?.cancel(); toastTask?.cancel() }
    func start() {
        guard observation == nil else { return }
        observation = Task { [weak self, store] in
            for await snapshot in await store.snapshots() {
                guard !Task.isCancelled, let self else { return }
                self.receive(snapshot)
            }
        }
    }
    private func receive(_ snapshot: SidebarFoldersSnapshot) {
        // Metadata publications share the catalog's array storage. Do not hash
        // every AgentPad reference again for each Telegram message/read.
        if self.snapshot.catalog.custom != snapshot.catalog.custom {
            let members = Set(snapshot.catalog.custom.flatMap(\.items))
            if summaryMembers != members { summaryMembers = members }
        }
        self.snapshot = snapshot; refresh()
    }
    func observeSummaries(workspace: WorkspaceStore, org: ChatOrgModel?, attention: AttentionSidebarModel,
                          people: @escaping (ChatOrgKey) -> ChatDMPeopleInput) {
        guard summarySource == nil || summarySource?.org !== org else { return }
        summarySource = SidebarFolderSummarySource(workspace: workspace, folders: self, org: org,
            attention: attention, people: people, after: summarySource?.delivery)
    }
    func configure(scope: String?, query: String, telegramOpen: Bool) {
        self.scope = scope; self.query = query; self.telegramOpen = telegramOpen
        refresh()
    }
    func viewport(_ ranges: [UUID:Range<Int>]) {
        guard self.ranges != ranges else { return }
        self.ranges = ranges; refresh()
    }
    private func refresh() {
        refreshTask?.cancel()
        let scope = scope, query = query, ranges = ranges, open = telegramOpen
        refreshTask = Task { [weak self, store] in
            let projection = await store.presentation(scope: scope, query: query, ranges: ranges, telegramOpen: open)
            guard !Task.isCancelled else { return }
            self?.custom = projection
        }
    }
    @discardableResult func perform(_ operation: SidebarFoldersStore.Operation, binding: TelegramProfileBinding?) async -> Bool {
        let result = await store.perform(operation, binding: binding)
        if case .failure(let failure) = result {
            failures.append(.init(operation: operation, binding: binding, message: failure.message))
            error = failures.first?.message; return false
        }
        receive(await store.current()); return true
    }
    func dismissFailure() {
        if !failures.isEmpty { failures.removeFirst() }
        error = failures.first?.message
    }
    func retry() {
        guard !retrying, let failed = failures.first else { return }
        retrying = true
        Task {
            // Re-enqueue exactly the original action, including its profile binding.
            // In particular, a partial delete must finish its tombstone operation.
            let result = await store.perform(failed.operation, binding: failed.binding)
            retrying = false
            if case .success = result {
                failures.removeAll { $0.id == failed.id }
                receive(await store.current())
            } else if case .failure(let failure) = result, let index = failures.firstIndex(where: { $0.id == failed.id }) {
                failures[index].message = failure.message
            }
            error = failures.first?.message
        }
    }
    func run(_ operation: SidebarFoldersStore.Operation) {
        let binding = snapshot.binding
        Task { await perform(operation, binding: binding) }
    }
    func setVisible(_ entry: SidebarFolderEntry, _ visible: Bool) {
        if case .telegram(let key) = entry.kind { run(.telegramVisible(key, visible)) }
        else { run(.visible(entry.id, visible)) }
        if !visible {
            hiddenToast = entry; toastTask?.cancel()
            toastTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { self?.hiddenToast = nil }
            }
        }
    }
    func undoHide() {
        guard let entry = hiddenToast else { return }
        setVisible(entry, true); hiddenToast = nil; toastTask?.cancel()
    }
    func move(_ entry: SidebarFolderEntry, by delta: Int) {
        guard let index = snapshot.catalog.order.firstIndex(of: entry.moveID) else { return }
        run(.move(entry.moveID, index + delta))
    }
    func newFolder() {
        let id = UUID(), binding = snapshot.binding
        Task { if await perform(.create(id, name: "New folder", symbol: "folder"), binding: binding) { editing = id } }
    }
    func remove(_ item: SidebarItemReference, from id: UUID) { run(.member(id, item, false)) }
    func limit(_ entry: String) -> Int { limits[entry] ?? 8 }
    func more(_ entry: String) { limits[entry] = limit(entry) + 10 }
    func less(_ entry: String) { limits[entry] = 8 }
}

extension TelegramListSnapshot {
    var sidebarEntry: SidebarFolderEntry {
        .init(id: SidebarFolderEntry.telegramID(key), title: name, kind: .telegram(key), symbol: sidebarSymbol,
              count: counts.rows, unread: counts.unreadItems, unmuted: counts.unmutedUnreadItems,
              attention: counts.attentionItems > 0, provisional: !complete, visible: visible)
    }
    var sidebarSymbol: String {
        if key == .archive { return "archivebox" }
        if key == .main { return "tray.full" }
        // circle.badge from the design is not available in the system symbol set.
        return ["All":"tray.full", "Unread":"circle.dotted", "Unmuted":"bell", "Bots":"cpu",
            "Channels":"megaphone", "Groups":"person.2", "Private":"person", "Custom":"folder", "Setup":"gearshape",
            "Sport":"sportscourt", "Cat":"cat", "Crown":"crown", "Favorite":"star", "Flower":"camera.macro",
            "Game":"gamecontroller", "Home":"house", "Love":"heart", "Mask":"theatermasks", "Party":"party.popper",
            "Note":"note.text", "Study":"graduationcap", "Trade":"chart.line.uptrend.xyaxis", "Travel":"airplane",
            "Work":"briefcase", "Airplane":"airplane", "Book":"book", "Light":"lightbulb", "Like":"hand.thumbsup",
            "Money":"dollarsign.circle", "Palette":"paintpalette"][icon] ?? "folder"
    }
}
