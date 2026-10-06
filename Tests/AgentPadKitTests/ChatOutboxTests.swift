import Foundation
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatOutboxTests: XCTestCase {
    private var root: URL!
    private let org = "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10"
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-outbox-\(UUID().uuidString)")
        ChatStubProtocol.reset()
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        try? FileManager.default.removeItem(at: root)
    }

    private var files: ChatFiles { ChatFiles(directory: root) }
    private var key: ChatOrgKey { ChatOrgKey(server: server, accountId: "acc", orgId: org) }

    private func store() throws -> ChatStore { try ChatStore.open(files: files, key: key).store }
    /// A cache of its own, for a scenario that must not see another's queue.
    private func store(_ account: String) throws -> ChatStore {
        try ChatStore.open(files: files, key: ChatOrgKey(server: server, accountId: account, orgId: org)).store
    }

    private func outbox(_ store: ChatStore, journal: ChatJournal? = nil, session: String = "s1") -> ChatOutbox {
        var queues: [ChatCommandTable] = [store.outbox]
        if let journal { queues.append(journal.runCommands(key)) }
        let outbox = ChatOutbox(queues: queues, api: ChatAPI(server: server, protocolClasses: [ChatStubProtocol.self]),
                                token: "aps_t", sessionId: session)
        outbox.retryDelay = { _ in 0.05 }
        return outbox
    }

    private func setName(_ outbox: ChatOutbox, _ name: String = "Anna", orderKey: String? = nil, dependsOn: String? = nil) throws -> ChatCommandRecord {
        try outbox.enqueue(org: org, type: "member.set_name", args: .object(["name": .string(name)]), orderKey: orderKey, dependsOn: dependsOn)
    }

    private func waitUntil(_ condition: @MainActor () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func state(_ store: ChatStore, _ id: String) throws -> ChatCommandRecord.State? {
        try store.commands().first { $0.commandId == id }?.state
    }

    nonisolated private static let ok = ChatStubProtocol.Answer(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8))

    func testZeroRetryAfterCannotSpinEvenWhenPumpIsWoken() async throws {
        ChatStubProtocol.reset { _, _ in .success(.init(status: 429, headers: ["Retry-After": "0"], body: Data())) }
        let store = try store(), box = outbox(store)
        defer { box.hold() }
        let record = try setName(box)
        try await waitUntil { try store.commands().first?.attempts ?? 0 >= 1 }
        let pending = try XCTUnwrap(store.commands().first)
        XCTAssertGreaterThan(try XCTUnwrap(pending.nextAttemptAt).timeIntervalSinceNow, 0.5)
        for _ in 0..<30 {
            box.pump()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(ChatStubProtocol.seen.count, 1)
        XCTAssertEqual(try store.commands().first?.bodyBytes, record.bodyBytes)
    }

    // (1), (10)
    func testRepeatAfterABreakSendsTheSameIdAndBytes() async throws {
        let calls = Counter()
        ChatStubProtocol.reset { _, _ in
            calls.increment()
            return calls.value == 1 ? .failure(URLError(.networkConnectionLost)) : .success(Self.ok)
        }
        let store = try store()
        let box = outbox(store)
        let record = try setName(box)
        try await waitUntil { try self.state(store, record.commandId) == .sent }
        _ = box
        let bodies = ChatStubProtocol.seen.map(\.body)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertEqual(bodies[0], record.bodyBytes)
        XCTAssertEqual(try store.commands().first?.bodyBytes, bodies[1])
        let sent = try JSONDecoder().decode(ChatCommandEnvelope.self, from: bodies[1])
        XCTAssertEqual(sent.commandId, record.commandId)
        XCTAssertNotNil(ChatUUID.time(of: sent.commandId))
        XCTAssertEqual(ChatStubProtocol.seen.first?.request.url?.path, "/v1/commands")
    }

    // (2)
    func testQueueSurvivesARestart() async throws {
        ChatStubProtocol.reset { _, _ in .failure(URLError(.notConnectedToInternet)) }
        var record: ChatCommandRecord?
        do {
            let first = outbox(try store())
            first.retryDelay = { _ in 60 }
            record = try setName(first)
            try await waitUntil { ChatStubProtocol.seen.count == 1 }
        }
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        let store = try store()
        let again = outbox(store)
        again.now = { Date().addingTimeInterval(120) }
        again.pump()
        try await waitUntil { try self.state(store, record!.commandId) == .sent }
        XCTAssertEqual(ChatStubProtocol.seen.first?.body, record?.bodyBytes)
    }

    // (3)
    func testEachAnswerHasItsAction() async throws {
        for status in [500, 503] {
            let calls = Counter()
            ChatStubProtocol.reset { _, _ in
                calls.increment()
                return calls.value == 1 ? .success(.init(status: status, body: Data(#"{"error":"internal"}"#.utf8))) : .success(Self.ok)
            }
            let store = try store()
            let box = outbox(store)
            let record = try setName(box)
            try await waitUntil { try self.state(store, record.commandId) == .sent }
            _ = box
            XCTAssertEqual(calls.value, 2, "\(status) is repeated")
        }

        // 429 waits for Retry-After.
        ChatStubProtocol.reset { _, _ in .success(.init(status: 429, headers: ["Retry-After": "30"], body: Data(#"{"error":"rate_limited"}"#.utf8))) }
        do {
            let store = try store("limited")
            let box = outbox(store)
            let start = Date()
            box.now = { start }
            let record = try setName(box, orderKey: "limited")
            try await waitUntil { try store.commands().first { $0.commandId == record.commandId }?.attempts == 1 }
            let saved = try XCTUnwrap(try store.commands().first { $0.commandId == record.commandId })
            XCTAssertEqual(saved.state, .pending)
            XCTAssertEqual(try XCTUnwrap(saved.nextAttemptAt).timeIntervalSince(start), 30, accuracy: 0.01)
        }

        // 401 stops the queue; the record stays.
        ChatStubProtocol.reset { _, _ in .success(.init(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))) }
        do {
            let store = try store("signed-out")
            let box = outbox(store)
            var unauthorized = 0
            box.onUnauthorized = { unauthorized += 1 }
            let record = try setName(box, orderKey: "signed-out")
            try await waitUntil { box.paused == .needsSignIn }
            XCTAssertEqual(unauthorized, 1)
            XCTAssertEqual(try state(store, record.commandId), .pending)
            let before = ChatStubProtocol.seen.count
            _ = try setName(box, orderKey: "other")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(ChatStubProtocol.seen.count, before, "nothing is sent while stopped")
        }

        // No repeat: the record fails with the code.
        for (status, code) in [(400, "invalid_request"), (403, "forbidden"), (404, "not_found"), (409, "command_conflict"), (413, "too_large")] {
            ChatStubProtocol.reset { _, _ in .success(.init(status: status, body: Data("{\"error\":\"\(code)\"}".utf8))) }
            let store = try store("fail-\(status)")
            let box = outbox(store)
            let record = try setName(box, orderKey: "fail-\(status)")
            try await waitUntil { try self.state(store, record.commandId) == .failed }
            XCTAssertEqual(try store.commands().first { $0.commandId == record.commandId }?.error, code)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(ChatStubProtocol.seen.count, 1, "\(status) is not repeated")
        }
        // `invalid_state` of a request that has ended is said apart: its debt
        // is paid (server d8d2ea0); one of a state still open stays itself.
        for (state, code) in [("failed", ChatOutbox.requestEnded), ("running", "invalid_state")] {
            ChatStubProtocol.reset { _, _ in .success(.init(status: 409, body: Data(#"{"error":"invalid_state","state":"\#(state)","version":7}"#.utf8))) }
            let store = try store("ended-\(state)")
            let box = outbox(store)
            let record = try setName(box, orderKey: "ended-\(state)")
            try await waitUntil { try self.state(store, record.commandId) == .failed }
            XCTAssertEqual(try store.commands().first { $0.commandId == record.commandId }?.error, code)
        }
    }

    // (5)
    func testOneOrderKeyGoesOneAtATime() async throws {
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        ChatStubProtocol.delay = 0.1
        let store = try store()
        let box = outbox(store)
        let first = try setName(box, "one"), second = try setName(box, "two"), third = try setName(box, "three")
        try await waitUntil { try store.commands().allSatisfy { $0.state == .sent } }
        XCTAssertEqual(ChatStubProtocol.maxInFlight, 1)
        let order = try ChatStubProtocol.seen.map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).commandId }
        XCTAssertEqual(order, [first.commandId, second.commandId, third.commandId])
        _ = third
    }

    // (6)
    func testDependentCommandGetsDependencyFailed() async throws {
        ChatStubProtocol.reset { _, body in
            let type = (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: body))?.args["name"]?.string
            return type == "parent" ? .success(.init(status: 409, body: Data(#"{"error":"invalid_state"}"#.utf8))) : .success(Self.ok)
        }
        let store = try store()
        let box = outbox(store)
        var failures: [String: String] = [:]
        box.onPermanentFailure = { record, code in failures[record.commandId] = code }
        let parent = try setName(box, "parent", orderKey: "a")
        let child = try setName(box, "child", orderKey: "b", dependsOn: parent.commandId)
        let other = try setName(box, "other", orderKey: "a")
        try await waitUntil { try self.state(store, child.commandId) == .failed && self.state(store, other.commandId) == .sent }
        XCTAssertEqual(failures, [parent.commandId: "invalid_state", child.commandId: "dependency_failed"])
        let sentNames = ChatStubProtocol.seen.compactMap { try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).args["name"]?.string }
        XCTAssertFalse(sentNames.contains("child"), "never sent")
        XCTAssertTrue(sentNames.contains("other"), "a failed command does not block the next one")
    }

    func testDependentWaitsForItsParentsAnswer() async throws {
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        ChatStubProtocol.delay = 0.1
        let store = try store()
        let box = outbox(store)
        let parent = try setName(box, "parent", orderKey: "a")
        _ = try setName(box, "child", orderKey: "b", dependsOn: parent.commandId)
        try await waitUntil { try store.commands().allSatisfy { $0.state == .sent } }
        let names = ChatStubProtocol.seen.compactMap { try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).args["name"]?.string }
        XCTAssertEqual(names, ["parent", "child"])
        XCTAssertEqual(ChatStubProtocol.maxInFlight, 1)
    }

    // (7)
    func testCommandOlderThan30DaysIsNotSent() async throws {
        let store = try store()
        let box = outbox(store)
        box.now = { Date().addingTimeInterval(-31 * 24 * 3600) }
        box.retryDelay = { _ in 3600 }
        ChatStubProtocol.reset { _, _ in .failure(URLError(.notConnectedToInternet)) }
        let record = try setName(box)
        try await waitUntil { ChatStubProtocol.seen.count == 1 }
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        var failures: [String] = []
        box.onPermanentFailure = { _, code in failures.append(code) }
        box.now = { Date().addingTimeInterval(7200) }
        box.pump()
        try await waitUntil { try self.state(store, record.commandId) == .failed }
        XCTAssertEqual(failures, ["command_expired"])
        XCTAssertEqual(ChatStubProtocol.seen.count, 0)
    }

    // (11)
    func testNotFoundIsReportedExactlyOnce() async throws {
        ChatStubProtocol.reset { _, _ in .success(.init(status: 404, body: Data(#"{"error":"not_found"}"#.utf8))) }
        let store = try store()
        let box = outbox(store)
        var reports: [String] = []
        box.onPermanentFailure = { record, code in reports.append("\(record.commandId) \(code)") }
        let record = try setName(box)
        try await waitUntil { try self.state(store, record.commandId) == .failed }
        box.pump()
        box.pump()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reports, ["\(record.commandId) not_found"])
    }

    // (12)
    func testNewSessionCarriesBusinessCommandsAndDropsTheRest() async throws {
        ChatStubProtocol.reset { _, _ in .success(.init(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))) }
        let store = try store()
        let box = outbox(store, session: "old")
        let create = try box.enqueue(org: org, type: "request.create", args: .object(["request_id": .string("r1"), "text": .string("hi")]), orderKey: "x")
        let name = try setName(box, orderKey: "y")
        try await waitUntil { box.paused == .needsSignIn }

        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        box.adoptSession("new", token: "aps_new")
        // The new session sends after its connection's hello.
        box.allow(connection: 2)
        try await waitUntil { try store.commands().contains { $0.sessionId == "new" && $0.state == .sent } }
        let all = try store.commands()
        XCTAssertEqual(all.first { $0.commandId == create.commandId }?.state, .dropped)
        XCTAssertEqual(all.first { $0.commandId == name.commandId }?.state, .dropped)
        let carried = try XCTUnwrap(all.first { $0.sessionId == "new" })
        XCTAssertNotEqual(carried.commandId, create.commandId)
        XCTAssertEqual(carried.type, "request.create")
        let sent = try JSONDecoder().decode(ChatCommandEnvelope.self, from: try XCTUnwrap(ChatStubProtocol.seen.last?.body))
        XCTAssertEqual(sent.commandId, carried.commandId)
        XCTAssertEqual(sent.args, .object(["request_id": .string("r1"), "text": .string("hi")]))
        XCTAssertEqual(ChatStubProtocol.seen.last?.request.value(forHTTPHeaderField: "Authorization"), "Bearer aps_new")
        XCTAssertEqual(ChatStubProtocol.seen.count, 1, "member.set_name is not sent again")
    }

    func testGenerationChangeWaitsForTheUser() async throws {
        ChatStubProtocol.reset { _, _ in .failure(URLError(.notConnectedToInternet)) }
        let store = try store()
        let box = outbox(store)
        box.retryDelay = { _ in 3600 }
        let name = try setName(box, orderKey: "a")
        let run = try box.enqueue(org: org, type: "run.start", args: .object([:]), orderKey: "b")
        try await waitUntil { ChatStubProtocol.seen.count == 2 }
        try box.generationChanged()
        XCTAssertEqual(try state(store, name.commandId), .unconfirmed)
        XCTAssertEqual(try state(store, run.commandId), .unconfirmed)
        XCTAssertNil(try box.resend(run.commandId), "run.* is never sent again")
        let again = try XCTUnwrap(try box.resend(name.commandId))
        XCTAssertNotEqual(again.commandId, name.commandId)
        XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: again.bodyBytes).commandId, again.commandId)
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        box.resume()
        try await waitUntil { try self.state(store, again.commandId) == .sent }
        XCTAssertEqual(try state(store, name.commandId), .unconfirmed)
    }

    func testExecutorCommandsGoToTheJournal() async throws {
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        let store = try store()
        let journal = try ChatJournal.open(files: files)
        let box = outbox(store, journal: journal)
        let fact = try box.enqueue(org: org, type: "run.started", args: .object(["run_id": .string("r")]), orderKey: "exec:run", journal: true)
        XCTAssertTrue(try store.commands().isEmpty)
        try await waitUntil { try journal.commands(for: self.key).first?.state == .sent }
        XCTAssertEqual(try journal.commands(for: key).first?.commandId, fact.commandId)
    }

    // MARK: Review fixes (review-client-c.md 5–8)

    /// 7: one order key goes in the order commands were queued, even with
    /// equal times and random id tails.
    func testQueueOrderIsTheOrderOfQueueing() async throws {
        let store = try store()
        let box = outbox(store)
        let fixed = Date(timeIntervalSince1970: 1_790_000_000)
        box.now = { fixed }
        try box.generationChanged()
        _ = box
        let held = ChatOutbox(queues: [store.outbox], api: ChatAPI(server: server, protocolClasses: [ChatStubProtocol.self]),
                              token: "aps_t", sessionId: "s1", held: true)
        held.now = { fixed }
        var names: [String] = []
        for i in 0..<30 {
            names.append("n\(i)")
            try setName(held, "n\(i)", orderKey: "names")
        }
        held.allow(connection: 1)
        try await waitUntil { ChatStubProtocol.seen.count == 30 }
        let sent = try ChatStubProtocol.seen.map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).args["name"]?.string ?? "" }
        XCTAssertEqual(sent, names)
    }

    /// 5: an answer that comes after a new generation or a new session does not undo it.
    func testLateAnswersDoNotUndoNewerDecisions() async throws {
        ChatStubProtocol.reset { _, _ in .failure(URLError(.networkConnectionLost)) }
        ChatStubProtocol.delay = 0.3
        let first = try store("late-generation")
        let box = outbox(first)
        let record = try setName(box)
        try await waitUntil { ChatStubProtocol.seen.count == 1 }
        try box.generationChanged()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try state(first, record.commandId), .unconfirmed, "the late network error did not make it pending again")

        ChatStubProtocol.reset { _, _ in .success(.init(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))) }
        ChatStubProtocol.delay = 0.3
        let other = try store("late-session")
        let second = outbox(other, session: "old")
        let create = try second.enqueue(org: org, type: "request.create", args: .object(["request_id": .string("r")]))
        try await waitUntil { ChatStubProtocol.seen.count == 1 }
        ChatStubProtocol.reset { _, _ in .failure(URLError(.notConnectedToInternet)) }
        second.retryDelay = { _ in 3600 }
        second.adoptSession("new", token: "aps_new")
        second.allow(connection: 2)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(second.paused, "a 401 for the old session does not stop the new one")
        XCTAssertEqual(try state(other, create.commandId), .dropped, "the old record stays dropped")
    }

    /// 6: carried over, a dependent follows its parent's successor.
    func testCarryOverRewritesDependencies() async throws {
        ChatStubProtocol.reset { _, _ in .success(.init(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))) }
        let store = try store()
        let journal = try ChatJournal.open(files: files)
        let box = outbox(store, journal: journal, session: "old")
        let finished = try box.enqueue(org: org, type: "run.finished", args: .object(["run_id": .string("r")]), orderKey: "exec:run", journal: true)
        _ = try box.enqueue(org: org, type: "result.deliver", args: .object(["run_id": .string("r")]), orderKey: "exec:result",
                            dependsOn: finished.commandId, journal: true)
        try await waitUntil { box.paused == .needsSignIn }
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        var failures: [String] = []
        box.onPermanentFailure = { _, code in failures.append(code) }
        box.adoptSession("new", token: "aps_new")
        box.allow(connection: 2)
        try await waitUntil { try journal.commands(for: self.key).filter { $0.sessionId == "new" }.allSatisfy { $0.state == .sent } }
        let fresh = try journal.commands(for: key).filter { $0.sessionId == "new" }
        XCTAssertEqual(fresh.map(\.type), ["run.finished", "result.deliver"])
        XCTAssertEqual(fresh[1].dependsOn, fresh[0].commandId)
        XCTAssertEqual(failures, [])
        let order = try ChatStubProtocol.seen.map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).type }
        XCTAssertEqual(order, ["run.finished", "result.deliver"])
    }

    /// 8: a queue that cannot be written stops, once, instead of spinning.
    func testStorageFailureStopsTheQueue() async throws {
        let store = try store()
        let parent = try store.enqueue(ChatCommandRecord(commandId: ChatUUID.v7(), sessionId: "s1", type: "member.set_name", bodyBytes: Data("{}".utf8),
                                                         orderKey: "a", dependsOn: nil, createdAt: Date(), state: .failed))
        _ = try store.enqueue(ChatCommandRecord(commandId: ChatUUID.v7(), sessionId: "s1", type: "member.set_name", bodyBytes: Data("{}".utf8),
                                                orderKey: "b", dependsOn: parent.commandId, createdAt: Date(), state: .pending))
        try denyUpdates(store)
        let box = outbox(store)
        var errors: [String] = []
        box.onStorageError = { errors.append($0) }
        box.pump()
        guard case .storageFailed = box.paused else { return XCTFail("\(String(describing: box.paused))") }
        XCTAssertEqual(errors.count, 1)
        box.pump()
        XCTAssertEqual(errors.count, 1, "stopped: nothing more is tried")
        XCTAssertEqual(ChatStubProtocol.seen.count, 0)
    }

    /// C13-6: the carry-over to a new session fails to be written; once
    /// storage works again, Try Again carries over first — the old session's
    /// `member.set_name` is dropped, never sent with the new token.
    func testTryAgainAfterAFailedCarryOverCarriesOverFirst() async throws {
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        let store = try store()
        let box = outbox(store, session: "old")
        box.hold()
        let create = try box.enqueue(org: org, type: "request.create", args: .object(["request_id": .string("r1"), "text": .string("hi")]), orderKey: "x")
        let name = try setName(box, orderKey: "y")
        try denyUpdates(store)
        box.adoptSession("new", token: "aps_new")
        guard case .storageFailed = box.paused else { return XCTFail("\(String(describing: box.paused))") }
        box.allow(connection: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ChatStubProtocol.seen.count, 0, "nothing goes before the carry-over")
        try allowUpdates(store)
        box.retryStorage()
        try await waitUntil { try store.commands().contains { $0.sessionId == "new" && $0.state == .sent } }
        let all = try store.commands()
        XCTAssertEqual(all.first { $0.commandId == name.commandId }?.state, .dropped)
        XCTAssertEqual(all.first { $0.commandId == create.commandId }?.state, .dropped)
        let sent = try ChatStubProtocol.seen.map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body) }
        XCTAssertEqual(sent.map(\.type), ["request.create"], "member.set_name of the old session is not sent")
        XCTAssertNotEqual(sent.first?.commandId, create.commandId, "carried with a new id")
    }

    /// C14-1: the carry-over failed, the storage came back, then a new
    /// generation's hello: the carry-over is done first, then the generation
    /// is handled; after Try Again the queue sends again.
    func testNewGenerationAfterAFailedCarryOverCarriesOverFirst() async throws {
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        let store = try store()
        let box = outbox(store, session: "old")
        box.hold()
        let create = try box.enqueue(org: org, type: "request.create", args: .object(["request_id": .string("r1"), "text": .string("hi")]), orderKey: "x")
        let name = try setName(box, orderKey: "y")
        try denyUpdates(store)
        box.adoptSession("new", token: "aps_new")
        guard case .storageFailed = box.paused else { return XCTFail("\(String(describing: box.paused))") }
        try allowUpdates(store)
        try box.generationChanged()
        XCTAssertEqual(box.paused, .generationChanged)
        let all = try store.commands()
        XCTAssertEqual(all.first { $0.commandId == name.commandId }?.state, .dropped, "dropped by the new session's rules")
        XCTAssertEqual(all.first { $0.commandId == create.commandId }?.state, .dropped)
        XCTAssertEqual(all.filter { $0.sessionId == "new" }.map(\.state), [.unconfirmed], "the carried one waits for the user")
        box.resume()
        box.allow(connection: 2)
        let later = try setName(box, orderKey: "z")
        try await waitUntil { try self.state(store, later.commandId) == .sent }
        let sent = try ChatStubProtocol.seen.map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body) }
        XCTAssertEqual(sent.map(\.commandId), [later.commandId])
    }

    /// C18-1: "the queue may send on a connection" is one event: allowed
    /// for a connection, and going on after the user's Try Again of a new
    /// generation; not while no connection is allowed.
    func testReadyIsToldOnAllowAndOnTryAgain() async throws {
        let store = try store()
        let box = outbox(store)
        box.hold()
        var told = 0
        box.onReady = { told += 1 }
        try box.generationChanged()
        box.resume()
        XCTAssertEqual(told, 0, "no connection allowed yet")
        box.allow(connection: 2)
        XCTAssertEqual(told, 1)
        try box.generationChanged()
        box.resume()
        XCTAssertEqual(told, 2)
    }

    nonisolated private func allowUpdates(_ store: ChatStore) throws {
        try store.queue.write { db in try db.execute(sql: "DROP TRIGGER deny") }
    }

    nonisolated private func denyUpdates(_ store: ChatStore) throws {
        try store.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER deny BEFORE UPDATE ON outbox BEGIN SELECT RAISE(ABORT, 'disk says no'); END")
        }
    }

    // MARK: Third review (review-client-c3.md 1, 7)

    /// C3-1: a 200 that comes after the connection dropped confirms nothing;
    /// the command goes again after the next hello.
    func testAcceptanceAfterADropConfirmsNothing() async throws {
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        ChatStubProtocol.delay = 0.3
        let store = try store()
        let box = outbox(store)
        var sent = 0
        box.onSent = { _, _ in sent += 1 }
        let record = try setName(box)
        try await waitUntil { ChatStubProtocol.seen.count == 1 }
        box.hold()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try state(store, record.commandId), .pending)
        XCTAssertEqual(sent, 0)
        ChatStubProtocol.delay = 0
        box.allow(connection: 3)
        try await waitUntil { try self.state(store, record.commandId) == .sent }
        XCTAssertEqual(ChatStubProtocol.seen.last?.body, record.bodyBytes, "the same bytes again")
    }

    /// C3-7: a dependency is checked within the queue's own organization; a
    /// parent not in the queue fails the command instead of passing it.
    func testDependencyOnAnotherOrganizationIsRefused() async throws {
        let journal = try ChatJournal.open(files: files)
        let other = ChatOrgKey(server: server, accountId: "acc", orgId: "other-org")
        let foreign = try journal.enqueue(ChatCommandRecord(commandId: ChatUUID.v7(), sessionId: "s1", type: "run.started",
                                                             bodyBytes: Data("{}".utf8), orderKey: "exec:x", dependsOn: nil,
                                                             createdAt: Date(), state: .pending), key: other)
        let store = try store()
        let box = outbox(store, journal: journal)
        box.hold()
        XCTAssertThrowsError(try box.enqueue(org: org, type: "run.finished", args: .object([:]), orderKey: "exec:run",
                                             dependsOn: foreign.commandId, journal: true))
        // A record that names a parent the queue does not hold fails.
        let orphan = try journal.enqueue(ChatCommandRecord(commandId: ChatUUID.v7(), sessionId: "s1", type: "run.finished",
                                                            bodyBytes: Data("{}".utf8), orderKey: "exec:y", dependsOn: foreign.commandId,
                                                            createdAt: Date(), state: .pending), key: key)
        var failures: [String] = []
        box.onPermanentFailure = { _, code in failures.append(code) }
        box.allow(connection: 1)
        try await waitUntil { try journal.commands(for: self.key).first { $0.commandId == orphan.commandId }?.state == .failed }
        XCTAssertEqual(failures, ["dependency_missing"])
        XCTAssertEqual(ChatStubProtocol.seen.count, 0)
    }

    // MARK: Second review (review-client-c2.md 1–4)

    /// C2-1: a new session after a 401 sends nothing until its connection's hello.
    func testNewSessionWaitsForItsHello() async throws {
        ChatStubProtocol.reset { _, _ in .success(.init(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))) }
        let store = try store()
        let box = outbox(store, session: "old")
        _ = try box.enqueue(org: org, type: "request.create", args: .object(["request_id": .string("r")]))
        try await waitUntil { box.paused == .needsSignIn }
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        box.adoptSession("new", token: "aps_new")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ChatStubProtocol.seen.count, 0, "nothing before the new connection's hello")
        box.allow(connection: 7)
        try await waitUntil { ChatStubProtocol.seen.count == 1 }
    }

    /// C2-2: a 200 that left before a new generation confirms nothing.
    func testAcceptanceFromBeforeANewGenerationConfirmsNothing() async throws {
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        ChatStubProtocol.delay = 0.3
        let store = try store()
        let box = outbox(store)
        var sent = 0
        box.onSent = { _, _ in sent += 1 }
        let record = try setName(box)
        try await waitUntil { ChatStubProtocol.seen.count == 1 }
        try box.generationChanged()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try state(store, record.commandId), .unconfirmed)
        XCTAssertEqual(sent, 0)
    }

    /// C2-3: the two tables never share an order key or a dependency.
    func testQueuesDoNotShareKeysOrDependencies() async throws {
        let store = try store()
        let journal = try ChatJournal.open(files: files)
        let box = outbox(store, journal: journal)
        box.hold()
        let cacheCommand = try setName(box)
        XCTAssertThrowsError(try box.enqueue(org: org, type: "run.started", args: .object([:]), orderKey: "exec:run",
                                             dependsOn: cacheCommand.commandId, journal: true))
        XCTAssertThrowsError(try box.enqueue(org: org, type: "run.started", args: .object([:]), orderKey: "run", journal: true))
        XCTAssertThrowsError(try setName(box, orderKey: "exec:names"))
    }

    /// C2-4: one counter of places across the cache and the journal.
    func testPlacesGrowAcrossBothTables() async throws {
        let store = try store()
        let journal = try ChatJournal.open(files: files)
        let box = outbox(store, journal: journal)
        box.hold()
        let a = try setName(box, "a")
        let b = try box.enqueue(org: org, type: "run.started", args: .object([:]), orderKey: "exec:run", journal: true)
        let c = try setName(box, "c")
        XCTAssertLessThan(a.seq, b.seq)
        XCTAssertLessThan(b.seq, c.seq)
    }

    /// Signing in again (6.4): the old session is closed with the old token,
    /// and its request.create goes again under the new session — with a new
    /// connection: nothing of the old one carries the new token (review C-1).
    func testSigningInAgainClosesTheOldSessionAndMovesTheQueue() async throws {
        let account = "8c2b3b55-6b1e-4f5e-9a39-0e3c1f7a2d40"
        let tokens = FakeTokenStore()
        let service = ChatService(files: files, tokens: tokens)
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        var transports: [FakeSocketTransport] = []
        service.makeSocketTransport = {
            let t = FakeSocketTransport()
            transports.append(t)
            return t
        }
        service.followsFeed = true
        let org = self.org
        func me(_ session: String) -> Data {
            Data(#"{"account_id":"\#(account)","session_id":"\#(session)","orgs":[{"org_id":"\#(org)","org_name":"R","role":"owner","handle":"anna","name":"Anna"}],"streams":{}}"#.utf8)
        }
        let state = Data(#"{"org":{"org_id":"\#(org)","name":"R"},"members":[],"teams":[],"my_teams":[],"admin":null,"streams":{"org:\#(org)":0}}"#.utf8)
        let signIn = Data(#"{"token":"aps_new","session_id":"new-session","account_id":"\#(account)","orgs":[{"org_id":"\#(org)","org_name":"R","role":"owner","handle":"anna","name":"Anna"}]}"#.utf8)
        let info = Data(#"{"name":"agentpad-server","version":"0.1.0","generation":"g","api_versions":["v1"],"capabilities":["auth.email_code","events.ws"]}"#.utf8)
        let meOld = me("old-session"), meNew = me("new-session")
        let commandsWork = Counter()
        ChatStubProtocol.reset { request, _ in
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/server"): return .success(.init(status: 200, body: info))
            case ("GET", "/v1/me"): return .success(.init(status: 200, body: bearer.hasSuffix("aps_new") ? meNew : meOld))
            case ("GET", "/v1/orgs/\(org)/state"): return .success(.init(status: 200, body: state))
            case ("POST", "/v1/auth/session"): return .success(.init(status: 200, body: signIn))
            case ("DELETE", "/v1/auth/session"): return .success(.init(status: 204, body: Data()))
            default: return commandsWork.value > 0 ? .success(Self.ok) : .failure(URLError(.notConnectedToInternet))
            }
        }
        try service.saveSignIn(ChatConnection(server: server, accountId: account, sessionId: "old-session", deviceName: "Mac", orgId: org),
                               token: "aps_old")
        try await service.start(mode: .server)
        try await waitUntil { !transports.isEmpty }
        transports[0].frame(#"{"frame":"hello","generation":"g","heartbeat_seconds":25,"version":"0.1.0"}"#)
        let outbox = try XCTUnwrap(service.orgSessions[key(account)]?.outbox)
        try await waitUntil { outbox.paused == nil }
        outbox.retryDelay = { _ in 3600 }
        let create = try outbox.enqueue(org: org, type: "request.create", args: .object(["request_id": .string("r1")]))
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.path == "/v1/commands" } }

        commandsWork.increment()
        let answer = try await service.authenticate(server: server, email: "anna@example.com", code: "12345678", deviceName: "Mac")
        let made = try await service.completeSignIn(answer, server: server, deviceName: "Mac", orgId: org)
        try await service.keepSignIn()
        XCTAssertEqual(made.sessionId, "new-session")
        XCTAssertEqual(tokens.stored(made.tokenAccount), "aps_new")
        XCTAssertEqual(transports[0].closedWith, 1000, "the old connection stopped")
        try await service.start(mode: .server)
        try await waitUntil { transports.count == 2 }
        XCTAssertEqual(transports[1].request?.value(forHTTPHeaderField: "Authorization"), "Bearer aps_new")
        transports[1].frame(#"{"frame":"hello","generation":"g","heartbeat_seconds":25,"version":"0.1.0"}"#)
        try await waitUntil { ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/commands" }.count == 2 }
        let delete = try XCTUnwrap(ChatStubProtocol.seen.first { $0.request.httpMethod == "DELETE" })
        XCTAssertEqual(delete.request.value(forHTTPHeaderField: "Authorization"), "Bearer aps_old")
        let command = try XCTUnwrap(ChatStubProtocol.seen.last { $0.request.url?.path == "/v1/commands" })
        XCTAssertEqual(command.request.value(forHTTPHeaderField: "Authorization"), "Bearer aps_new")
        XCTAssertNotEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: command.body).commandId, create.commandId)
    }

    // MARK: Fourth review (review-client-c4.md 7–9)

    /// C4-7: a command remembers the server generation that took it.
    func testSentCommandRecordsItsGeneration() async throws {
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        let store = try store()
        let box = outbox(store)
        box.hold()
        box.allow(connection: 1, generation: "g1")
        let name = try setName(box)
        try await waitUntil { try self.state(store, name.commandId) == .sent }
        XCTAssertEqual(try store.commands().first?.sentGeneration, "g1")
    }

    /// C4-8: sending again keeps the chain — the dependent follows its
    /// parent's successor, the originals are dropped with a note.
    func testResendKeepsDependencies() async throws {
        ChatStubProtocol.reset { _, _ in .failure(URLError(.notConnectedToInternet)) }
        let store = try store()
        let box = outbox(store)
        box.retryDelay = { _ in 3600 }
        let parent = try setName(box, "A", orderKey: "a")
        let child = try setName(box, "B", orderKey: "b", dependsOn: parent.commandId)
        try await waitUntil { ChatStubProtocol.seen.count >= 1 }
        try box.generationChanged()
        let made = try box.resendUnconfirmed()
        XCTAssertEqual(made.count, 2)
        let newParent = try XCTUnwrap(made.first { $0.orderKey == "a" })
        let newChild = try XCTUnwrap(made.first { $0.orderKey == "b" })
        XCTAssertEqual(newChild.dependsOn, newParent.commandId, "the dependency follows the successor")
        let old = try store.commands().filter { [parent.commandId, child.commandId].contains($0.commandId) }
        XCTAssertEqual(old.map(\.state), [.dropped, .dropped])
        XCTAssertEqual(old.first { $0.commandId == parent.commandId }?.error, "sent again as \(newParent.commandId)")
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        box.resume()
        try await waitUntil { try self.state(store, newChild.commandId) == .sent }
        XCTAssertEqual(try state(store, newParent.commandId), .sent)
    }

    /// C4-9: what waits for the user is read from disk — a restarted app's
    /// queue shows it; refused commands stay listed until dismissed.
    func testQueueProblemsSurviveARestart() async throws {
        ChatStubProtocol.reset { _, _ in .failure(URLError(.notConnectedToInternet)) }
        let first = outbox(try store())
        first.retryDelay = { _ in 3600 }
        _ = try setName(first)
        try await waitUntil { ChatStubProtocol.seen.count == 1 }
        try first.generationChanged()
        ChatStubProtocol.reset { _, _ in .success(.init(status: 403, body: Data(#"{"error":"forbidden"}"#.utf8))) }
        let store = try store()
        let restarted = outbox(store, session: "s2")
        restarted.hold()
        XCTAssertEqual(restarted.unconfirmed.count, 1, "seen after a restart, with the queue not paused")
        XCTAssertNil(restarted.paused)
        restarted.allow(connection: 1)
        let refused = try setName(restarted, "B")
        try await waitUntil { try self.state(store, refused.commandId) == .failed }
        XCTAssertEqual(restarted.refused.map(\.commandId), [refused.commandId])
        restarted.dismissRefused()
        XCTAssertTrue(restarted.refused.isEmpty)
    }

    /// C5-9: a command added while the queue waited, depending on one that is
    /// sent again, follows the successor and goes after it.
    func testWaitingDependentFollowsTheResentParent() async throws {
        ChatStubProtocol.reset { _, _ in .failure(URLError(.notConnectedToInternet)) }
        let store = try store()
        let box = outbox(store)
        box.retryDelay = { _ in 3600 }
        let parent = try setName(box, "A", orderKey: "a")
        try await waitUntil { ChatStubProtocol.seen.count >= 1 }
        try box.generationChanged()
        let child = try setName(box, "B", orderKey: "a", dependsOn: parent.commandId)
        XCTAssertEqual(try state(store, child.commandId), .pending)
        let made = try box.resendUnconfirmed()
        let successor = try XCTUnwrap(made.first)
        let moved = try XCTUnwrap(try store.commands().first { $0.commandId == child.commandId })
        XCTAssertEqual(moved.dependsOn, successor.commandId)
        XCTAssertGreaterThan(moved.seq, successor.seq, "the dependent goes after its new parent")
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        box.resume()
        try await waitUntil { try self.state(store, child.commandId) == .sent }
        XCTAssertEqual(try state(store, successor.commandId), .sent)
        let order = try ChatStubProtocol.seen.suffix(2).map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).commandId }
        XCTAssertEqual(order, [successor.commandId, child.commandId])
    }

    /// C6-8: A unconfirmed, then B (depending on A) and C waiting, all of one
    /// order key: sent again, the order is A′, B, C — C's newer value is not
    /// overwritten by B's older one.
    func testResendKeepsTheOrderOfTheWholeOrderKey() async throws {
        ChatStubProtocol.reset { _, _ in .failure(URLError(.notConnectedToInternet)) }
        let store = try store()
        let box = outbox(store)
        box.retryDelay = { _ in 3600 }
        let a = try setName(box, "A", orderKey: "name")
        try await waitUntil { ChatStubProtocol.seen.count >= 1 }
        try box.generationChanged()
        let b = try setName(box, "B", orderKey: "name", dependsOn: a.commandId)
        let c = try setName(box, "C", orderKey: "name")
        let made = try box.resendUnconfirmed()
        let aNew = try XCTUnwrap(made.first)
        let waiting = try store.commands().filter { $0.state == .pending }.sorted { $0.seq < $1.seq }.map(\.commandId)
        XCTAssertEqual(waiting, [aNew.commandId, b.commandId, c.commandId])
        ChatStubProtocol.reset { _, _ in .success(Self.ok) }
        box.resume()
        try await waitUntil { try self.state(store, c.commandId) == .sent }
        let names = try ChatStubProtocol.seen.suffix(3).map {
            try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).args["name"]
        }
        XCTAssertEqual(names, [.string("A"), .string("B"), .string("C")])
    }

    private func key(_ account: String) -> ChatOrgKey { ChatOrgKey(server: server, accountId: account, orgId: org) }
}
