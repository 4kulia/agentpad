import AgentPadTelegram
import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import AgentPadKit

private actor SettingsTelegramConnector: TelegramConnector {
    var restoreCount = 0
    var connectCount = 0
    var retryCount = 0
    var closeCount = 0
    var disconnectCount = 0
    var removalCount = 0
    var inputs: [TelegramAuthInput] = []
    var submissions: [(UUID, UInt64)] = []
    var holdsConnect = false
    var connectWaiter: CheckedContinuation<Void, Never>?
    var current = TelegramSnapshot()
    let stream: AsyncStream<TelegramSnapshot>
    let continuation: AsyncStream<TelegramSnapshot>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func snapshots() -> AsyncStream<TelegramSnapshot> { stream }
    func restore() { restoreCount += 1; continuation.yield(current) }
    func connect() async {
        connectCount += 1
        if holdsConnect { await withCheckedContinuation { connectWaiter = $0 } }
    }
    func holdConnect() { holdsConnect = true }
    func completeConnect() { connectWaiter?.resume(); connectWaiter = nil }
    func retry() { retryCount += 1 }
    func usePhone(attemptID: UUID, revision: UInt64) { submissions.append((attemptID, revision)) }
    func useQR(attemptID: UUID, revision: UInt64) { submissions.append((attemptID, revision)) }
    func submit(_ input: TelegramAuthInput, attemptID: UUID, revision: UInt64) {
        inputs.append(input); submissions.append((attemptID, revision))
    }
    func disconnect() { disconnectCount += 1 }
    func removeLocalData() { removalCount += 1 }
    func close() -> Bool { closeCount += 1; return true }
    func emit(_ snapshot: TelegramSnapshot) { current = snapshot; continuation.yield(snapshot) }
}

