import AppKit
import GRDB
import SwiftUI

/// The same address is used by channel, Team, status and attention entries.
@MainActor
final class RequestTabs {
    static let shared = RequestTabs()
    let router: TabRouter
    var chat: ChatService
    var team: TeamService
    var versions: ClaudeVersionApprovals
    init(router: TabRouter = .shared, chat: ChatService = .shared, team: TeamService = .shared,
         versions: ClaudeVersionApprovals = .shared) {
        self.router = router; self.chat = chat; self.team = team; self.versions = versions
    }
    var scope: TeamScope { team.calls.serverKey.map { .server(OrgKey($0)) } ?? .local }
    @discardableResult
    func open(_ id: String, scope: TeamScope? = nil, from store: WorkspaceStore? = nil) -> Session? {
        let route = ToolRoute.request(scope ?? self.scope, requestID: id)
        if router === TabRouter.shared { return SupportTabs.shared.navigation.open(route, from: store) }
        return router.open(route, from: store)
    }
    @discardableResult
    func open(_ id: String, callScope: TeamCallScope?, from store: WorkspaceStore? = nil) -> Session? {
        guard let callScope else { return open(id, scope: .local, from: store) }
        guard let key = try? OrgKey(server: callScope.server, accountID: callScope.accountId, orgID: callScope.orgId) else { return nil }
        return open(id, scope: .server(key), from: store)
    }
    func model(_ state: TabState) -> RequestTabModel {
        if let model = state.requestForm { return model }
        let model = RequestTabModel(state: state, tabs: self)
        state.requestForm = model
        return model
    }
    func tabID(_ state: TabState) -> UUID? {
        router.stores().flatMap(\.allSessions).first { $0.tabState === state }?.id
    }
    func clearReason(_ state: TabState) {
        guard let id = tabID(state), let owner = router.owner(of: id) else { return }
        do {
            if let draft = state.draft { try owner.store.drafts.discard(draft.id) }
            state.draft = nil; state.navigation.draftID = nil; state.savedRevision = nil
            state.changed()
        } catch { state.saveError = error.localizedDescription }
    }
}

/// Captured UI terms, never persisted as authority. The services still own D9,
/// Y2, folder grants and publication idempotency.
@MainActor @Observable
final class RequestTabModel {
    enum Action: Equatable {
        case allow, decline, publish, withhold
        case folder(String, TeamCalls.AccessRequest.State)
        case version(UUID, Bool)
    }
    struct Review: Equatable {
        var request: ChatRequest?
        var incoming: TeamCalls.Incoming?
        var identity: ChatConsentIdentity?
        var content: ChatChannelContent?
        var agent: TeamPublishedAgent?
        var result: String?
    }
    private weak var state: TabState?
    let tabs: RequestTabs
    let scope: TeamScope
    let id: String
    var revision = 0
    var loading = false
    var channelModel: ChatChannelOwnerModel?
    @ObservationIgnored private var followed: ChatStore?
    @ObservationIgnored private var watch: AnyDatabaseCancellable?
    @ObservationIgnored private var journalWatch: AnyDatabaseCancellable?

