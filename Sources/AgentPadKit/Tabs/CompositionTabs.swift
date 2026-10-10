import AppKit
import GRDB
import SwiftUI

/// Chat text stays in its scoped cache; routes and local Forward snapshots use
/// the existing tab repository. Neither store contains runtime authority.
enum ChatCompositionDrafts {
    static func read<T: Decodable>(_ type: T.Type, id: String, store: ChatStore) throws -> T? {
        try store.queue.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM composition_drafts WHERE id = ?", arguments: [id])
                .map { try JSONDecoder().decode(type, from: Data($0.utf8)) }
        }
    }
    static func save<T: Encodable>(_ value: T, id: String, channel: String? = nil, store: ChatStore) throws {
        let body = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO composition_drafts (id, channel_id, body) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET body = excluded.body",
                arguments: [id, channel, body])
        }
    }
}

struct PersonalAskDraft: Codable, Equatable {
    var prompt = ""
    var requestID = UUID().uuidString.lowercased()
}

struct NewChannelDraft: Codable, Equatable {
    var name = ""
    var channelID = UUID().uuidString.lowercased()
    var submitted = false
}

@MainActor
final class CompositionTabs {
    static let shared = CompositionTabs()
    let router: TabRouter
    let chat: ChatService
    private let teamOverride: TeamService?
    var team: TeamService { teamOverride ?? .shared }
    var orgModel: () -> ChatOrgModel?
    /// Runtime-only proof retained when a Forward tab is closed and reopened.
    private var sources: [UUID: AgentAnswerSource.Answer] = [:]
    private var reads: [UUID: Task<Void, Never>] = [:]
    private var snapshots: [UUID: (binding: AgentAnswerSource.Binding, text: String, id: UUID)] = [:]
    private var revocations: [OrgKey: Int] = [:]

