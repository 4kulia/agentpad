import AgentPadHookKit
import XCTest
@testable import AgentPadKit

/// Kernel/signature boundary only; journals, sockets and stores stay isolated.
final class AnswerProcessFixture: @unchecked Sendable {
    static let shell: Int32 = 99_999_970, claude: Int32 = 99_999_971, hook: Int32 = 99_999_972
    private let lock = NSLock()
    private var processes: [Int32: ChatSessionIdentity.Process] = [:]
    private var images: [Int32: ChatClaudeProcess.ImageIdentity] = [:]
    private var foreground: [Int32: Bool] = [:]
    private var signed: Set<Int32> = [claude]

    init() {
        add(Self.shell, parent: 1, name: "zsh", foreground: false)
        add(Self.claude, parent: Self.shell, name: "claude")
        add(Self.hook, parent: Self.claude, name: "agentpad-hook")
    }

    func add(_ pid: Int32, parent: Int32, name: String, trusted: Bool = false, start: UInt64 = 100,
             foreground: Bool = true, terminal: Int32? = 42) {
        lock.withLock {
            processes[pid] = .init(pid: pid, parent: parent, startedAtUs: start, terminal: terminal)
            self.foreground[pid] = foreground
            images[pid] = .init(path: "/fixture/\(name)", device: 1, inode: UInt64(pid), size: 10,
                modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0, auditToken: nil)
            if trusted { signed.insert(pid) }
        }
    }

    func remove(_ pid: Int32) { lock.withLock { _ = processes.removeValue(forKey: pid) } }

    var inspector: AgentAnswerProvenance.Inspector {
        .init(kernel: .init(process: { pid in self.lock.withLock { self.processes[pid] } },
                           image: { pid in self.lock.withLock { self.images[pid] } }),
              scan: { _ in self.lock.withLock { self.processes.values.map {
                  .init(pid: $0.pid, ppid: $0.parent, name: "fixture", isForeground: self.foreground[$0.pid] == true, startedAtUs: $0.startedAtUs)
              } } }, signed: { pid in self.lock.withLock { self.signed.contains(pid) } })
    }

    func capture(parent: Int32? = claude, origin: AgentPadCallerOrigin = .localProcess(pid: hook, startedAtUs: 100)) -> AgentAnswerProvenance? {
        AgentAnswerProvenance.capture(parentPID: parent, origin: origin, inspector: inspector)
    }

    @MainActor
    func bind(_ session: Session, conversation: String) throws {
        (session.engine as? TestEngine)?.foregroundPid = Self.claude
        AgentAnswerSource.recordHook(conversation: conversation, session: session,
            provenance: try XCTUnwrap(capture()), inspector: inspector)
        XCTAssertNotNil(session.answerBinding)
    }
}

@MainActor
final class AgentAnswerProvenanceTests: XCTestCase {
    func testHookRequiresKernelPeerParentAndStartNotAClaimedForegroundPID() throws {
        let fixture = AnswerProcessFixture()
        XCTAssertNotNil(fixture.capture())
        XCTAssertNil(fixture.capture(parent: nil))
        XCTAssertNil(fixture.capture(parent: 0))
        XCTAssertNil(fixture.capture(parent: AnswerProcessFixture.shell))
        XCTAssertNil(fixture.capture(origin: .outside))
        XCTAssertNil(fixture.capture(origin: .teamRun(callId: nil)))
        XCTAssertNil(fixture.capture(origin: .localProcess(pid: AnswerProcessFixture.hook, startedAtUs: 101)))
        fixture.add(AnswerProcessFixture.hook, parent: AnswerProcessFixture.shell, name: "agentpad-hook")
        XCTAssertNil(fixture.capture(), "a sender cannot just claim the tab's Claude PID")
    }

    func testShellWithoutClaudeAncestorAndUnsignedClaudeAreNotProof() {
        let fixture = AnswerProcessFixture()
        fixture.remove(AnswerProcessFixture.claude)
        fixture.add(AnswerProcessFixture.hook, parent: AnswerProcessFixture.shell, name: "agentpad-hook")
        XCTAssertNil(fixture.capture(parent: AnswerProcessFixture.shell), "a shell alone is not Claude")
        let unsigned: Int32 = 99_999_974
        fixture.add(unsigned, parent: AnswerProcessFixture.shell, name: "claude")
        fixture.add(AnswerProcessFixture.hook, parent: unsigned, name: "agentpad-hook")
        XCTAssertNil(fixture.capture(parent: unsigned), "a name is not Claude's signature")
    }

