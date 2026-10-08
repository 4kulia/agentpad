import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatUX2Fix2Tests: XCTestCase {
    private let andrew = ChatMentionCandidate(id: "same", address: "andrew", label: "Andrew")
    private let marina = ChatMentionCandidate(id: "marina", address: "marina", label: "Marina")
    private let agent = ChatMentionCandidate(id: "same", address: "reviewer@andrew", label: "Reviewer", agentId: "same")

    func testMentionSectionsKeepPeopleAndAgentsDistinctAndKeyboardOrderContiguous() {
        let sections = ChatMentionSection.grouped([agent, andrew, marina])
        XCTAssertEqual(sections.map(\.title), ["People", "Agents"])
        XCTAssertEqual(sections.map { $0.rows.map(\.candidate) }, [[andrew, marina], [agent]])
        XCTAssertEqual(sections.flatMap(\.rows).map(\.index), [0, 1, 2])
        XCTAssertNotEqual(sections[0].id, sections[1].id, "account and agent IDs can coincide; sections scope row identity")
        XCTAssertEqual(ChatMentionSection.grouped([andrew, agent, marina]), sections, "input need not already be grouped")
    }

    func testMentionFilteringNeverLeavesEmptyOrMislabeledSections() {
        for (query, titles, rows) in [("", ["People", "Agents"], [andrew, marina, agent]),
                                    ("Reviewer", ["Agents"], [agent]), ("mar", ["People"], [marina]),
                                    ("ANDREW", ["People", "Agents"], [andrew, agent]), ("missing", [], [])] {
            let sections = ChatMentionSection.grouped(ChatMentionCandidate.filtered([agent, andrew, marina], query: query))
            XCTAssertEqual(sections.map(\.title), titles, query)
            XCTAssertEqual(sections.flatMap(\.rows).map(\.candidate), rows, query)
            XCTAssertFalse(sections.contains { $0.rows.isEmpty })
        }
        XCTAssertEqual(ChatMentionSection.grouped([andrew]).map(\.title), ["People"])
        XCTAssertEqual(ChatMentionSection.grouped([agent]).map(\.title), ["Agents"])
        XCTAssertTrue(ChatMentionSection.grouped([]).isEmpty)
    }

    func testConnectionStatePrecedenceIncludesReconnectAndErrorsWithCachedChannels() throws {
        func status(_ snapshot: ChatSidebarSnapshot.State, _ socket: ChatSocket.State? = nil,
                    _ service: ChatService.State = .signedIn) -> ChatConnectionStatus {
            .init(snapshot: snapshot, service: service, socket: socket)
        }
        XCTAssertEqual(status(.ready(offline: false), .connected), .connected)
        XCTAssertEqual(status(.ready(offline: true), .disconnected), .offline)
        XCTAssertEqual(status(.ready(offline: false), .disconnected), .connecting, "backoff within the Offline grace period")
        XCTAssertEqual(status(.notConnected, nil, .off), .notConnected)
        XCTAssertEqual(status(.noChannels, .connected), .unavailable)
        XCTAssertEqual(status(.checking, .connected), .checking)
        for snapshot in [ChatSidebarSnapshot.State.ready(offline: true), .ready(offline: false), .checking, .notConnected] {
            XCTAssertEqual(status(snapshot, .connecting), .connecting)
            XCTAssertEqual(status(snapshot, .failed("failure")), .error)
            XCTAssertEqual(status(snapshot, .needsSignIn("expired")), .error)
            XCTAssertEqual(status(snapshot, .connecting, .needsSignIn("expired")), .error)
        }
        let key = ChatOrgKey(server: try ChatServerAddress(parsing: "https://chat.example.com"), accountId: "me", orgId: "org")
        XCTAssertEqual(status(.ready(offline: false), .connected, .notMember(key, "removed")), .error)
        XCTAssertEqual(ChatConnectionStatus.connected.text, "Connected")
        XCTAssertEqual(ChatConnectionStatus.connecting.text, "Connecting…")
        XCTAssertEqual(ChatConnectionStatus.notConnected.text, "Not connected")
        XCTAssertEqual(ChatConnectionStatus.connected.icon, "checkmark.circle.fill")
        XCTAssertEqual(ChatConnectionStatus.error.icon, "exclamationmark.circle.fill")
    }

    func testConnectionColorsUseSemanticTokensInBothThemes() throws {
        let settings = AgentPadSettingsModel.shared
        let old = (settings.appearanceMode, settings.lightTerminalThemeSelection, settings.darkTerminalThemeSelection)
        defer {
            settings.appearanceMode = old.0
            settings.lightTerminalThemeSelection = old.1; settings.darkTerminalThemeSelection = old.2
        }
        // Only mutate in-memory appearance; never save settings to a profile.
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        settings.darkTerminalThemeSelection = AgentPadSettingsModel.defaultDarkThemeSelection
        for mode in [AgentPadAppearanceMode.light, .dark] {
            settings.appearanceMode = mode
            XCTAssertEqual(Theme.resolved.isLight, mode == .light, "exercise both resolved palettes")
            XCTAssertEqual(ChatConnectionStatus.connected.color, ChatAppearance.success)
            XCTAssertEqual(ChatConnectionStatus.connecting.color, ChatAppearance.attention)
            XCTAssertEqual(ChatConnectionStatus.checking.color, ChatAppearance.attention)
            XCTAssertEqual(ChatConnectionStatus.error.color, ChatAppearance.failure)
            for state in [ChatConnectionStatus.notConnected, .offline, .unavailable] {
                XCTAssertEqual(state.color, ChatAppearance.secondary)
            }
            let green = try XCTUnwrap(NSColor(ChatConnectionStatus.connected.color).usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(green.greenComponent, green.redComponent)
            XCTAssertGreaterThan(green.greenComponent, green.blueComponent)
            XCTAssertNotEqual(ChatConnectionStatus.connected.color, ChatAppearance.secondary)
        }
    }

    func testPopupGeometryFitsNarrowWindowsAndFlipsOrScrollsAtEdges() {
        let bounds = CGRect(x: 100, y: 100, width: 340, height: 540)
        let viewport = CGRect(x: 120, y: 120, width: 268, height: 58)
        let bottomCaret = CGRect(x: 415, y: 135, width: 1, height: 18)
        let above = ChatMentionPopup.frame(caret: bottomCaret, viewport: viewport, bounds: bounds, height: 338)
        XCTAssertTrue(bounds.contains(above))
        XCTAssertEqual(above.width, 268)
        XCTAssertGreaterThan(above.minY, bottomCaret.maxY)
        let topCaret = CGRect(x: 120, y: 600, width: 1, height: 18)
        let below = ChatMentionPopup.frame(caret: topCaret, viewport: viewport, bounds: bounds, height: 338)
        XCTAssertTrue(bounds.contains(below))
        XCTAssertLessThan(below.maxY, topCaret.minY)
        let short = CGRect(x: 100, y: 100, width: 240, height: 180)
        let scrolled = ChatMentionPopup.frame(caret: bottomCaret, viewport: viewport, bounds: short, height: 338)
        XCTAssertTrue(short.contains(scrolled))
        XCTAssertLessThan(scrolled.height, 338)
        XCTAssertEqual(scrolled.width, 240)
    }

    func testNativePopupStaysAboveParentWithoutTakingFocusAndDetaches() async throws {
        _ = NSApplication.shared
        // XCTest has no running NSApplication event loop. Simulate key state,
        // while using real AppKit geometry, child windows and first responders.
        final class Window: NSWindow {
            var testKey = true
            override var isKeyWindow: Bool { testKey }
        }
        let window = Window(contentRect: CGRect(x: 200, y: 200, width: 440, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 24, y: 20, width: 392, height: 80))
        let editor = ChatMentionEditor.Editor(frame: scroll.bounds)
        editor.isRichText = false; editor.string = "@"; editor.setSelectedRange(NSRange(location: 1, length: 0))
        scroll.documentView = editor
        window.contentView?.addSubview(scroll)
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        window.makeFirstResponder(editor)
        editor.mentionPopup.update(.init(sections: ChatMentionSection.grouped([andrew, agent]), selected: 0,
                                         title: "Mention in channel", choose: { _ in }))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertFalse(editor.isHiddenOrHasHiddenAncestor)
        editor.mentionPopup.refresh()
        let panel = try XCTUnwrap(editor.mentionPopup.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.parent === window)
        XCTAssertTrue(window.childWindows?.contains(panel) == true)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(window.firstResponder === editor)
        let before = panel.frame
        // AppKit may cascade the initial window away from the requested origin.
        let origin = window.frame.origin
        window.setFrameOrigin(CGPoint(x: origin.x + 80, y: origin.y + 20))
        editor.mentionPopup.refresh()
        XCTAssertEqual(panel.frame.minX - before.minX, 80, accuracy: 1)
        XCTAssertEqual(panel.frame.minY - before.minY, 20, accuracy: 1)
        window.makeFirstResponder(nil)
        XCTAssertFalse(panel.isVisible)
        window.makeFirstResponder(editor)
        editor.mentionPopup.refresh()
        XCTAssertTrue(panel.isVisible)
        window.testKey = false
        editor.mentionPopup.refresh()
        XCTAssertFalse(panel.isVisible)
        window.testKey = true
        editor.mentionPopup.refresh()
        XCTAssertTrue(panel.isVisible)
        editor.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        editor.mentionPopup.refresh()
        XCTAssertFalse(panel.isVisible, "the input method owns its own candidate window")
        editor.unmarkText()
        editor.mentionPopup.update(nil)
        editor.mentionPopup.refresh()
        XCTAssertFalse(panel.isVisible)
        editor.mentionPopup.detach()
        XCTAssertNil(panel.parent)
    }
}
