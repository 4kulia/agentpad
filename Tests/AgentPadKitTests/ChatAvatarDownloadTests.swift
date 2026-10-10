import AppKit
import GRDB
import XCTest
@testable import AgentPadKit

/// Responses stay open until a test releases them. No network timing determines
/// whether a row is queued, downloading, or cancelled.
private final class AvatarDownloadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var waiting: [AvatarDownloadProtocol] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var identifiers: [Int] = []
    nonisolated(unsafe) private static var cancellations = 0
    nonisolated(unsafe) private static var bytes = Data()
    static var seen: [URLRequest] { lock.withLock { requests } }
    static var taskIDs: [Int] { lock.withLock { identifiers } }
    static var cancelled: Int { lock.withLock { cancellations } }
    static func reset(_ data: Data) {
        lock.withLock { waiting = []; requests = []; identifiers = []; cancellations = 0; bytes = data }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock {
            Self.waiting.append(self); Self.requests.append(request)
            if let task { Self.identifiers.append(task.taskIdentifier) }
        }
    }
    override func stopLoading() {
        Self.lock.withLock {
            if let index = Self.waiting.firstIndex(where: { $0 === self }) {
                Self.waiting.remove(at: index); Self.cancellations += 1
            }
        }
    }
    static func release(_ count: Int = .max, status: Int = 200, body: Data? = nil) {
        let (ready, body) = lock.withLock {
            let ready = Array(waiting.prefix(count)); waiting.removeFirst(ready.count)
            return (ready, body ?? bytes)
        }
        for item in ready {
            let response = HTTPURLResponse(url: item.request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png", "X-Avatar-Revision": "1", "X-AgentPad-Generation": "g"])!
            item.client?.urlProtocol(item, didReceive: response, cacheStoragePolicy: .notAllowed)
            item.client?.urlProtocol(item, didLoad: body)
            item.client?.urlProtocolDidFinishLoading(item)
        }
    }
}

