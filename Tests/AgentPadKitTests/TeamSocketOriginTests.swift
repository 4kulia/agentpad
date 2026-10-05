import AgentPadHookKit
import Darwin
import XCTest
@testable import AgentPadKit

/// Requests on the control socket from a team run's processes (Y4): a real
/// child and grandchild registered in `TeamProcesses`, a real socket for the
/// PID, and the controller's answers.
@MainActor
final class TeamSocketOriginTests: XCTestCase {
    private var child: Process?
    private var leader: TeamProcessStart?
    private var server: HookServer?
    private var socketPath = ""
    private var root: URL!
    private var service: TeamService!
    private let callId = UUID().uuidString.lowercased()

    override func setUp() async throws {
        socketPath = NSTemporaryDirectory() + "agentpad-origin-\(UUID().uuidString.prefix(8)).sock"
        root = FileManager.default.temporaryDirectory.appendingPathComponent("team-origin-\(UUID().uuidString)")
        service = TeamService(storage: TeamStorage(directory: root))
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(atPath: socketPath)
        if let leader {
            let seen = TeamPidSet()
            if let descendants = TeamProcesses.descendantIdentities(of: leader.identity) { seen.insert(descendants) }
            _ = await TeamProcesses.stop(leader, also: seen, grace: .milliseconds(100), killWait: .milliseconds(100))
            TeamProcesses.shared.remove(leader)
        }
        child = nil
        leader = nil
        service = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// A run like `ClaudeCodeRunner` starts: its own process group, registered
    /// with its call. Returns the run's pid and a grandchild's.
    private func startRun(_ script: String = "/bin/sleep 30 & /bin/sleep 30", environment: [String: String] = [:]) async throws -> (pid_t, pid_t) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        try process.run()
        child = process
        let pid = process.processIdentifier
        let leader = TeamProcessStart.of(pid)
        self.leader = leader
        TeamProcesses.shared.add(leader, callId: callId)
        let deadline = ContinuousClock.now + .seconds(5)
        var grandchild: pid_t?
        while grandchild == nil, ContinuousClock.now < deadline {
            grandchild = TeamProcesses.descendants(of: pid).first
            if grandchild == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        return (pid, try XCTUnwrap(grandchild))
    }

    private func controller() -> AgentPadCLIController {
        AgentPadCLIController(
            appVersion: "test", windows: { [] }, fallbackWindow: { nil }, activateApp: {},
            teamService: { [service = service!] in service },
            templates: { [] }, resume: { _, _, _, _, completion in completion(.opened) }
        )
    }

    private func respond(_ request: AgentPadCLIRequest, origin: AgentPadCallerOrigin) async -> AgentPadCLIResponse {
        let controller = controller()
        return await withCheckedContinuation { continuation in
            controller.handle(request, origin: origin) { continuation.resume(returning: $0) }
        }
    }

    private func team(_ action: AgentPadCLITeamAction, _ edit: (inout AgentPadCLIRequest) -> Void = { _ in }) -> AgentPadCLIRequest {
        var request = AgentPadCLIRequest(verb: .team)
        request.teamAction = action.rawValue
        edit(&request)
        return request
    }

    private var changingRequests: [(String, AgentPadCLIRequest)] {
        [
            ("team publish", team(.publish) { $0.teamAgent = "x"; $0.teamFolder = "/tmp"; $0.teamDescription = "d" }),
            ("open with a command", AgentPadCLIRequest(verb: .open, cwd: "/tmp", command: "touch /tmp/agentpad-y4")),
            ("resume", AgentPadCLIRequest(verb: .resume, agent: "claude", conversationId: UUID().uuidString)),
            ("close", AgentPadCLIRequest(verb: .close, tab: UUID().uuidString)),
            ("rename", AgentPadCLIRequest(verb: .rename, tab: UUID().uuidString, title: "x")),
            ("team ask", team(.ask) { $0.teamAgent = "a@b"; $0.teamPrompt = "hi" }),
        ]
    }

    // (1) The run and its grandchild may not change anything.
    func testRunAndGrandchildAreRefused() async throws {
        let (pid, grandchild) = try await startRun()
        for caller in [pid, grandchild] {
            let origin = AgentPadCallerOrigin.of(peerPID: caller)
            XCTAssertEqual(origin, .teamRun(callId: callId), "pid \(caller)")
            // C7: the server actions too, all five — refused before any window, read or queue.
            let server = [AgentPadCLITeamAction.status, .login, .logout, .members, .invite].map { ("team \($0.rawValue)", team($0)) }
            for (name, request) in changingRequests + server + [("focus", AgentPadCLIRequest(verb: .focus, tab: UUID().uuidString)),
                                                                ("team unpublish", team(.unpublish))] {
                let response = await respond(request, origin: origin)
                XCTAssertFalse(response.ok, name)
                XCTAssertEqual(response.error, AgentPadCallerOrigin.teamRunRefusal, name)
            }
        }
    }

    // (2) `team access` for its own call goes on; for another call it does not.
    func testRunMayAskForFoldersOnlyForItsOwnCall() async throws {
        let (pid, _) = try await startRun()
        let origin = AgentPadCallerOrigin.of(peerPID: pid)
        let own = team(.access) { $0.teamCall = self.callId.uppercased(); $0.teamFolder = "/tmp" }
        let other = team(.access) { $0.teamCall = UUID().uuidString; $0.teamFolder = "/tmp" }
        XCTAssertNil(origin.refusal(for: own))
        // Past the origin check: the call is not running here, so the calls layer answers.
        let ownAnswer = await TeamCLIHandler.handle(own, service: service, origin: origin)
        XCTAssertNotEqual(ownAnswer.error, AgentPadCallerOrigin.teamRunRefusal)
        XCTAssertTrue(ownAnswer.error?.contains("no running call") == true, ownAnswer.error ?? "")
        let otherAnswer = await TeamCLIHandler.handle(other, service: service, origin: origin)
        XCTAssertEqual(otherAnswer.error, AgentPadCallerOrigin.teamRunRefusal)
        // access-check of a request that is not this call's.
        let check = team(.accessCheck) { $0.teamAgent = UUID().uuidString }
        let checkAnswer = await TeamCLIHandler.handle(check, service: service, origin: origin)
        XCTAssertEqual(checkAnswer.error, AgentPadCallerOrigin.teamRunRefusal)
        // A run without run tools has no call to ask for.
        let anonymous = await TeamCLIHandler.handle(own, service: service, origin: .teamRun(callId: nil))
        XCTAssertEqual(anonymous.error, AgentPadCallerOrigin.teamRunRefusal)
    }

    // (3) The same requests from outside any run go on.
    func testOutsideCallerIsNotRefused() async throws {
        _ = try await startRun()
        let origin = AgentPadCallerOrigin.of(peerPID: getpid())
        XCTAssertEqual(origin, .outside)
        for (name, request) in changingRequests {
            XCTAssertNil(origin.refusal(for: request), name)
            let response = await respond(request, origin: origin)
            XCTAssertNotEqual(response.error, AgentPadCallerOrigin.teamRunRefusal, name)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("agents.json").path),
                      "the accepted publish used this test's storage")
    }