    init(router: TabRouter = .shared, chat: ChatService = .shared, team: TeamService? = nil,
         orgModel: @escaping () -> ChatOrgModel? = { ChatOrgCurrent.shared.model }) {
        self.router = router; self.chat = chat; teamOverride = team; self.orgModel = orgModel
    }
    func owner(_ state: TabState) -> TabRouter.Location? {
        for store in router.stores() {
            if let session = store.allSessions.first(where: { $0.tabState === state }) { return router.owner(of: session.id) }
        }
        return nil
    }
    @discardableResult func open(_ route: ToolRoute, from store: WorkspaceStore? = nil) -> Session? {
        router.open(route, from: store)
    }
    func agent(_ id: String, key: ChatOrgKey, channel: String?, from store: WorkspaceStore? = nil) {
        guard let state = open(.agent(OrgKey(key), agentID: id), from: store)?.tabState else { return }
        state.navigation.anchor = channel; state.changed()
    }
    func askModel(_ state: TabState) -> PersonalAskModel {
        if let model = state.askForm { return model }
        let model = PersonalAskModel(state: state, tabs: self)
        state.askForm = model
        state.persistEdits = { [weak model] in try model?.save() }
        state.discardEdits = { [weak model] in model?.reloadDraft() }
        return model
    }
    func newChannel(key: ChatOrgKey, teamID: String, from store: WorkspaceStore? = nil, fresh: Bool = false) {
        let scope = OrgKey(key)
        let saved = router.stores().flatMap { $0.drafts.drafts }.first {
            if case .newChannel(let key, let team, _) = $0.route { return key == scope && team == teamID }; return false
        }
        let existing = router.stores().flatMap(\.allSessions).compactMap(\.toolRoute).first {
            if case .newChannel(let key, let team, _) = $0 { return key == scope && team == teamID }; return false
        }
        let route = fresh ? .newChannel(scope, teamID: teamID, draftID: UUID()) : existing ?? saved?.route ?? .newChannel(scope, teamID: teamID, draftID: UUID())
        guard let state = open(route, from: store)?.tabState else { return }
        _ = channelModel(state)
    }
    func channelModel(_ state: TabState) -> NewChannelModel {
        if let model = state.newChannelForm { return model }
        let model = NewChannelModel(state: state, tabs: self); state.newChannelForm = model
        return model
    }
    func save(_ state: TabState) throws {
        guard let owner = owner(state), !state.isClosed else { throw ChatError.storage("The tab is closed.") }
        try owner.store.tabCloseCoordinator.save(state)
    }
    static func available(_ session: Session) -> Bool { AgentAnswerSource.problem(session) == nil }
    func forward(session: Session, store: WorkspaceStore, copyOnly: Bool = false,
                 inspector: AgentAnswerProvenance.Inspector = .init(),
                 reader: @escaping AgentAnswerSource.Reader = { try AgentAnswerTranscript.read(agent: $0, conversation: $1, root: $2) }) {
        guard AgentAnswerSource.supports(session), reads[session.id] == nil else { return }
        let destination = chat.connection?.orgKey.map(OrgKey.init)
        let epoch = destination.map { revocations[$0, default: 0] }
        // Reserve the source before awaiting transcript IO. No duplicate read
        // can race to open a second snapshot for the same answer.
        reads[session.id] = Task { [weak self, weak session] in
            guard let self, let session else { return }
            defer { self.reads[session.id] = nil }
            do {
                let sourceID = session.id
                let answer = try await AgentAnswerSource.read(session: session, store: store, inspector: inspector, reader: reader,
                    owner: { [weak self, weak store] in self?.router.owner(of: sourceID)?.store ?? store })
                guard answer.isCurrent(), let binding = session.answerBinding else { throw AgentAnswerTranscript.Problem.changed }
                guard destination.map({ revocations[$0, default: 0] }) == epoch else { return }
                if copyOnly { AgentAnswerForwardView.copy(answer.text); return }
                let old = snapshots[session.id]
                let id = old?.binding == binding && old?.text == answer.text ? old!.id : UUID()
                snapshots[session.id] = (binding, answer.text, id); sources[id] = answer
                let route = ToolRoute.forward(sourceSessionID: session.id, answerSnapshotID: id)
                guard let state = open(route, from: router.owner(of: session.id)?.store ?? store)?.tabState else { return }
                if state.draft == nil {
                    state.edit(.forwardForm(.init(snapshot: answer.text, markdown: answer.text, sourceTitle: answer.title,
                        conversationID: binding.conversation, destination: destination)))
                }
                _ = forwardModel(state)
            } catch {
                // Failure is attached to a normal tab and never presents an alert.
                let route = ToolRoute.forward(sourceSessionID: session.id, answerSnapshotID: UUID())
                open(route, from: router.owner(of: session.id)?.store ?? store)?.tabState?.message = AgentAnswerForward.message(error)
            }
        }
    }
    func forwardModel(_ state: TabState) -> AgentAnswerForward? {
        if let model = state.forwardForm { return model }
        guard case .forward(_, let id) = state.route else { return nil }
        let fields: ForwardDraft
        switch state.draft?.payload {
        case .forwardForm(let value): fields = value
        case .forward(let snapshot, let markdown, let destination, let channel, let thread, let attempt):
            fields = .init(snapshot: snapshot, markdown: markdown, destination: destination,
                channelID: channel ?? "", threadID: thread ?? "", attemptID: attempt)
        default: return nil
        }
        let source = sources[id]
        let model = AgentAnswerForward(draft: fields, caller: source?.caller, service: chat,
            sourceIsCurrent: { source?.isCurrent() ?? false })
        model.restartConfirmation = state.confirmation
        model.tabID = owner(state)?.session.id ?? id
        state.forwardForm = model
        model.changed = { [weak state, weak model] in
            guard let state, let model, !state.isClosed else { return }
            state.edit(.forwardForm(model.draft))
        }
        model.persist = { [weak self, weak state] in
            guard let self, let state else { throw ChatError.notConnected }; try self.save(state)
        }
        model.isOpen = { [weak state] in state?.isClosed == false }
        return model
    }
    func viewer(key: ChatOrgKey, message: ChatMessage, file: ChatAttachment, from store: WorkspaceStore? = nil) {
        let route: ToolRoute = message.dmId.map { .dmViewer(OrgKey(key), dmID: $0, messageID: message.id, attachmentID: file.id) }
            ?? .viewer(OrgKey(key), channelID: message.channelId, messageID: message.id, attachmentID: file.id)
        open(route, from: store)
    }
    func viewerModel(_ state: TabState) -> AttachmentViewerModel {
        if let model = state.viewerForm { return model }
        let model = AttachmentViewerModel(state: state, tabs: self); state.viewerForm = model; return model
    }
    func revoke(_ key: ChatOrgKey) {
        let scope = OrgKey(key)
        revocations[scope, default: 0] += 1
        func matches(_ draft: TabDraft) -> Bool {
            if case .forwardForm(let fields) = draft.payload { return fields.destination == scope }
            if case .forward(_, _, let destination, _, _, _) = draft.payload { return destination == scope }
            return draft.route.organizationScope == scope
        }
        for store in router.stores() {
            for draft in store.drafts.drafts where matches(draft) {
                if case .forward(_, let id) = draft.route { sources[id] = nil; snapshots = snapshots.filter { $0.value.id != id } }
                do { try store.drafts.discard(draft.id) }
                catch { store.allSessions.first { $0.tabState?.draft?.id == draft.id }?.tabState?.saveError = error.localizedDescription }
            }
            for state in store.allSessions.compactMap(\.tabState) where state.route.organizationScope == scope || state.draft.map(matches) == true {
                if case .forward(_, let id) = state.route { sources[id] = nil; snapshots = snapshots.filter { $0.value.id != id } }
                state.confirmation.invalidate()
                state.forwardForm?.changed = {}; state.forwardForm?.active = false; state.forwardForm = nil
                state.askForm?.invalidate(); state.askForm = nil; state.viewerForm?.invalidate()
                state.newChannelForm?.invalidate(); state.newChannelForm = nil
                state.draft = nil; state.navigation.draftID = nil; state.savedRevision = nil; state.changed()
            }
        }
    }
}

