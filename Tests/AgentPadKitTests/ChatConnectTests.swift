import Foundation
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatConnectTests: XCTestCase {
    private var root: URL!
    private let account = "8c2b3b55-6b1e-4f5e-9a39-0e3c1f7a2d40"
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-connect-\(UUID().uuidString)")
        ChatStubProtocol.reset()
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        try? FileManager.default.removeItem(at: root)
    }

    private var files: ChatFiles { ChatFiles(directory: root) }

    private func org(_ id: String, name: String = "anna") -> String {
        #"{"org_id":"\#(id)","org_name":"Org \#(id.prefix(4))","role":"member","handle":"anna","name":"\#(name)"}"#
    }

    /// A server that signs in with `orgs`; `codeStatus` answers the sign-in.
    private func serve(orgs: [String], token: String = "aps_new", codeStatus: Int = 200, capabilities: String = #"["auth.email_code","events.ws"]"#) {
        let signIn = Data(#"{"token":"\#(token)","session_id":"s-new","account_id":"\#(account)","orgs":[\#(orgs.joined(separator: ","))]}"#.utf8)
        let info = Data(#"{"name":"agentpad-server","version":"0.1.0","generation":"g","api_versions":["v1"],"capabilities":\#(capabilities)}"#.utf8)
        ChatStubProtocol.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/server"): .success(.init(status: 200, body: info))
            case ("POST", "/v1/auth/code"): .success(.init(status: 202))
            case ("POST", "/v1/auth/session"):
                codeStatus == 200 ? .success(.init(status: 200, body: signIn))
                    : .success(.init(status: codeStatus, body: Data(#"{"error":"invalid_code"}"#.utf8)))
            case ("DELETE", "/v1/auth/session"): .success(.init(status: 204, body: Data()))
            default: .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8)))
            }
        }
    }

    private func model(_ tokens: FakeTokenStore = FakeTokenStore(), switched: Counter = Counter()) -> (ChatConnectModel, ChatService) {
        let service = ChatService(files: files, tokens: tokens)
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        // Like the app's move: the record is written once the move began.
        let model = ChatConnectModel(service: service) {
            try await service.keepSignIn()
            switched.increment()
        }
        model.teamWorkIdle = { true }
        model.serverText = "https://chat.example.com"
        model.email = "anna@example.com"
        return (model, service)
    }

    private func toCode(_ model: ChatConnectModel) async {
        await model.sendCode()
        XCTAssertEqual(model.step, .code, model.error ?? "")
        model.code = "12345678"
    }

    private func requests(_ method: String, _ path: String) -> [ChatStubProtocol.Seen] {
        ChatStubProtocol.seen.filter { $0.request.httpMethod == method && $0.request.url?.path == path }
    }

    func testNoOrganizationClosesTheSessionAndKeepsNothing() async throws {
        serve(orgs: [])
        let switched = Counter()
        let (model, service) = model(switched: switched)
        await toCode(model)
        await model.submitCode()
        XCTAssertEqual(model.step, .noOrganization)
        XCTAssertEqual(requests("DELETE", "/v1/auth/session").first?.request.value(forHTTPHeaderField: "Authorization"), "Bearer aps_new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.serversURL.path))
        XCTAssertNil(service.connection)
        XCTAssertEqual(switched.value, 0)
    }

    func testOneOrganizationIsChosenAndTheNameAsked() async throws {
        let id = UUID().uuidString.lowercased()
        serve(orgs: [org(id)])
        let switched = Counter()
        let (model, service) = model(switched: switched)
        await toCode(model)
        await model.submitCode()
        let key = ChatOrgKey(server: server, accountId: account, orgId: id)
        XCTAssertEqual(model.step, .name(key))
        XCTAssertEqual(switched.value, 1, "switchToServer after the sign-in")
        XCTAssertEqual(try files.loadConnections().first?.orgId, id)
        model.displayName = "Anna"
        await model.saveName()
        XCTAssertEqual(model.step, .done)
        let queued = try XCTUnwrap(try service.session(for: key).store?.commands().first)
        XCTAssertEqual(queued.type, "member.set_name")
    }

    func testANameAlreadySetIsNotAskedAgain() async throws {
        serve(orgs: [org(UUID().uuidString.lowercased(), name: "Anna K")])
        let (model, _) = model()
        await toCode(model)
        await model.submitCode()
        XCTAssertEqual(model.step, .done)
    }

    func testSeveralOrganizationsAreOfferedAndTheChoiceKept() async throws {
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased()
        serve(orgs: [org(a), org(b, name: "Anna")])
        let (model, _) = model()
        await toCode(model)
        await model.submitCode()
        guard case .chooseOrg(let offered) = model.step else { return XCTFail("\(model.step)") }
        XCTAssertEqual(offered.map(\.orgId), [a, b])
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.serversURL.path), "nothing kept before the choice")
        await model.choose(b)
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(try files.loadConnections().first?.orgId, b)
    }

    func testCodeCanBeSentAgainAfter30Seconds() async throws {
        serve(orgs: [])
        let (model, _) = model()
        var clock = Date()
        model.now = { clock }
        await toCode(model)
        XCTAssertFalse(model.canResend)
        await model.resendCode()
        XCTAssertEqual(requests("POST", "/v1/auth/code").count, 1)
        clock = clock.addingTimeInterval(30)
        XCTAssertTrue(model.canResend)
        await model.resendCode()
        XCTAssertEqual(requests("POST", "/v1/auth/code").count, 2)
        XCTAssertFalse(model.canResend)
    }

    func testWrongCodeKeepsTheStep() async throws {
        serve(orgs: [], codeStatus: 401)
        let (model, _) = model()
        await toCode(model)
        await model.submitCode()
        XCTAssertEqual(model.step, .code)
        XCTAssertEqual(model.error, "The code is wrong or has expired. Ask for a new one.")
    }

    func testLostAnswerKeepsTheCodeStep() async throws {
        serve(orgs: [])
        let (model, _) = model()
        await toCode(model)
        let info = Data(#"{"name":"s","version":"1","generation":"g","api_versions":["v1"],"capabilities":["auth.email_code"]}"#.utf8)
        ChatStubProtocol.reset { request, _ in
            request.url?.path == "/v1/server" ? .success(.init(status: 200, body: info)) : .failure(URLError(.networkConnectionLost))
        }
        await model.submitCode()
        XCTAssertEqual(model.step, .code)
        XCTAssertTrue(model.error?.contains("Ask for a new code") == true)
    }

    func testUnreachableAndUnsuitableServers() async throws {
        ChatStubProtocol.reset { _, _ in .failure(URLError(.cannotConnectToHost)) }
        let (model, _) = model()
        await model.sendCode()
        XCTAssertEqual(model.step, .address)
        XCTAssertEqual(model.error, "The server cannot be reached. Check the address and the network.")
        serve(orgs: [], capabilities: "[]")
        await model.sendCode()
        XCTAssertEqual(model.error, "This server's version does not fit this AgentPad.")
        model.serverText = "http://example.com"
        await model.sendCode()
        XCTAssertEqual(model.error, "The server address must start with https://.")
    }

    func testConnectionTabMoveCloseReopenAndRestartNeverKeepSecrets() async throws {
        let ui = root.appendingPathComponent("ui")
        let app = AppPersistence(fileURL: ui.appendingPathComponent("state-v2.json"))
        var stores: [WorkspaceStore] = []
        func makeStore(_ id: UUID) -> WorkspaceStore {
            WorkspaceStore(persistence: WindowPersistence(windowId: id, app: app), initiallyEmpty: true, engineFactory: {
                XCTFail("Connection allocated a terminal"); return TestEngine()
            }, peerStores: { stores })
        }
        let a = makeStore(UUID()), b = makeStore(UUID()); stores = [a, b]
        defer { stores.forEach { $0.terminate() } }
        let router = TabRouter(); router.stores = { stores }; router.ensureHost = { a }
        let navigation = SupportTabNavigation(router: router); navigation.finishStartup()
        let (model, service) = model()
        let tabs = ConnectionTabs(navigation: navigation, service: service)
        let tab = try XCTUnwrap(tabs.show()), state = try XCTUnwrap(tab.tabState)
        state.connectionForm = model
        let token = "aps_TRANSIENT_SECRET", code = "87654321"
        serve(orgs: [org("org-a"), org("org-b")], token: token)
        await toCode(model); model.code = code
        XCTAssertTrue(a.flushPersistence())
        XCTAssertTrue(tabs.show() === tab)
        XCTAssertTrue(tabs.model(state) === model)
        XCTAssertTrue(b.handleTabDrop(droppedId: tab.id, in: b.active!))
        XCTAssertTrue(tabs.show() === tab)
        XCTAssertTrue(tabs.model(state) === model)
        XCTAssertEqual(model.code, code)
        await model.submitCode()
        XCTAssertEqual(model.code, "")
        XCTAssertNil(state.draft)
        XCTAssertTrue(b.flushPersistence())
        let restartedApp = AppPersistence(fileURL: ui.appendingPathComponent("state-v2.json"))
        let restored = WorkspaceStore(persistence: WindowPersistence(windowId: b.windowID, app: restartedApp), initiallyEmpty: true,
            engineFactory: { XCTFail("restored login started a process"); return TestEngine() })
        defer { restored.terminate() }
        let restoredState = try XCTUnwrap(restored.allSessions.first?.tabState)
        XCTAssertEqual(tabs.model(restoredState).step, .address)
        XCTAssertEqual(tabs.model(restoredState).code, "")
        b.closeTab(tab, in: b.active!)
        XCTAssertTrue(model.isClosed)
        XCTAssertEqual(model.code, "")
        XCTAssertNil(state.connectionForm)
        let reopened = try XCTUnwrap(b.reopenLastClosedTab()?.tabState)
        XCTAssertEqual(tabs.model(reopened).step, .address)
        XCTAssertEqual(tabs.model(reopened).code, "")
        XCTAssertTrue(b.flushPersistence())
        let until = Date().addingTimeInterval(2)
        while requests("DELETE", "/v1/auth/session").isEmpty, Date() < until { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requests("DELETE", "/v1/auth/session").count, 1, "close revokes the unchosen session")
        XCTAssertNil(service.connection)
        let uiFiles = FileManager.default.enumerator(at: ui, includingPropertiesForKeys: [.isRegularFileKey])!.allObjects.compactMap { $0 as? URL }
        for file in uiFiles {
            guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            for secret in [code, token, "s-new", "anna@example.com"] { XCTAssertFalse(text.contains(secret), file.lastPathComponent) }
        }
    }

    private func connectionStore(_ persistence: any Persistence = InMemoryPersistence(),
                                 peers: @escaping @MainActor () -> [WorkspaceStore] = { [] }) -> WorkspaceStore {
        WorkspaceStore(persistence: persistence, initiallyEmpty: true, engineFactory: {
            XCTFail("Connection allocated a terminal"); return TestEngine()
        }, peerStores: peers)
    }

    func testReviewConnectionLeavingClearsCodeAndPendingAuthorization() async throws {
        for path in ["leave", "last-window", "hide", "close-tab", "quit"] {
            for authenticated in [false, true] {
                serve(orgs: [org("org-a"), org("org-b")])
                let tokens = FakeTokenStore(), (model, service) = model(tokens)
                let store = connectionStore()
                defer { store.terminate() }
                let tab = store.openToolTab(.connection), state = try XCTUnwrap(tab.tabState)
                state.connectionForm = model
                await toCode(model)
                if authenticated { await model.submitCode() }
                let context = "\(path), authenticated: \(authenticated)"
                switch path {
                case "leave": state.leave()
                case "last-window":
                    // The last-window close prepares every tab, then hides the
                    // live store. Dock reopening reuses this same TabState.
                    XCTAssertTrue(store.tabCloseCoordinator.prepare(store.allSessions))
                    XCTAssertTrue(model.isClosed, context)
                    store.setOnScreen(false)
                case "hide": store.setOnScreen(false)
                case "close-tab": store.closeTab(tab, in: try XCTUnwrap(store.active))
                default:
                    XCTAssertTrue(store.tabCloseCoordinator.prepare(store.allSessions))
                    XCTAssertTrue(model.isClosed, context)
                    store.terminate()
                }
                XCTAssertTrue(model.isClosed, context)
                XCTAssertEqual(model.code, "", context)
                XCTAssertEqual(model.email, "", context)
                XCTAssertNil(model.codeSentAt, context)
                XCTAssertEqual(model.step, .address, context)
                XCTAssertNil(state.connectionForm, context)
                XCTAssertNil(service.connection, context)
                XCTAssertTrue(tokens.items.isEmpty, context)
                if !store.isTerminated {
                    store.setOnScreen(true)
                    let reopened = store.openToolTab(.connection)
                    let fresh = ConnectionTabs(service: service).model(try XCTUnwrap(reopened.tabState))
                    XCTAssertFalse(fresh === model, context)
                    XCTAssertFalse(fresh.isClosed, context)
                    XCTAssertEqual(fresh.step, .address, context)
                    XCTAssertEqual(fresh.code, "", context)
                }
                if authenticated {
                    let until = Date().addingTimeInterval(1)
                    while requests("DELETE", "/v1/auth/session").isEmpty, Date() < until {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    XCTAssertEqual(requests("DELETE", "/v1/auth/session").count, 1, context)
                    XCTAssertEqual(requests("DELETE", "/v1/auth/session").first?.request.value(forHTTPHeaderField: "Authorization"), "Bearer aps_new", context)
                }
                // Also clean up the deliberately failing pre-fix run before
                // resetting the stub server for the next case.
                model.close()
                if authenticated {
                    let until = Date().addingTimeInterval(1)
                    while requests("DELETE", "/v1/auth/session").isEmpty, Date() < until {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                }
            }
        }
    }

    func testReviewConnectionReopenAndDirectOpenFocusTheOtherWindow() throws {
        var stores: [WorkspaceStore] = []
        let a = connectionStore(peers: { stores }), b = connectionStore(peers: { stores })
        stores = [a, b]
        defer { stores.forEach { $0.terminate() } }
        let router = TabRouter(); router.stores = { stores }
        var revealed: [UUID] = []
        let previousReveal = TabRouter.shared.revealWindow
        defer { TabRouter.shared.revealWindow = previousReveal }
        TabRouter.shared.revealWindow = { revealed.append($0.windowID) }
        router.revealWindow = { revealed.append($0.windowID) }
        let closed = a.openToolTab(.connection)
        _ = a.openToolTab(.settings)
        a.closeTab(closed, in: try XCTUnwrap(a.active))
        let live = b.openToolTab(.connection), workspace = try XCTUnwrap(b.active)
        let state = try XCTUnwrap(live.tabState), tabs = ConnectionTabs(service: model().1)
        let form = tabs.model(state); form.code = "87654321"
        for operation in ["reopen", "direct", "router"] {
            _ = b.addEmptyWorkspace()
            revealed.removeAll()
            let found: Session?
            switch operation {
            case "reopen": found = a.reopenLastClosedTab()
            case "direct": found = a.openToolTab(.connection)
            default: found = router.open(.connection, from: a)
            }
            XCTAssertTrue(found === live, operation)
            XCTAssertEqual(stores.flatMap(\.allSessions).filter { $0.toolRoute == .connection }.count, 1, operation)
            XCTAssertTrue(b.active === workspace, operation)
            XCTAssertTrue(workspace.activeSession === live, operation)
            XCTAssertEqual(revealed.last, b.windowID, operation)
            XCTAssertTrue(tabs.model(state) === form, operation)
            XCTAssertEqual(form.code, "87654321", operation)
        }
        XCTAssertFalse(a.canReopenClosedTab)
    }

    func testReviewConnectionCloseUsesItsOwnIdentityEvenWithLegacyDuplicates() throws {
        // Simulate two tabs restored from an older build before reconciliation.
        let a = connectionStore(), b = connectionStore()
        defer { a.terminate(); b.terminate() }
        let first = a.openToolTab(.connection), second = b.openToolTab(.connection)
        let router = TabRouter(); router.stores = { [a, b] }
        let navigation = SupportTabNavigation(router: router); navigation.finishStartup()
        let tabs = ConnectionTabs(navigation: navigation, service: model().1)
        let state = try XCTUnwrap(second.tabState)
        tabs.close(state) // The same action is used by both Cancel and Close.
        XCTAssertTrue(a.allSessions.contains { $0 === first })
        XCTAssertFalse(b.allSessions.contains { $0 === second })
        XCTAssertTrue(state.isClosed)
        tabs.close(state) // A stale callback cannot close the remaining tab.
        XCTAssertTrue(a.allSessions.contains { $0 === first })
    }

    func testReviewConnectionRestoreDeduplicatesAndRevealsTheSurvivingTab() throws {
        var restored: [WorkspaceStore] = []
        for _ in 0..<2 {
            let persistence = InMemoryPersistence(), seed = connectionStore(persistence)
            _ = seed.openToolTab(.connection)
            _ = seed.openToolTab(.settings)
            XCTAssertTrue(seed.flushPersistence())
            seed.terminate()
            restored.append(connectionStore(InMemoryPersistence(initial: try XCTUnwrap(persistence.saved))))
        }
        defer { restored.forEach { $0.terminate() } }
        let first = try XCTUnwrap(restored[0].allSessions.first { $0.toolRoute == .connection })
        let duplicate = try XCTUnwrap(restored[1].allSessions.first { $0.toolRoute == .connection })
        let router = TabRouter(); router.stores = { restored }
        var revealed: [UUID] = []
        router.revealWindow = { revealed.append($0.windowID) }
        router.reconcileRestoredTabs()
        XCTAssertEqual(restored.flatMap(\.allSessions).filter { $0.toolRoute == .connection }.map(\.id), [first.id])
        XCTAssertTrue(duplicate.tabState?.isClosed == true)
        XCTAssertTrue(restored[0].active?.activeSession === first)
        XCTAssertEqual(revealed, [restored[0].windowID])
    }

    func testReviewConnectionKeychainFailureKeepsOrganizationRetryAndBackUsable() async throws {
        for recovery in ["retry", "back"] {
            serve(orgs: [org("org-a", name: "Anna"), org("org-b", name: "Anna")])
            let tokens = FakeTokenStore(), switched = Counter()
            let (model, service) = model(tokens, switched: switched)
            await toCode(model); await model.submitCode()
            let choice = model.step
            tokens.failure = .keychain("denied")
            await model.choose("org-a")
            XCTAssertEqual(model.step, choice)
            XCTAssertTrue(model.error?.contains("denied") == true)
            XCTAssertFalse(model.busy)
            XCTAssertNil(service.connection)
            XCTAssertTrue(tokens.items.isEmpty)
            XCTAssertEqual(switched.value, 0)
            XCTAssertTrue(requests("DELETE", "/v1/auth/session").isEmpty, "a retry needs the pending authorization")
            tokens.failure = nil
            if recovery == "retry" {
                await model.choose("org-b")
                XCTAssertEqual(model.step, .done)
                XCTAssertNil(model.error)
                XCTAssertEqual(service.connection?.orgId, "org-b")
                XCTAssertEqual(switched.value, 1)
                XCTAssertEqual(try files.loadConnections().first?.orgId, "org-b")
                await service.disconnect()
            } else {
                model.back()
                XCTAssertEqual(model.step, .address)
                XCTAssertNil(model.error)
                let until = Date().addingTimeInterval(1)
                while requests("DELETE", "/v1/auth/session").isEmpty, Date() < until {
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertEqual(requests("DELETE", "/v1/auth/session").count, 1)
                await toCode(model)
                await model.submitCode(); await model.choose("org-b")
                XCTAssertEqual(model.step, .done)
                await service.disconnect()
            }
        }
    }

    func testClosingDuringAuthenticationRevokesLateAnswerAndCannotSignIn() async throws {
        serve(orgs: [org("org-a")])
        let (model, service) = model()
        await toCode(model)
        ChatStubProtocol.delay = 0.15
        let submit = Task { await model.submitCode() }
        let until = Date().addingTimeInterval(2)
        while requests("POST", "/v1/auth/session").isEmpty, Date() < until { try await Task.sleep(for: .milliseconds(5)) }
        model.close()
        XCTAssertEqual(model.code, "")
        await submit.value
        XCTAssertNil(service.connection)
        XCTAssertEqual(model.step, .address)
        XCTAssertNil(model.error)
        XCTAssertEqual(requests("DELETE", "/v1/auth/session").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.serversURL.path))
    }

    func testNameValidationAndRestorationUseTheRealConnection() async throws {
        serve(orgs: [org("org-a")])
        let (model, service) = model()
        await toCode(model); await model.submitCode()
        let tabs = ConnectionTabs(service: service), state = TabState(route: .connection)
        state.connectionForm = model
        XCTAssertTrue(tabs.model(state) === model, "the connection update must preserve the name step")
        model.displayName = "  "
        await model.saveName()
        XCTAssertNotNil(model.error)
        guard case .name = model.step else { return XCTFail("name step lost") }
        model.close()
        let restored = ChatConnectModel(service: service)
        XCTAssertEqual(restored.step, .done)
        XCTAssertEqual(restored.code, "")
        XCTAssertEqual(restored.displayName, "")
    }

    func testClosingWhileOrganizationChoiceWaitsForTheCoreCannotCommit() async throws {
        serve(orgs: [org("org-a"), org("org-b")])
        let (model, service) = model()
        await toCode(model); await model.submitCode()
        let gate = AsyncGate()
        var entered = false
        service.onBeforeDisconnect { entered = true; await gate.wait() }
        let holdingCore = Task { await service.disconnect() }
        let deadline = Date().addingTimeInterval(2)
        while !entered, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(entered)
        let choice = Task { await model.choose("org-a") }
        while !model.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.busy)
        model.close()
        await gate.open()
        await holdingCore.value; await choice.value
        XCTAssertNil(service.connection)
        XCTAssertTrue(model.isClosed)
        XCTAssertNil(model.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.serversURL.path))
        XCTAssertEqual(requests("DELETE", "/v1/auth/session").count, 1)
    }

    func testRepeatedSendAndSubmitDoNotStartParallelRequests() async throws {
        serve(orgs: [org("org-a"), org("org-b")])
        ChatStubProtocol.delay = 0.05
        let (model, _) = model()
        let first = Task { await model.sendCode() }
        await Task.yield()
        await model.sendCode(); await first.value
        XCTAssertEqual(requests("POST", "/v1/auth/code").count, 1)
        model.code = "12345678"
        let submit = Task { await model.submitCode() }
        await Task.yield()
        await model.submitCode(); await submit.value
        XCTAssertEqual(requests("POST", "/v1/auth/session").count, 1)
        model.back()
        XCTAssertEqual(model.code, "")
    }

    /// Signing in again with the old token kept: the old session is closed with it.
    func testSigningInAgainClosesTheOldSession() async throws {
        let id = UUID().uuidString.lowercased()
        let tokens = FakeTokenStore()
        try ChatService(files: files, tokens: tokens).saveSignIn(
            ChatConnection(server: server, accountId: account, sessionId: "s-old", deviceName: "Mac", orgId: id), token: "aps_old")
        serve(orgs: [org(id, name: "Anna")])
        let (model, _) = model(tokens)
        await toCode(model)
        await model.submitCode()
        XCTAssertEqual(model.step, .done)
        let deletes = requests("DELETE", "/v1/auth/session")
        XCTAssertEqual(deletes.map { $0.request.value(forHTTPHeaderField: "Authorization") }, ["Bearer aps_old"])
        let made = try XCTUnwrap(try files.loadConnections().first)
        XCTAssertEqual(tokens.stored(made.tokenAccount), "aps_new")
        XCTAssertNil(tokens.stored(ChatConnection(server: server, accountId: account, sessionId: "s-old", deviceName: "Mac", orgId: id).tokenAccount),
                     "the old session's token goes with it")
    }

    /// C13-1: signing in again, the record and the token it names stay a
    /// pair whatever step a crash ends: the new token has its own item, the
    /// record names the old session until the move keeps the new one.
    func testSigningInAgainKeepsTheRecordAndItsTokenAPair() async throws {
        let id = UUID().uuidString.lowercased()
        let tokens = FakeTokenStore()
        let old = ChatConnection(server: server, accountId: account, sessionId: "s-old", deviceName: "Mac", orgId: id)
        try ChatService(files: files, tokens: tokens).saveSignIn(old, token: "aps_old")
        let service = ChatService(files: files, tokens: tokens)
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        serve(orgs: [org(id, name: "Anna")])
        var closed: [String] = []
        service.closeRemoteSession = { _, token in closed.append(token) }
        let answer = ChatSignIn(token: "aps_new", sessionId: "s-new", accountId: account, orgs: [])
        let made = try await service.completeSignIn(answer, server: server, deviceName: "Mac", orgId: id)
        // A crash here: the next launch reads the old record and its own token.
        let recorded = try XCTUnwrap(try files.loadConnections().first)
        XCTAssertEqual(recorded.sessionId, "s-old")
        XCTAssertEqual(tokens.stored(recorded.tokenAccount), "aps_old")
        XCTAssertTrue(closed.isEmpty, "the old session works until the new one is kept")
        try await service.keepSignIn()
        // Kept: the record names the new session and its token; the old one goes.
        let kept = try XCTUnwrap(try files.loadConnections().first)
        XCTAssertEqual(kept, made)
        XCTAssertEqual(tokens.stored(kept.tokenAccount), "aps_new")
        XCTAssertNil(tokens.stored(old.tokenAccount))
        XCTAssertEqual(closed, ["aps_old"])
    }

    /// Closing the earlier session is a debt: no network, its token is kept
    /// and the close is tried again until the server takes it — only a
    /// closed session's requests are closed by the server (D4b, d8d2ea0).
    func testTheEarlierSessionIsClosedEvenAfterAFailure() async throws {
        let id = UUID().uuidString.lowercased()
        let tokens = FakeTokenStore()
        let old = ChatConnection(server: server, accountId: account, sessionId: "s-old", deviceName: "Mac", orgId: id)
        try ChatService(files: files, tokens: tokens).saveSignIn(old, token: "aps_old")
        let service = ChatService(files: files, tokens: tokens)
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        service.closingRetryDelay = .milliseconds(100)
        serve(orgs: [org(id, name: "Anna")])
        var tries: [String] = []
        var down = true
        service.closeRemoteSession = { _, token in
            tries.append(token)
            if down { throw ChatAPIError.network("offline") }
        }
        let answer = ChatSignIn(token: "aps_new", sessionId: "s-new", accountId: account, orgs: [])
        _ = try await service.completeSignIn(answer, server: server, deviceName: "Mac", orgId: id)
        try await service.keepSignIn()
        XCTAssertEqual(tries, ["aps_old"])
        XCTAssertEqual(tokens.stored(old.tokenAccount), "aps_old", "kept until it is closed")
        XCTAssertEqual(files.loadClosing().map(\.sessionId), ["s-old"])
        // A keychain that cannot be read is not a token gone: kept (review D5b3-2).
        tokens.failure = .keychain("denied")
        await service.closeEarlierSessions()
        tokens.failure = nil
        XCTAssertEqual(files.loadClosing().map(\.sessionId), ["s-old"])
        // Kept across a start's pruning.
        try service.pruneTokens(keeping: [])
        XCTAssertEqual(tokens.stored(old.tokenAccount), "aps_old")
        down = false
        for _ in 0..<50 where !files.loadClosing().isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(files.loadClosing().isEmpty)
        XCTAssertGreaterThanOrEqual(tries.count, 2)
        XCTAssertNil(tokens.stored(old.tokenAccount), "closed: its token goes")
    }

    /// C13-3: a sign-in alone writes no record — only the move does — so no
    /// path (the debug menu's shortcut is gone) leaves a server mode behind.
    func testSignInAloneWritesNoRecord() async throws {
        let tokens = FakeTokenStore()
        let service = ChatService(files: files, tokens: tokens)
        let answer = ChatSignIn(token: "aps_new", sessionId: "s-new", accountId: account, orgs: [])
        let made = try await service.completeSignIn(answer, server: server, deviceName: "Mac", orgId: "org")
        XCTAssertEqual(tokens.stored(made.tokenAccount), "aps_new")
        XCTAssertTrue(try files.loadConnections().isEmpty)
        XCTAssertEqual(TeamMode.resolve(chatDirectory: files.directory).mode, .off)
        await service.discardSignIn()
        XCTAssertNil(tokens.stored(made.tokenAccount))
    }

    /// Review C-20: a server without the event feed is refused in the
    /// window, before anything is kept or switched.
    func testServerWithoutTheEventFeedIsRefusedByTheWindow() async throws {
        serve(orgs: [org(UUID().uuidString.lowercased())], capabilities: #"["auth.email_code"]"#)
        let switched = Counter()
        let (model, service) = model(switched: switched)
        await model.sendCode()
        XCTAssertEqual(model.step, .address)
        XCTAssertEqual(model.error, "This server's version does not fit this AgentPad.")
        XCTAssertNil(service.connection)
        XCTAssertEqual(switched.value, 0)
        XCTAssertTrue(ChatStubProtocol.seen.allSatisfy { $0.request.url?.path == "/v1/server" }, "no code was asked for")
    }

    /// Decision "Переход на сервер — только из выключенной командной работы":
    /// while a call runs here, the window says so and asks nothing of the server.
    func testRunningTeamWorkIsInTheWay() async throws {
        serve(orgs: [org("0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10")])
        let (model, service) = model()
        model.teamWorkIdle = { false }
        await model.sendCode()
        XCTAssertTrue(model.teamWorkInTheWay)
        XCTAssertEqual(model.error, TeamError.teamWorkOn.localizedDescription)
        XCTAssertEqual(model.step, .address)
        XCTAssertTrue(requests("POST", "/v1/auth/code").isEmpty)
        XCTAssertNil(service.connection)
    }

    /// The record is written only once the move began; team work turned on
    /// meanwhile — the move refused — leaves no record and touches nothing.
    func testRecordOnlyAfterTheMoveAndNoneWhenRefused() async throws {
        serve(orgs: [org("0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10")])
        let tokens = FakeTokenStore()
        let service = ChatService(files: files, tokens: tokens)
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        var disconnected = 0
        service.onDisconnected = { disconnected += 1 }
        var recordAtMove: Int?
        let refusing = ChatConnectModel(service: service) {
            recordAtMove = try self.files.loadConnections().count
            throw TeamError.teamWorkOn
        }
        refusing.teamWorkIdle = { true }
        refusing.serverText = "https://chat.example.com"
        refusing.email = "anna@example.com"
        await toCode(refusing)
        await refusing.submitCode()
        XCTAssertEqual(recordAtMove, 0, "no record before the move")
        XCTAssertTrue(refusing.teamWorkInTheWay)
        XCTAssertEqual(refusing.step, .address)
        XCTAssertNil(service.connection)
        XCTAssertTrue(try files.loadConnections().isEmpty, "a refused move leaves no record")
        XCTAssertEqual(disconnected, 0)
        XCTAssertEqual(requests("DELETE", "/v1/auth/session").count, 1, "its session closed")

        // The move that goes on writes the record.
        let moving = ChatConnectModel(service: service) { try await service.keepSignIn() }
        moving.teamWorkIdle = { true }
        moving.serverText = "https://chat.example.com"
        moving.email = "anna@example.com"
        await toCode(moving)
        await moving.submitCode()
        XCTAssertEqual(try files.loadConnections().count, 1)
    }

    func testFailedSwitchDoesNotKeepTheSignIn() async throws {
        let id = UUID().uuidString.lowercased()
        serve(orgs: [org(id, name: "Anna")])
        let tokens = FakeTokenStore()
        let service = ChatService(files: files, tokens: tokens)
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        struct Refused: Error {}
        let model = ChatConnectModel(service: service) { throw Refused() }
        model.serverText = "https://chat.example.com"
        model.email = "anna@example.com"
        await toCode(model)
        await model.submitCode()
        XCTAssertEqual(model.step, .address)
        XCTAssertNotNil(model.error)
        XCTAssertNil(service.connection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.serversURL.path))
        XCTAssertTrue(tokens.items.isEmpty, "no token is kept")
        XCTAssertEqual(requests("DELETE", "/v1/auth/session").first?.request.value(forHTTPHeaderField: "Authorization"), "Bearer aps_new")
    }
}
