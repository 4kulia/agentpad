import Foundation
import GRDB

/// The live connection of one signed-in session: one server, one account,
/// one token (C3, C8), and the single owner of what that connection means
/// (review C2, "one owner"). It is the socket's lifecycle: a connection's
/// `hello` comes here and is handled in one sequence — the account's
/// `/v1/me`, the organization it brings, the organization's snapshot and
/// server generation — before anything is subscribed, and the send queue is
/// allowed for exactly that connection. Every step carries the connection's
/// context and stops when it is no longer current. Signing in again or to
/// another server makes a new feed and stops this one (review C-1). After
/// every `await` it checks it is still the service's feed (review C-16).
@MainActor
final class ChatFeed: ChatSocketLifecycle {
    let connection: ChatConnection
    let token: String
    let socket: ChatSocket
    let account: ChatAccountFeed
    private let api: ChatAPI
    private weak var service: ChatService?
    private var starting: Task<Void, Never>?
    private(set) var stopped = false

    init(service: ChatService, connection: ChatConnection, token: String) {
        self.service = service
        self.connection = connection
        self.token = token
        let api = service.makeAPI(connection.server)
        self.api = api
        socket = ChatSocket(server: connection.server, token: token, makeTransport: service.makeSocketTransport)
        socket.checkServer = { [weak service] in
            let info = try await api.serverInfo()
            guard service?.connection?.sessionId == connection.sessionId else { return }
            service?.serverCapabilities[connection.server] = Set(info.capabilities)
        }
        account = ChatAccountFeed(accountId: connection.accountId, sessionId: connection.sessionId, socket: socket)
        socket.lifecycle = self
        // The one place that says the data is in step: runs waiting for their
        // facts may get them now (review C7-10).
        socket.onInStep = { [weak self] in
            guard let self, self.isCurrent else { return }
            self.service?.serverKnown()
        }
        socket.onEphemeral = { [weak self] org, type, body in
            guard let self, self.isCurrent else { return }
            self.service?.receiveChannelActivity(org: org, type: type, body: body)
            self.service?.onEphemeral(org, type, body)
        }
        socket.onUnauthorized = { [weak self] reason in
            guard let self, self.isCurrent else { return }
            self.service?.sessionEnded(reason)
        }
        if let delay = service.retryDelay { account.retryDelay = delay }
        account.onMembershipChanged = { [weak service] org in
            guard let service, let key = service.connection?.orgKey, key.orgId == org else { return }
            // `/v1/me` is read next; its answer takes the snapshot or leaves.
            service.orgSessions[key]?.sync?.rightsInDoubt(snapshot: false)
        }
        account.readMe = { [weak self] in
            guard let self, self.isCurrent else { return nil }
            return try? await api.me(token: token)
        }
        account.onMe = { [weak self] me in
            guard let self, self.isCurrent else { return }
            await self.membership(me)
        }
        account.onNotice = { [weak self] text in
            guard let self, self.isCurrent else { return }
            self.service?.onNotice(text)
        }
    }

    private var isCurrent: Bool { !stopped && service?.feed === self }

    private var key: ChatOrgKey? { connection.orgKey }
    private var session: ChatOrgSession? { key.flatMap { service?.orgSessions[$0] } }

    /// `/v1/me` (the account stream from its head, the organization if the
    /// account is in it), then the socket. Without a network the next
    /// `hello` reads what is still owed.
    func start() {
        starting = Task { [weak self] in
            guard let self else { return }
            await self.account.refresh()
            guard self.isCurrent, !Task.isCancelled else { return }
            self.socket.start()
        }
    }

    func waitUntilStarted() async { await starting?.value }

    /// Everything stops: the socket, the streams, the organization's sync and
    /// its queue's sending; nothing of this feed reaches the network again.
    func stop() {
        service?.channelActivity.removeAll()
        stopped = true
        starting?.cancel()
        account.stop()
        if let session {
            session.sync?.stop()
            session.sync = nil
            session.outbox?.hold()
        }
        socket.stop()
    }

    // MARK: ChatSocketLifecycle

    func socketHello(_ context: ChatConnectionContext) async -> Bool {
        guard isCurrent else { return false }
        // Before anything waits: a new server generation begins at once.
        if let sync = session?.sync, !sync.beginGeneration(context) { return false }
        // The account first: it may bring (or end) the organization.
        await account.prepare(context)
        guard isCurrent, socket.isCurrent(context) else { return false }
        if let sync = session?.sync {
            // An organization the account just brought begins here.
            guard sync.beginGeneration(context), await sync.prepare(context), isCurrent, socket.isCurrent(context) else { return false }
        }
        return true
    }

    func socketConnected(_ context: ChatConnectionContext) {
        guard isCurrent, socket.isCurrent(context) else { return }
        // This connection's generation is confirmed: the queue may send on
        // it — once its organization's synchronizer prepared it; one made
        // later allows the queue itself (review C15-2).
        guard session?.sync != nil else { return }
        session?.outbox?.allow(connection: context.id, generation: context.generation)
    }

    func socketDisconnected() {
        service?.channelActivity.removeAll()
        session?.outbox?.hold()
    }

    // MARK: Membership

