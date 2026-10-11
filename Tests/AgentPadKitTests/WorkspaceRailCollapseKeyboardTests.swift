import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class WorkspaceRailCollapseKeyboardTests: XCTestCase {
    func testNativeArrowsDisclosureAndHiddenTabRemovalInDockedAndPeekLists() async throws {
        let scope = TeamServiceTestScope(); defer { scope.close() }
        let store = makeTestStore(), controller = AgentPadWindowController(windowId: UUID(), store: store)
        defer { controller.close(); store.terminate() }
        let window = try XCTUnwrap(controller.window)
        let first = try XCTUnwrap(store.active), tab = try XCTUnwrap(first.activeSession)
        store.renameWorkspace(first, to: "Cedar")
        tab.renameForTesting("Deploy production")
        let second = store.addWorkspace(); store.renameWorkspace(second, to: "Birch")
        window.setContentSize(NSSize(width: 1200, height: 720))
        window.makeKeyAndOrderFront(nil)
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhancedUI = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previousEnhancedUI, forAttribute: enhancedUI) }

        func key(_ characters: String, _ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            let flags = (123...126).contains(code) ? modifiers.union([.function, .numericPad]) : modifiers
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
        }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
            controller.paneHost.renderNow()
        }
        func elements() -> [AXNode] {
            func visit(_ node: AXNode) -> [AXNode] { [node] + node.children.flatMap(visit) }
            return visit(AXNode(object: window.contentView!))
        }
        func element(_ id: String) throws -> AXNode {
            try XCTUnwrap(elements().first { $0.accessibilityIdentifier() == id }, "Missing accessibility element \(id)")
        }
        let rowID = "workspace-rail-\(first.id)"
        let disclosureID = "workspace-tabs-disclosure-\(first.id)"
        let tabID = "workspace-rail-tab-\(tab.id)"

        for railVisible in [true, false] {
            store.closeNavigation()
            store.leftNavigation.railVisible = railVisible
            store.setWorkspaceTabsCollapsed(false, workspaceID: first.id)
            store.openWorkspaceList()
            try await settle()
            XCTAssertEqual(store.navigationPresentation.list, railVisible ? .expanded : .peek)
            let search = try XCTUnwrap(window.firstResponder as? NSTextView,
                                      "Opening the list must focus its native search editor")
            XCTAssertTrue(search.isFieldEditor)
            XCTAssertEqual((search.delegate as? NSTextField)?.placeholderString, "Find workspace or tab")
            try key("\u{F702}", 123)
            XCTAssertTrue(window.firstResponder === search, "Left in the search field remains text navigation")
            XCTAssertFalse(store.leftNavigation.collapsedWorkspaceIDs.contains(first.id))
            try key("\u{F701}", 125)
            try await settle()
            let rowResponder = window.firstResponder
            XCTAssertFalse(rowResponder === search)
            XCTAssertTrue(try element(rowID).focused, "Down from search focuses the first workspace")
            XCTAssertEqual(try element(disclosureID).accessibilityValue() as? String, "Expanded")
            XCTAssertEqual(try element(disclosureID).accessibilityLabel(), "Collapse tabs in Cedar")
            XCTAssertNotNil(try element(tabID))
            for _ in 0..<2 {
                try key("\u{F702}", 123)
                try await settle()
                XCTAssertTrue(store.leftNavigation.collapsedWorkspaceIDs.contains(first.id))
                XCTAssertTrue(try element(rowID).focused, "Collapse must preserve the focused workspace")
            }
            XCTAssertEqual(try element(disclosureID).accessibilityValue() as? String, "Collapsed")
            XCTAssertTrue((try element(rowID).accessibilityValue() as? String)?.contains("Collapsed, 1 tab") == true)
            XCTAssertFalse(elements().contains { $0.accessibilityIdentifier() == tabID }, "Hidden tabs leave the accessibility and Tab traversal tree")
            try key("\u{F703}", 124)
            try await settle()
            XCTAssertFalse(store.leftNavigation.collapsedWorkspaceIDs.contains(first.id))
            XCTAssertTrue(try element(rowID).focused)
            XCTAssertNotNil(try element(tabID))
            XCTAssertNil(store.navigationPresentation.previewWorkspaceID, "Right in the expanded list must not open a preview")

            // Focus the actual disclosure independently of the machine's
            // global Keyboard Navigation preference, then send native keys.
            try element(disclosureID).focus()
            try await settle()
            XCTAssertTrue(try element(disclosureID).focused)
            try key("\u{F702}", 123)
            try await settle()
            XCTAssertTrue(store.leftNavigation.collapsedWorkspaceIDs.contains(first.id))
            XCTAssertTrue(try element(disclosureID).focused)
            try key("\u{F703}", 124)
            try await settle()
            XCTAssertFalse(store.leftNavigation.collapsedWorkspaceIDs.contains(first.id))
            XCTAssertTrue(try element(disclosureID).focused)
            try key("\u{F702}", 123)
            try await settle()
            try key("\u{F701}", 125)
            try await settle()
            let nextRowID = "workspace-rail-\(second.id)"
            XCTAssertTrue(try element(nextRowID).focused, "Navigation skips the removed tab rows")
            try key("\u{F702}", 123)
            try await settle()
            XCTAssertTrue(store.leftNavigation.collapsedWorkspaceIDs.contains(second.id))
            XCTAssertTrue(try element(nextRowID).focused)
            XCTAssertEqual(store.activeWorkspaceId, second.id, "Disclosure and arrows never activate a workspace")

            let all = try element("workspace-tabs-toggle-all")
            XCTAssertEqual(all.accessibilityLabel(), "Expand all")
            all.press()
            try await settle()
            XCTAssertTrue(store.leftNavigation.collapsedWorkspaceIDs.isEmpty)
            XCTAssertEqual(try element("workspace-tabs-toggle-all").accessibilityLabel(), "Collapse all")

            store.setWorkspaceTabsCollapsed(true, workspaceID: first.id)
            store.navigationPresentation.query = "production"
            try await settle()
            XCTAssertNotNil(try element(tabID))
            XCTAssertEqual(try element(disclosureID).accessibilityValue() as? String, "Expanded")
            XCTAssertEqual(try element(disclosureID).accessibilityLabel(), "Expand tabs after search in Cedar")
            try element(disclosureID).press()
            try await settle()
            XCTAssertNotNil(try element(tabID))
            XCTAssertFalse(store.leftNavigation.collapsedWorkspaceIDs.contains(first.id))
            try element(disclosureID).press()
            try await settle()
            XCTAssertNotNil(try element(tabID))
            store.navigationPresentation.query = ""
            try await settle()
            XCTAssertFalse(elements().contains { $0.accessibilityIdentifier() == tabID })
        }

        store.closeNavigation()
        store.leftNavigation.railVisible = true
        try await settle()
        try element(rowID).focus()
        try await settle()
        try key("\u{F703}", 124)
        try await settle()
        XCTAssertEqual(store.navigationPresentation.previewWorkspaceID, first.id,
                       "Right on the narrow rail keeps its existing tab preview")
    }

    func testOptionClickTogglesAllButAccessibilityPressStaysLocal() async throws {
        let scope = TeamServiceTestScope(); defer { scope.close() }
        let store = makeTestStore(), controller = AgentPadWindowController(windowId: UUID(), store: store)
        defer { controller.close(); store.terminate() }
        let window = try XCTUnwrap(controller.window)
        let first = try XCTUnwrap(store.active), second = store.addWorkspace()
        store.renameWorkspace(first, to: "Cedar")
        store.renameWorkspace(second, to: "Birch")
        window.setContentSize(NSSize(width: 1200, height: 720))
        window.makeKeyAndOrderFront(nil)
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhancedUI = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previousEnhancedUI, forAttribute: enhancedUI) }

        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
            controller.paneHost.renderNow()
        }
        func disclosure() throws -> AXNode {
            func visit(_ node: AXNode) -> [AXNode] { [node] + node.children.flatMap(visit) }
            return try XCTUnwrap(visit(AXNode(object: window.contentView!)).first {
                $0.accessibilityIdentifier() == "workspace-tabs-disclosure-\(first.id)"
            })
        }
        // Dequeuing establishes NSApp.currentEvent; sendEvent alone does not.
        func makeCurrent(_ event: NSEvent) throws -> NSEvent {
            NSApp.postEvent(event, atStart: true)
            let current = try XCTUnwrap(NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true))
            XCTAssertEqual(current.type, event.type)
            XCTAssertEqual(current.modifierFlags, event.modifierFlags)
            return current
        }
        func space(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        }
        func mouse(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            let frame = try XCTUnwrap(try disclosure().object.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let location = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        func click(modifiers: NSEvent.ModifierFlags) async throws {
            // Queue the release first so a native tracking loop can consume it.
            NSApp.postEvent(try mouse(.leftMouseUp, modifiers: modifiers), atStart: true)
            window.sendEvent(try makeCurrent(mouse(.leftMouseDown, modifiers: modifiers)))
            if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                window.sendEvent(release)
            }
            try await settle()
        }

        store.openWorkspaceList()
        store.navigationPresentation.query = "Cedar"
        store.setWorkspaceTabsCollapsed(true, workspaceID: first.id)
        try await settle()
        try await click(modifiers: .option)
        XCTAssertEqual(store.leftNavigation.collapsedWorkspaceIDs, [first.id, second.id], "Option-click includes filtered rows")
        try await click(modifiers: .option)
        XCTAssertTrue(store.leftNavigation.collapsedWorkspaceIDs.isEmpty)
        try await click(modifiers: [])
        XCTAssertEqual(store.leftNavigation.collapsedWorkspaceIDs, [first.id])

        for modifiers: NSEvent.ModifierFlags in [[], .option, [.control, .option]] {
            store.setWorkspaceTabsCollapsed(true, workspaceID: first.id)
            _ = try makeCurrent(space(.keyDown, modifiers: modifiers))
            try disclosure().press()
            try await settle()
            XCTAssertTrue(store.leftNavigation.collapsedWorkspaceIDs.isEmpty, "Keyboard/VoiceOver press only expands Cedar")
        }
        _ = try makeCurrent(mouse(.leftMouseUp, modifiers: .option))
        try disclosure().press()
        try await settle()
        XCTAssertEqual(store.leftNavigation.collapsedWorkspaceIDs, [first.id], "Accessibility must ignore a stale Option-click")

        XCTAssertEqual(store.activeWorkspaceId, second.id)
        XCTAssertEqual(store.navigationPresentation.query, "Cedar")
    }

    /// SwiftUI's virtual accessibility nodes implement the Objective-C getters
    /// without declaring NSAccessibilityProtocol conformance.
    private struct AXNode {
        let object: NSObject
        func attribute(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        var children: [AXNode] {
            (attribute("accessibilityChildren") as? [NSObject] ?? []).map { AXNode(object: $0) }
        }
        func accessibilityIdentifier() -> String? { attribute("accessibilityIdentifier") as? String }
        func accessibilityLabel() -> String? { attribute("accessibilityLabel") as? String }
        func accessibilityValue() -> Any? { attribute("accessibilityValue") }
        var focused: Bool { object.value(forKey: "accessibilityFocused") as? Bool ?? false }
        func focus() { object.setValue(true, forKey: "accessibilityFocused") }
        func press() {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector) else { XCTFail("Element has no press action"); return }
            typealias Press = @convention(c) (NSObject, Selector) -> Bool
            let invoke = unsafeBitCast(object.method(for: selector), to: Press.self)
            XCTAssertTrue(invoke(object, selector))
        }
    }
}
