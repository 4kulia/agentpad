import Foundation

/// A live tab and the Claude process that owns the MCP caller. Neither a hook
/// conversation UUID nor AGENTPAD_SURFACE_ID is consulted for attribution.
struct ChatLocalCaller: Codable, Equatable, Sendable {
    var surface: String
    var claudePID: Int32
    var claudeStart: UInt64
    var signature: String

    var provenance: String { "\(surface)/\(claudePID)/\(claudeStart)" }
}

@MainActor
enum ChatSessionIdentity {
    struct Tab {
        var id: UUID
        var customTitle: String?
        var folderName: String
        var processes: [SessionProcessScanner.Raw]
    }

    static func resolve(_ origin: AgentPadCallerOrigin, sessions: [Session]) -> ChatLocalCaller? {
        guard case .localProcess(let pid, let start) = origin,
              SessionProcessScanner.identityMatches(pid: pid, startedAtUs: start),
              TeamProcesses.shared.run(containing: pid) == .notFound else { return nil }
        let tabs = sessions.filter { $0.channel == nil }.map {
            tab($0, processes: SessionProcessScanner.identityProcesses(foregroundPID: $0.engine.foregroundPid ?? 0))
        }
        return resolve(pid: pid, startedAt: start, tabs: tabs, identity: SessionProcessScanner.identityMatches)
    }

    static func tab(_ session: Session, processes: [SessionProcessScanner.Raw]) -> Tab {
        Tab(id: session.id, customTitle: session.customTitle, folderName: session.currentDirectory.lastPathComponent, processes: processes)
    }

    static func resolve(pid: Int32, startedAt: UInt64, tabs: [Tab], identity: (Int32, UInt64) -> Bool) -> ChatLocalCaller? {
        guard identity(pid, startedAt) else { return nil }
        var found: [(Tab, SessionProcessScanner.Raw)] = []
        for tab in tabs {
            let byPID = Dictionary(tab.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            guard byPID[pid]?.startedAtUs == startedAt else { continue }
            var chain = Set<Int32>(), next = pid
            while next > 1, chain.insert(next).inserted, chain.count <= 256, let row = byPID[next] { next = row.ppid }
            let candidates = tab.processes.filter { $0.name == "claude" && chain.contains($0.pid) && identity($0.pid, $0.startedAtUs) }
            // Ambiguous nested Claude processes refuse, even in one terminal.
            guard candidates.count == 1 else { continue }
            found.append((tab, candidates[0]))
        }
        guard found.count == 1 else { return nil }
        let (tab, claude) = found[0]
        let base = name(tab)
        let duplicates = tabs.filter { name($0) == base && $0.processes.contains(where: { $0.name == "claude" && identity($0.pid, $0.startedAtUs) }) }.count
        let suffix = duplicates > 1 ? " \(tab.id.uuidString.lowercased().prefix(8))" : ""
        return ChatLocalCaller(surface: tab.id.uuidString.lowercased(), claudePID: claude.pid, claudeStart: claude.startedAtUs,
                               signature: limited(base, scalars: 120 - suffix.unicodeScalars.count) + suffix)
    }

    static func normalized(_ text: String) -> String {
        let clean = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !(0x202A...0x202E).contains($0.value)
                && !(0x2066...0x2069).contains($0.value) && ![0x200E, 0x200F, 0x061C].contains($0.value)
        }
        return limited(String(String.UnicodeScalarView(clean)).split(whereSeparator: \.isWhitespace).joined(separator: " "), scalars: 120)
    }

    /// PostgreSQL char_length counts Unicode scalars, while Swift's prefix
    /// counts graphemes. Keep whole graphemes within the server's 120 limit.
    static func limited(_ text: String, scalars maximum: Int) -> String {
        var result = "", count = 0
        for character in text {
            let size = character.unicodeScalars.count
            guard count + size <= maximum else { break }
            result.append(character); count += size
        }
        return result
    }

    static func name(_ tab: Tab) -> String {
        for value in [tab.customTitle, tab.folderName] {
            if let value, !normalized(value).isEmpty { return normalized(value) }
        }
        return "Claude Code \(tab.id.uuidString.lowercased().prefix(8))"
    }
}
