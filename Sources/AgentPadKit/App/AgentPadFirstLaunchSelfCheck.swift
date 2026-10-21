#if DEBUG
import AppKit
import CoreGraphics

/// A separate process per configuration: the first libghostty initialization
/// cannot be tested by reloading a singleton in the XCTest host.
@MainActor
public enum AgentPadFirstLaunchSelfCheck {
    enum Failure: Error { case check(String) }
    private struct NoCredentials: ChatTokenStore {
        func accounts() throws -> [String] { [] }
        func read(account: String) throws -> String? { nil }
        func write(_ token: String, account: String) throws { throw Failure.check("Startup check attempted credential storage") }
        func delete(account: String) throws { throw Failure.check("Startup check attempted credential deletion") }
    }
    private(set) static var checks = 0
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw Failure.check(message) }
    }
    static var screenUnlocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        return session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session[kCGSessionLoginDoneKey as String] as? Bool == true
            && session["CGSSessionScreenIsLocked"] as? Bool != true
    }
    static func attribute(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let key = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier"][name]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let key, object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: key)?.takeUnretainedValue()
    }
    static func nodes(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = [], queue = [root], seen: Set<ObjectIdentifier> = []
        while let object = queue.popLast(), result.count < 4000 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            queue += attribute(object, "accessibilityChildren") as? [NSObject] ?? []
            if let view = object as? NSView { queue += view.subviews }
        }
        return result
    }
    static func element(_ identifier: String, in window: NSWindow) -> NSObject? {
        nodes(window).first { attribute($0, "accessibilityIdentifier") as? String == identifier }
    }
    static func focusedView(in window: NSWindow) -> NSView? {
        guard let responder = window.firstResponder as? NSView else { return nil }
        if let editor = responder as? NSTextView, let field = editor.delegate as? NSView { return field }
        return responder
    }
    static func containsFocus(_ dialog: NSView, in window: NSWindow) -> Bool {
        focusedView(in: window)?.isDescendant(of: dialog) == true
    }
    /// AppKit's text-input-only keyboard mode excludes the SwiftUI button from
    /// its native key loop. Use a mounted native opener in that case, while
    /// dispatching the real Choose startup settings action (never presentChoice
    /// directly). Its exact NSResponder identity is the restoration assertion.
    private final class StartupOpenerProbe: NSButton {
        var actionFailure: Error?
        override var acceptsFirstResponder: Bool { true }
        @objc func openChoice(_ sender: Any?) {
            actionFailure = nil
            guard let window else {
                actionFailure = Failure.check("Startup test opener is not mounted")
                return
            }
            do { try AgentPadFirstLaunchSelfCheck.press("startup-choose-settings", in: window) }
            catch { actionFailure = error }
        }
    }
    static func focusStartupOpener(in window: NSWindow) async throws -> NSObject {
        try await until("the startup opener") { element("startup-choose-settings", in: window) != nil }
        let opener = element("startup-choose-settings", in: window)!
        if let view = opener as? NSView, view.acceptsFirstResponder,
           window.makeFirstResponder(view), window.firstResponder === view { return opener }
        let probe: StartupOpenerProbe
        if let existing = nodes(window).compactMap({ $0 as? StartupOpenerProbe }).first {
            probe = existing
        } else {
            guard let content = window.contentView else { throw Failure.check("Startup has no content view") }
            probe = StartupOpenerProbe(title: "Choose startup settings", target: nil, action: nil)
            probe.target = probe
            probe.action = #selector(StartupOpenerProbe.openChoice(_:))
            probe.setAccessibilityIdentifier("startup-native-test-opener")
            probe.frame = NSRect(x: 24, y: 24, width: 210, height: 28)
            content.addSubview(probe)
            print("Ghostty matrix opener: mounted DEBUG NSButton dispatches the production startup-choose-settings action; original \(type(of: opener)) has no native keyboard focus")
        }
        try require(probe.window === window && !probe.isHiddenOrHasHiddenAncestor,
                    "Startup test opener is not mounted and visible")
        try require(window.makeFirstResponder(probe) && window.firstResponder === probe,
                    "Startup test opener did not accept native keyboard focus")
        return probe
    }
    static func activateStartupOpener(_ opener: NSObject, in window: NSWindow) throws {
        if let probe = opener as? StartupOpenerProbe {
            try require(window.firstResponder === probe, "Startup action lost its native opener")
            probe.performClick(nil)
            if let failure = probe.actionFailure { throw failure }
        } else {
            try press("startup-choose-settings", in: window)
        }
    }
    static func removeStartupOpenerProbe(in window: NSWindow) {
        for probe in nodes(window).compactMap({ $0 as? StartupOpenerProbe }) {
            if window.firstResponder === probe { window.makeFirstResponder(nil) }
            probe.removeFromSuperview()
        }
    }
    static func openerHasFocus(_ opener: NSObject, in window: NSWindow) -> Bool {
        if let probe = opener as? StartupOpenerProbe {
            return probe.window === window && !probe.isHiddenOrHasHiddenAncestor && window.firstResponder === probe
        }
        // SwiftUI may recreate its AX node when the covered startup content
        // becomes accessible again; the mounted control keeps its identifier.
        let current = (attribute(opener, "accessibilityIdentifier") as? String)
            .flatMap { element($0, in: window) } ?? opener
        if let view = current as? NSView, let focused = focusedView(in: window) {
            return focused === view || focused.isDescendant(of: view)
        }
        return false
    }
    static func assertInitialFocus(_ dialog: NSView, in window: NSWindow) throws {
        try require(!nodes(dialog).contains { ($0 as? NSTextField)?.isEditable == true },
                    "Ghostty import unexpectedly has an editable first field")
        // A button-only page uses AppKit's first eligible key view. With the
        // system's text-input-only keyboard setting, the dialog itself is the
        // eligible fallback; no fabricated text field is inserted by the test.
        let next = dialog.nextValidKeyView
        let expected = next.flatMap { $0.isDescendant(of: dialog) ? $0 : nil } ?? dialog
        try require(focusedView(in: window) === expected,
                    "Ghostty initial focus did not reach its first eligible control: expected \(type(of: expected)); actual \(String(describing: window.firstResponder))")
    }
    static func assertTraversal(_ panel: NSView, window: NSWindow, name: String) async throws -> String {
        // Read AppKit's eligible key loop independently of dispatched Tab events.
        // Normalize field editors: multiple text fields share one NSTextView.
        var eligible: [NSView] = []
        var seen: Set<ObjectIdentifier> = []
        var next = panel.nextValidKeyView
        while let view = next, seen.insert(ObjectIdentifier(view)).inserted {
            try require(seen.count < 512, "\(name) native key loop did not terminate")
            // The hosting dialog redirects focus into its fields; it is a
            // boundary/fallback, not an additional eligible form control.
            if view !== panel && view.isDescendant(of: panel) { eligible.append(view) }
            next = view.nextValidKeyView
        }
        if eligible.isEmpty { eligible = [panel] }
        let controlCount = eligible.filter { $0 !== panel }.count
        func describe(_ view: NSView?) -> String {
            guard let view else { return "nil" }
            return "\(type(of: view)):\((view as? NSTextField)?.placeholderString ?? view.accessibilityIdentifier()):\(ObjectIdentifier(view))"
        }
        print("Matrix key loop: \(name) \(eligible.map { describe($0) })")
        guard let start = focusedView(in: window), let startIndex = eligible.firstIndex(where: { $0 === start }) else {
            throw Failure.check("\(name) focus is not in its eligible native key loop")
        }
        for backwards in [false, true] {
            let direction = backwards ? "Shift-Tab" : "Tab"
            let expected = (1...eligible.count).map { offset in
                eligible[(startIndex + (backwards ? eligible.count - offset : offset)) % eligible.count]
            }
            var visited: [ObjectIdentifier] = []
            // AppKit can visit the dialog boundary on reverse traversal, while
            // its hosting view forwards forward traversal into the first field.
            // Ignore that boundary in the control sequence, but require the
            // independently read key-loop order (reversed for Shift-Tab),
            // including the final wrap back to the starting control.
            for step in 1...max(1, controlCount + 1) {
                let before = focusedView(in: window)
                key("\t", code: 48, in: window, modifiers: backwards ? .shift : [])
                try await Task.sleep(for: .milliseconds(15))
                try require(containsFocus(panel, in: window), "\(name) allowed \(direction) focus outside its popup")
                // The dialog is a focus boundary/fallback, not a second control.
                guard controlCount > 1 else { continue }
                let after = focusedView(in: window)
                try require(after !== before, "\(name) \(direction) step \(step) did not move between \(controlCount) eligible controls; before=\(describe(before)) after=\(describe(after))")
                try require(after === panel || eligible.contains(where: { $0 === after }),
                            "\(name) \(direction) moved outside its eligible control loop")
                print("Matrix traversal: \(name) \(direction) step \(step): \(describe(before)) -> \(describe(after))")
                if after === panel {
                    try require(before === (backwards ? eligible.first : eligible.last),
                                "\(name) \(direction) reached the dialog boundary before the control-loop boundary")
                    continue
                }
                let expectedControl = expected[visited.count]
                try require(after === expectedControl,
                            "\(name) \(direction) control \(visited.count + 1) is out of order; expected=\(describe(expectedControl)) actual=\(describe(after))")
                visited.append(ObjectIdentifier(expectedControl))
                if after === start { break }
            }
            if controlCount > 1 {
                try require(visited == expected.map(ObjectIdentifier.init),
                            "\(name) \(direction) did not visit every eligible control in order and wrap to its starting control")
            }
        }
        return controlCount > 1 ? "pass: forward order and reverse order with wrap across \(controlCount) controls"
            : "pass: \(controlCount) eligible controls; focus remains contained"
    }

    /// Keyboard ownership is the offscreen window's firstResponder model.
    static func nativeRow(_ name: String, in window: NSWindow,
                          reset: () async throws -> Void, check: () async throws -> Void) async throws {
        try require(screenUnlocked, "\(name): native row requires an unlocked console")
        AgentPadQuietUI.select(window)
        try AgentPadQuietUI.assertQuiet()
        try await reset()
        do { try await check() }
        catch { throw Failure.check("Ghostty matrix \(name): \(error)") }
        try AgentPadQuietUI.assertQuiet()
        print("Ghostty matrix \(name): PASS (quiet firstResponder model)")
    }
    static func press(_ identifier: String, in window: NSWindow) throws {
        guard let object = element(identifier, in: window) else { throw Failure.check("Missing button: \(identifier)") }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        try require(object.responds(to: selector), "Button has no press action: \(identifier)")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(object.method(for: selector), to: Press.self)
        try require(action(object, selector), "Button press failed: \(identifier)")
    }
    static func key(_ character: String, code: UInt16, in window: NSWindow,
                    modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        AgentPadQuietUI.send(event, to: window)
    }
    static func scrim(_ window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            AgentPadQuietUI.send(event, to: window)
        }
    }
    static func ready(_ startup: AgentPadStartupWindowController) async throws -> NSView {
        do {
            try await until("the Ghostty import popup layout") {
                startup.window?.contentView?.layoutSubtreeIfNeeded()
                guard let window = startup.window,
                      let dialog = element("popup-dialog", in: window) as? NSView,
                      case .native(let page) = startup.popups.page, let height = page.contentHeight,
                      abs(dialog.bounds.height - height - 63) < 1 else { return false }
                return dialog.visibleRect.contains(dialog.bounds)
                    && element("ghostty-import", in: window) != nil && element("ghostty-fresh", in: window) != nil
            }
        } catch {
            if let window = startup.window {
                let dialog = element("popup-dialog", in: window) as? NSView
                let height: CGFloat? = if case .native(let page) = startup.popups.page { page.contentHeight } else { nil }
                print("Startup layout: bounds=\(String(describing: dialog?.bounds)) visible=\(String(describing: dialog?.visibleRect)) measured=\(String(describing: height)) import=\(element("ghostty-import", in: window) != nil) fresh=\(element("ghostty-fresh", in: window) != nil)")
                let ids = nodes(window).map { "\(type(of: $0)) id=\(attribute($0, "accessibilityIdentifier") ?? "")" }.joined(separator: "\n")
                try? ids.write(to: AgentPadSettings.directory.deletingLastPathComponent().appendingPathComponent("startup-accessibility.txt"), atomically: true, encoding: .utf8)
                try? screenshot(window, to: AgentPadSettings.directory.deletingLastPathComponent().appendingPathComponent("startup-layout.png"))
            }
            throw error
        }
        return element("popup-dialog", in: startup.window!) as! NSView
    }
    static func screenshot(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure.check("Could not capture startup window")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.check("Could not encode startup window") }
        try png.write(to: url)
    }
    static func until(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let ready = await condition()
        try require(ready, "Timed out waiting for \(message); app active: \(NSApp.isActive), key window: \(String(describing: NSApp.keyWindow?.windowNumber))")
    }
    public static func run() -> Never {
        guard ProcessInfo.processInfo.environment["AGENTPAD_DEBUG_CONFIG_DIRECTORY"] != nil,
              ProcessInfo.processInfo.environment["AGENTPAD_DEBUG_STATE_PATH"] != nil,
              let mode = CommandLine.arguments.last else { exit(2) }
        AgentPadQuietUI.start()
        let app = NSApplication.shared
        app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                    with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        AgentPadFonts.registerOnce()
        let delegate = AppDelegate(appPersistence: AppPersistence(),
            agentProfiles: AgentProfileStore(accountTokens: NoCredentials()))
        Task { @MainActor in
            do {
                try await delegate.checkFirstLaunch(mode: mode)
                await delegate.endFirstLaunchCheck()
                try AgentPadQuietUI.finish()
                print("First launch \(mode): PASS (\(checks) checks)"); exit(0)
            } catch {
                await delegate.endFirstLaunchCheck()
                try? AgentPadQuietUI.finish()
                fputs("First launch \(mode): FAIL: \(error)\n", stderr); exit(1)
            }
        }
        app.run()
        exit(1)
    }
}
#endif
