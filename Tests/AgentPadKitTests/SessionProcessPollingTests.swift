import XCTest
@testable import AgentPadKit

@MainActor
final class SessionProcessPollingTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    func testTimeoutSkipsSampleAndContinuesAfterDelayWithPreviousCPUWindow() async {
        let calls = Calls(), gate = Gate()
        gate.close(); defer { gate.open() }
        let entered = expectation(description: "second scan blocked")
        let recovered = expectation(description: "polling recovered without restarting")
        var ticks: [ContinuousClock.Instant] = [], updates: [[SessionProcess]] = []
        let task = Task {
            await SessionProcessPolling.run(interval: .milliseconds(100), timeout: 0.05, foregroundPID: {
                ticks.append(.now)
                return 42
            }, scan: { pid, previousCPU in
                XCTAssertFalse(Thread.isMainThread)
                let tick = calls.next()
                XCTAssertEqual(pid, 42)
                XCTAssertEqual(previousCPU?.atNs, tick == 1 ? nil : 1,
                               "A failed sample must preserve the last successful CPU window")
                if tick == 2 { entered.fulfill(); gate.pass() }
                let rows = SessionProcessScanner.tree(from: [
                    .init(pid: pid, ppid: 1, name: "node", isForeground: true,
                          ports: [UInt16(3000 + tick)], cpuPercent: tick * 10)
                ])
                return (rows, .init(atNs: UInt64(tick), cpuNs: [pid: UInt64(tick)]))
            }, update: { rows in
                updates.append(rows)
                if updates.count == 2 { recovered.fulfill() }
            })
        }
        defer { task.cancel() }
        await fulfillment(of: [entered, recovered], timeout: 3)
        task.cancel(); await task.value
        XCTAssertEqual(ticks.count, 3)
        if ticks.count == 3 {
            XCTAssertGreaterThanOrEqual(ticks[1].duration(to: ticks[2]), .milliseconds(100),
                                        "Timeout recovery must retain the normal poll delay")
        }
        XCTAssertEqual(updates.map { $0.first?.ports }, [[3001], [3003]])
        XCTAssertEqual(updates.map { $0.first?.cpuPercent }, [10, 30])
    }

    func testBusyWorkersQueueTheCurrentIteration() async {
        let gate = Gate(), calls = Calls()
        gate.close(); defer { gate.open() }
        let entered = expectation(description: "workers occupied")
        entered.expectedFulfillmentCount = BackgroundInspection.workerLimit
        let blockers = (0..<BackgroundInspection.workerLimit).map { _ in
            Task { try? await BackgroundInspection.run { entered.fulfill(); gate.pass() } }
        }
        await fulfillment(of: [entered], timeout: 3)
        let attempted = expectation(description: "poll attempted with busy workers")
        let recovered = expectation(description: "poll recovered after workers became available")
        var ticks: [ContinuousClock.Instant] = []
        let task = Task {
            await SessionProcessPolling.run(interval: .milliseconds(100), foregroundPID: {
                ticks.append(.now)
                if ticks.count == 1 { attempted.fulfill() }
                return 42
            }, scan: { _, _ in
                XCTAssertFalse(Thread.isMainThread)
                _ = calls.next()
                return ([], .init(atNs: 1, cpuNs: [:]))
            }, update: { _ in recovered.fulfill() })
        }
        defer { task.cancel() }
        await fulfillment(of: [attempted], timeout: 3)
        XCTAssertEqual(calls.count, 0, "A busy worker pool must not scan on the caller")
        gate.open()
        await fulfillment(of: [recovered], timeout: 3)
        task.cancel(); await task.value
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(ticks.count, 1, "Freeing a worker must complete the queued sample without retrying")
        for blocker in blockers { await blocker.value }
    }

    func testCancellationStopsPollingWithoutApplyingLateScan() async {
        let gate = Gate()
        gate.close(); defer { gate.open() }
        let entered = expectation(description: "scan blocked")
        let task = Task {
            await SessionProcessPolling.run(foregroundPID: { 42 }, scan: { _, _ in
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill(); gate.pass()
                return ([], .init(atNs: 1, cpuNs: [:]))
            }, update: { _ in XCTFail("A cancelled task must not publish a late scan") })
        }
        defer { task.cancel() }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel(); await task.value
    }
}
