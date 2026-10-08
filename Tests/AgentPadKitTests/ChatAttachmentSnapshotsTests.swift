import AppKit
import Foundation
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

/// Real AppKit windows hosting the production SwiftUI components. Synthetic
/// organization/content only; no production account, cache or server is used.
@MainActor final class ChatAttachmentSnapshotsTests: XCTestCase {
    func testNativeAttachmentSnapshots() async throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTPAD_ATTACHMENT_CAPTURE"] else { throw XCTSkip("Native attachment snapshots are opt-in") }
        ChatNotifications.badgeChanged = {}
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("att-native-" + UUID().uuidString)
        let f = try await ChatChannelExecutionTests.Fixture(root: root)
        let oldService = TeamService.sharedForTesting
        TeamService.sharedForTesting = f.teamService
        defer { TeamService.sharedForTesting = oldService }
        ChatOrgCurrent.shared.refresh(f.service)
        defer { ChatOrgCurrent.shared.refresh() }
        defer { f.service.attachmentManagers.values.forEach { $0.revoke() }; ChatStubProtocol.reset(); try? FileManager.default.removeItem(at: root) }
        let channel = "f5000000-0000-4000-8000-000000000001", messageID = "f5000000-0000-4000-8000-000000000002"
        let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        f.service.serverCapabilities[f.key.server] = ["chat.attachments", "chat.attachments_context", "chat.channel_ux1"]
        f.service.serverAttachmentLimits[f.key.server] = limits
        f.service.isServerKnown = { _, _ in true }
        let model = ChatChannelModel(key: f.key, channel: channel); model.service = f.service; model.follow(f.store)
        let manager = try XCTUnwrap(f.service.attachments(f.key))
        let png = Self.png()
        var picture = try ChatAttachmentStorage.descriptor(data: png, name: "upload-checks.png", limits: limits); picture.hasPreview = true
        var note = try ChatAttachmentStorage.descriptor(data: Data("Verification notes\n".utf8), name: "verification-notes.txt", limits: limits); note.position = 1
        let body: [String: Any] = ["message_id": messageID, "channel_id": channel, "author_account_id": f.key.accountId,
            "text": "Upload checks are complete. The screenshot and notes are attached below.", "revision": 1, "seq": 1,
            "created_at": "2026-10-07T12:00:00Z", "attachments": try [picture, note].map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: body))
        try await f.store.queue.write { _ = try ChatMessages.write($0, wire) }
        let message = try await f.store.queue.read { ChatMessage(row: try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM messages WHERE message_id = ?", arguments: [messageID]))) }
        ChatStubProtocol.reset { request, _ in .success(.init(status: 200, body: request.url?.path.hasSuffix("/original") == true || request.url?.path.hasSuffix("/preview") == true ? png : Data(#"{"events":[],"result":{}}"#.utf8))) }
        _ = try await manager.load(message, file: picture, preview: true)
        let draftData = Data("Client protocol checks passed.\n".utf8)
        let draftFile = try ChatAttachmentStorage.descriptor(data: draftData, name: "client-checks.txt", limits: limits)
        let draft = ChatAttachmentDraft(file: draftFile, messageId: UUID().uuidString.lowercased(), channel: channel, root: "", session: "s-anna", generation: "g1",
            sha256: ChatAttachments.digest(draftData), createdAt: Date(), expiresAt: Date().addingTimeInterval(86000), state: .ready, progress: 1)
        try manager.storage.save(draftData, key: f.key, id: draft.id)
        try await f.store.queue.write { try ChatAttachments.put($0, draft); try ChatAttachments.bumpDraft($0, channel: channel, root: "") }
        model.saveDraft("Here are the client checks. I’ll add the final screenshot next.", root: nil)
        manager.reconcile()
        let members = [ChatOrgView.Member(accountId: f.key.accountId, handle: "anna", name: "Anna", role: "owner")]
        let settings = AgentPadSettingsModel.shared
        let previous = settings.appearanceMode
        defer { settings.appearanceMode = previous }
        for dark in [false, true] {
            settings.appearanceMode = dark ? .dark : .light
            let view = VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("# billing").font(Theme.display(19, weight: .semibold))
                    Spacer()
                    Label("Connected", systemImage: "checkmark.circle.fill").font(Theme.display(11)).foregroundStyle(ChatAppearance.success)
                }.padding(24)
                Divider()
                ChatMessageRow(model: model, message: message, members: members, mentionable: [], me: f.key.accountId, archived: false, replies: 0)
                Spacer(minLength: 20)
                Divider()
                ChatUX1Composer(model: model, root: nil, members: members, mentionable: [], agents: [])
            }.frame(width: 900, height: 780).background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
                .environment(\.colorScheme, dark ? .dark : .light)
            try await capture(view, output: output, name: dark ? "r116-att-dark" : "r116-att-light", dark: dark)
        }
        settings.appearanceMode = .light
        try await manager.open(message, file: picture)
        try await capture(ChatAttachmentViewer(manager: manager, message: message, file: picture), output: output, name: "r116-att-viewer", dark: false)
        await f.service.disconnect()
    }
    private func capture(_ view: some View, output: String, name: String, dark: Bool) async throws {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        var captured: Data?
        // AppKit can cache the SwiftUI image layer before its pixels have been
        // composited. Require the fixture's blue chart, not merely its pale
        // background, before accepting a native screenshot.
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var chartPixels = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.blueComponent > color.redComponent * 1.5,
                       color.blueComponent > color.greenComponent * 1.05 { chartPixels += 1 }
                }
            }
            if chartPixels > 200 { captured = bitmap.representation(using: .png, properties: [:]); break }
        }
        try XCTUnwrap(captured, "Native image pixels did not settle").write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
    private static func png() -> Data {
        let image = NSImage(size: NSSize(width: 640, height: 320)); image.lockFocus()
        NSColor(calibratedRed: 0.92, green: 0.96, blue: 0.97, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 640, height: 320).fill()
        NSColor(calibratedRed: 0.17, green: 0.48, blue: 0.64, alpha: 1).setFill()
        for index in 0..<6 { NSBezierPath(roundedRect: NSRect(x: 62 + index * 86, y: 45, width: 52, height: 44 + index * 30), xRadius: 6, yRadius: 6).fill() }
        ("Upload checks · October 2026" as NSString).draw(at: NSPoint(x: 46, y: 267), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.darkGray])
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
}
