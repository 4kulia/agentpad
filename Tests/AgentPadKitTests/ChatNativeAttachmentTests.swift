import AppKit
import AgentPadQuietTestSupport
import GRDB
import XCTest
@testable import AgentPadKit

/// The transport holds real manager requests until the test releases that path.
/// Cancellation follows URLSession's normal stopLoading path, so hidden/reused
/// cells must relinquish their actual transfer rather than a synthetic task.
private final class NativeAttachmentProtocol: URLProtocol, @unchecked Sendable {
    struct Traffic: Equatable {
        var paths: [String] = []
        var completed: [String] = []
        var cancelled: [String] = []
    }
    private struct State {
        var answers: [String: Result<ChatStubProtocol.Answer, URLError>] = [:]
        var released: Set<String> = []
        var pending: [ObjectIdentifier: NativeAttachmentProtocol] = [:]
        var traffic = Traffic()
    }
    private static let lock = NSLock()
    private static let delivery = DispatchQueue(label: "chat-native-attachment-fixture")
    nonisolated(unsafe) private static var state = State()
    private let completionLock = NSLock()
    private var stopped = false
    private var delivered = false

    static var traffic: Traffic { lock.lock(); defer { lock.unlock() }; return state.traffic }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        precondition(state.pending.isEmpty, "A previous native attachment request was not released")
        state = State()
    }
    static func hold(_ path: String, answer: Result<ChatStubProtocol.Answer, URLError>) {
        lock.lock(); defer { lock.unlock() }
        state.answers[path] = answer; state.released.remove(path)
    }
    static func release(_ path: String) {
        lock.lock()
        state.released.insert(path)
        let pending = state.pending.values.filter { $0.request.url?.path == path }
        let answer = state.answers[path] ?? .failure(URLError(.unsupportedURL))
        for item in pending { state.pending[ObjectIdentifier(item)] = nil }
        lock.unlock()
        for item in pending { delivery.async { item.complete(answer) } }
    }
    /// Deliver the URLProtocol response while the main actor is still occupied.
    /// Its suspended native-card task can resume only after the caller returns
    /// to the executor, allowing a deterministic binding change before callback.
    static func releaseBeforeReturning(_ path: String) {
        release(path)
        delivery.sync {}
    }
    static func releaseAll() {
        lock.lock(); let paths = Array(state.answers.keys); lock.unlock()
        paths.forEach(release)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.state.traffic.paths.append(path)
        guard let answer = Self.state.answers[path] else {
            Self.lock.unlock()
            Self.delivery.async { self.complete(.failure(URLError(.unsupportedURL))) }
            return
        }
        if Self.state.released.contains(path) {
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
        if cancelled { Self.state.traffic.cancelled.append(request.url?.path ?? "") }
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
        Self.lock.lock(); Self.state.traffic.completed.append(request.url?.path ?? ""); Self.lock.unlock()
    }
}

@MainActor final class ChatNativeAttachmentTests: XCTestCase {
    private var directory: URL!
    private var scope: TeamServiceTestScope!
    private var fixtures: [NativeAttachmentFixture] = []
    private var cells: [ChatNativeShellCell] = []
    private var hosts: [ChatQuietHost] = []

    override func setUp() async throws {
        guard APQuietIsEnabled() else { throw NSError(domain: "Quiet harness required", code: 1) }
        _ = NSApplication.shared
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce()
        ChatNotifications.badgeChanged = {}
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-attachments-\(UUID())")
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
        NativeAttachmentProtocol.reset()
    }

    override func tearDown() async throws {
        cells.forEach { $0.unbind() }; cells.removeAll()
        hosts.forEach { $0.close() }; hosts.removeAll()
        for fixture in fixtures.reversed() {
            fixture.adapter.invalidate()
            fixture.manager.revoke()
            fixture.base.sender?.hold()
            await fixture.base.service.disconnect()
        }
        NativeAttachmentProtocol.releaseAll()
        fixtures.removeAll()
        ChatStubProtocol.reset(); scope?.close()
        try? FileManager.default.removeItem(at: directory)
        XCTAssertNil(APQuietFailure())
    }

    private func fixture() async throws -> NativeAttachmentFixture {
        let value = try await NativeAttachmentFixture(directory: directory.appendingPathComponent(UUID().uuidString))
        fixtures.append(value)
        return value
    }

