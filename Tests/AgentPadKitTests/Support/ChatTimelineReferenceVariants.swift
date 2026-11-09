import AppKit
import AgentPadQuietTestSupport
import Foundation
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor enum ChatTimelineReferenceVariants {
    static func viewportOnly(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        try await toolbarViewportEdges(c, fixture: f, dark: dark)
    }
    static func run(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        try await denseReactions(c, fixture: f, dark: dark)
        try await reactors(c, fixture: f, dark: dark)
        try await picker(c, fixture: f, dark: dark)
        try await recovery(c, fixture: f, dark: dark)
        try await attribution(c, fixture: f, dark: dark)
        try await avatars(c, fixture: f, dark: dark)
        try await editorAndTime(c, fixture: f, dark: dark)
        try await menus(c, fixture: f, dark: dark)
        try await toolbarVariants(c, fixture: f, dark: dark, connected: false)
        try await replyControlFocus(c, fixture: f, dark: dark)
        try await multilineMembership(c, fixture: f, dark: dark)
        try await connectedControls(c, dark: dark)
        ChatOrgCurrent.shared.refresh(f.service)
    }

    private static func row(_ model: any ChatConversationPresentation, message: ChatMessage, members: [ChatOrgView.Member],
                            width: CGFloat, archived: Bool = false) -> AnyView {
        AnyView(VStack(spacing: 0) {
            Color.clear.frame(height: 24)
            ChatNativeRowFixture(model: model, message: message, members: members, mentionable: members.map { ($0.accountId, $0.handle) },
                me: model.key.accountId, archived: archived, replies: 0, inThread: width == 420)
            Spacer(minLength: 0)
        }.frame(width: width, height: 600, alignment: .topLeading))
    }

    private static func seedB1(_ f: ChatChannelExecutionTests.Fixture, message: ChatMessage, reactions: [ChatB1.Reaction],
                               pin: Bool = false, intent: String? = nil, failed: Bool = false, dark: Bool) throws -> ChatB1Channel {
        f.service.serverCapabilities[f.key.server] = ChatB1.capabilities
        f.service.isServerKnown = { _, _ in true }
        let value = ChatB1.Metadata(messageId: message.id, deleted: false, reactions: reactions,
            pin: pin ? .init(pinnedBy: f.key.accountId, pinnedAt: ChatTimelineReferenceFixture.date) : nil, threadSummary: nil)
        try f.store.queue.write { db in
            try db.execute(sql: "DELETE FROM b1_metadata")
            try db.execute(sql: "DELETE FROM b1_intents")
            try ChatB1.watch(db, channel: message.channelId, ids: [message.id])
            try db.execute(sql: "UPDATE b1_metadata SET data = ?, dirty = 0, as_of_seq = 3 WHERE message_id = ?",
                arguments: [try JSONEncoder().encode(value), message.id])
            if let intent {
                let command = "reference-variant-\(message.id)-\(intent)-\(dark)"
                var record = ChatCommandRecord(commandId: command, sessionId: "s-anna", type: "message.reaction.set", bodyBytes: Data(),
                    orderKey: command, createdAt: ISO8601DateFormatter().date(from: ChatTimelineReferenceFixture.date)!, state: .pending)
                if failed { record.state = .dropped; record.error = "Change not confirmed. Try again." }
                try record.insert(db)
                try db.execute(sql: "INSERT INTO b1_intents (command_id, channel_id, message_id, choice, present) VALUES (?, ?, ?, ?, 1)",
                    arguments: [command, message.channelId, message.id, intent])
            }
        }
        return ChatB1Channel(key: f.key, channel: message.channelId, store: f.store, service: f.service)
    }

    private static func denseReactions(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let m = try ChatTimelineReferenceFixture.message("reference-variant-twenty", me: f.key.accountId)
        let emoji = ChatTimelineReferenceFixture.emoji + ["✨", "💯", "😍", "🤯", "😢", "😡", "👏", "🙌"]
        XCTAssertEqual(Set(emoji).count, 20)
        let reactions = emoji.map { ChatB1.Reaction(emoji: $0, count: 3, mine: $0 == "👍") }
        let b1 = try seedB1(f, message: m, reactions: reactions, dark: dark)
        let model = ChatTimelineReferenceModel(f, messages: [m]); model.b1 = b1
        XCTAssertEqual(b1.state.metadata[m.id]?.reactions.count, 20)
        try await c.capture("b1-twenty-emoji-narrow-thread", inventory: ["R27"], model: model, messages: [m], width: 420, dark: dark,
            detail: ["reactionCount": 20], content: c.row(model, message: m, width: 420, thread: true))
    }

    private static func reactors(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let m = try ChatTimelineReferenceFixture.message("reference-variant-reactors", me: f.key.accountId)
        let socket = ChatSocket(server: f.key.server, token: "test-only", makeTransport: { FakeSocketTransport() })
        let api = ChatAPI(server: f.key.server, protocolClasses: [ChatStubProtocol.self])
        let owner = ChatSync(key: f.key, store: f.store, api: api, socket: socket, outbox: nil, token: "test-only")
        let previous = f.service.orgSessions[f.key]?.sync
        f.service.orgSessions[f.key]?.sync = owner
        owner.b1.configure(["chat.reactions"])
        owner.b1.resume()
        defer {
            owner.stop(); socket.stop(); f.service.orgSessions[f.key]?.sync = previous
            f.service.orgSessions[f.key]?.snapshotOwed = false
            ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
        }
        let b1 = try seedB1(f, message: m, reactions: [.init(emoji: "👍", count: 3, mine: false)], dark: dark)
        let model = ChatTimelineReferenceModel(f, messages: [m]); model.b1 = b1
        let path = "/v1/orgs/\(f.key.orgId)/channels/\(m.channelId)/messages/\(m.id)/reactions"
        for state in ["names-and-former-member", "show-more", "second-page", "empty", "error-retry", "loading", "inaccessible"] {
            let ids = state == "empty" ? [] : [f.key.accountId, CallJSON.boris, "reference-former-member"]
            let next: String? = state == "show-more" || state == "second-page" ? "reference-more" : nil
            let response = try JSONEncoder().encode(ChatB1.ReactorsPage(asOfSeq: 1000, accountIds: ids, next: next))
            let second = try JSONEncoder().encode(ChatB1.ReactorsPage(asOfSeq: 1000, accountIds: ["reference-second-page-former"], next: nil))
            let gate = Gate()
            if state == "loading" { gate.close() }
            ChatStubProtocol.reset { request, _ in
                guard request.url?.path == path else { return .failure(URLError(.unsupportedURL)) }
                gate.pass()
                if state == "error-retry" { return .failure(URLError(.networkConnectionLost)) }
                let after = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "after" }?.value
                return .success(.init(status: 200, body: state == "second-page" && after != nil ? second : response))
            }
            defer { gate.open() }
            f.service.orgSessions[f.key]?.snapshotOwed = state == "inaccessible"
            if !["loading", "inaccessible", "error-retry"].contains(state) {
                let list = ChatReactionAccounts(b1: b1, message: m.id, emoji: "👍")
                await list.load(restart: true)
                XCTAssertEqual(list.accounts, ids)
                XCTAssertEqual(list.next, next)
                XCTAssertNil(list.error)
                if state == "second-page" {
                    await list.load(restart: false)
                    XCTAssertEqual(list.accounts, ids + ["reference-second-page-former"])
                    XCTAssertNil(list.next)
                }
            }
            try await c.capture("reactors-content-" + state, inventory: ["R28"], model: model, messages: [m], width: 420, dark: dark,
                detail: ["reactorsBranch": state, "responseAccounts": ids, "responseNext": next ?? NSNull(),
                    "requiredVisibleText": state == "inaccessible" ? ["Channel unavailable"] : state == "empty" ? ["No reactions yet"] : state == "error-retry" ? ["Could not load reactions.", "Retry"] : state == "show-more" ? ["Anna", "Boris", "Former member", "Show more"] : state == "names-and-former-member" ? ["Anna", "Boris", "Former member"] : ["Who reacted"],
                    "placement": "production ChatReactorsView content; external popup placement recorded separately"],
                content: AnyView(VStack(alignment: .leading) {
                    ChatReactorsView(b1: b1, message: m.id, emoji: "👍", members: c.members)
                    Spacer()
                }.padding(24).frame(width: 420, height: 600)), prepare: { _, window in
                    if state == "loading" {
                        for _ in 0..<30 {
                            if ChatStubProtocol.seen.contains(where: { $0.request.url?.path == path }) { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        XCTAssertTrue(ChatStubProtocol.seen.contains { $0.request.url?.path == path })
                    }
                    if state == "second-page" {
                        XCTAssertTrue(ChatTimelineReferenceCapture.press("Show more", window: window))
                        try await Task.sleep(for: .milliseconds(100))
                        let more = ChatTimelineReferenceCapture.accessibilityNodes(window).contains { node in
                            ChatTimelineReferenceCapture.accessibilityAttribute(node, "accessibilityTitle") as? String == "Show more"
                        }
                        XCTAssertFalse(more)
                    }
                })
            gate.open()
            f.service.orgSessions[f.key]?.snapshotOwed = false
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private static func picker(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool, connected: Bool = false) async throws {
        let m = try ChatTimelineReferenceFixture.message("reference-variant-picker", me: f.key.accountId)
        for state in ["valid-entry", "invalid-entry", "pending", "failure"] {
            let b1 = try seedB1(f, message: m, reactions: [], intent: state == "pending" ? "👍" : nil, dark: dark)
            if state == "failure" { b1.toggle(m.id, emoji: "invalid") }
            let model = ChatTimelineReferenceModel(f, messages: [m]); model.b1 = b1
            let entry = state == "valid-entry" ? "🎉" : state == "invalid-entry" ? "two words" : state == "pending" ? "👍" : ""
            if connected { XCTAssertTrue(b1.canChange) }
            try await c.capture("reaction-picker-\(connected ? "connected-" : "")" + state, inventory: ["R29"], model: model, messages: [m], width: 420, dark: dark,
                detail: ["pickerBranch": state, "entry": entry, "canChange": b1.canChange, "requiredVisibleText": state == "failure" ? ["Choose one emoji."] : ["Add reaction"],
                    "placement": connected ? "production picker with connected fake feed and held outbox" : "production picker with disconnected mutation gate"],
                content: AnyView(VStack(alignment: .leading) { ChatReactionPicker(b1: b1, message: m.id); Spacer() }.frame(width: 420, height: 600)),
                prepare: { host, window in
                    let field = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host, NSTextField.self).first { $0.placeholderString == "Emoji" })
                    if !entry.isEmpty {
                        window.makeFirstResponder(field)
                        field.stringValue = entry
                        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                        try await Task.sleep(for: .milliseconds(30))
                        XCTAssertEqual(field.stringValue, entry)
                    }
                    if state == "pending" { XCTAssertTrue(b1.pending(m.id, choice: "👍")) }
                    if state == "failure" { XCTAssertEqual(b1.problem(m.id), "Choose one emoji.") }
                    if connected {
                        let add = try XCTUnwrap(ChatTimelineReferenceCapture.accessibilityNodes(window).first { node in
                            ["accessibilityLabel", "accessibilityTitle"].contains { ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String == "Add" }
                        })
                        XCTAssertEqual(try enabled(add), state == "valid-entry")
                    }
                })
        }
        f.service.serverCapabilities[f.key.server] = []
    }

    private static func pickerPopup(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let message = try ChatTimelineReferenceFixture.message("reference-picker-popup", me: f.key.accountId)
        let model = ChatTimelineReferenceModel(f, messages: [message])
        let b1 = try seedB1(f, message: message, reactions: [], dark: dark)
        model.b1 = b1
        XCTAssertTrue(b1.canChange)
        for width: CGFloat in [760, 420] {
            try await c.capture("reaction-picker-owner", inventory: ["R29", "S26"], model: model, messages: [message], width: width, dark: dark,
                detail: ["activeMessageID": message.id],
                content: c.row(model, message: message, width: width, thread: width == 420, selected: true),
                prepare: { _, window in
                    XCTAssertTrue(ChatTimelineReferenceCapture.press("Add reaction", window: window))
                    try await Task.sleep(for: .milliseconds(150))
                    let popup = try XCTUnwrap(NSApp.windows.first { $0 !== window && $0.isVisible && $0.parent === window })
                    defer { popup.performClose(nil) }
                    XCTAssertFalse(APQuietWindowHasOSFocus(popup))
                    let labels = ChatTimelineReferenceCapture.accessibilityNodes(popup).flatMap { node in
                        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String }
                    }
                    XCTAssertTrue(labels.contains("Add reaction"), "Native picker heading absent: \(labels)")
                    popup.colorSpace = ChatTimelineCaptureColor.colorSpace
                    let view = try XCTUnwrap(popup.contentView)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try ChatTimelineCaptureColor.bitmap(view)
                    try c.write(bitmap, id: "reaction-picker-popup-window-\(Int(width))-\(dark ? "dark" : "light")", inventory: ["R29", "S26"],
                        width: view.bounds.width, height: view.bounds.height, dark: dark, scale: popup.backingScaleFactor,
                        detail: ["fixtureValues": try [JSONSerialization.jsonObject(with: JSONEncoder().encode(message))],
                            "nativePopup": true, "stateLabels": ["reaction-picker-open"], "nativeAccessibilityStrings": labels])
                })
        }
    }

    private static func recovery(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        let file = try ChatAttachmentStorage.descriptor(data: Data("Paused fixture".utf8), name: "paused-notes.txt", limits: limits)
        f.service.serverAttachmentLimits[f.key.server] = limits
        f.service.serverCapabilities[f.key.server] = []
        for state in ["attachment-paused", "failed-retry-disabled", "delete-conflict", "archived-edit-recovery", "other-editor-blocks-edit-again"] {
            var m = try ChatTimelineReferenceFixture.message("reference-variant-" + state, me: f.key.accountId)
            let model = ChatTimelineReferenceModel(f)
            if state == "attachment-paused" { m.localState = .sending; m.attachments = [file] }
            if state == "failed-retry-disabled" { m.localState = .failed; m.localError = "not_connected"; model.retryAllowed = false }
            if state == "delete-conflict" { m.localEdit = .init(kind: "delete", text: nil, state: "failed", error: "revision_conflict") }
            if state == "archived-edit-recovery" || state == "other-editor-blocks-edit-again" {
                m.localEdit = .init(kind: "edit", text: "A recoverable saved edit.", state: "failed", error: "not_connected")
            }
            if state == "other-editor-blocks-edit-again" {
                let other = try ChatTimelineReferenceFixture.message("reference-other-active-editor", me: f.key.accountId)
                model.editing = .init(messageId: other.id, root: nil, text: other.text, revision: other.revision, message: other)
            }
            model.feed.messages = [m]
            model.feed.archived = state == "archived-edit-recovery"
            if state == "attachment-paused" {
                XCTAssertNotNil(f.service.attachments(f.key)?.pauseReason(owner: m.attachmentOwner))
            }
            for width: CGFloat in [760, 420] {
                try await c.capture(state, inventory: ["R18", "R19"], model: model, messages: [m], width: width, dark: dark,
                    detail: ["recoveryBranch": state, "retryAllowed": model.canRetry(m)],
                    content: c.row(model, message: m, width: width, thread: width == 420, archived: model.feed.archived))
            }
        }
    }

    private static func attribution(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        for state in ["own-you", "published-catalog-name", "published-agent-fallback", "unknown-fixed-attribution", "number-placeholder", "emoji-question-placeholder"] {
            var m = try ChatTimelineReferenceFixture.message("reference-attribution-" + state, me: f.key.accountId)
            var members = c.members
            if state == "own-you" { members = members.filter { $0.accountId != f.key.accountId } }
            if state == "published-catalog-name" { m.authorAgentId = CallJSON.agent; m.authorAgentName = nil }
            if state == "published-agent-fallback" { m.authorAgentId = "reference-missing-agent"; m.authorAgentName = nil }
            if state == "unknown-fixed-attribution" { m.hasFixed = false; m.hasMutable = false }
            if state == "number-placeholder" || state == "emoji-question-placeholder" {
                let name = state == "number-placeholder" ? "123" : "🦊✨"
                members = [.init(accountId: f.key.accountId, handle: "anna", name: name, role: "owner")]
            }
            let model = ChatTimelineReferenceModel(f, messages: [m])
            for width: CGFloat in [760, 420] {
                try await c.capture("attribution-" + state, inventory: ["R06", "R08"], model: model, messages: [m], width: width, dark: dark,
                    detail: ["attributionBranch": state, "members": members.map { ["accountId": $0.accountId, "handle": $0.handle, "name": $0.name, "role": $0.role] }],
                    content: row(model, message: m, members: members, width: width))
            }
        }
    }

    private static func avatars(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let fixture = try AvatarTestFixture()
        let service = fixture.service, ref = fixture.own
        let context = try XCTUnwrap(service.avatarDisplayContext(fixture.key))
        let bytes = try AvatarTestImage.png()
        let imageID = "01900000-0000-7000-8000-000000000099"
        service.avatars.receive(.init(revision: 1, imageId: imageID), for: ref, context: context)
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200,
            headers: ["Content-Type": "image/png", "X-Avatar-Revision": "1", "X-AgentPad-Generation": "g"], body: bytes)) }
        let image = await service.avatars.load(ref)
        XCTAssertNotNil(image)
        let model = ChatTimelineReferenceModel(f)
        let profileID = UUID()
        let details = AgentProfileStore.shared.details
        details.avatarImages[profileID] = (details.avatar(profileID).revision, image)
        defer { details.avatarImages.removeValue(forKey: profileID) }
        do {
        try await c.capture("avatar-local-profile-image", inventory: ["R08"], model: model, messages: [], width: 420, dark: dark,
            detail: ["avatarBranch": "localProfileID", "fixture": "test-only decoded local profile cache; no profile or file write"],
            content: AnyView(VStack(alignment: .leading) {
                ContactAvatar(stableID: "reference-local-profile", name: "Local agent", kind: .agent, size: 96, localProfileID: profileID, service: service)
                Spacer()
            }.padding(24).frame(width: 420, height: 600)), prepare: { _, _ in XCTAssertNotNil(details.image(profileID)) })
        for state in ["remote-image", "valid-held-image", "revoked-placeholder"] {
            if state == "valid-held-image" {
                service.avatars.countLimit = 0; service.avatars.clear()
                service.avatars.receive(.init(revision: 1, imageId: imageID), for: ref, context: context)
            }
            if state == "revoked-placeholder" { fixture.service.orgSessions[fixture.key]?.snapshotOwed = true }
            try await c.capture("avatar-" + state, inventory: ["R08"], model: model, messages: [], width: 420, dark: dark,
                detail: ["avatarBranch": state, "avatarReference": ref.subject.id,
                    "placement": state == "valid-held-image" ? "countLimit zero; mounted load must retain decoded image outside cache" : "production ContactAvatar"],
                content: AnyView(VStack(alignment: .leading) {
                    ContactAvatar(stableID: ref.subject.id, name: "Anna", kind: .person, size: 96, remote: ref, service: service)
                    Spacer()
                }.padding(24).frame(width: 420, height: 600)), prepare: { _, _ in
                    if state == "revoked-placeholder" { XCTAssertNil(service.avatarDisplayContext(fixture.key)) }
                    else {
                        let loaded = await service.avatars.load(ref)
                        XCTAssertNotNil(loaded)
                    }
                })
        }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
    }

    private static func editorAndTime(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        for state in ["invalid-short-time", "editor-unfocused", "editor-max160", "editor-loading", "editor-programmatic-marked-text"] {
            var m = try ChatTimelineReferenceFixture.message("reference-variant-" + state, me: f.key.accountId)
            if state == "invalid-short-time" { m.createdAt = "invalid-reference-timestamp" }
            if state == "editor-loading" { m.hasMutable = false }
            let model = ChatTimelineReferenceModel(f, messages: [m])
            if state.hasPrefix("editor-") {
                let text = state == "editor-max160" ? String(repeating: "A long saved editor line.\n", count: 40) : "Saved text remains in the inline editor."
                model.editing = .init(messageId: m.id, root: nil, text: text, revision: m.revision, message: m)
            }
            for width: CGFloat in [760, 420] {
                try await c.capture(state, inventory: state == "invalid-short-time" ? ["R09"] : ["R20", "R21"], model: model, messages: [m], width: width, dark: dark,
                    detail: ["editorTimeBranch": state, "timestampTooltipExpected": m.createdAt,
                        "imeBoundary": "programmatic NSTextInputClient marked text only; no hardware input-method session"],
                    content: c.row(model, message: m, width: width, thread: false, selected: state == "invalid-short-time"), prepare: { host, window in
                        if state == "editor-unfocused" { window.makeFirstResponder(nil) }
                        if state.hasPrefix("editor-") {
                            let editor = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host, NSTextView.self).first { $0.isEditable })
                            if state == "editor-max160" { XCTAssertGreaterThan((editor.string as NSString).length, 900) }
                            if state == "editor-unfocused" { XCTAssertFalse(window.firstResponder === editor) }
                            if state == "editor-programmatic-marked-text" {
                                window.makeFirstResponder(editor)
                                editor.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
                                XCTAssertTrue(editor.hasMarkedText())
                            }
                        }
                    })
            }
        }
    }

    private static func menus(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool, connected: Bool = false) async throws {
        for state in ["other-channel", "deleted-dm", "loading", "pin", "unpin", "pin-pending", "copy-text-loading"] {
            var m = try ChatTimelineReferenceFixture.message("reference-menu-" + state, me: f.key.accountId, text: "Menu enumeration target.")
            let model = ChatTimelineReferenceModel(f)
            if state == "other-channel" { m.authorAccountId = CallJSON.boris }
            if state == "deleted-dm" { m.deletedAt = ChatTimelineReferenceFixture.date; model.isDM = true }
            if state == "loading" || state == "copy-text-loading" { m.hasMutable = false }
            model.feed.messages = [m]
            if !model.isDM {
                model.b1 = try seedB1(f, message: m, reactions: [], pin: state == "unpin", intent: state == "pin-pending" ? "pin" : nil, dark: dark)
            }
            let message = m
            try await c.capture("menu-owner-row-\(connected ? "connected-" : "")" + state, inventory: [], model: model, messages: [message], width: 760, dark: dark,
                detail: ["menuVariant": state, "menuBitmap": false], content: c.row(model, message: message, width: 760, thread: false), prepare: { host, window in
                    let cell = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host, ChatNativeShellCell.self).first)
                    let menu = try XCTUnwrap(cell.rowActions.makeMenu())
                    if model.isDM {
                        XCTAssertNil(model.b1)
                        XCTAssertEqual(menu.items.map(\.title).filter { ["Add reaction…", "Pin message", "Unpin message"].contains($0) }, [])
                        XCTAssertTrue(menu.items.contains { $0.title == "Copy text" })
                    }
                    if connected && !model.isDM {
                        XCTAssertTrue(try XCTUnwrap(model.b1).canChange)
                        if ["pin", "unpin", "pin-pending"].contains(state) {
                            let pin = try XCTUnwrap(menu.items.first { $0.title == "Pin message" || $0.title == "Unpin message" })
                            XCTAssertEqual(pin.isEnabled, state != "pin-pending")
                        }
                    }
                    let items = menu.items.map { ["title": $0.title, "enabled": $0.isEnabled, "separator": $0.isSeparatorItem] as [String: Any] }
                    let record: [String: Any] = ["inventoryIDs": ["R23"], "state": state, "menuItems": items,
                        "status": "enumeration only; native menu tracking and bitmap are not invoked",
                        "copyTextResult": model.copyText(message) ?? NSNull(), "canChangeB1": model.b1?.canChange ?? false,
                        "fixtureValues": try [JSONSerialization.jsonObject(with: JSONEncoder().encode(message))]]
                    try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                        .write(to: c.output.appendingPathComponent("context-menu-\(connected ? "connected-" : "")\(state)-\(dark ? "dark" : "light").json"), options: .withoutOverwriting)
                })
        }
        f.service.serverCapabilities[f.key.server] = []
    }

    private static func control(_ title: String, window: NSWindow) throws -> NSObject {
        try XCTUnwrap(ChatTimelineReferenceCapture.accessibilityNodes(window).first { node in
            // AppKit exposes the SwiftUI Menu's native title as "More" on this OS.
            ["accessibilityLabel", "accessibilityTitle", "accessibilityHelp"].contains {
                let value = ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String
                return value == title || (title == "More message actions" && value == "More")
            }
        }, "Production control '\(title)' must be present")
    }

    private static func assertToolbar(_ expected: [String: Bool], absent: [String], window: NSWindow) throws {
        for (title, expectedEnabled) in expected {
            XCTAssertEqual(try enabled(control(title, window: window)), expectedEnabled, title)
        }
        let labels = ChatTimelineReferenceCapture.accessibilityNodes(window).flatMap { node in
            ["accessibilityLabel", "accessibilityTitle"].compactMap { ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String }
        }
        for title in absent { XCTAssertFalse(labels.contains(title), "Unexpected production toolbar control '\(title)'") }
    }

    private static func focus(_ title: String, window: NSWindow) async throws -> NSObject {
        let node = try control(title, window: window)
        guard node.responds(to: NSSelectorFromString("setAccessibilityFocused:")) else {
            throw NSError(domain: "Reference control has no local AX focus setter: " + title, code: 1)
        }
        node.setValue(true, forKey: "accessibilityFocused")
        try await Task.sleep(for: .milliseconds(60))
        let current = try control(title, window: window)
        // The quiet window cannot satisfy every SwiftUI AX focus request. The capture
        // writer records the observed result and an explicit release-session gap.
        XCTAssertTrue(try enabled(current), "The requested production control must be enabled: " + title)
        return current
    }

    private static func frame(_ node: NSObject, host: NSView, window: NSWindow) throws -> CGRect {
        guard node.responds(to: NSSelectorFromString("accessibilityFrame")) else {
            throw NSError(domain: "Reference control has no accessibility frame", code: 1)
        }
        let screen = try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        return host.convert(window.convertFromScreen(screen), from: nil)
    }

    private static func toolbarVariants(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool, connected: Bool) async throws {
        let states = connected ? ["reaction-reply-edit-delete-menu", "reply-delete-only", "edit-disabled"] : ["reaction-disabled", "reply-delete-only", "edit-disabled"]
        for state in states {
            var message = try ChatTimelineReferenceFixture.message("reference-toolbar-\(connected)-" + state, me: f.key.accountId)
            if state == "reply-delete-only" { message.authorAgentId = CallJSON.agent; message.authorAgentName = "Billing agent" }
            let model = ChatTimelineReferenceModel(f, messages: [message])
            if state != "reply-delete-only" { model.b1 = try seedB1(f, message: message, reactions: [], dark: dark) }
            if state == "edit-disabled" {
                let other = try ChatTimelineReferenceFixture.message("reference-toolbar-other-editor", me: f.key.accountId)
                model.editing = .init(messageId: other.id, root: nil, text: other.text, revision: other.revision, message: other)
            }
            XCTAssertEqual(model.canEdit(message), state != "reply-delete-only")
            XCTAssertTrue(model.canDelete(message))
            let expected: [String: Bool] = state == "reply-delete-only"
                ? ["Reply in thread": true, "Delete message…": true, "More message actions": true]
                : ["Add reaction": connected, "Reply in thread": true, "Edit message": state != "edit-disabled", "Delete message…": true, "More message actions": true]
            let absent = state == "reply-delete-only" ? ["Add reaction", "Edit message"] : []
            for width: CGFloat in [760, 420] {
                try await c.capture("toolbar-\(connected ? "connected" : "disconnected")-" + state, inventory: ["R22", "R24"], model: model, messages: [message], width: width, dark: dark,
                    detail: ["activeMessageID": message.id, "toolbarBranch": state, "expectedEnabledControls": expected, "absentControls": absent, "activation": "actual selected production row"],
                    content: c.row(model, message: message, width: width, thread: width == 420, selected: true),
                    prepare: { _, window in try assertToolbar(expected, absent: absent, window: window) })
            }
        }
    }

    private static func replyControlFocus(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let root = try ChatTimelineReferenceFixture.message("reference-reply-control-focus", me: f.key.accountId)
        var reply = try ChatTimelineReferenceFixture.message("reference-reply-control-child", me: CallJSON.boris, seq: 2)
        reply.threadRootId = root.id
        for server in [false, true] {
            let model = ChatTimelineReferenceModel(f, messages: [root, reply])
            model.feed.replySummaries[root.id] = ChatReplySummary(messages: [reply], complete: true)
            if server {
                let b1 = try seedB1(f, message: root, reactions: [], dark: dark)
                let summary = ChatB1.Summary(rootId: root.id, replyCount: 1, lastReplyAt: reply.createdAt, lastReplySeq: reply.seq,
                    lastParticipants: [.init(authorAccountId: CallJSON.boris)])
                let metadata = ChatB1.Metadata(messageId: root.id, deleted: false, reactions: [], pin: nil, threadSummary: summary)
                try await f.store.queue.write { db in
                    try db.execute(sql: "UPDATE b1_metadata SET data = ? WHERE message_id = ?", arguments: [try JSONEncoder().encode(metadata), root.id])
                }
                model.b1 = b1
            } else { model.focusedMessageID = root.id }
            let title = server ? "1 reply, Boris, open thread" : "1 reply, open thread"
            for increased in [false, true] {
                for width: CGFloat in [760, 420] {
                    let name = "\(server ? "server" : "local")-reply-focus-\(increased ? "increased" : "standard")"
                    try await c.capture(name, inventory: ["T21", "R33"], model: model, messages: [root, reply], width: width, dark: dark,
                        detail: ["activeMessageID": root.id, "requiredVisibleText": [title], "focusedControl": title,
                            "focusRoute": server ? "existing local accessibilityFocused setter" : "production focusedMessageID initial observer",
                            "swiftUIColorSchemeContrast": increased ? "increased" : "standard", "workspaceContrastUnmodified": true],
                        content: AnyView(c.row(model, message: root, width: width, thread: false, selected: true)
                            .environment(\._colorSchemeContrast, increased ? .increased : .standard)), prepare: { _, window in
                            if server { _ = try await focus(title, window: window) }
                            else {
                                let node = try control(title, window: window)
                                XCTAssertEqual(node.value(forKey: "accessibilityFocused") as? Bool, true, "Model route must focus the actual local reply button")
                            }
                        })
                }
            }
        }
    }

    private static func toolbarControlFocus(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let message = try ChatTimelineReferenceFixture.message("reference-toolbar-action-focus", me: f.key.accountId)
        let model = ChatTimelineReferenceModel(f, messages: [message])
        model.b1 = try seedB1(f, message: message, reactions: [], dark: dark)
        let expected = ["Add reaction": true, "Reply in thread": true, "Edit message": true, "Delete message…": true, "More message actions": true]
        for increased in [false, true] {
            for width: CGFloat in [760, 420] {
                try await c.capture("toolbar-action-focus-\(increased ? "increased" : "standard")", inventory: ["R10", "R22"], model: model, messages: [message], width: width, dark: dark,
                    detail: ["activeMessageID": message.id, "focusedControl": "Reply in thread", "expectedEnabledControls": expected,
                        "focusRoute": "existing local accessibilityFocused setter", "swiftUIColorSchemeContrast": increased ? "increased" : "standard", "workspaceContrastUnmodified": true],
                    content: AnyView(c.row(model, message: message, width: width, thread: width == 420, selected: true)
                        .environment(\._colorSchemeContrast, increased ? .increased : .standard)), prepare: { _, window in
                        try assertToolbar(expected, absent: [], window: window)
                        _ = try await focus("Reply in thread", window: window)
                    })
            }
        }
    }

    private static func toolbarViewportEdges(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let messages = try (0..<40).map { index in
            try ChatTimelineReferenceFixture.message("reference-toolbar-edge-\(index)", me: f.key.accountId, text: "Viewport edge message \(index).", seq: index + 1)
        }
        for width: CGFloat in [760, 420] {
            let root = width == 420 ? messages[0].id : nil
            let values = messages.enumerated().map { index, value in
                var value = value
                value.threadRootId = index == 0 ? nil : root
                return value
            }
            let target = values[20]
            for edge in ["top", "trailing"] {
                let model = ChatTimelineReferenceModel(f, messages: values)
                model.threadRoot = root
                model.revealMessageID = target.id
                model.b1 = try seedB1(f, message: target, reactions: [], dark: dark)
                try await c.capture("toolbar-viewport-" + edge, inventory: ["R22"], model: model, messages: values, width: width, dark: dark, root: root,
                    detail: ["activeMessageID": target.id, "viewportEdge": edge, "container": "actual production ChatTimelineView clip viewport"],
                    content: c.timeline(model, root: root, width: width), prepare: { host, window in
                        // Complete reveal navigation before staging an independent
                        // viewport position. Keep the selected toolbar via focus.
                        model.focusedMessageID = target.id
                        model.revealMessageID = nil
                        try await Task.sleep(for: .milliseconds(150))
                        let native = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host, NativeChatTimelineContainer.self).first)
                        let viewport = native.coordinator.scrollController, scroll = try XCTUnwrap(viewport.scroll)
                        viewport.stopFollowing()
                        if edge == "top" {
                            _ = try control("Reply in thread", window: window)
                            let body = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host, NSTextView.self).first { $0.string == target.text })
                            let bodyBefore = body.convert(.zero, to: host).y
                            // Release the real viewport's restoration through its input
                            // path, just as the unchanged continuity harness does.
                            let delta = Int32((bodyBefore - 5).rounded())
                            for (amount, phase): (Int32, Int64) in [(delta, 1), (0, 4)] {
                                let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -amount, wheel2: 0, wheel3: 0))
                                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                                cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                                cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                                let center = window.convertPoint(toScreen: NSPoint(x: width / 2, y: 300))
                                cg.location = CGPoint(x: center.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - center.y)
                                APQuietSendEvent(try XCTUnwrap(NSEvent(cgEvent: cg)), window)
                                try await Task.sleep(for: .milliseconds(60))
                            }
                            host.layoutSubtreeIfNeeded()
                            try await Task.sleep(for: .milliseconds(60))
                            let after = try frame(control("Reply in thread", window: window), host: host, window: window)
                            XCTAssertTrue(body.window === window)
                            XCTAssertEqual(body.convert(.zero, to: host).y, 5, accuracy: 0.75, "Native body must reach the staged top edge")
                            XCTAssertTrue(after.intersects(host.bounds), "The actual toolbar control must still intersect the viewport")
                        } else {
                            let more = try frame(control("More message actions", window: window), host: host, window: window)
                            XCTAssertLessThanOrEqual(more.maxX, host.bounds.maxX)
                            XCTAssertGreaterThan(more.maxX, host.bounds.maxX - 40, "Actual trailing control must reach the production viewport edge inset")
                            XCTAssertGreaterThan(more.minX, host.bounds.minX)
                        }
                    })
            }
        }
    }

    private static func enabled(_ node: NSObject) throws -> Bool {
        if let control = node as? NSControl { return control.isEnabled }
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        if node.responds(to: selector), let value = node.perform(selector, with: "AXEnabled")?.takeUnretainedValue() as? NSNumber {
            return value.boolValue
        }
        let getter = NSSelectorFromString("isAccessibilityEnabled")
        guard node.responds(to: getter) else { throw NSError(domain: "Reference AXEnabled unavailable", code: 1) }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: getter), to: Getter.self)(node, getter)
    }

    private static func connectedControls(_ c: ChatTimelineReferenceCapture, dark: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reference-connected-controls-\(UUID())")
        let f = try await ChatChannelExecutionTests.Fixture(root: directory)
        do {
            let me = f.key.accountId, org = f.key.orgId
            let team = "f5000000-0000-4000-8000-000000000004", channel = ChatTimelineReferenceFixture.channel
            let caps = ["auth.email_code", "events.ws", "chat.channels", "chat.reactions", "chat.pins"]
            let info = try JSONSerialization.data(withJSONObject: ["name": "Reference fixture", "version": "0.1.0", "generation": "g1", "api_versions": ["v1"], "capabilities": caps])
            let account = try JSONSerialization.data(withJSONObject: ["account_id": me, "session_id": "s-anna",
                "orgs": [["org_id": org, "org_name": "Reference", "role": "member", "handle": "anna", "name": "Anna"]], "streams": ["account:\(me)": 0]])
            let state: [String: Any] = ["org": ["org_id": org, "name": "Reference"],
                "members": [["account_id": me, "handle": "anna", "name": "Anna", "role": "member"]],
                "teams": [["team_id": team, "name": "Billing", "is_general": false, "archived_at": NSNull(), "members": [me]]],
                "my_teams": [team], "admin": NSNull(), "agents": [], "requests": [], "requests_next": NSNull(),
                "channels": [["channel_id": channel, "team_id": team, "name": "billing", "created_by": me,
                    "created_at": ChatTimelineReferenceFixture.date, "archived": false, "version": 1, "head": 0, "messages": [], "messages_before": NSNull()]],
                "channels_next": NSNull(), "streams": ["org:\(org)": 0, "member:\(org):\(me)": 0, "team:\(team)": 0]]
            let snapshot = try JSONSerialization.data(withJSONObject: state)
            ChatStubProtocol.reset { request, _ in
                switch request.url?.path {
                case "/v1/server": return .success(.init(status: 200, body: info))
                case "/v1/me": return .success(.init(status: 200, body: account))
                case "/v1/orgs/\(org)/state": return .success(.init(status: 200, body: snapshot))
                default: return .failure(URLError(.unsupportedURL))
                }
            }
            let transport = FakeSocketTransport()
            f.service.makeSocketTransport = { transport }
            f.service.followsFeed = true
            try await f.service.start(mode: .server)
            for _ in 0..<200 {
                if transport.request != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(transport.request)
            transport.push(.opened)
            transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
            var answered = 0
            for _ in 0..<200 {
                for streams in transport.subscribes.dropFirst(answered) {
                    for (stream, head) in streams { transport.frame("{\"frame\":\"subscribed\",\"stream\":\"\(stream)\",\"head\":\(head)}") }
                }
                answered = transport.subscribes.count
                if f.service.socket?.state == .connected && ChatNotifications.allowed(f.service, f.key, channel: channel) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(f.service.socket?.state, .connected)
            XCTAssertTrue(ChatNotifications.allowed(f.service, f.key, channel: channel))
            f.service.orgSessions[f.key]?.outbox?.hold()
            try await picker(c, fixture: f, dark: dark, connected: true)
            try await pickerPopup(c, fixture: f, dark: dark)
            try await menus(c, fixture: f, dark: dark, connected: true)
            try await toolbarVariants(c, fixture: f, dark: dark, connected: true)
            try await toolbarControlFocus(c, fixture: f, dark: dark)
            try await toolbarViewportEdges(c, fixture: f, dark: dark)
        } catch {
            f.service.stopFeed(); await f.service.disconnect()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        f.service.stopFeed(); await f.service.disconnect()
        try FileManager.default.removeItem(at: directory)
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
    }

    private static func multilineMembership(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let channel = ChatTimelineReferenceFixture.channel
        try f.write("DELETE FROM agent_channels")
        try f.write("UPDATE meta SET agents_served = 1")
        try f.write("UPDATE channels SET archived = 0 WHERE channel_id = ?", [channel])
        try f.write("INSERT OR REPLACE INTO agents_catalog (agent_id, owner_account_id, name, description, access, enabled, available) VALUES (?, ?, 'billing', '', 'read', 1, 1)",
            [CallJSON.agent, CallJSON.boris])
        ChatOrgCurrent.shared.refresh(f.service)
        let model = ChatChannelModel(key: f.key, channel: channel); model.service = f.service; model.follow(f.store)
        let m = try ChatTimelineReferenceFixture.message("reference-membership-multiline", me: f.key.accountId, text: "@billing@boris Please check this question.")
        XCTAssertEqual(f.service.state, .signedIn)
        try ChatTimelineReferenceCapture.prepareOrganization(f.service)
        let org = try XCTUnwrap(ChatOrgCurrent.shared.model)
        let mentions = org.missingAgentMentions(in: m.text, channel: channel, catalog: try f.store.calls.catalog())
        XCTAssertEqual(mentions.count, 1)
        XCTAssertEqual(mentions.first?.guidance, "Ask its owner to add it before requesting an answer.")
        try await c.capture("membership-multiline", inventory: ["R42"], model: model, messages: [m], width: 260, dark: dark,
            detail: ["guidance": mentions.map(\.guidance), "canAdd": mentions.map(\.canAdd), "requiredVisibleText": ["Ask its owner to add it before requesting an answer."]],
            content: c.row(model, message: m, width: 260, thread: false))
        try f.write("INSERT OR REPLACE INTO agent_channels (channel_id, agent_id, name, owner_account_id, access, enabled, available) VALUES (?, ?, 'billing', ?, 'read', 1, 1)",
            [channel, CallJSON.agent, f.key.accountId])
        try f.write("UPDATE agents_catalog SET owner_account_id = ? WHERE agent_id = ?", [f.key.accountId, CallJSON.agent])
        ChatOrgCurrent.shared.refresh(f.service)
    }
}
