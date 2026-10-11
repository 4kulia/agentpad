import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramConnectorTests: XCTestCase, @unchecked Sendable {
    func testNoClientBeforeConnectAndOneClientAcrossWindows() async throws {
        let fixture = try TelegramFixture()
        let disabled = LocalTDLibConnector(credentials: nil, applicationVersion: "test", clientFactory: { throw TelegramStorageError.io })
        await disabled.connect()
        let unavailable = await disabled.currentSnapshot()
        XCTAssertEqual(unavailable.state, .disabled)
        let live = try fixture.connector()
        await live.restore()
        XCTAssertTrue(fixture.client.requests.isEmpty)
        await live.connect(); await live.connect()
        await eventually { await isQR(live) }
        XCTAssertEqual(fixture.client.requests.filter { $0.type == "getAuthorizationState" }.count, 1)
        XCTAssertFalse(fixture.client.mainThreadReceives)
        _ = await live.close()
    }

    func testOptionsQueuedBeforeParametersThenAcknowledgedAndReadBack() async throws {
        let fixture = try TelegramFixture(), connector: LocalTDLibConnector
        connector = try fixture.connector()
        await connector.connect()
        await eventually { await isQR(connector) }
        let requests = fixture.client.requests
        let parameters = try XCTUnwrap(requests.firstIndex { $0.type == "setTdlibParameters" })
        let options = requests.enumerated().filter { $0.element.type == "setOption" }
        XCTAssertEqual(options.count, 2)
        XCTAssertTrue(options.allSatisfy { $0.offset < parameters })
        XCTAssertEqual(requests[parameters]["use_test_dc"], .bool(true))
        XCTAssertEqual(requests[parameters]["use_secret_chats"], .bool(false))
        let key = try XCTUnwrap(requests[parameters]["database_encryption_key"]?.string.flatMap { Data(base64Encoded: $0) })
        XCTAssertEqual(key.count, 32)
        let snapshot = await connector.currentSnapshot()
        XCTAssertTrue(snapshot.optionsVerified)
        XCTAssertTrue(snapshot.receivedNotificationSnapshot)
        _ = await connector.close()
    }

    func testReadbackMismatchNeverBecomesReady() async throws {
        let fixture = try TelegramFixture(); fixture.client.optionReadback = 0
        let connector = try fixture.connector()
        await connector.connect()
        await eventually { await connector.currentSnapshot().failure == .initialization }
        XCTAssertFalse(fixture.client.requests.contains { $0.type == "requestQrCodeAuthentication" })
        _ = await connector.close()
    }

    func testQRPasswordAndGetMeBindingBeforeConnected() async throws {
        let fixture = try TelegramFixture(); fixture.client.automaticMe = false
        let connector = try fixture.connector()
        await connector.connect()
        await eventually { await isQR(connector) }
        fixture.client.auth("authorizationStateWaitPassword", ["password_hint": .string("hint")])
        await eventually { await connector.currentSnapshot().state == .password(hint: "hint") }
        let form = await connector.currentSnapshot()
        await connector.submit(.password("fake password"), attemptID: form.attemptID, revision: form.revision)
        await connector.submit(.password("duplicate"), attemptID: form.attemptID, revision: form.revision)
        XCTAssertEqual(fixture.client.requests.filter { $0.type == "checkAuthenticationPassword" }.count, 1)
        fixture.client.auth("authorizationStateReady")
        await eventually { fixture.client.requests.contains { $0.type == "getMe" } }
        let waiting = await connector.currentSnapshot()
        XCTAssertEqual(waiting.state, .verifyingAccount)
        fixture.client.reply(try XCTUnwrap(fixture.client.requests.last { $0.type == "getMe" }), FakeTDLibClient.user)
        await eventually {
            if case .connected(let account) = await connector.currentSnapshot().state { return account.userID == 9007199254740991 }
            return false
        }
        await connector.submit(.password("stale"), attemptID: form.attemptID, revision: form.revision)
        XCTAssertEqual(fixture.client.requests.filter { $0.type == "checkAuthenticationPassword" }.count, 1)
        _ = await connector.close()
    }

    func testPhoneCodeEmailFallbackAndResendGate() async throws {
        let fixture = try TelegramFixture(), connector: LocalTDLibConnector
        connector = try fixture.connector()
        await connector.connect(); await eventually { await isQR(connector) }
        var form = await connector.currentSnapshot()
        await connector.usePhone(attemptID: form.attemptID, revision: form.revision)
        await eventually { await connector.currentSnapshot().state == .phoneNumber }
        let phoneClient = fixture.latestClient
        form = await connector.currentSnapshot()
        await connector.submit(.phone("+9996612345"), attemptID: form.attemptID, revision: form.revision)
        XCTAssertEqual(phoneClient.requests.last?.type, "setAuthenticationPhoneNumber")
        await eventually { if case .code = await connector.currentSnapshot().state { true } else { false } }
        form = await connector.currentSnapshot()
        await connector.submit(.resend, attemptID: form.attemptID, revision: form.revision)
        XCTAssertFalse(phoneClient.requests.contains { $0.type == "resendAuthenticationCode" })
        await connector.submit(.code("12345"), attemptID: form.attemptID, revision: form.revision)
        XCTAssertEqual(phoneClient.requests.last?.type, "checkAuthenticationCode")
        phoneClient.auth("authorizationStateWaitEmailAddress")
        await eventually { await connector.currentSnapshot().state == .emailAddress }
        form = await connector.currentSnapshot()
        await connector.submit(.email("test@example.test"), attemptID: form.attemptID, revision: form.revision)
        XCTAssertEqual(phoneClient.requests.last?.type, "setAuthenticationEmailAddress")
        phoneClient.auth("authorizationStateWaitEmailCode")
        await eventually { await connector.currentSnapshot().state == .emailCode(pattern: "") }
        form = await connector.currentSnapshot()
        await connector.submit(.emailCode("12345"), attemptID: form.attemptID, revision: form.revision)
        XCTAssertEqual(phoneClient.requests.last?["code"]?.object?.type, "emailAddressAuthenticationCode")
        _ = await connector.close()
    }

    func testTimeoutKeepsInFlightRequestAndAcceptsLateState() async throws {
        let fixture = try TelegramFixture(); fixture.client.automaticQR = false
        let connector = try fixture.connector(timeout: 0.05)
        await connector.connect()
        await eventually { await connector.currentSnapshot().failure == .timeout }
        await connector.connect()
        XCTAssertEqual(fixture.client.requests.filter { $0.type == "requestQrCodeAuthentication" }.count, 1)
        fixture.client.auth("authorizationStateWaitOtherDeviceConfirmation", ["link": .string("tg://login?token=late")])
        await eventually { await isQR(connector) }
        _ = await connector.close()
    }

    func testClosePreservesSessionAndKeyWithoutLogoutOrDestroy() async throws {
        let fixture = try TelegramFixture(), connector: LocalTDLibConnector
        connector = try fixture.connector()
        await connector.connect(); await eventually { await isQR(connector) }
        let closed = await connector.close()
        XCTAssertTrue(closed)
        XCTAssertEqual(fixture.client.releases, 1)
        XCTAssertFalse(fixture.client.requests.contains { ["logOut", "destroy"].contains($0.type) })
        let parameters = try XCTUnwrap(fixture.client.requests.first { $0.type == "setTdlibParameters" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(parameters["database_directory"]?.string)))
        _ = await connector.close() // releases the stopped profile lease
        let profile = try XCTUnwrap(fixture.profiles.open(environment: .test, create: false))
        XCTAssertNotNil(try fixture.keys.read(account: profile.manifest.keyAccount))
    }
    func testLogoutRemovesAfterTDLibCompletesAndCloses() async throws {
        let fixture = try TelegramFixture(), connector: LocalTDLibConnector
        connector = try fixture.connector()
        await connector.connect(); await eventually { await isQR(connector) }
        let parameters = try XCTUnwrap(fixture.client.requests.first { $0.type == "setTdlibParameters" })
        let database = try XCTUnwrap(parameters["database_directory"]?.string)
        await connector.disconnect()
        await eventually { await connector.currentSnapshot().state == .disconnected }
        XCTAssertEqual(fixture.client.releases, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database))
        XCTAssertNil(try fixture.profiles.open(environment: .test, create: false))
    }

    func testPreReadyLogoutOKPreservesProfileAndKeyAfterOrdinaryCloseAndRestart() async throws {
        let fixture = try TelegramFixture(); fixture.client.logoutBehavior = .acceptedPending
        let connector = try fixture.connector(timeout: 0.05)
        await connector.connect(); await eventually { await isQR(connector) }
        let saved = try manifest(fixture.client)
        await connector.disconnect()
        // The pin returns Ok before asynchronous auth-key destruction finishes.
        await eventually { await connector.currentSnapshot().state == .cleanupPending }
        XCTAssertNotEqual(try manifest(fixture.client).logoutCompleted, true)
        XCTAssertNotNil(try fixture.keys.read(account: saved.keyAccount))
        XCTAssertFalse(fixture.client.requests.contains { $0.type == "close" })
        let closed = await connector.close()
        XCTAssertTrue(closed)
        XCTAssertNotEqual(try manifest(fixture.client).logoutCompleted, true)
        _ = await connector.close() // release the stopped profile lease

        let resumedClient = FakeTDLibClient(database: fixture.client.database)
        let resumed = try fixture.connector(client: resumedClient)
        await resumed.restore()
        await eventually { resumedClient.requests.contains { $0.type == "setTdlibParameters" } }
        XCTAssertNotNil(try fixture.keys.read(account: saved.keyAccount))
        XCTAssertEqual(try manifest(resumedClient).cleanup, .logout)
        resumedClient.completeLogout()
        await eventually { await resumed.currentSnapshot().state == .disconnected }
        XCTAssertNil(try fixture.keys.read(account: saved.keyAccount))
        XCTAssertNil(try fixture.profiles.open(environment: .test, create: false))
        XCTAssertFalse(resumedClient.requests.contains { ["logOut", "close", "requestQrCodeAuthentication"].contains($0.type) })
    }

    func testOfflineLogoutAndRestoredContinuationSurviveTimeoutAndRetry() async throws {
        let fixture = try TelegramFixture(); fixture.client.logoutBehavior = .silent
        let connector = try fixture.connector(timeout: 0.05)
        await connector.connect(); await eventually { await isQR(connector) }
        fixture.client.auth("authorizationStateReady")
        await eventually { if case .connected = await connector.currentSnapshot().state { true } else { false } }
        let saved = try manifest(fixture.client)
        await connector.disconnect()
        await eventually { await connector.currentSnapshot().state == .cleanupPending }
        await connector.retry(); await connector.retry()
        XCTAssertEqual(fixture.client.requests.filter { $0.type == "logOut" }.count, 1)
        XCTAssertFalse(fixture.client.requests.contains { $0.type == "close" })
        XCTAssertEqual(fixture.client.releases, 0)
        _ = await connector.close(); _ = await connector.close()

        let resumedClient = FakeTDLibClient(database: fixture.client.database)
        let resumed = try fixture.connector(timeout: 0.05, client: resumedClient)
        await resumed.restore()
        await eventually { await resumed.currentSnapshot().state == .cleanupPending }
        await resumed.retry(); await resumed.disconnect()
        XCTAssertFalse(resumedClient.requests.contains { ["logOut", "close", "destroy"].contains($0.type) })
        XCTAssertEqual(resumedClient.releases, 0)
        XCTAssertNotNil(try fixture.keys.read(account: saved.keyAccount))
        // Restored TDLib has no logOut RPC to acknowledge; its own completion
        // must still remove the profile and key when connectivity returns.
        resumedClient.completeLogout()
        await eventually { await resumed.currentSnapshot().state == .disconnected }
        XCTAssertNil(try fixture.keys.read(account: saved.keyAccount))
        XCTAssertNil(try fixture.profiles.open(environment: .test, create: false))
    }

    func testAlreadyLoggingOutIsInProgressAndRetryDoesNotClose() async throws {
        let fixture = try TelegramFixture(); fixture.client.logoutBehavior = .alreadyLoggingOut
        let connector = try fixture.connector(timeout: 0.05)
        await connector.connect(); await eventually { await isQR(connector) }
        await connector.disconnect()
        await eventually { await connector.currentSnapshot().state == .cleanupPending }
        await connector.retry()
        XCTAssertEqual(fixture.client.requests.filter { $0.type == "logOut" }.count, 1)
        XCTAssertFalse(fixture.client.requests.contains { $0.type == "close" })
        XCTAssertEqual(fixture.client.releases, 0)
        fixture.client.completeLogout()
        await eventually { await connector.currentSnapshot().state == .disconnected }
        XCTAssertNil(try fixture.profiles.open(environment: .test, create: false))
    }

    func testRetryDoesNotInterruptTDLibOwnRevocation() async throws {
        let fixture = try TelegramFixture(), connector: LocalTDLibConnector
        connector = try fixture.connector()
        await connector.connect(); await eventually { await isQR(connector) }
        fixture.client.auth("authorizationStateReady")
        await eventually { if case .connected = await connector.currentSnapshot().state { true } else { false } }
        fixture.client.auth("authorizationStateLoggingOut")
        await eventually { await connector.currentSnapshot().state == .reauthenticationRequired }
        await connector.retry()
        XCTAssertFalse(fixture.client.requests.contains { ["logOut", "close"].contains($0.type) })
        XCTAssertEqual(fixture.client.releases, 0)
        fixture.client.completeLogout()
        await eventually { fixture.client.releases == 1 }
        await connector.retry()
        await eventually { await isQR(connector) }
        XCTAssertEqual(fixture.factory.clients.count, 2)
        _ = await connector.close()
    }

    func testAbortedInitializationOptionsDoNotInterruptRestoredLogout() async throws {
        let fixture = try TelegramFixture()
        var profile = try fixture.profiles.open(environment: .test, create: true)
        profile?.manifest.cleanup = .logout; try profile?.save(); profile = nil
        fixture.client.database.save(TDLibMessage("authorizationStateLoggingOut"))
        fixture.client.abortOptionAcknowledgements = true
        let connector = try fixture.connector(timeout: 0.05)
        await connector.restore()
        await eventually { await connector.currentSnapshot().state == .cleanupPending }
        XCTAssertFalse(fixture.client.requests.contains { ["close", "logOut"].contains($0.type) })
        fixture.client.completeLogout()
        await eventually { await connector.currentSnapshot().state == .disconnected }
        XCTAssertNil(try fixture.profiles.open(environment: .test, create: false))
    }

    func testCompletedLogoutCanFinishLocalRemovalAfterRestart() async throws {
        let fixture = try TelegramFixture(); fixture.client.logoutBehavior = .acceptedPending
        let connector = try fixture.connector()
        await connector.connect(); await eventually { await isQR(connector) }
        let saved = try manifest(fixture.client)
        await connector.disconnect()
        fixture.keys.error = .keyUnavailable
        fixture.client.completeLogout()
        await eventually { await connector.currentSnapshot().failure == .keyUnavailable }
        XCTAssertEqual(try manifest(fixture.client).logoutCompleted, true)
        _ = await connector.close()
        fixture.keys.error = nil
        let resumedClient = FakeTDLibClient(), resumed = try fixture.connector(client: resumedClient)
        await resumed.restore()
        let snapshot = await resumed.currentSnapshot()
        XCTAssertEqual(snapshot.state, .disconnected)
        XCTAssertTrue(resumedClient.requests.isEmpty)
        XCTAssertNil(try fixture.keys.read(account: saved.keyAccount))
        XCTAssertNil(try fixture.profiles.open(environment: .test, create: false))
    }

    func testLegacyLogoutConfirmedFlagDoesNotDeletePendingProfile() async throws {
        let fixture = try TelegramFixture()
        var profile = try fixture.profiles.open(environment: .test, create: true)
        let saved = try XCTUnwrap(profile).manifest
        _ = try TelegramDatabaseKeys(store: fixture.keys).key(account: saved.keyAccount, mayCreate: true)
        profile?.manifest.cleanup = .logout; profile?.manifest.keyCreated = true
        let url = try XCTUnwrap(profile).directory.appendingPathComponent("profile.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(profile).manifest)) as? [String: Any])
        legacy["logoutConfirmed"] = true
        try TelegramProfileStore.write(JSONSerialization.data(withJSONObject: legacy), to: url)
        profile = nil
        fixture.client.database.save(TDLibMessage("authorizationStateLoggingOut"))
        let connector = try fixture.connector(timeout: 0.05)
        await connector.restore()
        await eventually { await connector.currentSnapshot().state == .cleanupPending }
        XCTAssertNotNil(try fixture.keys.read(account: saved.keyAccount))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(fixture.client.requests.contains { ["logOut", "close"].contains($0.type) })
        fixture.client.completeLogout()
        await eventually { await connector.currentSnapshot().state == .disconnected }
    }

    func testQRPhoneFallbackWaitsForLogoutCompletionAndReachesPhoneLogin() async throws {
        let fixture = try TelegramFixture(); fixture.client.logoutBehavior = .acceptedPending
        let connector = try fixture.connector(timeout: 0.05)
        await connector.connect(); await eventually { await isQR(connector) }
        let qr = await connector.currentSnapshot()
        await connector.usePhone(attemptID: qr.attemptID, revision: qr.revision)
        await connector.submit(.phone("+9996612345"), attemptID: qr.attemptID, revision: qr.revision)
        fixture.client.auth("authorizationStateWaitOtherDeviceConfirmation", ["link": .string("tg://login?token=stale")])
        fixture.client.auth("authorizationStateReady") // a scan racing the switch
        await eventually { await connector.currentSnapshot().state == .cleanupPending }
        XCTAssertEqual(fixture.factory.clients.count, 1)
        XCTAssertFalse(fixture.client.requests.contains { ["setAuthenticationPhoneNumber", "getMe", "close"].contains($0.type) })
        await connector.retry()
        fixture.client.completeLogout()
        await eventually { await connector.currentSnapshot().state == .phoneNumber }
        XCTAssertEqual(fixture.factory.clients.count, 2)
        XCTAssertEqual(fixture.client.releases, 1)
        let phoneClient = fixture.latestClient
        XCTAssertFalse(phoneClient.requests.contains { $0.type == "requestQrCodeAuthentication" })
        var form = await connector.currentSnapshot()
        XCTAssertTrue(form.optionsVerified)
        await connector.submit(.phone("+9996612345"), attemptID: form.attemptID, revision: form.revision)
        await eventually { if case .code = await connector.currentSnapshot().state { true } else { false } }
        form = await connector.currentSnapshot()
        XCTAssertNil(form.failure)
        await connector.submit(.code("12345"), attemptID: form.attemptID, revision: form.revision)
        phoneClient.auth("authorizationStateReady")
        await eventually { if case .connected = await connector.currentSnapshot().state { true } else { false } }
        _ = await connector.close()
    }

    func testRestoredQRCanSwitchToPhoneAndBackToRenewingQR() async throws {
        let fixture = try TelegramFixture(), connector: LocalTDLibConnector
        connector = try fixture.connector()
        await connector.connect(); await eventually { await isQR(connector) }
        _ = await connector.close()
        await connector.connect(); await eventually { await isQR(connector) }
        // The pin restores the saved QR even without a new QR request.
        let restoredQRClient = fixture.latestClient
        XCTAssertFalse(restoredQRClient.requests.contains { $0.type == "requestQrCodeAuthentication" })
        var form = await connector.currentSnapshot()
        await connector.usePhone(attemptID: form.attemptID, revision: form.revision)
        await eventually { await connector.currentSnapshot().state == .phoneNumber }
        XCTAssertEqual(restoredQRClient.releases, 1)
        form = await connector.currentSnapshot()
        let phoneClient = fixture.latestClient
        await connector.useQR(attemptID: form.attemptID, revision: form.revision)
        await connector.useQR(attemptID: form.attemptID, revision: form.revision) // stale window
        await eventually { await isQR(connector) }
        XCTAssertEqual(phoneClient.requests.filter { $0.type == "requestQrCodeAuthentication" }.count, 1)
        phoneClient.auth("authorizationStateWaitOtherDeviceConfirmation", ["link": .string("tg://login?token=renewed")])
        await eventually { await connector.currentSnapshot().state == .qr(link: "tg://login?token=renewed") }
        let renewed = await connector.currentSnapshot()
        XCTAssertGreaterThan(renewed.revision, form.revision)
        _ = await connector.close()
    }

    func testShutdownDuringPhoneFallbackDoesNotRestartClient() async throws {
        let fixture = try TelegramFixture(); fixture.client.logoutBehavior = .acceptedPending
        let connector = try fixture.connector()
        await connector.connect(); await eventually { await isQR(connector) }
        let form = await connector.currentSnapshot()
        await connector.usePhone(attemptID: form.attemptID, revision: form.revision)
        _ = await connector.close()
        XCTAssertEqual(fixture.factory.clients.count, 1)
        XCTAssertNotEqual(try manifest(fixture.client).logoutCompleted, true)
        let snapshot = await connector.currentSnapshot()
        XCTAssertEqual(snapshot.state, .cleanupPending)
        _ = await connector.close()
    }

    private func manifest(_ client: FakeTDLibClient) throws -> TelegramProfileManifest {
        let database = try XCTUnwrap(client.requests.first { $0.type == "setTdlibParameters" }?["database_directory"]?.string)
        let url = URL(fileURLWithPath: database).deletingLastPathComponent().appendingPathComponent("profile.json")
        return try JSONDecoder().decode(TelegramProfileManifest.self, from: Data(contentsOf: url))
    }

    func testClosedAloneDoesNotProveLogoutAndLocalRemovalUsesDestroy() async throws {
        let fixture = try TelegramFixture(); fixture.client.logoutBehavior = .closedWithoutOK
        let connector = try fixture.connector()
        await connector.connect(); await eventually { await isQR(connector) }
        await connector.disconnect()
        await eventually { await connector.currentSnapshot().state == .cleanupPending }
        let database = try XCTUnwrap(fixture.client.requests.first { $0.type == "setTdlibParameters" }?["database_directory"]?.string)
        XCTAssertTrue(FileManager.default.fileExists(atPath: database))
        await connector.removeLocalData()
        let removed = await connector.currentSnapshot()
        XCTAssertEqual(removed.state, .disconnected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database))

        let other = try TelegramFixture(), active = try other.connector()
        await active.connect(); await eventually { await isQR(active) }
        await active.removeLocalData()
        await eventually { await active.currentSnapshot().state == .disconnected }
        XCTAssertTrue(other.client.requests.contains { $0.type == "destroy" })
        XCTAssertFalse(other.client.requests.contains { $0.type == "logOut" })
    }

    func testCancelIgnoresLateReadyAndOfflineCleanupIsDurable() async throws {
        let fixture = try TelegramFixture(); fixture.client.logoutBehavior = .silent
        let connector = try fixture.connector(timeout: 0.05)
        await connector.connect(); await eventually { await isQR(connector) }
        await connector.disconnect()
        fixture.client.auth("authorizationStateReady")
        await eventually { await connector.currentSnapshot().state == .cleanupPending }
        XCTAssertFalse(fixture.client.requests.contains { $0.type == "getMe" })
        _ = await connector.close(); _ = await connector.close()
        let restoredClient = FakeTDLibClient()
        let restored = try fixture.connector(client: restoredClient)
        await restored.restore()
        await eventually { await restored.currentSnapshot().state == .disconnected }
        XCTAssertTrue(restoredClient.requests.contains { $0.type == "logOut" })
        XCTAssertFalse(restoredClient.requests.contains { $0.type == "requestQrCodeAuthentication" })
    }

    func testMissingKeyDoesNotOverwriteExistingDatabase() async throws {
        let fixture = try TelegramFixture()
        var profile = try fixture.profiles.open(environment: .test, create: true)
        profile?.manifest.keyCreated = true; try profile?.save()
        profile = nil
        let connector = try fixture.connector()
        await connector.restore()
        let snapshot = await connector.currentSnapshot()
        XCTAssertEqual(snapshot.failure, .keyMissing)
        XCTAssertTrue(fixture.client.requests.isEmpty)
        XCTAssertEqual(fixture.keys.insertions, 0)
        _ = await connector.close()
    }

    func testBindingMismatchBlocksProfileWithoutDeletingIt() async throws {
        let fixture = try TelegramFixture()
        var profile = try fixture.profiles.open(environment: .test, create: true)
        try profile?.bind(userID: 1234, environment: .test)
        profile = nil
        let connector = try fixture.connector()
        await connector.connect(); await eventually { await isQR(connector) }
        fixture.client.auth("authorizationStateReady")
        await eventually { await connector.currentSnapshot().failure == .accountMismatch }
        _ = await connector.close(); _ = await connector.close()
        let retained = try XCTUnwrap(fixture.profiles.open(environment: .test, create: false))
        XCTAssertEqual(retained.manifest.userID, "1234")
        XCTAssertFalse(fixture.client.requests.contains { ["logOut", "destroy"].contains($0.type) })
    }

    func testPasswordErrorIsRecoverableAndLateErrorCannotReplaceNewForm() async throws {
        let fixture = try TelegramFixture(); fixture.client.automaticForms = false
        let connector = try fixture.connector()
        await connector.connect(); await eventually { await isQR(connector) }
        fixture.client.auth("authorizationStateWaitPassword")
        await eventually { await connector.currentSnapshot().state == .password(hint: "") }
        var form = await connector.currentSnapshot()
        await connector.submit(.password("incorrect fixture"), attemptID: form.attemptID, revision: form.revision)
        let first = try XCTUnwrap(fixture.client.requests.last { $0.type == "checkAuthenticationPassword" })
        let error = TDLibMessage("error", ["code": .integer(400), "message": .string("PASSWORD_HASH_INVALID")])
        fixture.client.reply(first, error)
        await eventually { await connector.currentSnapshot().failure == .invalidPassword }
        form = await connector.currentSnapshot()
        XCTAssertFalse(form.isSubmitting)
        await connector.submit(.password("second fixture"), attemptID: form.attemptID, revision: form.revision)
        let second = try XCTUnwrap(fixture.client.requests.last { $0.type == "checkAuthenticationPassword" })
        fixture.client.auth("authorizationStateReady")
        fixture.client.reply(second, error)
        await eventually { if case .connected = await connector.currentSnapshot().state { true } else { false } }
        let connected = await connector.currentSnapshot()
        XCTAssertNil(connected.failure)
        _ = await connector.close()
    }

    func testCloseTimeoutKeepsClientLeaseUntilClosed() async throws {
        let fixture = try TelegramFixture(); fixture.client.automaticClose = false
        let connector = try fixture.connector(timeout: 0.05)
        await connector.connect(); await eventually { await isQR(connector) }
        let closed = await connector.close()
        XCTAssertFalse(closed)
        XCTAssertEqual(fixture.client.releases, 0)
        await connector.connect()
        XCTAssertEqual(fixture.client.requests.filter { $0.type == "getAuthorizationState" }.count, 1)
        fixture.client.auth("authorizationStateClosed")
        await eventually { fixture.client.releases == 1 }
        _ = await connector.close()
    }
}
