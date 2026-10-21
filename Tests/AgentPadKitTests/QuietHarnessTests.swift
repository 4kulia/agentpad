import AppKit
import AVFoundation
import AgentPadQuietTestSupport
import ObjectiveC
import XCTest

@MainActor
final class QuietHarnessTests: XCTestCase {
    private func requireContainment() throws {
        // Never exercise activation, ordering or audio unless the mandatory
        // process loader has already installed all boundaries, including dyld.
        XCTAssertTrue(APQuietIsEnabled(), "XCTest must bootstrap quiet mode before its first fixture")
        guard APQuietIsEnabled() else { throw NSError(domain: "QuietHarness", code: 1) }
        _ = NSApplication.shared
        XCTAssertNil(APQuietFailure())
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 20, y: 30, width: 400, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func assertInvisible(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(window.alphaValue, 0, file: file, line: line)
        XCTAssertTrue(window.ignoresMouseEvents, file: file, line: line)
        XCTAssertFalse(window.hasShadow, file: file, line: line)
        XCTAssertFalse(APQuietWindowHasOSFocus(window), "AppKit key/main ownership must stay absent", file: file, line: line)
        XCTAssertNil(APQuietFailure(), file: file, line: line)
    }

    func testAutomaticBootstrapAndEveryWindowStayInvisible() throws {
        try requireContainment()
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        let window = makeWindow()
        defer { window.close() }
        XCTAssertFalse(window.isVisible)
        assertInvisible(window)
        window.center()
        window.setFrame(NSRect(x: 0, y: 0, width: 500, height: 350), display: true, animate: true)
        window.setFrameOrigin(.zero)
        window.setFrameTopLeftPoint(.zero)
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.hasShadow = true
        assertInvisible(window)
        APQuietSelectWindow(window)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(NSApp.keyWindow === window, "Menu routing uses the selected-window model")
        XCTAssertTrue(window.isKeyWindow && window.isMainWindow, "Product eligibility uses the selected-window routing model")
        XCTAssertFalse(APQuietWindowHasOSFocus(window), "The routing model must never acquire real desktop ownership")
        assertInvisible(window)
    }

    func testActivationAndFullscreenRequestsCannotReachTheDesktop() throws {
        try requireContainment()
        let window = makeWindow()
        defer { window.close() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        if let screen = NSScreen.screens.first {
            XCTAssertFalse(window.contentView!.enterFullScreenMode(screen))
        }
        assertInvisible(window)
    }

    func testWindowOrderingAnimationsCannotBeEnabled() throws {
        try requireContainment()
        let window = makeWindow()
        defer { window.close() }
        XCTAssertEqual(window.animationBehavior, .none)
        window.animationBehavior = .utilityWindow
        XCTAssertEqual(window.animationBehavior, .none)
        assertInvisible(window)
    }

    func testRequestedFramesSurviveSelectionAndEveryPlacementAPI() throws {
        try requireContainment()
        let window = makeWindow()
        defer { window.close() }
        XCTAssertEqual(window.frame, window.frameRect(forContentRect: NSRect(x: 20, y: 30, width: 400, height: 300)))
        let requested = NSRect(x: 50, y: 60, width: 500, height: 350)
        window.setFrame(requested, display: true, animate: true)
        XCTAssertEqual(window.frame, requested)
        APQuietSelectWindow(window)
        XCTAssertEqual(window.frame, requested)
        window.setFrameOrigin(NSPoint(x: 70, y: 90))
        XCTAssertEqual(window.frame, NSRect(x: 70, y: 90, width: 500, height: 350))
        window.setFrameTopLeftPoint(NSPoint(x: 80, y: 500))
        XCTAssertEqual(window.frame, NSRect(x: 80, y: 150, width: 500, height: 350))
        XCTAssertFalse(APQuietWindowHasOSFocus(window))
        assertInvisible(window)
    }

    func testApplicationMonitorsRunBeforeAnOverriddenWindowSinkAndCanConsumeEvents() throws {
        try requireContainment()
        let window = EventSink(contentRect: NSRect(x: 20, y: 30, width: 400, height: 300),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var intercepted = 0
        let monitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            intercepted += 1
            XCTAssertEqual(window.receivedEvents, intercepted - 1)
            return intercepted == 3 ? nil : event
        })
        defer { NSEvent.removeMonitor(monitor) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        NSApp.sendEvent(event)
        APQuietSendEvent(event, window)
        NSApp.sendEvent(event)
        XCTAssertEqual(intercepted, 3)
        XCTAssertEqual(window.receivedEvents, 2)
        XCTAssertFalse(APQuietWindowHasOSFocus(window))
        assertInvisible(window)
    }

    func testLowerLevelFocusEntryCannotGrantDesktopOwnershipToAnEligibleSubclass() throws {
        try requireContainment()
        // Spy on the saved AppKit entry points so a broken guard fails without
        // ever granting real focus, even during a regression/mutation check.
        let keyMethod = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, NSSelectorFromString("apq_becomeKeyWindow")))
        let mainMethod = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, NSSelectorFromString("apq_becomeMainWindow")))
        var keyEntries = 0, mainEntries = 0
        let keySpy = imp_implementationWithBlock({ (_: NSWindow) in keyEntries += 1 } as @convention(block) (NSWindow) -> Void)
        let mainSpy = imp_implementationWithBlock({ (_: NSWindow) in mainEntries += 1 } as @convention(block) (NSWindow) -> Void)
        let keyOriginal = method_setImplementation(keyMethod, keySpy)
        let mainOriginal = method_setImplementation(mainMethod, mainSpy)
        defer {
            method_setImplementation(keyMethod, keyOriginal)
            method_setImplementation(mainMethod, mainOriginal)
            imp_removeBlock(keySpy)
            imp_removeBlock(mainSpy)
        }
        let window = FocusEligibleWindow(contentRect: NSRect(x: 30, y: 40, width: 400, height: 300),
                                         styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertTrue(window.canBecomeKey && window.canBecomeMain)
        APQuietSelectWindow(window)
        window.becomeKey()
        window.becomeMain()
        XCTAssertEqual(keyEntries, 0)
        XCTAssertEqual(mainEntries, 0)
        assertInvisible(window)
    }

    func testLocalMonitorsAndFirstResponderReceiveDirectWindowEvents() throws {
        try requireContainment()
        let window = makeWindow(), view = KeyReceiver(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { window.close() }
        window.contentView = view
        APQuietSelectWindow(window)
        XCTAssertTrue(window.makeFirstResponder(view))
        var intercepted = 0
        let monitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            intercepted += 1
            return event
        })
        defer { NSEvent.removeMonitor(monitor) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        APQuietSendEvent(event, window)
        NSApp.sendEvent(event)
        window.sendEvent(event)
        XCTAssertEqual(intercepted, 3)
        XCTAssertEqual(view.receivedKeys, 3)
        XCTAssertTrue(window.firstResponder === view)
        window.orderOut(nil)
        APQuietSendEvent(event, window)
        XCTAssertFalse(window.isVisible, "Sending an event must not reveal a closed fixture")
        assertInvisible(window)
    }

    func testRealPopoverStaysInvisibleWithoutDesktopOwnership() throws {
        try requireContainment()
        let owner = makeWindow()
        defer { owner.close() }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        APQuietSelectWindow(owner)
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.show(relativeTo: NSRect(x: 20, y: 20, width: 10, height: 10),
                     of: try XCTUnwrap(owner.contentView), preferredEdge: .maxY)
        defer { popover.close() }
        let child = try XCTUnwrap(controller.view.window)
        XCTAssertTrue(popover.isShown)
        XCTAssertFalse(child === owner)
        XCTAssertTrue(owner.isKeyWindow && owner.isMainWindow)
        // The aliases hold the original NSApplication getters. These must stay
        // nil even if the window getter delegates to its parent's routing model.
        XCTAssertNil(NSApp.perform(NSSelectorFromString("apq_keyWindow"))?.takeUnretainedValue())
        XCTAssertNil(NSApp.perform(NSSelectorFromString("apq_mainWindow"))?.takeUnretainedValue())
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
        assertInvisible(owner)
        assertInvisible(child)
    }

    func testInternalHelperEventsPreserveTheSelectedOwner() throws {
        try requireContainment()
        let owner = makeWindow(), helper = makeWindow()
        defer { helper.close(); owner.close() }
        APQuietSelectWindow(owner)
        // Text-input helpers receive these AppKit run-loop events even while
        // the app is prohibited and every window is invisible.
        let event = try XCTUnwrap(NSEvent.otherEvent(with: .appKitDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: helper.windowNumber, context: nil,
            subtype: 0, data1: 0, data2: 0))
        XCTAssertTrue(event.window === helper)
        NSApp.sendEvent(event)
        XCTAssertTrue(NSApp.keyWindow === owner, "An internal helper event must not replace the explicit routing owner")
        XCTAssertTrue(NSApp.mainWindow === owner)
        XCTAssertFalse(helper.isVisible)
        assertInvisible(owner)
        assertInvisible(helper)
    }

    func testHiddenSelectedWindowHasNoRoutingFocusUntilSelectedAgain() throws {
        try requireContainment()
        let window = makeWindow(), view = KeyReceiver(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { window.close() }
        window.contentView = view
        APQuietSelectWindow(window)
        XCTAssertTrue(window.makeFirstResponder(view))
        window.orderOut(nil)

        func assertHiddenWithoutFocus(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(window.isVisible, file: file, line: line)
            XCTAssertNil(NSApp.keyWindow, file: file, line: line)
            XCTAssertNil(NSApp.mainWindow, file: file, line: line)
            XCTAssertFalse(window.isKeyWindow, file: file, line: line)
            XCTAssertFalse(window.isMainWindow, file: file, line: line)
            assertInvisible(window, file: file, line: line)
        }
        assertHiddenWithoutFocus()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        APQuietSendEvent(event, window)
        XCTAssertEqual(view.receivedKeys, 1)
        assertHiddenWithoutFocus()

        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "Hidden receiver", action: #selector(KeyReceiver.receiveShortcut(_:)), keyEquivalent: "x")
        menu.addItem(item)
        let shortcut = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        XCTAssertFalse(menu.performKeyEquivalent(with: shortcut))
        XCTAssertEqual(view.receivedShortcuts, 0)

        APQuietSelectWindow(window)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(NSApp.keyWindow === window && NSApp.mainWindow === window)
        XCTAssertTrue(window.isKeyWindow && window.isMainWindow)
        XCTAssertTrue(menu.performKeyEquivalent(with: shortcut))
        XCTAssertEqual(view.receivedShortcuts, 1)
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
        assertInvisible(window)
    }

    func testCAndFrameworkSoundsAreInterceptedAndMediaStaysMuted() throws {
        try requireContainment()
        let initial = APQuietMutedSoundCount()
        NSSound.beep()
        XCTAssertEqual(APQuietMutedSoundCount(), initial + 1)
        let beforeFrameworkCall = APQuietMutedSoundCount()
        // NSResponder's implementation calls NSBeep from inside AppKit. This
        // proves more than substituting the app's direct C symbol.
        NSResponder().noResponder(for: #selector(NSResponder.keyDown(with:)))
        XCTAssertEqual(APQuietMutedSoundCount(), beforeFrameworkCall + 1)
        let sound = try XCTUnwrap(NSSound(named: "Basso"))
        XCTAssertFalse(sound.play())
        XCTAssertEqual(APQuietMutedSoundCount(), beforeFrameworkCall + 2)
        let player = AVPlayer()
        player.isMuted = false
        player.play()
        XCTAssertTrue(player.isMuted)
        player.pause()
        let beforeAnnouncement = APQuietMutedSoundCount()
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: "quiet fixture", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        XCTAssertEqual(APQuietMutedSoundCount(), beforeAnnouncement + 1)
        XCTAssertNil(APQuietFailure())
    }

    func testTabResponderModelMovesAndWrapsOnlyWhenTraversalIsRequested() throws {
        try requireContainment()
        let window = makeWindow()
        defer { window.close() }
        let first = NSTextField(frame: NSRect(x: 20, y: 180, width: 300, height: 24))
        let second = NSTextField(frame: NSRect(x: 20, y: 140, width: 300, height: 24))
        window.contentView!.addSubview(first)
        window.contentView!.addSubview(second)
        APQuietSelectWindow(window)
        window.recalculateKeyViewLoop()
        first.nextKeyView = second
        second.nextKeyView = first
        XCTAssertTrue(window.makeFirstResponder(first))
        func focusedField() -> NSTextField? {
            if let editor = window.firstResponder as? NSTextView { return editor.delegate as? NSTextField }
            return window.firstResponder as? NSTextField
        }
        window.selectNextKeyView(nil)
        XCTAssertTrue(focusedField() === second)
        window.selectNextKeyView(nil)
        XCTAssertTrue(focusedField() === first, "The firstResponder loop must wrap")
        window.selectPreviousKeyView(nil)
        XCTAssertTrue(focusedField() === second, "Reverse traversal must wrap")
        window.selectPreviousKeyView(nil)
        XCTAssertTrue(focusedField() === first)
        assertInvisible(window)
    }

    private final class KeyReceiver: NSView {
        var receivedKeys = 0
        var receivedShortcuts = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { receivedKeys += 1 }
        @objc func receiveShortcut(_ sender: Any?) { receivedShortcuts += 1 }
    }

    private final class EventSink: NSWindow {
        var receivedEvents = 0
        override func sendEvent(_ event: NSEvent) { receivedEvents += 1 }
    }

    private final class FocusEligibleWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}
