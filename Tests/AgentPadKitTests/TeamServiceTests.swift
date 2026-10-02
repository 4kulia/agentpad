import Foundation
import XCTest
@testable import AgentPadKit

/// In-memory network: transports find each other by id; a ticket is
/// "ticket-<id>". Lets pairing run end to end without iroh.
final class FakeTeamNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable (String, TeamMessage) async -> TeamMessage] = [:]
    func register(_ id: String, _ handler: @escaping @Sendable (String, TeamMessage) async -> TeamMessage) {
        lock.withLock { handlers[id] = handler }
    }
    func unregister(_ id: String) { lock.withLock { _ = handlers.removeValue(forKey: id) } }
    func handler(_ id: String) -> (@Sendable (String, TeamMessage) async -> TeamMessage)? { lock.withLock { handlers[id] } }
}

final class FakeTeamTransport: TeamTransport, @unchecked Sendable {
    let localId: String
    let network: FakeTeamNetwork
    init(id: String, network: FakeTeamNetwork) { localId = id; self.network = network }

    func start(handler: @escaping @Sendable (String, TeamMessage) async -> TeamMessage) async throws {
        network.register(localId, handler)
    }
    func request(_ message: TeamMessage, to address: TeamPeerAddress, timeout: Duration) async throws -> (peerId: String, reply: TeamMessage) {
        let target: String
        switch address {
        case .ticket(let ticket): target = try endpointId(ofTicket: ticket)
        case .endpoint(let id, _): target = id
        }
        guard let handler = network.handler(target) else { throw TeamError.unreachable("offline") }
        // Round-trip through the wire format, as the real transport does.
        let reply = await handler(localId, try TeamWire.decode(TeamWire.encode(message)))
        return (target, try TeamWire.decode(TeamWire.encode(reply)))
    }
    func inviteTicket(timeout: Duration) async throws -> String { "ticket\(localId)" }
    func endpointId(ofTicket ticket: String) throws -> String {
        guard ticket.hasPrefix("ticket") else { throw TeamError.invalidLink("bad ticket") }
        return String(ticket.dropFirst("ticket".count))
    }
    func stop() async { network.unregister(localId) }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@MainActor
final class TeamServiceTests: XCTestCase {
    private var root: URL!
    private let network = FakeTeamNetwork()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("team-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func service(_ name: String, id: String) -> TeamService {
        let network = self.network
        return TeamService(storage: TeamStorage(directory: root.appendingPathComponent(name))) { _ in
            FakeTeamTransport(id: id, network: network)
        }
    }

    private func pair(_ inviter: TeamService, _ joiner: TeamService, approve: Bool = true) async throws -> TeamContact {
        inviter.approvePairing = { _ in approve }
        let url = try await inviter.createInvite()
        let link = try XCTUnwrap(try TeamInviteLink.parse(url))
        return try await joiner.join(try joiner.prepareJoin(link))
    }

