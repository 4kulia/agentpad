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
    struct Binding {
        let conversation: String
        let owner: AgentAnswerProvenance.Snapshot
    }

    struct Conversation: Equatable {
        let id: String
        let launchId: String?
        var ids: Set<String> { Set([id, launchId].compactMap { $0 }) }

        init(_ id: String, launchId: String? = nil) {
            self.id = id.lowercased()
            self.launchId = launchId?.lowercased()
        }
    }

    /// One request-local guard for every personal DM operation. Recheck the
    /// same conversation and role after suspension; a previous send or taint
    /// entry never grants access to a later call.
    @MainActor
    struct Authorization {
        let conversation: Conversation
        private let check: @MainActor () throws -> Conversation

        init(caller: ChatLocalCaller, service: ChatService,
             personalConversation: @escaping @MainActor () throws -> Conversation,
             revalidate: @escaping @MainActor () throws -> Bool) throws {
            let check: @MainActor () throws -> Conversation = {
                do {
                    let conversation = try personalConversation()
                    try ChatPersonalAccess.require(conversation, caller: caller, service: service)
                    // Check the live caller last, after the synchronous journal
                    // and publication reads, immediately before using access.
                    guard try revalidate() else { throw ChatSessionTools.Failure(code: "dm_not_allowed") }
                    return conversation
                } catch { throw ChatSessionTools.Failure(code: "dm_not_allowed") }
            }
            self.conversation = try check()
            self.check = check
        }

        func requireCurrent() throws {
            guard try check() == conversation else { throw ChatSessionTools.Failure(code: "dm_not_allowed") }
        }
    }

    /// Called only after live process verification. Hook routing/history UUIDs
    /// by themselves cannot establish the binding to that signed Claude process.
    static func conversation(caller: ChatLocalCaller, sessions: [Session],
                             kernel: ChatSessionIdentity.Kernel = .init()) throws -> Conversation {
        let matches = sessions.filter { $0.id.uuidString.lowercased() == caller.surface && $0.hasProcess }
        guard matches.count == 1, let tab = matches.first, tab.effectiveRemoteHost == nil,
              !HookServer.pendingConversations.contains(tab.id),
              let binding = tab.personalBinding,
              binding.owner.process.pid == caller.claudePID, binding.owner.process.startedAtUs == caller.claudeStart,
              kernel.process(caller.claudePID) == binding.owner.process,
              kernel.image(caller.claudePID) == binding.owner.image,
              let id = UUID(uuidString: binding.conversation),
              tab.conversationId?.lowercased() == id.uuidString.lowercased() else {
            throw ChatSessionTools.Failure(code: "dm_not_allowed")
        }
        return Conversation(id.uuidString, launchId: tab.launchedConversationId)
    }

    /// Hook authentication is off-main and can finish after MCP verification.
    /// Wait briefly for that evidence, never authorize a saved/resume UUID alone.
    static func waitForConversation(_ verified: ChatSessionIdentity.Verification,
                                    sessions: @escaping @MainActor () -> [Session],
                                    kernel: ChatSessionIdentity.Kernel,
                                    isCallerWaiting: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while true {
            try Task.checkCancellation()
            guard isCallerWaiting() else { throw ChatSessionTools.Failure(code: "dm_not_allowed") }
            try ChatSessionIdentity.revalidate(verified, sessions: sessions(), kernel: kernel)
            if (try? conversation(caller: verified.caller, sessions: sessions(), kernel: kernel)) != nil { return }
            guard ContinuousClock.now < deadline else { throw ChatSessionTools.Failure(code: "dm_not_allowed") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Role is deliberately independent of channel attribution/sessionAuthor.
    /// Every run kind and every account/org in the journal counts.
    static func require(_ conversation: Conversation, caller: ChatLocalCaller, service: ChatService) throws {
        guard let journal = service.journal else { throw ChatSessionTools.Failure(code: "dm_not_allowed") }
        do {
            let incompleteBefore = try journal.executorConversations.seedIncompleteBefore()
            for id in conversation.ids {
                guard try !journal.executorConversations.contains(id),
                      ExecutorConversations.allowsHistory(id, incompleteBefore: incompleteBefore, root: service.claudeProjectsRoot)
                else { throw ChatSessionTools.Failure(code: "dm_not_allowed") }
            }
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