@MainActor @Observable
final class PersonalAskModel {
    let key: ChatOrgKey
    let agentID: String
    let tabs: CompositionTabs
    private weak var state: TabState?
    private var fields = PersonalAskDraft()
    var problem: String?
    var revision = 0
    private var dirty = false
    private var revoked = false
    @ObservationIgnored private var watch: AnyDatabaseCancellable?
    @ObservationIgnored private weak var followed: ChatStore?
    init(state: TabState, tabs: CompositionTabs) {
        guard case .ask(let key, let agent) = state.route else { preconditionFailure("Ask route required") }
        self.key = key.chatKey; agentID = agent; self.state = state; self.tabs = tabs
        follow()
    }
    var readable: Bool { !revoked && state?.isClosed == false && ChatAttention.personalAllowed(key, tabs.chat) }
    var actions: ChatSidebarAgentActions? {
        guard readable, let model = tabs.orgModel(), model.key == key else { return nil }
        return ChatSidebarAgentActions(agentID: agentID, active: nil, model: model)
    }
    var prompt: String {
        get { fields.prompt }
        set {
            guard readable else { return }
            if sentRequest != nil { fields = PersonalAskDraft() }
            fields.prompt = newValue; dirty = true
            do { try save() } catch { state?.saveError = error.localizedDescription }
        }
    }
    var history: [ChatRequest] {
        _ = revision
        guard readable else { return [] }
        return ((try? tabs.chat.orgSessions[key]?.store?.calls.requests()) ?? []).filter {
            $0.kind == "personal" && $0.agentId == agentID && $0.initiatorAccountId == key.accountId
        }
    }
    var sentRequest: ChatRequest? { history.first { $0.requestId == fields.requestID } }
    var canSend: Bool {
        guard readable, sentRequest == nil, ChatChannelAsk.textProblem(prompt) == nil,
              let actions, let model = tabs.orgModel(), tabs.team.calls.serverKey == key else { return false }
        return actions.canAsk(in: model)
    }
    func follow() {
        guard readable, let store = tabs.chat.orgSessions[key]?.store, followed !== store else { return }
        followed = store; reloadDraft()
        let changed = CoalescedMainActorAction { [weak self] in self?.revision += 1 }
        watch = DatabaseRegionObservation(tracking: Table("requests"), Table("results"), Table("meta"))
            .start(in: store.queue, onError: { _ in changed.schedule() }) { _ in changed.schedule() }
    }
    func reloadDraft() {
        guard readable, let store = tabs.chat.orgSessions[key]?.store else { return }
        do {
            fields = try ChatCompositionDrafts.read(PersonalAskDraft.self, id: "ask:" + agentID, store: store) ?? .init()
            dirty = false; state?.saveError = nil
        } catch { state?.saveError = error.localizedDescription }
    }
    func save() throws {
        guard dirty else { return }
        guard readable, let store = tabs.chat.orgSessions[key]?.store else { throw ChatError.notConnected }
        try ChatCompositionDrafts.save(fields, id: "ask:" + agentID, store: store)
        dirty = false; state?.saveError = nil
    }
    func invalidate() { revoked = true; fields = .init(); dirty = false; watch = nil; followed = nil }
    func send() {
        guard canSend, let actions, let model = tabs.orgModel(), let calls = tabs.chat.orgSessions[key]?.store?.calls else { return }
        do {
            dirty = true; try save()
            try actions.submitAsk(in: model, resolve: { address in
                try calls.queue.read { try ChatCallStore.resolve($0, address: address).agentId }
            }, send: { address in
                _ = try tabs.team.calls.ask(address, prompt: fields.prompt, threadId: nil, origin: nil,
                    area: .some(key), requestID: fields.requestID)
            })
            revision += 1; problem = nil
        } catch { problem = error.localizedDescription }
    }
    @discardableResult func copy(_ shown: ChatRequest, to board: NSPasteboard = .general) -> Bool {
        guard let current = history.first(where: { $0.requestId == shown.requestId }), current == shown,
              current.state == .finished, let text = current.localText ?? current.result?.shownText else { return false }
        AgentAnswerForwardView.copy(text, to: board); return true
    }
}

