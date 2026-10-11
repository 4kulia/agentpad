import Foundation
import Darwin
import XCTest
@testable import AgentPadTelegram

final class MemoryTelegramKeys: TelegramKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var error: TelegramStorageError?
    private(set) var insertions = 0
    func read(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }; return values[account]
    }
    func insert(_ key: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }
        guard values[account] == nil else { throw TelegramStorageError.keyExists }
        values[account] = key; insertions += 1
    }
    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }; values[account] = nil
    }
}

/// The pin persists both QR auth state and logout/key-destruction intent. close
/// preserves them; only completed logout clears them for a new phone login.
final class FakeTDLibDatabase: @unchecked Sendable {
    private let lock = NSLock()
    private var saved = TDLibMessage("authorizationStateWaitPhoneNumber")
    var state: TDLibMessage { lock.lock(); defer { lock.unlock() }; return saved }
    func save(_ state: TDLibMessage) {
        guard !["authorizationStateWaitTdlibParameters", "authorizationStateClosing", "authorizationStateClosed"].contains(state.type) else { return }
        lock.lock(); saved = state; lock.unlock()
    }
    func completeLogout() { save(TDLibMessage("authorizationStateWaitPhoneNumber")) }
}

final class FakeTDLibClient: TDLibClient, @unchecked Sendable {
    enum LogoutBehavior { case success, silent, acceptedPending, alreadyLoggingOut, closedWithoutOK }
    let database: FakeTDLibDatabase
    private let condition = NSCondition()
    private var authState = "authorizationStateWaitTdlibParameters"
    private var incoming: [TDLibMessage] = []
    private var sent: [TDLibMessage] = []
    private var deferredOptions: [TDLibMessage] = []
    private var forumTopicInfos: [String: TDLibValue] = [:]
    private var releasedCount = 0
    private var receivedOnMain = false
    var logoutBehavior: LogoutBehavior = .success
    var optionReadback: Int64?
    var abortOptionAcknowledgements = false
    var automaticMe = true
    var automaticClose = true
    var automaticQR = true
    var automaticForms = true
    var automaticChats = true
    var startupUpdates: [TDLibMessage] = []
    var initialNotificationGroups: [TDLibValue] = []

    init(database: FakeTDLibDatabase = FakeTDLibDatabase()) { self.database = database }

    var requests: [TDLibMessage] { condition.lock(); defer { condition.unlock() }; return sent }
    var releases: Int { condition.lock(); defer { condition.unlock() }; return releasedCount }
    var mainThreadReceives: Bool { condition.lock(); defer { condition.unlock() }; return receivedOnMain }

