import Foundation
import IrohLib

/// Team work, stage 1: turning it on, inviting a colleague, pairing, and
/// knowing which colleagues are online (docs/agentpad/TEAM.md 6.1, 7.1–7.3).
///
/// Off until the user turns it on: no endpoint, no network traffic (P-1).
@MainActor
@Observable
final class TeamService {
    static let shared = TeamService(storage: .standard)

    enum Status: Equatable {
        case off
        case starting
        case on(localId: String)
        case failed(String)
    }

    /// An incoming join request waiting for this user's decision.
    struct PendingPairing: Equatable, Identifiable {
        /// One per request, so a late timer from an earlier request by the
        /// same Mac can never answer this one.
        let attempt: UUID
        let peerId: String
        let name: String
        let code: String
        var id: UUID { attempt }
    }

    /// A join this Mac is about to send or is waiting on.
    struct JoinAttempt: Equatable, Sendable {
        let link: TeamInviteLink
        let inviterId: String
        /// Committed to before the inviter's nonce is known (TeamPairingCode).
        let nonce: String
        /// Known once the inviter answered the commitment.
        var code: String?
    }

    /// The inviter's half of a pairing: what a joiner committed to, and the
    /// nonce sent back. Kept only briefly, keyed by the joiner's key.
    private struct Commitment {
        let secretHash: String
        let commitment: String
        let inviterNonce: String
        let at: Date
    }

    /// How long an invitation stays valid (P-2).
    static let inviteLifetime: TimeInterval = 24 * 60 * 60
    /// How long the inviter's decision is awaited before declining.
    static let approvalTimeout: Duration = .seconds(120)
    /// A presence round; answering within two rounds counts as online.
    static let presenceInterval: Duration = .seconds(60)

    private(set) var status: Status = .off
    private(set) var config = TeamConfig()
    private(set) var contacts: [TeamContact] = []
    /// Join requests waiting for this user's decision (P-4).
    private(set) var pendingPairings: [PendingPairing] = []
    /// This Mac's own join in flight, with the code to compare (P-4).
    private(set) var outgoingJoin: JoinAttempt?

    var isOn: Bool { if case .on = status { true } else { false } }
    var localId: String? { if case .on(let id) = status { id } else { nil } }

    /// Called when a join request arrives. Returns the user's answer, or nil
    /// when the answer comes later through `decide` (the right panel).
    var approvePairing: @MainActor (PendingPairing) async -> Bool? = { _ in nil }
    /// Fires when `pendingPairings` changes, for the Dock badge.
    var onPendingChange: @MainActor () -> Void = {}

    /// Published agents and calls (stage 2).
    let calls: TeamCalls
    private let storage: TeamStorage
    private let makeTransport: @Sendable (Data) async throws -> TeamTransport
    private var transport: TeamTransport?
    private var invites: [TeamInviteRecord] = []
    private var presenceTask: Task<Void, Never>?
    private var decisions: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var commitments: [String: Commitment] = [:]
    /// Commitments made per invitation, ever. Each is one guess at matching
    /// codes for someone relaying between two people, so they are few.
    private var commitAttempts: [String: Int] = [:]
    /// How long a commitment waits for its reveal, and how many may wait.
    static let commitmentLifetime: TimeInterval = 60
    static let maxCommitments = 8
    static let maxCommitsPerInvite = 3
    /// Bumped by every enable/disable, so a start that finishes after the
    /// user changed their mind shuts down what it started.
    private var generation = 0
    private var starting: Task<Void, Never>?

    init(
        storage: TeamStorage,
        runner: TeamAgentRunner = ClaudeCodeRunner(),
        makeTransport: @escaping @Sendable (Data) async throws -> TeamTransport = { try await IrohTeamTransport.bind(secretKey: $0) }
    ) {
        self.storage = storage
        self.makeTransport = makeTransport
        self.calls = TeamCalls(storage: storage, runner: runner)
        calls.service = self
    }

    // MARK: Lifecycle

