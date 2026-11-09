import AppKit
import AgentPadQuietTestSupport
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor final class ChatTimelineReferenceTests: XCTestCase {
    func testCurrentTimelineReferenceCaptures() async throws {
        guard let destination = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_REFERENCE_CAPTURE"] else { throw XCTSkip("Reference bitmap production is opt-in") }
        guard APQuietIsEnabled() else { throw NSError(domain: "Run reference capture through scripts/test-quiet.py", code: 1) }
        ChatScrollAppKitSettings.install()
        AgentPadFonts.registerOnce()
        _ = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhancedUI = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previousEnhancedUI, forAttribute: enhancedUI) }
        let scope = TeamServiceTestScope()
        let previousBadgeChanged = ChatNotifications.badgeChanged
        ChatNotifications.badgeChanged = {}
        defer { ChatNotifications.badgeChanged = previousBadgeChanged }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("chat-timeline-reference-\(UUID())")
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
        let fixture = try await ChatChannelExecutionTests.Fixture(root: scratch)
        defer { scope.close(); ChatStubProtocol.reset(); try? FileManager.default.removeItem(at: scratch) }
        let previousTeam = TeamService.sharedForTesting
        TeamService.sharedForTesting = fixture.teamService
        defer { TeamService.sharedForTesting = previousTeam; ChatOrgCurrent.shared.refresh() }
        ChatOrgCurrent.shared.refresh(fixture.service)
        let settings = AgentPadSettingsModel.shared
        let previous = (settings.appearanceMode, settings.lightTerminalThemeSelection, settings.darkTerminalThemeSelection)
        let previousPairedSchema = settings.pairedThemeSchemaEnabled
        settings.prepareFirstLaunchAppearance()
        let oldTime = UserDefaults.standard.object(forKey: "chat.ux2.alwaysShowTime")
        defer {
            if !previousPairedSchema { settings.load() }
            settings.appearanceMode = previous.0; settings.lightTerminalThemeSelection = previous.1; settings.darkTerminalThemeSelection = previous.2
            if let oldTime { UserDefaults.standard.set(oldTime, forKey: "chat.ux2.alwaysShowTime") }
            else { UserDefaults.standard.removeObject(forKey: "chat.ux2.alwaysShowTime") }
        }
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        settings.darkTerminalThemeSelection = AgentPadSettingsModel.defaultDarkThemeSelection
        UserDefaults.standard.set(false, forKey: "chat.ux2.alwaysShowTime")
        let capture = try ChatTimelineReferenceCapture(output: URL(fileURLWithPath: destination), me: fixture.key.accountId)
        do {
            for dark in [false, true] {
                settings.appearanceMode = dark ? .dark : .light
                XCTAssertEqual(Theme.resolved.isLight, !dark)
                if ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_REFERENCE_DRAFTS_ONLY"] == "1" {
                    try await productionChromeAndMembership(capture, fixture: fixture, dark: dark)
                    continue
                }
                if ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_REFERENCE_VIEWPORT_ONLY"] == "1" {
                    try await ChatTimelineReferenceVariants.viewportOnly(capture, fixture: fixture, dark: dark)
                    continue
                }
                try await textAndStateMatrix(capture, fixture: fixture, dark: dark)
                try await timelineMatrix(capture, fixture: fixture, dark: dark)
                try await metadataMatrix(capture, fixture: fixture, dark: dark)
                try await interactionMatrix(capture, fixture: fixture, dark: dark)
                try await attachmentMatrix(capture, fixture: fixture, dark: dark)
                try await confirmationMatrix(capture, fixture: fixture, dark: dark)
                try await sourceAndBoundaryMatrix(capture, fixture: fixture, dark: dark)
                try await productionChromeAndMembership(capture, fixture: fixture, dark: dark)
                try await replyAndSummaryVariants(capture, fixture: fixture, dark: dark)
                try await mediaGeometryAndViewer(capture, fixture: fixture, dark: dark)
                try await auxiliaryAndAppearanceVariants(capture, fixture: fixture, dark: dark)
                try await remainingChromeAndAsk(capture, fixture: fixture, dark: dark)
                try await remainingReachableStates(capture, fixture: fixture, dark: dark)
                try await retainedSessionAndPublication(capture, outerService: fixture.service, dark: dark)
                try await ChatTimelineReferenceVariants.run(capture, fixture: fixture, dark: dark)
                try await ChatTimelineReferenceGrouping.run(capture, fixture: fixture, dark: dark)
            }
            try capture.finish()
        } catch {
            print("CHAT REFERENCE FAILED after \(capture.records.last?["captureID"] ?? "no capture"): \(error)")
            fixture.service.attachmentManagers.values.forEach { $0.revoke() }
            fixture.sender?.hold(); await fixture.service.disconnect()
            throw error
        }
        fixture.service.attachmentManagers.values.forEach { $0.revoke() }
        fixture.sender?.hold(); await fixture.service.disconnect()
        let subset = ["AGENTPAD_CHAT_NATIVE_REFERENCE_VIEWPORT_ONLY", "AGENTPAD_CHAT_NATIVE_REFERENCE_DRAFTS_ONLY"]
            .contains { ProcessInfo.processInfo.environment[$0] == "1" }
        XCTAssertGreaterThan(capture.records.count, subset ? 0 : 200)
        XCTAssertNil(APQuietFailure())
    }

    private func textAndStateMatrix(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let plain = try ChatTimelineReferenceFixture.message("reference-plain", me: f.key.accountId)
        var cases: [(String, ChatMessage, [String])] = [("plain", plain, ["R01", "R03", "R04", "R05", "R11"])]
        let texts: [(String, String, [String])] = [
            ("long-markdown", String(repeating: "A **long formatted** paragraph with *emphasis*, ~~removed words~~ and `inline_code`. ", count: 9), ["R11", "R13"]),
            ("headings", "# Heading one\n## Heading two\n### Heading three\n#### Heading four\n##### Heading five\n###### Heading six\n\nParagraph after headings.", ["R12"]),
            ("code", "```swift\nlet values = [1, 2, 3]\nfor value in values {\n    print(\"value: \\(value)\")\n}\n```", ["R12", "R13"]),
            ("lists", "- first\n  - nested\n    continuation\n- [x] checked\n- [ ] unchecked\n\n3. first ordered\n4. second ordered", ["R13"]),
            ("quote-table-rule", "> quotation\n> > nested quotation\n\n| First | Second |\n| --- | --- |\n| value | other |\n\n---", ["R12", "R13"]),
            ("links-mentions", "@anna and @BORIS: [safe web](https://example.com/docs) [email](mailto:hello@example.com), [refused](javascript:alert(1)) and `@anna`.", ["R15", "R16"]),
            ("literal-media-html-nul", "![literal image](https://example.invalid/image.png) <b>literal HTML</b>\u{0000} stays text.", ["R14"]),
            ("unicode-wrap", "English 👩🏽‍💻 e\u{301} العربية עברית 日本語\n" + String(repeating: "long_unbroken_word_", count: 24), ["R11"])
        ]
        for (name, text, ids) in texts { var m = plain; m.messageId = "reference-" + name; m.text = text; cases.append((name, m, ids)) }
        var deleted = plain; deleted.messageId = "reference-deleted"; deleted.deletedAt = "2026-10-08T10:00:00Z"
        var loading = plain; loading.messageId = "reference-loading"; loading.hasMutable = false
        var stale = plain; stale.messageId = "reference-stale"; stale.stale = 4
        var sending = plain; sending.messageId = "reference-sending"; sending.seq = nil; sending.localState = .sending
        var failed = plain; failed.messageId = "reference-failed"; failed.seq = nil; failed.localState = .failed; failed.localError = "connection_lost"
        var edited = plain; edited.messageId = "reference-edited"; edited.editedAt = "2026-10-08T10:00:00Z"
        cases += [("deleted", deleted, ["R17"]), ("loading", loading, ["R17"]), ("stale", stale, ["R17"]),
                  ("sending", sending, ["R18"]), ("failed", failed, ["R18"]), ("edited", edited, ["R18"])]
        for (kind, state, error) in [("edit", "saving", nil), ("delete", "saving", nil), ("edit", "failed", "revision_conflict"),
                                     ("delete", "failed", "access_denied"), ("edit", "failed", "connection_lost")] as [(String, String, String?)] {
            var m = plain; m.messageId = "reference-\(kind)-\(state)-\(error ?? "none")"
            m.localEdit = .init(kind: kind, text: "Retained failed edit text", state: state, error: error)
            cases.append(("\(kind)-\(state)-\(error ?? "none")", m, state == "saving" ? ["R18"] : ["R19"]))
        }
        for (name, who, agent, session) in [("former", "former-account", nil, nil), ("published-agent", f.key.accountId, CallJSON.agent, nil),
                                            ("legacy-signature", f.key.accountId, nil, "Legacy assistant")] as [(String, String, String?, String?)] {
            var m = plain; m.messageId = "reference-" + name; m.authorAccountId = who; m.authorAgentId = agent
            m.authorAgentName = agent == nil ? nil : "Billing agent"; m.authorSessionName = session
            cases.append((name, m, ["R06", "R07", "R08"]))
        }
        for width: CGFloat in [760, 420] {
            let thread = width == 420
            for (name, m, ids) in cases {
                let model = ChatTimelineReferenceModel(f, messages: [m]); model.threadRoot = thread ? m.id : nil
                try await c.capture(name, inventory: ids, model: model, messages: [m], width: width, dark: dark,
                    content: c.row(model, message: m, width: width, thread: thread))
            }
            for state in ["grouped", "selected", "edit", "edit-error", "archived-edit", "time-preference", "dm-sending"] {
                let model = ChatTimelineReferenceModel(f, messages: [plain]); model.threadRoot = thread ? plain.id : nil
                var m = plain
                if state.hasPrefix("edit") || state == "archived-edit" {
                    _ = model.beginEditing(m, root: model.threadRoot, recovering: false)
                    if state == "edit-error" { model.editing?.problem = "The current draft could not be saved." }
                }
                if state == "dm-sending" { model.isDM = true; m.localState = .sending; m.seq = nil; model.feed.messages = [m] }
                UserDefaults.standard.set(state == "time-preference", forKey: "chat.ux2.alwaysShowTime")
                try await c.capture(state, inventory: state.contains("edit") ? ["R20", "R21"] : state == "dm-sending" ? ["R18"] : ["R09", "R10", "R22"],
                    model: model, messages: [m], width: width, dark: dark,
                    content: c.row(model, message: m, width: width, thread: thread, grouped: state == "grouped", selected: state == "selected", archived: state == "archived-edit"))
            }
        }
        UserDefaults.standard.set(false, forKey: "chat.ux2.alwaysShowTime")
    }

    private func timelineMatrix(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let root = try ChatTimelineReferenceFixture.message(ChatTimelineReferenceFixture.root, me: f.key.accountId)
        var continuation = root; continuation.messageId = "reference-continuation"; continuation.seq = 2; continuation.createdAt = "2026-10-07T12:01:00Z"
        var reply = root; reply.messageId = "reference-reply"; reply.seq = 3; reply.threadRootId = root.id
        reply.authorAccountId = CallJSON.boris; reply.inReplyToMessageId = root.id; reply.text = "A reply that retains its original source link."
        var nextDay = continuation; nextDay.messageId = "reference-next-day"; nextDay.seq = 4; nextDay.createdAt = "2026-10-08T12:00:00Z"
        for dm in [false, true] {
            for thread in [false, true] {
                for width: CGFloat in [760, 420, 320] {
                    let values = thread ? [root, reply] : [root, continuation, nextDay]
                    let m = ChatTimelineReferenceModel(f, messages: values); m.isDM = dm; m.threadRoot = thread ? root.id : nil
                    m.feed.hasOlder = true; m.threadHasEarlier = true; m.feed.earlierUnread = !thread
                    m.feed.unreadID = continuation.id; m.threadUnreadID = reply.id
                    m.feed.replySummaries[root.id] = ChatReplySummary(messages: [reply], complete: false)
                    m.feed.unreadReplyCounts[root.id] = 2; m.feed.requests[root.id] = 1
                    try await c.capture("\(dm ? "dm" : "channel")-\(thread ? "thread" : "feed")", inventory: ["T01", "T05", "T06", "T07", "T10", "T11", "T12", "R02", "R30", "R31", "R32", "R49", "R50"],
                        model: m, messages: values, width: width, dark: dark, root: m.threadRoot, content: c.timeline(m, root: m.threadRoot, width: width))
                }
                let m = ChatTimelineReferenceModel(f); m.isDM = dm; m.threadRoot = thread ? root.id : nil
                let width: CGFloat = thread ? 420 : 760
                try await c.capture("empty-\(dm ? "dm" : "channel")-\(thread ? "thread" : "feed")", inventory: ["T08", "R50"], model: m, messages: [], width: width, dark: dark, root: m.threadRoot, content: c.timeline(m, root: m.threadRoot, width: width))
            }
        }
        for mode in ["reveal", "focus", "live-resize"] {
            let m = ChatTimelineReferenceModel(f, messages: [root, continuation, nextDay])
            if mode == "reveal" { m.revealMessageID = continuation.id }
            if mode == "focus" { m.focusRequest = .init(area: .feed) }
            try await c.capture(mode, inventory: mode == "live-resize" ? ["T03", "T18"] : ["T20", "T21", "T23", "R52"], model: m,
                messages: m.feed.messages, width: 760, dark: dark, detail: ["resizeWidths": mode == "live-resize" ? [760, 600, 420, 320, 760] : []],
                content: AnyView(ChatTimelineView(model: m, root: nil, members: c.members, mentionable: [], me: f.key.accountId, archived: false, ownerModel: nil)),
                prepare: { host, window in
                    if mode == "live-resize" {
                        for width: CGFloat in [600, 420, 320, 760] {
                            window.setContentSize(CGSize(width: width, height: 600)); host.layoutSubtreeIfNeeded()
                            try await Task.sleep(for: .milliseconds(30))
                            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                            try c.write(bitmap, id: "resize-step-\(Int(width))-\(dark ? "dark" : "light")", inventory: ["T03", "T18"], width: width, height: 600, dark: dark,
                                scale: window.backingScaleFactor, detail: ["fixtureValues": try m.feed.messages.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
                                    "positions": String(describing: m.positions), "stepWidth": width])
                        }
                    }
                })
        }
    }

    private func metadataMatrix(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        f.service.serverCapabilities[f.key.server] = ChatB1.capabilities
        f.service.isServerKnown = { _, _ in true }
        let m = try ChatTimelineReferenceFixture.message("reference-metadata", me: f.key.accountId)
        let b1 = ChatB1Channel(key: f.key, channel: m.channelId, store: f.store, service: f.service)
        for state in ["loading", "error", "reactions-1", "reactions-12", "pinned", "pin-pending", "reaction-pending", "reaction-new-pending", "reaction-error", "reaction-problem", "reaction-picker", "reactors-popup"] {
            try await f.store.queue.write { db in
                try db.execute(sql: "DELETE FROM b1_metadata")
                try db.execute(sql: "DELETE FROM b1_intents")
                try ChatB1.watch(db, channel: m.channelId, ids: [m.id])
                if state == "error" { try db.execute(sql: "UPDATE b1_metadata SET error = 'Message details unavailable'") }
                if !["loading", "error"].contains(state) {
                    let reactions = (state == "reactions-12" ? ChatTimelineReferenceFixture.emoji : ["👍"]).map { ChatB1.Reaction(emoji: $0, count: 3, mine: $0 == "👍") }
                    let summary = ChatB1.Summary(rootId: m.id, replyCount: 12, lastReplyAt: ChatTimelineReferenceFixture.date, lastReplySeq: 13,
                        lastParticipants: [.init(authorAccountId: CallJSON.boris)])
                    let value = ChatB1.Metadata(messageId: m.id, deleted: false, reactions: reactions,
                        pin: state == "pinned" ? .init(pinnedBy: f.key.accountId, pinnedAt: ChatTimelineReferenceFixture.date) : nil, threadSummary: summary)
                    try db.execute(sql: "UPDATE b1_metadata SET data = ?, dirty = 0, as_of_seq = 3 WHERE message_id = ?", arguments: [try JSONEncoder().encode(value), m.id])
                    if state.hasSuffix("pending") || state == "reaction-error" {
                        let command = "reference-b1-\(state)-\(dark)"
                        var record = ChatCommandRecord(commandId: command, sessionId: "s-anna", type: "message.reaction.set", bodyBytes: Data(), orderKey: command,
                            createdAt: ISO8601DateFormatter().date(from: ChatTimelineReferenceFixture.date)!, state: .pending)
                        if state == "reaction-error" { record.state = .dropped; record.error = "Change not confirmed. Try again." }
                        try record.insert(db)
                        try db.execute(sql: "INSERT INTO b1_intents (command_id, channel_id, message_id, choice, present) VALUES (?, ?, ?, ?, 1)",
                            arguments: [command, m.channelId, m.id, state == "pin-pending" ? "pin" : state == "reaction-new-pending" ? "✨" : "👍"])
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(30))
            let model = ChatTimelineReferenceModel(f, messages: [m]); model.b1 = b1; model.feed.unreadReplyCounts[m.id] = 4
            if state == "reaction-problem" { b1.toggle(m.id, emoji: "not emoji") }
            for width: CGFloat in [760, 420] {
                if state == "reaction-picker" {
                    try await c.capture(state, inventory: ["R29"], model: model, messages: [m], width: width, dark: dark,
                        content: AnyView(VStack { ChatReactionPicker(b1: b1, message: m.id); Spacer() }.frame(width: width, height: 600)))
                } else if state == "reactors-popup" {
                    try await c.capture(state, inventory: ["R28"], model: model, messages: [m], width: width, dark: dark,
                        content: AnyView(ChatReactionChip(b1: b1, message: m.id, reaction: .init(emoji: "👍", count: 3, mine: true), members: c.members).padding(30).frame(width: width, height: 600)),
                        prepare: { host, window in
                            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: CGPoint(x: width / 2, y: 300), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                            let menu = try XCTUnwrap(host.menu(for: event)); let item = try XCTUnwrap(menu.items.first { $0.title == "Who reacted" })
                            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
                            try await Task.sleep(for: .milliseconds(150))
                            let popup = try XCTUnwrap(NSApp.windows.first { $0 !== window && $0.isVisible && $0.parent === window })
                            let view = try XCTUnwrap(popup.contentView)
                            view.layoutSubtreeIfNeeded(); let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
                            try c.write(bitmap, id: "reactors-popup-window-\(Int(width))-\(dark ? "dark" : "light")", inventory: ["R28", "S26"], width: view.bounds.width, height: view.bounds.height, dark: dark, scale: popup.backingScaleFactor,
                                detail: ["fixtureValues": try [JSONSerialization.jsonObject(with: JSONEncoder().encode(m))], "nativePopup": true])
                            popup.performClose(nil)
                        })
                } else {
                    try await c.capture("b1-" + state, inventory: ["R26", "R27", "R32"], model: model, messages: [m], width: width, dark: dark,
                        detail: ["metadata": String(describing: b1.state)], content: c.row(model, message: m, width: width, thread: width == 420))
                }
            }
        }
        f.service.serverCapabilities[f.key.server] = []
    }

    private func attachmentMatrix(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        f.service.serverCapabilities[f.key.server] = ["chat.attachments", "chat.attachments_context"]
        let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        f.service.serverAttachmentLimits[f.key.server] = limits
        f.service.isServerKnown = { _, _ in true }
        let png = try ChatTimelineReferenceFixture.png()
        var image = try ChatAttachmentStorage.descriptor(data: png, name: "reference-chart.png", limits: limits); image.hasPreview = true
        let note = try ChatAttachmentStorage.descriptor(data: Data("Fixture notes\n".utf8), name: "reference-notes.txt", limits: limits)
        let manager = try XCTUnwrap(f.service.attachments(f.key))
        for state in ["file", "image-loading", "image-decoded", "image-failure", "image-no-preview", "mixed", "access-lost"] {
            var file = image; file.attachmentId = "reference-file-\(state)-\(dark ? "dark" : "light")"
            if state == "image-no-preview" { file.hasPreview = false }
            var m = try ChatTimelineReferenceFixture.message("reference-media-\(state)-\(dark ? "dark" : "light")", me: f.key.accountId)
            m.attachments = state == "file" ? [note] : state == "mixed" ? [note, file, image] : [file]
            m.attachmentOnly = true
            let fields: [String: Any] = ["message_id": m.id, "channel_id": m.channelId, "author_account_id": m.authorAccountId,
                "text": m.text, "seq": 100 + (dark ? 20 : 0) + ["file", "image-loading", "image-decoded", "image-failure", "image-no-preview", "mixed", "access-lost"].firstIndex(of: state)!, "revision": m.revision,
                "created_at": m.createdAt, "attachment_only": true, "attachments": try m.attachments.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]
            let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: fields))
            try await f.store.queue.write { _ = try ChatMessages.write($0, wire) }
            m = try XCTUnwrap(manager.message(owner: .channel(m.channelId), id: m.id))
            ChatStubProtocol.reset { _, _ in
                if state == "image-loading" { Thread.sleep(forTimeInterval: 0.6) }
                return state == "image-failure" ? .failure(URLError(.cannotDecodeContentData)) : .success(.init(status: 200, body: png))
            }
            if state == "image-decoded" || state == "mixed" {
                for picture in m.attachments where picture.mime.hasPrefix("image/") { _ = try await manager.load(m, file: picture, preview: true) }
            }
            let model = ChatTimelineReferenceModel(f, messages: [m])
            for width: CGFloat in [760, 420] {
                try await c.capture(state, inventory: ["R34", "R35", "R36", "R37", "R38", "R40"], model: model, messages: [m], width: width, dark: dark,
                    decoded: state == "image-decoded" || state == "mixed", detail: ["attachmentState": state],
                    content: c.row(model, message: m, width: width, thread: width == 420), prepare: { _, _ in
                        if state == "access-lost" { f.service.orgSessions[f.key]?.snapshotOwed = true; manager.suspend() }
                    })
                f.service.orgSessions[f.key]?.snapshotOwed = false
            }
        }
        f.service.serverCapabilities[f.key.server] = []
    }

    private func interactionMatrix(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let message = try ChatTimelineReferenceFixture.message("reference-interaction", me: f.key.accountId,
            text: "Selectable **native text**, @anna, and a [checked link](https://example.com/reference).")
        for width: CGFloat in [760, 420] {
            let model = ChatTimelineReferenceModel(f, messages: [message]); model.threadRoot = width == 420 ? message.id : nil
            for state in ["native-selection", "hover", "context-menu"] {
                try await c.capture(state, inventory: state == "native-selection" ? ["T26", "R11"] : state == "hover" ? ["R09", "R10", "R22"] : [],
                    model: model, messages: [message], width: width, dark: dark,
                    detail: state == "native-selection" ? ["expectedNativeSelection": NSStringFromRange(NSRange(location: 0, length: 16)), "nativeSelectionTextPrefix": "Selectable"] : [:],
                    content: c.row(model, message: message, width: width, thread: width == 420), beforeBitmap: { host, window in
                        guard state == "native-selection" else { return }
                        let text = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host, NSTextView.self).first { $0.string.contains("Selectable") })
                        // A SwiftUI layout pass can replace text storage and reset its
                        // selection. Stage after settlement and verify after rendering.
                        window.makeFirstResponder(text); text.setSelectedRange(NSRange(location: 0, length: 16))
                        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 16))
                    }, prepare: { host, window in
                        let text = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host, NSTextView.self).first { $0.string.contains("Selectable") })
                        if state == "native-selection" {
                            window.makeFirstResponder(text); text.setSelectedRange(NSRange(location: 0, length: 16))
                            XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 16))
                        } else if state == "hover" {
                            let point = text.convert(CGPoint(x: 10, y: 10), to: nil)
                            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
                            APQuietSendEvent(event, window)
                            host.updateTrackingAreas()
                            for view in ChatTimelineReferenceCapture.descendants(host, NSView.self) {
                                for area in view.trackingAreas {
                                    let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                        eventNumber: 2, trackingNumber: 0, userData: nil))
                                    (area.owner as? NSResponder)?.mouseEntered(with: entered)
                                }
                            }
                            try await Task.sleep(for: .milliseconds(40))
                        } else {
                            let cell = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host, ChatNativeShellCell.self).first)
                            let menu = try XCTUnwrap(cell.rowActions.makeMenu())
                            let titles = menu.items.map { ["title": $0.title, "enabled": $0.isEnabled, "separator": $0.isSeparatorItem] as [String: Any] }
                            try JSONSerialization.data(withJSONObject: ["inventoryIDs": ["R23"], "menuItems": titles,
                                "status": "native menu enumerated without tracking; native menu bitmap unavailable in existing quiet harness",
                                "fixtureValues": try [JSONSerialization.jsonObject(with: JSONEncoder().encode(message))]], options: [.prettyPrinted, .sortedKeys])
                                .write(to: c.output.appendingPathComponent("context-menu-enumeration-\(Int(width))-\(dark ? "dark" : "light").json"), options: .withoutOverwriting)
                        }
                    })
            }
        }
    }

    private func confirmationMatrix(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let m = try ChatTimelineReferenceFixture.message("reference-confirmation", me: f.key.accountId)
        for width: CGFloat in [760, 420, 260] {
          for dm in [false, true] {
            for phase in ["awaiting", "executing", "failed"] {
                let model = ChatTimelineReferenceModel(f, messages: [m]); model.isDM = dm
                let confirmation = ConfirmationCoordinator(); model.confirmation = confirmation
                _ = confirmation.request(.init(tabID: UUID(), targetID: "message:\(m.id)"), title: "Delete this message?", consequences: dm ? "Its text will be removed. Replies stay in the thread." : "Copies already in the context of a running agent stay.", verb: "Delete", destructive: true, stillValid: { true }, operation: {
                    if phase == "failed" { throw NSError(domain: "Fixture deletion failed", code: 1, userInfo: [NSLocalizedDescriptionKey: "The deletion could not be confirmed."]) }
                    try await Task.sleep(for: .milliseconds(500))
                })
                try await c.capture("confirmation-\(dm ? "dm" : "channel")-" + phase, inventory: ["R25", "S26"], model: model, messages: [m], width: width, dark: dark,
                    content: c.row(model, message: m, width: width, thread: false), prepare: { _, _ in
                        if phase != "awaiting" { confirmation.confirm(); try await Task.sleep(for: .milliseconds(40)) }
                    })
                confirmation.cancel(); confirmation.invalidate()
            }
          }
        }
    }

    private func replyAndSummaryVariants(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let source = try ChatTimelineReferenceFixture.message("reference-source-link", me: f.key.accountId)
        for state in ["long-truncated90", "source-deleted", "source-missing", "deleted-host"] {
            var original = source
            if state == "long-truncated90" { original.text = String(repeating: "source text ", count: 20) }
            if state == "source-deleted" { original.deletedAt = ChatTimelineReferenceFixture.date }
            var reply = source; reply.messageId = "reference-reply-" + state; reply.seq = 2
            reply.inReplyToMessageId = original.id; reply.threadRootId = original.id
            if state == "deleted-host" { reply.deletedAt = ChatTimelineReferenceFixture.date }
            let model = ChatTimelineReferenceModel(f, messages: state == "source-missing" ? [reply] : [original, reply]); model.threadRoot = source.id
            for width: CGFloat in [760, 420] {
                try await c.capture("reply-link-" + state, inventory: ["R30"], model: model, messages: model.feed.messages,
                    width: width, dark: dark, root: source.id, detail: ["visualStates": ["reply-" + state]],
                    content: c.row(model, message: reply, width: width, thread: width == 420))
            }
        }
        for state in ["local-one", "local-multiple", "local-three-identities", "server-zero-local-fallback", "server-agent-session-former", "plural-requests"] {
            var root = source; root.messageId = "reference-summary-" + state
            var replies: [ChatMessage] = []
            for index in 0..<(state == "local-one" ? 1 : 3) {
                var value = root; value.messageId += "-reply-\(index)"; value.seq = index + 2; value.threadRootId = root.id
                value.authorAccountId = index == 0 ? f.key.accountId : CallJSON.boris
                if state == "local-three-identities", index == 1 { value.authorAgentId = CallJSON.agent; value.authorAgentName = "Billing agent" }
                if state == "local-three-identities", index == 2 { value.authorSessionName = "Review session" }
                replies.append(value)
            }
            let model = ChatTimelineReferenceModel(f, messages: [root] + replies)
            model.feed.replySummaries[root.id] = ChatReplySummary(messages: replies, complete: true)
            model.feed.unreadReplyCounts[root.id] = state.hasPrefix("server") ? 2 : 0
            model.feed.requests[root.id] = state == "plural-requests" ? 3 : 0
            if state.hasPrefix("server") {
                f.service.serverCapabilities[f.key.server] = ["chat.thread_summary"]
                let participants: [ChatB1.Participant] = [
                    .init(authorAccountId: f.key.accountId, authorAgentId: CallJSON.agent, authorAgentName: "Billing agent"),
                    .init(authorAccountId: CallJSON.boris, authorSessionName: "Review session"),
                    .init(authorAccountId: "removed-member")]
                let summary = ChatB1.Summary(rootId: root.id, replyCount: state == "server-zero-local-fallback" ? 0 : 7,
                    lastReplyAt: ChatTimelineReferenceFixture.date, lastReplySeq: 8, lastParticipants: participants)
                let metadata = ChatB1.Metadata(messageId: root.id, deleted: false, reactions: [], pin: nil, threadSummary: summary)
                try f.write("INSERT OR REPLACE INTO b1_metadata (channel_id, message_id, data, dirty) VALUES (?, ?, ?, 0)", [root.channelId, root.id, try JSONEncoder().encode(metadata)])
                model.b1 = ChatB1Channel(key: f.key, channel: root.channelId, store: f.store, service: f.service)
            }
            for width: CGFloat in [760, 420] {
                try await c.capture("summary-" + state, inventory: ["R31", "R32"], model: model, messages: model.feed.messages,
                    width: width, dark: dark, detail: ["visualStates": [state]], content: c.row(model, message: root, width: width, thread: false))
            }
            f.service.serverCapabilities[f.key.server] = []
        }
    }

    private func mediaGeometryAndViewer(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        f.service.serverCapabilities[f.key.server] = ["chat.attachments", "chat.attachments_context"]
        let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        f.service.serverAttachmentLimits[f.key.server] = limits; f.service.isServerKnown = { _, _ in true }
        let png = try ChatTimelineReferenceFixture.png()
        let base = try ChatAttachmentStorage.descriptor(data: png, name: "reference-geometry.png", limits: limits)
        let manager = try XCTUnwrap(f.service.attachments(f.key))
        var viewerMessage: ChatMessage?
        for state in ["jpeg", "pdf", "md", "csv", "log", "json", "unknown-mime", "long-filename", "long-mime", "extreme-wide", "extreme-tall", "unknown-dimensions", "grid-threshold-before", "grid-threshold-after"] {
            var file = base; file.attachmentId = "reference-geometry-\(state)-\(dark)"; file.hasPreview = false
            switch state {
            case "jpeg": file.mime = "image/jpeg"; file.name = "photograph.jpeg"
            case "pdf": file.mime = "application/pdf"; file.name = "document.pdf"
            case "md", "csv", "log": file.mime = "text/plain"; file.name = "document." + state
            case "json": file.mime = "application/json"; file.name = "data.json"
            case "unknown-mime": file.mime = "application/octet-stream"; file.name = "binary.data"
            case "long-filename": file.mime = "text/plain"; file.name = String(repeating: "a-very-long-filename-", count: 12) + ".txt"
            case "long-mime": file.mime = "application/vnd.reference.very-long-mime-type-for-wrapping-observation"; file.name = "mime.data"
            case "extreme-wide": file.width = 3200; file.height = 40
            case "extreme-tall": file.width = 40; file.height = 3200
            case "unknown-dimensions": file.width = nil; file.height = nil
            default: break
            }
            var second = file; second.attachmentId += "-second"; second.position = 1
            let files = state.hasPrefix("grid-") ? [file, second] : [file]
            let values: [String: Any] = ["message_id": "reference-geometry-message-\(state)-\(dark)", "channel_id": ChatTimelineReferenceFixture.channel,
                "author_account_id": f.key.accountId, "text": "Attachment geometry fixture", "revision": 1, "seq": 300 + (dark ? 50 : 0) + ["jpeg", "pdf", "md", "csv", "log", "json", "unknown-mime", "long-filename", "long-mime", "extreme-wide", "extreme-tall", "unknown-dimensions", "grid-threshold-before", "grid-threshold-after"].firstIndex(of: state)!,
                "created_at": ChatTimelineReferenceFixture.date, "attachments": try files.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]
            let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: values))
            try await f.store.queue.write { _ = try ChatMessages.write($0, wire) }
            let message = try XCTUnwrap(manager.message(owner: .channel(ChatTimelineReferenceFixture.channel), id: wire.messageId))
            if state == "extreme-wide" { viewerMessage = message }
            let model = ChatTimelineReferenceModel(f, messages: [message])
            let widths: [CGFloat] = state.hasPrefix("grid-") ? (state.hasSuffix("before") ? [395, 315] : [405, 325]) : [760, 420]
            for width in widths {
                try await c.capture("media-geometry-" + state, inventory: ["R35", "R36", "R38"], model: model, messages: [message], width: width, dark: dark,
                    detail: ["visualStates": [state]], content: c.row(model, message: message, width: width, thread: width <= 420))
            }
        }
        let message = try XCTUnwrap(viewerMessage), file = try XCTUnwrap(message.attachments.first)
        for state in ["loading", "error-reload", "access-unavailable", "zoom-min", "zoom-max"] {
            let tab = TabState(route: .viewer(OrgKey(f.key), channelID: message.channelId, messageID: message.id, attachmentID: file.id))
            let viewer = AttachmentViewerModel(state: tab, tabs: CompositionTabs(router: TabRouter(), chat: f.service, team: f.teamService))
            ChatStubProtocol.reset { _, _ in
                if state == "loading" { Thread.sleep(forTimeInterval: 0.8) }
                return state == "error-reload" ? .failure(URLError(.cannotConnectToHost)) : .success(.init(status: 200, body: png))
            }
            if state.hasPrefix("zoom-") { await viewer.load(); viewer.zoom = state == "zoom-min" ? 0.25 : 3 }
            if state == "access-unavailable" { f.service.orgSessions[f.key]?.snapshotOwed = true }
            let projection = ChatTimelineReferenceModel(f, messages: [message])
            try await c.capture("viewer-" + state, inventory: ["R39"], model: projection, messages: [message], width: 760, dark: dark,
                detail: ["viewerState": state, "zoom": viewer.zoom, "saveControlOnly": true], content: AnyView(AttachmentViewerTab(model: viewer).frame(width: 760, height: 600)))
            viewer.invalidate(); tab.isClosed = true; f.service.orgSessions[f.key]?.snapshotOwed = false
        }
        f.service.serverCapabilities[f.key.server] = []
    }

    private func auxiliaryAndAppearanceVariants(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let runtimeDate = Date()
        var today = try ChatTimelineReferenceFixture.message("reference-today", me: f.key.accountId)
        today.createdAt = ISO8601DateFormatter().string(from: runtimeDate)
        let todayModel = ChatTimelineReferenceModel(f, messages: [today])
        for width: CGFloat in [760, 420] {
            try await c.capture("date-today", inventory: ["T10", "R49"], model: todayModel, messages: [today], width: width, dark: dark,
                detail: ["runtimeClock": ISO8601DateFormatter().string(from: runtimeDate), "datePolicy": "Actual capture-day fixture; exact createdAt frozen in record"],
                content: c.timeline(todayModel, root: nil, width: width))
        }
        let messages = try (0..<60).map { index in
            try ChatTimelineReferenceFixture.message("reference-detached-\(index)", me: CallJSON.boris,
                text: "History message \(index). " + String(repeating: "Reading at a detached position. ", count: 4), seq: index + 1)
        }
        for width: CGFloat in [760, 420] {
            for count in [0, 3] {
                let model = ChatTimelineReferenceModel(f, messages: messages)
                var position = ChatScrollPosition(); _ = position.update(messages, me: f.key.accountId)
                position.atBottom = false; position.anchor = messages[20].id
                if count > 0 { position.unseen = Set(messages.suffix(count).map(\.id)) }
                model.positions[""] = position
                try await c.capture(count == 0 ? "overlay-jump-to-latest" : "overlay-new-messages-count", inventory: ["T16"], model: model, messages: messages,
                    width: width, dark: dark, detail: ["visualStates": [count == 0 ? "jump-to-latest" : "new-messages-count"], "unseenCount": count],
                    content: c.timeline(model, root: nil, width: width))
            }
        }
        let model = ChatChannelModel(key: f.key, channel: ChatTimelineReferenceFixture.channel); model.service = f.service; model.follow(f.store)
        for state in ["results", "empty", "back"] {
            model.setSearching(true)
            if state == "back", let target = model.feed.messages.first { model.navigate(to: target) }
            for width: CGFloat in [760, 420] {
                try await c.capture("local-search-" + state, inventory: ["T27"], model: model, messages: model.feed.messages,
                    width: width, dark: dark, detail: ["visualStates": ["local-search-" + state]],
                    content: AnyView(VStack(spacing: 0) { ChatLocalSearch(model: model); c.timeline(model, root: model.threadRoot, width: width, height: 350); Spacer() }.frame(width: width, height: 600)),
                    prepare: { host, window in
                        let field = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host, NSTextField.self).first { $0.placeholderString == "Search loaded history" })
                        let query = state == "empty" ? "NO_REFERENCE_MATCH_6FD31" : "question"
                        window.makeFirstResponder(field)
                        if let editor = field.currentEditor() as? NSTextView { editor.selectAll(nil); editor.insertText(query, replacementRange: editor.selectedRange()) }
                        else { field.stringValue = query; field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field)) }
                        try await Task.sleep(for: .milliseconds(40))
                    })
            }
            model.returnFromNavigation(); model.setSearching(false)
        }
        let settings = AgentPadSettingsModel.shared
        let previous = (settings.appearanceMode, settings.systemAppearanceIsDark, settings.lightTerminalThemeSelection, settings.darkTerminalThemeSelection, settings.terminalThemeChoices)
        defer { settings.appearanceMode = previous.0; settings.systemAppearanceIsDark = previous.1; settings.lightTerminalThemeSelection = previous.2; settings.darkTerminalThemeSelection = previous.3; settings.terminalThemeChoices = previous.4 }
        let themeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("reference-theme-\(UUID())")
        try FileManager.default.createDirectory(at: themeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: themeDirectory) }
        let themeText = "background = #\(dark ? "17222E" : "F2F5E9")\nforeground = #\(dark ? "E9D8BC" : "253544")\n"
        try themeText.write(to: themeDirectory.appendingPathComponent("Reference custom"), atomically: true, encoding: .utf8)
        let custom = try XCTUnwrap(AgentPadTerminalTheme.userThemes(in: themeDirectory).first)
        settings.terminalThemeChoices.append(custom)
        if dark { settings.darkTerminalThemeSelection = custom.storedValue } else { settings.lightTerminalThemeSelection = custom.storedValue }
        try await c.capture("custom-preset", inventory: ["R04", "S25"], model: todayModel, messages: [today], width: 760, dark: dark,
            detail: ["customPreset": ["id": custom.id, "background": custom.backgroundHex, "foreground": custom.foregroundHex]], content: c.row(todayModel, message: today, width: 760, thread: false, selected: true))
        settings.lightTerminalThemeSelection = previous.2; settings.darkTerminalThemeSelection = previous.3
        settings.appearanceMode = .system; settings.systemAppearanceIsDark = dark
        try await c.capture("system-appearance-before", inventory: ["S25"], model: todayModel, messages: [today], width: 760, dark: dark,
            detail: ["appearanceMode": "system", "systemAppearanceIsDark": dark], content: c.row(todayModel, message: today, width: 760, thread: false))
        settings.systemAppearanceIsDark = !dark
        try await c.capture("system-appearance-after", inventory: ["S25"], model: todayModel, messages: [today], width: 760, dark: !dark,
            detail: ["appearanceMode": "system", "systemAppearanceIsDark": !dark], content: c.row(todayModel, message: today, width: 760, thread: false))
        settings.appearanceMode = previous.0
        for increased in [false, true] {
            let focusModel = ChatTimelineReferenceModel(f, messages: [today]); focusModel.focusRequest = .init(area: .feed)
            try await c.capture(increased ? "focus-increased-environment" : "focus-standard-environment", inventory: ["R05", "R33", "R52"], model: focusModel, messages: [today], width: 760, dark: dark,
                detail: ["swiftUIColorSchemeContrast": increased ? "increased" : "standard", "workspaceContrastUnmodified": true],
                content: AnyView(c.timeline(focusModel, root: nil, width: 760).environment(\._colorSchemeContrast, increased ? .increased : .standard)))
        }
    }

    private func productionChromeAndMembership(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let channel = ChatTimelineReferenceFixture.channel, root = ChatTimelineReferenceFixture.root
        let wireFields: [String: Any] = ["message_id": root, "channel_id": channel, "author_account_id": f.key.accountId,
            "text": "@billing@anna Could you check the saved question?", "revision": 3, "seq": 1, "created_at": ChatTimelineReferenceFixture.date]
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: wireFields))
        try await f.store.queue.write { _ = try ChatMessages.write($0, wire) }
        f.service.serverCapabilities[f.key.server] = ["chat.attachments", "chat.attachments_context", "chat.channel_ux1"]
        let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        f.service.serverAttachmentLimits[f.key.server] = limits
        f.service.isServerKnown = { _, _ in true }
        let session = ChatChannelSession()
        let baseCard = ChatChannelCard(channelId: channel, teamId: "f5000000-0000-4000-8000-000000000004", name: "billing", createdBy: f.key.accountId, archived: false, version: 1)
        session.update(.ready(baseCard, team: "Billing", offline: true), key: f.key, store: f.store, service: f.service)
        let model = try XCTUnwrap(session.model)
        model.saveDraft("Saved composer text stays outside the timeline.", root: nil)
        let manager = try XCTUnwrap(f.service.attachments(f.key))
        let previousAPI = f.service.makeAPI
        f.service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatTimelineReferenceDraftProtocol.self], timeout: 300) }
        func removeReferenceDrafts() {
            for draft in manager.drafts where draft.file.name.hasPrefix("draft-") {
                manager.remove(draft, cancelOnServer: false)
            }
        }
        defer { removeReferenceDrafts(); f.service.makeAPI = previousAPI }
        let bytes = Data("Reference draft file\n".utf8)
        // Start both held transfers before adding the waiting draft. Active
        // operations keep reconcile from resetting uploading/checking to waiting.
        let states: [(Int, ChatAttachmentDraft.State)] = [(1, .uploading), (2, .checking), (0, .waiting), (3, .ready), (4, .failed)]
        for (index, state) in states {
            var file = try ChatAttachmentStorage.descriptor(data: bytes, name: "draft-\(state.rawValue).txt", limits: limits)
            file.attachmentId = String(format: "f6000000-0000-4000-8000-%012d", index + (dark ? 100 : 0))
            var draft = ChatAttachmentDraft(file: file, messageId: "reference-draft-post", channel: channel, root: "", session: "s-anna", generation: "g1",
                sha256: ChatAttachments.digest(bytes), createdAt: ISO8601DateFormatter().date(from: ChatTimelineReferenceFixture.date)!.addingTimeInterval(Double(index)),
                expiresAt: Date().addingTimeInterval(86000), state: [.uploading, .checking].contains(state) ? .waiting : state,
                progress: state == .uploading ? 0.45 : state == .ready ? 1 : 0)
            draft.prepareCommand = "reference-prepare-\(state.rawValue)"; draft.completeCommand = "reference-complete-\(state.rawValue)"
            if state == .failed { draft.problem = "The file could not be uploaded. Retry when connected." }
            try manager.storage.save(bytes, key: f.key, id: draft.id)
            let savedDraft = draft
            try await f.store.queue.write { try ChatAttachments.put($0, savedDraft) }
            manager.reconcile()
            let deadline = ContinuousClock.now + .seconds(3)
            while manager.drafts.first(where: { $0.id == savedDraft.id })?.state != state, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(manager.drafts.first(where: { $0.id == savedDraft.id })?.state, state)
        }
        manager.reconcile()
        for width: CGFloat in [1040, 760, 420] {
            for state in ["offline", "archived", "ask-expanded", "ask-collapsed"] {
                var card = baseCard; card.archived = state == "archived"
                if state.hasPrefix("ask-") {
                    let offer = ChatChannelAsk.Offer(messageId: root, agentId: CallJSON.agent, address: "billing@anna", text: "Check this saved question.", root: root)
                    let form = ChannelAskModel(model: model, fields: .init(offer: offer, text: offer.text, chosen: [root]))
                    form.expanded = state == "ask-expanded"; model.channelAsk = form
                } else { model.channelAsk = nil }
                try await c.capture("production-channel-" + state, inventory: state.hasPrefix("ask-") ? ["T04", "R41", "R51"] : ["T03", "T04", "R41"],
                    model: model, messages: model.feed.messages, width: width, height: 900, dark: dark,
                    detail: ["caller": "ChatChannelView", "offline": true, "archived": card.archived, "askExpanded": model.channelAsk?.expanded ?? false,
                             "requiredVisibleText": ["Waiting to upload", "Uploading · 45%", "Verifying format…"]],
                    content: AnyView(ChatChannelView(card: card, team: "Billing", offline: true, key: f.key, conversation: session, service: f.service).frame(width: width, height: 900)),
                    beforeBitmap: { _, _ in
                        let expected = ["waiting": 0.0, "uploading": 0.45, "checking": 1.0, "ready": 1.0, "failed": 0.0]
                        for (name, progress) in expected {
                            let draft = try XCTUnwrap(manager.drafts.first { $0.file.name == "draft-\(name).txt" })
                            XCTAssertEqual(draft.state.rawValue, name, "Draft state at bitmap capture")
                            XCTAssertEqual(draft.progress, progress, "Draft progress at bitmap capture")
                            guard draft.state.rawValue == name, draft.progress == progress else {
                                throw NSError(domain: "Draft changed before bitmap capture: \(name)", code: 1)
                            }
                        }
                    })
            }
        }
        removeReferenceDrafts()
        f.service.makeAPI = previousAPI
        model.channelAsk = nil
        try f.write("DELETE FROM agent_channels")
        try f.write("UPDATE meta SET agents_served = 1")
        for state in ["addable", "other-owner", "disabled", "archived"] {
            let guidance = state == "archived" ? "This channel is archived."
                : state == "other-owner" ? "Ask its owner to add it before requesting an answer."
                : state == "disabled" ? "Enable the agent, then add it to request an answer."
                : "Add it to request an answer."
            let owner = state == "other-owner" ? CallJSON.boris : f.key.accountId
            try f.write("INSERT OR REPLACE INTO agents_catalog (agent_id, owner_account_id, name, description, access, enabled, available) VALUES (?, ?, 'billing', '', 'read', ?, 1)",
                [CallJSON.agent, owner, state == "disabled" ? 0 : 1])
            try f.write("UPDATE channels SET archived = ? WHERE channel_id = ?", [state == "archived", channel])
            ChatOrgCurrent.shared.refresh(f.service)
            try await Task.sleep(for: .milliseconds(80))
            let text = "@billing@\(state == "other-owner" ? "boris" : "anna") Please check this question."
            var message = try ChatTimelineReferenceFixture.message("reference-membership-" + state, me: f.key.accountId, text: text)
            message.seq = 1
            for width: CGFloat in [760, 420] {
                try await c.capture("membership-" + state, inventory: ["R42"], model: model, messages: [message], width: width, dark: dark,
                    detail: ["catalogOwner": owner, "catalogEnabled": state != "disabled", "channelArchived": state == "archived", "requiredVisibleText": [guidance]],
                    content: c.row(model, message: message, width: width, thread: width == 420, archived: state == "archived"))
            }
        }
        try f.write("UPDATE channels SET archived = 0 WHERE channel_id = ?", [channel])
        try f.write("INSERT OR REPLACE INTO agent_channels (channel_id, agent_id, name, owner_account_id, access, enabled, available) VALUES (?, ?, 'billing', ?, 'read', 1, 1)", [channel, CallJSON.agent, f.key.accountId])
        try await productionDMChrome(c, fixture: f, dark: dark)
        f.service.serverCapabilities[f.key.server] = []
    }

    private func productionDMChrome(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let dm = "reference-private-dm"
        let message = ChatDMMessageWire(messageId: "reference-private-message", dmId: dm, threadRootId: nil, authorAccountId: f.key.accountId,
            text: "Private message in the shared timeline.", mentions: [], revision: 2, seq: 1, createdAt: ChatTimelineReferenceFixture.date)
        let reply = ChatDMMessageWire(messageId: "reference-private-reply", dmId: dm, threadRootId: message.messageId, authorAccountId: CallJSON.boris,
            text: "A private thread reply.", mentions: [], revision: 1, seq: 2, createdAt: ChatTimelineReferenceFixture.date)
        var card = ChatDMCard(dmId: dm, peer: .init(accountId: CallJSON.boris, name: "Boris", handle: "boris", active: true), state: "active", version: 1,
            createdAt: ChatTimelineReferenceFixture.date, head: 2, messages: [message, reply])
        let transport = FakeSocketTransport()
        let socket = ChatSocket(server: f.key.server, token: "test-only", makeTransport: { transport })
        let api = ChatAPI(server: f.key.server, protocolClasses: [ChatStubProtocol.self])
        let owner = ChatSync(key: f.key, store: f.store, api: api, socket: socket, outbox: nil, token: "test-only")
        let previous = f.service.orgSessions[f.key]?.sync
        f.service.orgSessions[f.key]?.sync = owner
        defer { owner.stop(); socket.stop(); f.service.orgSessions[f.key]?.sync = previous }
        f.service.serverCapabilities[f.key.server] = ["chat.dm", "chat.attachments", "chat.dm.attachments"]
        var dmLimits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        dmLimits.dmSenderBytes = 20 * 1024 * 1024
        f.service.serverAttachmentLimits[f.key.server] = dmLimits
        owner.dm.sessionId = "s-anna"; owner.dm.configure(true)
        let catalog = try JSONEncoder().encode(ChatDMPage(dms: [card], next: nil))
        let thread = try JSONEncoder().encode(ChatDMMessagesPage(messages: [message, reply], next: nil, head: 2))
        ChatStubProtocol.reset { request, _ in .success(.init(status: 200, body: request.url?.path.hasSuffix("/dms") == true ? catalog : thread)) }
        try await owner.dm.reloadCatalog(valid: { true })
        for state in ["feed", "thread", "empty", "read-only", "orphan-reply-files"] {
            card.state = state == "read-only" ? "closed" : "active"; card.version += 1
            card.messages = state == "empty" ? [] : [message, reply]
            try f.store.dmWrite { db in
                try db.execute(sql: "DELETE FROM dm_messages WHERE dm_id = ?", arguments: [dm])
                try ChatDMStore.writeCard(db, card)
                _ = try ChatDMStore.saveDraft(db, dm, root: nil, text: "Saved private composer draft.")
            }
            if state == "orphan-reply-files" {
                let bytes = Data("Saved private reply attachment\n".utf8)
                var file = try ChatAttachmentStorage.descriptor(data: bytes, name: "saved-orphan-reply.txt", limits: dmLimits)
                file.attachmentId = "f6000000-0000-4000-8001-00000000000\(dark ? 1 : 0)"
                var draft = ChatAttachmentDraft(file: file, messageId: "reference-orphan-post", owner: .dm(dm), root: "reference-missing-private-thread",
                    session: "s-anna", generation: "g1", sha256: ChatAttachments.digest(bytes), createdAt: Date(), expiresAt: Date().addingTimeInterval(3600), state: .failed)
                draft.problem = "Saved reply file stays on this Mac until its thread is available."
                let manager = try XCTUnwrap(f.service.attachments(f.key))
                try manager.storage.save(bytes, key: f.key, id: draft.id)
                try f.store.dmWrite { db in
                    try ChatAttachments.put(db, draft)
                    _ = try ChatDMStore.saveDraft(db, dm, root: draft.root, text: "Saved reply text for a thread outside this loaded history.")
                }
                manager.reconcile()
            }
            let model = ChatDMModel(key: f.key, dm: dm, service: f.service)
            if state == "thread" { model.openThread(message.messageId) }
            try await Task.sleep(for: .milliseconds(100))
            if state == "orphan-reply-files" { XCTAssertEqual(model.orphanedFileDraftRoots, ["reference-missing-private-thread"]) }
            for width: CGFloat in [1040, 760, 420] {
                try await c.capture("production-dm-" + state, inventory: ["T01", "T03", "T04", "T08"], model: model, messages: model.conversationMessages(root: model.threadRoot),
                    width: width, height: 780, dark: dark, root: model.threadRoot,
                    detail: ["caller": "ChatDMView", "card": try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)),
                        "requiredVisibleText": state == "orphan-reply-files" ? ["Saved reply draft — its thread is not loaded", "saved-orphan-reply.txt"] : []],
                    content: AnyView(ChatDMView(model: model, card: card).frame(width: width, height: 780)))
            }
            model.stop()
        }
    }

    private func sourceExpansionAndLegacyReasons(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture,
                                                model: ChatChannelModel, owner: ChatChannelOwnerModel, dark: Bool) async throws {
        let root = ChatTimelineReferenceFixture.root, channel = ChatTimelineReferenceFixture.channel
        let rootFields: [String: Any] = ["message_id": root, "channel_id": channel, "author_account_id": f.key.accountId,
            "text": "Source request fixture", "revision": 2, "seq": 1, "created_at": ChatTimelineReferenceFixture.date]
        let rootWire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: rootFields))
        try await f.store.queue.write { _ = try ChatMessages.write($0, rootWire) }
        for mode in ["collapsed-four", "expanded-four", "deleted-host", "offline", "activity", "cancel-submitted", "local-pending", "automatic-cancelled", "go-answer"] {
            try f.write("DELETE FROM requests")
            let count = mode.hasSuffix("four") ? 4 : 1
            for index in 0..<count where mode != "local-pending" {
                let id = "reference-source-extra-\(mode)-\(index)-\(dark)"
                let state = mode == "cancel-submitted" ? "submitted" : ["automatic-cancelled", "go-answer"].contains(mode) ? "finished" : "running"
                var body = CallJSON.request(id, state: state, version: 1, runId: mode == "go-answer" ? "reference-answer-run-\(dark)" : nil,
                    owner: f.key.accountId, initiator: mode == "cancel-submitted" ? f.key.accountId : CallJSON.boris)
                body["kind"] = "channel"; body["channel_id"] = channel; body["thread_root_id"] = root; body["source_message_id"] = root
                if mode == "automatic-cancelled" { body["publication"] = "awaiting_publish"; try f.journal.blockAutomaticRequest(f.key, request: id) }
                if mode == "go-answer" { body["publication"] = "published" }
                let wire = CallJSON.wire(body)
                try await f.store.queue.write { try ChatCallStore.apply($0, wire, onThisDevice: false) }
            }
            if mode == "local-pending" {
                let command = "reference-local-call-\(dark)"
                let record = ChatCommandRecord(commandId: command, sessionId: "s-anna", type: "request.create_in_channel_v2", bodyBytes: Data(), orderKey: command,
                    createdAt: ISO8601DateFormatter().date(from: ChatTimelineReferenceFixture.date)!, state: .pending)
                try await f.store.queue.write { try record.insert($0) }
                try f.write("INSERT OR REPLACE INTO channel_sends (draft_version, channel_id, message_id, command_id) VALUES (?, ?, ?, ?)", [command, channel, root, command])
                try f.write("INSERT OR REPLACE INTO channel_call_intents (request_id, message_id, agent_id, command_id) VALUES (?, ?, ?, ?)", [command, root, CallJSON.agent, command])
            }
            if mode == "go-answer" {
                var values = rootFields; values["message_id"] = "reference-answer-\(dark)"; values["seq"] = dark ? 601 : 501
                values["run_id"] = "reference-answer-run-\(dark)"; values["author_agent_id"] = CallJSON.agent; values["author_agent_name"] = "Billing agent"
                let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: values))
                try await f.store.queue.write { _ = try ChatMessages.write($0, wire) }
            }
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(model.sourceStatuses.filter { $0.source == root }.count, count)
            if mode == "activity", let request = model.sourceStatuses.first {
                f.service.receiveChannelActivity(org: f.key.orgId, type: "run.activity", body: .object(["request_id": .string(request.id), "text": .string("Reading reference files")]))
            }
            if mode == "offline" { f.service.isServerKnown = { _, _ in false } }
            let required = mode == "expanded-four" ? ["Show less"] : mode == "collapsed-four" ? ["1 more requests"] : mode == "offline" ? ["Offline"] : mode == "activity" ? ["Reading reference files"] : mode == "automatic-cancelled" ? ["automatic publication cancelled"] : []
            for width: CGFloat in [760, 420] {
                var message = try XCTUnwrap(model.message(root))
                if mode == "deleted-host" { message.deletedAt = ChatTimelineReferenceFixture.date }
                let view = mode == "deleted-host" ? c.row(model, message: message, width: width, thread: false)
                    : AnyView(VStack { ChatSourceProgress(model: model, source: root); Spacer() }.padding(18).frame(width: width, height: 600))
                try await c.capture("source-extra-" + mode, inventory: ["R43", "R44", "R45", "R46"], model: model, messages: [message], width: width, dark: dark,
                    detail: ["visualStates": [mode], "requiredVisibleText": required], content: view, prepare: { _, window in
                        if mode == "expanded-four" { XCTAssertTrue(ChatTimelineReferenceCapture.press("1 more requests", window: window)); try await Task.sleep(for: .milliseconds(40)) }
                    })
            }
            f.service.isServerKnown = { _, _ in true }; f.service.clearChannelActivity()
            if mode == "local-pending" {
                try f.write("DELETE FROM channel_call_intents WHERE request_id = ?", ["reference-local-call-\(dark)"])
                try f.write("DELETE FROM channel_sends WHERE draft_version = ?", ["reference-local-call-\(dark)"])
            }
        }
        for reason in ["agent_removed", "agent_disabled", "owner_left_team", "channel_archived", "initiator_removed", "initiator_left_team", "unrecognized_reason"] {
            let card = ChatChannelRequests.Card(requestId: "reference-legacy-" + reason, agentName: "Billing agent", initiatorAccountId: "former-member", ownerAccountId: f.key.accountId,
                state: TeamRequestState(rawValue: "finished"), publication: "publish_failed", publishReason: reason)
            let legacy = ChatTimelineReferenceModel(f); legacy.threadRoot = root; legacy.threadRequests = [card]
            for width: CGFloat in [760, 420] {
                try await c.capture("legacy-reason-" + reason, inventory: ["R47", "R48"], model: legacy, messages: [], width: width, dark: dark, root: root,
                    detail: ["legacyStateWord": card.stateWord, "publishReason": reason, "requiredVisibleText": [card.stateWord, "a former member", "Open Request"]],
                    content: AnyView(ChatTimelineView(model: legacy, root: root, members: c.members, mentionable: [], me: f.key.accountId, archived: false, ownerModel: owner).frame(width: width, height: 600)))
            }
        }
    }

    private func remainingChromeAndAsk(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let channel = ChatTimelineReferenceFixture.channel, root = ChatTimelineReferenceFixture.root
        let card = ChatChannelCard(channelId: channel, teamId: "f5000000-0000-4000-8000-000000000004", name: "billing", createdBy: f.key.accountId, archived: false, version: 1)
        let session = ChatChannelSession()
        f.service.serverCapabilities[f.key.server] = ChatB1.capabilities
        try f.write("UPDATE meta SET agents_served = 1")
        session.update(.ready(card, team: "Billing", offline: true), key: f.key, store: f.store, service: f.service)
        let model = try XCTUnwrap(session.model)
        let pins = [ChatB1.PinnedMessage(messageId: root, seq: 1, authorAccountId: f.key.accountId, excerpt: "Pinned fixture message", pinnedBy: f.key.accountId, pinnedAt: ChatTimelineReferenceFixture.date)]
        try f.write("INSERT OR REPLACE INTO b1_pins (channel_id, data, dirty) VALUES (?, ?, 0)", [channel, try JSONEncoder().encode(pins)])
        let orphan: [String: Any] = ["message_id": "reference-orphan-unread-\(dark)", "channel_id": channel, "thread_root_id": "reference-unloaded-root", "author_account_id": CallJSON.boris,
            "text": "An unread reply outside the loaded roots", "revision": 1, "seq": dark ? 2301 : 2300, "created_at": ChatTimelineReferenceFixture.date]
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: orphan))
        try await f.store.queue.write { _ = try ChatMessages.write($0, wire) }
        for state in ["thread", "pin-banner", "pins-panel", "agents", "unread-threads"] {
            session.showingAgents = state == "agents"; model.pins.close()
            if state == "thread" { model.openThread(root) } else { model.openThread(nil) }
            if state == "pins-panel" { model.pins.open() }
            try await Task.sleep(for: .milliseconds(80))
            for width: CGFloat in [1040, 760, 420] {
                try await c.capture("production-channel-extra-" + state, inventory: ["T03", "T04"], model: model, messages: model.conversationMessages(root: model.threadRoot),
                    width: width, height: 900, dark: dark, root: model.threadRoot,
                    detail: ["caller": "ChatChannelView", "visualStates": [state], "unloadedUnreadCount": model.feed.unloadedUnreadReplyCount],
                    content: AnyView(ChatChannelView(card: card, team: "Billing", offline: true, key: f.key, conversation: session, service: f.service).frame(width: width, height: 900)))
            }
        }
        session.showingAgents = false; model.pins.close(); model.openThread(nil)
        f.service.serverCapabilities[f.key.server] = []
        f.service.attachments(f.key)?.revoke()
        let agent = ChatChannelAgent(channelId: channel, agentId: CallJSON.agent, name: "billing", ownerAccountId: f.key.accountId, ownerHandle: "anna",
            description: "Billing fixture", access: "read", enabled: true, available: true, executorDeviceName: "Fixture Mac")
        XCTAssertTrue(model.send("@billing@anna Please review the fixture question.", root: nil, members: [], agents: [agent]))
        XCTAssertFalse(model.offers.isEmpty)
        for state in ["offer", "pending", "failed", "expanded-error"] {
            if state != "offer" { for offer in model.offers { model.dismissOffer(offer) } }
            if state == "pending" || state == "failed" {
                let id = "reference-ask-extra-\(state)-\(dark)"
                let envelope = ChatCommandEnvelope(commandId: id, org: f.key.orgId, type: "request.create_in_channel", args: .object([
                    "request_id": .string(id), "channel_id": .string(channel), "agent_id": .string(CallJSON.agent), "thread_root_id": .string(root), "text": .string("Ask fixture question")]))
                var record = ChatCommandRecord(commandId: id, sessionId: "s-anna", type: "request.create_in_channel", bodyBytes: try envelope.encoded(), orderKey: id,
                    createdAt: ISO8601DateFormatter().date(from: ChatTimelineReferenceFixture.date)!, state: state == "failed" ? .failed : .pending)
                if state == "failed" { record.error = "context_changed" }
                let saved = record
                try await f.store.queue.write { try saved.insert($0) }
            }
            if state == "expanded-error" {
                let offer = ChatChannelAsk.Offer(messageId: root, agentId: CallJSON.agent, address: "billing@anna", text: "Question", root: root)
                let form = ChannelAskModel(model: model, fields: .init(offer: offer, text: offer.text, chosen: [root]))
                form.problem = "A message of the context was changed or deleted: choose the context again"; model.channelAsk = form
            }
            try await Task.sleep(for: .milliseconds(60))
            for width: CGFloat in [760, 420] {
                try await c.capture("ask-extra-" + state, inventory: ["R51"], model: model, messages: model.feed.messages, width: width, dark: dark,
                    detail: ["visualStates": ["ask-" + state], "offers": model.offers.map { $0.address }, "asks": model.asks.map { ["failed": $0.failed, "error": $0.error ?? "", "text": $0.text] }],
                    content: AnyView(VStack { ChatAskStrip(model: model, agents: [agent]); Spacer() }.frame(width: width, height: 600)))
            }
            try f.write("UPDATE outbox SET dismissed = 1 WHERE command_id LIKE 'reference-ask-extra-%'")
            model.channelAsk = nil
        }
        f.service.serverCapabilities[f.key.server] = []
    }

    private func remainingReachableStates(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        for own in [true, false] {
            let message = try ChatTimelineReferenceFixture.message("reference-toolbar-ownership-\(own)", me: own ? f.key.accountId : CallJSON.boris)
            let model = ChatTimelineReferenceModel(f, messages: [message])
            XCTAssertEqual(model.canEdit(message), own); XCTAssertEqual(model.canDelete(message), own)
            for width: CGFloat in [760, 420] {
                try await c.capture(own ? "active-own-actions" : "active-other-actions", inventory: ["R22", "R24"], model: model, messages: [message], width: width, dark: dark,
                    detail: ["activeMessageID": message.id, "expectedOwnership": own ? "own" : "other", "requiredVisibleText": ["Reply in thread"]],
                    content: c.row(model, message: message, width: width, thread: width == 420, selected: true))
            }
        }
        let root = try ChatTimelineReferenceFixture.message("reference-server-separator-root", me: f.key.accountId)
        var reply = root; reply.messageId = "reference-server-separator-reply"; reply.seq = 2; reply.threadRootId = root.id; reply.authorAccountId = CallJSON.boris
        let threadModel = ChatTimelineReferenceModel(f, messages: [root, reply]); threadModel.threadRoot = root.id
        f.service.serverCapabilities[f.key.server] = ["chat.thread_summary"]
        let summary = ChatB1.Summary(rootId: root.id, replyCount: 27, lastReplyAt: ChatTimelineReferenceFixture.date, lastReplySeq: 28, lastParticipants: [])
        let metadata = ChatB1.Metadata(messageId: root.id, deleted: false, reactions: [], pin: nil, threadSummary: summary)
        try f.write("INSERT OR REPLACE INTO b1_metadata (channel_id, message_id, data, dirty) VALUES (?, ?, ?, 0)", [root.channelId, root.id, try JSONEncoder().encode(metadata)])
        threadModel.b1 = ChatB1Channel(key: f.key, channel: root.channelId, store: f.store, service: f.service)
        XCTAssertEqual(threadModel.b1?.state.metadata[root.id]?.threadSummary?.replyCount, 27)
        for width: CGFloat in [760, 420] {
            try await c.capture("server-first-reply-separator", inventory: ["T12", "R49"], model: threadModel, messages: [root, reply], width: width, dark: dark, root: root.id,
                detail: ["localReplyCount": 1, "serverReplyCount": 27, "requiredVisibleText": ["27 replies"]], content: c.timeline(threadModel, root: root.id, width: width))
        }
        f.service.serverCapabilities[f.key.server] = ["chat.attachments", "chat.attachments_context"]
        let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        f.service.serverAttachmentLimits[f.key.server] = limits; f.service.isServerKnown = { _, _ in true }
        let manager = try XCTUnwrap(f.service.attachments(f.key))
        manager.revoke()
        let bytes = Data("Retained editor attachment\n".utf8)
        var file = try ChatAttachmentStorage.descriptor(data: bytes, name: "retained-edit-attachment.txt", limits: limits)
        file.attachmentId = "reference-retained-edit-file-\(dark)"
        let values: [String: Any] = ["message_id": "reference-editor-file-message-\(dark)", "channel_id": root.channelId, "author_account_id": f.key.accountId,
            "text": "Editor and attachment coexist.", "revision": 1, "seq": dark ? 2601 : 2600, "created_at": ChatTimelineReferenceFixture.date,
            "attachments": try [JSONSerialization.jsonObject(with: JSONEncoder().encode(file))]]
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: values))
        try await f.store.queue.write { _ = try ChatMessages.write($0, wire) }
        let message = try XCTUnwrap(manager.message(owner: .channel(root.channelId), id: wire.messageId))
        let editor = ChatTimelineReferenceModel(f, messages: [message]); _ = editor.beginEditing(message, root: nil, recovering: false)
        for width: CGFloat in [760, 420] {
            editor.editing?.root = width == 420 ? message.id : nil; editor.threadRoot = editor.editing?.root
            try await c.capture("editor-attachments-retained", inventory: ["R20", "R34"], model: editor, messages: [message], width: width, dark: dark,
                detail: ["requiredVisibleText": ["retained-edit-attachment.txt", "Save"]], content: c.row(editor, message: message, width: width, thread: width == 420),
                prepare: { host, _ in
                    XCTAssertEqual(ChatTimelineReferenceCapture.descendants(host, ChatMentionEditor.Editor.self).first?.string, "Editor and attachment coexist.")
                    XCTAssertNotNil(manager.stamp(owner: message.attachmentOwner))
                })
        }
        var fallback = message; fallback.messageId = "reference-empty-attachment-fallback"; fallback.text = ""; fallback.attachmentOnly = true
        f.service.serverCapabilities[f.key.server] = []
        let fallbackModel = ChatTimelineReferenceModel(f, messages: [fallback])
        for width: CGFloat in [760, 420] {
            try await c.capture("attachments-fallback", inventory: ["R34"], model: fallbackModel, messages: [fallback], width: width, dark: dark,
                detail: ["requiredVisibleText": ["Attachments"], "attachmentCapability": false, "originalText": ""], content: c.row(fallbackModel, message: fallback, width: width, thread: width == 420),
                prepare: { host, _ in
                    XCTAssertEqual(ChatTimelineReferenceCapture.descendants(host, NSTextView.self).first { !$0.isEditable }?.string, "Attachments")
                })
        }
        f.service.serverCapabilities[f.key.server] = ["chat.attachments", "chat.attachments_context"]
        var importCompleted = false
        try manager.importFiles(count: 1, owner: .channel(root.channelId), root: nil, load: {
            try await Task.sleep(for: .seconds(30)); return []
        }, completion: { _ in importCompleted = true })
        do {
            XCTAssertTrue(manager.isImporting(channel: root.channelId, root: nil))
            for width: CGFloat in [760, 420] {
                try await c.capture("draft-importing", inventory: ["R41"], model: fallbackModel, messages: [], width: width, dark: dark,
                    detail: ["requiredVisibleText": ["Preparing files…"], "importLoad": "Existing async load closure held until capture; cancelled without importing bytes"],
                    content: AnyView(VStack { ChatAttachmentDraftStrip(manager: manager, channel: root.channelId, root: nil); Spacer() }.frame(width: width, height: 600)))
            }
        } catch {
            manager.suspend()
            for _ in 0..<100 where !importCompleted { try? await Task.sleep(for: .milliseconds(10)) }
            throw error
        }
        manager.suspend()
        for _ in 0..<100 where !importCompleted { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(importCompleted, "Owned held import must complete cancellation before leaving its capture fixture")
        let unknown = ChatChannelRequests.Card(requestId: "reference-legacy-unknown", agentName: "Billing agent", initiatorAccountId: f.key.accountId, ownerAccountId: CallJSON.boris,
            state: TeamRequestState(rawValue: "awaiting_vendor_response"))
        let legacy = ChatTimelineReferenceModel(f); legacy.threadRoot = root.id; legacy.threadRequests = [unknown]
        XCTAssertEqual(unknown.stateWord, "awaiting vendor response")
        for width: CGFloat in [760, 420] {
            try await c.capture("legacy-unknown-state-caption", inventory: ["R48"], model: legacy, messages: [], width: width, dark: dark, root: root.id,
                detail: ["rawState": unknown.state.rawValue, "requiredVisibleText": ["awaiting vendor response"]], content: c.timeline(legacy, root: root.id, width: width))
        }
        let requestID = "reference-source-action-race-\(dark)"
        var request = CallJSON.request(requestID, state: "running", version: 1, owner: f.key.accountId)
        request["kind"] = "channel"; request["channel_id"] = root.channelId; request["thread_root_id"] = root.id; request["source_message_id"] = root.id
        let requestWire = CallJSON.wire(request)
        try await f.store.queue.write { db in try db.execute(sql: "DELETE FROM requests"); try ChatCallStore.apply(db, requestWire, onThisDevice: false) }
        let source = ChatChannelModel(key: f.key, channel: root.channelId); source.service = f.service; source.follow(f.store)
        for width: CGFloat in [760, 420] {
            try f.write("UPDATE requests SET state = 'running' WHERE request_id = ?", [requestID])
            try await Task.sleep(for: .milliseconds(40))
            try await c.capture("source-local-action-problem", inventory: ["R43"], model: source, messages: [], width: width, dark: dark,
                detail: ["requiredVisibleText": ["Only a call that is running can be stopped."], "actionTrigger": "Request changes to approved after mount, before stale Stop action; action returns local rejection without enqueue"],
                content: AnyView(VStack { ChatSourceProgress(model: source, source: root.id); Spacer() }.padding(18).frame(width: width, height: 600)),
                prepare: { host, window in
                    try f.write("UPDATE requests SET state = 'approved' WHERE request_id = ?", [requestID])
                    guard try f.request(requestID).state == .approved else { throw NSError(domain: "Fixture did not close Stop eligibility before stale action", code: 1) }
                    let before = try f.store.outbox.commands().count
                    XCTAssertTrue(ChatTimelineReferenceCapture.press("Stop agent", window: window))
                    XCTAssertEqual(try f.store.outbox.commands().count, before, "Stale Stop rejection cannot enqueue a command")
                    try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
                })
        }
        f.service.serverCapabilities[f.key.server] = []
    }

    private func retainedSessionAndPublication(_ c: ChatTimelineReferenceCapture, outerService: ChatService, dark: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-reference-retained-session-\(UUID())")
        let runner = F6Runner(projects: directory.appendingPathComponent("claude-projects"))
        let fixture = try await ChatChannelExecutionTests.Fixture(root: directory, executor: runner)
        let previousTeam = TeamService.sharedForTesting
        TeamService.sharedForTesting = fixture.teamService
        ChatOrgCurrent.shared.refresh(fixture.service)
        defer { TeamService.sharedForTesting = previousTeam; ChatOrgCurrent.shared.refresh(outerService) }
        do {
            try fixture.write("UPDATE meta SET agents_served = 1")
            fixture.service.isServerKnown = { _, _ in true }
            let run = try await fixture.finish()
            let request = "f5000000-0000-4000-8000-000000000003", channel = ChatTimelineReferenceFixture.channel, root = ChatTimelineReferenceFixture.root
            try fixture.write("UPDATE requests SET source_message_id = ? WHERE request_id = ?", [root, request])
            let owner = ChatChannelOwnerModel(service: fixture.service, key: fixture.key, channel: channel)
            XCTAssertTrue(owner.canOpenSession(request))
            let model = ChatChannelModel(key: fixture.key, channel: channel); model.service = fixture.service; model.follow(fixture.store)
            let card = ChatChannelRequests.Card(requestId: request, agentName: "Billing agent", initiatorAccountId: CallJSON.boris, ownerAccountId: fixture.key.accountId,
                state: TeamRequestState(rawValue: "finished"), publication: "awaiting_publish")
            for state in ["open-session", "stale-open-control-removed"] {
                for width: CGFloat in [760, 420] {
                    let transcript = runner.transcript(run.conversationId)
                    let saved = try Data(contentsOf: transcript)
                    try await c.capture("legacy-retained-" + state, inventory: ["R47"], model: model, messages: [], width: width, dark: dark,
                        detail: ["visualStates": [state], "conversationID": run.conversationId,
                            "requiredVisibleText": [state == "open-session" ? "Open Session" : "Open Request"],
                            "returnedErrorContract": "This conversation is not available through the channel on this Mac.",
                            "settledErrorVisibility": state == "open-session" ? "no error" : "Open Session control and its nested error disappear when the gateway closes"],
                        content: AnyView(VStack { ChatRequestCardRow(card: card, members: c.members, ownerModel: owner); Spacer() }.padding(18).frame(width: width, height: 600)),
                        prepare: { host, window in
                            if state == "stale-open-control-removed" {
                                try FileManager.default.removeItem(at: transcript)
                                guard !owner.canOpenSession(request) else {
                                    throw NSError(domain: "Fixture session gateway remained open after transcript removal; refusing the stale action", code: 1)
                                }
                                XCTAssertTrue(ChatTimelineReferenceCapture.press("Open Session", window: window))
                                try await Task.sleep(for: .milliseconds(40))
                                host.layoutSubtreeIfNeeded()
                                let strings = ChatTimelineReferenceCapture.accessibilityNodes(window).flatMap { node in
                                    ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap {
                                        ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String
                                    }
                                }
                                XCTAssertFalse(strings.contains { $0.contains("Open Session") }, "The unchanged row removes the session control after its gate closes")
                                let rejection = "This conversation is not available through the channel on this Mac."
                                XCTAssertFalse(strings.contains { $0.contains(rejection) }, "The error is nested under the same closed gate and is absent from the settled row")
                                XCTAssertEqual(owner.openSession(request), rejection, "The rejected-action return value is a separate contract from the settled row's pixels")
                            }
                        })
                    try saved.write(to: transcript)
                }
            }
            let command = try fixture.service.publishChannelResult(fixture.key, requestId: request, publish: true)
            for state in ["pending", "failed", "unconfirmed"] {
                try fixture.write("UPDATE outbox SET state = ?, error = ? WHERE command_id = ?", [state, state == "failed" ? "too_large" : nil, command.commandId])
                try await Task.sleep(for: .milliseconds(60))
                XCTAssertNotNil(fixture.service.channelPublicationIssue(fixture.key, requestId: request))
                for width: CGFloat in [760, 420] {
                    try await c.capture("publication-issue-" + state, inventory: ["R44", "R51"], model: model, messages: [], width: width, dark: dark,
                        detail: ["publicationIssue": fixture.service.channelPublicationIssue(fixture.key, requestId: request) ?? "", "runID": run.runId,
                            "requiredVisibleText": [fixture.service.channelPublicationIssue(fixture.key, requestId: request) ?? "", "Open Request"]],
                        content: AnyView(VStack(spacing: 16) { ChatChannelOwnerPanel(model: owner); ChatSourceProgress(model: model, source: root); Spacer() }.padding(18).frame(width: width, height: 600)))
                }
            }
            fixture.sender?.hold(); await fixture.service.disconnect()
        } catch { fixture.sender?.hold(); await fixture.service.disconnect(); try? FileManager.default.removeItem(at: directory); throw error }
        try FileManager.default.removeItem(at: directory)
    }

    private func sourceAndBoundaryMatrix(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let model = ChatChannelModel(key: f.key, channel: ChatTimelineReferenceFixture.channel); model.service = f.service; model.follow(f.store)
        try f.write("UPDATE meta SET agents_served = 1")
        let ownerModel = ChatChannelOwnerModel(service: f.service, key: f.key, channel: ChatTimelineReferenceFixture.channel)
        for state in ["submitted", "awaiting_decision", "approved", "starting", "running", "finished", "failed", "declined", "cancelled", "stopped", "lost"] {
            let publications: [String?] = state == "finished" ? ["published", "awaiting_publish", "withheld", "publish_failed", nil] : [nil]
            for publication in publications {
                let id = "reference-request-\(state)-\(publication ?? "none")"
                var body = CallJSON.request(id, state: state, version: 1, fixed: true)
                body["kind"] = "channel"; body["channel_id"] = ChatTimelineReferenceFixture.channel
                body["thread_root_id"] = ChatTimelineReferenceFixture.root; body["source_message_id"] = ChatTimelineReferenceFixture.root
                if let publication { body["publication"] = publication }
                if publication == "publish_failed" { body["publish_reason"] = "agent_disabled" }
                let requestWire = CallJSON.wire(body)
                try await f.store.queue.write { db in
                    try db.execute(sql: "DELETE FROM requests")
                    try ChatCallStore.apply(db, requestWire, onThisDevice: false)
                }
                try await Task.sleep(for: .milliseconds(40))
                XCTAssertEqual(model.sourceStatuses.filter { $0.source == ChatTimelineReferenceFixture.root }.count, 1)
                let card = ChatChannelRequests.Card(requestId: id, agentName: "Billing agent", initiatorAccountId: CallJSON.boris, ownerAccountId: f.key.accountId,
                    state: TeamRequestState(rawValue: state), publication: publication, publishReason: publication == "publish_failed" ? "agent_disabled" : nil)
                let legacy = ChatTimelineReferenceModel(f); legacy.threadRoot = ChatTimelineReferenceFixture.root; legacy.threadRequests = [card]
                for width: CGFloat in [760, 420] {
                    try await c.capture("source-\(state)-\(publication ?? "none")", inventory: ["R43", "R44", "R45", "R46", "R47", "R48"], model: model, messages: [], width: width, dark: dark,
                        detail: ["requestFixture": body, "sourceStatuses": String(describing: model.sourceStatuses)],
                        content: AnyView(VStack(alignment: .leading, spacing: 16) {
                            ChatSourceProgress(model: model, source: ChatTimelineReferenceFixture.root)
                            ChatTimelineView(model: legacy, root: legacy.threadRoot, members: c.members, mentionable: [], me: f.key.accountId, archived: false, ownerModel: ownerModel).frame(height: 220)
                            Spacer()
                        }.padding(18).frame(width: width, height: 600)))
                }
            }
        }
        try await sourceExpansionAndLegacyReasons(c, fixture: f, model: model, owner: ownerModel, dark: dark)
        model.saveDraft("A composer draft outside the scrolling history.", root: nil)
        for width: CGFloat in [760, 420] {
            try await c.capture("chrome-composer-boundary", inventory: [], model: model, messages: model.feed.messages,
                width: width, height: 780, dark: dark, content: AnyView(VStack(spacing: 0) {
                    Text("# billing").font(Theme.display(18, weight: .semibold)).padding(20)
                    Divider()
                    ChatTimelineView(model: model, root: nil, members: c.members, mentionable: [], me: f.key.accountId, archived: false, ownerModel: nil)
                    Divider()
                    ChatUX1Composer(model: model, root: nil, members: c.members, mentionable: [], agents: [])
                }.frame(width: width, height: 780)))
        }
    }
}
