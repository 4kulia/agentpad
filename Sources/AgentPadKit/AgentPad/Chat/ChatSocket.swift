import Foundation

// MARK: Transport

enum ChatTransportEvent: Equatable, Sendable {
    case opened
    case text(Data)
    /// The socket closed with a WebSocket close code.
    case closed(code: Int)
    /// It never opened, or broke: `httpStatus` is the upgrade's answer when there was one.
    case failed(String, httpStatus: Int?)
}

/// The WebSocket under `ChatSocket`, so a test or the network experiment
/// (X2) can replace it.
@MainActor
protocol ChatSocketTransport: AnyObject {
    func open(_ request: URLRequest, onEvent: @escaping @MainActor (ChatTransportEvent) -> Void)
    func send(_ text: String)
    func close(code: Int)
}

/// `URLSessionWebSocketTask`: ephemeral, no redirects, messages up to 256 KiB.
@MainActor
final class ChatURLSessionTransport: ChatSocketTransport {
    static let maximumMessageSize = 256 * 1024

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var onEvent: (@MainActor (ChatTransportEvent) -> Void)?
    private let protocolClasses: [AnyClass]?

    init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
    }

    func open(_ request: URLRequest, onEvent: @escaping @MainActor (ChatTransportEvent) -> Void) {
        self.onEvent = onEvent
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        if let protocolClasses { config.protocolClasses = protocolClasses }
        let delegate = Delegate()
        delegate.owner = self
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        self.session = session
        self.task = task
        task.resume()
        receive(task)
    }

    func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    func close(code: Int) {
        onEvent = nil
        task?.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .success(.string(let text)):
                    self.onEvent?(.text(Data(text.utf8)))
                    self.receive(task)
                case .success(.data(let data)):
                    self.onEvent?(.text(data))
                    self.receive(task)
                case .success:
                    self.receive(task)
                case .failure(let error):
                    self.ended(task, error)
                }
            }
        }
    }

    private func ended(_ task: URLSessionWebSocketTask, _ error: Error?) {
        let event: ChatTransportEvent
        if task.closeCode != .invalid {
            event = .closed(code: task.closeCode.rawValue)
        } else {
            event = .failed(error?.localizedDescription ?? "closed", httpStatus: (task.response as? HTTPURLResponse)?.statusCode)
        }
        let report = onEvent
        onEvent = nil
        self.task = nil
        session?.invalidateAndCancel()
        session = nil
        report?(event)
    }

    fileprivate func didOpen() { onEvent?(.opened) }

    private final class Delegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        weak var owner: ChatURLSessionTransport?

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            MainActor.assumeIsolated { owner?.didOpen() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

// MARK: Socket

/// One connection of the socket: its id and the server generation its
/// `hello` named. Everything done for a connection carries it and checks it
/// is still current before changing anything (review C2-5).
struct ChatConnectionContext: Equatable, Sendable {
    let id: Int
    let generation: String
}

/// The single owner of what a connection means beyond its streams — the
/// generation, the send queues, the snapshots (`ChatFeed`). The socket asks
/// it once per connection, before anything is subscribed.
@MainActor
protocol ChatSocketLifecycle: AnyObject {
    /// The connection's `hello`. Done when it returns true; false leaves the
    /// connection without subscriptions (it was superseded or failed).
    func socketHello(_ context: ChatConnectionContext) async -> Bool
    /// The connection is subscribed.
    func socketConnected(_ context: ChatConnectionContext)
    /// The connection is gone.
    func socketDisconnected()
}

/// Whoever owns a set of streams: an organization (`ChatSync`) or the
/// account. The socket keeps no state of an organization.
@MainActor
protocol ChatStreamSink: AnyObject {
    func cursor(_ stream: String) -> Int
    /// Applies an event whose `seq` is the cursor plus one; false when it
    /// could not be written (the stream is then followed again, review C3-17).
    func apply(_ event: ChatEvent) -> Bool
    /// `resync_required`: take the snapshot once; it moves the cursors and
    /// follows the streams again itself (`resubscribe`).
    func resync(_ stream: String) async throws
    /// `subscribed`: caught up.
    func ready(_ stream: String, head: Int)
    /// `unsubscribed`: no longer readable; its data goes.
    func dropped(_ stream: String)
    /// The stream fell behind and is followed again: not in step until `ready` (review C7-7).
    func catchingUp(_ stream: String)
}

extension ChatStreamSink {
    func catchingUp(_ stream: String) {}
}

/// The event feed of one (server, account) (docs/agentpad/CHAT-PLAN.md C3):
/// subscribes the streams its sinks hand it and gives each event to the sink
/// that owns its stream, applying the rule for numbers.
@MainActor
@Observable
final class ChatSocket {
    func checkCapabilitiesAgain() { Task { try? await checkServer() } }

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        /// 4401 or a refused upgrade: not repeated with this token.
        case needsSignIn(String)
        /// The server does not fit, or a stream cannot be synchronized.
        case failed(String)

        /// Associated errors may contain server text; diagnostics never do.
        var logName: String {
            switch self {
            case .disconnected: "disconnected"
            case .connecting: "connecting"
            case .connected: "connected"
            case .needsSignIn: "needsSignIn"
            case .failed: "failed"
            }
        }
    }

    enum ReconnectReason: String {
        case requested, wake, networkPathChanged, journalChanged
        case serverCheckFailed, handshakeTimeout, remoteClose, transportFailure
        case helloRejected, resyncFailed, heartbeatTimeout
    }

    static let subprotocol = "agentpad.chat.v1"

    private(set) var state: State = .disconnected {
        didSet {
            guard state != oldValue else { return }
            trace("state=\(oldValue.logName)->\(state.logName)")
            updateOfflineIndicator()
        }
    }
    /// Presentation only: actions still require the actual connected state.
    private(set) var showsOffline = true
    var offlineDelay: Duration = .seconds(2)
    private var offlineTimer: Task<Void, Never>?
    var log: (String) -> Void = { line in
        try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
    }

    private func trace(_ event: String) { log("[ChatSocket] epoch=\(connection) \(event)") }

    private func updateOfflineIndicator() {
        switch state {
        case .connected:
            offlineTimer?.cancel()
            offlineTimer = nil
            showsOffline = false
        case .disconnected where running, .connecting where running:
            // One deadline spans backoff and every subsequent attempt.
            guard !showsOffline, offlineTimer == nil else { return }
            let delay = offlineDelay
            offlineTimer = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.offlineTimer = nil
                self.showsOffline = true
            }
        default:
            offlineTimer?.cancel()
            offlineTimer = nil
            showsOffline = true
        }
    }
    /// Streams subscribed but not yet caught up: the UI says "syncing".
    private(set) var syncing: Set<String> = []
    /// Every followed stream is caught up and none is stuck: the one place
    /// that says the connection's data is in step (review C7-10).
    var onInStep: @MainActor () -> Void = {}
    /// An ephemeral frame (D4b): a hint, never state.
    var onEphemeral: @MainActor (_ org: String, _ type: String, _ body: ChatJSON) -> Void = { _, _, _ in }

    /// After any change of the streams' states: in step is said from here only.
    private func streamsChanged() {
        if syncing.isEmpty, stuck.isEmpty { onInStep() }
    }

    /// A stream is followed again from its cursor: out of step until its
    /// `subscribed` says it reached the head (review C7-7).
    private func catchUp(_ stream: String, from cursor: Int, sink: ChatStreamSink) {
        catchingUp.insert(stream)
        syncing.insert(stream)
        sink.catchingUp(stream)
        sendSubscribe([stream: cursor])
    }
    /// Streams that could not be synchronized (resync right after a snapshot).
    private(set) var stuck: Set<String> = []
    /// The server generation the current connection's `hello` named.
    private(set) var generation: String?

    let server: ChatServerAddress
    private var token: String
    private let makeTransport: @MainActor () -> ChatSocketTransport
    /// Checks the server before connecting (`/v1/server` with `events.ws`).
    var checkServer: @MainActor () async throws -> Void = {}
    var onUnauthorized: @MainActor (String) -> Void = { _ in }
    /// Delay before reconnect attempt `n` (1, 2, …): 1…60 s, jittered.
    var retryDelay: (Int) -> TimeInterval = { n in max(1, min(60, pow(2, Double(n - 1)) * Double.random(in: 0.5...1.5))) }
    /// After `1012` (server restarting): up to 10 s.
    var restartDelay: () -> TimeInterval = { Double.random(in: 0...10) }
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }

    private var owners: [String: ChatStreamSink] = [:]
    /// The owner of the connection's meaning (`ChatFeed`).
    weak var lifecycle: ChatSocketLifecycle?
    private var transport: ChatSocketTransport?
    private var attempts = 0
    private var heartbeat: Duration = .seconds(25)
    private var lastFrame: ContinuousClock.Instant = .now
    private var watchdog: Task<Void, Never>?
    private var reconnecting: Task<Void, Never>?
    private var connecting: Task<Void, Never>?
    private var helloSeen = false
    /// Streams re-subscribed after a gap: later events are ignored until `subscribed`.
    private var catchingUp: Set<String> = []
    /// Each stream's last subscription number. Every `subscribe` carries a
    /// new `sub` (numbers only grow on a socket); the server returns it in the
    /// `subscribed`, `resync_required` and `unsubscribed` of each stream of the
    /// frame. An answer of an earlier subscription — its frames may still come
    /// after a new one was sent — says nothing of the last (review C9-4, C10-4).
    private var lastSub: [String: Int] = [:]
    private var nextSub = 0

    /// Sends `subscribe` for `cursors` with a new subscription number.
    private func sendSubscribe(_ cursors: [String: Int]) {
        guard !cursors.isEmpty else { return }
        nextSub += 1
        for stream in cursors.keys { lastSub[stream] = nextSub }
        transport?.send(ChatFrame.subscribe(cursors, sub: nextSub).encoded())
    }

    /// A stream's answer belongs to its last subscription: the number it
    /// echoes is that subscription's. An answer without one is not ours.
    private func isCurrentAnswer(_ stream: String, sub: Int?) -> Bool {
        guard let sub else { return false }
        return lastSub[stream] == sub
    }

    /// Nothing of `stream` stays behind: not syncing, not stuck, not waited
    /// for (review C8-7, C9-6).
    private func forget(_ stream: String) {
        owners[stream] = nil
        syncing.remove(stream)
        catchingUp.remove(stream)
        stuck.remove(stream)
        resynced.remove(stream)
        applyFailures[stream] = nil
        lastSub[stream] = nil
        limited[stream] = nil
    }
    /// Streams refused for the socket's limit, by how many times in a row.
    private var limited: [String: Int] = [:]
    /// F3: streams held back by the socket's limit (`too_many_streams`), retried.
    var limitedStreams: Set<String> { Set(limited.keys) }

    /// Streams followed on this socket, but those of a prefix (F3: the room left for channels).
    func followedCount(excludingPrefix prefix: String) -> Int { owners.keys.filter { !$0.hasPrefix(prefix) }.count }
    /// Streams whose snapshot on `resync_required` succeeded on this
    /// connection, waiting for `subscribed`.
    private var resynced: Set<String> = []
    private var running = false
    /// Frames of the current connection, handled one at a time in order.
    private var frames: AsyncStream<ChatFrame>.Continuation?
    /// How long a connection may take from opening to a handled hello.
    var handshakeTimeout: Duration = .seconds(60)
    private var handshake: Task<Void, Never>?
    private var applyFailures: [String: Int] = [:]
    static let maxApplyFailures = 3
    /// Changes with every connection and drop: reads started before do not
    /// count after (review C3-2).
    var epoch: Int { connection }

    /// Which connection is current; everything started for an earlier one
    /// checks it after each `await` and gives up (review C-17).
    private var connection = 0

    init(server: ChatServerAddress, token: String, makeTransport: @escaping @MainActor () -> ChatSocketTransport = { ChatURLSessionTransport() }) {
        self.server = server
        self.token = token
        self.makeTransport = makeTransport
    }

    // MARK: Streams

    /// Adds streams for `sink`; sent at once when connected. A stuck stream
    /// stays stuck until `unstick` (review C2-9).
    func subscribe(_ streams: [String], sink: ChatStreamSink) {
        var fresh: [String: Int] = [:]
        for stream in streams {
            owners[stream] = sink
            if !stuck.contains(stream) { fresh[stream] = sink.cursor(stream) }
        }
        guard state == .connected, helloSeen, !fresh.isEmpty else { return }
        syncing.formUnion(fresh.keys)
        sendSubscribe(fresh)
    }

    /// Follows `streams` again from their cursors now — after a snapshot
    /// moved them (review C-9).
    func resubscribe(_ streams: [String]) {
        let mine = streams.filter { owners[$0] != nil && !stuck.contains($0) }
        for stream in mine { catchingUp.remove(stream) }
        guard state == .connected, helloSeen, !mine.isEmpty else { return }
        let cursors = Dictionary(uniqueKeysWithValues: mine.map { ($0, owners[$0]!.cursor($0)) })
        syncing.formUnion(mine)
        sendSubscribe(cursors)
    }

    func unsubscribe(_ streams: [String]) {
        for stream in streams { forget(stream) }
        if state == .connected, !streams.isEmpty { transport?.send(ChatFrame.unsubscribe(streams).encoded()) }
        if !streams.isEmpty { streamsChanged() }
    }

    /// Every stream of `sink` goes.
    func detach(_ sink: ChatStreamSink) {
        unsubscribe(owners.filter { $0.value === sink }.map(\.key))
    }

    /// The user asks to try a stuck stream again.
    func unstick(_ stream: String) {
        guard stuck.remove(stream) != nil else { return }
        resubscribe([stream])
    }

    /// The current connection, once its `hello` was handled.
    var context: ChatConnectionContext? {
        guard helloSeen, let generation else { return nil }
        return ChatConnectionContext(id: connection, generation: generation)
    }

    func isCurrent(_ context: ChatConnectionContext) -> Bool { context.id == connection }

    var streams: Set<String> { Set(owners.keys) }


    // MARK: Connection

    func start() {
        guard !running else { return }
        running = true
        attempts = 0
        connect()
    }

    func stop() {
        running = false
        reconnecting?.cancel()
        trace("stop")
        drop()
        state = .disconnected
        updateOfflineIndicator()
    }

    /// A new network or a wake. `force` (the system said so) reconnects even
    /// a connection that looks alive — it may be dead on the old path
    /// (review C-21); otherwise only one that is not connected.
    func reconnectNow(force: Bool = false, reason: ReconnectReason = .requested) {
        guard running else { return }
        if case .needsSignIn = state { return }
        guard force || state != .connected || now() - lastFrame > heartbeat else { return }
        trace("reconnect reason=\(reason.rawValue) force=\(force)")
        attempts = 0
        reconnecting?.cancel()
        drop()
        connect()
    }

    private func connect() {
        guard running else { return }
        reconnecting?.cancel()
        connection += 1
        let id = connection
        state = .connecting
        helloSeen = false
        catchingUp = []
        resynced = []
        lastSub = [:]
        connecting = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.checkServer()
            } catch ChatAPIError.unsuitableServer(let missing) {
                guard id == self.connection else { return }
                self.state = .failed(ChatAPIError.unsuitableServer(missing: missing).localizedDescription)
                self.running = false
                return
            } catch {
                guard id == self.connection else { return }
                return self.scheduleReconnect(after: nil, reason: .serverCheckFailed)
            }
            guard id == self.connection, self.running, !Task.isCancelled else { return }
            self.open(id)
        }
    }

    private func open(_ id: Int) {
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let made = makeTransport()
        transport = made
        lastFrame = now()
        // Until the hello is handled: a bounded wait of its own (review C3-5).
        handshake?.cancel()
        let limit = handshakeTimeout
        handshake = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard let self, !Task.isCancelled, self.connection == id, !self.helloSeen else { return }
            self.scheduleReconnect(after: nil, reason: .handshakeTimeout)
        }
        let (stream, continuation) = AsyncStream<ChatFrame>.makeStream()
        frames = continuation
        Task { [weak self] in
            for await frame in stream {
                guard let self, self.connection == id else { return }
                await self.handle(frame, connection: id)
            }
        }
        made.open(request) { [weak self, weak made] event in
            guard let self, let made, self.transport === made, self.connection == id else { return }
            self.handle(event)
        }
    }

    private var wsURL: URL {
        var parts = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false)!
        parts.scheme = server.scheme == "https" ? "wss" : "ws"
        parts.path = "/v1/ws"
        return parts.url!
    }

    /// Ends the current connection and everything started for it.
    private func drop() {
        connection += 1
        handshake?.cancel()
        connecting?.cancel()
        connecting = nil
        watchdog?.cancel()
        frames?.finish()
        frames = nil
        if let transport {
            trace("close direction=local code=1000")
            transport.close(code: 1000)
        }
        transport = nil
        syncing = []
        catchingUp = []
        resynced = []
        lastSub = [:]
        helloSeen = false
        generation = nil
        if state == .connected || state == .connecting { state = .disconnected }
        lifecycle?.socketDisconnected()
    }

    private func scheduleReconnect(after delay: TimeInterval?, reason: ReconnectReason) {
        trace("reconnect reason=\(reason.rawValue)")
        drop()
        guard running else { return }
        attempts += 1
        let wait = delay ?? retryDelay(attempts)
        trace("retry attempt=\(attempts) delay=\(wait)")
        reconnecting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func handle(_ event: ChatTransportEvent) {
        switch event {
        case .opened:
            lastFrame = now()
        case .text(let data):
            lastFrame = now()
            guard let frame = try? ChatFrame.decode(data) else { return }
            frames?.yield(frame)
        case .closed(let code):
            trace("close direction=remote code=\(code)")
            switch code {
            case 4401: signedOut("The server closed this session. Sign in again.")
            case 1012: scheduleReconnect(after: restartDelay(), reason: .remoteClose)
            default: scheduleReconnect(after: nil, reason: .remoteClose)
            }
        case .failed(_, let status):
            trace("transportFailure httpStatus=\(status.map(String.init) ?? "none")")
            if status == 401 { signedOut("The server did not accept this session. Sign in again.") }
            else { scheduleReconnect(after: nil, reason: .transportFailure) }
        }
    }

    private func signedOut(_ reason: String) {
        running = false
        reconnecting?.cancel()
        drop()
        state = .needsSignIn(reason)
        onUnauthorized(reason)
    }

    // MARK: Frames

    private func handle(_ frame: ChatFrame, connection id: Int) async {
        switch frame {
        case .hello(let generation, let seconds, _):
            heartbeat = .seconds(max(1, seconds))
            let context = ChatConnectionContext(id: id, generation: generation)
            // The owner handles the generation before anything is subscribed;
            // it may add streams meanwhile, and they are subscribed below. A
            // hello it could not finish is tried again by a new connection
            // (review C3-5).
            if let lifecycle {
                let done = await lifecycle.socketHello(context)
                guard id == connection else { return }
                guard done else { return scheduleReconnect(after: nil, reason: .helloRejected) }
            }
            handshake?.cancel()
            // Liveness counts from here, for the established connection.
            lastFrame = now()
            startWatchdog()
            state = .connected
            attempts = 0
            helloSeen = true
            self.generation = generation
            let cursors = Dictionary(uniqueKeysWithValues: owners.filter { !stuck.contains($0.key) }.map { ($0.key, $0.value.cursor($0.key)) })
            syncing = Set(cursors.keys)
            sendSubscribe(cursors)
            lifecycle?.socketConnected(context)
        case .event(let event):
            guard let sink = owners[event.stream] else { return }
            let cursor = sink.cursor(event.stream)
            if event.seq <= cursor { return }
            if event.seq > cursor + 1 {
                // Missed something: this stream again from its cursor, once.
                guard !catchingUp.contains(event.stream) else { return }
                catchUp(event.stream, from: cursor, sink: sink)
                return
            }
            if !sink.apply(event) {
                // Not written: the stream is not in step. Followed again from
                // its cursor; after a few failures it is stuck (review C3-17).
                applyFailures[event.stream, default: 0] += 1
                if applyFailures[event.stream, default: 0] >= Self.maxApplyFailures {
                    stuck.insert(event.stream)
                    syncing.remove(event.stream)
                } else if !catchingUp.contains(event.stream) {
                    catchUp(event.stream, from: sink.cursor(event.stream), sink: sink)
                }
                return
            }
            applyFailures[event.stream] = nil
        case .subscribed(let stream, let head, let sub):
            // The answer to an earlier subscription of this stream: it says
            // nothing of the last one (review C9-4, C10-4).
            guard isCurrentAnswer(stream, sub: sub) else { return }
            limited[stream] = nil
            catchingUp.remove(stream)
            resynced.remove(stream)
            guard let sink = owners[stream] else { return }
            // A stuck stream stays in error, whatever comes (review C4-10).
            guard !stuck.contains(stream) else { return }
            // Ready only when the cursor really reached the head.
            if sink.cursor(stream) < head {
                catchUp(stream, from: sink.cursor(stream), sink: sink)
                return
            }
            syncing.remove(stream)
            sink.ready(stream, head: head)
            streamsChanged()
        case .resyncRequired(let stream, let sub):
            guard isCurrentAnswer(stream, sub: sub) else { return }
            guard let sink = owners[stream], !stuck.contains(stream) else { return }
            if resynced.contains(stream) {
                // Again right after a snapshot that worked: no loop.
                resynced.remove(stream)
                syncing.remove(stream)
                stuck.insert(stream)
                return
            }
            do {
                try await sink.resync(stream)
            } catch {
                // Not taken: not counted as done (review C-13); try again later.
                guard id == connection else { return }
                return scheduleReconnect(after: nil, reason: .resyncFailed)
            }
            // The sink followed the stream again itself (one owner of that).
            guard id == connection, owners[stream] === sink else { return }
            resynced.insert(stream)
        case .tooManyStreams(let stream, let sub):
            // The socket's limit, not the right: the stream and its data stay
            // the sink's, and it is subscribed again after a pause, growing as
            // reconnects do; out of step meanwhile (review C6g p2-5).
            guard isCurrentAnswer(stream, sub: sub), let sink = owners[stream] else { return }
            limited[stream, default: 0] += 1
            // Tried again only while this refusal is still the stream's last
            // word: a newer subscription, its success or the stream gone end it.
            let refused = lastSub[stream]
            syncing.insert(stream)
            sink.catchingUp(stream)
            let wait = retryDelay(limited[stream] ?? 1)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, self.owners[stream] === sink, self.connection == id,
                      self.limited[stream] != nil, self.lastSub[stream] == refused else { return }
                self.resubscribe([stream])
            }
        case .unsubscribed(let stream, let sub):
            guard isCurrentAnswer(stream, sub: sub) else { return }
            let sink = owners[stream]
            forget(stream)
            sink?.dropped(stream)
            streamsChanged()
        case .ping:
            transport?.send(ChatFrame.pong.encoded())
        case .ephemeral(let org, let type, let body):
            onEphemeral(org, type, body)
        case .pong, .subscribe, .unsubscribe, .unknown:
            break
        }
    }

    /// Nothing from the server for two heartbeats: the connection is gone.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.heartbeat / 2)
                guard !Task.isCancelled, self.state == .connected else { return }
                if self.now() - self.lastFrame > self.heartbeat * 2 {
                    self.scheduleReconnect(after: 0, reason: .heartbeatTimeout)
                    return
                }
            }
        }
    }
}