    func testEnablingCreatesAPrivateIdentityAndStarts() async throws {
        let a = service("a", id: "aaaa")
        await a.enable(displayName: "Andrey")
        XCTAssertEqual(a.status, .on(localId: "aaaa"))
        let key = root.appendingPathComponent("a/identity.key").path
        let attributes = try FileManager.default.attributesOfItem(atPath: key)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("a").path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testOffByDefault() async {
        let a = service("a", id: "aaaa")
        await a.load()
        XCTAssertEqual(a.status, .off)
    }

    func testPairingAddsEachOtherWithMatchingCodes() async throws {
        let a = service("a", id: "aaaa"), b = service("b", id: "bbbb")
        await a.enable(displayName: "Andrey"); await b.enable(displayName: "Masha")
        var shown: TeamService.PendingPairing?
        a.approvePairing = { shown = $0; return true }
        let url = try await a.createInvite()
        let link = try XCTUnwrap(try TeamInviteLink.parse(url))
        let attempt = try b.prepareJoin(link)
        var joinerCode: String?
        let contact = try await b.join(attempt) { joinerCode = $0 }
        XCTAssertEqual(contact.id, "aaaa")
        XCTAssertEqual(contact.name, "Andrey")
        XCTAssertEqual(a.contacts.map(\.id), ["bbbb"])
        XCTAssertEqual(a.contacts.first?.name, "Masha")
        XCTAssertNotNil(joinerCode)
        XCTAssertEqual(shown?.code, joinerCode, "both screens show the same code")
        XCTAssertEqual(link.inviterName, "Andrey")
    }

    /// The app answers from the right panel: no answer from `approvePairing`,
    /// the request waits in `pendingPairings` until `decide`.
    func testRequestWaitsForADecisionFromThePanel() async throws {
        let a = service("a", id: "aaaa"), b = service("b", id: "bbbb")
        await a.enable(displayName: "A"); await b.enable(displayName: "B")
        a.approvePairing = { _ in nil }
        var changes = 0
        a.onPendingChange = { changes += 1 }
        let url = try await a.createInvite()
        let link = try XCTUnwrap(try TeamInviteLink.parse(url))
        let attempt = try b.prepareJoin(link)
        async let joined = b.join(attempt)
        while a.pendingPairings.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(a.pendingPairings.first?.name, "B")
        a.decide("bbbb", approve: true)
        _ = try await joined
        XCTAssertTrue(a.pendingPairings.isEmpty)
        XCTAssertEqual(a.contacts.map(\.id), ["bbbb"])
        XCTAssertEqual(changes, 2, "appeared and went away")
    }

    /// Review case: disabling while the endpoint is still binding must not
    /// leave a running endpoint behind.
    func testDisableDuringStartLeavesNothingRunning() async throws {
        let network = self.network
        let a = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("a"))) { _ in
            try await Task.sleep(for: .milliseconds(200))
            return FakeTeamTransport(id: "aaaa", network: network)
        }
        async let started: Void = a.enable(displayName: "A")
        try await Task.sleep(for: .milliseconds(50))
        try await a.disable()
        await started
        XCTAssertEqual(a.status, .off)
        XCTAssertNil(network.handler("aaaa"), "the endpoint started late was stopped")
    }

