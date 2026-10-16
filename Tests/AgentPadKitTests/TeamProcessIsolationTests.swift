import Darwin
import XCTest
@testable import AgentPadKit

@MainActor
final class TeamProcessIsolationTests: XCTestCase {
    private var root: URL!
    private let processes = TeamProcesses()

    /// Exercise the kernel's ENOMEM response, rather than making the whole
    /// table unreadable. A growing table makes the previously sized buffer
    /// too small in exactly the same way.
    func testExitedExecutorAfterTableGrowthUnblocksTheSameRegistry() async throws {
        let read = TeamProcesses.readProcessTable
        defer { TeamProcesses.readProcessTable = read }
        let lock = NSLock()
        let tried = TeamValueBox<Bool>()
        let failure = TeamValueBox<Int32>()
        TeamProcesses.readProcessTable = { mib, buffer, size in
            let undersize = lock.withLock {
                guard mib[2] == KERN_PROC_ALL, buffer != nil, tried.get() != true else { return false }
                tried.set(true)
                return true
            }
            if undersize { size = MemoryLayout<kinfo_proc>.stride }
            let result = read(&mib, buffer, &size)
            if undersize { let error = errno; failure.set(error); errno = error }
            return result
        }
        let binary = try NativeVersionFixture.make(in: root)
        let hold = root.appendingPathComponent("run-hold")
        try Data().write(to: hold)
        let start = TeamStartBox(), request = request()
        let runner = ClaudeCodeRunner(fixturePath: binary.path, processes: processes)
        let service = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("team")), runner: runner)
        let run = Task { try await runner.run(request, onActivity: { _ in }, onProcessStarted: { start.set($0) }) }
        defer { run.cancel(); try? FileManager.default.removeItem(at: hold) }
        let deadline = ContinuousClock.now + .seconds(5)
        while (start.get() == nil || failure.get() == nil), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(failure.get(), ENOMEM, "the kernel rejected an undersized snapshot")
        let leader = try XCTUnwrap(start.get())
        XCTAssertEqual(TeamProcesses.liveness(leader.identity), .alive)
        XCTAssertFalse(service.canMoveToServer)
        do {
            try await TeamMode.switchToServer(service: service) { _ in XCTFail("a live run cannot switch modes") }
            XCTFail("a live run was admitted")
        } catch { XCTAssertEqual(error as? TeamError, .teamWorkOn) }
        try FileManager.default.removeItem(at: hold)
        let answer = try await run.value
        XCTAssertEqual(answer.text, "fixture answer")
        XCTAssertEqual(TeamProcesses.liveness(leader.identity), .gone)
        XCTAssertNil(processes.seen(of: leader), "successful cleanup must release the entry")
        XCTAssertTrue(processes.leftOvers().isEmpty)
        XCTAssertTrue(service.canMoveToServer)
        try await TeamMode.switchToServer(service: service) { _ in }
        XCTAssertEqual(service.mode, .server)
    }

    func testRepeatedTableGrowthAndOtherReadFailuresStayUnknown() {
        let read = TeamProcesses.readProcessTable
        defer { TeamProcesses.readProcessTable = read }
        for error in [ENOMEM, EIO] {
            let copies = TeamValueBox<Int>()
            TeamProcesses.readProcessTable = { mib, buffer, size in
                guard buffer != nil else { return read(&mib, buffer, &size) }
                copies.set((copies.get() ?? 0) + 1)
                errno = error
                return -1
            }
            XCTAssertNil(TeamProcesses.descendantIdentities(of: getpid()))
            XCTAssertEqual(copies.get(), error == ENOMEM ? 3 : 1)
        }
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("team-process-isolation-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        processes.killAll()
        for left in processes.leftOvers() { processes.remove(left.leader) }
        try? FileManager.default.removeItem(at: root)
    }

    private func request() -> TeamRunRequest {
        TeamRunRequest(agent: TeamPublishedAgent(name: "isolation", description: "test", folder: root.path, access: .read),
                       prompt: "test", sessionId: UUID().uuidString, resume: false, callerName: "test", callerProject: nil)
    }

}