    // (4) No PID from the kernel: fail closed, including folder access.
    func testUnplacedCallerIsRefused() async throws {
        for pid in [nil, 0, -1] as [pid_t?] {
            let origin = AgentPadCallerOrigin.of(peerPID: pid)
            XCTAssertEqual(origin, .teamRun(callId: nil))
            for (name, request) in changingRequests + [("team access", team(.access) { $0.teamCall = self.callId; $0.teamFolder = "/tmp" })] {
                let response = await respond(request, origin: origin)
                XCTAssertEqual(response.error, AgentPadCallerOrigin.teamRunRefusal, name)
            }
        }
    }

    /// The socket end to end: with a PID that cannot be read, `team publish`
    /// and `team status` are refused.
    func testSocketWithAnUnreadablePeer() async throws {
        let controller = controller()
        startServer(controller, readPeerPID: { _ in nil })
        let publish = try await exchange(changingRequests[0].1)
        XCTAssertEqual(publish.error, AgentPadCallerOrigin.teamRunRefusal)
        let status = try await exchange(team(.status))
        XCTAssertFalse(status.ok, status.error ?? "")
        XCTAssertEqual(status.error, AgentPadCallerOrigin.teamRunRefusal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("agents.json").path))
    }

    /// The socket end to end with the real `LOCAL_PEERPID`: a client the run
    /// started is refused, and its command never runs.
    func testSocketKnowsARunsClient() async throws {
        let marker = NSTemporaryDirectory() + "agentpad-y4-\(UUID().uuidString.prefix(8))"
        startServer(controller())
        var request = changingRequests[1].1
        request.command = "touch \(marker)"
        let line = try XCTUnwrap(request.encodedLine())
        let output = NSTemporaryDirectory() + "agentpad-y4-out-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: output) }
        // Registered before the client connects; the client is the run's
        // grandchild. It stays connected after writing, as agentpad-cli does.
        _ = try await startRun(
            #"/bin/sleep 0.5; /bin/sh -c '(printf "%s" "$LINE"; /bin/sleep 2) | /usr/bin/nc -U "$SOCK" > "$OUT"'"#,
            environment: ["LINE": String(decoding: line, as: UTF8.self), "SOCK": socketPath, "OUT": output]
        )
        let deadline = ContinuousClock.now + .seconds(8)
        while child?.isRunning == true, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let data = try Data(contentsOf: URL(fileURLWithPath: output))
        let response = try XCTUnwrap(AgentPadCLIResponse.decode(from: data))
        XCTAssertEqual(response.error, AgentPadCallerOrigin.teamRunRefusal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    // MARK: Review fixes (review-client-c.md 2, 3)

    /// Hook messages: a confirmed team run's are dropped; everyone else's
    /// go through, as in 1.0.6 (Y4 narrowed).
    func testHookMessagesFollowTheOrigin() async throws {
        var seen: [String] = []
        let server = HookServer(socketPath: socketPath) { message in
            switch message {
            case .conversationId(let id, _): seen.append("conversation \(id)")
            default: seen.append("other")
            }
        }
        self.server = server
        server.start()
        let surface = UUID().uuidString
        let conversation = ["kind": "conversationId", "surface": surface, "conversationId": "c1"]
        let env = ["kind": "env", "surface": surface]
        for (origin, expected) in [(AgentPadCallerOrigin.teamRun(callId: nil), [String]()),
                                   (.outside, ["conversation c1", "other"])] {
            seen = []
            server.originOf = { _ in origin }
            let path = socketPath
            let sent = await Task.detached { [conversation, env] in
                AgentPadHookKit.sendPayload(conversation, to: path) && AgentPadHookKit.sendPayload(env, to: path)
            }.value
            XCTAssertTrue(sent)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(seen, expected, "\(origin)")
        }
    }

    /// `shellCommand`: only the named shell or a process under it, outside any run.
    func testShellCommandNeedsTheNamedShellOutsideRuns() async throws {
        var asked: [pid_t] = []
        let server = HookServer(socketPath: socketPath) { _ in }
        server.onShellCommandRequest = { request in asked.append(request.shellPID); return "echo hi" }
        self.server = server
        server.start()
        let path = socketPath
        func fetch(_ pid: pid_t) async -> String? {
            await Task.detached { AgentPadHookKit.fetchShellCommand(surface: UUID(), shellPID: pid, socketPath: path) }.value
        }
        server.originOf = { _ in .teamRun(callId: nil) }
        let fromRun = await fetch(getpid())
        XCTAssertNil(fromRun)
        server.originOf = { _ in .outside }
        // Another tab's shell: a process that is not this one nor above it.
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["5"]
        try other.run()
        defer { other.terminate() }
        let otherShell = await fetch(other.processIdentifier)
        XCTAssertNil(otherShell)
        let own = await fetch(getpid())
        XCTAssertEqual(own, "echo hi")
        XCTAssertEqual(asked, [getpid()], "only the own shell's request reached the app")
    }

    /// A walk that cannot reach launchd counts only what it read: a run
    /// found on the way is a run; otherwise the caller is served (Y4 narrowed).
    func testIncompleteAncestorWalkCountsWhatItRead() throws {
        let processes = TeamProcesses()
        // A chain longer than the walk's limit.
        let long = processes.run(containing: 10_000) { pid in (parent: pid - 1, group: pid) }
        XCTAssertEqual(long, .notFound)
        // An ancestor that cannot be read.
        let broken = processes.run(containing: 500) { pid in pid == 500 ? (parent: 400, group: 500) : nil }
        XCTAssertEqual(broken, .notFound)
        // A chain to launchd outside every run.
        let fine = processes.run(containing: 500) { pid in (parent: pid == 500 ? 1 : 0, group: pid) }
        XCTAssertEqual(fine, .notFound)
    }

    /// Review C2-20: a tab's hook is acknowledged off the main thread — it
    /// takes milliseconds even while the main thread is busy.
    func testHookIsAcknowledgedWhileTheMainThreadIsBusy() async throws {
        var seen = 0
        let server = HookServer(socketPath: socketPath) { _ in seen += 1 }
        self.server = server
        server.start()
        let path = socketPath
        let busy = expectation(description: "main thread was busy")
        DispatchQueue.main.async {
            Thread.sleep(forTimeInterval: 0.6)
            busy.fulfill()
        }
        let elapsed = await Task.detached { () -> Double in
            usleep(50_000)
            let started = Date()
            _ = AgentPadHookKit.sendPayload(["kind": "env", "surface": UUID().uuidString], to: path)
            return Date().timeIntervalSince(started)
        }.value
        XCTAssertLessThan(elapsed, 0.05, "the hook did not wait for the main thread")
        await fulfillment(of: [busy], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(seen, 1, "and the message still reached the app")
    }

    /// C3-15: a hook waits at most its deadline, whatever the other end does;
    /// a silent client does not hold up another's hook.
    func testHookHasAHardDeadlineAndSilentClientsHoldNothing() async throws {
        // A socket that listens and never accepts or reads.
        let deaf = NSTemporaryDirectory() + "agentpad-deaf-\(UUID().uuidString.prefix(6)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd); unlink(deaf) }
        _ = AgentPadHookKit.withUnixSocketAddress(path: deaf) { Darwin.bind(fd, $0, $1) }
        Darwin.listen(fd, 1)
        let big = ["kind": "env", "surface": UUID().uuidString, "pad": String(repeating: "x", count: 200_000)]
        let elapsed = await Task.detached { () -> Double in
            let started = Date()
            _ = AgentPadHookKit.sendPayload(big, to: deaf)
            return Date().timeIntervalSince(started)
        }.value
        XCTAssertLessThan(elapsed, 0.3)

        // The app's socket: a client that connects and stays silent.
        var seen = 0
        let server = HookServer(socketPath: socketPath) { _ in seen += 1 }
        self.server = server
        server.start()
        let silent = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(silent) }
        _ = AgentPadHookKit.withUnixSocketAddress(path: socketPath) { Darwin.connect(silent, $0, $1) }
        let path = socketPath
        let hookTime = await Task.detached { () -> Double in
            usleep(50_000)
            let started = Date()
            _ = AgentPadHookKit.sendPayload(["kind": "env", "surface": UUID().uuidString], to: path)
            return Date().timeIntervalSince(started)
        }.value
        XCTAssertLessThan(hookTime, 0.1, "not held up by the silent client")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(seen, 1)
    }

    private func startServer(_ controller: AgentPadCLIController, readPeerPID: (@Sendable (Int32) -> pid_t?)? = nil) {
        let server = HookServer(socketPath: socketPath) { _ in }
        if let readPeerPID { server.readPeerPID = readPeerPID }
        server.onCLIRequest = { request, origin, isCallerWaiting, completion in
            controller.handle(request, origin: origin, isCallerWaiting: isCallerWaiting, completion: completion)
        }
        server.start()
        self.server = server
    }

    /// One request from this process; the main actor stays free for the server.
    private func exchange(_ request: AgentPadCLIRequest) async throws -> AgentPadCLIResponse {
        let line = try XCTUnwrap(request.encodedLine())
        let path = socketPath
        let data = try await Task.detached { () -> Data in
            switch AgentPadCLITransport.roundTrip(line: line, socketPath: path, timeout: 5) {
            case .success(let data): return data
            case .failure(let failure): throw NSError(domain: "y4", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(failure)"])
            }
        }.value
        return try XCTUnwrap(AgentPadCLIResponse.decode(from: data))
    }
}

extension TeamProcessStart {
    /// The identity of a live process, as a run's leader (tests).
    static func of(_ pid: pid_t) -> TeamProcessStart {
        TeamProcessStart(pid: pid, pgid: getpgid(pid), startTime: TeamProcesses.startTime(pid) ?? 0)
    }
}
