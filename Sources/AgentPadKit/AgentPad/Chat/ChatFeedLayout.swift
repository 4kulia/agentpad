import Foundation

/// Presentation only: identity never comes from a display name or an @ in text.
struct ChatAuthorIdentity: Hashable, Sendable {
    var account: String
    var agent: String?
    var session: String?

    init(_ message: ChatMessage) {
        account = message.authorAccountId
        agent = message.authorAgentId
        session = message.authorSessionName
    }

    var isBot: Bool { agent != nil || session != nil }
    /// Swift's Hasher is randomized at launch. Use a fixed hash for avatar colors.
    var colorIndex: Int {
        let text = [account, agent ?? "", session ?? ""].joined(separator: "\u{0}")
        return Int(text.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 } % 4)
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

enum ChatFeedLayout {
    static func selection(moving direction: Int, in ids: [String], from selected: String?) -> String? {
        guard !ids.isEmpty else { return nil }
        let index = selected.flatMap { ids.firstIndex(of: $0) } ?? (direction > 0 ? -1 : ids.count)
        return ids[min(max(index + direction, 0), ids.count - 1)]
    }
    struct Row: Identifiable, Equatable {
        var message: ChatMessage
        var startsGroup: Bool
        var date: Date?
        var startsUnread: Bool
        var id: String { message.messageId }
    }

    static func date(_ iso: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    static func rows(_ messages: [ChatMessage], unreadID: String? = nil, calendar: Calendar = .current) -> [Row] {
        // Sequence determines order, including when clocks run backwards. Pending
        // posts retain their queue order after the server's messages.
        let ordered = messages.enumerated().sorted {
            if let a = $0.element.seq, let b = $1.element.seq { return a == b ? $0.offset < $1.offset : a < b }
            if $0.element.seq != nil { return true }
            if $1.element.seq != nil { return false }
            return $0.offset < $1.offset
        }.map(\.element)
        var previous: ChatMessage?
        var previousDate: Date?
        return ordered.map { message in
            let now = date(message.createdAt)
            let sameDay = now.flatMap { day in previousDate.map { calendar.isDate(day, inSameDayAs: $0) } } ?? false
            let unread = message.messageId == unreadID
            let grouped = previous.map { before in
                sameDay && !unread && !before.deleted && !message.deleted && before.hasFixed && message.hasFixed
                    && !before.loading && !message.loading && before.localState == nil && message.localState == nil
                    && before.channelId == message.channelId && before.threadRootId == message.threadRootId
                    && ChatAuthorIdentity(before) == ChatAuthorIdentity(message)
                    && now.flatMap { n in previousDate.map { abs(n.timeIntervalSince($0)) <= 300 } } == true
            } ?? false
            let row = Row(message: message, startsGroup: !grouped, date: sameDay ? nil : now, startsUnread: unread)
            previous = message
            previousDate = now
            return row
        }
    }
}

struct ChatReplySummary: Equatable, Sendable {
    var count: Int
    var complete: Bool
    /// Representatives of distinct known identities; never synthesized members.
    var participants: [ChatMessage]
    var latest: ChatMessage?

    init(messages: [ChatMessage], complete: Bool) {
        let known = messages.filter { $0.seq != nil }
        count = known.count
        self.complete = complete && known.allSatisfy { $0.hasFixed }
        var seen = Set<ChatAuthorIdentity>()
        participants = Array(known.filter { $0.hasFixed && !$0.authorAccountId.isEmpty && seen.insert(ChatAuthorIdentity($0)).inserted }.prefix(3))
        latest = known.filter(\.hasFixed).max { ($0.seq ?? 0) < ($1.seq ?? 0) }
    }

    var label: String { "\(count)\(complete ? "" : "+") \(count == 1 && complete ? "reply" : "replies")" }
}

/// The read position belongs to a conversation in a tab, never to the account's
/// shared draft. Geometry updates confirm bottom before any read mark advances.
struct ChatScrollPosition: Equatable {
    var atBottom = false
    var initialized = false
    var anchor: String?
    var unseen = Set<String>()
    private var known = Set<String>()
    private var lastSequence = 0

    mutating func update(_ messages: [ChatMessage]) -> Bool {
        let ids = Set(messages.map(\.messageId))
        let follow = !initialized || atBottom
        if initialized && !atBottom {
            unseen.formUnion(messages.filter { !known.contains($0.messageId) && ($0.seq == nil || ($0.seq ?? 0) > lastSequence) }.map(\.messageId))
        }
        known = ids
        unseen.formIntersection(ids)
        lastSequence = max(lastSequence, messages.compactMap(\.seq).max() ?? 0)
        if !messages.isEmpty { initialized = true }
        return follow
    }

    mutating func measured(bottom: Bool, anchor: String?) {
        atBottom = bottom
        self.anchor = anchor
        if bottom { unseen = [] }
    }

    static func canMarkRead(appActive: Bool, shown: Bool, atBottom: Bool, searching: Bool) -> Bool {
        appActive && shown && atBottom && !searching
    }
}
