import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

final class AvatarTestServer: @unchecked Sendable {
    let lock = NSLock()
    var revision = 0
    var image: String?
    var bytes: Data?
    var applied: [String: Int] = [:]
    var losses = 0
    var lostStatus: Int?
    var rejection: (Int, String, String?)?
    var generation = "g"
    var writes = 0
    let account = "01900000-0000-7000-8000-000000000003"
    func change(_ work: (AvatarTestServer) -> Void) { lock.withLock { work(self) } }
    func answer(_ request: URLRequest, _ data: Data) -> Result<ChatStubProtocol.Answer, URLError> {
        lock.withLock {
            func result(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Result<ChatStubProtocol.Answer, URLError> {
                .success(.init(status: status, headers: headers, body: try! JSONSerialization.data(withJSONObject: object)))
            }
            let path = request.url!.path.components(separatedBy: "/").filter { !$0.isEmpty }
            if path.last != "avatar" {
                guard path.last == image, let bytes else { return result(["error": "not_found"], status: 404) }
                return .success(.init(status: 200, headers: ["Content-Type": "image/png", "X-AgentPad-Generation": generation, "X-Avatar-Revision": String(revision)], body: bytes))
            }
            var receipt: [String: Any] = ["generation": generation, "account_id": account]
            if path.contains("agents") { receipt["org_id"] = path[2]; receipt["agent_id"] = path[4] }
            if request.httpMethod != "GET" {
                if let rejection { return result(["error": rejection.1], status: rejection.0, headers: rejection.2.map { ["Retry-After": $0] } ?? [:]) }
                let id = request.value(forHTTPHeaderField: "X-Command-Id")!
                if applied[id] == nil {
                    guard request.value(forHTTPHeaderField: "If-Match") == "\"\(revision)\"" else { return result(["error": "revision_conflict"], status: 409) }
                    revision += 1; writes += 1
                    image = request.httpMethod == "DELETE" ? nil : ChatUUID.v7()
                    bytes = image == nil ? nil : data
                    applied[id] = revision
                }
                if losses > 0 {
                    losses -= 1
                    if let lostStatus { return result(["error": "gateway_timeout"], status: lostStatus) }
                    return .failure(URLError(.networkConnectionLost))
                }
                receipt["command_id"] = id; receipt["applied_revision"] = applied[id]
            }
            receipt["avatar"] = ["revision": revision, "image_id": image as Any? ?? NSNull()]
            return result(receipt)
        }
    }
}

@MainActor
final class ChatAvatarEditorTests: XCTestCase {
    var fixture: AvatarTestFixture!
    var backend: AvatarTestServer!
    var editor: ChatAvatarEditor!
    override func setUp() async throws {
        fixture = try AvatarTestFixture(); backend = AvatarTestServer()
        let backend = backend!
        ChatStubProtocol.reset { backend.answer($0, $1) }
        editor = ChatAvatarEditor(reference: fixture.own, service: fixture.service)
    }
    override func tearDown() async throws { editor.invalidate(); await fixture.close(); fixture = nil; ChatStubProtocol.delay = 0 }
    func testChangeAndRemoveOnlyConfirmAfterServerWithCASAndFreshImageVersion() async throws {
        await editor.load(); XCTAssertEqual(editor.confirmed?.revision, 0)
        editor.source = try AvatarTestImage.make(noise: true)
        await editor.saveCrop()
        XCTAssertEqual(editor.operation, .saved); XCTAssertEqual(editor.confirmed?.revision, 1)
        XCTAssertNotNil(editor.confirmed?.imageId); XCTAssertNil(editor.source)
        let upload = try XCTUnwrap(ChatStubProtocol.seen.first { $0.request.httpMethod == "PUT" })
        XCTAssertLessThanOrEqual(upload.body.count, 245_760)
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "If-Match"), "\"0\"")
        await editor.remove()
        XCTAssertEqual(editor.operation, .saved); XCTAssertEqual(editor.confirmed?.revision, 2)
        XCTAssertNil(editor.confirmed?.imageId)
        XCTAssertNil(fixture.service.avatars.metadata[fixture.own.subject]?.imageId)
    }
    func testLostResponseChecksExactCommandAndBlocksReplacementUntilResolved() async throws {
        await editor.load(); backend.change { $0.losses = 2 }
        let bytes = try AvatarTestImage.png()
        await editor.save(bytes)
        XCTAssertEqual(editor.operation, .checking)
        let command = try XCTUnwrap(editor.command)
        let count = ChatStubProtocol.seen.count
        await editor.remove(); await editor.save(bytes)
        XCTAssertEqual(ChatStubProtocol.seen.count, count)
        await editor.retry()
        XCTAssertEqual(editor.operation, .saved); XCTAssertNil(editor.command)
        let writes = ChatStubProtocol.seen.filter { $0.request.httpMethod == "PUT" }
        XCTAssertEqual(writes.count, 3)
        XCTAssertTrue(writes.allSatisfy { $0.request.value(forHTTPHeaderField: "X-Command-Id") == command.id && $0.body == bytes })
        backend.change { XCTAssertEqual($0.writes, 1) }
    }
    func testConflictRequiresReloadAndSmallerImageUsesNewCommandAfter413() async throws {
        await editor.load(); backend.change { $0.revision = 3 }
        let bytes = try AvatarTestImage.png()
        await editor.save(bytes)
        guard case .failed(_, .reload) = editor.operation else { return XCTFail("Reload required") }
        let count = ChatStubProtocol.seen.count
        await editor.save(bytes); await editor.retry()
        XCTAssertEqual(ChatStubProtocol.seen.count, count)
        await editor.load(); XCTAssertEqual(editor.confirmed?.revision, 3)
        backend.change { $0.rejection = (413, "too_large", nil) }
        await editor.save(bytes)
        guard case .failed(_, .smaller) = editor.operation else { return XCTFail("Smaller required") }
        let old = try XCTUnwrap(ChatStubProtocol.seen.last?.request.value(forHTTPHeaderField: "X-Command-Id"))
        backend.change { $0.rejection = nil }
        await editor.smaller(); XCTAssertEqual(editor.operation, .saved)
        let next = try XCTUnwrap(ChatStubProtocol.seen.last)
        XCTAssertNotEqual(next.request.value(forHTTPHeaderField: "X-Command-Id"), old)
        XCTAssertEqual(next.request.value(forHTTPHeaderField: "If-Match"), "\"3\"")
        XCTAssertLessThan(try ChatAvatarImage.read(next.body).width, 512)
    }
    func testAmbiguousHTTPFailuresReplayCommittedWriteWithExactCommand() async throws {
        let bytes = try AvatarTestImage.png()
        for status in [408, 500, 502, 503, 504] {
            editor = ChatAvatarEditor(reference: fixture.own, service: fixture.service)
            await editor.load()
            backend.change { $0.losses = 2; $0.lostStatus = status }
            let before = ChatStubProtocol.seen.count
            await editor.save(bytes)
            XCTAssertEqual(editor.operation, .checking, "HTTP \(status) is ambiguous")
            XCTAssertTrue(editor.blocksEditing)
            let command = editor.command
            XCTAssertNotNil(command)
            await editor.retry()
            XCTAssertEqual(editor.operation, .saved)
            XCTAssertNil(editor.command)
            let attempts = Array(ChatStubProtocol.seen.dropFirst(before))
            XCTAssertEqual(attempts.count, 3, "One automatic replay followed by explicit verification")
            XCTAssertTrue(attempts.allSatisfy {
                $0.request.httpMethod == "PUT" && $0.body == bytes &&
                $0.request.value(forHTTPHeaderField: "X-Command-Id") == command?.id &&
                $0.request.value(forHTTPHeaderField: "X-AgentPad-Generation") == command?.generation &&
                $0.request.value(forHTTPHeaderField: "If-Match") == "\"\(command?.expectedRevision ?? -1)\""
            })
            backend.change { XCTAssertEqual($0.writes, $0.revision, "Replays must never apply twice") }
        }
    }
    func testErrorActionsAndRateLimitDoNotCreateBlindRetries() async throws {
        await editor.load()
        let cases: [(Int, String, ChatAvatarEditor.Recovery)] = [(415, "unsupported_media_type", .choose), (409, "storage_quota_exceeded", .smaller), (409, "generation_mismatch", .reload)]
        for (status, code, action) in cases {
            await editor.load()
            backend.change { $0.rejection = (status, code, nil) }
            await editor.save(try AvatarTestImage.png())
            guard case .failed(_, let recovery) = editor.operation else { XCTFail(code); continue }
            XCTAssertEqual(recovery, action)
        }
        await editor.load(); backend.change { $0.rejection = (429, "rate_limited", "60") }
        await editor.save(try AvatarTestImage.png())
        XCTAssertFalse(editor.canRetry)
        let count = ChatStubProtocol.seen.count; await editor.retry()
        XCTAssertEqual(ChatStubProtocol.seen.count, count)
    }
    func testNoCapabilityOrOffNeverProbesAndClosedEditorDropsLateResponse() async throws {
        fixture.service.serverCapabilities[fixture.key.server] = []
        await editor.load(); await editor.save(try AvatarTestImage.png())
        XCTAssertEqual(editor.operation, .unsupported); XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        fixture.service.serverCapabilities[fixture.key.server] = ["chat.avatars"]
        await editor.load(); ChatStubProtocol.delay = 0.04
        let work = Task { await editor.save(try! AvatarTestImage.png()) }
        while !editor.inFlight { await Task.yield() }
        editor.invalidate(); await work.value
        XCTAssertNil(editor.command); XCTAssertNotEqual(editor.operation, .saved)
        XCTAssertNil(fixture.service.avatars.metadata[fixture.own.subject]?.imageId)
    }
    func testLateWriteAfterAccountOrgOrAccessChangeCannotConfirm() async throws {
        await editor.load(); ChatStubProtocol.delay = 0.05
        var confirmations = 0; editor.onConfirmed = { _ in confirmations += 1 }
        let work = Task { await editor.save(try! AvatarTestImage.png()) }
        while !editor.inFlight { await Task.yield() }
        fixture.service.invalidateAvatars()
        await work.value
        XCTAssertEqual(confirmations, 0); XCTAssertNotEqual(editor.operation, .saved)
        XCTAssertNil(editor.command)
        let count = ChatStubProtocol.seen.count
        await editor.retry(); XCTAssertEqual(ChatStubProtocol.seen.count, count)
    }
    func testNewerRemovalDuringWriteIsNeverDeclaredPublished() async throws {
        await editor.load(); ChatStubProtocol.delay = 0.05
        var confirmations = 0; editor.onConfirmed = { _ in confirmations += 1 }
        let work = Task { await editor.save(try! AvatarTestImage.png()) }
        while !editor.inFlight { await Task.yield() }
        fixture.service.avatars.receive(.init(revision: 9, imageId: nil), for: fixture.own, context: fixture.service.avatarContext(fixture.key)!)
        await work.value
        XCTAssertEqual(confirmations, 0)
        XCTAssertEqual(fixture.service.avatars.metadata[fixture.own.subject]?.revision, 9)
        guard case .failed(_, .reload) = editor.operation else { return XCTFail("Reload newer photo") }
    }
    func testAccountAndOperationStatesRenderWithoutVision() async throws {
        let previous = AgentPadSettingsModel.testModel
        defer { AgentPadSettingsModel.testModel = previous }
        await editor.load()
        for dark in [false, true] {
            AgentPadSettingsModel.testModel = AgentPadSettingsModel(read: { ["appearance": ["mode": dark ? "dark" : "light"]] }, write: { _ in }, appliesRuntimeEffects: false)
            let host = NSHostingView(rootView: AccountAvatarForm(key: fixture.key, service: fixture.service).frame(width: 760, height: 620)
                .foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground).environment(\.colorScheme, Theme.chromeColorScheme))
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 620); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let root = ProcessInfo.processInfo.environment["AGENTPAD_TEST_ARTIFACTS"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: root).appendingPathComponent("account-avatar-\(dark ? "dark" : "light").png"))
            }
        }
    }
    func testConfirmationPersistenceFailureRetriesLocallyWithoutAnotherUpload() async throws {
        await editor.load()
        var fail = true, records = 0
        editor.onConfirmed = { _ in records += 1; if fail { throw CocoaError(.fileWriteUnknown) } }
        await editor.save(try AvatarTestImage.png())
        XCTAssertTrue(editor.needsCheck); XCTAssertEqual(records, 1)
        let count = ChatStubProtocol.seen.count
        fail = false; await editor.retry()
        XCTAssertEqual(editor.operation, .saved); XCTAssertEqual(records, 2)
        XCTAssertEqual(ChatStubProtocol.seen.count, count)
    }
    func testCapabilityRestoredAfterLostReplyRequiresReloadInsteadOfReplayingOldEpoch() async throws {
        await editor.load(); backend.change { $0.losses = 2 }
        await editor.save(try AvatarTestImage.png())
        XCTAssertEqual(editor.operation, .checking)
        fixture.service.serverCapabilities[fixture.key.server] = []
        await editor.retry(); XCTAssertEqual(editor.operation, .unsupported)
        fixture.service.serverCapabilities[fixture.key.server] = ["chat.avatars"]
        let count = ChatStubProtocol.seen.count
        await editor.load()
        guard case .failed(_, .reload) = editor.operation else { return XCTFail("Fresh confirmation required") }
        XCTAssertEqual(ChatStubProtocol.seen.count, count); XCTAssertNil(editor.command)
        await editor.load(); XCTAssertEqual(editor.confirmed?.revision, 1)
    }

    func testAccountCropAndOperationBlocksRenderWithoutOCR() async throws {
        func capture(_ content: some View, name: String) throws {
            let host = NSHostingView(rootView: content.padding(24).frame(width: 660, height: 400)
                .foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground).environment(\.colorScheme, Theme.chromeColorScheme))
            host.frame = NSRect(x: 0, y: 0, width: 660, height: 400); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let root = ProcessInfo.processInfo.environment["AGENTPAD_TEST_ARTIFACTS"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: root).appendingPathComponent("avatar-\(name).png"))
            }
        }
        try capture(AvatarCropView(source: AvatarTestImage.make(), crop: .constant(.init()), stableID: "me", name: "You", kind: .person, choose: {}), name: "account-crop")
        await editor.load(); backend.change { $0.losses = 2 }
        await editor.save(try AvatarTestImage.png()); XCTAssertEqual(editor.operation, .checking)
        try capture(AvatarOperationBlock(editor: editor, choose: {}), name: "checking")
        backend.change { $0.rejection = (413, "too_large", nil) }
        await editor.retry()
        try capture(AvatarOperationBlock(editor: editor, choose: {}), name: "error")
        fixture.service.serverCapabilities[fixture.key.server] = []; await editor.load()
        XCTAssertEqual(editor.operation, .unsupported)
        try capture(AvatarOperationBlock(editor: editor, choose: {}), name: "unsupported")
        fixture.service.serverCapabilities[fixture.key.server] = ["chat.avatars"]
        backend.change { $0.rejection = nil }; await editor.load()
        ChatStubProtocol.delay = 0.2
        let saving = Task { await editor.remove() }
        while !editor.inFlight { await Task.yield() }
        XCTAssertEqual(editor.operation, .saving)
        try capture(AvatarOperationBlock(editor: editor, choose: {}), name: "saving")
        await saving.value
    }

}
