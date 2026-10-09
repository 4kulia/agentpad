import Foundation
import CryptoKit

/// Only ordinary text blocks are admitted. All source I/O runs in the utility
/// worker; no CLI, tool payload, project file or remote root is read here.
enum ConversationSource {
    static let agents = [AgentTemplate.claudeCodeID, AgentTemplate.codex.id]
    struct File: Sendable { var agent: String; var url: URL; var root: URL }
    struct Snapshot: Sendable {
        var record: AgentSessionRecord
        var turns: [ConversationTurn]
        var digest: String
        var checkpoint: UInt64
        var skipped: Int
        var partial: Bool
        var stamp: String
        var resumedFrom: UInt64 = 0
        var parserState: Data?
    }
    static func stamp(_ s: stat) -> String {
        "\(s.st_dev):\(s.st_ino):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec)"
    }
    static func safe(_ url: URL, under root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = url.standardizedFileURL
        guard file.resolvingSymlinksInPath().pathComponents.starts(with: base.pathComponents),
              file.resolvingSymlinksInPath() != base,
              (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        var current = file
        while current.path != "/" {
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
            if current.resolvingSymlinksInPath() == base { return true }
            current.deleteLastPathComponent()
        }
        return false
    }

    /// A throwing walk is essential: an unreadable root must never be mistaken
    /// for a successful empty enumeration and delete its saved sources.
    static func enumerate(_ roots: [String: URL]) throws -> [File] {
        var result: [File] = []
        let fm = FileManager.default
        for agent in agents {
            guard let supplied = roots[agent], fm.fileExists(atPath: supplied.path) else { continue }
            guard safe(supplied.appendingPathComponent("probe"), under: supplied) else { continue }
            let root = supplied.resolvingSymlinksInPath()
            var failure: Error?
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
                                            options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else {
                throw SearchProblem.unavailable
            }
            for case let url as URL in walker {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                if values.isSymbolicLink == true { walker.skipDescendants(); continue }
                guard values.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
                if agent == AgentTemplate.claudeCodeID {
                    guard url.resolvingSymlinksInPath().pathComponents.count == root.pathComponents.count + 2,
                          UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
                } else if !url.lastPathComponent.hasPrefix("rollout-") { continue }
                result.append(File(agent: agent, url: url, root: root))
            }
            if let failure { throw failure }
        }
        var dated: [(file: File, date: Date)] = []
        for file in result {
            let date = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            dated.append((file, date))
        }
        dated.sort { a, b in a.date == b.date ? a.file.url.path < b.file.url.path : a.date > b.date }
        return dated.map(\.file)
    }

    static func read(_ file: File, visibility: ChannelConversationFilter, throttled: Bool = true, previous: Snapshot? = nil) async throws -> Snapshot? {
        guard safe(file.url, under: file.root) else { throw SearchProblem.unavailable }
        let filenameID = file.url.deletingPathExtension().lastPathComponent
        guard visibility.allows(agentId: file.agent, conversationId: filenameID, root: file.root) else { return nil }
        let descriptor = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SearchProblem.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(); guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw SearchProblem.unavailable }
        let limit = UInt64(before.st_size)
        var parser = Parser(agent: file.agent, filenameID: filenameID)
        var hash = SHA256(), offset: UInt64 = 0, resumedFrom: UInt64 = 0
        // Verify the saved prefix without parsing it. Only a replacement,
        // truncation or changed prefix requires parsing again from byte zero.
        if let previous, let state = previous.parserState, previous.checkpoint <= limit,
           identity(previous.stamp) == identity(stamp(before)) {
            hash = try await prefixHash(handle, count: previous.checkpoint, throttled: throttled)
            if digest(hash) == previous.digest {
                parser = try JSONDecoder().decode(Parser.self, from: state)
                parser.turns = previous.turns
                offset = previous.checkpoint; resumedFrom = offset
            }
        }
        if resumedFrom == 0 { hash = SHA256(); try handle.seek(toOffset: 0) }
        var line = Data(), lineStart = offset, oversize = false
        var checkpoint = offset, checkpointHash = hash
        while offset < limit {
            try Task.checkCancellation()
            let start = Date()
            guard let data = try handle.read(upToCount: Int(min(65_536, limit - offset))), !data.isEmpty else { throw SearchProblem.changed }
            var position = data.startIndex
            while position < data.endIndex {
                let newline = data[position...].firstIndex(of: 10)
                let end = newline.map { data.index(after: $0) } ?? data.endIndex
                let fragment = data[position..<end]
                hash.update(data: newline == nil ? fragment : fragment.dropLast())
                let turnPrefix = newline == nil ? "" : digest(hash)
                if newline != nil { hash.update(data: Data([10])) }
                offset += UInt64(fragment.count)
                if !oversize {
                    if line.count + fragment.count <= 8 * 1_024 * 1_024 { line.append(contentsOf: fragment) }
                    else { line.removeAll(keepingCapacity: false); oversize = true }
                }
                if newline != nil {
                    if oversize { parser.skipped += 1 }
                    else if line.contains(where: { !$0.isJSONWhitespace }) {
                        parser.consume(line, offset: lineStart, prefix: turnPrefix)
                    }
                    checkpoint = offset; checkpointHash = hash; lineStart = offset
                    line.removeAll(keepingCapacity: true); oversize = false
                }
                position = end
            }
            try await throttle(start: start, bytes: data.count, enabled: throttled)
        }
        if !line.isEmpty, AgentSessionScanner.jsonObject(line) != nil {
            parser.consume(line, offset: lineStart, prefix: digest(hash)); checkpoint = offset; checkpointHash = hash
        }
        // Appends may continue while we read: publish the bounded prefix we
        // captured, after verifying it has not been rewritten underneath us.
        var after = stat(), current = stat()
        guard fstat(descriptor, &after) == 0, lstat(file.url.path, &current) == 0,
              current.st_dev == before.st_dev, current.st_ino == before.st_ino,
              after.st_size >= before.st_size else { throw SearchProblem.changed }
        if stamp(after) != stamp(before) {
            try handle.seek(toOffset: 0)
            let verified = try await prefixHash(handle, count: limit, throttled: throttled)
            guard digest(verified) == digest(hash), lstat(file.url.path, &current) == 0,
                  current.st_dev == before.st_dev, current.st_ino == before.st_ino,
                  current.st_size >= before.st_size else { throw SearchProblem.changed }
        }
        guard !parser.excluded, let id = parser.conversationID, let cwd = parser.cwd,
              visibility.allows(agentId: file.agent, conversationId: id, startedAt: parser.started, root: file.root) else { return nil }
        let record = AgentSessionRecord(agentId: file.agent, conversationId: id, title: parser.title ?? "", cwd: URL(fileURLWithPath: cwd),
            lastActivity: Date(timeIntervalSince1970: Double(before.st_mtimespec.tv_sec)), agentTitle: parser.title,
            firstPrompt: parser.firstPrompt, automatic: parser.automatic,
            startedAt: parser.started, fileURL: file.url)
        let turns = parser.turns
        parser.turns = [] // The database already stores the bounded turn window.
        return Snapshot(record: record, turns: turns, digest: digest(checkpointHash), checkpoint: checkpoint,
                        skipped: parser.skipped, partial: parser.partial || checkpoint < limit, stamp: stamp(before),
                        resumedFrom: resumedFrom, parserState: try JSONEncoder().encode(parser))
    }

