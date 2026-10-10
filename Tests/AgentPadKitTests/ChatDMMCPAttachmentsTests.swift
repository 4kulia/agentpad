import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

extension ChatSessionDMToolsTests {
    var dmFile: ChatAttachment {
        .init(attachmentId: "7a7c1c61-1bf9-450b-bec8-a754ed38e530", position: 0,
              name: "../../private.txt", mime: "text/plain", size: 5, hasPreview: false)
    }
    func enableDMAttachments() {
        f.service.serverCapabilities[f.key.server] = ["chat.dm", "chat.dm.session_signature", "chat.attachments", "chat.dm.attachments"]
        var limits = try! JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        limits.dmSenderBytes = 5 * 1024 * 1024 * 1024
        f.service.serverAttachmentLimits[f.key.server] = limits
    }
    func dmAttachmentMessage() -> ChatDMMessageWire {
        .init(messageId: "0192a3b4-5c6d-7e8f-9a0b-1c2d3e4f5b01", dmId: dm,
              authorAccountId: CallJSON.boris, text: "Attachments", mentions: [], revision: 1, seq: 2,
              createdAt: "2026-10-09T00:00:00Z", attachments: [dmFile], attachmentOnly: true)
    }
    func dmAttachmentPage(_ message: ChatDMMessageWire? = nil) throws -> Data {
        try JSONEncoder().encode(ChatDMMessagesPage(messages: [message ?? dmAttachmentMessage()], next: nil, head: 2))
    }
    func serveDMAttachment(_ message: ChatDMMessageWire? = nil) throws {
        let body = try dmAttachmentPage(message)
        ChatStubProtocol.reset { request, _ in
            .success(.init(status: 200, body: request.url!.path.hasSuffix("/original") ? Data("notes".utf8) : body))
        }
    }
    func readDMFile(download: Bool = true, extra: [String: ChatJSON] = [:], waiting: @escaping @MainActor () -> Bool = { true }) async throws -> ChatJSON {
        var args: [String: ChatJSON] = ["tool": .string("chat_read"), "org_id": .string(f.key.orgId), "kind": .string("dm"), "dm_id": .string(dm)]
        if download { args["attachment_id"] = .string(dmFile.id) }
        args.merge(extra) { _, b in b }
        return try await ChatSessionTools.call(.object(args), caller: caller, service: f.service,
            isCallerWaiting: waiting, personalConversation: { .init(self.conversation) }, revalidate: { self.valid })
    }
    func assertNoDMDownload(file: StaticString = #filePath, line: UInt = #line) throws {
        let directory = f.service.files.mcpDownloadsRoot
        if FileManager.default.fileExists(atPath: directory.path) {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [], file: file, line: line)
        }
    }
    func signalDMDeletion(_ message: ChatDMMessageWire) throws {
        try f.store.dmWrite { db in
            _ = try ChatDMStore.apply(db, .init(stream: "member", seq: 20, id: UUID().uuidString, type: "dm.message.delete", actor: nil,
                body: .object(["dm_id": .string(message.dmId), "message_id": .string(message.messageId),
                    "message_seq": .number(Double(message.seq)), "revision": .number(Double(message.revision + 1))]), commandId: nil, at: "2026-10-09T00:00:00Z"))
        }
    }

    func testDMAttachmentPersonalMetadataDownloadAndThreadArePageBoundWithoutReadMarks() async throws {
        try serveDMAttachment()
        let listed = try await readDMFile(download: false)
        guard case .array(let messages) = listed["messages"], case .array(let attachments) = messages.first?["attachments"],
              case .object(let descriptor) = attachments.first else { return XCTFail("Missing descriptor") }
        XCTAssertEqual(Set(descriptor.keys), ["attachment_id", "name", "mime", "size"])
        XCTAssertEqual(descriptor["attachment_id"], .string(dmFile.id))
        XCTAssertEqual(ChatStubProtocol.seen.count, 1, "Listing must not fetch bytes")
        XCTAssertTrue(try ChatDMHistory(files: f.service.files).contains(conversation))
        conversation = UUID().uuidString.lowercased()
        let thread = UUID().uuidString.lowercased()
        var reply = dmAttachmentMessage(); reply.threadRootId = thread
        try serveDMAttachment(reply)
        let downloaded = try await readDMFile(extra: ["thread_root_id": .string(thread), "before": .number(9)])
        let path = try XCTUnwrap(downloaded["path"]?.string), url = URL(fileURLWithPath: path)
        XCTAssertEqual(try Data(contentsOf: url), Data("notes".utf8))
        XCTAssertTrue(path.hasPrefix(f.service.files.mcpDownloadsRoot.path + "/"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertNotNil(downloaded["expires_at"]?.string)
        XCTAssertTrue(ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/threads/\(thread)") == true && $0.request.url?.query == "before=9" })
        XCTAssertTrue(try ChatDMHistory(files: f.service.files).contains(conversation))
        for table in ["dm_marks", "dm_messages", "dm_cards", "dm_notified"] {
            XCTAssertEqual(try f.store.dmRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") }, 0)
        }
        XCTAssertTrue(f.service.attachmentManagers.isEmpty)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        f.service.mcpDownloads.remove(surface: caller.surface)
        try assertNoDMDownload()
    }

    func testDMAttachmentTombstonesAndLegacyServersDoNotExposeDescriptors() async throws {
        var deleted = dmAttachmentMessage(); deleted.deletedAt = "2026-10-09T01:00:00Z"
        try serveDMAttachment(deleted)
        let tombstone = try await readDMFile(download: false)
        guard case .array(let messages) = tombstone["messages"] else { return XCTFail() }
        XCTAssertEqual(messages.first?["attachments"], .array([]))
        XCTAssertEqual(messages.first?["text"], .string(""))
        f.service.serverCapabilities[f.key.server]?.remove("chat.dm.attachments")
        try serveDMAttachment()
        let legacy = try await readDMFile(download: false)
        guard case .array(let messages) = legacy["messages"] else { return XCTFail() }
        XCTAssertEqual(messages.first?["attachments"], .array([]))
        XCTAssertEqual(messages.first?["text"], .string("Attachments"))
        ChatStubProtocol.reset()
        await refused("unsupported") { try await self.readDMFile() }
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
    }

    func testDMAttachmentMissingDeletedForeignThreadOversizedAndStaleNeverFetchOriginal() async throws {
        for mutation in 0..<7 {
            var message = dmAttachmentMessage()
            var extra: [String: ChatJSON] = [:]
            switch mutation {
            case 0: message.attachments = []
            case 1: message.deletedAt = "2026-10-09T01:00:00Z"
            case 2: message.dmId = UUID().uuidString.lowercased()
            case 3: extra["thread_root_id"] = .string(UUID().uuidString.lowercased())
            case 4: message.attachments[0].size = 10 * 1024 * 1024 + 1
            case 5: message.attachments[0].size = 0
            default: try signalDMDeletion(message)
            }
            try serveDMAttachment(message)
            await refused("not_found") { try await self.readDMFile(extra: extra) }
            XCTAssertEqual(ChatStubProtocol.seen.count, 1)
            try assertNoDMDownload()
        }
        XCTAssertFalse(try ChatDMHistory(files: f.service.files).contains(conversation))
    }

    func testDMAttachmentLimitsAndPersonalRoleRefuseBeforeIO() async throws {
        await refused("not_connected") { try await self.readDMFile(extra: ["org_id": .string(UUID().uuidString)]) }
        f.service.serverAttachmentLimits[f.key.server]?.dmSenderBytes = nil
        await refused("unsupported") { try await self.readDMFile() }
        enableDMAttachments()
        valid = false
        await refused("dm_not_allowed") { try await self.readDMFile() }
        valid = true
        f.agent.sessionId = conversation
        await refused("dm_not_allowed") { try await self.readDMFile() }
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        try assertNoDMDownload()
    }

    func testDMAttachmentLateOriginalRechecksIdentityPublicationSettingsAndDeletion() async throws {
        for mutation in 0..<7 {
            valid = true; f.service.dmToolsEnabled = { true }; enableDMAttachments()
            try f.store.dmWrite { try $0.execute(sql: "DELETE FROM dm_revisions") }
            let body = try dmAttachmentPage(), entered = expectation(description: "await original"), gate = Gate()
            gate.close(); defer { gate.open() }
            ChatStubProtocol.reset { request, _ in
                if request.url!.path.hasSuffix("/original") {
                    entered.fulfill(); gate.pass()
                    return .success(.init(status: 200, body: Data("notes".utf8)))
                }
                return .success(.init(status: 200, body: body))
            }
            let task = Task { try await self.readDMFile() }
            await fulfillment(of: [entered], timeout: 3)
            switch mutation {
            case 0: valid = false
            case 1: f.service.dmToolsEnabled = { false }
            case 2: f.service.serverCapabilities[f.key.server]?.remove("chat.dm.attachments")
            case 3: try signalDMDeletion(dmAttachmentMessage())
            case 4: f.service.mcpDownloads.remove(surface: caller.surface)
            case 5: conversation = UUID().uuidString.lowercased()
            default:
                let surface = caller.surface
                try await f.journal.queue.write { db in
                    try db.execute(sql: "INSERT INTO publication_surfaces (server, account_id, org_id, agent_id, surface_id, session_id, generation) VALUES ('s', 'a', 'o', 'agent', ?, 'session', 'generation')", arguments: [surface])
                }
            }
            gate.open()
            do { _ = try await task.value; XCTFail("Late private file escaped") } catch {}
            try assertNoDMDownload()
            XCTAssertFalse(try ChatDMHistory(files: f.service.files).contains(conversation))
        }
    }

    func testDMAttachmentHistoryWriteFailureRemovesFinishedFile() async throws {
        try Data("broken".utf8).write(to: ChatDMHistory(files: f.service.files).url)
        try serveDMAttachment()
        await refused("dm_not_allowed") { try await self.readDMFile() }
        XCTAssertEqual(ChatStubProtocol.seen.count, 2, "The failure happens after preparing the private file")
        try assertNoDMDownload()
    }

    func testDMAttachmentReadOnlyAndChannelEpochKeepFilesButMemberDeletionRemovesThem() async throws {
        var closed = try JSONDecoder().decode(ChatDMCard.self, from: card())
        closed.state = "read_only"; closed.version += 1; closed.peer.active = false
        try f.store.dmWrite { try ChatDMStore.writeCard($0, closed, window: false) }
        try serveDMAttachment()
        let result = try await readDMFile()
        let path = try XCTUnwrap(result["path"]?.string)
        let channelCopy = try f.service.mcpDownloads.reserve(dmFile, surface: caller.surface, key: f.key, store: f.store)
        _ = try f.service.mcpDownloads.finish(channelCopy, bytes: Data("notes".utf8))
        var other = dmAttachmentMessage(); other.dmId = UUID().uuidString.lowercased()
        try signalDMDeletion(other)
        try f.store.dmWrite {
            try $0.execute(sql: "UPDATE meta SET channel_access_epoch = channel_access_epoch + 1")
            _ = try ChatDMStore.advance($0)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "DM reading does not use channel access")
        XCTAssertFalse(FileManager.default.fileExists(atPath: channelCopy.path.path), "Channel copies still use channel access")
        XCTAssertEqual(try f.store.dmRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dm_messages") }, 0)
        try signalDMDeletion(dmAttachmentMessage())
        for _ in 0..<50 where FileManager.default.fileExists(atPath: path) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Uncached member deletion must remove MCP originals")
    }

    func testDMAttachmentQuotaCapabilityAndSettingCleanupShareDownloadStorage() async throws {
        f.service.mcpDownloads.quota = dmFile.size
        try serveDMAttachment()
        _ = try await readDMFile()
        await refused("download_limit") { try await self.readDMFile() }
        f.service.serverCapabilities[f.key.server]?.remove("chat.dm.attachments")
        try assertNoDMDownload()
        enableDMAttachments()
        _ = try await readDMFile()
        f.service.dmToolsEnabled = { false }
        try assertNoDMDownload()
    }

    func testDMAttachmentTimeoutAndIPCCancelLeaveNoReservation() async throws {
        try serveDMAttachment()
        ChatStubProtocol.delay = 0.1
        f.service.mcpDownloadDeadline = 0.02
        await refused("download_timeout") { try await self.readDMFile() }
        try assertNoDMDownload()
        do { _ = try await readDMFile(waiting: { false }); XCTFail("Cancelled IPC downloaded") } catch {}
        try assertNoDMDownload()
        XCTAssertFalse(try ChatDMHistory(files: f.service.files).contains(conversation))
    }
}