    func testEnablingTwiceStartsOneEndpoint() async {
        let counter = Counter()
        let network = self.network
        let a = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("a"))) { _ in
            counter.increment()
            try await Task.sleep(for: .milliseconds(100))
            return FakeTeamTransport(id: "aaaa", network: network)
        }
        async let first: Void = a.enable(displayName: "A")
        async let second: Void = a.enable(displayName: "A")
        _ = await (first, second)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(a.status, .on(localId: "aaaa"))
    }

    /// Review case: the invitation list changes while a request waits —
    /// a used one is pruned (indices shift) and a new one is added. The
    /// approval must spend the request's own invitation, not whatever now
    /// sits at its old index.
    func testApprovalUsesTheRequestsOwnInvitation() async throws {
        let a = service("a", id: "aaaa"), b = service("b", id: "bbbb")
        let c = service("c", id: "cccc"), d = service("d", id: "dddd")
        for (s, n) in [(a, "A"), (b, "B"), (c, "C"), (d, "D")] { await s.enable(displayName: n) }
        a.approvePairing = { _ in true }
        let usedURL = try await a.createInvite()           // index 0, used by C below
        a.approvePairing = { _ in nil }
        let waitingURL = try await a.createInvite()        // index 1, B's request waits on it
        a.approvePairing = { _ in true }
        _ = try await c.join(try c.prepareJoin(try XCTUnwrap(try TeamInviteLink.parse(usedURL))))
        a.approvePairing = { _ in nil }
        let bAttempt = try b.prepareJoin(try XCTUnwrap(try TeamInviteLink.parse(waitingURL)))
        async let bJoined = b.join(bAttempt)
        while a.pendingPairings.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        // Prunes the used invitation (B's moves to index 0) and appends a new one at index 1.
        let freshURL = try await a.createInvite()
        a.decide("bbbb", approve: true)
        _ = try await bJoined
        a.approvePairing = { _ in true }
        // The fresh invitation must still be unused.
        _ = try await d.join(try d.prepareJoin(try XCTUnwrap(try TeamInviteLink.parse(freshURL))))
        XCTAssertEqual(Set(a.contacts.map(\.id)), ["bbbb", "cccc", "dddd"])
        // And B's own invitation is spent.
        do {
            _ = try await d.join(try d.prepareJoin(try XCTUnwrap(try TeamInviteLink.parse(waitingURL))))
            XCTFail("B's invitation is used up")
        } catch let error as TeamError {
            XCTAssertEqual(error, .refused("invite_invalid"))
        }
    }

    /// Review case: an answer meant for an earlier request by the same Mac
    /// (a late timer, a stale row) must not answer a later one.
    func testDecisionsAreBoundToTheirRequest() async throws {
        let a = service("a", id: "aaaa"), b = service("b", id: "bbbb")
        await a.enable(displayName: "A"); await b.enable(displayName: "B")
        a.approvePairing = { _ in nil }
        let firstURL = try await a.createInvite()
        let first = try b.prepareJoin(try XCTUnwrap(try TeamInviteLink.parse(firstURL)))
        async let firstJoin = b.join(first)
        while a.pendingPairings.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let oldAttempt = try XCTUnwrap(a.pendingPairings.first?.attempt)
        a.decide(attempt: oldAttempt, approve: false)
        do { _ = try await firstJoin; XCTFail("declined") } catch {}
        // Same Mac asks again.
        let secondURL = try await a.createInvite()
        let second = try b.prepareJoin(try XCTUnwrap(try TeamInviteLink.parse(secondURL)))
        async let secondJoin = b.join(second)
        while a.pendingPairings.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        a.decide(attempt: oldAttempt, approve: true)
        XCTAssertEqual(a.pendingPairings.count, 1, "the old answer reaches nothing")
        XCTAssertTrue(a.contacts.isEmpty)
        a.decide("bbbb", approve: true)
        _ = try await secondJoin
        XCTAssertEqual(a.contacts.map(\.id), ["bbbb"])
    }

    /// The reveal must match the commitment made before the inviter's nonce
    /// was known; otherwise the code could be steered.
    func testRevealWithoutMatchingCommitmentIsRefused() async throws {
        let a = service("a", id: "aaaa")
        await a.enable(displayName: "A")
        var asked = false
        a.approvePairing = { _ in asked = true; return true }
        let url = try await a.createInvite()
        let link = try XCTUnwrap(try TeamInviteLink.parse(url))
        let nonce = try TeamInviteLink.randomToken()
        // No commitment at all.
        let bare = await a.handle(TeamMessage(type: .pairRequest, name: "X", secret: link.secret, nonce: nonce), from: "xxxx")
        XCTAssertEqual(bare.type, .pairDenied)
        // Committed to one nonce, revealed another.
        let commit = await a.handle(TeamMessage(type: .pairCommit, name: "X", secret: link.secret,
                                                commitment: TeamPairingCode.commitment(to: nonce)), from: "xxxx")
        XCTAssertEqual(commit.type, .pairNonce)
        let other = try TeamInviteLink.randomToken()
        let swapped = await a.handle(TeamMessage(type: .pairRequest, name: "X", secret: link.secret, nonce: other), from: "xxxx")
        XCTAssertEqual(swapped.type, .pairDenied)
        XCTAssertFalse(asked, "nothing reached the screen")
        XCTAssertTrue(a.contacts.isEmpty)
    }

    /// Review case: a relay must not draw fresh inviter nonces until the
    /// codes match — a commitment stands, and an invitation allows few.
    func testCommitAttemptsAreLimited() async throws {
        let a = service("a", id: "aaaa")
        await a.enable(displayName: "A")
        let url = try await a.createInvite()
        let link = try XCTUnwrap(try TeamInviteLink.parse(url))
        func commit(from peer: String) async throws -> TeamMessage {
            await a.handle(TeamMessage(type: .pairCommit, name: "X", secret: link.secret,
                                       commitment: TeamPairingCode.commitment(to: try TeamInviteLink.randomToken())), from: peer)
        }
        let first = try await commit(from: "p1")
        XCTAssertEqual(first.type, .pairNonce)
        let again = try await commit(from: "p1")
        XCTAssertEqual(again.code, "busy", "a standing commitment is not replaced")
        let second = try await commit(from: "p2")
        let third = try await commit(from: "p3")
        XCTAssertEqual(second.type, .pairNonce)
        XCTAssertEqual(third.type, .pairNonce)
        let fourth = try await commit(from: "p4")
        XCTAssertEqual(fourth.code, "invite_invalid", "the invitation is spent after a few tries")
    }

    /// on → off → on while the first start is still binding ends up on.
    func testReenablingDuringAStartEndsUpOn() async throws {
        let network = self.network
        let a = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("a"))) { _ in
            try await Task.sleep(for: .milliseconds(150))
            return FakeTeamTransport(id: "aaaa", network: network)
        }
        async let first: Void = a.enable(displayName: "A")
        try await Task.sleep(for: .milliseconds(30))
        try await a.disable()
        await a.enable(displayName: "A")
        await first
        XCTAssertEqual(a.status, .on(localId: "aaaa"))
        XCTAssertNotNil(network.handler("aaaa"))
    }

    func testOwnInvitationCannotBeUsed() async throws {
        let a = service("a", id: "aaaa")
        await a.enable(displayName: "A")
        let url = try await a.createInvite()
        let link = try XCTUnwrap(try TeamInviteLink.parse(url))
        XCTAssertThrowsError(try a.prepareJoin(link))
        do {
            _ = try await a.join(try a.prepareJoin(link))
            XCTFail("joining yourself must fail")
        } catch {}
        XCTAssertTrue(a.contacts.isEmpty)
    }

    func testInvitationWorksOnce() async throws {
        let a = service("a", id: "aaaa"), b = service("b", id: "bbbb"), c = service("c", id: "cccc")
        await a.enable(displayName: "A"); await b.enable(displayName: "B"); await c.enable(displayName: "C")
        a.approvePairing = { _ in true }
        let inviteURL = try await a.createInvite()
        let link = try XCTUnwrap(try TeamInviteLink.parse(inviteURL))
        _ = try await b.join(try b.prepareJoin(link))
        do {
            _ = try await c.join(try c.prepareJoin(link))
            XCTFail("a used invitation must be refused")
        } catch let error as TeamError {
            XCTAssertEqual(error, .refused("invite_invalid"))
        }
        XCTAssertEqual(a.contacts.map(\.id), ["bbbb"])
    }

    func testWrongSecretIsRefusedWithoutAskingTheUser() async throws {
        let a = service("a", id: "aaaa"), b = service("b", id: "bbbb")
        await a.enable(displayName: "A"); await b.enable(displayName: "B")
        var asked = false
        a.approvePairing = { _ in asked = true; return true }
        _ = try await a.createInvite()
        let forged = TeamInviteLink(ticket: "ticketaaaa", secret: try TeamInviteLink.newSecret(), inviterName: "A")
        do {
            _ = try await b.join(try b.prepareJoin(forged))
            XCTFail("forged secret must be refused")
        } catch let error as TeamError {
            XCTAssertEqual(error, .refused("invite_invalid"))
        }
        XCTAssertFalse(asked, "no dialog for a stranger")
        XCTAssertTrue(a.contacts.isEmpty)
    }

    func testDeclinedRequestAddsNobody() async throws {
        let a = service("a", id: "aaaa"), b = service("b", id: "bbbb")
        await a.enable(displayName: "A"); await b.enable(displayName: "B")
        do {
            _ = try await pair(a, b, approve: false)
            XCTFail("declined request must fail")
        } catch let error as TeamError {
            XCTAssertEqual(error, .refused("denied"))
        }
        XCTAssertTrue(a.contacts.isEmpty)
        XCTAssertTrue(b.contacts.isEmpty)
    }

    func testOnlyColleaguesMaySayHello() async throws {
        let a = service("a", id: "aaaa"), b = service("b", id: "bbbb"), stranger = service("s", id: "ssss")
        await a.enable(displayName: "A"); await b.enable(displayName: "B"); await stranger.enable(displayName: "S")
        _ = try await pair(a, b)
        let fromStranger = await a.handle(TeamMessage(type: .hello, name: "S"), from: "ssss")
        XCTAssertEqual(fromStranger, .error("not_paired"))
        let fromColleague = await a.handle(TeamMessage(type: .hello, name: "B"), from: "bbbb")
        XCTAssertEqual(fromColleague.type, .helloOK)
        try a.remove("bbbb")
        let afterRemoval = await a.handle(TeamMessage(type: .hello, name: "B"), from: "bbbb")
        XCTAssertEqual(afterRemoval, .error("not_paired"), "removal stops accepting at once")
    }

    func testPresenceMarksAnsweringColleaguesOnline() async throws {
        let a = service("a", id: "aaaa"), b = service("b", id: "bbbb")
        await a.enable(displayName: "A"); await b.enable(displayName: "B")
        _ = try await pair(a, b)
        let i = try XCTUnwrap(b.contacts.firstIndex { $0.id == "aaaa" })
        XCTAssertTrue(b.contacts[i].isOnline())
        try await a.disable()
        // Offline now: the next round gets no answer, lastSeen stays old.
        let before = b.contacts[i].lastSeen
        await b.pingContacts()
        XCTAssertEqual(b.contacts[i].lastSeen, before)
        XCTAssertFalse(b.contacts[i].isOnline(now: Date().addingTimeInterval(TeamContact.onlineWindow + 1)))
    }

    func testStateSurvivesRestart() async throws {
        let a = service("a", id: "aaaa"), b = service("b", id: "bbbb")
        await a.enable(displayName: "A"); await b.enable(displayName: "B")
        _ = try await pair(a, b)
        try await a.disable()
        let again = service("a", id: "aaaa")
        await again.load()
        XCTAssertEqual(again.status, .off, "left off stays off")
        XCTAssertEqual(again.contacts.map(\.id), ["bbbb"])
        await again.enable(displayName: "A")
        XCTAssertEqual(again.status, .on(localId: "aaaa"))
    }

    func testDamagedIdentityStopsTeamWorkInsteadOfReplacingIt() async throws {
        let dir = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = dir.appendingPathComponent("identity.key")
        FileManager.default.createFile(atPath: key.path, contents: Data(repeating: 1, count: 10), attributes: [.posixPermissions: 0o600])
        let a = service("a", id: "aaaa")
        await a.enable(displayName: "A")
        guard case .failed = a.status else { return XCTFail("expected failure, got \(a.status)") }
        XCTAssertEqual(FileManager.default.contents(atPath: key.path)?.count, 10, "the old key is kept")
    }

    func testOutstandingRequestAnswersBusy() async throws {
        let a = service("a", id: "aaaa"), b = service("b", id: "bbbb"), c = service("c", id: "cccc")
        await a.enable(displayName: "A"); await b.enable(displayName: "B"); await c.enable(displayName: "C")
        let firstURL = try await a.createInvite()
        let secondURL = try await a.createInvite()
        let first = try XCTUnwrap(try TeamInviteLink.parse(firstURL))
        let second = try XCTUnwrap(try TeamInviteLink.parse(secondURL))
        a.approvePairing = { _ in try? await Task.sleep(for: .milliseconds(300)); return true }
        let firstAttempt = try b.prepareJoin(first)
        async let joined = b.join(firstAttempt)
        try await Task.sleep(for: .milliseconds(50))
        do {
            _ = try await c.join(try c.prepareJoin(second))
            XCTFail("a second request during an open dialog must be refused")
        } catch let error as TeamError {
            XCTAssertEqual(error, .refused("busy"))
        }
        _ = try await joined
        XCTAssertEqual(a.contacts.map(\.id), ["bbbb"])
    }
}

