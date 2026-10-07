import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatPinsTests: XCTestCase {
    private var directory: URL!
    private var scope: TeamServiceTestScope!
    private let key = ChatOrgKey(server: try! ChatServerAddress(parsing: "https://pins.example.com"), accountId: "me", orgId: "org")
    private let members: [ChatOrgView.Member] = [
        .init(accountId: "me", handle: "alex", name: "Alex", role: "member"),
        .init(accountId: "other", handle: "marina", name: "Marina", role: "member")
    ]

    override func setUp() async throws {
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(UUID())")
    }
    override func tearDown() async throws { scope.close(); try? FileManager.default.removeItem(at: directory) }

    private func write<T>(_ store: ChatStore, _ body: (Database) throws -> T) throws -> T { try store.queue.write(body) }

    private func pin(_ id: String, seq: Int, agent: Bool = false, root: String? = nil) -> ChatB1.PinnedMessage {
        .init(messageId: id, seq: seq, threadRootId: root, authorAccountId: agent ? "other" : "me",
              authorAgentId: agent ? "bot" : nil, authorAgentName: agent ? "Reviewer" : nil,
              excerpt: "A short preview", pinnedBy: "me", pinnedAt: "2026-10-07T10:0\(seq):00Z")
    }
    private func store(key requested: ChatOrgKey? = nil) throws -> ChatStore {
        let s = try ChatStore.open(files: ChatFiles(directory: directory), key: requested ?? key).store
        try s.apply(.init(cursors: ["channel:c": 10, "member:org:me": 4], members: [], teams: [.init(teamId: "t", name: "Team")],
                          channels: [.init(channelId: "c", teamId: "t", name: "planning", archived: false, version: 1, head: 10, messages: [])]), confirmsRights: "session")
        try s.setGeneration("g1")
        return s
    }
    private func message(_ id: String, seq: Int, text: String, store: ChatStore, root: String? = nil) throws -> ChatMessage {
        let json: [String: Any] = ["message_id": id, "channel_id": "c", "seq": seq, "thread_root_id": root as Any? ?? NSNull(),
                                  "author_account_id": "me", "text": text, "mentions": [], "revision": 1, "created_at": "2026-10-07T10:00:00Z"]
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: json))
        return try store.queue.write { db in
            try ChatMessages.write(db, wire)
            return try XCTUnwrap(Row.fetchOne(db, sql: "\(ChatMessages.select) WHERE m.message_id = ?", arguments: [id])).mapMessage()
        }
    }
    private func seed(_ pins: [ChatB1.PinnedMessage], in store: ChatStore) throws {
        try store.queue.write { try $0.execute(sql: "INSERT OR REPLACE INTO b1_pins (channel_id, data) VALUES ('c', ?)", arguments: [try ChatB1.encode(pins)]) }
    }
    private func service() -> ChatService {
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        service.serverCapabilities[key.server] = ChatB1.capabilities
        return service
    }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    func testNewestPinComesFirst() {
        XCTAssertEqual(ChatPins.ordered([pin("old", seq: 1), pin("new", seq: 2)]).map(\.id), ["new", "old"])
    }

    func testBannerCyclesWithValidSelection() {
        let old = pin("old", seq: 1), new = pin("new", seq: 2)
        let pins = [new, old]
        let state = ChatPinsPresentation()
        XCTAssertEqual(state.current(in: pins)?.id, "new")
        state.advance(in: pins); XCTAssertEqual(state.current(in: pins)?.id, "old")
        state.advance(in: pins); XCTAssertEqual(state.current(in: pins)?.id, "new")
        state.advance(in: pins)
        let newest = pin("newest", seq: 3)
        state.reconcile(old: pins, new: [newest] + pins)
        XCTAssertEqual(state.current(in: [newest] + pins)?.id, "newest")
        state.reconcile(old: pins, new: [old]); XCTAssertEqual(state.current(in: [old])?.id, "old")
        state.reconcile(old: [old], new: pins); XCTAssertEqual(state.current(in: pins)?.id, "new")
        state.reconcile(old: pins, new: []); state.advance(in: [])
        XCTAssertNil(state.current(in: [])); XCTAssertNil(state.selectedID)
    }

    func testPaneExpansionAndThreadJumpPreserveSearchAndReturn() {
        let state = ChatPinsPresentation()
        state.query = "decision"; state.filter = .agents
        state.open()
        XCTAssertFalse(state.coversConversation(width: 1100))
        XCTAssertTrue(state.coversConversation(width: 700))
        state.expanded = true
        XCTAssertTrue(state.coversConversation(width: 1100))
        state.prepareJump(pin("p", seq: 1), width: 1100)
        XCTAssertFalse(state.isPresented); XCTAssertTrue(state.returnsToPins)
        state.open(); XCTAssertFalse(state.returnsToPins)
        XCTAssertEqual(state.query, "decision"); XCTAssertEqual(state.filter, .agents)
        state.expanded = false
        state.prepareJump(pin("reply", seq: 2, root: "root"), width: 1100)
        XCTAssertFalse(state.isPresented); XCTAssertTrue(state.returnsToPins)
        state.open(); state.prepareJump(pin("p", seq: 1), width: 1100)
        XCTAssertTrue(state.isPresented, "a wide side panel stays beside a channel target")
        state.close(); XCTAssertFalse(state.returnsToPins)
    }

    func testSearchIncludesFullTextAndAuthorsWithEveryWordAndAgentFilter() throws {
        let s = try store()
        let body = try message("bot", seq: 2, text: "## Résumé\n\n" + String(repeating: "Long text. ", count: 80) + "needle", store: s)
        let pins = [pin("person", seq: 1), pin("bot", seq: 2, agent: true)]
        func found(_ query: String, _ filter: ChatPinFilter = .all) -> [String] {
            ChatPins.matching(pins, messages: ["bot": body], members: members, query: query, filter: filter).map(\.id)
        }
        XCTAssertEqual(found("  NEEDLE reviewer résumé "), ["bot"])
        XCTAssertEqual(found("preview Alex", .people), ["person"])
        XCTAssertEqual(found("", .agents), ["bot"])
        XCTAssertEqual(found("", .people), ["person"])
        XCTAssertTrue(found("needle absent").isEmpty)
        var session = pin("session", seq: 3); session.authorSessionName = "Terminal agent"
        XCTAssertTrue(ChatPins.isAgent(session))
        var deleted = body; deleted.deletedAt = "now"
        XCTAssertTrue(ChatPins.matching([pins[1]], messages: ["bot": deleted], members: members, query: "needle", filter: .all).isEmpty)
    }

    func testMissingBodiesUseNewestRevisionAndSkipCompleteOrDeletedMessages() throws {
        let s = try store(), pins = [pin("missing", seq: 1), pin("stale", seq: 2), pin("ready", seq: 3), pin("gone", seq: 4)]
        var stale = try message("stale", seq: 2, text: "old", store: s); stale.stale = 7
        let ready = try message("ready", seq: 3, text: "whole", store: s)
        var gone = try message("gone", seq: 4, text: "", store: s); gone.deletedAt = "now"
        XCTAssertEqual(ChatPins.missing(pins, messages: ["stale": stale, "ready": ready, "gone": gone]),
                       [.init(id: "missing", sequence: 1, revision: 1), .init(id: "stale", sequence: 2, revision: 7)])
    }

    func testBannerPreferenceSurvivesReopenAndIsScopedToChannelAndOrganization() throws {
        let s = try store()
        try write(s) { try ChatPins.setBannerHidden($0, channel: "c", hidden: true) }
        let reopened = try ChatStore.open(files: ChatFiles(directory: directory), key: key).store
        XCTAssertTrue(try reopened.queue.read { try ChatPins.bannerHidden($0, channel: "c") })
        XCTAssertFalse(try reopened.queue.read { try ChatPins.bannerHidden($0, channel: "other") })
        for other in [ChatOrgKey(server: key.server, accountId: "another", orgId: key.orgId),
                      ChatOrgKey(server: key.server, accountId: key.accountId, orgId: "another"),
                      ChatOrgKey(server: try ChatServerAddress(parsing: "https://another.example.com"), accountId: key.accountId, orgId: key.orgId)] {
            let isolated = try store(key: other)
            XCTAssertFalse(try isolated.queue.read { try ChatPins.bannerHidden($0, channel: "c") })
        }
        try reopened.queue.write { try ChatPins.setBannerHidden($0, channel: "c", hidden: false) }
        XCTAssertFalse(try s.queue.read { try ChatPins.bannerHidden($0, channel: "c") })
    }

    func testB1ObservesFullTextEditsPreferencesAndMasksContentOnAccessLoss() async throws {
        let s = try store()
        _ = try message("p", seq: 1, text: "complete **body**", store: s)
        try seed([pin("p", seq: 1)], in: s)
        let service = service()
        let first = ChatB1Channel(key: key, channel: "c", store: s, service: service)
        let second = ChatB1Channel(key: key, channel: "c", store: s, service: service)
        XCTAssertEqual(first.state.pinMessages["p"]?.text, "complete **body**")
        first.setBannerHidden(true)
        try await settle { second.state.bannerHidden }
        try write(s) { try $0.execute(sql: "UPDATE messages SET text = 'edited body', revision = 2 WHERE message_id = 'p'") }
        try await settle { first.state.pinMessages["p"]?.text == "edited body" }
        let session = service.session(for: key)
        XCTAssertNil(first.state.pins, "a snapshot owed masks cached text synchronously")
        XCTAssertTrue(first.state.pinMessages.isEmpty)
        session.snapshotOwed = false; session.doubtNotWritten = true
        XCTAssertNil(first.state.pins, "a failed rights write also masks cached text synchronously")
        XCTAssertTrue(first.state.pinMessages.isEmpty)
        session.doubtNotWritten = false
        try write(s) { try $0.execute(sql: "UPDATE meta SET rights_in_doubt = 1") }
        try await settle { !first.state.accessible }
        XCTAssertTrue(first.state.pinMessages.isEmpty); XCTAssertNil(first.state.pins)
    }

    func testPinPanelPreservesNativeThreadEditorAndDraft() async throws {
        let s = try store(), service = service()
        _ = try message("root", seq: 1, text: "**Topic**\n\nFinal detail", store: s)
        let reply = try message("reply", seq: 2, text: "Original reply", store: s, root: "root")
        try seed([pin("root", seq: 1)], in: s)
        let card = ChatChannelCard(channelId: "c", teamId: "t", name: "planning", archived: false, version: 1)
        let conversation = ChatChannelSession()
        conversation.update(.ready(card, team: "Product", offline: true), key: key, store: s, service: service)
        let model = try XCTUnwrap(conversation.model)
        model.openThread("root")
        let host = NSHostingView(rootView: ChatChannelView(card: card, team: "Product", offline: true, key: key, conversation: conversation)
            .frame(width: 700, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func editors(_ view: NSView) -> [ChatMentionEditor.Editor] {
            (view as? ChatMentionEditor.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.beginEditing(reply, root: "root"))
        model.editing?.text = "Unsaved thread revision"
        try await settle { editors(host).contains { $0.string == "Unsaved thread revision" } }
        model.pins.open()
        try await settle { editors(host).isEmpty }
        func markdown(_ view: NSView) -> [ChatMentionText.MessageTextView] {
            (view as? ChatMentionText.MessageTextView).map { [$0] } ?? view.subviews.flatMap(markdown)
        }
        let pinnedText = try XCTUnwrap(markdown(host).first { $0.string.contains("Final detail") })
        XCTAssertEqual(pinnedText.string, "Topic\nFinal detail", "the complete Markdown is selectable native text")
        let headingFont = try XCTUnwrap(pinnedText.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: headingFont).contains(.boldFontMask))
        XCTAssertEqual(model.threadRoot, "root")
        XCTAssertEqual(model.editing?.text, "Unsaved thread revision")
        model.pins.close()
        try await settle { editors(host).contains { $0.string == "Unsaved thread revision" } }
        XCTAssertEqual(model.threadRoot, "root")
        model.pins.open()
        try await settle { editors(host).isEmpty }
        ChatMessageNavigation.request(ChatMessageLink(key: key, channel: "c", message: "root", sequence: 1), key: key, destination: host)
        try await settle { !model.pins.isPresented && model.revealMessageID == "root" }
    }

    func testMentionClosesNarrowPinsAndRestoresChannelComposer() async throws {
        try await checkMentionWithPins(width: 700, expanded: false)
    }

    func testMentionClosesExpandedPinsAndRestoresChannelComposer() async throws {
        try await checkMentionWithPins(width: 1100, expanded: true)
    }

    private func checkMentionWithPins(width: CGFloat, expanded: Bool) async throws {
        let s = try store(), service = service()
        _ = try message("root", seq: 1, text: "Pinned topic", store: s)
        try seed([pin("root", seq: 1)], in: s)
        let card = ChatChannelCard(channelId: "c", teamId: "t", name: "planning", archived: false, version: 1)
        let conversation = ChatChannelSession()
        conversation.update(.ready(card, team: "Team", offline: true), key: key, store: s, service: service)
        let model = try XCTUnwrap(conversation.model)
        model.saveDraft("channel draft", root: nil, mentionOnly: true)
        model.saveDraft("thread draft", root: "root")
        model.openThread("root")
        model.pins.query = "topic"; model.pins.filter = .people
        model.pins.expanded = expanded; model.pins.open()
        let org = ChatOrgModel(me: "me") { _, _ in XCTFail("Mention must not send anything"); return "unexpected" }
        org.key = key
        org.set(ChatOrgView(orgName: "Test", teams: [.init(teamId: "t", name: "Team", isGeneral: true, archived: false, mine: true, members: ["me"])],
            channels: [card], channelsServed: true,
            channelAgents: [.init(channelId: "c", agentId: "agent", name: "reviewer", ownerAccountId: "me", ownerHandle: "me",
                                  description: "", access: "read", enabled: true, available: true)], agentsServed: true))
        let host = NSHostingView(rootView: ChatChannelView(card: card, team: "Team", offline: true, key: key, conversation: conversation)
            .frame(width: width, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func editors(_ view: NSView) -> [ChatMentionEditor.Editor] {
            (view as? ChatMentionEditor.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.pins.coversConversation(width: width))
        XCTAssertTrue(editors(host).isEmpty)
        XCTAssertTrue(ChatSidebarMention.request(agentID: "agent", ref: ChannelRef(key, channel: "c"), window: window,
            destination: host, model: org, isActive: { true }, openChannel: { conversation.showChannelComposer() }))
        XCTAssertFalse(model.pins.isPresented, "Mention must reveal the editor without a manual close")
        XCTAssertNil(model.threadRoot)
        try await settle { editors(host).contains { $0.string == "channel draft @reviewer@me " } }
        let editor = try XCTUnwrap(editors(host).first { $0.navigationTarget == ChannelRef(key, channel: "c") })
        XCTAssertTrue(window.firstResponder === editor)
        ChatSidebarMention.editorReady(editor)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.draft(root: nil), "channel draft @reviewer@me ", "only one insertion")
        XCTAssertTrue(model.composerDraft(root: nil).mentionOnly)
        XCTAssertEqual(model.draft(root: "root"), "thread draft")
        XCTAssertEqual(model.pins.query, "topic"); XCTAssertEqual(model.pins.filter, .people)
        XCTAssertTrue(try s.outbox.commands().isEmpty)
    }

    func testNativeR115Snapshots() async throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTPAD_R115_CAPTURE"] else { throw XCTSkip("Native screenshots are opt-in") }
        _ = NSApplication.shared
        let service = service()
        try service.saveSignIn(.init(server: key.server, accountId: key.accountId, sessionId: "session", deviceName: "Fixture", orgId: key.orgId), token: "fixture")
        service.session(for: key).snapshotOwed = false
        let s = try store()
        try write(s) { db in
            for member in members {
                try db.execute(sql: "INSERT OR REPLACE INTO members (account_id, handle, name, role) VALUES (?, ?, ?, ?)",
                               arguments: [member.accountId, member.handle, member.name, member.role])
            }
        }
        let text = """
        ## Review summary

        The release is ready for a final review. **All checks passed**, including channel navigation and draft restoration.

        - [x] Keep the conversation draft
        - [x] Open the original thread
        - [x] Read the complete pinned message

        | Check | Result |
        | --- | --- |
        | Navigation | Passed |
        | Drafts | Preserved |

        ```swift
        let decision = review.accepted
        publish(decision)
        ```

        > Keep important decisions easy to find.

        Next: discuss the final wording and collect feedback from the team.
        """
        _ = try message("review", seq: 2, text: text, store: s)
        _ = try message("agenda", seq: 3, text: "## Team sync\n\n1. Review the pinned decisions\n2. Check channel navigation\n3. Agree on the release checklist", store: s)
        _ = try message("latest", seq: 4, text: "The review and agenda are pinned. Let's keep the next steps here.", store: s)
        var review = pin("review", seq: 2, agent: true)
        review.excerpt = "Review summary · All checks passed, including channel navigation and draft restoration."
        var agenda = pin("agenda", seq: 3)
        agenda.excerpt = "Team sync · Review pinned decisions, check navigation, agree on the checklist."
        try seed([review, agenda], in: s)
        try write(s) { db in
            try db.execute(sql: "UPDATE channel_windows SET bottom_seq = 1, history_next = NULL WHERE channel_id = 'c'")
            try db.execute(sql: "UPDATE messages SET author_account_id = 'other', author_agent_id = 'bot', author_agent_name = 'Reviewer' WHERE message_id = 'review'")
            for id in ["review", "agenda", "latest"] {
                let pin = ["review", "agenda"].contains(id) ? ChatB1.Pin(pinnedBy: "me", pinnedAt: "2026-10-07T10:00:00Z") : nil
                let metadata = ChatB1.Metadata(messageId: id, deleted: false, reactions: [], pin: pin)
                try db.execute(sql: "INSERT INTO b1_metadata (channel_id, message_id, data) VALUES ('c', ?, ?)", arguments: [id, try ChatB1.encode(metadata)])
            }
        }
        ChatOrgCurrent.shared.refresh(service)
        defer { service.stopFeed(); ChatOrgCurrent.shared.refresh() }
        let card = ChatChannelCard(channelId: "c", teamId: "t", name: "planning", archived: false, version: 1)
        let conversation = ChatChannelSession()
        conversation.update(.ready(card, team: "Product", offline: true), key: key, store: s, service: service)
        let model = try XCTUnwrap(conversation.model)
        let settings = AgentPadSettingsModel.shared
        let prior = (settings.appearanceMode, settings.lightTerminalThemeSelection, settings.darkTerminalThemeSelection)
        defer { settings.appearanceMode = prior.0; settings.lightTerminalThemeSelection = prior.1; settings.darkTerminalThemeSelection = prior.2 }
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        settings.darkTerminalThemeSelection = AgentPadSettingsModel.defaultDarkThemeSelection
        for dark in [false, true] {
            settings.appearanceMode = dark ? .dark : .light
            model.pins.close()
            let content = ChatChannelView(card: card, team: "Product", offline: true, key: key, conversation: conversation)
            try await capture(content, output: output, name: "banner-\(dark ? "dark" : "light")", size: NSSize(width: 1040, height: 720), dark: dark)
            model.pins.open()
            try await capture(content, output: output, name: "pins-\(dark ? "dark" : "light")", size: NSSize(width: 1180, height: 820), dark: dark)
        }
        settings.appearanceMode = .dark
        model.pins.open(); model.pins.expanded = true; model.pins.filter = .agents
        let content = ChatChannelView(card: card, team: "Product", offline: true, key: key, conversation: conversation)
        try await capture(content, output: output, name: "pins-expanded", size: NSSize(width: 1000, height: 860), dark: true)
        model.pins.expanded = false
        try await capture(content, output: output, name: "pins-narrow", size: NSSize(width: 640, height: 860), dark: true)
        model.pins.query = "publish"
        try await capture(content, output: output, name: "pins-search", size: NSSize(width: 1000, height: 860), dark: true)
        model.pins.query = ""; model.pins.close()
        let b1 = try XCTUnwrap(model.b1)
        b1.setBannerHidden(true)
        try await settle { b1.state.bannerHidden }
        try await capture(content, output: output, name: "banner-hidden", size: NSSize(width: 1040, height: 720), dark: true)

        let org = ChatOrgModel(me: "me") { _, _ in XCTFail("Snapshots do not send commands"); return "none" }
        org.key = key
        org.set(ChatOrgView(orgName: "Product", members: members,
            teams: [.init(teamId: "t", name: "Product", isGeneral: true, archived: false, mine: true, members: ["me", "other"])],
            channels: [card], channelsServed: true,
            channelAgents: [.init(channelId: "c", agentId: "writer", name: "writer", ownerAccountId: "me", ownerHandle: "alex",
                                 description: "Reviews and edits project files.", access: "edit-files", enabled: true, available: true),
                            .init(channelId: "c", agentId: "reviewer", name: "reviewer", ownerAccountId: "other", ownerHandle: "marina",
                                  description: "Reviews changes and explains decisions.", access: "read", enabled: true, available: true)], agentsServed: true))
        let workspace = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() }, optionsProvider: { _ in nil }, resumeProvider: { true })
        defer { workspace.terminate() }
        for id in ["writer", "reviewer"] {
            let card = ChatSidebarAgentCard(agentID: id, active: ChannelRef(key, channel: "c"), window: nil, store: workspace, model: org, close: {})
            try await capture(card, output: output, name: "agent-\(id)", size: NSSize(width: 352, height: 410), dark: true)
        }
    }

    private func capture(_ content: some View, output: String, name: String, size: NSSize, dark: Bool) async throws {
        let host = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let url = URL(fileURLWithPath: output).appendingPathComponent("r115-merge-\(name).png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

private extension Row {
    func mapMessage() -> ChatMessage { ChatMessage(row: self) }
}
