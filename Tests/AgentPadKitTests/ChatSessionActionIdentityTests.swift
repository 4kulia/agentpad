import AgentPadHookKit
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatSessionActionIdentityTests: XCTestCase {
    private var root: URL!
    private var fixtures: [ChatChannelExecutionTests.Fixture] = []
    private let channel = "f5000000-0000-4000-8000-000000000001"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-action-identity-\(UUID())")
        ChatNotifications.badgeChanged = {}
    }

    override func tearDown() async throws {
        for f in fixtures { f.sender?.hold(); await f.service.disconnect() }
        fixtures = []
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }

    /// Deterministic kernel boundary: no need to wait for the OS to recycle a
    /// particular PID, and no real profile, credentials or Claude process.
    private final class KernelTable: @unchecked Sendable {
        static let shell: Int32 = 99_999_980, claude: Int32 = 99_999_981, peer: Int32 = 99_999_982
        let lock = NSLock()
        var processes: [Int32: ChatSessionIdentity.Process] = [
            shell: .init(pid: shell, parent: 1, startedAtUs: 100, terminal: 42),
            claude: .init(pid: claude, parent: shell, startedAtUs: 200, terminal: 42),
            peer: .init(pid: peer, parent: claude, startedAtUs: 300, terminal: 42)]
        var images: [Int32: ChatClaudeProcess.ImageIdentity] = [:]
        var signatureCalls: [Int32: Int] = [:]

        init() {
            for pid in [Self.shell, Self.claude, Self.peer] { images[pid] = Self.image(inode: UInt64(pid)) }
        }

        static func image(inode: UInt64, device: Int32 = 1, changed: Int64 = 1) -> ChatClaudeProcess.ImageIdentity {
            .init(path: "/fixture/claude", device: device, inode: inode, size: 123,
                  modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: changed, changedNanoseconds: 0, auditToken: nil)
        }

        var kernel: ChatSessionIdentity.Kernel {
            .init(process: { pid in self.lock.withLock { self.processes[pid] } },
                  image: { pid in self.lock.withLock { self.images[pid] } })
        }

        func scan(_ foreground: Int32) -> [SessionProcessScanner.Raw] {
            XCTAssertFalse(Thread.isMainThread, "full scans stay off-main")
            return lock.withLock { processes.values.map {
                .init(pid: $0.pid, ppid: $0.parent, name: "fixture", isForeground: true, startedAtUs: $0.startedAtUs)
            } }
        }

        func signature(_ pid: Int32) -> Bool {
            XCTAssertFalse(Thread.isMainThread, "Security APIs stay off-main")
            lock.withLock { signatureCalls[pid, default: 0] += 1 }
            return pid == Self.claude
        }

        func replace(_ pid: Int32, start: UInt64? = nil, parent: Int32? = nil, terminal: Int32? = nil) {
            lock.withLock {
                guard let old = processes[pid] else { return }
                processes[pid] = .init(pid: pid, parent: parent ?? old.parent,
                                      startedAtUs: start ?? old.startedAtUs, terminal: terminal ?? old.terminal)
            }
        }
    }

    private func fixture() async throws -> ChatChannelExecutionTests.Fixture {
        let f = try await ChatChannelExecutionTests.Fixture(root: root.appendingPathComponent(UUID().uuidString))
        fixtures.append(f)
        f.service.serverCapabilities[f.key.server] = ["chat.session_tools"]
        f.service.isServerKnown = { _, _ in true }
        return f
    }

    private func tab() -> Session {
        let engine = TestEngine()
        engine.foregroundPid = KernelTable.claude
        return Session(engine: engine, currentDirectory: root, agent: .terminal)
    }

    private func request(_ tool: String, org: String) throws -> AgentPadCLIRequest {
        var args: [String: ChatJSON] = ["tool": .string(tool), "org_id": .string(org)]
        if tool != "chat_channels" { args["channel_id"] = .string(channel) }
        if tool == "chat_post" { args["text"] = .string("must not be queued") }
        var request = AgentPadCLIRequest(verb: .team)
        request.teamAction = "chat"
        request.chatArguments = String(decoding: try JSONEncoder().encode(ChatJSON.object(args)), as: UTF8.self)
        return request
    }

    private func assertRefused(_ reply: AgentPadCLIResponse, fixture: ChatChannelExecutionTests.Fixture,
                               code: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(reply.ok, file: file, line: line)
        XCTAssertEqual(reply.error, code, file: file, line: line)
        let json = try JSONDecoder().decode(ChatJSON.self, from: Data(XCTUnwrap(reply.chatResult).utf8))
        XCTAssertTrue(json["message"]?.string?.localizedCaseInsensitiveContains("restart Claude") == true, file: file, line: line)
        XCTAssertNil(json["messages"], file: file, line: line)
        XCTAssertNil(json["channels"], file: file, line: line)
        XCTAssertTrue(try fixture.store.outbox.commands().isEmpty, file: file, line: line)
        XCTAssertEqual(try fixture.store.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM session_posts") }, 0, file: file, line: line)
    }

    func testClaudeExitOrPIDReuseDuringAwaitCannotReadOrQueueWithLiveDescendant() async throws {
        for tool in ["chat_channels", "chat_read", "chat_post"] {
            for reused in [false, true] {
                try await whileAwaiting(tool) { table, _ in
                    if reused { table.replace(KernelTable.claude, start: 201) }
                    else { table.lock.withLock { table.processes[KernelTable.claude] = nil } }
                    XCTAssertNotNil(table.kernel.process(KernelTable.peer), "the socket caller is still alive")
                }
            }
        }
    }

    func testCallerAncestryTTYTabAndImageAreRecheckedAfterAwait() async throws {
        let changes: [(String, (KernelTable, Session) -> Void)] = [
            ("session_process_unavailable", { table, _ in table.replace(KernelTable.peer, start: 301) }),
            ("session_not_in_tab", { table, _ in table.replace(KernelTable.peer, parent: KernelTable.shell) }),
            ("session_not_in_tab", { table, _ in table.replace(KernelTable.peer, terminal: 43) }),
            ("session_not_in_tab", { table, _ in table.replace(KernelTable.claude, terminal: 43) }),
            ("session_not_in_tab", { _, tab in (tab.engine as? TestEngine)?.foregroundPid = nil }),
            ("session_image_changed", { table, _ in table.lock.withLock {
                table.images[KernelTable.claude] = KernelTable.image(inode: 777)
            } }),
            ("session_image_changed", { table, _ in table.lock.withLock {
                table.images[KernelTable.claude] = KernelTable.image(inode: UInt64(KernelTable.claude), device: 2)
            } }),
            ("session_image_changed", { table, _ in table.lock.withLock {
                table.images[KernelTable.claude] = KernelTable.image(inode: UInt64(KernelTable.claude), changed: 2)
            } }),
            // A shell cannot exec a nested Claude under a cached negative result.
            ("session_image_changed", { table, _ in table.lock.withLock {
                table.images[KernelTable.shell] = KernelTable.image(inode: 888)
            } })]
        for (code, change) in changes { try await whileAwaiting("chat_post", code: code, change: change) }
    }

    private func whileAwaiting(_ tool: String, code: String = "session_process_unavailable",
                               change: (KernelTable, Session) -> Void) async throws {
        let f = try await fixture(), table = KernelTable(), tab = tab(), gate = Gate()
        let entered = expectation(description: "HTTP awaited")
        gate.close(); defer { gate.open() }
        let body = tool == "chat_channels" ? #"{"channels":[],"next":null}"# : #"{"messages":[],"next":null,"head":0}"#
        ChatStubProtocol.reset { _, _ in
            entered.fulfill(); gate.pass()
            return .success(.init(status: 200, body: Data(body.utf8)))
        }
        let request = try request(tool, org: f.key.orgId)
        let task = Task {
            await ChatSessionTools.handle(request, origin: .localProcess(pid: KernelTable.peer, startedAtUs: 300),
                                          sessions: { [tab] }, service: f.service, isCallerWaiting: { true },
                                          signatureVerifier: table.signature, scan: table.scan, kernel: table.kernel)
        }
        await fulfillment(of: [entered], timeout: 3)
        let calls = table.lock.withLock { table.signatureCalls }
        change(table, tab)
        gate.open()
        let reply = await task.value
        try assertRefused(reply, fixture: f, code: code)
        XCTAssertEqual(table.lock.withLock { table.signatureCalls }, calls, "no background signature check between final guard and action")
    }

    func testCompletedBackgroundProofCannotAuthorizeBeforeFirstAction() async throws {
        let f = try await fixture(), table = KernelTable(), tab = tab()
        var captures = 0
        let reply = await ChatSessionTools.handle(try request("chat_channels", org: f.key.orgId),
            origin: .localProcess(pid: KernelTable.peer, startedAtUs: 300), sessions: {
                captures += 1
                if captures == 2 {
                    // The detached proof has completed, but its actor continuation
                    // now sees a reused Claude PID and the still-open original tab.
                    table.replace(KernelTable.claude, start: 201)
                }
                return [tab]
            }, service: f.service, signatureVerifier: table.signature, scan: table.scan, kernel: table.kernel)
        try assertRefused(reply, fixture: f, code: "session_process_unavailable")
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
    }

    func testStableProofCachesSignatureByImageAndKeepsReading() async throws {
        let f = try await fixture(), table = KernelTable(), tab = tab()
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8))) }
        let reply = await ChatSessionTools.handle(try request("chat_read", org: f.key.orgId),
            origin: .localProcess(pid: KernelTable.peer, startedAtUs: 300), sessions: { [tab] }, service: f.service,
            signatureVerifier: table.signature, scan: table.scan, kernel: table.kernel)
        XCTAssertTrue(reply.ok, reply.chatResult ?? "no result")
        XCTAssertEqual(table.lock.withLock { table.signatureCalls }, [KernelTable.shell: 1, KernelTable.claude: 1, KernelTable.peer: 1])
        XCTAssertEqual(ChatStubProtocol.seen.count, 1)
    }

    func testProofIsBoundToLiveTabTTYAndForegroundLifetime() async throws {
        let table = KernelTable(), tab = tab(), foreground: Int32 = 99_999_983
        table.processes[foreground] = .init(pid: foreground, parent: KernelTable.shell, startedAtUs: 400, terminal: 42)
        table.images[foreground] = KernelTable.image(inode: 1234)
        let engine = try XCTUnwrap(tab.engine as? TestEngine)
        engine.foregroundPid = foreground
        let verified = try await ChatSessionIdentity.verify(.localProcess(pid: KernelTable.peer, startedAtUs: 300),
            sessions: [tab], scan: table.scan, signatureVerifier: table.signature, kernel: table.kernel)
        try ChatSessionIdentity.revalidate(verified, sessions: [tab], kernel: table.kernel)
        let otherTab = self.tab()
        for tabs in [[], [otherTab], [tab, otherTab]] {
            XCTAssertThrowsError(try ChatSessionIdentity.revalidate(verified, sessions: tabs, kernel: table.kernel)) {
                XCTAssertEqual($0 as? ChatSessionIdentity.VerificationError, .notInTab)
            }
        }
        table.replace(foreground, start: 401)
        XCTAssertThrowsError(try ChatSessionIdentity.revalidate(verified, sessions: [tab], kernel: table.kernel)) {
            XCTAssertEqual($0 as? ChatSessionIdentity.VerificationError, .notInTab)
        }
        table.replace(foreground, start: 400, terminal: 43)
        XCTAssertThrowsError(try ChatSessionIdentity.revalidate(verified, sessions: [tab], kernel: table.kernel)) {
            XCTAssertEqual($0 as? ChatSessionIdentity.VerificationError, .notInTab)
        }
        engine.foregroundPid = KernelTable.claude
        try ChatSessionIdentity.revalidate(verified, sessions: [tab], kernel: table.kernel)
    }

    func testSignatureResultCannotBeBoundToAnImageChangedDuringVerification() async throws {
        let f = try await fixture(), table = KernelTable(), tab = tab()
        let reply = await ChatSessionTools.handle(try request("chat_channels", org: f.key.orgId),
            origin: .localProcess(pid: KernelTable.peer, startedAtUs: 300), sessions: { [tab] }, service: f.service,
            signatureVerifier: { pid in
                let trusted = table.signature(pid)
                if trusted { table.lock.withLock { table.images[pid] = KernelTable.image(inode: 999) } }
                return trusted
            }, scan: table.scan, kernel: table.kernel)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error, "unrecognized_claude_code_signature")
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }
}