@MainActor
final class TelegramSettingsViewModelTests: XCTestCase {
    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected model state", file: file, line: line)
    }

    func testRestorationIsOnceAndDoesNotConnectANewAccount() async {
        let connector = SettingsTelegramConnector()
        let model = TelegramSettingsViewModel(connector: connector)
        model.start(environment: [:]); model.start(environment: [:])
        await eventually { await connector.restoreCount == 1 }
        let count = await connector.connectCount
        XCTAssertEqual(count, 0)
        await model.connect()
        let connected = await connector.connectCount
        XCTAssertEqual(connected, 1)
        await model.shutdown()
        let closed = await connector.closeCount
        XCTAssertEqual(closed, 1)
    }

    func testPasswordBufferClearedAndSubmissionUsesExactForm() async {
        let connector = SettingsTelegramConnector(), model: TelegramSettingsViewModel
        model = TelegramSettingsViewModel(connector: connector)
        model.start(environment: [:]); await eventually { await connector.restoreCount == 1 }
        var form = TelegramSnapshot(); form.state = .password(hint: "test hint"); form.revision = 8
        await connector.emit(form); await eventually { model.snapshot == form }
        model.input = "synthetic password"
        await model.submit()
        XCTAssertTrue(model.input.isEmpty)
        let sent = await connector.inputs
        guard case .password(let value) = sent.first else { return XCTFail("No password request") }
        XCTAssertEqual(value, "synthetic password")
        let ids = await connector.submissions
        XCTAssertEqual(ids.first?.0, form.attemptID); XCTAssertEqual(ids.first?.1, 8)
        model.input = "new draft"
        form.revision = 9
        await connector.emit(form); await eventually { model.input.isEmpty }
        await model.shutdown()
    }

    func testSubmittingFormDoesNotResubmitAndCancellationClearsInput() async {
        let connector = SettingsTelegramConnector(), model: TelegramSettingsViewModel
        model = TelegramSettingsViewModel(connector: connector)
        model.start(environment: [:]); await eventually { await connector.restoreCount == 1 }
        var form = TelegramSnapshot(); form.state = .password(hint: ""); form.isSubmitting = true
        await connector.emit(form); await eventually { model.snapshot == form }
        model.input = "synthetic"; await model.submit()
        let sent = await connector.inputs
        XCTAssertTrue(sent.isEmpty)
        await model.disconnect()
        XCTAssertTrue(model.input.isEmpty); XCTAssertNil(model.qrImage)
        let cancellations = await connector.disconnectCount
        XCTAssertEqual(cancellations, 1)
        await model.shutdown()
    }

    func testLocalRemovalAndRetryHaveDistinctActions() async {
        let connector = SettingsTelegramConnector(), model: TelegramSettingsViewModel
        model = TelegramSettingsViewModel(connector: connector)
        model.start(environment: [:]); await eventually { await connector.restoreCount == 1 }
        await model.retry()
        let closed = await connector.closeCount, retries = await connector.retryCount
        XCTAssertEqual(closed, 0); XCTAssertEqual(retries, 1)
        await model.removeLocalData()
        let removals = await connector.removalCount, logouts = await connector.disconnectCount
        XCTAssertEqual(removals, 1); XCTAssertEqual(logouts, 0)
        await model.shutdown()
    }

    func testLateQRRenderingCannotReplacePasswordForm() async {
        let connector = SettingsTelegramConnector(), model: TelegramSettingsViewModel
        model = TelegramSettingsViewModel(connector: connector)
        var form = TelegramSnapshot(); form.state = .qr(link: "tg://login?token=synthetic")
        model.receive(form)
        form.revision += 1; form.state = .password(hint: "")
        model.receive(form)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.qrImage)
        XCTAssertEqual(model.snapshot.state, .password(hint: ""))
        await model.shutdown()
    }

    func testQRIsGeneratedLocallyAndSettingsSectionIsRoutable() throws {
        let link = "tg://login?token=synthetic"
        let bytes = try XCTUnwrap(TelegramQR.png(link))
        let image = try XCTUnwrap(CIImage(data: bytes))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: image) as? [CIQRCodeFeature]
        XCTAssertEqual(features?.first?.messageString, link)
        XCTAssertTrue(SettingsTabSection.allCases.contains(.telegram))
        XCTAssertEqual(SettingsTabSection.telegram.title, "Telegram")
        XCTAssertTrue(TelegramBuild.privacyText.contains("Nothing related to Telegram is sent to the AgentPad server"))
    }

    func testShutdownWaitsForInFlightConnectWithoutBlockingMainActor() async {
        let connector = SettingsTelegramConnector(), model: TelegramSettingsViewModel
        model = TelegramSettingsViewModel(connector: connector)
        await connector.holdConnect()
        let connect = Task { await model.connect() }
        await eventually { await connector.connectCount == 1 }
        let shutdown = Task { await model.shutdown() }
        await Task.yield()
        let before = await connector.closeCount
        XCTAssertEqual(before, 0)
        await connector.completeConnect()
        await connect.value; await shutdown.value
        let after = await connector.closeCount
        XCTAssertEqual(after, 1)
        await model.connect()
        let final = await connector.connectCount
        XCTAssertEqual(final, 1, "Shutdown prevents a new client from starting after close")
    }

    func testNetworkRecoveryRetriesOnlyPendingLogout() async {
        let connector = SettingsTelegramConnector(), model: TelegramSettingsViewModel
        model = TelegramSettingsViewModel(connector: connector)
        model.start(environment: [:]); await eventually { await connector.restoreCount == 1 }
        await model.retryPendingLogout()
        let idle = await connector.retryCount
        XCTAssertEqual(idle, 0)
        var pending = TelegramSnapshot(); pending.state = .cleanupPending
        await connector.emit(pending); await eventually { model.snapshot == pending }
        await model.retryPendingLogout()
        let retries = await connector.retryCount, closes = await connector.closeCount
        XCTAssertEqual(retries, 1); XCTAssertEqual(closes, 0)
        await model.retry() // the manual Retry logout action follows the same path
        let manualRetries = await connector.retryCount, manualCloses = await connector.closeCount
        XCTAssertEqual(manualRetries, 2); XCTAssertEqual(manualCloses, 0)
        pending.state = .reauthenticationRequired
        await connector.emit(pending); await eventually { model.snapshot == pending }
        await model.retryPendingLogout()
        let unchanged = await connector.retryCount
        XCTAssertEqual(unchanged, 2)
        await model.shutdown()
    }

    func testSwitchingBackToQRUsesCurrentFormAndClearsPhoneInput() async {
        let connector = SettingsTelegramConnector(), model: TelegramSettingsViewModel
        model = TelegramSettingsViewModel(connector: connector)
        model.start(environment: [:]); await eventually { await connector.restoreCount == 1 }
        var form = TelegramSnapshot(); form.state = .phoneNumber; form.revision = 5
        await connector.emit(form); await eventually { model.snapshot == form }
        model.input = "+9996612345"
        await model.useQR()
        XCTAssertTrue(model.input.isEmpty)
        let submissions = await connector.submissions
        XCTAssertEqual(submissions.first?.0, form.attemptID)
        XCTAssertEqual(submissions.first?.1, form.revision)
        await model.shutdown()
    }
}
