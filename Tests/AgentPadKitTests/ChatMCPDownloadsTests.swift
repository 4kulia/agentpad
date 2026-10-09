import Darwin
import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatMCPDownloadsTests: XCTestCase {
    var root: URL!
    var f: ChatChannelExecutionTests.Fixture!
    let channel = "f5000000-0000-4000-8000-000000000001"
    let conversation = UUID().uuidString.lowercased()
    let caller = ChatLocalCaller(surface: UUID().uuidString.lowercased(), claudePID: 321, claudeStart: 123, signature: "Personal")
    var file: ChatAttachment!
    var waiting = true
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-download-\(UUID())")
        f = try await ChatChannelExecutionTests.Fixture(root: root)
        f.service.isServerKnown = { _, _ in true }
        f.service.serverCapabilities[f.key.server] = ["chat.session_tools", "chat.attachments"]
        f.service.serverAttachmentLimits[f.key.server] = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        file = ChatAttachment(attachmentId: UUID().uuidString.lowercased(), position: 0, name: "../../outside.txt", mime: "text/plain", size: 5, hasPreview: false)
    }
    override func tearDown() async throws {
        await f?.service.disconnect(); f = nil; ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }
    func page(deleted: Bool = false, other: Bool = false) throws -> Data {
        let descriptor = String(decoding: try JSONEncoder().encode(file), as: UTF8.self)
        return Data("""
        {"messages":[{"message_id":"\(UUID())","channel_id":"\(other ? UUID().uuidString : channel)","author_account_id":"\(CallJSON.boris)","text":"notes","mentions":[],"revision":1,"seq":1,"created_at":"2026-10-09T00:00:00Z","deleted_at":\(deleted ? "\"2026-10-09T01:00:00Z\"" : "null"),"attachments":[\(descriptor)]}],"next":null}
        """.utf8)
    }
    func call(download: Bool = true, extra: [String: ChatJSON] = [:]) async throws -> ChatJSON {
        var args: [String: ChatJSON] = ["tool": .string("chat_read"), "org_id": .string(f.key.orgId), "channel_id": .string(channel)]
        if download { args["attachment_id"] = .string(file.id) }
        args.merge(extra) { _, b in b }
        return try await ChatSessionTools.call(.object(args), caller: caller, service: f.service,
            isCallerWaiting: { self.waiting }, personalConversation: { .init(self.conversation) }, revalidate: { true })
    }
    func testChannelMetadataAndOriginalArePageBoundPrivateFilesWithoutReadMarks() async throws {
        let body = try page(), id = file.id
        ChatStubProtocol.reset { request, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
            if request.url!.path.hasSuffix("/original") {
                XCTAssertTrue(request.url!.path.contains(id))
                return .success(.init(status: 200, body: Data("notes".utf8)))
            }
            return .success(.init(status: 200, body: body))
        }
        let page = try await call(download: false)
        guard case .array(let messages) = page["messages"], case .array(let attachments) = messages.first?["attachments"],
              case .object(let metadata) = attachments.first else { return XCTFail() }
        XCTAssertEqual(Set(metadata.keys), ["attachment_id", "name", "mime", "size"])
        let result = try await call(extra: ["before": .number(2)])
        let path = try XCTUnwrap(result["path"]?.string), url = URL(fileURLWithPath: path)
        XCTAssertEqual(try Data(contentsOf: url), Data("notes".utf8))
        XCTAssertTrue(path.hasPrefix(f.service.files.mcpDownloadsRoot.path + "/"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertNotNil(result["expires_at"]?.string.flatMap { ISO8601DateFormatter().date(from: $0) })
        XCTAssertTrue(ChatStubProtocol.seen.contains { $0.request.url?.query == "before=2" })
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        f.service.mcpDownloads.remove(surface: caller.surface)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
    func testMissingDeletedWrongPageAndPublishedSourceNeverDownload() async throws {
        for (deleted, other) in [(true, false), (false, true)] {
            let body = try page(deleted: deleted, other: other)
            ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: body)) }
            do { _ = try await call(); XCTFail() } catch {}
            XCTAssertEqual(ChatStubProtocol.seen.count, 1)
        }
        f.agent.sessionId = conversation; f.agent.enabled = false
        ChatStubProtocol.reset()
        do { _ = try await call(); XCTFail() } catch { XCTAssertEqual((error as? ChatSessionTools.Failure)?.code, "dm_not_allowed") }
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
    }
    func testPersonalDownloadAfterClearOrResumeDoesNotInheritPreviousRunDenial() async throws {
        let process = AnswerProcessFixture()
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode)
        let executor = UUID().uuidString.lowercased(), personal = UUID().uuidString.lowercased()
        let caller = ChatLocalCaller(surface: tab.id.uuidString.lowercased(), claudePID: AnswerProcessFixture.claude,
                                     claudeStart: 100, signature: "Personal")
        try await f.journal.queue.write { db in
            try db.execute(sql: "INSERT INTO approvals (id, server, account_id, org_id, request_id, agent_id, kind, params, params_hash, run_id, start_command_id, generation, created_at) VALUES ('a', 's', 'a', 'o', 'r', 'agent', 'personal', '{}', 'hash', 'run', 'cmd', 'g', ?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO runs (run_id, request_id, approval_id, agent_id, conversation_id, started_at, ended_at, kind) VALUES ('run', 'r', 'a', 'agent', ?, ?, ?, 'personal')", arguments: [executor, Date(), Date()])
        }
        func bind(_ id: String) throws {
            try process.bind(tab, conversation: id)
            tab.conversationId = id
        }
        func download() async throws -> ChatJSON {
            try await ChatSessionTools.call(.object(["tool": .string("chat_read"), "org_id": .string(f.key.orgId),
                "channel_id": .string(channel), "attachment_id": .string(file.id)]), caller: caller, service: f.service,
                personalConversation: { try ChatPersonalAccess.conversation(caller: caller, sessions: [tab]) }, revalidate: { true })
        }
        try bind(personal)
        let body = try page()
        for next in [UUID().uuidString.lowercased(), personal] {
            try bind(executor)
            ChatStubProtocol.reset()
            do { _ = try await download(); XCTFail("Executor history downloaded a file") }
            catch { XCTAssertEqual((error as? ChatSessionTools.Failure)?.code, "dm_not_allowed") }
            XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
            try bind(next)
            ChatStubProtocol.reset { request, _ in
                .success(.init(status: 200, body: request.url!.path.hasSuffix("/original") ? Data("notes".utf8) : body))
            }
            let result = try await download()
            let path = try XCTUnwrap(result["path"]?.string)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("notes".utf8))
            XCTAssertEqual(ChatStubProtocol.seen.count, 2)
        }
    }

    func testExclusiveNoFollowWriterQuotaTTLAndStartupCleanup() throws {
        let downloads = f.service.mcpDownloads
        downloads.quota = 10
        let first = try downloads.reserve(file, surface: caller.surface, key: f.key, store: f.store)
        let second = try downloads.reserve(file, surface: caller.surface, key: f.key, store: f.store)
        XCTAssertThrowsError(try downloads.reserve(file, surface: caller.surface, key: f.key, store: f.store)) {
            XCTAssertEqual(($0 as? ChatSessionTools.Failure)?.code, "download_limit")
        }
        let outside = root.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: first.path, withDestinationURL: outside)
        XCTAssertThrowsError(try downloads.finish(first, bytes: Data("notes".utf8)))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
        downloads.remove(first)
        _ = try downloads.finish(second, bytes: Data("notes".utf8))
        XCTAssertThrowsError(try downloads.finish(second, bytes: Data("other".utf8)))
        downloads.now = { second.expires.addingTimeInterval(1) }
        downloads.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path.path))
        let third = try downloads.reserve(file, surface: caller.surface, key: f.key, store: f.store)
        _ = try downloads.finish(third, bytes: Data("notes".utf8))
        _ = ChatMCPDownloads(root: downloads.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: third.path.path))
        try FileManager.default.removeItem(at: downloads.root)
        try FileManager.default.createSymbolicLink(at: downloads.root, withDestinationURL: root)
        XCTAssertThrowsError(try downloads.reserve(file, surface: caller.surface, key: f.key, store: f.store))
        downloads.removeAll()
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
    }
    func testRevocationAndDisconnectRemoveExistingFiles() async throws {
        let downloads = f.service.mcpDownloads
        let first = try downloads.reserve(file, surface: caller.surface, key: f.key, store: f.store)
        _ = try downloads.finish(first, bytes: Data("notes".utf8))
        try f.store.putRightsInDoubt()
        for _ in 0..<50 where FileManager.default.fileExists(atPath: first.path.path) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path.path))
        let second = try downloads.reserve(file, surface: caller.surface, key: f.key, store: f.store)
        _ = try downloads.finish(second, bytes: Data("notes".utf8))
        f.service.invalidateAttachments()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path.path))
    }
    func testRevocationDuringOriginalTransferDiscardsBytesAndReservation() async throws {
        let body = try page(), gate = Gate(), entered = expectation(description: "original awaited")
        gate.close(); defer { gate.open() }
        ChatStubProtocol.reset { request, _ in
            if request.url!.path.hasSuffix("/original") {
                entered.fulfill(); gate.pass()
                return .success(.init(status: 200, body: Data("notes".utf8)))
            }
            return .success(.init(status: 200, body: body))
        }
        let task = Task { try await self.call() }
        await fulfillment(of: [entered], timeout: 3)
        try f.store.putRightsInDoubt()
        gate.open()
        do { _ = try await task.value; XCTFail("Revoked file escaped") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.service.mcpDownloads.root.path), [])
    }
    func testDeadlineAndCancellationCoverTheWholeOperation() async throws {
        for cancelled in [false, true] {
            do {
                _ = try await ChatSessionTools.withDownloadDeadline(seconds: 0.02, isCallerWaiting: { !cancelled }) {
                    try await Task.sleep(for: .seconds(30)); return .null
                }
                XCTFail("No deadline")
            } catch {
                if cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual((error as? ChatSessionTools.Failure)?.code, "download_timeout") }
            }
        }
        let reservation = try f.service.mcpDownloads.reserve(file, surface: caller.surface, key: f.key, store: f.store)
        XCTAssertThrowsError(try f.service.mcpDownloads.finish(reservation, bytes: Data("oversized".utf8)))
        f.service.mcpDownloads.remove(reservation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.path.deletingLastPathComponent().path))
    }
}
