import AppKit
import SwiftUI

extension OrgKey {
    var chatKey: ChatOrgKey { ChatOrgKey(server: server, accountId: accountID, orgId: orgID) }
}

extension ToolRoute {
    var teamScope: TeamScope? {
        switch self {
        case .publishedAgents(let scope), .teamActivity(let scope), .publication(let scope, _), .publish(let scope, _, _, _): scope
        default: nil
        }
    }
}

/// Entry points only; identity, transfer, persistence and confirmation belong
/// to the common tab mechanism.
@MainActor
final class TeamTabs {
    static let shared = TeamTabs()
    let router: TabRouter
    var serviceProvider: () -> TeamService = { .shared }
    var organization: () -> ChatOrgModel? = { ChatOrgCurrent.shared.model }
    var connectionIdentity: () -> String? = {
        guard let identity = ChatOrgCurrent.identity() else { return nil }
        let generation = ChatService.shared.connection?.orgKey.map { ChatAttention.scope($0, .shared).generation } ?? ""
        return identity + "|" + generation
    }
    var assignment: (UUID) -> ChatOrgKey? = { ChatService.shared.assignmentKey($0) }
    var chosenTeams: (UUID, ChatOrgKey) -> [String]? = { ChatService.shared.chosenTeams($0, key: $1) }
    var sourceInspector = AgentAnswerProvenance.Inspector()
    var bindPublication: (ChatOrgKey, UUID, UUID?) throws -> Void = {
        try ChatService.shared.bindPublication($0, agent: $1.uuidString.lowercased(), surface: $2)
    }
    init(router: TabRouter = .shared) { self.router = router }
    var service: TeamService { serviceProvider() }
    var currentScope: TeamScope? {
        if !service.calls.serverMode { return .local }
        return service.calls.serverKey.map { .server(OrgKey($0)) }
    }
    func owner(_ state: TabState) -> TabRouter.Location? {
        for store in router.stores() {
            if let session = store.allSessions.first(where: { $0.tabState === state }) { return router.owner(of: session.id) }
        }
        return nil
    }
    func canRead(_ scope: TeamScope) -> Bool {
        guard scope == currentScope else { return false }
        guard case .server(let key) = scope else { return true }
        guard let model = organization(), model.key.map(OrgKey.init) == key else { return false }
        return model.isCurrent() && model.visible && !model.inDoubt && !model.snapshotOwed() && !model.showsOffline()
    }
    func teams(_ scope: TeamScope) -> [ChatOrgView.Team] {
        guard canRead(scope), case .server = scope else { return [] }
        return organization()?.myTeams ?? []
    }
    func agents(_ scope: TeamScope) -> [TeamPublishedAgent] {
        guard canRead(scope) else { return [] }
        return service.calls.agents.filter {
            guard let key = assignment($0.id) else { return service.calls.publishing?.isAssigned($0.id) != true }
            return scope == .server(OrgKey(key))
        }
    }
    @discardableResult
    func open(_ route: ToolRoute, from store: WorkspaceStore? = nil) -> Session? {
        // All production entries respect the existing startup gate.
        if router === TabRouter.shared { return SupportTabs.shared.navigation.open(route, from: store) }
        return router.open(route, from: store)
    }
    @discardableResult
    func showAgents(from store: WorkspaceStore? = nil) -> Session? {
        guard let scope = currentScope else { return showActivity(from: store) }
        return open(.publishedAgents(scope), from: store)
    }
    @discardableResult
    func showActivity(section: String = "connection", from store: WorkspaceStore? = nil) -> Session? {
        let session = open(.teamActivity(currentScope ?? .local), from: store)
        if let state = session?.tabState { select(section, state: state) }
        return session
    }
    func select(_ section: String, state: TabState) {
        guard state.navigation.selection != section else { return }
        state.confirmation.invalidate(); state.navigation.selection = section; state.changed()
    }
    @discardableResult
    func showPublication(_ editing: TeamAgentEditing, from store: WorkspaceStore? = nil) -> Session? {
        open(.publication(editing.key.map { .server(OrgKey($0)) } ?? .local,
                          publicationID: editing.agent.id.uuidString.lowercased()), from: store)
    }
    @discardableResult
    func publish(sessionID: String? = nil, title: String = "", surfaceID: UUID? = nil,
                 from store: WorkspaceStore? = nil, newDraft: Bool = false) -> Session? {
        guard let scope = currentScope else { return nil }
        let conversation = sessionID?.lowercased()
        if !newDraft, let conversation, let agent = agents(scope).first(where: { $0.sessionId == conversation }) {
            guard let session = open(.publication(scope, publicationID: agent.id.uuidString.lowercased()), from: store),
                  let state = session.tabState else { return nil }
            let form = form(state)
            var fields = form.fields
            fields.sourceSurfaceID = surfaceID; fields.sourceConversationID = conversation
            if fields != form.fields { form.fields = fields }
            return session
        }
        let matches: (ToolRoute) -> Bool = {
            if case .publish(let s, _, let surface, let id) = $0 { return s == scope && surface == surfaceID && id == conversation }
            return false
        }
        let stores = router.stores().filter { !$0.isTerminated }
        let existing = newDraft ? nil : stores.flatMap(\.allSessions).compactMap(\.toolRoute).first(where: matches)
            ?? stores.flatMap { $0.drafts.drafts }.sorted { $0.revision > $1.revision }.map(\.route).first(where: matches)
        let route = existing ?? .publish(scope, draftID: UUID(), sourceSessionID: surfaceID, conversationID: conversation)
        guard let session = open(route, from: store), let state = session.tabState else { return nil }
        if state.publicationForm == nil, state.draft == nil { state.transient["publicationSourceTitle"] = title }
        if canRead(scope) { _ = form(state, title: title) }
        return session
    }
    func requestUnpublish(_ agents: [TeamPublishedAgent], state: TabState) {
        guard !agents.isEmpty, let scope = state.route.teamScope, let owner = owner(state) else { return }
        let identity = connectionIdentity()
        state.confirmation.request(.init(tabID: owner.session.id, targetID: agents.map { $0.id.uuidString }.joined(separator: ","),
            scope: state.route.organizationScope, generation: identity, deadline: Date().addingTimeInterval(120)),
            title: agents.count == 1 ? "Stop publishing \(agents[0].name)?" : "Stop publishing this session?",
            consequences: "Colleagues can no longer call it. Calls already allowed finish.", verb: "Unpublish", destructive: true,
            stillValid: { [self] in
                canRead(scope) && connectionIdentity() == identity && agents.allSatisfy { agent in self.agents(scope).contains(agent) }
            }) { [self] in
                for agent in agents { try service.calls.unpublish(agent.id) }
            }
    }
    func stopPublishing(_ agents: [TeamPublishedAgent]) {
        guard let scope = currentScope, let first = agents.first,
              let state = open(.publication(scope, publicationID: first.id.uuidString.lowercased()))?.tabState else { return }
        requestUnpublish(agents, state: state)
    }
    /// Errors without a surviving source live in the pinned Delivery section.
    /// Only metadata enters the notification history.
    func report(_ title: String, _ error: Error?, scope: TeamScope? = nil) {
        let scope = scope ?? currentScope ?? .local
        if let state = open(.teamActivity(scope))?.tabState {
            select("delivery", state: state)
            state.message = title + (error.map { "\n" + $0.localizedDescription } ?? "")
        }
        let key: ChatOrgKey? = { if case .server(let key) = scope { return key.chatKey }; return nil }()
        AttentionLedger.shared.upsert(AttentionEvent(source: "team-operation", object: UUID().uuidString,
            kind: .failure, destination: .recovery("delivery"), scope: key.map { ChatAttention.scope($0, .shared) }))
    }
}

