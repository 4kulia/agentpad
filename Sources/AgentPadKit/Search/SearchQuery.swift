import Foundation
import CryptoKit

enum SearchProblem: Error, LocalizedError, Equatable {
    case invalidQuery, invalidCursor, unavailable, changed, sizeLimit, rebuildRequired
    var errorDescription: String? {
        switch self {
        case .invalidQuery: "Use 1–32 words, up to 512 UTF-8 bytes."
        case .invalidCursor: "Results changed. Refresh the search."
        case .unavailable: "Conversation text unavailable. Refresh the index and try again."
        case .changed: "This turn changed or is no longer available. Refresh the search."
        case .sizeLimit: "Index size limit reached. Partial results."
        case .rebuildRequired: "Index cleared. Choose Rebuild index to enable indexing again."
        }
    }
}

struct SearchQuery: Equatable, Sendable {
    let text: String
    let words: [String]
    init(_ text: String) throws {
        let words = text.components(separatedBy: CharacterSet.alphanumerics.union(.nonBaseCharacters).inverted).filter { !$0.isEmpty }
        guard text.utf8.count <= 512, !words.isEmpty, words.count <= 32 else { throw SearchProblem.invalidQuery }
        self.text = text; self.words = words
    }
    var match: String { words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ") }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func digest(_ text: String) -> String { digest(Data(text.utf8)) }
}

struct LocalSearchFilter: Codable, Equatable, Sendable {
    var agent: String?
    var folder: String?
    var from: Date?
    var to: Date?
    static func dayRange(_ first: Date, _ last: Date, calendar: Calendar = .current) -> (Date, Date) {
        (calendar.startOfDay(for: first), calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last))!)
    }
    var normalizedFolder: String? { folder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path } }
}

struct ConversationTurn: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var role: String
    var text: String
    var date: Date?
    var ordinal: Int
    var offset: UInt64
    var truncated = false
    var prefixDigest = ""
    var digest: String {
        SearchQuery.digest(role + "\u{0}" + text + "\u{0}" + String(date?.timeIntervalSince1970 ?? -62_135_596_800) + "\u{0}" + String(truncated))
    }
}

struct LocalSearchHit: Identifiable, Equatable, Sendable {
    var record: AgentSessionRecord
    var turn: ConversationTurn
    var sourceDigest: String
    var epoch: String
    var turnDigest: String = ""
    var id: String { record.id + ":" + turn.id }
}

enum SearchSnippet {
    static func text(_ text: String, words: [String], limit: Int = 320) -> String {
        guard text.count > limit else { return text }
        let match = words.compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }.min() ?? text.startIndex
        let start = text.index(match, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        return String(text[start...].prefix(limit))
    }
}

struct LocalSearchCursor: Codable, Equatable, Sendable {
    var epoch: String
    var fingerprint: String
    var time: Double
    var agent: String
    var conversation: String
    var turn: String
}

struct LocalSearchPage: Sendable {
    var hits: [LocalSearchHit] = []
    var next: LocalSearchCursor?
}
