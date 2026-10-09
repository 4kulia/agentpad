import Foundation
import GRDB

/// One policy for ordinary session readers/actions. Executor conversations stay
/// behind the approval gateway even after sign-out, journal reset or result erasure.
/// Do not derive this from the disposable organization cache or current mode.
struct ChannelConversationFilter: Sendable {
    private let channelIds: Set<String>?
    private let seedIncompleteBefore: Date?

    init(channelIds: Set<String>?, seedIncompleteBefore: Date? = nil) {
        self.channelIds = channelIds.map { Set($0.map { $0.lowercased() }) }
        self.seedIncompleteBefore = seedIncompleteBefore
    }

    static func read(_ db: Database, executorIds: Set<String> = [], seedIncompleteBefore: Date? = nil) throws -> Self {
        Self(channelIds: executorIds.union(try String.fetchAll(db, sql: "SELECT DISTINCT conversation_id FROM runs")),
             seedIncompleteBefore: seedIncompleteBefore)
    }

    /// Read-only, including when Team is off. Persistent marks still apply with
    /// no journal; either unreadable source cannot prove a conversation personal.
    static func current(journalURL: URL = ChatFiles.standard.journalURL) -> Self {
        do {
            let executors = ExecutorConversations(files: ChatFiles(directory: journalURL.deletingLastPathComponent()))
            let ids = try executors.ids(), incompleteBefore = try executors.seedIncompleteBefore()
            var info = stat()
            if lstat(journalURL.path, &info) != 0 {
                return Self(channelIds: errno == ENOENT ? ids : nil, seedIncompleteBefore: incompleteBefore)
            }
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: journalURL.path, configuration: config)
            return try queue.read { try read($0, executorIds: ids, seedIncompleteBefore: incompleteBefore) }
        } catch { return Self(channelIds: nil) }
    }

    func allows(agentId: String = AgentTemplate.claudeCodeID, conversationId: String?, startedAt: Date? = nil,
                root: URL = ClaudeSessionResume.projectsRoot()) -> Bool {
        guard agentId == AgentTemplate.claudeCodeID, let conversationId else { return true }
        guard let channelIds, !channelIds.contains(conversationId.lowercased()) else { return false }
        return ExecutorConversations.allowsHistory(conversationId, incompleteBefore: seedIncompleteBefore, startedAt: startedAt, root: root)
    }

    func apply(_ records: [AgentSessionRecord]) -> [AgentSessionRecord] {
        records.filter { allows(agentId: $0.agentId, conversationId: $0.conversationId, startedAt: $0.startedAt) }
    }
}
