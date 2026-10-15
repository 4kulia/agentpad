import AgentPadTelegram
import Foundation
import Observation

/// The actor does all SQL, reduction and sorting. MainActor only presents one
/// snapshot and bounded row metadata shared by all app windows.
@MainActor @Observable
final class TelegramChatsModel {
    private(set) var snapshot = TelegramChatSnapshot()
    private(set) var metadataRevision: UInt64 = 0
    private(set) var listPages: [TelegramListKey:[Int:TelegramChatPage]] = [:]
    private(set) var attentionState: TelegramAttentionState?
    var attentionKeys: [TelegramAttentionOrderKey] { attentionState?.order.keys ?? [] }
    private(set) var attentionRevealed = 0
    private(set) var attentionRows: [Int64:TelegramChatRow] = [:]
    /// Bounded page corrections, separate from the provider's full live marks.
    private(set) var attentionInactive = Set<Int64>()
    private(set) var customRows: [Int64:TelegramChatRow] = [:]
    @ObservationIgnored private var customRequest = UUID()
    var readNotice: TelegramReadNotice?
    @ObservationIgnored private var attentionEpoch = UUID()
    @ObservationIgnored private var attentionViewports: [UUID:Set<Int64>] = [:]
    @ObservationIgnored private var attentionViewportReported = false
    private var attentionPositions: [Int64:Int] { attentionState?.order.positions ?? [:] }
    @ObservationIgnored private var attentionAttempted = Set<Int64>()
    @ObservationIgnored private var attentionTask: Task<Void,Never>?
    /// Deterministic cost probe: attention entries visited by receive/cache work.
    @ObservationIgnored private(set) var attentionReceiveWorkCount = 0
    struct Window: Hashable { let list: TelegramListKey; let start: Int }
    @ObservationIgnored private var windowsAge: [Window] = []
    @ObservationIgnored private var folderViewports: [UUID:[Window]] = [:]
    @ObservationIgnored private var viewportOwners: [UUID] = []
    @ObservationIgnored private var appliedViewport = Set<Window>()
    @ObservationIgnored private var requestedWindows: [TelegramListKey:Set<Int>] = [:]
    @ObservationIgnored private var viewportTask: Task<Void,Never>?
    @ObservationIgnored private var customViewports: [UUID:Set<Int64>] = [:]
    private(set) var provider: (any TelegramChatProvider)?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var serial = UUID()
    @ObservationIgnored var changed: (() -> Void)?
    @ObservationIgnored private let searches = NSHashTable<TelegramSearchModel>.weakObjects()
    @ObservationIgnored private var attentionDestinations = Set<TelegramChatID>()
    @ObservationIgnored private var destinationsTask: Task<Void, Never>?

