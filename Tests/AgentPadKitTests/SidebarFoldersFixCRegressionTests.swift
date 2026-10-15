import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

extension SidebarFoldersUITests {
    func testCMetadataRefreshesCustomOrderCountsAttentionAndHiddenRowsWithoutStoreViewport() async throws {
        let id = UUID(), binding = fixture.binding
        _ = await fixture.folders.perform(.create(id, name: "Live metadata", symbol: "folder"), binding: binding)
        for chat in [Int64(2), 3] { _ = await fixture.folders.perform(.member(id, .telegram(chat), true), binding: binding) }
        _ = await fixture.folderStore.perform(.refreshTelegram, binding: binding)
        fixture.folders.viewport([id: 0..<8])
        try await eventually { fixture.folders.custom[id]?.rows.count == 2 }
        XCTAssertEqual(fixture.folders.custom[id]?.items, [.telegram(2), .telegram(3)])
        let before = await fixture.folderStore.current()
        XCTAssertTrue(before.rows.isEmpty, "The UI's projection ranges do not materialise store snapshot rows")
        var latest = FoldersUIFixture.rows()[2]
        latest.lastMessageDate += 10_000
        await fixture.folderStore.updateTelegramRows([latest], binding: binding)
        try await eventually { fixture.folders.custom[id]?.items.first == .telegram(3) }
        var read = FoldersUIFixture.rows()[1]
        read.unreadCount = 0; read.attention = nil
        latest.unreadCount = 0
        await fixture.folderStore.updateTelegramRows([read, latest], binding: binding)
        try await eventually { fixture.folders.custom[id]?.unread == 0 && fixture.folders.custom[id]?.attention == false }
        latest.hidden = true
        await fixture.folderStore.updateTelegramRows([latest], binding: binding)
        try await eventually { fixture.folders.custom[id]?.items == [.telegram(2)] }
        XCTAssertNil(fixture.folders.custom[id]?.rows[.telegram(3)], "Don't show must remove the layout slot, too")
        let after = await fixture.folderStore.current()
        XCTAssertGreaterThan(after.revision, before.revision)
        XCTAssertTrue(after.members[id]?.contains(.telegram(3)) == true, "Hiding preserves membership")
        await fixture.folderStore.updateTelegramRows([read, latest], binding: binding)
        let unchanged = await fixture.folderStore.current()
        XCTAssertEqual(unchanged.revision, after.revision)
    }

    func testCSidebarRedrawDoesNotReadSessionHistoryWithNoCustomFolders() async throws {
        for folder in fixture.folders.snapshot.catalog.custom {
            _ = await fixture.folders.perform(.delete(folder.id), binding: fixture.binding)
        }
        fixture.store.setEntryCollapsed("myAgents", true)
        let host = FoldersUIHost(fixture.sidebar)
        defer { host.close() }
        try await host.settle()
        var historyReads = 0
        fixture.store.conversationVisibility = { historyReads += 1; return .init(channelIds: []) }
        for query in ["Launch", "", "Lea", ""] {
            fixture.store.chatNavigation.query = query
            try await host.settle()
        }
        XCTAssertEqual(historyReads, 0, "Filtering/redrawing the sidebar must not build and sort profile histories for folder metadata")
    }

