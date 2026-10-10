import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatSidebarTests: XCTestCase {
    private var teamScope: TeamServiceTestScope!
    private let key = ChatOrgKey(server: try! ChatServerAddress(parsing: "https://chat.example.com"), accountId: "me", orgId: "org")

    override func setUp() async throws { teamScope = TeamServiceTestScope() }
    override func tearDown() async throws { teamScope.close(); teamScope = nil }

    private func team(_ id: String, mine: Bool = true, archived: Bool = false) -> ChatOrgView.Team {
        .init(teamId: id, name: id, isGeneral: id == "General", archived: archived, mine: mine, members: ["me"])
    }
    private func channel(_ id: String, team: String = "General", name: String? = nil, archived: Bool = false) -> ChatChannelCard {
        .init(channelId: id, teamId: team, name: name ?? id, createdBy: "me", archived: archived, version: 1)
    }
    private func agent(_ id: String, channel: String, name: String = "reviewer", owner: String = "me") -> ChatChannelAgent {
        .init(channelId: channel, agentId: id, name: name, ownerAccountId: owner, ownerHandle: owner,
              description: "Reviews changes", access: "read", enabled: true, available: true)
    }
    private func model() -> ChatOrgModel {
        let model = ChatOrgModel(me: "me") { _, _ in XCTFail("Navigation must not send commands"); return "unexpected" }
        model.key = key
        model.set(ChatOrgView(orgName: "Example",
            members: [.init(accountId: "me", handle: "me", name: "Owner", role: "member")],
            teams: [team("General"), team("Archive", archived: true), team("Hidden", mine: false)],
            channels: [channel("one", name: "AgentPad Change \\ Support"), channel("two"),
                       channel("old", team: "Archive", archived: true), channel("hidden", team: "Hidden")],
            channelsServed: true,
            unread: ["one": .init(count: 3, more: true), "two": .init(something: true), "hidden": .init(count: 100)],
            mentionsUnread: 1, mentionsByChannel: ["one": 1, "hidden": 99],
            channelAgents: [agent("a1", channel: "one"), agent("a1", channel: "two"),
                            agent("a2", channel: "one"), agent("hidden-agent", channel: "hidden")],
            myAgents: [.init(agentId: "own", ownerAccountId: "me", name: "writer", description: "", access: "read",
                             enabled: true, available: false)], agentsServed: true))
        return model
    }
    private func snapshot(_ model: ChatOrgModel, active: String = "one") -> ChatSidebarSnapshot {
        ChatSidebarSnapshot(model: model, active: ChannelRef(key, channel: active))
    }

    func testTeamBoundariesAndLiteralBackslashNames() {
        let view = snapshot(model())
        XCTAssertEqual(view.teams.map(\.id), ["General", "Archive"])
        XCTAssertEqual(view.teams.map { $0.channels.map(\.id) }, [["one", "two"], ["old"]])
        XCTAssertEqual(view.teams[0].channels[0].card.name, "AgentPad Change \\ Support")
        XCTAssertTrue(view.teams[1].channels[0].card.archived)
        XCTAssertEqual(view.unread.count, 3, "hidden counts never enter navigation")
        XCTAssertEqual(view.mentions, 1, "mentions and messages are not added together")
        XCTAssertTrue(view.incomplete)
        XCTAssertEqual(view.teams[0].channels[0].mentionLabel, "@1+")
    }

    func testFiltersKeepOnlyKnownAccessibleMatchesAndEmptyTeams() {
        let view = snapshot(model())
        XCTAssertEqual(view.filteredTeams(query: " SUPPORT ", filter: .all).flatMap(\.channels).map(\.id), ["one"])
        XCTAssertEqual(view.filteredTeams(query: "general", filter: .all).flatMap(\.channels).map(\.id), ["one", "two"])
        XCTAssertTrue(view.filteredTeams(query: "Hidden", filter: .all).isEmpty)
        XCTAssertEqual(view.filteredTeams(query: "", filter: .unread).flatMap(\.channels).map(\.id), ["one", "two"])
        XCTAssertEqual(view.filteredTeams(query: "", filter: .mentions).flatMap(\.channels).map(\.id), ["one"])
        XCTAssertTrue(view.filteredAgents(query: "", filter: .unread).isEmpty)
        XCTAssertEqual(view.filteredAgents(query: "VIEW", filter: .all).map(\.id), ["a1", "a2"])
        XCTAssertTrue(view.filteredTeams(query: "absent", filter: .all).isEmpty)
    }

    func testAgentsGroupByIDNotNameAndCurrentChannelUsesWholeScope() {
        let model = model()
        let view = snapshot(model)
        XCTAssertEqual(view.agents.map(\.id), ["a1", "a2", "own"])
        XCTAssertEqual(view.agents[0].channels, ["one", "two"])
        XCTAssertTrue(view.agents[0].inCurrentChannel)
        XCTAssertEqual(view.agents[0].owner, "Owner")
        var another = ChannelRef(key, channel: "one"); another.account = "other"
        XCTAssertFalse(ChatSidebarSnapshot(model: model, active: another).agents.contains { $0.inCurrentChannel })
        var changed = model.view; changed.agentsServed = false; model.set(changed)
        XCTAssertTrue(snapshot(model).agents.isEmpty)
    }

    func testStatePrecedenceAndNoCachedResultsAcrossTheF2Gate() {
        let model = model()
        XCTAssertEqual(snapshot(model).state, .ready(offline: false))
        let ref = ChannelRef(key, channel: "one")
        guard case .ready(_, _, false) = ChannelTabState.of(ref, model: model) else { return XCTFail("channel should share the grace period") }
        model.showsOffline = { true }
        XCTAssertEqual(snapshot(model).state, .ready(offline: true))
        guard case .ready(_, _, true) = ChannelTabState.of(ref, model: model) else { return XCTFail("channel should show the persistent outage") }
        model.snapshotOwed = { true }
        XCTAssertEqual(snapshot(model).state, .checking)
        assertHidden(snapshot(model))
        model.snapshotOwed = { false }
        var view = model.view; view.rightsInDoubt = true; model.set(view)
        assertHidden(snapshot(model))
        view.rightsInDoubt = false; model.set(view)
        model.storageProblem = { true }
        assertHidden(snapshot(model))
        model.storageProblem = { false }
        view.channelsServed = false; model.set(view)
        XCTAssertEqual(snapshot(model).state, .noChannels)
        model.isCurrent = { false }
        XCTAssertEqual(snapshot(model).state, .notConnected)
        assertHidden(snapshot(model))
        XCTAssertEqual(ChatSidebarSnapshot(model: nil, active: nil).state, .notConnected)
    }

    func testRevokedTeamClearsSearchAgentsAndBadgesImmediately() {
        let model = model()
        var view = model.view
        view.teams[0].mine = false
        view.myAgents = []
        model.set(view)
        let after = snapshot(model)
        XCTAssertEqual(after.teams.map(\.id), ["Archive"])
        XCTAssertTrue(after.filteredTeams(query: "Support", filter: .all).isEmpty)
        XCTAssertTrue(after.agents.isEmpty)
        XCTAssertEqual(after.mentions, 0)
        XCTAssertEqual(after.unread.count, 0)
    }

    private func assertHidden(_ snapshot: ChatSidebarSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(snapshot.teams.isEmpty, file: file, line: line)
        XCTAssertTrue(snapshot.agents.isEmpty, file: file, line: line)
        XCTAssertEqual(snapshot.mentions, 0, file: file, line: line)
        XCTAssertNil(ChatSidebarSnapshot.unreadLabel(snapshot.unread), file: file, line: line)
    }

    func testF4BadgeStatesAndFollowedChannels() {
        XCTAssertNil(ChatSidebarSnapshot.unreadLabel(.init()))
        XCTAssertEqual(ChatSidebarSnapshot.unreadLabel(.init(count: 4)), "4")
        XCTAssertEqual(ChatSidebarSnapshot.unreadLabel(.init(count: 4, more: true)), "4+")
        XCTAssertEqual(ChatSidebarSnapshot.unreadLabel(.init(more: true)), "•")
        XCTAssertEqual(ChatSidebarSnapshot.unreadLabel(.init(something: true)), "•")
        let model = model(); model.isFollowed = { $0 == "two" }
        XCTAssertFalse(snapshot(model).teams[0].channels[1].isUnread)
        var view = model.view; view.unread["one"]?.muted = true; model.set(view)
        XCTAssertTrue(snapshot(model).teams[0].channels[0].isUnread, "mute silences thread replies, not mentions or unread")
    }

    func testKeyboardSelectionExpansionAndActivationAreSeparate() {
        typealias R = ChatSidebarKeyboard.Row
        let rows: [R] = [.init(id: .team("t"), expanded: true), .init(id: .channel("a"), parent: .team("t")),
                         .init(id: .channel("b"), parent: .team("t")), .init(id: .agents, expanded: false)]
        XCTAssertEqual(ChatSidebarKeyboard.route(.down, selection: nil, rows: rows), .select(.team("t")))
        XCTAssertEqual(ChatSidebarKeyboard.route(.up, selection: nil, rows: rows), .select(.agents))
        XCTAssertEqual(ChatSidebarKeyboard.route(.down, selection: .channel("a"), rows: rows), .select(.channel("b")))
        XCTAssertEqual(ChatSidebarKeyboard.route(.enter, selection: .channel("a"), rows: rows), .activate(.channel("a")))
        XCTAssertEqual(ChatSidebarKeyboard.route(.left, selection: .channel("b"), rows: rows), .select(.team("t")))
        XCTAssertEqual(ChatSidebarKeyboard.route(.left, selection: .team("t"), rows: rows), .expand(.team("t"), false))
        XCTAssertEqual(ChatSidebarKeyboard.route(.right, selection: .team("t"), rows: rows), .select(.channel("a")))
        XCTAssertEqual(ChatSidebarKeyboard.route(.right, selection: .agents, rows: rows), .expand(.agents, true))
        XCTAssertEqual(ChatSidebarKeyboard.route(.enter, selection: .agents, rows: rows), .expand(.agents, true))
        XCTAssertEqual(ChatSidebarKeyboard.route(.down, selection: .agents, rows: rows), .select(.agents))
        XCTAssertEqual(ChatSidebarKeyboard.route(.enter, selection: .channel("removed"), rows: rows), .select(.team("t")))
        XCTAssertEqual(ChatSidebarKeyboard.route(.down, selection: nil, rows: []), .none)
    }

    func testChangingContextAndLosingAccessClearTransientNames() {
        let navigation = ChatSidebarNavigation()
        navigation.adopt("first")
        navigation.query = "Support"; navigation.filter = .mentions; navigation.agentID = "a1"
        navigation.toOpen.insert(ChannelRef(key, channel: "pending"))
        navigation.adopt("first")
        XCTAssertEqual(navigation.query, "Support")
        navigation.hideRestrictedContent()
        XCTAssertEqual(navigation.query, "")
        XCTAssertNil(navigation.agentID)
        XCTAssertEqual(navigation.toOpen.count, 1, "snapshot delay does not lose a create awaiting its card")
        navigation.adopt("another-session")
        XCTAssertEqual(navigation.filter, .all)
        XCTAssertTrue(navigation.toOpen.isEmpty)
    }

    func testWindowModesWidthsAndSectionsRestoreWithoutChangingTabs() throws {
        let persistence = InMemoryPersistence()
        let store = makeStore(persistence)
        defer { store.terminate() }
        let tabs = store.active?.root.allPanes.flatMap(\.tabs).map(\.id)
        store.sidebarWidth = 400
        store.setSidebarMode(.compact)
        store.setSidebarContent(.chat)
        XCTAssertEqual(store.sidebarMode, .full)
        XCTAssertEqual(store.sidebarDisplayWidth, 268)
        store.setSidebarDisplayWidth(299.5)
        store.setChatSectionCollapsed(.init(key, team: "General"), true)
        store.chatNavigation.query = "private search"
        store.flushPersistence()
        let data = try JSONEncoder().encode(XCTUnwrap(persistence.saved))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private search"))
        let restored = makeStore(InMemoryPersistence(initial: try JSONDecoder().decode(PersistedState.self, from: data)))
        defer { restored.terminate() }
        XCTAssertEqual(restored.sidebarContent, .chat)
        XCTAssertEqual(restored.sidebarDisplayWidth, 300)
        XCTAssertEqual(restored.chatSidebarPreferences.collapsed, [.init(key, team: "General")])
        XCTAssertEqual(restored.chatNavigation.query, "")
        store.setSidebarContent(.team)
        XCTAssertEqual(store.sidebarDisplayWidth, 400)
        store.flushPersistence()
        XCTAssertEqual(persistence.saved?.sidebarSelectedContent, "team")
        XCTAssertEqual(store.active?.root.allPanes.flatMap(\.tabs).map(\.id), tabs)
        XCTAssertEqual(restored.sidebarContent, .chat, "another window keeps its selection")
        store.setSidebarContent(.chat)
        XCTAssertEqual(store.sidebarDisplayWidth, 300)
    }

    func testRollbackReadsLegacyModeAndPreservesTabs() throws {
        // Shape of the old client: unknown extra fields are ignored, its
        // sidebarContent is deliberately the old enum with only two cases.
        struct OldWindow: Decodable {
            enum Content: String, Decodable { case files, workspaces }
            var sidebarContent: Content?
            var workspaces: [PersistedWorkspace]
        }
        let persistence = InMemoryPersistence()
        let store = makeStore(persistence)
        defer { store.terminate() }
        for content in [SidebarContent.workspaces, .files, .team, .chat] {
            store.setSidebarContent(content); store.flushPersistence()
            let data = try JSONEncoder().encode(XCTUnwrap(persistence.saved))
            let old = try JSONDecoder().decode(OldWindow.self, from: data)
            XCTAssertEqual(old.sidebarContent, content == .files ? .files : .workspaces)
            XCTAssertEqual(old.workspaces.count, store.workspaces.count)
        }
        var legacy = try XCTUnwrap(persistence.saved)
        legacy.leftNavigation = nil
        legacy.sidebarSelectedContent = "future-mode"
        legacy.sidebarContent = .files
        legacy.chatSidebarPreferences = nil
        let restored = makeStore(InMemoryPersistence(initial: legacy))
        defer { restored.terminate() }
        XCTAssertEqual(restored.sidebarContent, .files)
        XCTAssertEqual(restored.chatSidebarPreferences.width, 268)
    }

    func testChatWidthClampsAndSectionsAreScoped() throws {
        XCTAssertEqual(ChatSidebarPreferences.clampWidth(100), 220)
        XCTAssertEqual(ChatSidebarPreferences.clampWidth(900), 320)
        XCTAssertEqual(ChatSidebarPreferences.clampWidth(.nan), 268)
        var prefs = ChatSidebarPreferences()
        let one = ChatSidebarPreferences.Section(key, team: "General")
        var other = one; other.account = "another"
        prefs.setCollapsed(one, true); prefs.setCollapsed(one, true)
        XCTAssertEqual(prefs.collapsed, [one])
        XCTAssertFalse(prefs.collapsed.contains(other))
        prefs.setCollapsed(one, false)
        XCTAssertTrue(prefs.collapsed.isEmpty)
    }

    private func makeStore(_ persistence: InMemoryPersistence) -> WorkspaceStore {
        WorkspaceStore(persistence: persistence, engineFactory: { TestEngine() }, optionsProvider: { _ in nil }, resumeProvider: { true })
    }

    func testMentionInsertionCannotCrossWindowChannelAccountOrIME() {
        let ref = ChannelRef(key, channel: "one")
        XCTAssertTrue(ChatSidebarMention.accepts(target: ref, requested: ref, sameWindow: true, sameHost: true, visible: true, markedText: false))
        XCTAssertFalse(ChatSidebarMention.accepts(target: nil, requested: ref, sameWindow: true, sameHost: true, visible: true, markedText: false), "thread and inline editors have no navigation target")
        for (window, visible, marked) in [(false, true, false), (true, false, false), (true, true, true)] {
            XCTAssertFalse(ChatSidebarMention.accepts(target: ref, requested: ref, sameWindow: window, sameHost: true, visible: visible, markedText: marked))
        }
        var other = ref; other.account = "other"
        XCTAssertFalse(ChatSidebarMention.accepts(target: other, requested: ref, sameWindow: true, sameHost: true, visible: true, markedText: false))
        XCTAssertFalse(ChatSidebarMention.accepts(target: ref, requested: ref, sameWindow: true, sameHost: false, visible: true, markedText: false))
        other = ref; other.channel = "two"
        XCTAssertFalse(ChatSidebarMention.accepts(target: other, requested: ref, sameWindow: true, sameHost: true, visible: true, markedText: false))
    }

    func testMentionUsesNativeEditingUndoAndTheOriginatingWindowOnly() throws {
        final class Delegate: NSObject, NSTextViewDelegate {
            var edits = 0
            func textDidChange(_ notification: Notification) { edits += 1 }
        }
        let model = model(), ref = ChannelRef(key, channel: "one")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; otherWindow.isReleasedWhenClosed = false
        defer { window.close(); otherWindow.close() }
        let editor = ChatMentionEditor.Editor(frame: window.contentView!.bounds)
        let other = ChatMentionEditor.Editor(frame: otherWindow.contentView!.bounds)
        editor.navigationTarget = ref; other.navigationTarget = ref
        editor.allowsUndo = true; editor.isRichText = false
        window.contentView = editor; otherWindow.contentView = other
        editor.string = "draft 😀"; other.string = "another window"
        let delegate = Delegate(); editor.delegate = delegate
        editor.setSelectedRange(NSRange(location: 6, length: 2))
        ChatSidebarMention.register(editor); ChatSidebarMention.register(other)
        let undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping()
        XCTAssertTrue(ChatSidebarMention.insert(agentID: "a1", ref: ref, window: window, destination: editor, model: model))
        undo.endUndoGrouping()
        XCTAssertEqual(editor.string, "draft @reviewer@me ")
        XCTAssertEqual(other.string, "another window")
        XCTAssertEqual(delegate.edits, 1, "the existing composer delegate saves the new draft/version")
        undo.undo()
        XCTAssertEqual(editor.string, "draft 😀")
        var view = model.view; view.rightsInDoubt = true; model.set(view)
        XCTAssertFalse(ChatSidebarMention.insert(agentID: "a1", ref: ref, window: window, destination: editor, model: model))
        XCTAssertEqual(editor.string, "draft 😀")
    }

    func testMentionUsesOnlyActiveTabHostWithSameChannelInTwoPanes() throws {
        let store = makeStore(InMemoryPersistence()), model = model(), ref = ChannelRef(key, channel: "one")
        defer { store.terminate() }
        let workspace = try XCTUnwrap(store.active), pane = try XCTUnwrap(workspace.activePane)
        let first = store.openChannelTab(ref, in: workspace, pane: pane)
        let secondPane = try XCTUnwrap(store.splitPane(pane, orientation: .horizontal, in: workspace))
        let second = store.openChannelTab(ref, in: workspace, pane: secondPane)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let container = try XCTUnwrap(window.contentView)
        let firstHost = first.engine.view, secondHost = second.engine.view
        firstHost.frame = NSRect(x: 0, y: 0, width: 400, height: 160)
        secondHost.frame = NSRect(x: 400, y: 0, width: 400, height: 160)
        container.addSubview(firstHost); container.addSubview(secondHost)
        let firstEditor = ChatMentionEditor.Editor(frame: firstHost.bounds), secondEditor = ChatMentionEditor.Editor(frame: secondHost.bounds)
        for (host, editor) in [(firstHost, firstEditor), (secondHost, secondEditor)] {
            host.addSubview(editor); editor.navigationTarget = ref; ChatSidebarMention.register(editor)
        }
        // Exercise both active hosts: arbitrary NSHashTable order cannot pass both.
        for (session, active, inactive) in [(first, firstEditor, secondEditor), (second, secondEditor, firstEditor)] {
            firstEditor.string = "one"; secondEditor.string = "two"
            store.activateTab(session, in: workspace)
            active.setSelectedRange(NSRange(location: (active.string as NSString).length, length: 0))
            let untouched = inactive.string
            XCTAssertTrue(ChatSidebarMention.insert(agentID: "a1", ref: ref, window: window, model: model, store: store))
            XCTAssertTrue(active.string.hasSuffix(" @reviewer@me "))
            XCTAssertEqual(inactive.string, untouched)
            XCTAssertTrue(window.firstResponder === active)
            XCTAssertTrue(workspace.activeSession === session)
        }
    }

    func testMissingComposerOpensSameHostAndDeliversOnceAfterAttachment() async throws {
        try await checkDeferredMention(invalidate: nil)
    }

    func testCardMentionRoutesThroughPinAndThreadDismissal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mention-pins-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ChatFiles(directory: directory), service = ChatService(files: files, tokens: FakeTokenStore())
        let cache = try ChatStore.open(files: files, key: key).store
        let workspace = makeTestStore(), org = model(), ref = ChannelRef(key, channel: "one")
        defer { workspace.terminate() }
        let active = try XCTUnwrap(workspace.active)
        let tab = workspace.openChannelTab(ref, in: active, pane: try XCTUnwrap(active.activePane))
        let engine = try XCTUnwrap(tab.engine as? ChannelTabEngine)
        engine.conversation.update(.ready(channel("one"), team: "General", offline: true), key: key, store: cache, service: service)
        let conversation = try XCTUnwrap(engine.conversation.model)
        conversation.openThread("thread")
        conversation.pins.open(); conversation.pins.expanded = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            // The native restoration/delivery is covered by ChatPinsTests;
            // cancel this routing-only request before releasing its window.
            ChatSidebarMention.request(agentID: "a1", ref: ref, window: nil, destination: engine.view, model: org,
                isActive: { false }, openChannel: {})
            window.close()
        }
        XCTAssertTrue(ChatSidebarMention.insert(agentID: "a1", ref: ref, window: window, model: org, store: workspace))
        XCTAssertFalse(conversation.pins.isPresented)
        XCTAssertNil(conversation.threadRoot)
        XCTAssertTrue(active.activeSession === tab)
        XCTAssertTrue(try cache.outbox.commands().isEmpty)
    }

    func testDeferredMentionDropsOnActiveTabChange() async throws { try await checkDeferredMention(invalidate: "tab") }
    func testDeferredMentionDropsOnAccessLoss() async throws { try await checkDeferredMention(invalidate: "access") }

    private func checkDeferredMention(invalidate: String?) async throws {
        let model = model(), ref = ChannelRef(key, channel: "one")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 160))
        let other = ChatMentionEditor.Editor(frame: NSRect(x: 400, y: 0, width: 400, height: 160))
        window.contentView?.addSubview(host); window.contentView?.addSubview(other)
        other.navigationTarget = ref; other.string = "inactive draft"; ChatSidebarMention.register(other)
        var opens = 0, active = true
        XCTAssertTrue(ChatSidebarMention.request(agentID: "a1", ref: ref, window: window, destination: host, model: model,
            isActive: { active }, openChannel: { opens += 1 }))
        XCTAssertEqual(opens, 1, "absence in this host must open this channel, never use another panel")
        ChatSidebarMention.editorReady(other)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(other.string, "inactive draft")
        if invalidate == "tab" { active = false }
        if invalidate == "access" { var view = model.view; view.rightsInDoubt = true; model.set(view) }
        let editor = ChatMentionEditor.Editor(frame: host.bounds)
        editor.navigationTarget = ref; editor.string = "restored draft"; editor.setSelectedRange(NSRange(location: 14, length: 0))
        ChatSidebarMention.register(editor); host.addSubview(editor)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(editor.string, invalidate == nil ? "restored draft @reviewer@me " : "restored draft")
        ChatSidebarMention.editorReady(editor)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(editor.string, invalidate == nil ? "restored draft @reviewer@me " : "restored draft", "one delivery only")
        XCTAssertEqual(other.string, "inactive draft")
    }

    func testMentionDoesNotReopenOrModifyAnIMEOrDisabledEditor() throws {
        let model = model(), ref = ChannelRef(key, channel: "one")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let editor = ChatMentionEditor.Editor(frame: window.contentView!.bounds)
        window.contentView = editor; editor.navigationTarget = ref; ChatSidebarMention.register(editor)
        for ime in [true, false] {
            editor.string = "draft"; editor.isEditable = ime
            if ime { editor.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 5, length: 0)) }
            let before = editor.string
            XCTAssertFalse(ChatSidebarMention.request(agentID: "a1", ref: ref, window: window, destination: editor, model: model,
                isActive: { true }, openChannel: { XCTFail("an existing editor must not be replaced") }))
            XCTAssertEqual(editor.string, before)
            editor.unmarkText()
        }
    }

    func testF4MentionsUseOneLedgerForRowsAndDockIncludingMutedReplies() throws {
        let queue = try DatabaseQueue()
        try ChatStoreMigrations.cache.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "UPDATE meta SET me = 'me'")
            try db.execute(sql: "INSERT INTO teams (team_id, name, mine) VALUES ('t', 'General', 1), ('hidden', 'Hidden', 0)")
            try db.execute(sql: "INSERT INTO channels (channel_id, team_id, name, version, stamp) VALUES ('a', 't', 'A', 1, 1), ('b', 't', 'B', 1, 1), ('h', 'hidden', 'H', 1, 1)")
            for (id, channel, author, mentions, root, deleted) in [
                ("root", "a", "other", "[\"me\"]", nil, nil),
                ("reply", "a", "other", "[\"me\"]", "root", nil),
                ("other-channel", "b", "other", "[\"me\"]", nil, nil),
                ("my-own", "a", "me", "[\"me\"]", nil, nil),
                ("bot-mention", "a", "other", "[\"agent-id\"]", nil, nil),
                ("deleted", "a", "other", "[\"me\"]", nil, "gone"),
                ("hidden", "h", "other", "[\"me\"]", nil, nil)
            ] as [(String, String, String, String, String?, String?)] {
                try db.execute(sql: "INSERT INTO messages (message_id, channel_id, author_account_id, mentions, thread_root_id, deleted_at, seq, has_fixed, has_mutable) VALUES (?, ?, ?, ?, ?, ?, 10, 1, 1)",
                               arguments: [id, channel, author, mentions, root, deleted])
            }
            try ChatUnread.setMuted(db, channel: "a", true)
            XCTAssertEqual(try ChatUnread.unreadMentionsByChannel(db), ["a": 2, "b": 1])
            XCTAssertEqual(try ChatUnread.unreadMentions(db), 3)
            try db.execute(sql: "INSERT INTO notified (object_id, kind, channel_id, seq, read) VALUES ('reply', 'mention', 'a', 10, 1)")
            XCTAssertEqual(try ChatUnread.unreadMentionsByChannel(db), ["a": 1, "b": 1])
            try ChatUnread.markRead(db, channel: "a", upTo: 10)
            XCTAssertEqual(try ChatUnread.unreadMentionsByChannel(db), ["b": 1])
            XCTAssertEqual(try ChatUnread.unreadMentions(db), 1)
            try db.execute(sql: "UPDATE teams SET mine = 0 WHERE team_id = 't'")
            XCTAssertEqual(try ChatUnread.unreadMentions(db), 0)
        }
    }
}

