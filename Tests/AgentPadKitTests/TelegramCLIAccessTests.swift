import XCTest
@testable import AgentPadHookKit
@testable import AgentPadKit
@testable import AgentPadTelegram

/// Synthetic Telegram data only; no account, connector or network.
@MainActor
final class TelegramCLIAccessTests: XCTestCase {
    private let secret = "TELEGRAM-PRIVATE-MARKER"
    private var stores: [WorkspaceStore] = []
    private var reveals = 0
    private var activations = 0

    override func tearDown() async throws {
        stores.forEach { $0.terminate() }
        stores = []
        try await super.tearDown()
    }

    private func store() -> WorkspaceStore {
        let store = makeTestStore()
        stores.append(store)
        return store
    }

    private func controller(personal: Bool = false) -> AgentPadCLIController {
        let controller = AgentPadCLIController(appVersion: "test", windows: {
            self.stores.enumerated().map { index, store in
                .init(store: store, isKey: index == 0, reveal: { _, _ in self.reveals += 1 })
            }
        }, fallbackWindow: { nil }, activateApp: { self.activations += 1 }, templates: { [.terminal] },
        resume: { _, _, _, _, completion in completion(.opened) })
        controller.displayTitleAccess = { _, sessions in
            // Even identity/title inspection only receives exportable tabs.
            XCTAssertTrue(sessions.allSatisfy(CLIListAccess.allowsSession))
            return personal
        }
        return controller
    }

    private func respond(_ controller: AgentPadCLIController, _ request: AgentPadCLIRequest,
                         origin: AgentPadCallerOrigin = .outside) async -> AgentPadCLIResponse {
        await withCheckedContinuation { continuation in
            controller.handle(request, origin: origin) { continuation.resume(returning: $0) }
        }
    }

    private var origins: [AgentPadCallerOrigin] {
        [.outside, .localProcess(pid: 99_999_980, startedAtUs: 100),
         .teamRun(callId: "run"), .teamRun(callId: nil)]
    }

    private func privateTabs(in store: WorkspaceStore) -> [Session] {
        let id = TelegramChatID(environment: .test, account: 42, chat: 202)
        let chat = store.openToolTab(.telegram(id))
        chat.tabState?.telegramRow = .init(id: id, title: secret + " chat", username: secret + " username", kind: .forum,
            unreadCount: 5, unreadMentionCount: 2, inMain: true, inArchive: false, pinned: true, hidden: false,
            lastMessageDate: 100, knownRelevant: true)
        let topic = store.openToolTab(.telegram(id.withTopic(.forum(7))))
        topic.tabState?.telegramRow = chat.tabState?.telegramRow
        topic.tabState?.telegramTopicTitle = secret + " topic"
        // An unopened/restored destination has no fetched metadata yet.
        let unloaded = store.openToolTab(.telegram(.init(environment: .production, account: 43, chat: 303)))
        let search = store.openToolTab(.search)
        let notifications = store.openToolTab(.notifications)
        let settings = store.openToolTab(.settings, navigation: .init(settingsSection: .telegram))
        let tabs = [chat, topic, unloaded, search, notifications, settings]
        for tab in tabs {
            tab.tabState?.message = secret + " notification / preview / attention reason"
        }
        return tabs
    }

