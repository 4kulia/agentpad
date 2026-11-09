import AppKit
import GhosttyKit
import XCTest
@testable import AgentPadKit

/// Codex rust-v0.163.0 (83086188ae0614bd882818ff1aa23f3194962012):
/// tui/src/tui/{alternate_screen,keyboard_modes}.rs, text_selection.rs,
/// transcript_view/input.rs, clipboard_copy.rs. A fake child exchanges bytes with
/// libghostty's manual I/O backend; it never runs an agent or a native clipboard.
@MainActor
final class TerminalCodexCopyTests: XCTestCase {
    func testCodexPlainDragCopiesThroughOSC52WithoutTerminalSelection() async throws {
        try await withCodex { t, fake in
            try drag(t, mods: [], end: 5)
            try await fake.waitForClipboard("hello")
            XCTAssertNil(t.view.readSelection())
            XCTAssertFalse(t.view.validateMenuItem(copyItem()))
            XCTAssertTrue(t.output.take().contains("\u{1B}[<32;6;1M"))
        }
    }

    func testCodexOptionDragMakesTerminalSelectionAndCommandCopy() async throws {
        try await withCodex(extraConfig: "mouse-shift-capture = always\n") { t, _ in
            t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 0, row: 0, mods: [.option]))
            // Real modifier changes also pass through flagsChanged mid-gesture.
            t.view.pressedMouseButtons = { 1 }
            let flags = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                modifierFlags: [], timestamp: 1, windowNumber: t.window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 58))
            t.view.flagsChanged(with: flags)
            t.view.mouseDragged(with: try t.mouse(.leftMouseDragged, column: 4, row: 0, mods: []))
            t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 4, row: 0, mods: []))
            XCTAssertEqual(t.view.readSelection(), "hello")
            XCTAssertTrue(t.view.validateMenuItem(copyItem()))
            XCTAssertTrue(t.view.performKeyEquivalent(with: key(t, code: 8, text: "c", mods: [.command])))
            XCTAssertEqual(t.clipboard.string(forType: .string), "hello")
            let bytes = t.output.take()
            XCTAssertFalse(bytes.contains("\u{1B}[<0;"), "Option must not leak a left press")
            XCTAssertFalse(bytes.contains("\u{1B}[<8;"), "Option must not leak an Alt-left press")
            XCTAssertFalse(bytes.contains("u"), "native Copy must not send a keyboard report")
        }
    }

    func testCodexShiftDragAndEditCopyUseTerminalSelection() async throws {
        try await withCodex { t, _ in
            try drag(t, mods: [.shift], end: 5)
            let selected = try XCTUnwrap(t.view.readSelection())
            XCTAssertFalse(selected.isEmpty)
            XCTAssertTrue(t.view.validateMenuItem(copyItem()))
            XCTAssertTrue(t.window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil) == true)
            XCTAssertEqual(t.clipboard.string(forType: .string), selected)
        }
    }

    func testCodexDoubleAndTripleClickCopyThroughOSC52() async throws {
        try await withCodex { t, fake in
            for clicks in 1...3 {
                t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 1, row: 0, mods: [], clicks: clicks))
                t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 1, row: 0, mods: [], clicks: clicks))
                if clicks == 2 { try await fake.waitForClipboard("hello") }
                if clicks == 3 { try await fake.waitForClipboard("hello world\n") }
            }
            XCTAssertNil(t.view.readSelection())
            XCTAssertFalse(t.view.validateMenuItem(copyItem()))
        }
    }

    func testCodexCommandCopyKeyEquivalentReachesTUISelection() async throws {
        try await checkCommandCopy(keyEquivalent: true)
    }

    func testCodexCommandCopyKeyDownReachesTUISelection() async throws {
        try await checkCommandCopy(keyEquivalent: false)
    }

    func testCodexCommandCopyNormalizesCyrillicLayout() async throws {
        try await checkCommandCopy(keyEquivalent: true, unmodifiedText: "с")
    }

    func testCodexCoreEncoderCanForwardUnselectedCommandCopy() async throws {
        try await withCodex(autoCopy: false) { t, _ in
            var event = GhosttySurfaceView.makeKeyEvent(for: key(t, code: 8, text: "c", mods: [.command]))
            event.unshifted_codepoint = 99
            XCTAssertTrue(GhosttySurfaceView.send(event, text: "c", to: t.surface))
            XCTAssertEqual(t.output.take(), "\u{1B}[99;9u")
        }
    }

    private func checkCommandCopy(keyEquivalent: Bool, unmodifiedText: String = "c") async throws {
        try await withCodex(autoCopy: false) { t, fake in
            try drag(t, mods: [], end: 5)
            try await fake.waitForSelection()
            XCTAssertNil(t.view.readSelection())
            t.clipboard.setString("unchanged", forType: .string)
            _ = t.output.take()
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command], timestamp: 1, windowNumber: t.window.windowNumber,
                context: nil, characters: "c", charactersIgnoringModifiers: unmodifiedText,
                isARepeat: false, keyCode: 8))
            if keyEquivalent {
                XCTAssertTrue(t.view.performKeyEquivalent(with: event))
            } else {
                t.view.keyDown(with: event)
            }
            let output = t.output.take()
            XCTAssertEqual(output, "\u{1B}[99;9u",
                "Codex owns the selection and recognizes Kitty Super+C")
            guard output == "\u{1B}[99;9u" else { return }
            try await fake.waitForClipboard("hello")
        }
    }

    func testCodexControlCopyAndCopyLatestResponseRemainTUIKeys() async throws {
        try await withCodex(autoCopy: false) { t, fake in
            try drag(t, mods: [], end: 5)
            try await fake.waitForSelection()
            _ = t.output.take()
            let controlC = key(t, code: 8, text: "\u{03}", mods: [.control])
            XCTAssertFalse(t.view.performKeyEquivalent(with: controlC))
            t.view.keyDown(with: controlC)
            let scalar = try XCTUnwrap(controlC.characters(byApplyingModifiers: [])?.unicodeScalars.first)
            // Codex enables alternate keys (Kitty flag 4), so a non-US
            // logical C retains its code point and the base-layout C (99).
            let keyCodes = scalar.value == 99 ? "99" : "\(scalar.value)::99"
            XCTAssertEqual(t.output.take(), "\u{1B}[\(keyCodes);5u")
            print("Codex-mode Ctrl+C: CSI \(keyCodes);5u (active layout, unchanged)")
            // Legacy Ctrl+C stays ETX without changing the owner's input source.
            t.feed("\u{1B}[<u")
            t.view.keyDown(with: controlC)
            XCTAssertEqual(t.output.take(), "\u{03}")
            try await fake.waitForClipboard("hello")
            let controlO = key(t, code: 31, text: "\u{0F}", mods: [.control])
            XCTAssertFalse(t.view.performKeyEquivalent(with: controlO))
            t.view.keyDown(with: controlO)
            XCTAssertEqual(t.output.take(), "\u{0F}")
            try await fake.waitForClipboard("hello world\nsecond line\nПривет 🐱")
        }
    }

    func testCodexOSC52HonorsAllowAskAndDenyPolicies() async throws {
        for policy in ["allow", "ask", "deny"] {
            try await withCodex(extraConfig: "clipboard-write = \(policy)\n") { t, fake in
                t.clipboard.setString("unchanged", forType: .string)
                try drag(t, mods: [], end: 5)
                try await fake.waitForSelection()
                if policy == "allow" {
                    try await fake.waitForClipboard("hello")
                } else if policy == "ask" {
                    try await fake.wait { t.session.terminalConfirmation.isAwaiting }
                    XCTAssertEqual(t.clipboard.string(forType: .string), "unchanged")
                    let confirmation = t.session.terminalConfirmation
                    confirmation.shown(true)
                    confirmation.confirm()
                    await t.settleDecision()
                    XCTAssertEqual(t.clipboard.string(forType: .string), "hello")
                } else {
                    // The marker follows OSC 52 in the same ordered output stream.
                    XCTAssertEqual(t.clipboard.string(forType: .string), "unchanged")
                    XCTAssertFalse(t.session.terminalConfirmation.isAwaiting)
                }
            }
        }
    }

    private func drag(_ t: ClipboardTerminal, mods: NSEvent.ModifierFlags, end: Int) throws {
        t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 0, row: 0, mods: mods))
        t.view.mouseDragged(with: try t.mouse(.leftMouseDragged, column: end, row: 0, mods: mods))
        t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: end, row: 0, mods: mods))
    }

    private func copyItem() -> NSMenuItem {
        NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    }

    private func key(_ t: ClipboardTerminal, code: UInt16, text: String, mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
            timestamp: 1, windowNumber: t.window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    private func withCodex(
        autoCopy: Bool = true,
        extraConfig: String = "",
        _ body: (ClipboardTerminal, FakeCodexCopyProcess) async throws -> Void
    ) async throws {
        let terminal = try ClipboardTerminal(extraConfig: AgentPadSettings.baselineConfig
            + "copy-on-select = false\n" + extraConfig)
        let fake = FakeCodexCopyProcess(terminal: terminal)
        do {
            try await fake.start(autoCopy: autoCopy)
            try await body(terminal, fake)
        } catch {
            await fake.close()
            await terminal.close()
            throw error
        }
        await fake.close()
        await terminal.close()
    }
}

