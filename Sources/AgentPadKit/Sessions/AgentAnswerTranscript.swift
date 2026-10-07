import Foundation

/// Reads only the conversation already bound to a tab. Never searches by cwd,
/// activity time or transcript contents, and never uses terminal scrollback.
enum AgentAnswerTranscript {
    enum Agent: Sendable { case claude, codex }
    enum Problem: String, Error, LocalizedError {
        // AgentPad: ID discovery alone does not establish export provenance.
        case unbound = "Copy and Forward are available once this tab's Claude answers again."
        case unverified = "AgentPad cannot verify this Codex journal. Copy selected text from the terminal."
        case missing = "The conversation journal for this tab was not found. Copy from the terminal or retry after the agent has saved its answer."
        case unknown = "This conversation journal uses an unsupported or damaged format. No answer was copied."
        case noAnswer = "This conversation does not contain an assistant answer yet."
        case changed = "The conversation or terminal processes changed. Wait for this tab's Claude to answer again."
        case tooLarge = "This journal contains a record too large to read safely. Save a shorter answer and retry."
        case remote = "The journal of a remote agent is not available on this Mac."
        var errorDescription: String? { rawValue }
    }

    static func read(agent: Agent, conversation: String, root: URL) throws -> String {
        guard let uuid = UUID(uuidString: conversation) else { throw Problem.unbound }
        let id = uuid.uuidString.lowercased()
        let file: URL?
        switch agent {
        case .claude:
            file = AgentSessionScanner.claudeTranscript(conversationId: id, root: root)
        case .codex:
            // Filename-only enumeration; even metadata from a sibling is private.
            let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
            file = entries?.compactMap { $0 as? URL }.first {
                $0.lastPathComponent.hasPrefix("rollout-") && $0.lastPathComponent.hasSuffix("-\(id).jsonl")
                    && isLocalFile($0, under: root)
            }
        }
        guard let file, isLocalFile(file, under: root), let handle = try? FileHandle(forReadingFrom: file) else {
            throw Problem.missing
        }
        defer { try? handle.close() }
        do {
            // A fixed-size snapshot cannot chase an actively growing journal.
            var remaining = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            var parser = Parser(agent: agent, conversation: id), pending = Data()
            while remaining > 0 {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: Int(min(remaining, 64 * 1024))), !chunk.isEmpty else { break }
                remaining -= UInt64(chunk.count)
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    try parser.consume(Data(pending[..<newline]))
                    pending.removeSubrange(...newline)
                }
                guard pending.count <= 32 * 1024 * 1024 else { throw Problem.tooLarge }
            }
            // An incomplete append is not an answer. A complete final JSON
            // record without a newline is valid too.
            if !pending.isEmpty, (try? JSONSerialization.jsonObject(with: pending)) != nil { try parser.consume(pending) }
            return try parser.finish()
        } catch let problem as Problem { throw problem }
        catch is CancellationError { throw CancellationError() }
        catch { throw Problem.missing }
    }

    static func isLocalFile(_ file: URL, under root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let plain = file.standardizedFileURL
        let resolved = plain.resolvingSymlinksInPath()
        return resolved.pathComponents.starts(with: base.pathComponents)
            && resolved.pathComponents.count > base.pathComponents.count
            && resolved == base.appendingPathComponent(plain.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count).joined(separator: "/"))
            && (try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map {
                $0.isRegularFile == true && $0.isSymbolicLink != true
            } == true
    }

    struct Parser {
        let agent: Agent
        let conversation: String
        private var recognized = false
        private var latest: String?
        private var groupID: String?
        private var blocks: [(id: String, text: String)] = []

        init(agent: Agent, conversation: String) { self.agent = agent; self.conversation = conversation }

        mutating func consume(_ data: Data) throws {
            if data.allSatisfy({ [9, 13, 32].contains($0) }) { return }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { throw Problem.unknown }
            switch agent {
            case .claude:
                if let id = object["sessionId"] as? String, id.lowercased() != conversation { throw Problem.changed }
                guard object["isSidechain"] as? Bool != true else { throw Problem.changed }
                if type == "user" { recognized = true }
                guard type == "assistant" else { return }
                recognized = true
                guard let message = object["message"] as? [String: Any], message["role"] as? String == "assistant" else { throw Problem.unknown }
                let text = try Self.text(message["content"], textType: "text", ignored: ["tool_use", "thinking", "redacted_thinking"])
                let id = message["id"] as? String ?? UUID().uuidString
                if id != groupID { groupID = id; blocks = [] }
                if !text.isEmpty {
                    let blockID = object["uuid"] as? String ?? UUID().uuidString
                    if let index = blocks.firstIndex(where: { $0.id == blockID }) { blocks[index].text = text }
                    else { blocks.append((blockID, text)) }
                    latest = blocks.map(\.text).joined(separator: "\n\n")
                }
            case .codex:
                guard let payload = object["payload"] as? [String: Any] else { throw Problem.unknown }
                if type == "session_meta" {
                    guard (payload["id"] as? String ?? payload["session_id"] as? String)?.lowercased() == conversation else { throw Problem.changed }
                    recognized = true
                } else if type == "response_item", payload["type"] as? String == "message", payload["role"] as? String == "assistant" {
                    guard Self.isFinal(payload) else { return }
                    let text = try Self.text(payload["content"], textType: "output_text", ignored: [])
                    if !text.isEmpty { latest = text }
                } else if type == "event_msg", payload["type"] as? String == "agent_message", Self.isFinal(payload) {
                    // Older rollouts use this event; newer ones also write a
                    // response_item. Replacing, not appending, avoids duplicates.
                    guard let text = payload["message"] as? String else { throw Problem.unknown }
                    if !text.isEmpty { latest = text }
                }
            }
        }

        private static func isFinal(_ payload: [String: Any]) -> Bool {
            payload["phase"] == nil || payload["phase"] is NSNull || payload["phase"] as? String == "final_answer"
        }

        private static func text(_ content: Any?, textType: String, ignored: Set<String>) throws -> String {
            if let string = content as? String { return string }
            guard let content = content as? [[String: Any]] else { throw Problem.unknown }
            return try content.compactMap { block -> String? in
                guard let type = block["type"] as? String else { throw Problem.unknown }
                if ignored.contains(type) { return nil }
                guard type == textType, let text = block["text"] as? String else { throw Problem.unknown }
                return text
            }.joined(separator: "\n\n")
        }

        func finish() throws -> String {
            guard recognized else { throw Problem.unknown }
            guard let latest, !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Problem.noAnswer }
            return latest
        }
    }
}

enum AgentAnswerText {
    /// Keep whole graphemes, including emoji and combining marks, inside the
    /// server's byte limit. Copy and Save always use the unabridged draft.
    static func forSending(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let suffix = "\n\n[Truncated]"
        let budget = max(0, maxBytes - suffix.utf8.count)
        var count = 0, result = ""
        for character in text {
            let size = character.utf8.count
            guard count + size <= budget else { break }
            result.append(character); count += size
        }
        return result + (maxBytes >= suffix.utf8.count ? suffix : "")
    }
}