extension ChatSidebarTests {
    func testR115AgentCardLabelsAccessAndRoutesRealChannelActions() throws {
        let model = model(), active = ChannelRef(key, channel: "two")
        let actions = try XCTUnwrap(ChatSidebarAgentActions(agentID: "a1", active: active, model: model))
        XCTAssertEqual(actions.channels.map(\.channelId), ["two", "one"])
        XCTAssertEqual(actions.mentionChannel?.channelId, "two")
        XCTAssertEqual(actions.address, "reviewer@me")
        XCTAssertEqual(actions.accessLabel, "Access: Read")
        var changed = model.view
        changed.channelAgents[0].access = "edit-files"; changed.channelAgents[1].access = "edit-files"
        model.set(changed)
        XCTAssertEqual(ChatSidebarAgentActions(agentID: "a1", active: active, model: model)?.accessLabel, "Access: Edit files (no shell)")
        var opened: [ChannelRef] = []
        XCTAssertTrue(ChatSidebarAgentActions.open(agentID: "a1", channel: "one", model: model) { opened.append($0) })
        XCTAssertEqual(opened, [ChannelRef(key, channel: "one")])
        XCTAssertFalse(ChatSidebarAgentActions.open(agentID: "a1", channel: "hidden", model: model) { opened.append($0) })
        XCTAssertEqual(opened.count, 1)
        model.isCurrent = { false }
        XCTAssertFalse(ChatSidebarAgentActions.open(agentID: "a1", channel: "one", model: model) { opened.append($0) })
        XCTAssertEqual(opened.count, 1)
    }

