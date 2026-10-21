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
        XCTAssertEqual(model.progressIndex, 0)
        await toCode(model)
        XCTAssertEqual(model.progressIndex, 1)
        await model.submitCode()
        XCTAssertEqual(model.step, .noOrganization)
        XCTAssertEqual(model.progressIndex, 2)
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
        XCTAssertEqual(model.progressIndex, 3)
        XCTAssertEqual(switched.value, 1, "switchToServer after the sign-in")
        XCTAssertEqual(try files.loadConnections().first?.orgId, id)
        model.displayName = "Anna"
        await model.saveName()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(model.progressIndex, 4)
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
        XCTAssertEqual(model.progressIndex, 2)
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

    private func connectionStore(_ persistence: any Persistence = InMemoryPersistence(),
                                 peers: @escaping @MainActor () -> [WorkspaceStore] = { [] }) -> WorkspaceStore {
        WorkspaceStore(persistence: persistence, initiallyEmpty: true, engineFactory: {
            XCTFail("Connection allocated a terminal"); return TestEngine()
        }, peerStores: peers)
    }

    private func connectionTabs(_ stores: [WorkspaceStore], service: ChatService) -> ConnectionTabs {
        let router = TabRouter(); router.stores = { stores }; router.ensureHost = { stores.first }
        let navigation = SupportTabNavigation(router: router); navigation.finishStartup()
        return ConnectionTabs(navigation: navigation, service: service)
    }

    private func waitForRevocation() async throws {
        let until = Date().addingTimeInterval(2)
        while requests("DELETE", "/v1/auth/session").isEmpty, Date() < until {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(requests("DELETE", "/v1/auth/session").count, 1)
    }

    func testConnectionPopupDismissKeepsRuntimeDraftAndRestartNeverKeepsSecrets() async throws {
        let ui = root.appendingPathComponent("ui")
        let stateURL = ui.appendingPathComponent("state-v2.json"), windowID = UUID()
        let app = AppPersistence(fileURL: stateURL)
        let store = connectionStore(WindowPersistence(windowId: windowID, app: app))
        defer { store.terminate() }
        let (model, service) = model()
        let tabs = connectionTabs([store], service: service)
        let popup = try XCTUnwrap(tabs.show()), state = try XCTUnwrap(popup.tabState)
        state.connectionForm = model
        let credential = "aps_TRANSIENT_SECRET", verification = "87654321"
        serve(orgs: [org("org-a"), org("org-b")], token: credential)
        await toCode(model); model.code = verification
        store.popups.dismiss(reason: .dismiss)
        XCTAssertFalse(store.popups.isPresented)
        XCTAssertTrue(store.allSessions.isEmpty)
        XCTAssertFalse(model.isClosed)
        XCTAssertTrue(state.connectionForm === model)
        XCTAssertTrue(model.code == verification)
        XCTAssertTrue(tabs.show() === popup)
        XCTAssertTrue(store.popups.draftKept)
        XCTAssertTrue(tabs.model(state) === model)
        await model.submitCode()
        let offered = model.step
        store.popups.dismiss(reason: .dismiss)
        XCTAssertTrue(requests("DELETE", "/v1/auth/session").isEmpty, "dismissal keeps the pending organization choice")
        XCTAssertTrue(tabs.show() === popup)
        XCTAssertEqual(model.step, offered)
        XCTAssertTrue(store.flushPersistence())
        XCTAssertNil(state.draft)
        XCTAssertTrue(store.drafts.drafts.isEmpty)

        let restarted = AppPersistence(fileURL: stateURL)
        let restored = connectionStore(WindowPersistence(windowId: windowID, app: restarted))
        defer { restored.terminate() }
        XCTAssertTrue(restored.allSessions.isEmpty)
        XCTAssertTrue(restored.popups.sessions.isEmpty)
        XCTAssertFalse(restored.popups.isPresented)
        let restoredTabs = connectionTabs([restored], service: ChatService(files: files, tokens: FakeTokenStore()))
        let fresh = restoredTabs.model(try XCTUnwrap(restoredTabs.show()?.tabState))
        XCTAssertEqual(fresh.step, .address)
        XCTAssertTrue(fresh.email.isEmpty && fresh.code.isEmpty)
        let uiFiles = FileManager.default.enumerator(at: ui, includingPropertiesForKeys: [.isRegularFileKey])!.allObjects.compactMap { $0 as? URL }
        for file in uiFiles {
            guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            for secret in [verification, credential, "s-new", "anna@example.com"] {
                XCTAssertFalse(text.contains(secret), "Runtime connection input must not enter \(file.lastPathComponent)")
            }
        }
        tabs.cancel(state)
        XCTAssertTrue(model.isClosed)
        XCTAssertTrue(model.email.isEmpty && model.code.isEmpty)
        XCTAssertNil(state.connectionForm)
        XCTAssertTrue(store.popups.sessions.isEmpty)
        try await waitForRevocation()
        XCTAssertNil(service.connection)
    }

    func testConnectionPopupCancelDiscardsEveryUnfinishedStep() async throws {
        for step in ["address", "code", "organization"] {
            serve(orgs: [org("org-a"), org("org-b")])
            let (model, service) = model()
            let store = connectionStore()
            defer { store.terminate() }
            let tabs = connectionTabs([store], service: service)
            let popup = try XCTUnwrap(tabs.show()), state = try XCTUnwrap(popup.tabState)
            state.connectionForm = model
            if step != "address" { await toCode(model) }
            if step == "organization" { await model.submitCode() }
            tabs.cancel(state)
            XCTAssertTrue(model.isClosed, step)
            XCTAssertTrue(model.email.isEmpty && model.code.isEmpty, step)
            XCTAssertNil(model.codeSentAt, step)
            XCTAssertNil(state.connectionForm, step)
            XCTAssertTrue(state.isClosed, step)
            XCTAssertFalse(store.popups.isPresented, step)
            XCTAssertTrue(store.popups.sessions.isEmpty, step)
            let fresh = tabs.model(try XCTUnwrap(tabs.show()?.tabState))
            XCTAssertFalse(fresh === model, step)
            XCTAssertEqual(fresh.step, .address, step)
            XCTAssertFalse(store.popups.draftKept, step)
            if step == "organization" { try await waitForRevocation() }
            XCTAssertNil(service.connection, step)
        }
    }

    func testOrganizationBackReturnsToCodeAndPreservesServerAndEmailDraft() async throws {
        serve(orgs: [org("org-a"), org("org-b")])
        let (model, service) = model()
        await toCode(model)
        let sentAt = model.codeSentAt
        await model.submitCode()
        model.back()
        XCTAssertEqual(model.step, .code)
        XCTAssertEqual(model.serverText, "https://chat.example.com")
        XCTAssertEqual(model.email, "anna@example.com")
        XCTAssertEqual(model.codeSentAt, sentAt)
        XCTAssertTrue(model.code.isEmpty)
        XCTAssertNil(service.connection)
        try await waitForRevocation()
        model.back()
        XCTAssertEqual(model.step, .address)
        XCTAssertEqual(model.email, "anna@example.com")
        XCTAssertEqual(model.serverText, "https://chat.example.com")
        XCTAssertNil(model.codeSentAt)
    }

    func testConnectionPopupDismissDuringAuthenticationKeepsInFlightOperationAndName() async throws {
        serve(orgs: [org("org-a")])
        let (model, service) = model()
        let store = connectionStore()
        defer { store.terminate() }
        let tabs = connectionTabs([store], service: service)
        let popup = try XCTUnwrap(tabs.show()), state = try XCTUnwrap(popup.tabState)
        state.connectionForm = model
        await toCode(model)
        ChatStubProtocol.delay = 0.08
        let submit = Task { await model.submitCode() }
        let deadline = Date().addingTimeInterval(2)
        while requests("POST", "/v1/auth/session").isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.busy)
        store.popups.dismiss(reason: .dismiss)
        XCTAssertFalse(model.isClosed)
        XCTAssertTrue(model.busy)
        await submit.value
        XCTAssertEqual(model.step, .name(ChatOrgKey(server: server, accountId: account, orgId: "org-a")))
        XCTAssertTrue(tabs.show() === popup)
        XCTAssertTrue(tabs.model(state) === model)
        model.displayName = "Anna"
        store.popups.dismiss(reason: .dismiss)
        XCTAssertTrue(tabs.show() === popup)
        XCTAssertEqual(model.displayName, "Anna")
        await model.saveName()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(model.connectedSummary, "Org org- · anna@example.com")
        XCTAssertTrue(requests("DELETE", "/v1/auth/session").isEmpty)
        tabs.close(state)
        XCTAssertTrue(store.popups.sessions.isEmpty)
        XCTAssertTrue(model.isClosed)
        XCTAssertNotNil(service.connection, "Close on Connected keeps the completed sign-in")
        await service.disconnect()
    }

    func testConnectionPopupIsWindowLocalAndClosingUsesItsOwnIdentity() throws {
        var stores: [WorkspaceStore] = []
        let a = connectionStore(peers: { stores }), b = connectionStore(peers: { stores })
        stores = [a, b]
        defer { stores.forEach { $0.terminate() } }
        let router = TabRouter(); router.stores = { stores }
        let service = model().1
        let navigation = SupportTabNavigation(router: router); navigation.finishStartup()
        let tabs = ConnectionTabs(navigation: navigation, service: service)
        let first = try XCTUnwrap(router.open(.connection, from: a))
        let second = try XCTUnwrap(router.open(.connection, from: b))
        XCTAssertFalse(first === second)
        let firstState = try XCTUnwrap(first.tabState), secondState = try XCTUnwrap(second.tabState)
        let form = tabs.model(firstState); form.email = "draft@example.com"
        a.popups.dismiss(reason: .dismiss)
        XCTAssertTrue(router.open(.connection, from: a) === first)
        XCTAssertTrue(tabs.model(firstState) === form)
        XCTAssertEqual(form.email, "draft@example.com")
        tabs.cancel(secondState)
        XCTAssertTrue(a.popups.contains(first.id))
        XCTAssertFalse(b.popups.contains(second.id))
        XCTAssertTrue(secondState.isClosed)
        tabs.close(secondState)
        XCTAssertTrue(a.popups.contains(first.id), "a stale callback cannot consume another window's form")
        XCTAssertTrue(stores.allSatisfy { $0.allSessions.isEmpty })
    }

    func testLegacyConnectionTabRestoresAsNotShownAndReopensFresh() throws {
        let persistence = InMemoryPersistence()
        let seed = connectionStore(persistence)
        let workspace = seed.addEmptyWorkspace()
        let connection = seed.makeToolSession(.connection, navigation: TabNavigation(), cwd: URL(fileURLWithPath: "/tmp"))
        workspace.activePane?.tabs.append(connection)
        workspace.activePane?.activeTabId = connection.id
        XCTAssertTrue(seed.flushPersistence())
        let saved = try XCTUnwrap(persistence.saved)
        seed.terminate()
        let restored = connectionStore(InMemoryPersistence(initial: saved))
        defer { restored.terminate() }
        XCTAssertTrue(restored.allSessions.isEmpty)
        XCTAssertFalse(restored.popups.isPresented)
        XCTAssertTrue(restored.popups.sessions.isEmpty)
        let tabs = connectionTabs([restored], service: model().1)
        let fresh = tabs.model(try XCTUnwrap(tabs.show()?.tabState))
        XCTAssertEqual(fresh.step, .address)
        XCTAssertTrue(fresh.email.isEmpty && fresh.code.isEmpty)
        XCTAssertTrue(restored.allSessions.isEmpty)
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
                XCTAssertEqual(model.step, .code)
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
