import Foundation

@MainActor
struct AgentProfileSessionItem: Identifiable {
    /// A live row uses the tab's UUID, including before discovery finds an id.
    let id: String
    let session: Session?
    let record: AgentSessionRecord?
    let title: String
    let cwd: URL
    let lastActivity: Date

    var canOpen: Bool { session != nil || isDirectory(cwd) }
    var unavailableReason: String { "Original folder not found: \(cwd.path). This session cannot resume in another folder." }
}

@MainActor
enum AgentProfileSessions {
    static let pageSize = 5

    static func items(profile: AgentProfile, profiles: AgentProfileStore, sessions: [Session],
                      visibility: ChannelConversationFilter = .current(), names: [SessionNameKey: String] = [:]) -> [AgentProfileSessionItem] {
        let records = visibility.apply(profiles.records(for: profile.id))
        let byConversation = Dictionary(records.map { ($0.conversationId, $0) }, uniquingKeysWith: { first, _ in first })
        var liveConversations: Set<String> = []
        var result: [AgentProfileSessionItem] = []
        for session in sessions where session.hasProcess && session.sshWorkspaceHost == nil {
            let conversation = session.conversationId ?? session.resumedConversationId
            let record = conversation.flatMap { byConversation[$0] }
            guard session.profileID == profile.id || (session.agent.rosterId == profile.rosterID && record != nil),
                  visibility.allows(agentId: profile.rosterID, conversationId: conversation) else { continue }
            if let conversation { liveConversations.insert(conversation) }
            let name = conversation.flatMap { names[SessionNameKey(profile.rosterID, $0)] }
            result.append(AgentProfileSessionItem(id: session.id.uuidString, session: session, record: record,
                title: name ?? SessionTitle.nonempty(record?.title) ?? session.title,
                cwd: record?.cwd ?? session.profileOriginalCwd ?? session.currentDirectory,
                lastActivity: max(session.hookStateAt, session.catalogStartedAt, record?.lastActivity ?? .distantPast)))
        }
        for record in records where !liveConversations.contains(record.conversationId) {
            result.append(AgentProfileSessionItem(id: record.id, session: nil, record: record,
                title: names[record.nameKey] ?? record.resolvedTitle(), cwd: record.cwd, lastActivity: record.lastActivity))
        }
        return result.sorted {
            $0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : $0.id < $1.id
        }
    }

    static func page(_ items: [AgentProfileSessionItem], limit: Int) -> [AgentProfileSessionItem] {
        Array(items.prefix(max(pageSize, limit)))
    }
}
