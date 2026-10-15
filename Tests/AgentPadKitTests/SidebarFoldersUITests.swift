import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

@MainActor final class SidebarFoldersUITests: XCTestCase {
    var team: TeamServiceTestScope!
    var fixture: FoldersUIFixture!
    var previousTheme: AgentPadSettingsModel?
    var previousEnhancedUI: Any?
    let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    override func setUp() async throws {
        _ = NSApplication.shared
        previousEnhancedUI = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true,forAttribute: enhancedUI)
        team = TeamServiceTestScope(); previousTheme = AgentPadSettingsModel.testModel
        AgentPadSettingsModel.testModel = AgentPadSettingsModel(read: { ["appearance":["mode":"light"]] },write: { _ in },appliesRuntimeEffects: false)
        fixture = try FoldersUIFixture(); try await fixture.start()
    }
    override func tearDown() async throws {
        SidebarFolderActions.shared.request = nil
        fixture.close(); fixture = nil; team.close(); team = nil
        AgentPadSettingsModel.testModel = previousTheme
        NSApp.accessibilitySetValue(previousEnhancedUI,forAttribute: enhancedUI)
    }
    func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Condition was not reached",file: file,line: line)
    }
    func testHostedPinnedRegionDoesNotMoveWhenFoldersScroll() async throws {
        let host = FoldersUIHost(fixture.sidebar); defer { host.close() }; try await host.settle()
        let pinned = try XCTUnwrap(host.elements.first { $0.accessibilityLabel()?.hasPrefix("Needs attention, pinned,") == true })
        let before = pinned.accessibilityFrame()
        let scroll = try XCTUnwrap(host.scrolls().max { $0.frame.height < $1.frame.height })
        scroll.contentView.scroll(to: NSPoint(x: 0,y: 300)); scroll.reflectScrolledClipView(scroll.contentView)
        try await host.settle()
        let after = try XCTUnwrap(host.elements.first { $0.accessibilityLabel()?.hasPrefix("Needs attention, pinned,") == true }).accessibilityFrame()
        XCTAssertEqual(before.minY,after.minY,accuracy: 1)
        XCTAssertEqual(before.height,after.height,accuracy: 1)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY,0)
        let maximum = await fixture.provider.maximumWindows
        XCTAssertLessThanOrEqual(maximum,5)
    }
    func testHostedThirtyCriticalItemsAreCappedAndSurviveCollapse() async throws {
        let items = (0..<30).map { AttentionItem(id: "critical-\($0)",tier: $0.isMultiple(of: 2) ? 0 : 1,time: .now,
            title: "Approval \($0)",subtitle: "Needs input",action: .event("critical-\($0)")) }
        let host = FoldersUIHost(VStack(spacing: 0) {
            AttentionSectionContent(items: items,total: 30,alwaysShowsHeader: true,maximumHeight: 240,
                collapsed: .constant(true),expanded: .constant(false),activate: { _ in },secondary: { _ in },settings: {})
            Spacer()
        },height: 600)
        defer { host.close() }; try await host.settle()
        let pinned = try XCTUnwrap(host.elements.first { $0.accessibilityLabel() == "Needs attention, pinned, 30 items" })
        XCTAssertLessThanOrEqual(pinned.accessibilityFrame().height,240)
        XCTAssertTrue(host.labels().contains { $0.contains("Approval 0") })
        XCTAssertTrue(host.scrolls().contains { ($0.documentView?.frame.height ?? 0) > $0.frame.height })
    }
    func testOrderedEntriesVisibilityAndPersistentCollapseReopen() async throws {
        let sidebar = fixture.sidebar
        XCTAssertEqual(Array(sidebar.folderEntries(sidebar.snapshot).map(\.title).prefix(6)),["Channels · Aster","People","Launch","Work","Family","All chats"])
        let work = try XCTUnwrap(sidebar.folderEntries(sidebar.snapshot).first { $0.title == "Work" })
        sidebar.setEntryExpanded(work,false)
        try await eventually { !fixture.sidebar.entryExpanded(work) }
        XCTAssertFalse(fixture.sidebar.entryExpanded(work),"A new view reads persisted profile collapse")
        let people = try XCTUnwrap(sidebar.folderEntries(sidebar.snapshot).first { $0.title == "People" })
        sidebar.setEntryExpanded(people,true)
        let restored = try JSONDecoder().decode(ChatSidebarPreferences.self,from: JSONEncoder().encode(fixture.store.chatSidebarPreferences))
        XCTAssertFalse(restored.collapsedEntries.contains(people.id))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(restored),as: UTF8.self).contains("folder:1"))
        fixture.folders.setVisible(work,false)
        try await eventually { !fixture.sidebar.folderEntries(fixture.sidebar.snapshot).contains { $0.id == work.id } }
        fixture.folders.undoHide()
        try await eventually { fixture.sidebar.folderEntries(fixture.sidebar.snapshot).contains { $0.id == work.id } }
    }
    func testHostedBadgesProvisionalAccessibilityAndCollapsedAttentionDot() async throws {
        let entry = SidebarFolderEntry(id: "sample",title: "Work",kind: .telegram(.folder(1)),count: 8,unread: 8,unmuted: 3,attention: true,provisional: true)
        var muted = entry; muted.unmuted = 0; muted.title = "Muted"
        let host = FoldersUIHost(VStack {
            SidebarFolderEntryView(entry: entry,expanded: false,sticky: false,toggle: {}) { EmptyView() } actions: { EmptyView() }
            SidebarFolderEntryView(entry: muted,expanded: false,sticky: false,toggle: {}) { EmptyView() } actions: { EmptyView() }
            Spacer()
        },height: 220)
        defer { host.close() }; try await host.settle()
        XCTAssertEqual(entry.badgeCount,3); XCTAssertEqual(muted.badgeCount,8)
        XCTAssertTrue(host.labels().contains(entry.accessibilityLabel))
        XCTAssertTrue(entry.accessibilityLabel.contains("at least 3 unread, needs attention"))
        XCTAssertTrue(host.elements.contains { $0.accessibilityValue() as? String == "Collapsed" })
        func bluePixels(unmuted: Bool, contrast: Bool = false) async throws -> Int {
            let badge = FoldersUIHost(SidebarUnreadBadge(count: 8,unmuted: unmuted),width: 100,height: 50,contrast: contrast)
            defer { badge.close() }; try await badge.settle()
            let bitmap = try badge.bitmap()
            return (0..<bitmap.pixelsWide).reduce(0) { count, x in
                count + (0..<bitmap.pixelsHigh).filter { y in
                    guard let color = bitmap.colorAt(x: x,y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.blueComponent > color.redComponent + 0.15 && color.greenComponent > color.redComponent + 0.04
                }.count
            }
        }
        let ordinary = try await bluePixels(unmuted: true)
        let mutedPixels = try await bluePixels(unmuted: false)
        let outlinedPixels = try await bluePixels(unmuted: true,contrast: true)
        XCTAssertGreaterThan(ordinary,0)
        XCTAssertEqual(mutedPixels,0)
        XCTAssertGreaterThan(outlinedPixels,ordinary,"Increased contrast adds the badge outline")
    }
    func testMoreAddsTenShowLessAndStickyHeaderHasOneAccessibleInstance() async throws {
        let main = try XCTUnwrap(fixture.sidebar.folderEntries(fixture.sidebar.snapshot).first { $0.kind == .telegram(.main) })
        fixture.sidebar.more(main)
        try await eventually { fixture.telegram.snapshot.lists.first { $0.key == .main }?.capacity == 18 }
        fixture.sidebar.more(main)
        try await eventually { fixture.telegram.snapshot.lists.first { $0.key == .main }?.capacity == 28 }
        for entry in fixture.sidebar.folderEntries(fixture.sidebar.snapshot) where entry.id != main.id { fixture.folders.setVisible(entry,false) }
        let host = FoldersUIHost(fixture.sidebar); defer { host.close() }; try await host.settle()
        let scroll = try XCTUnwrap(host.scrolls().max { $0.frame.height < $1.frame.height })
        scroll.contentView.scroll(to: NSPoint(x: 0,y: 160)); scroll.reflectScrolledClipView(scroll.contentView); try await host.settle()
        let headers = host.elements.filter { $0.accessibilityLabel()?.hasPrefix("All chats, Telegram folder,") == true }
        XCTAssertEqual(headers.count,1)
        if let header = headers.first {
            let top = scroll.window!.convertToScreen(scroll.convert(scroll.bounds,to: nil)).maxY
            XCTAssertEqual(header.accessibilityFrame().maxY,top,accuracy: 15)
        }
        await fixture.telegram.expand(.main,showLess: true)
        try await eventually { fixture.telegram.snapshot.lists.first { $0.key == .main }?.capacity == 8 }
        XCTAssertFalse(fixture.telegram.snapshot.lists.first { $0.key == .main }!.expanded)
        var provisional = main; provisional.provisional = true
        let counter = FoldersUIHost(fixture.sidebar.entryMore(provisional),height: 100)
        defer { counter.close() }; try await counter.settle()
        XCTAssertTrue(counter.labels().contains("143+ more"))
    }
    func testOneChatInTwoRealRowsSharesSelectionBadgesAndSpokenState() async throws {
        var row = FoldersUIFixture.rows()[1]; row.markedUnread = true; row.pinned = true; row.muted = true
        _ = fixture.store.openToolTab(.telegram(row.id))
        let folder = SidebarCustomFolder(id: fixture.launch,name: "Launch")
        let host = FoldersUIHost(VStack {
            TelegramFolderRow(row: row,store: fixture.store,model: fixture.telegram,folders: fixture.folders,entryID: "work")
            TelegramFolderRow(row: row,store: fixture.store,model: fixture.telegram,folders: fixture.folders,entryID: "launch",folder: folder)
            Spacer()
        },height: 220)
        defer { host.close() }; try await host.settle()
        let rows = host.elements.filter { $0.accessibilityLabel()?.hasPrefix("Pine Studio, Supergroup,") == true }
        XCTAssertEqual(rows.count,2)
        XCTAssertTrue(rows.allSatisfy { $0.accessibilityValue() as? String == "Selected" })
        XCTAssertEqual(rows.filter { $0.accessibilityLabel()?.contains("pinned in Telegram") == true }.count,1)
        XCTAssertTrue(rows.allSatisfy { $0.accessibilityLabel()?.contains("marked unread, ") == true && $0.accessibilityLabel()?.contains("muted, in Needs attention") == true })
    }
    func testRowMenuChooserToggleAndCreateThenRemoveMembership() async throws {
        let row = FoldersUIFixture.rows()[2]
        let rowView = TelegramFolderRow(row: row,store: fixture.store,model: fixture.telegram,folders: fixture.folders,entryID: "work",selected: true)
        let menu = FoldersUIHost(VStack(alignment: .leading) { rowView; Spacer() },width: 320,height: 400)
        try await menu.settle()
        menu.key(109,"\u{F70D}",modifiers: .shift,throughApp: true); try await menu.settle()
        XCTAssertTrue(menu.press("Add to folder…",popup: true))
        let request = try XCTUnwrap(SidebarFolderActions.shared.request)
        try await eventually { menu.popupElements.contains { $0.accessibilityLabel() == "Add to folder" } }
        menu.close()
        XCTAssertEqual(request.item,.telegram(row.id.chat)); XCTAssertEqual(request.anchor,"work")
        let chooser = FoldersUIHost(AddToFolderChooser(request: request,model: fixture.folders,dismiss: {}),width: 308,height: 440)
        defer { chooser.close() }; try await chooser.settle()
        XCTAssertTrue(chooser.press("Clients"))
        try await eventually { fixture.folders.snapshot.members[fixture.clients]?.contains(.telegram(3)) == true }
        try await chooser.settle(); XCTAssertTrue(chooser.press("New folder…")); try await chooser.settle()
        let editor = try XCTUnwrap(chooser.window.firstResponder as? NSTextView)
        editor.insertText("Release notes",replacementRange: NSRange(location: 0,length: editor.string.utf16.count))
        chooser.key(36,"\r")
        try await eventually { fixture.folders.snapshot.catalog.custom.contains { $0.name == "Release notes" } }
        let created = try XCTUnwrap(fixture.folders.snapshot.catalog.custom.first { $0.name == "Release notes" })
        try await eventually { fixture.folders.snapshot.members[created.id] == [.telegram(3)] }
        fixture.folders.remove(.telegram(3),from: created.id)
        try await eventually { fixture.folders.snapshot.members[created.id]?.isEmpty == true }
        chooser.close(); SidebarFolderActions.shared.request = nil
        let pinned = FoldersUIHost(fixture.sidebar)
        defer { pinned.close() }; try await pinned.settle()
        let attention = try XCTUnwrap(fixture.attention.items.first { $0.telegramChat != nil })
        SidebarFolderActions.shared.present(.telegram(try XCTUnwrap(attention.telegramChat)),binding: fixture.binding,
            windowID: fixture.store.windowID,anchor: "attention:" + attention.id)
        try await eventually { pinned.popupElements.contains { $0.accessibilityLabel() == "Add to folder" } }
    }
    func testSheetOneTelegramHandleAndKeyboardMovesWholeBlock() async throws {
        let host = FoldersUIHost(FoldersSheet(model: fixture.folders,entries: fixture.sidebar.folderEntries(fixture.sidebar.snapshot,includeHidden: true),telegram: fixture.telegram,dismiss: {}),width: 520,height: 650)
        defer { host.close() }; try await host.settle()
        XCTAssertEqual(host.labels().filter { $0 == "Move Telegram" }.count,1)
        XCTAssertFalse(host.labels().contains("Move Work")); XCTAssertFalse(host.labels().contains("Move All chats"))
        let before = fixture.folders.snapshot.catalog.order
        for _ in 0..<4 { host.key(125,"\u{F701}"); try await host.settle() }
        host.key(126,"\u{F700}",modifiers: [.command,.option])
        try await eventually { fixture.folders.snapshot.catalog.order != before }
        XCTAssertEqual(fixture.folders.snapshot.catalog.order.firstIndex(of: "telegram"),(before.firstIndex(of: "telegram") ?? 0) - 1)
        XCTAssertEqual(fixture.telegram.snapshot.lists.map(\.name),["Work","Family","Unread","All chats","Archive"])
        XCTAssertTrue(host.labels().contains("Show Work"))
        host.key(49," "); try await eventually { fixture.telegram.snapshot.lists.first { $0.key == .folder(1) }?.visible == false }
        try await host.settle(); host.key(49," "); try await eventually { fixture.telegram.snapshot.lists.first { $0.key == .folder(1) }?.visible == true }
    }
    func testSheetCreateRenameDeleteAndNotConnectedGroup() async throws {
        let host = FoldersUIHost(FoldersSheet(model: fixture.folders,entries: fixture.sidebar.folderEntries(fixture.sidebar.snapshot,includeHidden: true),telegram: fixture.telegram,dismiss: {}),width: 520,height: 650)
        defer { host.close() }; try await host.settle()
        XCTAssertTrue(host.press("New folder"))
        try await eventually { fixture.folders.editing != nil }
        let id = try XCTUnwrap(fixture.folders.editing)
        XCTAssertEqual(fixture.folders.snapshot.catalog.order.first,SidebarEntryIdentity.custom(id))
        try await host.settle()
        let editor = try XCTUnwrap(host.window.firstResponder as? NSTextView)
        editor.insertText("Release notes",replacementRange: NSRange(location: 0,length: editor.string.utf16.count))
        host.key(36,"\r")
        try await eventually { fixture.folders.snapshot.catalog.custom.first { $0.id == id }?.name == "Release notes" }
        try await host.settle()
        host.key(51,"\u{8}",modifiers: .command)
        try await eventually { fixture.folders.deleting?.id == id }
        try await host.settle()
        XCTAssertTrue(host.labels().contains("Items stay where they are."))
        host.press("Delete")
        try await eventually { fixture.folders.snapshot.catalog.tombstones.contains(id) }
        fixture.telegram.receive(.init()); try await host.settle()
        XCTAssertTrue(host.labels().contains("Connect"))
        XCTAssertTrue(host.labels().contains("Connect to show its folders"))
        XCTAssertFalse(host.labels().contains("Show Work"))
    }
    func testOfflineUnavailableArchivedAndEmptyStatesUseRealRows() async throws {
        await fixture.provider.setState(.paused("No connection"))
        try await eventually { fixture.telegram.folderStatus == "Offline · No connection" }
        let channel = SidebarItemReference.agentpad(.channel(.init(server: fixture.key.server.description,account: fixture.key.accountId,org: fixture.key.orgId,channel: "old-release")))
        _ = await fixture.folders.perform(.member(fixture.launch,channel,true),binding: fixture.binding)
        fixture.sidebar.configureFolderProjection()
        let host = FoldersUIHost(fixture.sidebar); defer { host.close() }; try await host.settle()
        try await eventually { host.labels().contains { $0.contains("Offline · saved chat") } }
        try await eventually { host.elements.contains { ($0.accessibilityValue() as? String)?.contains("Archived · read only") == true } }
        await fixture.provider.removeFolder(.folder(1))
        try await eventually { !fixture.sidebar.folderEntries(fixture.sidebar.snapshot).contains { $0.title == "Work" } }
        XCTAssertTrue(fixture.folders.snapshot.members[fixture.launch]?.contains(.telegram(3)) == true)
        fixture.telegram.receive(.init())
        _ = await fixture.folderStore.perform(.attach(nil,nil),binding: nil)
        try await eventually { fixture.folders.snapshot.binding == nil }
        XCTAssertEqual(fixture.folders.snapshot.catalog.custom.first { $0.id == fixture.launch }?.items.count,5)
        XCTAssertFalse(fixture.folders.snapshot.members[fixture.launch]?.contains(.telegram(3)) == true)
        try await host.settle()
        XCTAssertTrue(host.labels().contains("Telegram is not connected on this Mac."))
        let missing = SidebarItemReference.agentpad(.myAgent(UUID()))
        _ = await fixture.folders.perform(.member(fixture.launch,missing,true),binding: nil)
        try await eventually { host.labels().contains("Unavailable ·") }
        XCTAssertTrue(host.press("Remove"))
        try await eventually { fixture.folders.snapshot.members[fixture.launch]?.contains(missing) == false }
        host.close()
        let prior = TelegramService.settings.snapshot
        defer { TelegramService.settings.receive(prior) }
        var blocked = TelegramSnapshot(); blocked.state = .blocked; blocked.failure = .storage
        TelegramService.settings.receive(blocked)
        let blockedHost = FoldersUIHost(fixture.sidebar)
        defer { blockedHost.close() }; try await blockedHost.settle()
        XCTAssertTrue(blockedHost.labels().contains(TelegramFolderRollback.note))
        XCTAssertTrue(blockedHost.labels().contains(TelegramFailure.storage.message))

        let empty = SidebarCustomFolder(id: UUID(),name: "Empty")
        _ = await fixture.folders.perform(.create(empty.id,name: empty.name,symbol: "folder"),binding: nil)
        let custom = FoldersUIHost(fixture.sidebar.folderBody(.init(id: SidebarEntryIdentity.custom(empty.id),title: empty.name,kind: .custom(empty.id)),snapshot: fixture.sidebar.snapshot),height: 160)
        defer { custom.close() }; try await custom.settle()
        XCTAssertTrue(custom.labels().contains("Right-click a chat, channel, person or agent → Add to folder…"))
        var list = TelegramListSnapshot(key: .main,name: "All chats",icon: "All",visible: true,complete: true,generation: 1,revision: 1,counts: .init(),capacity: 0,expanded: false,windows: [:],collapsedWindows: [])
        let noChats = FoldersUIHost(TelegramListEntryView(list: list,store: fixture.store,model: fixture.telegram,folders: fixture.folders,viewport: .init(),select: { _ in }),height: 120)
        defer { noChats.close() }; try await noChats.settle()
        XCTAssertTrue(noChats.labels().contains("No chats yet · Find a chat ⌘P"))
        list.key = .folder(7); list.complete = false
        let updating = FoldersUIHost(TelegramListEntryView(list: list,store: fixture.store,model: fixture.telegram,folders: fixture.folders,viewport: .init(),select: { _ in }),height: 120)
        defer { updating.close() }; try await updating.settle()
        XCTAssertTrue(updating.labels().contains("No chats")); XCTAssertTrue(updating.labels().contains("Updating…"))
    }
    func testFilterLeavesTelegramAndForeignMembersDoNotLeak() async throws {
        let foreign = SidebarItemReference.agentpad(.person(.init(server: fixture.key.server.description,account: "other",org: "secret",peer: "foreign")))
        _ = await fixture.folders.perform(.member(fixture.launch,foreign,true),binding: fixture.binding)
        fixture.store.chatNavigation.query = "no matching AgentPad item"
        fixture.sidebar.configureFolderProjection()
        try await eventually { fixture.folders.custom[fixture.launch]?.foreign == 1 && fixture.folders.custom[fixture.launch]?.items == [.telegram(3)] }
        let entries = fixture.sidebar.folderEntries(fixture.sidebar.snapshot)
        XCTAssertTrue(entries.contains { $0.title == "Work" }); XCTAssertFalse(entries.contains { $0.kind == .people })
        XCTAssertEqual(fixture.folders.custom[fixture.launch]?.items,[.telegram(3)])
        XCTAssertFalse(fixture.folders.custom[fixture.launch]?.items.contains(foreign) == true)
    }
    func testArrowRoutingNeverOpensAndAllThreeRegionsCycle() async throws {
        let sidebar = fixture.sidebar, entries = sidebar.folderEntries(sidebar.snapshot)
        let work = try XCTUnwrap(entries.first { $0.title == "Work" })
        await fixture.telegram.setViewport(list: .folder(1),windows: [0]); await fixture.telegram.loadPage(list: .folder(1),start: 0)
        fixture.store.chatNavigation.selection = .entry(work.id)
        sidebar.handle(.down,sidebar.snapshot)
        XCTAssertEqual(fixture.store.chatNavigation.selection,.entryItem(entry: work.id,item: "telegram:1"))
        sidebar.handle(.left,sidebar.snapshot)
        XCTAssertEqual(fixture.store.chatNavigation.selection,.entry(work.id))
        let opened = await fixture.provider.opened
        XCTAssertEqual(opened,0)
        XCTAssertEqual(SidebarFocusRegion.next(.attention,backwards: false),.search)
        XCTAssertEqual(SidebarFocusRegion.next(.search,backwards: false),.folders)
        XCTAssertEqual(SidebarFocusRegion.next(.folders,backwards: false),.attention)
        XCTAssertEqual(SidebarFocusRegion.next(.attention,backwards: true),.folders)
        fixture.store.chatNavigation.selection = .entryItem(entry: work.id,item: "telegram:1")
        let host = FoldersUIHost(fixture.sidebar); defer { host.close() }; try await host.settle()
        fixture.store.chatNavigation.focusRequested = true; try await host.settle()
        host.key(48,"\t"); try await host.settle()
        host.key(48,"\t"); try await host.settle()
        XCTAssertTrue(host.window.firstResponder is NSTextView,"Tab reaches the filter after the pinned region")
        host.key(48,"\t"); try await host.settle()
        XCTAssertFalse(host.window.firstResponder is NSTextView)
        fixture.store.chatNavigation.selection = .entry(work.id)
        host.key(125,"\u{F701}"); try await host.settle()
        XCTAssertEqual(fixture.store.chatNavigation.selection,.entryItem(entry: work.id,item: "telegram:1"))
        host.key(36,"\r",modifiers: [.command,.shift])
        try await eventually { SidebarFolderActions.shared.request?.item == .telegram(1) }
        let afterKeys = await fixture.provider.opened
        XCTAssertEqual(afterKeys,0)
    }
    func testFollowHideReadNoticeAndShownInCaption() async throws {
        var row = FoldersUIFixture.rows()[1]; row.lists = [.folder(1),.main]
        XCTAssertEqual(fixture.telegram.shownIn(row),"Shown in: Work · All chats …")
        await fixture.telegram.follow(row)
        let followed = await fixture.provider.chat(row.id)
        XCTAssertTrue(followed?.followEnabled == true)
        await fixture.provider.setReadFailure(); await fixture.telegram.markAsRead(row)
        let host = FoldersUIHost(TelegramReadNoticeView(model: fixture.telegram),width: 350,height: 100)
        defer { host.close() }; try await host.settle()
        XCTAssertTrue(host.labels().contains("Retry")); XCTAssertTrue(host.press("Retry"))
        try await eventually { await fixture.provider.readCalls == 2 }
        await fixture.telegram.mode(row,.hidden)
        let hidden = await fixture.provider.chat(row.id)
        XCTAssertTrue(hidden?.hidden == true)
        XCTAssertFalse(hidden?.followEnabled == true)
        row.kind = .forum; XCTAssertFalse(row.canMarkAsRead)
    }
    func testComposerAndQuickOpenCommandShiftReturnPresentGenericChooser() async throws {
        let row = FoldersUIFixture.rows()[2]
        let session = try XCTUnwrap(fixture.store.openToolTab(.telegram(row.id)))
        let state = try XCTUnwrap(session.tabState)
        let conversation = TelegramConversationModel(id: row.id)
        var snapshot = TelegramConversationSnapshot(destination: row.id)
        snapshot.connected = true; snapshot.capabilities.canRead = true; snapshot.capabilities.canSend = true
        snapshot.title = row.title; snapshot.kind = row.kind
        conversation.receive(snapshot); conversation.provider = ConversationUIFake()
        state.telegramModel = conversation; state.telegramRow = row
        let composer = FoldersUIHost(TelegramConversationView(state: state,id: row.id,chats: fixture.telegram,applicationInteractive: { true }),width: 600,height: 440)
        defer { composer.close() }
        try await composer.settle()
        let editors = composer.descendants().compactMap { $0 as? ChatMentionEditor.Editor }
        let editor = try XCTUnwrap(editors.first)
        composer.window.makeFirstResponder(editor); try await composer.settle()
        XCTAssertTrue(composer.window.isKeyWindow)
        XCTAssertTrue(NavigationPresentationGate.allowsAcknowledgement(editor,appActive: true))
        // A directly delivered editor event can follow a mouse event in AppKit.
        // isARepeat is only valid on a key event, even for synthetic input.
        let pointer = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,location: .zero,modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: composer.window.windowNumber,context: nil,
            eventNumber: 0,clickCount: 0,pressure: 0))
        NSApp.postEvent(pointer,atStart: true)
        let queued = try XCTUnwrap(NSApp.nextEvent(matching: .mouseMoved,until: .distantPast,inMode: .default,dequeue: true))
        NSApp.sendEvent(queued)
        XCTAssertEqual(NSApp.currentEvent?.type,.mouseMoved)
        editor.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: [.command,.shift],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: composer.window.windowNumber,context: nil,characters: "\r",charactersIgnoringModifiers: "\r",isARepeat: false,keyCode: 36)))
        try await eventually { SidebarFolderActions.shared.request?.item == .telegram(3) }
        XCTAssertEqual(SidebarFolderActions.shared.request?.binding,fixture.binding)
        XCTAssertTrue(conversation.draft.isEmpty)
        SidebarFolderActions.shared.request = nil; composer.close()

        let telegram = TelegramSearchModel(chats: fixture.telegram)
        let search = EverywhereSearchModel(messages: .init(context: { nil },availability: { .noTeam },fetch: { _, _ in
            XCTFail("Folder UI must not use a server"); return .init(hits: [],next: nil)
        }),indexing: .init(index: ConversationIndex(directory: fixture.root.appendingPathComponent("search"),roots: [:])),
            catalog: .init(scan: { _ in .init(records: [],scanned: 0,total: 0,skipped: 0) }),
            names: SessionNames(url: fixture.root.appendingPathComponent("names.sqlite")),profiles: fixture.store.agentProfiles,telegram: telegram)
        fixture.store.searchModel = search
        let router = TabRouter(); router.stores = { [self.fixture.store] }
        search.openTelegram = { hit, beside, add in
            Task { if await telegram.open(hit,from: self.fixture.store,beside: beside,addToFolder: add,router: router) { search.dismiss() } }
        }
        let host = FoldersUIHost(SearchEverywhereField(store: fixture.store,model: search),width: 600,height: 80)
        defer { host.close() }; try await host.settle()
        search.source = .telegram; search.begin()
        try await eventually { host.window.firstResponder is NSTextView && !search.choices.isEmpty }
        search.selected = "t:" + TelegramSearchHit(row: row).id
        XCTAssertTrue(host.window.performKeyEquivalent(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: [.command,.shift],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: host.window.windowNumber,context: nil,characters: "\r",charactersIgnoringModifiers: "\r",isARepeat: false,keyCode: 36))))
        try await eventually { SidebarFolderActions.shared.request?.item == .telegram(3) }
        XCTAssertEqual(fixture.store.active?.activeSession?.toolRoute,.telegram(row.id))
        XCTAssertEqual(SidebarFolderActions.shared.request?.windowID,fixture.store.windowID)
    }
    func testTwoSidebarWindowsShareFivePageBudgetAndReleaseIndependently() async throws {
        for _ in 0..<10 { await fixture.telegram.expand(.main) }
        let first = UUID(), second = UUID()
        fixture.telegram.folderViewport([.init(list: .main,start: 0),.init(list: .main,start: 50),.init(list: .main,start: 100)],owner: first)
        try await eventually { fixture.telegram.listPages[.main]?[100] != nil }
        fixture.telegram.folderViewport([.init(list: .folder(1),start: 0),.init(list: .folder(2),start: 0),.init(list: .archive,start: 0)],owner: second)
        try await eventually { fixture.telegram.listPages[.archive]?[0] != nil }
        let maximum = await fixture.provider.maximumWindows
        XCTAssertEqual(maximum,5)
        fixture.telegram.folderViewport([],owner: second)
        try await eventually { fixture.telegram.listPages[.main]?[100] != nil && fixture.telegram.listPages[.archive]?.isEmpty != false }
        XCTAssertNotNil(fixture.telegram.listPages[.main]?[0])
    }
    func testNativeFiveMockupStatesInBothThemes() async throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTPAD_FOLDERS_CAPTURE"] else { throw XCTSkip("Opt-in native folder captures") }
        for dark in [false,true] {
            AgentPadSettingsModel.testModel = AgentPadSettingsModel(read: { ["appearance":["mode":dark ? "dark" : "light"]] },write: { _ in },appliesRuntimeEffects: false)
            for state in ["overview","scrolled","add-to-folder","folders-sheet","not-connected"] {
                let f = try FoldersUIFixture(); try await f.start(); defer { f.close() }
                if state != "not-connected" { _ = f.store.openToolTab(.telegram(FoldersUIFixture.rows()[2].id)) }
                if state == "scrolled" { await f.telegram.expand(.main); await f.telegram.expand(.main) }
                if state == "not-connected" {
                    f.telegram.receive(.init())
                    _ = await f.folderStore.perform(.attach(nil,nil),binding: nil)
                }
                if state == "folders-sheet" {
                    _ = await f.folders.perform(.move(SidebarEntryIdentity.custom(f.clients),3),binding: f.binding)
                    _ = await f.folders.perform(.move(SidebarEntryIdentity.custom(f.pins),4),binding: f.binding)
                    f.folders.editing = f.clients
                }
                let content = snapshotContent(f,state: state)
                let host = FoldersUIHost(content,width: state == "folders-sheet" ? 820 : state == "add-to-folder" ? 820 : 268,height: 930,dark: dark)
                defer { host.close() }; try await host.settle()
                if state == "scrolled", let scroll = host.scrolls().max(by: { $0.frame.height < $1.frame.height }) {
                    scroll.contentView.scroll(to: NSPoint(x: 0,y: 560)); scroll.reflectScrolledClipView(scroll.contentView); try await host.settle()
                }
                if ["overview","folders-sheet","add-to-folder"].contains(state) {
                    try await eventually { f.telegram.customRows[3] != nil && f.folders.custom[f.launch]?.rows.count == 5 }
                    try await host.settle()
                    XCTAssertTrue(host.labels().contains { $0.hasPrefix("Harbor release, Supergroup,") })
                    XCTAssertTrue(host.labels().contains("#launch"))
                }
                if state == "scrolled" {
                    try await eventually { f.telegram.listPages[.main]?[0]?.rows.isEmpty == false }
                    try await host.settle()
                    XCTAssertTrue(host.labels().contains { $0.hasPrefix("Ellis Fen, Private chat,") })
                }
                if state == "not-connected" {
                    try await eventually { f.folders.custom[f.launch]?.rows.count == 4 }
                    try await host.settle()
                    XCTAssertTrue(host.labels().contains("#launch"))
                }
                XCTAssertTrue(host.labels().contains { $0.hasPrefix("Needs attention, pinned,") })
                try host.png(URL(fileURLWithPath: output).appendingPathComponent("\(state)-\(dark ? "dark" : "light").png"))
            }
        }
    }
    @ViewBuilder func snapshotContent(_ f: FoldersUIFixture, state: String) -> some View {
        HStack(alignment: .top,spacing: 14) {
            f.sidebar.frame(width: 268)
            if state == "folders-sheet" {
                FoldersSheet(model: f.folders,entries: f.sidebar.folderEntries(f.sidebar.snapshot,includeHidden: true),telegram: f.telegram,dismiss: {}).padding(.top,24)
            }
            if state == "add-to-folder" {
                HStack(alignment: .top,spacing: 10) {
                    VStack(alignment: .leading,spacing: 10) {
                        TelegramFolderRow(row: FoldersUIFixture.rows()[2],store: f.store,model: f.telegram,folders: f.folders,entryID: "work").menu
                    }.font(Theme.display(11)).buttonStyle(.plain).padding(12).frame(width: 226)
                        .background(Theme.chromeBackground,in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.chromeHairline))
                    AddToFolderChooser(request: .init(item: .telegram(3),binding: f.binding,windowID: f.store.windowID,anchor: "work"),model: f.folders,dismiss: {})
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.chromeHairline))
                }.padding(.top,260)
                Spacer(minLength: 0)
            }
        }
    }
}
