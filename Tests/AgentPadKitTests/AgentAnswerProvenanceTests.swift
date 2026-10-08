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
             foreground: Bool = true, terminal: Int32? = 42, path: String? = nil) {
        lock.withLock {
            processes[pid] = .init(pid: pid, parent: parent, startedAtUs: start, terminal: terminal)
            self.foreground[pid] = foreground
            images[pid] = .init(path: path ?? "/fixture/\(name)", device: 1, inode: UInt64(pid), size: 10,
                modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0, auditToken: nil)
            if trusted { signed.insert(pid) }
        }
    }

    func remove(_ pid: Int32) { lock.withLock { _ = processes.removeValue(forKey: pid) } }

    var inspector: AgentAnswerProvenance.Inspector {
        .init(kernel: .init(process: { pid in self.lock.withLock { self.processes[pid] } },
                           image: { pid in self.lock.withLock { self.images[pid] } }),
              scan: { pid in self.lock.withLock { self.processes.values.filter {
                  self.processes[pid]?.terminal != nil && $0.terminal == self.processes[pid]?.terminal
              }.map {
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
    func testResumedLoginZshAgentPadBashWrapperAndVersionedClaudeWithDetachedHook() async throws {
        let store = makeTestStore(), fixture = AnswerProcessFixture()
        defer { store.terminate() }
        for pid in [AnswerProcessFixture.shell, AnswerProcessFixture.claude, AnswerProcessFixture.hook] { fixture.remove(pid) }
        // The reported 1.1.6 tree, including exact PID/parent/group topology.
        // proc_pidpath resolves ~/.local/bin/claude to the versioned image;
        // the AgentPad script's kernel image is /bin/bash, not the script.
        fixture.add(45905, parent: 45872, name: "login", foreground: false, path: "/usr/bin/login")
        fixture.add(45908, parent: 45905, name: "zsh", foreground: false, path: "/bin/zsh")
        fixture.add(45936, parent: 45908, name: "bash", path: "/bin/bash")
        fixture.add(45968, parent: 45936, name: "2.1.292", trusted: true,
                    path: "/fixture/home/.local/share/claude/versions/2.1.292")
        fixture.add(46013, parent: 45968, name: "node")
        fixture.add(46050, parent: 46013, name: "node")
        fixture.add(46016, parent: 45968, name: "agentpad-cli")
        let tab = try XCTUnwrap(store.active?.activeSession)
        tab.agent = .claudeCode
        (tab.engine as? TestEngine)?.foregroundPid = 45936 // tpgid, shared with Claude
        let id = UUID().uuidString.lowercased()
        tab.conversationId = id
        tab.resumedConversationId = id // persisted --resume alone is never proof
        XCTAssertEqual(AgentAnswerSource.problem(tab, inspector: fixture.inspector), .unbound)
        for terminal: Int32? in [42, nil] {
            fixture.add(46080, parent: 45968, name: "zsh", foreground: terminal != nil, terminal: terminal)
            fixture.add(46081, parent: 46080, name: "agentpad-hook", foreground: terminal != nil, terminal: terminal)
            let proof = try XCTUnwrap(fixture.capture(parent: 46080, origin: .localProcess(pid: 46081, startedAtUs: 100)))
            AgentAnswerSource.recordHook(conversation: id, session: tab, provenance: proof, inspector: fixture.inspector)
            XCTAssertEqual(tab.answerBinding?.process.pid, 45968)
            XCTAssertNil(AgentAnswerSource.problem(tab, inspector: fixture.inspector))
            fixture.remove(46081); fixture.remove(46080)
            let answer = try await AgentAnswerSource.read(session: tab, store: store, inspector: fixture.inspector) { _, journal, _ in
                XCTAssertEqual(journal, id)
                return "Resumed Claude answer"
            }
            XCTAssertEqual(answer.text, "Resumed Claude answer")
            XCTAssertTrue(answer.isCurrent())
        }
    }

    func testDetachedHookStillRejectsForeignAncestryMultiplexersAndMultipleClaude() throws {
        let fixture = AnswerProcessFixture(), shell: Int32 = 99_999_976
        fixture.add(shell, parent: AnswerProcessFixture.claude, name: "sh", foreground: false, terminal: nil)
        fixture.add(AnswerProcessFixture.hook, parent: shell, name: "agentpad-hook", foreground: false, terminal: nil)
        XCTAssertNotNil(fixture.capture(parent: shell))
        for name in ["tmux", "screen", "node", "nodejs"] {
            fixture.add(shell, parent: AnswerProcessFixture.claude, name: name, foreground: false, terminal: nil)
            XCTAssertNil(fixture.capture(parent: shell), name)
        }
        fixture.add(shell, parent: AnswerProcessFixture.shell, name: "sh", foreground: false, terminal: nil)
        XCTAssertNil(fixture.capture(parent: shell), "same surface cannot replace the authenticated parent chain")
        fixture.add(shell, parent: AnswerProcessFixture.claude, name: "sh", foreground: false, terminal: nil)
        fixture.add(99_999_977, parent: AnswerProcessFixture.shell, name: "2.1.292", trusted: true)
        XCTAssertNil(fixture.capture(parent: shell), "another signed Claude on the TTY is still ambiguous")
    }

    func testSocketReportsConcreteFailureAndFreshProofClearsIt() async throws {
        let fixture = AnswerProcessFixture(), store = makeTestStore()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession), second: Int32 = 99_999_977
        tab.agent = .claudeCode
        fixture.add(second, parent: AnswerProcessFixture.shell, name: "2.1.292", trusted: true)
        let received = expectation(description: "refusal reason delivered with hook")
        let path = NSTemporaryDirectory() + "answer-reason-\(UUID().uuidString.prefix(8)).sock"
        let server = HookServer(socketPath: path, answerInspector: fixture.inspector) { message in
            guard case .conversationId(let journal, let surface, let proof, let failure) = message else { return }
            XCTAssertNil(proof)
            XCTAssertEqual(failure, .ambiguousClaude)
            store.applyHookConversationId(conversationId: journal, sessionId: surface, provenance: proof, failure: failure)
            XCTAssertEqual(AgentAnswerSource.problem(tab), .ambiguousClaude)
            XCTAssertFalse(CompositionTabs.available(tab))
            received.fulfill()
        }
        server.originOf = { _ in .localProcess(pid: AnswerProcessFixture.hook, startedAtUs: 100) }
        server.start()
        defer { server.stop() }
        let id = UUID().uuidString.lowercased()
        let payload = AgentPadHookKit.buildConversationIdPayload(surface: tab.id.uuidString,
            conversationId: id, claudeParentPID: AnswerProcessFixture.claude)
        let sent = await Task.detached { AgentPadHookKit.sendPayload(payload, to: path) }.value
        XCTAssertTrue(sent)
        await fulfillment(of: [received], timeout: 3)
        fixture.remove(second)
        try fixture.bind(tab, conversation: id)
        XCTAssertNil(tab.answerBindingProblem)
        XCTAssertNil(AgentAnswerSource.problem(tab, inspector: fixture.inspector))
    }

    func testDetachedHelpersMayExitButCannotReparentOrExecAfterVerification() throws {
        let fixture = AnswerProcessFixture(), shell: Int32 = 99_999_976
        fixture.add(shell, parent: AnswerProcessFixture.claude, name: "sh", foreground: false, terminal: nil)
        fixture.add(AnswerProcessFixture.hook, parent: shell, name: "agentpad-hook", foreground: false, terminal: nil)
        let proof = try XCTUnwrap(fixture.capture(parent: shell))
        fixture.add(shell, parent: 1, name: "sh", foreground: false, terminal: nil)
        XCTAssertFalse(proof.isCurrent(inspector: fixture.inspector))
        fixture.add(shell, parent: AnswerProcessFixture.claude, name: "node", foreground: false, terminal: nil)
        XCTAssertFalse(proof.isCurrent(inspector: fixture.inspector))
        fixture.add(shell, parent: AnswerProcessFixture.claude, name: "sh", foreground: false, terminal: nil)
        var inspector = fixture.inspector
        let image = inspector.kernel.image
        inspector.kernel.image = { pid in pid == AnswerProcessFixture.hook ? nil : image(pid) }
        XCTAssertFalse(proof.isCurrent(inspector: inspector), "an unreadable image of the same live helper still refuses")
        fixture.remove(shell)
        fixture.remove(AnswerProcessFixture.hook)
        XCTAssertTrue(proof.isCurrent(inspector: fixture.inspector))
    }

    func testDetachedHookExitDuringImageReadStillBindsAnswer() async throws {
        let store = makeTestStore(), fixture = AnswerProcessFixture()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession)
        tab.agent = .claudeCode
        fixture.add(AnswerProcessFixture.hook, parent: AnswerProcessFixture.claude,
                    name: "agentpad-hook", foreground: false, terminal: nil)
        try fixture.bind(tab, conversation: UUID().uuidString.lowercased())
        let proof = try XCTUnwrap(fixture.capture()), id = UUID().uuidString.lowercased()
        var inspector = fixture.inspector
        let image = inspector.kernel.image
        inspector.kernel.image = { pid in
            if pid == AnswerProcessFixture.hook {
                fixture.remove(pid) // ACK lets the helper exit after the process read.
                return nil
            }
            return image(pid)
        }
        AgentAnswerSource.recordHook(conversation: id, session: tab, provenance: proof, inspector: inspector)
        XCTAssertNil(fixture.inspector.kernel.process(AnswerProcessFixture.hook))
        XCTAssertEqual(tab.answerBinding?.conversation, id, "hook exit must not leave Copy/Forward unbound")
        XCTAssertNil(AgentAnswerSource.problem(tab, inspector: inspector))
        let answer = try await AgentAnswerSource.read(session: tab, store: store, inspector: inspector) { _, journal, _ in
            XCTAssertEqual(journal, id)
            return "This tab's answer"
        }
        XCTAssertEqual(answer.text, "This tab's answer")
        XCTAssertTrue(answer.isCurrent())
    }

    func testDetachedHookPIDReuseOutsideTerminalKeepsAnswerCurrent() async throws {
        let store = makeTestStore(), fixture = AnswerProcessFixture()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession)
        tab.agent = .claudeCode
        fixture.add(AnswerProcessFixture.hook, parent: AnswerProcessFixture.claude,
                    name: "agentpad-hook", foreground: false, terminal: nil)
        let id = UUID().uuidString.lowercased()
        try fixture.bind(tab, conversation: id)
        let answer = try await AgentAnswerSource.read(session: tab, store: store, inspector: fixture.inspector) { _, journal, _ in
            XCTAssertEqual(journal, id)
            return "Bound answer"
        }
        for terminal: Int32? in [nil, 43] {
            fixture.add(AnswerProcessFixture.hook, parent: 1, name: "unrelated", start: 101, terminal: terminal)
            XCTAssertTrue(answer.isCurrent(), "a new owner of the detached hook PID outside the tab cannot revoke export")
            XCTAssertNil(AgentAnswerSource.problem(tab, inspector: fixture.inspector))
            XCTAssertEqual(tab.answerBinding?.conversation, id)
        }
        fixture.add(AnswerProcessFixture.hook, parent: AnswerProcessFixture.shell, name: "claude", trusted: true, start: 101)
        XCTAssertFalse(answer.isCurrent(), "the reused PID on the tab's TTY still introduces ambiguity")
        XCTAssertEqual(AgentAnswerSource.problem(tab, inspector: fixture.inspector), .changed)
    }

    func testDetachedHookPIDReuseDuringImageReadKeepsEvidenceCurrent() throws {
        for imageUnavailable in [false, true] {
            let fixture = AnswerProcessFixture()
            fixture.add(AnswerProcessFixture.hook, parent: AnswerProcessFixture.claude,
                        name: "agentpad-hook", foreground: false, terminal: nil)
            let proof = try XCTUnwrap(fixture.capture())
            var inspector = fixture.inspector
            let image = inspector.kernel.image
            inspector.kernel.image = { pid in
                if pid == AnswerProcessFixture.hook {
                    fixture.add(pid, parent: 1, name: "unrelated", start: 101, terminal: 43)
                    if imageUnavailable { return nil }
                }
                return image(pid)
            }
            XCTAssertTrue(proof.isCurrent(inspector: inspector), "a different start time means the old helper exited")
            XCTAssertEqual(fixture.inspector.kernel.process(AnswerProcessFixture.hook)?.startedAtUs, 101)
            XCTAssertTrue(proof.matchesForeground(AnswerProcessFixture.claude, inspector: inspector))
        }
    }

    func testPeerPIDReuseBetweenAuthenticationAndAncestryCannotBorrowNewProcess() {
        let fixture = AnswerProcessFixture()
        var inspector = fixture.inspector
        let read = inspector.kernel.process
        inspector.kernel.process = { pid in
            let result = read(pid)
            if pid == AnswerProcessFixture.hook, result?.startedAtUs == 100 {
                fixture.add(pid, parent: AnswerProcessFixture.claude, name: "agentpad-hook", start: 101)
            }
            return result
        }
        XCTAssertNil(AgentAnswerProvenance.capture(parentPID: AnswerProcessFixture.claude,
            origin: .localProcess(pid: AnswerProcessFixture.hook, startedAtUs: 100), inspector: inspector))
    }

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
        XCTAssertEqual(AgentAnswerSource.problem(tab, inspector: fixture.inspector), .foregroundMismatch)
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
            XCTAssertFalse(CompositionTabs.available(tab))
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
        fixture.add(AnswerProcessFixture.claude, parent: AnswerProcessFixture.shell, name: "other-image")
        XCTAssertFalse(evidence.isCurrent(inspector: fixture.inspector), "Claude's image must still match after the hook exits")
        fixture.add(AnswerProcessFixture.claude, parent: AnswerProcessFixture.shell, name: "claude", foreground: false)
        XCTAssertFalse(evidence.isCurrent(inspector: fixture.inspector), "Claude must remain in the foreground")
        fixture.add(AnswerProcessFixture.claude, parent: AnswerProcessFixture.shell, name: "claude", start: 101)
        XCTAssertFalse(evidence.isCurrent(inspector: fixture.inspector))
        fixture.remove(AnswerProcessFixture.claude)
        XCTAssertFalse(evidence.isCurrent(inspector: fixture.inspector), "only helpers may exit without revoking the binding")
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
            guard case .conversationId(let id, let surface, let provenance, let failure) = message else { return }
            XCTAssertNil(provenance)
            store.applyHookConversationId(conversationId: id, sessionId: surface, provenance: provenance, failure: failure)
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
        XCTAssertFalse(CompositionTabs.available(tab))
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
            guard case .conversationId(let journal, let surface, let provenance, let failure) = message else { return }
            XCTAssertEqual(surface, tab.id)
            XCTAssertEqual(journal, id)
            XCTAssertEqual(provenance?.process.pid, AnswerProcessFixture.claude)
            AgentAnswerSource.recordHook(conversation: journal, session: tab, provenance: provenance, failure: failure, inspector: fixture.inspector)
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
