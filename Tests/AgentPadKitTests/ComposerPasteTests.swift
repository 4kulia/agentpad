import AppKit
import XCTest
@testable import AgentPadKit

/// Exercise AppKit menu validation and key-equivalent dispatch. Calling
/// editor.paste directly would miss the disabled-Paste regression entirely.
@MainActor final class ComposerPasteTestWindow {
    let window: NSWindow
    let mainMenu = NSMenu()
    let editMenu = NSMenu(title: "Edit")
    let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    private let previousMenu: NSMenu?
    private let previousWindow: NSWindow?
    private let clipboard: [[NSPasteboard.PasteboardType: Data]]

    init(content: NSView) {
        let app = NSApplication.shared
        previousMenu = app.mainMenu; previousWindow = app.keyWindow
        clipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content
        let applicationMenu = NSMenuItem(title: "AgentPad Paste Test", action: nil, keyEquivalent: "")
        applicationMenu.submenu = NSMenu(title: "AgentPad Paste Test"); mainMenu.addItem(applicationMenu)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = editMenu; mainMenu.addItem(edit)
        paste.keyEquivalentModifierMask = .command; editMenu.addItem(paste)
        app.mainMenu = mainMenu
        window.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()
    }
    func close() {
        NSApp.mainMenu = previousMenu
        window.contentView = nil; window.close(); previousWindow?.makeKey()
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects(clipboard.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        })
    }
    func focus(_ editor: NSTextView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(window.makeFirstResponder(editor), file: file, line: line)
        XCTAssertTrue(window.firstResponder === editor, file: file, line: line)
        // The command-line XCTest host cannot become an active application.
        // Resolve the menu target from the real window's first responder;
        // NSMenu still performs its native validation and Command-V dispatch.
        paste.target = window.firstResponder
    }
    func commandV(file: StaticString = #filePath, line: UInt = #line) throws {
        editMenu.update()
        XCTAssertTrue(paste.isEnabled, "Edit > Paste must be enabled for the current pasteboard", file: file, line: line)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9), file: file, line: line)
        XCTAssertTrue(mainMenu.performKeyEquivalent(with: event), file: file, line: line)
    }
}

@MainActor final class ComposerPasteTests: XCTestCase {
    func testTerminalComposerEnablesImagePasteAndKeepsNativeTextPaste() async throws {
        let editor = ComposerNSTextView(); editor.isRichText = false
        let ui = ComposerPasteTestWindow(content: editor)
        defer { ui.close() }
        ui.focus(editor)
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        let board = NSPasteboard.general
        board.clearContents(); board.setData(image.representation(using: .png, properties: [:])!, forType: .png)
        XCTAssertTrue(editor.validateMenuItem(ui.paste))
        XCTAssertTrue(editor.validateUserInterfaceItem(ui.paste))
        try ui.commandV()
        let deadline = ContinuousClock.now + .seconds(5)
        while editor.string.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(editor.string.hasSuffix(".png"), editor.string)
        XCTAssertEqual(editor.string.components(separatedBy: ".png").count, 2)
        editor.string = ""; editor.setSelectedRange(NSRange(location: 0, length: 0))
        board.clearContents(); board.setString("plain text", forType: .string)
        try ui.commandV()
        XCTAssertEqual(editor.string, "plain text")
        editor.isEditable = false
        ui.editMenu.update(); XCTAssertFalse(ui.paste.isEnabled)
    }
}