    private func wait(_ stage: String, diagnostic: (() -> String)? = nil, _ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while try !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out at \(stage); traffic=\(NativeAttachmentProtocol.traffic); \(diagnostic?() ?? "")")
                throw NSError(domain: "NativeAttachmentFixture", code: 1)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func cell(_ fixture: NativeAttachmentFixture, message: ChatMessage, width: CGFloat = 760) throws -> ChatNativeShellCell {
        let value = ChatNativeShellCell(kind: .message)
        cells.append(value)
        try fixture.configure(value, messageID: message.id, width: width)
        return value
    }

    private func host(_ cell: ChatNativeShellCell) throws -> ChatQuietHost {
        let value = ChatQuietHost(view: cell, dark: false, width: try XCTUnwrap(cell.plan).width.points,
                                  height: max(300, try XCTUnwrap(cell.plan).height))
        hosts.append(value)
        cell.layoutSubtreeIfNeeded()
        return value
    }

    private func image(_ fixture: NativeAttachmentFixture, name: String = "preview.png", preview: Bool = true,
                       width: Int = 320, height: Int = 160) throws -> (ChatAttachment, Data) {
        let data = try png(width: width, height: height)
        var file = try ChatAttachmentStorage.descriptor(data: data, name: name, limits: fixture.limits)
        file.hasPreview = preview
        return (file, data)
    }

    private func png(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            pixels[offset] = 30; pixels[offset + 1] = 100; pixels[offset + 2] = 220; pixels[offset + 3] = 255
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testNativeAttachmentTypePartitionAndGenericGeometryUseDeclaredMetadata() async throws {
        let f = try await fixture()
        var (wide, _) = try image(f, name: "wide.png")
        wide.width = 10_000; wide.height = 1
        var (tall, _) = try image(f, name: "tall.png")
        tall.mime = "image/jpeg"; tall.width = 1; tall.height = 10_000
        let documents = ["application/pdf", "text/plain", "application/json", "image/gif", "video/mp4", "audio/ogg"].enumerated().map {
            ChatAttachment(attachmentId: UUID().uuidString.lowercased(), position: $0.offset,
                name: "A deliberately long document name \(String(repeating: "filename ", count: 8)).bin",
                mime: $0.element, size: 9_216, hasPreview: true)
        }
        let message = try await f.stored([documents[0], wide, documents[1], tall] + Array(documents.dropFirst(2)))
        let snapshot = f.snapshot(), row = try XCTUnwrap(f.snapshot().rows.first { $0.messageID == message.id })
        guard case .message(let content) = row.payload else { return XCTFail("Missing attachment row") }
        let body = CGRect(x: 68, y: 40, width: 668, height: 24)
        let plan = ChatNativeAttachmentLayout(message: content, style: snapshot.style, body: body)
        XCTAssertEqual(plan.cards.map(\.file.id), [wide.id, tall.id] + documents.map(\.id))
        XCTAssertEqual(plan.cards.prefix(2).map(\.image), [CGRect(x: 0, y: 0, width: 172, height: 44), CGRect(x: 0, y: 0, width: 172, height: 180)])
        XCTAssertEqual(plan.cards.prefix(2).map(\.frame.origin), [CGPoint(x: 68, y: 72), CGPoint(x: 252, y: 72)])
        for card in plan.cards.prefix(2) {
            XCTAssertEqual(card.name.minY, card.image.maxY + 4)
            XCTAssertTrue(card.document.isEmpty); XCTAssertTrue(card.save.isEmpty)
        }
        for card in plan.cards.dropFirst(2) {
            XCTAssertTrue(card.image.isEmpty)
            XCTAssertEqual(card.background.width, 360)
            XCTAssertEqual(card.document.minX, 10)
            XCTAssertEqual(card.name.minX, card.document.maxX + 10)
            XCTAssertEqual(card.detail.minY, card.name.maxY + 3)
            XCTAssertEqual(card.save, CGRect(x: 322, y: (card.background.height - 28) / 2, width: 28, height: 28))
            XCTAssertGreaterThanOrEqual(card.save.minX - card.name.maxX, 4)
        }
        XCTAssertEqual(plan.cards[2].frame.minY, plan.cards[1].frame.maxY + 8)
        XCTAssertEqual(plan.bottom, try XCTUnwrap(plan.cards.last).frame.maxY)
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init(), "Pure geometry must not fetch hasPreview files")
    }

    func testNativeAttachmentGridThresholdsUnknownDimensionsAndSingleImageCaps() async throws {
        let f = try await fixture()
        var (first, _) = try image(f)
        first.width = nil; first.height = nil
        var (second, _) = try image(f, name: "second.png")
        second.width = 0; second.height = 0
        let message = try await f.stored([first, second])
        let snapshot = f.snapshot(), row = try XCTUnwrap(snapshot.rows.first { $0.messageID == message.id })
        guard case .message(let content) = row.payload else { return XCTFail("Missing attachment row") }
        for inThread in [false, true] {
            let value = NativeTimelineSnapshot.Message(content: content.content, startsGroup: true, inThread: inThread)
            let threshold: CGFloat = inThread ? 228 : 308
            let maximum: CGFloat = inThread ? 130 : 180
            let two = ChatNativeAttachmentLayout(message: value, style: snapshot.style,
                body: CGRect(x: 62, y: 30, width: threshold, height: 20))
            let one = ChatNativeAttachmentLayout(message: value, style: snapshot.style,
                body: CGRect(x: 62, y: 30, width: threshold - 1, height: 20))
            XCTAssertEqual(two.cards.map(\.image.height), [maximum, maximum])
            XCTAssertEqual(two.cards[0].frame.minY, two.cards[1].frame.minY)
            XCTAssertEqual(two.cards[1].frame.minX - two.cards[0].frame.maxX, 8)
            XCTAssertEqual(one.cards[1].frame.minY - one.cards[0].frame.maxY, 8)
            XCTAssertEqual(one.cards[0].frame.minX, one.cards[1].frame.minX)
        }
        let single = try await f.stored([first])
        let singleSnapshot = f.snapshot(), singleRow = try XCTUnwrap(singleSnapshot.rows.first { $0.messageID == single.id })
        guard case .message(let singleContent) = singleRow.payload else { return XCTFail("Missing single attachment row") }
        for inThread in [false, true] {
            let value = NativeTimelineSnapshot.Message(content: singleContent.content, startsGroup: true, inThread: inThread)
            let layout = ChatNativeAttachmentLayout(message: value, style: snapshot.style,
                body: CGRect(x: 68, y: 20, width: 600, height: 24))
            XCTAssertEqual(layout.cards.map(\.image), [CGRect(x: 0, y: 0, width: inThread ? 280 : 360, height: inThread ? 180 : 240)])
        }
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init())
    }

    func testNativeGenericMIMEWrapsAndCardHeightIsNotFixedAt52() async throws {
        let f = try await fixture()
        let file = ChatAttachment(attachmentId: UUID().uuidString.lowercased(), position: 0,
            name: String(repeating: "Long attachment filename ", count: 12) + ".docx",
            mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", size: 12_345, hasPreview: false)
        let message = try await f.stored([file]), snapshot = f.snapshot()
        let row = try XCTUnwrap(snapshot.rows.first { $0.messageID == message.id })
        guard case .message(let content) = row.payload else { return XCTFail("Missing generic file") }
        let wide = ChatNativeAttachmentLayout(message: content, style: snapshot.style,
            body: CGRect(x: 68, y: 20, width: 360, height: 24))
        let narrow = ChatNativeAttachmentLayout(message: content, style: snapshot.style,
            body: CGRect(x: 68, y: 20, width: 180, height: 24))
        let wideCard = try XCTUnwrap(wide.cards.first), narrowCard = try XCTUnwrap(narrow.cards.first)
        XCTAssertEqual(narrowCard.name.height, wideCard.name.height, "A long name stays on one line")
        XCTAssertGreaterThan(narrowCard.detail.height, wideCard.detail.height, "MIME and size wrap into the available width")
        XCTAssertGreaterThan(narrowCard.background.height, 52)
        XCTAssertEqual(narrowCard.background.height, max(narrowCard.document.height, narrowCard.name.height + 3 + narrowCard.detail.height, 28) + 20)
        let shell = try cell(f, message: message, width: 272), card = try XCTUnwrap(shell.attachments.cards.first)
        XCTAssertEqual(card.name.text.string, file.name)
        XCTAssertEqual(card.detail.text.string, "\(file.mime) · \(file.sizeText)")
        XCTAssertEqual((card.name.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(card.accessibilityLabel(), "\(file.mime), \(file.name), \(file.sizeText)")
        XCTAssertEqual(card.download.toolTip, "Save…")
        XCTAssertTrue(card.imageButton.isHidden)
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init())
    }

    func testNativeAttachmentMeasurementIsPureAndDelayedDecodePreservesInstalledPlan() async throws {
        let f = try await fixture(), (file, data) = try image(f)
        let message = try await f.stored([file])
        let path = f.path(file)
        NativeAttachmentProtocol.hold(path, answer: .success(.init(status: 200, body: data)))
        let snapshot = f.snapshot(), row = try XCTUnwrap(snapshot.rows.first { $0.messageID == message.id })
        for width: CGFloat in [280, 420, 760, 980, 760] {
            _ = f.layout.plan(row, snapshot: snapshot, width: .init(width, scale: 2))
            _ = f.layout.content(row, snapshot: snapshot, width: .init(width, scale: 2))
        }
        let shell = try cell(f, message: message), installed = try XCTUnwrap(shell.plan)
        let card = try XCTUnwrap(shell.attachments.cards.first)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init())
        XCTAssertNil(card.currentTask); XCTAssertNil(card.imageButton.preview); XCTAssertFalse(card.visible)
        shell.setMediaVisible(true)
        try await wait("visible preview request") { NativeAttachmentProtocol.traffic.paths == [path] }
        XCTAssertFalse(card.spinner.isHidden)
        XCTAssertEqual(shell.plan, installed)
        NativeAttachmentProtocol.release(path)
        try await wait("decoded native pixels") { card.imageButton.preview != nil && card.currentTask == nil }
        XCTAssertEqual(card.imageButton.preview?.width, 320)
        XCTAssertEqual(card.imageButton.preview?.height, 160)
        XCTAssertTrue(card.spinner.isHidden)
        XCTAssertEqual(shell.plan, installed, "Decoded pixels cannot mutate any installed frame")
        try f.configure(shell, messageID: message.id)
        XCTAssertEqual(shell.plan, installed, "The preview is paint-only in a fresh snapshot too")
        shell.setMediaVisible(false)
        XCTAssertNil(card.imageButton.preview)
        shell.setMediaVisible(true)
        XCTAssertNotNil(card.imageButton.preview, "Reappearance obtains the manager's authorized decoded cache")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init(paths: [path], completed: [path], cancelled: []))
    }

