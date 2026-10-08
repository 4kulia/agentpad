import AppKit
import Foundation
import GRDB
import ImageIO
import SwiftUI
import Vision
import XCTest
@testable import AgentPadKit

private final class AttachmentTestServer: @unchecked Sendable {
    let lock = NSLock()
    var rows: [String: [String: Any]] = [:]
    var bytes: [String: Data] = [:]
    var checking = false
    var failUpload = false
    var deny = false
    var refusedPath: String?
    var refusedStatus = 404
    var postError: String?
    var losePostReply = false
    var validatePosts = false
    var requestContent: Data?
    var downloads: Data = Data()
    func answer(_ request: URLRequest, _ body: Data) -> Result<ChatStubProtocol.Answer, URLError> {
        lock.lock(); defer { lock.unlock() }
        func reply(_ object: Any, status: Int = 200) -> Result<ChatStubProtocol.Answer, URLError> {
            .success(.init(status: status, body: try! JSONSerialization.data(withJSONObject: object)))
        }
        if deny { return reply(["error": "not_found"], status: 404) }
        let path = request.url!.path
        if path == refusedPath { return reply(["error": "opaque_access_error"], status: refusedStatus) }
        if path.contains("/requests/") {
            if path.contains("/attachments/") { return .success(.init(status: 200, body: downloads)) }
            if let requestContent { return .success(.init(status: 200, body: requestContent)) }
        }
        if path == "/v1/commands" {
            let command = try! JSONDecoder().decode(ChatCommandEnvelope.self, from: body)
            let id = command.args["attachment_id"]?.string ?? ""
            switch command.type {
            case "message.post_with_attachments":
                if let postError { return reply(["error": postError], status: 409) }
                if losePostReply { return .failure(URLError(.networkConnectionLost)) }
                if validatePosts, case .array(let ids) = command.args["attachment_ids"],
                   ids.contains(where: { rows[$0.string ?? ""]?["state"] as? String != "ready" }) {
                    return reply(["error": "attachment_not_ready"], status: 409)
                }
            case "attachment.prepare":
                if rows[id] == nil {
                    rows[id] = ["attachment_id": id, "state": "reserved", "name": command.args["name"]!.string!,
                                "size": command.args["size"]!.int!, "mime": command.args["mime"]!.string!, "has_preview": false,
                                "expires_at": "2099-01-01T00:00:00Z"]
                }
            case "attachment.complete":
                if rows[id]?["state"] as? String != "ready" { rows[id]?["state"] = "checking" }
            case "attachment.cancel": rows[id] = ["attachment_id": id, "state": "deleted", "error": "cancelled"]
            default: break
            }
            return reply(["events": [], "result": ["attachment_id": id]])
        }
        let pieces = path.split(separator: "/").map(String.init)
        if let index = pieces.firstIndex(of: "attachments"), pieces.count > index + 1 {
            let id = pieces[index + 1]
            if request.httpMethod == "PUT" {
                if failUpload { return reply(["error": "storage_unavailable"], status: 503) }
                bytes[id] = body; rows[id]?["state"] = "uploaded"
                return reply(["attachment_id": id])
            }
            if path.hasSuffix("/preview") || path.hasSuffix("/original") { return .success(.init(status: 200, body: downloads)) }
            if rows[id]?["state"] as? String == "checking", !checking { rows[id]?["state"] = "ready" }
            return reply(rows[id] ?? ["error": "not_found"], status: rows[id] == nil ? 404 : 200)
        }
        return reply(["events": [], "result": [:]])
    }
    func change(_ body: (AttachmentTestServer) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
}

@MainActor final class ChatAttachmentsTests: XCTestCase {
    private var root: URL!
    private var fixtures: [ChatChannelExecutionTests.Fixture] = []
    private var viewerStates: [TabState] = []
    private let channel = "f5000000-0000-4000-8000-000000000001"
    private let messageID = "f5000000-0000-4000-8000-000000000002"
    private let requestID = "f5000000-0000-4000-8000-000000000003"
    private let server = AttachmentTestServer()
    static let limitsJSON = #"{"file_bytes":10485760,"message_files":4,"message_bytes":20971520,"pending_files":8,"pending_bytes":104857600,"uploads_per_account":2,"downloads_per_account":4,"upload_request_seconds":150,"image_pixels":20000000,"image_side":10000,"preview_side":1280,"preview_bytes":524288,"draft_ttl_seconds":86400,"context_files":4,"context_bytes":20971520,"extensions":["png","jpg","jpeg","pdf","txt","md","csv","log","json"],"mime_types":["image/png","image/jpeg","application/pdf","text/plain","application/json"],"verification":"type_only"}"#
    private var limits: ChatAttachmentLimits { try! JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(Self.limitsJSON.utf8)) }
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("att-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ChatNotifications.badgeChanged = {}
        let server = server
        ChatStubProtocol.reset { server.answer($0, $1) }
    }
    override func tearDown() async throws {
        for f in fixtures { f.service.attachmentManagers.values.forEach { $0.revoke() }; f.sender?.hold(); await f.service.disconnect() }
        fixtures = []; viewerStates = []
        try await Task.sleep(for: .milliseconds(30))
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }
    private func fixture() async throws -> ChatChannelExecutionTests.Fixture {
        let f = try await ChatChannelExecutionTests.Fixture(root: root.appendingPathComponent(UUID().uuidString))
        fixtures.append(f)
        f.service.serverCapabilities[f.key.server] = ["chat.attachments", "chat.attachments_context", "chat.channel_ux1"]
        f.service.serverAttachmentLimits[f.key.server] = limits
        f.service.isServerKnown = { _, _ in true }
        return f
    }
    private func manager(_ f: ChatChannelExecutionTests.Fixture) throws -> ChatAttachmentManager {
        let manager = try XCTUnwrap(f.service.attachments(f.key)); manager.pollDelay = { _ in .milliseconds(15) }; return manager
    }
    private func viewer(_ f: ChatChannelExecutionTests.Fixture, message: ChatMessage, file: ChatAttachment) -> AttachmentViewerModel {
        let state = TabState(route: .viewer(OrgKey(f.key), channelID: message.channelId, messageID: message.id, attachmentID: file.id))
        viewerStates.append(state)
        return AttachmentViewerModel(state: state, tabs: CompositionTabs(router: TabRouter(), chat: f.service, team: f.teamService))
    }
    private func model(_ f: ChatChannelExecutionTests.Fixture) -> ChatChannelModel {
        let model = ChatChannelModel(key: f.key, channel: channel); model.service = f.service; model.follow(f.store); return model
    }
    private func read<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    private func write<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try queue.write(body) }
    private func wait(_ condition: () throws -> Bool) async throws {
        let until = ContinuousClock.now + .seconds(5)
        while try !condition() { if ContinuousClock.now >= until { XCTFail("timed out"); return }; try await Task.sleep(for: .milliseconds(10)) }
    }
    @discardableResult private func message(_ f: ChatChannelExecutionTests.Fixture, file: ChatAttachment, revision: Int = 1, deleted: Bool = false, only: Bool = false, id: String? = nil) throws -> ChatMessage {
        let messageID = id ?? messageID
        var fields: [String: Any] = ["message_id": messageID, "channel_id": channel, "author_account_id": f.key.accountId,
            "text": deleted ? "" : (only ? "Вложения" : "Screenshot and investigation notes"), "revision": revision, "seq": 1,
            "created_at": "2026-10-07T12:00:00Z", "attachments": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(file))], "attachment_only": only]
        if deleted { fields["deleted_at"] = "2026-10-07T12:01:00Z" }
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: fields))
        try f.store.queue.write { _ = try ChatMessages.write($0, wire) }
        return try read(f.store.queue) { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM messages WHERE message_id = ?", arguments: [messageID])).mapMessage() }
    }
    private func file(_ data: Data = Data("notes".utf8), name: String = "notes.txt") throws -> ChatAttachment {
        try ChatAttachmentStorage.descriptor(data: data, name: name, limits: limits)
    }

    private func sender(_ f: ChatChannelExecutionTests.Fixture) throws -> ChatOutbox {
        let session = try XCTUnwrap(f.service.orgSessions[f.key])
        session.startSending(api: f.service.makeAPI(f.key.server), token: "test-only", sessionId: "s-anna", journal: nil, onUnauthorized: {})
        let outbox = try XCTUnwrap(session.outbox)
        f.sender = outbox
        f.service.configureCommandCapabilities(outbox, key: f.key)
        outbox.onSent = { f.service.commandAnswered(f.key, $0, .taken($1)) }
        outbox.onPermanentFailure = { f.service.commandAnswered(f.key, $0, .refused($1)) }
        return outbox
    }

    private func savedPost(_ f: ChatChannelExecutionTests.Fixture) async throws -> (ChatAttachmentManager, ChatAttachmentDraft, String) {
        let manager = try manager(f), model = model(f)
        try manager.add(data: Data("saved original".utf8), name: "saved.txt", channel: channel, root: nil)
        try await wait { manager.drafts.first?.state == .ready }
        let draft = try XCTUnwrap(manager.drafts.first)
        let id = try f.service.sendChannel(f.key, channel: channel, root: nil, text: "", mentions: [], agents: [],
            draftVersion: XCTUnwrap(model.draftVersion(root: nil)), mentionOnly: true)
        manager.reconcile()
        XCTAssertTrue(manager.drafts.isEmpty)
        XCTAssertEqual(manager.queued.map(\.id), [draft.id])
        manager.remove(draft, cancelOnServer: false)
        manager.retry(draft)
        XCTAssertEqual(manager.queued.map(\.id), [draft.id], "A stale composer action cannot take a post's ownership")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try manager.storage.url(f.key, id: draft.id).path))
        return (manager, draft, id)
    }

    func testFilePanelKeepsOriginatingChannelOrThreadComposerAndRejectsStaleDraft() async throws {
        let f = try await fixture(), manager = try manager(f), model = model(f)
        let thread = UUID().uuidString.lowercased(), otherThread = UUID().uuidString.lowercased()
        let channelFile = root.appendingPathComponent("channel.txt"), threadFile = root.appendingPathComponent("thread.txt")
        try Data("channel file".utf8).write(to: channelFile); try Data("thread file".utf8).write(to: threadFile)
        model.saveDraft("Channel draft", root: nil); model.saveDraft("Thread draft", root: thread)
        model.openThread(thread)
        let channelSelection = try XCTUnwrap(ChatComposerFileSelection(model: model, root: nil, attachments: manager))
        let threadSelection = try XCTUnwrap(ChatComposerFileSelection(model: model, root: thread, attachments: manager))
        let channelImported = expectation(description: "Channel files imported"), threadImported = expectation(description: "Thread files imported")
        XCTAssertTrue(try channelSelection.importFiles([channelFile]) { error in XCTAssertNil(error); channelImported.fulfill() })
        // A navigation change must never retarget the captured thread's files.
        model.openThread(otherThread)
        XCTAssertTrue(try threadSelection.importFiles([threadFile]) { error in XCTAssertNil(error); threadImported.fulfill() })
        await fulfillment(of: [channelImported, threadImported], timeout: 5)
        try await wait { manager.files(channel: self.channel, root: nil).count == 1 && manager.files(channel: self.channel, root: thread).count == 1 }
        XCTAssertEqual(manager.files(channel: channel, root: nil).map { $0.file.name }, ["channel.txt"])
        XCTAssertEqual(manager.files(channel: channel, root: thread).map { $0.file.name }, ["thread.txt"])
        XCTAssertTrue(manager.files(channel: channel, root: otherThread).isEmpty)
        XCTAssertEqual(model.draft(root: nil), "Channel draft"); XCTAssertEqual(model.draft(root: thread), "Thread draft")

        let stale = try XCTUnwrap(ChatComposerFileSelection(model: model, root: nil, attachments: manager))
        model.saveDraft("A newer edit", root: nil)
        XCTAssertFalse(try stale.importFiles([channelFile]))
        let revoked = try XCTUnwrap(ChatComposerFileSelection(model: model, root: nil, attachments: manager))
        try f.store.putRightsInDoubt()
        XCTAssertFalse(try revoked.importFiles([channelFile]))
    }

    private func otherChannel(_ f: ChatChannelExecutionTests.Fixture) throws -> String {
        let id = UUID().uuidString.lowercased()
        try f.write("INSERT INTO channels (channel_id, team_id, name, archived, version, stamp) SELECT ?, team_id, 'other', 0, 1, stamp FROM channels WHERE channel_id = ?", [id, channel])
        return id
    }

    func testOwnershipArchiveRefusesRetryAndEndsRenewalWithoutBlockingOtherChannel() async throws {
        for archiveDuringRetry in [false, true] {
            let f = try await fixture()
            let (manager, draft, id) = try await savedPost(f)
            let outbox = try sender(f)
            server.change { $0.postError = "attachment_expired" }
            outbox.allow(connection: 1, generation: "g1")
            try await wait { try f.store.outbox.commands().first?.state == .failed }
            outbox.hold()
            server.change { $0.postError = nil; $0.checking = true }
            if archiveDuringRetry {
                try f.service.retry(f.key, messageId: id)
                try await wait { manager.queued.first?.state == .checking }
            }
            let owned = try read(f.store.queue) { try ChatAttachments.drafts($0, includingQueued: true) }
            let active = try otherChannel(f)
            try f.write("UPDATE channels SET archived = 1 WHERE channel_id = ?", [channel])
            let row = try XCTUnwrap(model(f).message(id))
            XCTAssertFalse(f.service.canRetryPost(f.key, row: row))
            // The entry point itself rejects stale UI clicks, before observation.
            let original = try XCTUnwrap(f.store.outbox.commands().last)
            XCTAssertThrowsError(try f.service.retryAttachmentPost(f.key, row: row, original: original))
            if !archiveDuringRetry { XCTAssertThrowsError(try f.service.retry(f.key, messageId: id)) }
            manager.reconcile()
            server.change { $0.checking = false }
            XCTAssertEqual(model(f).message(id)?.localState, .failed)
            XCTAssertEqual(model(f).message(id)?.localError, "channel_archived")
            XCTAssertTrue(manager.queued.allSatisfy { $0.state == .failed })
            XCTAssertFalse(try f.store.outbox.commands().contains { $0.state == .pending })
            XCTAssertEqual(try Data(contentsOf: manager.storage.url(f.key, id: XCTUnwrap(owned.first).id)), Data("saved original".utf8))
            let textID = try f.service.post(f.key, channel: active, root: nil, text: "still sending", mentions: [])
            outbox.allow(connection: 2, generation: "g1")
            try await wait { try f.store.outbox.commands().first { ChatService.args($0)["message_id"]?.string == textID }?.state == .sent }
            XCTAssertEqual(model(f).message(id)?.localState, .failed, "Late uploads cannot revive a terminal owner")
            try f.service.discard(f.key, messageId: id)
            XCTAssertTrue(manager.queued.isEmpty)
            for file in owned + [draft] { XCTAssertFalse(FileManager.default.fileExists(atPath: try manager.storage.url(f.key, id: file.id).path)) }
        }
    }

    func testOwnershipDisconnectAndCacheDeletionRemoveDirectoryWithoutManager() async throws {
        for disconnect in [true, false] {
            for opened in [true, false] {
                let f = try await fixture(), bytes = Data("saved locally".utf8)
                let storage = f.service.files.attachmentStorage
                let draft = ChatAttachmentDraft(file: try file(bytes), messageId: messageID, channel: channel, root: "",
                    session: "s-anna", generation: "g1", sha256: ChatAttachments.digest(bytes), createdAt: Date(), expiresAt: .distantFuture)
                try storage.save(bytes, key: f.key, id: draft.id)
                try write(f.store.queue) { try ChatAttachments.put($0, draft) }
                let other = ChatOrgKey(server: f.key.server, accountId: "another-account", orgId: "another-org")
                try storage.save(bytes, key: other, id: draft.id)
                if opened { _ = try manager(f) }
                else { XCTAssertNil(f.service.attachmentManagers[f.key]) }
                if disconnect { await f.service.disconnect() }
                else { f.service.membershipLost(f.key) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: storage.directory(f.key).path), "disconnect=\(disconnect), manager=\(opened)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.service.files.cacheURL(f.key).path))
                XCTAssertNil(f.service.attachmentManagers[f.key])
                XCTAssertEqual(try Data(contentsOf: storage.url(other, id: draft.id)), bytes)
                try await Task.sleep(for: .milliseconds(40))
                XCTAssertFalse(FileManager.default.fileExists(atPath: storage.directory(f.key).path), "A late import/upload must not restore erased bytes")
            }
        }
    }

    func testOwnershipUnconfirmedGenerationIsNotSentAndCanDeleteWithoutBlockingQueue() async throws {
        let f = try await fixture()
        let (first, draft, id) = try await savedPost(f)
        let original = try XCTUnwrap(f.store.outbox.commands().first)
        let team = try read(f.store.queue) { try XCTUnwrap(String.fetchOne($0, sql: "SELECT team_id FROM channels WHERE channel_id = ?", arguments: [channel])) }
        let outbox = try sender(f)
        try outbox.generationChanged()
        try f.store.beginGeneration("g2")
        try f.store.apply(ChatSnapshot(cursors: [:], channels: [
            .init(channelId: channel, teamId: team, name: "billing", archived: false, version: 1)
        ]), confirmsRights: "s-anna")
        try f.store.endChannelsRead(since: 0, seen: [channel])
        try f.store.finishGeneration("g2")
        first.suspend(); f.service.attachmentManagers[f.key] = nil
        // Recovery runs even before a composer has created its manager.
        f.service.resendPosts(f.key)
        let row = try XCTUnwrap(model(f).message(id))
        XCTAssertEqual(row.localState, .failed)
        XCTAssertEqual(row.localError, "attachment_unconfirmed")
        XCTAssertFalse(f.service.canRetryPost(f.key, row: row))
        XCTAssertThrowsError(try f.service.retry(f.key, messageId: id))
        XCTAssertEqual(try f.store.outbox.commands().count, 1)
        XCTAssertEqual(try f.store.outbox.commands().first?.state, .unconfirmed)
        XCTAssertEqual(try f.store.outbox.commands().first?.bodyBytes, original.bodyBytes)
        let manager = try manager(f)
        XCTAssertEqual(manager.queued.first?.state, .failed)
        XCTAssertTrue(manager.drafts.isEmpty, "Send transferred the single owner to the post")
        XCTAssertEqual(try Data(contentsOf: manager.storage.url(f.key, id: draft.id)), Data("saved original".utf8))
        let textID = try f.service.post(f.key, channel: try otherChannel(f), root: nil, text: "new generation", mentions: [])
        outbox.allow(connection: 2, generation: "g2"); outbox.resume()
        try await wait { try f.store.outbox.commands().first { ChatService.args($0)["message_id"]?.string == textID }?.state == .sent }
        XCTAssertFalse(ChatStubProtocol.seen.contains { $0.body == original.bodyBytes })
        manager.suspend(); f.service.attachmentManagers[f.key] = nil
        try f.service.discard(f.key, messageId: id)
        XCTAssertNil(model(f).message(id))
        XCTAssertTrue(try read(f.store.queue) { try ChatAttachments.drafts($0, includingQueued: true).isEmpty })
        XCTAssertFalse(FileManager.default.fileExists(atPath: try manager.storage.url(f.key, id: draft.id).path))
    }

    func testOwnershipExpiredWithoutRenewalIsTerminalAndReleasesQuotaOnDelete() async throws {
        for queued in [false, true] {
            let f = try await fixture(), manager = try manager(f)
            let id: String?
            if queued { id = try await savedPost(f).2 }
            else {
                try manager.add(data: Data("saved original".utf8), name: "saved.txt", channel: channel, root: nil)
                try await wait { manager.drafts.first?.state == .ready }
                id = nil
            }
            f.service.serverCapabilities[f.key.server] = []
            try write(f.store.queue) { db in
                for var file in try ChatAttachments.drafts(db, includingQueued: true) {
                    file.expiresAt = .distantPast; file.state = .waiting
                    try ChatAttachments.put(db, file)
                }
            }
            manager.reconcile()
            let file = try XCTUnwrap((manager.drafts + manager.queued).first)
            XCTAssertEqual(file.state, .failed)
            XCTAssertNotNil(file.problem)
            if let id {
                XCTAssertEqual(model(f).message(id)?.localState, .failed)
                XCTAssertEqual(try f.store.outbox.commands().first?.state, .failed)
                let outbox = try sender(f)
                let textID = try f.service.post(f.key, channel: try otherChannel(f), root: nil, text: "after expiry", mentions: [])
                outbox.allow(connection: 1, generation: "g1")
                try await wait { try f.store.outbox.commands().first { ChatService.args($0)["message_id"]?.string == textID }?.state == .sent }
                try f.service.discard(f.key, messageId: id)
            } else { manager.remove(file) }
            XCTAssertTrue(try read(f.store.queue) { try ChatAttachments.drafts($0, includingQueued: true).isEmpty })
            XCTAssertFalse(FileManager.default.fileExists(atPath: try manager.storage.url(f.key, id: file.id).path))
        }
    }

    func testOwnershipArchivedChannelAndThreadShowSavedFilesWithDeleteAndReuseQuota() async throws {
        let f = try await fixture(), manager = try manager(f)
        var small = limits; small.pendingFiles = 2; small.pendingBytes = 10 + 2 * small.previewBytes
        f.service.serverAttachmentLimits[f.key.server] = small
        try manager.add(data: Data("12345".utf8), name: "channel-saved.txt", channel: channel, root: nil)
        try manager.add(data: Data("67890".utf8), name: "thread-saved.txt", channel: channel, root: messageID)
        try await wait { manager.drafts.count == 2 && manager.drafts.allSatisfy { $0.state == .ready } }
        let owned = manager.drafts, active = try otherChannel(f)
        try f.write("UPDATE channels SET archived = 1 WHERE channel_id = ?", [channel])
        manager.reconcile()
        XCTAssertTrue(manager.drafts.allSatisfy { $0.state == .failed })
        XCTAssertThrowsError(try manager.add(data: Data("x".utf8), name: "next.txt", channel: active, root: nil))
        for draft in manager.drafts {
            XCTAssertFalse(manager.canRetry(draft))
            manager.retry(draft)
        }
        XCTAssertTrue(manager.drafts.allSatisfy { $0.state == .failed })
        let team = try read(f.store.queue) { try XCTUnwrap(String.fetchOne($0, sql: "SELECT team_id FROM channels WHERE channel_id = ?", arguments: [channel])) }
        let card = ChatChannelCard(channelId: channel, teamId: team, name: "billing", archived: true, version: 2)
        let conversation = ChatChannelSession()
        conversation.update(.ready(card, team: "Billing", offline: false), key: f.key, store: f.store, service: f.service)
        let model = try XCTUnwrap(conversation.model)
        model.openThread(messageID)
        let host = NSHostingView(rootView: ChatChannelView(card: card, team: "Billing", offline: false, key: f.key, conversation: conversation)
            .frame(width: 1120, height: 700).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        for name in ["channel-saved.txt", "thread-saved.txt"] {
            let words = try await renderedOwnershipText(host)
            let text = words.map { $0.0 }.joined(separator: " ")
            XCTAssertTrue(text.contains(name), text)
            XCTAssertTrue(text.contains("Not sent"), text)
            XCTAssertFalse(text.contains("Retry"), text)
            // Click the production Delete action in the pane containing this file.
            let file = try XCTUnwrap(words.first { $0.0.contains(name) }, text)
            let buttons = words.filter { $0.0.contains("Delete") && $0.1.midX > file.1.midX }
            let button = try XCTUnwrap(buttons.min { $0.1.midX < $1.1.midX }, text)
            let x = button.1.midX * host.bounds.width
            let y = (host.isFlipped ? 1 - button.1.midY : button.1.midY) * host.bounds.height
            let point = host.convert(NSPoint(x: x, y: y), to: nil)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: true)
            window.sendEvent(try event(.leftMouseDown))
            if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { window.sendEvent(up) }
            try await wait { !manager.drafts.contains { $0.file.name == name } }
        }
        for file in owned { XCTAssertFalse(FileManager.default.fileExists(atPath: try manager.storage.url(f.key, id: file.id).path)) }
        try manager.add(data: Data("abcde".utf8), name: "next.txt", channel: active, root: nil)
        try await wait { manager.files(channel: active, root: nil).first?.state == .ready }
    }

    private func renderedOwnershipText(_ host: NSView) async throws -> [(String, CGRect)] {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { result in result.topCandidates(1).first.map { ($0.string, result.boundingBox) } }
    }

    func testCompatibility1CapabilityLossKeepsDraftBytesAndContextSelection() async throws {
        let f = try await fixture(), manager = try manager(f), model = model(f), bytes = Data("clipboard bytes".utf8)
        try manager.add(data: bytes, name: "notes.txt", channel: channel, root: nil)
        try await wait { manager.drafts.first?.state == .ready }
        var draft = try XCTUnwrap(manager.drafts.first)
        let selection = ChatAttachmentManifest(file: draft.file, messageId: draft.messageId, revision: 1, sha256: draft.sha256)
        model.saveDraft("caption", root: nil, attachmentSelection: [selection])
        f.service.serverCapabilities[f.key.server] = []
        draft.expiresAt = .distantPast
        try write(f.store.queue) { try ChatAttachments.put($0, draft) }
        manager.reconcile()
        XCTAssertEqual(manager.files(channel: channel, root: nil).map(\.id), [draft.id])
        XCTAssertEqual(model.composerDraft(root: nil).attachmentSelection, [selection])
        XCTAssertEqual(try Data(contentsOf: manager.storage.url(f.key, id: draft.id)), bytes)
        XCTAssertEqual(manager.pauseReason, ChatAttachmentError.paused.localizedDescription)
        XCTAssertThrowsError(try f.service.sendChannel(f.key, channel: channel, root: nil, text: "caption", mentions: [], agents: [],
            draftVersion: XCTUnwrap(model.draftVersion(root: nil)), mentionOnly: true)) {
            XCTAssertEqual($0 as? ChatAttachmentError, .paused)
        }
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        // A backup restore is unknown access, not a confirmed revocation.
        try f.store.beginGeneration("g2")
        manager.reconcile()
        XCTAssertEqual(try read(f.store.queue) { try ChatAttachments.drafts($0).map(\.id) }, [draft.id])
        XCTAssertEqual(model.composerDraft(root: nil).attachmentSelection, [selection])
        XCTAssertEqual(try Data(contentsOf: manager.storage.url(f.key, id: draft.id)), bytes)
    }

    func testCompatibility1ContextOnlySelectionSurvivesCapabilityRollback() async throws {
        for capabilities: Set<String> in [[], ["chat.channel_ux1"], ["chat.channel_ux1", "chat.attachments"]] {
            let f = try await fixture(), manager = try manager(f), model = model(f)
            let source = try message(f, file: file())
            let selected = ChatAttachmentManifest(file: source.attachments[0], messageId: source.id,
                revision: source.revision, sha256: ChatAttachments.digest(Data("notes".utf8)))
            let text = "@billing@anna read the selected file"
            model.saveDraft(text, root: nil, contextIds: [source.id], attachmentSelection: [selected])
            let version = try XCTUnwrap(model.draftVersion(root: nil))
            let agents = try f.store.channelAgents(channel)
            f.service.serverCapabilities[f.key.server] = capabilities
            manager.reconcile()
            XCTAssertThrowsError(try f.service.sendChannel(f.key, channel: channel, root: nil, text: text, mentions: [],
                agents: agents, draftVersion: version, mentionOnly: false, additionalContext: [source])) {
                XCTAssertEqual($0 as? ChatAttachmentError, .paused)
            }
            XCTAssertEqual(model.composerDraft(root: nil).attachmentSelection, [selected])
            XCTAssertEqual(model.draftVersion(root: nil), version)
            XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        }
    }

    func testCompatibility2QueuedBytesSurviveRestartExpiryAndRenewOnRetryUntilACK() async throws {
        let f = try await fixture(), first = try manager(f), model = model(f), bytes = Data("retained original".utf8)
        try first.add(data: bytes, name: "notes.txt", channel: channel, root: nil)
        let secondBytes = Data("second retained original".utf8)
        try first.add(data: secondBytes, name: "second.txt", channel: channel, root: nil)
        try await wait { first.drafts.count == 2 && first.drafts.allSatisfy { $0.state == .ready } }
        let draft = try XCTUnwrap(first.drafts.first)
        let second = try XCTUnwrap(first.drafts.last)
        let selection = ChatAttachmentManifest(file: draft.file, messageId: draft.messageId, revision: 1, sha256: draft.sha256)
        model.saveDraft("@billing@anna read", root: nil, attachmentSelection: [selection])
        let id = try f.service.sendChannel(f.key, channel: channel, root: nil, text: model.draft(root: nil), mentions: [], agents: f.store.channelAgents(channel),
            draftVersion: XCTUnwrap(model.draftVersion(root: nil)), mentionOnly: false)
        first.reconcile()
        XCTAssertTrue(first.files(channel: channel, root: nil).isEmpty)
        XCTAssertEqual(try Data(contentsOf: first.storage.url(f.key, id: draft.id)), bytes)
        XCTAssertEqual(try Data(contentsOf: first.storage.url(f.key, id: second.id)), secondBytes)
        first.suspend(); f.service.attachmentManagers[f.key] = nil
        let manager = try manager(f)
        try write(f.store.queue) { db in
            for var expired in try ChatAttachments.drafts(db, includingQueued: true) {
                expired.expiresAt = .distantPast
                try ChatAttachments.put(db, expired)
            }
        }
        f.service.serverCapabilities[f.key.server] = []
        manager.reconcile()
        XCTAssertEqual(try Data(contentsOf: manager.storage.url(f.key, id: draft.id)), bytes)
        let outbox = try sender(f)
        server.change { $0.postError = "attachment_expired"; $0.validatePosts = true }
        f.service.serverCapabilities[f.key.server] = ["chat.attachments"]
        manager.reconcile(); outbox.allow(connection: 1, generation: "g1")
        try await wait { try f.store.outbox.commands().first?.state == .failed }
        let original = try XCTUnwrap(f.store.outbox.commands().first)
        XCTAssertEqual(original.error, "attachment_expired")
        XCTAssertEqual(try Data(contentsOf: manager.storage.url(f.key, id: draft.id)), bytes)
        server.change { $0.postError = nil; $0.checking = true }
        try f.service.retry(f.key, messageId: id)
        let retried = try XCTUnwrap(f.store.outbox.commands().last)
        XCTAssertNotEqual(retried.commandId, original.commandId)
        XCTAssertNotEqual(ChatService.args(retried)["attachment_ids"], ChatService.args(original)["attachment_ids"])
        let owned = try read(f.store.queue) { try ChatAttachments.drafts($0, includingQueued: true) }
        let renewed = try XCTUnwrap(owned.first)
        XCTAssertEqual(owned.count, 2)
        XCTAssertEqual(owned.map(\.file.name), ["notes.txt", "second.txt"])
        XCTAssertTrue(Set(owned.map(\.id)).isDisjoint(with: [draft.id, second.id]))
        let manifestJSON = try read(f.store.queue) { try XCTUnwrap(String.fetchOne($0, sql: "SELECT attachment_manifest FROM channel_call_intents")) }
        XCTAssertEqual(try JSONDecoder().decode([ChatAttachmentManifest].self, from: Data(manifestJSON.utf8)).map(\.id), [renewed.id])
        XCTAssertEqual(try read(f.store.queue) { try String.fetchOne($0, sql: "SELECT command_id FROM channel_sends") }, retried.commandId)
        try await wait { ChatStubProtocol.seen.contains { $0.request.httpMethod == "PUT" && $0.request.url?.path.contains(renewed.id) == true } }
        XCTAssertEqual(try Data(contentsOf: manager.storage.url(f.key, id: renewed.id)), bytes)
        XCTAssertFalse(ChatStubProtocol.seen.contains { $0.body == retried.bodyBytes }, "Post must wait for renewed files to be ready")
        server.change { $0.checking = false }
        try await wait { try f.store.outbox.commands().last?.state == .sent }
        manager.reconcile()
        XCTAssertEqual(try read(f.store.queue) { try Int.fetchOne($0, sql: "SELECT count(*) FROM attachment_drafts") }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try manager.storage.url(f.key, id: renewed.id).path))
        XCTAssertEqual(try f.store.outbox.commands().first?.bodyBytes, original.bodyBytes)
        XCTAssertTrue(ChatStubProtocol.seen.contains { $0.request.httpMethod == "PUT" && $0.body == bytes && $0.request.url?.path.contains(renewed.id) == true })
        XCTAssertTrue(ChatStubProtocol.seen.contains { $0.request.httpMethod == "PUT" && $0.body == secondBytes && $0.request.url?.path.contains(owned[1].id) == true })
        for item in [draft, second] + owned {
            XCTAssertFalse(FileManager.default.fileExists(atPath: try manager.storage.url(f.key, id: item.id).path))
        }
    }

    func testCompatibility2LostACKReplaysExactCommandAndDiscardReleasesBytes() async throws {
        let f = try await fixture(), manager = try manager(f), model = model(f), bytes = Data("saved".utf8)
        try manager.add(data: bytes, name: "notes.txt", channel: channel, root: nil)
        try await wait { manager.drafts.first?.state == .ready }
        let draft = try XCTUnwrap(manager.drafts.first)
        let id = try f.service.sendChannel(f.key, channel: channel, root: nil, text: "", mentions: [], agents: [],
            draftVersion: XCTUnwrap(model.draftVersion(root: nil)), mentionOnly: true)
        server.change { $0.losePostReply = true }
        let outbox = try sender(f); outbox.retryDelay = { _ in 60 }
        outbox.allow(connection: 1, generation: "g1")
        try await wait { try f.store.outbox.commands().first?.attempts == 1 }
        outbox.hold()
        let original = try XCTUnwrap(f.store.outbox.commands().first)
        let json = try read(f.store.queue) { try XCTUnwrap(String.fetchOne($0, sql: "SELECT body FROM attachment_drafts")) }
        var expired = try JSONDecoder().decode(ChatAttachmentDraft.self, from: Data(json.utf8)); expired.expiresAt = .distantPast
        try write(f.store.queue) { try ChatAttachments.put($0, expired) }
        manager.reconcile()
        XCTAssertEqual(try Data(contentsOf: manager.storage.url(f.key, id: draft.id)), bytes)
        XCTAssertEqual(try f.store.outbox.commands().first?.bodyBytes, original.bodyBytes)
        try f.write("UPDATE outbox SET next_attempt_at = NULL")
        outbox.allow(connection: 2, generation: "g1")
        try await wait { try f.store.outbox.commands().first?.attempts == 2 }
        outbox.hold()
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.body == original.bodyBytes }.count, 2)
        // An explicit user discard, after a terminal refusal, releases ownership.
        try f.write("UPDATE outbox SET state = 'failed', error = 'attachment_expired'")
        f.service.commandAnswered(f.key, original, .refused("attachment_expired"))
        try f.service.discard(f.key, messageId: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try manager.storage.url(f.key, id: draft.id).path))
    }

    func testCompatibility2ConfirmedMessageOrRevocationReleasesQueuedBytes() async throws {
        for revoke in [false, true] {
            let f = try await fixture(), manager = try manager(f), model = model(f)
            try manager.add(data: Data("saved".utf8), name: "notes.txt", channel: channel, root: nil)
            try await wait { manager.drafts.first?.state == .ready }
            let draft = try XCTUnwrap(manager.drafts.first)
            let id = try f.service.sendChannel(f.key, channel: channel, root: nil, text: "", mentions: [], agents: [],
                draftVersion: XCTUnwrap(model.draftVersion(root: nil)), mentionOnly: true)
            manager.reconcile()
            XCTAssertTrue(FileManager.default.fileExists(atPath: try manager.storage.url(f.key, id: draft.id).path))
            if revoke { try f.write("UPDATE teams SET mine = 0") }
            else { _ = try message(f, file: draft.file, id: id) }
            manager.reconcile()
            XCTAssertFalse(FileManager.default.fileExists(atPath: try manager.storage.url(f.key, id: draft.id).path))
        }
    }

    func testCompatibility4EmptyV2ManifestDeclinesPermanentlyWithoutLaunching() async throws {
        for action in ["receive", "notify", "allow"] {
            let f = try await fixture()
            let state = action == "receive" ? "submitted" : "awaiting_decision"
            try f.move(state, 2)
            try f.write("UPDATE requests SET conditions_version = 2")
            var content = f.content(); content.attachments = []
            server.change { $0.requestContent = try! JSONEncoder().encode(content) }
            let request = try f.request()
            XCTAssertFalse(content.validates(request, references: nil))
            if action == "allow" {
                let reason = await f.owner.decideChannel(f.key, requestId: requestID, allow: true, reason: nil)
                XCTAssertEqual(reason, ChatAttachmentError.contextLost.localizedDescription)
            } else {
                let result = await f.owner.perform(state == "submitted" ? .receive : .notifyDecision, request: request, key: f.key)
                XCTAssertEqual(result, .done)
            }
            let commands = try f.journal.runCommands(f.key).commands()
            let decline = try XCTUnwrap(commands.first { $0.type == "request.decide" })
            XCTAssertEqual(ChatService.args(decline)["allow"], .bool(false))
            XCTAssertTrue(ChatService.args(decline)["reason"]?.string?.contains("context file is no longer available") == true)
            XCTAssertNil(try f.journal.approval(f.key, requestId: requestID))
            XCTAssertNil(try read(f.store.queue) { try ChatChannelContent.read($0, request: requestID) })
            if state == "submitted" { XCTAssertNotNil(decline.dependsOn) }
        }
    }

    func testCompatibility4DeclineDoesNotFetchContextButStillChecksAccess() async throws {
        let f = try await fixture()
        try f.move("awaiting_decision", 2)
        try f.write("UPDATE requests SET conditions_version = 2")
        server.change { $0.deny = true }
        let before = ChatStubProtocol.seen.count
        let result = await f.owner.decideChannel(f.key, requestId: requestID, allow: false, reason: "No thanks")
        XCTAssertNil(result)
        XCTAssertEqual(ChatStubProtocol.seen.count, before)
        let decline = try XCTUnwrap(f.journal.runCommands(f.key).commands().first { $0.type == "request.decide" })
        XCTAssertEqual(ChatService.args(decline)["reason"], .string("No thanks"))
        try f.write("UPDATE teams SET mine = 0")
        let denied = await f.owner.decideChannel(f.key, requestId: requestID, allow: false, reason: nil)
        XCTAssertNotNil(denied)
        XCTAssertEqual(ChatStubProtocol.seen.count, before)
    }

    func testCapabilityAndLimitsFailClosed() async throws {
        let f = try await fixture(), manager = try manager(f)
        XCTAssertNotNil(manager.limits)
        f.service.serverCapabilities[f.key.server] = []
        XCTAssertNil(manager.limits)
        XCTAssertThrowsError(try manager.add(data: Data("a".utf8), name: "a.txt", channel: channel, root: nil))
        f.service.serverCapabilities[f.key.server] = ["chat.attachments"]
        f.service.serverAttachmentLimits[f.key.server] = nil
        XCTAssertNil(manager.limits)
        var bad = limits; bad.messageFiles = 0
        f.service.serverAttachmentLimits[f.key.server] = bad
        XCTAssertNil(manager.limits)
    }
    func testStorageCopiesOwnBytesPermissionsAndRejectsUnsafeInputs() throws {
        let key = ChatOrgKey(server: try ChatServerAddress(parsing: "https://example.test"), accountId: "a", orgId: "o")
        let storage = ChatAttachmentStorage(root: root.appendingPathComponent("private"))
        let source = root.appendingPathComponent("notes.txt"), data = Data("private notes".utf8), id = UUID().uuidString
        try data.write(to: source)
        try storage.save(ChatAttachmentStorage.read(source, limit: limits.fileBytes), key: key, id: id)
        try Data("changed".utf8).write(to: source)
        let saved = try storage.url(key, id: id)
        XCTAssertEqual(try Data(contentsOf: saved), data)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: storage.directory(key).path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        for path in [link, root!, URL(string: "https://example.test/file.txt")!] { XCTAssertThrowsError(try ChatAttachmentStorage.read(path, limit: 100)) }
        XCTAssertThrowsError(try storage.url(key, id: "../escape"))
        XCTAssertThrowsError(try file(Data(), name: "empty.txt"))
        XCTAssertThrowsError(try file(Data([0, 2, 4]), name: "x.txt"))
        XCTAssertThrowsError(try file(Data("hello".utf8), name: "x.png"))
        XCTAssertThrowsError(try file(Data("{}".utf8), name: "../x.json"))
        XCTAssertThrowsError(try file(Data("{}".utf8), name: "x\u{202e}.json"))
        XCTAssertThrowsError(try file(Data("<svg/>".utf8), name: "x.svg"))
        XCTAssertThrowsError(try file(Data("bad json".utf8), name: "x.json"))
        storage.remove(key, id: id); XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
    }
    func testFolderBoundaryResolvesSymlinksAndAllowsNarrowProjects() throws {
        let home = root.appendingPathComponent("home"), temp = root.appendingPathComponent("tmp"), data = home.appendingPathComponent("Library/Application Support/AgentPad")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        for bad in ["/", root.path, home.path, home.appendingPathComponent("Library").path, data.path, temp.path, alias.path] {
            XCTAssertThrowsError(try ChatAttachmentStorage.checkFolders([bad], data: data, temporary: temp, home: home), bad)
        }
        XCTAssertNoThrow(try ChatAttachmentStorage.checkFolders([home.appendingPathComponent("project").path, temp.appendingPathComponent("project").path], data: data, temporary: temp, home: home))
    }
    func testReview1ManagedStorageDescendantsAndOtherCallDirectoriesAreDenied() async throws {
        let f = try await fixture()
        let shared = ChatAttachmentStorage.standard.root
        let alias = root.appendingPathComponent("shared-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shared)
        let otherCall = FileManager.default.temporaryDirectory.appendingPathComponent("agentpad-call-" + UUID().uuidString.lowercased())
        try ChatAttachmentStorage.secureDirectory(otherCall)
        defer { try? FileManager.default.removeItem(at: otherCall) }
        try ChatAttachmentStorage.write(Data(), to: otherCall.appendingPathComponent(".agentpad-attachment-call"))
        for path in [shared, shared.appendingPathComponent("organization"), alias, otherCall, otherCall.appendingPathComponent("nested")] {
            XCTAssertThrowsError(try ChatAttachmentStorage.checkFolders([path.path]), path.path)
            for primary in [true, false] {
                var agent = f.agent
                if primary { agent.folder = path.path } else { agent.extraFolders = [path.path] }
                XCTAssertThrowsError(try f.service.publish([agent], teams: ["f5000000-0000-4000-8000-000000000004"], key: f.key)) {
                    XCTAssertEqual($0 as? ChatAttachmentError, .folders)
                }
            }
        }
        // Only this execution's explicit, canonical directory gets the exception.
        XCTAssertNoThrow(try ChatAttachmentStorage.checkFolders([otherCall.path], executionDirectory: otherCall.resolvingSymlinksInPath()))
        XCTAssertThrowsError(try ChatAttachmentStorage.checkFolders([shared.path], executionDirectory: shared))
    }

    func testReview2FolderIdentityAndVolumeCaseRulesIncludeMissingDescendants() async throws {
        let home = root.appendingPathComponent("home"), temp = root.appendingPathComponent("tmp")
        let data = home.appendingPathComponent("Library/Application Support/agentpad")
        let shared = data.appendingPathComponent("attachments/org")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let caseSensitive = try XCTUnwrap(root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
        let alternate = home.appendingPathComponent("LIBRARY/Application Support/AgentPad/Attachments/ORG")
        if !caseSensitive {
            let actual = try FileManager.default.attributesOfItem(atPath: shared.path)
            let alias = try FileManager.default.attributesOfItem(atPath: alternate.path)
            XCTAssertEqual(actual[.systemNumber] as? NSNumber, alias[.systemNumber] as? NSNumber)
            XCTAssertEqual(actual[.systemFileNumber] as? NSNumber, alias[.systemFileNumber] as? NSNumber)
        }
        for path in [alternate, alternate.appendingPathComponent("future/file"), home.appendingPathComponent("LIBRARY"), root.appendingPathComponent("TMP")] {
            if caseSensitive { XCTAssertNoThrow(try ChatAttachmentStorage.checkFolders([path.path], data: data, temporary: temp, home: home)) }
            else { XCTAssertThrowsError(try ChatAttachmentStorage.checkFolders([path.path], data: data, temporary: temp, home: home)) }
        }
        // A dangling alias must also protect a not-yet-created managed root.
        let futureData = home.appendingPathComponent("Library/Application Support/future-agentpad")
        let link = root.appendingPathComponent("future-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("Library/Application Support/FUTURE-AGENTPAD/attachments"))
        if caseSensitive { XCTAssertNoThrow(try ChatAttachmentStorage.checkFolders([link.path], data: futureData, temporary: temp, home: home)) }
        else { XCTAssertThrowsError(try ChatAttachmentStorage.checkFolders([link.path], data: futureData, temporary: temp, home: home)) }
        XCTAssertNoThrow(try ChatAttachmentStorage.checkFolders([data.path + "-project", temp.appendingPathComponent("project").path], data: data, temporary: temp, home: home))

        if !caseSensitive {
            let f = try await fixture()
            let managed = ChatAttachmentStorage.dataDirectory
            let forbidden = managed.deletingLastPathComponent().appendingPathComponent(managed.lastPathComponent.uppercased()).appendingPathComponent("attachments")
            for primary in [true, false] {
                var agent = f.agent
                if primary { agent.folder = forbidden.path } else { agent.extraFolders = [forbidden.path] }
                XCTAssertThrowsError(try f.service.publish([agent], teams: ["f5000000-0000-4000-8000-000000000004"], key: f.key)) {
                    XCTAssertEqual($0 as? ChatAttachmentError, .folders)
                }
            }
        }
    }

    func testCapabilityWithdrawalPausesQueueWithoutBlockingIndependentText() async throws {
        let f = try await fixture(), manager = try manager(f), model = model(f)
        model.saveDraft("keep caption", root: nil)
        try manager.add(data: Data("notes".utf8), name: "notes.txt", channel: channel, root: nil)
        try await wait { manager.drafts.first?.state == .ready }
        _ = try f.service.sendChannel(f.key, channel: channel, root: nil, text: model.draft(root: nil), mentions: [], agents: [],
            draftVersion: XCTUnwrap(model.draftVersion(root: nil)), mentionOnly: false)
        let original = try XCTUnwrap(f.store.outbox.commands().first)
        let outbox = try sender(f)
        let dependent = try outbox.enqueue(org: f.key.orgId, type: "request.create_in_channel_with_attachments", args: .object([:]), dependsOn: original.commandId)
        try f.write("INSERT INTO channel_call_intents (request_id, message_id, agent_id, command_id) VALUES (?, ?, ?, ?)",
            [requestID, ChatService.args(original)["message_id"]!.string!, f.agent.id.uuidString.lowercased(), dependent.commandId])
        let textDependent = try outbox.enqueue(org: f.key.orgId, type: "message.post", args: .object(["text": .string("dependent")]), dependsOn: original.commandId)
        let textID = try f.service.post(f.key, channel: channel, root: nil, text: "ordinary text", mentions: [])
        f.service.serverCapabilities[f.key.server] = []
        manager.reconcile(); outbox.allow(connection: 1, generation: "g1")
        try await wait { try f.store.outbox.commands().first { ChatService.args($0)["message_id"]?.string == textID }?.state == .sent }
        let pending = try XCTUnwrap(f.store.outbox.commands().first)
        XCTAssertEqual(pending.state, .pending); XCTAssertEqual(pending.bodyBytes, original.bodyBytes)
        XCTAssertEqual(try f.store.outbox.commands().first { $0.commandId == textDependent.commandId }?.state, .pending)
        XCTAssertEqual(try f.store.outbox.commands().first { $0.commandId == dependent.commandId }?.state, .pending)
        XCTAssertFalse(ChatStubProtocol.seen.contains { $0.body == original.bodyBytes })
        f.service.serverCapabilities[f.key.server] = ["chat.attachments"]
        manager.reconcile(); outbox.pump()
        try await wait { try f.store.outbox.commands().first?.state == .sent }
        XCTAssertEqual(try f.store.outbox.commands().first { $0.commandId == dependent.commandId }?.state, .pending)
        f.service.serverCapabilities[f.key.server] = ["chat.attachments", "chat.attachments_context"]
        outbox.pump()
        try await wait { try f.store.outbox.commands().first { $0.commandId == dependent.commandId }?.state == .sent }
    }

    func testReview1FilePostRecoveryPreservesCommandAndNeverSubstitutesText() async throws {
        for state: ChatCommandRecord.State? in [.pending, .unconfirmed, .dropped, .failed, .sent, nil] {
            let f = try await fixture()
            let files = [try file(), try file(Data("two".utf8), name: "two.txt")]
            let args: ChatJSON = .object(["message_id": .string(messageID), "channel_id": .string(channel),
                "text": .string("caption"), "mentions": .array([]), "attachment_ids": .array(files.map { .string($0.id) })])
            let original = try f.service.prepareCommand(f.key, type: "message.post_with_attachments", args: args)
            let messageID = messageID, channel = channel
            try write(f.store.queue) { db in
                try ChatMessages.insertSending(db, id: messageID, channel: channel, root: nil, author: f.key.accountId, text: "caption", mentions: [], at: ChatService.now())
                try ChatAttachments.write(db, id: messageID, files: files, only: false)
                if let state {
                    var record = original.record; record.state = state
                    if state == .dropped { record.sessionId = "closed-session" }
                    _ = try original.table.insert(db, record, seq: record.seq)
                }
            }
            f.service.resendPosts(f.key)
            let commands = try f.store.outbox.commands()
            XCTAssertFalse(commands.contains { $0.type == "message.post" }, "state \(String(describing: state))")
            XCTAssertTrue(commands.allSatisfy { ChatService.args($0)["attachment_ids"] == args["attachment_ids"] })
            let local = try read(f.store.queue) { try String.fetchOne($0, sql: "SELECT local_state FROM messages WHERE message_id = ?", arguments: [messageID]) }
            if [.pending, .sent].contains(state) {
                XCTAssertEqual(local, "sending")
                XCTAssertEqual(commands.count, state == .sent ? 2 : 1)
            } else {
                XCTAssertEqual(local, "failed")
                if state != .failed { XCTAssertThrowsError(try f.service.retry(f.key, messageId: messageID)) }
            }
        }
    }
    func testRawProtocolExactBytesBearerRedirectLimitAndCancellation() async throws {
        let address = try ChatServerAddress(parsing: "https://chat.example.com")
        let api = ChatAPI(server: address, protocolClasses: [ChatStubProtocol.self])
        let data = Data([0, 1, 2, 3, 255]), id = UUID().uuidString.lowercased()
        try await api.attachmentUpload(org: "org", id: id, data: data, token: "fixture-token", seconds: 150) { _ in }
        let seen = try XCTUnwrap(ChatStubProtocol.seen.last)
        XCTAssertEqual(seen.request.httpMethod, "PUT"); XCTAssertEqual(seen.body, data)
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Content-Length"), "5")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertNil(seen.request.value(forHTTPHeaderField: "Content-Encoding"))
        ChatStubProtocol.reset { _, _ in .success(.init(status: 302, headers: ["Location": "https://other.test/steal"])) }
        do { _ = try await api.attachmentBytes(path: "/file", token: "t", limit: 20); XCTFail("redirect followed") }
        catch { XCTAssertEqual(error as? ChatAPIError, .redirect(302)) }
        XCTAssertEqual(ChatStubProtocol.seen.count, 1)
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: Data(repeating: 1, count: 100))) }
        do { _ = try await api.attachmentBytes(path: "/file", token: "t", limit: 10); XCTFail("unbounded file") } catch { }
        ChatStubProtocol.delay = 0.15
        let task = Task { try await api.attachmentBytes(path: "/file", token: "t", limit: 200) }
        try await Task.sleep(for: .milliseconds(15)); task.cancel()
        do { _ = try await task.value; XCTFail("cancel ignored") } catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(160))
    }
    func testPrepareAndCompleteReceiptsDoNotAuthorizeSendCancellationCannotResurrect() async throws {
        let f = try await fixture(), manager = try manager(f)
        server.change { $0.checking = true }
        try manager.add(data: Data("notes".utf8), name: "notes.txt", channel: channel, root: nil)
        try await wait { manager.drafts.first?.state == .checking }
        XCTAssertThrowsError(try manager.prepared(channel: channel, root: nil))
        let draft = try XCTUnwrap(manager.drafts.first), path = try manager.storage.url(f.key, id: draft.id)
        manager.remove(draft)
        server.change { $0.checking = false }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(manager.drafts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(try read(f.store.queue) { try ChatAttachments.drafts($0) }.isEmpty)
        XCTAssertTrue(ChatStubProtocol.seen.contains { (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).type) == "attachment.cancel" })
    }
    func testFileOnlyAtomicPostSharedDraftAndRevisionGuard() async throws {
        let f = try await fixture(), manager = try manager(f), model = model(f)
        try manager.add(data: Data("one".utf8), name: "one.txt", channel: channel, root: nil)
        try await wait { manager.drafts.first?.state == .ready }
        let firstVersion = try XCTUnwrap(model.draftVersion(root: nil))
        try manager.add(data: Data("two".utf8), name: "two.txt", channel: channel, root: nil)
        try await wait { manager.drafts.count == 2 && manager.drafts.allSatisfy { $0.state == .ready } }
        let first = try XCTUnwrap(manager.drafts.first)
        try await f.store.queue.write { try ChatAttachments.put($0, first) }
        XCTAssertEqual(try read(f.store.queue) { try ChatAttachments.drafts($0).map { $0.file.name } }, ["one.txt", "two.txt"], "Progress and retries must preserve attachment order")
        XCTAssertTrue(manager === f.service.attachments(f.key))
        XCTAssertThrowsError(try f.service.sendChannel(f.key, channel: channel, root: nil, text: "", mentions: [], agents: [], draftVersion: firstVersion, mentionOnly: false))
        let version = try XCTUnwrap(model.draftVersion(root: nil)), ids = manager.drafts.map(\.id)
        let sent = try f.service.sendChannel(f.key, channel: channel, root: nil, text: "", mentions: [], agents: [], draftVersion: version, mentionOnly: false)
        let command = try XCTUnwrap(f.store.outbox.commands().first)
        XCTAssertEqual(command.type, "message.post_with_attachments")
        XCTAssertEqual(ChatService.args(command)["attachment_ids"], .array(ids.map(ChatJSON.string)))
        XCTAssertEqual(ChatService.args(command)["text"], .string(""))
        XCTAssertNil(model.draftVersion(root: nil))
        let row = try read(f.store.queue) { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM messages WHERE message_id = ?", arguments: [sent])).mapMessage() }
        XCTAssertTrue(row.attachmentOnly); XCTAssertEqual(row.attachments.map(\.id), ids)
        XCTAssertEqual(try f.service.sendChannel(f.key, channel: channel, root: nil, text: "", mentions: [], agents: [], draftVersion: version, mentionOnly: false), sent)
        XCTAssertEqual(try f.store.outbox.commands().count, 1)
    }
    func testServerLimitsFailureRetryAndThreadDestination() async throws {
        let f = try await fixture(), manager = try manager(f), model = model(f)
        var small = limits; small.messageFiles = 1; small.fileBytes = 5; small.messageBytes = 5
        f.service.serverAttachmentLimits[f.key.server] = small
        server.change { $0.failUpload = true }
        model.saveDraft("caption survives", root: messageID)
        try manager.add(data: Data("notes".utf8), name: "a.txt", channel: channel, root: messageID)
        try await wait { manager.drafts.first?.state == .failed }
        XCTAssertEqual(model.draft(root: messageID), "caption survives")
        XCTAssertTrue(manager.files(channel: channel, root: nil).isEmpty)
        XCTAssertThrowsError(try manager.add(data: Data("a".utf8), name: "b.txt", channel: channel, root: messageID))
        XCTAssertThrowsError(try manager.add(data: Data("abcdef".utf8), name: "b.txt", channel: channel, root: nil))
        server.change { $0.failUpload = false }
        manager.retry(try XCTUnwrap(manager.drafts.first))
        try await wait { manager.drafts.first?.state == .ready }
        XCTAssertEqual(manager.drafts.first?.root, messageID)
    }
    func testDeletionAndRevokeRejectLatePreviewsAndClearViewer() async throws {
        let f = try await fixture(), manager = try manager(f), image = Self.png()
        var file = try file(image, name: "screen.png"); file.hasPreview = true
        let message = try message(f, file: file, only: true)
        XCTAssertEqual(message.displayText, "")
        server.change { $0.downloads = image }
        _ = try await manager.load(message, file: file, preview: true)
        let viewer = viewer(f, message: message, file: file); await viewer.load()
        XCTAssertNotNil(manager.image(message, file: file)); XCTAssertNotNil(viewer.preview)
        let capture = try XCTUnwrap(manager.stamp(channel: channel, message: message, file: file))
        _ = try self.message(f, file: file, revision: 2, deleted: true)
        manager.reconcile()
        XCTAssertFalse(manager.current(capture)); XCTAssertNil(manager.image(message, file: file)); XCTAssertNil(viewer.preview)
        _ = try self.message(f, file: file, revision: 1)
        let tombstone = try read(f.store.queue) { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM messages WHERE message_id = ?", arguments: [messageID])).mapMessage() }
        XCTAssertTrue(tombstone.attachments.isEmpty)
        // Revoke/rejoin gives a new epoch, so an old response still cannot apply.
        try f.write("UPDATE meta SET channel_access_epoch = channel_access_epoch + 1")
        try f.write("UPDATE teams SET mine = 0")
        XCTAssertNil(manager.stamp(channel: channel))
        try f.write("UPDATE teams SET mine = 1")
        XCTAssertFalse(manager.current(capture))
    }

    func testViewerTabsHaveIndependentBytesAndRejectLateDownloadsAfterRevisionOrRevocation() async throws {
        let f = try await fixture(), manager = try manager(f)
        let firstBytes = Self.png(), secondBytes = try metadataImage("public.jpeg")
        let firstFile = try file(firstBytes, name: "one.png"), secondFile = try file(secondBytes, name: "two.jpg")
        let firstMessage = try message(f, file: firstFile)
        let secondMessage = try message(f, file: secondFile, id: UUID().uuidString.lowercased())
        let first = viewer(f, message: firstMessage, file: firstFile), second = viewer(f, message: secondMessage, file: secondFile)
        server.change { $0.downloads = firstBytes }; await first.load()
        server.change { $0.downloads = secondBytes }; await second.load()
        XCTAssertEqual(first.preview?.data, firstBytes); XCTAssertEqual(second.preview?.data, secondBytes)
        first.zoom = 2; XCTAssertEqual(second.zoom, 1)
        _ = try message(f, file: firstFile, revision: 2)
        XCTAssertNil(first.preview)
        let before = ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/original") == true }.count
        ChatStubProtocol.delay = 0.1
        server.change { $0.downloads = firstBytes }
        let loading = Task { await first.load() }
        try await wait { ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/original") == true }.count > before }
        _ = try message(f, file: firstFile, revision: 3)
        await loading.value
        XCTAssertNil(first.preview, "A late download cannot fill the new revision")
        try f.write("UPDATE teams SET mine = 0"); manager.reconcile()
        XCTAssertNil(first.preview); XCTAssertNil(second.preview)
    }
    func testClipboardFileURLWinsOverIconAndPlainTextIsNative() async throws {
        let f = try await fixture(), manager = try manager(f), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("normal text", forType: .string)
        XCTAssertFalse(try ChatAttachmentPaste.take(pasteboard, manager: manager, channel: channel, root: nil))
        let url = root.appendingPathComponent("notes.txt")
        try Data("from Finder".utf8).write(to: url)
        pasteboard.clearContents(); pasteboard.writeObjects([url as NSURL]); pasteboard.setData(Self.png(), forType: .png)
        XCTAssertTrue(try ChatAttachmentPaste.take(pasteboard, manager: manager, channel: channel, root: nil))
        try await wait { manager.drafts.count == 1 }
        XCTAssertEqual(manager.drafts.count, 1); XCTAssertEqual(manager.drafts.first?.file.name, "notes.txt")
        pasteboard.clearContents(); pasteboard.setData(Self.png(), forType: .png)
        XCTAssertTrue(try ChatAttachmentPaste.take(pasteboard, manager: manager, channel: channel, root: messageID))
        try await wait { manager.files(channel: self.channel, root: self.messageID).count == 1 }
        XCTAssertEqual(manager.files(channel: channel, root: messageID).first?.file.mime, "image/png")
    }

    private func pasteEditor(in view: NSView) -> ChatMentionEditor.Editor? {
        (view as? ChatMentionEditor.Editor) ?? view.subviews.lazy.compactMap { self.pasteEditor(in: $0) }.first
    }
    private func composer(_ model: ChatChannelModel, root: String?) -> NSHostingView<some View> {
        NSHostingView(rootView: ChatUX1Composer(model: model, root: root, members: [], mentionable: [], agents: [])
            .frame(width: 700, height: 400))
    }
    private func clipboardImage(_ type: String, frames: Int = 1) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(Self.png() as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), data = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, frames, nil))
        for _ in 0..<frames { CGImageDestinationAddImage(output, image, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return data as Data
    }

    private func metadataImage(_ type: String, orientation: Int = 6) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for (index, color) in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                               CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 0, alpha: 1)].enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: (index % 2) * 40, y: (1 - index / 2) * 20, width: 40, height: 20))
        }
        let data = NSMutableData(), metadata = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(metadata, "https://example.test/private/" as CFString, "private" as CFString, nil))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "private:Location" as CFString, "PRIVATE-XMP-LOCATION" as CFString))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.37, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 4.90, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "PRIVATE-EXIF-COMMENT"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCByline: "PRIVATE-IPTC-AUTHOR"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "PRIVATE-TIFF-ARTIST"],
        ]
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(output, try XCTUnwrap(context.makeImage()), metadata, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        // Verify the fixture really carries location and all three metadata families.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(props[kCGImagePropertyGPSDictionary], type)
        XCTAssertNotNil(props[kCGImagePropertyExifDictionary], type)
        XCTAssertNotNil(props[kCGImagePropertyIPTCDictionary], type)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int, orientation, type)
        let tags = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(tags, nil, "private:Location" as CFString) as String?, "PRIVATE-XMP-LOCATION", type)
        return data as Data
    }

    private func imageCorners(_ data: Data) throws -> [String] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        // Decode the pixels without applying EXIF: the upload must already be oriented.
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), w = image.width, h = image.height
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return [(w / 4, h / 4), (3 * w / 4, h / 4), (w / 4, 3 * h / 4), (3 * w / 4, 3 * h / 4)].map { x, y in
            let offset = (y * w + x) * 4
            return (0..<3).map { pixels[offset + $0] > 127 ? "1" : "0" }.joined()
        }
    }

    private func assertNoImageMetadata(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), file: file, line: line)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], file: file, line: line)
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyIPTCDictionary] {
            XCTAssertNil(props[key], "Leaked \(key)", file: file, line: line)
        }
        XCTAssertTrue(props[kCGImagePropertyOrientation] == nil || props[kCGImagePropertyOrientation] as? Int == 1, file: file, line: line)
        for marker in ["PRIVATE-", "Exif\0\0", "http://ns.adobe.com/xap/1.0/", "<x:xmpmeta", "<rdf:RDF"] {
            XCTAssertNil(data.range(of: Data(marker.utf8)), "Leaked metadata bytes: \(marker.debugDescription)", file: file, line: line)
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            XCTAssertNil(CGImageMetadataCopyStringValueWithPath(metadata, nil, "private:Location" as CFString), file: file, line: line)
        }
    }

    private func checkMetadataUpload(type: String, ext: String, route: String) async throws {
        let f = try await fixture(), manager = try manager(f), original = try metadataImage(type)
        let url = root.appendingPathComponent(UUID().uuidString + "." + ext), board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try original.write(to: url)
        let completion: @MainActor (Error?) -> Void = { XCTAssertNil($0, route) }
        switch route {
        case "clipboard":
            board.setData(original, forType: .init(type))
            XCTAssertTrue(try ChatAttachmentPaste.take(board, manager: manager, channel: channel, root: nil, completion: completion))
        case "file":
            try manager.importFiles([.file(url)], channel: channel, root: nil, completion: completion)
        case "legacy":
            try manager.add(urls: [url], channel: channel, root: nil)
        default:
            board.writeObjects([url as NSURL]); board.setData(Self.png(), forType: .png)
            XCTAssertTrue(try ChatAttachmentPaste.take(board, manager: manager, channel: channel, root: nil,
                fromDrop: route == "drop", completion: completion))
        }
        try await wait { manager.drafts.first?.state == .ready }
        let draft = try XCTUnwrap(manager.drafts.first)
        var uploaded: Data?
        server.change { uploaded = $0.bytes[draft.id] }
        let bytes = try XCTUnwrap(uploaded)
        try assertNoImageMetadata(bytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 40); XCTAssertEqual(image.height, 80)
        XCTAssertEqual(try imageCorners(bytes), ["001", "100", "110", "010"], "Orientation 6 must be baked into the pixels: \(route)")
        XCTAssertEqual(bytes.count, draft.file.size)
        XCTAssertEqual(ChatAttachments.digest(bytes), draft.sha256)
        XCTAssertEqual(try Data(contentsOf: manager.storage.url(f.key, id: draft.id)), bytes)
        XCTAssertEqual(try Data(contentsOf: url), original, "The source file must remain unchanged")
    }

    func testImageMetadataIsStrippedFromUploadedJPEGAcrossImportPaths() async throws {
        for route in ["clipboard", "file", "finder", "drop", "legacy"] {
            try await checkMetadataUpload(type: "public.jpeg", ext: "jpg", route: route)
        }
    }

    func testLegacyJPEGWithGPSIsSanitizedOnRetryAndRetryKeepsBytesAndHash() async throws {
        let f = try await fixture(), original = try metadataImage("public.jpeg")
        var old = ChatAttachmentDraft(file: try file(original, name: "old.jpg"), messageId: messageID,
            channel: channel, root: "", session: "s-anna", generation: "g1",
            sha256: ChatAttachments.digest(original), createdAt: Date(), expiresAt: .distantFuture)
        old.state = .failed
        // Write the pre-update shape and original bytes, bypassing all import paths.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "sanitizedImageSHA256")
        old = try JSONDecoder().decode(ChatAttachmentDraft.self, from: JSONSerialization.data(withJSONObject: json))
        try f.service.files.attachmentStorage.save(original, key: f.key, id: old.id)
        try write(f.store.queue) { try ChatAttachments.put($0, old) }
        // The old prepare might have succeeded before the network failure.
        server.change { $0.rows[old.id] = ["attachment_id": old.id, "state": "reserved", "size": original.count]; $0.failUpload = true }
        let manager = try manager(f)
        manager.retry(old)
        try await wait { manager.drafts.first?.id != old.id && manager.drafts.first?.state == .failed }
        let cleaned = try XCTUnwrap(manager.drafts.first)
        let saved = try Data(contentsOf: manager.storage.url(f.key, id: cleaned.id))
        try assertNoImageMetadata(saved)
        XCTAssertEqual(cleaned.file.size, saved.count)
        XCTAssertEqual(cleaned.sha256, ChatAttachments.digest(saved))
        XCTAssertEqual(cleaned.sanitizedImageSHA256, cleaned.sha256)
        server.change { $0.failUpload = false }
        manager.retry(cleaned)
        try await wait { manager.drafts.first?.state == .ready }
        var uploaded: Data?
        server.change { uploaded = $0.bytes[cleaned.id] }
        XCTAssertEqual(uploaded, saved)
        try assertNoImageMetadata(XCTUnwrap(uploaded))
        XCTAssertEqual(manager.drafts.first?.id, cleaned.id)
        XCTAssertEqual(manager.drafts.first?.sha256, cleaned.sha256)
        XCTAssertFalse(ChatStubProtocol.seen.contains { $0.request.httpMethod == "PUT" && $0.body == original })
    }

    func testRenewingLegacyJPEGRecomputesFileAndSelectedManifest() async throws {
        let f = try await fixture(), manager = try manager(f), original = try metadataImage("public.jpeg")
        var old = ChatAttachmentDraft(file: try file(original, name: "expired.jpg"), messageId: messageID,
            channel: channel, root: "", session: "s-anna", generation: "g1",
            sha256: ChatAttachments.digest(original), createdAt: Date(), expiresAt: .distantPast)
        old.state = .failed
        try manager.storage.save(original, key: f.key, id: old.id)
        try write(f.store.queue) { try ChatAttachments.put($0, old) }
        let model = model(f)
        model.saveDraft("saved caption", root: nil, attachmentSelection: [.init(file: old.file, messageId: messageID, revision: 1, sha256: old.sha256)])
        let next = try manager.renewed(old, capture: XCTUnwrap(manager.uploadStamp(channel: channel)))
        let saved = try Data(contentsOf: manager.storage.url(f.key, id: next.id))
        try assertNoImageMetadata(saved)
        XCTAssertEqual(next.file.size, saved.count)
        XCTAssertEqual(next.sha256, ChatAttachments.digest(saved))
        XCTAssertNotEqual(next.prepareCommand, old.prepareCommand)
        try write(f.store.queue) { try manager.replace($0, draft: old, with: next) }
        manager.reconcile()
        try await wait { manager.drafts.first?.state == .ready }
        XCTAssertEqual(model.composerDraft(root: nil).attachmentSelection.first?.sha256, next.sha256)
        XCTAssertEqual(model.composerDraft(root: nil).attachmentSelection.first?.file.size, saved.count)
        var uploaded: Data?
        server.change { uploaded = $0.bytes[next.id] }
        XCTAssertEqual(uploaded, saved)
    }

    func testImageMetadataIsStrippedFromUploadedPNGHEICAndTIFF() async throws {
        for (type, ext) in [("public.png", "png"), ("public.heic", "heic"), ("public.tiff", "tiff")] {
            for route in ["clipboard", "file"] { try await checkMetadataUpload(type: type, ext: ext, route: route) }
        }
    }

    func testImageMetadataStrippingBakesAllEXIFOrientationsIntoPixels() async throws {
        let expected = [
            ["100", "010", "001", "110"], ["010", "100", "110", "001"],
            ["110", "001", "010", "100"], ["001", "110", "100", "010"],
            ["100", "001", "010", "110"], ["001", "100", "110", "010"],
            ["110", "010", "001", "100"], ["010", "110", "100", "001"],
        ]
        for orientation in 1...8 {
            let original = try metadataImage("public.jpeg", orientation: orientation)
            XCTAssertEqual(try imageCorners(original), expected[0])
            let prepared = try await ChatAttachmentWorker.shared.prepare(.clipboard(original), limits: limits)
            try assertNoImageMetadata(prepared.data)
            XCTAssertEqual(prepared.file.width, orientation < 5 ? 80 : 40)
            XCTAssertEqual(prepared.file.height, orientation < 5 ? 40 : 80)
            XCTAssertEqual(try imageCorners(prepared.data), expected[orientation - 1], "EXIF orientation \(orientation)")
        }
    }

    func testAnimatedGIFReportsComposerErrorWithoutUploading() async throws {
        let gif = try clipboardImage("com.compuserve.gif", frames: 2)
        XCTAssertEqual(CGImageSourceGetCount(try XCTUnwrap(CGImageSourceCreateWithData(gif as CFData, nil))), 2)
        let url = root.appendingPathComponent("Animation.gif"); try gif.write(to: url)
        for (route, destination) in [("clipboard", nil), ("clipboardAndPNG", messageID), ("finder", nil), ("drop", messageID)] as [(String, String?)] {
            let f = try await fixture(), manager = try manager(f), model = model(f)
            let host = composer(model, root: destination), ui = ComposerPasteTestWindow(content: host)
            defer { ui.close() }
            try await wait { self.pasteEditor(in: host)?.attachments != nil }
            let editor = try XCTUnwrap(pasteEditor(in: host)); ui.focus(editor)
            let board = NSPasteboard.general; board.clearContents()
            if route == "finder" || route == "drop" { board.writeObjects([url as NSURL]) }
            else { board.setData(gif, forType: .init("com.compuserve.gif")) }
            if route != "clipboard" { board.setData(Self.png(), forType: .png) }
            if route == "drop" { XCTAssertTrue(try XCTUnwrap(editor.dropAttachments)(board)) }
            else { try ui.commandV() }
            try await wait { !manager.isImporting(channel: self.channel, root: destination) }
            XCTAssertEqual(model.problem, "Animated GIF attachments are not supported by this server. Choose another file.", route)
            XCTAssertTrue(manager.drafts.isEmpty, route)
            XCTAssertEqual(editor.string, "")
            let visible = try await renderedOwnershipText(host).map(\.0).joined(separator: " ")
            XCTAssertTrue(visible.contains("Animated GIF"), visible)
        }
        XCTAssertFalse(ChatStubProtocol.seen.contains { $0.request.httpMethod == "PUT" })
        XCTAssertFalse(ChatStubProtocol.seen.contains { (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).type) == "attachment.prepare" })
        XCTAssertEqual(try Data(contentsOf: url), gif)
    }

    func testNativeChatImagePasteViaEditMenuInChannelAndThread() async throws {
        let f = try await fixture(), manager = try manager(f), model = model(f)
        for destination in [nil, messageID] as [String?] {
            model.openThread(destination)
            let host = composer(model, root: destination), ui = ComposerPasteTestWindow(content: host)
            defer { ui.close() }
            try await wait { self.pasteEditor(in: host)?.attachments != nil }
            let editor = try XCTUnwrap(pasteEditor(in: host))
            ui.focus(editor)
            for type in ["public.png", "public.jpeg", "public.heic", "com.compuserve.gif"] {
                let board = NSPasteboard.general
                board.clearContents(); board.setData(try clipboardImage(type), forType: .init(type))
                XCTAssertNil(board.string(forType: .string))
                // These assertions must fail if either validator is reverted.
                XCTAssertTrue(editor.validateMenuItem(ui.paste), type)
                XCTAssertTrue(editor.validateUserInterfaceItem(ui.paste), type)
                let count = manager.files(channel: channel, root: destination).count
                try ui.commandV()
                try await wait { !manager.isImporting(channel: self.channel, root: destination) }
                XCTAssertNil(model.problem)
                XCTAssertEqual(manager.files(channel: channel, root: destination).count, count + 1, "Exactly one attachment per Command-V: \(type)")
                let draft = try XCTUnwrap(manager.files(channel: channel, root: destination).last)
                XCTAssertEqual(draft.file.mime, type == "public.jpeg" ? "image/jpeg" : "image/png")
                XCTAssertEqual(draft.file.name, type == "public.jpeg" ? "Clipboard.jpg" : "Clipboard.png")
                XCTAssertEqual(editor.string, "", "The image must not also insert text")
            }
        }
        XCTAssertEqual(manager.files(channel: channel, root: nil).count, 4)
        XCTAssertEqual(manager.files(channel: channel, root: messageID).count, 4)
    }

    func testNativeChatPasteKeepsTextFallbackAndCapabilityGate() async throws {
        for support in ["enabled", "no capability", "no limits"] {
            let f = try await fixture(), manager = try manager(f), model = model(f)
            if support == "no capability" { f.service.serverCapabilities[f.key.server] = [] }
            if support == "no limits" { f.service.serverAttachmentLimits[f.key.server] = nil }
            let host = composer(model, root: nil), ui = ComposerPasteTestWindow(content: host)
            defer { ui.close() }
            try await wait { self.pasteEditor(in: host) != nil }
            let editor = try XCTUnwrap(pasteEditor(in: host))
            ui.focus(editor)
            XCTAssertEqual(editor.attachments != nil, support == "enabled")
            let board = NSPasteboard.general
            board.clearContents(); board.setString("ordinary text", forType: .string)
            try ui.commandV()
            XCTAssertEqual(editor.string, "ordinary text")
            XCTAssertEqual(model.draft(root: nil), "ordinary text")
            if support != "enabled" {
                board.clearContents(); board.setData(Self.png(), forType: .png)
                ui.editMenu.update(); XCTAssertFalse(ui.paste.isEnabled)
                XCTAssertFalse(editor.validateUserInterfaceItem(ui.paste))
                board.setString(" fallback", forType: .string)
                try ui.commandV()
                XCTAssertEqual(editor.string, "ordinary text fallback")
            } else {
                // Advertised image data can disappear (e.g. a clipboard owner
                // exits). Exercise the production composer's Boolean result.
                let provider = MissingClipboardImage()
                let item = NSPasteboardItem()
                item.setDataProvider(provider, forTypes: [.png])
                item.setString(" fallback", forType: .string)
                board.clearContents(); board.writeObjects([item])
                XCTAssertTrue(ChatAttachmentPaste.accepts(board))
                XCTAssertNil(board.data(forType: .png))
                try ui.commandV()
                XCTAssertEqual(editor.string, "ordinary text fallback")
                withExtendedLifetime(provider) {}
            }
            XCTAssertTrue(manager.drafts.isEmpty)
            board.clearContents(); board.setData(Self.png(), forType: .png)
            editor.isEditable = false
            ui.editMenu.update(); XCTAssertFalse(ui.paste.isEnabled)
            XCTAssertFalse(editor.validateUserInterfaceItem(ui.paste))
        }
    }

    func testClipboardFileImagesConvertWithoutAttachingFinderIcons() async throws {
        let f = try await fixture(), manager = try manager(f), board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        for (ext, type) in [("png", "public.png"), ("heic", "public.heic"), ("tiff", "public.tiff"), ("gif", "com.compuserve.gif")] {
            let url = root.appendingPathComponent("Screenshot." + ext)
            try clipboardImage(type).write(to: url)
            board.clearContents(); board.writeObjects([url as NSURL]); board.setData(Data("Finder icon".utf8), forType: .tiff)
            let count = manager.drafts.count
            var finished = false
            XCTAssertTrue(try ChatAttachmentPaste.take(board, manager: manager, channel: channel, root: nil) { error in
                XCTAssertNil(error); finished = true
            })
            try await wait { finished }
            XCTAssertEqual(manager.drafts.count, count + 1)
            let draft = try XCTUnwrap(manager.drafts.last)
            XCTAssertEqual(draft.file.name, "Screenshot.png"); XCTAssertEqual(draft.file.mime, "image/png")
        }
    }

    func testConvertedClipboardImagesKeepNegotiatedLimits() async throws {
        let heic = try clipboardImage("public.heic")
        var narrow = limits
        narrow.imageSide = 1
        do { _ = try await ChatAttachmentWorker.shared.prepare(.clipboard(heic), limits: narrow); XCTFail("oversized pixels accepted") }
        catch { XCTAssertEqual(error as? ChatAttachmentError, .type) }
        narrow = limits; narrow.fileBytes = 1
        do { _ = try await ChatAttachmentWorker.shared.prepare(.clipboard(heic), limits: narrow); XCTFail("oversized encoded bytes accepted") }
        catch { XCTAssertEqual(error as? ChatAttachmentError, .size) }
        narrow = limits; narrow.extensions = ["jpeg"]; narrow.mimeTypes = ["image/jpeg"]
        let jpeg = try await ChatAttachmentWorker.shared.prepare(.clipboard(heic), limits: narrow)
        XCTAssertEqual(jpeg.file.name, "Clipboard.jpeg"); XCTAssertEqual(jpeg.file.mime, "image/jpeg")
        narrow.extensions = ["txt"]; narrow.mimeTypes = ["text/plain"]
        do { _ = try await ChatAttachmentWorker.shared.prepare(.clipboard(heic), limits: narrow); XCTFail("unsupported server type accepted") }
        catch { XCTAssertEqual(error as? ChatAttachmentError, .type) }
    }

    func testNativeScreenshotLazyImagePromisePastesOnce() async throws {
        let f = try await fixture(), manager = try manager(f), model = model(f)
        let host = composer(model, root: nil), ui = ComposerPasteTestWindow(content: host)
        defer { ui.close() }
        try await wait { self.pasteEditor(in: host)?.attachments != nil }
        ui.focus(try XCTUnwrap(pasteEditor(in: host)))
        let provider = LazyClipboardImage(data: Self.png())
        let item = NSPasteboardItem(); item.setDataProvider(provider, forTypes: [.png])
        let board = NSPasteboard.general
        board.clearContents(); XCTAssertTrue(board.writeObjects([item]))
        XCTAssertTrue(ChatAttachmentPaste.accepts(board))
        XCTAssertEqual(provider.requests, 0, "Validation must not request the promised bytes")
        try ui.commandV()
        XCTAssertTrue(manager.isImporting(channel: channel, root: nil))
        XCTAssertThrowsError(try manager.prepared(channel: channel, root: nil))
        try await wait { !manager.isImporting(channel: self.channel, root: nil) }
        XCTAssertNil(model.problem)
        XCTAssertEqual(manager.drafts.count, 1)
        XCTAssertEqual(manager.drafts.first?.file.name, "Clipboard.png")
        XCTAssertEqual(provider.requests, 1)
        withExtendedLifetime(provider) {}
    }

    func testDragOnlyFilePromiseDoesNotSuppressClipboardText() async throws {
        let f = try await fixture(), manager = try manager(f), board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let delegate = PromisedClipboardImage(data: Self.png())
        let provider = NSFilePromiseProvider(fileType: "public.png", delegate: delegate)
        board.writeObjects([provider])
        board.setString("ordinary text", forType: .string)
        XCTAssertTrue(ChatAttachmentPaste.accepts(board, fromDrop: true))
        XCTAssertFalse(ChatAttachmentPaste.accepts(board))
        XCTAssertFalse(try ChatAttachmentPaste.take(board, manager: manager, channel: channel, root: nil))
        XCTAssertTrue(manager.drafts.isEmpty)
        XCTAssertNil(delegate.destination)
        withExtendedLifetime(provider) {}
    }

    func testDroppedFilePromisesStartSynchronouslyAndKeepAuthorization() async throws {
        for outcome in ["success", "revoked", "failed"] {
            let f = try await fixture(), manager = try manager(f)
            // A legacy promise can advertise one type but deliver two files.
            let receiver = ControlledFilePromise(data: Self.png())
            var finished = false
            try ChatAttachmentPaste.takePromises([receiver], manager: manager, channel: channel, root: messageID) { error in
                XCTAssertEqual(error == nil, outcome == "success"); finished = true
            }
            let directory = try XCTUnwrap(receiver.destination, "The promise must start before the drop handler returns")
            XCTAssertTrue(manager.isImporting(channel: channel, root: messageID))
            XCTAssertThrowsError(try manager.prepared(channel: channel, root: messageID))
            if outcome == "revoked" {
                try f.write("UPDATE teams SET mine = 0")
                try f.write("UPDATE teams SET mine = 1")
            }
            receiver.fulfill(error: outcome == "failed" ? ChatAttachmentError.source : nil)
            try await wait { finished }
            XCTAssertEqual(manager.files(channel: channel, root: messageID).count, outcome == "success" ? 2 : 0)
            XCTAssertTrue(manager.files(channel: channel, root: nil).isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        let f = try await fixture(), manager = try manager(f), receiver = ControlledFilePromise(data: Self.png())
        XCTAssertThrowsError(try ChatAttachmentPaste.takePromises(Array(repeating: receiver, count: limits.messageFiles + 1),
            manager: manager, channel: channel, root: nil))
        XCTAssertNil(receiver.destination, "Reject over-quota promises before asking the source to write files")
    }

    func testReview1ClipboardDefersProcessingAndRejectsResultAfterRevokeRejoin() async throws {
        let f = try await fixture(), manager = try manager(f), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(Self.png(), forType: .png)
        var finished = false
        XCTAssertTrue(try ChatAttachmentPaste.take(pasteboard, manager: manager, channel: channel, root: nil) { error in
            XCTAssertNotNil(error); finished = true
        })
        XCTAssertTrue(manager.drafts.isEmpty, "Paste must return before image decoding/encoding and draft application")
        XCTAssertThrowsError(try manager.prepared(channel: channel, root: nil), "A caption cannot be sent while files are being prepared")
        // No yield: the worker result must not apply even if access is back by
        // the time the main actor resumes it.
        try f.write("UPDATE teams SET mine = 0")
        try f.write("UPDATE teams SET mine = 1")
        try await wait { finished }
        XCTAssertTrue(manager.drafts.isEmpty)
        XCTAssertTrue(try read(f.store.queue) { try ChatAttachments.drafts($0) }.isEmpty)
        XCTAssertFalse(ChatStubProtocol.seen.contains { (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).type) == "attachment.prepare" })
    }

    func testLargeClipboardRejectionKeepsMainActorResponsiveAndQueueBounded() async throws {
        // The maximum accepted pixel count, with a tiny byte limit so rejection
        // happens after PNG encoding. Image generation itself is outside the UI.
        let png = try await Task.detached {
            let context = try XCTUnwrap(CGContext(data: nil, width: 5000, height: 4000, bitsPerComponent: 8, bytesPerRow: 20000,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let image = try XCTUnwrap(context.makeImage()), data = NSMutableData()
            let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(output, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(output))
            return data as Data
        }.value
        let f = try await fixture(), manager = try manager(f), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var small = limits; small.fileBytes = 1; small.pendingFiles = 1
        f.service.serverAttachmentLimits[f.key.server] = small
        pasteboard.setData(png, forType: .png)
        var finished = false, pulses = 0
        XCTAssertTrue(try ChatAttachmentPaste.take(pasteboard, manager: manager, channel: channel, root: nil) { error in
            XCTAssertEqual(error as? ChatAttachmentError, .size); finished = true
        })
        XCTAssertThrowsError(try ChatAttachmentPaste.take(pasteboard, manager: manager, channel: channel, root: nil))
        let heartbeat = Task { @MainActor in
            while !finished { pulses += 1; try? await Task.sleep(for: .milliseconds(2)) }
        }
        try await wait { finished }
        await heartbeat.value
        XCTAssertGreaterThan(pulses, 1, "Image processing must let the main actor continue even when the PNG is rejected")
        XCTAssertTrue(manager.drafts.isEmpty)
    }

    func testPreparedDraftThumbnailSurvivesProgressWithoutReadingOriginal() async throws {
        let f = try await fixture(), manager = try manager(f), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        server.change { $0.checking = true }
        pasteboard.setData(Self.png(), forType: .png)
        XCTAssertTrue(try ChatAttachmentPaste.take(pasteboard, manager: manager, channel: channel, root: nil))
        try await wait { manager.drafts.first?.state == .checking }
        let draft = try XCTUnwrap(manager.drafts.first), image = try XCTUnwrap(manager.draftImage(draft))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 84)
        manager.storage.remove(f.key, id: draft.id)
        manager.reconcile()
        XCTAssertTrue(manager.draftImage(draft) === image)
        try f.write("UPDATE teams SET mine = 0"); manager.reconcile()
        XCTAssertNil(manager.draftImage(draft))
    }
    func testManifestHashAndOrderArePartOfConsentAndBashIsRefused() async throws {
        let f = try await fixture(), manager = try manager(f), model = model(f)
        try f.write("UPDATE agent_channels SET executor_session_id = 's-anna'")
        try await f.journal.queue.write { try $0.execute(sql: "UPDATE assignments SET published_session = 's-anna'") }
        let file = try file(), original = try message(f, file: file)
        let selection = ChatAttachmentManifest(file: file, messageId: original.id, revision: original.revision, sha256: ChatAttachments.digest(Data("notes".utf8)))
        model.saveDraft("@billing@anna please read", root: nil, contextIds: [original.id], attachmentSelection: [selection])
        let version = try XCTUnwrap(model.draftVersion(root: nil)), card = try XCTUnwrap(f.store.channelAgents(channel).first)
        _ = try f.service.sendChannel(f.key, channel: channel, root: nil, text: model.draft(root: nil), mentions: [], agents: [card], draftVersion: version, mentionOnly: false, additionalContext: [original])
        let command = try XCTUnwrap(f.store.outbox.commands().first { $0.type == "request.create_in_channel_with_attachments" })
        XCTAssertEqual(ChatService.args(command)["conditions_version"], .number(2))
        XCTAssertEqual(ChatService.args(command)["attachments"], .array([selection.reference]))
        XCTAssertNotNil(command.dependsOn)
        let authority = try XCTUnwrap(f.journal.channelAuthority(ChatService.args(command)["request_id"]!.string!))
        XCTAssertEqual(authority.attachments, [selection])
        let launch = TeamLaunchRequest(requestId: "r", prompt: "p", callerName: "n", callerProject: nil, conversationId: nil, expiresAt: Date().addingTimeInterval(100), attachments: [selection])
        var inputs = TeamLaunchInputs(agent: f.agent, request: launch), other = inputs
        other.attachments?[0].sha256 = String(repeating: "0", count: 64)
        XCTAssertNotEqual(inputs, other)
        inputs.attachments = nil; XCTAssertNotEqual(inputs, other)
        try f.write("UPDATE agent_channels SET access = 'edit'")
        model.saveDraft("@billing@anna again", root: nil, contextIds: [original.id], attachmentSelection: [selection])
        XCTAssertThrowsError(try f.service.sendChannel(f.key, channel: channel, root: nil, text: model.draft(root: nil), mentions: [], agents: f.store.channelAgents(channel), draftVersion: XCTUnwrap(model.draftVersion(root: nil)), mentionOnly: false, additionalContext: [original]))
        XCTAssertTrue(manager.files(channel: channel, root: nil).isEmpty)
    }
    func testExecutionCopiesOnlySelectedHashVerifiedFilesAndRemovesOnRevoke() async throws {
        let f = try await fixture(), manager = try manager(f), bytes = Data("selected only".utf8), file = try file(bytes)
        let selection = ChatAttachmentManifest(file: file, messageId: messageID, revision: 2, sha256: ChatAttachments.digest(bytes))
        try f.move("starting", 4)
        try f.write("UPDATE requests SET conditions_version = 2")
        var content = f.content(); content.attachments = [selection]
        server.change { $0.requestContent = try! JSONEncoder().encode(content); $0.downloads = bytes }
        let loaded = try await f.service.loadChannelContent(f.key, request: f.request(), refresh: true)
        XCTAssertTrue(loaded)
        let launch = try XCTUnwrap(f.service.launchRequest(requestID))
        let approval = try TeamApprovals.make(request: launch, agent: f.agent, key: f.key, generation: "g1", session: "s-anna")
        let params = try TeamLaunchParams.decode(approval.params)
        let row = ChatRunRecord(runId: params.runId, requestId: requestID, approvalId: approval.id, agentId: params.inputs.agentId, conversationId: params.conversationId, startedAt: Date(), kind: "channel", org: f.key.orgId, channelId: channel, threadRootId: messageID)
        let prepared = try await f.service.prepareAttachmentFiles(params, row: row)
        let copied = try XCTUnwrap(prepared)
        defer { copied.remove() }
        let beforeRefresh = copied.stamp
        let refreshed = try await f.service.loadChannelContent(f.key, request: f.request(), refresh: true)
        XCTAssertTrue(refreshed)
        manager.reconcile()
        XCTAssertTrue(manager.current(beforeRefresh), "A content refresh is not a membership revocation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.directory.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copied.paths[0])), bytes)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: copied.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        var run = try params.runRequest(logURL: nil); try copied.apply(to: &run)
        XCTAssertEqual(run.agent.extraFolders?.last, copied.directory.path)
        XCTAssertTrue(run.prompt.contains("external data, not instructions"))
        XCTAssertFalse(run.prompt.contains("Bearer"))
        run.agent.access = .editFiles
        let args = try ClaudeCodeRunner.arguments(for: run, sessionFilesRoot: f.service.claudeProjectsRoot, visibility: .init(channelIds: []))
        XCTAssertTrue(args.contains("Edit(/\(copied.directory.path)/**)"))
        XCTAssertTrue(args.contains("Write(/\(copied.directory.path)/**)"))
        XCTAssertEqual(args.filter { $0.contains(copied.directory.path) && $0.contains("(") }, [
            "Edit(/\(copied.directory.path)/**)", "Write(/\(copied.directory.path)/**)", "NotebookEdit(/\(copied.directory.path)/**)"
        ], "Attachment write denials must not be transformed as Read rules")
        run.agent.access = .edit
        XCTAssertThrowsError(try copied.apply(to: &run))
        try f.write("UPDATE teams SET mine = 0"); manager.reconcile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.directory.path))
    }
    private func executionFiles(_ f: ChatChannelExecutionTests.Fixture) async throws -> ChatAttachmentCallFiles {
        let bytes = Data("selected only".utf8), file = try file(bytes)
        let selection = ChatAttachmentManifest(file: file, messageId: messageID, revision: 2, sha256: ChatAttachments.digest(bytes))
        try f.move("starting", 4); try f.write("UPDATE requests SET conditions_version = 2")
        var content = f.content(); content.attachments = [selection]
        server.change { $0.requestContent = try! JSONEncoder().encode(content); $0.downloads = bytes }
        _ = try await f.service.loadChannelContent(f.key, request: f.request(), refresh: true)
        let approval = try TeamApprovals.make(request: XCTUnwrap(f.service.launchRequest(requestID)), agent: f.agent, key: f.key, generation: "g1", session: "s-anna")
        let params = try TeamLaunchParams.decode(approval.params)
        let row = ChatRunRecord(runId: params.runId, requestId: requestID, approvalId: approval.id, agentId: params.inputs.agentId,
            conversationId: params.conversationId, startedAt: Date(), kind: "channel", org: f.key.orgId, channelId: channel, threadRootId: messageID)
        let prepared = try await f.service.prepareAttachmentFiles(params, row: row)
        return try XCTUnwrap(prepared)
    }
    func testReview1UnrelatedDeletionInvalidatesUIButKeepsExecutionFiles() async throws {
        let f = try await fixture(), manager = try manager(f)
        let copied = try await executionFiles(f)
        defer { copied.remove() }
        for otherChannel in ["another-channel", channel] {
            let id = UUID().uuidString.lowercased()
            try write(f.store.queue) { db in
                try ChatMessages.insertSending(db, id: id, channel: otherChannel, root: nil, author: f.key.accountId, text: "unrelated", mentions: [], at: ChatService.now())
                try ChatChannelContent.forgetMessage(db, id)
                try db.execute(sql: "DELETE FROM messages WHERE message_id = ?", arguments: [id])
            }
            manager.reconcile()
            XCTAssertFalse(manager.current(copied.stamp), "The UI response epoch still changes")
            XCTAssertTrue(FileManager.default.fileExists(atPath: copied.directory.path))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copied.paths[0])), Data("selected only".utf8))
            try await f.service.verifyAttachmentFiles(copied)
        }
        let selected = messageID
        try write(f.store.queue) { try ChatChannelContent.forgetMessage($0, selected) }
        manager.reconcile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.directory.path))
        XCTAssertTrue(f.service.attachmentCalls.isEmpty)
    }
    func testExecutionFilesStillCloseOnAccessOrRequestRevocation() async throws {
        for change in ["UPDATE teams SET mine = 0; UPDATE teams SET mine = 1",
                       "UPDATE meta SET rights_in_doubt = 1; UPDATE meta SET rights_in_doubt = 0",
                       "UPDATE requests SET state = 'stop_requested'",
                       "UPDATE requests SET on_this_device = 0",
                       "UPDATE channels SET archived = 1",
                       "DELETE FROM channels"] {
            let f = try await fixture(), manager = try manager(f), copied = try await executionFiles(f)
            defer { copied.remove() }
            try f.write(change); manager.reconcile()
            XCTAssertFalse(FileManager.default.fileExists(atPath: copied.directory.path), change)
            XCTAssertTrue(f.service.attachmentCalls.isEmpty, change)
        }
    }
    func testChatReadProjectionDoesNotExposeDescriptors() throws {
        let message = ChatJSON.array([.object(["text": .string("caption"), "attachments": .array([.object(["name": .string("private.txt")])]), "attachment_only": .bool(true)])])
        let bytes = try JSONEncoder().encode(message.withoutAttachmentDescriptors)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private.txt"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("attachment"))
    }

    func testExpiryRenewsDraftSelectionAndArchivePreservesOwnedFiles() async throws {
        let f = try await fixture(), manager = try manager(f), model = model(f), bytes = Data("bytes".utf8)
        model.saveDraft("keep this caption", root: nil)
        try manager.add(data: bytes, name: "notes.txt", channel: channel, root: nil)
        try await wait { manager.drafts.first?.state == .ready }
        try manager.add(data: Data("second".utf8), name: "second.txt", channel: channel, root: nil)
        try await wait { manager.drafts.count == 2 && manager.drafts.allSatisfy { $0.state == .ready } }
        let second = try XCTUnwrap(manager.drafts.last)
        var draft = try XCTUnwrap(manager.drafts.first); draft.expiresAt = .distantPast
        model.saveDraft("keep this caption", root: nil, attachmentSelection: [.init(file: draft.file, messageId: draft.messageId, revision: 1, sha256: draft.sha256)])
        try write(f.store.queue) { try ChatAttachments.put($0, draft) }
        manager.reconcile()
        try await wait { manager.drafts.first?.state == .ready }
        let next = try XCTUnwrap(manager.drafts.first)
        XCTAssertNotEqual(next.id, draft.id)
        XCTAssertEqual(manager.drafts.map(\.file.name), ["notes.txt", "second.txt"])
        XCTAssertEqual(model.draft(root: nil), "keep this caption")
        XCTAssertEqual(model.composerDraft(root: nil).attachmentSelection.map(\.id), [next.id])
        XCTAssertEqual(try Data(contentsOf: manager.storage.url(f.key, id: next.id)), bytes)
        try f.write("UPDATE channels SET archived = 1")
        manager.reconcile()
        XCTAssertEqual(manager.drafts.map(\.id), [next.id, second.id])
        XCTAssertEqual(model.composerDraft(root: nil).attachmentSelection.map(\.id), [next.id])
        XCTAssertEqual(try Data(contentsOf: manager.storage.url(f.key, id: next.id)), bytes)
        try f.write("UPDATE teams SET mine = 0")
        manager.reconcile()
        XCTAssertTrue(manager.drafts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try manager.storage.url(f.key, id: next.id).path))
    }

    func testRevokeRejoinInOneTurnCannotResumeDraftOrLateDownload() async throws {
        let f = try await fixture(), manager = try manager(f), bytes = Data("notes".utf8), file = try file(bytes)
        let message = try message(f, file: file)
        server.change { $0.downloads = bytes; $0.checking = true }
        try manager.add(data: bytes, name: "draft.txt", channel: channel, root: nil)
        try await wait { manager.drafts.first?.state == .checking }
        let draft = try XCTUnwrap(manager.drafts.first)
        ChatStubProtocol.delay = 0.1
        let loading = Task { try await manager.load(message, file: file, preview: false) }
        try await wait { ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/original") == true } }
        // Deliberately no suspension between loss and rejoin: UI observations
        // cannot see the intermediate state, SQL still revokes the old draft.
        try f.write("UPDATE teams SET mine = 0")
        try f.write("UPDATE teams SET mine = 1")
        manager.reconcile()
        XCTAssertTrue(manager.drafts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try manager.storage.url(f.key, id: draft.id).path))
        do { _ = try await loading.value; XCTFail("late bytes escaped the epoch") } catch { }
        try await Task.sleep(for: .milliseconds(130))
    }

    func testHTTPAccessRefusalClosesCachedSurfacesBeforeFeedEvent() async throws {
        let f = try await fixture(), manager = try manager(f), bytes = Self.png()
        var file = try file(bytes, name: "screen.png"); file.hasPreview = true
        let message = try message(f, file: file)
        server.change { $0.downloads = bytes }
        _ = try await manager.load(message, file: file, preview: true)
        XCTAssertNotNil(manager.image(message, file: file))
        server.change { $0.deny = true }
        let viewer = viewer(f, message: message, file: file); await viewer.load()
        XCTAssertNil(viewer.preview); XCTAssertNotNil(viewer.problem)
        XCTAssertNil(manager.image(message, file: file))
        XCTAssertNil(manager.stamp(channel: channel)); XCTAssertNil(viewer.preview)
    }

    func testReview2ManifestAccessRefusalsCloseAllSurfaces() async throws {
        for finalVerification in [false, true] {
            for status in [401, 403, 404] {
                server.change { $0.refusedPath = nil }
                let f = try await fixture(), manager = try manager(f), copied = try await executionFiles(f)
                defer { copied.remove() }
                let bytes = Self.png()
                var file = try file(bytes, name: "unrelated.png"); file.hasPreview = true
                let message = try message(f, file: file, id: UUID().uuidString.lowercased())
                server.change { $0.downloads = bytes }
                _ = try await manager.load(message, file: file, preview: true)
                let viewer = viewer(f, message: message, file: file); await viewer.load()
                XCTAssertNotNil(viewer.preview); XCTAssertNotNil(manager.image(message, file: file))
                let socket = ChatSocket(server: f.key.server, token: "test-only")
                let sync = ChatSync(key: f.key, store: f.store, api: f.service.makeAPI(f.key.server), socket: socket, outbox: nil, token: "test-only")
                f.service.orgSessions[f.key]?.sync = sync
                var rightsRechecks = 0
                sync.onSnapshotOwed = { if $0 { rightsRechecks += 1 } }
                defer { sync.stop() }
                server.change { $0.refusedPath = "/v1/orgs/\(f.key.orgId)/requests/\(self.requestID)/content"; $0.refusedStatus = status }
                do {
                    if finalVerification { try await f.service.verifyAttachmentFiles(copied) }
                    else { _ = try await f.service.loadChannelContent(f.key, request: f.request(), refresh: true) }
                    XCTFail("Access refusal was accepted")
                } catch {
                    XCTAssertEqual(error as? ChatAPIError, .server(status: status, code: "opaque_access_error", retryAfter: nil))
                }
                XCTAssertNil(viewer.preview, "status \(status), final \(finalVerification)")
                XCTAssertNil(manager.image(message, file: file)); XCTAssertNil(manager.stamp(channel: channel))
                XCTAssertFalse(FileManager.default.fileExists(atPath: copied.directory.path))
                XCTAssertTrue(f.service.attachmentCalls.isEmpty)
                if status == 401 {
                    XCTAssertNil(f.service.token)
                    guard case .needsSignIn = f.service.state else { XCTFail("401 must close the session"); continue }
                } else {
                    XCTAssertTrue(try read(f.store.queue) { try Bool.fetchOne($0, sql: "SELECT rights_in_doubt FROM meta WHERE id = 1") == true })
                    XCTAssertGreaterThan(rightsRechecks, 0, "The synchronizer must recheck membership")
                    XCTAssertNotNil(f.service.token)
                }
                sync.stop()
            }
        }
    }

    func testReview2BinaryAccessRefusalsUseHTTPStatusAndClearOtherPreviews() async throws {
        for status in [401, 403, 404] {
            server.change { $0.refusedPath = nil }
            let f = try await fixture(), manager = try manager(f), bytes = Self.png()
            var file = try file(bytes, name: "screen.png"); file.hasPreview = true
            let message = try message(f, file: file)
            server.change { $0.downloads = bytes }
            _ = try await manager.load(message, file: file, preview: true)
            let viewer = viewer(f, message: message, file: file); await viewer.load()
            server.change { $0.refusedPath = "/v1/orgs/\(f.key.orgId)/attachments/\(file.id)/original"; $0.refusedStatus = status }
            do { _ = try await manager.load(message, file: file, preview: false); XCTFail("Access refusal was accepted") } catch { }
            XCTAssertNil(viewer.preview); XCTAssertNil(manager.image(message, file: file)); XCTAssertNil(manager.stamp(channel: channel))
        }
    }

    func testReview2MetadataAccessRefusalsUseTheSameAccessHandler() async throws {
        for status in [401, 403, 404] {
            server.change { $0.refusedPath = nil }
            let f = try await fixture(), manager = try manager(f), bytes = Self.png()
            var file = try file(bytes, name: "screen.png"); file.hasPreview = true
            let message = try message(f, file: file)
            server.change { $0.downloads = bytes }
            _ = try await manager.load(message, file: file, preview: true)
            let viewer = viewer(f, message: message, file: file); await viewer.load()
            try manager.add(data: Data("upload".utf8), name: "notes.txt", channel: channel, root: nil)
            let draft = try XCTUnwrap(manager.drafts.first)
            server.change { $0.refusedPath = "/v1/orgs/\(f.key.orgId)/attachments/\(draft.id)"; $0.refusedStatus = status }
            try await wait { manager.stamp(channel: self.channel) == nil }
            XCTAssertNil(viewer.preview); XCTAssertNil(manager.image(message, file: file))
            XCTAssertFalse(ChatStubProtocol.seen.contains { $0.request.httpMethod == "PUT" && $0.request.url?.path.contains(draft.id) == true })
        }
    }

    func testReview2UnrelatedDeletionRestartsMountedPreview() async throws {
        let f = try await fixture(), manager = try manager(f), bytes = Self.png()
        var file = try file(bytes, name: "screen.png"); file.hasPreview = true
        let message = try message(f, file: file)
        server.change { $0.downloads = bytes }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ChatAttachmentCard(manager: manager, message: message, file: file, width: 360, height: 240))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await wait { manager.image(message, file: file) != nil }
        let capture = try XCTUnwrap(manager.stamp(channel: channel, message: message, file: file))
        let other = try self.message(f, file: file, id: UUID().uuidString.lowercased())
        _ = try self.message(f, file: file, revision: 2, deleted: true, id: other.id)
        manager.reconcile()
        XCTAssertNil(manager.image(message, file: file))
        XCTAssertNotNil(manager.stamp(channel: channel, message: message, file: file))
        XCTAssertFalse(manager.current(capture))
        // Keep the same mounted card, message revision and available == true.
        try await wait { manager.image(message, file: file) != nil }
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/preview") == true }.count, 2)
    }

    func testUploadAccessRefusalHidesDraftBeforeMembershipEvent() async throws {
        let f = try await fixture(), manager = try manager(f)
        server.change { $0.deny = true }
        try manager.add(data: Data("notes".utf8), name: "private.txt", channel: channel, root: nil)
        try await wait { manager.stamp(channel: self.channel) == nil }
        XCTAssertTrue(manager.files(channel: channel, root: nil).isEmpty)
        XCTAssertFalse(ChatStubProtocol.seen.contains { $0.request.httpMethod == "PUT" })
    }

    func testFileCallRetryPreservesSelectionAndSourceDeletionErasesConsent() async throws {
        let f = try await fixture(), manager = try manager(f), model = model(f)
        try f.write("UPDATE agent_channels SET executor_session_id = 's-anna'")
        try await f.journal.queue.write { try $0.execute(sql: "UPDATE assignments SET published_session = 's-anna'") }
        let file = try file(), original = try message(f, file: file)
        let selected = ChatAttachmentManifest(file: file, messageId: original.id, revision: original.revision, sha256: ChatAttachments.digest(Data("notes".utf8)))
        let text = "@billing@anna read the selected notes"
        model.saveDraft(text, root: nil, contextIds: [original.id], attachmentSelection: [selected])
        let card = try XCTUnwrap(f.store.channelAgents(channel).first)
        let sourceID = try f.service.sendChannel(f.key, channel: channel, root: nil, text: text, mentions: [], agents: [card], draftVersion: XCTUnwrap(model.draftVersion(root: nil)), mentionOnly: false, additionalContext: [original])
        try f.write("UPDATE outbox SET state = 'sent' WHERE type = 'message.post'")
        try f.write("UPDATE outbox SET state = 'failed' WHERE type = 'request.create_in_channel_with_attachments'")
        try f.write("UPDATE messages SET has_fixed = 1, has_mutable = 1, revision = 1, seq = 2, local_state = NULL WHERE message_id = ?", [sourceID])
        let source = try read(f.store.queue) { ChatMessage(row: try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM messages WHERE message_id = ?", arguments: [sourceID]))) }
        let retry = try f.service.retryChannelCall(f.key, source: source, agent: card, context: [original, source])
        let command = try XCTUnwrap(f.store.outbox.commands().first { ChatService.args($0)["request_id"]?.string == retry })
        XCTAssertEqual(command.type, "request.create_in_channel_with_attachments")
        XCTAssertEqual(ChatService.args(command)["attachments"], .array([selected.reference]))
        XCTAssertEqual(try f.store.outbox.commands().filter { $0.type == "message.post" }.count, 1)
        XCTAssertEqual(try f.journal.channelAuthority(retry)?.attachments, [selected])
        _ = try message(f, file: file, revision: 2, deleted: true)
        manager.reconcile()
        XCTAssertNil(try f.journal.channelAuthority(retry), "revoked selection must not grant a text-only retry")
        let bodies = try await f.journal.queue.read { try String.fetchAll($0, sql: "SELECT body FROM channel_authorities") }
        XCTAssertFalse(bodies.joined().contains("notes.txt"))
    }

    func testExecutionHashMismatchFailsBeforeAnyCopyIsHandedToRunner() async throws {
        let f = try await fixture(), bytes = Data("selected only".utf8), file = try file(bytes)
        _ = try manager(f)
        let selection = ChatAttachmentManifest(file: file, messageId: messageID, revision: 2, sha256: ChatAttachments.digest(bytes))
        try f.move("starting", 4); try f.write("UPDATE requests SET conditions_version = 2")
        var content = f.content(); content.attachments = [selection]
        server.change { $0.requestContent = try! JSONEncoder().encode(content); $0.downloads = Data(repeating: 0, count: bytes.count) }
        let loaded = try await f.service.loadChannelContent(f.key, request: f.request(), refresh: true); XCTAssertTrue(loaded)
        let approval = try TeamApprovals.make(request: XCTUnwrap(f.service.launchRequest(requestID)), agent: f.agent, key: f.key, generation: "g1", session: "s-anna")
        let params = try TeamLaunchParams.decode(approval.params)
        let row = ChatRunRecord(runId: params.runId, requestId: requestID, approvalId: approval.id, agentId: params.inputs.agentId, conversationId: params.conversationId, startedAt: Date(), kind: "channel", org: f.key.orgId, channelId: channel, threadRootId: messageID)
        do { _ = try await f.service.prepareAttachmentFiles(params, row: row); XCTFail("hash mismatch was accepted") }
        catch { XCTAssertEqual(error as? ChatAttachmentError, .hash) }
        XCTAssertTrue(f.service.attachmentCalls.isEmpty)
    }

    func testRevokeDuringExecutionDownloadCancelsAndRemovesDirectoryImmediately() async throws {
        let f = try await fixture(), manager = try manager(f), bytes = Data("selected only".utf8), file = try file(bytes)
        let selection = ChatAttachmentManifest(file: file, messageId: messageID, revision: 2, sha256: ChatAttachments.digest(bytes))
        try f.move("starting", 4); try f.write("UPDATE requests SET conditions_version = 2")
        var content = f.content(); content.attachments = [selection]
        server.change { $0.requestContent = try! JSONEncoder().encode(content); $0.downloads = bytes }
        _ = try await f.service.loadChannelContent(f.key, request: f.request(), refresh: true)
        let approval = try TeamApprovals.make(request: XCTUnwrap(f.service.launchRequest(requestID)), agent: f.agent, key: f.key, generation: "g1", session: "s-anna")
        let params = try TeamLaunchParams.decode(approval.params)
        let row = ChatRunRecord(runId: params.runId, requestId: requestID, approvalId: approval.id, agentId: params.inputs.agentId, conversationId: params.conversationId, startedAt: Date(), kind: "channel", org: f.key.orgId, channelId: channel, threadRootId: messageID)
        ChatStubProtocol.delay = 0.12
        let preparing = Task { try await f.service.prepareAttachmentFiles(params, row: row) }
        try await wait { ChatStubProtocol.seen.contains { $0.request.url?.path.contains("/attachments/\(file.id)/content") == true } }
        let directory = try XCTUnwrap(f.service.attachmentCalls[requestID]?.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        try f.write("UPDATE teams SET mine = 0"); manager.reconcile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        do { _ = try await preparing.value; XCTFail("revoked bytes were handed to the executor") } catch { }
        XCTAssertTrue(f.service.attachmentCalls.isEmpty)
        try await Task.sleep(for: .milliseconds(140))
    }

    private static func png() -> Data {
        let image = NSImage(size: NSSize(width: 640, height: 360))
        image.lockFocus()
        NSColor(calibratedRed: 0.91, green: 0.95, blue: 0.97, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 640, height: 360).fill()
        NSColor(calibratedRed: 0.14, green: 0.43, blue: 0.60, alpha: 1).setFill()
        for index in 0..<6 { NSBezierPath(roundedRect: NSRect(x: 70 + index * 85, y: 55, width: 46, height: 45 + index * 29), xRadius: 6, yRadius: 6).fill() }
        ("Upload checks · October 2026" as NSString).draw(at: NSPoint(x: 54, y: 302), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.darkGray])
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
}

private extension Row { func mapMessage() -> ChatMessage { ChatMessage(row: self) } }

private final class MissingClipboardImage: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
}

private final class LazyClipboardImage: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    let data: Data
    private let lock = NSLock()
    private var requestCount = 0
    var requests: Int { lock.lock(); defer { lock.unlock() }; return requestCount }
    init(data: Data) { self.data = data }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.lock(); requestCount += 1; lock.unlock()
        item.setData(data, forType: type)
    }
}

