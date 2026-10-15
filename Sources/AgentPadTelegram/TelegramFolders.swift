import CryptoKit
import Foundation

/// Profile-scoped identities. Never encode these in app/window persistence.
public struct TelegramProfileBinding: Equatable, Hashable, Sendable {
    public let environment: TelegramEnvironment
    public let account: Int64
    public let connectionID: UUID
    public init(environment: TelegramEnvironment, account: Int64, connectionID: UUID) {
        self.environment = environment; self.account = account; self.connectionID = connectionID
    }
    public var migratedPinsID: UUID { Self.migratedPinsID(connectionID: connectionID) }
    public static func migratedPinsID(connectionID: UUID) -> UUID {
        var namespace = connectionID.uuid
        var bytes = withUnsafeBytes(of: &namespace) { Data($0) }
        bytes.append(contentsOf: "pinned-here".utf8)
        var hash = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x50; hash[8] = (hash[8] & 0x3f) | 0x80
        return UUID(uuid: (hash[0],hash[1],hash[2],hash[3],hash[4],hash[5],hash[6],hash[7],
                           hash[8],hash[9],hash[10],hash[11],hash[12],hash[13],hash[14],hash[15]))
    }
}

public enum TelegramListKey: Hashable, Sendable, RawRepresentable {
    case main, archive, folder(Int64)
    public init?(rawValue: String) {
        if rawValue == "main" { self = .main }
        else if rawValue == "archive" { self = .archive }
        else if rawValue.hasPrefix("folder:"), let id = Int64(rawValue.dropFirst(7)), id > 0 { self = .folder(id) }
        else { return nil }
    }
    public var rawValue: String {
        switch self { case .main: "main"; case .archive: "archive"; case .folder(let id): "folder:\(id)" }
    }
    var tdlib: TDLibValue {
        switch self {
        case .main: .typed("chatListMain")
        case .archive: .typed("chatListArchive")
        case .folder(let id): .typed("chatListFolder", ["chat_folder_id": .integer(id)])
        }
    }
    init?(_ object: TDLibMessage?) {
        switch object?.type {
        case "chatListMain": self = .main
        case "chatListArchive": self = .archive
        case "chatListFolder":
            guard let id = object?["chat_folder_id"]?.integer, id > 0 else { return nil }; self = .folder(id)
        default: return nil
        }
    }
}

public struct TelegramListCounts: Equatable, Sendable {
    public var rows = 0
    public var unreadItems = 0
    public var unmutedUnreadItems = 0
    public var attentionItems = 0
    public init() {}
}

public struct TelegramListSnapshot: Equatable, Sendable, Identifiable {
    public var key: TelegramListKey
    public var id: TelegramListKey { key }
    public var name: String
    public var icon: String
    public var visible: Bool
    public var complete: Bool
    public var generation: UInt64
    public var revision: UInt64
    public var counts: TelegramListCounts
    /// Number of positions, including live-filtered holes while held.
    public var capacity: Int
    public var expanded: Bool
    public var windows: [Int: TelegramChatPage]
    public var collapsedWindows: Set<UUID>
}

public enum TelegramFolderError: Error, Equatable, Sendable {
    case unavailable, staleBinding, invalidTarget, tooLarge, storage
}

/// Compact sort/aggregate metadata consumed by the folder actor, never persisted
/// outside the profile or retained as full row metadata in the UI.
public struct TelegramFolderSummary: Sendable {
    public var chat: Int64
    public var title: String
    public var date: Int64
    public var unread: Bool
    public var muted: Bool
    public var attention: Bool
    public var hidden: Bool
    public var available: Bool
}

public enum TelegramMarkReadStep: String, Hashable, Sendable { case messages, markedUnread, mentions }
public struct TelegramAttentionOrderKey: Equatable, Sendable {
    public var chat: Int64
    public var tier: Int
    public var rankingTime: Int64
    public init(chat: Int64, tier: Int, rankingTime: Int64) {
        self.chat = chat; self.tier = tier; self.rankingTime = rankingTime
    }
}
public struct TelegramMarkReadResult: Equatable, Sendable {
    public var failed: Set<TelegramMarkReadStep> = []
    public var openChatRequired = false
    public var error: TelegramFolderError?
    public var succeeded: Bool { failed.isEmpty && !openChatRequired && error == nil }
    public init() {}
}

/// A single ordering contract for the local SQL query and merged search hits.
public enum TelegramSearchRank {
    static let relevantSQL = "(\(TelegramChatIndex.attentionMembershipSQL) OR id IN (SELECT chat FROM tg_list_order WHERE list='main' AND position<50))"
    static let sql = "CASE WHEN tg_lower(title)=? OR tg_lower(username)=? THEN 0 ELSE 1 END, CASE WHEN \(relevantSQL) THEN 0 ELSE 1 END, lastDate DESC, id"
    public static func precedes(_ a: TelegramSearchHit, _ b: TelegramSearchHit, query: String) -> Bool {
        let query = query.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        func exact(_ row: TelegramChatRow) -> Bool { row.title.lowercased() == query || row.username.lowercased() == query }
        if exact(a.row) != exact(b.row) { return exact(a.row) }
        if a.row.knownRelevant != b.row.knownRelevant { return a.row.knownRelevant }
        if a.row.lastMessageDate != b.row.lastMessageDate { return a.row.lastMessageDate > b.row.lastMessageDate }
        if a.row.id.chat != b.row.id.chat { return a.row.id.chat < b.row.id.chat }
        return (a.userID ?? 0) < (b.userID ?? 0)
    }
}