    /// The organization follows the account's membership (review C-15):
    /// gone — its cache goes and the connection stays; back — a new session
    /// of it starts; still there — a snapshot (the event said something changed).
    private func membership(_ me: ChatMe) async {
        guard let service, let key else { return }
        let member = me.orgs.contains { $0.orgId == key.orgId }
        let existing = service.orgSessions[key]
        if !member {
            if existing != nil || service.state == .signedIn { service.membershipLost(key) }
            return
        }
        if let sync = existing?.sync {
            sync.requestSnapshot()
            return
        }
        // A member (again): the organization starts; its queue waits for a
        // connection whose hello it has seen.
        service.membershipRegained(key)
        let fresh = service.session(for: key)
        guard let store = fresh.store else { return }
        fresh.startSending(api: api, token: token, sessionId: connection.sessionId, journal: service.journal) { [weak service] in
            service?.sessionEnded("The server closed this session. Sign in again.")
        }
        // A command answered for good, either way: its owner follows, by type
        // (`ChatService.commandAnswered`, the one place).
        fresh.outbox?.onSent = { [weak service] record, answer in
            service?.commandAnswered(key, record, .taken(answer))
        }
        fresh.outbox?.onPermanentFailure = { [weak service] record, code in
            service?.commandAnswered(key, record, .refused(code))
        }
        fresh.outbox?.onReady = { [weak service, weak fresh] in
            service?.serverKnown()
            // Sending is possible again: what waited for it goes on (review D8d-p2-4).
            fresh?.actions?.run()
        }
        // A command of the organization's window refused as forbidden or not
        // found: a sign the rights or the membership changed, taken when
        // the queue learns it — whether or not a window shows it (C6g p2-4).
        fresh.outbox?.onRefused = { [weak service, weak fresh] record, code in
            // Messages too: a refused post or change says the same of the rights (review F3-1).
            guard ChatOrgView.commandTypes.contains(record.type) || ChatMessages.eventTypes.contains(record.type),
                  ["forbidden", "not_found"].contains(code) else { return }
            fresh?.sync?.rightsInDoubt()
            if code == "not_found" { service?.accountFeed?.readMeAgain() }
        }
        let sync = ChatSync(key: key, store: store, api: api, socket: socket, outbox: fresh.outbox, token: token)
        if let delay = service.retryDelay { sync.retryDelay = delay }
        sync.generationState = service.journal
        sync.runningRequests = { [weak service] in try service?.journal?.runningRequests(key) ?? [] }
        sync.localFacts = { [weak service] ids in service?.localFacts(key, ids) }
        sync.onCallsChanged = { [weak fresh, weak service] in
            fresh?.actions?.run()
            // The catalog may have changed: the audiences follow it (review D3b-3).
            service?.settleAudiences(key)
            service?.onCallsChanged(key)
        }
        sync.onInStep = { [weak fresh] in fresh?.actions?.run() }
        sync.onChannelsPaused = { [weak fresh] paused in if fresh?.pausedChannels != paused { fresh?.pausedChannels = paused } }
        sync.setOpenChannels(service.openChannels(key))
        sync.onLiveMessage = { [weak fresh, weak service] channel, id in
            guard let store = fresh?.store, let service else { return }
            ChatNotifications.live(service, key, store: store, channel: channel, messageId: id)
        }
        // What may be seen changed, or a message went: notices are reconciled (review F4-A).
        sync.onMessageGone = { [weak service] _, _ in if let service { ChatNotifications.reconcile(service) } }
        // One point after every transaction that may change what notices stand for (review F4b-5).
        ChatNotifications.follow(service, session: fresh)
        sync.onFollowed = { [weak fresh] channels in if fresh?.followedChannels != channels { fresh?.followedChannels = channels } }
        sync.onSnapshotOwed = { [weak fresh, weak service] owed in
            if fresh?.snapshotOwed != owed { fresh?.snapshotOwed = owed }
            if let service { ChatNotifications.reconcile(service) }
        }
        fresh.snapshotOwed = sync.needsSnapshot
        sync.sessionId = connection.sessionId
        sync.onStorageProblem = { [weak fresh] failed in
            guard let fresh else { return }
            // Each failure, and the end of one, begins a new epoch: a view
            // counts only if read after it — after the write that worked, not
            // only after the failure (review C6j).
            if failed || fresh.doubtNotWritten { fresh.doubtWriteFailures += 1 }
            fresh.doubtNotWritten = failed
        }
        sync.onMembershipInDoubt = { [weak service] in service?.accountFeed?.readMeAgain() }
        sync.voidApprovals = { [weak service] generation in
            guard let journal = service?.journal else { return }
            try TeamApprovals.voidOtherGenerations(current: generation, key: key, journal: journal)
        }
        fresh.sync = sync
        // Posts left "sending" by an earlier run go again with their ids (F3).
        service.resendPosts(key)
        await sync.start()
        // Made while a connection is already up (or during its hello, after
        // the account's turn): it is readied for that connection now, so it
        // does not miss it (review C2-7); what fails now, its snapshot retry
        // finishes (review C16-1).
        if let context = socket.context, isCurrent { _ = await sync.ready(for: context) }
    }
}
