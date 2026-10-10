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
            let hadDMFiles = service?.serverCapabilities[connection.server]?.contains("chat.dm.attachments") == true
            if !hadDMFiles, info.capabilities.contains("chat.dm.attachments"), let key = connection.orgKey {
                service?.orgSessions[key]?.sync?.requestSnapshot()
            }
            service?.serverCapabilities[connection.server] = Set(info.capabilities)
            service?.configureAvatars(info, server: connection.server)
            service?.serverB1Limits[connection.server] = info.limits?.chatB1
            service?.serverAttachmentLimits[connection.server] = info.limits?.attachments
            service?.attachmentManagers.values.forEach { $0.reconcile() }
            if let key = connection.orgKey {
                let sync = service?.orgSessions[key]?.sync
                sync?.b1.configure(Set(info.capabilities), limits: info.limits?.chatB1)
                let hadDM = sync?.dm.enabled == true
                sync?.dm.configure(info.capabilities.contains("chat.dm"))
                if !hadDM && info.capabilities.contains("chat.dm") { sync?.requestSnapshot() }
                service?.orgSessions[key]?.outbox?.pump()
            }
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
        account.onNotice = { [weak self] event in
            guard let self, self.isCurrent, let service = self.service, let key = service.connection?.orgKey else { return }
            service.onNotice(AttentionEvent(source: "account-event", object: String(event.seq), episode: event.type,
                kind: .account, destination: .organization(key.orgId, section: .devices), scope: ChatAttention.scope(key, service)))
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
        service?.clearChannelActivity()
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
        if service?.avatarGenerations[connection.server] != context.generation {
            service?.invalidateAvatars()
            service?.avatarGenerations[connection.server] = context.generation
        }
        // Before anything waits: a new server generation begins at once.
        if let sync = session?.sync, !sync.beginGeneration(context) { return false }
        // The account first: it may bring (or end) the organization.
        await account.prepare(context)
        guard isCurrent, socket.isCurrent(context) else { return false }
        if let sync = session?.sync {
            // An organization the account just brought begins here.
            guard sync.beginGeneration(context) else { return false }
            // This sync has a fixed server/account/org; beginGeneration above
            // cleared any old generation. An unchanged B1 capability set now
            // only refreshes its projections, preserving what is displayed.
            sync.b1.configure(service?.serverCapabilities[connection.server] ?? [], limits: service?.serverB1Limits[connection.server], reconnect: true)
            guard await sync.prepare(context), isCurrent, socket.isCurrent(context) else { return false }
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
        service?.invalidateAttachments()
        session?.sync?.b1.suspend()
        service?.clearChannelActivity()
        session?.outbox?.hold()
    }

    // MARK: Membership

    /// The organization follows the account's membership (review C-15):
    /// gone — its cache goes and the connection stays; back — a new session
    /// of it starts; still there — a snapshot (the event said something changed).
    private func membership(_ me: ChatMe) async {
        guard let service else { return }
        service.reconcileDMScopes(me, connection: connection)
        guard let key else { return }
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
            guard ChatOrgView.commandTypes.contains(record.type) || ChatMessages.eventTypes.contains(record.type) || ChatB1.commands.contains(record.type)
                    || ["message.post_with_attachments", "request.create_in_channel_with_attachments", "attachment.prepare", "attachment.complete", "attachment.cancel"].contains(record.type),
                  ["forbidden", "not_found"].contains(code) else { return }
            fresh?.sync?.rightsInDoubt()
            service?.attachmentManagers[key]?.suspend()
            service?.reconcileAttachmentCalls()
            if code == "not_found" { service?.accountFeed?.readMeAgain() }
        }
        let sync = ChatSync(key: key, store: store, api: api, socket: socket, outbox: fresh.outbox, token: token)
        if let delay = service.retryDelay { sync.retryDelay = delay }
        sync.onAvatarSnapshot = { [weak service] in service?.receiveAvatars($0, key: key) }
        sync.onAvatarEvent = { [weak service] in service?.avatarEvent($0, key: key) }
        sync.onAvatarAccessChanged = { [weak service] in service?.invalidateAvatars() }
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
        sync.dm.setOpen(Set(service.openDMTabs.keys.filter { $0.belongs(to: key) }.map(\.dm)))
        sync.onLiveEvent = { [weak service] event in
            guard let service else { return }
            let admin = ["invitation.create", "invitation.accept", "invitation.revoke"].contains(event.type)
            let mine = event.body["account_id"]?.string == key.accountId && ["member.update", "member.remove", "team.remove_member", "team.leave"].contains(event.type)
            guard admin || mine else { return }
            service.onNotice(AttentionEvent(source: "organization-event", object: event.stream, episode: String(event.seq),
                kind: .account, destination: .organization(key.orgId, section: admin ? .invitations : .members), scope: ChatAttention.scope(key, service)))
        }
        sync.dm.onLiveMessage = { [weak service] dm, id in
            if let service { ChatDMNotices.live(service, key, dm: dm, id: id) }
        }
        sync.dm.onChanged = { [weak service] in
            guard let service else { return }
            service.reconcileDMAttachments(key)
            ChatNotifications.reconcile(service)
        }
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
        sync.dm.sessionId = connection.sessionId
        sync.dm.isCurrent = { [weak service, weak fresh, connection] in
            service?.state == .signedIn && service?.connection == connection && fresh?.doubtNotWritten == false
        }
        sync.dm.configure(service.supports("chat.dm", key: key))
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
        sync.b1.onCapabilities = { [weak service, weak fresh] info in
            let hadDMFiles = service?.serverCapabilities[key.server]?.contains("chat.dm.attachments") == true
            if !hadDMFiles, info.capabilities.contains("chat.dm.attachments") { fresh?.sync?.requestSnapshot() }
            service?.serverCapabilities[key.server] = Set(info.capabilities)
            service?.configureAvatars(info, server: key.server)
            service?.serverB1Limits[key.server] = info.limits?.chatB1
            service?.serverAttachmentLimits[key.server] = info.limits?.attachments
            service?.attachmentManagers.values.forEach { $0.reconcile() }
            let hadDM = fresh?.sync?.dm.enabled == true
            fresh?.sync?.dm.configure(info.capabilities.contains("chat.dm"))
            if !hadDM && info.capabilities.contains("chat.dm") { fresh?.sync?.requestSnapshot() }
            fresh?.outbox?.pump()
        }
        sync.b1.canNotify = { [weak service] channel in
            guard let service else { return false }
            return ChatNotifications.visible(service, key, channel)
        }
        sync.b1.onEligible = { [weak service, weak store] channel, id in
            guard let service, let store else { return }
            ChatNotifications.live(service, key, store: store, channel: channel, messageId: id, eligibleReply: true)
        }
        sync.b1.configure(service.serverCapabilities[key.server] ?? [], limits: service.serverB1Limits[key.server])
        if let outbox = fresh.outbox { service.configureCommandCapabilities(outbox, key: key) }
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

extension ChatService {
    func configureCommandCapabilities(_ outbox: ChatOutbox, key: ChatOrgKey) {
        func attachmentCapability(_ type: String) -> String? {
            switch type {
            case "message.post_with_attachments": "chat.attachments"
            case "request.create_in_channel_with_attachments": "chat.attachments_context"
            default: nil
            }
        }
        outbox.maySendCommand = { [weak self] record in
            if record.type == "dm.message.post_with_attachments" {
                return self?.dmAllowed(key, Self.args(record)["dm_id"]?.string) == true
                    && self?.attachments(key)?.limits(for: .dm(Self.args(record)["dm_id"]?.string ?? "")) != nil
                    && self?.attachments(key)?.postReady(record) == true
            }
            if ChatDMStore.commands.contains(record.type) {
                return self?.supports("chat.dm", key: key) == true
                    && (!record.requiresDMSignature || self?.supports("chat.dm.session_signature", key: key) == true)
            }
            if let capability = attachmentCapability(record.type) {
                return self?.supports(capability, key: key) == true && self?.attachments(key)?.limits != nil
                    && self?.attachments(key)?.postReady(record) == true
            }
            return !ChatB1.commands.contains(record.type) || self?.supports(ChatB1.capability(for: record.type), key: key) == true
        }
        outbox.isSuspended = { [weak self] record in
            if record.type == "dm.message.post_with_attachments" {
                return self?.attachments(key)?.limits(for: .dm(Self.args(record)["dm_id"]?.string ?? "")) == nil
                    || self?.dmAllowed(key, Self.args(record)["dm_id"]?.string) != true
            }
            if ChatDMStore.commands.contains(record.type) {
                return self?.supports("chat.dm", key: key) != true
                    || (record.requiresDMSignature && self?.supports("chat.dm.session_signature", key: key) != true)
            }
            guard let capability = attachmentCapability(record.type) else { return false }
            return self?.supports(capability, key: key) != true || self?.attachments(key)?.limits == nil
        }
        outbox.permanentRejection = { [weak self] record in
            guard ChatAttachments.postCommands.contains(record.type), let store = self?.orgSessions[key]?.store else { return nil }
            return try? store.queue.read { try ChatAttachments.postFailure($0, record) }
        }
    }
}