final class TeamInviteLinkTests: XCTestCase {
    func testRoundTrip() throws {
        let link = TeamInviteLink(ticket: "endpointabc123", secret: try TeamInviteLink.newSecret(), inviterName: "Андрей")
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(url.scheme, "agentpad")
        XCTAssertEqual(try TeamInviteLink.parse(url), link)
    }

    func testOtherLinksAreNotTeamLinks() throws {
        XCTAssertNil(try TeamInviteLink.parse(URL(string: "agentpad://resume?agent=codex&id=x")!))
        XCTAssertNil(try TeamInviteLink.parse(URL(string: "https://team/join?t=a&s=b")!))
    }

    func testMalformedTeamLinksAreRejectedVisibly() {
        let secret = try! TeamInviteLink.newSecret()
        for raw in [
            "agentpad://team/join?s=\(secret)",
            "agentpad://team/join?t=abc&s=short",
            "agentpad://team/join?t=a%20b&s=\(secret)",
            "agentpad://team/leave?t=abc&s=\(secret)",
        ] {
            XCTAssertThrowsError(try TeamInviteLink.parse(URL(string: raw)!), raw)
        }
    }

    func testNamesFromAnotherMachineAreOneShortLine() {
        XCTAssertEqual(TeamInviteLink.sanitizedName("  Masha\n\u{7}Evil  "), "MashaEvil")
        XCTAssertEqual(TeamInviteLink.sanitizedName("Masha\u{2028}Allow\u{202E}x"), "MashaAllowx")
        XCTAssertEqual(TeamInviteLink.sanitizedName(String(repeating: "x", count: 200)).count, 64)
    }

