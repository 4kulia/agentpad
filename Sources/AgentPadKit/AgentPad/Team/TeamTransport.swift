import Foundation
import IrohLib

/// How AgentPad reaches a colleague's AgentPad. Everything above this protocol
/// is independent of iroh, so a future server can carry the same messages
/// (TEAM.md 7.1, 10) and tests can run without a network.
protocol TeamTransport: AnyObject, Sendable {
    /// This endpoint's public key, lowercase hex.
    var localId: String { get }
    /// Starts accepting. `handler` answers every incoming request; the
    /// transport authenticates the sender's key, the handler decides what
    /// that key may do.
    func start(handler: @escaping @Sendable (_ peerId: String, _ message: TeamMessage) async -> TeamMessage) async throws
    /// Sends one request and returns the answer with the key that answered.
    func request(_ message: TeamMessage, to address: TeamPeerAddress, timeout: Duration) async throws -> (peerId: String, reply: TeamMessage)
    /// An invitation address: key and home relay, no IP addresses.
    func inviteTicket(timeout: Duration) async throws -> String
    /// The key inside a ticket, so a joiner can show the pairing code first.
    func endpointId(ofTicket ticket: String) throws -> String
    func stop() async
}

/// Resolves with whichever finishes first: `operation`, or the deadline.
/// Unlike a task group it does not wait for the loser — an iroh call that
/// ignores cancellation cannot hold the caller past the deadline.
func teamDeadline<T: Sendable>(
    _ timeout: Duration,
    onTimeout: (@Sendable () -> Void)? = nil,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = TeamOnce()
    return try await withCheckedThrowingContinuation { continuation in
        Task {
            do {
                let value = try await operation()
                if gate.claim() { continuation.resume(returning: value) }
            } catch {
                if gate.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: timeout)
            if gate.claim() {
                onTimeout?()
                continuation.resume(throwing: TeamError.timedOut)
            }
        }
    }
}

final class TeamOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - iroh

final class IrohTeamTransport: TeamTransport, @unchecked Sendable {
    private let endpoint: Endpoint
    let localId: String
    private let alpn = Data(TeamWire.alpn.utf8)
    private let lock = NSLock()
    private var acceptTask: Task<Void, Never>?
    /// Incoming connections and streams served at once; past these limits
    /// new ones are refused rather than queued.
    private static let maxConnections = 32
    private static let maxConcurrentStreams = 16
    static let maxStreamsPerConnection = 4
    private let connectionSlots = TeamSlots(TeamSlots.Count(IrohTeamTransport.maxConnections))
    private let streamSlots = TeamSlots(TeamSlots.Count(IrohTeamTransport.maxConcurrentStreams))
    private let handshakes = TeamHandshakes(perSource: 4)

    private init(endpoint: Endpoint) {
        self.endpoint = endpoint
        self.localId = endpoint.id().description
    }

