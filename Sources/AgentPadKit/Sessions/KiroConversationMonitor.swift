import Darwin
import Foundation

/// Watches Kiro's opt-in ACP wire recording and extracts the exact session id
/// returned by `session/new`. AgentPad supplies a unique recording path per
/// terminal surface, so concurrent Kiro tabs cannot race through a shared
/// history database or accidentally claim one another's newest session.
@MainActor
final class KiroConversationMonitor {
    private struct Watch {
        let path: String
        let source: DispatchSourceFileSystemObject
        var pendingRead: DispatchWorkItem?
    }

    private var watches: [UUID: Watch] = [:]
    private var generation: [UUID: Int] = [:]
    private var recordPaths: [UUID: String] = [:]

    func start(
        sessionId: UUID,
        path: String,
        attempt: Int = 0,
        update: @MainActor @escaping (String) -> Void
    ) {
        recordPaths[sessionId] = path
        if watches[sessionId]?.path == path {
            scheduleRead(sessionId: sessionId, update: update)
            return
        }
        let token = (generation[sessionId] ?? 0) + 1
        generation[sessionId] = token

        guard FileManager.default.fileExists(atPath: path) else {
            // Kiro creates the record after its TUI/ACP process starts. Poll
            // for up to 30s; auth and first-run setup can delay session/new.
            guard attempt < 120 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.generation[sessionId] == token else { return }
                self.start(sessionId: sessionId, path: path, attempt: attempt + 1, update: update)
            }
            return
        }

        install(sessionId: sessionId, path: path, update: update)
        scheduleRead(sessionId: sessionId, update: update)
    }

    /// Stops watching one surface. `removeRecord` is reserved for a command
    /// or tab that is actually ending; cross-window tab handoff stops the
    /// source watcher without deleting the live Kiro process's recording.
    func stop(sessionId: UUID, removeRecord: Bool = false) {
        let path = recordPaths.removeValue(forKey: sessionId)
        guard watches[sessionId] != nil || generation[sessionId] != nil || path != nil else { return }
        generation[sessionId] = (generation[sessionId] ?? 0) + 1
        if let watch = watches.removeValue(forKey: sessionId) {
            watch.pendingRead?.cancel()
            watch.source.cancel()
        }
        if removeRecord, let path {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    func stopAll(removeRecords: Bool = false) {
        let ids = Set(watches.keys)
            .union(generation.keys)
            .union(recordPaths.keys)
        for id in ids {
            stop(sessionId: id, removeRecord: removeRecords)
        }
    }

    private func install(
        sessionId: UUID,
        path: String,
        update: @MainActor @escaping (String) -> Void
    ) {
        if let old = watches.removeValue(forKey: sessionId) {
            old.pendingRead?.cancel()
            old.source.cancel()
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                self.stop(sessionId: sessionId)
                self.start(sessionId: sessionId, path: path, update: update)
                return
            }
            self.scheduleRead(sessionId: sessionId, update: update)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watches[sessionId] = Watch(path: path, source: source, pendingRead: nil)
    }

    private func scheduleRead(
        sessionId: UUID,
        update: @MainActor @escaping (String) -> Void
    ) {
        guard var watch = watches[sessionId] else { return }
        watch.pendingRead?.cancel()
        let path = watch.path
        let token = (generation[sessionId] ?? 0) + 1
        generation[sessionId] = token
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let conversationId = Self.latestSessionId(atPath: path)
                DispatchQueue.main.async {
                    guard let self, self.generation[sessionId] == token else { return }
                    if let conversationId { update(conversationId) }
                }
            }
        }
        watch.pendingRead = work
        watches[sessionId] = watch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    nonisolated static func latestSessionId(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 4 * 1024 * 1024
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data = data.suffix(from: data.index(after: newline))
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return latestSessionId(in: text)
    }

    /// ACP recorders may wrap each JSON-RPC message in a direction/timestamp
    /// envelope. Walk every nested object, remember the request ids for
    /// `session/new`, then accept `result.sessionId` only from the matching
    /// response. `session/load` carries its exact id in the request params, so
    /// capture that directly when the user resumes/switches inside the TUI.
    /// This avoids grabbing tool-call or subagent session ids.
    nonisolated static func latestSessionId(in jsonLines: String) -> String? {
        var newRequestIds = Set<String>()
        var latest: String?

        for line in jsonLines.split(whereSeparator: \.isNewline) {
            guard let value = parseJSONLine(String(line)) else { continue }
            for object in dictionaries(in: value) {
                let method = object["method"] as? String
                if method == "session/new",
                   let id = jsonRPCId(object["id"]) {
                    newRequestIds.insert(id)
                }
                if method == "session/load",
                   let params = object["params"],
                   let sessionId = stringValue(forKeys: ["sessionId", "session_id"], in: params) {
                    latest = sessionId
                }
                guard let id = jsonRPCId(object["id"]),
                      newRequestIds.contains(id),
                      let result = object["result"],
                      let sessionId = stringValue(forKeys: ["sessionId", "session_id"], in: result)
                else { continue }
                latest = sessionId
            }
        }
        return latest
    }

    private nonisolated static func parseJSONLine(_ line: String) -> Any? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) {
            return value
        }
        // Some recorder versions prefix direction/timestamp text.
        guard let first = trimmed.firstIndex(of: "{"),
              let last = trimmed.lastIndex(of: "}"),
              first <= last
        else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(trimmed[first...last].utf8))
    }

    private nonisolated static func dictionaries(in value: Any) -> [[String: Any]] {
        if let object = value as? [String: Any] {
            return [object] + object.values.flatMap(dictionaries(in:))
        }
        if let array = value as? [Any] {
            return array.flatMap(dictionaries(in:))
        }
        return []
    }

    private nonisolated static func jsonRPCId(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private nonisolated static func stringValue(forKeys keys: [String], in value: Any) -> String? {
        if let object = value as? [String: Any] {
            for key in keys {
                if let raw = object[key] as? String {
                    let string = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !string.isEmpty { return string }
                }
            }
            for nested in object.values {
                if let found = stringValue(forKeys: keys, in: nested) { return found }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = stringValue(forKeys: keys, in: nested) { return found }
            }
        }
        return nil
    }
}
