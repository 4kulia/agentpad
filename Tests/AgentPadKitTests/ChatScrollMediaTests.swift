import AppKit
import AgentPadQuietTestSupport
import GRDB
import Observation
import SwiftUI
import XCTest
@testable import AgentPadKit

private final class ChatScrollMediaPreviewProtocol: URLProtocol, @unchecked Sendable {
    struct Snapshot {
        var paths: [String] = []
        var completed = 0
        var cancelled = 0
    }
    private struct State {
        var path = ""
        var answer: Result<ChatStubProtocol.Answer, URLError> = .failure(URLError(.unsupportedURL))
        var released = false
        var pending: [ObjectIdentifier: ChatScrollMediaPreviewProtocol] = [:]
        var snapshot = Snapshot()
    }
    private static let lock = NSLock()
    private static let delivery = DispatchQueue(label: "chat-scroll-media-preview")
    nonisolated(unsafe) private static var state = State()
    private let completionLock = NSLock()
    private var stopped = false
    private var delivered = false
    static var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return state.snapshot }
    static func configure(path: String, answer: Result<ChatStubProtocol.Answer, URLError>) {
        lock.lock(); defer { lock.unlock() }
        state = State(path: path, answer: answer)
    }
    static func release() {
        lock.lock()
        state.released = true
        let pending = Array(state.pending.values), answer = state.answer
        state.pending = [:]
        lock.unlock()
        for item in pending { delivery.async { item.complete(answer) } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let path = request.url?.path ?? ""
        Self.state.snapshot.paths.append(path)
        guard path == Self.state.path else {
            Self.lock.unlock()
            Self.delivery.async { self.complete(.failure(URLError(.unsupportedURL))) }
            return
        }
        if Self.state.released {
            let answer = Self.state.answer
            Self.lock.unlock()
            Self.delivery.async { self.complete(answer) }
        } else {
            Self.state.pending[ObjectIdentifier(self)] = self
            Self.lock.unlock()
        }
    }
    override func stopLoading() {
        completionLock.lock()
        let cancelled = !delivered && !stopped
        stopped = true
        completionLock.unlock()
        Self.lock.lock()
        Self.state.pending[ObjectIdentifier(self)] = nil
        if cancelled { Self.state.snapshot.cancelled += 1 }
        Self.lock.unlock()
    }
    private func complete(_ answer: Result<ChatStubProtocol.Answer, URLError>) {
        completionLock.lock()
        guard !stopped && !delivered else { completionLock.unlock(); return }
        delivered = true
        completionLock.unlock()
        switch answer {
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        case .success(let value):
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: value.status,
                httpVersion: "HTTP/1.1", headerFields: value.headers) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: value.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        Self.lock.lock(); Self.state.snapshot.completed += 1; Self.lock.unlock()
    }
}

@MainActor
final class ChatScrollMediaTests: XCTestCase {
    private let channel = "f5000000-0000-4000-8000-000000000001"
    private let changedID = "scroll-media-3"
    private let anchorID = "scroll-media-4"
    private var directory: URL!
    private var scope: TeamServiceTestScope!
    private var fixtures: [ChatChannelExecutionTests.Fixture] = []
    private var mediaFixture: ChatChannelExecutionTests.Fixture!
    private var loadedValues: [ChatMessage] = []

