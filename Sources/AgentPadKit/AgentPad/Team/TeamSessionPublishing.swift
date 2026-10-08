import AppKit
import SwiftUI

/// A session's publication opens in the same editor as its catalog entry.
struct TeamPublishMenu: View {
    /// The Claude Code conversation; nil for other agents, which shows nothing.
    let sessionId: String?
    let title: String
    var surfaceId: UUID? = nil

    var body: some View {
        if let sessionId, TeamSessionFiles.isValidId(sessionId), ChannelConversationFilter.current().allows(conversationId: sessionId) {
            Menu("Publish to Team") {
                Button("Publish…") { TeamTabs.shared.publish(sessionID: sessionId, title: title, surfaceID: surfaceId) }
                let published = TeamTabs.shared.currentScope.map { TeamTabs.shared.agents($0).filter { $0.sessionId == sessionId.lowercased() } } ?? []
                if !published.isEmpty {
                    Divider()
                    Button("Stop Publishing This Session") {
                        TeamTabs.shared.stopPublishing(published)
                    }
                }
            }
        }
    }
}

/// What a session is published as.
enum TeamPublishMode: String, CaseIterable, Identifiable, Codable {
    case session, folder, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .session: "This session"
        case .folder: "New agent in its folder"
        case .both: "Both"
        }
    }
}

/// Target-selection helpers shared by the session form and its regression tests.
@MainActor
enum TeamSessionPublication {
    /// The teams to show when the agents edited are `edited` (they were
    /// `previous`): theirs — General only for a new publication — or nil
    /// when the agent edited did not change, so the owner's own choice stays.
    static func restored(edited: [TeamPublishedAgent], previous: [UUID]?, general: [String],
                         earlier: (UUID) -> [String]?) -> Set<String>? {
        guard edited.map(\.id) != previous else { return nil }
        return Set(edited.compactMap { earlier($0.id) }.first ?? general)
    }

    /// The existing agents a publication in `mode` changes.
    static func edited(mode: TeamPublishMode, sessionId: String, folderName: String, folder: String?,
                       calls: TeamCalls) -> [TeamPublishedAgent] {
        var out: [TeamPublishedAgent] = []
        if mode != .folder, let agent = calls.agents(forSession: sessionId).first { out.append(agent) }
        if mode != .session, let folder, let agent = folderAgent(name: folderName, folder: folder, calls: calls) { out.append(agent) }
        return out
    }

    /// The folder agent of this session's folder by that name: an update of it.
    static func folderAgent(name: String, folder: String, calls: TeamCalls) -> TeamPublishedAgent? {
        calls.agents.first { $0.name == name.lowercased() && !$0.isSession && $0.folder == folder }
    }

}