    /// Binds an endpoint with the stored identity. Uses n0's public relays and
    /// address lookup (TEAM.md 9).
    static func bind(secretKey: Data) async throws -> IrohTeamTransport {
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetN0(), secretKey: secretKey, alpns: [Data(TeamWire.alpn.utf8)]
        ))
        return IrohTeamTransport(endpoint: endpoint)
    }

    func start(handler: @escaping @Sendable (String, TeamMessage) async -> TeamMessage) async throws {
        let task = Task.detached { [endpoint, connectionSlots, streamSlots, handshakes] in
            while !Task.isCancelled, let incoming = await endpoint.acceptNext() {
                // Bounded before any work: past the limit a connection is
                // refused instead of queueing tasks for strangers.
                guard await connectionSlots.tryAcquire() else {
                    try? await incoming.refuse()
                    continue
                }
                Task.detached {
                    defer { Task { await connectionSlots.release() } }
                    await Self.serveConnection(incoming, handshakes: handshakes, streamSlots: streamSlots, handler: handler)
                }
            }
        }
        lock.withLock { acceptTask = task }
    }

    /// One connection: its streams are served side by side, each bounded in
    /// time. A stream that runs out of time closes the whole connection —
    /// in IrohLib 1.1.0 that is the only call that interrupts a read or a
    /// write stuck inside Rust (a stream's own stop waits for the same lock).
    private static func serveConnection(
        _ incoming: Incoming, handshakes: TeamHandshakes, streamSlots: TeamSlots,
        handler: @escaping @Sendable (String, TeamMessage) async -> TeamMessage
    ) async {
        let holder = TeamConnectionHolder()
        // At most a few handshakes per remote address at once. A handshake is
        // not interruptible from Swift (see `teamDeadline`) and QUIC keeps a
        // live one open, so this, not a timer, bounds what one source holds.
        let source: String
        switch try? await incoming.remoteAddr() {
        case .ip(let addr): source = "ip:\(addr.split(separator: ":").dropLast().joined(separator: ":"))"
        case .relay(let url, let id): source = "relay:\(url):\(id)"
        default: source = "unknown"
        }
        guard await handshakes.begin(source) else {
            try? await incoming.refuse()
            return
        }
        let connection: Connection
        do {
            connection = try await incoming.accept().connect()
        } catch {
            await handshakes.end(source)
            return
        }
        await handshakes.end(source)
        holder.set(connection)
        try? connection.setMaxConcurrentBiStreams(count: UInt64(maxStreamsPerConnection))
        let peer = connection.remoteId().description
        while true {
            let stream: BiStream
            do {
                // An idle connection gives its slot back; one with a request
                // in progress (a pairing waiting on the user can take two
                // minutes) is not idle.
                stream = try await teamDeadline(.seconds(30), onTimeout: { if holder.activeStreams == 0 { holder.close() } }) {
                    try await connection.acceptBi()
                }
            } catch TeamError.timedOut where holder.activeStreams > 0 && !holder.isClosed {
                continue
            } catch {
                return
            }
            guard await streamSlots.tryAcquire() else {
                try? await stream.send().reset(errorCode: 2)
                continue
            }
            holder.streamStarted()
            Task.detached {
                defer {
                    holder.streamEnded()
                    Task { await streamSlots.release() }
                }
                await serve(stream, from: peer, connection: holder, handler: handler)
            }
        }
    }

    private static func serve(
        _ stream: BiStream, from peer: String, connection: TeamConnectionHolder,
        handler: @escaping @Sendable (String, TeamMessage) async -> TeamMessage
    ) async {
        do {
            let data = try await teamDeadline(.seconds(15), onTimeout: { connection.close() }) {
                try await stream.recv().readToEnd(sizeLimit: UInt32(TeamWire.maxMessageBytes))
            }
            let reply: TeamMessage
            do {
                let message = try TeamWire.decode(data)
                reply = message.protocolVersion > TeamWire.version
                    ? .error("protocol_too_new")
                    : await handler(peer, message)
            } catch {
                reply = .error("malformed")
            }
            let payload = try TeamWire.encode(reply)
            // A peer that never grants flow control for the answer must not
            // hold this slot either.
            try await teamDeadline(.seconds(15), onTimeout: { connection.close() }) {
                try await stream.send().writeAll(buf: payload)
                try await stream.send().finish()
            }
        } catch {
            connection.close()
        }
    }

    func request(_ message: TeamMessage, to address: TeamPeerAddress, timeout: Duration) async throws -> (peerId: String, reply: TeamMessage) {
        let addr: EndpointAddr
        switch address {
        case .ticket(let ticket):
            do { addr = try EndpointTicket.fromString(str: ticket).endpointAddr() }
            catch { throw TeamError.invalidLink("the address in the link cannot be read") }
        case .endpoint(let id, let relay):
            do { addr = EndpointAddr(id: try EndpointId.fromString(s: id), relayUrl: relay, addresses: []) }
            catch { throw TeamError.unreachable("bad colleague key") }
        }
        let payload = try TeamWire.encode(message)
        let holder = TeamConnectionHolder()
        return try await teamDeadline(timeout, onTimeout: { holder.close() }) { [endpoint, alpn] in
            let connection: Connection
            do { connection = try await endpoint.connect(addr: addr, alpn: alpn) }
            catch { throw TeamError.unreachable(String(describing: error)) }
            holder.set(connection)
            let stream = try await connection.openBi()
            try await stream.send().writeAll(buf: payload)
            try await stream.send().finish()
            let data = try await stream.recv().readToEnd(sizeLimit: UInt32(TeamWire.maxMessageBytes))
            let reply = try TeamWire.decode(data)
            let peer = connection.remoteId().description
            try? connection.close(errorCode: 0, reason: Data("done".utf8))
            return (peer, reply)
        }
    }

    func inviteTicket(timeout: Duration) async throws -> String {
        // Wait for a home relay by polling — `online()` cannot be bounded
        // (its future ignores cancellation in IrohLib 1.1.0).
        let deadline = ContinuousClock.now + timeout
        var relay = endpoint.addr().relayUrl()
        while relay == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            relay = endpoint.addr().relayUrl()
        }
        guard let relay else { throw TeamError.unreachable("no relay reachable; check the network") }
        let addr = EndpointAddr(id: endpoint.id(), relayUrl: relay, addresses: [])
        return try EndpointTicket.fromAddr(addr: addr).description
    }

    func endpointId(ofTicket ticket: String) throws -> String {
        do { return try EndpointTicket.fromString(str: ticket).endpointAddr().id().description }
        catch { throw TeamError.invalidLink("the address in the link cannot be read") }
    }

    func stop() async {
        let task: Task<Void, Never>? = lock.withLock {
            let current = acceptTask
            acceptTask = nil
            return current
        }
        task?.cancel()
        _ = try? await teamDeadline(.seconds(3)) { [endpoint] in try await endpoint.close() }
    }
}

/// Lets a deadline close the connection a request is stuck on, and knows
/// whether any request on it is still in progress.
final class TeamConnectionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: Connection?
    private var closed = false
    private var active = 0
    var activeStreams: Int { lock.withLock { active } }
    var isClosed: Bool { lock.withLock { closed } }
    func streamStarted() { lock.withLock { active += 1 } }
    func streamEnded() { lock.withLock { active -= 1 } }
    func set(_ connection: Connection) {
        lock.lock(); defer { lock.unlock() }
        if closed { try? connection.close(errorCode: 1, reason: Data("timeout".utf8)) } else { self.connection = connection }
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        try? connection?.close(errorCode: 1, reason: Data("timeout".utf8))
    }
}

/// A counting semaphore for async code.
actor TeamSlots {
    struct Count { let value: Int; init(_ value: Int) { self.value = value } }
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ count: Count) { free = count.value }
    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func tryAcquire() -> Bool {
        guard free > 0 else { return false }
        free -= 1
        return true
    }
    func release() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}

/// Handshakes in progress per remote source.
actor TeamHandshakes {
    private let perSource: Int
    private var counts: [String: Int] = [:]
    init(perSource: Int) { self.perSource = perSource }
    func begin(_ source: String) -> Bool {
        let n = counts[source, default: 0]
        guard n < perSource else { return false }
        counts[source] = n + 1
        return true
    }
    func end(_ source: String) {
        let n = counts[source, default: 1] - 1
        counts[source] = n > 0 ? n : nil
    }
}
