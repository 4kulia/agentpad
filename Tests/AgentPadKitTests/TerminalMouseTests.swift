import AppKit
import GhosttyKit
import XCTest
@testable import AgentPadKit

/// Real libghostty surfaces with manual I/O: deliberately omit mouseUp, then
/// inspect the selection / mouse reports rather than just a Swift state flag.
@MainActor
final class TerminalMouseTests: XCTestCase {
    func testInterruptedLinkClickDoesNotSwallowNextSelectionRelease() async throws {
        for losesFocus in [false, true] {
            let t = try LinkTerminal()
            t.feed("docs/file.swift\r\nabcdefghijklmnopqrstuvwxyz\r\n")
            await t.drain()
            t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 4, row: 0, mods: [.command]))
            XCTAssertTrue(t.view.fileLinks.isHandlingClick)
            // A preview/editor takes focus and receives the first mouseUp.
            if losesFocus { XCTAssertTrue(t.window.makeFirstResponder(nil)) }
            t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 2, row: 1, mods: []))
            t.view.mouseDragged(with: try t.mouse(.leftMouseDragged, column: 7, row: 1, mods: []))
            t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 7, row: 1, mods: []))
            let selected = t.view.readSelection()
            XCTAssertNotNil(selected)
            try moveCore(t, column: 18, row: 1)
            XCTAssertEqual(t.view.readSelection(), selected, "hover must not continue a released selection")
            XCTAssertTrue(t.files.isEmpty)
            await t.close()
        }
    }

    func testFocusLossReleasesSurfaceBeforeClearingHover() async throws {
        let t = try LinkTerminal()
        t.feed("abcdefghijklmnopqrstuvwxyz\r\nsecond line\r\n")
        await t.drain()
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 2, row: 0, mods: []))
        t.view.mouseDragged(with: try t.mouse(.leftMouseDragged, column: 7, row: 0, mods: []))
        let selected = t.view.readSelection()
        XCTAssertNotNil(selected)
        XCTAssertTrue(t.window.makeFirstResponder(nil))
        XCTAssertEqual(t.view.readSelection(), selected, "clearing hover must not drag to (-1, -1)")
        try moveCore(t, column: 18, row: 0)
        XCTAssertEqual(t.view.readSelection(), selected, "libghostty must actually receive release")
        await t.close()
    }

    func testHiddenDetachedAndInactiveSurfacesReleaseWithoutMouseUp() async throws {
        let boundaries: [(String, (LinkTerminal) -> Void)] = [
            ("hidden tab", { $0.view.isHidden = true }),
            ("hidden workspace", { $0.view.superview?.isHidden = true }),
            ("detach", { $0.view.removeFromSuperview() }),
            ("reparent", { t in
                let container = NSView(frame: t.view.frame)
                t.view.superview?.addSubview(container)
                container.addSubview(t.view)
            }),
            ("ordered out", { $0.view.isOffScreen = true }),
            ("window resign key", { NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: $0.window) }),
            ("minimize", { NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: $0.window) }),
            ("close", { NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: $0.window) }),
            ("app deactivate", { _ in NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp) }),
        ]
        for (name, interrupt) in boundaries {
            let t = try await selectionTerminal()
            try startSelection(t)
            let selected = t.view.readSelection()
            interrupt(t)
            XCTAssertEqual(t.view.readSelection(), selected, name)
            try moveCore(t, column: 18, row: 0)
            XCTAssertEqual(t.view.readSelection(), selected, "\(name) must release the core button")
            await t.close()
        }
    }

    func testTabHostSwitchReleasesRetainedSurface() async throws {
        let engine = LibghosttyEngine()
        let t = try LinkTerminal(view: try XCTUnwrap(engine.view as? GhosttySurfaceView))
        let first = Session(engine: engine, currentDirectory: URL(fileURLWithPath: "/tmp"), agent: .terminal)
        let second = Session(engine: TestEngine(), currentDirectory: URL(fileURLWithPath: "/tmp"), agent: .terminal)
        let host = TerminalTabHostView(frame: t.view.frame)
        t.window.contentView = host
        host.update(tabs: [first, second], activeTabId: first.id, grabsFocusOnMount: true)
        t.feed("abcdefghijklmnopqrstuvwxyz\r\n")
        await t.drain()
        try startSelection(t)
        let selected = t.view.readSelection()
        host.update(tabs: [first, second], activeTabId: second.id, grabsFocusOnMount: true)
        XCTAssertTrue(t.view.isHidden)
        XCTAssertTrue(t.view.superview === host, "the inactive surface stays mounted")
        host.update(tabs: [first, second], activeTabId: first.id, grabsFocusOnMount: true)
        try moveCore(t, column: 18, row: 0)
        XCTAssertEqual(t.view.readSelection(), selected)
        await t.close()
    }

    func testMissingReleaseRecoveredBeforeHoverEnterExitAndModifiers() async throws {
        let events: [(String, (GhosttySurfaceView, NSEvent) -> Void)] = [
            ("move", { $0.mouseMoved(with: $1) }),
            ("enter", { $0.mouseEntered(with: $1) }),
            ("exit", { $0.mouseExited(with: $1) }),
        ]
        for (name, deliver) in events {
            let t = try await selectionTerminal()
            try startSelection(t)
            let selected = t.view.readSelection()
            t.view.pressedMouseButtons = { 0 }
            deliver(t.view, try t.mouse(.mouseMoved, column: 18, row: 0, mods: []))
            try moveCore(t, column: 23, row: 0)
            XCTAssertEqual(t.view.readSelection(), selected, name)
            await t.close()
        }
        let t = try await selectionTerminal()
        try startSelection(t)
        let selected = t.view.readSelection()
        t.view.pressedMouseButtons = { 0 }
        let flags = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: t.window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56))
        t.view.flagsChanged(with: flags)
        try moveCore(t, column: 23, row: 0)
        XCTAssertEqual(t.view.readSelection(), selected)
        await t.close()
    }

    func testExitWhileButtonHeldPreservesDrag() async throws {
        let t = try await selectionTerminal()
        try startSelection(t)
        let selected = t.view.readSelection()
        t.view.pressedMouseButtons = { 1 }
        t.view.mouseExited(with: try t.mouse(.mouseMoved, column: 7, row: 0, mods: []))
        XCTAssertEqual(t.view.readSelection(), selected, "exit must not send (-1, -1) during a drag")
        t.view.mouseDragged(with: try t.mouse(.leftMouseDragged, column: 18, row: 0, mods: []))
        XCTAssertNotEqual(t.view.readSelection(), selected, "the drag must remain active")
        t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 18, row: 0, mods: []))
        let finished = t.view.readSelection()
        try moveCore(t, column: 23, row: 0)
        XCTAssertEqual(t.view.readSelection(), finished)
        await t.close()
    }

    func testNewPressBalancesMissingReleaseBeforeUpdatingPosition() async throws {
        let t = try await reportingTerminal()
        t.view.pressedMouseButtons = { 1 }
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 2, row: 0, mods: []))
        XCTAssertEqual(t.output.take(), "\u{1B}[<0;3;1M")
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 18, row: 0, mods: []))
        XCTAssertEqual(t.output.take(), "\u{1B}[<0;3;1m\u{1B}[<0;19;1M", "release old position before the new press")
        t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 18, row: 0, mods: []))
        XCTAssertEqual(t.output.take(), "\u{1B}[<0;19;1m")
        t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 18, row: 0, mods: []))
        XCTAssertEqual(t.output.take(), "", "ignore an unmatched/late release")
        await t.close()
    }

    func testReleaseDeliveredToAnotherWindowStillResetsSurface() async throws {
        let t = try await reportingTerminal()
        let sink = MouseReleaseSinkWindow()
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 2, row: 0, mods: []))
        _ = t.output.take()
        NSApp.sendEvent(try release(in: sink))
        XCTAssertEqual(sink.releases, 1)
        await t.drain()
        XCTAssertEqual(t.output.take(), "\u{1B}[<0;3;1m")
        try moveCore(t, column: 18, row: 0)
        XCTAssertEqual(t.output.take(), "", "no phantom TUI drag after a stolen release")
        await t.close()
    }

    func testDeferredReleaseCannotCancelNewerPress() async throws {
        let t = try await reportingTerminal()
        let sink = MouseReleaseSinkWindow()
        t.view.pressedMouseButtons = { 1 }
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 2, row: 0, mods: []))
        NSApp.sendEvent(try release(in: sink))
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 18, row: 0, mods: []))
        _ = t.output.take()
        await t.drain()
        XCTAssertEqual(t.output.take(), "", "queued cleanup belongs to the old gesture")
        t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 18, row: 0, mods: []))
        XCTAssertEqual(t.output.take(), "\u{1B}[<0;19;1m")
        await t.close()
    }

    func testNewPressInAnotherViewRepairsMissingRelease() async throws {
        let t = try await reportingTerminal()
        let sink = MouseReleaseSinkWindow()
        t.view.pressedMouseButtons = { 1 }
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 2, row: 0, mods: []))
        _ = t.output.take()
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sink.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.sendEvent(down)
        XCTAssertEqual(sink.presses, 1)
        XCTAssertEqual(t.output.take(), "\u{1B}[<0;3;1m")
        await t.close()
    }

    func testKeyboardInputRepairsMissingRelease() async throws {
        let t = try await reportingTerminal()
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 2, row: 0, mods: []))
        _ = t.output.take()
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: t.window.windowNumber, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        t.view.keyDown(with: escape)
        XCTAssertEqual(t.output.take(), "\u{1B}[<0;3;1m\u{1B}")
        try moveCore(t, column: 18, row: 0)
        XCTAssertEqual(t.output.take(), "")
        await t.close()
    }

    func testMiddleAndLeftButtonsAreBalancedIndependently() async throws {
        let t = try await reportingTerminal()
        t.view.pressedMouseButtons = { 5 }
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 2, row: 0, mods: []))
        let middleDown = try middleMouse(.otherMouseDown, in: t)
        XCTAssertEqual(middleDown.buttonNumber, 2)
        t.view.otherMouseDown(with: middleDown)
        _ = t.output.take()
        t.view.otherMouseUp(with: try middleMouse(.otherMouseUp, in: t))
        XCTAssertEqual(t.output.take(), "\u{1B}[<1;3;1m")
        XCTAssertTrue(t.window.makeFirstResponder(nil))
        XCTAssertEqual(t.output.take(), "\u{1B}[<0;3;1m", "middle up must not release left")
        t.view.otherMouseDown(with: middleDown)
        _ = t.output.take()
        t.view.isHidden = true
        XCTAssertEqual(t.output.take(), "\u{1B}[<1;3;1m", "hidden surfaces release middle too")
        t.view.otherMouseUp(with: try middleMouse(.otherMouseUp, in: t))
        XCTAssertEqual(t.output.take(), "")
        await t.close()
    }

    func testInterruptedHostClicksNeverEmitUnmatchedTUIRelease() async throws {
        for mods: NSEvent.ModifierFlags in [[.command], [.option]] {
            let t = try await reportingTerminal()
            t.feed("docs/file.swift\r\n")
            t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 4, row: 0, mods: mods))
            XCTAssertEqual(t.output.take(), "")
            XCTAssertTrue(t.window.makeFirstResponder(nil))
            XCTAssertFalse(t.view.fileLinks.isHandlingClick)
            t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 18, row: 0, mods: []))
            XCTAssertEqual(t.output.take(), "")
            XCTAssertTrue(t.files.isEmpty)
            await t.close()
        }
    }

    func testCancelledOSC8ClickDoesNotOpenURLOnSyntheticRelease() async throws {
        let t = try LinkTerminal()
        t.feed("\u{1B}]8;;https://example.com/cancelled\u{1B}\\label\u{1B}]8;;\u{1B}\\")
        await t.drain()
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 2, row: 0, mods: [.command]))
        XCTAssertFalse(t.view.fileLinks.isHandlingClick, "OSC 8 clicks are handled by the core")
        XCTAssertTrue(t.window.makeFirstResponder(nil))
        await t.drain()
        XCTAssertTrue(t.urls.isEmpty, "synthetic release cancels, never activates the core's latched link")
        await t.close()
    }

    private func selectionTerminal() async throws -> LinkTerminal {
        let t = try LinkTerminal()
        let container = NSView(frame: t.view.frame)
        t.window.contentView = container
        container.addSubview(t.view)
        t.view.pressedMouseButtons = { 0 }
        t.feed("abcdefghijklmnopqrstuvwxyz\r\nsecond line\r\n")
        await t.drain()
        return t
    }

    private func reportingTerminal() async throws -> LinkTerminal {
        let t = try LinkTerminal()
        t.view.pressedMouseButtons = { 0 }
        t.feed("\u{1B}[?1002h\u{1B}[?1006h")
        await t.drain()
        _ = t.output.take()
        return t
    }

    private func startSelection(_ t: LinkTerminal) throws {
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 2, row: 0, mods: []))
        t.view.mouseDragged(with: try t.mouse(.leftMouseDragged, column: 7, row: 0, mods: []))
        XCTAssertNotNil(t.view.readSelection())
    }

    private func release(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }

    private func middleMouse(_ type: NSEvent.EventType, in t: LinkTerminal) throws -> NSEvent {
        let seed = try t.mouse(type, column: 2, row: 0, mods: [])
        let cgEvent = try XCTUnwrap(seed.cgEvent?.copy())
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }

    private func moveCore(_ t: LinkTerminal, column: Int, row: Int) throws {
        let event = try t.mouse(.mouseMoved, column: column, row: row, mods: [])
        let point = t.view.convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(t.surface, point.x, t.view.bounds.height - point.y,
                                  GhosttySurfaceView.mapModifiers([]))
    }
}

/// Receives a real NSApplication event, but deliberately never forwards it to
/// the surface. Exercises the local monitor without clicking the user's UI.
@MainActor
private final class MouseReleaseSinkWindow: NSWindow {
    var releases = 0
    var presses = 0
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: .borderless, backing: .buffered, defer: false)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp { releases += 1 }
        else if event.type == .leftMouseDown { presses += 1 }
        else { super.sendEvent(event) }
    }
}
