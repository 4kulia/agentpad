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

    private final class ScanSafetyBound: @unchecked Sendable {
        private let lock = NSLock()
        private let timer: DispatchSourceTimer
        private var finished = false
        private var release: (@Sendable () -> Void)?

        init(timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
            timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ProcessScanUITests.safety"))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { @Sendable [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    guard !self.finished else { return }
                    self.finished = true
                    XCTFail("Blocked scanner test exceeded its \(timeout)-second safety bound", file: file, line: line)
                    self.release?()
                    self.release = nil
                }
            }
            timer.resume()
        }

        func watch(_ gate: Gate, entry: AsyncStream<Void>.Continuation) -> Bool {
            lock.withLock {
                guard !finished else { return false }
                release = { gate.open(); entry.finish() }
                return true
            }
        }

        func stop() {
            // Serialize teardown with any in-flight failure report so it cannot
            // escape this test and be attributed to the next one.
            lock.withLock { finished = true; release = nil }
            timer.cancel()
        }
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
        // This is an emergency bound for the entire test, including retries,
        // independent of MainActor scheduling and the timeout under test.
        let safety = ScanSafetyBound(timeout: 30)
        defer { safety.stop() }
        let store = makeTestStore()
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.activeSession), fixture = AnswerProcessFixture()
        tab.agent = .claudeCode
        try fixture.bind(tab, conversation: UUID().uuidString)
        let maxAttempts = 100
        for _ in 0..<maxAttempts {
            let gate = Gate(), calls = Calls(), exits = Calls()
            gate.close()
            defer { gate.open() }
            let (entered, entry) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            guard safety.watch(gate, entry: entry) else { return }
            var inspector = fixture.inspector
            inspector.scan = { _ in
                calls.record()
                entry.yield(())
                // Fail a synchronous-scan regression without deadlocking the
                // test runner's main thread in the test double itself.
                guard !Thread.isMainThread else {
                    XCTFail("Process scanning must never run on the main thread")
                    return []
                }
                gate.pass()
                exits.record()
                return []
            }
            let stalled = inspector
            let forward = Task {
                defer { entry.finish() }
                do {
                    _ = try await AgentAnswerSource.read(session: tab, store: store, inspector: stalled,
                        reader: { _, _, _ in XCTFail("Do not read a journal without verification"); return "" }, timeout: 0.1)
                    XCTFail("Expected a bounded verification failure")
                    return false
                } catch {
                    XCTAssertEqual(error as? AgentAnswerTranscript.Problem, .inspectionTimeout)
                    return error as? AgentAnswerTranscript.Problem == .inspectionTimeout
                }
            }
            var entries = entered.makeAsyncIterator()
            guard await entries.next() != nil else {
                // The deadline can expire before a worker is scheduled. That
                // does not exercise a blocked scanner: establish that precondition
                // again, releasing this attempt's gate even if it enters late.
                guard await forward.value else { return }
                continue
            }

            // Prove progress while the scanner has no possible return. XCTest
            // can spend seconds symbolizing SwiftUI's unhosted-State warnings
            // on the main thread; a wall-clock heartbeat deadline measures that
            // reporting/scheduling delay as well as the code under test.
            _ = tabBar(tab, store).body
            await Task { @MainActor in
                XCTAssertEqual(calls.count, 1)
                XCTAssertFalse(calls.usedMainThread)
                XCTAssertEqual(exits.count, 0)
                _ = tabBar(tab, store).body
            }.value
            let timedOut = await forward.value
            XCTAssertTrue(timedOut)
            XCTAssertEqual(exits.count, 0, "Forward must return before the scanner is released")
            XCTAssertEqual(AgentAnswerSource.problem(tab), .inspectionTimeout)
            XCTAssertFalse(CompositionTabs.available(tab))
            _ = tabBar(tab, store).body
            return
        }
        XCTFail("Could not start a blocked scanner after \(maxAttempts) attempts")
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