    func testPairingCodeIsSymmetricAndSixDigits() {
        let ab = TeamPairingCode.code("aaaa", "bbbb", secret: "s", inviterNonce: "i", joinerNonce: "j")
        XCTAssertEqual(ab, TeamPairingCode.code("BBBB", "aaaa", secret: "s", inviterNonce: "i", joinerNonce: "j"))
        XCTAssertNotEqual(ab, TeamPairingCode.code("aaaa", "cccc", secret: "s", inviterNonce: "i", joinerNonce: "j"))
        XCTAssertNotEqual(ab, TeamPairingCode.code("aaaa", "bbbb", secret: "s", inviterNonce: "other", joinerNonce: "j"))
        XCTAssertNotEqual(ab, TeamPairingCode.code("aaaa", "bbbb", secret: "s", inviterNonce: "i", joinerNonce: "other"))
        XCTAssertEqual(ab.filter(\.isNumber).count, 6)
    }

    func testWireDecodingIsStrict() throws {
        let good = try TeamWire.encode(TeamMessage(type: .hello, name: "A"))
        XCTAssertEqual(try TeamWire.decode(good).type, .hello)
        XCTAssertThrowsError(try TeamWire.decode(good.dropLast()), "no newline")
        XCTAssertThrowsError(try TeamWire.decode(good + good), "two lines")
        XCTAssertThrowsError(try TeamWire.decode(Data(repeating: 0x20, count: TeamWire.maxMessageBytes + 1)))
    }
}

/// Two real iroh endpoints on this Mac pairing through n0's relays. Needs the
/// network, so it runs only with AGENTPAD_LIVE_IROH=1.
@MainActor
final class TeamLiveIrohTests: XCTestCase {
    func testPairAndSeeEachOtherOverIroh() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTPAD_LIVE_IROH"] == "1", "set AGENTPAD_LIVE_IROH=1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("a")))
        let b = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("b")))
        await a.enable(displayName: "Live A"); await b.enable(displayName: "Live B")
        guard a.isOn, b.isOn else { return XCTFail("start failed: \(a.status) / \(b.status)") }
        a.approvePairing = { _ in true }
        let url = try await a.createInvite()
        XCTAssertFalse(url.absoluteString.contains("192.168"), "no IP addresses in the link")
        let link = try XCTUnwrap(try TeamInviteLink.parse(url))
        let contact = try await b.join(try b.prepareJoin(link))
        XCTAssertEqual(contact.id, a.localId)
        XCTAssertEqual(a.contacts.first?.id, b.localId)
        await a.pingContacts()
        XCTAssertTrue(try XCTUnwrap(a.contacts.first).isOnline())
        try try await a.disable(); try await b.disable()
    }
}
