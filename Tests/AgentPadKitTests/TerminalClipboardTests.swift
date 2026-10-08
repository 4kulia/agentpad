import AppKit
import GhosttyKit
import XCTest
@testable import AgentPadKit

/// Real AppKit responders, production clipboard callbacks, and the pinned
/// libghostty byte encoder. No shell, user's clipboard, or user config.
@MainActor
final class TerminalClipboardTests: XCTestCase {
    func testOnlyUnmodifiedCommandCopyAndPasteAreClipboardShortcuts() {
        for (code, char, action) in [(UInt16(8), "c", GhosttySurfaceView.ClipboardAction.copy), (9, "v", .paste)] {
            XCTAssertEqual(GhosttySurfaceView.clipboardAction(for: key(code, char, [.command])), action)
            XCTAssertEqual(GhosttySurfaceView.clipboardAction(for: key(code, char.uppercased(), [.command, .capsLock])), action)
            for mods: NSEvent.ModifierFlags in [[], [.control], [.shift], [.option], [.command, .control], [.command, .shift], [.command, .option]] {
                XCTAssertNil(GhosttySurfaceView.clipboardAction(for: key(code, char, mods)))
            }
        }
        XCTAssertNil(GhosttySurfaceView.clipboardAction(for: key(13, "w", [.command])))
        let translated = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 1, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "м",
            isARepeat: false, keyCode: 9)!
        XCTAssertEqual(GhosttySurfaceView.clipboardAction(for: translated), .paste)
    }

    func testCommandShortcutsUseTheCommandKeyboardLayout() throws {
        for (code, action) in [(UInt16(8), GhosttySurfaceView.ClipboardAction.copy), (9, .paste)] {
            let seed = key(code, "", [.command])
            let typed = try XCTUnwrap(seed.characters(byApplyingModifiers: []))
            let command = try XCTUnwrap(seed.characters(byApplyingModifiers: .command))
            try XCTSkipUnless(command == "c" || command == "v", "current Command layout uses different copy/paste keys")
            XCTAssertEqual(GhosttySurfaceView.clipboardAction(for: key(code, typed, [.command])), action)
        }
    }

    func testCommandCopyUsesCoreSelectionAndNoSelectionIsANoop() async throws {
        try await withTerminal { t in
            t.clipboard.setString("keep me", forType: .string)
            XCTAssertTrue(t.view.performKeyEquivalent(with: key(8, "c", [.command])))
            XCTAssertEqual(t.clipboard.string(forType: .string), "keep me")
            XCTAssertEqual(t.output.take(), "")
            t.feed("Привет 🌍\r\n")
            XCTAssertTrue(ghostty_surface_select_viewport_rows(t.surface, 0, 0))
            XCTAssertTrue(t.view.performKeyEquivalent(with: key(8, "c", [.command])))
            XCTAssertEqual(t.clipboard.string(forType: .string), "Привет 🌍")
            XCTAssertEqual(t.output.take(), "")
        }
    }

    func testEditMenuSelectorsAndValidationUseTheTerminalResponder() async throws {
        try await withTerminal { t in
            let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            XCTAssertFalse(t.view.validateMenuItem(copy))
            XCTAssertFalse(t.view.validateMenuItem(paste))
            t.feed("from terminal\r\n")
            XCTAssertTrue(ghostty_surface_select_viewport_rows(t.surface, 0, 0))
            XCTAssertTrue(t.view.validateMenuItem(copy))
            // tryToPerform walks the actual responder selectors used by the
            // nil-target Edit menu, including their Objective-C visibility.
            XCTAssertTrue(t.window.firstResponder?.tryToPerform(copy.action!, with: copy) == true)
            XCTAssertEqual(t.clipboard.string(forType: .string), "from terminal")
            XCTAssertTrue(t.view.validateMenuItem(paste))
            XCTAssertTrue(t.window.firstResponder?.tryToPerform(paste.action!, with: paste) == true)
            XCTAssertEqual(t.output.take(), "from terminal")
        }
    }

    func testCommandPasteAndKeyDownFallbackEachPasteExactlyOnce() async throws {
        try await withTerminal { t in
            t.feed("\u{1B}[?2004h")
            t.clipboard.setString("строка 🐱\n中文\n", forType: .string)
            XCTAssertTrue(t.view.performKeyEquivalent(with: key(9, "v", [.command])))
            XCTAssertEqual(t.output.take(), "\u{1B}[200~строка 🐱\n中文\n\u{1B}[201~")
            t.view.keyDown(with: key(9, "v", [.command]))
            XCTAssertEqual(t.output.take(), "\u{1B}[200~строка 🐱\n中文\n\u{1B}[201~")
            // The text is captured and queued before the next input/event.
            t.clipboard.setString("different", forType: .string)
            t.view.sendInput("X")
            XCTAssertEqual(t.output.take(), "X")
        }
    }

    func testUnfocusedHiddenAndDetachedTerminalsDeclineKeyEquivalents() async throws {
        try await withTerminal { t in
            t.clipboard.setString("terminal clipboard", forType: .string)
            let editor = NSTextView(frame: .zero)
            t.view.addSubview(editor)
            XCTAssertTrue(t.window.makeFirstResponder(editor))
            XCTAssertFalse(t.view.performKeyEquivalent(with: key(9, "v", [.command])))
            XCTAssertEqual(t.output.take(), "")
            XCTAssertTrue(t.window.makeFirstResponder(t.view))
            t.view.isHidden = true
            XCTAssertFalse(t.view.performKeyEquivalent(with: key(9, "v", [.command])))
            t.view.isHidden = false
            t.view.removeFromSuperview()
            XCTAssertFalse(t.view.performKeyEquivalent(with: key(9, "v", [.command])))
        }
    }

    func testDirectPasteTracksBracketedModeAndPreservesUnicodeAndEmbeddedNUL() async throws {
        try await withTerminal { t in
            let text = "one\nдва\r\n猫🙂\0tail"
            t.view.paste(text)
            XCTAssertEqual(t.output.take(), "one\rдва\r\r猫🙂 tail")
            t.feed("\u{1B}[?2004h")
            t.view.paste(text)
            XCTAssertEqual(t.output.take(), "\u{1B}[200~one\nдва\r\n猫🙂 tail\u{1B}[201~")
            t.feed("\u{1B}[?2004l")
            t.view.paste("again\n")
            XCTAssertEqual(t.output.take(), "again\r")
            t.view.paste("")
            XCTAssertEqual(t.output.take(), "")
        }
    }

    func testLargeAndEmptyClipboardPastes() async throws {
        try await withTerminal { t in
            t.feed("\u{1B}[?2004h")
            XCTAssertTrue(t.view.pasteFromClipboardViaCore())
            XCTAssertEqual(t.output.take(), "")
            XCTAssertNil(t.window.attachedSheet)
            let text = String(repeating: "Привет 🐱 中文\n", count: 4096)
            t.clipboard.setString(text, forType: .string)
            XCTAssertTrue(t.view.pasteFromClipboardViaCore())
            XCTAssertEqual(t.output.take(), "\u{1B}[200~" + text + "\u{1B}[201~")
        }
    }

    func testEditPasteFileURLUsesEscapedPathAndCoreFraming() async throws {
        try await withTerminal { t in
            t.feed("\u{1B}[?2004h")
            t.clipboard.writeObjects([NSURL(fileURLWithPath: "/tmp/with space/猫.txt")])
            XCTAssertTrue(t.view.tryToPerform(#selector(NSText.paste(_:)), with: nil))
            XCTAssertEqual(t.output.take(), "\u{1B}[200~/tmp/with\\ space/猫.txt\u{1B}[201~")
        }
    }

    func testProtectedClipboardPasteHandlesNULAndConfirmationCancelThenAllow() async throws {
        try await withTerminal { t in
            t.clipboard.setString("before\0after", forType: .string)
            XCTAssertTrue(t.view.pasteFromClipboardViaCore())
            XCTAssertEqual(t.output.take(), "before after")
            let earlier = Set(AttentionLedger.shared.events.filter { $0.source == "sheet" }.map(\.id))
            t.clipboard.setString("one\ntwo", forType: .string)
            XCTAssertTrue(t.view.pasteFromClipboardViaCore())
            XCTAssertEqual(t.output.take(), "")
            let cancel = try XCTUnwrap(t.window.attachedSheet?.windowController as? ConsentSheetController)
            let waiting = AttentionLedger.shared.events.filter { $0.source == "sheet" && !earlier.contains($0.id) }.map(\.id)
            XCTAssertEqual(waiting.count, 1)
            XCTAssertEqual(AttentionLedger.shared.events.first(where: { $0.id == waiting.first })?.body, "")
            cancel.finish(false)
            cancel.finish(true) // A late second button/teardown cannot grant consent.
            XCTAssertTrue(AttentionLedger.shared.events.filter { waiting.contains($0.id) }.isEmpty)
            XCTAssertEqual(t.output.take(), "")
            XCTAssertTrue(t.view.pasteFromClipboardViaCore())
            let allow = try XCTUnwrap(t.window.attachedSheet?.windowController as? ConsentSheetController)
            t.clipboard.setString("changed after the prompt", forType: .string)
            allow.finish(true)
            XCTAssertEqual(t.output.take(), "one\rtwo")
        }
    }

    func testControlCharactersInPasteAreFilteredByTheCoreWithoutNestedBrackets() async throws {
        try await withTerminal { t in
            t.feed("\u{1B}[?2004h")
            t.clipboard.setString("a\u{1B}[201~\u{03}b", forType: .string)
            XCTAssertTrue(t.view.pasteFromClipboardViaCore())
            XCTAssertEqual(t.output.take(), "")
            let allow = try XCTUnwrap(t.window.attachedSheet?.windowController as? ConsentSheetController)
            allow.finish(true)
            // Embedded ESC is data filtered by Ghostty; never a second fence.
            XCTAssertEqual(t.output.take(), "\u{1B}[200~a [201~ b\u{1B}[201~")
        }
    }

    func testControlKeysStayWithTUIInLegacyAndKittyModes() async throws {
        try await withTerminal { t in
            t.clipboard.setString("MUST NOT PASTE", forType: .string)
            let cases: [(UInt16, String)] = [
                (8, "\u{03}"), (9, "\u{16}"), (0, "\u{01}"), (15, "\u{12}"),
            ]
            for kitty in [false, true] {
                if kitty { t.feed("\u{1B}[>1u") }
                for (code, chars) in cases {
                    let event = key(code, chars, [.control])
                    // Kitty uses the active layout's logical code point; on
                    // Russian input Ctrl+C is CSI 1089;5u, not CSI 99;5u.
                    let scalar = try XCTUnwrap(event.characters(byApplyingModifiers: [])?.unicodeScalars.first)
                    let kittyBytes = "\u{1B}[\(scalar.value);5u"
                    XCTAssertFalse(t.view.performKeyEquivalent(with: event))
                    t.view.keyDown(with: event)
                    XCTAssertEqual(t.output.take(), kitty ? kittyBytes : chars, "Ctrl keyCode \(code)")
                }
            }
            XCTAssertEqual(t.clipboard.string(forType: .string), "MUST NOT PASTE")
        }
    }

    func testOptionDragSelectsDuringMouseReportingEvenWithShiftCaptureAlways() async throws {
        try await withTerminal(extraConfig: "mouse-shift-capture = always\n") { t in
            t.feed("\u{1B}[?1049h\u{1B}[?1002h\u{1B}[?1006hhello world\r\nsecond line")
            XCTAssertTrue(ghostty_surface_mouse_captured(t.surface))
            t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 0, row: 0, mods: [.option]))
            // The user releases Option while continuing to drag.
            t.view.mouseDragged(with: try t.mouse(.leftMouseDragged, column: 5, row: 1, mods: []))
            t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 5, row: 1, mods: []))
            XCTAssertEqual(t.view.readSelection(), "hello world\nsecond")
            XCTAssertEqual(t.output.take(), "", "no half mouse gesture may reach the TUI")
            XCTAssertTrue(t.view.performKeyEquivalent(with: key(8, "c", [.command])))
            XCTAssertEqual(t.clipboard.string(forType: .string), "hello world\nsecond")
            t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 1, row: 0, mods: []))
            t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 1, row: 0, mods: []))
            XCTAssertEqual(t.output.take(), "\u{1B}[<0;2;1M\u{1B}[<0;2;1m", "normal TUI clicks resume after release")
        }
    }

    func testShiftSelectionAndOptionSelectionOfWideGlyphs() async throws {
        try await withTerminal(extraConfig: "mouse-shift-capture = never\nwindow-padding-x = 9\nwindow-padding-y = 7\n") { t in
            t.feed("\u{1B}[?1002h\u{1B}[?1006ha猫🙂z")
            t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 2, row: 0, mods: [.option]))
            t.view.mouseDragged(with: try t.mouse(.leftMouseDragged, column: 4, row: 0, mods: [.option]))
            t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 4, row: 0, mods: [.option]))
            XCTAssertEqual(t.view.readSelection(), "猫🙂")
            XCTAssertEqual(t.output.take(), "")
            _ = ghostty_surface_clear_selection(t.surface)
            t.view.mouseDown(with: try t.mouse(.leftMouseDown, column: 0, row: 0, mods: [.shift]))
            t.view.mouseDragged(with: try t.mouse(.leftMouseDragged, column: 5, row: 0, mods: [.shift]))
            t.view.mouseUp(with: try t.mouse(.leftMouseUp, column: 5, row: 0, mods: [.shift]))
            XCTAssertNotNil(t.view.readSelection())
            XCTAssertEqual(t.output.take(), "")
        }
    }

    private func key(_ code: UInt16, _ characters: String, _ mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
            timestamp: 1, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func withTerminal(
        extraConfig: String = "",
        _ body: (ClipboardTerminal) throws -> Void
    ) async throws {
        let terminal = try ClipboardTerminal(extraConfig: extraConfig)
        do {
            try body(terminal)
        } catch {
            await terminal.close()
            throw error
        }
        await terminal.close()
    }
}

