import AppKit
import AgentPadQuietTestSupport
import GRDB
import QuartzCore
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatRowMaterializationTests: XCTestCase {
    private let channel = "f5000000-0000-4000-8000-000000000001"
    private var directory: URL!
    private var scope: TeamServiceTestScope!
    private var fixture: ChatChannelExecutionTests.Fixture?

    override func setUp() async throws {
        guard APQuietIsEnabled() else { throw NSError(domain: "Quiet harness required", code: 1) }
        AgentPadFonts.registerOnce()
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-row-materialization-\(UUID())")
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
        fixture = try await ChatChannelExecutionTests.Fixture(root: directory)
    }

    override func tearDown() async throws {
        fixture?.service.attachmentManagers.values.forEach { $0.revoke() }
        fixture?.sender?.hold()
        await fixture?.service.disconnect()
        fixture = nil
        ChatStubProtocol.reset()
        scope?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func mount(width: CGFloat, content: () -> AnyView) -> [String: Double] {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        APQuietSelectWindow(window)
        let start = CACurrentMediaTime()
        let host = NSHostingView(rootView: content())
        window.contentView = host
        let created = CACurrentMediaTime()
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let laidOut = CACurrentMediaTime()
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertFalse(APQuietWindowHasOSFocus(window))
        host.rootView = AnyView(EmptyView())
        window.contentView = nil
        window.close()
        return ["hostMS": (created - start) * 1_000, "layoutMS": (laidOut - created) * 1_000,
                "totalMS": (laidOut - start) * 1_000, "height": size.height]
    }

    func testProfileProductionRowsAttachmentsReactionsAndAvatars() async throws {
        let channel = self.channel
        let fixture = try XCTUnwrap(fixture)
        fixture.service.serverCapabilities[fixture.key.server] = ["chat.attachments", "chat.reactions"]
        fixture.service.isServerKnown = { _, _ in true }
        let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        fixture.service.serverAttachmentLimits[fixture.key.server] = limits
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 32 * 4, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for index in 0..<(32 * 16 * 4) { pixels[index] = 180 }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        var image = try ChatAttachmentStorage.descriptor(data: png, name: "profile.png", limits: limits)
        image.hasPreview = true
        var placeholder = image
        placeholder.attachmentId = UUID().uuidString.lowercased()
        placeholder.hasPreview = false
        let note = try ChatAttachmentStorage.descriptor(data: Data("Fixture notes".utf8), name: "notes.txt", limits: limits)
        let categories = ["plain", "formatted-paragraph", "code-block", "file-card", "image-placeholder", "image-loaded", "reactions-1", "reactions-12"]
        let messages = try categories.enumerated().map { index, category -> ChatMessage in
            let files = category == "file-card" ? [note] : category == "image-placeholder" ? [placeholder] : category == "image-loaded" ? [image] : []
            let text = category == "formatted-paragraph" ? ChatScrollContinuityTests.Fixture.message(1, root: nil).text
                : category == "code-block" ? ChatScrollContinuityTests.Fixture.message(2, root: nil).text : "Fixture row \(index)."
            let fields: [String: Any] = ["message_id": "materialization-\(index)", "channel_id": channel,
                "author_account_id": fixture.key.accountId, "text": text, "seq": index + 1, "revision": 1,
                "created_at": "2026-10-21T12:00:00Z",
                "attachments": try files.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]
            let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: fields))
            try fixture.store.queue.write { _ = try ChatMessages.write($0, wire) }
            return try XCTUnwrap(fixture.service.attachments(fixture.key)?.message(owner: .channel(channel), id: wire.messageId))
        }
        let emoji = ["👍", "👎", "❤️", "🎉", "🚀", "👀", "✅", "🔥", "💡", "🙏", "🤔", "😂"]
        try await fixture.store.queue.write { db in
            try ChatB1.watch(db, channel: channel, ids: messages.map(\.id))
            let token = try XCTUnwrap(ChatB1.readToken(db, channel: channel))
            let metadata = messages.enumerated().map { index, message in
                ChatB1.Metadata(messageId: message.id, deleted: false,
                    reactions: index == 6 ? [.init(emoji: "👍", count: 3, mine: false)] : index == 7 ? emoji.map { .init(emoji: $0, count: 3, mine: false) } : [],
                    pin: nil, threadSummary: nil)
            }
            XCTAssertTrue(try ChatB1.apply(db, page: .init(asOfSeq: 1, items: metadata), channel: channel,
                token: token, tickets: Dictionary(uniqueKeysWithValues: messages.map { ($0.id, 0) })))
        }
        let b1 = ChatB1Channel(key: fixture.key, channel: channel, store: fixture.store, service: fixture.service)
        XCTAssertEqual(b1.state.metadata[messages[7].id]?.reactions.count, 12)
        let manager = try XCTUnwrap(fixture.service.attachments(fixture.key))
        let path = "/v1/orgs/\(fixture.key.orgId)/attachments/\(image.id)/preview"
        ChatStubProtocol.reset { request, _ in
            request.url?.path == path ? .success(.init(status: 200, body: png)) : .failure(URLError(.unsupportedURL))
        }
        _ = try await manager.load(messages[5], file: image, preview: true)
        let loaded = try XCTUnwrap(manager.image(messages[5], file: image))
        let avatarImage = NSImage(cgImage: loaded, size: .zero)
        XCTAssertNil(manager.image(messages[4], file: placeholder))
        let requestsBefore = ChatStubProtocol.seen.count
        let model = ChatScrollMediaTests.Model(fixture, messages: messages, b1: b1)
        var samples: [[String: Any]] = []
        for width: CGFloat in [760, 420] {
            for iteration in 0..<12 {
                for (index, category) in categories.enumerated() {
                    let result = mount(width: width) {
                        AnyView(ChatNativeRowFixture(model: model, message: messages[index], members: [], mentionable: [],
                            me: fixture.key.accountId, archived: false, replies: 0, inThread: width == 420, startsGroup: false)
                            .frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
                    }
                    var sample: [String: Any] = result.mapValues { $0 as Any }
                    sample.merge(["category": category, "width": width, "iteration": iteration]) { $1 }
                    samples.append(sample)
                }
                for picture in [false, true] {
                    let result = mount(width: 32) {
                        AnyView(ContactAvatar(stableID: "fixture-avatar", name: "Fixture person", kind: .person,
                            image: picture ? avatarImage : nil))
                    }
                    var sample: [String: Any] = result.mapValues { $0 as Any }
                    sample.merge(["category": picture ? "avatar-image" : "avatar-placeholder", "width": 32,
                                  "paneWidth": width, "iteration": iteration]) { $1 }
                    samples.append(sample)
                }
            }
        }
        XCTAssertEqual(ChatStubProtocol.seen.count, requestsBefore, "Materialization must reuse the decoded image without additional traffic")
        if let output = ProcessInfo.processInfo.environment["AGENTPAD_SCROLL_EVIDENCE"] {
            let url = URL(fileURLWithPath: output).appendingPathComponent("row-materialization.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        }
        for category in categories + ["avatar-image", "avatar-placeholder"] {
            let costs = samples.filter { $0["category"] as? String == category }.compactMap { $0["totalMS"] as? Double }.sorted()
            print("CHAT_ROW_MATERIALIZATION category=\(category) samples=\(costs.count) p95MS=\(costs[Int(Double(costs.count - 1) * 0.95)]) maxMS=\(costs.last ?? 0)")
        }
        XCTAssertNil(APQuietFailure())
    }
}