    func testR115MentionOfferedInWritableChannelIncludingAgentNotYetAdded() throws {
        let model = model()
        let actions = try XCTUnwrap(ChatSidebarAgentActions(agentID: "own", active: ChannelRef(key, channel: "one"), model: model))
        XCTAssertTrue(actions.channels.isEmpty)
        XCTAssertEqual(actions.mentionChannel?.channelId, "one")
        XCTAssertEqual(actions.address, "writer@me")
        XCTAssertNil(ChatSidebarAgentActions(agentID: "own", active: nil, model: model)?.mentionChannel)
        XCTAssertNil(ChatSidebarAgentActions(agentID: "own", active: ChannelRef(key, channel: "old"), model: model)?.mentionChannel)
        var other = ChannelRef(key, channel: "one"); other.account = "other"
        XCTAssertNil(ChatSidebarAgentActions(agentID: "own", active: other, model: model)?.mentionChannel)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = ChatMentionEditor.Editor(frame: window.contentView!.bounds)
        editor.navigationTarget = ChannelRef(key, channel: "one")
        editor.string = "Draft"; editor.setSelectedRange(NSRange(location: 5, length: 0))
        window.contentView = editor; ChatSidebarMention.register(editor)
        XCTAssertTrue(ChatSidebarMention.insert(agentID: "own", ref: ChannelRef(key, channel: "one"), window: window, destination: editor, model: model))
        XCTAssertEqual(editor.string, "Draft @writer@me ")
    }