    private static func identity(_ stamp: String) -> String { stamp.split(separator: ":").prefix(2).joined(separator: ":") }
    private static func digest(_ hash: SHA256) -> String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
    private static func prefixHash(_ handle: FileHandle, count: UInt64, throttled: Bool) async throws -> SHA256 {
        var hash = SHA256(), offset: UInt64 = 0
        while offset < count {
            try Task.checkCancellation()
            let start = Date()
            guard let data = try handle.read(upToCount: Int(min(65_536, count - offset))), !data.isEmpty else { throw SearchProblem.changed }
            hash.update(data: data); offset += UInt64(data.count)
            try await throttle(start: start, bytes: data.count, enabled: throttled)
        }
        return hash
    }
    private static func throttle(start: Date, bytes: Int, enabled: Bool) async throws {
        if enabled { try await Task.sleep(for: .seconds(max(Double(bytes) / 8_388_608, Date().timeIntervalSince(start) * 9))) }
        else { await Task.yield() }
    }

    private struct Parser: Codable {
        let agent: String
        let filenameID: String
        var conversationID: String?
        var cwd: String?
        var started: Date?
        var title: String?
        var firstPrompt: String?
        var automatic = false
        var excluded = false
        var turns: [ConversationTurn] = []
        var bytes = 0, ordinal = 0, skipped = 0
        var partial = false
        // Codex writes both representations of a visible message. Pair only
        // opposite representations, never two identical user turns.
        struct Pending: Codable { var kind: String; var role: String; var digest: String }
        var pendingCodex: Pending?