@MainActor
private final class FakeCodexCopyProcess {
    let terminal: ClipboardTerminal
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var title = ""

    init(terminal: ClipboardTerminal) { self.terminal = terminal }

    func start(autoCopy: Bool) async throws {
        terminal.view.onTitleChange = { [weak self] in self?.title = $0 }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script, autoCopy ? "1" : "0"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak terminal] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            Task { @MainActor in
                guard let terminal, let surface = terminal.view.surface else { return }
                bytes.withUnsafeBytes { raw in
                    ghostty_surface_process_output(surface,
                        raw.baseAddress?.assumingMemoryBound(to: CChar.self), UInt(raw.count))
                }
            }
        }
        try process.run()
        terminal.output.onWrite = { [input] in
            try? input.fileHandleForWriting.write(contentsOf: $0)
        }
        try await wait { self.title == "codex-copy-ready" }
        XCTAssertTrue(ghostty_surface_mouse_captured(terminal.surface))
        _ = terminal.output.take()
    }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            ghostty_app_tick(terminal.app)
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Fake Codex did not reach the expected terminal/clipboard state")
        throw FakeFailure.timeout
    }

    func waitForSelection() async throws { try await wait { self.title == "codex-copy-selected" } }
    func waitForClipboard(_ value: String) async throws {
        try await wait { self.terminal.clipboard.string(forType: .string) == value }
    }

    func close() async {
        terminal.output.onWrite = nil
        try? input.fileHandleForWriting.close()
        for _ in 0..<200 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        terminal.view.onTitleChange = nil
        XCTAssertEqual(process.terminationStatus, 0, "fake process must exit cleanly")
    }

    private enum FakeFailure: Error { case timeout }

    // Only source-observed copy behavior is modeled. arboard is deliberately
    // unavailable: copies take Codex's OSC 52 fallback into a named pasteboard.
    // Host-native selection is never implemented by the fake.
    private static let script = #"""