    func testShellHookAndLaunchWrapperWithMCPNodesBindOnlyAfterFreshHook() async throws {
        let store = makeTestStore(), fixture = AnswerProcessFixture()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession)
        tab.agent = .claudeCode
        let wrapper: Int32 = 99_999_975, hookShell: Int32 = 99_999_976
        fixture.add(wrapper, parent: AnswerProcessFixture.shell, name: "bash")
        fixture.add(AnswerProcessFixture.claude, parent: wrapper, name: "claude")
        fixture.add(hookShell, parent: AnswerProcessFixture.claude, name: "sh")
        fixture.add(AnswerProcessFixture.hook, parent: hookShell, name: "agentpad-hook")
        fixture.add(99_999_977, parent: AnswerProcessFixture.claude, name: "npm")
        fixture.add(99_999_978, parent: 99_999_977, name: "node")
        (tab.engine as? TestEngine)?.foregroundPid = wrapper
        let id = UUID().uuidString.lowercased()
        tab.conversationId = id
        tab.resumedConversationId = id
        XCTAssertEqual(AgentAnswerSource.problem(tab, inspector: fixture.inspector), .unbound)
        let evidence = try XCTUnwrap(fixture.capture(parent: hookShell))
        XCTAssertEqual(evidence.process.pid, AnswerProcessFixture.claude)
        AgentAnswerSource.recordHook(conversation: id, session: tab, provenance: evidence, inspector: fixture.inspector)
        XCTAssertNil(AgentAnswerSource.problem(tab, inspector: fixture.inspector))
        fixture.remove(AnswerProcessFixture.hook)
        fixture.remove(hookShell)
        let answer = try await AgentAnswerSource.read(session: tab, store: store, inspector: fixture.inspector) { _, journal, _ in
            XCTAssertEqual(journal, id)
            return "This tab's answer"
        }
        XCTAssertEqual(answer.text, "This tab's answer")
        XCTAssertTrue(answer.isCurrent())
        fixture.add(wrapper, parent: AnswerProcessFixture.shell, name: "bash", foreground: false)
        XCTAssertFalse(answer.isCurrent(), "losing the foreground group revokes the binding")
    }

    func testIntermediaryCannotBorrowUnrelatedOrRuntimeClaudeIdentity() throws {
        for name in ["node", "nodejs", "tmux", "screen", "zellij", "claude"] {
            let fixture = AnswerProcessFixture(), intermediary: Int32 = 99_999_975
            fixture.add(intermediary, parent: AnswerProcessFixture.claude, name: name)
            fixture.add(AnswerProcessFixture.hook, parent: intermediary, name: "agentpad-hook")
            XCTAssertNil(fixture.capture(parent: intermediary), name)
        }
        let fixture = AnswerProcessFixture(), hookShell: Int32 = 99_999_975
        fixture.add(hookShell, parent: AnswerProcessFixture.shell, name: "sh")
        fixture.add(AnswerProcessFixture.hook, parent: hookShell, name: "agentpad-hook")
        XCTAssertNil(fixture.capture(parent: hookShell), "same TTY and one Claude do not prove ancestry")
        fixture.add(hookShell, parent: AnswerProcessFixture.claude, name: "sh", terminal: 43)
        XCTAssertNil(fixture.capture(parent: hookShell), "every link must belong to the tab's TTY")
        fixture.add(hookShell, parent: hookShell, name: "sh")
        XCTAssertNil(fixture.capture(parent: hookShell), "cycles refuse without hanging")
    }

    func testForegroundMustBeClaudeOrItsForegroundShellAncestorAndNeverMultiplexer() throws {
        let store = makeTestStore(), fixture = AnswerProcessFixture()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession)
        tab.agent = .claudeCode
        let other: Int32 = 99_999_975
        fixture.add(other, parent: AnswerProcessFixture.shell, name: "bash")
        (tab.engine as? TestEngine)?.foregroundPid = other
        AgentAnswerSource.recordHook(conversation: UUID().uuidString, session: tab,
            provenance: fixture.capture(), inspector: fixture.inspector)
        XCTAssertNil(tab.answerBinding, "a foreground shell sibling is not the launch wrapper")
        for name in ["tmux", "screen", "zellij"] {
            fixture.add(other, parent: AnswerProcessFixture.shell, name: name)
            fixture.add(AnswerProcessFixture.claude, parent: other, name: "claude")
            XCTAssertNil(fixture.capture(), name)
        }
    }

    func testNestedAndRenamedSignedClaudeRefuseEvenWithOrdinaryHookShell() {
        for name in ["claude", "2.1.999"] {
            let fixture = AnswerProcessFixture(), second: Int32 = 99_999_975, hookShell: Int32 = 99_999_976
            fixture.add(second, parent: AnswerProcessFixture.claude, name: name, trusted: true)
            fixture.add(hookShell, parent: second, name: "sh")
            fixture.add(AnswerProcessFixture.hook, parent: hookShell, name: "agentpad-hook")
            XCTAssertNil(fixture.capture(parent: hookShell), name)
        }
    }

    func testMultipleClaudeIncludingRenamedAndNodeRuntimeRefuse() {
        for (name, signed) in [("claude", true), ("2.1.999", true), ("claude", false), ("node", false)] {
            let fixture = AnswerProcessFixture()
            fixture.add(99_999_973, parent: AnswerProcessFixture.shell, name: name, trusted: signed)
            XCTAssertNil(fixture.capture(), name)
        }
    }

    func testBackgroundClaudeCannotEstablishAnExportBinding() {
        let fixture = AnswerProcessFixture()
        fixture.add(AnswerProcessFixture.claude, parent: AnswerProcessFixture.shell, name: "claude", foreground: false)
        XCTAssertNil(fixture.capture())
    }

    func testTmuxSurfaceAndForeignHookCannotReplaceTheBoundJournal() throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession), fixture = AnswerProcessFixture()
        tab.agent = .claudeCode
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        try fixture.bind(tab, conversation: first)
        for foreground in [AnswerProcessFixture.shell, 99_999_973] {
            (tab.engine as? TestEngine)?.foregroundPid = foreground
            AgentAnswerSource.recordHook(conversation: second, session: tab, provenance: fixture.capture(), inspector: fixture.inspector)
            XCTAssertNil(tab.answerBinding, "tmux/shell or another pane's Claude cannot match the hook parent")
            XCTAssertNotNil(AgentAnswerSource.problem(tab, inspector: fixture.inspector)?.errorDescription)
            XCTAssertFalse(AgentAnswerWindow.available(tab))
        }
        try fixture.bind(tab, conversation: first)
        store.applyHookConversationId(conversationId: second, sessionId: tab.id)
        XCTAssertNil(tab.answerBinding, "legacy/unverified hooks clear prior trust, even for a stable foreground")
    }

    func testFreshProcessesExecAndPIDReuseInvalidateEvidenceButHookMayExit() throws {
        let fixture = AnswerProcessFixture(), evidence = try XCTUnwrap(fixture.capture())
        fixture.remove(AnswerProcessFixture.hook)
        XCTAssertTrue(evidence.isCurrent(inspector: fixture.inspector))
        fixture.add(99_999_973, parent: AnswerProcessFixture.claude, name: "helper")
        XCTAssertFalse(evidence.isCurrent(inspector: fixture.inspector), "new processes require a new hook, without guessing their role")
        fixture.remove(99_999_973)
        fixture.add(AnswerProcessFixture.shell, parent: 1, name: "other-image")
        XCTAssertFalse(evidence.isCurrent(inspector: fixture.inspector), "same PID/start after exec is insufficient")
        fixture.add(AnswerProcessFixture.shell, parent: 1, name: "zsh")
        fixture.add(AnswerProcessFixture.claude, parent: AnswerProcessFixture.shell, name: "claude", start: 101)
        XCTAssertFalse(evidence.isCurrent(inspector: fixture.inspector))
    }

    func testSocketCannotAuthenticatePayloadPIDWithoutAClaudeParent() async throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession)
        tab.agent = .claudeCode
        (tab.engine as? TestEngine)?.foregroundPid = ProcessInfo.processInfo.processIdentifier
        let path = NSTemporaryDirectory() + "answer-hook-\(UUID().uuidString.prefix(8)).sock"
        let received = expectation(description: "hook dispatched")
        let server = HookServer(socketPath: path) { message in
            guard case .conversationId(let id, let surface, let provenance) = message else { return }
            XCTAssertNil(provenance)
            store.applyHookConversationId(conversationId: id, sessionId: surface, provenance: provenance)
            received.fulfill()
        }
        server.start()
        defer { server.stop() }
        let payload = AgentPadHookKit.buildConversationIdPayload(surface: tab.id.uuidString,
            conversationId: UUID().uuidString, claudeParentPID: ProcessInfo.processInfo.processIdentifier)
        let sent = await Task.detached { AgentPadHookKit.sendPayload(payload, to: path) }.value
        XCTAssertTrue(sent)
        await fulfillment(of: [received], timeout: 3)
        XCTAssertNil(tab.answerBinding)
        XCTAssertFalse(AgentAnswerWindow.available(tab))
    }

    func testSocketPreservesVerifiedParentWithJournalAndChecksSignaturesOffMain() async throws {
        let store = makeTestStore(), fixture = AnswerProcessFixture()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession)
        tab.agent = .claudeCode
        let wrapper: Int32 = 99_999_975, hookShell: Int32 = 99_999_976
        fixture.add(wrapper, parent: AnswerProcessFixture.shell, name: "bash")
        fixture.add(AnswerProcessFixture.claude, parent: wrapper, name: "claude")
        fixture.add(hookShell, parent: AnswerProcessFixture.claude, name: "sh")
        fixture.add(AnswerProcessFixture.hook, parent: hookShell, name: "agentpad-hook")
        (tab.engine as? TestEngine)?.foregroundPid = wrapper
        let path = NSTemporaryDirectory() + "answer-proof-\(UUID().uuidString.prefix(8)).sock"
        let id = UUID().uuidString.lowercased()
        let received = expectation(description: "verified hook dispatched")
        var inspector = fixture.inspector
        let signature = inspector.signed
        inspector.signed = { pid in
            XCTAssertFalse(Thread.isMainThread, "SecCode checks must stay off the UI thread")
            return signature(pid)
        }
        let server = HookServer(socketPath: path, answerInspector: inspector) { message in
            guard case .conversationId(let journal, let surface, let provenance) = message else { return }
            XCTAssertEqual(surface, tab.id)
            XCTAssertEqual(journal, id)
            XCTAssertEqual(provenance?.process.pid, AnswerProcessFixture.claude)
            AgentAnswerSource.recordHook(conversation: journal, session: tab, provenance: provenance, inspector: fixture.inspector)
            received.fulfill()
        }
        server.originOf = { _ in .localProcess(pid: AnswerProcessFixture.hook, startedAtUs: 100) }
        server.start()
        defer { server.stop() }
        let payload = AgentPadHookKit.buildConversationIdPayload(surface: tab.id.uuidString,
            conversationId: id, claudeParentPID: hookShell)
        let sent = await Task.detached { AgentPadHookKit.sendPayload(payload, to: path) }.value
        XCTAssertTrue(sent)
        await fulfillment(of: [received], timeout: 3)
        XCTAssertEqual(tab.answerBinding?.conversation, id)
        XCTAssertNil(AgentAnswerSource.problem(tab, inspector: fixture.inspector))
    }

    func testImageChangeDuringSignatureCheckCannotProduceEvidence() {
        let fixture = AnswerProcessFixture()
        var inspector = fixture.inspector
        let signature = inspector.signed
        inspector.signed = { pid in
            if pid == AnswerProcessFixture.claude {
                fixture.add(pid, parent: AnswerProcessFixture.shell, name: "replaced-image")
            }
            return signature(pid)
        }
        XCTAssertNil(AgentAnswerProvenance.capture(parentPID: AnswerProcessFixture.claude,
            origin: .localProcess(pid: AnswerProcessFixture.hook, startedAtUs: 100), inspector: inspector))
    }
}