@MainActor
private final class ClipboardTerminal {
    let window: NSWindow
    let view: GhosttySurfaceView
    let clipboard = NSPasteboard(name: .init("agentpad-clipboard-contract-\(UUID())"))
    let output = ClipboardOutput()
    let app: ghostty_app_t
    let config: ghostty_config_t
    var surface: ghostty_surface_t { view.surface! }

    init(extraConfig: String) throws {
        _ = NSApplication.shared
        // Initialize the C runtime exactly once, like the existing key tests.
        _ = try XCTUnwrap(LibghosttyApp.shared.app)
        let isolatedConfig = try XCTUnwrap(ghostty_config_new())
        config = isolatedConfig
        let settings = "font-family = Menlo\ncopy-on-select = false\nclipboard-trim-trailing-spaces = true\n" + extraConfig
        settings.withCString { ghostty_config_load_string(isolatedConfig, $0, UInt(settings.utf8.count), "clipboard-test") }
        ghostty_config_finalize(isolatedConfig)
        var runtime = LibghosttyApp.runtimeConfig()
        app = try XCTUnwrap(ghostty_app_new(&runtime, isolatedConfig))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        view = GhosttySurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.clipboard = clipboard
        window.contentView = view
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.scale_factor = Double(window.backingScaleFactor)
        surfaceConfig.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        surfaceConfig.io_write_cb = clipboardTestWrite
        surfaceConfig.io_write_userdata = Unmanaged.passUnretained(output).toOpaque()
        _ = try XCTUnwrap(view.attachSurface(app: app, config: &surfaceConfig))
        XCTAssertTrue(window.makeFirstResponder(view))
        ghostty_surface_set_focus(surface, true)
        _ = output.take()
    }

