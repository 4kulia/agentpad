import Foundation
import GRDB

/// One policy for ordinary session readers/actions. Channel conversations belong
/// to the channel gateway even after publication, sign-out or result erasure.
/// Do not derive this from the disposable organization cache or current mode.
struct ChannelConversationFilter: Sendable {
    private let channelIds: Set<String>?

    init(channelIds: Set<String>?) {
        self.channelIds = channelIds.map { Set($0.map { $0.lowercased() }) }
    }

    static func read(_ db: Database) throws -> Self {
        Self(channelIds: Set(try String.fetchAll(db, sql: "SELECT DISTINCT conversation_id FROM runs WHERE kind = 'channel'")))
    }

    /// Read-only, including when Team is off. A missing journal has no channel
    /// runs; an unreadable journal cannot prove a Claude conversation is personal.
    static func current(journalURL: URL = ChatFiles.standard.journalURL) -> Self {
        var info = stat()
        if lstat(journalURL.path, &info) != 0 {
            return Self(channelIds: errno == ENOENT ? [] : nil)
        }
        do {
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: journalURL.path, configuration: config)
            return try queue.read { try read($0) }
        } catch { return Self(channelIds: nil) }
    }

    func allows(agentId: String = AgentTemplate.claudeCodeID, conversationId: String?) -> Bool {
        guard agentId == AgentTemplate.claudeCodeID, let conversationId else { return true }
        return channelIds.map { !$0.contains(conversationId.lowercased()) } ?? false
    }

    func apply(_ records: [AgentSessionRecord]) -> [AgentSessionRecord] {
        records.filter { allows(agentId: $0.agentId, conversationId: $0.conversationId) }
    }
}