    func testNativeAttachmentHiddenAndUnboundCellsCancelWithoutPublishingErrors() async throws {
        let f = try await fixture(), (file, data) = try image(f)
        let message = try await f.stored([file]), path = f.path(file)
        NativeAttachmentProtocol.hold(path, answer: .success(.init(status: 200, body: data)))
        let shell = try cell(f, message: message), card = try XCTUnwrap(shell.attachments.cards.first)
        let actions = try XCTUnwrap(f.adapter.actions), context = try XCTUnwrap(actions.attachmentContext(messageID: message.id, fileID: file.id))
        shell.setMediaVisible(true)
        try await wait("first preview request") { NativeAttachmentProtocol.traffic.paths == [path] }
        shell.setMediaVisible(false)
        try await wait("hidden preview cancellation") { NativeAttachmentProtocol.traffic.cancelled == [path] }
        XCTAssertNil(card.currentTask); XCTAssertNil(card.imageButton.preview); XCTAssertTrue(card.spinner.isHidden)
        XCTAssertNil(actions.attachmentPresentation(context).problem)
        shell.setMediaVisible(true)
        try await wait("second preview request") { NativeAttachmentProtocol.traffic.paths == [path, path] }
        shell.unbind()
        try await wait("unbound preview cancellation") { NativeAttachmentProtocol.traffic.cancelled == [path, path] }
        NativeAttachmentProtocol.release(path)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(card.binding); XCTAssertNil(card.currentTask); XCTAssertNil(card.imageButton.preview)
        XCTAssertNil(actions.attachmentPresentation(context).problem)
        XCTAssertNil(f.manager.image(message, file: file))
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init(paths: [path, path], completed: [], cancelled: [path, path]))
    }

    func testNativeAttachmentFailureNeedsNewPlanAndRetryLoadsThroughTheRealManager() async throws {
        let f = try await fixture(), (file, data) = try image(f)
        let message = try await f.stored([file]), path = f.path(file)
        NativeAttachmentProtocol.hold(path, answer: .failure(URLError(.networkConnectionLost)))
        let shell = try cell(f, message: message), before = try XCTUnwrap(shell.plan)
        let card = try XCTUnwrap(shell.attachments.cards.first)
        let actions = try XCTUnwrap(f.adapter.actions), context = try XCTUnwrap(actions.attachmentContext(messageID: message.id, fileID: file.id))
        shell.setMediaVisible(true)
        try await wait("failing preview request") { NativeAttachmentProtocol.traffic.paths == [path] }
        NativeAttachmentProtocol.release(path)
        try await wait("failure publication") { actions.attachmentPresentation(context).problem == "Preview failed to load." }
        XCTAssertEqual(shell.plan, before, "A completion may publish state but may not resize the installed plan")
        try f.configure(shell, messageID: message.id)
        let failed = try XCTUnwrap(shell.plan)
        // The paired legacy sequence adds a 13-point error/Retry line after a
        // 4-point gap; preserving that growth is the timeline parity contract.
        XCTAssertEqual(failed.height, before.height + 17)
        XCTAssertEqual(failed.body, before.body)
        XCTAssertEqual(card.problem.text.string, "Preview failed to load.")
        XCTAssertTrue(card.imageButton.failed); XCTAssertFalse(card.retry.isHidden); XCTAssertTrue(card.spinner.isHidden)
        NativeAttachmentProtocol.hold(path, answer: .success(.init(status: 200, body: data)))
        card.retry.performClick(nil)
        XCTAssertNil(actions.attachmentPresentation(context).problem)
        XCTAssertEqual(actions.attachmentPresentation(context).operation, .init(busy: false, retry: 1))
        try f.configure(shell, messageID: message.id)
        try await wait("retried preview request") { NativeAttachmentProtocol.traffic.paths == [path, path] }
        XCTAssertEqual(shell.plan?.height, before.height)
        NativeAttachmentProtocol.release(path)
        try await wait("retry pixels") { card.imageButton.preview != nil }
        XCTAssertFalse(card.imageButton.failed)
        XCTAssertNil(actions.attachmentPresentation(context).problem)
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init(paths: [path, path], completed: [path, path], cancelled: []))
    }

    func testNativeFailedPreviewScrollAwayAndBackClearsErrorBeforeAutomaticRetryCompletes() async throws {
        let f = try await fixture(), (file, data) = try image(f)
        let message = try await f.stored([file]), path = f.path(file)
        for index in 0..<30 { _ = try await f.stored([], text: "After the retrying preview \(index).") }
        NativeAttachmentProtocol.hold(path, answer: .failure(URLError(.networkConnectionLost)))
        let coordinator = NativeChatTimelineCoordinator(), view = NativeChatTimelineContainer(coordinator: coordinator)
        let host = ChatQuietHost(view: view, dark: false, width: 760, height: 400)
        hosts.append(host)
        defer { coordinator.dispose() }
        ChatScrollAppKitSettings.apply(to: coordinator.scrollView)
        let initial = f.snapshot()
        coordinator.actions = f.adapter.actions; view.update(initial)
        try await host.settle()
        XCTAssertTrue(coordinator.scrollController.scrollTo(messageID: message.id, alignment: .top))
        try await host.settle()
        try await wait("initial preview request") { NativeAttachmentProtocol.traffic.paths == [path] }
        let index = try XCTUnwrap(coordinator.messageIndex(message.id))
        let before = try XCTUnwrap(coordinator.layoutPlan(at: index))
        let actions = try XCTUnwrap(f.adapter.actions)
        let context = try XCTUnwrap(actions.attachmentContext(messageID: message.id, fileID: file.id))
        NativeAttachmentProtocol.release(path)
        try await wait("preview failure") { actions.attachmentPresentation(context).problem == "Preview failed to load." }
        view.update(f.snapshot()); try await host.settle()
        XCTAssertEqual(coordinator.layoutPlan(at: index)?.height, before.height + 17)
        let failedCell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell)
        let failedCard = try XCTUnwrap(failedCell.attachments.cards.first)
        XCTAssertFalse(failedCard.retry.isHidden)

        let last = try XCTUnwrap(coordinator.snapshot?.rows.compactMap(\.messageID).last)
        XCTAssertTrue(coordinator.scrollController.scrollTo(messageID: last, alignment: .top))
        try await host.settle()
        XCTAssertFalse(failedCard.visible)
        XCTAssertNil(failedCard.currentTask)
        XCTAssertEqual(actions.attachmentPresentation(context).problem, "Preview failed to load.")
        NativeAttachmentProtocol.hold(path, answer: .success(.init(status: 200, body: data)))
        XCTAssertTrue(coordinator.scrollController.scrollTo(messageID: message.id, alignment: .top))
        try await host.settle()
        try await wait("automatic preview retry") { NativeAttachmentProtocol.traffic.paths.count >= 2 }
        // Legacy's .task clears its error before awaiting the restarted load.
        // No Retry click and no successful response have occurred here.
        XCTAssertNil(actions.attachmentPresentation(context).problem)
        XCTAssertEqual(actions.attachmentPresentation(context).operation, .init())
        view.update(f.snapshot()); try await host.settle()
        let loading = try XCTUnwrap(coordinator.layoutPlan(at: index))
        let cell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell)
        let card = try XCTUnwrap(cell.attachments.cards.first)
        XCTAssertEqual(loading.height, before.height)
        XCTAssertTrue(card.problem.isHidden); XCTAssertTrue(card.retry.isHidden)
        XCTAssertFalse(card.imageButton.failed); XCTAssertFalse(card.spinner.isHidden)
        XCTAssertNotNil(card.currentTask); XCTAssertNil(card.imageButton.preview)
        let origin = coordinator.scrollView.contentView.bounds.origin

        NativeAttachmentProtocol.release(path)
        try await wait("automatic retry pixels") { card.imageButton.preview != nil && card.currentTask == nil }
        XCTAssertNil(actions.attachmentPresentation(context).problem)
        XCTAssertEqual(cell.plan, loading, "Successful decode must preserve the installed loading plan")
        view.update(f.snapshot()); try await host.settle()
        XCTAssertEqual(coordinator.layoutPlan(at: index), loading, "Success must not remove an error row or change geometry")
        XCTAssertEqual(coordinator.scrollView.contentView.bounds.origin, origin)
        XCTAssertTrue(card.spinner.isHidden)
    }

    func testNativeAttachmentFailureTransactionPreservesFollowingReadingAnchor() async throws {
        let f = try await fixture(), (file, _) = try image(f)
        for index in 0..<12 { _ = try await f.stored([], text: "Earlier native message \(index).") }
        let changed = try await f.stored([file], text: "A delayed preview above the reading position.")
        let anchor = try await f.stored([], text: "Keep this native reading line in the same place.")
        for index in 0..<20 { _ = try await f.stored([], text: "Later native message \(index).") }
        let path = f.path(file)
        NativeAttachmentProtocol.hold(path, answer: .failure(URLError(.networkConnectionLost)))
        let coordinator = NativeChatTimelineCoordinator(), view = NativeChatTimelineContainer(coordinator: coordinator)
        let host = ChatQuietHost(view: view, dark: false, width: 760, height: 400)
        hosts.append(host)
        defer { coordinator.dispose() }
        ChatScrollAppKitSettings.apply(to: coordinator.scrollView)
        let initial = f.snapshot()
        coordinator.actions = f.adapter.actions; view.update(initial)
        try await host.settle()
        coordinator.scrollController.stopFollowing()
        let anchorFrame = try XCTUnwrap(coordinator.scrollController.bodyFrame(anchor.id))
        coordinator.scrollView.contentView.scroll(to: CGPoint(x: 0, y: anchorFrame.minY - 100))
        coordinator.scrollView.reflectScrolledClipView(coordinator.scrollView.contentView)
        try await host.settle()
        coordinator.refreshMediaVisibility()
        try await wait("native table preview") { NativeAttachmentProtocol.traffic.paths == [path] }
        let changedIndex = try XCTUnwrap(coordinator.messageIndex(changed.id))
        let shell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: changedIndex, makeIfNecessary: false) as? ChatNativeShellCell)
        let oldPlan = try XCTUnwrap(shell.plan)
        let beforeY = try XCTUnwrap(coordinator.scrollController.bodyFrame(anchor.id)).minY - coordinator.scrollView.contentView.bounds.minY
        XCTAssertEqual(beforeY, 100, accuracy: 0.75)
        let changedFrame = try XCTUnwrap(coordinator.scrollController.bodyFrame(changed.id))
        XCTAssertLessThan(changedFrame.minY, coordinator.scrollView.contentView.bounds.minY)
        XCTAssertGreaterThan(changedFrame.maxY, coordinator.scrollView.contentView.bounds.minY)
        let actions = try XCTUnwrap(f.adapter.actions), context = try XCTUnwrap(actions.attachmentContext(messageID: changed.id, fileID: file.id))
        NativeAttachmentProtocol.release(path)
        try await wait("native table failure publication") { actions.attachmentPresentation(context).problem == "Preview failed to load." }
        XCTAssertEqual(shell.plan, oldPlan)
        view.update(f.snapshot())
        try await host.settle()
        XCTAssertGreaterThan(try XCTUnwrap(coordinator.layoutPlan(at: changedIndex)).height, oldPlan.height)
        let afterY = try XCTUnwrap(coordinator.scrollController.bodyFrame(anchor.id)).minY - coordinator.scrollView.contentView.bounds.minY
        XCTAssertEqual(afterY, beforeY, accuracy: 0.75)
        XCTAssertFalse(coordinator.scrollController.following)
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init(paths: [path], completed: [path], cancelled: []))
    }

    func testNativeViewportHidingScrollingAndWindowDetachOwnPreviewLifetime() async throws {
        let f = try await fixture()
        let (firstFile, firstBytes) = try image(f, name: "first-viewport.png")
        let (secondFile, secondBytes) = try image(f, name: "second-viewport.png")
        let first = try await f.stored([firstFile])
        for index in 0..<24 { _ = try await f.stored([], text: "Between the native image rows \(index).") }
        let second = try await f.stored([secondFile])
        for index in 0..<12 { _ = try await f.stored([], text: "After the native image rows \(index).") }
        let firstPath = f.path(firstFile), secondPath = f.path(secondFile)
        NativeAttachmentProtocol.hold(firstPath, answer: .success(.init(status: 200, body: firstBytes)))
        NativeAttachmentProtocol.hold(secondPath, answer: .success(.init(status: 200, body: secondBytes)))
        let coordinator = NativeChatTimelineCoordinator(), view = NativeChatTimelineContainer(coordinator: coordinator)
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 760, height: 400))
        parent.isHidden = true
        view.frame = parent.bounds; view.autoresizingMask = [.width, .height]; parent.addSubview(view)
        let host = ChatQuietHost(view: parent, dark: false, width: 760, height: 400)
        hosts.append(host)
        defer { coordinator.dispose() }
        ChatScrollAppKitSettings.apply(to: coordinator.scrollView)
        let snapshot = f.snapshot()
        coordinator.actions = f.adapter.actions; view.update(snapshot)
        try await host.settle()
        let firstIndex = try XCTUnwrap(coordinator.messageIndex(first.id)), secondIndex = try XCTUnwrap(coordinator.messageIndex(second.id))
        func viewportDiagnostic() -> String {
            let table = coordinator.tableView, clip = coordinator.scrollView.contentView
            let rows = [("first", firstIndex), ("second", secondIndex)].map { name, index in
                let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell
                let card = cell?.attachments.cards.first
                return "\(name): row=\(table.rect(ofRow: index)), cellFrame=\(String(describing: cell?.frame)), cellVisibleRect=\(String(describing: cell?.visibleRect)), attachmentsFrame=\(String(describing: cell?.attachments.frame)), attachmentsVisibleRect=\(String(describing: cell?.attachments.visibleRect)), cardFrame=\(String(describing: card?.frame)), cardVisibleRect=\(String(describing: card?.visibleRect)), cardVisible=\(String(describing: card?.visible)), task=\(card?.currentTask != nil), spinnerHidden=\(String(describing: card?.spinner.isHidden)), cardWindow=\(card?.window != nil)"
            }.joined(separator: " | ")
            return "parentHidden=\(parent.isHidden), parentWindow=\(parent.window != nil), containerHidden=\(view.isHiddenOrHasHiddenAncestor), containerWindow=\(view.window != nil), containerFrame=\(view.frame), tableHidden=\(table.isHiddenOrHasHiddenAncestor), tableWindow=\(table.window != nil), tableFrame=\(table.frame), tableVisibleRect=\(table.visibleRect), clipFrame=\(clip.frame), clipBounds=\(clip.bounds); \(rows)"
        }
        XCTAssertTrue(coordinator.scrollController.scrollTo(messageID: second.id, alignment: .top))
        _ = coordinator.layoutPlan(at: firstIndex)
        let prefetched = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: firstIndex, makeIfNecessary: true) as? ChatNativeShellCell)
        let prefetchedCard = try XCTUnwrap(prefetched.attachments.cards.first)
        XCTAssertFalse(coordinator.tableView.rect(ofRow: firstIndex).intersects(coordinator.scrollView.contentView.bounds))
        XCTAssertFalse(prefetchedCard.visible); XCTAssertNil(prefetchedCard.currentTask)
        XCTAssertTrue(prefetchedCard.spinner.isHidden)
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init(), "Hidden measurement and real offscreen row creation cannot request media")

        XCTAssertTrue(coordinator.scrollController.scrollTo(messageID: first.id, alignment: .top))
        parent.isHidden = false
        try await host.settle()
        try await wait("unhidden native viewport", diagnostic: viewportDiagnostic) { NativeAttachmentProtocol.traffic.paths == [firstPath] }
        let firstShell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: firstIndex, makeIfNecessary: false) as? ChatNativeShellCell)
        let firstCard = try XCTUnwrap(firstShell.attachments.cards.first)
        XCTAssertTrue(firstCard.visible); XCTAssertNotNil(firstCard.currentTask); XCTAssertFalse(firstCard.spinner.isHidden)
        parent.isHidden = true
        try await host.settle()
        try await wait("hidden parent cancels actual preview", diagnostic: viewportDiagnostic) { NativeAttachmentProtocol.traffic.cancelled == [firstPath] }
        XCTAssertFalse(firstCard.visible); XCTAssertNil(firstCard.currentTask); XCTAssertNil(firstCard.imageButton.preview)
        XCTAssertTrue(firstCard.spinner.isHidden)
        parent.isHidden = false
        try await host.settle()
        try await wait("visible row restarts after parent unhide", diagnostic: viewportDiagnostic) { NativeAttachmentProtocol.traffic.paths == [firstPath, firstPath] }

        XCTAssertTrue(coordinator.scrollController.scrollTo(messageID: second.id, alignment: .top))
        try await host.settle()
        try await wait("scroll cancels retained old card", diagnostic: viewportDiagnostic) { NativeAttachmentProtocol.traffic.cancelled == [firstPath, firstPath] }
        try await wait("scroll loads newly visible row", diagnostic: viewportDiagnostic) { NativeAttachmentProtocol.traffic.paths == [firstPath, firstPath, secondPath] }
        XCTAssertFalse(firstCard.visible); XCTAssertNil(firstCard.currentTask); XCTAssertNil(firstCard.imageButton.preview)
        XCTAssertTrue(firstCard.spinner.isHidden || firstCard.window == nil)
        let secondShell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: secondIndex, makeIfNecessary: false) as? ChatNativeShellCell)
        let detachedCard = try XCTUnwrap(secondShell.attachments.cards.first)
        view.removeFromSuperview()
        try await wait("window detach cancels native preview", diagnostic: viewportDiagnostic) { NativeAttachmentProtocol.traffic.cancelled == [firstPath, firstPath, secondPath] }
        XCTAssertNil(view.window); XCTAssertNil(detachedCard.binding); XCTAssertNil(detachedCard.currentTask)
        XCTAssertFalse(detachedCard.visible); XCTAssertNil(detachedCard.imageButton.preview)
        XCTAssertTrue(detachedCard.spinner.isHidden || detachedCard.window == nil)

        parent.addSubview(view)
        try await host.settle()
        try await wait("reattachment restarts only the visible media", diagnostic: viewportDiagnostic) { NativeAttachmentProtocol.traffic.paths == [firstPath, firstPath, secondPath, secondPath] }
        let reattached = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: secondIndex, makeIfNecessary: false) as? ChatNativeShellCell)
        let currentCard = try XCTUnwrap(reattached.attachments.cards.first)
        NativeAttachmentProtocol.release(secondPath)
        try await wait("reattached current preview") { currentCard.imageButton.preview != nil && currentCard.currentTask == nil }
        XCTAssertTrue(currentCard.spinner.isHidden)
        XCTAssertNil(f.manager.image(first, file: firstFile))
        XCTAssertNotNil(f.manager.image(second, file: secondFile))
        XCTAssertEqual(NativeAttachmentProtocol.traffic,
            .init(paths: [firstPath, firstPath, secondPath, secondPath], completed: [secondPath], cancelled: [firstPath, firstPath, secondPath]))
    }

    func testNativePendingPreviewRejectsCompletionAfterFullBindingChanges() async throws {
        let f = try await fixture(), (file, bytes) = try image(f)
        let message = try await f.stored([file]), path = f.path(file)
        NativeAttachmentProtocol.hold(path, answer: .failure(URLError(.networkConnectionLost)))
        let coordinator = NativeChatTimelineCoordinator(), view = NativeChatTimelineContainer(coordinator: coordinator)
        let host = ChatQuietHost(view: view, dark: false, width: 760, height: 400)
        hosts.append(host)
        defer { coordinator.dispose() }
        ChatScrollAppKitSettings.apply(to: coordinator.scrollView)
        let initial = f.snapshot()
        coordinator.actions = f.adapter.actions; view.update(initial)
        try await host.settle()
        try await wait("original binding preview") { NativeAttachmentProtocol.traffic.paths == [path] }
        let index = try XCTUnwrap(coordinator.messageIndex(message.id))
        let shell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell)
        let card = try XCTUnwrap(shell.attachments.cards.first), oldBinding = try XCTUnwrap(card.binding)
        let oldTask = try XCTUnwrap(card.currentTask), oldPlan = try XCTUnwrap(shell.plan)
        let actions = try XCTUnwrap(f.adapter.actions), context = try XCTUnwrap(actions.attachmentContext(messageID: message.id, fileID: file.id))

        // The response has reached URLSession, but this actor turn installs the
        // new display identity before the old task can deliver its failure.
        NativeAttachmentProtocol.releaseBeforeReturning(path)
        NativeAttachmentProtocol.hold(path, answer: .success(.init(status: 200, body: bytes)))
        view.update(f.snapshot(author: "Anna renamed"))
        let newBinding = try XCTUnwrap(card.binding), newPlan = try XCTUnwrap(shell.plan)
        XCTAssertEqual(newBinding.id, oldBinding.id); XCTAssertEqual(newBinding.epoch, oldBinding.epoch)
        XCTAssertGreaterThan(newBinding.contentRevision, oldBinding.contentRevision)
        XCTAssertGreaterThan(newBinding.reuseGeneration, oldBinding.reuseGeneration)
        XCTAssertTrue(oldTask.isCancelled)
        XCTAssertEqual(try XCTUnwrap(actions.attachmentContext(messageID: message.id, fileID: file.id)).stamp, context.stamp,
            "The descriptor and service authorization stay the same; the complete cell binding changed")
        try await wait("fresh binding preview request") { NativeAttachmentProtocol.traffic.paths == [path, path] }
        XCTAssertTrue(shell.attachments.cards.first === card)
        XCTAssertNil(actions.attachmentPresentation(context).problem)
        XCTAssertNil(card.imageButton.preview); XCTAssertFalse(card.imageButton.failed)
        XCTAssertNotNil(card.currentTask); XCTAssertFalse(card.spinner.isHidden)
        XCTAssertEqual(shell.plan, newPlan)
        XCTAssertEqual(newPlan.attachments, oldPlan.attachments)
        XCTAssertFalse(shell.apply(ifCurrent: oldBinding) { _ in XCTFail("Old complete binding was accepted") })
        NativeAttachmentProtocol.release(path)
        try await wait("fresh binding paints after old callback") { card.imageButton.preview != nil && card.currentTask == nil }
        XCTAssertEqual(card.binding, newBinding); XCTAssertEqual(shell.plan, newPlan)
        XCTAssertNil(actions.attachmentPresentation(context).problem)
        XCTAssertTrue(card.spinner.isHidden)
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init(paths: [path, path], completed: [path, path], cancelled: []))
    }

    func testNativeAttachmentReuseRejectsOldPixelsErrorsAndGeometry() async throws {
        let f = try await fixture()
        let (oldFile, oldBytes) = try image(f, name: "old.png"), (newFile, newBytes) = try image(f, name: "new.png", width: 64, height: 64)
        let old = try await f.stored([oldFile]), new = try await f.stored([newFile])
        NativeAttachmentProtocol.hold(f.path(oldFile), answer: .success(.init(status: 200, body: oldBytes)))
        NativeAttachmentProtocol.hold(f.path(newFile), answer: .success(.init(status: 200, body: newBytes)))
        let shell = try cell(f, message: old), oldCard = try XCTUnwrap(shell.attachments.cards.first)
        shell.setMediaVisible(true)
        try await wait("old row request") { NativeAttachmentProtocol.traffic.paths == [f.path(oldFile)] }
        let oldBinding = try XCTUnwrap(shell.binding)
        try f.configure(shell, messageID: new.id)
        shell.setMediaVisible(true)
        let newCard = try XCTUnwrap(shell.attachments.cards.first), newPlan = try XCTUnwrap(shell.plan)
        try await wait("reused row request") { NativeAttachmentProtocol.traffic.paths == [f.path(oldFile), f.path(newFile)] }
        try await wait("old row cancelled") { NativeAttachmentProtocol.traffic.cancelled == [f.path(oldFile)] }
        NativeAttachmentProtocol.release(f.path(oldFile)); NativeAttachmentProtocol.release(f.path(newFile))
        try await wait("current row decoded") { newCard.imageButton.preview != nil }
        XCTAssertFalse(oldCard === newCard)
        XCTAssertNil(oldCard.binding); XCTAssertNil(oldCard.imageButton.preview)
        XCTAssertEqual(newCard.imageButton.preview?.width, 64)
        XCTAssertEqual(newCard.name.text.string, "new.png")
        XCTAssertEqual(newCard.binding?.id.kind, .message(new.id))
        XCTAssertEqual(shell.plan, newPlan)
        XCTAssertFalse(shell.apply(ifCurrent: oldBinding) { _ in XCTFail("Old binding was accepted") })
        XCTAssertNil(f.manager.image(old, file: oldFile))
        XCTAssertEqual(NativeAttachmentProtocol.traffic.completed, [f.path(newFile)])
    }

    func testNativeAttachmentNoPreviewRemainsSpinnerAndImageActionUsesCurrentRoute() async throws {
        let f = try await fixture(), (file, _) = try image(f, preview: false)
        let message = try await f.stored([file])
        let shell = try cell(f, message: message), card = try XCTUnwrap(shell.attachments.cards.first)
        let actions = try XCTUnwrap(f.adapter.actions)
        var opened: [String] = []
        actions.attachmentViewer = { key, source, attachment in
            XCTAssertEqual(key, f.base.key)
            opened.append("\(source.id)/\(attachment.id)")
        }
        shell.setMediaVisible(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(card.spinner.isHidden); XCTAssertNil(card.currentTask); XCTAssertFalse(card.imageButton.failed)
        XCTAssertEqual(card.accessibilityLabel(), "\(file.mime), \(file.name), \(file.sizeText)")
        XCTAssertEqual(card.imageButton.toolTip, "Open image")
        XCTAssertTrue(card.download.isHidden)
        card.imageButton.performClick(nil)
        XCTAssertEqual(opened, ["\(message.id)/\(file.id)"])
        try f.base.write("UPDATE messages SET deleted_at = '2026-10-06T13:00:00Z' WHERE message_id = ?", [message.id])
        // The retained button must fail its current stamp before a repaint.
        card.imageButton.performClick(nil)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init())
    }

    func testNativeMessageEditInvalidationPublishesFileUnavailableUntilHydration() async throws {
        let f = try await fixture(), (file, bytes) = try image(f)
        let message = try await f.stored([file]), path = f.path(file)
        NativeAttachmentProtocol.hold(path, answer: .success(.init(status: 200, body: bytes)))
        let shell = try cell(f, message: message), card = try XCTUnwrap(shell.attachments.cards.first)
        let installed = try XCTUnwrap(shell.plan), actions = try XCTUnwrap(f.adapter.actions)
        shell.setMediaVisible(true)
        try await wait("preview before real edit event") { NativeAttachmentProtocol.traffic.paths == [path] }
        let outerTask = try XCTUnwrap(card.currentTask)
        let event = ChatEvent(stream: "channel:\(message.channelId)", seq: 2, id: UUID().uuidString,
            type: "message.edit", actor: nil,
            body: .object(["message_id": .string(message.id), "revision": .number(2), "message_seq": .number(1)]),
            commandId: nil, at: "2026-10-06T12:01:00Z")
        try await f.base.store.queue.write { db in XCTAssertTrue(try ChatMessages.apply(db, event)) }
        f.manager.reconcile()
        try await wait("edit invalidation cancels only the manager read") {
            NativeAttachmentProtocol.traffic.cancelled == [path] && card.currentTask == nil && f.model.message(message.id)?.stale == 2
        }
        let stale = try XCTUnwrap(f.model.message(message.id))
        XCTAssertEqual(stale.revision, 1); XCTAssertEqual(stale.attachments, [file]); XCTAssertTrue(stale.loading)
        XCTAssertFalse(outerTask.isCancelled, "Service cancellation does not cancel the still-bound native cell task")
        XCTAssertNotNil(f.manager.stamp(owner: stale.attachmentOwner))
        XCTAssertNil(f.manager.stamp(owner: stale.attachmentOwner, message: stale, file: file))
        XCTAssertNil(f.manager.image(stale, file: file)); XCTAssertNil(card.imageButton.preview)
        XCTAssertEqual(shell.plan, installed, "The failure callback must not resize the installed reservation")
        XCTAssertEqual(actions.attachmentPresentations(message: stale)[file.id]?.problem, "File unavailable.")
        try f.configure(shell, messageID: message.id)
        let unavailable = try XCTUnwrap(shell.plan?.attachments?.cards.first)
        XCTAssertEqual(unavailable.problemText, "File unavailable.")
        XCTAssertGreaterThan(unavailable.problem.height, 0)
        XCTAssertTrue(unavailable.retry.isEmpty)
        XCTAssertTrue(card.imageButton.failed); XCTAssertFalse(card.imageButton.isEnabled)
        XCTAssertTrue(card.retry.isHidden); XCTAssertTrue(card.spinner.isHidden)

        let fields: [String: Any] = ["message_id": message.id, "channel_id": message.channelId,
            "author_account_id": message.authorAccountId, "text": "Hydrated edited attachment caption", "revision": 2, "seq": 1,
            "created_at": message.createdAt, "edited_at": "2026-10-06T12:01:00Z",
            "attachments": try [JSONSerialization.jsonObject(with: JSONEncoder().encode(file))]]
        let hydrated = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: fields))
        try await f.base.store.queue.write { db in XCTAssertTrue(try ChatMessages.write(db, hydrated)) }
        try await wait("real edited message hydration") { f.model.message(message.id)?.revision == 2 && f.model.message(message.id)?.stale == nil }
        let fresh = try XCTUnwrap(f.model.message(message.id))
        XCTAssertNil(actions.attachmentPresentations(message: fresh)[file.id]?.problem,
            "The new revision cannot inherit the unavailable state of an older descriptor")
        NativeAttachmentProtocol.hold(path, answer: .success(.init(status: 200, body: bytes)))
        try f.configure(shell, messageID: message.id)
        try await wait("hydrated revision starts its own preview") { NativeAttachmentProtocol.traffic.paths == [path, path] }
        XCTAssertNil(shell.plan?.attachments?.cards.first?.problemText)
        XCTAssertFalse(card.imageButton.failed); XCTAssertTrue(card.imageButton.isEnabled)
        NativeAttachmentProtocol.release(path)
        try await wait("hydrated preview paints") { card.imageButton.preview != nil && card.currentTask == nil }
        XCTAssertNil(actions.attachmentPresentations(message: fresh)[file.id]?.problem)
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init(paths: [path, path], completed: [path], cancelled: [path]))
    }

    func testNativeAttachmentRevokedStampCancelsAndCannotCacheLatePreview() async throws {
        let f = try await fixture(), (file, data) = try image(f)
        let message = try await f.stored([file]), path = f.path(file)
        NativeAttachmentProtocol.hold(path, answer: .success(.init(status: 200, body: data)))
        let shell = try cell(f, message: message), card = try XCTUnwrap(shell.attachments.cards.first)
        let actions = try XCTUnwrap(f.adapter.actions), context = try XCTUnwrap(actions.attachmentContext(messageID: message.id, fileID: file.id))
        shell.setMediaVisible(true)
        try await wait("authorized request") { NativeAttachmentProtocol.traffic.paths == [path] }
        try f.base.store.putRightsInDoubt()
        f.manager.reconcile()
        try await wait("revoked transfer cancellation") { NativeAttachmentProtocol.traffic.cancelled == [path] }
        NativeAttachmentProtocol.release(path)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(f.manager.current(context.stamp))
        XCTAssertNil(actions.attachmentContext(messageID: message.id, fileID: file.id))
        XCTAssertNil(card.imageButton.preview); XCTAssertNil(f.manager.image(message, file: file))
        XCTAssertNil(actions.attachmentPresentation(context).problem)
        try f.configure(shell, messageID: message.id)
        XCTAssertTrue(shell.attachments.cards.isEmpty)
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init(paths: [path], completed: [], cancelled: [path]))
    }

    func testNativeAttachmentSaveContinuesAfterScrollOffAndReportsBusyOnTheCard() async throws {
        let f = try await fixture(), data = Data("The user requested this original file.\n".utf8)
        let file = try ChatAttachmentStorage.descriptor(data: data, name: "notes.txt", limits: f.limits)
        let message = try await f.stored([file]), path = f.path(file, preview: false)
        NativeAttachmentProtocol.hold(path, answer: .success(.init(status: 200, body: data)))
        let shell = try cell(f, message: message), card = try XCTUnwrap(shell.attachments.cards.first)
        let host = try host(shell), actions = try XCTUnwrap(f.adapter.actions)
        let context = try XCTUnwrap(actions.attachmentContext(messageID: message.id, fileID: file.id))
        var writes: [Data] = [], operationFinished = false
        actions.startAttachmentSave(context, window: host.window, stillValid: { true }) { manager, source, attachment, window, valid in
            defer { operationFinished = true }
            XCTAssertTrue(window === host.window)
            let original = try await manager.load(source, file: attachment, preview: false)
            if valid() { writes.append(original) }
        }
        try f.configure(shell, messageID: message.id); shell.setMediaVisible(true)
        try await wait("user original request") { NativeAttachmentProtocol.traffic.paths == [path] }
        XCTAssertEqual(actions.attachmentPresentation(context).operation, .init(busy: true, retry: 0))
        XCTAssertTrue(card.download.isHidden); XCTAssertFalse(card.spinner.isHidden)
        XCTAssertTrue(card.imageButton.isHidden)
        XCTAssertEqual(card.download.accessibilityLabel(), "Save notes.txt")
        shell.setMediaVisible(false); shell.unbind()
        XCTAssertNil(card.currentTask)
        NativeAttachmentProtocol.release(path)
        try await wait("save completion after recycling") { operationFinished && !actions.attachmentPresentation(context).operation.busy }
        XCTAssertEqual(writes, [data])
        XCTAssertNil(actions.attachmentPresentation(context).problem)
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init(paths: [path], completed: [path], cancelled: []))
    }

    func testNativeAttachmentSaveRechecksWindowOwnershipBeforeFinalWrite() async throws {
        let f = try await fixture(), data = Data("Original must not reach an invalid owner.\n".utf8)
        let file = try ChatAttachmentStorage.descriptor(data: data, name: "owner.txt", limits: f.limits)
        let message = try await f.stored([file]), path = f.path(file, preview: false)
        NativeAttachmentProtocol.hold(path, answer: .success(.init(status: 200, body: data)))
        let shell = try cell(f, message: message), host = try host(shell)
        let actions = try XCTUnwrap(f.adapter.actions), context = try XCTUnwrap(actions.attachmentContext(messageID: message.id, fileID: file.id))
        var ownerStillValid = true, finished = false, writes: [Data] = []
        actions.startAttachmentSave(context, window: host.window, stillValid: { ownerStillValid }) { manager, source, attachment, _, valid in
            defer { finished = true }
            let bytes = try await manager.load(source, file: attachment, preview: false)
            if valid() { writes.append(bytes) }
        }
        try await wait("save awaiting original") { NativeAttachmentProtocol.traffic.paths == [path] }
        ownerStillValid = false
        NativeAttachmentProtocol.release(path)
        try await wait("invalid owner completion") { finished && !actions.attachmentPresentation(context).operation.busy }
        XCTAssertTrue(writes.isEmpty)
        XCTAssertNil(actions.attachmentPresentation(context).problem)
        XCTAssertEqual(NativeAttachmentProtocol.traffic, .init(paths: [path], completed: [path], cancelled: []))
    }
}