struct TeamScopeView<Content: View>: View {
    let scope: TeamScope
    let tabs: TeamTabs
    @ViewBuilder let content: () -> Content
    var body: some View {
        Group {
            if tabs.canRead(scope) { content() }
            else {
                VStack(spacing: 12) {
                    Text("Connect to this organization and wait for access to be checked.").foregroundStyle(.secondary)
                    Button("Connect to a Server…") { ConnectionTabs.shared.show() }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ChatOrgCurrent.identity()) { ChatOrgCurrent.shared.refresh() }
    }
}

struct TeamActivityTab: View {
    @Bindable var state: TabState
    let scope: TeamScope
    let tabs: TeamTabs
    private var section: Binding<String> {
        Binding(get: { state.navigation.selection ?? "connection" }, set: { tabs.select($0, state: state) })
    }
    var body: some View {
        TeamScopeView(scope: scope, tabs: tabs) {
            VStack(spacing: 0) {
                Picker("Team activity", selection: section) {
                    Text("Connection").tag("connection")
                    Text("Requests").tag("requests")
                    Text("Delivery").tag("delivery")
                }.pickerStyle(.segmented).padding(16)
                if section.wrappedValue == "requests" { TeamCallsSidebar(service: tabs.service) }
                else {
                    ScrollView {
                        if section.wrappedValue == "delivery", let message = state.message {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message).foregroundStyle(.red).textSelection(.enabled)
                                Button("Dismiss") { state.message = nil }
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        TeamStatusView(service: tabs.service, delivery: section.wrappedValue == "delivery", scope: scope)
                    }
                }
            }
        }
    }
}
