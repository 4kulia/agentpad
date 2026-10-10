import Foundation
import GRDB

/// Everything of one organization on one server for one account: cache,
/// sync, send queue, calls (docs/agentpad/CHAT-PLAN.md 6.11). Nothing of an
/// organization lives anywhere else, so switching organizations later means
/// another `ChatOrgSession`, not new storage.
@MainActor
@Observable
final class ChatOrgSession {
    let key: ChatOrgKey
    /// The cache; nil when it could not be opened (`problem` says why).
    private(set) var store: ChatStore?
    private(set) var problem: String?
    /// The user has read a problem that needs nothing more (a cache made anew).
    func acknowledgeProblem() { if store != nil { problem = nil } }
    /// The cache was damaged and made anew: a full snapshot is due, and
    /// commands not yet sent were lost — the user is told (C4).
    private(set) var needsFullSnapshot = false
    /// The send queue (C2): the cache's `outbox` and the journal's `run_commands`.
    private(set) var outbox: ChatOutbox?
    /// Follows the server (C8); nil until the feed starts.
    var sync: ChatSync?
    var dmList: ChatDMListModel?
    /// The doubt of the user's rights could not be written to the cache
    /// (it is tried again): the window shows nothing of the organization
    /// meanwhile — no second place the doubt is kept (C6g).
    var doubtNotWritten = false
    /// Every failed write of the doubt, and every end of such a failure,
    /// counted: a model shows only a view read after the last of them
    /// (review C6i p1-2, C6j).
    var doubtWriteFailures = 0
    /// A snapshot is owed or under way (`ChatSync.needsSnapshot`), mirrored
    /// here to be observed: no channel is shown until it is applied whole,
    /// its pages included (review F2-p1-4). True until a synchronizer says.
    var snapshotOwed = true
    /// F3: open channels without live events (over the socket's budget, or held by its limit).
    var pausedChannels: Set<String> = []
    /// F4: the one point that reconciles notices after any write that may
    /// change what they stand for — cards, teams, messages, markers, rights.
    var noticeWatch: AnyDatabaseCancellable?
    /// F4: channels whose streams are followed now (their unread is counted live).
    var followedChannels: Set<String> = []
    /// Runs the actions requests owe (D8, 6.12): the organization's one
    /// runner (`ChatService.runners`), given this state's cache; nil without one.
    var actions: ChatActionRunner?

