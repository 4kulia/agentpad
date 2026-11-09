import AppKit
import AgentPadQuietTestSupport
import GRDB
import XCTest
@testable import AgentPadKit

/// Tests release the actual URLSession responses explicitly. No server or
/// network timing is involved in consumer, queue, or reuse assertions.
private final class NativeAvatarProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var waiting: [NativeAvatarProtocol] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var stopped = 0
    nonisolated(unsafe) private static var bytes = Data()
    static var seen: [URLRequest] { lock.withLock { requests } }
    static var cancelled: Int { lock.withLock { stopped } }
    static func reset(_ data: Data) { lock.withLock { waiting = []; requests = []; stopped = 0; bytes = data } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.waiting.append(self); Self.requests.append(request) } }
    override func stopLoading() {
        Self.lock.withLock {
            if let index = Self.waiting.firstIndex(where: { $0 === self }) { Self.waiting.remove(at: index); Self.stopped += 1 }
        }
    }
    @discardableResult static func release(path: String? = nil, body: Data? = nil, status: Int = 200) -> Int {
        let (ready, data) = lock.withLock {
            let ready = waiting.filter { path == nil || $0.request.url?.path == path }
            waiting.removeAll { item in ready.contains { $0 === item } }
            return (ready, body ?? bytes)
        }
        for item in ready {
            let response = HTTPURLResponse(url: item.request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png", "X-Avatar-Revision": "1", "X-AgentPad-Generation": "g"])!
            item.client?.urlProtocol(item, didReceive: response, cacheStoragePolicy: .notAllowed)
            item.client?.urlProtocol(item, didLoad: data)
            item.client?.urlProtocolDidFinishLoading(item)
        }
        return ready.count
    }
}

@MainActor final class ChatNativeAvatarTests: XCTestCase {
    private var fixture: AvatarTestFixture!
    private var refs: [ChatAvatarReference] = []
    private var views: [ChatNativeAvatarView] = []
    private var transports = 0
    private var style: NativeTimelineSnapshot.Style { ChatTimelineW01.style() }

