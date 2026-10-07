import AppKit
import GhosttyKit
import XCTest
@testable import AgentPadKit

@MainActor
final class TerminalScrollTests: XCTestCase {
    func testWheelAndTrackpadScrollPrimaryHistoryAfterLinkHover() async throws {
        for precise in [false, true] {
            let terminal = try LinkTerminal()
            terminal.feed((0..<150).map { "line \($0) docs/file.swift\r\n" }.joined())
            await terminal.drain()
            terminal.view.mouseMoved(with: try terminal.mouse(.mouseMoved, column: 12, row: 3, mods: [.command]))
            XCTAssertNotNil(terminal.hover)
            let before = try scrollbar(terminal)
            XCTAssertGreaterThan(before.total, before.len)
            let event = try scroll(terminal, precise: precise, delta: precise ? 10 : 2)
            terminal.view.scrollWheel(with: event)
            if precise {
                XCTAssertEqual(try scrollbar(terminal).offset, before.offset, "sub-line trackpad movement accumulates")
                terminal.view.scrollWheel(with: event)
            }
            XCTAssertLessThan(try scrollbar(terminal).offset, before.offset, "scroll up must leave the bottom, precise=\(precise)")
            XCTAssertNil(terminal.hover)
            XCTAssertTrue(terminal.files.isEmpty)
            XCTAssertTrue(terminal.output.take().isEmpty, "primary scrollback does not send keys")
            terminal.view.scrollWheel(with: try scroll(terminal, precise: precise, delta: precise ? -40 : -4))
            XCTAssertEqual(try scrollbar(terminal).offset, before.offset)
            await terminal.close()
        }
    }

    func testAlternateScreenWheelAndTrackpadReachTUIAsArrowsOrMouseReports() async throws {
        for mouseReporting in [false, true] {
            for precise in [false, true] {
                let terminal = try LinkTerminal()
                terminal.feed("\u{1B}[?1049h" + (mouseReporting ? "\u{1B}[?1000h\u{1B}[?1006h" : ""))
                await terminal.drain()
                // Deliberately stale coordinates: scroll must use its own event,
                // including on the first gesture after focus/mouse exit.
                terminal.view.mouseMoved(with: try terminal.mouse(.mouseMoved, column: 1, row: 1, mods: []))
                terminal.view.fileLinks.clear()
                _ = terminal.output.take()
                terminal.view.scrollWheel(with: try scroll(terminal, precise: precise, delta: precise ? 20 : 1))
                let up = terminal.output.take()
                if mouseReporting {
                    XCTAssertTrue(up.contains("\u{1B}[<64;5;4M"), "TUI wheel up at the event cell: \(up.debugDescription)")
                } else {
                    XCTAssertTrue(up.contains("\u{1B}[A") || up.contains("\u{1B}OA"), "alternate scroll sends up: \(up.debugDescription)")
                }
                terminal.view.scrollWheel(with: try scroll(terminal, precise: precise, delta: precise ? -20 : -1))
                let down = terminal.output.take()
                if mouseReporting {
                    XCTAssertTrue(down.contains("\u{1B}[<65;5;4M"), "TUI wheel down: \(down.debugDescription)")
                } else {
                    XCTAssertTrue(down.contains("\u{1B}[B") || down.contains("\u{1B}OB"), "alternate scroll sends down: \(down.debugDescription)")
                }
                XCTAssertTrue(terminal.files.isEmpty)
                await terminal.close()
            }
        }
    }

    private func scrollbar(_ terminal: LinkTerminal) throws -> ghostty_surface_scrollbar_s {
        var value = ghostty_surface_scrollbar_s()
        XCTAssertTrue(ghostty_surface_scrollbar(terminal.surface, &value))
        return value
    }

    private func scroll(_ terminal: LinkTerminal, precise: Bool, delta: CGFloat) throws -> NSEvent {
        let mouse = try terminal.mouse(.mouseMoved, column: 4, row: 3, mods: [])
        return TerminalScrollEvent(point: mouse.locationInWindow, precise: precise, delta: delta)
    }
}

private final class TerminalScrollEvent: NSEvent {
    let point: NSPoint
    let precise: Bool
    let delta: CGFloat
    init(point: NSPoint, precise: Bool, delta: CGFloat) {
        self.point = point; self.precise = precise; self.delta = delta
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var locationInWindow: NSPoint { point }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { delta }
}