    var connected: Bool { snapshot.account != nil && snapshot.state != .disconnected }
    func registerSearch(_ search: TelegramSearchModel) { searches.add(search) }
    func attach(_ provider: any TelegramChatProvider) {
        observation?.cancel(); receive(TelegramChatSnapshot()); self.provider = provider
        serial = UUID(); let serial = serial
        observation = Task { [weak self] in
            let updates = await provider.chatSnapshots()
            for await snapshot in updates {
                guard !Task.isCancelled, let self, self.serial == serial else { return }
                self.receive(snapshot)
            }
        }
        let destinations = attentionDestinations
        Task { await provider.setAttentionDestinations(destinations) }
    }
    deinit { observation?.cancel(); viewportTask?.cancel(); attentionTask?.cancel() }
    func receive(_ snapshot: TelegramChatSnapshot) {
        attentionReceiveWorkCount = 0
        let accountChanged = self.snapshot.binding != snapshot.binding || self.snapshot.account != snapshot.account || (connected && snapshot.state == .disconnected)
        let old = self.snapshot
        self.snapshot = snapshot
        metadataRevision &+= 1
        attentionEpoch = UUID()
        attentionTask?.cancel(); attentionTask = nil
        attentionAttempted = []
        let state = snapshot.attentionState.flatMap {
            $0.order.binding == snapshot.binding && $0.order.revision == snapshot.attentionRevision ? $0 : nil
        }
        let orderChanged = accountChanged || attentionState?.order != state?.order
        // O(1) adoption, including Observation's equality checks. Only the
        // provider builds or scans the full order and live-marker collections.
        attentionState = state
        if orderChanged {
            attentionRevealed = min(50,attentionKeys.count)
        }
        if accountChanged { attentionViewports = [:]; attentionViewportReported = false }
        attentionInactive = []
        // Drop stale badges synchronously, but never drop their slots.
        attentionRows = Dictionary(snapshot.attentionRows.map {
            attentionReceiveWorkCount += 1
            return ($0.id.chat,$0)
        }, uniquingKeysWith: { _, row in row })
        if old.binding != snapshot.binding { listPages = [:]; windowsAge = []; requestedWindows = [:] }
        for key in listPages.keys where !snapshot.lists.contains(where: { $0.key == key }) { listPages[key] = nil }
        for list in snapshot.lists {
            if old.lists.first(where: { $0.key == list.key })?.revision != list.revision { listPages[list.key] = [:] }
            if let allowed = requestedWindows[list.key] { listPages[list.key] = listPages[list.key]?.filter { allowed.contains($0.key) } }
            for (start,page) in list.windows where requestedWindows[list.key]?.contains(start) != false {
                listPages[list.key,default: [:]][start] = page; touch(.init(list: list.key,start: start))
            }
        }
        // Invalidate every window's retained results synchronously, including
        // stopped searches and results tabs with no mounted search field.
        if accountChanged {
            customRows = [:]; customRequest = UUID(); customViewports = [:]
            folderViewports = [:]; viewportOwners = []; appliedViewport = []; requestedWindows = [:]
            viewportTask?.cancel(); viewportTask = nil
            readNotice = nil; SidebarFolderActions.shared.invalidateTelegram(binding: snapshot.binding)
            for search in searches.allObjects { search.accountChanged() }
        }
        trimMetadata()
        changed?()
    }
    func loadPage(list: TelegramListKey, start: Int) async {
        guard listPages[list]?[start] == nil, let provider, let binding = snapshot.binding,
              let revision = snapshot.lists.first(where: { $0.key == list })?.revision else { return }
        let serial = serial
        let page = await provider.chatPage(list: list, from: start, revision: revision, binding: binding)
        guard self.serial == serial, snapshot.binding == binding,
              requestedWindows[list]?.contains(start) != false,
              snapshot.lists.first(where: { $0.key == list })?.revision == page.revision else { return }
        // Empty windows with a next cursor are valid: every row may be hidden.
        listPages[list,default: [:]][start] = page; touch(.init(list: list,start: start)); trimMetadata()
    }
    func setViewport(list: TelegramListKey, windows: Set<Int>) async {
        guard let provider, let binding = snapshot.binding else { return }
        // Older provider publications may arrive after a viewport change. They
        // must not reinsert a page that this window budget has just released.
        requestedWindows[list] = windows
        listPages[list] = listPages[list]?.filter { windows.contains($0.key) }
        windowsAge.removeAll { $0.list == list && !windows.contains($0.start) }
        trimMetadata()
        try? await provider.setViewport(list: list, windows: windows, binding: binding)
    }
    /// All mounted sidebars share the provider's five-window budget. A single
    /// worker releases old windows before adding new ones, even across windows.
    func folderViewport(_ windows: [Window], owner: UUID) {
        guard folderViewports[owner] != windows else { return }
        folderViewports[owner] = windows.isEmpty ? nil : windows
        viewportOwners.removeAll { $0 == owner }
        if !windows.isEmpty { viewportOwners.insert(owner,at: 0) }
        guard viewportTask == nil else { return }
        let serial = serial
        viewportTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.serial == serial {
                var desired = Set<Window>()
                for owner in viewportOwners {
                    for window in folderViewports[owner] ?? [] where desired.count < 5 {
                        guard snapshot.lists.contains(where: { $0.key == window.list && window.start < $0.capacity }) else { continue }
                        desired.insert(window)
                    }
                }
                if desired == appliedViewport { break }
                let old = appliedViewport
                for key in Set(old.map(\.list)) {
                    let kept = Set(old.intersection(desired).filter { $0.list == key }.map(\.start))
                    await setViewport(list: key,windows: kept)
                    guard !Task.isCancelled, self.serial == serial else { return }
                }
                for key in Set(desired.map(\.list)) {
                    await setViewport(list: key,windows: Set(desired.filter { $0.list == key }.map(\.start)))
                    guard !Task.isCancelled, self.serial == serial else { return }
                }
                appliedViewport = desired
                for window in desired { await loadPage(list: window.list,start: window.start) }
            }
            if self.serial == serial { viewportTask = nil }
        }
    }
    func customViewport(_ chats: Set<Int64>, owner: UUID = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))) async {
        customViewports[owner] = chats.isEmpty ? nil : chats
        let chats = Set(customViewports.values.flatMap { $0 }.sorted().prefix(76))
        guard let provider, let binding = snapshot.binding else { customRows = [:]; return }
        let request = UUID(); customRequest = request
        customRows = customRows.filter { chats.contains($0.key) }
        var rows: [Int64:TelegramChatRow] = [:]
        for chat in chats.sorted().prefix(76) {
            let row = await provider.chat(.init(environment: binding.environment, account: binding.account, chat: chat))
            guard customRequest == request, snapshot.binding == binding else { return }
            if let row, !row.hidden, row.kind.eligible { rows[chat] = row }
        }
        customRows = rows
        trimMetadata()
    }
    func expand(_ list: TelegramListKey, showLess: Bool = false) async {
        guard let provider, let binding = snapshot.binding else { return }
        try? await provider.expandChats(list: list, showLess: showLess, binding: binding)
    }
    func hold(_ list: TelegramListKey, held: Bool, owner: UUID) async {
        guard let provider, let binding = snapshot.binding else { return }
        try? await provider.holdChatOrder(list: list, held: held, owner: owner, binding: binding)
    }
    func shownIn(_ row: TelegramChatRow) -> String {
        let names = snapshot.lists.filter { $0.visible && row.lists.contains($0.key) }.map(\.name)
        let uncertain = snapshot.lists.contains { !$0.visible || !$0.complete }
        return "Shown in: " + (names.isEmpty ? "None" : names.joined(separator: " · ")) + (uncertain ? " …" : "")
    }
    private func touch(_ window: Window) { windowsAge.removeAll { $0 == window }; windowsAge.append(window) }
    /// Lists have the provider's five-window allowance. Attention uses the
    /// remaining shared ceiling, including snapshot, suggestion and custom rows.
    /// Nothing is exempt from the ceiling because an owner can see it.
    private func trimMetadata() {
        windowsAge.removeAll { listPages[$0.list]?[$0.start] == nil }
        var listRows = listPages.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.rows.count } }
        while listRows > 250, !windowsAge.isEmpty {
            let oldest = windowsAge.removeFirst()
            listRows -= listPages[oldest.list]?.removeValue(forKey: oldest.start)?.rows.count ?? 0
        }
        reconcileAttentionMetadata()
    }
    var retainedMetadataCount: Int { otherMetadataCount + attentionRows.count }
    private var otherMetadataCount: Int {
        snapshot.attentionRows.count + snapshot.suggestionRows.count + customRows.count
            + snapshot.lists.reduce(0) { $0 + $1.windows.values.reduce(0) { $0 + $1.rows.count } }
            + listPages.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.rows.count } }
    }
    /// Actual row IDs, not pages: adjacent windows can share metadata without
    /// protecting fifty offscreen rows each. All visible rows precede margins.
    func attentionViewport(_ chats: Set<Int64>, owner: UUID) {
        guard !attentionViewportReported || (attentionViewports[owner] ?? []) != chats else { return }
        attentionViewportReported = true
        attentionViewports[owner] = chats.isEmpty ? nil : chats
        reconcileAttentionMetadata()
    }
    private var attentionCandidates: Set<Int64> {
        let budget = max(0,TelegramChatLimits.metadataRows - otherMetadataCount)
        let owners: [[Int]] = attentionViewportReported
            ? attentionViewports.keys.sorted { $0.uuidString < $1.uuidString }.map { owner in
                (attentionViewports[owner] ?? []).compactMap {
                    attentionReceiveWorkCount += 1
                    return attentionPositions[$0]
                }.filter { $0 < attentionRevealed }.sorted()
            }
            : [Array(0..<min(50,attentionRevealed))]
        // Round-robin admission keeps many owners under the same hard ceiling.
        // The choice depends on viewports, never on which response arrived last.
        var visible = Set<Int>(), ordered: [Int] = []
        for index in 0..<(owners.map(\.count).max() ?? 0) {
            for positions in owners where index < positions.count {
                let position = positions[index]
                if visible.insert(position).inserted { ordered.append(position) }
            }
        }
        var margin = Set<Int>()
        for position in visible {
            for nearby in max(0,position - 3)..<min(attentionRevealed,position + 4) where !visible.contains(nearby) {
                margin.insert(nearby)
            }
        }
        return Set((ordered + margin.sorted()).lazy.map {
            self.attentionReceiveWorkCount += 1
            return self.attentionKeys[$0].chat
        }
            .filter { self.attentionState?.inactive.contains($0) != true }.prefix(budget))
    }
    private var desiredAttentionChats: Set<Int64> { attentionCandidates.subtracting(attentionInactive) }
    private func reconcileAttentionMetadata() {
        let candidates = attentionCandidates
        attentionInactive.formIntersection(candidates)
        let wanted = candidates.subtracting(attentionInactive)
        attentionRows = attentionRows.filter {
            attentionReceiveWorkCount += 1
            return wanted.contains($0.key)
        }
        attentionAttempted.formIntersection(wanted)
        guard attentionTask == nil, provider != nil,
              wanted.contains(where: { attentionRows[$0] == nil && !attentionAttempted.contains($0) }) else { return }
        let epoch = attentionEpoch
        attentionTask = Task { [weak self] in
            guard let self else { return }
            defer { if attentionEpoch == epoch { attentionTask = nil } }
            while !Task.isCancelled, attentionEpoch == epoch, let provider, let binding = snapshot.binding {
                let wanted = desiredAttentionChats
                guard let position = wanted.compactMap({ chat -> Int? in
                    attentionRows[chat] == nil && !attentionAttempted.contains(chat) ? attentionPositions[chat] : nil
                }).min() else { return }
                let start = position / 50 * 50
                let requested = wanted.filter { (attentionPositions[$0] ?? -50) / 50 * 50 == start }
                attentionAttempted.formUnion(requested)
                let revision = snapshot.attentionRevision
                // Pages are transport only. They never own geometry or cached rows.
                let page = await provider.attentionPage(start: start,revision: revision,binding: binding)
                guard !Task.isCancelled, attentionEpoch == epoch, snapshot.binding == binding,
                      snapshot.attentionRevision == page.revision else { return }
                let admitted = desiredAttentionChats.intersection(requested)
                let valid = page.attentionKeys != nil || page.attentionFrontier != nil || page.next != nil || !page.rows.isEmpty
                if valid {
                    let live = Set(page.rows.filter { !$0.hidden && $0.kind.eligible && $0.attention != nil }.map(\.id.chat))
                    attentionInactive.formUnion(admitted.subtracting(live))
                    for row in page.rows where admitted.contains(row.id.chat) && live.contains(row.id.chat) {
                        attentionRows[row.id.chat] = row
                    }
                }
                reconcileAttentionMetadata()
                changed?()
            }
        }
    }
    func holdAttention(_ held: Bool, owner: UUID) async {
        guard let provider, let binding = snapshot.binding else { return }
        try? await provider.holdAttentionOrder(held, owner: owner, binding: binding)
    }
    var revealedAttentionKeys: [TelegramAttentionOrderKey] { Array(attentionKeys.prefix(attentionRevealed)) }
    var attentionNext: Int? { attentionRevealed < attentionKeys.count ? attentionRevealed : nil }
    var attentionFrontier: TelegramAttentionOrderKey? {
        attentionNext == nil ? nil : revealedAttentionKeys.last
    }
    func expandAttention() async {
        attentionRevealed = min(attentionKeys.count,attentionRevealed + 50)
        reconcileAttentionMetadata()
        changed?()
    }
    func mode(_ row: TelegramChatRow, _ mode: TelegramChatMode) async { await provider?.setChatMode(row.id, mode: mode) }
    func follow(_ row: TelegramChatRow, binding expected: TelegramProfileBinding? = nil) async {
        guard let provider, let binding = snapshot.binding, row.id.account == binding.account, row.id.environment == binding.environment else { return }
        guard expected == nil || expected == binding else { return }
        do { try await provider.setFollow(row.id.chat, enabled: !row.followEnabled, binding: binding) }
        catch { if snapshot.binding == binding { readNotice = .init(row: row, binding: binding, message: "Could not change new-message notifications · Try again") } }
    }
    func markAsRead(_ row: TelegramChatRow, retry: Set<TelegramMarkReadStep>? = nil, binding expected: TelegramProfileBinding? = nil) async {
        guard row.canMarkAsRead, let provider, let binding = snapshot.binding,
              row.id.account == binding.account, row.id.environment == binding.environment else { return }
        guard expected == nil || expected == binding else { return }
        let serial = serial
        let result = await provider.markAsRead(row.id.chat, retry: retry, binding: binding)
        guard self.serial == serial, snapshot.binding == binding else { return }
        if result.succeeded { readNotice = nil; return }
        let message = result.failed.isEmpty && result.error == nil ? "Open the chat to read it" : "Could not mark \(row.title) as read"
        readNotice = .init(row: row, binding: binding, message: message + (result.openChatRequired && !result.failed.isEmpty ? " · Open the chat to read it" : ""),
            failed: result.failed, retryAll: result.error == .storage || result.error == .unavailable)
    }
    func retryMarkAsRead() async {
        guard let notice = readNotice, snapshot.binding == notice.binding, notice.canRetry else { return }
        await markAsRead(notice.row, retry: notice.retryAll ? nil : notice.failed)
    }
    func loadedRow(_ id: TelegramChatID) -> TelegramChatRow? {
        attentionRows[id.chat].flatMap { $0.id.root == id.root ? $0 : nil }
            ?? listPages.values.lazy.flatMap { $0.values.flatMap(\.rows) }.first { $0.id.root == id.root }
            ?? customRows[id.chat] ?? snapshot.suggestionRows.first { $0.id.root == id.root }
    }
    func observeAttention(_ destinations: Set<TelegramChatID>) {
        guard attentionDestinations != destinations else { return }
        attentionDestinations = destinations
        guard destinationsTask == nil else { return }
        destinationsTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                let value = self.attentionDestinations
                await self.provider?.setAttentionDestinations(value)
                if value == self.attentionDestinations { break }
            } while !Task.isCancelled
            self.destinationsTask = nil
        }
    }
    func row(_ id: TelegramChatID) async -> TelegramChatRow? { await provider?.chat(id) }

}