    override func setUp() async throws {
        fixture = try AvatarTestFixture()
        transports = 0
        NativeAvatarProtocol.reset(try AvatarTestImage.png())
        fixture.service.makeAPI = { [unowned self] in
            transports += 1
            return ChatAPI(server: $0, protocolClasses: [NativeAvatarProtocol.self])
        }
        refs = [fixture.own] + (0..<5).map { _ in .init(key: fixture.key, subject: .account(ChatUUID.v7())) }
        try fixture.store.apply(.init(cursors: [:], members: refs.map {
            .init(accountId: $0.subject.id, handle: $0.subject.id, name: "Photo", role: "member")
        }), confirmsRights: "s")
        let context = try XCTUnwrap(fixture.service.avatarDisplayContext(fixture.key))
        for ref in refs { fixture.service.avatars.receive(.init(revision: 1, imageId: ChatUUID.v7()), for: ref, context: context) }
    }
    override func tearDown() async throws {
        views.forEach { $0.unbind() }; views = []
        await fixture.close(); fixture = nil
        refs = []
    }
    private func binding(_ row: String = "reference-avatar", revision: UInt64 = 1) -> ChatNativeShellCell.Binding {
        let conversation = NativeTimelineSnapshot.Conversation(key: fixture.key, address: .channel("avatar-fixture"), root: nil)
        return .init(id: .init(conversation: conversation, kind: .message(row)), epoch: ChatTimelineW01.epoch,
                     contentRevision: revision, reuseGeneration: revision)
    }
    private func source(_ index: Int) -> NativeTimelineSnapshot.Avatar {
        let ref = refs[index], service = fixture.service
        return .init(reference: ref, metadata: service.avatars.metadata[ref.subject],
                     generation: service.avatars.imageGeneration(ref), context: service.avatarDisplayContext(fixture.key))
    }
    private func imagePath(_ index: Int) throws -> String {
        let ref = refs[index]
        let image = try XCTUnwrap(fixture.service.avatars.metadata[ref.subject]?.imageId)
        return try ref.subject.path(in: fixture.key) + "/" + image
    }
    private func configure(_ view: ChatNativeAvatarView, _ index: Int, row: String = "reference-avatar", revision: UInt64 = 1,
                           fallback: ChatNativeAvatarView.Fallback = .own) {
        view.configure(placeholder: .init(stableID: refs[index].subject.id, name: "Photo", kind: .person),
                       source: source(index), owner: binding(row, revision: revision), style: style,
                       service: fixture.service, fallback: fallback)
    }
    private func make(_ index: Int, visible: Bool = true) -> ChatNativeAvatarView {
        let view = ChatNativeAvatarView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        views.append(view); configure(view, index); view.setVisible(visible)
        return view
    }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Expected controlled avatar transition", file: file, line: line)
    }

    func testHiddenConfigureAndGeometryDoNoWorkAndRevisionReplacesPendingConsumer() async throws {
        let view = make(0, visible: false)
        for revision in 2...5 { configure(view, 0, revision: UInt64(revision)); view.layoutSubtreeIfNeeded() }
        XCTAssertEqual(transports, 0); XCTAssertTrue(NativeAvatarProtocol.seen.isEmpty)
        XCTAssertFalse(view.hasLoadTask); XCTAssertNil(view.registeredReference); XCTAssertNil(view.heldImage)
        view.setVisible(true)
        let other = make(0)
        try await wait { NativeAvatarProtocol.seen.count == 1 }
        let serial = view.requestSerial
        configure(view, 0, revision: 9)
        XCTAssertGreaterThan(view.requestSerial, serial, "Every full cell binding fences its own consumer completion")
        XCTAssertEqual(view.boundOwner, binding(revision: 9))
        NativeAvatarProtocol.release()
        try await wait { view.hasImage && !view.hasLoadTask && other.hasImage }
        XCTAssertEqual(NativeAvatarProtocol.seen.count, 1)
        XCTAssertEqual(transports, 1)
    }

    func testDuplicateConsumersCancelOnlyWhenLastViewHides() async throws {
        let first = make(0), second = make(0)
        try await wait { NativeAvatarProtocol.seen.count == 1 }
        first.setVisible(false)
        XCTAssertFalse(first.hasLoadTask); XCTAssertNil(first.registeredReference); XCTAssertNil(first.heldImage)
        await Task.yield()
        XCTAssertEqual(NativeAvatarProtocol.cancelled, 0)
        second.setVisible(false)
        try await wait { NativeAvatarProtocol.cancelled == 1 }
        XCTAssertFalse(second.hasLoadTask); XCTAssertNil(second.registeredReference)
        first.setVisible(true)
        try await wait { NativeAvatarProtocol.seen.count == 2 }
        NativeAvatarProtocol.release()
        try await wait { first.hasImage }
        XCTAssertFalse(second.hasImage)
    }

    func testHiddenQueuedConsumerNeverStartsAndNextVisibleWaiterAdvances() async throws {
        let active = (0..<4).map { make($0) }
        try await wait { NativeAvatarProtocol.seen.count == 4 }
        let queued = make(4), next = make(5)
        await Task.yield()
        queued.setVisible(false); active[0].setVisible(false)
        try await wait { NativeAvatarProtocol.cancelled == 1 && NativeAvatarProtocol.seen.count == 5 }
        XCTAssertFalse(NativeAvatarProtocol.seen.contains { $0.url?.path.contains(refs[4].subject.id) == true })
        NativeAvatarProtocol.release()
        try await wait { next.hasImage && active.dropFirst().allSatisfy(\.hasImage) }
        XCTAssertNil(queued.heldImage); XCTAssertFalse(queued.hasLoadTask)
    }

    func testReusingAViewRejectsThePreviousRowAndHideRejectsCompletion() async throws {
        let reused = make(0), survivor = make(0)
        try await wait { NativeAvatarProtocol.seen.count == 1 }
        configure(reused, 1, row: "replacement")
        try await wait { NativeAvatarProtocol.seen.count == 2 }
        XCTAssertEqual(NativeAvatarProtocol.release(path: try imagePath(0)), 1)
        try await wait { survivor.hasImage }
        XCTAssertFalse(reused.hasImage)
        XCTAssertEqual(reused.registeredReference, refs[1])
        reused.setVisible(false)
        try await wait { NativeAvatarProtocol.cancelled == 1 }
        XCTAssertEqual(NativeAvatarProtocol.release(path: try imagePath(1)), 0, "The hidden consumer's request was cancelled")
        XCTAssertFalse(reused.hasImage); XCTAssertNil(reused.heldImage); XCTAssertFalse(reused.hasLoadTask)
        configure(reused, 0); reused.setVisible(true)
        try await wait { reused.hasImage }
        XCTAssertEqual(reused.registeredReference, refs[0])
    }

    func testMountedPhotosRemainHeldUnderCountAndBytePressure() async throws {
        let cache = fixture.service.avatars
        cache.countLimit = 1
        let mounted = (0..<3).map { make($0) }
        try await wait { NativeAvatarProtocol.seen.count == 3 }
        NativeAvatarProtocol.release()
        try await wait { mounted.allSatisfy(\.hasImage) && mounted.allSatisfy { !$0.hasLoadTask } }
        XCTAssertEqual(refs.prefix(3).filter { cache.image($0) != nil }.count, 1)
        XCTAssertTrue(mounted.allSatisfy { $0.heldImage != nil })
        let version = cache.metadata, context = try XCTUnwrap(fixture.service.avatarDisplayContext(fixture.key))
        cache.byteLimit = 1; cache.clear()
        for ref in refs { cache.receive(version[ref.subject], for: ref, context: context) }
        for index in mounted.indices { configure(mounted[index], index) }
        try await wait { NativeAvatarProtocol.seen.count == 6 }
        NativeAvatarProtocol.release()
        try await wait { mounted.allSatisfy(\.hasImage) && mounted.allSatisfy { !$0.hasLoadTask } }
        XCTAssertTrue(refs.allSatisfy { cache.image($0) == nil })
        for index in mounted.indices { configure(mounted[index], index) }
        XCTAssertEqual(NativeAvatarProtocol.seen.count, 6, "Uncached held photos must not start a configure/reload loop")
        mounted[0].setVisible(false)
        XCTAssertNil(mounted[0].heldImage); XCTAssertTrue(mounted[1].hasImage)
    }

    func testHeldPhotoAndDelayedBytesAreRejectedAtLiveAccessFence() async throws {
        fixture.service.avatars.countLimit = 0
        let held = make(1), pending = make(2)
        try await wait { NativeAvatarProtocol.seen.count == 2 }
        XCTAssertEqual(NativeAvatarProtocol.release(path: try imagePath(1)), 1)
        try await wait { held.hasImage }
        try fixture.store.apply(.init(cursors: [:], members: [
            .init(accountId: fixture.key.accountId, handle: "me", name: "Me", role: "member")
        ]), confirmsRights: "s")
        XCTAssertFalse(held.hasImage, "The draw fence must reject held bytes before another snapshot is installed")
        XCTAssertNil(held.heldImage)
        XCTAssertEqual(NativeAvatarProtocol.release(path: try imagePath(2)), 1)
        try await wait { !pending.hasLoadTask }
        XCTAssertFalse(pending.hasImage); XCTAssertNil(pending.heldImage)
        configure(held, 1); configure(pending, 2)
        try await wait { !held.hasLoadTask && !pending.hasLoadTask }
        XCTAssertEqual(NativeAvatarProtocol.seen.count, 2, "Revoked subjects cannot fetch again")
    }

    func testMetadataTombstoneAndServiceInvalidationClearHeldPhotos() async throws {
        fixture.service.avatars.countLimit = 0
        let view = make(0)
        try await wait { NativeAvatarProtocol.seen.count == 1 }
        NativeAvatarProtocol.release()
        try await wait { view.hasImage }
        let old = try XCTUnwrap(fixture.service.avatars.metadata[refs[0].subject])
        let context = try XCTUnwrap(fixture.service.avatarDisplayContext(fixture.key))
        fixture.service.avatars.receive(.init(revision: 2, imageId: nil), for: refs[0], context: context)
        XCTAssertFalse(view.hasImage)
        fixture.service.avatars.receive(old, for: refs[0], context: context)
        XCTAssertEqual(fixture.service.avatars.metadata[refs[0].subject], .init(revision: 2, imageId: nil))
        configure(view, 0)
        try await wait { !view.hasLoadTask }
        XCTAssertEqual(NativeAvatarProtocol.seen.count, 1)
        fixture.service.invalidateAvatars()
        XCTAssertFalse(view.hasImage); XCTAssertNil(view.heldImage)
    }

    func testTransparentPhotoReplacesFallbackAndUnbindReleasesEverything() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 6, height: 32))
        let bytes = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        let view = make(0)
        let host = NativeAvatarBlackView(frame: view.frame); host.addSubview(view)
        try await wait { NativeAvatarProtocol.seen.count == 1 }
        NativeAvatarProtocol.release(body: bytes)
        try await wait { view.hasImage }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(center.redComponent, 0.02); XCTAssertLessThan(center.greenComponent, 0.02); XCTAssertLessThan(center.blueComponent, 0.02)
        view.unbind()
        XCTAssertFalse(view.hasImage); XCTAssertNil(view.heldImage); XCTAssertNil(view.registeredReference); XCTAssertFalse(view.hasLoadTask)
    }

    func testCoordinatorResolvesMainAndReplyServicesAndUsesActualClipVisibility() async throws {
        XCTAssertTrue(APQuietIsEnabled(), "Run through scripts/test-quiet.py")
        _ = NSApplication.shared; AgentPadFonts.registerOnce()
        let model = ChatTimelineW01Model(directory: fixture.root, key: fixture.key, service: fixture.service)
        var message = ChatTimelineW01.message("reference-summary-local-one")
        message.authorAccountId = refs[0].subject.id
        message.text = Array(repeating: "A tall message keeps the reply avatar below the visible clip.", count: 70).joined(separator: "\n\n")
        var reply = ChatTimelineW01.message("reference-summary-local-one-reply", seq: 2, root: message.id)
        reply.authorAccountId = refs[1].subject.id
        model.feed.messages = [message] + (3..<33).map { ChatTimelineW01.message("clip-filler-\($0)", seq: $0) }
        model.feed.replySummaries[message.id] = .init(messages: [reply], complete: true)
        let adapter = ChatTimelineAdapter(), coordinator = NativeChatTimelineCoordinator()
        let container = NativeChatTimelineContainer(coordinator: coordinator)
        let host = ChatQuietHost(view: container, dark: false, width: 760, height: 300)
        defer { coordinator.dispose(); adapter.invalidate(); host.close() }
        let snapshot = adapter.snapshot(model: model, root: nil, members: refs.map {
            .init(accountId: $0.subject.id, handle: $0.subject.id, name: "Photo", role: "member")
        }, mentionable: [], me: fixture.key.accountId, archived: false, ownerModel: nil, style: style)
        coordinator.actions = adapter.actions
        container.update(snapshot); try await host.settle()
        XCTAssertTrue(adapter.actions?.avatarService(messageID: message.id) === fixture.service)
        XCTAssertNil(adapter.actions?.avatarService(messageID: "absent-row"))
        let index = try XCTUnwrap(coordinator.messageIndex(message.id)), scroll = coordinator.scrollView
        coordinator.scrollController.stopFollowing()
        func scrollTo(_ y: CGFloat) async throws {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await host.settle()
        }
        coordinator.tableView.layoutSubtreeIfNeeded()
        XCTAssertTrue(coordinator.scrollController.scrollTo(messageID: message.id, alignment: .top))
        try await host.settle()
        let cell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell)
        let replyAvatar = try XCTUnwrap(cell.replySummary.parityAvatars.first)
        let plan = try XCTUnwrap(cell.plan)
        func geometry(_ stage: String) -> String {
            "W06 avatar viewport \(stage): row=\(coordinator.tableView.rect(ofRow: index)), cell=\(cell.frame), body=\(plan.body), "
                + "summary=\(cell.replySummary.frame), replyTable=\(replyAvatar.convert(replyAvatar.bounds, to: coordinator.tableView)), "
                + "clip=\(scroll.contentView.bounds), visible=\(replyAvatar.visibleRect)"
        }
        let clippedGeometry = geometry("top")
        print(clippedGeometry)
        XCTAssertGreaterThan(plan.body.height, scroll.contentView.bounds.height, clippedGeometry)
        XCTAssertFalse(replyAvatar.convert(replyAvatar.bounds, to: coordinator.tableView).intersects(scroll.contentView.bounds), clippedGeometry)
        XCTAssertEqual(replyAvatar.frame.size, CGSize(width: 21, height: 21))
        XCTAssertTrue(replyAvatar.visibleRect.intersection(replyAvatar.bounds).isEmpty, clippedGeometry)
        XCTAssertNil(replyAvatar.registeredReference); XCTAssertFalse(replyAvatar.hasLoadTask)
        let mainPath = try imagePath(0), replyPath = try imagePath(1)
        try await wait { NativeAvatarProtocol.seen.contains { $0.url?.path == mainPath } }
        XCTAssertFalse(NativeAvatarProtocol.seen.contains { $0.url?.path == replyPath }, "A visible tall row must not start its clipped reply avatar")
        XCTAssertEqual(NativeAvatarProtocol.release(path: mainPath), 1)
        try await wait { cell.mainAvatar.hasImage }
        let replyFrame = replyAvatar.convert(replyAvatar.bounds, to: coordinator.tableView)
        try await scrollTo(replyFrame.minY - 50)
        let shownGeometry = geometry("reply")
        print(shownGeometry)
        XCTAssertTrue(replyAvatar.convert(replyAvatar.bounds, to: coordinator.tableView).intersects(scroll.contentView.bounds), shownGeometry)
        XCTAssertFalse(replyAvatar.visibleRect.intersection(replyAvatar.bounds).isEmpty, shownGeometry)
        XCTAssertFalse(cell.mainAvatar.convert(cell.mainAvatar.bounds, to: coordinator.tableView).intersects(scroll.contentView.bounds), shownGeometry)
        XCTAssertFalse(cell.mainAvatar.hasLoadTask, "The main avatar is clipped even while its tall row remains visible")
        XCTAssertNil(cell.mainAvatar.registeredReference, "A clipped main avatar must release its cache visibility registration")
        XCTAssertNil(cell.mainAvatar.heldImage, "A clipped main avatar must release its held photo")
        try await wait { NativeAvatarProtocol.seen.contains { $0.url?.path == replyPath } }
        XCTAssertEqual(replyAvatar.registeredReference, refs[1])
        XCTAssertEqual(NativeAvatarProtocol.release(path: replyPath), 1)
        try await wait { replyAvatar.hasImage }
        try await scrollTo(coordinator.tableView.rect(ofRow: index).maxY + 100)
        XCTAssertFalse(replyAvatar.hasImage); XCTAssertNil(replyAvatar.heldImage)
        XCTAssertFalse(replyAvatar.hasLoadTask); XCTAssertNil(replyAvatar.registeredReference)
        XCTAssertFalse(cell.mainAvatar.hasImage); XCTAssertNil(cell.mainAvatar.heldImage)
        XCTAssertFalse(cell.mainAvatar.hasLoadTask); XCTAssertNil(cell.mainAvatar.registeredReference)
    }

    func testDeletedChannelSummaryAndRequestButtonsOpenExistingThread() async throws {
        let f = try await ChatNativeActionFixture(count: 2)
        defer { f.dispose() }
        let root = f.messages[0], reply = f.messages[1]
        try f.base.write("UPDATE messages SET thread_root_id = ? WHERE message_id = ?", [root.id, reply.id])
        try f.base.write("UPDATE messages SET deleted_at = '2026-10-26T12:00:00Z' WHERE message_id = ?", [root.id])
        try f.base.move("finished", 1, here: false, publication: "published")
        try f.base.write("UPDATE requests SET thread_root_id = ? WHERE channel_id = ?", [root.id, root.channelId])
        try await f.settle()
        XCTAssertTrue(try XCTUnwrap(f.model.message(root.id)).deleted)
        XCTAssertEqual(f.model.feed.replySummaries[root.id]?.count, 1)
        XCTAssertEqual(f.model.feed.requests[root.id], 1)
        for server in [false, true] {
            f.base.service.serverCapabilities[f.base.key.server] = server ? ["chat.thread_summary"] : []
            if server {
                let summary = ChatB1.Summary(rootId: root.id, replyCount: 1, lastReplyAt: reply.createdAt,
                    lastReplySeq: reply.seq, lastParticipants: [.init(authorAccountId: reply.authorAccountId)])
                let metadata = ChatB1.Metadata(messageId: root.id, deleted: true, reactions: [], pin: nil, threadSummary: summary)
                try f.base.write("INSERT OR REPLACE INTO b1_metadata (channel_id, message_id, data, dirty) VALUES (?, ?, ?, 0)",
                    [root.channelId, root.id, try JSONEncoder().encode(metadata)])
            }
            try await f.settle()
            let row = try f.row(root.id), summary = row.replySummary
            XCTAssertEqual(summary.parityPlan?.kind, server ? .server : .local)
            XCTAssertFalse(summary.parityButton.isHidden)
            XCTAssertFalse(try XCTUnwrap(f.adapter.actions).perform(.reply, messageID: root.id),
                "The toolbar's create-reply policy still excludes deleted channel messages")
            summary.parityButton.isEnabled = false
            XCTAssertFalse(summary.parityButton.accessibilityPerformPress())
            XCTAssertNil(f.model.threadRoot, "A disabled reply summary cannot open a thread")
            summary.parityButton.isEnabled = true
            XCTAssertTrue(summary.parityButton.accessibilityPerformPress(), "A dispatched native summary AX action reports success")
            XCTAssertEqual(f.model.threadRoot, root.id, "Existing replies remain reachable after root deletion")
            f.model.openThread(nil)
            try await f.settle()
            let requests = try f.row(root.id).replySummary.parityRequestButton
            XCTAssertFalse(requests.isHidden)
            requests.performClick(nil)
            XCTAssertEqual(f.model.threadRoot, root.id, "Request-count links navigate to the same existing root")
            f.model.openThread(nil)
            try await f.settle()
        }
        let summary = try f.row(root.id).replySummary
        f.adapter.invalidate()
        summary.parityButton.performClick(nil)
        summary.parityRequestButton.performClick(nil)
        XCTAssertNil(f.model.threadRoot, "A disposed pane cannot dispatch retained summary controls")
        summary.unbind()
        XCTAssertFalse(summary.parityButton.accessibilityPerformPress(), "An unbound native summary has no AX action")
        XCTAssertTrue(try f.commands().isEmpty)
        await f.close()
    }

    func testReferenceReplyVariantsChooseLocalServerAndParticipantNames() {
        if let symbol = ChatNativeReplySummaryLayout.chevron(style: style) {
            print("W06 reply chevron: size=\(symbol.size), alignmentRect=\(symbol.alignmentRect)")
        }
        let base = ChatTimelineW01.message("reference-summary-local-three-identities")
        var agent = ChatTimelineW01.message("reference-summary-local-three-identities-reply-1", seq: 2, root: base.id)
        agent.authorAccountId = CallJSON.boris; agent.authorAgentId = CallJSON.agent; agent.authorAgentName = "Billing agent"
        var session = agent; session.messageId = "reference-summary-local-three-identities-reply-2"
        session.authorAgentId = nil; session.authorSessionName = "Review session"; session.seq = 3
        let local = ChatReplySummary(messages: [base, agent, session], complete: false)
        let server = ChatB1.Summary(rootId: base.id, replyCount: 7, lastReplyAt: base.createdAt, lastReplySeq: 8, lastParticipants: [
            .init(authorAccountId: "w01-me", authorAgentId: CallJSON.agent, authorAgentName: "Billing agent"),
            .init(authorAccountId: CallJSON.boris, authorSessionName: "Review session"), .init(authorAccountId: "removed-member")])
        let snapshot = ChatTimelineSnapshotBuilder().build(ChatTimelineW01.input(messages: [ChatTimelineW01.content(base)]))
        let body = CGRect(x: 68, y: 34, width: 668, height: 20)
        func plan(_ summary: ChatB1.Summary?, unread: Int = 0, requests: Int = 0, thread: Bool = false) -> ChatNativeReplySummaryLayout {
            let value = summary.map { NativeTimelineSnapshot.Metadata(value: .init(messageId: base.id, deleted: false,
                reactions: [], pin: nil, threadSummary: $0), intents: [], reactionsSupported: false, pinsSupported: false,
                summarySupported: true, accessible: true, canChange: true, loadError: nil, problem: nil) }
            let content = NativeTimelineSnapshot.MessageContent(message: base, author: "Anna", authorTooltip: "", addresses: [],
                replyToText: nil, replySummary: local, replyCount: 900, unreadReplyCount: unread, requestCount: requests,
                editing: nil, confirmation: nil, actions: ChatTimelineW01.content(base).actions, metadata: value,
                sources: [], membershipHints: [], attachments: .init(limits: nil, available: false, availableFileIDs: [], pauseReason: nil))
            return .init(message: .init(content: content, startsGroup: true, inThread: thread), snapshot: snapshot, body: body)
        }
        let localPlan = plan(nil)
        XCTAssertEqual(localPlan.kind, .local); XCTAssertEqual(localPlan.label, "3+ replies")
        XCTAssertEqual(localPlan.participants.map(\.name), ["Anna", "?", "?"])
        XCTAssertEqual(localPlan.participants.map(\.frame.width), [21, 21, 21])
        XCTAssertEqual(localPlan.participants.map(\.frame.minX), [68, 85, 102])
        XCTAssertEqual(localPlan.summaryFrame.minY, 57); XCTAssertEqual(localPlan.summaryFrame.height, 31)
        XCTAssertEqual(localPlan.help, "Loaded replies · more may exist")
        let serverPlan = plan(server, unread: 2, requests: 3)
        XCTAssertEqual(serverPlan.kind, .server); XCTAssertEqual(serverPlan.label, "7 replies")
        XCTAssertEqual(serverPlan.participants.map(\.name), ["Billing agent", "Review session", "Former member"])
        XCTAssertEqual(serverPlan.accessibilityLabel, "7 replies, 2 new, Billing agent, Review session, Former member, open thread")
        XCTAssertEqual(serverPlan.unread, "2 new"); XCTAssertEqual(serverPlan.request, "3 requests to agents")
        XCTAssertEqual(serverPlan.requestFrame.minY, serverPlan.summaryFrame.maxY + 3)
        var zero = server; zero.replyCount = 0
        XCTAssertEqual(plan(zero, unread: 2).kind, .local)
        XCTAssertNil(plan(zero).kind); XCTAssertEqual(plan(zero).bottom, body.maxY)
        XCTAssertEqual(plan(nil, requests: 1).request, "1 request to agents")
        XCTAssertNil(plan(server, unread: 2, requests: 3, thread: true).kind)
        XCTAssertEqual(plan(server, unread: 2, requests: 3, thread: true).frame, .zero)
        XCTAssertEqual(transports, 0); XCTAssertTrue(NativeAvatarProtocol.seen.isEmpty)
    }
}

@MainActor private final class NativeAvatarBlackView: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.black.setFill(); bounds.fill() }
}