    func testCSingleHookChangeWithCustomFoldersHasBoundedMetadataReads() async throws {
        fixture.folders.viewport([fixture.launch: 0..<8])
        let profile = fixture.store.agentProfiles.profiles[0]
        let ref = SidebarItemReference.agentpad(.myAgent(profile.id))
        let catalog = fixture.store.sessionDisplaySources.catalog
        let source = try XCTUnwrap(fixture.folders.summarySource)
        var sessions: [Session] = []
        for size in [8, 64] {
            for index in sessions.count..<size {
                let session = try fixture.store.startAgentProfile(profile.id).get()
                session.conversationId = "bounded-\(index)"
                try fixture.store.agentProfiles.bind(.init(agentId: profile.rosterID, conversationId: "bounded-\(index)",
                    title: "History", cwd: profile.folder, lastActivity: .distantPast), to: profile.id)
                sessions.append(session)
            }
            var view = fixture.org.view
            view.channels += (view.channels.count..<size).map {
                .init(channelId: "bounded-\($0)", teamId: "aster", name: "Channel \($0)", createdBy: "me", archived: false, version: 1)
            }
            fixture.org.set(view)
            let date = Date(timeIntervalSince1970: 2_000_000_000 + Double(size))
            sessions[0].hookStateAt = date
            try await eventually { fixture.folders.custom[self.fixture.launch]?.rows[ref]?.activity == date }
            await source.delivery?.value
            let before = catalog.recordReadCount
            let liveReads = source.sessionReadCount, chatReads = source.chatReadCount
            sessions[0].hookStateAt = date.addingTimeInterval(1)
            try await eventually { fixture.folders.custom[self.fixture.launch]?.rows[ref]?.activity == date.addingTimeInterval(1) }
            let reads = catalog.recordReadCount - before
            XCTAssertLessThanOrEqual(reads, 1, "One hook update must not reread \(size) bindings and live sessions (read \(reads))")
            XCTAssertEqual(source.sessionReadCount - liveReads, 1)
            XCTAssertEqual(source.chatReadCount - chatReads, 0)
            print("Folder hook regression: \(size) sessions/channels, \(reads) catalog reads")
        }
    }

    func testCDeletingSelectedFolderKeepsNeighbourAndKeyboardFocus() async throws {
        let host = FoldersUIHost(FoldersSheet(model: fixture.folders,
            entries: fixture.sidebar.folderEntries(fixture.sidebar.snapshot, includeHidden: true), telegram: fixture.telegram, dismiss: {}), width: 520, height: 650)
        defer { host.close() }
        try await host.settle()
        XCTAssertTrue(host.press("New folder"))
        try await eventually { fixture.folders.editing != nil }
        let id = try XCTUnwrap(fixture.folders.editing)
        try await host.settle(); host.key(36, "\r")
        try await eventually { fixture.folders.editing == nil }
        try await host.settle(); host.key(51, "\u{8}", modifiers: .command)
        try await eventually { fixture.folders.deleting?.id == id }
        try await host.settle(); host.press("Delete")
        try await eventually { fixture.folders.snapshot.catalog.tombstones.contains(id) }
        try await host.settle()
        let neighbour = try XCTUnwrap(fixture.folders.snapshot.catalog.order.first)
        host.key(49, " ")
        try await eventually { fixture.folders.snapshot.catalog.hidden.contains(neighbour) }
        host.key(125, "\u{F701}"); try await host.settle()
        host.key(49, " ")
        try await eventually { fixture.folders.snapshot.catalog.hidden.contains(SidebarEntryIdentity.people(fixture.key)) }
    }

    func testCChooserArrowSelectionStaysVisibleAndAccessible() async throws {
        for n in 0..<24 {
            _ = await fixture.folders.perform(.create(UUID(), name: String(format: "Folder %02d", n), symbol: "folder"), binding: fixture.binding)
        }
        let host = FoldersUIHost(AddToFolderChooser(request: .init(item: .telegram(3), binding: fixture.binding,
            windowID: fixture.store.windowID, anchor: nil), model: fixture.folders, dismiss: {}), width: 308, height: 440)
        defer { host.close() }; try await host.settle()
        for _ in 0..<20 { host.key(125, "\u{F701}"); try await Task.sleep(for: .milliseconds(15)) }
        try await host.settle()
        let row = try XCTUnwrap(host.elements.first { $0.accessibilityLabel() == "Folder 19" })
        let scroll = try XCTUnwrap(host.scrolls().first)
        let visible = host.window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        XCTAssertGreaterThanOrEqual(row.accessibilityFrame().minY, visible.minY - 1)
        XCTAssertLessThanOrEqual(row.accessibilityFrame().maxY, visible.maxY + 1)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        // VoiceOver focus is platform-gated when VoiceOver is off. The selected
        // trait exposes the same row through the native accessibility tree.
        XCTAssertTrue((row.object.value(forKey: "accessibilitySelected") as? Bool) == true)
        host.key(49, " ")
        let id = try XCTUnwrap(fixture.folders.snapshot.catalog.custom.first { $0.name == "Folder 19" }?.id)
        try await eventually { fixture.folders.snapshot.members[id]?.contains(.telegram(3)) == true }
    }