extension TelegramChatRow {
    var canMarkAsRead: Bool { kind.eligible && kind != .forum && (unreadCount > 0 || markedUnread || unreadMentionCount > 0) }
    var canFollow: Bool { [.group,.supergroup,.forum,.channel].contains(kind) && !hidden }
    var followTitle: String {
        if followActivating { return "Turning on…" }
        return kind == .channel ? "Notify about new posts" : "New messages → Needs attention"
    }
    var displayKind: String {
        switch kind {
        case .person: "Private chat"
        case .group: "Group"
        case .supergroup: "Supergroup"
        case .channel: "Channel"
        case .forum: "Forum"
        case .bot: "Bot"
        case .savedMessages: "Saved Messages"
        case .secret: "Not available on this Mac"
        case .channelDirect: "Open in Telegram"
        case .unknown: "Chat details unavailable"
        }
    }
    var symbol: String {
        switch kind {
        case .person: "person.crop.circle"
        case .group, .supergroup: "person.2"
        case .channel: "megaphone"
        case .forum: "bubble.left.and.bubble.right"
        case .bot: "cpu"
        case .savedMessages: "bookmark"
        case .secret: "lock"
        case .channelDirect, .unknown: "arrow.up.right.square"
        }
    }

}

struct TelegramReadNotice: Identifiable {
    let id = UUID()
    var row: TelegramChatRow
    var binding: TelegramProfileBinding
    var message: String
    var failed: Set<TelegramMarkReadStep> = []
    var retryAll = false
    var canRetry: Bool { retryAll || !failed.isEmpty }
}

extension TelegramAttentionSummary {
    var caption: String {
        let label: String = switch kind {
        case .direct: "Direct message"
        case .mention: "Mentioned you"
        case .reply, .botReply: "Replied to you"
        case .groupMessage: "New messages"
        case .channelPost: "New channel posts"
        }
        func display(_ value: Int) -> String { value > 999 ? "999+" : "\(value)\(incomplete ? "+" : "")" }
        if firstMessage == 0 { return "\(label) · Checking unread messages…" }
        if classCount < count { return "\(label) · \(display(classCount)) · \(display(count - classCount)) other new" }
        return "\(label) · \(display(count)) new"
    }
}
