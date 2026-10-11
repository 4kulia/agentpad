import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class ProcessScanUITests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var scans = 0
        private var main = false
        func record() { lock.withLock { scans += 1; main = main || Thread.isMainThread } }
        func reset() { lock.withLock { scans = 0; main = false } }
        var count: Int { lock.withLock { scans } }
        var usedMainThread: Bool { lock.withLock { main } }
    }

    private func tabBar(_ tab: Session, _ store: WorkspaceStore) -> TabBarItem {
        TabBarItem(tab: tab, store: store, isActive: true, canCloseToRight: false,
                   onActivate: {}, onClose: {}, onCloseOthers: {}, onCloseToRight: {},
                   onDuplicate: {}, onRename: { _ in }, onSplit: { _ in }, onMoveToNewWindow: {})
    }

    func testTabBarRenderingAndAvailabilityPerformZeroProcessScans() async throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession), fixture = AnswerProcessFixture(), calls = Calls()
        SessionProcessScanner.inspectionObserver.withLock { observer in
            observer = { if Thread.isMainThread { calls.record() } }
        }
        defer { SessionProcessScanner.inspectionObserver.withLock { $0 = nil } }
        tab.agent = .claudeCode
        try fixture.bind(tab, conversation: UUID().uuidString)
        var inspector = fixture.inspector
        let scan = inspector.scan
        inspector.scan = { pid in calls.record(); return scan(pid) }
        try await AgentAnswerSource.refresh(tab, inspector: inspector)
        XCTAssertGreaterThan(calls.count, 0)
        XCTAssertFalse(calls.usedMainThread)
        calls.reset()
        let engine = try XCTUnwrap(tab.engine as? TestEngine)
        engine.foregroundPIDReads = 0
        for _ in 0..<20 {
            _ = tabBar(tab, store).body
            XCTAssertNil(AgentAnswerSource.problem(tab))
            XCTAssertTrue(CompositionTabs.available(tab))
        }
        XCTAssertEqual(calls.count, 0, "Rendering and help/enabled getters must only read the cache")
        XCTAssertEqual(engine.foregroundPIDReads, 0, "The native foreground getter performs a terminal ioctl")
    }

    func testForeverBlockedScannerDoesNotBlockRenderingOrForwardTimeout() async throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession), fixture = AnswerProcessFixture()
        tab.agent = .claudeCode
        try fixture.bind(tab, conversation: UUID().uuidString)
        let entered = expectation(description: "scanner entered off-main")
        let returned = expectation(description: "Forward timed out without waiting for the scanner")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var inspector = fixture.inspector
        inspector.scan = { _ in
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            // Block through every assertion; release only at teardown so this
            // test cannot permanently consume another test's worker capacity.
            release.wait()
            return []
        }
        let stalled = inspector
        Task {
            defer { returned.fulfill() }
            do {
                _ = try await AgentAnswerSource.read(session: tab, store: store, inspector: stalled,
                    reader: { _, _, _ in XCTFail("Do not read a journal without verification"); return "" }, timeout: 0.1)
                XCTFail("Expected a bounded verification failure")
            } catch { XCTAssertEqual(error as? AgentAnswerTranscript.Problem, .inspectionTimeout) }
        }
        await fulfillment(of: [entered], timeout: 3)
        // These MainActor turns still execute while the kernel substitute has
        // no possible return. A structured task-group race would hang here.
        _ = tabBar(tab, store).body
        let heartbeat = expectation(description: "MainActor heartbeat")
        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat, returned], timeout: 3)
        XCTAssertEqual(AgentAnswerSource.problem(tab), .inspectionTimeout)
        XCTAssertFalse(CompositionTabs.available(tab))
        _ = tabBar(tab, store).body
    }

    func testLateScanCannotValidateChangedForegroundOrBinding() async throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession), fixture = AnswerProcessFixture()
        tab.agent = .claudeCode
        try fixture.bind(tab, conversation: UUID().uuidString)
        let entered = expectation(description: "scan started"), release = DispatchSemaphore(value: 0)
        var inspector = fixture.inspector
        let scan = inspector.scan
        inspector.scan = { pid in entered.fulfill(); release.wait(); return scan(pid) }
        let delayed = inspector
        let task = Task { try await AgentAnswerSource.refresh(tab, inspector: delayed) }
        await fulfillment(of: [entered], timeout: 3)
        (tab.engine as? TestEngine)?.foregroundPid = nil
        release.signal()
        await XCTAssertThrowsErrorAsync(try await task.value) {
            XCTAssertEqual($0 as? AgentAnswerTranscript.Problem, .changed)
        }
        XCTAssertFalse(CompositionTabs.available(tab))
    }
}