    override func setUp() async throws {
        guard APQuietIsEnabled() else { throw NSError(domain: "Quiet harness required", code: 1) }
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-scroll-media-\(UUID())")
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
        mediaFixture = try await fixture(capabilities: ["chat.attachments", "chat.reactions"])
        if name.contains("testLoadedImagesPreciseScrollContinuityInChannelAndThread") {
            let limits = try XCTUnwrap(mediaFixture.service.serverAttachmentLimits[mediaFixture.key.server])
            let pixels = try png()
            let image = try benchmarkIdentity(ChatAttachmentStorage.descriptor(data: pixels, name: "scroll-image.png", limits: limits), messageID: "scroll-media-3")
            let note = try benchmarkIdentity(ChatAttachmentStorage.descriptor(data: Data("Fixture notes".utf8), name: "notes.txt", limits: limits), messageID: "scroll-media-6")
            loadedValues = try messages(mediaFixture, image: image, note: note, delayed: false)
            let manager = try XCTUnwrap(mediaFixture.service.attachments(mediaFixture.key))
            let path = "/v1/orgs/\(mediaFixture.key.orgId)/attachments/\(image.id)/preview"
            ChatScrollMediaPreviewProtocol.configure(path: path, answer: .success(.init(status: 200, body: pixels)))
            mediaFixture.service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatScrollMediaPreviewProtocol.self]) }
            ChatScrollMediaPreviewProtocol.release()
            for index in [3, 8] {
                let file = try XCTUnwrap(loadedValues[index].attachments.first)
                _ = try await manager.load(loadedValues[index], file: file, preview: true)
                XCTAssertNotNil(manager.image(loadedValues[index], file: file))
            }
        }
    }

    override func tearDown() async throws {
        ChatScrollMediaPreviewProtocol.release()
        for fixture in fixtures {
            fixture.service.attachmentManagers.values.forEach { $0.revoke() }
            fixture.sender?.hold()
            await fixture.service.disconnect()
        }
        fixtures = []
        ChatStubProtocol.reset()
        scope?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    @Observable final class Model: ChatConversationPresentation {
        let key: ChatOrgKey
        let service: ChatService
        let isDM = false
        var feed = ChatChannelModel.Feed()
        var b1: ChatB1Channel?
        var confirmation: ConfirmationCoordinator? { nil }
        var deletionRoot: String? { nil }
        var editing: ChatChannelModel.Editing?
        var threadRoot: String?
        var threadHasEarlier: Bool { false }
        var threadUnreadID: String? { nil }
        var positions: [String: ChatScrollPosition] = [:]
        var focusedMessageID: String? { nil }
        var revealMessageID: String?
        var focusRequest: ChatFocusRequest? { nil }
        var readingPositionRestored: Int { 0 }
        var searching: Bool { false }
        var hasNavigationReturn: Bool { false }
        var sourceStatuses: [ChatSourceStatus] { [] }
        var threadRequests: [ChatChannelRequests.Card] { [] }
        init(_ fixture: ChatChannelExecutionTests.Fixture, messages: [ChatMessage], b1: ChatB1Channel? = nil) {
            key = fixture.key; service = fixture.service; self.b1 = b1
            feed.messages = messages; feed.archived = false; feed.hasOlder = false
        }
        func notificationPlace(root: String?) -> String { "scroll-media-fixture" }
        func destination(root: String?) -> ConversationDestination { .channel(key, chat: feed.messages[0].channelId, thread: root) }
        func message(_ id: String) -> ChatMessage? { feed.messages.first { $0.id == id } }
        func conversationMessages(root: String?) -> [ChatMessage] { feed.messages }
        func openThread(_ id: String?) {}
        func loadOlder() {}
        func earlierReplies() {}
        func beginReading(root: String?) {}
        func endReading(root: String?) {}
        func readIfLooking(root: String?, appActive: Bool, shown: Bool, atBottom: Bool) {}
        func markConversationRead(root: String?, clearingBoundary: Bool) {}
        func finishNavigation() {}
        func dismissTransient() -> Bool { false }
        func canEdit(_ message: ChatMessage) -> Bool { false }
        func canDelete(_ message: ChatMessage) -> Bool { false }
        func canRetry(_ message: ChatMessage) -> Bool { false }
        func beginEditing(_ message: ChatMessage, root: String?, recovering: Bool) -> Bool { false }
        func cancelEditing(messageID: String?, all: Bool) { editing = nil }
        func saveEditing(members: [(account: String, handle: String)]) -> Bool { false }
        func requestDelete(_ message: ChatMessage, root: String?) -> Bool { false }
        func retry(_ message: ChatMessage) {}
        func discard(_ message: ChatMessage) {}
        func discardEdit(_ message: ChatMessage) {}
    }

    private typealias Probe = ChatScrollProbe
    @MainActor private final class Mounted {
        let model: Model
        let probe = Probe()
        let host: NSHostingView<AnyView>
        let window: NSWindow
        init(_ model: Model) {
            self.model = model
            let probe = probe
            host = NSHostingView(rootView: AnyView(ChatScrollNativeAdapter().timeline(model: model, root: nil, probe: probe)
                .frame(width: 520, height: 400)))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            APQuietSelectWindow(window)
        }
        var viewport: ChatTimelineScrollController? {
            guard let coordinator = descendants(host, NativeChatTimelineContainer.self).first?.coordinator else { return nil }
            probe.frameProvider = { [weak coordinator] in coordinator?.scrollController.bodyFrames ?? [:] }
            return coordinator.scrollController
        }
        var nativeTextY: [CGFloat] {
            descendants(host, NSTextView.self).filter { $0.string.hasPrefix("Attachment reference") }
                .map { $0.convert(.zero, to: host).y }.sorted()
        }
        func close() {
            host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
            window.contentView = nil; window.close()
        }
        private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
        }
    }

    private func fixture(capabilities: Set<String>) async throws -> ChatChannelExecutionTests.Fixture {
        let fixture = try await ChatChannelExecutionTests.Fixture(root: directory.appendingPathComponent(UUID().uuidString))
        fixtures.append(fixture)
        fixture.service.serverCapabilities[fixture.key.server] = capabilities
        fixture.service.isServerKnown = { _, _ in true }
        if capabilities.contains("chat.attachments") {
            fixture.service.serverAttachmentLimits[fixture.key.server] = try JSONDecoder().decode(
                ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        }
        return fixture
    }

    private func messages(_ fixture: ChatChannelExecutionTests.Fixture, image: ChatAttachment,
                          note: ChatAttachment, delayed: Bool) throws -> [ChatMessage] {
        var values = (0..<320).map { index in
            let text: String
            switch index % 6 {
            case 0: text = "One line \(index)."
            case 1: text = String(repeating: "A **long paragraph** with [a link](https://example.com), _emphasis_ and enough words to wrap. ", count: 16)
            case 2: text = "```swift\n" + (0..<18).map { "let value\($0) = \($0) // fixture code" }.joined(separator: "\n") + "\n```"
            case 3: text = "> Quoted context\n\n- first item\n- second item\n\n# Heading\n\nFollow-up \(index)"
            case 4: text = "[Attachment reference](https://example.com/file)\n\n" + String(repeating: "Short wrap. ", count: 18)
            default: text = "Message \(index) with `inline code`."
            }
            return ChatMessage(row: Row(["message_id": "scroll-media-\(index)", "channel_id": channel,
                "author_account_id": (index / 3).isMultiple(of: 2) ? fixture.key.accountId : CallJSON.boris,
                "seq": index + 1, "created_at": String(format: "2026-10-%02dT12:00:00Z", 18 + index / 80),
                "has_fixed": true, "has_mutable": true, "text": text, "mentions": "[]", "revision": 1]))
        }
        var targetImage = image; targetImage.hasPreview = delayed
        var staticImage = image; staticImage.hasPreview = false
        values[3] = try attachment(fixture, files: [targetImage], index: 3, text: "Delayed image preview")
        values[6] = try attachment(fixture, files: [note], index: 6, text: "Fixture notes are attached.")
        values[8] = try attachment(fixture, files: [staticImage], index: 8, text: "A second image reserves its descriptor dimensions.")
        XCTAssertEqual(values.count, 320)
        return values
    }

    private func wait(_ mounted: Mounted, stage: String, _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            mounted.host.layoutSubtreeIfNeeded()
            if try condition() { return }
            guard ContinuousClock.now < deadline else {
                let traffic = ChatScrollMediaPreviewProtocol.snapshot
                print("CHAT_MEDIA timeout stage=\(stage) changed=\(String(describing: mounted.probe.frames[changedID])) anchor=\(String(describing: mounted.probe.frames[anchorID])) requests=\(traffic.paths) complete=\(traffic.completed) cancel=\(traffic.cancelled)")
                throw NSError(domain: "ChatScrollMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out at \(stage)"])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func settle(_ mounted: Mounted) async throws {
        for _ in 0..<6 {
            mounted.host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func position(_ mounted: Mounted, anchorY: CGFloat) async throws {
        try await wait(mounted, stage: "attach viewport") { mounted.viewport?.scroll?.documentView != nil }
        let viewport = try XCTUnwrap(mounted.viewport), scroll = try XCTUnwrap(viewport.scroll)
        mounted.probe.scroll = scroll
        let document = try XCTUnwrap(scroll.documentView)
        scroll.verticalScrollElasticity = .none
        try await wait(mounted, stage: "native media plan") { viewport.bodyFrame(self.changedID) != nil }
        XCTAssertTrue(viewport.scrollTo(messageID: changedID, alignment: .center))
        try await wait(mounted, stage: "reveal media row") {
            guard let changed = mounted.probe.frames[self.changedID], let anchor = mounted.probe.frames[self.anchorID] else { return false }
            return changed.maxY > 0 && changed.minY < 400 && anchor.minY < 400
        }
        let input = viewport.inputGeneration
        viewport.userWillScroll()
        XCTAssertGreaterThan(viewport.inputGeneration, input)
        for _ in 0..<3 {
            let frame = try XCTUnwrap(mounted.probe.frames[anchorID])
            let delta = (frame.minY - anchorY) * (document.isFlipped ? 1 : -1)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + delta))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(mounted)
        }
        XCTAssertEqual(viewport.position.anchor, anchorID, "Native input must retain the reading row after positioning")
        XCTAssertEqual(try XCTUnwrap(mounted.probe.frames[anchorID]).minY, anchorY, accuracy: 1)
        XCTAssertFalse(viewport.following)
        XCTAssertFalse(viewport.atBottom)
        let changed = try XCTUnwrap(mounted.probe.frames[changedID])
        XCTAssertLessThan(changed.minY, 0, "Keep the changing row partly above the viewport")
        XCTAssertGreaterThan(changed.maxY, 0, "Keep the changing row mounted while its content changes")
    }

    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 160,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 320 * 4, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for offset in stride(from: 0, to: 320 * 160 * 4, by: 4) {
            pixels[offset] = 50; pixels[offset + 1] = 100; pixels[offset + 2] = 220; pixels[offset + 3] = 255
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func attachment(_ fixture: ChatChannelExecutionTests.Fixture, files: [ChatAttachment], index: Int, text: String) throws -> ChatMessage {
        let id = "scroll-media-\(index)"
        let fields: [String: Any] = ["message_id": id, "channel_id": channel, "author_account_id": CallJSON.boris,
            "text": text, "revision": 1, "seq": index + 1, "created_at": "2026-10-18T12:00:00Z",
            "attachments": try files.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: fields))
        try fixture.store.queue.write { _ = try ChatMessages.write($0, wire) }
        return try fixture.store.queue.read { db in
            ChatMessage(row: try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM messages WHERE message_id = ?", arguments: [id])))
        }
    }

    func testDelayedPreviewSuccessKeepsReservedRowHeightAndReadingAnchor() async throws {
        try await preview(succeeds: true)
    }

    func testDelayedPreviewFailureAddsErrorHeightAndKeepsReadingAnchor() async throws {
        try await preview(succeeds: false)
    }

    private func preview(succeeds: Bool) async throws {
        let fixture = try XCTUnwrap(mediaFixture)
        let limits = try XCTUnwrap(fixture.service.serverAttachmentLimits[fixture.key.server])
        let data = try png()
        var file = try ChatAttachmentStorage.descriptor(data: data, name: "delayed-preview.png", limits: limits)
        file.hasPreview = true
        let note = try ChatAttachmentStorage.descriptor(data: Data("Fixture attachment notes.\n".utf8), name: "fixture-notes.txt", limits: limits)
        let values = try messages(fixture, image: file, note: note, delayed: true)
        let message = values[3]
        let manager = try XCTUnwrap(fixture.service.attachments(fixture.key))
        XCTAssertNotNil(manager.stamp(owner: message.attachmentOwner, message: message, file: file))
        let path = "/v1/orgs/\(fixture.key.orgId)/attachments/\(file.id)/preview"
        ChatScrollMediaPreviewProtocol.configure(path: path, answer: succeeds
            ? .success(.init(status: 200, body: data)) : .failure(URLError(.networkConnectionLost)))
        fixture.service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatScrollMediaPreviewProtocol.self]) }
        defer { ChatScrollMediaPreviewProtocol.release() }
        try applyReactions([], to: values, fixture: fixture, head: 1)
        let b1 = ChatB1Channel(key: fixture.key, channel: channel, store: fixture.store, service: fixture.service)
        let mounted = Mounted(Model(fixture, messages: values, b1: b1))
        defer { mounted.close() }
        print("CHAT_MEDIA begin kind=preview-\(succeeds ? "success" : "failure") rows=\(values.count) imageCards=2 fileCards=1 expectedPath=\(path)")
        try await position(mounted, anchorY: 220)
        try await wait(mounted, stage: "preview request") { ChatScrollMediaPreviewProtocol.snapshot.paths.contains(path) }
        XCTAssertNil(manager.image(message, file: file), "The pending measurement must precede preview completion")
        let before = try XCTUnwrap(mounted.probe.frames[changedID])
        let anchorBefore = try XCTUnwrap(mounted.probe.frames[anchorID])
        let nativeBefore = try XCTUnwrap(mounted.nativeTextY.first)
        print("CHAT_MEDIA pending height=\(before.height) anchorY=\(anchorBefore.minY) changedY=\(before.minY)")
        ChatScrollMediaPreviewProtocol.release()
        if succeeds {
            try await wait(mounted, stage: "preview pixels decoded") { manager.image(message, file: file) != nil }
        } else {
            try await wait(mounted, stage: "preview error row") { (mounted.probe.frames[self.changedID]?.height ?? 0) > before.height + 10 }
            XCTAssertNil(manager.image(message, file: file))
        }
        try await settle(mounted)
        let after = try XCTUnwrap(mounted.probe.frames[changedID])
        let anchorAfter = try XCTUnwrap(mounted.probe.frames[anchorID])
        let traffic = ChatScrollMediaPreviewProtocol.snapshot
        print("CHAT_MEDIA result kind=preview-\(succeeds ? "success" : "failure") rowGrowth=\(after.height - before.height) anchorJump=\(anchorAfter.minY - anchorBefore.minY) requests=\(traffic.paths.count) complete=\(traffic.completed) cancel=\(traffic.cancelled) imageLoaded=\(manager.image(message, file: file) != nil)")
        if succeeds { XCTAssertEqual(after.height, before.height, accuracy: 0.75) }
        else { XCTAssertGreaterThan(after.height, before.height + 10) }
        XCTAssertEqual(anchorAfter.minY, anchorBefore.minY, accuracy: 0.75, "Async preview state must preserve the reading position")
        XCTAssertEqual(try XCTUnwrap(mounted.nativeTextY.first), nativeBefore, accuracy: 0.75)
        XCTAssertEqual(traffic.paths, [path], "The production card must actually request the expected preview once")
        XCTAssertEqual(traffic.completed, 1)
        XCTAssertEqual(traffic.cancelled, 0)
        XCTAssertNil(APQuietFailure()); XCTAssertFalse(APQuietWindowHasOSFocus(mounted.window))
    }

    func testReactionGrowthAboveViewportKeepsReadingAnchor() async throws {
        let fixture = try XCTUnwrap(mediaFixture)
        let limits = try XCTUnwrap(fixture.service.serverAttachmentLimits[fixture.key.server])
        let image = try ChatAttachmentStorage.descriptor(data: png(), name: "reaction-fixture.png", limits: limits)
        let note = try ChatAttachmentStorage.descriptor(data: Data("Fixture notes.\n".utf8), name: "reaction-notes.txt", limits: limits)
        let values = try messages(fixture, image: image, note: note, delayed: false)
        try applyReactions([], to: values, fixture: fixture, head: 1)
        let b1 = ChatB1Channel(key: fixture.key, channel: channel, store: fixture.store, service: fixture.service)
        XCTAssertEqual(b1.state.metadata[changedID]?.reactions, [])
        let mounted = Mounted(Model(fixture, messages: values, b1: b1))
        defer { mounted.close() }
        print("CHAT_MEDIA begin kind=reactions rows=\(values.count) imageCards=2 fileCards=1")
        try await position(mounted, anchorY: 220)
        let before = try XCTUnwrap(mounted.probe.frames[changedID])
        let anchorBefore = try XCTUnwrap(mounted.probe.frames[anchorID])
        XCTAssertLessThan(before.minY, 0, "The changing row must begin above the viewport")
        let nativeBefore = try XCTUnwrap(mounted.nativeTextY.first)
        XCTAssertGreaterThan(before.maxY, 0, "The changing row must remain partly visible")
        let reactions = ["👍", "❤️", "😂", "🎉", "✨", "👀", "🚀", "🔥", "✅", "🙏", "💡", "💯"].map {
            ChatB1.Reaction(emoji: $0, count: 3, mine: false)
        }
        try applyReactions(reactions, to: values, fixture: fixture, head: 2)
        try await wait(mounted, stage: "reaction strip growth") {
            b1.state.metadata[self.changedID]?.reactions == reactions &&
                (mounted.probe.frames[self.changedID]?.height ?? 0) > before.height + 20
        }
        try await settle(mounted)
        XCTAssertEqual(try XCTUnwrap(mounted.nativeTextY.first), nativeBefore, accuracy: 0.75)
        print("CHAT_MEDIA result kind=reactions reactionCount=\(reactions.count) rowGrowth=\((mounted.probe.frames[changedID]?.height ?? 0) - before.height) anchorJump=\((mounted.probe.frames[anchorID]?.minY ?? 0) - anchorBefore.minY) anchorBefore=\(anchorBefore.minY) anchorAfter=\(mounted.probe.frames[anchorID]?.minY ?? 0)")
        XCTAssertEqual(b1.state.metadata[changedID]?.reactions, reactions)
        XCTAssertGreaterThan(try XCTUnwrap(mounted.probe.frames[changedID]).height, before.height + 20)
        XCTAssertEqual(try XCTUnwrap(mounted.probe.frames[anchorID]).minY, anchorBefore.minY, accuracy: 0.75,
                       "Growing reactions above the viewport must preserve the reading position")
        XCTAssertFalse(try XCTUnwrap(mounted.viewport).following)
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty, "Metadata is seeded locally; scrolling must not request a server")
        XCTAssertNil(APQuietFailure()); XCTAssertFalse(APQuietWindowHasOSFocus(mounted.window))
    }

    private func applyReactions(_ reactions: [ChatB1.Reaction], to messages: [ChatMessage],
                                fixture: ChatChannelExecutionTests.Fixture, head: Int) throws {
        try fixture.store.queue.write { db in
            try ChatB1.watch(db, channel: channel, ids: messages.map(\.id))
            let token = try XCTUnwrap(ChatB1.readToken(db, channel: channel))
            let metadata = messages.map { message in
                ChatB1.Metadata(messageId: message.id, deleted: false,
                                reactions: message.id == changedID ? reactions : ((message.seq ?? 0).isMultiple(of: 17) ? [.init(emoji: "👍", count: 2, mine: false)] : []),
                                pin: nil, threadSummary: nil)
            }
            XCTAssertTrue(try ChatB1.apply(db, page: .init(asOfSeq: head, items: metadata), channel: channel, token: token,
                                          tickets: Dictionary(uniqueKeysWithValues: messages.map { ($0.id, 0) })))
        }
    }

    func testDenseReactionsPreciseScrollContinuityInChannelAndThread() throws {
        try mediaPreciseScrollContinuity(adapter: ChatScrollMounts.benchmark ?? ChatScrollNativeAdapter(),
            prefix: "dense-", reactionValues: ["👍", "❤️", "😂", "🎉", "✨", "👀", "🚀", "🔥", "✅", "🙏", "💡", "💯"])
    }

    func testLoadedImagesPreciseScrollContinuityInChannelAndThread() throws {
        XCTAssertEqual(loadedValues.count, 320)
        let before = ChatScrollMediaPreviewProtocol.snapshot.paths.count
        try mediaPreciseScrollContinuity(adapter: ChatScrollMounts.benchmark ?? ChatScrollNativeAdapter(),
            prefix: "loaded-", prepared: loadedValues)
        XCTAssertEqual(ChatScrollMediaPreviewProtocol.snapshot.paths.count, before,
            "Decoded fixtures must not fetch while scrolling")
    }

    func testNativeMediaPreciseScrollContinuityInChannelAndThread() throws {
        try mediaPreciseScrollContinuity(adapter: ChatScrollNativeAdapter()) { mounted in
            let tables = ChatScrollMounted<Model>.descendants(mounted.host, ChatNativeTableView.self)
            XCTAssertEqual(tables.count, 1, "The media workload must mount the actual native timeline")
            let table = try XCTUnwrap(tables.first)
            let coordinator = try XCTUnwrap(table.dataSource as? NativeChatTimelineCoordinator)
            XCTAssertTrue(mounted.scroll.documentView === table)
            XCTAssertTrue(mounted.viewport === coordinator.scrollController)
            XCTAssertEqual(coordinator.snapshot?.messageIDs, mounted.model.feed.messages.map(\.id))
            XCTAssertFalse(ChatScrollMounted<Model>.descendants(table, ChatNativeShellCell.self).isEmpty)
            func subtree(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(subtree) }
            XCTAssertFalse(subtree(table).contains { String(reflecting: type(of: $0)).contains("NSHosting") },
                "Native media rows must not contain hosted SwiftUI content")
        }
    }

    private func benchmarkIdentity(_ descriptor: ChatAttachment, messageID: String) throws -> ChatAttachment {
        guard ProcessInfo.processInfo.environment["AGENTPAD_CHAT_BENCH_RENDERER"] != nil else { return descriptor }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["AGENTPAD_CHAT_BENCH_MEDIA_FIXTURE"])
        let messages = try JSONDecoder().decode([ChatMessage].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let original = try XCTUnwrap(messages.first { $0.id == messageID }?.attachments.first)
        var value = descriptor
        // Descriptor creation uses UUIDs. Replay the frozen identity without
        // changing the generated bytes, dimensions or any displayed property.
        value.attachmentId = original.id
        XCTAssertEqual(value, original, "Every descriptor field except its generated UUID must already match W00")
        return value
    }

    private func mediaPreciseScrollContinuity(adapter: any ChatScrollMountAdapter,
        prefix: String = "", reactionValues: [String] = ["👍"], prepared: [ChatMessage]? = nil,
        verifyMount: (ChatScrollMounted<Model>) throws -> Void = { _ in }) throws {
        let fixture = try XCTUnwrap(mediaFixture)
        let limits = try XCTUnwrap(fixture.service.serverAttachmentLimits[fixture.key.server])
        let image = try benchmarkIdentity(ChatAttachmentStorage.descriptor(data: png(), name: "scroll-image.png", limits: limits), messageID: "scroll-media-3")
        let note = try benchmarkIdentity(ChatAttachmentStorage.descriptor(data: Data("Fixture notes".utf8), name: "notes.txt", limits: limits), messageID: "scroll-media-6")
        let values = try prepared ?? messages(fixture, image: image, note: note, delayed: false)
        try applyReactions(reactionValues.map { .init(emoji: $0, count: 3, mine: false) }, to: values, fixture: fixture, head: 1)
        let b1 = ChatB1Channel(key: fixture.key, channel: channel, store: fixture.store, service: fixture.service)
        for root: String? in [nil, "fixture-root"] {
            let model = Model(fixture, messages: values, b1: b1)
            model.threadRoot = root
            model.feed.messages = values.map { value in var value = value; value.threadRootId = root; return value }
            model.feed.unreadID = "scroll-media-7"
            model.revealMessageID = "scroll-media-9"
            let mounted = try ChatScrollContinuityTests.Mounted(model: model, root: root, adapter: adapter)
            defer { mounted.close() }
            model.revealMessageID = nil; mounted.settle()
            try mounted.recordFixture(.media, root: root, prefix: prefix)
            try mounted.drive(.media)
            try mounted.recordDiagnostics(prefix + ChatScrollWorkload.media.caseName(root: root) + "-counters")
            try verifyMount(mounted)
            let samples = mounted.probe.samples
            try ChatScrollRecords.write(samples, workload: .media, root: root, renderer: adapter.name, prefix: prefix)
            try ChatScrollRecords.validate(samples, workload: .media)
            for kind in ["up", "down"] {
                let selected = samples.filter { $0["kind"] as? String == kind }
                let errors = selected.compactMap { $0["error"] as? Double }.map(abs)
                let costs = selected.compactMap { $0["milliseconds"] as? Double }.sorted()
                XCTAssertEqual(errors.count, selected.count)
                print("CHAT_MEDIA_SCROLL renderer=\(adapter.name) \(root ?? "channel") \(kind) events=\(selected.count) jumps=\(errors.filter { $0 > 0.75 }.count) maxJump=\(errors.max() ?? 0) p95ms=\(ChatScrollRecords.percentile95(costs)) maxms=\(costs.last ?? 0)")
                XCTAssertLessThanOrEqual(errors.max() ?? .infinity, 0.75)
            }
            let seen = Set(samples.flatMap { ($0["heights"] as? [String: CGFloat])?.keys.map { $0 } ?? [] })
            XCTAssertTrue(seen.contains("scroll-media-6"), "The gesture must cross a real file card")
            XCTAssertTrue(seen.contains("scroll-media-8"), "The gesture must cross a real image card")
            XCTAssertNil(APQuietFailure()); XCTAssertFalse(APQuietWindowHasOSFocus(mounted.window))
        }
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
    }
}