    func enqueue(_ message: TDLibMessage) {
        TelegramFixtureSchema.check(message)
        condition.lock(); incoming.append(message); condition.signal(); condition.unlock()
    }
    func auth(_ type: String, _ fields: [String: TDLibValue] = [:]) {
        condition.lock(); authState = type; condition.unlock()
        database.save(TDLibMessage(type, fields))
        enqueue(TDLibMessage("updateAuthorizationState", ["authorization_state": .object(TDLibMessage(type, fields).fields)]))
    }
    func completeLogout() {
        database.completeLogout()
        auth("authorizationStateClosed")
    }
    func reply(_ request: TDLibMessage, _ response: TDLibMessage = TDLibMessage("ok")) {
        for message in replyMessages(request, response) { enqueue(message) }
    }
    func replyMessages(_ request: TDLibMessage, _ response: TDLibMessage) -> [TDLibMessage] {
        TelegramFixtureSchema.check(response)
        condition.lock(); defer { condition.unlock() }
        var messages: [TDLibMessage] = []
        if request.type == "getForumTopic", response.type == "forumTopic", let info = response["info"]?.object,
           let chat = info["chat_id"]?.integer, let topic = info["forum_topic_id"]?.integer {
            // ForumTopicManager::on_get_forum_topic_impl in the pin sends
            // changed info, then updateForumTopic, before resolving the RPC.
            let key = "\(chat):\(topic)"
            if forumTopicInfos[key] != response["info"] {
                forumTopicInfos[key] = response["info"]
                messages.append(TDLibMessage("updateForumTopicInfo", ["info": response["info"]!]))
            }
            var update = TDLibMessage("updateForumTopic", ["chat_id": .integer(chat), "forum_topic_id": .integer(topic)])
            for field in ["is_pinned", "last_read_inbox_message_id", "last_read_outbox_message_id", "unread_mention_count",
                          "unread_reaction_count", "unread_poll_vote_count", "notification_settings", "draft_message"] {
                update[field] = response[field]
            }
            messages.append(update)
        }
        var response = response; response["@extra"] = request["@extra"]
        messages.append(response)
        return messages
    }
    static let user = TDLibMessage("user", ["id": .integer(9007199254740991), "first_name": .string("Test"), "last_name": .string("Account")])
    static let codeInfo: [String: TDLibValue] = ["code_info": .object([
        "type": .object(["@type": .string("authenticationCodeTypeTelegramMessage")]),
        "next_type": .object(["@type": .string("authenticationCodeTypeSms")]), "timeout": .integer(30)
    ])]
    func send(_ request: TDLibMessage) throws {
        condition.lock(); sent.append(request); let state = authState; condition.unlock()
        switch request.type {
        case "getAuthorizationState": auth("authorizationStateWaitTdlibParameters"); reply(request, TDLibMessage("authorizationStateWaitTdlibParameters"))
        case "setOption":
            if state == "authorizationStateReady" { reply(request) }
            else { deferredOptions.append(request) }
        case "setTdlibParameters":
            // The order that reproduced the spike: auth updates can arrive
            // before parameters/options are acknowledged.
            let restored = database.state
            auth(restored.type, restored.fields)
            for update in startupUpdates { enqueue(update) }
            enqueue(TDLibMessage("updateActiveNotifications", ["groups": .array(initialNotificationGroups)]))
            reply(request)
            for option in deferredOptions {
                reply(option, abortOptionAcknowledgements
                      ? TDLibMessage("error", ["code": .integer(500), "message": .string("Request aborted")])
                      : TDLibMessage("ok"))
            }
            deferredOptions.removeAll()
        case "getOption":
            let name = request["name"]?.string
            if name == "version" { reply(request, TDLibMessage("optionValueString", ["value": .string(TelegramBuild.version)])) }
            else if name == "commit_hash" { reply(request, TDLibMessage("optionValueString", ["value": .string(TelegramBuild.commit)])) }
            else { reply(request, TDLibMessage("optionValueInteger", ["value": .integer(optionReadback ?? (name == "notification_group_size_max" ? 10 : 25))])) }
        case "requestQrCodeAuthentication":
            if automaticQR { reply(request); auth("authorizationStateWaitOtherDeviceConfirmation", ["link": .string("tg://login?token=synthetic")]) }
        case "setAuthenticationPhoneNumber":
            // AuthManager::set_phone_number in 42e6a525 explicitly excludes QR.
            guard state == "authorizationStateWaitPhoneNumber" else {
                reply(request, TDLibMessage("error", ["code": .integer(400), "message": .string("Call to setAuthenticationPhoneNumber unexpected")]))
                return
            }
            if automaticForms { auth("authorizationStateWaitCode", Self.codeInfo); reply(request) }
        case "getMe": if automaticMe { reply(request, Self.user) }
        case "getScopeNotificationSettings":
            if automaticChats { reply(request, TDLibMessage("scopeNotificationSettings", ["mute_for": .integer(0), "disable_mention_notifications": .bool(false)])) }
        case let method where ["getChatHistory", "searchChatMessages"].contains(method) && request["@extra"]?.string?.hasPrefix("chats:background:") == true:
            if automaticChats {
                var response = TDLibMessage(request.type == "getChatHistory" ? "messages" : "foundChatMessages", ["messages": .array([])])
                if request.type == "searchChatMessages" { response["next_from_message_id"] = .integer(0) }
                reply(request, response)
            }
        case "loadChats":
            if automaticChats { reply(request, TDLibMessage("error", ["code": .integer(404), "message": .string("All chats loaded")])) }
        case "searchChats", "searchChatsOnServer":
            if automaticChats { reply(request, TDLibMessage("chats", ["chat_ids": .array([])])) }
        case "searchContacts":
            if automaticChats { reply(request, TDLibMessage("users", ["user_ids": .array([])])) }
        case "searchPublicChat", "createPrivateChat", "addRecentlyFoundChat":
            if automaticChats { reply(request, TDLibMessage("error", ["code": .integer(400), "message": .string("Not found")])) }
        case "logOut":
            if state == "authorizationStateLoggingOut" {
                reply(request, TDLibMessage("error", ["code": .integer(400), "message": .string("Already logging out")]))
                return
            }
            switch logoutBehavior {
            case .success: auth("authorizationStateLoggingOut"); reply(request); completeLogout()
            case .silent: auth("authorizationStateLoggingOut")
            case .acceptedPending: auth("authorizationStateLoggingOut"); reply(request)
            case .alreadyLoggingOut:
                reply(request, TDLibMessage("error", ["code": .integer(400), "message": .string("Already logging out")]))
                auth("authorizationStateLoggingOut")
            case .closedWithoutOK: auth("authorizationStateClosed")
            }
        case "close", "destroy":
            if automaticClose { reply(request); auth("authorizationStateClosed") }
        default: if automaticForms { reply(request) }
        }
    }
    func receive(timeout: TimeInterval) throws -> TDLibMessage? {
        condition.lock(); defer { condition.unlock() }
        receivedOnMain = receivedOnMain || Thread.isMainThread
        if incoming.isEmpty { _ = condition.wait(until: Date().addingTimeInterval(min(timeout, 0.01))) }
        return incoming.isEmpty ? nil : incoming.removeFirst()
    }
    func release() { condition.lock(); releasedCount += 1; condition.unlock() }
}

