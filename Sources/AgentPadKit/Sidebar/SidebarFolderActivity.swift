import AgentPadTelegram
import Foundation

extension SidebarItemSummary {
    static func channel(_ channel: ChatSidebarSnapshot.Channel, scope: ChatOrgKey) -> Self {
        .init(reference: .agentpad(.channel(.init(server: scope.server.description, account: scope.accountId, org: scope.orgId, channel: channel.id))),
              title: channel.card.name, activity: channel.activity, unread: channel.isUnread, attention: channel.mentions > 0)
    }
    static func person(_ person: ChatDMPerson, scope: ChatOrgKey) -> Self {
        let activity = person.conversation?.lastUsed
        return .init(reference: .agentpad(.person(.init(server: scope.server.description, account: scope.accountId, org: scope.orgId, peer: person.id))),
                     title: person.peer.name, activity: activity == .distantPast ? nil : activity,
                     unread: person.unread, muted: person.roots.muted)
    }
    static func myAgent(_ profile: AgentProfile, sessions: [AgentSessionRecord]) -> Self {
        .init(reference: .agentpad(.myAgent(profile.id)), title: profile.name,
              activity: sessions.map(\.lastActivity).max() ?? profile.createdAt)
    }
    static func teamAgent(_ agent: ChatSidebarSnapshot.Agent, scope: ChatOrgKey) -> Self {
        .init(reference: .agentpad(.teamAgent(.init(server: scope.server.description, account: scope.accountId, org: scope.orgId, agent: agent.id))),
              title: agent.name, activity: nil, available: agent.available)
    }
}

/// App lifetime wiring. All metadata reads and sorting stay on the owner actor.
@MainActor
enum SidebarFoldersService {
    static let store = SidebarFoldersStore()
    private static var startup: Task<Void,Never>?
    private static var attached: TelegramProfileBinding?
    private static var attachTask: Task<Void,Never>?
    private static var desired: (TelegramProfileBinding?,(any TelegramChatProvider)?) = (nil,nil)
    private static var windowIDs: Set<UUID>?
    private static var refreshTask: Task<Void,Never>?
    private static var refreshAgain = false
    static func windows(_ ids: Set<UUID>) {
        windowIDs = ids
        if let binding = attached { Task { _ = await store.perform(.windows(ids), binding: binding) } }
    }
    static func start() {
        guard startup == nil else { return }
        startup = Task { _ = await store.perform(.load(defaults: []), binding: nil) }
    }
    static func receive(_ snapshot: TelegramChatSnapshot, provider: (any TelegramChatProvider)?) {
        guard let startup else { return }
        desired = (snapshot.binding,provider)
        if snapshot.binding != attached, attachTask == nil {
            attachTask = Task {
                await startup.value
                repeat {
                    let target = desired
                    guard await store.perform(.attach(target.1,target.0), binding: target.0) == .success else { break }
                    attached = target.0
                    if target.0 != nil, let windowIDs { _ = await store.perform(.windows(windowIDs), binding: target.0) }
                } while attached != desired.0
                attachTask = nil
            }
        }
        let rows = snapshot.lists.flatMap { $0.windows.values.flatMap(\.rows) } + snapshot.suggestionRows + snapshot.attentionRows
        Task { await store.updateTelegramRows(rows, binding: snapshot.binding) }
        refreshAgain = true
        if refreshTask == nil {
            refreshTask = Task {
                await startup.value
                await attachTask?.value
                repeat {
                    refreshAgain = false
                    if let binding = attached { _ = await store.perform(.refreshTelegram, binding: binding) }
                } while refreshAgain
                refreshTask = nil
            }
        }
    }
    static func defaults(scope: ChatOrgKey, teams: [String]) {
        guard let startup else { return }
        let entries = teams.map { SidebarEntryIdentity.team(scope,team: $0) } + [SidebarEntryIdentity.people(scope),"telegram","myAgents",SidebarEntryIdentity.teamAgents(scope)]
        Task { await startup.value; _ = await store.perform(.defaults(entries), binding: nil) }
    }
}