import base64
import os
import re
import sys
import time

auto_copy = sys.argv[1] == "1"
text = "hello world\nsecond line\nПривет 🐱"
selection = ""
anchor = None
last_click = None
buffer = b""

def emit(value):
    sys.stdout.write(value)
    sys.stdout.flush()

def copy(value):
    if value:
        encoded = base64.b64encode(value.encode("utf-8")).decode("ascii")
        emit("\x1b]52;c;" + encoded + "\x07")

def offset(column, row):
    return min(len(text), max(0, column - 1) + (12 if row > 1 else 0))

emit("\x1b[?2004h\x1b[>4;0m\x1b[>5u\x1b[?1004h\x1b[?1049h"
     "\x1b[>4;0m\x1b[>5u"
     "\x1b[?1007l\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h"
     "\x1b[H" + text.replace("\n", "\r\n") + "\x1b]2;codex-copy-ready\x07")
while True:
    chunk = os.read(0, 4096)
    if not chunk:
        break
    buffer += chunk
    while buffer:
        mouse = re.match(rb"\x1b\[<(\d+);(\d+);(\d+)([Mm])", buffer)
        key = re.match(rb"\x1b\[(\d+)(?::\d*(?::(\d+))?)?;(\d+)u", buffer)
        if mouse:
            button, column, row = map(int, mouse.group(1, 2, 3))
            released = mouse.group(4) == b"m"
            buffer = buffer[mouse.end():]
            position = offset(column, row)
            if button & 3 == 0 and not button & 32 and not released:
                now = time.monotonic()
                clicks = (last_click[3] % 3 + 1 if last_click and
                          now - last_click[0] < .4 and
                          (column, row) == last_click[1:3] else 1)
                last_click = (now, column, row, clicks)
                anchor = position
                selection = ""
                if clicks == 2:
                    start = text.rfind(" ", 0, position) + 1
                    end = text.find(" ", position)
                    selection = text[start:end if end >= 0 else len(text)]
                elif clicks == 3:
                    selection = "hello world\n"
            elif button & 3 == 0 and button & 32 and anchor is not None:
                selection = text[min(anchor, position):max(anchor, position)]
            elif button & 3 == 0 and released:
                anchor = None
                if auto_copy:
                    copy(selection)
                emit("\x1b]2;codex-copy-selected\x07")
        elif key:
            code, mods = int(key.group(1)), int(key.group(3))
            base = int(key.group(2)) if key.group(2) else code
            buffer = buffer[key.end():]
            if 99 in (code, base) and mods in (5, 6, 9):
                copy(selection)
            elif 111 in (code, base) and mods == 5:
                copy(text)
        elif buffer.startswith(b"\x1b[I") or buffer.startswith(b"\x1b[O"):
            buffer = buffer[3:]
        elif buffer[0] != 27:
            char, buffer = buffer[0], buffer[1:]
            if char == 3:
                copy(selection)
            elif char == 15:
                copy(text)
        else:
            break
"""#
}
