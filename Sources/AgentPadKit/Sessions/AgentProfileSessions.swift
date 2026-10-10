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
                      catalog: SessionCatalog = .shared,
                      visibility: ChannelConversationFilter = .current(), names: [SessionNameKey: String] = [:]) -> [AgentProfileSessionItem] {
        let records = visibility.apply(profiles.records(for: profile.id))
        let byConversation = Dictionary(records.map { ($0.conversationId, $0) }, uniquingKeysWith: { first, _ in first })
        var liveConversations: Set<String> = []
        var result: [AgentProfileSessionItem] = []
        for session in sessions where session.hasProcess && session.sshWorkspaceHost == nil {
            let conversation = session.conversationId ?? session.resumedConversationId
            let bound = conversation.flatMap { byConversation[$0] }
            let scanned = conversation.flatMap { catalog.record(for: SessionNameKey(profile.rosterID, $0)) }
            let record = scanned ?? bound
            guard session.profileID == profile.id || (session.launchOrigin?.templateID == profile.templateID && session.agent.rosterId == profile.rosterID && bound != nil),
                  visibility.allows(agentId: profile.rosterID, conversationId: conversation) else { continue }
            if let conversation { liveConversations.insert(conversation) }
            let name = conversation.flatMap { names[SessionNameKey(profile.rosterID, $0)] }
            let cwd = bound?.cwd ?? session.profileOriginalCwd ?? session.currentDirectory
            let metadata = SessionDisplayMetadata.resolve(catalog: scanned, binding: bound,
                live: .init(session: session, manualTitle: name), folderName: cwd.lastPathComponent)
            result.append(AgentProfileSessionItem(id: session.id.uuidString, session: session, record: record,
                title: metadata.title, cwd: cwd, lastActivity: metadata.lastActivity))
        }
        let template = AgentTemplate.all.first { $0.id == profile.templateID }?.title
        for bound in records where !liveConversations.contains(bound.conversationId) {
            let scanned = catalog.record(for: bound.nameKey)
            let metadata = SessionDisplayMetadata.resolve(catalog: scanned, binding: bound,
                live: .init(templateTitle: template, manualTitle: names[bound.nameKey]), folderName: bound.cwd.lastPathComponent)
            result.append(AgentProfileSessionItem(id: bound.id, session: nil, record: scanned ?? bound,
                title: metadata.title, cwd: bound.cwd, lastActivity: metadata.lastActivity))
        }
        return result.sorted {
            $0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : $0.id < $1.id
        }
    }

    static func page(_ items: [AgentProfileSessionItem], limit: Int) -> [AgentProfileSessionItem] {
        Array(items.prefix(max(pageSize, limit)))
    }
}
