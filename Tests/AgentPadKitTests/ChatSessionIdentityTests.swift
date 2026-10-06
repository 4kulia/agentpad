import AgentPadHookKit
import Darwin
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatSessionIdentityTests: XCTestCase {
    private var root: URL!
    private var server: HookServer?
    private var child: Process?
    private var leader: TeamProcessStart?
    private var fixture: ChatChannelExecutionTests.Fixture?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-identity-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ChatNotifications.badgeChanged = {}
    }

    override func tearDown() async throws {
        server?.stop()
        if let leader {
            let seen = TeamPidSet()
            if let descendants = TeamProcesses.descendantIdentities(of: leader.identity) { seen.insert(descendants) }
            _ = await TeamProcesses.stop(leader, also: seen, grace: .milliseconds(100), killWait: .milliseconds(100))
            TeamProcesses.shared.remove(leader)
        }
        fixture?.sender?.hold()
        await fixture?.service.disconnect()
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
        child = nil; leader = nil; server = nil; fixture = nil
    }

    /// An arbitrary binary mimics the native installation's version path.
    /// Real kernel name, PTY, parents and LOCAL_PEERPID; no Claude
    /// config, hooks, credentials or production socket are involved.
    private func startTerminal(request: AgentPadCLIRequest, socket: String) throws {
        let native = root.appendingPathComponent("claude/versions/2.1.291")
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("native.c")
        try #"""
        #include <stdio.h>
        #include <stdlib.h>
        #include <unistd.h>
        #include <sys/wait.h>
        int main(int argc, char **argv) {
            if (argc != 2) return 2;
            char path[4096];
            snprintf(path, sizeof(path), "%s/pid", getenv("FIXTURE"));
            FILE *out = fopen(path, "w");
            if (!out) return 3;
            fprintf(out, "%d", getpid()); fclose(out);
            pid_t child = fork();
            if (child < 0) return 4;
            if (!child) { execl("/bin/bash", "bash", "--noprofile", "--norc", argv[1], NULL); _exit(127); }
            int status = 0;
            return waitpid(child, &status, 0) < 0 ? 5 : 0;
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = [source.path, "-o", native.path]
        compile.standardOutput = FileHandle.nullDevice
        compile.standardError = FileHandle.nullDevice
        try compile.run(); compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0)
        try XCTUnwrap(request.encodedLine()).write(to: root.appendingPathComponent("request"))
        let script = """
        while [ ! -f "$FIXTURE/ready" ]; do /bin/sleep 0.02; done
        (/bin/cat "$FIXTURE/request"; /bin/sleep 10) | /usr/bin/nc -U "$SOCKET" > "$FIXTURE/response"
        /bin/sleep 30
        """
        try script.write(to: root.appendingPathComponent("native.sh"), atomically: true, encoding: .utf8)
        try #"""
        "$NATIVE" "$FIXTURE/native.sh"
        /bin/sleep 30
        """#.write(to: root.appendingPathComponent("bash.sh"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-f", "-c", #"/bin/bash --noprofile --norc "$FIXTURE/bash.sh"; true"#]
        process.environment = ["PATH": "/usr/bin:/bin", "FIXTURE": root.path, "NATIVE": native.path, "SOCKET": socket]
        process.standardInput = Pipe()
        let log = root.appendingPathComponent("terminal-output")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        process.standardOutput = output
        process.standardError = output
        try process.run()
        child = process
        leader = TeamProcessStart.of(process.processIdentifier)
    }

    private func waitFor(_ stage: String, _ condition: () throws -> Bool) async throws {
        let until = ContinuousClock.now + .seconds(8)
        while try !condition() {
            guard ContinuousClock.now < until else {
                let log = (try? String(contentsOf: root.appendingPathComponent("terminal-output"), encoding: .utf8)) ?? ""
                throw NSError(domain: "chat-identity-timeout", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(stage): \(log)"])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testForgedNativeVersionProcessAndItsSocketChildCannotUseChannelTools() async throws {
        try await checkNativeProcess(asTeamRun: false, trustedSignature: false)
    }

    func testVerifiedSignatureCanReadChannelsBeforeAnyHook() async throws {
        try await checkNativeProcess(asTeamRun: false, trustedSignature: true)
    }

    func testNativeTeamRunAndItsSocketChildCannotReadChannels() async throws {
        try await checkNativeProcess(asTeamRun: true, trustedSignature: true)
    }

    func testEndedClaudeWithLiveSocketChildCannotPostAfterAwait() async throws {
        let f = try await ChatChannelExecutionTests.Fixture(root: root.appendingPathComponent("service"))
        fixture = f
        f.service.serverCapabilities[f.key.server] = ["chat.session_tools"]
        f.service.isServerKnown = { _, _ in true }
        let gate = Gate(), entered = expectation(description: "post preflight suspended")
        gate.close(); defer { gate.open() }
        ChatStubProtocol.reset { _, _ in
            entered.fulfill(); gate.pass()
            return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8)))
        }
        let engine = TestEngine()
        let liveTab = Session(engine: engine, currentDirectory: root, agent: .terminal)
        let path = root.appendingPathComponent("socket").path
        let server = HookServer(socketPath: path) { _ in XCTFail("no hook is required") }
        self.server = server
        server.start()
        var request = AgentPadCLIRequest(verb: .team)
        request.teamAction = "chat"
        request.chatArguments = "{\"tool\":\"chat_post\",\"org_id\":\"\(f.key.orgId)\",\"channel_id\":\"f5000000-0000-4000-8000-000000000001\",\"text\":\"late post\"}"
        try startTerminal(request: request, socket: path)
        let pidFile = root.appendingPathComponent("pid")
        try await waitFor("native PID") { FileManager.default.fileExists(atPath: pidFile.path) }
        let nativePID = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        engine.foregroundPid = nativePID
        var peer: (Int32, UInt64)?
        var callerWaiting: (() -> Bool)?
        server.onCLIRequest = { request, origin, waiting, completion in
            if case .localProcess(let pid, let start) = origin { peer = (pid, start) }
            callerWaiting = waiting
            Task {
                completion(await ChatSessionTools.handle(request, origin: origin, sessions: { [liveTab] },
                    service: f.service, isCallerWaiting: waiting, signatureVerifier: { $0 == nativePID }))
            }
        }
        try Data().write(to: root.appendingPathComponent("ready"))
        await fulfillment(of: [entered], timeout: 5)
        let (peerPID, peerStart) = try XCTUnwrap(peer)
        XCTAssertNotEqual(peerPID, nativePID)
        XCTAssertEqual(kill(nativePID, SIGKILL), 0, "only the fixture process we started")
        try await waitFor("Claude exit") { ChatSessionIdentity.Process.read(nativePID) == nil }
        XCTAssertTrue(SessionProcessScanner.identityMatches(pid: peerPID, startedAtUs: peerStart), "MCP descendant survives Claude")
        XCTAssertEqual(callerWaiting?(), true, "the socket stays open")
        gate.open()
        let output = root.appendingPathComponent("response")
        try await waitFor("refusal") { (try? Data(contentsOf: output).contains(0x0A)) == true }
        let response = try XCTUnwrap(AgentPadCLIResponse.decode(from: Data(contentsOf: output)))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "session_process_unavailable")
        XCTAssertTrue(response.chatResult?.contains("Restart Claude") == true)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testKernelVerificationDoesNotOccupyMainActor() async throws {
        try await checkOffMainVerification(blockSignature: false)
    }

    func testSignatureVerificationDoesNotOccupyMainActor() async throws {
        try await checkOffMainVerification(blockSignature: true)
    }

    private func checkOffMainVerification(blockSignature: Bool) async throws {
        let pid = getpid(), start = try XCTUnwrap(SessionProcessScanner.startTimeUs(of: pid))
        let engine = TestEngine()
        engine.foregroundPid = pid
        let tab = Session(engine: engine, currentDirectory: root, agent: .terminal)
        let entered = expectation(description: "verification started")
        entered.assertForOverFulfill = false
        let release = DispatchGroup()
        release.enter()
        let wait: @Sendable () -> Void = {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success, "MainActor must release verification")
        }
        let task = Task {
            try await ChatSessionIdentity.verify(.localProcess(pid: pid, startedAtUs: start), sessions: [tab], scan: { foreground in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(foreground, pid)
                if !blockSignature { wait() }
                return [.init(pid: pid, ppid: 1, name: "claude", isForeground: true, startedAtUs: start)]
            }, signatureVerifier: { candidate in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(candidate, pid)
                if blockSignature { wait() }
                return true
            }, kernel: .init(process: { candidate in
                guard candidate == pid else { return nil }
                return .init(pid: pid, parent: 1, startedAtUs: start, terminal: 1)
            }))
        }
        await fulfillment(of: [entered], timeout: 2)
        // This actor turn releases a blocked scan or signature check.
        release.leave()
        let caller = try await task.value
        XCTAssertEqual(caller.caller.surface, tab.id.uuidString.lowercased())
    }

    private func checkNativeProcess(asTeamRun: Bool, trustedSignature: Bool) async throws {
        let f = try await ChatChannelExecutionTests.Fixture(root: root.appendingPathComponent("service"))
        fixture = f
        f.service.serverCapabilities[f.key.server] = ["chat.session_tools"]
        f.service.isServerKnown = { _, _ in true }
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: Data(#"{"channels":[],"next":null}"#.utf8))) }
        let workspace = makeTestStore(claudeProjectsRoot: f.service.claudeProjectsRoot)
        let tab = try XCTUnwrap(workspace.active?.activeSession)
        let engine = try XCTUnwrap(tab.engine as? TestEngine)
        tab.customTitle = "Native Claude"
        let path = root.appendingPathComponent("socket").path
        var caller: ChatLocalCaller?
        var peer: Int32?
        var acceptedOrigin: AgentPadCallerOrigin?
        let server = HookServer(socketPath: path) { _ in XCTFail("no hook is required") }
        self.server = server
        server.start()
        var request = AgentPadCLIRequest(verb: .team)
        request.teamAction = AgentPadCLITeamAction.chat.rawValue
        request.chatArguments = #"{"tool":"chat_channels"}"#
        try startTerminal(request: request, socket: path)
        let pidFile = root.appendingPathComponent("pid")
        try await waitFor("native PID") { FileManager.default.fileExists(atPath: pidFile.path) }
        let nativePID = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        let verifier: @Sendable (Int32) -> Bool = { pid in
            XCTAssertFalse(Thread.isMainThread, "initial verification and every revalidation must stay off-main")
            return trustedSignature ? pid == nativePID : ChatClaudeProcess.hasTrustedSignature(pid)
        }
        server.onCLIRequest = { request, origin, waiting, completion in
            acceptedOrigin = origin
            if case .localProcess(let pid, _) = origin { peer = pid }
            Task {
                caller = await ChatSessionIdentity.resolve(origin, sessions: [tab], signatureVerifier: verifier)
                completion(await ChatSessionTools.handle(request, origin: origin, sessions: { [tab] },
                                                         service: f.service, isCallerWaiting: waiting, signatureVerifier: verifier))
            }
        }
        engine.foregroundPid = nativePID
        let rows = SessionProcessScanner.identityProcesses(foregroundPID: nativePID)
        XCTAssertEqual(rows.first { $0.pid == nativePID }?.name, "2.1.291", "reproduce the released predicate's blind spot")
        XCTAssertTrue(rows.contains { $0.name == "zsh" })
        XCTAssertTrue(rows.contains { $0.name == "bash" })
        XCTAssertNil(tab.conversationId)
        let nativeOrigin = AgentPadCallerOrigin.of(peerPID: nativePID)
        let nativeCaller = await ChatSessionIdentity.resolve(nativeOrigin, sessions: [tab], signatureVerifier: verifier)
        XCTAssertEqual(nativeCaller?.claudePID, trustedSignature ? nativePID : nil)
        let run = TeamProcessStart.of(nativePID)
        let callId = UUID().uuidString.lowercased()
        if asTeamRun {
            TeamProcesses.shared.add(run, callId: callId)
            // Registration after accept must also be noticed on revalidation.
            let teamCaller = await ChatSessionIdentity.resolve(nativeOrigin, sessions: [tab], signatureVerifier: verifier)
            XCTAssertNil(teamCaller)
        }
        defer { if asTeamRun { TeamProcesses.shared.remove(run) } }
        try Data().write(to: root.appendingPathComponent("ready"))
        let output = root.appendingPathComponent("response")
        try await waitFor("socket response") { (try? Data(contentsOf: output).contains(0x0A)) == true }
        let response = try XCTUnwrap(AgentPadCLIResponse.decode(from: Data(contentsOf: output)))
        if asTeamRun {
            XCTAssertEqual(acceptedOrigin, .teamRun(callId: callId))
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error, "team_run_not_allowed")
            XCTAssertNil(caller)
            XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
            XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        } else if trustedSignature {
            XCTAssertTrue(response.ok, response.chatResult ?? response.error ?? "no result")
            XCTAssertEqual(caller?.claudePID, nativePID)
            XCTAssertEqual(caller?.surface, tab.id.uuidString.lowercased())
            XCTAssertNotNil(peer)
            XCTAssertNotEqual(peer, nativePID, "the socket peer is the MCP transport child, not Claude")
            XCTAssertEqual(ChatStubProtocol.seen.count, 1)
        } else {
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error, "unrecognized_claude_code_signature")
            XCTAssertNil(caller)
            XCTAssertNotNil(peer)
            XCTAssertNotEqual(peer, nativePID)
            for tool in ["chat_channels", "chat_read", "chat_post"] {
                request.chatArguments = "{\"tool\":\"\(tool)\"}"
                // nc exits once its response arrives; the fixture ancestor is
                // still alive, so the remaining verbs test signature refusal.
                let reply = await ChatSessionTools.handle(request, origin: nativeOrigin,
                                                         sessions: { [tab] }, service: f.service)
                XCTAssertFalse(reply.ok)
                let json = try JSONDecoder().decode(ChatJSON.self, from: Data(XCTUnwrap(reply.chatResult).utf8))
                XCTAssertEqual(json["error"]?.string, "unrecognized_claude_code_signature")
                XCTAssertTrue(json["message"]?.string?.contains("unrecognized Claude Code signature") == true)
                XCTAssertTrue(json["message"]?.string?.contains("npm/node") == true)
                XCTAssertTrue(json["message"]?.string?.contains("official native Claude Code") == true)
            }
            XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
            XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        }
    }

    private func nativeTab(id: UUID = UUID(), offset: Int32 = 0) -> ChatSessionIdentity.Tab {
        let names = ["login", "zsh", "bash", "2.1.291", "agentpad-cli"]
        let rows = names.enumerated().map { i, name in
            let pid = offset + 10 + Int32(i)
            return SessionProcessScanner.Raw(pid: pid, ppid: i == 0 ? 1 : pid - 1, name: name,
                                             isForeground: i >= 2, startedAtUs: UInt64(pid * 10))
        }
        return .init(id: id, customTitle: "Same title", folderName: "project", processes: rows)
    }

    private func nativeSignature(_ pid: Int32) -> Bool {
        pid % 100 == 13
    }

    func testOnlySignatureRecognizesClaudeRegardlessOfProcessName() {
        for name in ["claude", "2.1.291", "node", "unrelated"] {
            var tab = nativeTab()
            tab.processes[3] = .init(pid: 13, ppid: 12, name: name, isForeground: true, startedAtUs: 130)
            XCTAssertNil(ChatSessionIdentity.resolve(pid: 14, startedAt: 140, tabs: [tab], identity: { _, _ in true },
                                                    signatureVerifier: { _ in false }), name)
            XCTAssertEqual(ChatSessionIdentity.resolve(pid: 14, startedAt: 140, tabs: [tab], identity: { _, _ in true },
                                                      signatureVerifier: nativeSignature)?.claudePID, 13, name)
        }
        XCTAssertNil(ChatClaudeProcess.executablePath(of: 99_999_999))
        XCTAssertFalse(ChatClaudeProcess.hasTrustedSignature(99_999_999))
    }

    func testNativeAncestryCrossesLoginAndShellsAndDisambiguatesTabNames() throws {
        let a = nativeTab(), b = nativeTab(offset: 100)
        let caller = try ChatSessionIdentity.verify(pid: 14, startedAt: 140, tabs: [a, b], identity: { _, _ in true }, signatureVerifier: nativeSignature)
        XCTAssertEqual(caller.claudePID, 13)
        XCTAssertEqual(caller.claudeStart, 130)
        XCTAssertEqual(caller.surface, a.id.uuidString.lowercased())
        XCTAssertEqual(caller.signature, "Same title \(a.id.uuidString.lowercased().prefix(8))")
        let other = try ChatSessionIdentity.verify(pid: 114, startedAt: 1140, tabs: [a, b], identity: { _, _ in true }, signatureVerifier: nativeSignature)
        XCTAssertNotEqual(other.signature, caller.signature)
        let alone = try ChatSessionIdentity.verify(pid: 14, startedAt: 140, tabs: [a], identity: { _, _ in true }, signatureVerifier: nativeSignature)
        XCTAssertEqual(alone.signature, "Same title")
    }

    func testNativeVerificationStillRefusesWrongTabStalePIDMissingAndNestedClaude() throws {
        let tab = nativeTab()
        func refused(_ tabs: [ChatSessionIdentity.Tab], as reason: ChatSessionIdentity.VerificationError,
                     identity: (Int32, UInt64) -> Bool = { _, _ in true },
                     signature: ChatClaudeProcess.SignatureVerifier = { $0 == 13 }) {
            XCTAssertThrowsError(try ChatSessionIdentity.verify(pid: 14, startedAt: 140, tabs: tabs, identity: identity, signatureVerifier: signature)) {
                XCTAssertEqual($0 as? ChatSessionIdentity.VerificationError, reason)
            }
        }
        refused([nativeTab(offset: 100)], as: .notInTab)
        refused([tab], as: .processUnavailable, identity: { $0 != 14 && $1 != 140 })
        refused([tab], as: .unrecognizedSignature, identity: { $0 != 13 && $1 != 130 })
        refused([tab], as: .unrecognizedSignature, signature: { _ in false })
        refused([tab, tab], as: .ambiguous)
        var nested = tab
        nested.processes[2] = .init(pid: 12, ppid: 11, name: "claude", isForeground: true, startedAtUs: 120)
        refused([nested], as: .ambiguous, signature: { $0 == 12 || $0 == 13 })
        var missing = tab
        missing.processes.removeAll { $0.pid == 13 }
        refused([missing], as: .unrecognizedSignature)
        var reused = tab
        reused.processes[4] = .init(pid: 14, ppid: 13, name: "agentpad-cli", isForeground: true, startedAtUs: 141)
        refused([reused], as: .notInTab)
    }

    func testSignatureVerificationRechecksProcessLifetimeAndFinalImage() {
        let tab = nativeTab()
        var alive = true
        XCTAssertNil(ChatSessionIdentity.resolve(pid: 14, startedAt: 140, tabs: [tab], identity: { _, _ in alive },
            signatureVerifier: { pid in
                guard pid == 13 else { return false }
                alive = false
                return true
            }))
        var checks = 0
        XCTAssertNil(ChatSessionIdentity.resolve(pid: 14, startedAt: 140, tabs: [tab], identity: { _, _ in true },
            signatureVerifier: { pid in
                guard pid == 13 else { return false }
                checks += 1
                return checks < 3 // image changes after candidate/name checks, before the decision
            }))
    }

    func testUnverifiableProcessGetsRestartAdviceWithoutReadingOrPosting() async throws {
        let f = try await ChatChannelExecutionTests.Fixture(root: root.appendingPathComponent("service"))
        fixture = f
        for tool in ["chat_channels", "chat_read", "chat_post"] {
            var request = AgentPadCLIRequest(verb: .team)
            request.teamAction = "chat"
            request.chatArguments = "{\"tool\":\"\(tool)\"}"
            for origin in [AgentPadCallerOrigin.outside, .localProcess(pid: 99_999_999, startedAtUs: 1)] {
                let reply = await ChatSessionTools.handle(request, origin: origin, sessions: { [] }, service: f.service)
                XCTAssertFalse(reply.ok)
                let json = try JSONDecoder().decode(ChatJSON.self, from: Data(XCTUnwrap(reply.chatResult).utf8))
                XCTAssertEqual(json["error"]?.string, "session_process_unavailable")
                XCTAssertTrue(json["message"]?.string?.contains("Restart Claude in this tab") == true)
            }
        }
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }
}
