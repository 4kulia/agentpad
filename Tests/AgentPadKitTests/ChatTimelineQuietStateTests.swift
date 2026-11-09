import AppKit
import AgentPadQuietTestSupport
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor final class ChatTimelineQuietStateTests: XCTestCase {
    private let errorText = "The file could not be transferred. Try again."

    private func capture(_ name: String, me: String) throws -> ChatTimelineReferenceCapture? {
        guard let destination = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_REFERENCE_CAPTURE"] else { return nil }
        return try ChatTimelineReferenceCapture(output: URL(fileURLWithPath: destination)
            .appendingPathComponent("supplemental").appendingPathComponent(name), me: me)
    }

    private func withFixture(_ body: (ChatChannelExecutionTests.Fixture, URL) async throws -> Void) async throws {
        guard APQuietIsEnabled() else { throw NSError(domain: "Run through scripts/test-quiet.py", code: 1) }
        _ = NSApplication.shared
        AgentPadFonts.registerOnce()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhanced = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previousEnhanced, forAttribute: enhanced) }
        let settings = AgentPadSettingsModel.shared
        let paired = settings.pairedThemeSchemaEnabled
        let previous = (settings.appearanceMode, settings.lightTerminalThemeSelection, settings.darkTerminalThemeSelection)
        settings.prepareFirstLaunchAppearance()
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        settings.darkTerminalThemeSelection = AgentPadSettingsModel.defaultDarkThemeSelection
        defer {
            settings.appearanceMode = previous.0
            settings.lightTerminalThemeSelection = previous.1
            settings.darkTerminalThemeSelection = previous.2
            if !paired { settings.load() }
        }
        let scope = TeamServiceTestScope()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("chat-quiet-states-\(UUID())")
        let previousBadgeChanged = ChatNotifications.badgeChanged
        ChatNotifications.badgeChanged = {}
        defer { ChatNotifications.badgeChanged = previousBadgeChanged }
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
        let f = try await ChatChannelExecutionTests.Fixture(root: scratch)
        defer { scope.close(); ChatStubProtocol.reset(); try? FileManager.default.removeItem(at: scratch) }
        do { try await body(f, scratch) }
        catch {
            f.service.attachmentManagers.values.forEach { $0.revoke() }
            f.sender?.hold(); await f.service.disconnect()
            throw error
        }
        f.service.attachmentManagers.values.forEach { $0.revoke() }
        f.sender?.hold(); await f.service.disconnect()
        XCTAssertNil(APQuietFailure())
    }

    private func wait(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while try !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(try condition(), "Production state did not settle before bounded deadline")
        guard try condition() else { throw NSError(domain: "Quiet state timeout", code: 1) }
    }

    private func exists(_ title: String, in host: ChatQuietHost) -> Bool {
        host.nodes.contains { node in
            ["accessibilityLabel", "accessibilityTitle"].contains {
                ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String == title
            }
        }
    }

    private func attachment(_ f: ChatChannelExecutionTests.Fixture) async throws -> (ChatAttachmentManager, ChatMessage, ChatAttachment, Data) {
        let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        f.service.serverCapabilities[f.key.server] = ["chat.attachments", "chat.attachments_context", "chat.channel_ux1"]
        f.service.serverAttachmentLimits[f.key.server] = limits
        f.service.isServerKnown = { _, _ in true }
        let bytes = Data("Synthetic quiet save fixture\n".utf8)
        let file = try ChatAttachmentStorage.descriptor(data: bytes, name: "quiet-notes.txt", limits: limits)
        let seq = try await f.store.queue.read { try Int.fetchOne($0, sql: "SELECT COALESCE(MAX(seq), 0) + 1 FROM messages") ?? 1 }
        let body: [String: Any] = ["message_id": UUID().uuidString.lowercased(), "channel_id": ChatTimelineReferenceFixture.channel,
            "author_account_id": f.key.accountId, "text": "A generic file to save.", "revision": 1, "seq": seq,
            "created_at": ChatTimelineReferenceFixture.date,
            "attachments": try [JSONSerialization.jsonObject(with: JSONEncoder().encode(file))]]
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: body))
        try await f.store.queue.write { _ = try ChatMessages.write($0, wire) }
        let message = try await f.store.queue.read { db in
            ChatMessage(row: try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM messages WHERE message_id = ?", arguments: [wire.messageId])))
        }
        let manager = try XCTUnwrap(f.service.attachments(f.key))
        XCTAssertNotNil(manager.stamp(owner: message.attachmentOwner, message: message, file: file))
        return (manager, message, file, bytes)
    }

    func testGenericSaveUsesActualBusyErrorRetryAndCancelStates() async throws {
        try await withFixture { f, scratch in
            let output = try capture("quiet-save", me: f.key.accountId)
            for dark in [false, true] {
                AgentPadSettingsModel.shared.appearanceMode = dark ? .dark : .light
                XCTAssertEqual(Theme.resolved.isLight, !dark)
                let (manager, message, file, bytes) = try await attachment(f)
                let panel = try ChatQuietSavePanel(directory: scratch.appendingPathComponent("save-\(dark)"))
                defer { panel.close() }
                let previousContent = NativeTabEngine.content
                let previousStores = TabRouter.shared.stores
                let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
                    engineFactory: { XCTFail("Quiet Save must never create a terminal"); return TestEngine() })
                defer {
                    panel.close(); store.terminate()
                    NativeTabEngine.content = previousContent
                    TabRouter.shared.stores = previousStores
                }
                NativeTabEngine.content = { _ in AnyView(ChatAttachmentCard(manager: manager, message: message, file: file,
                    width: 360, height: 52).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(ChatAppearance.surface).environment(\.colorScheme, dark ? .dark : .light)) }
                TabRouter.shared.stores = { [store] }
                let session = store.openToolTab(.unavailable(UUID()))
                let engine = try XCTUnwrap(session.engine as? NativeTabEngine)
                let host = ChatQuietHost(view: engine.view, dark: dark)
                defer { host.close() }
                try await host.settle()
                XCTAssertFalse(session.hasProcess)
                XCTAssertEqual(engine.starts, 0)
                XCTAssertTrue(try host.enabled("Save quiet-notes.txt"))

                ChatStubProtocol.reset { _, _ in .failure(URLError(.timedOut)) }
                try host.press("Save quiet-notes.txt")
                try await wait { panel.pending == 1 }
                try await host.settle()
                XCTAssertFalse(exists("Save quiet-notes.txt", in: host))
                XCTAssertFalse(exists("Retry", in: host))
                XCTAssertFalse(ChatTimelineReferenceCapture.descendants(host.view, NSProgressIndicator.self).isEmpty,
                    "Busy must mount the actual native progress indicator; the card's containing AX element hides its role")
                XCTAssertTrue(ChatStubProtocol.seen.isEmpty, "Held panel must not start the download")
                try host.snapshot(output, id: "save-busy", labels: ["save-busy-spinner"], dark: dark, messages: [message],
                    detail: ["panelDecision": "held public callback adapter", "productionRoute": "AX Save -> real owner -> manager.save"])

                try panel.complete(.cancel)
                try await wait { exists("Save quiet-notes.txt", in: host) }
                XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: panel.output.path))
                XCTAssertFalse(host.strings.contains(errorText))

                try host.press("Save quiet-notes.txt")
                try await wait { panel.pending == 1 }
                try panel.complete(.OK)
                try await wait { host.strings.contains(errorText) && exists("Retry", in: host) }
                try await host.settle()
                XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/original") == true }.count, 1)
                XCTAssertTrue(try host.enabled("Retry"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: panel.output.path))
                try host.snapshot(output, id: "save-error", labels: ["save-error", "save-retry"], dark: dark, messages: [message])

                try host.press("Retry")
                try await wait { panel.pending == 1 }
                try await host.settle()
                XCTAssertFalse(host.strings.contains(errorText))
                XCTAssertFalse(exists("Retry", in: host))
                XCTAssertFalse(exists("Save quiet-notes.txt", in: host))
                try host.snapshot(output, id: "save-retry-busy", labels: ["save-retry", "save-busy-spinner"], dark: dark, messages: [message])
                ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: bytes)) }
                try panel.complete(.OK)
                try await wait { FileManager.default.fileExists(atPath: panel.output.path) && exists("Save quiet-notes.txt", in: host) }
                XCTAssertEqual(try Data(contentsOf: panel.output), bytes)
                XCTAssertFalse(exists("Retry", in: host))
                XCTAssertEqual(panel.calls, 3)
                XCTAssertNil(host.window.attachedSheet)
                XCTAssertFalse(APQuietWindowHasOSFocus(host.window))

                try FileManager.default.removeItem(at: panel.output)
                try host.press("Save quiet-notes.txt")
                try await wait { panel.pending == 1 }
                TabRouter.shared.stores = { [] }
                ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: bytes)) }
                try panel.complete(.OK)
                try await wait { exists("Save quiet-notes.txt", in: host) }
                XCTAssertTrue(ChatStubProtocol.seen.isEmpty, "A removed owner cannot download after held consent")
                XCTAssertFalse(FileManager.default.fileExists(atPath: panel.output.path))
                TabRouter.shared.stores = { [store] }

                try f.store.putRightsInDoubt()
                manager.suspend()
                try await host.settle()
                XCTAssertNil(manager.stamp(owner: message.attachmentOwner, message: message, file: file))
                XCTAssertFalse(try host.enabled("Save quiet-notes.txt"))
                try host.snapshot(output, id: "save-unavailable-leaf", labels: ["save-unavailable"], dark: dark, messages: [message],
                    detail: ["scope": "retained isolated production card; parent timeline normally removes unavailable cards"])
                let parent = ChatQuietHost(content: AnyView(ChatMessageAttachments(manager: manager, message: message)), dark: dark)
                defer { parent.close() }
                try await parent.settle()
                XCTAssertFalse(exists("Save quiet-notes.txt", in: parent))
                // Restore access through the actual store snapshot boundary before the next theme.
                let team = "f5000000-0000-4000-8000-000000000004"
                try f.store.apply(ChatSnapshot(cursors: [:], members: [
                    .init(accountId: f.key.accountId, handle: "anna", name: "Anna", role: "owner"),
                    .init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
                    teams: [.init(teamId: team, name: "Billing", mine: true)],
                    teamMembers: [.init(teamId: team, accountId: f.key.accountId), .init(teamId: team, accountId: CallJSON.boris)],
                    channels: [.init(channelId: message.channelId, teamId: team, name: "billing", archived: false, version: 1)],
                    channelsComplete: true, agentChannels: []), confirmsRights: "s-anna")
            }
            try output?.finish()
        }
    }

    func testSampledAccentAndWorkspaceContrastUseActualProductionColors() async throws {
        try await withFixture { f, _ in
            let output = try capture("quiet-traits", me: f.key.accountId)
            let originalAccent = NSColor.controlAccentColor
            let originalContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let traits = try ChatQuietTraits(accent: NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.90, alpha: 1), increased: false)
            defer { traits.close() }
            for dark in [false, true] {
                AgentPadSettingsModel.shared.appearanceMode = dark ? .dark : .light
                let message = try ChatTimelineReferenceFixture.message("sampled-traits-\(dark)", me: f.key.accountId,
                    text: "@anna [reference](https://example.com/docs)")
                let model = ChatTimelineReferenceModel(f, messages: [message])
                let members = [ChatOrgView.Member(accountId: f.key.accountId, handle: "anna", name: "Anna", role: "owner")]
                var accentSamples: [NSColor] = []
                for after in [false, true] {
                    traits.accent = after ? NSColor(calibratedRed: 0.85, green: 0.15, blue: 0.25, alpha: 1)
                        : NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.90, alpha: 1)
                    traits.increased = false
                    let host = ChatQuietHost(content: AnyView(ChatNativeRowFixture(model: model, message: message, members: members,
                        mentionable: [(f.key.accountId, "anna")], me: f.key.accountId, archived: false, replies: 0, selected: true)
                        .frame(width: 760).background(ChatAppearance.surface)), dark: dark)
                    defer { host.close() }
                    try await host.settle()
                    let text = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host.view, NSTextView.self).first)
                    let attributed = try XCTUnwrap(text.textStorage)
                    let range = (attributed.string as NSString).range(of: "@anna")
                    XCTAssertNotEqual(range.location, NSNotFound)
                    let color = try XCTUnwrap(attributed.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor)
                    let expected = try XCTUnwrap(traits.accent.withAlphaComponent(0.15).usingColorSpace(.deviceRGB))
                    let sampled = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
                    XCTAssertEqual(sampled.redComponent, expected.redComponent, accuracy: 0.0001)
                    XCTAssertEqual(sampled.greenComponent, expected.greenComponent, accuracy: 0.0001)
                    XCTAssertEqual(sampled.blueComponent, expected.blueComponent, accuracy: 0.0001)
                    XCTAssertEqual(sampled.alphaComponent, 0.15, accuracy: 0.0001)
                    XCTAssertEqual(attributed.attribute(.toolTip, at: range.location, effectiveRange: nil) as? String, "@anna")
                    accentSamples.append(sampled)
                    try host.snapshot(output, id: "sampled-accent-\(after ? "after" : "before")", labels: ["accent-only-before-after"], dark: dark, messages: [message],
                        detail: ["traitMode": "sampled-getter-override", "settingsWritten": false, "liveNotifications": false,
                            "liveOSSettingsTransition": false, "remountedHost": true,
                            "originalAccent": originalAccent.description, "originalWorkspaceContrast": originalContrast])
                }
                XCTAssertNotEqual(accentSamples[0], accentSamples[1])
                for increased in [false, true] {
                    traits.increased = increased
                    XCTAssertEqual(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast, increased)
                    let foreground = try XCTUnwrap(NSColor(Theme.chromeForeground).usingColorSpace(.deviceRGB))
                    let border = try XCTUnwrap(NSColor(ChatAppearance.border).usingColorSpace(.deviceRGB))
                    XCTAssertEqual(border.redComponent, foreground.redComponent, accuracy: 0.0001)
                    XCTAssertEqual(border.greenComponent, foreground.greenComponent, accuracy: 0.0001)
                    XCTAssertEqual(border.blueComponent, foreground.blueComponent, accuracy: 0.0001)
                    XCTAssertEqual(border.alphaComponent, foreground.alphaComponent * (increased ? 0.65 : 0.22), accuracy: 0.0001)
                    let host = ChatQuietHost(content: AnyView(ChatReactionChip(b1: ChatB1Channel(key: f.key,
                        channel: message.channelId, store: f.store, service: f.service), message: message.id,
                        reaction: .init(emoji: "👍", count: 3, mine: false), members: members).padding(30)
                        .frame(width: 760, height: 260).background(ChatAppearance.surface)), dark: dark)
                    defer { host.close() }
                    try await host.settle()
                    try host.snapshot(output, id: "sampled-contrast-\(increased ? "after" : "before")",
                        labels: ["increase-contrast-before-after", "increased-contrast-border"], dark: dark, messages: [message],
                        detail: ["traitMode": "sampled-getter-override", "settingsWritten": false, "liveNotifications": false,
                            "sampledBorderOpacity": increased ? 0.65 : 0.22, "scope": "actual production reaction chip border"])
                }
            }
            traits.close()
            XCTAssertEqual(NSColor.controlAccentColor, originalAccent)
            XCTAssertEqual(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast, originalContrast)
            try output?.finish()
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testNativeMenuContractsWithoutTrackingOrClipboardActions() async throws {
        try await withFixture { f, _ in
            let timeKey = "chat.ux2.alwaysShowTime"
            let previous = UserDefaults.standard.object(forKey: timeKey)
            defer {
                if let previous { UserDefaults.standard.set(previous, forKey: timeKey) }
                else { UserDefaults.standard.removeObject(forKey: timeKey) }
            }
            for variant in ["own-channel", "other-channel", "deleted-dm", "loading", "pin", "unpin", "pin-pending"] {
                UserDefaults.standard.set(false, forKey: timeKey)
                var message = try ChatTimelineReferenceFixture.message("quiet-menu-" + variant, me: f.key.accountId,
                    text: "A [reference](https://example.com/docs) menu target.")
                if variant == "other-channel" { message.authorAccountId = CallJSON.boris }
                if variant == "deleted-dm" { message.deletedAt = ChatTimelineReferenceFixture.date }
                if variant == "loading" { message.hasMutable = false }
                let model = ChatTimelineReferenceModel(f, messages: [message])
                model.isDM = variant == "deleted-dm"
                if ["pin", "unpin", "pin-pending"].contains(variant) {
                    f.service.serverCapabilities[f.key.server] = ChatB1.capabilities
                    f.service.isServerKnown = { _, _ in true }
                    let metadata = ChatB1.Metadata(messageId: message.id, deleted: false, reactions: [],
                        pin: variant == "unpin" ? .init(pinnedBy: f.key.accountId, pinnedAt: ChatTimelineReferenceFixture.date) : nil,
                        threadSummary: nil)
                    let target = message
                    try await f.store.queue.write { db in
                        try db.execute(sql: "DELETE FROM b1_metadata")
                        try db.execute(sql: "DELETE FROM b1_intents")
                        try ChatB1.watch(db, channel: target.channelId, ids: [target.id])
                        try db.execute(sql: "UPDATE b1_metadata SET data = ?, dirty = 0, as_of_seq = 3 WHERE message_id = ?",
                            arguments: [try JSONEncoder().encode(metadata), target.id])
                        if variant == "pin-pending" {
                            let command = "quiet-pin-pending"
                            let record = ChatCommandRecord(commandId: command, sessionId: "s-anna", type: "message.pin.set",
                                bodyBytes: Data(), orderKey: command, createdAt: Date(), state: .pending)
                            try record.insert(db)
                            try db.execute(sql: "INSERT INTO b1_intents (command_id, channel_id, message_id, choice, present) VALUES (?, ?, ?, 'pin', 1)",
                                arguments: [command, target.channelId, target.id])
                        }
                    }
                    model.b1 = ChatB1Channel(key: f.key, channel: message.channelId, store: f.store, service: f.service)
                }
                let members = [ChatOrgView.Member(accountId: f.key.accountId, handle: "anna", name: "Anna", role: "owner")]
                let host = ChatQuietHost(content: AnyView(ChatNativeRowFixture(model: model, message: message, members: members,
                    mentionable: [(f.key.accountId, "anna")], me: f.key.accountId, archived: false, replies: 0)
                    .frame(width: 760)), dark: false)
                defer { host.close() }
                try await host.settle()
                let cell = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host.view, ChatNativeShellCell.self).first)
                let menu = try XCTUnwrap(cell.rowActions.makeMenu())
                var expected = ["Reply in Thread", "Open as tab"]
                if variant != "deleted-dm" { expected.append("Copy message link") }
                expected += ["Always show time", "Copy text"]
                if !["other-channel", "deleted-dm", "loading"].contains(variant) { expected.append("Edit") }
                if !["other-channel", "deleted-dm"].contains(variant) { expected.append("Delete…") }
                if ["pin", "unpin", "pin-pending"].contains(variant) {
                    expected = ["Add reaction…", variant == "unpin" ? "Unpin message" : "Pin message"] + expected
                }
                XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), expected)
                let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy text" })
                XCTAssertTrue(copy.isEnabled, "Current source leaves Copy text enabled; loading/deleted action is a no-op")
                XCTAssertEqual(model.copyText(message), ["deleted-dm", "loading"].contains(variant) ? nil : message.text)
                let toggle = try XCTUnwrap(menu.items.first { $0.title == "Always show time" })
                XCTAssertEqual(toggle.state, .off)
                if variant == "own-channel" {
                    menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0 === toggle }))
                    try await wait { UserDefaults.standard.bool(forKey: timeKey) }
                    try await host.settle()
                    let updated = try XCTUnwrap(cell.rowActions.makeMenu())
                    XCTAssertEqual(updated.items.first { $0.title == "Always show time" }?.state, .on)
                    let text = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host.view, NSTextView.self).first)
                    let range = (text.string as NSString).range(of: "reference")
                    XCTAssertNotEqual(range.location, NSNotFound)
                    XCTAssertEqual(text.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) as? URL,
                        URL(string: "https://example.com/docs"))
                    let layout = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
                    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                    let point = text.convert(NSPoint(x: rect.midX + text.textContainerOrigin.x,
                        y: rect.midY + text.textContainerOrigin.y), to: nil)
                    let linkEvent = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
                        modifierFlags: [], timestamp: 0, windowNumber: host.window.windowNumber, context: nil,
                        eventNumber: 2, clickCount: 1, pressure: 1))
                    let nativeMenu = try XCTUnwrap(text.menu(for: linkEvent))
                    XCTAssertFalse(nativeMenu.items.isEmpty, "Default native text menu must materialize without tracking")
                }
                if let b1 = model.b1 {
                    let pin = try XCTUnwrap(menu.items.first { $0.title == "Pin message" || $0.title == "Unpin message" })
                    XCTAssertFalse(pin.isEnabled, "This fixture is disconnected; connected eligibility is covered by existing connected menus")
                    if variant == "pin-pending" { XCTAssertTrue(b1.pending(message.id, choice: "pin")) }
                }
                XCTAssertNil(host.window.attachedSheet)
                XCTAssertNil(APQuietFailure())
            }
        }
    }

    func testAllNativePresentationGapsHaveExplicitContentContracts() throws {
        XCTAssertTrue(APQuietIsEnabled())
        let row = try source("Sources/AgentPadKit/AgentPad/Chat/ChatNativeRowActions.swift")
        let cell = try source("Sources/AgentPadKit/AgentPad/Chat/ChatNativeShellCell.swift")
        let reaction = try source("Sources/AgentPadKit/AgentPad/Chat/ChatNativeMetadataViews.swift")
        let appearance = try source("Sources/AgentPadKit/AgentPad/Chat/ChatAppearance.swift")
        let mention = try source("Sources/AgentPadKit/AgentPad/Chat/ChatMessageText.swift")
        for exact in ["item(\"Always show time\", checked:", "self?.actions?.copyText(messageID: id)",
            "metadata.canChange && metadata.value != nil && !metadata.intents.contains"] {
            XCTAssertTrue(row.contains(exact), "Native row contract changed: \(exact)")
        }
        for exact in ["header.toolTip = content.headerTooltip", "timestamp.toolTip = content.timeTooltip",
            "timestamp.setAccessibilityElement(false)"] {
            XCTAssertTrue(cell.contains(exact), "Native tooltip contract changed: \(exact)")
        }
        for exact in ["Who reacted · right-click for the full list", "override func mouseExited(with event: NSEvent) { clearHover() }",
            "hoverAccounts = []; hoverAccountIDs = []; hoverHasMore = false", "let requestedVersion = b1.state.versions[id]"] {
            XCTAssertTrue(reaction.contains(exact), "Native reaction help contract changed: \(exact)")
        }
        XCTAssertTrue(appearance.contains("NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.65 : 0.22"))
        XCTAssertTrue(mention.contains("accent: NSColor.controlAccentColor.usingColorSpace(.deviceRGB)"))
        let attributed = ChatMentionText.attributed("@anna [reference](https://example.com/docs)", addresses: ["anna"])
        XCTAssertEqual(attributed.attribute(.toolTip, at: 0, effectiveRange: nil) as? String, "@anna")
        let linkRange = (attributed.string as NSString).range(of: "reference")
        XCTAssertEqual(attributed.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL, URL(string: "https://example.com/docs"))
        XCTAssertNil(ChatMentionText.attributed("@anna", addresses: []).attribute(.toolTip, at: 0, effectiveRange: nil))
        XCTAssertNil(APQuietFailure())
    }
}