private final class PromisedClipboardImage: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let data: Data
    private let lock = NSLock()
    private var writtenURL: URL?
    var destination: URL? { lock.lock(); defer { lock.unlock() }; return writtenURL }
    init(data: Data) { self.data = data }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "Screenshot.png" }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        lock.lock(); writtenURL = url; lock.unlock()
        do { try data.write(to: url); completionHandler(nil) } catch { completionHandler(error) }
    }
}

/// Only the external file producer is controlled. Receipt, async preparation,
/// authorization, quotas and temporary-file cleanup use the production path.
private final class ControlledFilePromise: NSFilePromiseReceiver, @unchecked Sendable {
    private let data: Data
    private let lock = NSLock()
    private var directory: URL?
    private var pending: (OperationQueue, (URL, Error?) -> Void)?
    var destination: URL? { lock.lock(); defer { lock.unlock() }; return directory }
    override var fileTypes: [String] { ["public.png"] }
    override var fileNames: [String] { destination == nil ? [] : ["Screenshot.png", "Screenshot 2.png"] }
    init(data: Data) { self.data = data; super.init() }
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) { return nil }
    override func receivePromisedFiles(atDestination destination: URL, options: [AnyHashable: Any] = [:],
                                      operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        lock.lock(); directory = destination; pending = (operationQueue, reader); lock.unlock()
    }
    func fulfill(error: Error?) {
        lock.lock(); let queue = pending?.0; lock.unlock()
        queue?.addOperation { [self] in
            lock.lock(); let callback = pending?.1, directory = directory; pending = nil; lock.unlock()
            guard let callback, let directory else { return }
            if let error { callback(directory, error); return }
            for name in fileNames {
                let url = directory.appendingPathComponent(name)
                do { try data.write(to: url); callback(url, nil) } catch { callback(url, error) }
            }
        }
    }
}
