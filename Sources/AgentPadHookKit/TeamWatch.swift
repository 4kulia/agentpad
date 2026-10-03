import Foundation

// AgentPad: `agentpad-cli team watch <call-id>` — what a colleague's call is
// doing on this Mac, live, in a tab of its own. Reads the copy of the run's
// events the app keeps in `team/runs/<call-id>.jsonl` and prints it as text.

public enum AgentPadTeamWatch {
    public static func logPath(callId: String) -> String? {
        guard UUID(uuidString: callId) != nil else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("\(AppIdentity.supportDirectoryName)/team/runs/\(callId.lowercased()).jsonl").path
    }

    /// Where a watched run stands.
    public struct Progress: Equatable {
        public var answered = false
        public var ended = false
        public init() {}
    }

    /// One event as lines for the terminal, or nil for events not worth
    /// showing.
    public static func render(_ line: Data, progress: inout Progress) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        switch type {
        case "agentpad_request" where object["continuation"] as? Bool == true:
            let folders = (object["folders"] as? [String] ?? []).map { AgentPadHookKit.plain($0) }.joined(separator: ", ")
            return dim(String(repeating: "─", count: 40)) + "\n" + bold("Continuing with access the owner granted") + dim(folders.isEmpty ? "" : "  \(folders)")
        case "agentpad_request":
            let from = AgentPadHookKit.plain(object["from"] as? String ?? "a colleague")
            let agent = AgentPadHookKit.plain(object["agent"] as? String ?? "agent")
            var lines = [
                bold("Team call: \(from) → \(agent)") + dim("  [\(AgentPadHookKit.plain(object["access"] as? String ?? ""))] \(AgentPadHookKit.plain(object["folder"] as? String ?? ""))"),
            ]
            if object["copyOfSession"] as? Bool == true { lines.append(dim("Runs on a copy of the published session's conversation.")) }
            lines.append(dim("Request:"))
            lines.append(indent(AgentPadHookKit.plainText(object["prompt"] as? String ?? ""), "  "))
            lines.append(dim(String(repeating: "─", count: 40)))
            return lines.joined(separator: "\n")
        case "system":
            guard object["subtype"] as? String == "init" else { return nil }
            let model = AgentPadHookKit.plain(object["model"] as? String ?? "")
            return dim("Claude Code started\(model.isEmpty ? "" : " · \(model)")")
        case "assistant":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            var out: [String] = []
            for part in content {
                switch part["type"] as? String {
                case "text":
                    let text = AgentPadHookKit.plainText(part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { out.append(text) }
                case "tool_use":
                    let name = AgentPadHookKit.plain(part["name"] as? String ?? "tool")
                    out.append(cyan("▸ \(name)") + dim(summary(part["input"])))
                default:
                    break
                }
            }
            return out.isEmpty ? nil : out.joined(separator: "\n")
        case "user":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let results = content.filter { $0["type"] as? String == "tool_result" }
            guard !results.isEmpty else { return nil }
            return results.map { result in
                let text = resultText(result["content"])
                let head = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(4).map { AgentPadHookKit.plain(String($0)) }
                let more = text.split(separator: "\n").count > 4 ? dim(" …") : ""
                let mark = result["is_error"] as? Bool == true ? "  ⎿ ✗ " : "  ⎿ "
                return dim(mark + head.joined(separator: "\n    ")) + more
            }.joined(separator: "\n")
        case "agentpad_end":
            progress.ended = true
            return progress.answered ? nil : dim(String(repeating: "─", count: 40)) + "\n" + bold("Stopped") + dim("  the run ended without an answer")
        case "result":
            progress.answered = true
            let turns = (object["num_turns"] as? Int).map { "\($0) steps" } ?? ""
            let seconds = (object["duration_ms"] as? Int).map { String(format: "%.0f s", Double($0) / 1000) } ?? ""
            let failed = object["is_error"] as? Bool == true
            return dim(String(repeating: "─", count: 40)) + "\n"
                + bold(failed ? "Ended with an error" : "Done") + dim("  \([turns, seconds].filter { !$0.isEmpty }.joined(separator: " · "))")
                + "\n" + dim("This answer went to the colleague's agent.")
        default:
            return nil
        }
    }

    /// Follows the log until the run ends; prints a waiting line while the
    /// call has not started. Returns the thread's session id, if known.
    @discardableResult
    public static func follow(path: String, waitForStart: TimeInterval = 3600, out: (String) -> Void,
                              isStillWanted: () -> Bool = { true }) -> String? {
        var announced = false
        let gaveUp = Date().addingTimeInterval(waitForStart)
        while !FileManager.default.fileExists(atPath: path) {
            if !announced {
                out(dim("Waiting for the call to start — it runs once it is allowed and a slot is free…"))
                announced = true
            }
            guard isStillWanted() else { return nil }
            if Date() > gaveUp {
                out(dim("The call has not started; it may have been declined or cancelled. Close this tab."))
                return nil
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            out("Cannot read \(path).")
            return nil
        }
        defer { try? handle.close() }
        var buffer = Data()
        var progress = Progress()
        var session: String?
        // The app always ends the log with `agentpad_end`, also for a run
        // that was stopped; a long silent tool run is just waited out.
        // After the end of a run, a few seconds more: a run that was granted
        // a folder goes on in the same log.
        var quietAfterEnd = 0
        while isStillWanted() {
            let chunk = handle.availableData
            if chunk.isEmpty {
                if progress.ended {
                    quietAfterEnd += 1
                    if quietAfterEnd > 60 { break }  // 15 s: a continuation starts once the old run is fully stopped
                }
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }

            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   object["type"] as? String == "agentpad_request" {
                    if session == nil { session = object["session"] as? String }
                    // A continuation starts: the run is not over after all.
                    progress = Progress()
                    quietAfterEnd = 0
                }
                if let text = render(Data(line), progress: &progress) { out(text) }
            }
        }
        return session
    }

    // MARK: Formatting

    private static func summary(_ input: Any?) -> String {
        guard let input = input as? [String: Any] else { return "" }
        let preferred = ["command", "file_path", "pattern", "path", "description", "url"]
        for key in preferred {
            if let value = input[key] as? String, !value.isEmpty {
                let one = AgentPadHookKit.plain(value)
                return "  " + (one.count > 160 ? String(one.prefix(160)) + "…" : one)
            }
        }
        return ""
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    private static func indent(_ text: String, _ prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
    }

    private static func bold(_ s: String) -> String { "\u{1B}[1m\(s)\u{1B}[0m" }
    private static func dim(_ s: String) -> String { "\u{1B}[2m\(s)\u{1B}[0m" }
    private static func cyan(_ s: String) -> String { "\u{1B}[36m\(s)\u{1B}[0m" }
}
