import Foundation
import Network
import XCTest
@testable import AgentPadKit

/// A transport the test drives: what the socket sent, and events to push.
@MainActor
final class FakeSocketTransport: ChatSocketTransport {
    var sent: [String] = []
    var request: URLRequest?
    var closedWith: Int?
    private var onEvent: (@MainActor (ChatTransportEvent) -> Void)?

    func open(_ request: URLRequest, onEvent: @escaping @MainActor (ChatTransportEvent) -> Void) {
        self.request = request
        self.onEvent = onEvent
    }
    func send(_ text: String) { sent.append(text) }
    func close(code: Int) { closedWith = code; onEvent = nil }

    func push(_ event: ChatTransportEvent) { onEvent?(event) }
    /// A frame from the server. Like the server, an answer for a stream
    /// carries the `sub` of its last `subscribe` unless the test gives one.
    func frame(_ json: String) {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let kind = object["frame"] as? String, ["subscribed", "unsubscribed", "resync_required"].contains(kind),
              object["sub"] == nil, let stream = object["stream"] as? String
        else { return push(.text(Data(json.utf8))) }
        object["sub"] = lastSub(of: stream)
        push(.text((try? JSONSerialization.data(withJSONObject: object)) ?? Data(json.utf8)))
    }

    /// The `sub` of the last `subscribe` that named `stream`.
    func lastSub(of stream: String) -> Int? {
        for text in sent.reversed() {
            if case .subscribe(let streams, let sub) = try? ChatFrame.decode(Data(text.utf8)), streams[stream] != nil { return sub }
        }
        return nil
    }

    /// The subscription number of each `subscribe` sent.
    var subs: [Int?] {
        sent.compactMap { text in
            if case .subscribe(_, let sub) = try? ChatFrame.decode(Data(text.utf8)) { sub } else { nil }
        }
    }
    var subscribes: [[String: Int]] {
        sent.compactMap { text in
            if case .subscribe(let streams, _) = try? ChatFrame.decode(Data(text.utf8)) { streams } else { nil }
        }
    }
}

/// A sink that keeps cursors in memory.
@MainActor
final class FakeSink: ChatStreamSink, ChatSocketLifecycle {
    var cursors: [String: Int]
    var applied: [String] = []
    var hellos: [String] = []
    var resyncs: [String] = []
    var ready: [String] = []
    var drops: [String] = []
    var resyncTo: [String: Int] = [:]
    /// The next resyncs that fail.
    var failingResyncs = 0
    /// What the transport had sent when `hello` reached this sink.
    var sentAtHello: Int?
    var transport: FakeSocketTransport?
    weak var socket: ChatSocket?

    init(_ cursors: [String: Int]) { self.cursors = cursors }

    /// The next hellos this owner cannot finish.
    var failingHellos = 0
    func socketHello(_ context: ChatConnectionContext) async -> Bool {
        hellos.append(context.generation)
        sentAtHello = transport?.sent.count
        if failingHellos > 0 {
            failingHellos -= 1
            return false
        }
        return true
    }
    func socketConnected(_ context: ChatConnectionContext) {}
    func socketDisconnected() {}
    func cursor(_ stream: String) -> Int { cursors[stream] ?? 0 }
    var caughtUp: [String] = []
    func catchingUp(_ stream: String) { caughtUp.append(stream) }
    /// The next applies that fail to write.
    var failingApplies = 0
    func apply(_ event: ChatEvent) -> Bool {
        if failingApplies > 0 {
            failingApplies -= 1
            return false
        }
        applied.append("\(event.stream)#\(event.seq)")
        cursors[event.stream] = event.seq
        return true
    }
    func resync(_ stream: String) async throws {
        resyncs.append(stream)
        if failingResyncs > 0 {
            failingResyncs -= 1
            throw URLError(.networkConnectionLost)
        }
        cursors[stream] = resyncTo[stream] ?? cursors[stream]
        // The sink follows the stream again itself, as ChatSync does.
        socket?.resubscribe([stream])
    }
    func ready(_ stream: String, head: Int) { ready.append(stream) }
    func dropped(_ stream: String) { drops.append(stream) }
}