    init(state: TabState, tabs: RequestTabs) {
        self.state = state; self.tabs = tabs
        guard case .request(let scope, let id) = state.route else { preconditionFailure("Request route required") }
        self.scope = scope; self.id = id
        follow()
    }
    var key: ChatOrgKey? { if case .server(let key) = scope { key.chatKey } else { nil } }
    var calls: TeamCalls { tabs.team.calls }
    var chat: ChatService { tabs.chat }
    var reason: String {
        get { if case .reason(let value) = state?.draft?.payload { value } else { "" } }
        set { state?.confirmation.invalidate(); state?.edit(.reason(newValue)) }
    }
    var request: ChatRequest? {
        _ = revision
        guard let key, ChatAttention.personalAllowed(key, chat),
              let request = try? chat.orgSessions[key]?.store?.calls.request(id), request.hasFixed else { return nil }
        if request.kind == "channel" {
            guard let channel = request.channelId, chat.channelAgentAllowed(key, channel: channel) else { return nil }
        } else if request.ownerAccountId != key.accountId && request.initiatorAccountId != key.accountId { return nil }
        return request
    }
    private var callsReadable: Bool {
        if let key { return ChatAttention.personalAllowed(key, chat) && calls.serverKey == key }
        return !calls.serverMode
    }
    var incoming: TeamCalls.Incoming? { callsReadable ? calls.incoming.first { $0.id == id } : nil }
    var outgoing: TeamCalls.Outgoing? { callsReadable ? calls.outgoing.first { $0.id == id } : nil }
    var readable: Bool { request != nil || incoming != nil || outgoing != nil }
    var folders: [TeamCalls.AccessRequest] {
        guard readable else { return [] }
        return request?.kind == "channel" ? calls.channelPendingAccess(id) : calls.pendingAccess.filter { $0.callId == id }
    }
    var versions: [ClaudeVersionApprovals.Pending] { readable ? tabs.versions.pending.filter { $0.callId == id } : [] }
    var result: String? {
        guard readable else { return nil }
        if let key, request?.kind == "channel" { return try? chat.channelPublicationText(key, requestId: id) }
        return request?.localText ?? incoming?.answer?.text ?? request?.result?.shownText ?? outgoing?.report.text
    }
    var resultTitle: String {
        if request?.kind == "channel" { return "Preview · only on this Mac until published" }
        if request?.localText != nil { return "Answer" }
        let truncated = incoming?.answer != nil ? incoming?.truncated == true
            : (request?.result.map { $0.truncated || $0.trimmed == true } ?? (outgoing?.report.truncated == true))
        return truncated ? "Answer · truncated" : "Answer"
    }
    var activity: String? {
        guard readable else { return nil }
        if let key, request?.kind == "channel" { return chat.activity(key, request: id) }
        return incoming?.activity ?? outgoing?.report.activity
    }
    var canStop: Bool {
        if let request, let key, request.kind == "channel" {
            return request.ownerAccountId == key.accountId && [.starting, .running].contains(request.state)
        }
        return incoming.map { [.queued, .running].contains($0.state) && calls.refusal(.stop, for: $0) == nil } ?? false
    }
    func stop() {
        guard canStop else { return }
        if let key, request?.kind == "channel" {
            state?.message = chat.askToEnd(key, id, type: "request.stop", states: [.starting, .running])
        } else { state?.message = calls.stop(id) }
    }
    var canDecide: Bool {
        if let request, let key {
            return request.ownerAccountId == key.accountId && request.onThisDevice && request.state == .awaitingDecision
                && request.deliverBy.flatMap(ChatStore.date).map({ $0 > Date() }) == true
                && (request.kind != "channel" || channelModel?.isAutomatic(request) == false)
        }
        return incoming.map { $0.needsDecisionHere && $0.decideBy > Date() && calls.refusal(.decide, for: $0) == nil } ?? false
    }
    var canAllow: Bool {
        guard canDecide else { return false }
        if let request, let key, request.kind == "channel" { return chat.channelDecisionReady(key, request: request) }
        return true
    }
    func follow() {
        guard let key, let store = chat.orgSessions[key]?.store, followed !== store else { return }
        followed = store
        let changes = CoalescedMainActorAction { [weak self] in
            self?.revision += 1; self?.state?.confirmation.validate()
        }
        watch = DatabaseRegionObservation(tracking: Table("requests"), Table("request_contents"), Table("channels"),
            Table("teams"), Table("team_members"), Table("members"), Table("agent_channels"), Table("meta"), Table("outbox"))
            .start(in: store.queue, onError: { _ in }) { _ in changes.schedule() }
        if let journal = chat.journal {
            journalWatch = DatabaseRegionObservation(tracking: Table("runs"), Table("approvals"), Table("run_commands"), Table("assignments"))
                .start(in: journal.queue, onError: { _ in }) { _ in changes.schedule() }
        }
        channelModel = nil
    }
    func load() async {
        follow()
        guard let key, let request, let channel = request.channelId else { return }
        if channelModel?.channel != channel { channelModel = ChatChannelOwnerModel(service: chat, key: key, channel: channel) }
        guard !loading, request.state == .awaitingDecision, request.onThisDevice,
              channelModel?.content(request) == nil else { return }
        loading = true
        defer { loading = false; revision += 1 }
        do { _ = try await chat.loadChannelContent(key, request: request) }
        catch { state?.message = error.localizedDescription }
    }
    func review() -> Review? {
        guard readable else { return nil }
        let request = request
        let agent = request?.agentId.flatMap { chat.localAgent($0) } ?? incoming.flatMap { calls.localAgent(for: $0) }
        return Review(request: request, incoming: request == nil ? incoming : nil,
            identity: key.flatMap { chat.consentIdentity($0) },
            content: request?.channelId == nil ? nil : key.flatMap { key in
                try? chat.orgSessions[key]?.store?.queue.read { try ChatChannelContent.read($0, request: id) }
            }, agent: agent, result: result)
    }
    @discardableResult
    func confirm(_ action: Action) -> Bool {
        guard let state, let tabID = tabs.tabID(state), let reviewed = review() else { return false }
        let title: String, verb: String, consequences: String
        switch action {
        case .allow, .decline:
            guard canDecide, action != .allow || canAllow else { return false }
            title = action == .allow ? "Allow this request?" : "Decline this request?"
            verb = action == .allow ? "Allow" : "Decline"
            consequences = action == .allow ? "Run the request with the context, executor and limits shown above. Claude Code version approval is separate."
                : "The requester sees your reason. This request will not run."
        case .publish, .withhold:
            guard let key, request?.publication == "awaiting_publish", chat.channelPreview(key, requestId: id) != nil else { return false }
            if action == .publish, let problem = chat.channelPublishProblem(key, requestId: id) { state.message = problem; return false }
            title = action == .publish ? "Publish this result?" : "Withhold this result?"
            verb = action == .publish ? "Publish" : "Don't Publish"
            consequences = action == .publish ? "Current and future members of the channel's team will see the previewed answer." : "The answer stays on this Mac."
        case .folder(let id, let decision):
            guard let folder = folders.first(where: { $0.id == id }) else { return false }
            title = "Folder: \(folder.path)"
            verb = decision == .denied ? "Deny folder" : decision == .always ? "Always allow folder" : "Allow folder once"
            consequences = folder.reason + (decision == .always && scope == .local ? "\nThe folder will be added to this agent for future calls." : "")
        case .version(let id, let allow):
            guard let item = versions.first(where: { $0.id == id }) else { return false }
            title = "Claude Code \(item.grant.version)"; verb = allow ? item.allowTitle : ClaudeVersionApprovals.Pending.declineTitle
            consequences = item.message
        }
        let reason = self.reason
        let valid = { [weak self, weak state] in
            guard let self, let state, !state.isClosed, self.review() == reviewed else { return false }
            switch action {
            case .allow, .decline: return self.canDecide && (action != .allow || self.canAllow) && self.reason == reason
            case .folder(let id, _): return self.folders.contains { $0.id == id }
            case .version(let id, _): return self.versions.contains { $0.id == id }
            default: return true
            }
        }
        let deadline = [.allow, .decline].contains(action)
            ? (request?.deliverBy.flatMap(ChatStore.date) ?? incoming?.decideBy) : nil
        return state.confirmation.request(.init(tabID: tabID, targetID: id, scope: key.map(OrgKey.init),
            generation: reviewed.identity?.generation, revision: request.map { String($0.version) }, deadline: deadline),
            title: title, consequences: consequences, verb: verb, destructive: action == .decline || action == .withhold,
            stillValid: valid) { [self] in
                var problem: String?
                switch action {
                case .allow, .decline:
                    if let key, request?.kind == "channel" {
                        guard let owner = chat.owner else { throw ChatError.notConnected }
                        problem = await owner.decideChannel(key, requestId: id, allow: action == .allow, reason: reason, stillValid: valid)
                    } else { problem = calls.decide(id, allow: action == .allow, reason: reason) }
                case .publish, .withhold:
                    guard let key else { throw ChatError.notConnected }
                    try chat.publishChannelResult(key, requestId: id, publish: action == .publish)
                case .folder(let id, let decision): problem = await calls.decideAccess(id, decision)
                case .version(let id, let allow): tabs.versions.decide(id, allow: allow)
                }
                if let problem { throw ChatError.storage(problem) }
                if action == .allow || action == .decline, self.reason == reason { tabs.clearReason(state) }
            }
    }
    func copyResult(expected: String? = nil, to board: NSPasteboard = .general) {
        guard let text = result, expected == nil || expected == text else { return }
        board.clearContents(); board.setString(text, forType: .string)
    }
}
