import Foundation
import GRDB

/// A small, local set, independent of organization caches, accounts and the
/// resettable run journal. It only prevents executors from inheriting DM context.
struct ChatDMHistory: Sendable {
    let files: ChatFiles
    private static let lock = NSLock()
    var url: URL { files.directory.appendingPathComponent("dm-conversations.json") }

    private func read() throws -> Set<String> {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return [] }
            throw ChatSessionTools.Failure(code: "dm_not_allowed")
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ChatSessionTools.Failure(code: "dm_not_allowed") }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)).map { $0.lowercased() })
    }

    func contains(_ conversation: String) throws -> Bool {
        try Self.lock.withLock { try read().contains(conversation.lowercased()) }
    }

    func record(_ conversation: String) throws {
        try record([conversation])
    }

    func record(_ conversations: Set<String>) throws {
        try Self.lock.withLock {
            let normalized = try conversations.map { conversation in
                guard let id = UUID(uuidString: conversation) else { throw ChatSessionTools.Failure(code: "dm_not_allowed") }
                return id.uuidString.lowercased()
            }
            var ids = try read()
            guard !Set(normalized).isSubset(of: ids) else { return }
            ids.formUnion(normalized)
            try files.writePrivate(try JSONEncoder().encode(ids.sorted()), to: url)
        }
    }

    /// Failure to read the set cannot authorize inherited context.
    func needsFreshSession(_ conversation: String) -> Bool { (try? contains(conversation)) ?? true }
    static let publicationNote = "Private messages were read in this session; colleagues get a fresh session"
}

@MainActor
enum ChatPersonalAccess {
    struct Conversation: Equatable {
        let id: String
        let launchId: String?
        var ids: Set<String> { Set([id, launchId].compactMap { $0 }) }

        init(_ id: String, launchId: String? = nil) {
            self.id = id.lowercased()
            self.launchId = launchId?.lowercased()
        }
    }

    /// Called only after live process verification. Hook routing/history UUIDs
    /// by themselves cannot establish the binding to that signed Claude process.
    static func conversation(caller: ChatLocalCaller, sessions: [Session]) throws -> Conversation {
        let matches = sessions.filter { $0.id.uuidString.lowercased() == caller.surface && $0.hasProcess }
        guard matches.count == 1, let tab = matches.first, tab.effectiveRemoteHost == nil,
              let binding = tab.answerBinding, let provenance = binding.provenance,
              provenance.process == binding.process,
              binding.process.pid == caller.claudePID, binding.process.startedAtUs == caller.claudeStart,
              let id = UUID(uuidString: binding.conversation),
              tab.conversationId?.lowercased() == id.uuidString.lowercased() else {
            throw ChatSessionTools.Failure(code: "dm_not_allowed")
        }
        return Conversation(id.uuidString, launchId: tab.launchedConversationId)
    }

    /// Role is deliberately independent of channel attribution/sessionAuthor.
    /// Every run kind and every account/org in the journal counts.
    static func require(_ conversation: Conversation, caller: ChatLocalCaller, service: ChatService) throws {
        guard let journal = service.journal else { throw ChatSessionTools.Failure(code: "dm_not_allowed") }
        do {
            let publications = try journal.queue.read { db -> [String] in
                for id in conversation.ids {
                    guard try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM runs WHERE lower(conversation_id) = ?)",
                                            arguments: [id])! else { throw ChatSessionTools.Failure(code: "dm_not_allowed") }
                }
                guard try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM publication_surfaces WHERE surface_id = ?)",
                                        arguments: [caller.surface])! else {
                    throw ChatSessionTools.Failure(code: "dm_not_allowed")
                }
                return try String.fetchAll(db, sql: "SELECT DISTINCT agent_id FROM assignments")
            }
            guard !publications.contains(where: { service.localAgent($0)?.sessionId.map { conversation.ids.contains($0.lowercased()) } == true }) else {
                throw ChatSessionTools.Failure(code: "dm_not_allowed")
            }
        } catch { throw ChatSessionTools.Failure(code: "dm_not_allowed") }
    }
}