    func testR115AskRechecksColleagueAddressOrganizationAndVisibility() throws {
        let model = model()
        var view = model.view
        view.channelAgents.append(agent("colleague", channel: "one", owner: "other"))
        model.set(view)
        let target = try XCTUnwrap(ChatSidebarAgentActions(agentID: "colleague", active: nil, model: model))
        XCTAssertTrue(target.canAsk(in: model))
        var sent: [String] = []
        try target.submitAsk(in: model, resolve: { _ in "colleague" }, send: { sent.append($0) })
        XCTAssertEqual(sent, ["reviewer@other"])
        XCTAssertThrowsError(try target.submitAsk(in: model, resolve: { _ in "replacement-agent" }, send: { sent.append($0) }))
        XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(try XCTUnwrap(ChatSidebarAgentActions(agentID: "a1", active: nil, model: model)).canAsk(in: model))
        model.key = ChatOrgKey(server: key.server, accountId: key.accountId, orgId: "elsewhere")
        XCTAssertFalse(target.canAsk(in: model))
        model.key = key
        view.channelAgents[view.channelAgents.count - 1].name = "renamed"; model.set(view)
        XCTAssertFalse(target.canAsk(in: model))
        view.channelAgents[view.channelAgents.count - 1].name = "reviewer"; view.rightsInDoubt = true; model.set(view)
        XCTAssertFalse(target.canAsk(in: model))
    }