@MainActor
final class ChatAvatarDownloadTests: XCTestCase {
    private var fixture: AvatarTestFixture!
    private var refs: [ChatAvatarReference] = []
    private var tasks: [Task<Void, Never>] = []
    private var finished = Set<Int>()
    private var apiCount = 0
    override func setUp() async throws {
        fixture = try AvatarTestFixture()
        AvatarDownloadProtocol.reset(try AvatarTestImage.png())
        fixture.service.makeAPI = { [unowned self] in
            apiCount += 1
            return ChatAPI(server: $0, protocolClasses: [AvatarDownloadProtocol.self])
        }
        refs = [fixture.own] + (0..<7).map { _ in .init(key: fixture.key, subject: .account(ChatUUID.v7())) }
        try fixture.store.apply(.init(cursors: [:], members: refs.map {
            .init(accountId: $0.subject.id, handle: $0.subject.id, name: "Photo", role: "member")
        }), confirmsRights: "s")
        let context = try XCTUnwrap(fixture.service.avatarContext(fixture.key))
        for ref in refs { fixture.service.avatars.receive(.init(revision: 1, imageId: ChatUUID.v7()), for: ref, context: context) }
    }
    override func tearDown() async throws {
        tasks.forEach { $0.cancel() }
        await fixture.close()
        for task in tasks { await task.value }
        fixture = nil
    }
    @discardableResult private func start(_ index: Int) -> Task<Void, Never> {
        let id = tasks.count, ref = refs[index], service = fixture.service
        let task = Task { await service.avatars.load(ref); finished.insert(id) }
        tasks.append(task)
        return task
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Expected queue transition")
    }
    private func drain() async throws {
        let end = ContinuousClock.now + .seconds(2)
        while finished.count < tasks.count, ContinuousClock.now < end {
            AvatarDownloadProtocol.release()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(finished.count, tasks.count)
    }
    func testWaitingQueueDoesNoPollingAndSlotReleaseDoesNotReadSQLOnMainActor() async throws {
        let statements = Counter(), mainStatements = Counter()
        try await fixture.store.queue.write { db in
            db.trace { _ in
                statements.increment()
                if Thread.isMainThread { mainStatements.increment() }
            }
        }
        for index in refs.indices { start(index) }
        try await wait { AvatarDownloadProtocol.seen.count == 4 }
        let before = statements.value
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(statements.value, before, "Queued rows must remain asleep until a slot is released")
        let onMain = mainStatements.value
        AvatarDownloadProtocol.release(1)
        try await wait { AvatarDownloadProtocol.seen.count == 5 }
        XCTAssertEqual(mainStatements.value, onMain, "Waking a waiter must not synchronously query SQLite")
        try await drain()
        XCTAssertEqual(AvatarDownloadProtocol.seen.count, refs.count)
        XCTAssertEqual(apiCount, 1, "All reads in this scope share their API")
    }
    func testDisappearingViewsCancelActiveAndQueuedDownloadsAndWakeNextWaiter() async throws {
        for index in 0..<4 { start(index) }
        try await wait { AvatarDownloadProtocol.seen.count == 4 }
        let queued = start(4)
        start(5)
        await Task.yield()
        queued.cancel(); tasks[0].cancel()
        try await wait { AvatarDownloadProtocol.cancelled == 1 && AvatarDownloadProtocol.seen.count == 5 }
        XCTAssertEqual(AvatarDownloadProtocol.seen.last?.url?.path, try refs[5].subject.path(in: fixture.key) + "/" + fixture.service.avatars.metadata[refs[5].subject]!.imageId!)
        try await drain()
        XCTAssertFalse(AvatarDownloadProtocol.seen.contains { $0.url?.path.contains(refs[4].subject.id) == true })
        XCTAssertNil(fixture.service.avatars.image(refs[0]))
        XCTAssertNotNil(fixture.service.avatars.image(refs[5]))
    }
    func testSharedDownloadCancelsOnlyAfterItsLastViewDisappears() async throws {
        let first = start(0), second = start(0)
        try await wait { AvatarDownloadProtocol.seen.count == 1 }
        first.cancel()
        try await wait { finished.contains(0) }
        XCTAssertEqual(AvatarDownloadProtocol.cancelled, 0, "The other view still needs the shared request")
        second.cancel()
        try await wait { AvatarDownloadProtocol.cancelled == 1 && finished.count == 2 }
        XCTAssertEqual(AvatarDownloadProtocol.seen.count, 1)
        XCTAssertNil(fixture.service.avatars.image(refs[0]))
    }
    func testCancelledMetadataReloadsImmediatelyWhenRowReturns() async throws {
        let ref = refs[0]
        let version = try XCTUnwrap(fixture.service.avatars.metadata[ref.subject])
        let reply = try JSONEncoder().encode(ChatAvatarReply(generation: "g", accountId: ref.subject.id, avatar: version))
        fixture.service.avatars.clear()
        let first = start(0)
        try await wait { AvatarDownloadProtocol.seen.count == 1 }
        first.cancel()
        await first.value
        // Return before waiting for the cancelled transport to finish unwinding.
        let returning = start(0)
        try await wait { (AvatarDownloadProtocol.seen.count == 2 && AvatarDownloadProtocol.cancelled == 1) || finished.contains(1) }
        XCTAssertEqual(AvatarDownloadProtocol.seen.count, 2, "A cancelled metadata read must not consume the ten-second retry budget")
        guard AvatarDownloadProtocol.seen.count == 2 else { return }
        AvatarDownloadProtocol.release(1, body: reply)
        try await wait { AvatarDownloadProtocol.seen.count == 3 || finished.contains(1) }
        AvatarDownloadProtocol.release()
        await returning.value
        let path = try ref.subject.path(in: fixture.key)
        XCTAssertEqual(AvatarDownloadProtocol.seen.map { $0.url!.path }, [path, path, path + "/" + version.imageId!])
        XCTAssertNotNil(fixture.service.avatars.image(ref), "The remounted row loads without a timer or another invalidation")
    }
    func testCancelledImageReloadsImmediatelyWhenRowReturns() async throws {
        let first = start(0)
        try await wait { AvatarDownloadProtocol.seen.count == 1 }
        first.cancel()
        await first.value
        let returning = start(0)
        try await wait { (AvatarDownloadProtocol.seen.count == 2 && AvatarDownloadProtocol.cancelled == 1) || finished.contains(1) }
        XCTAssertEqual(AvatarDownloadProtocol.seen.count, 2)
        AvatarDownloadProtocol.release()
        await returning.value
        XCTAssertEqual(AvatarDownloadProtocol.seen.first?.url, AvatarDownloadProtocol.seen.last?.url,
                       "Successfully read metadata stays usable when only the image request was cancelled")
        XCTAssertNotNil(fixture.service.avatars.image(refs[0]))
    }
    func testFailedMetadataStillLimitsImmediateRetries() async throws {
        fixture.service.avatars.clear()
        let first = start(0)
        try await wait { AvatarDownloadProtocol.seen.count == 1 }
        AvatarDownloadProtocol.release(status: 503)
        await first.value
        await start(0).value
        XCTAssertEqual(AvatarDownloadProtocol.seen.count, 1, "An actual failure must still prevent a mount retry loop")
        XCTAssertNil(fixture.service.avatars.image(refs[0]))
    }
    func testAccessChangesWhileQueuedOrDownloadingRejectStaleImages() async throws {
        for index in 0..<5 { start(index) }
        try await wait { AvatarDownloadProtocol.seen.count == 4 }
        let ids = [refs[0].subject.id, refs[4].subject.id]
        try await fixture.store.queue.write { db in
            try db.execute(sql: "DELETE FROM members WHERE account_id IN (?, ?)", arguments: StatementArguments(ids))
        }
        try await drain()
        XCTAssertEqual(AvatarDownloadProtocol.seen.count, 4, "A queued read revalidates access before sending")
        try fixture.store.apply(.init(cursors: [:], members: refs.map {
            .init(accountId: $0.subject.id, handle: $0.subject.id, name: "Photo", role: "member")
        }), confirmsRights: "s")
        XCTAssertNil(fixture.service.avatars.image(refs[0]), "Late bytes must never enter the cache after access was removed")
        XCTAssertNil(fixture.service.avatars.image(refs[4]))
    }
    func testScopeReusesAPIAndURLSessionUntilInvalidation() async throws {
        let first = try XCTUnwrap(fixture.service.avatarAuthorization(refs[0]))
        let writer = try XCTUnwrap(fixture.service.avatarWriteAuthorization(refs[0]))
        XCTAssertTrue(first.api === writer.api)
        for index in 0..<2 {
            start(index)
            try await wait { AvatarDownloadProtocol.seen.count == index + 1 }
            AvatarDownloadProtocol.release()
            await tasks[index].value
        }
        XCTAssertEqual(apiCount, 1)
        XCTAssertEqual(AvatarDownloadProtocol.taskIDs.count, 2)
        XCTAssertEqual(Set(AvatarDownloadProtocol.taskIDs).count, 2, "One session issues successive task IDs, rather than a new session per request")
        fixture.service.invalidateAvatars()
        let next = try XCTUnwrap(fixture.service.avatarAuthorization(refs[0]))
        XCTAssertFalse(first.api === next.api, "A new access scope gets a fresh transport")
    }
    func testSharedTransportKeepsThePerRequestDeadline() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AvatarDownloadProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: fixture.key.server.baseURL)
        request.timeoutInterval = 0.05
        let transfer = Task {
            try await ChatAttachmentTransfer(limit: 1024, progress: { _ in })
                .run(request, upload: nil, protocols: nil, session: session)
        }
        try await wait { AvatarDownloadProtocol.cancelled == 1 }
        transfer.cancel()
        do { _ = try await transfer.value; XCTFail("The unanswered transfer must time out") } catch {}
    }
}
