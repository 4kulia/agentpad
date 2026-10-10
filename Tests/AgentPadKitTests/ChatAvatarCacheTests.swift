import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatAvatarCacheTests: XCTestCase {
    let server = try! ChatServerAddress(parsing: "https://avatars.example")
    let account = "01900000-0000-7000-8000-000000000003"
    let org = "01900000-0000-7000-8000-000000000005"
    let image = "01900000-0000-7000-8000-000000000004"
    var key: ChatOrgKey { .init(server: server, accountId: account, orgId: org) }
    var ref: ChatAvatarReference { .init(key: key, subject: .account(account)) }
    var live: ChatAvatarContext?
    var visible = true
    var cache: ChatAvatarCache!
    override func setUp() async throws {
        live = .init(key: key, session: "s", generation: "g", epoch: 1)
        cache = ChatAvatarCache(isCurrent: { [weak self] in self?.visible == true && self?.live == $0 }) { [weak self] ref in
            guard let self, self.visible, let live = self.live, ref.key == live.key else { return nil }
            return .init(context: live, api: ChatAPI(server: live.key.server, protocolClasses: [ChatStubProtocol.self]), token: "t")
        }
        let data = try AvatarTestImage.png()
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, headers: ["Content-Type": "image/png", "X-Avatar-Revision": "1", "X-AgentPad-Generation": "g"], body: data)) }
    }
    override func tearDown() async throws { cache.clear(); cache = nil; ChatStubProtocol.delay = 0 }
    private func seed() { cache.receive(.init(revision: 1, imageId: image), for: ref, context: live!) }
    private func inFlight() async throws {
        let until = ContinuousClock.now + .seconds(2)
        while ChatStubProtocol.seen.isEmpty {
            if ContinuousClock.now > until { XCTFail("no request"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testOnDemandVersionDeduplicationAndMemoryEviction() async throws {
        seed(); XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        await cache.load(ref); await cache.load(ref)
        XCTAssertEqual(ChatStubProtocol.seen.count, 1); XCTAssertNotNil(cache.image(ref))
        cache.countLimit = 1
        let another = ChatAvatarReference(key: key, subject: .agent(org))
        cache.receive(.init(revision: 1, imageId: image), for: another, context: live!)
        await cache.load(another)
        XCTAssertNotNil(cache.image(another)); XCTAssertNil(cache.image(ref))
    }
    func testOmittedAndOlderMetadataPreserveButRemovalImmediatelyClears() async throws {
        seed(); await cache.load(ref)
        cache.receive(nil, for: ref, context: live!)
        cache.receive(.init(revision: 0, imageId: nil), for: ref, context: live!)
        XCTAssertNotNil(cache.image(ref))
        cache.receive(.init(revision: 2, imageId: nil), for: ref, context: live!)
        XCTAssertNil(cache.image(ref))
        seed(); await cache.load(ref)
        XCTAssertEqual(cache.metadata[ref.subject]?.revision, 2)
        XCTAssertNil(cache.image(ref)); XCTAssertEqual(ChatStubProtocol.seen.count, 1)
    }
    func testEvictionUsesRecentReadsRatherThanInsertionOrder() async throws {
        cache.countLimit = 2
        let second = ChatAvatarReference(key: key, subject: .agent(ChatUUID.v7()))
        let third = ChatAvatarReference(key: key, subject: .agent(ChatUUID.v7()))
        for reference in [ref, second, third] {
            cache.receive(.init(revision: 1, imageId: image), for: reference, context: live!)
        }
        await cache.load(ref); await cache.load(second)
        XCTAssertNotNil(cache.image(ref)) // Most recently used, despite loading first.
        await cache.load(third)
        XCTAssertNotNil(cache.image(ref))
        XCTAssertNil(cache.image(second))
        XCTAssertNotNil(cache.image(third))
    }
    func testEvictionPrefersNonVisibleImagesAndChangesTheirLoadGeneration() async throws {
        cache.countLimit = 2
        let second = ChatAvatarReference(key: key, subject: .agent(ChatUUID.v7()))
        let third = ChatAvatarReference(key: key, subject: .agent(ChatUUID.v7()))
        for reference in [ref, second, third] {
            cache.receive(.init(revision: 1, imageId: image), for: reference, context: live!)
        }
        let view = UUID()
        cache.setVisible(ref, id: view)
        await cache.load(ref); await cache.load(second)
        let generation = cache.imageGeneration(second)
        await cache.load(third)
        XCTAssertNotNil(cache.image(ref), "The oldest image is still visible")
        XCTAssertNil(cache.image(second), "Evict a newer, non-visible image first")
        XCTAssertNotEqual(cache.imageGeneration(second), generation)
        cache.setVisible(nil, id: view)
        await cache.load(second)
        XCTAssertNotNil(cache.image(second))
    }
    func testLateBytesNeverOverwriteNewerRemoval() async throws {
        seed(); ChatStubProtocol.delay = 0.06
        let pending = Task { await cache.load(ref) }; try await inFlight()
        cache.receive(.init(revision: 2, imageId: nil), for: ref, context: live!)
        await pending.value
        XCTAssertNil(cache.image(ref)); XCTAssertEqual(cache.metadata[ref.subject]?.revision, 2)
    }
    func testLateResponsesDroppedAcrossServerAccountOrgGenerationSessionAndAccessEpoch() async throws {
        let otherServer = try ChatServerAddress(parsing: "https://other.example")
        let contexts: [ChatAvatarContext?] = [
            nil,
            .init(key: .init(server: otherServer, accountId: account, orgId: org), session: "s", generation: "g", epoch: 1),
            .init(key: .init(server: server, accountId: image, orgId: org), session: "s", generation: "g", epoch: 1),
            .init(key: .init(server: server, accountId: account, orgId: image), session: "s", generation: "g", epoch: 1),
            .init(key: key, session: "s", generation: "restored", epoch: 1),
            .init(key: key, session: "new", generation: "g", epoch: 1),
            .init(key: key, session: "s", generation: "g", epoch: 2)
        ]
        for next in contexts {
            cache.clear(); live = .init(key: key, session: "s", generation: "g", epoch: 1); seed()
            let count = ChatStubProtocol.seen.count; ChatStubProtocol.delay = 0.05
            let pending = Task { await cache.load(ref) }
            while ChatStubProtocol.seen.count == count { await Task.yield() }
            live = next; await pending.value
            XCTAssertNil(cache.image(ref))
            live = .init(key: key, session: "s", generation: "g", epoch: 1)
            XCTAssertNil(cache.image(ref), "Late bytes were never inserted")
        }
    }
    func testNoAuthorizationNoProbeAndCrossScopeRequestsAreRejected() async throws {
        live = nil; await cache.load(ref, refresh: true)
        live = .init(key: key, session: "s", generation: "g", epoch: 1)
        let other = ChatAvatarReference(key: .init(server: server, accountId: image, orgId: org), subject: ref.subject)
        await cache.load(other, refresh: true)
        visible = false; await cache.load(ref, refresh: true)
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = ChatService(files: ChatFiles(directory: root), tokens: FakeTokenStore())
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        service.serverCapabilities[server] = ["chat.avatars"]
        service.avatarGenerations[server] = "g"
        await service.avatars.load(ref, refresh: true)
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testLateMetadataCannotResurrectTombstoneAnd404ClearsBytes() async throws {
        let reply = ChatAvatarReply(generation: "g", accountId: account, avatar: .init(revision: 1, imageId: image))
        let data = try JSONEncoder().encode(reply)
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: data)) }; ChatStubProtocol.delay = 0.05
        let pending = Task { await cache.load(ref) }; try await inFlight()
        cache.receive(.init(revision: 3, imageId: nil), for: ref, context: live!)
        await pending.value
        XCTAssertEqual(cache.metadata[ref.subject]?.revision, 3); XCTAssertEqual(ChatStubProtocol.seen.count, 1)
        cache.clear(); seed()
        let bytes = try AvatarTestImage.png()
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, headers: ["Content-Type": "image/png", "X-Avatar-Revision": "1", "X-AgentPad-Generation": "g"], body: bytes)) }
        await cache.load(ref); XCTAssertNotNil(cache.image(ref))
        ChatStubProtocol.reset { _, _ in .success(.init(status: 404)) }
        await cache.load(ref, refresh: true); XCTAssertNil(cache.image(ref))
    }
    func testSignedInLegacyServerNeverRequestsAndCapabilityLossPurgesMemory() async throws {
        let fixture = try AvatarTestFixture(capable: false)
        await fixture.service.avatars.load(fixture.own, refresh: true)
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        fixture.service.serverCapabilities[fixture.key.server] = ["chat.avatars"]
        let context = try XCTUnwrap(fixture.service.avatarContext(fixture.key))
        fixture.service.avatars.receive(.init(revision: 1, imageId: image), for: fixture.own, context: context)
        await fixture.service.avatars.load(fixture.own)
        XCTAssertNotNil(fixture.service.avatars.image(fixture.own))
        fixture.service.serverCapabilities[fixture.key.server] = []
        XCTAssertNil(fixture.service.avatars.image(fixture.own))
        XCTAssertTrue(fixture.service.avatars.metadata.isEmpty)
        let count = ChatStubProtocol.seen.count
        await fixture.service.avatars.load(fixture.own, refresh: true)
        XCTAssertEqual(ChatStubProtocol.seen.count, count)
        await fixture.close()
    }

    func testMembershipAndRightsCommitsInvalidateMemoizedVisibility() async throws {
        let fixture = try AvatarTestFixture()
        let service = fixture.service
        let other = ChatAvatarReference(key: fixture.key, subject: .account(ChatUUID.v7()))
        let members: [ChatSnapshot.Member] = [fixture.own, other].map {
            .init(accountId: $0.subject.id, handle: $0.subject.id, name: "Photo", role: "member")
        }
        XCTAssertNil(service.avatarAuthorization(other))
        let deniedEpoch = service.avatarEpoch
        try fixture.store.apply(.init(cursors: [:], members: members), confirmsRights: "s")
        XCTAssertGreaterThan(service.avatarEpoch, deniedEpoch)
        let allowed = try XCTUnwrap(service.avatarAuthorization(other))
        try await fixture.store.queue.write { db in
            try db.execute(sql: "UPDATE members SET name = 'Renamed' WHERE account_id = ?", arguments: [other.subject.id])
        }
        XCTAssertEqual(service.avatarEpoch, allowed.context.epoch, "A rename does not change avatar visibility")
        XCTAssertEqual(service.avatarAuthorization(other)?.context, allowed.context)
        try fixture.store.putRightsInDoubt()
        XCTAssertGreaterThan(service.avatarEpoch, allowed.context.epoch)
        XCTAssertNil(service.avatarAuthorization(other), "Cached authorization cannot survive rights in doubt")
        try fixture.store.apply(.init(cursors: [:], members: members), confirmsRights: "s")
        XCTAssertNotNil(service.avatarAuthorization(other), "The denied result must expire when rights are confirmed")
        await fixture.close()
    }

    func testImage404RefreshesMetadataAndFetchesOnlyTheNewImageVersion() async throws {
        let next = ChatUUID.v7(), bytes = try AvatarTestImage.png()
        let reply = ChatAvatarReply(generation: "g", accountId: account, avatar: .init(revision: 2, imageId: next))
        let json = try JSONEncoder().encode(reply)
        ChatStubProtocol.reset { request, _ in
            if request.url?.lastPathComponent == "avatar" { return .success(.init(status: 200, body: json)) }
            if request.url?.lastPathComponent == next {
                return .success(.init(status: 200, headers: ["Content-Type": "image/png", "X-Avatar-Revision": "2", "X-AgentPad-Generation": "g"], body: bytes))
            }
            return .success(.init(status: 404))
        }
        seed(); await cache.load(ref)
        XCTAssertEqual(cache.metadata[ref.subject]?.imageId, next)
        XCTAssertNotNil(cache.image(ref))
        XCTAssertEqual(ChatStubProtocol.seen.count, 3)
    }
    func testManyVisibleSubjectsBoundConcurrentReadsAndDropQueuedRequestsOnRevocation() async throws {
        let refs = (0..<12).map { _ in ChatAvatarReference(key: key, subject: .agent(ChatUUID.v7())) }
        for ref in refs { cache.receive(.init(revision: 1, imageId: image), for: ref, context: live!) }
        ChatStubProtocol.delay = 0.05
        let tasks = refs.map { ref in Task { await cache.load(ref) } }
        for task in tasks { await task.value }
        XCTAssertLessThanOrEqual(ChatStubProtocol.maxInFlight, 4)
        XCTAssertEqual(ChatStubProtocol.seen.count, 12)
        cache.clear()
        for ref in refs { cache.receive(.init(revision: 1, imageId: image), for: ref, context: live!) }
        let more = refs.map { ref in Task { await cache.load(ref) } }
        await Task.yield(); live = nil; cache.clear()
        for task in more { await task.value }
        XCTAssertTrue(cache.metadata.isEmpty)
        XCTAssertTrue(refs.allSatisfy { cache.image($0) == nil })
    }

}