    /// Reads saved state and starts the endpoint if team work was left on.
    func load() async {
        do {
            config = try storage.load(TeamConfig.self, from: storage.configURL, default: TeamConfig())
            contacts = try storage.load([TeamContact].self, from: storage.contactsURL, default: [])
            invites = try storage.load([TeamInviteRecord].self, from: storage.invitesURL, default: [])
            try calls.load()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        if config.enabled { await startEndpoint() }
    }

    func enable(displayName: String) async {
        let name = TeamInviteLink.sanitizedName(displayName)
        config.displayName = name.isEmpty ? TeamInviteLink.sanitizedName(Host.current().localizedName ?? "AgentPad") : name
        config.enabled = true
        do { try storage.save(config, to: storage.configURL) } catch {
            status = .failed(error.localizedDescription)
            return
        }
        await startEndpoint()
    }

    /// Stops the endpoint at once. Throws only when the choice could not be
    /// saved — team work is off now, but would come back after a restart.
    func disable() async throws {
        generation += 1
        let token = generation
        config.enabled = false
        await stopEndpoint()
        // Turned on again while stopping: that start owns the status now.
        if token == generation { status = .off }
        try storage.save(config, to: storage.configURL)
    }

    func setDisplayName(_ raw: String) throws {
        let name = TeamInviteLink.sanitizedName(raw)
        guard !name.isEmpty else { return }
        config.displayName = name
        try storage.save(config, to: storage.configURL)
    }

    private func startEndpoint() async {
        // A start already running may be one the user has since cancelled
        // (on → off → on): wait for it, then start again if still wanted.
        while let running = starting {
            await running.value
            // Whoever sees it finish clears it, so no caller spins on a
            // finished task.
            if starting == running { starting = nil }
        }
        guard transport == nil, config.enabled else { return }
        generation += 1
        let token = generation
        let task = Task { await self.bindAndStart(token) }
        starting = task
        await task.value
        if starting == task { starting = nil }
    }

    private func bindAndStart(_ token: Int) async {
        status = .starting
        let made: TeamTransport
        do {
            let key = try storage.loadOrCreateIdentity { SecretKey.generate().toBytes() }
            made = try await makeTransport(key)
            try await made.start { [weak self] peer, message in
                guard let self else { return .error("shutting_down") }
                return await self.handle(message, from: peer)
            }
        } catch {
            if token == generation { status = .failed(error.localizedDescription) }
            return
        }
        // Turned off (or restarted) while binding: drop what was started.
        guard token == generation, config.enabled else {
            await made.stop()
            return
        }
        transport = made
        status = .on(localId: made.localId)
        startPresence()
    }

    private func stopEndpoint() async {
        presenceTask?.cancel()
        presenceTask = nil
        for (_, decision) in decisions { decision.resume(returning: false) }
        decisions = [:]
        commitments = [:]
        calls.stopAll()
        if !pendingPairings.isEmpty {
            pendingPairings = []
            onPendingChange()
        }
        let current = transport
        transport = nil
        await current?.stop()
    }

    // MARK: Inviting

    /// A new one-time invitation (P-2). Only the secret's hash is stored.
    func createInvite() async throws -> URL {
        guard let transport else { throw TeamError.notEnabled }
        let ticket = try await transport.inviteTicket(timeout: .seconds(10))
        let secret = try TeamInviteLink.newSecret()
        let now = Date()
        invites.removeAll { $0.expiresAt < now || $0.usedBy != nil }
        invites.append(TeamInviteRecord(
            secretHash: TeamInviteRecord.hash(secret), createdAt: now, expiresAt: now.addingTimeInterval(Self.inviteLifetime)
        ))
        try storage.save(invites, to: storage.invitesURL)
        let link = TeamInviteLink(ticket: ticket, secret: secret, inviterName: config.displayName)
        guard let url = link.url else { throw TeamError.invalidLink("cannot build the link") }
        return url
    }

    // MARK: Joining

    /// Checks the link and picks this side's nonce (P-3).
    func prepareJoin(_ link: TeamInviteLink) throws -> JoinAttempt {
        guard let transport else { throw TeamError.notEnabled }
        let inviter = try transport.endpointId(ofTicket: link.ticket)
        guard inviter != transport.localId else { throw TeamError.invalidLink("this is your own invitation") }
        return JoinAttempt(link: link, inviterId: inviter, nonce: try TeamInviteLink.randomToken(), code: nil)
    }

    /// Pairs in two exchanges: commit to this side's nonce and receive the
    /// inviter's, then reveal and wait for the inviter's approval. `onCode`
    /// gets the code to compare as soon as it is known — before the inviter
    /// decides. While this runs, `outgoingJoin` carries the code too (the CLI
    /// shows it in `team status`).
    @discardableResult
    func join(_ attempt: JoinAttempt, onCode: @MainActor (String) -> Void = { _ in }) async throws -> TeamContact {
        guard let transport else { throw TeamError.notEnabled }
        guard outgoingJoin == nil else { throw TeamError.refused("join_in_progress") }
        var attempt = attempt
        outgoingJoin = attempt
        defer { outgoingJoin = nil }
        let address = TeamPeerAddress.ticket(attempt.link.ticket)

        let commit = TeamMessage(
            type: .pairCommit, name: config.displayName, secret: attempt.link.secret,
            commitment: TeamPairingCode.commitment(to: attempt.nonce), appVersion: AgentPadApp.displayVersion
        )
        let (firstPeer, nonceReply) = try await transport.request(commit, to: address, timeout: .seconds(30))
        guard firstPeer == attempt.inviterId else { throw TeamError.protocolViolation("answered by another key") }
        switch nonceReply.type {
        case .pairNonce: break
        case .pairDenied, .error: throw TeamError.refused(nonceReply.code ?? "denied")
        default: throw TeamError.protocolViolation("unexpected \(nonceReply.type.rawValue)")
        }
        guard let inviterNonce = nonceReply.nonce, TeamInviteLink.isValidSecret(inviterNonce) else {
            throw TeamError.protocolViolation("missing nonce")
        }
        let code = TeamPairingCode.code(
            transport.localId, attempt.inviterId, secret: attempt.link.secret,
            inviterNonce: inviterNonce, joinerNonce: attempt.nonce
        )
        attempt.code = code
        outgoingJoin = attempt
        onCode(code)

        let reveal = TeamMessage(
            type: .pairRequest, name: config.displayName, secret: attempt.link.secret, nonce: attempt.nonce,
            appVersion: AgentPadApp.displayVersion
        )
        // Longer than the inviter's approval window.
        let (peer, reply) = try await transport.request(reveal, to: address, timeout: .seconds(150))
        guard peer == attempt.inviterId else { throw TeamError.protocolViolation("answered by another key") }
        switch reply.type {
        case .pairOK:
            let name = TeamInviteLink.sanitizedName(reply.name ?? "")
            return try addContact(id: peer, name: name.isEmpty ? attempt.link.inviterName : name)
        case .pairDenied, .error:
            throw TeamError.refused(reply.code ?? "denied")
        default:
            throw TeamError.protocolViolation("unexpected \(reply.type.rawValue)")
        }
    }

    // MARK: Colleagues

    /// Stops accepting the colleague at once; throws if that could not be
    /// saved, since they would be accepted again after a restart.
    func remove(_ contactId: String) throws {
        contacts.removeAll { $0.id == contactId }
        calls.peerRemoved(contactId)
        try storage.save(contacts, to: storage.contactsURL)
    }

    func rename(_ contactId: String, alias: String?) throws {
        guard let i = contacts.firstIndex(where: { $0.id == contactId }) else { return }
        let clean = alias.map(TeamInviteLink.sanitizedName)
        contacts[i].alias = clean?.isEmpty == false ? clean : nil
        try storage.save(contacts, to: storage.contactsURL)
    }

    /// The user's answer to a pending join request, by peer.
    func decide(_ peerId: String, approve: Bool) {
        guard let pending = pendingPairings.first(where: { $0.peerId == peerId }) else { return }
        decide(attempt: pending.attempt, approve: approve)
    }

    func decide(attempt: UUID, approve: Bool) {
        decisions.removeValue(forKey: attempt)?.resume(returning: approve)
    }

    @discardableResult
    private func addContact(id: String, name: String) throws -> TeamContact {
        let now = Date()
        let contact: TeamContact
        if let i = contacts.firstIndex(where: { $0.id == id }) {
            contacts[i].name = name
            contacts[i].lastSeen = now
            contact = contacts[i]
        } else {
            contact = TeamContact(id: id, name: name, alias: nil, relayURL: nil, addedAt: now, lastSeen: now)
            contacts.append(contact)
        }
        try storage.save(contacts, to: storage.contactsURL)
        return contact
    }

    /// One request to a paired colleague; the answer must come from their key.
    func send(_ message: TeamMessage, to contactId: String, timeout: Duration) async throws -> TeamMessage {
        guard let transport else { throw TeamError.notEnabled }
        guard let contact = contacts.first(where: { $0.id == contactId }) else { throw TeamError.refused("not_paired") }
        let address = TeamPeerAddress.endpoint(id: contact.id, relayURL: contact.relayURL)
        let (peer, reply) = try await transport.request(message, to: address, timeout: timeout)
        guard peer == contact.id else { throw TeamError.protocolViolation("answered by another key") }
        markSeen(peer, name: nil)
        return reply
    }

    // MARK: Presence

    private func startPresence() {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pingContacts()
                try? await Task.sleep(for: Self.presenceInterval)
            }
        }
    }

    /// Says hello to every colleague; whoever answers is online (P-6).
    func pingContacts() async {
        guard let transport else { return }
        let hello = TeamMessage(type: .hello, name: config.displayName, appVersion: AgentPadApp.displayVersion)
        await withTaskGroup(of: (String, TeamMessage?).self) { group in
            for contact in contacts {
                let address = TeamPeerAddress.endpoint(id: contact.id, relayURL: contact.relayURL)
                group.addTask {
                    guard let (peer, reply) = try? await transport.request(hello, to: address, timeout: .seconds(20)),
                          peer == contact.id
                    else { return (contact.id, nil) }
                    return (contact.id, reply)
                }
            }
            for await (id, reply) in group {
                guard let reply, reply.type == .helloOK else { continue }
                markSeen(id, name: reply.name)
            }
        }
    }

    private func markSeen(_ id: String, name: String?) {
        guard let i = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[i].lastSeen = Date()
        if let name = name.map(TeamInviteLink.sanitizedName), !name.isEmpty { contacts[i].name = name }
        try? storage.save(contacts, to: storage.contactsURL)
    }

    // MARK: Incoming

    /// Answers one request. The transport has authenticated `peer`'s key;
    /// this decides what that key may do: a colleague may say hello, anyone
    /// holding a live invitation may ask to join, nothing else is accepted.
    func handle(_ message: TeamMessage, from peer: String) async -> TeamMessage {
        switch message.type {
        case .hello:
            guard contacts.contains(where: { $0.id == peer }) else { return .error("not_paired") }
            markSeen(peer, name: message.name)
            return TeamMessage(type: .helloOK, name: config.displayName, appVersion: AgentPadApp.displayVersion)
        case .pairCommit:
            return handlePairCommit(message, from: peer)
        case .pairRequest:
            return await handlePairRequest(message, from: peer)
        case .catalogGet, .callStart, .callAttach, .callCancel:
            // A request accepted just before team work was turned off is
            // answered, not queued.
            guard isOn, config.enabled else { return .error("shutting_down") }
            // Only colleagues see the catalog or call agents (P-5).
            guard let contact = contacts.first(where: { $0.id == peer }) else { return .error("not_paired") }
            markSeen(peer, name: nil)
            return await calls.handle(message, from: contact)
        default:
            return .error("unexpected")
        }
    }

    private func liveInvite(_ hash: String, now: Date = Date()) -> Int? {
        invites.firstIndex { $0.secretHash == hash && $0.usedBy == nil && $0.expiresAt > now }
    }

    /// First half of pairing: remember the joiner's commitment and answer
    /// with this side's nonce. Nothing reaches the screen yet.
    private func handlePairCommit(_ message: TeamMessage, from peer: String) -> TeamMessage {
        let now = Date()
        commitments = commitments.filter { now.timeIntervalSince($0.value.at) < Self.commitmentLifetime }
        guard let secret = message.secret, TeamInviteLink.isValidSecret(secret),
              let commitment = message.commitment, commitment.count == 64,
              commitment.allSatisfy({ $0.isHexDigit })
        else { return TeamMessage(type: .pairDenied, code: "invite_invalid") }
        let hash = TeamInviteRecord.hash(secret)
        guard let index = liveInvite(hash) else { return TeamMessage(type: .pairDenied, code: "invite_invalid") }
        // A commitment stands until revealed or expired: re-committing would
        // let a relay draw fresh inviter nonces until the codes match.
        guard commitments[peer] == nil else { return TeamMessage(type: .pairDenied, code: "busy") }
        guard pendingPairings.isEmpty, commitments.count < Self.maxCommitments else {
            return TeamMessage(type: .pairDenied, code: "busy")
        }
        // Few tries per invitation, then it is spent: 3 tries leave a relay
        // a 3-in-a-million chance of matching codes.
        let tries = commitAttempts[hash, default: 0] + 1
        commitAttempts[hash] = tries
        if tries > Self.maxCommitsPerInvite {
            invites[index].usedBy = "spent:too-many-attempts"
            try? storage.save(invites, to: storage.invitesURL)
            return TeamMessage(type: .pairDenied, code: "invite_invalid")
        }
        guard let nonce = try? TeamInviteLink.randomToken() else { return .error("storage") }
        commitments[peer] = Commitment(secretHash: hash, commitment: commitment, inviterNonce: nonce, at: now)
        return TeamMessage(type: .pairNonce, nonce: nonce)
    }

    /// Second half: the joiner reveals its nonce; it must match what it
    /// committed to before seeing ours. Only then does the request reach the
    /// screen, with the code both sides now share.
    private func handlePairRequest(_ message: TeamMessage, from peer: String) async -> TeamMessage {
        guard let secret = message.secret, TeamInviteLink.isValidSecret(secret),
              let nonce = message.nonce, TeamInviteLink.isValidSecret(nonce),
              let localId
        else { return TeamMessage(type: .pairDenied, code: "invite_invalid") }
        let hash = TeamInviteRecord.hash(secret)
        guard let commitment = commitments.removeValue(forKey: peer),
              Date().timeIntervalSince(commitment.at) < Self.commitmentLifetime,
              commitment.secretHash == hash,
              commitment.commitment == TeamPairingCode.commitment(to: nonce)
        else { return TeamMessage(type: .pairDenied, code: "invite_invalid") }
        guard liveInvite(hash) != nil else { return TeamMessage(type: .pairDenied, code: "invite_invalid") }
        guard pendingPairings.isEmpty else { return TeamMessage(type: .pairDenied, code: "busy") }
        let name = TeamInviteLink.sanitizedName(message.name ?? "")
        let pending = PendingPairing(
            attempt: UUID(),
            peerId: peer,
            name: name.isEmpty ? "A colleague" : name,
            code: TeamPairingCode.code(localId, peer, secret: secret, inviterNonce: commitment.inviterNonce, joinerNonce: nonce)
        )
        pendingPairings.append(pending)
        onPendingChange()
        let approved = await decision(for: pending)
        pendingPairings.removeAll { $0.attempt == pending.attempt }
        onPendingChange()
        guard approved else { return TeamMessage(type: .pairDenied, code: "denied") }
        // Found again by its hash: the list may have changed while waiting.
        guard let index = liveInvite(hash) else { return TeamMessage(type: .pairDenied, code: "invite_invalid") }
        invites[index].usedBy = peer
        do {
            try storage.save(invites, to: storage.invitesURL)
            try addContact(id: peer, name: pending.name)
        } catch {
            return .error("storage")
        }
        return TeamMessage(type: .pairOK, name: config.displayName, appVersion: AgentPadApp.displayVersion)
    }

    /// Waits for the user — through `approvePairing` or `decide` — and
    /// declines when neither answers within `approvalTimeout`.
    private func decision(for pending: PendingPairing) async -> Bool {
        await withCheckedContinuation { continuation in
            decisions[pending.attempt] = continuation
            Task { [weak self] in
                guard let self, let answer = await self.approvePairing(pending) else { return }
                self.decide(attempt: pending.attempt, approve: answer)
            }
            Task { [weak self] in
                try? await Task.sleep(for: Self.approvalTimeout)
                self?.decide(attempt: pending.attempt, approve: false)
            }
        }
    }
}