@MainActor @Observable
final class NewChannelModel {
    let key: ChatOrgKey
    let teamID: String
    private weak var state: TabState?
    let tabs: CompositionTabs
    var fields: NewChannelDraft { didSet { state?.edit(.newChannelForm(fields)) } }
    var problem: String?
    private var revoked = false
    init(state: TabState, tabs: CompositionTabs) {
        guard case .newChannel(let key, let team, _) = state.route else { preconditionFailure("New channel route required") }
        self.key = key.chatKey; teamID = team; self.state = state; self.tabs = tabs
        if case .newChannelForm(let fields) = state.draft?.payload { self.fields = fields }
        else if case .channel(let name) = state.draft?.payload { fields = .init(name: name) }
        else { fields = .init() }
        state.edit(.newChannelForm(fields))
    }
    var model: ChatOrgModel? { tabs.orgModel().flatMap { $0.key == key && $0.isCurrent() ? $0 : nil } }
    var readable: Bool { !revoked && state?.isClosed == false && ChatAttention.personalAllowed(key, tabs.chat) }
    func invalidate() { revoked = true; fields = .init() }
    var canCreate: Bool {
        guard readable, !fields.submitted, let model,
              let team = model.channelTeams.first(where: { $0.teamId == teamID }), model.canCreateChannel(in: team),
              let store = tabs.chat.orgSessions[key]?.store else { return false }
        guard let commands = try? store.outbox.commands() else { return false }
        return !commands.contains { $0.type == "channel.create" && ChatService.args($0)["channel_id"]?.string == fields.channelID && $0.state != .failed }
    }
    func create() {
        guard canCreate, let state, let model, let team = model.channelTeams.first(where: { $0.teamId == teamID }) else { return }
        problem = nil
        do {
            if let issue = ChatOrgModel.channelNameProblem(fields.name) { throw ChatError.storage(issue) }
            try tabs.save(state)
            _ = try model.createChannel(fields.name, in: team, channelID: fields.channelID)
            fields.submitted = true
            try tabs.save(state)
            reconcile()
        } catch { problem = error.localizedDescription }
    }
    func newDraft() {
        guard readable, let state else { return }
        tabs.newChannel(key: key, teamID: teamID, from: tabs.owner(state)?.store, fresh: true)
    }
    func reconcile() {
        guard readable, let state, let model, let owner = tabs.owner(state) else { return }
        // Checking the stable object ID also covers a crash between queueing and
        // saving submitted=true; opening never reissues channel.create.
        guard model.visibleChannel(fields.channelID) != nil else { return }
        guard tabs.router.rekey(owner.session.id, to: ChannelRef(key, channel: fields.channelID)) != nil else { return }
        if let id = state.navigation.draftID { try? owner.store.drafts.discard(id) }
    }
}