        mutating func consume(_ data: Data, offset: UInt64, prefix: String) {
            guard let object = AgentSessionScanner.jsonObject(data) else { skipped += 1; return }
            let type = object["type"] as? String ?? ""
            let date = (object["timestamp"] as? String).flatMap(ChatStore.date)
            if started == nil { started = date }
            var role: String?, text: String?, native: String?
            if agent == AgentTemplate.claudeCodeID {
                conversationID = filenameID
                if let id = object["sessionId"] as? String, id.lowercased() != filenameID.lowercased() { excluded = true; return }
                if object["isSidechain"] as? Bool == true { excluded = true; return }
                if object["entrypoint"] as? String == "sdk-cli" { automatic = true }
                if let value = object["cwd"] as? String { cwd = value }
                if type == "custom-title" { title = object["customTitle"] as? String }
                guard type == "user" || type == "assistant", object["isMeta"] as? Bool != true,
                      object["isCompactSummary"] as? Bool != true,
                      let message = object["message"] as? [String: Any] else { return }
                role = type; text = Self.text(message["content"], types: ["text"])
                native = type == "assistant" ? message["id"] as? String ?? object["uuid"] as? String : object["uuid"] as? String
            } else {
                guard let payload = object["payload"] as? [String: Any] else { return }
                if type == "session_meta" {
                    conversationID = CodexUsageMonitor.conversationId(fromSessionMetaPayload: payload)
                    cwd = CodexUsageMonitor.cwd(fromSessionMetaPayload: payload)
                    if (payload["source"] as? [String: Any])?["subagent"] != nil { excluded = true }
                    automatic = payload["originator"] as? String == "codex_exec" || payload["source"] as? String == "exec"
                    return
                }
                if type == "event_msg" {
                    switch payload["type"] as? String {
                    case "user_message": role = "user"
                    case "agent_message": role = "assistant"
                    default: return
                    }
                    text = payload["message"] as? String
                } else if type == "response_item", payload["type"] as? String == "message" {
                    role = payload["role"] as? String
                    text = Self.text(payload["content"], types: ["input_text", "output_text"])
                } else { return }
                native = payload["id"] as? String
            }
            guard let role, ["user", "assistant"].contains(role), let text, !text.isEmpty,
                  !Self.serviceText(text) else { return }
            if agent == AgentTemplate.codex.id, let pending = pendingCodex, pending.kind != type,
               pending.role == role, pending.digest == SearchQuery.digest(text) {
                pendingCodex = nil; return
            }
            ordinal += 1
            var utf8 = Data(text.utf8.prefix(65_536))
            while String(data: utf8, encoding: .utf8) == nil { utf8.removeLast() }
            let bounded = String(decoding: utf8, as: UTF8.self)
            if role == "user", firstPrompt == nil { firstPrompt = bounded }
            let id = native ?? "position:\(offset)"
            var turn = ConversationTurn(id: id, role: role, text: bounded, date: date, ordinal: ordinal, offset: offset, truncated: text.utf8.count > 65_536, prefixDigest: prefix)
            if let index = turns.firstIndex(where: { $0.id == id }) {
                turn.date = turns[index].date ?? turn.date; turn.ordinal = turns[index].ordinal
                bytes -= turns[index].text.utf8.count; turns[index] = turn
            }
            else { turns.append(turn) }
            bytes += bounded.utf8.count
            while bytes > 32 * 1_024 * 1_024 || turns.count > 50_000 {
                bytes -= turns.removeFirst().text.utf8.count; partial = true
            }
            partial = partial || turn.truncated
            if agent == AgentTemplate.codex.id { pendingCodex = Pending(kind: type, role: role, digest: SearchQuery.digest(text)) }
        }
        static func text(_ content: Any?, types: Set<String>) -> String? {
            if let text = content as? String { return text }
            return (content as? [[String: Any]])?.compactMap { block in
                guard let type = block["type"] as? String, types.contains(type) else { return nil as String? }
                return block["text"] as? String
            }.joined(separator: "\n")
        }
        static func serviceText(_ text: String) -> Bool {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ["<system-reminder>", "<environment_context>", "<permissions instructions>", "# AGENTS.md instructions", "<turn_aborted>",
                    "<command-name>", "<local-command", "Caveat:", "This session is being continued from a previous conversation"].contains { value.hasPrefix($0) }
        }
    }
}

private extension UInt8 {
    var isJSONWhitespace: Bool { self == 10 || self == 13 || self == 32 || self == 9 }
}
