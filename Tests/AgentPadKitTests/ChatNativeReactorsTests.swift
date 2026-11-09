import AppKit
import AgentPadQuietTestSupport
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor final class ChatNativeReactorsTests: XCTestCase {
    private var fixtures: [ChatNativeActionFixture] = []
    private var syncs: [ChatSync] = []
    private let defaultTooltip = "Who reacted · right-click for the full list"

    override func tearDown() async throws {
        syncs.forEach { $0.stop() }; syncs = []
        for fixture in fixtures.reversed() { await fixture.close() }
        fixtures = []
    }
    private func fixture(count: Int = 1) async throws -> ChatNativeActionFixture {
        let fixture = try await ChatNativeActionFixture(count: count)
        fixtures.append(fixture)
        try await fixture.connectSocket()
        let sync = ChatSync(key: fixture.base.key, store: fixture.base.store,
            api: ChatAPI(server: fixture.base.key.server, protocolClasses: [ChatStubProtocol.self]),
            socket: try XCTUnwrap(fixture.base.service.socket), outbox: nil, token: "test-only")
        fixture.base.service.orgSessions[fixture.base.key]?.sync = sync
        sync.b1.configure(["chat.reactions"]); sync.b1.resume(); syncs.append(sync)
        let account = fixture.base.key.accountId
        ChatStubProtocol.reset { request, _ in
            guard request.url?.path.hasSuffix("/reactions") == true else { return .failure(URLError(.unsupportedURL)) }
            return .success(.init(status: 200, body: Data("{\"as_of_seq\":10,\"account_ids\":[\"\(account)\",\"former-member\"],\"next\":\"page-2\"}".utf8)))
        }
        for message in fixture.messages { try metadata(fixture, id: message.id, count: 2) }
        try await fixture.settle()
        return fixture
    }
    private func metadata(_ fixture: ChatNativeActionFixture, id: String, count: Int) throws {
        let value = ChatB1.Metadata(messageId: id, deleted: false,
            reactions: [.init(emoji: "👍", count: count, mine: false)], pin: nil)
        try fixture.base.write("INSERT INTO b1_metadata (channel_id, message_id, data, dirty) VALUES (?, ?, ?, 0) ON CONFLICT(message_id) DO UPDATE SET data = excluded.data, ticket = ticket + 1",
            [fixture.model.channel, id, try ChatB1.encode(value)])
    }
    private func chip(in cell: ChatNativeShellCell) throws -> NSButton {
        try XCTUnwrap(cell.metadata.parityControls.first { $0.id == "w07/metadata/reaction/👍/chip" }?.view as? NSButton)
    }
    private func event(for chip: NSButton, fixture: ChatNativeActionFixture) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
            location: chip.convert(CGPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.host.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    private func rebind(_ cell: ChatNativeShellCell, to id: String, fixture: ChatNativeActionFixture) throws {
        let snapshot = try XCTUnwrap(fixture.coordinator.snapshot)
        let index = try XCTUnwrap(fixture.coordinator.messageIndex(id))
        let row = snapshot.rows[index], plan = try XCTUnwrap(fixture.coordinator.layoutPlan(at: index))
        cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: plan,
            content: fixture.coordinator.layoutEngine.content(row, snapshot: snapshot, width: plan.width), actions: fixture.adapter.actions)
        cell.configureActions(row: row, snapshot: snapshot, actions: fixture.adapter.actions,
            layer: try XCTUnwrap(fixture.coordinator.tableView.documentLayer))
        cell.setMediaVisible(true); cell.layoutSubtreeIfNeeded()
    }
    private var reactorReads: Int { ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/reactions") == true }.count }
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
    private func renameMember(_ name: String, fixture: ChatNativeActionFixture) async throws {
        let snapshot = fixture.adapter.snapshot(model: fixture.model, root: nil,
            members: [.init(accountId: fixture.base.key.accountId, handle: "anna", name: name, role: "owner")],
            mentionable: [(fixture.base.key.accountId, "anna")], me: fixture.base.key.accountId,
            archived: fixture.model.feed.archived, ownerModel: nil,
            style: ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
                increasedContrast: false, alwaysShowTime: false))
        fixture.coordinator.actions = fixture.adapter.actions; fixture.view.update(snapshot)
        try await fixture.host.settle()
    }

    func testHoverNamesRefreshForDirectoryAndVersionWithoutRefetchLoop() async throws {
        let fixture = try await fixture(), id = fixture.messages[0].id
        let cell = try fixture.row(id), chip = try chip(in: cell), event = try event(for: chip, fixture: fixture)
        chip.mouseEntered(with: event)
        try await eventually { chip.toolTip == "Anna, Former member…" }
        XCTAssertEqual(fixture.adapter.actions?.reactorAccounts, [id: Set([fixture.base.key.accountId, "former-member"])])
        XCTAssertEqual(reactorReads, 1)
        try await renameMember("Annabelle", fixture: fixture)
        XCTAssertTrue(try self.chip(in: cell) === chip)
        XCTAssertEqual(chip.toolTip, "Annabelle, Former member…")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(reactorReads, 1, "A loaded reactor's directory rename must not cause another network read")
        try fixture.base.write("UPDATE b1_metadata SET ticket = ticket + 1 WHERE message_id = ?", [id])
        try await eventually { self.reactorReads == 2 && chip.toolTip == "Annabelle, Former member…" }
        XCTAssertEqual(fixture.adapter.actions?.reactorAccounts, [id: Set([fixture.base.key.accountId, "former-member"])])
        chip.mouseExited(with: event)
        XCTAssertEqual(chip.toolTip, defaultTooltip)
        XCTAssertEqual(fixture.adapter.actions?.reactorAccounts, [:])
        fixture.base.service.orgSessions[fixture.base.key]?.snapshotOwed = true
        chip.mouseEntered(with: event)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(chip.toolTip, defaultTooltip)
        XCTAssertEqual(reactorReads, 2, "Current access loss prevents a new hover fetch")
        XCTAssertNil(APQuietFailure())
    }

    func testRetainedMenuAndLateHoverResponseCannotTargetReboundRow() async throws {
        let fixture = try await fixture(count: 2), firstID = fixture.messages[0].id, secondID = fixture.messages[1].id
        let cell = try fixture.row(firstID), formerChip = try chip(in: cell), event = try event(for: formerChip, fixture: fixture)
        let menu = try XCTUnwrap(formerChip.menu(for: event))
        let formerPopup = try XCTUnwrap(cell.metadata.parityPopovers["👍"])
        ChatStubProtocol.delay = 0.25
        formerChip.mouseEntered(with: event)
        try await eventually { self.reactorReads == 1 }
        try rebind(cell, to: secondID, fixture: fixture)
        let currentChip = try chip(in: cell), currentPopup = try XCTUnwrap(cell.metadata.parityPopovers["👍"])
        menu.performActionForItem(at: 0)
        XCTAssertFalse(formerPopup.popover.isShown)
        XCTAssertFalse(currentPopup.popover.isShown)
        XCTAssertFalse(NavigationPresentationGate.obscures(fixture.host.window))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(formerChip.toolTip)
        XCTAssertEqual(currentChip.toolTip, defaultTooltip)
        XCTAssertEqual(fixture.adapter.actions?.reactorAccounts, [:])
        XCTAssertEqual(reactorReads, 1)
        XCTAssertNil(APQuietFailure())
    }

    func testCurrentMenuSurvivesCountChangeAndAccessLossClosesPopup() async throws {
        let fixture = try await fixture(), id = fixture.messages[0].id
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let cell = try fixture.row(id), chip = try chip(in: cell), event = try event(for: chip, fixture: fixture)
        let menu = try XCTUnwrap(chip.menu(for: event))
        try metadata(fixture, id: id, count: 3)
        try await fixture.settle()
        XCTAssertTrue(try self.chip(in: cell) === chip)
        menu.performActionForItem(at: 0)
        try await fixture.host.settle()
        let popup = try XCTUnwrap(cell.metadata.parityPopovers["👍"])
        XCTAssertTrue(popup.popover.isShown, "A same-source count change must not invalidate its retained menu")
        try await eventually { fixture.adapter.actions?.reactorAccounts[id] == Set([fixture.base.key.accountId, "former-member"]) }
        fixture.base.service.orgSessions[fixture.base.key]?.snapshotOwed = true
        try await eventually { !popup.popover.isShown && !NavigationPresentationGate.obscures(fixture.host.window) }
        XCTAssertEqual(fixture.adapter.actions?.reactorAccounts, [:])
        menu.performActionForItem(at: 0)
        XCTAssertFalse(popup.popover.isShown)
        XCTAssertNil(APQuietFailure())
    }

    func testReactorRetryAfterCellReuseFetchesOnlyCurrentMessage() async throws {
        let fixture = try await fixture(count: 2)
        let firstID = fixture.messages[0].id, secondID = fixture.messages[1].id
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let cell = try fixture.row(firstID)
        try rebind(cell, to: secondID, fixture: fixture)
        let chip = try chip(in: cell), event = try event(for: chip, fixture: fixture)
        ChatStubProtocol.reset { request, _ in
            guard request.url?.path.hasSuffix("/reactions") == true else { return .failure(URLError(.unsupportedURL)) }
            return .failure(URLError(.notConnectedToInternet))
        }
        try XCTUnwrap(chip.menu(for: event)).performActionForItem(at: 0)
        try await fixture.host.settle()
        let popup = try XCTUnwrap(cell.metadata.parityPopovers["👍"])
        XCTAssertTrue(popup.popover.isShown)
        let window = try XCTUnwrap(popup.popover.contentViewController?.view.window)
        func labels() -> [String] {
            window.contentView?.layoutSubtreeIfNeeded()
            return ChatTimelineReferenceCapture.accessibilityNodes(window).flatMap { node in
                ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap {
                    ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String
                }
            }
        }
        try await eventually { labels().contains("Could not load reactions.") && labels().contains("Retry") }
        let firstRequests = ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/reactions") == true }
        XCTAssertEqual(firstRequests.count, 1)
        XCTAssertEqual(fixture.adapter.actions?.reactorAccounts, [:])
        let account = fixture.base.key.accountId
        ChatStubProtocol.reset { request, _ in
            guard request.url?.path.hasSuffix("/reactions") == true else { return .failure(URLError(.unsupportedURL)) }
            return .success(.init(status: 200, body: Data("{\"as_of_seq\":10,\"account_ids\":[\"\(account)\",\"former-member\"],\"next\":null}".utf8)))
        }
        XCTAssertTrue(ChatTimelineReferenceCapture.press("Retry", window: window))
        try await eventually {
            let values = labels()
            return values.contains("Anna") && values.contains("Former member")
                && !values.contains("Could not load reactions.") && !values.contains("Retry")
                && fixture.adapter.actions?.reactorAccounts[secondID] == Set([account, "former-member"])
        }
        let requests = firstRequests + ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/reactions") == true }
        XCTAssertEqual(requests.count, 2)
        for value in requests {
            let request = value.request, url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(url.path.hasSuffix("/messages/\(secondID)/reactions"))
            XCTAssertFalse(url.pathComponents.contains(firstID), "Reactor retry must never fetch the cell's former message")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "emoji" }?.value, "👍")
            XCTAssertNil(query.first { $0.name == "after" })
            XCTAssertNil(query.first { $0.name == "at" })
        }
        XCTAssertNil(fixture.adapter.actions?.reactorAccounts[firstID])
        XCTAssertTrue(popup.popover.isShown)
        XCTAssertTrue(NavigationPresentationGate.obscures(fixture.host.window))
        XCTAssertFalse(APQuietWindowHasOSFocus(window))
        XCTAssertNil(APQuietFailure())
    }

    func testActualReactorMenusMatchLegacyAndDispatchScopedPopupsAfterReuse() async throws {
        let fixture = try await fixture(count: 2)
        let firstID = fixture.messages[0].id, secondID = fixture.messages[1].id
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let cell = try fixture.row(firstID)
        try rebind(cell, to: secondID, fixture: fixture)
        let chip = try chip(in: cell), event = try event(for: chip, fixture: fixture)
        let b1 = try XCTUnwrap(fixture.adapter.actions?.reactionContext(messageID: secondID))
        let members = [ChatOrgView.Member(accountId: fixture.base.key.accountId, handle: "anna", name: "Anna", role: "owner")]
        let measured = ChatTimelineParityLayout.legacy(content: AnyView(
            ChatReactionStrip(b1: b1, message: secondID, members: members)
                .chatParity("w07-reactor-menu-reference", "row")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)))
        let legacyHost = ChatQuietHost(content: measured.content, dark: false, width: 120, height: 80)
        defer { legacyHost.close() }
        try await legacyHost.settle()
        let legacyMenu = try XCTUnwrap(try ChatNativeMenuParity.legacy(in: legacyHost))
        let nativeMenu = try XCTUnwrap(chip.menu(for: event))
        let legacyItems = ChatNativeMenuParity.items(legacyMenu), nativeItems = ChatNativeMenuParity.items(nativeMenu)
        XCTAssertEqual(nativeItems, legacyItems, "Compare actual AppKit titles, order, enabled/checked state, separators and submenus")
        XCTAssertFalse(NavigationPresentationGate.obscures(legacyHost.window))
        XCTAssertFalse(NavigationPresentationGate.obscures(fixture.host.window))
        func labels(_ window: NSWindow) -> [String] {
            window.contentView?.layoutSubtreeIfNeeded()
            return ChatTimelineReferenceCapture.accessibilityNodes(window).flatMap { node in
                ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap {
                    ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String
                }
            }
        }

        try ChatNativeMenuParity.dispatch("Who reacted", in: legacyMenu)
        try await eventually {
            NavigationPresentationGate.obscures(legacyHost.window)
                && NSApp.windows.contains { $0 !== legacyHost.window && $0.isVisible && $0.parent === legacyHost.window }
        }
        let legacyPopup = try XCTUnwrap(NSApp.windows.first {
            $0 !== legacyHost.window && $0.isVisible && $0.parent === legacyHost.window
        })
        defer { legacyPopup.performClose(nil) }
        try await eventually { labels(legacyPopup).contains("Anna") && self.reactorReads == 1 }
        XCTAssertFalse(NavigationPresentationGate.obscures(fixture.host.window))
        XCTAssertFalse(APQuietWindowHasOSFocus(legacyPopup))
        legacyPopup.performClose(nil)
        try await eventually { !legacyPopup.isVisible && !NavigationPresentationGate.obscures(legacyHost.window) }

        APQuietSelectWindow(fixture.host.window)
        try ChatNativeMenuParity.dispatch("Who reacted", in: nativeMenu)
        let nativePopup = try XCTUnwrap(cell.metadata.parityPopovers["👍"])
        defer { nativePopup.close(returnFocus: false) }
        try await eventually { nativePopup.popover.isShown && NavigationPresentationGate.obscures(fixture.host.window) }
        let nativeWindow = try XCTUnwrap(nativePopup.popover.contentViewController?.view.window)
        try await eventually { labels(nativeWindow).contains("Anna") && self.reactorReads == 2 }
        XCTAssertFalse(NavigationPresentationGate.obscures(legacyHost.window))
        XCTAssertFalse(APQuietWindowHasOSFocus(nativeWindow))
        let requests = ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/reactions") == true }
        XCTAssertEqual(requests.count, 2, "Each actual menu dispatch opens its production reactor loader")
        for value in requests {
            let request = value.request, url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(url.path.hasSuffix("/messages/\(secondID)/reactions"))
            XCTAssertFalse(url.pathComponents.contains(firstID))
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "emoji" }?.value, "👍")
        }
        nativePopup.close()
        try await eventually { !nativePopup.popover.isShown && !NavigationPresentationGate.obscures(fixture.host.window) }
        XCTAssertFalse(NavigationPresentationGate.obscures(legacyHost.window))
        XCTAssertEqual(fixture.adapter.actions?.reactorAccounts, [:])
        if let directory = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_PARITY_EVIDENCE"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(["legacy": legacyItems, "native": nativeItems])
                .write(to: url.appendingPathComponent("reactors-context-menu-parity.json"))
        }
        XCTAssertNil(APQuietFailure())
    }

    func testOpenPopupRefreshesAnchorBoundsAndDismissalPreservesOtherFocus() async throws {
        let fixture = try await fixture(), id = fixture.messages[0].id
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let cell = try fixture.row(id), chip = try chip(in: cell), event = try event(for: chip, fixture: fixture)
        XCTAssertTrue(fixture.host.window.makeFirstResponder(fixture.coordinator.tableView))
        try XCTUnwrap(chip.menu(for: event)).performActionForItem(at: 0)
        try await fixture.host.settle()
        let popup = try XCTUnwrap(cell.metadata.parityPopovers["👍"]), before = chip.bounds
        XCTAssertTrue(popup.popover.isShown)
        try metadata(fixture, id: id, count: 200_000)
        try await fixture.settle()
        XCTAssertTrue(try self.chip(in: cell) === chip)
        XCTAssertTrue(popup.popover.isShown)
        XCTAssertGreaterThan(chip.bounds.width, before.width)
        XCTAssertEqual(popup.popover.positioningRect, chip.bounds)
        let other = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        fixture.view.addSubview(other)
        defer { other.removeFromSuperview() }
        XCTAssertTrue(fixture.host.window.makeFirstResponder(other))
        let responder = fixture.host.window.firstResponder
        popup.close()
        try await eventually { !popup.popover.isShown && !NavigationPresentationGate.obscures(fixture.host.window) }
        XCTAssertTrue(fixture.host.window.firstResponder === responder)
        XCTAssertNil(APQuietFailure())
    }
}