@MainActor
final class ChatSocketTests: XCTestCase {
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")
    private var transports: [FakeSocketTransport] = []

    private func socket(_ sink: FakeSink, streams: [String]) -> ChatSocket {
        let socket = ChatSocket(server: server, token: "aps_t") { [unowned self] in
            let t = FakeSocketTransport()
            self.transports.append(t)
            sink.transport = t
            return t
        }
        socket.retryDelay = { _ in 0.05 }
        socket.restartDelay = { 0.05 }
        socket.lifecycle = sink
        sink.socket = socket
        socket.subscribe(streams, sink: sink)
        return socket
    }

    private var transport: FakeSocketTransport { transports.last! }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func event(_ stream: String, _ seq: Int) -> String {
        #"{"frame":"event","stream":"\#(stream)","seq":\#(seq),"id":"\#(UUID())","type":"member.set_name","actor":null,"body":{},"command_id":null,"at":"2026-10-03T18:20:00Z","sig":null,"sig_alg":null,"enc":null}"#
    }

    private let org = "org:o1", team = "team:t1"

    /// Connected and subscribed to `org` (cursor 5) and `team` (cursor 2).
    private func connected(_ sink: FakeSink, heartbeat: Int = 25) async throws -> ChatSocket {
        let socket = socket(sink, streams: [org, team])
        socket.start()
        try await waitUntil { !self.transports.isEmpty }
        transport.push(.opened)
        transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":\#(heartbeat),"version":"0.1.0"}"#)
        try await waitUntil { socket.state == .connected && !self.transport.subscribes.isEmpty }
        return socket
    }

