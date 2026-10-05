import XCTest
@testable import AgentPadKit

/// A channel tab (DESIGN-F2, V1): saved, restored without a terminal
/// process, duplicated, moved, closed and reopened — its channel's name kept
/// nowhere with it.
@MainActor
final class ChatTabTests: XCTestCase {
    private let ref = ChannelRef(server: "https://chat.example.com", account: "a1", org: "o1", channel: "c1")

    private func store(_ persistence: InMemoryPersistence, spawned: @escaping () -> Void = {}, peers: @escaping @MainActor () -> [WorkspaceStore] = { [] }) -> WorkspaceStore {
        WorkspaceStore(persistence: persistence, engineFactory: { spawned(); return TestEngine() },
                       optionsProvider: { _ in nil }, resumeProvider: { true }, peerStores: peers)
    }

    private func tabs(_ state: PersistedState) -> [PersistedTab] {
        func walk(_ node: PersistedPaneNode) -> [PersistedTab] {
            switch node.kind {
            case .pane(let p): return p.tabs
            case .split(_, let a, let b, _): return walk(a) + walk(b)
            }
        }
        return state.workspaces.flatMap { walk($0.root) }
    }

    func testRestoredWithoutAProcessAndWithoutAName() throws {
        let first = InMemoryPersistence()
        let a = store(first)
        let ws = a.workspaces[0]
        let terminals = ws.root.allPanes.flatMap(\.tabs).count
        a.addTab(in: ws)
        let channel = a.openChannelTab(ref, in: ws)
        channel.customTitle = "#secret-name"
        a.flushPersistence()
        let saved = try XCTUnwrap(first.saved)
        let persisted = try XCTUnwrap(tabs(saved).first { $0.channel == ref })
        XCTAssertNil(persisted.customTitle, "no title kept for a channel tab")
        let data = try JSONEncoder().encode(saved)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret-name"))

        var spawns = 0
        let b = store(InMemoryPersistence(initial: try JSONDecoder().decode(PersistedState.self, from: data)), spawned: { spawns += 1 })
        let restored = b.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }
        let tab = try XCTUnwrap(restored.first { $0.id == channel.id })
        XCTAssertEqual(tab.channel, ref)
        XCTAssertNil(tab.customTitle)
        XCTAssertEqual((tab.engine as? ChannelTabEngine)?.starts, 0)
        XCTAssertEqual(spawns, terminals + 1, "engines only for terminal tabs")
        XCTAssertEqual(tab.title, "Channel", "no name before its card may be seen")
        XCTAssertEqual(tab.agent.id, AgentTemplate.terminal.id, "nothing to publish as an agent")
        XCTAssertNil(tab.conversationId)
    }

    func testStateFrom106ReadsAsTerminals() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","agentId":"terminal","currentDirectoryPath":"/tmp"}"#
        XCTAssertNil(try JSONDecoder().decode(PersistedTab.self, from: Data(json.utf8)).channel)
    }

    func testRenameIsRefused() {
        let a = store(InMemoryPersistence())
        let channel = a.openChannelTab(ref, in: a.workspaces[0])
        a.renameTab(channel, to: "mine")
        XCTAssertNil(channel.customTitle)
    }

    /// ⌘⇧T brings a channel back a channel, with no title kept.
    func testReopenedAsAChannel() throws {
        let a = store(InMemoryPersistence())
        let ws = a.workspaces[0]
        let channel = a.openChannelTab(ref, in: ws)
        a.closeTab(channel, in: ws)
        let back = try XCTUnwrap(a.reopenLastClosedTab())
        XCTAssertEqual(back.channel, ref)
        XCTAssertTrue(back.engine is ChannelTabEngine)
        XCTAssertNil(back.customTitle)
    }

    /// The open tab of a channel is found by the whole ref (review F2b-3).
    func testShowChannelFindsTheTabByTheWholeRef() throws {
        let a = store(InMemoryPersistence())
        let ws = a.workspaces[0]
        let opened = try XCTUnwrap(a.showChannel(ref))
        XCTAssertTrue(a.showChannel(ref) === opened, "brought forward, not opened again")
        var otherAccount = ref
        otherAccount.account = "a2"
        XCTAssertFalse(a.showChannel(otherAccount) === opened)
        XCTAssertFalse(a.showChannel(ref, newTab: true) === opened)
        XCTAssertEqual(ws.root.allPanes.flatMap(\.tabs).filter { $0.channel != nil }.count, 3)
    }

    func testDuplicateMoveAndClose() throws {
        var stores: [WorkspaceStore] = []
        let a = store(InMemoryPersistence(), peers: { stores })
        let b = store(InMemoryPersistence(), peers: { stores })
        stores = [a, b]
        let wsA = a.workspaces[0], wsB = b.workspaces[0]
        let moving = a.openChannelTab(ref, in: wsA)
        let copy = try XCTUnwrap(a.duplicateTab(moving, in: wsA))
        XCTAssertEqual(copy.channel, ref)
        XCTAssertNotEqual(copy.id, moving.id)
        let target = try XCTUnwrap(wsB.root.firstPane)
        XCTAssertTrue(b.handleTabDrop(droppedId: moving.id, to: target, at: target.tabs.count, in: wsB))
        XCTAssertTrue(target.tabs.contains { $0 === moving })
        XCTAssertEqual((moving.engine as? ChannelTabEngine)?.terminations, 0)
        // The tab's own Close.
        (moving.engine as? ChannelTabEngine)?.onClose()
        XCTAssertFalse(target.tabs.contains { $0 === moving })
    }

    /// The state path of a debug build is read only under `#if DEBUG`.
    func testDebugStatePathIsDebugOnly() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentPadKit/Sessions/Persistence.swift")
        let lines = try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")
        var depth = 0, found = 0
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "#if DEBUG" { depth += 1 } else if t == "#endif", depth > 0 { depth -= 1 }
            if line.contains("AGENTPAD_DEBUG_STATE_PATH") && !t.hasPrefix("//") {
                found += 1
                XCTAssertGreaterThan(depth, 0, "read outside #if DEBUG: \(t)")
            }
        }
        XCTAssertEqual(found, 1)
    }

    // MARK: Review F2, round 2: no title kept by a reader

    /// Close goes to the store holding the tab now, also once the store it
    /// was made in is gone (review F2b-p2-3).
    func testCloseAfterTheFirstWindowIsGone() throws {
        var stores: [WorkspaceStore] = []
        var a: WorkspaceStore? = store(InMemoryPersistence(), peers: { stores })
        let b = store(InMemoryPersistence(), peers: { stores })
        stores = [a!, b]
        let moving = a!.openChannelTab(ref, in: a!.workspaces[0])
        let target = try XCTUnwrap(b.workspaces[0].root.firstPane)
        XCTAssertTrue(b.handleTabDrop(droppedId: moving.id, to: target, at: target.tabs.count, in: b.workspaces[0]))
        stores = [b]
        a = nil
        (moving.engine as? ChannelTabEngine)?.onClose()
        XCTAssertFalse(target.tabs.contains { $0 === moving })
    }

    /// The Dock's tab submenu takes each title when it shows (review F2b-p1-2).
    func testDockSubmenuReadsTitlesWhenShown() {
        let a = store(InMemoryPersistence())
        let tab = a.addTab(in: a.workspaces[0])
        a.renameTab(tab, to: "first")
        let filler = DockTabMenuFiller(sessions: [{ [weak tab] in tab }]) { title, _ in NSMenuItem(title: title, action: nil, keyEquivalent: "") }
        let menu = NSMenu()
        filler.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.title), ["first"])
        a.renameTab(tab, to: "second")
        filler.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.title), ["second"])
    }

    @Observable final class Titles { var all: [String] = []; var other = 0 }

    /// The palette's watch fires when the titles change, not on any change
    /// of what they are read from (review F2b-p1-1).
    func testPaletteWatchFiresOnlyWhenTitlesChange() async throws {
        let titles = Titles()
        titles.all = ["#secret"]
        var fired = 0
        let watch = TitleWatch(read: { _ = titles.other; return titles.all }) { fired += 1 }
        titles.other += 1
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fired, 0)
        titles.all = ["Channel"]
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fired, 1)
        withExtendedLifetime(watch) {}
    }

    /// An open Dock submenu closes once its titles change (review F2c-p2-1).
    func testAnOpenDockSubmenuClosesWhenATitleChanges() async throws {
        let a = store(InMemoryPersistence())
        let tab = a.addTab(in: a.workspaces[0])
        a.renameTab(tab, to: "first")
        let filler = DockTabMenuFiller(sessions: [{ [weak tab] in tab }]) { title, _ in NSMenuItem(title: title, action: nil, keyEquivalent: "") }
        var cancelled = 0
        filler.cancel = { _ in cancelled += 1 }
        let menu = NSMenu()
        filler.menuNeedsUpdate(menu)
        filler.menuWillOpen(menu)
        a.renameTab(tab, to: "second")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(cancelled, 1)
        filler.menuDidClose(menu)
        a.renameTab(tab, to: "third")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(cancelled, 1, "closed: no longer watched")
    }
}
