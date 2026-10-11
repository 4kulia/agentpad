import Foundation

/// Owns the sole local account. All reduction, JSON, Keychain and disk work is
/// isolated here, off MainActor. The blocking C receive has its own queue.
public actor LocalTDLibConnector: TelegramConnector, TelegramChatProvider, TelegramConversationProvider {
    public typealias ClientFactory = @Sendable () throws -> any TDLibClient
    private enum Purpose: Equatable {
        case probe, version, commit, parameters, optionAck(String), optionValue(String)
        case qr, form(UInt64), me, logout, close, destroy
    }
    private struct Pending {
        let purpose: Purpose
        let deadline: Date
        var timedOut = false
    }
    private let credentials: TelegramCredentials?
    private let environment: TelegramEnvironment
    private let profiles: TelegramProfileStore
    private let keys: TelegramDatabaseKeys
    private let factory: ClientFactory
    private let applicationVersion: String
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private var profile: TelegramProfile?
    private var client: (any TDLibClient)?
    private var receiver: Task<Void, Never>?
    private var pending: [String: Pending] = [:]
    private var machine = TelegramAuthorizationMachine()
    private var observers: [UUID: AsyncStream<TelegramSnapshot>.Continuation] = [:]
    private var lastPublished: TelegramSnapshot?
    private var epoch = UUID()
    private var parametersSent = false
    private var initializationChecks = Set<String>()
    private var rawAuth = ""
    private var qrRequested = false
    private var phoneSelected = false
    private var explicitAuthentication = false
    private var identifying = false
    private var account: TelegramAccount?
    private var databaseKey: Data?
    private var closing = false
    private var logoutRequested = false
    private var logoutInProgress = false
    private var logoutDeadline: Date?
    private var phoneAfterLogout = false
    private var destroyRequested = false
    private var revoked = false
    private var closeWaiters: [CheckedContinuation<Bool, Never>] = []
    private var closeDeadline: Date?
    private var authDeadline: Date?
    private var conversations: TelegramFeedSession?
    private var accentColors: [Int: (light: [UInt32], dark: [UInt32])] = [:]
    private var applicationActive = false
    private var chats: TelegramChatSession?
    private var chatObservers: [UUID: AsyncStream<TelegramChatSnapshot>.Continuation] = [:]
    private var scanPause: String?

    public init(credentials: TelegramCredentials?, environment: TelegramEnvironment = .production,
                profiles: TelegramProfileStore = .standard, keys: TelegramDatabaseKeys = .init(),
                applicationVersion: String, timeout: TimeInterval = 40,
                now: @escaping @Sendable () -> Date = Date.init,
                clientFactory: ClientFactory? = nil) {
        self.credentials = credentials; self.environment = environment
        self.profiles = profiles; self.keys = keys; self.applicationVersion = applicationVersion
        self.timeout = timeout; self.now = now
        self.factory = clientFactory ?? { try TDLibJSONClient() }
    }

    public func snapshots() -> AsyncStream<TelegramSnapshot> {
        let id = UUID()
        let pair = AsyncStream<TelegramSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation
        pair.continuation.yield(machine.snapshot)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish() {
        guard lastPublished != machine.snapshot else { return }
        lastPublished = machine.snapshot
        for observer in observers.values { observer.yield(machine.snapshot) }
    }
    public func currentSnapshot() -> TelegramSnapshot { machine.snapshot }

    public func restore() { start(create: false, explicit: false) }
    public func connect() {
        guard client == nil else { return }
        start(create: true, explicit: true)
    }

    public func retry() async {
        // TDLib resumes persisted auth=logout/auth=destroy itself. Retrying a
        // live cleanup must never interrupt its server-side revocation.
        if client != nil, logoutInProgress || rawAuth == "authorizationStateLoggingOut" { return }
        if profile?.manifest.cleanup == .logout {
            if client == nil { start(create: false, explicit: false) }
            return
        }
        if await close() { connect() }
    }

    private func start(create: Bool, explicit: Bool, phone: Bool = false) {
        guard client == nil else { return }
        machine = TelegramAuthorizationMachine()
        epoch = UUID(); rawAuth = ""; pending.removeAll(); initializationChecks.removeAll()
        parametersSent = false; qrRequested = false; phoneSelected = phone; identifying = false
        closing = false; logoutRequested = false; destroyRequested = false; revoked = false; account = nil
        authDeadline = nil; logoutDeadline = nil; logoutInProgress = false
        explicitAuthentication = explicit
        machine.snapshot.state = .starting
        publish()
        do {
            // No client, network, profile or Keychain key until Connect or an
            // existing profile is restored. Configuration absence is local.
            guard credentials != nil else {
                machine.snapshot.state = .disabled; machine.snapshot.failure = .configuration; publish(); return
            }
            if profile == nil { profile = try profiles.open(environment: environment, create: create) }
            guard let profile else { machine.snapshot.state = .disconnected; publish(); return }
            if profile.manifest.cleanup == .localOnly || profile.manifest.logoutCompleted == true {
                try finishRemoval(); return
            }
            machine.cleanup = profile.manifest.cleanup == .logout
            if machine.cleanup { machine.snapshot.state = .loggingOut }
            let emptyDatabase = try FileManager.default.contentsOfDirectory(atPath: profile.database.path).isEmpty
            databaseKey = try keys.key(account: profile.manifest.keyAccount,
                                       mayCreate: !profile.manifest.keyCreated && emptyDatabase)
            profile.manifest.keyCreated = true
            try profile.save()
            let index = try TelegramChatIndex(directory: profile.directory, environment: environment,
                                              account: Int64(profile.manifest.userID ?? "0") ?? 0)
            if machine.cleanup { try index.clearNotifications() }
            let client = try factory()
            self.client = client
            let chats = TelegramChatSession(index: index, send: { try client.send($0) })
            chats.observers = chatObservers; chats.pause = scanPause
            self.chats = chats
            let worker = TDLibReceiveQueue(client: client)
            let generation = epoch
            // Correlation is registered before sending the first request.
            send("getAuthorizationState", purpose: .probe)
            receiver = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    let result: Result<TDLibMessage?, any Error>
                    do { result = .success(try await worker.next()) }
                    catch { result = .failure(error) }
                    guard let self, await self.consume(result, epoch: generation) else { break }
                }
            }
        } catch {
            databaseKey = nil
            machine.snapshot.state = .blocked
            machine.snapshot.failure = TelegramFailure.classify(error)
            publish()
        }
    }

    private func send(_ method: String, _ fields: [String: TDLibValue] = [:], purpose: Purpose) {
        guard let client else { return }
        let token = UUID().uuidString
        var request = TDLibMessage(method, fields)
        request["@extra"] = .string(token)
        pending[token] = Pending(purpose: purpose, deadline: now().addingTimeInterval(timeout))
        do { try client.send(request) }
        catch {
            pending[token] = nil
            fail(.transport)
        }
    }

    private func initialize() {
        guard !parametersSent, let profile, let credentials, let key = databaseKey else { return }
        parametersSent = true
        send("getOption", ["name": .string("version")], purpose: .version)
        send("getOption", ["name": .string("commit_hash")], purpose: .commit)
        // The pin defers these replies until setTdlibParameters. Never await
        // either setOption before queuing parameters (spike finding).
        for (name, value) in Self.notificationOptions {
            send("setOption", ["name": .string(name), "value": .object([
                "@type": .string("optionValueInteger"), "value": .integer(value)
            ])], purpose: .optionAck(name))
        }
        send("setTdlibParameters", [
            "use_test_dc": .bool(environment == .test),
            "database_directory": .string(profile.database.path), "files_directory": .string(profile.files.path),
            "database_encryption_key": .string(key.base64EncodedString()),
            "use_file_database": .bool(true), "use_chat_info_database": .bool(true), "use_message_database": .bool(true),
            "use_secret_chats": .bool(false), "api_id": .integer(Int64(credentials.apiID)), "api_hash": .string(credentials.apiHash),
            "system_language_code": .string("en"), "device_model": .string("AgentPad Mac"),
            "system_version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "application_version": .string(applicationVersion)
        ], purpose: .parameters)
        databaseKey = nil
        // Wait for the restored auth state before deciding to send logOut:
        // the pin automatically continues LoggingOut after initialization.
    }
    private static let notificationOptions: [(String, Int64)] = [
        ("notification_group_size_max", Int64(TelegramNotificationLimits.perGroup)),
        ("notification_group_count_max", Int64(TelegramNotificationLimits.groups))
    ]

    /// No awaits here: apply each response/update in receive order before the
    /// next receive, including early notification snapshots and auth changes.
    private func consume(_ result: Result<TDLibMessage?, any Error>, epoch: UUID) -> Bool {
        guard self.epoch == epoch, client != nil else { return false }
        switch result {
        case .failure: fail(.transport); requestClose()
        case .success(let message):
            if let message {
                if message.type == "updateAccentColors" { accentColors = TelegramFeedSession.decodeSponsoredColors(message) }
                if message.type == "updateAuthorizationState", let state = message["authorization_state"]?.object {
                    authorization(state)
                } else if message.type == "updateConnectionState" {
                    switch message["state"]?.object?.type {
                    case "connectionStateReady": machine.snapshot.network = .ready
                    case "connectionStateUpdating": machine.snapshot.network = .updating
                    case "connectionStateConnecting", "connectionStateConnectingToProxy": machine.snapshot.network = .connecting
                    default: machine.snapshot.network = .waiting
                    }
                } else if message.type == "updateActiveNotifications" {
                    machine.snapshot.receivedNotificationSnapshot = true
                }
                if let token = message["@extra"]?.string, let request = pending.removeValue(forKey: token) {
                    response(message, for: request.purpose)
                }
                if !machine.cleanup, !closing, !revoked {
                    chats?.receive(message, now: now())
                    if chats?.notificationProtocolFailed == true { fail(.transport); requestClose() }
                    conversations?.receive(message, now: now(), uptime: ProcessInfo.processInfo.systemUptime)
                }
            }
        }
        checkTimeouts()
        chats?.network = machine.snapshot.network
        if !machine.cleanup, !closing {
            conversations?.network = machine.snapshot.network
            conversations?.tick(now: now(), uptime: ProcessInfo.processInfo.systemUptime)
            chats?.tick(now: now())
        }
        publish()
        return self.epoch == epoch && client != nil
    }

    private func authorization(_ state: TDLibMessage) {
        rawAuth = state.type
        authDeadline = nil
        // Cleanup survives process death and wins over any late Ready/form.
        if machine.cleanup {
            switch state.type {
            case "authorizationStateWaitTdlibParameters": initialize()
            case "authorizationStateLoggingOut": observeLogout()
            case "authorizationStateClosing": break
            case "authorizationStateClosed": didClose()
            default: requestLogout()
            }
            return
        }
        if closing {
            if state.type == "authorizationStateClosed" { didClose() }
            return
        }
        if state.type == "authorizationStateLoggingOut" {
            try? chats?.index.clearNotifications()
            revoked = true; account = nil; invalidateForms(); conversations?.stop(); conversations = nil; chats?.stop()
        }
        // A restored, revoked session must not silently start a new QR flow.
        if state.type == "authorizationStateWaitPhoneNumber", profile?.manifest.userID != nil, !explicitAuthentication {
            machine.snapshot.state = .reauthenticationRequired
            requestClose()
            return
        }
        let effect = machine.transition(state, now: now())
        switch effect {
        case .initialize: initialize()
        case .qr: advanceAuthentication()
        case .identify:
            guard !identifying else { return }
            identifying = true
            send("getMe", purpose: .me)
        case .closed: didClose()
        case .none: break
        }
    }

    private func response(_ response: TDLibMessage, for purpose: Purpose) {
        // Ignore form replies after another TDLib auth state replaced that form.
        if case .form(let revision) = purpose, revision != machine.snapshot.revision { return }
        if purpose == .qr, machine.snapshot.state != .requestingQR { return }
        if machine.cleanup {
            // Form/option requests can be aborted by TDLib's own shutdown.
            // Their late failures must not turn logout into an ordinary close.
            switch purpose { case .probe, .parameters, .logout, .close, .destroy: break; default: return }
        }
        if closing, purpose != .close, purpose != .logout, purpose != .destroy { return }
        if response.type == "error" {
            let failure = TelegramFailure.rpc(response, parameters: purpose == .parameters)
            switch purpose {
            case .logout:
                if response["code"]?.integer == 400, response["message"]?.string == "Already logging out" {
                    observeLogout()
                } else {
                    machine.snapshot.state = .cleanupPending; machine.snapshot.failure = .logoutUnconfirmed; requestClose()
                }
            case .close, .destroy:
                machine.snapshot.failure = failure
            case .form, .qr:
                authDeadline = nil
                machine.snapshot.isSubmitting = false; machine.snapshot.failure = failure
                if purpose == .qr { machine.snapshot.state = .phoneNumber; phoneSelected = true }
            default: fail(failure); requestClose()
            }
            return
        }
        switch purpose {
        case .probe:
            if rawAuth.isEmpty { authorization(response) }
        case .version:
            guard response.type == "optionValueString", response["value"]?.string == TelegramBuild.version else {
                fail(.initialization); requestClose(); return
            }
            initializationChecks.insert("version")
        case .commit:
            guard response.type == "optionValueString", response["value"]?.string == TelegramBuild.commit else {
                fail(.initialization); requestClose(); return
            }
            initializationChecks.insert("commit")
        case .parameters:
            guard response.type == "ok" else { fail(.initialization); requestClose(); return }
            initializationChecks.insert("parameters")
        case .optionAck(let name):
            guard response.type == "ok" else { fail(.initialization); requestClose(); return }
            initializationChecks.insert("ack:" + name)
        case .optionValue(let name):
            guard response.type == "optionValueInteger",
                  response["value"]?.integer == Self.notificationOptions.first(where: { $0.0 == name })?.1 else {
                fail(.initialization); requestClose(); return
            }
            initializationChecks.insert("value:" + name)
        case .qr:
            // WaitOtherDeviceConfirmation carries/renews the link. Ok isn't a
            // successful login, and a timeout must not create a duplicate RPC.
            break
        case .form:
            // Wait for TDLib's next state before enabling another submission.
            break
        case .me:
            guard machine.authorizationReady, let id = response["id"]?.integer, id > 0, response.type == "user" else {
                fail(.accountMismatch); requestClose(); return
            }
            do {
                try profile?.bind(userID: id, environment: environment)
                let name = [response["first_name"]?.string, response["last_name"]?.string].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " ")
                let names = response["usernames"]?.object?["active_usernames"]
                let username: String?
                if case .array(let values) = names { username = values.first?.string } else { username = nil }
                account = TelegramAccount(userID: id, displayName: name, username: username)
                try chats?.index.apply(TDLibMessage("updateUser", ["user": .object(response.fields)]), now: Int64(now().timeIntervalSince1970))
            } catch { fail(TelegramFailure.classify(error)); requestClose() }
        case .logout:
            // Before Ready the pin replies Ok as soon as key destruction starts.
            // Keep the profile/key until TDLib finishes and closes on its own.
            if response.type == "ok" { observeLogout() }
        case .close, .destroy: break // Only the Closed update releases the lease.
        }
        guard !machine.cleanup else { return }
        let ackSet: Set<String> = ["parameters", "ack:notification_group_size_max", "ack:notification_group_count_max"]
        if ackSet.isSubset(of: initializationChecks), !initializationChecks.contains("readbackSent") {
            initializationChecks.insert("readbackSent")
            for (name, _) in Self.notificationOptions { send("getOption", ["name": .string(name)], purpose: .optionValue(name)) }
        }
        let verified: Set<String> = ["version", "commit", "parameters", "value:notification_group_size_max", "value:notification_group_count_max"]
        if verified.isSubset(of: initializationChecks) {
            machine.snapshot.optionsVerified = true
            advanceAuthentication()
        }
    }

    private func advanceAuthentication() {
        guard machine.snapshot.optionsVerified, !machine.cleanup, !closing,
              machine.snapshot.state != .blocked else { return }
        if machine.authorizationReady, let account {
            machine.snapshot.state = .connected(account); machine.snapshot.failure = nil
            machine.snapshot.isSubmitting = false
            if chats?.active == false {
                do {
                    try chats?.activate(account: account.userID, user: nil, now: now())
                    if let profile, let client, let chats {
                        // initialize() deliberately releases its temporary DB
                        // key. Read it again off MainActor to derive the vault
                        // key; do not retain the raw database key for the UI.
                        let key = try keys.key(account: profile.manifest.keyAccount, mayCreate: false)
                        let journal = try TelegramSendJournal(directory: profile.directory, databaseKey: key, now: now())
                        let feed = TelegramFeedSession(account: account.userID, environment: environment, epoch: epoch, journal: journal, send: { try client.send($0) })
                        feed.active = applicationActive
                        feed.sponsoredDisk = try TelegramSponsoredDiskCache(root: profile.directory.appendingPathComponent("sponsored", isDirectory: true), source: profile.files)
                        feed.sponsoredColors = accentColors
                        feed.externalInteractive = { [weak chats] in chats?.interactiveCount ?? 0 }
                        feed.nameLookup = { [weak chats] in try? chats?.index.userTitle($0) }
                        feed.chatNameLookup = { [weak chats] in try? chats?.index.chatTitle($0) }
                        feed.accountRetryAt = { [weak chats] in chats?.retryNotBefore ?? .distantPast }
                        feed.onFloodWait = { [weak chats] in chats?.deferRequests(until: $0) }
                        chats.otherInteractiveCount = { [weak feed] in feed?.interactiveCount ?? 0 }
                        conversations = feed
                    }
                }
                catch { fail(.storage); requestClose() }
            }
        } else if rawAuth == "authorizationStateWaitPhoneNumber", !qrRequested {
            if phoneSelected { machine.snapshot.state = .phoneNumber }
            else {
                qrRequested = true
                machine.snapshot.state = .requestingQR
                authDeadline = now().addingTimeInterval(timeout)
                send("requestQrCodeAuthentication", ["other_user_ids": .array([])], purpose: .qr)
            }
        }
    }

    public func usePhone(attemptID: UUID, revision: UInt64) {
        guard matches(attemptID, revision), !machine.snapshot.isSubmitting else { return }
        guard rawAuth == "authorizationStateWaitPhoneNumber" || rawAuth == "authorizationStateWaitOtherDeviceConfirmation" else { return }
        if qrRequested || rawAuth == "authorizationStateWaitOtherDeviceConfirmation" {
            // The pin rejects phone entry in WaitOtherDeviceConfirmation and
            // restores that QR state after close. logOut -> Closed resets it;
            // only then create a phone-first client with a fresh profile.
            phoneAfterLogout = true
            beginLogout()
        } else {
            phoneSelected = true
            machine.snapshot.revision &+= 1
            machine.snapshot.state = .phoneNumber; machine.snapshot.failure = nil; publish()
        }
    }

    public func useQR(attemptID: UUID, revision: UInt64) {
        guard matches(attemptID, revision), !machine.snapshot.isSubmitting,
              machine.snapshot.state == .phoneNumber, rawAuth == "authorizationStateWaitPhoneNumber" else { return }
        phoneSelected = false; qrRequested = false
        machine.snapshot.revision &+= 1
        machine.snapshot.failure = nil
        advanceAuthentication(); publish()
    }

    public func submit(_ input: TelegramAuthInput, attemptID: UUID, revision: UInt64) {
        guard matches(attemptID, revision), !machine.snapshot.isSubmitting, machine.snapshot.optionsVerified else { return }
        let method: String
        let fields: [String: TDLibValue]
        switch (machine.snapshot.state, input) {
        case (.phoneNumber, .phone(let value)) where !value.isEmpty && rawAuth == "authorizationStateWaitPhoneNumber":
            method = "setAuthenticationPhoneNumber"; fields = ["phone_number": .string(value), "settings": .null]
        case (.code, .code(let value)) where !value.isEmpty:
            method = "checkAuthenticationCode"; fields = ["code": .string(value)]
        case (.emailAddress, .email(let value)) where !value.isEmpty:
            method = "setAuthenticationEmailAddress"; fields = ["email_address": .string(value)]
        case (.emailCode, .emailCode(let value)) where !value.isEmpty:
            method = "checkAuthenticationEmailCode"; fields = ["code": .object(["@type": .string("emailAddressAuthenticationCode"), "code": .string(value)])]
        case (.password, .password(let value)) where !value.isEmpty:
            method = "checkAuthenticationPassword"; fields = ["password": .string(value)]
        case (.code(let info), .resend) where info.resendAvailableAt.map({ $0 <= now() }) == true:
            method = "resendAuthenticationCode"; fields = ["reason": .null]
        case (.emailCode, .resend): method = "resendAuthenticationCode"; fields = ["reason": .null]
        default: return
        }
        machine.snapshot.isSubmitting = true; machine.snapshot.failure = nil
        authDeadline = now().addingTimeInterval(timeout)
        send(method, fields, purpose: .form(revision)); publish()
    }

    private func matches(_ id: UUID, _ revision: UInt64) -> Bool {
        client != nil && !machine.cleanup && !closing && machine.snapshot.attemptID == id && machine.snapshot.revision == revision
    }

    public func disconnect() {
        phoneAfterLogout = false
        beginLogout()
    }

    private func beginLogout() {
        guard let profile else { return }
        do {
            profile.manifest.cleanup = .logout; try profile.save()
            try chats?.index.clearNotifications()
            machine.cleanup = true; invalidateForms(); account = nil
            conversations?.stop(); conversations = nil; chats?.stop()
            machine.snapshot.state = .loggingOut; machine.snapshot.failure = nil
            if client == nil { start(create: false, explicit: false) }
            else if parametersSent { requestLogout() }
            publish()
        } catch { fail(.storage); publish() }
    }

    private func requestLogout() {
        guard parametersSent, !rawAuth.isEmpty, rawAuth != "authorizationStateWaitTdlibParameters",
              rawAuth != "authorizationStateClosing", rawAuth != "authorizationStateClosed",
              !logoutRequested, !logoutInProgress, !closing, !destroyRequested else { return }
        if rawAuth == "authorizationStateLoggingOut" { observeLogout(); return }
        logoutRequested = true
        logoutDeadline = now().addingTimeInterval(timeout)
        send("logOut", purpose: .logout)
    }

    private func observeLogout() {
        if !logoutInProgress, logoutDeadline == nil { logoutDeadline = now().addingTimeInterval(timeout) }
        logoutInProgress = true
    }

    public func removeLocalData() {
        // Called only by the explicit, warned Settings action. This is NOT a
        // successful logout and does not revoke the session in Telegram Devices.
        phoneAfterLogout = false
        do {
            if profile == nil { profile = try profiles.open(environment: environment, create: false) }
            guard let profile else { return }
            profile.manifest.cleanup = .localOnly; try profile.save()
            try chats?.index.clearNotifications()
            machine.cleanup = true; invalidateForms(); account = nil
            conversations?.stop(); conversations = nil; chats?.stop()
            if client == nil { try finishRemoval() }
            else if !closing {
                destroyRequested = true
                machine.snapshot.state = .closing
                if parametersSent { send("destroy", purpose: .destroy) } else { requestClose() }
            }
        } catch { fail(TelegramFailure.classify(error)) }
        publish()
    }

    public func close() async -> Bool {
        phoneAfterLogout = false
        guard client != nil else { profile = nil; return true }
        invalidateForms()
        if !machine.cleanup, machine.snapshot.state != .blocked { machine.snapshot.state = .closing }
        requestClose()
        publish()
        return await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
            if closeDeadline == nil { closeDeadline = now().addingTimeInterval(min(timeout, 10)) }
        }
    }

    private func requestClose() {
        guard !closing, client != nil else { return }
        closing = true
        conversations?.stop(); conversations = nil; chats?.stop()
        send("close", purpose: .close)
    }

    private func didClose() {
        let keepFailure = machine.snapshot.state == .blocked
        // A close/destroy we requested can abort revocation. Only TDLib's own
        // Closed after a started logout proves it finished destroying auth keys.
        let completedLogout = machine.cleanup && logoutInProgress && !closing && !destroyRequested
        client?.release(); client = nil; receiver = nil; pending.removeAll(); databaseKey = nil
        conversations?.stop(); conversations = nil; chats?.stop(); chats = nil
        logoutDeadline = nil
        account = nil; machine.authorizationReady = false; invalidateForms()
        do {
            if completedLogout, let profile {
                profile.manifest.logoutCompleted = true
                try profile.save()
            }
            if profile?.manifest.cleanup == .localOnly || profile?.manifest.logoutCompleted == true {
                try finishRemoval()
                if completedLogout, phoneAfterLogout {
                    phoneAfterLogout = false
                    start(create: true, explicit: true, phone: true)
                }
            } else if profile?.manifest.cleanup == .logout {
                machine.snapshot.state = .cleanupPending; machine.snapshot.failure = .logoutUnconfirmed
            } else if !keepFailure {
                machine.snapshot.state = revoked || profile?.manifest.userID != nil ? .reauthenticationRequired : .disconnected
            }
        } catch { fail(TelegramFailure.classify(error)) }
        // Keep a lease for a pending cleanup/error in this process, released
        // by close()/quit or reused by an explicit retry. No other client can
        // open it while the user is deciding how to recover.
        let waiters = closeWaiters; closeWaiters.removeAll(); closeDeadline = nil
        for waiter in waiters { waiter.resume(returning: true) }
        publish()
    }

    private func finishRemoval() throws {
        guard let profile else { return }
        try keys.delete(account: profile.manifest.keyAccount)
        try profile.remove()
        self.profile = nil
        machine = TelegramAuthorizationMachine()
        publish()
    }

    private func invalidateForms() {
        machine.snapshot.attemptID = UUID(); machine.snapshot.revision &+= 1
        machine.snapshot.isSubmitting = false
        authDeadline = nil
    }
    private func fail(_ failure: TelegramFailure) {
        machine.snapshot.state = .blocked; machine.snapshot.failure = failure
        invalidateForms()
    }

    private func checkTimeouts() {
        let current = now()
        if let authDeadline, current >= authDeadline {
            machine.snapshot.failure = .timeout
            self.authDeadline = nil
        }
        if let logoutDeadline, current >= logoutDeadline {
            self.logoutDeadline = nil
            machine.snapshot.state = .cleanupPending; machine.snapshot.failure = .logoutUnconfirmed
            // This is a diagnostic timeout, including after logOut returned Ok.
            // Leave TDLib alive to finish revocation when the network returns.
        }
        for token in Array(pending.keys) {
            guard var request = pending[token], !request.timedOut, request.deadline <= current else { continue }
            request.timedOut = true; pending[token] = request
            switch request.purpose {
            case .logout: break // The whole logout has a deadline, not just its RPC.
            case .close, .destroy: machine.snapshot.failure = .timeout
            case .form(let revision) where revision != machine.snapshot.revision: break
            case .qr, .form, .me, .version, .commit, .optionAck, .optionValue:
                if !machine.cleanup { machine.snapshot.failure = .timeout }
            default: machine.snapshot.failure = .timeout
            }
            // Keep correlation until the late reply/Closed. No replay or local
            // rate limiter: TDLib may be handling FLOOD_WAIT inside the call.
        }
        if let closeDeadline, current >= closeDeadline {
            self.closeDeadline = nil
            let waiters = closeWaiters; closeWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: false) }
        }
    }

    public func chatSnapshots() -> AsyncStream<TelegramChatSnapshot> {
        let id = UUID()
        let pair = AsyncStream<TelegramChatSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        chatObservers[id] = pair.continuation; chats?.observers[id] = pair.continuation
        pair.continuation.yield(chats?.snapshot ?? TelegramChatSnapshot())
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeChatObserver(id) } }
        return pair.stream
    }
    private func removeChatObserver(_ id: UUID) { chatObservers[id] = nil; chats?.observers[id] = nil }
    public func chatPage(offset: Int, revision: UInt64) -> TelegramChatPage {
        let rows: [TelegramChatRow]
        if let chats, chats.active, chats.snapshot.revision == revision, offset < chats.snapshot.visibleCount {
            rows = (try? chats.index.page(offset: offset, limit: min(50, chats.snapshot.visibleCount - offset), now: Int64(now().timeIntervalSince1970))) ?? []
        } else { rows = [] }
        return TelegramChatPage(revision: revision, offset: offset, rows: rows)
    }
    public func expandChats(showLess: Bool) {
        guard let chats, chats.active else { return }
        chats.index.expandedCapacity = showLess ? nil : chats.snapshot.visibleCount + 10
        chats.publish(now: now(), force: true)
    }
    public func holdChatOrder(_ held: Bool, owner: UUID) {
        guard let chats else { return }
        if held && chats.holds.isEmpty { chats.index.heldVisibleCount = chats.snapshot.visibleCount }
        if held { chats.holds.insert(owner) } else { chats.holds.remove(owner) }
        chats.index.orderHeld = !chats.holds.isEmpty
        if !chats.index.orderHeld, chats.active { chats.index.heldVisibleCount = nil; chats.publish(now: now()) }
    }
    public func setChatMode(_ id: TelegramChatID, mode: TelegramChatMode) {
        guard let chats, chats.active, id.account == chats.index.account, id.environment == environment else { return }
        do { try chats.index.mode(id.chat, mode, now: Int64(now().timeIntervalSince1970)) }
        catch { chats.index.error = "The Telegram setting could not be saved on this Mac." }
        chats.publish(now: now(), force: true)
    }
    public func searchTelegram(_ query: String) -> AsyncStream<TelegramSearchSnapshot> {
        guard let chats, chats.active else {
            return AsyncStream { $0.yield(.init(query: query, notice: "Connect Telegram…")); $0.finish() }
        }
        let stream = chats.beginSearch(query, now: now())
        let generation = chats.generation
        chats.search?.continuation.onTermination = { [weak self] _ in Task { await self?.cancelChatSearch(generation) } }
        return stream
    }
    private func cancelChatSearch(_ generation: UInt64) { chats?.cancelSearch(generation) }
    public func resolveChat(_ hit: TelegramSearchHit) async -> TelegramChatRow? {
        guard let chats else { return nil }
        return await withCheckedContinuation { chats.resolve(hit, now: now(), continuation: $0) }
    }
    public func didOpenChat(_ id: TelegramChatID) { chats?.opened(id, now: now()) }
    public func chat(_ id: TelegramChatID) -> TelegramChatRow? {
        guard let chats, chats.active, id.account == chats.index.account, id.environment == environment else { return nil }
        return try? chats.index.get(id.chat, now: Int64(now().timeIntervalSince1970))
    }
    public func setAttentionDestinations(_ destinations: Set<TelegramChatID>) {
        guard let chats, chats.active else { return }
        chats.index.attentionDestinations = Set(destinations.filter { $0.account == chats.index.account && $0.environment == environment }.prefix(1000))
        chats.publish(now: now())
    }
    public func setDirectAttention(_ enabled: Bool) {
        guard let chats, chats.active else { return }
        do { try chats.index.setDirectAttention(enabled, now: Int64(now().timeIntervalSince1970)) }
        catch { chats.index.error = "The Telegram setting could not be saved on this Mac." }
        chats.publish(now: now())
    }
    public func snoozeAttention(_ id: TelegramChatID, undo: Bool) {
        guard let chats, chats.active, id.account == chats.index.account, id.environment == environment else { return }
        do { try chats.index.snooze(id.chat, undo: undo, now: Int64(now().timeIntervalSince1970)) }
        catch { chats.index.error = "The Telegram setting could not be saved on this Mac." }
        chats.publish(now: now())
    }
    public func setChannelNotifications(_ id: TelegramChatID, enabled: Bool) {
        guard let chats, chats.active, id.account == chats.index.account, id.environment == environment else { return }
        do { try chats.index.channelNotifications(id.chat, enabled: enabled, now: Int64(now().timeIntervalSince1970)) }
        catch { chats.index.error = "The Telegram setting could not be saved on this Mac." }
        chats.publish(now: now())
    }
    public func consumeNotification(_ id: String) -> Bool {
        guard let chats, chats.active else { return false }
        do { try chats.index.consumeNotification(id, now: Int64(now().timeIntervalSince1970)) }
        catch { chats.index.error = "Telegram notification state could not be saved on this Mac."; chats.publish(now: now()); return false }
        chats.publish(now: now()); return true
    }
    public func setChatScanPaused(_ reason: String?) { scanPause = reason; chats?.pause = reason; chats?.tick(now: now()) }

    public func conversation(_ id: TelegramChatID, pane: UUID) -> AsyncStream<TelegramConversationSnapshot> {
        guard let conversations else { return AsyncStream { $0.finish() } }
        let stream = conversations.subscribe(id, pane: pane)
        let epoch = conversations.epoch
        conversations.feeds[id]?.observers[pane]?.onTermination = { [weak self] _ in
            Task { await self?.releaseConversation(id, pane: pane, epoch: epoch) }
        }
        conversations.tick(now: now(), uptime: ProcessInfo.processInfo.systemUptime)
        return stream
    }
    public func releaseConversation(_ id: TelegramChatID, pane: UUID, epoch: UUID) {
        guard conversations?.matches(id, epoch) == true else { return }; conversations?.release(id, pane: pane)
    }
    public func loadHistory(_ id: TelegramChatID, epoch: UUID, latest: Bool) {
        guard let conversations, conversations.matches(id, epoch), let feed = conversations.feeds[id] else { return }
        if latest {
            feed.botInfoLoaded = false
            if conversations.scopeMute[conversations.muteScope(feed)] == nil { conversations.scopeMuteAttempted.remove(conversations.muteScope(feed)) }
            if feed.snapshot.replyKeyboard == nil { feed.replyMarkupID = feed.chat?["reply_markup_message_id"]?.integer ?? 0 }
        }
        if !feed.snapshot.capabilities.canRead { feed.needsDetails = true }
        else { conversations.load(feed, latest: latest) }
    }
    @discardableResult public func updateDraft(_ id: TelegramChatID, epoch: UUID, draft: TelegramDraft) -> Bool {
        let saved = conversations?.draft(id, epoch: epoch, value: draft) ?? false
        conversations?.publish(); return saved
    }
    public func sendDraft(_ id: TelegramChatID, epoch: UUID, draft: TelegramDraft) { conversations?.sendDraft(id, epoch: epoch, draft: draft); conversations?.publish() }
    public func retryMessage(_ id: TelegramChatID, epoch: UUID, message: Int64) { conversations?.retry(id, epoch: epoch, messageID: message) }
    public func recoverMessage(_ id: TelegramChatID, epoch: UUID, operation: UUID) { conversations?.recover(id, epoch: epoch, operation: operation); conversations?.publish() }
    public func discardRecovery(_ id: TelegramChatID, epoch: UUID, operation: UUID) { conversations?.discardRecovery(id, epoch: epoch, operation: operation); conversations?.publish() }
    public func observePresentation(_ id: TelegramChatID, observation: TelegramPresentationObservation) {
        conversations?.now = now()
        conversations?.observation(id, observation)
        guard observation.isCurrent, observation.active, observation.shown, applicationActive,
              let conversations, conversations.matches(id, observation.epoch), let feed = conversations.feeds[id],
              feed.observers[observation.pane] != nil, feed.snapshot.capabilities.canRead else { return }
        let ids = observation.ordinaryIDs.intersection(Set(feed.snapshot.messages.map(\.messageID)))
        if !ids.isEmpty { try? chats?.index.viewedMessages(chat: id.chat, ids: ids, now: Int64(now().timeIntervalSince1970)) }
    }
    public func loadMessage(_ id: TelegramChatID, epoch: UUID, message: Int64) {
        guard let conversations, conversations.matches(id, epoch), let feed = conversations.feeds[id],
              message > 0 else { return }
        feed.requestedMessage = message
        conversations.tick(now: now(), uptime: ProcessInfo.processInfo.systemUptime)
    }
    public func setApplicationActive(_ active: Bool) {
        applicationActive = active; conversations?.active = active
        conversations?.tick(now: now(), uptime: ProcessInfo.processInfo.systemUptime)
    }
    public func composerActivity(_ id: TelegramChatID, epoch: UUID, pane: UUID, typing: Bool) {
        conversations?.composer(id, epoch: epoch, pane: pane, typing: typing)
    }
    public func stageAttachment(_ id: TelegramChatID, epoch: UUID, data: Data, name: String, mime: String, width: Int, height: Int) throws -> TelegramStagedAttachment {
        guard let conversations else { throw TelegramConversationError.unavailable }
        return try conversations.stage(id, epoch: epoch, data: data, name: name, mime: mime, width: width, height: height)
    }
    public func discardAttachment(_ id: TelegramChatID, epoch: UUID, file: UUID) {
        guard let conversations, conversations.matches(id, epoch) else { return }; conversations.journal.removeStage(file)
    }
    public func downloadAttachment(_ id: TelegramChatID, epoch: UUID, message: Int64, cancel: Bool) {
        conversations?.download(id, epoch: epoch, messageID: message, cancel: cancel)
    }
    public func attachmentURL(_ id: TelegramChatID, epoch: UUID, message: Int64) throws -> URL {
        guard let conversations, let profile else { throw TelegramConversationError.unavailable }
        return try conversations.attachmentURL(id, epoch: epoch, messageID: message, filesRoot: profile.files)
    }
    public func attachmentImportDirectory(_ id: TelegramChatID, epoch: UUID) throws -> URL {
        guard let conversations, conversations.matches(id, epoch), conversations.feeds[id]?.snapshot.capabilities.canSend == true else { throw TelegramConversationError.unavailable }
        return try conversations.journal.importDirectory()
    }
    public func removeAttachmentImportDirectory(_ id: TelegramChatID, epoch: UUID, directory: URL) {
        guard let conversations, conversations.matches(id, epoch) else { return }; conversations.journal.removeImportDirectory(directory)
    }
    public func setAttachmentCacheLimit(_ id: TelegramChatID, epoch: UUID, mebibytes: Int) {
        guard let conversations, conversations.matches(id, epoch) else { return }; conversations.setCacheLimit(mebibytes)
    }
    public func clearAttachmentCache(_ id: TelegramChatID, epoch: UUID) {
        guard let conversations, conversations.matches(id, epoch) else { return }; conversations.clearCache()
    }
    public func externalMessageLink(_ id: TelegramChatID, epoch: UUID, message: Int64) async -> URL? {
        guard let conversations, conversations.matches(id, epoch), conversations.feeds[id]?.snapshot.messages.contains(where: { $0.messageID == message }) == true else { return nil }
        return await withCheckedContinuation { continuation in
            let sent = conversations.request("getMessageLink", ["chat_id": .integer(id.chat), "message_id": .integer(message),
                "media_timestamp": .integer(0), "checklist_task_id": .integer(0), "poll_option_id": .string(""), "for_album": .bool(false), "in_message_thread": .bool(false)]) { [weak conversations] response in
                    guard conversations?.matches(id, epoch) == true, response.type == "messageLink", let link = response["link"]?.string,
                          let url = URL(string: link), url.scheme == "https", ["t.me", "telegram.me"].contains(url.host?.lowercased() ?? ""), url.user == nil, url.password == nil else {
                        continuation.resume(returning: nil); return
                    }
                    continuation.resume(returning: url)
                }
            if !sent { continuation.resume(returning: nil) }
        }
    }

    public func performBotAction(_ id: TelegramChatID, epoch: UUID, action: TelegramBotAction) async -> TelegramBotActionResult {
        guard let conversations else { return .error("Telegram is disconnected") }
        return await withCheckedContinuation { continuation in
            conversations.botAction(id, epoch: epoch, action: action) { continuation.resume(returning: $0) }
            conversations.publish()
        }
    }
    public func checkInlineQuery(_ id: TelegramChatID, epoch: UUID, text: String) async -> TelegramInlineQueryCheck {
        guard let conversations else { return .unavailable }
        return await withCheckedContinuation { continuation in
            conversations.inspectInlineQuery(id, epoch: epoch, text: text) { continuation.resume(returning: $0) }
        }
    }
    public func conversationIsCurrent(_ id: TelegramChatID, epoch: UUID) -> Bool {
        conversations?.matches(id, epoch) == true && conversations?.feeds[id]?.snapshot.capabilities.canRead == true
    }

    public func performSponsoredAction(_ id: TelegramChatID, epoch: UUID, action: TelegramSponsoredAction) async -> TelegramSponsoredActionResult {
        guard let conversations else { return .error("Telegram is disconnected") }
        conversations.now = now()
        return await withCheckedContinuation { continuation in
            conversations.sponsoredAction(id, epoch: epoch, action: action) { continuation.resume(returning: $0) }
            conversations.publish()
        }
    }

}