/// Real domain model, SQLite attachment ownership, manager and scoped actions.
/// Only bytes and a save sheet's final write are controlled by the tests.
@MainActor private final class NativeAttachmentFixture {
    let base: ChatChannelExecutionTests.Fixture
    let model: ChatChannelModel
    let limits: ChatAttachmentLimits
    let manager: ChatAttachmentManager
    let adapter = ChatTimelineAdapter()
    let layout = ChatTimelineLayout()
    let layer = ChatNativeDocumentLayer()
    private var sequence = 0
    static let channel = "f5000000-0000-4000-8000-000000000001"

    init(directory: URL) async throws {
        base = try await ChatChannelExecutionTests.Fixture(root: directory)
        limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        base.service.serverCapabilities[base.key.server] = ["chat.attachments", "chat.attachments_context", "chat.channel_ux1"]
        base.service.serverAttachmentLimits[base.key.server] = limits
        base.service.isServerKnown = { _, _ in true }
        base.service.makeAPI = { ChatAPI(server: $0, protocolClasses: [NativeAttachmentProtocol.self]) }
        manager = try XCTUnwrap(base.service.attachments(base.key))
        model = ChatChannelModel(key: base.key, channel: Self.channel)
        model.service = base.service; model.tabID = UUID(); model.follow(base.store)
    }