    func feed(_ text: String) {
        text.withCString { ghostty_surface_process_output(surface, $0, UInt(text.utf8.count)) }
    }

    func mouse(_ type: NSEvent.EventType, column: Int, row: Int, mods: NSEvent.ModifierFlags) throws -> NSEvent {
        var grid = ghostty_surface_grid_metrics_s()
        XCTAssertTrue(ghostty_surface_grid_metrics(surface, &grid))
        let point = NSPoint(x: grid.padding_left + (Double(column) + 0.5) * grid.cell_width,
            y: view.bounds.height - grid.padding_top - (Double(row) + 0.5) * grid.cell_height)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
            modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func close() async {
        (window.attachedSheet?.windowController as? ConsentSheetController)?.finish(false)
        view.releaseSurface()
        await withCheckedContinuation { continuation in
            SurfaceTeardownCoordinator.shared.whenDrained { continuation.resume() }
        }
        window.contentView = nil
        window.orderOut(nil)
        ghostty_app_free(app)
        ghostty_config_free(config)
        clipboard.releaseGlobally()
    }
}

private final class ClipboardOutput {
    private var bytes = Data()
    func append(_ pointer: UnsafePointer<CChar>, count: Int) {
        bytes.append(UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: count)
    }
    func take() -> String {
        defer { bytes.removeAll(keepingCapacity: true) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private let clipboardTestWrite: ghostty_io_write_cb = { userdata, pointer, count in
    guard let userdata, let pointer else { return }
    Unmanaged<ClipboardOutput>.fromOpaque(userdata).takeUnretainedValue().append(pointer, count: Int(count))
}