final class FakeTDLibClientFactory: @unchecked Sendable {
    let first: FakeTDLibClient
    private let lock = NSLock()
    private var created: [FakeTDLibClient] = []
    init(first: FakeTDLibClient = FakeTDLibClient()) { self.first = first }
    var clients: [FakeTDLibClient] { lock.lock(); defer { lock.unlock() }; return created }
    func makeClient() -> FakeTDLibClient {
        lock.lock(); defer { lock.unlock() }
        let client = created.isEmpty ? first : FakeTDLibClient(database: first.database)
        created.append(client)
        return client
    }
}

final class TelegramFixture: @unchecked Sendable {
    let directory: URL
    let keys = MemoryTelegramKeys()
    let factory = FakeTDLibClientFactory()
    var client: FakeTDLibClient { factory.first }
    var latestClient: FakeTDLibClient { factory.clients.last ?? client }
    let profiles: TelegramProfileStore
    init() throws {
        // Foundation preserves the system /var alias when resolving URLs;
        // our profile policy deliberately rejects symlink ancestors.
        let temporary = FileManager.default.temporaryDirectory.path
        let canonical = try XCTUnwrap(realpath(temporary, nil))
        defer { free(canonical) }
        directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("telegram-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        profiles = TelegramProfileStore(root: directory.appendingPathComponent("telegram"))
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func connector(timeout: TimeInterval = 2, client: FakeTDLibClient? = nil) throws -> LocalTDLibConnector {
        let factory = client.map { FakeTDLibClientFactory(first: $0) } ?? self.factory
        return LocalTDLibConnector(credentials: try TelegramCredentials(apiID: 123, apiHash: String(repeating: "a", count: 32)),
            environment: .test, profiles: profiles, keys: TelegramDatabaseKeys(store: keys), applicationVersion: "test",
            timeout: timeout, clientFactory: { factory.makeClient() })
    }
}

func eventually(_ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<300 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition was not reached", file: file, line: line)
}

func isQR(_ connector: LocalTDLibConnector) async -> Bool {
    if case .qr = await connector.currentSnapshot().state { true } else { false }
}