    func testR115PublicationEditorResolvesExactAgentAndCapturedOrganization() throws {
        let first = TeamPublishedAgent(name: "first", description: "First", folder: "/tmp/first")
        let second = TeamPublishedAgent(name: "second", description: "Second", folder: "/tmp/second", access: .editFiles)
        let opened = try XCTUnwrap(TeamAgentEditing.resolve(agentID: second.id.uuidString.lowercased(), key: key, currentKey: key, agents: [first, second]))
        XCTAssertEqual(opened.agent, second); XCTAssertEqual(opened.key, key)
        XCTAssertNil(TeamAgentEditing.resolve(agentID: "missing", key: key, currentKey: key, agents: [first, second]))
        XCTAssertNil(TeamAgentEditing.resolve(agentID: second.id.uuidString, key: key, currentKey: nil, agents: [first, second]))
        XCTAssertNil(TeamAgentEditing.resolve(agentID: second.id.uuidString, key: key,
            currentKey: ChatOrgKey(server: key.server, accountId: "other", orgId: key.orgId), agents: [first, second]))
    }
    func testProfileKeyboardEnterStartsWhileArrowsOnlyDiscloseHistory() {
        let id = UUID(), profile = ChatSidebarRowID.profile(id), session = ChatSidebarRowID.history(id, "session")
        let rows: [ChatSidebarKeyboard.Row] = [.init(id: profile, expanded: true), .init(id: session, parent: profile), .init(id: .allSessions)]
        XCTAssertEqual(ChatSidebarKeyboard.route(.enter, selection: profile, rows: rows), .activate(profile))
        XCTAssertEqual(ChatSidebarKeyboard.route(.left, selection: profile, rows: rows), .expand(profile, false))
        XCTAssertEqual(ChatSidebarKeyboard.route(.right, selection: profile, rows: rows), .select(session))
        XCTAssertEqual(ChatSidebarKeyboard.route(.enter, selection: session, rows: rows), .activate(session))
        XCTAssertEqual(ChatSidebarKeyboard.route(.down, selection: session, rows: rows), .select(.allSessions))
    }

