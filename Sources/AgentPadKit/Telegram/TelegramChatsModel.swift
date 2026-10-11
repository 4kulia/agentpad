import AgentPadTelegram
import Foundation
import Observation

/// The actor does all SQL, reduction and sorting. MainActor only presents one
/// snapshot and a bounded set of virtualized pages shared by app windows.
@MainActor @Observable
final class TelegramChatsModel {
    private(set) var snapshot = TelegramChatSnapshot()
    private(set) var pages: [Int: [TelegramChatRow]] = [:]
    private(set) var provider: (any TelegramChatProvider)?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var pageAge: [Int] = []
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
    deinit { observation?.cancel() }
    func receive(_ snapshot: TelegramChatSnapshot) {
        let accountChanged = self.snapshot.account != snapshot.account || (connected && snapshot.state == .disconnected)
        self.snapshot = snapshot
        pages = [0: snapshot.firstRows]; pageAge = [0]
        // Invalidate every window's retained results synchronously, including
        // stopped searches and results tabs with no mounted search field.
        if accountChanged { for search in searches.allObjects { search.accountChanged() } }
        changed?()
    }
    func loadPage(_ offset: Int) async {
        guard pages[offset] == nil, let provider else { return }
        let serial = serial, revision = snapshot.revision
        let page = await provider.chatPage(offset: offset, revision: revision)
        guard self.serial == serial, snapshot.revision == page.revision, !page.rows.isEmpty else { return }
        // 20 pages / 1000 compact DTOs (<4 MiB). Eviction only affects the
        // viewport cache, never discoverability or the expanded row count.
        pageAge.removeAll { $0 == offset }; pageAge.append(offset)
        pages[offset] = page.rows
        while pageAge.count > 20 { pages.removeValue(forKey: pageAge.removeFirst()) }
    }
    func expand(showLess: Bool = false) async { await provider?.expandChats(showLess: showLess) }
    func hold(_ held: Bool, owner: UUID) async { await provider?.holdChatOrder(held, owner: owner) }
    func mode(_ row: TelegramChatRow, _ mode: TelegramChatMode) async { await provider?.setChatMode(row.id, mode: mode) }
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
    var status: String? {
        if let error = snapshot.error { return error }
        switch snapshot.state {
        case .disconnected: return nil
        case .scanning: return "Scanning recent chats… · \(snapshot.foundCount) found so far"
        case .paused(let reason): return "Scan paused · \(reason) · \(snapshot.foundCount) found so far"
        case .complete: return snapshot.automaticCount == 0 ? "No recent conversations" : nil
        }
    }
}

extension TelegramChatRow {
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
    var shelfCaption: String {
        if hidden { return "Hidden here" }
        if pinned { return "Pinned here" }
        if isAutomatic {
            let days = max(0, Int(Date().timeIntervalSince1970 - Double(recentOutgoingDate)) / 86400)
            return days == 0 ? "You wrote · today" : "You wrote · \(days)d ago"
        }
        return displayKind + (inArchive ? " · Archive" : "")
    }
}

extension TelegramAttentionSummary {
    var caption: String {
        let label: String = switch kind {
        case .direct: "Direct message"
        case .mention: "Mentioned you"
        case .reply, .botReply: "Replied to you"
        case .channelPost: "New channel posts"
        }
        return firstMessage == 0 ? "Checking unread posts…" : "\(label) · \(count) new"
    }
}