    func testRequestAndFirstSubscribe() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        XCTAssertEqual(transport.request?.url?.absoluteString, "wss://chat.example.com:443/v1/ws")
        XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "Authorization"), "Bearer aps_t")
        XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "agentpad.chat.v1")
        XCTAssertEqual(transport.subscribes, [[org: 5, team: 2]])
        XCTAssertEqual(sink.hellos, ["g1"])
        XCTAssertEqual(sink.sentAtHello, 0, "the generation is handled before anything is subscribed")
        XCTAssertEqual(socket.syncing, [org, team])
        transport.frame(#"{"frame":"subscribed","stream":"org:o1","head":5}"#)
        try await waitUntil { socket.syncing == [self.team] }
        transport.frame(#"{"frame":"ping"}"#)
        try await waitUntil { self.transport.sent.contains(#"{"frame":"pong"}"#) }
    }

    func testGapResubscribesOnlyThatStreamOnce() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        defer { socket.stop() }
        transport.frame(event(org, 6))
        transport.frame(event(org, 8))
        transport.frame(event(org, 9))
        transport.frame(event(team, 3))
        try await waitUntil { sink.applied.count == 2 }
        XCTAssertEqual(sink.applied, ["\(org)#6", "\(team)#3"])
        XCTAssertEqual(transport.subscribes, [[org: 5, team: 2], [org: 6]])
        transport.frame(event(org, 7))
        transport.frame(event(org, 8))
        transport.frame(#"{"frame":"subscribed","stream":"org:o1","head":8}"#)
        transport.frame(event(org, 10))
        try await waitUntil { sink.applied.count == 4 }
        XCTAssertEqual(transport.subscribes.count, 3, "a later gap asks again")
    }

    func testRepeatsAreNotAppliedTwice() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        defer { socket.stop() }
        for seq in [5, 6, 6, 4, 7, 7] { transport.frame(event(org, seq)) }
        try await waitUntil { sink.applied.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sink.applied, ["\(org)#6", "\(org)#7"])
    }

    func testUnsubscribedStreamLeavesTheSocketAndOthers() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        transport.frame(#"{"frame":"unsubscribed","stream":"team:t1"}"#)
        transport.frame(event(team, 3))
        transport.frame(event(org, 6))
        try await waitUntil { sink.applied == ["\(self.org)#6"] }
        XCTAssertEqual(sink.drops, [team])
        XCTAssertEqual(sink.resyncs, [], "no snapshot for it")
        XCTAssertNil(transport.closedWith)
        XCTAssertEqual(socket.state, .connected)
        XCTAssertEqual(socket.streams, [org])
    }

    /// C6g p2-5: refused for the socket's limit of streams is no refusal of
    /// the right: nothing is dropped, no snapshot, and the stream is
    /// subscribed again after a pause.
    func testAStreamRefusedForTheLimitIsSubscribedAgain() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        defer { socket.stop() }
        socket.retryDelay = { _ in 0.05 }
        let sent = transport.subscribes.count
        transport.frame(#"{"frame":"unsubscribed","stream":"team:t1","reason":"too_many_streams"}"#)
        try await waitUntil { self.transport.subscribes.count > sent }
        XCTAssertEqual(transport.subscribes.last?[team], 2, "from its cursor again")
        XCTAssertEqual(sink.drops, [])
        XCTAssertEqual(sink.resyncs, [])
        XCTAssertEqual(Set(socket.streams), [org, team])
    }

    /// C6h p2-4: the retry belongs to its refusal: once the stream is
    /// subscribed again meanwhile, no more subscribe goes.
    func testALimitRetryEndsWithItsRefusal() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        defer { socket.stop() }
        socket.retryDelay = { _ in 0.15 }
        let sent = transport.subscribes.count
        transport.frame(#"{"frame":"unsubscribed","stream":"team:t1","reason":"too_many_streams"}"#)
        transport.frame(#"{"frame":"subscribed","stream":"team:t1","head":2}"#)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(transport.subscribes.count, sent, "nothing more after the stream was subscribed")
    }

    func testClosedSessionIsNotRetried() async throws {
        let sink = FakeSink([org: 5])
        var reasons: [String] = []
        let socket = try await connected(sink)
        socket.onUnauthorized = { reasons.append($0) }
        transport.push(.closed(code: 4401))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transports.count, 1)
        guard case .needsSignIn = socket.state else { return XCTFail("\(socket.state)") }
        XCTAssertEqual(reasons.count, 1)
        socket.reconnectNow()
        XCTAssertEqual(transports.count, 1, "not even on a network change")

        // A refused upgrade (401) is the same.
        let other = FakeSink([org: 0])
        let second = self.socket(other, streams: [org])
        second.start()
        try await waitUntil { self.transports.count == 2 }
        transport.push(.failed("bad response", httpStatus: 401))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transports.count, 2)
        guard case .needsSignIn = second.state else { return XCTFail("\(second.state)") }
    }

    func testOtherClosesAreRetried() async throws {
        let sink = FakeSink([org: 5])
        let socket = try await connected(sink)
        for code in [1012, 1013, 1009, 1006] {
            let count = transports.count
            transport.push(.closed(code: code))
            try await waitUntil { self.transports.count == count + 1 }
            transport.push(.opened)
            transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
            try await waitUntil { socket.state == .connected }
            XCTAssertEqual(transport.subscribes.last?[org], 5, "from the cursor again")
        }
    }

    func testResyncRequiredTakesOneSnapshotAndNoLoop() async throws {
        let sink = FakeSink([org: 5, team: 2])
        sink.resyncTo = [org: 40]
        let socket = try await connected(sink)
        transport.frame(#"{"frame":"resync_required","stream":"org:o1"}"#)
        try await waitUntil { self.transport.subscribes.count == 2 }
        XCTAssertEqual(sink.resyncs, [org])
        XCTAssertEqual(transport.subscribes.last, [org: 40])
        transport.frame(#"{"frame":"resync_required","stream":"org:o1"}"#)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sink.resyncs, [org], "exactly one snapshot")
        XCTAssertEqual(socket.stuck, [org])
        XCTAssertEqual(transport.subscribes.count, 2)
    }

    func testSilenceLongerThanTwoHeartbeatsReconnects() async throws {
        let sink = FakeSink([org: 5])
        let socket = try await connected(sink, heartbeat: 1)
        XCTAssertEqual(transports.count, 1)
        try await waitUntil { self.transports.count == 2 }
        socket.stop()
        XCTAssertEqual(transports.first?.closedWith, 1000)
    }

    func testUnsuitableServerIsNotRetried() async throws {
        let sink = FakeSink([org: 5])
        let socket = socket(sink, streams: [org])
        socket.checkServer = { throw ChatAPIError.unsuitableServer(missing: ["events.ws"]) }
        socket.start()
        try await waitUntil { if case .failed = socket.state { true } else { false } }
        XCTAssertTrue(transports.isEmpty)
        guard case .failed(let text) = socket.state else { return }
        XCTAssertTrue(text.contains("server version does not fit"))
    }

    // MARK: Review fixes (review-client-c.md 13, 17, 21)

    /// 13: a snapshot that failed is not counted as done.
    func testFailedResyncIsTriedAgain() async throws {
        let sink = FakeSink([org: 5, team: 2])
        sink.failingResyncs = 1
        sink.resyncTo = [org: 40]
        let socket = try await connected(sink)
        defer { socket.stop() }
        transport.frame(#"{"frame":"resync_required","stream":"org:o1"}"#)
        try await waitUntil { self.transports.count == 2 }
        transport.push(.opened)
        transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
        try await waitUntil { socket.state == .connected }
        transport.frame(#"{"frame":"resync_required","stream":"org:o1"}"#)
        try await waitUntil { sink.resyncs.count == 2 }
        XCTAssertEqual(socket.stuck, [], "the second request is a new attempt, not a loop")
        try await waitUntil { self.transport.subscribes.last == [self.org: 40] }
    }

    /// C2-9: one subscribe per resync (the sink's), and a stuck stream stays stuck.
    func testResyncHasOneOwnerAndStuckStaysStuck() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        defer { socket.stop() }
        let before = transport.subscribes.count
        transport.frame(#"{"frame":"resync_required","stream":"org:o1"}"#)
        try await waitUntil { sink.resyncs.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.subscribes.count, before + 1, "the sink's subscribe only")
        transport.frame(#"{"frame":"resync_required","stream":"org:o1"}"#)
        try await waitUntil { socket.stuck == [self.org] }
        transport.frame(#"{"frame":"resync_required","stream":"org:o1"}"#)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sink.resyncs.count, 1, "stuck: no more snapshots")
        // A new connection does not subscribe it either, until unstuck.
        transport.push(.closed(code: 1006))
        try await waitUntil { self.transports.count == 2 }
        transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
        try await waitUntil { socket.state == .connected }
        XCTAssertNil(transport.subscribes.last?[org])
        socket.unstick(org)
        try await waitUntil { self.transport.subscribes.last?[self.org] != nil }
    }

    /// 17: a check of an earlier attempt that ends late opens nothing.
    func testLateCheckOfAnEarlierAttemptOpensNothing() async throws {
        let sink = FakeSink([org: 5])
        let socket = socket(sink, streams: [org])
        var release: [CheckedContinuation<Void, Never>] = []
        socket.checkServer = { await withCheckedContinuation { release.append($0) } }
        socket.start()
        try await waitUntil { release.count == 1 }
        socket.state == .connecting ? () : XCTFail("\(socket.state)")
        socket.reconnectNow(force: true)
        try await waitUntil { release.count == 2 }
        release[1].resume()
        try await waitUntil { self.transports.count == 1 }
        release[0].resume()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transports.count, 1, "the first attempt was superseded")
        socket.stop()
    }

    /// 17: a hello of an earlier connection subscribes nothing on a newer one.
    func testHelloOfAnEarlierConnectionDoesNotSubscribeTheNewOne() async throws {
        let slow = SlowHelloSink([org: 5])
        let socket = ChatSocket(server: server, token: "aps_t") { [unowned self] in
            let t = FakeSocketTransport()
            self.transports.append(t)
            return t
        }
        socket.retryDelay = { _ in 0.05 }
        socket.lifecycle = slow
        socket.subscribe([org], sink: slow)
        socket.start()
        try await waitUntil { !self.transports.isEmpty }
        let first = transport
        first.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
        try await waitUntil { slow.waiting }
        socket.reconnectNow(force: true)
        try await waitUntil { self.transports.count == 2 }
        slow.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(first.subscribes.isEmpty)
        XCTAssertTrue(transports[1].subscribes.isEmpty, "no hello on it yet")
        XCTAssertNotEqual(socket.state, ChatSocket.State.connected)
        socket.stop()
    }

    /// 21: a network change reconnects a connection that looks alive.
    func testForcedReconnectOnANetworkChange() async throws {
        let sink = FakeSink([org: 5])
        let socket = try await connected(sink)
        socket.reconnectNow()
        XCTAssertEqual(transports.count, 1, "a plain call leaves a fresh connection alone")
        socket.reconnectNow(force: true)
        try await waitUntil { self.transports.count == 2 }
        XCTAssertEqual(transports[0].closedWith, 1000)
        socket.stop()
    }

    // MARK: Third review (review-client-c3.md 5, 17)

    /// C3-5: a hello that could not be finished brings a new connection; a
    /// connection without a hello in time too.
    func testUnfinishedOrMissingHelloReconnects() async throws {
        let sink = FakeSink([org: 5])
        sink.failingHellos = 1
        let socket = socket(sink, streams: [org])
        socket.start()
        try await waitUntil { !self.transports.isEmpty }
        transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
        try await waitUntil { self.transports.count == 2 }
        XCTAssertTrue(transports[0].subscribes.isEmpty)
        // No hello at all within the handshake time.
        socket.handshakeTimeout = .milliseconds(100)
        transport.push(.closed(code: 1006))
        try await waitUntil { self.transports.count == 3 }
        try await waitUntil { self.transports.count == 4 }
        socket.stop()
    }

    /// C3-17: an event that could not be written is not passed: the stream is
    /// followed again from its cursor, and `subscribed` behind the cursor is not ready.
    func testUnwrittenEventIsFollowedAgain() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        defer { socket.stop() }
        sink.failingApplies = 1
        transport.frame(event(org, 6))
        try await waitUntil { self.transport.subscribes.last == [self.org: 5] }
        transport.frame(#"{"frame":"subscribed","stream":"org:o1","head":6}"#)
        try await waitUntil { self.transport.subscribes.filter { $0 == [self.org: 5] }.count == 2 }
        XCTAssertTrue(socket.syncing.contains(org), "not ready: the cursor is behind the head")
        transport.frame(event(org, 6))
        try await waitUntil { sink.applied == ["\(self.org)#6"] }
    }

    /// C4-10: a stream stuck on events it could not write is never ready,
    /// whatever `subscribed` says afterwards.
    func testStreamStuckOnWritesIsNeverReady() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        defer { socket.stop() }
        sink.failingApplies = 3
        for _ in 1...3 {
            transport.frame(event(org, 6))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await waitUntil { socket.stuck.contains(self.org) }
        let readyBefore = sink.ready.filter { $0 == org }.count
        transport.frame(#"{"frame":"subscribed","stream":"org:o1","head":5}"#)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sink.ready.filter { $0 == org }.count, readyBefore, "a stuck stream stays in error")
        XCTAssertTrue(socket.stuck.contains(org))
    }

    /// C7-7, C7-10: a stream that falls behind is out of step until caught
    /// up again; "in step" is said once, when the last stream is caught up.
    func testCatchingUpEndsReadinessAndInStepIsSaidOnce() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        defer { socket.stop() }
        var inStep = 0
        socket.onInStep = { inStep += 1 }
        transport.frame(#"{"frame":"subscribed","stream":"org:o1","head":5}"#)
        try await waitUntil { sink.ready.contains(self.org) }
        XCTAssertEqual(inStep, 0, "the team stream is not caught up yet")
        transport.frame(#"{"frame":"subscribed","stream":"team:t1","head":2}"#)
        try await waitUntil { inStep == 1 }
        // A gap after being in step: out of step at once.
        transport.frame(event(org, 7))
        try await waitUntil { socket.syncing.contains(self.org) }
        XCTAssertEqual(sink.caughtUp, [org])
        transport.frame(#"{"frame":"subscribed","stream":"org:o1","head":5}"#)
        try await waitUntil { inStep == 2 }
    }

    /// C8-7: the last stream waited for goes away — in step; a stuck stream
    /// that goes away leaves nothing behind.
    func testRemovedStreamsAreNotWaitedFor() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        defer { socket.stop() }
        var inStep = 0
        socket.onInStep = { inStep += 1 }
        transport.frame(#"{"frame":"subscribed","stream":"org:o1","head":5}"#)
        try await waitUntil { sink.ready.contains(self.org) }
        XCTAssertEqual(inStep, 0)
        transport.frame(#"{"frame":"unsubscribed","stream":"team:t1"}"#)
        try await waitUntil { inStep == 1 }
        // A stuck stream that goes away.
        sink.failingApplies = 3
        for _ in 1...3 {
            transport.frame(event(org, 6))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await waitUntil { socket.stuck.contains(self.org) }
        transport.frame(#"{"frame":"unsubscribed","stream":"org:o1"}"#)
        try await waitUntil { inStep == 2 }
        XCTAssertTrue(socket.stuck.isEmpty)
    }

    /// C9-4: a `subscribed` of an earlier subscription — its head below where
    /// the last one started — does not say the stream caught up.
    func testEarlierSubscribedConfirmsNothing() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        defer { socket.stop() }
        // A snapshot moved the cursor to 20; the stream is followed again from there.
        sink.cursors[org] = 20
        socket.resubscribe([org])
        XCTAssertTrue(socket.syncing.contains(org))
        let readyBefore = sink.ready.filter { $0 == org }.count
        let earlier = try XCTUnwrap(transport.subs.first ?? nil)
        transport.frame(#"{"frame":"subscribed","stream":"org:o1","head":12,"sub":\#(earlier)}"#)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(socket.syncing.contains(org), "the earlier subscription's answer")
        XCTAssertEqual(sink.ready.filter { $0 == org }.count, readyBefore)
        transport.frame(#"{"frame":"subscribed","stream":"org:o1","head":20}"#)
        try await waitUntil { !socket.syncing.contains(self.org) }
    }

    /// C9-6: a stream this side stops following leaves nothing behind, stuck included.
    func testLocalUnsubscribeForgetsAStuckStream() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        defer { socket.stop() }
        var inStep = 0
        socket.onInStep = { inStep += 1 }
        transport.frame(#"{"frame":"subscribed","stream":"team:t1","head":2}"#)
        sink.failingApplies = 3
        for _ in 1...3 {
            transport.frame(event(org, 6))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await waitUntil { socket.stuck.contains(self.org) }
        XCTAssertEqual(inStep, 0)
        socket.unsubscribe([org])
        XCTAssertTrue(socket.stuck.isEmpty)
        XCTAssertEqual(inStep, 1, "nothing left to wait for")
    }

    /// C10-4: the server echoes the subscription number: an answer of an
    /// earlier subscription — even with a head equal to where the last one
    /// started — confirms nothing; only the last subscription's does.
    func testSubscriptionNumberTellsTheLastAnswer() async throws {
        let sink = FakeSink([org: 5, team: 2])
        let socket = try await connected(sink)
        defer { socket.stop() }
        let first = try XCTUnwrap(transport.subs.last ?? nil)
        sink.cursors[org] = 20
        socket.resubscribe([org])
        let second = try XCTUnwrap(transport.subs.last ?? nil)
        XCTAssertGreaterThan(second, first)
        transport.frame(#"{"frame":"subscribed","stream":"org:o1","head":20,"sub":\#(first)}"#)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(socket.syncing.contains(org), "an earlier subscription's answer, though its head is 20")
        transport.frame(#"{"frame":"unsubscribed","stream":"org:o1","sub":\#(first)}"#)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(sink.drops.isEmpty, "nor does its unsubscribed")
        transport.frame(#"{"frame":"subscribed","stream":"org:o1","head":20,"sub":\#(second)}"#)
        try await waitUntil { !socket.syncing.contains(self.org) }
    }

    /// The real transport against a local WebSocket server: the subprotocol
    /// and token arrive, frames go both ways, and a 300 KiB frame is refused.
    func testRealTransportAgainstALocalServer() async throws {
        let local = try LocalWebSocketServer()
        defer { local.stop() }
        let port = try await local.ready()
        let sink = FakeSink(["org:o1": 0])
        let socket = ChatSocket(server: try ChatServerAddress(parsing: "http://127.0.0.1:\(port)"), token: "aps_local")
        socket.retryDelay = { _ in 30 }
        socket.lifecycle = sink
        socket.subscribe(["org:o1"], sink: sink)
        socket.start()
        try await waitUntil { local.received.contains { $0.contains("subscribe") } }
        XCTAssertEqual(local.headers["authorization"], "Bearer aps_local")
        local.send(event("org:o1", 1))
        try await waitUntil { sink.applied == ["org:o1#1"] }

        let big = #"{"frame":"event","stream":"org:o1","seq":2,"pad":""# + String(repeating: "x", count: 300 * 1024) + #""}"#
        local.send(big)
        try await waitUntil { socket.state != .connected }
        XCTAssertEqual(sink.applied, ["org:o1#1"], "the 300 KiB frame was not applied")
        socket.stop()
    }
}

/// A sink whose `hello` waits until released.
@MainActor
final class SlowHelloSink: ChatStreamSink, ChatSocketLifecycle {
    let cursors: [String: Int]
    private(set) var waiting = false
    private var gate: CheckedContinuation<Void, Never>?
    init(_ cursors: [String: Int]) { self.cursors = cursors }
    func socketHello(_ context: ChatConnectionContext) async -> Bool {
        waiting = true
        await withCheckedContinuation { gate = $0 }
        return true
    }
    func socketConnected(_ context: ChatConnectionContext) {}
    func socketDisconnected() {}
    func release() { gate?.resume(); gate = nil }
    func cursor(_ stream: String) -> Int { cursors[stream] ?? 0 }
    func apply(_ event: ChatEvent) -> Bool { true }
    func resync(_ stream: String) async throws {}
    func ready(_ stream: String, head: Int) {}
    func dropped(_ stream: String) {}
}

/// A one-connection WebSocket server on 127.0.0.1 (Network.framework).
final class LocalWebSocketServer: @unchecked Sendable {
    private var listener: NWListener!
    private let queue = DispatchQueue(label: "local-ws")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var _received: [String] = []
    private var _headers: [String: String] = [:]

    var received: [String] { lock.withLock { _received } }
    var headers: [String: String] { lock.withLock { _headers } }

    init() throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1024 * 1024
        ws.setClientRequestHandler(queue) { [weak self] protocols, headers in
            self?.lock.withLock {
                for (name, value) in headers { self?._headers[name.lowercased()] = value }
            }
            let chosen = protocols.contains("agentpad.chat.v1") ? "agentpad.chat.v1" : nil
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: chosen)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.connection = connection }
            connection.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.send(#"{"frame":"hello","generation":"g","heartbeat_seconds":25,"version":"0.1.0"}"#) }
            }
            connection.start(queue: self.queue)
            self.receive(connection)
        }
    }

    func ready() async throws -> UInt16 {
        listener.start(queue: queue)
        let deadline = ContinuousClock.now + .seconds(5)
        while listener.port == nil || listener.port?.rawValue == 0 {
            guard ContinuousClock.now < deadline else { throw URLError(.cannotConnectToHost) }
            try await Task.sleep(for: .milliseconds(10))
        }
        return listener.port!.rawValue
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data { self.lock.withLock { self._received.append(String(decoding: data, as: UTF8.self)) } }
            self.receive(connection)
        }
    }

    func send(_ text: String) {
        guard let connection = lock.withLock({ connection }) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    func stop() {
        lock.withLock { connection }?.cancel()
        listener.cancel()
    }
}
