import Foundation
import GRDB
import Observation

/// Per-tab reading state; only banner visibility is persisted in the scoped cache.
@MainActor @Observable
final class ChatPinsPresentation {
    var isPresented = false
    var expanded = false
    var query = ""
    var filter = ChatPinFilter.all
    var scrollID: String?
    private(set) var selectedID: String?
    private(set) var returnsToPins = false

    func current(in pins: [ChatB1.PinnedMessage]) -> ChatB1.PinnedMessage? {
        pins.first { $0.id == selectedID } ?? pins.first
    }

    func advance(in pins: [ChatB1.PinnedMessage]) {
        guard let current = current(in: pins), let index = pins.firstIndex(where: { $0.id == current.id }) else {
            selectedID = nil; return
        }
        selectedID = pins[(index + 1) % pins.count].id
    }

    func reconcile(old: [ChatB1.PinnedMessage], new: [ChatB1.PinnedMessage]) {
        if new.first?.id != old.first?.id || !new.contains(where: { $0.id == selectedID }) {
            selectedID = new.first?.id
        }
    }

    func coversConversation(width: Double) -> Bool { isPresented && (expanded || width < 900) }

    func open() { isPresented = true; returnsToPins = false }
    func close() { isPresented = false; returnsToPins = false }

    func prepareJump(_ pin: ChatB1.PinnedMessage, width: Double) {
        if coversConversation(width: width) || pin.threadRootId != nil {
            returnsToPins = isPresented
            isPresented = false
        }
    }
}

enum ChatPinFilter: String, CaseIterable {
    case all = "All", agents = "Agents", people = "People"
}

enum ChatPins {
    static func ordered(_ pins: [ChatB1.PinnedMessage]) -> [ChatB1.PinnedMessage] {
        pins.sorted {
            if $0.pinnedAt != $1.pinnedAt { return $0.pinnedAt > $1.pinnedAt }
            if $0.seq != $1.seq { return $0.seq > $1.seq }
            return $0.id < $1.id
        }
    }

    static func author(_ pin: ChatB1.PinnedMessage, members: [ChatOrgView.Member]) -> String {
        pin.authorAgentName ?? pin.authorSessionName ?? name(pin.authorAccountId, members: members)
    }

    static func name(_ id: String, members: [ChatOrgView.Member]) -> String {
        members.first { $0.accountId == id }?.name ?? "Former member"
    }

    static func isAgent(_ pin: ChatB1.PinnedMessage) -> Bool {
        pin.authorAgentId != nil || pin.authorSessionName != nil
    }

    static func matching(_ pins: [ChatB1.PinnedMessage], messages: [String: ChatMessage], members: [ChatOrgView.Member],
                         query: String, filter: ChatPinFilter) -> [ChatB1.PinnedMessage] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return pins.filter { pin in
            guard filter == .all || (filter == .agents) == isAgent(pin) else { return false }
            let message = messages[pin.id]
            let body = message?.deleted == true ? "" : (message?.text ?? pin.excerpt)
            let haystack = [body, author(pin, members: members), name(pin.pinnedBy, members: members)].joined(separator: " ")
            return words.allSatisfy { haystack.localizedStandardContains($0) }
        }
    }

    struct Read: Equatable {
        var id: String
        var sequence: Int
        var revision: Int
    }

    static func missing(_ pins: [ChatB1.PinnedMessage], messages: [String: ChatMessage]) -> [Read] {
        pins.compactMap { pin in
            let message = messages[pin.id]
            guard message?.deleted != true, message == nil || message?.needsRead == true else { return nil }
            return Read(id: pin.id, sequence: pin.seq, revision: max(1, message?.stale ?? message?.revision ?? 0))
        }
    }

    static func bannerHidden(_ db: Database, channel: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT hidden FROM pin_preferences WHERE channel_id = ?", arguments: [channel]) ?? false
    }

    static func setBannerHidden(_ db: Database, channel: String, hidden: Bool) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO pin_preferences (channel_id, hidden) VALUES (?, ?)", arguments: [channel, hidden])
    }
}