    func stored(_ files: [ChatAttachment], text: String = "Native attachment fixture") async throws -> ChatMessage {
        sequence += 1
        let fields: [String: Any] = ["message_id": UUID().uuidString.lowercased(), "channel_id": Self.channel,
            "author_account_id": base.key.accountId, "text": text, "revision": 1, "seq": sequence,
            "created_at": "2026-10-06T12:00:00Z",
            "attachments": try files.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: fields))
        try await base.store.queue.write { _ = try ChatMessages.write($0, wire) }
        let deadline = ContinuousClock.now + .seconds(4)
        // The snapshot consumes the observed feed, not a direct database read.
        // Wait for that publication before a caller takes its initial snapshot.
        while !model.feed.messages.contains(where: { $0.id == wire.messageId }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(model.feed.messages.first { $0.id == wire.messageId })
    }

    func snapshot(author: String = "Anna") -> NativeTimelineSnapshot {
        adapter.snapshot(model: model, root: nil,
            members: [.init(accountId: base.key.accountId, handle: "anna", name: author, role: "owner")],
            mentionable: [(base.key.accountId, "anna")], me: base.key.accountId, archived: model.feed.archived,
            ownerModel: nil, style: ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
                increasedContrast: false, alwaysShowTime: false))
    }

    func configure(_ cell: ChatNativeShellCell, messageID: String, width: CGFloat = 760) throws {
        let snapshot = snapshot()
        let row = try XCTUnwrap(snapshot.rows.first { $0.messageID == messageID })
        let width = ChatTimelineWidth(width, scale: snapshot.style.metrics.scale)
        let plan = layout.plan(row, snapshot: snapshot, width: width)
        cell.frame = CGRect(x: 0, y: 0, width: width.points, height: plan.height)
        cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: plan,
            content: layout.content(row, snapshot: snapshot, width: width), actions: adapter.actions)
        cell.configureActions(row: row, snapshot: snapshot, actions: adapter.actions, layer: layer)
        cell.layoutSubtreeIfNeeded()
    }

    func path(_ file: ChatAttachment, preview: Bool = true) -> String {
        "/v1/orgs/\(base.key.orgId)/attachments/\(file.id)/\(preview ? "preview" : "original")"
    }
}