    func testOnlyConfirmedLocalPublicationDeduplicatesRemoteRows() {
        let profile = UUID(), own = snapshot(model()).agents.first!
        var result = LocalProfilePublications()
        result.include(agent: own, profileID: profile, confirmed: false)
        result.include(agent: own, profileID: nil, confirmed: true)
        XCTAssertTrue(result.agents.isEmpty, "Name/account matches are not local origin")
        var remote = own; remote.mine = false
        result.include(agent: remote, profileID: profile, confirmed: true)
        XCTAssertTrue(result.profiles.isEmpty)
        result.include(agent: own, profileID: profile, confirmed: true)
        result.include(agent: own, profileID: profile, confirmed: true)
        XCTAssertEqual(result.profiles, [profile]); XCTAssertEqual(result.agents, [own.id])
    }

    func testUnifiedSidebarKeepsLocalProfilesWhenTeamAccessIsClosedAndRendersNarrow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-profiles-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = AgentProfileStore(), store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            agentProfiles: profiles, engineFactory: { TestEngine() }, optionsProvider: { _ in nil })
        defer { store.terminate() }
        let profile = try profiles.add(template: .codex, folder: root, name: "Local writer")
        store.expandedAgentProfiles.insert(profile.id)
        let model = model()
        let history = AgentSessionHistory(profiles: profiles); history.scan = { [] }
        let previous = AgentPadSettingsModel.testModel
        defer { AgentPadSettingsModel.testModel = previous }
        for state in ["connected", "local", "offline", "checking"] {
            model.showsOffline = { state == "offline" }; model.snapshotOwed = { state == "checking" }
            let activeModel = state == "local" ? nil : model
            let snapshot = ChatSidebarSnapshot(model: activeModel, active: nil)
            if state == "checking" || state == "local" { XCTAssertTrue(snapshot.agents.isEmpty); XCTAssertTrue(snapshot.teams.isEmpty) }
            XCTAssertEqual(profiles.profiles, [profile])
            for dark in [false, true] {
                AgentPadSettingsModel.testModel = AgentPadSettingsModel(read: { ["appearance": ["mode": dark ? "dark" : "light"]] }, write: { _ in }, appliesRuntimeEffects: false)
                let host = NSHostingView(rootView: ChatSidebarView(store: store, navigation: ChatSidebarNavigation(), model: activeModel, profileHistory: history)
                    .foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground).environment(\.colorScheme, dark ? .dark : .light))
                host.frame = NSRect(x: 0, y: 0, width: 236, height: 980); host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let path = ProcessInfo.processInfo.environment["AGENTPAD_TEST_ARTIFACTS"] {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("sidebar-\(state)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    func testConfirmedLinkProjectionIsScopedAndKeepsAnotherMacRemote() throws {
        let profiles = AgentProfileStore()
        let profile = try profiles.add(template: .codex, folder: FileManager.default.temporaryDirectory)
        var details = profiles.details.archive
        details.confirmedPublications = [.init(scope: OrgKey(key), agentID: "a1", profileID: profile.id, acceptedSessionID: "this-mac")]
        try profiles.details.commit(details)
        var agent = snapshot(model()).agents.first!
        agent.executorSessionID = "this-mac"
        XCTAssertEqual(LocalProfilePublications.current(profiles, key: key, agents: [agent]).profiles, [profile.id])
        agent.executorSessionID = "other-mac"
        XCTAssertTrue(LocalProfilePublications.current(profiles, key: key, agents: [agent]).agents.isEmpty)
        agent.executorSessionID = "this-mac"
        let other = ChatOrgKey(server: key.server, accountId: key.accountId, orgId: "another-org")
        XCTAssertTrue(LocalProfilePublications.current(profiles, key: other, agents: [agent]).profiles.isEmpty)
        XCTAssertEqual(profiles.details.archive.confirmedPublications?.map(\.profileID), [profile.id], "Local mode keeps the accepted link without probing a server")
    }

}