    func testCRetryControlCompletesPartialDeleteAndPreservesOriginalBinding() async throws {
        await fixture.provider.setTombstoneFailure(true)
        let success = await fixture.folders.perform(.delete(fixture.launch), binding: fixture.binding)
        XCTAssertFalse(success)
        XCTAssertTrue(fixture.folders.snapshot.catalog.tombstones.contains(fixture.launch))
        let remaining = await fixture.provider.members[fixture.launch]
        XCTAssertNotNil(remaining, "Catalog deletion succeeded but provider cleanup failed")
        let host = FoldersUIHost(fixture.sidebar.folderFooter, width: 400, height: 150)
        defer { host.close() }; try await host.settle()
        // A reconnect must not retarget the failed operation to the new profile.
        let other = TelegramProfileBinding(environment: .test, account: 99, connectionID: UUID())
        let replacement = FoldersUIProvider(snapshot: .init(), rows: [:])
        _ = await fixture.folderStore.perform(.attach(replacement, other), binding: other)
        try await eventually { fixture.folders.snapshot.binding == other }
        let attempts = await replacement.tombstoneAttempts
        XCTAssertTrue(host.press("Retry"), "Retry must be an actionable control")
        try await host.settle()
        let retriedAttempts = await replacement.tombstoneAttempts
        XCTAssertEqual(attempts, retriedAttempts, "Retry must keep the original binding")
        XCTAssertNotNil(fixture.folders.error)
        // Reattach the origin while still failing, then let Retry finish cleanup.
        _ = await fixture.folderStore.perform(.attach(fixture.provider, fixture.binding), binding: fixture.binding)
        try await eventually { fixture.folders.snapshot.binding == fixture.binding }
        await fixture.provider.setTombstoneFailure(false)
        try await host.settle(); XCTAssertTrue(host.press("Retry"))
        try await eventually { await fixture.provider.members[fixture.launch] == nil }
        try await eventually { fixture.folders.error == nil }
    }

    func testCInboxArrowRowsHaveVisibleFocusBorders() async throws {
        let entry = SidebarEntryIdentity.team(fixture.key, team: "aster")
        fixture.store.setEntryCollapsed(entry, false)
        let host = FoldersUIHost(fixture.sidebar)
        defer { host.close() }; try await host.settle()
        fixture.store.chatNavigation.focusRequested = true
        try await host.settle()
        let scroll = try XCTUnwrap(host.scrolls().max { $0.frame.height < $1.frame.height })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await host.settle()
        fixture.store.chatNavigation.selection = .entry(entry)
        for (kind, name) in [("unread", "Unread"), ("mentions", "Mentions")] {
            host.key(125, "\u{F701}"); try await host.settle()
            XCTAssertEqual(fixture.store.chatNavigation.selection, .entryItem(entry: entry, item: "inbox:\(kind)"))
            try await eventually {
                guard let row = host.elements.first(where: { $0.accessibilityLabel() == name }) else { return false }
                let visible = host.window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                return row.accessibilityFrame().minY >= visible.minY - 1 && row.accessibilityFrame().maxY <= visible.maxY + 1
            }
            let row = try XCTUnwrap(host.elements.first { $0.accessibilityLabel() == name })
            let visible = host.window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            XCTAssertGreaterThanOrEqual(row.accessibilityFrame().minY, visible.minY - 1)
            XCTAssertLessThanOrEqual(row.accessibilityFrame().maxY, visible.maxY + 1)
            var frame = host.view.convert(host.window.convertFromScreen(row.accessibilityFrame()), from: nil)
            if !host.view.isFlipped { frame.origin.y = host.view.bounds.height - frame.maxY }
            let bitmap = try host.bitmap()
            let scale = CGFloat(bitmap.pixelsWide) / host.view.bounds.width
            var blue = 0
            for x in max(0, Int(frame.minX * scale))..<min(bitmap.pixelsWide, Int(frame.maxX * scale)) {
                for y in max(0, Int(frame.minY * scale))..<min(bitmap.pixelsHigh, Int(frame.maxY * scale)) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.blueComponent > color.redComponent + 0.15 && color.greenComponent > color.redComponent + 0.04 { blue += 1 }
                }
            }
            XCTAssertGreaterThan(blue, 150, "The routed \(name) row needs the same visible focus border as other rows")
        }
    }
}
