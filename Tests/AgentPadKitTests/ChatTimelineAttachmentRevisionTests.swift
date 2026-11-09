import Foundation
import GRDB
import Observation
import XCTest
@testable import AgentPadKit

@MainActor final class ChatTimelineAttachmentRevisionTests: XCTestCase {
    private typealias F = ChatTimelineW01
    private typealias S = NativeTimelineSnapshot
    private var directory: URL!
    private var fixtures: [ChatChannelExecutionTests.Fixture] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-timeline-attachment-revisions-\(UUID().uuidString)")
        ChatNotifications.badgeChanged = {}
    }

    override func tearDown() async throws {
        for fixture in fixtures {
            fixture.service.attachmentManagers.values.forEach { $0.revoke() }
            fixture.sender?.hold()
            await fixture.service.disconnect()
        }
        fixtures.removeAll()
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testNumericLimitsPreserveWholeSnapshotForFileRowsAcrossAllPanes() throws {
        let limits = try limits()
        let changed = changedNumericLimits(limits)
        for dm in [false, true] {
            for root in [nil, "root"] as [String?] {
                let builder = ChatTimelineSnapshotBuilder()
                var message = F.message("files", root: root, dm: dm)
                message.attachments = files()
                let before = builder.build(F.input(messages: [content(message, limits: limits)], dm: dm, root: root))
                let after = builder.build(F.input(messages: [content(message, limits: changed)], dm: dm, root: root))
                XCTAssertEqual(after, before, "Numeric upload/download quotas do not change the displayed files, revisions or generation")
            }
        }
    }

    func testFileGeometryAndAvailabilityStillInvalidateOnlyTheMessage() throws {
        let limits = try limits()
        let builder = ChatTimelineSnapshotBuilder()
        var message = F.message("files")
        message.attachments = files()
        let initial = content(message, limits: limits)
        XCTAssertTrue(initial.attachments.limitsAvailable)
        XCTAssertEqual(builder.build(F.input(messages: [initial])), expected(initial, generation: 1))

        let hidden = content(message, limits: limits, available: false, fileIDs: [], pauseReason: "Files unavailable")
        XCTAssertEqual(builder.build(F.input(messages: [hidden])), expected(hidden, generation: 2))
        let unsupported = content(message, limits: nil, available: false, fileIDs: [], pauseReason: "Files unavailable")
        XCTAssertFalse(unsupported.attachments.limitsAvailable)
        XCTAssertEqual(builder.build(F.input(messages: [unsupported])), expected(unsupported, generation: 3))
        XCTAssertEqual(builder.build(F.input(messages: [initial])), expected(initial, generation: 4))

        let revokedFile = content(message, limits: limits, fileIDs: ["image"])
        XCTAssertEqual(builder.build(F.input(messages: [revokedFile])), expected(revokedFile, generation: 5))
        message.attachments[1].height = 480
        let resized = content(message, limits: limits, fileIDs: ["image"])
        XCTAssertEqual(builder.build(F.input(messages: [resized])), expected(resized, generation: 6))
    }

    func testAdapterIgnoresNumericLimitsForAnAuthorizedStoredFile() async throws {
        let fixture = try await ChatChannelExecutionTests.Fixture(root: directory)
        fixtures.append(fixture)
        let limits = try limits()
        fixture.service.serverCapabilities[fixture.key.server] = ["chat.attachments", "chat.attachments_context", "chat.channel_ux1"]
        fixture.service.serverAttachmentLimits[fixture.key.server] = limits
        fixture.service.isServerKnown = { _, _ in true }
        let file = try ChatAttachmentStorage.descriptor(data: Data("Timeline file fixture\n".utf8), name: "notes.txt", limits: limits)
        let channel = "f5000000-0000-4000-8000-000000000001"
        let body: [String: Any] = ["message_id": "timeline-file", "channel_id": channel,
            "author_account_id": fixture.key.accountId, "text": "Stored file", "revision": 1, "seq": 1,
            "created_at": "2026-10-06T12:00:00Z",
            "attachments": try [JSONSerialization.jsonObject(with: JSONEncoder().encode(file))]]
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: body))
        try await fixture.store.queue.write { _ = try ChatMessages.write($0, wire) }
        let message = try await fixture.store.queue.read { db in
            ChatMessage(row: try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM messages WHERE message_id = ?", arguments: [wire.messageId])))
        }
        let model = ChatTimelineW01Model(directory: directory, key: fixture.key, service: fixture.service)
        model.channel = channel
        model.feed.messages = [message]
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        func capture() -> S {
            adapter.snapshot(model: model, root: nil, members: [], mentionable: [], me: fixture.key.accountId,
                archived: false, ownerModel: nil, style: F.style(), now: F.day)
        }
        let before = capture()
        let row = try XCTUnwrap(before.rows.first { $0.messageID == message.id })
        guard case .message(let value) = row.payload else { return XCTFail("Missing file row") }
        XCTAssertEqual(value.content.attachments,
            .init(limits: limits, available: true, availableFileIDs: [file.id], pauseReason: nil))
        fixture.service.serverAttachmentLimits[fixture.key.server] = changedNumericLimits(limits)
        XCTAssertEqual(capture(), before, "A live adapter recapture retains the file row's layout/content cache identity")
    }

    func testFilelessOwnerAvailabilityIsObservedAndRecheckedAfterCapabilityAndRightsChanges() async throws {
        let fixture = try await ChatChannelExecutionTests.Fixture(root: directory)
        fixtures.append(fixture)
        let capabilities: Set<String> = ["chat.attachments", "chat.attachments_context", "chat.channel_ux1"]
        fixture.service.serverCapabilities[fixture.key.server] = capabilities
        fixture.service.serverAttachmentLimits[fixture.key.server] = try limits()
        fixture.service.isServerKnown = { _, _ in true }
        let channel = "f5000000-0000-4000-8000-000000000001"
        var messages = (0..<3).map { index in
            var message = F.message("fileless-\(index)", seq: index + 1)
            message.channelId = channel; message.authorAccountId = fixture.key.accountId
            return message
        }
        messages[2].deletedAt = "2026-10-06T13:00:00Z"
        let model = ChatTimelineW01Model(directory: directory, key: fixture.key, service: fixture.service)
        model.channel = channel; model.feed.messages = messages
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        func availability() -> [String: Bool] {
            let snapshot = adapter.snapshot(model: model, root: nil, members: [], mentionable: [], me: fixture.key.accountId,
                archived: false, ownerModel: nil, style: F.style(), now: F.day)
            return Dictionary(uniqueKeysWithValues: snapshot.rows.compactMap { row in
                guard case .message(let message) = row.payload else { return nil }
                XCTAssertTrue(message.content.message.attachments.isEmpty)
                XCTAssertTrue(message.content.attachments.availableFileIDs.isEmpty)
                return (message.content.message.id, message.content.attachments.available)
            })
        }
        let authorized = ["fileless-0": true, "fileless-1": true, "fileless-2": false]
        let unavailable = ["fileless-0": false, "fileless-1": false, "fileless-2": false]
        XCTAssertEqual(availability(), authorized, "Fileless rows retain the legacy attachment-container presence")
        let changed = expectation(description: "Owner capability remains an observed snapshot dependency")
        withObservationTracking { _ = availability() } onChange: { changed.fulfill() }
        fixture.service.serverCapabilities[fixture.key.server] = []
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(availability(), unavailable)
        fixture.service.serverCapabilities[fixture.key.server] = capabilities
        XCTAssertEqual(availability(), authorized, "A negative owner result cannot outlive one capture")
        try await fixture.store.queue.write { try $0.execute(sql: "UPDATE meta SET rights_in_doubt = 1 WHERE id = 1") }
        XCTAssertEqual(availability(), unavailable, "A positive owner result cannot survive live access loss")
        try await fixture.store.queue.write { try $0.execute(sql: "UPDATE meta SET rights_in_doubt = 0 WHERE id = 1") }
        XCTAssertEqual(availability(), authorized, "The next capture must re-read restored owner access")
        XCTAssertEqual(model.feed.messages, messages, "Access refresh does not need a synthetic message mutation")
    }

    private func limits() throws -> ChatAttachmentLimits {
        var limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        limits.dmSenderBytes = 30_000_000
        return limits
    }

    private func changedNumericLimits(_ original: ChatAttachmentLimits) -> ChatAttachmentLimits {
        var changed = original
        changed.dmSenderBytes = original.dmSenderBytes.map { $0 + 1 }
        changed.fileBytes += 1
        changed.messageFiles += 1
        changed.messageBytes += 1
        changed.pendingFiles += 1
        changed.pendingBytes += 1
        changed.uploadsPerAccount += 1
        changed.downloadsPerAccount += 1
        changed.uploadRequestSeconds += 1
        changed.imagePixels += 1
        changed.imageSide += 1
        changed.previewSide += 1
        changed.previewBytes += 1
        changed.draftTTLSeconds += 1
        changed.contextFiles += 1
        changed.contextBytes += 1
        return changed
    }

    private func files() -> [ChatAttachment] {
        [.init(attachmentId: "file", position: 0, name: "notes.txt", mime: "text/plain", size: 20, hasPreview: false),
         .init(attachmentId: "image", position: 1, name: "image.png", mime: "image/png", size: 200,
               hasPreview: true, width: 640, height: 320)]
    }

    private func content(_ message: ChatMessage, limits: ChatAttachmentLimits?, available: Bool = true,
                         fileIDs: Set<String> = ["file", "image"], pauseReason: String? = nil) -> S.MessageContent {
        let base = F.content(message)
        return .init(message: base.message, author: base.author, authorTooltip: base.authorTooltip, addresses: base.addresses,
            replyToText: base.replyToText, replySummary: base.replySummary, replyCount: base.replyCount,
            unreadReplyCount: base.unreadReplyCount, requestCount: base.requestCount, editing: base.editing,
            confirmation: base.confirmation, actions: base.actions, metadata: base.metadata,
            sources: base.sources, membershipHints: base.membershipHints,
            attachments: .init(limits: limits, available: available, availableFileIDs: fileIDs, pauseReason: pauseReason))
    }

    private func expected(_ content: S.MessageContent, generation: UInt64) -> S {
        F.expected(rows: [F.row(.topInset, .inset(16)),
            F.row(.dayBoundary(content.message.id), .day(F.day, label: "Today, Oct 6, 2026")),
            F.row(.message(content.message.id), .message(.init(content: content, startsGroup: true, inThread: false)),
                content: generation, layout: generation, visual: F.visual()),
            F.row(.bottomInset, .inset(20))], ids: [content.message.id], generation: generation)
    }
}