    init(key: ChatOrgKey, files: ChatFiles) {
        self.key = key
        do {
            let (store, recovered) = try ChatStore.open(files: files, key: key)
            try files.restoreDMOutbox(key, store: store)
            self.store = store
            if recovered {
                needsFullSnapshot = true
                problem = "The local copy of this organization was damaged and is loaded again. Commands not yet sent were lost."
            }
            // Every organization starts with its rights in doubt: what the
            // cache says of them is confirmed only by a snapshot applied in
            // this run, so nothing a launch may have missed shows (review C6h).
            if (try? store.putRightsInDoubt()) == nil {
                doubtNotWritten = true
                doubtWriteFailures += 1
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Starts sending once the session's token is known; later sign-ins
    /// move the queue to the new session (6.4).
    func startSending(api: ChatAPI, token: String, sessionId: String, journal: ChatJournal?,
                      onUnauthorized: @escaping @MainActor () -> Void) {
        if let outbox {
            outbox.adoptSession(sessionId, token: token)
            return
        }
        guard let store else { return }
        var queues: [ChatCommandTable] = [store.outbox]
        if let journal { queues.append(journal.runCommands(key)) }
        let made = ChatOutbox(queues: queues, api: api, token: token, sessionId: sessionId, held: true)
        made.onUnauthorized = onUnauthorized
        made.onDMOpened = { [weak self] dm in self?.sync?.dm.opened(dm) }
        outbox = made
        made.adoptSession(sessionId, token: token)
    }
}

/// The connection to an AgentPad server (C1). Started once at launch in
/// `server` mode and by `TeamMode.switchToServer`; in `off` mode it does
/// nothing and never touches the keychain.
@MainActor
@Observable
final class ChatService {
    static let shared: ChatService = {
        let service = ChatService(files: .standard, tokens: ChatKeychain.standard())
        service.followsFeed = true
        return service
    }()

    enum State: Equatable {
        case off
        /// No usable token: the user signs in again. Local tabs and agents work.
        case needsSignIn(String)
        case signedIn
        /// The account left this organization; the connection may later change.
        /// The confirmation owns its key, independently of the live connection.
        case notMember(ChatOrgKey, String)
    }

    /// Opens the event feed when signed in (C3, C8); off in tests that do not
    /// stand up a server.
    var followsFeed = false
    var dmToolsEnabled: @MainActor () -> Bool = { ChatDMSettings.enabled(in: AgentPadSettings.loadParsed() ?? [:]) } {
        didSet { if !dmToolsEnabled() { mcpDownloads.removeDM() } }
    }
    var dmToolCursors: [String: ChatDMToolCursor] = [:]
    var dmToolSending = Set<String>()
    /// Negotiated on each connection; never inferred from cached data.
    var serverCapabilities: [ChatServerAddress: Set<String>] = [:] {
        didSet {
            if oldValue.contains(where: { $0.value.contains("chat.avatars") && serverCapabilities[$0.key]?.contains("chat.avatars") != true }) { invalidateAvatars() }
            for (ref, editor) in avatarEdits where ref.key == connection?.orgKey &&
                oldValue[ref.key.server]?.contains("chat.avatars") != true && serverCapabilities[ref.key.server]?.contains("chat.avatars") == true {
                editor.capabilityAvailable()
            }
            if oldValue.contains(where: { $0.value.contains("chat.attachments") && serverCapabilities[$0.key]?.contains("chat.attachments") != true }) {
                mcpDownloads.removeAll()
            }
            for (server, previous) in oldValue where ["chat.dm", "chat.dm.session_signature", "chat.dm.attachments"].contains(where: {
                previous.contains($0) && serverCapabilities[server]?.contains($0) != true
            }) { mcpDownloads.removeDM(server: server) }
        }
    }
    @ObservationIgnored var avatarProfiles: () -> AgentProfileStore = { .shared }
    var avatarEdits: [ChatAvatarReference: ChatAvatarEditor] = [:]
    var avatarUploads: [ChatAvatarReference: (UUID, Task<Void, Never>)] = [:]
    var avatarInvalidations = 0
    var avatarEpoch: Int {
        avatarInvalidations + (connection?.orgKey.flatMap { orgSessions[$0]?.store?.avatarAccess.value } ?? 0)
    }
    var avatarGenerations: [ChatServerAddress: String] = [:]
    var avatarLimits: [ChatServerAddress: ChatAvatarLimits] = [:]
    @ObservationIgnored var avatarTransport: (ChatAvatarContext, ChatAPI)?
    @ObservationIgnored lazy var avatars: ChatAvatarCache = {
        let cache = ChatAvatarCache(isCurrent: { [weak self] in self?.avatarDownloadIsCurrent($0) == true },
                                    validate: { [weak self] in await self?.avatarDownloadAllowed($0, context: $1) == true }) {
            [weak self] ref in self?.avatarAuthorization(ref)
        }
        cache.onUnauthorized = { [weak self] context in
            guard let self, self.avatarContext(context.key) == context else { return }
            self.sessionEnded("Sign in again.")
        }
        return cache
    }()
    var serverAttachmentLimits: [ChatServerAddress: ChatAttachmentLimits] = [:]
    @ObservationIgnored var attachmentManagers: [ChatOrgKey: ChatAttachmentManager] = [:]
    var attachmentEpoch = 0
    @ObservationIgnored let mcpDownloads: ChatMCPDownloads
    var mcpDownloadDeadline: TimeInterval = 180
    @ObservationIgnored var attachmentCalls: [String: ChatAttachmentCallFiles] = [:]
    var serverB1Limits: [ChatServerAddress: ChatB1.Limits] = [:]
    // TTL refreshes are bookkeeping, not SwiftUI changes. The display revision
    // is coalesced and expires via one task for the whole service.
    @ObservationIgnored var channelActivity: [String: ChatChannelActivity] = [:]
    var channelActivityRevision = 0
    @ObservationIgnored var channelActivityExpiry: Task<Void, Never>?
    @ObservationIgnored lazy var channelActivityChanges = CoalescedMainActorAction(delay: 0.25) { [weak self] in
        self?.channelActivityRevision += 1
    }

    func supports(_ capability: String, key: ChatOrgKey) -> Bool {
        serverCapabilities[key.server]?.contains(capability) == true
    }
    /// Delay before retry `n` of `/v1/me` and of snapshots; nil keeps theirs
    /// (tests shorten it).
    var retryDelay: ((Int) -> TimeInterval)?
    /// The live connection of the signed-in session; a new one for every
    /// sign-in (review C-1).
    private(set) var feed: ChatFeed?
    var socket: ChatSocket? { feed?.socket }
    var accountFeed: ChatAccountFeed? { feed?.account }
    /// The socket's transport; replaced in tests.
    var makeSocketTransport: @MainActor () -> ChatSocketTransport = { ChatURLSessionTransport() }
    /// "A new device signed in…" and other notices for the user.
    var onNotice: @MainActor (AttentionEvent) -> Void = { _ in }
    /// What a run of this Mac does now (D4b §2.4); the owner's side tells it.
    var onRunActivity: @MainActor (ChatRunRecord, String) -> Void = { _, _ in }

    /// An ephemeral frame of an organization (D4b): `run.activity`, `run.access_wait`.
    var onEphemeral: @MainActor (_ org: String, _ type: String, _ body: ChatJSON) -> Void = { _, _, _ in }

    /// A hint to the run's audience (D4b): no queue, no repeat — lost is fine.
    func sendEphemeral(_ key: ChatOrgKey, type: String, body: [String: ChatJSON]) {
        guard state == .signedIn, let connection, connection.orgKey == key, let token else { return }
        let api = makeAPI(connection.server)
        Task {
            do { try await api.postEphemeral(org: key.orgId, type: type, body: .object(body), token: token) } catch {
                NSLog("agentpad: \(type) was not told: \(error.localizedDescription)")
            }
        }
    }

    /// The server took the owner's `agent.unpublish`: the local agent goes (D3b).
    var onAgentUnpublished: @MainActor (String) -> Void = { _ in }

    private(set) var state: State = .off {
        didSet {
            if state != oldValue {
                invalidateAttachments()
                invalidateAvatars()
                if state != .signedIn { onCloseConversations(connection?.orgKey) }
                onStateChange()
                // F4: signed out, another account, a session ended: notices that no longer apply go.
                ChatNotifications.reconcile(self)
            }
        }
    }
    /// The state changed (the team tools follow it: DESIGN-D6).
    var onStateChange: @MainActor () -> Void = {}

    /// Why the session cannot be used now, in the CLI's words; nil when it can.
    var sessionProblem: String? {
        switch state {
        case .signedIn: nil
        case .off: "not connected to a server"
        case .needsSignIn: "not connected to a server: sign in again in AgentPad"
        case .notMember: "not a member of the organization any more"
        }
    }

    /// A saved connection with its token: what is known of the session
    /// without a network. A session the server ended has no token.
    var hasSavedSession: Bool {
        guard let saved = try? files.loadConnections().first, saved.revoked != true,
              let token = try? tokens.read(account: saved.tokenAccount) else { return false }
        return token != nil
    }
    /// Whenever it changes, `TeamCalls` follows at once — before anything
    /// awaits — to the new organization's cache or to none (review D8c-3).
    private(set) var connection: ChatConnection? {
        didSet {
            if connection != oldValue {
                if let oldKey = oldValue?.orgKey, oldKey != connection?.orgKey { onCloseConversations(oldKey) }
                invalidateAttachments()
                invalidateAvatars()
                activateCalls()
                // F4: another account or organization — notices that no longer apply go (review F4b-5).
                ChatNotifications.reconcile(self)
            }
            if let session = connection?.sessionId, session != lastSession {
                if lastSession != nil { sessionChanged() }
                lastSession = session
            }
        }
    }
    /// The last session this app was connected under (Disconnect keeps it).
    private var lastSession: String?
    /// Folder grants of the earlier session are forgotten (D4b, lead's rule on review D4b2).
    var onSessionChanged: @MainActor () -> Void = {}

    /// Another session of this Mac — any sign-in — is as `4401` for what the
    /// earlier one began (lead's rule on review D4b2-A): its runs stop here,
    /// every approval and continuation of the account not spent is voided,
    /// and its folder grants are forgotten; nothing carries over. The
    /// server closes its requests.
    private func sessionChanged() {
        if let connection {
            do { try journal?.voidUnspent(server: connection.server.description, accountId: connection.accountId, reason: "executor_signed_out") } catch {
                // The launcher spends an approval under its own session only: refused all the same.
                NSLog("agentpad: approvals of the earlier session could not be voided: \(error.localizedDescription)")
            }
        }
        if let stopper { Task { await stopper.stopRuns() } }
        onSessionChanged()
    }
    /// One per (server, account, organization); one in the pilot.
    private(set) var orgSessions: [ChatOrgKey: ChatOrgSession] = [:]
    /// The token store is the developer's file, not the keychain.
    let isDevelopmentBuild: Bool

    /// Closes the session on the server; best effort, skipped without a
    /// network. Set by the HTTP client (C2).
    var closeRemoteSession: @MainActor (ChatConnection, String) async throws -> Void
    /// The HTTP client of a server; replaced in tests.
    var makeAPI: @MainActor (ChatServerAddress) -> ChatAPI = { ChatAPI(server: $0) }
    /// After `disconnect`: team work is off.
    var onDisconnected: @MainActor () -> Void = {}
    var onCloseConversations: @MainActor (ChatOrgKey?) -> Void = { _ in }
    private(set) var disconnectedDMCount: Int?
    /// The organization's connection is ready now (its generation settled, its
    /// requests' states this connection's); replaced in tests.
    @ObservationIgnored
    var isServerKnown: @MainActor (ChatService, ChatOrgKey) -> Bool = { service, key in
        guard let sync = service.orgSessions[key]?.sync, let socket = service.socket else { return false }
        return sync.state == .ready && sync.readyEpoch == socket.epoch && socket.state == .connected && !sync.needsSnapshot
            && socket.syncing.isEmpty && socket.stuck.isEmpty && sync.isSettled(on: socket)
    }

    let files: ChatFiles
    let orgCurrent = ChatOrgCurrent()
    let attentionAggregates = AttentionAggregates()
    private let tokens: ChatTokenStore
    private(set) var token: String?
    /// The run journal; nil outside server mode or when it is damaged —
    /// then `journalProblem` is set and server runs on this Mac are refused
    /// until `resetJournal` (C4).
    private(set) var journal: ChatJournal?
    private(set) var journalProblem: String?
    /// Tests replace this with an isolated projects directory.
    var claudeProjectsRoot = TeamSessionFiles.root
    private var beforeDisconnect: [@MainActor () async -> Void] = []

    init(files: ChatFiles, tokens: ChatTokenStore) {
        self.files = files
        self.mcpDownloads = ChatMCPDownloads(root: files.mcpDownloadsRoot)
        self.tokens = tokens
        disconnectedDMCount = files.savedDMCount
        self.isDevelopmentBuild = tokens is ChatDevTokenFile
        closeRemoteSession = { _, _ in }
        closeRemoteSession = { [unowned self] connection, token in
            try await self.makeAPI(connection.server).signOut(token: token)
        }
        launchRequest = { [unowned self] id in
            self.orgSessions.values.lazy.compactMap { session in
                session.store.flatMap { store in
                    if let request = try? store.calls.request(id), request.kind == "channel" {
                        guard let channel = request.channelId, ChatNotifications.allowed(self, session.key, channel: channel) else { return nil }
                    }
                    // An unspent Allow survives an app restart in this session.
                    // Its frozen snapshot is the one consented to, not a later
                    // edit or deletion of one of the context messages.
                    let approval = try? self.journal?.approval(session.key, requestId: id)
                    let params = approval.flatMap { try? TeamLaunchParams.decode($0.params) }
                    let request = try? store.calls.request(id)
                    if let params, let request, !self.automaticApprovalValid(session.key, request: request, params: params) { return nil }
                    let same = params?.session == self.connection?.sessionId && params?.channelId == request?.channelId
                        && params?.threadRootId == request?.threadRootId && params?.initiator == request?.initiatorAccountId
                        && params?.inputs.prompt == request?.text && params?.inputs.agentId == request?.agentId
                    return Self.launchRequest(id, store: store, frozenContext: same ? params?.inputs.context : nil)
                }
            }.first
        }
        requestState = { [unowned self] key, id in
            guard let request = try? self.orgSessions[key]?.store?.calls.request(id) else { return nil }
            return request.state.rawValue
        }
        installConversations()
        attentionAggregates.dmSource = ChatDMAttentionSource(service: self, immediateInitialValue: false)
        orgCurrent.follow(self)
    }

    /// Runs before the session is closed on `disconnect`, in the order added
    /// — stopping server runs and sending their facts (D11).
    func onBeforeDisconnect(_ handler: @escaping @MainActor () async -> Void) {
        beforeDisconnect.append(handler)
    }

    /// Reads the saved connection and its token, and starts serving it:
    /// the feed, then the organization's queue once `hello` confirmed the
    /// server generation. Called at launch and as step 5 of
    /// `TeamMode.switchToServer` (review C-18), and again after a new
    /// sign-in. Throws only when there is no connection to start; a token
    /// that cannot be read leaves the state `needsSignIn` with the reason,
    /// without retrying.
    func start(mode: TeamMode) async throws {
        guard mode == .server else { return }
        try await exclusively { try await self.startNow() }
    }

    // MARK: One operation at a time (review C2-10)

    /// Start, sign-in and Disconnect run one after another: none sees the
    /// middle of another, so a Disconnect still waiting cannot remove what a
    /// later sign-in kept.
    private var operationRunning = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    private func exclusively<T>(_ operation: @MainActor () async throws -> T) async rethrows -> T {
        while operationRunning {
            await withCheckedContinuation { operationWaiters.append($0) }
        }
        operationRunning = true
        defer {
            operationRunning = false
            if !operationWaiters.isEmpty { operationWaiters.removeFirst().resume() }
        }
        return try await operation()
    }

    private func startNow() async throws {
        guard let saved = try files.loadConnections().first else { throw ChatError.notConnected }
        stopFeed()
        // Another server or account: what belonged to the old one stops.
        for key in orgSessions.keys where key.server != saved.server || key.accountId != saved.accountId {
            dropSession(key)
        }
        connection = saved
        // Tokens no record names go; a failure is tried again at the next start.
        try? pruneTokens(keeping: [saved.tokenAccount])
        // Earlier sessions not closed yet: tried again at each start.
        if !files.loadClosing().isEmpty { Task { await self.closeEarlierSessions() } }
        openJournal()
        launcher?.open()
        // Runs an earlier app left behind are found and stopped first (D11).
        await recovery?.check()
        // Ended by the server: its token goes (again, if deleting it failed before).
        if saved.revoked == true {
            try? tokens.delete(account: saved.tokenAccount)
            token = nil
            state = .needsSignIn("The server closed this session. Sign in again.")
            return
        }
        do {
            guard let found = try tokens.read(account: saved.tokenAccount) else {
                token = nil
                state = .needsSignIn("Sign in to \(saved.server.host) again.")
                return
            }
            token = found
        } catch {
            token = nil
            state = .needsSignIn(error.localizedDescription)
            return
        }
        // Queues kept from an earlier session move to this one before any new
        // command is queued, and wait for this connection's hello (review C15-2).
        for session in orgSessions.values {
            guard let outbox = session.outbox, outbox.sessionId != saved.sessionId else { continue }
            outbox.hold()
            outbox.adoptSession(saved.sessionId, token: token!)
        }
        state = .signedIn
        if let key = saved.orgKey { _ = session(for: key) }
        activateCalls()
        if followsFeed {
            let feed = ChatFeed(service: self, connection: saved, token: token!)
            self.feed = feed
            feed.start()
            await feed.waitUntilStarted()
        }
    }

    /// Stops the live connection, if any.
    func stopFeed() {
        invalidateAvatars()
        invalidateAttachments()
        feed?.stop()
        feed = nil
    }

    // MARK: Feed (C8)

    /// The server ended the session (401 or 4401), whoever saw it — the
    /// socket, the send queue, a read of a window: the connection's work
    /// stops here, the same for all — socket and its retries, synchronization,
    /// sending held, the queues kept — and the user signs in again
    /// (review C6d: one path for every 401).
    func sessionEnded(_ reason: String) {
        attachmentManagers.values.forEach { $0.revoke(preservingDM: true) }
        stopFeed()
        // The server will not take this token again: it goes, so a restart
        // does not take the session for a live one (DESIGN-D6 §7.1). The
        // connection's record stays for signing in again.
        if let connection { forget(connection) }
        token = nil
        state = .needsSignIn(reason)
        // The executor's session is closed: every run stops here; its facts
        // are not the closed session's to send — the server closes its
        // requests (D4b, `4401`).
        if let stopper { Task { await stopper.stopAll() } }
    }

    /// The refused session is marked in its connection's record first —
    /// whatever the keychain does — and its token deleted; a delete that
    /// fails is tried again at the next start (review D6-2).
    private func forget(_ refused: ChatConnection) {
        do {
            var records = try files.loadConnections()
            for i in records.indices where records[i].tokenAccount == refused.tokenAccount { records[i].revoked = true }
            try files.saveConnections(records)
        } catch {
            NSLog("agentpad: the ended session could not be marked: \(error.localizedDescription)")
        }
        try? tokens.delete(account: refused.tokenAccount)
    }

    /// The account is no longer in the organization: its cache goes, the
    /// connection and the account's stream stay.
    func membershipLost(_ key: ChatOrgKey) {
        if self === ChatService.shared { CompositionTabs.shared.revoke(key) }
        attachmentManagers.removeValue(forKey: key)?.revoke()
        // Out of the organization: its runs stop here, with no fact — the
        // account may not tell them any more (DESIGN-D3b-D4b-D5b §10.3).
        if let stopper { Task { await stopper.stopAll(of: key) } }
        let name = try? orgSessions[key]?.store?.orgName
        orgSessions[key]?.outbox?.hold()
        reconcileChannelResults(revoked: key)
        clearB1PrivateState(key)
        let archived = (try? files.saveDMOutbox(key, store: orgSessions[key]?.store, preservingFiles: false)) != nil
        if !archived { try? orgSessions[key]?.store?.dmWrite { try ChatDMStore.clear($0) } }
        disconnectedDMCount = files.savedDMCount
        onCloseConversations(key)
        dropSession(key)
        if archived { files.removeCache(key) }
        if connection?.orgKey == key {
            state = .notMember(key, "You are no longer a member of \((name ?? nil) ?? "this organization").")
        }
    }

    /// Queues a command of the organization: through its send queue, or —
    /// before the queue runs — straight into the cache's table, to go once
    /// it does.
    @discardableResult
    func enqueue(_ key: ChatOrgKey, type: String, args: ChatJSON, orderKey: String? = nil, dependsOn: String? = nil,
                 afterCreateOf requestId: String? = nil) throws -> ChatCommandRecord {
        let session = session(for: key)
        if let outbox = session.outbox {
            // Queued under the session the record names, never a queue's earlier one (review C15-2).
            if let connection, let token, outbox.sessionId != connection.sessionId {
                outbox.adoptSession(connection.sessionId, token: token)
            }
            return try outbox.enqueue(org: key.orgId, type: type, args: args, orderKey: orderKey, dependsOn: dependsOn, afterCreateOf: requestId)
        }
        guard let store = session.store, let connection else { throw ChatError.notConnected }
        let id = ChatUUID.v7()
        let bytes = try ChatCommandEnvelope(commandId: id, org: key.orgId, type: type, args: args).encoded()
        var tables = [store.outbox]
        if let journal { tables.append(journal.runCommands(key)) }
        let seq = try ChatCommandTable.maxSeq(tables) + 1
        let record = ChatCommandRecord(commandId: id, sessionId: connection.sessionId, type: type, bodyBytes: bytes,
                                       orderKey: orderKey ?? key.orgId, dependsOn: dependsOn, createdAt: Date(), state: .pending)
        if let requestId { return try store.outbox.enqueue(record, afterCreateOf: requestId, seq: seq) }
        return try store.outbox.enqueue(record, seq: seq)
    }

    /// A command of the organization made but not stored, for a caller that
    /// stores it in its own transaction (`ChatCommandTable.insert`) with what
    /// it belongs to, then calls `sent` (D5): through the send queue, or —
    /// before it runs — as `enqueue` would make it. Never makes a session.
    func prepareCommand(_ key: ChatOrgKey, type: String, args: ChatJSON) throws -> (record: ChatCommandRecord, table: ChatCommandTable, sent: @MainActor () -> Void) {
        guard let session = orgSessions[key], let store = session.store, let connection, connection.orgKey == key else {
            throw ChatError.notConnected
        }
        // A call's commands go in its own order (`out:<request_id>`, §3.1):
        // a `429` of one call holds no other (review D5b2-3).
        let order = args["request_id"]?.string.map { "out:\($0)" }
        if let outbox = session.outbox {
            if let token, outbox.sessionId != connection.sessionId { outbox.adoptSession(connection.sessionId, token: token) }
            var record = try outbox.prepare(org: key.orgId, type: type, args: args)
            if let order { record.orderKey = order }
            return (record, store.outbox, { [weak outbox] in outbox?.pump() })
        }
        let id = ChatUUID.v7()
        let bytes = try ChatCommandEnvelope(commandId: id, org: key.orgId, type: type, args: args).encoded()
        var tables = [store.outbox]
        if let journal { tables.append(journal.runCommands(key)) }
        var record = ChatCommandRecord(commandId: id, sessionId: connection.sessionId, type: type, bodyBytes: bytes,
                                       orderKey: order ?? key.orgId, dependsOn: nil, createdAt: Date(), state: .pending)
        record.seq = try ChatCommandTable.maxSeq(tables) + 1
        return (record, store.outbox, {})
    }

    /// D5: calls asked here the server refused, or whose command was
    /// dropped and not carried, end as `failed` — then the same way as an
    /// outcome from the server: the calls read again (whoever waits on one
    /// wakes) and the outcome's notice runs.
    /// A write that fails is tried again after a pause, as the reconcile
    /// owed is (review D5-p1-1).
    func settleCreates(_ key: ChatOrgKey) {
        guard let session = orgSessions[key], let calls = session.store?.calls else { return }
        let settled: [String]
        do { settled = try calls.settleCreates() } catch { return settleLater(key) }
        guard !settled.isEmpty else { return }
        onCallsChanged(key)
        session.actions?.run()
    }

    private func settleLater(_ key: ChatOrgKey) {
        guard settleOwed[key] == nil else { return }
        let delay = reconcileDelay
        settleOwed[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.settleOwed[key] = nil
            self.settleCreates(key)
        }
    }

    /// The account is in its organization again.
    func membershipRegained(_ key: ChatOrgKey) {
        if case .notMember(let removed, _) = state, removed == key, connection?.orgKey == key {
            state = .signedIn
        }
    }

    /// The organization's state, made on first use. Its requests are
    /// reconciled at once: what the cache held at launch owes its actions now.
    func session(for key: ChatOrgKey) -> ChatOrgSession {
        if let existing = orgSessions[key] { return existing }
        let made = ChatOrgSession(key: key, files: files)
        orgSessions[key] = made
        made.actions = runner(for: key)
        made.actions?.attach(made.store?.calls)
        reconcileCalls(made)
        // Calls asked before a crash whose `request.create` was refused meanwhile (D5).
        settleCreates(key)
        activateCalls()
        return made
    }

    /// The calls `TeamCalls` shows and makes: those of the connection's
    /// current (server, account, organization), or none (D8).
    var onCallStore: @MainActor (ChatOrgKey?, ChatCallStore?) -> Void = { _, _ in }
    /// The cache last handed over, and whose.
    private var activeCalls: (key: ChatOrgKey, store: ChatStore)?

    /// Hands `TeamCalls` the current organization's cache whenever that
    /// changes: another organization, a new state of the same one, none
    /// (review D8b-4). A session of another organization changes nothing.
    func activateCalls() {
        let key = connection?.orgKey
        let store = key.flatMap { orgSessions[$0]?.store }
        if let key, let store {
            if activeCalls?.key == key, activeCalls?.store === store { return }
            activeCalls = (key, store)
            onCallStore(key, store.calls)
        } else if activeCalls != nil {
            activeCalls = nil
            onCallStore(nil, nil)
        }
    }
    /// An organization's requests changed in its cache.
    var onCallsChanged: @MainActor (ChatOrgKey) -> Void = { _ in }

    /// The organization's state goes: its calls leave `TeamCalls` with it.
    private func dropSession(_ key: ChatOrgKey) {
        guard let session = orgSessions.removeValue(forKey: key) else { return }
        session.sync?.stop()
        session.dmList?.stop()
        // The runner stays; it has no cache until a new state hands one.
        session.actions?.attach(nil)
        session.outbox?.hold()
        activateCalls()
    }

    // MARK: Calls (D8)

    /// One action runner per (server, account, organization) for the life
    /// of the app: the organization's states come and go, the runner stays —
    /// no row is ever run twice at once (lead's decision after review D8e).
    private var runners: [ChatOrgKey: ChatActionRunner] = [:]

    func runner(for key: ChatOrgKey) -> ChatActionRunner {
        if let existing = runners[key] { return existing }
        let made = ChatActionRunner(key: key)
        made.handler = { [weak self] in self?.actionHandlers[$0] }
        // Only while the server is known on the current connection — the
        // condition handlers check (`isServerKnown`); it becoming true wakes
        // the runners (`serverKnown`, `ChatSync.onInStep`) (review D8f-p2-2).
        made.mayRun = { [weak self] in self.map { $0.isServerKnown($0, key) } ?? false }
        runners[key] = made
        return made
    }

    /// The handlers of actions by kind (D4, D5, D11 register theirs).
    var actionHandlers: [ChatActionKind: ChatActionHandler] = [:]

    /// The run journal's facts of an organization's requests; nil without a
    /// journal, or when it cannot be read — then nothing of the executor's
    /// side is decided.
    /// A journal that exists but could not be read owes the organization
    /// another reconcile, a little later (review D8f-p2-5).
    func localFacts(_ key: ChatOrgKey, _ requestIds: [String]) -> [String: ChatLocalFacts]? {
        guard let journal else { return nil }
        do {
            if journalReadFails() { throw ChatError.storage("a read failed (test)") }
            return try journal.facts(key, requestIds: requestIds) { [launcher] in launcher?.isLive($0) ?? false }
        } catch {
            NSLog("agentpad: the run journal could not be read: \(error.localizedDescription)")
            reconcileLater(key)
            return nil
        }
    }

    /// Tests: reading the journal's facts fails while true.
    var journalReadFails: () -> Bool = { false }
    /// Pause before a reconcile owed; shortened in tests.
    var reconcileDelay: Duration = .seconds(5)
    private var reconcileOwed: [ChatOrgKey: Task<Void, Never>] = [:]
    private var settleOwed: [ChatOrgKey: Task<Void, Never>] = [:]

    func reconcileLater(_ key: ChatOrgKey) {
        guard reconcileOwed[key] == nil else { return }
        let delay = reconcileDelay
        reconcileOwed[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.reconcileOwed[key] = nil
            if let session = self.orgSessions[key] { self.reconcileCalls(session) }
        }
    }

    /// Every request of the organization's cache gets the actions it owes,
    /// and they run (6.12: at launch, and when the journal comes back). Old
    /// history goes first.
    func reconcileCalls(_ session: ChatOrgSession) {
        guard let store = session.store else { return }
        try? store.calls.trim()
        guard let ids = try? store.calls.requestIds() else { return reconcileLater(session.key) }
        do { try store.reconcileAll(facts: localFacts(session.key, ids)) } catch {
            NSLog("agentpad: the requests of \(session.key.orgId) could not be reconciled: \(error.localizedDescription)")
            reconcileLater(session.key)
        }
        session.actions?.run()
        settlePublications(session.key)
        if isServerKnown(self, session.key) { announceAfterNewSession(session.key) }
        onCallsChanged(session.key)
    }

    // MARK: Signing in

    /// Asks the server to mail a sign-in code.
    func requestCode(server: ChatServerAddress, email: String) async throws {
        try await makeAPI(server).requestCode(email: email)
    }

    /// Checks the code and opens a session on the server; keeps nothing yet
    /// (the connection window decides about the organization first).
    func authenticate(server: ChatServerAddress, email: String, code: String, deviceName: String) async throws -> ChatSignIn {
        try await makeAPI(server).signIn(email: email, code: code, deviceName: deviceName)
    }

    /// Closes a session that is not kept (no organization to open).
    func discard(_ answer: ChatSignIn, server: ChatServerAddress) async {
        try? await makeAPI(server).signOut(token: answer.token)
    }

    /// Keeps a sign-in with the organization chosen: its token only, in a
    /// keychain item of its own session. The server record is written by
    /// `keepSignIn`, once team work moved to the server: a move refused
    /// leaves no record behind (decision "Переход на сервер — только из
    /// выключенной командной работы"). Serving it — the feed, the queue moved
    /// to the new session (6.4) — starts with `start(mode:)` (review C-18).
    @discardableResult
    func completeSignIn(_ answer: ChatSignIn, server: ChatServerAddress, deviceName: String, orgId: String?,
                        stillValid: @escaping @MainActor () -> Bool = { true }) async throws -> ChatConnection {
        try await exclusively {
            guard stillValid() else { throw CancellationError() }
            return try await self.completeSignInNow(answer, server: server, deviceName: deviceName, orgId: orgId)
        }
    }

    /// The connection the server record names while a newer sign-in is not
    /// kept yet: its session closes and its token goes once the record names
    /// the new one (review C13-1).
    private var replaced: ChatConnection?

    /// The sign-in not yet kept on disk: its record is written now, then the
    /// session it replaces closes and its token goes. A crash at any step
    /// leaves a record whose own token is in the keychain.
    func keepSignIn() async throws {
        guard let connection else { throw ChatError.notConnected }
        try files.saveConnections([connection])
        guard let old = replaced else { return }
        replaced = nil
        await retire(old)
    }

    /// A sign-in team work did not move to (a call began meanwhile): its
    /// session closes and its token goes; the record, if any, still names
    /// the connection before it, whose token stays.
    func discardSignIn(expecting expected: ChatConnection? = nil) async {
        await exclusively {
            guard expected == nil || self.connection == expected else { return }
            self.stopFeed()
            self.replaced = nil
            guard let connection = self.connection else { return }
            if let token = self.token { try? await self.closeRemoteSession(connection, token) }
            try? self.tokens.delete(account: connection.tokenAccount)
            self.connection = nil
            self.token = nil
            self.state = .off
        }
    }

    /// Removes every token of AgentPad's server sign-ins other than
    /// `keeping`: earlier sessions, accounts or servers a crash or a failed
    /// delete left in the keychain — one record, one server in the pilot
    /// (review C14-2, C15-1). Run at every start and by Disconnect, so
    /// nothing left behind is forgotten.
    func pruneTokens(keeping: Set<String>) throws {
        // The tokens of earlier sessions still to close stay until they are closed.
        let closing = Set(files.loadClosing().map(\.tokenAccount))
        for account in try tokens.accounts() where !keeping.contains(account) && !closing.contains(account) {
            try tokens.delete(account: account)
        }
    }

    /// Closes a session no record names any more and removes its token; a
    /// token that could not be removed goes with the next start's pruning.
    /// An earlier session of this Mac is closed on the server — a debt, as a
    /// fact is: kept on disk with its token until the server took it (or
    /// says it is closed already), tried again after a failure and at the
    /// next start. Only a closed session's requests are closed by the
    /// server (lead's rule on review D4b, server d8d2ea0).
    private func retire(_ old: ChatConnection) async {
        var closing = files.loadClosing()
        if !closing.contains(where: { $0.tokenAccount == old.tokenAccount }) { closing.append(old) }
        do { try files.saveClosing(closing) } catch {
            NSLog("agentpad: the earlier session could not be kept to close: \(error.localizedDescription)")
        }
        await closeEarlierSessions()
    }

    /// Delay before closing earlier sessions again after a failure; shortened in tests.
    var closingRetryDelay: Duration = .seconds(30)
    private var closingRetry: Task<Void, Never>?

    /// Closes every earlier session kept to close; one that fails is tried again later.
    func closeEarlierSessions() async {
        var closed: Set<String> = []
        for old in files.loadClosing() {
            // A keychain that could not be read is not a token gone: kept,
            // tried again (review D5b3-2). Only a confirmed absence lets it go.
            let read: String?
            do { read = try tokens.read(account: old.tokenAccount) } catch { continue }
            guard let token = read else {
                closed.insert(old.tokenAccount)
                continue
            }
            do {
                try await closeRemoteSession(old, token)
            } catch ChatAPIError.server(status: 401, _, _) {
                // Closed already.
            } catch {
                continue
            }
            closed.insert(old.tokenAccount)
            // A delete that fails goes with the next start's pruning.
            try? tokens.delete(account: old.tokenAccount)
        }
        // Read again — another may have been added meanwhile: what is not
        // closed is still to close.
        let still = files.loadClosing().filter { !closed.contains($0.tokenAccount) }
        try? files.saveClosing(still)
        guard !still.isEmpty, closingRetry == nil else { return }
        let delay = closingRetryDelay
        closingRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.closingRetry = nil
            await self.closeEarlierSessions()
        }
    }

    private func completeSignInNow(_ answer: ChatSignIn, server: ChatServerAddress, deviceName: String,
                                   orgId: String?) async throws -> ChatConnection {
        let made = ChatConnection(server: server, accountId: answer.accountId, sessionId: answer.sessionId,
                                  deviceName: deviceName, orgId: orgId)
        // The old session's connection stops before anything of the new one exists.
        stopFeed()
        try tokens.write(answer.token, account: made.tokenAccount)
        let recorded = try? files.loadConnections().first
        if let recorded, recorded.tokenAccount != made.tokenAccount { replaced = recorded }
        // A sign-in no record names, replaced before it was kept, goes now.
        if let unkept = connection, unkept.tokenAccount != made.tokenAccount, unkept.tokenAccount != recorded?.tokenAccount {
            await retire(unkept)
        }
        connection = made
        token = answer.token
        openJournal()
        state = .signedIn
        return made
    }

    private func openJournal() {
        guard journal == nil else { return }
        do {
            let opened = try ChatJournal.open(files: files)
            journal = opened
            journalProblem = nil
            makeExecutor()
            attachJournal(opened)
        } catch {
            journalProblem = error.localizedDescription
            // Earlier runs cannot be checked: no agent starts, in any mode,
            // until the journal opens or is reset (review C11-3).
            TeamRunAdmission.journalBlocks = { _ in true }
        }
    }

    // MARK: Recovery actions (review C3-6)

    /// What stopped, for the Team window: one line per problem — the
    /// connection's state, a sign-in not undone, each organization's cache
    /// and queue (review C12-5).
    var problems: [String] {
        var lines: [String] = []
        if case .needsSignIn(let text) = state { lines.append(text) }
        for (_, session) in orgSessions.sorted(by: { $0.key.orgId < $1.key.orgId }) {
            if let problem = session.problem { lines.append(problem) }
        }
        for (_, session) in orgSessions.sorted(by: { $0.key.orgId < $1.key.orgId }) {
            guard let outbox = session.outbox else { continue }
            // From what is stored, so it is there after a restart too (review C4-9).
            let unconfirmed = outbox.unconfirmed.filter { !ChatOutbox.neverResent($0.type) }.count
            if unconfirmed > 0 {
                lines.append("The server was restored from a backup. \(unconfirmed) change(s) made before were not confirmed; send them again or leave them.")
            }
            let refused = outbox.refused
            if !refused.isEmpty {
                let codes = Set(refused.compactMap(\.error)).sorted().joined(separator: ", ")
                lines.append("The server refused \(refused.count) change(s) (\(codes)).")
            }
            switch outbox.paused {
            case .generationChanged?:
                if unconfirmed == 0 { lines.append("The server was restored from a backup; sending is paused.") }
            case .storageFailed(let text)?:
                lines.append("Changes cannot be saved on this Mac: \(text)")
            case .needsSignIn?:
                lines.append("The server closed this session. Connect again to send the changes waiting here.")
            case nil:
                break
            }
        }
        if let socket, !socket.stuck.isEmpty {
            lines.append("\(socket.stuck.count) part(s) of the organization could not be brought up to date.")
        }
        return lines
    }

    /// The user has read the refused changes.
    func dismissRefused() {
        for session in orgSessions.values {
            session.outbox?.dismissRefused()
            session.acknowledgeProblem()
        }
    }

    /// Something only to be read and dismissed: refused changes, a cache made anew.
    var hasRefused: Bool {
        orgSessions.values.contains { !($0.outbox?.refused.isEmpty ?? true) || ($0.problem != nil && $0.store != nil) }
    }

    /// Everything stopped tries again: unconfirmed changes are sent again as
    /// new commands — never `run.*` or `request.decide` — a queue stopped on
    /// storage is retried, stuck streams are followed again.
    func retryStopped() {
        for session in orgSessions.values {
            guard let outbox = session.outbox else { continue }
            // Publications waiting for the owner go again too, from their assignment (D3).
            resendPublications(session.key)
            _ = try? outbox.resendUnconfirmed()
            switch outbox.paused {
            case .generationChanged?:
                outbox.resume()
            case .storageFailed?:
                outbox.retryStorage()
            default:
                break
            }
            // What was made goes now, if the connection allows (review C5-8).
            outbox.pump()
        }
        for stream in socket?.stuck ?? [] { socket?.unstick(stream) }
    }

    /// How long Disconnect waits for queued run facts to be taken.
    var factsGrace: Duration = .seconds(10)

    private func waitForExecutorFacts() async {
        guard let journal, let connection else { return }
        let deadline = ContinuousClock.now + factsGrace
        while ContinuousClock.now < deadline {
            let sessions = orgSessions.filter { $0.key.server == connection.server && $0.key.accountId == connection.accountId }
            let waiting = sessions.contains { key, session in
                guard session.outbox?.isSending == true else { return false }
                let open = (try? journal.commands(for: key)) ?? []
                return open.contains { $0.state == .pending && $0.type.hasPrefix("run.") }
            }
            guard waiting else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The user chose to reset a damaged run journal. The organizations'
    /// queues take the new journal's table (review C3-14).
    func resetJournal() throws {
        try journal?.queue.close()
        let fresh = try ChatJournal.reset(files: files)
        journal = fresh
        journalProblem = nil
        makeExecutor()
        attachJournal(fresh)
    }

    /// A journal opened or reset while organizations' queues exist: their
    /// queues take its table. The synchronizers keep the generation in it,
    /// and a new hello prepares it before anything is sent or run (review
    /// C3-14, C4-6, C14-4).
    private func attachJournal(_ journal: ChatJournal) {
        guard !orgSessions.isEmpty else { return }
        for (key, session) in orgSessions {
            session.sync?.generationState = journal
            session.outbox?.hold()
            session.outbox?.replaceJournal(journal.runCommands(key))
            reconcileCalls(session)
        }
        socket?.reconnectNow(force: true, reason: .journalChanged)
    }

    /// At launch, in any mode: a run journal left on disk is opened and its
    /// open runs are found, registered (Y4) and stopped, their facts queued
    /// for when a server is connected again (review C3-9, C3-10). Nothing
    /// is created when there is no journal.
    func recoverRunsAtLaunch() async {
        ChatAttachmentCallFiles.sweep()
        // One point decides whether agents may start (review C11-3, C12-1):
        // no journal for sure — they may; a journal opened — it says; a
        // journal that cannot be looked at or opened — none may.
        var info = stat()
        if stat(files.journalURL.path, &info) != 0 {
            let reason = errno
            guard reason == ENOENT else {
                journalProblem = "The run journal cannot be looked at: \(String(cString: strerror(reason)))."
                TeamRunAdmission.journalBlocks = { _ in true }
                return
            }
            TeamRunAdmission.journalBlocks = { _ in false }
            return
        }
        openJournal()
        await recovery?.check()
    }

    // MARK: Executor (D9, D11)

    /// Starts server-mode runs from approvals only; nil while the journal
    /// cannot be opened, so nothing runs then.
    private(set) var launcher: TeamLauncher?
    private(set) var recovery: TeamRunRecovery?
    private(set) var stopper: TeamRunStopper?
    /// The runner of server-mode runs; replaced in tests.
    var executorRunner: TeamAgentRunner = ClaudeCodeRunner()
    /// The local agent by id (`agents.json`); set by the app.
    var localAgent: @MainActor (String) -> TeamPublishedAgent? = { id in
        TeamService.shared.calls.agents.first { $0.id.uuidString.lowercased() == id }
    }
    /// Owners of commands by type, told of the server's final answer
    /// (`commandAnswered`); `agent.publish` is D3's own.
    var commandOwners: [String: @MainActor (ChatOrgKey, ChatCommandRecord, ChatCommandOutcome) -> Void] = [:]
    /// F3: channel tabs open now, counted by their channel.
    var openChannelTabs: [ChannelRef: Int] = [:]
    var openDMTabs: [ChatDMRef: Set<UUID>] = [:]
    /// The owner's side (D4), once installed by the app.
    var owner: ChatOwnerSide?
    /// A request waits for this owner's decision (`notify_decision`): told once.
    var onDecisionWanted: @MainActor (String) -> Void = { _ in }
    /// Bumped whenever a publication changed (D3): its views read again.
    var publishRevision = 0
    /// Problems of publications by operation and organization; each tried
    /// again (`reconcileLater`) and cleared by its own success.
    var publishProblems: [String: String] = [:]
    /// The request as the cache has it (D8); replaced in tests.
    var launchRequest: @MainActor (String) -> TeamLaunchRequest? = { _ in nil }
    /// A request's state as this organization's cache has it (D8); nil when
    /// it is not known. Keyed by the organization (review C6-9).
    var requestState: @MainActor (ChatOrgKey, String) -> String? = { _, _ in nil }

    /// What a run is built from, out of the cache: the request's text, its
    /// caller by name, the project it was asked from, its deadline.
    /// Whose thread a set of requests is (D5b §3.2, F6): a personal one's is
    /// its initiator's, as the journal recorded at the Allow; a channel's is
    /// its channel and root. No case checks nothing (lead's rule on 7a17ada).
    enum ThreadScope: Equatable {
        case personal(initiator: String)
        case channel(channelId: String, rootId: String)

        func admits(_ params: TeamLaunchParams?) -> Bool {
            switch self {
            case .personal(let initiator): params?.initiator == initiator && params?.channelId == nil
            case .channel(let channelId, let rootId): params?.channelId == channelId && params?.threadRootId == rootId
            }
        }
    }

    /// What this Mac has of a request's thread.
    enum ThreadLookup: Equatable {
        /// The request names no thread.
        case none
        /// A thread this Mac never had with this caller and agent: declined.
        case unknown
        /// Had here: its latest finished run's conversation, or none yet (a
        /// run allowed, not finished: the next starts its own).
        case known(conversation: String?)
    }

    /// The thread a request goes on (D5b §3.2, F6): channel history comes
    /// directly from the journal's full key, beyond the snapshot window.
    /// Personal threads use the cache's request ids. `includingItself`: the
    /// request's own run counts too — the owner's Continue… (F6).
    func threadLookup(_ request: ChatRequest, store: ChatStore, key: ChatOrgKey, includingItself: Bool = false) -> ThreadLookup {
        if request.kind == "channel" {
            guard let channel = request.channelId, let root = request.threadRootId else { return .none }
            guard let agent = request.agentId else { return .unknown }
            // A channel's first request is allowed too. Its participants do
            // not own the thread; the channel team does (F6).
            let entries = threadEntries(nil, key: key, agentId: agent, scope: .channel(channelId: channel, rootId: root))
                .filter { includingItself || $0.requestId != request.requestId }
            guard !entries.isEmpty else { return .unknown }
            return .known(conversation: entries.first { $0.finished }?.conversation)
        }
        guard let thread = includingItself ? (request.threadId ?? request.requestId) : request.threadId else { return .none }
        guard journal != nil, let agentId = request.agentId, let initiator = request.initiatorAccountId else { return .unknown }
        let ids = (try? store.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT request_id FROM requests WHERE agent_id = ? AND initiator_account_id = ? AND (request_id != ? OR ?)
                    AND (request_id = ? OR thread_id = ?)
                """, arguments: [agentId, initiator, request.requestId, includingItself, thread, thread])
        }) ?? []
        return threadRuns(ids, key: key, agentId: agentId, scope: .personal(initiator: initiator))
    }

    /// The conversation of the latest finished run of a thread, if any.
    func latestConversation(_ requestIds: [String], key: ChatOrgKey, agentId: String, scope: ThreadScope) -> String? {
        if case .known(let conversation) = threadRuns(requestIds, key: key, agentId: agentId, scope: scope) { return conversation }
        return nil
    }

    /// The thread among `requestIds` as this Mac allowed it: approvals of this
    /// organization and `agentId` only — the journal is every server's, a
    /// request id is not a key (review D5b-1) — of the server's generation
    /// now, admitted by `scope` as the journal recorded it at the Allow, not
    /// as the server says of the id now (review D5b2-1). Known when one was
    /// allowed; its conversation is the latest finished run's.
    func threadRuns(_ requestIds: [String], key: ChatOrgKey, agentId: String, scope: ThreadScope) -> ThreadLookup {
        let admitted = threadEntries(requestIds, key: key, agentId: agentId, scope: scope)
        guard !admitted.isEmpty else { return .unknown }
        return .known(conversation: admitted.first { $0.finished }?.conversation)
    }

    struct ThreadEntry {
        let requestId: String
        let params: TeamLaunchParams
        let conversation: String?
        let finished: Bool
    }

    /// The journal's full key and frozen scope apply equally to lookup and
    /// memory shown in a channel. Nil ids counts history even beyond the cache.
    func threadEntries(_ requestIds: [String]?, key: ChatOrgKey, agentId: String, scope: ThreadScope) -> [ThreadEntry] {
        guard requestIds?.isEmpty != true, let journal, let generation = try? journal.generation(key).generation else { return [] }
        let filter = requestIds.map { "AND a.request_id IN (" + $0.map { _ in "?" }.joined(separator: ",") + ")" } ?? ""
        let channelFilter: String
        var arguments = [key.server.description, key.accountId, key.orgId, agentId, generation] + (requestIds ?? [])
        switch scope {
        case .personal: channelFilter = ""
        case .channel(let channel, let root):
            channelFilter = """
                AND r.kind = 'channel' AND r.org = a.org_id AND r.agent_id = a.agent_id
                    AND r.channel_id = ? AND r.thread_root_id = ? AND r.channel_revoked = 0
                """
            arguments += [channel, root]
        }
        let rows = (try? journal.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.request_id, a.params, r.conversation_id, r.outcome FROM approvals a LEFT JOIN runs r ON r.approval_id = a.id
                WHERE a.server = ? AND a.account_id = ? AND a.org_id = ? AND a.agent_id = ? AND a.generation = ? AND a.kind = 'initial'
                    \(filter) \(channelFilter)
                ORDER BY r.ended_at DESC, r.started_at DESC, r.run_id DESC
                """, arguments: StatementArguments(arguments))
        }) ?? []
        return rows.compactMap { row in
            guard let params = try? TeamLaunchParams.decode(row["params"]), scope.admits(params) else { return nil }
            return ThreadEntry(requestId: row["request_id"], params: params, conversation: row["conversation_id"],
                               finished: (row["outcome"] as String?) == ChatRunRecord.Outcome.finished.rawValue)
        }
    }

    static func launchRequest(_ id: String, store: ChatStore, frozenContext: String? = nil) -> TeamLaunchRequest? {
        guard let request = try? store.calls.request(id), request.hasFixed, let text = request.text,
              let deadline = request.deliverBy.flatMap(ChatStore.date)
        else { return nil }
        let caller = try? store.queue.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM members WHERE account_id = ?", arguments: [request.initiatorAccountId])
        }
        var made = TeamLaunchRequest(requestId: id, prompt: text, context: nil, callerName: (caller ?? nil) ?? "a colleague",
                                     callerProject: request.origin?.project, conversationId: nil, expiresAt: deadline)
        // The thread, by its key (D5b §3.2): its conversation is the start's to choose.
        if request.kind == "channel" {
            let content = try? store.queue.read { try ChatChannelContent.read($0, request: id) }
            guard let channel = request.channelId, let context = frozenContext ?? content?.launchContext else { return nil }
            made.context = context
            made.attachments = content?.attachments
            if request.conditionsVersion == 2 && made.attachments?.isEmpty != false { return nil }
            made.channelId = channel
            made.threadRootId = request.threadRootId
            made.sourceMessageId = request.sourceMessageId
            made.replyMode = request.replyMode
            made.thread = request.threadRootId.map { "channel:\(channel):\($0)" }
        } else {
            made.thread = request.threadId.map { "personal:\($0)" }
        }
        return made
    }
    private var stopperRegistered = false

    private func makeExecutor() {
        guard let journal else { return }
        let launcher = TeamLauncher(journal: journal, runner: executorRunner)
        launcher.agent = { [weak self] in self?.localAgent($0) }
        launcher.request = { [weak self] in self?.launchRequest($0) }
        launcher.prepareAttachmentFiles = { [weak self] params, row in
            guard let self else { throw ChatAttachmentError.unavailable }
            return try await self.prepareAttachmentFiles(params, row: row)
        }
        launcher.verifyAttachmentFiles = { [weak self] files in
            guard let self else { throw ChatAttachmentError.unavailable }
            try await self.verifyAttachmentFiles(files)
        }
        launcher.requestCanExecute = { [weak self] id in
            guard let self, let key = self.connection?.orgKey, let state = self.requestState(key, id) else { return false }
            return ["starting", "running"].contains(state)
        }
        // The journal's generation; nothing runs while a change of it is
        // under way (review C3-3).
        // The journal's generation and any change of it under way, in one read
        // that fails as a whole (review C7-8).
        launcher.generationState = { [weak journal] key in
            guard let journal else { throw ChatError.storage("no run journal") }
            return try journal.generation(key)
        }
        launcher.facts = self
        launcher.onActivity = { [weak self] row, text in self?.onRunActivity(row, text) }
        launcher.currentSession = { [weak self] in self?.connection?.sessionId }
        // At the start: the thread's latest finished run's conversation (F6, D9).
        launcher.threadConversation = { [weak self] approval in
            guard let self, let key = approval.key, let store = self.orgSessions[key]?.store,
                  let request = (try? store.calls.request(approval.requestId)) ?? nil,
                  case .known(let conversation) = self.threadLookup(request, store: store, key: key)
            else { return nil }
            return conversation
        }
        launcher.resolveChannelConversation = { [weak self] id in
            guard let self else { return nil }
            return try? ClaudeSessionResume.resolve(id, root: self.claudeProjectsRoot, visibility: .init(channelIds: [])).get()
        }
        // Both modes start agents through one runner: it asks the journal too (review C10-6).
        TeamRunAdmission.journalBlocks = { [weak journal, weak launcher] agentId in
            guard let journal else { return false }
            guard let rows = try? journal.unfinishedRuns() else { return true }
            return rows.contains { $0.agentId == agentId && $0.processesGoneAt == nil && !(launcher?.isLive($0.runId) ?? false) }
        }
        let recovery = TeamRunRecovery(journal: journal) { [weak launcher] in launcher?.isLive($0) ?? false }
        recovery.facts = self
        launcher.recovery = recovery
        let stopper = TeamRunStopper(launcher: launcher)
        self.launcher = launcher
        self.recovery = recovery
        self.stopper = stopper
        if !stopperRegistered {
            stopperRegistered = true
            // Runs stop and their facts are queued before the session closes.
            onBeforeDisconnect { [weak self] in await self?.stopper?.stopAll() }
        }
    }

    /// Keeps a sign-in at once: the token first, then the record that allows
    /// connecting at the next launch. One server and account in the pilot.
    func saveSignIn(_ connection: ChatConnection, token: String) throws {
        try tokens.write(token, account: connection.tokenAccount)
        do {
            try files.saveConnections([connection])
        } catch {
            try? tokens.delete(account: connection.tokenAccount)
            throw error
        }
        self.connection = connection
        self.token = token
        openJournal()
        state = .signedIn
    }

    /// Leaves the server: (1) the handlers registered with
    /// `onBeforeDisconnect`; (2) the session is closed on the server (skipped
    /// without a network); (3) the token, (4) the saved record and (5) the
    /// cache files go. `journal.sqlite` stays: it holds assignments, the run
    /// log and results not yet delivered (6.11).
    func disconnect() async {
        _ = await disconnect(expecting: nil)
    }

    /// What one Disconnect did (C7).
    enum DisconnectOutcome: Equatable {
        case done
        /// A step did not finish; the connection stays (the core's text).
        case notFinished(String)
        /// The connection is no longer the one asked for: nothing done.
        case stale
    }

    /// Disconnect of `expected` — checked inside the serialized part, so a
    /// sign-in in between is never the one disconnected — or of whatever
    /// connection there is (`nil`). The outcome is this call's own (C7).
    func disconnect(expecting expected: ChatConnection?) async -> DisconnectOutcome {
        await exclusively {
            if let expected, self.connection != expected { return .stale }
            await self.disconnectNow()
            if self.connection == nil { return .done }
            if case .needsSignIn(let text) = self.state { return .notFinished(text) }
            return .notFinished("Disconnect did not finish.")
        }
    }

    private func disconnectNow() async {
        for handler in beforeDisconnect { await handler() }
        // The facts those handlers queued go before the session closes, while
        // the queue can send — at most `factsGrace`; what does not go stays
        // in the journal (review C3-13).
        await waitForExecutorFacts()
        // Nothing of the connection outlives Disconnect, also a start still
        // waiting for an answer (review C-16).
        stopFeed()
        for session in orgSessions.values {
            session.sync?.stop()
            session.outbox?.hold()
        }
        guard let connection else {
            state = .off
            onDisconnected()
            return
        }
        if let token { try? await closeRemoteSession(connection, token) }
        token = nil
        var keys = Set(orgSessions.keys.filter { $0.server == connection.server && $0.accountId == connection.accountId })
        keys.formUnion(attachmentManagers.keys.filter { $0.server == connection.server && $0.accountId == connection.accountId })
        if let key = connection.orgKey { keys.insert(key) }
        keys.formUnion(files.attachmentScopes(server: connection.server, account: connection.accountId))
        // Include unopened caches, and keep the connection record until its
        // queue is safe so a failed archive can be retried after a restart.
        do {
            for key in keys { try files.saveDMOutbox(key, store: orgSessions[key]?.store) }
            disconnectedDMCount = files.savedDMCount
        } catch {
            state = .needsSignIn("Disconnect could not finish: unsent direct messages could not be saved. Try Disconnect again.")
            return
        }
        // Disconnect is done only once it is on disk: the token gone, the
        // server record gone. A step that fails is shown;
        // the connection stays so Disconnect can be pressed again, and each
        // step is safe to repeat (review C5-12).
        let steps: [(String, () throws -> Void)] = [
            ("the sign-in could not be removed from the keychain", { try self.pruneTokens(keeping: []) }),
            ("the server record could not be removed", { try self.files.saveConnections([]) }),
        ]
        // The record named an earlier session still: its token goes too.
        if let old = replaced {
            replaced = nil
            try? tokens.delete(account: old.tokenAccount)
        }
        for (what, step) in steps {
            do { try step() } catch {
                state = .needsSignIn("Disconnect could not finish: \(what) (\(error.localizedDescription)). Try Disconnect again.")
                return
            }
        }
        onCloseConversations(nil)
        for key in keys {
            attachmentManagers.removeValue(forKey: key)?.suspend()
            clearB1PrivateState(key)
            dropSession(key)
            files.removeCache(key)
        }
        self.connection = nil
        token = nil
        activateCalls()
        state = .off
        onDisconnected()
    }
}

extension ChatService: TeamRunFacts {
    func factStored(_ key: ChatOrgKey) {
        orgSessions[key]?.outbox?.resetPlaces()
        orgSessions[key]?.outbox?.pump()
    }

    /// The run's organization has a ready connection: its generation is
    /// settled (none pending) and its requests' states are those of this
    /// connection's snapshot and events.
    /// ... and the request's own state is known from it: what is not known is
    /// waited for, never guessed (review C6-5).
    func canChooseFact(for run: ChatRunRecord) -> Bool {
        guard let journal, let approval = try? journal.approval(run.approvalId), let key = approval.key,
              let kept = try? journal.generation(key), kept.generation != nil, kept.pending == nil
        else { return false }
        return isServerKnown(self, key) && requestState(key, run.requestId) != nil
    }

    /// A connection became ready: runs recovered earlier may get their facts.
    func serverKnown() {
        attachmentManagers.values.forEach { $0.reconcile() }
        for actions in runners.values { actions.run() }
        // Publications (D3): settled, and announced again after a new session.
        if let key = currentKey, isServerKnown(self, key) {
            settlePublications(key)
            announceAfterNewSession(key)
        }
        guard let recovery, !recovery.awaitingFact.isEmpty else { return }
        Task { await recovery.check() }
    }
}