    private func assertPrivate(_ text: String, tabs: [Session], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains(secret), text, file: file, line: line)
        for tab in tabs {
            XCTAssertFalse(text.lowercased().contains(tab.id.uuidString.lowercased()), text, file: file, line: line)
        }
    }

    private func assertPrivate(_ response: AgentPadCLIResponse, tabs: [Session], file: StaticString = #filePath, line: UInt = #line) throws {
        assertPrivate(String(decoding: try XCTUnwrap(response.encodedLine()), as: UTF8.self), tabs: tabs, file: file, line: line)
    }

    func testListAllFormatsExcludeTelegramForPersonalExecutorAndTeamCallers() async throws {
        let first = store(), terminal = try XCTUnwrap(first.active?.activeSession)
        terminal.terminalTitle = "Visible terminal title"
        let hidden = privateTabs(in: first)
        let second = store()
        let onlyPrivate = second.addEmptyWorkspace()
        let moreHidden = privateTabs(in: second)
        let tabs = hidden + moreHidden
        for source in SearchSource.allCases {
            first.search.source = source
            for personal in [true, false] {
                let controller = controller(personal: personal)
                for origin in origins {
                    let response = await respond(controller, .init(verb: .list), origin: origin)
                    XCTAssertTrue(response.ok)
                    let windows = try XCTUnwrap(response.windows)
                    XCTAssertEqual(windows.count, 2)
                    let listed = windows.flatMap(\.workspaces).flatMap(\.tabs)
                    XCTAssertEqual(Set(listed.map(\.id)), Set([terminal.id.uuidString, second.workspaces[0].activeSession!.id.uuidString]))
                    XCTAssertEqual(listed.first?.title, personal ? terminal.title : terminal.publicName)
                    XCTAssertTrue(try XCTUnwrap(windows[1].workspaces.first { $0.id == onlyPrivate.id.uuidString }).tabs.isEmpty)
                    try assertPrivate(response, tabs: tabs)
                    assertPrivate(AgentPadHookKit.renderCLIList(windows), tabs: tabs)
                    assertPrivate(AgentPadHookKit.renderCLIListJSON(windows), tabs: tabs)
                }
            }
        }
    }

    func testListDoesNotInheritHiddenActiveTabMetadataThroughWorkspaceTitle() async throws {
        let store = store(), hidden = privateTabs(in: store)
        let workspace = try XCTUnwrap(store.active)
        // Workspace.title can inherit terminalTitle independently of content.
        workspace.activeSession?.terminalTitle = secret + " aggregate title"
        let response = await respond(controller(personal: true), .init(verb: .list))
        try assertPrivate(response, tabs: hidden)
        workspace.customTitle = "Explicit workspace name"
        let named = await respond(controller(), .init(verb: .list))
        XCTAssertEqual(named.windows?.first?.workspaces.first?.title, "Explicit workspace name")
    }

    func testListRechecksContentAfterAwaitingPersonalTitleAccess() async throws {
        let store = store(), tab = try XCTUnwrap(store.active?.activeSession)
        let controller = controller(personal: true)
        controller.displayTitleAccess = { _, _ in
            await Task.yield()
            tab.content = .tool(.telegram(.init(environment: .test, account: 42, chat: 202)))
            tab.terminalTitle = self.secret
            return true
        }
        let response = await respond(controller, .init(verb: .list))
        XCTAssertTrue(response.ok)
        XCTAssertTrue(try XCTUnwrap(response.windows?.first?.workspaces.first).tabs.isEmpty)
        try assertPrivate(response, tabs: [tab])
    }

    private func assertUnaddressable(_ verb: AgentPadCLIVerb) async throws {
        let store = store(), hidden = privateTabs(in: store), controller = controller(personal: true)
        let before = store.allSessions.map(\.id)
        for origin in origins {
            let missing = await respond(controller, .init(verb: verb, tab: UUID().uuidString, title: "new title"), origin: origin)
            for tab in hidden {
                let response = await respond(controller, .init(verb: verb, tab: tab.id.uuidString, title: "new title"), origin: origin)
                XCTAssertFalse(response.ok)
                XCTAssertEqual(response, missing, "A hidden tab must be indistinguishable from an unknown tab")
                try assertPrivate(response, tabs: hidden)
                XCTAssertNil(tab.explicitName)
            }
        }
        XCTAssertEqual(store.allSessions.map(\.id), before)
        XCTAssertEqual(reveals, 0)
        XCTAssertEqual(activations, 0)
    }

    func testFocusCannotAddressTelegramSurfaces() async throws { try await assertUnaddressable(.focus) }
    func testCloseCannotAddressTelegramSurfaces() async throws { try await assertUnaddressable(.close) }
    func testRenameCannotAddressTelegramSurfaces() async throws { try await assertUnaddressable(.rename) }

    func testStatusDoesNotDescribeTelegramSurfaces() async throws {
        let hidden = privateTabs(in: store())
        let response = await respond(controller(), .init(verb: .status))
        XCTAssertTrue(response.ok)
        XCTAssertNil(response.windows)
        try assertPrivate(response, tabs: hidden)
    }

    func testOpenReturnsOnlyTheNewTerminalID() async throws {
        let store = store(), hidden = privateTabs(in: store)
        let response = await respond(controller(), .init(verb: .open, noFocus: true))
        XCTAssertTrue(response.ok, response.error ?? "")
        let opened = try XCTUnwrap(store.allSessions.first { $0.id.uuidString == response.tabId })
        XCTAssertTrue(opened.hasProcess)
        try assertPrivate(response, tabs: hidden)
    }

    func testResumeCannotSelectTelegramAsAnAgent() async throws {
        let hidden = privateTabs(in: store())
        let response = await respond(controller(), .init(verb: .resume, agent: "telegram", conversationId: UUID().uuidString))
        XCTAssertFalse(response.ok)
        try assertPrivate(response, tabs: hidden)
        XCTAssertEqual(activations, 0)
    }

    func testHookSocketListUsesTheSameBoundary() async throws {
        let hidden = privateTabs(in: store()), controller = controller(personal: true)
        let path = NSTemporaryDirectory() + "tg-cli-\(UUID().uuidString.prefix(8)).sock"
        let server = HookServer(socketPath: path, handler: { _ in XCTFail("Not a hook event") })
        server.onCLIRequest = { request, origin, waiting, completion in
            controller.handle(request, origin: origin, isCallerWaiting: waiting, completion: completion)
        }
        server.start()
        defer { server.stop() }
        let line = try XCTUnwrap(AgentPadCLIRequest(verb: .list).encodedLine())
        let bytes = try await Task.detached {
            try AgentPadCLITransport.roundTrip(line: line, socketPath: path, timeout: 5).get()
        }.value
        let response = try XCTUnwrap(AgentPadCLIResponse.decode(from: bytes))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.windows?.first?.workspaces.first?.tabs.count, 1)
        assertPrivate(String(decoding: bytes, as: UTF8.self), tabs: hidden)
    }

    func testShellCommandHookCannotReadTelegramSurfaces() throws {
        let store = store(), hidden = privateTabs(in: store)
        for tab in hidden {
            XCTAssertNil(store.takeShellCommand(sessionId: tab.id, shellPID: 123))
        }
    }

    private func assertMCPRejectsTelegram(_ tool: String) async throws {
        let store = store(), terminal = try XCTUnwrap(store.active?.activeSession)
        let hidden = privateTabs(in: store), processes = AnswerProcessFixture()
        terminal.agent = .claudeCode
        (terminal.engine as? TestEngine)?.foregroundPid = AnswerProcessFixture.claude
        let arguments: [String: Any] = tool == "chat_channels" ? ["scope": "telegram"] : [
            "org_id": UUID().uuidString, "kind": "telegram", "channel_id": hidden[0].id.uuidString,
        ].merging(tool == "chat_post" ? ["text": secret] : [:]) { _, new in new }
        // Check the MCP frontend with a verified caller. Telegram is not a
        // channel/DM scope, and argument errors must not echo IDs or text.
        let mcp = AgentPadTeamMCPServer(cwd: "/tmp", version: "test", send: { request, _, _ in
            XCTAssertEqual(request.teamAction, AgentPadCLITeamAction.verifyCaller.rawValue)
            return .success(.init(ok: true))
        }, write: { _ in })
        let (text, isError) = mcp.callTool(tool, arguments: arguments, requestKey: "test", progressToken: nil)
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("invalid_args"))
        assertPrivate(text, tabs: hidden)

        // A raw socket request cannot bypass that validation either. Verify
        // an actual synthetic personal terminal, with Telegram tabs alongside.
        var request = AgentPadCLIRequest(verb: .team)
        request.teamAction = AgentPadCLITeamAction.chat.rawValue
        var payload = arguments; payload["tool"] = tool
        request.chatArguments = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let response = await ChatSessionTools.handle(request,
            origin: .localProcess(pid: AnswerProcessFixture.hook, startedAtUs: 100),
            sessions: { store.allSessions }, signatureVerifier: processes.inspector.signed,
            scan: processes.inspector.scan, kernel: processes.inspector.kernel)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "invalid_args")
        try assertPrivate(response, tabs: hidden)
    }

    func testMCPChatChannelsRejectsTelegramScope() async throws { try await assertMCPRejectsTelegram("chat_channels") }
    func testMCPChatReadRejectsTelegramKind() async throws { try await assertMCPRejectsTelegram("chat_read") }
    func testMCPChatPostRejectsTelegramKind() async throws { try await assertMCPRejectsTelegram("chat_post") }

    func testMCPVerifyCallerCannotBorrowTelegramSurfaces() async throws {
        let hidden = privateTabs(in: store()), processes = AnswerProcessFixture()
        var request = AgentPadCLIRequest(verb: .team)
        request.teamAction = AgentPadCLITeamAction.verifyCaller.rawValue
        let response = await ChatSessionTools.handle(request,
            origin: .localProcess(pid: AnswerProcessFixture.hook, startedAtUs: 100),
            sessions: { hidden }, signatureVerifier: processes.inspector.signed,
            scan: processes.inspector.scan, kernel: processes.inspector.kernel)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "session_not_in_tab")
        try assertPrivate(response, tabs: hidden)
    }
}
