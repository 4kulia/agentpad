#if DEBUG
import AppKit
import AVFoundation
@testable import AgentPadTelegram
import CoreGraphics
import GRDB
import SwiftUI

/// Standalone AppKit/AX run, outside XCTest's host. It starts no app services,
/// reads no saved workspaces and writes only its temporary test profile.
@MainActor
public enum AgentPadNoModalsSelfCheck {
    public static func run() -> Never {
        AgentPadQuietUI.start()
        let app = NSApplication.shared
        AgentPadFonts.registerOnce()
        app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                    with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let probe = NoModalsUIProbe()
        Task { @MainActor in
            // The full composition family renders both themes and traverses
            // every control. Offscreen rendering can exceed two minutes.
            try? await Task.sleep(for: .seconds(300))
            fputs("No-modals UI/AX: FAIL: timed out\n", stderr); exit(1)
        }
        Task { @MainActor in
            do {
                try await probe.run()
                try AgentPadQuietUI.finish()
                let label = probe.captureOnly ? "Popup rendered captures" : "No-modals UI/AX"
                print("\(label): PASS (\(probe.checks) checks, \(probe.screenshotCount) screenshots)")
                exit(0)
            }
            catch { try? AgentPadQuietUI.finish(); fputs("No-modals UI/AX: FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
        exit(1)
    }
}

@MainActor
private final class NoModalsUIProbe: NSObject {
    enum Failure: Error { case check(String) }
    private let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/pop1-fixture-\(UUID())")
    private let shots = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENTPAD_POPUP_SHOTS"]
        ?? FileManager.default.currentDirectoryPath + "/.build/pop1-shots")
    private let tokens = UIProbeTokens()
    private let telegram = TelegramSettingsViewModel(connector: UIProbeTelegramConnector())
    private lazy var profiles = AgentProfileStore(
        fileURL: directory.appendingPathComponent("profiles.json"),
        details: AgentProfileDetailsStore(fileURL: directory.appendingPathComponent("profile-details.json")),
        accountTokens: tokens)
    private var screenshotNames: [String] = []
    let captureOnly = ProcessInfo.processInfo.environment["AGENTPAD_POPUP_CAPTURE_ONLY"] == "1"
    var screenshotCount: Int { screenshotNames.count }
    private(set) var checks = 0
    private lazy var appPersistence = AppPersistence(fileURL: directory.appendingPathComponent("state-v2.json"))
    private lazy var sessionNames = SessionNames(url: directory.appendingPathComponent("session-names.sqlite"))
    private var stores: [WorkspaceStore] = []
    private var windows: [NSWindow] = []
    private var windowControllers: [AgentPadWindowController] = []
    private var phaseThreeMenuDelegate: AppDelegate?
    private var phaseThreeWindowItem: NSMenuItem?
    private var phaseThreeOtherWindow: NSWindow?
    private var current: WorkspaceStore?
    private var processRequests = 0
    private var modalWatch: Timer?
    private var unexpectedWindow = false
    private var completionHelpers: Set<Int> = []
    private var matrixEvidence: [[String: String]] = []
    private var matrixFailures: [String] = []
    private let support = SupportTabs.shared
    private var storedSettings: [String: Any] = [:]
    private lazy var model = AgentPadSettingsModel(read: { [weak self] in self?.storedSettings },
        write: { [weak self] in self?.storedSettings = $0 }, appliesRuntimeEffects: false)

    private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !value() { throw Failure.check(message) }
    }
    private func settle() async { try? await Task.sleep(for: .milliseconds(180)) }
    private func eventually(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        // Let AppKit commit pending layout between readiness probes.
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        try require(condition(), message)
    }
    private func host() -> WorkspaceStore {
        if let current { return current }
        return newWindow()
    }
    private func workspaceView(_ workspace: Workspace, store: WorkspaceStore) -> NSView {
        NSHostingView(rootView: UIProbeWorkspaceRoot(workspace: workspace, store: store))
    }
    @discardableResult private func newWindow(appController: Bool = false) -> WorkspaceStore {
        let windowID = UUID()
        let persistence = WindowPersistence(windowId: windowID, app: appPersistence)
        let store = WorkspaceStore(persistence: persistence, initiallyEmpty: true, agentProfiles: profiles,
            sessionNames: sessionNames, engineFactory: { [weak self] in
            self?.processRequests += 1
            return NativeTabEngine(state: TabState(route: .unavailable(UUID())), tabID: UUID())
        }, peerStores: { [weak self] in self?.stores ?? [] })
        let window: NSWindow
        if appController {
            let controller = AgentPadWindowController(windowId: windowID, store: store)
            windowControllers.append(controller)
            window = controller.window!
            window.setContentSize(NSSize(width: 1180, height: 820))
        } else {
            window = NSWindow(contentRect: NSRect(x: 80 + stores.count * 32, y: 80, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        }
        window.title = "AgentPad · no-modals test profile"
        window.isReleasedWhenClosed = false
        window.contentView = workspaceView(store.active!, store: store)
        stores.append(store); windows.append(window); current = store
        AgentPadQuietUI.select(window)
        return store
    }
    private func reveal(_ store: WorkspaceStore) {
        guard let index = stores.firstIndex(where: { $0 === store }) else { return }
        current = store; AgentPadQuietUI.select(windows[index])
    }
    @objc private func settings() { support.settings() }
    @objc private func inbox() { support.navigation.open(.notifications) }
    @objc private func closeTab() {
        guard let store = current, let workspace = store.active, let tab = workspace.activeSession else { return }
        store.closeTab(tab, in: workspace)
    }
    private func shortcut(_ character: String, modifiers: NSEvent.ModifierFlags = .command) throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
        try require(NSApp.mainMenu?.performKeyEquivalent(with: event) == true, "shortcut \(character) did not route")
    }
    private func menu() {
        let root = NSMenu(), item = NSMenuItem(), commands = NSMenu()
        for (title, action, key) in [("Settings", #selector(settings), ","), ("Notifications", #selector(inbox), "i"), ("Close Tab", #selector(closeTab), "w")] {
            let command = NSMenuItem(title: title, action: action, keyEquivalent: key)
            command.target = self; command.keyEquivalentModifierMask = .command; commands.addItem(command)
        }
        item.submenu = commands; root.addItem(item); NSApp.mainMenu = root
    }
    /// SwiftUI exports NSObject AX nodes that are not NSViews. Walk the public
    /// accessibility selectors so labels/IDs are tested on the rendered tree.
    private func attribute(_ object: NSObject, _ name: String) -> Any? {
        if name == "accessibilityEnabled" {
            for selectorName in ["isAccessibilityEnabled", "accessibilityEnabled"] {
                let selector = NSSelectorFromString(selectorName)
                if object.responds(to: selector) {
                    typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
                    let function = unsafeBitCast(object.method(for: selector), to: Enabled.self)
                    return NSNumber(value: function(object, selector))
                }
            }
        }
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let key = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier", "accessibilityLabel": "AXDescription", "accessibilityRole": "AXRole",
                   "accessibilitySubrole": "AXSubrole", "accessibilityTitle": "AXTitle", "accessibilityEnabled": "AXEnabled"][name]
        guard let key else { return nil }
        return object.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: key)?.takeUnretainedValue()
    }
    private func nodes(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = [], queue = [root], seen: Set<ObjectIdentifier> = []
        while let object = queue.popLast(), result.count < 4000 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            queue += (attribute(object, "accessibilityChildren") as? [NSObject]) ?? []
            if let view = object as? NSView { queue += view.subviews }
        }
        return result
    }
    private func element(_ identifier: String, in window: NSWindow) -> NSObject? {
        nodes(window).first { attribute($0, "accessibilityIdentifier") as? String == identifier }
    }
    private func press(_ identifier: String, in window: NSWindow) throws {
        guard let object = element(identifier, in: window) else {
            try screenshot(window, name: "failure")
            let dump = nodes(window).map { object in
                "\(type(of: object)) id=\(attribute(object, "accessibilityIdentifier") ?? "") label=\(attribute(object, "accessibilityLabel") ?? "") frame=\((object as? NSView)?.frame ?? .zero)"
            }.joined(separator: "\n")
            try dump.write(to: shots.appendingPathComponent("accessibility.txt"), atomically: true, encoding: .utf8)
            print("UI profile and screenshots: \(shots.path)")
            throw Failure.check("AX missing: \(identifier)")
        }
        try press(object, name: identifier)
    }
    private func pressButton(_ title: String, in window: NSWindow) throws {
        let matches = nodes(window).filter {
            attribute($0, "accessibilityRole") as? String == "AXButton"
                && (attribute($0, "accessibilityLabel") as? String == title
                    || attribute($0, "accessibilityTitle") as? String == title)
        }
        try require(matches.count == 1, "Expected one native button named \(title); found \(matches.count)")
        try press(matches[0], name: title)
    }
    private func press(_ object: NSObject, name: String) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        if object.responds(to: selector) {
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let function = unsafeBitCast(object.method(for: selector), to: Press.self)
            try require(function(object, selector), "AX press failed: \(name)")
        } else {
            let actions = object.perform(NSSelectorFromString("accessibilityActionNames"))?.takeUnretainedValue() as? [String] ?? []
            try require(actions.contains("AXPress"), "AX button has no press action: \(name)")
            object.perform(NSSelectorFromString("accessibilityPerformAction:"), with: "AXPress")
        }
    }
    private func screenshot(_ window: NSWindow, name: String, record: Bool = true) throws {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure.check("Could not capture popup screenshot")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.check("Could not encode popup screenshot")
        }
        try png.write(to: shots.appendingPathComponent(name + ".png"))
        if record { screenshotNames.append(name + ".png") }
    }
    private func scrollToEnd(_ tab: Session) throws {
        guard let probe = nodes(tab.engine.view).compactMap({ $0 as? TabScrollPosition.Probe }).first,
              let clip = probe.clip, let document = clip.documentView else { throw Failure.check("Settings scroll view is unavailable") }
        clip.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - clip.bounds.height)))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
    }
    private func currentTool(_ store: WorkspaceStore, route: ToolRoute) throws -> Session {
        guard case .tool(let session) = store.popups.page, session.toolRoute == route else {
            throw Failure.check("Expected popup route: \(route.title)")
        }
        return session
    }
    private func dialog(_ window: NSWindow, title: String) throws -> NSView {
        guard let object = element("popup-dialog", in: window), let view = object as? NSView else {
            throw Failure.check("Popup has no native AX dialog boundary")
        }
        try require(attribute(object, "accessibilityRole") as? String == "AXGroup", "Popup AX role is not AXGroup")
        try require(attribute(object, "accessibilitySubrole") as? String == "AXDialog", "Popup AX subrole is not AXDialog")
        let label = attribute(object, "accessibilityLabel") as? String
        let axTitle = attribute(object, "accessibilityTitle") as? String
        try require(label == title || axTitle == title, "Popup accessible title did not follow its page")
        try require(nodes(window).filter { attribute($0, "accessibilityIdentifier") as? String == "popup-dialog" }.count == 1,
                    "More than one popup is visible in one window")
        return view
    }
    private func focusIsInside(_ dialog: NSView, window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        if responder.isDescendant(of: dialog) { return true }
        if let editor = responder as? NSTextView, let field = editor.delegate as? NSView {
            return field.isDescendant(of: dialog)
        }
        return false
    }
    private func key(_ character: String, code: UInt16, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        AgentPadQuietUI.send(event, to: window)
    }
    private func scrim(_ window: NSWindow) {
        // The scrim is intentionally hidden from AX; send a real window click.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            AgentPadQuietUI.send(event, to: window)
        }
    }
    private func accountForm(_ store: WorkspaceStore) throws -> ClaudeAccountForm {
        guard case .account(let form) = store.popups.page else { throw Failure.check("Account form is not visible") }
        return form
    }
    private func accountMenu(_ title: String, in window: NSWindow) throws {
        guard let popup = nodes(window).compactMap({ $0 as? NSPopUpButton }).first(where: {
            $0.menu?.items.contains { $0.title == title } == true
        }), let item = popup.menu?.items.first(where: { $0.title == title }) else {
            throw Failure.check("Native Claude account menu command is missing: \(title)")
        }
        popup.select(item)
        try require(popup.sendAction(popup.action, to: popup.target), "Native account menu command did not dispatch")
    }
    private func avatarImage() throws -> CGImage {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure.check("Could not create in-memory profile image")
        }
        context.setFillColor(CGColor(red: 0.25, green: 0.48, blue: 0.82, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else { throw Failure.check("Could not finish in-memory profile image") }
        return image
    }
    private func dismissAndCheck(_ store: WorkspaceStore, window: NSWindow, action: String) async throws {
        switch action {
        case "escape": key("\u{1b}", code: 53, in: window)
        case "scrim": scrim(window)
        default: try press("popup-close", in: window)
        }
        await settle()
        try require(!store.popups.isPresented, "\(action) did not dismiss the popup")
    }
    private func report() throws {
        let body = """
        # Popup selfcheck

        PASS: \(checks) isolated in-window popup UI and accessibility checks.
        - Startup deferral, independent window ownership, singleton Settings, content routes remain tabs.
        - All 15 Settings sections switched through accessibility buttons in dark and light.
        - Edit profile draft retention, Draft kept, Back from Add account, Cancel versus Save.
        - Native account menu Add/Manage commands return through Back without losing the profile draft.
        - Direct sidebar Edit profile entry has no Back; the Settings-to-profile screenshot is nested.
        - Profile photo Save applies pending name and closes; late completion preserves another popup.
        - Add and Replace token forms use generated credentials held only in memory.
        - Remove confirmation ignores Escape, scrim and X; explicit Cancel and Remove exercised.
        - AXGroup/AXDialog title, focus entry/traversal/return, Escape/scrim/X dismissal.
        - Installed content-navigation and Window-menu actions disabled for the selected offscreen popup owner.
        - No auxiliary NSWindow and no terminal process factory request.
        - Settings scroll retention and accessible icon import failure preserved.
        - Phase 2 groups C–F: every moved popup in dark/light, all five Connect steps, live Ask receipt and request review states.
        - Connect busy state, incidental dismissal/reopen and completed Close use isolated intercepted transport.
        - No real server sign-in, socket connection, terminal/worktree creation or request execution.
        - Screenshots: \(screenshotNames.count), captured from NSWindow content using AppKit bitmap caching.

        \(screenshotNames.sorted().map { "- " + $0 }.joined(separator: "\n"))
        """
        try body.write(to: shots.deletingLastPathComponent().appendingPathComponent("pop2-selfcheck-report.md"),
                       atomically: true, encoding: .utf8)
    }
    /// Quiet mode supplies the selected window to menu validation; keyboard
    /// assertions inspect that window's actual firstResponder.
    private func popupNavigationMenus() async throws {
        let originalMenu = NSApp.mainMenu, originalWindows = NSApp.windowsMenu, originalHelp = NSApp.helpMenu
        let previousKeyWindow = NSApp.keyWindow
        let windowID = UUID()
        let store = WorkspaceStore(persistence: WindowPersistence(windowId: windowID, app: appPersistence),
            initiallyEmpty: true, agentProfiles: profiles, engineFactory: { [weak self] in
                self?.processRequests += 1
                return NativeTabEngine(state: TabState(route: .unavailable(UUID())), tabID: UUID())
            })
        let controller = AgentPadWindowController(windowId: windowID, store: store)
        guard let window = controller.window else { throw Failure.check("Menu probe has no AgentPad window") }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        stores.append(store); windows.append(contentsOf: [window, other])
        defer {
            NSApp.removeWindowsItem(other); other.close(); controller.close(); store.terminate()
            stores.removeAll { $0 === store }
            windows.removeAll { $0 === window || $0 === other }
            NSApp.mainMenu = originalMenu; NSApp.windowsMenu = originalWindows; NSApp.helpMenu = originalHelp
            if let previousKeyWindow { AgentPadQuietUI.select(previousKeyWindow) }
        }
        let delegate = AppDelegate(appPersistence: appPersistence, agentProfiles: profiles)
        delegate.installMainMenu()
        NSApp.addWindowsItem(other, title: "Other popup focus test window", filename: false)
        AgentPadQuietUI.select(window)
        await settle()
        try require(NSApp.keyWindow === window, "Menu validation must resolve the selected offscreen owner")
        try require(window.windowController === controller, "The selected window must retain its owning AgentPad controller")
        guard let mainMenu = NSApp.mainMenu, let windowMenu = NSApp.windowsMenu,
              let windowItem = windowMenu.item(withTitle: "Other popup focus test window") else {
            throw Failure.check("Installed menu probe is missing its Window item")
        }
        func flatten(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(flatten) ?? []) }
        }
        let selectors = Set(["handleNewTab", "handleNewWorkspace", "handleNewWindow", "handleQuickOpen",
            "handleAllSessions", "handleNextWaitingSession", "handleNextTab", "handlePreviousTab",
            "handleFocusNextPane", "handleFocusPreviousPane", "handleSwitchTab:", "handleSwitchWorkspace:",
            "handleNavigationCommand:"])
        let items = flatten(mainMenu).filter {
            $0.action.map { selectors.contains(NSStringFromSelector($0)) } == true
        }
        try require(Set(items.compactMap { $0.action.map(NSStringFromSelector) }) == selectors,
                    "Installed content-navigation menu inventory changed")
        delegate.menuNeedsUpdate(windowMenu)
        try require(windowItem.isEnabled, "Window navigation must be available before opening the popup")
        _ = store.openToolTab(.settings)
        await settle()
        try require(NSApp.keyWindow === window, "Popup presentation changed the menu probe's selected owner")
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        for item in items {
            check(!delegate.validateMenuItem(item), "\(item.title) must be disabled while the popup owns focus")
        }
        check(windowMenu.delegate === delegate, "The actual Window menu must request popup validation")
        delegate.menuNeedsUpdate(windowMenu)
        check(!windowItem.isEnabled, "A Window-menu selection must not focus another terminal behind an open popup")
        store.popups.dismiss(reason: .dismiss)
        for item in items where item.action.map(NSStringFromSelector) == "handleNewWindow" {
            check(delegate.validateMenuItem(item), "Closing the popup must restore app navigation")
        }
        delegate.menuNeedsUpdate(windowMenu)
        windowMenu.update()
        check(windowItem.isEnabled, "Closing the popup must restore Window-menu navigation")
        try require(failures.isEmpty, "Popup menu focus isolation: " + failures.joined(separator: "; "))
    }

    func run() async throws {
        // Keep the bounded offscreen export scheduled without preventing idle sleep.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Verify and export popup fixture captures")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        defer {
            modalWatch?.invalidate()
            stores.forEach { $0.terminate() }
            windows.forEach { $0.orderOut(nil) }
            tokens.clear()
            try? FileManager.default.removeItem(at: directory)
        }
        let work = try profiles.claudeAccounts.add(name: "Work", token: UUID().uuidString + UUID().uuidString)
        let personal = try profiles.claudeAccounts.add(name: "Personal", token: UUID().uuidString + UUID().uuidString)
        let profile = try profiles.add(template: .claudeCode, folder: directory, name: "Reviewer")
        try profiles.setClaudeAccount(profileID: profile.id, accountID: work.id)
        AgentPadSettingsModel.testModel = model
        model.appearanceMode = .dark
        model.activatePairedThemeSchemaAndSave()
        support.settingsModel = { [weak self] in self!.model }
        telegram.start(environment: [:])
        await telegram.whenInitialized()
        support.telegramSettings = { [weak self] in self!.telegram }
        support.ledger = AttentionLedger()
        support.updates = UpdatesTabModel(packaged: { false }, attention: UpdateAttention(ledger: support.ledger),
                                         fetch: { _ in .upToDate(current: "1.1.8") })
        let router = support.navigation.router
        router.stores = { [weak self] in self?.stores ?? [] }
        router.ensureHost = { [weak self] in self?.host() }
        router.revealWindow = { [weak self] in self?.reveal($0) }
        support.install(); menu()
        modalWatch = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let unexpected = NSApp.windows.first(where: {
                    $0.isVisible && !self.windows.contains($0)
                        && !self.matrixSystemCompletionHelper($0)

                }) {
                    self.unexpectedWindow = true
                    try? self.screenshot(unexpected, name: "failure-unexpected-window")
                    fputs("Forbidden auxiliary window in no-modals UI test: \(type(of: unexpected)); bundle=\(Bundle(for: type(of: unexpected)).bundleURL.path); title=\(unexpected.title); content=\(String(describing: unexpected.contentView))\n", stderr)
                    let owner = NSApp.keyWindow
                    fputs("Auxiliary ownership: helperKey=\(unexpected.isKeyWindow) modal=\(NSApp.modalWindow === unexpected) sheet=\(unexpected.sheetParent != nil) ownerRegistered=\(owner.map { self.windows.contains($0) } ?? false) ownerResponder=\(String(describing: owner?.firstResponder)) popup=\(owner.flatMap { self.element("popup-dialog", in: $0) } != nil)\n", stderr)
                    exit(1)
                }
            }
        }
        if let batch = ProcessInfo.processInfo.environment["AGENTPAD_POPUP_PHASE3_BATCH"] {
            if batch == "fallback" {
                modalWatch?.invalidate()
                checks += try await AgentPadPopupFallbackSelfCheck.run()
                let actual = Set(try FileManager.default.contentsOfDirectory(atPath: shots.path).filter { $0.hasSuffix(".png") })
                try require(actual == AgentPadPopupFallbackSelfCheck.screenshotNames, "Native fallback screenshot inventory is incomplete")
                screenshotNames = actual.sorted()
                return
            }
            try await phaseThree(batch)
            return
        }
        if captureOnly {
            try await capturePhaseTwo()
            return
        }
        try shortcut(",")
        try require(windows.isEmpty, "Settings created a window before startup completed")
        support.navigation.finishStartup()
        await settle()
        try require(windows.count == 1 && processRequests == 0, "no-window entry started a process or a second window")
        let first = stores[0], firstWindow = windows[0]
        AgentPadQuietUI.select(firstWindow)
        await settle()
        let settings = try currentTool(first, route: .settings), state = settings.tabState!
        try require(first.allSessions.isEmpty, "Settings was inserted into a pane")
        try AgentPadQuietUI.assertQuiet()
        let initialDialog = try dialog(firstWindow, title: "Settings")
        try require(focusIsInside(initialDialog, window: firstWindow), "Opening popup did not move keyboard focus inside")
        let traversalModifiers: [NSEvent.ModifierFlags] = [[], .shift]
        for modifiers in traversalModifiers {
            for _ in 0..<24 {
                key("\t", code: 48, in: firstWindow, modifiers: modifiers)
                try require(focusIsInside(initialDialog, window: firstWindow), "Tab traversal escaped the popup")
            }
        }
        try press("settings-section-about", in: firstWindow); await settle()
        try shortcut(","); await settle()
        try require(first.popups.sessions.count == 1 && state.navigation.settingsSection == .about,
                    "Cmd-, lost Settings identity or selected section")
        let expectedSections = ["general", "profile", "telegram", "sidebar", "appearance", "agents", "claudeAccounts",
                                "terminals", "openIn", "statusBar", "notifications", "search", "advanced", "about", "updates"]
        try require(SettingsTabSection.allCases.map(\.rawValue) == expectedSections, "Settings inventory changed")
        for light in [false, true] {
            model.appearanceMode = light ? .light : .dark
            NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            await settle()
            for section in SettingsTabSection.allCases {
                try press("settings-section-" + section.rawValue, in: firstWindow); await settle()
                try require(state.navigation.settingsSection == section, "Settings AX section navigation failed")
                try require(element("settings-detail-" + section.rawValue, in: firstWindow) != nil, "Settings detail is missing")
                _ = try dialog(firstWindow, title: "Settings")
                let slug = section == .claudeAccounts ? "claude-accounts" : section == .openIn ? "open-in" : section == .statusBar ? "status-bar" : section.rawValue
                try screenshot(firstWindow, name: "popups-settings-" + slug + (light ? "-light" : ""))
            }
            try press("settings-section-claudeAccounts", in: firstWindow); await settle()
            try press("claude-account-select-" + work.id.uuidString, in: firstWindow); await settle()
            guard let usedRemove = element("claude-account-remove-" + work.id.uuidString, in: firstWindow) else {
                try press("claude-account-remove-" + work.id.uuidString, in: firstWindow)
                throw Failure.check("Used Work account has no Remove action")
            }
            try require((attribute(usedRemove, "accessibilityEnabled") as? NSNumber)?.boolValue == false,
                        "Remove is enabled for the Work account assigned to Reviewer")
            try press("claude-account-add", in: firstWindow); await settle()
            _ = try dialog(firstWindow, title: "Add Claude account")
            try screenshot(firstWindow, name: "popups-add-claude-account" + (light ? "-light" : ""))
            try press("claude-account-cancel", in: firstWindow); await settle()
            try pressButton("Replace token…", in: firstWindow); await settle()
            _ = try dialog(firstWindow, title: "Replace Claude token")
            try screenshot(firstWindow, name: "popups-replace-token" + (light ? "-light" : ""))
            try press("claude-account-cancel", in: firstWindow); await settle()
            try press("claude-account-select-" + personal.id.uuidString, in: firstWindow); await settle()
            try press("claude-account-remove-" + personal.id.uuidString, in: firstWindow); await settle()
            _ = try dialog(firstWindow, title: "Remove Claude account?")
            try screenshot(firstWindow, name: "popups-remove-confirmation" + (light ? "-light" : ""))
            key("\u{1b}", code: 53, in: firstWindow); await settle()
            scrim(firstWindow); await settle()
            // Disabled X has no action; its enabled state is part of the AX contract.
            guard let close = element("popup-close", in: firstWindow) else { throw Failure.check("Confirmation has no X") }
            try require((attribute(close, "accessibilityEnabled") as? NSNumber)?.boolValue == false,
                        "Destructive confirmation X is enabled")
            try require(first.popups.locksDismissal && profiles.claudeAccounts.account(personal.id) != nil,
                        "Escape or scrim approved/dismissed a destructive decision")
            try press("popup-confirm-cancel", in: firstWindow); await settle()
            try require(profiles.claudeAccounts.account(personal.id) != nil, "Cancel removed an account")
            first.popups.present(.agentProfile(profile.id)); await settle()
            _ = try dialog(firstWindow, title: "Edit profile")
            try require(first.popups.canGoBack && element("popup-back", in: firstWindow) != nil,
                        "Profile opened from Settings must have Back")
            try screenshot(firstWindow, name: "popups-edit-profile" + (light ? "-light" : ""))
            try press("agent-profile-cancel", in: firstWindow); await settle()
            first.popups.dismiss(reason: .dismiss); await settle()
            // The sidebar's Edit profile action uses this same router entry point.
            support.navigation.open(.agentProfile(profile.id), from: first); await settle()
            _ = try dialog(firstWindow, title: "Edit profile")
            try require(!first.popups.canGoBack && element("popup-back", in: firstWindow) == nil,
                        "Direct Edit profile entry must not have Back")
            try screenshot(firstWindow, name: "popups-edit-profile-direct" + (light ? "-light" : ""))
            try press("agent-profile-cancel", in: firstWindow); await settle()
            first.popups.present(.settings); await settle()
        }
        // Preserve the former native-editor overlap, scroll and field-error coverage.
        try press("settings-section-agents", in: firstWindow); await settle()
        model.addCustomAgent(); state.settingsScreen.expandedAgentID = model.customAgents.last!.id
        let agentID = model.customAgents.last!.id
        SettingsIconImport.apply(directory.appendingPathComponent("damaged.png"), agentID: agentID,
            model: model, screen: state.settingsScreen, importIcon: { _, _ in throw CocoaError(.fileReadCorruptFile) })
        await settle(); try scrollToEnd(settings); await settle()
        let scrollOffset = state.navigation.settingsScrollOffsets?["agents"] ?? 0
        try require(scrollOffset > 0, "Settings scroll position was not captured")
        try press("settings-section-about", in: firstWindow); await settle()
        try press("settings-section-agents", in: firstWindow); await settle()
        try require(abs((state.navigation.settingsScrollOffsets?["agents"] ?? 0) - scrollOffset) < 2, "Section switch lost scroll position")
        try scrollToEnd(settings); await settle()
        try require(element("agent-icon-error-" + agentID, in: firstWindow) != nil, "Icon error is not accessible at its field")
        let panel = try dialog(firstWindow, title: "Settings")
        let contentFrame = panel.convert(panel.bounds, to: firstWindow.contentView)
        try require(!nodes(firstWindow).compactMap { $0 as? RightClickCatcher.SecondaryClickView }.contains { view in
            view.convert(view.bounds, to: firstWindow.contentView).intersection(contentFrame).height > 1
        }, "Terminal right-click interceptor covers popup editor")
        let second = newWindow(), secondWindow = windows[1]
        try shortcut(","); await settle()
        let secondSettings = try currentTool(second, route: .settings)
        try require(secondSettings !== settings && first.popups.isPresented && second.popups.isPresented,
                    "Settings ownership was shared across windows")
        try press("settings-section-general", in: secondWindow); await settle()
        try require(state.navigation.settingsSection == .agents, "One window changed another window's Settings section")
        try press("popup-close", in: secondWindow); await settle()
        try require(!second.popups.isPresented && first.popups.isPresented, "Closing one popup dismissed the other window")
        reveal(first); await settle()
        for action in ["escape", "scrim", "close"] {
            first.popups.present(.settings); await settle()
            try await dismissAndCheck(first, window: firstWindow, action: action)
        }
        guard let opener = nodes(firstWindow).compactMap({ $0 as? UIProbeFocusView.Probe }).first else {
            throw Failure.check("Workspace focus target is missing")
        }
        firstWindow.makeFirstResponder(opener)
        first.popups.present(.agentProfile(profile.id)); await settle()
        let editSession = try currentTool(first, route: .agentProfile(profile.id))
        guard let editor = editSession.tabState?.profileEditor else { throw Failure.check("Real profile editor is missing") }
        editor.name = "Reviewer draft"
        try await dismissAndCheck(first, window: firstWindow, action: "close")
        try require(firstWindow.firstResponder === opener, "Dismiss did not return focus to its opener")
        try require(profiles.profile(profile.id)?.name == "Reviewer", "Closing a draft saved the profile")
        first.popups.present(.agentProfile(profile.id)); await settle()
        try require(editSession.tabState?.profileEditor === editor && editor.name == "Reviewer draft", "Reopen lost the editor draft")
        try require(element("popup-draft-kept", in: firstWindow) != nil, "Reopen lacks Draft kept")
        try accountMenu("Add account…", in: firstWindow); await settle()
        _ = try accountForm(first)
        try require(editor.claudeAccountID == work.id, "Native Add account menu changed account selection")
        try press("popup-back", in: firstWindow); await settle()
        let menuAddParent = try currentTool(first, route: .agentProfile(profile.id))
        try require(menuAddParent === editSession && editor.name == "Reviewer draft", "Native Add account Back lost parent draft")
        try accountMenu("Manage accounts…", in: firstWindow); await settle()
        let manager = try currentTool(first, route: .settings)
        try require(manager.tabState?.navigation.settingsSection == .claudeAccounts, "Native Manage accounts menu opened wrong section")
        try press("popup-back", in: firstWindow); await settle()
        let menuManageParent = try currentTool(first, route: .agentProfile(profile.id))
        try require(menuManageParent === editSession && editor.name == "Reviewer draft" && editor.claudeAccountID == work.id,
                    "Native Manage accounts Back lost parent draft or selection")
        try press("agent-profile-add-account", in: firstWindow); await settle()
        let form = try accountForm(first)
        form.name = "Temporary account"; form.token = UUID().uuidString + UUID().uuidString
        try press("popup-back", in: firstWindow); await settle()
        let returnedEditor = try currentTool(first, route: .agentProfile(profile.id))
        try require(returnedEditor === editSession, "Back did not restore the parent profile editor")
        try require(editor.name == "Reviewer draft", "Back lost parent name draft")
        try press("agent-profile-add-account", in: firstWindow); await settle()
        let returnedForm = try accountForm(first)
        try require(returnedForm === form && form.name == "Temporary account" && !form.token.isEmpty,
                    "Back/reopen lost account form draft")
        try press("claude-account-cancel", in: firstWindow); await settle()
        try require(form.token.isEmpty && profiles.claudeAccounts.list.count == 2, "Cancel applied account form or retained token")
        try press("agent-profile-cancel", in: firstWindow); await settle()
        try require(profiles.profile(profile.id)?.name == "Reviewer", "Cancel saved the profile draft")
        first.popups.present(.agentProfile(profile.id)); await settle()
        let saveSession = try currentTool(first, route: .agentProfile(profile.id))
        saveSession.tabState?.profileEditor?.name = "Reviewer saved"
        try press("agent-profile-save", in: firstWindow); await settle()
        try require(profiles.profile(profile.id)?.name == "Reviewer saved" && !first.popups.isPresented, "Save did not apply and close profile")
        first.popups.present(.agentProfile(profile.id)); await settle()
        let photoSession = try currentTool(first, route: .agentProfile(profile.id))
        guard let photoEditor = photoSession.tabState?.profileEditor else { throw Failure.check("Photo editor is missing") }
        photoEditor.name = "Reviewer photo saved"
        photoEditor.source = try avatarImage()
        try press("agent-profile-save", in: firstWindow)
        try await eventually("Profile photo Save did not finish") {
            if case .failed = photoEditor.operation { return true }
            return !first.popups.isPresented
        }
        try require(!first.popups.isPresented && profiles.profile(profile.id)?.name == "Reviewer photo saved"
                    && profiles.details.avatar(profile.id).revision == 1 && profiles.details.avatarURL(profile.id) != nil,
                    "One photo Save did not apply both image and pending name and close")
        first.popups.present(.agentProfile(profile.id)); await settle()
        let lateSession = try currentTool(first, route: .agentProfile(profile.id))
        guard let lateEditor = lateSession.tabState?.profileEditor else { throw Failure.check("Late photo editor is missing") }
        lateEditor.name = "Reviewer photo retained"
        lateEditor.source = try avatarImage()
        try press("agent-profile-save", in: firstWindow)
        // AX dispatch schedules Save on MainActor. Replace the page synchronously,
        // before that task can complete, to make the late-completion order deterministic.
        let protectedSettings = first.popups.present(.settings)
        try await eventually("Late profile photo Save did not finish") {
            if case .failed = lateEditor.operation { return true }
            return profiles.profile(profile.id)?.name == "Reviewer photo retained"
        }
        let retainedSettings = try currentTool(first, route: .settings)
        try require(retainedSettings === protectedSettings && profiles.details.avatar(profile.id).revision == 2,
                    "Late profile photo completion closed another popup")
        await settle()
        try require(!first.popups.canGoBack && !first.popups.contains(lateSession.id),
                    "Completed photo editor remained in popup history")
        first.popups.presentSettings(section: .claudeAccounts); await settle()
        try press("claude-account-add", in: firstWindow); await settle()
        let addedForm = try accountForm(first)
        addedForm.name = "Added in selfcheck"; addedForm.token = UUID().uuidString + UUID().uuidString
        try press("claude-account-apply", in: firstWindow); await settle()
        try require(profiles.claudeAccounts.list.count == 3 && addedForm.token.isEmpty, "Add did not apply/clear account form")
        try press("claude-account-select-" + work.id.uuidString, in: firstWindow); await settle()
        try pressButton("Replace token…", in: firstWindow); await settle()
        let replaceForm = try accountForm(first)
        replaceForm.token = UUID().uuidString + UUID().uuidString
        try press("claude-account-apply", in: firstWindow); await settle()
        try require(profiles.claudeAccounts.list.count == 3 && replaceForm.token.isEmpty, "Replace did not apply and close")
        try press("claude-account-select-" + personal.id.uuidString, in: firstWindow); await settle()
        try press("claude-account-remove-" + personal.id.uuidString, in: firstWindow); await settle()
        try press("popup-confirm-accept", in: firstWindow); await settle()
        try require(profiles.claudeAccounts.account(personal.id) == nil, "Explicit Remove did not apply")
        try press("popup-close", in: firstWindow); await settle()
        try shortcut("i"); await settle()
        try require(first.allSessions.filter { $0.toolRoute == .notifications }.count == 1 && !first.popups.isPresented,
                    "Notifications content was classified as a popup")
        try shortcut("w"); await settle()
        try require(first.allSessions.isEmpty, "Cmd-W did not close content tab")
        let reopened = first.reopenLastClosedTab()
        try require(reopened?.toolRoute == .notifications, "Content tab reopen failed")
        support.linkFailed("Invalid agentpad://resume?token=" + UUID().uuidString)
        support.linkFailed("Invalid agentpad://resume?token=" + UUID().uuidString)
        await settle()
        try require(first.popups.sessions.filter { $0.toolRoute == .linkFailure }.count == 1, "Link failure duplicated popups")
        try await popupNavigationMenus()
        try require(stores.allSatisfy { $0.popups.sessions.allSatisfy { $0.toolRoute?.presentation == .popup } },
                    "A content route was retained as a popup")
        try require(!unexpectedWindow && processRequests == 0, "Forbidden surface or terminal process")
        try checkScreenshotInventory(NoModalsMatrixInventory.settingsFrames)
        first.popups.dismiss(reason: .dismiss)
        reveal(first)
        for light in [false, true] {
            model.appearanceMode = light ? .light : .dark
            NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            await settle()
            try await phaseTwoLocalScreenshots(first, window: firstWindow, light: light)
            try await phaseTwoConnectScreenshots(first, window: firstWindow, light: light)
        }
        try await phaseTwoScreenshots(first, window: firstWindow)
        try checkScreenshotInventory(NoModalsMatrixInventory.settingsFrames + NoModalsMatrixInventory.phaseTwoFrames,
            layouts: NoModalsMatrixInventory.layoutFrames)
        await telegram.shutdown()
        try report()
        print("UI profile and screenshots: \(shots.path)")
    }
}

private enum PhaseThreeBatch: String, CaseIterable {
    case settings, local, connection, composition, publication, organization, operations, folders, telegram, video
    var frames: [String] {
        switch self {
        case .settings: NoModalsMatrixInventory.settingsFrames
        case .local: ["new-agent", "new-ssh", "new-worktree", "workspace-details"]
        case .connection: ["connect-server", "connect-code", "connect-organization", "connect-name", "connect-connected", "connect-busy"]
        case .composition: NoModalsMatrixInventory.compositionFrames
        case .publication: ["publish-session"]
        case .organization: ["organization-members", "organization-teams", "organization-invitations",
            "organization-devices", "organization-audit", "remove-member"]
        case .operations: ["link-failure", "close-workspaces", "file-conflict", "file-replace", "file-progress", "import-session"]
        case .folders: ["folders", "delete-folder", "add-to-folder"]
        case .telegram: ["telegram-bot", "telegram-bot-url", "telegram-sponsored", "telegram-sponsored-report",
            "telegram-sponsored-url", "telegram-local-data"]
        case .video: ["telegram-video-url"]
        }
    }
}

/// Named states of the 28 popup families in NO-MODALS-inventory.md. Screenshot
/// expectations are derived from these states and themes, never an image count.
enum NoModalsMatrixInventory {
    enum FirstField {
        case identifier(String, placeholder: String? = nil)
        // Some existing forms expose only a native placeholder, not an AX ID.
        case placeholder(String)
        case fieldless
    }
    static func firstField(_ frame: String) -> FirstField? {
        switch frame {
        case "new-message": .identifier("newMessageSearch", placeholder: "Find a person by name or handle")
        case "new-channel": .identifier("newChannelName")
        case "new-agent": .identifier("new-agent-folder")
        case "new-ssh": .identifier("ssh-workspace-name")
        case "new-worktree": .identifier("worktree-branch")
        case "workspace-details": .identifier("workspace-title")
        case "edit-profile", "edit-profile-direct": .identifier("agent-profile-name")
        case "add-claude-account": .identifier("claude-account-name")
        case "replace-token": .identifier("claude-account-token")
        case "connect-server", "connect-code", "connect-name": .identifier(frame)
        case "forward": .identifier("forwardMarkdown")
        case "ask-agent": .identifier("personalAskPrompt")
        case "request-approval", "request-approval-draft": .identifier("request-decline-reason")
        case "settings-advanced": .identifier("diagnostics-display-name")
        case "settings-agents": .placeholder("Add to the AgentPad context…")
        case "organization-members": .placeholder("Your name")
        case "organization-teams": .placeholder("New team name")
        case "organization-invitations": .placeholder("Email")
        case "publication", "publish": .placeholder("Name")
        case "publish-session": .placeholder("Session's name")
        case "add-to-folder": .placeholder("Find a folder")
        case "settings-general", "settings-appearance", "settings-terminals", "settings-sidebar",
             "settings-search", "settings-notifications", "settings-open-in", "settings-status-bar",
             "settings-profile", "settings-claude-accounts", "settings-telegram", "settings-updates", "settings-about",
             "remove-confirmation", "connect-organization", "connect-connected", "connect-busy", "ask-sent",
             "request-folder", "request-publish", "published-agent", "organization-devices", "organization-audit",
             "remove-member", "link-failure", "close-workspaces", "file-conflict", "file-replace", "file-progress",
             "import-session", "folders", "delete-folder", "telegram-bot", "telegram-bot-url", "telegram-sponsored",
             "telegram-sponsored-report", "telegram-sponsored-url", "telegram-local-data", "telegram-video-url": .fieldless
        default: nil
        }
    }
    static func isFullscreenHelper(_ name: String, frameworkOwned: Bool) -> Bool {
        frameworkOwned && ["_NSFullScreenTransitionOverlayWindow", "NSToolbarFullScreenWindow"].contains(name)
    }
    static var settingsFrames: [String] {
        SettingsTabSection.allCases.map { section in
            "settings-" + (section == .claudeAccounts ? "claude-accounts" : section == .openIn ? "open-in"
                : section == .statusBar ? "status-bar" : section.rawValue)
        } + ["edit-profile", "edit-profile-direct", "add-claude-account", "replace-token", "remove-confirmation"]
    }
    static let compositionFrames = ["new-message", "new-channel", "forward", "ask-agent", "ask-sent",
        "request-approval", "request-approval-draft", "request-folder", "request-publish", "publish", "publish-session",
        "publication", "published-agent"]
    static var phaseTwoFrames: [String] { PhaseThreeBatch.local.frames + PhaseThreeBatch.connection.frames + compositionFrames }
    static let layoutFrames = ["request-approval-confirmation", "publish-confirmation"]
    static func images(_ frames: [String], prefix: String = "popups-") -> Set<String> {
        Set(frames.flatMap { [prefix + $0 + ".png", prefix + $0 + "-light.png"] })
    }
}

private extension NoModalsUIProbe {
    func matrixSystemCompletionHelper(_ helper: NSWindow) -> Bool {
        // macOS may attach its remote autofill suggestions to an editable field.
        // This exact contextual helper is not an AgentPad presentation surface.
        // It may report isKeyWindow while NSApp.keyWindow and the active field
        // editor still belong to our popup; validate that actual owner below.
        guard NSStringFromClass(type(of: helper)) == "SPRoundedWindow",
              Bundle(for: type(of: helper)).bundleURL.path == "/System/Library/PrivateFrameworks/SafariPlatformSupport.framework",
              let content = helper.contentView, NSStringFromClass(type(of: content)) == "NSRemoteView",
              content.description.contains("com.apple.SafariPlatformSupport.Helper SPCompletionListServiceViewController"),
              NSApp.modalWindow !== helper, helper.sheetParent == nil,
              let owner = NSApp.keyWindow, windows.contains(owner),
              let panel = element("popup-dialog", in: owner) as? NSView,
              let editor = owner.firstResponder as? NSTextView, editor.isEditable,
              focusIsInside(panel, window: owner) else { return false }
        if completionHelpers.insert(helper.windowNumber).inserted {
            print("Matrix OS helper: SafariPlatformSupport completion list; native popup editor remains focused")
        }
        return true
    }

    func checkScreenshotInventory(_ frames: [String], layouts: [String] = []) throws {
        let expected = NoModalsMatrixInventory.images(frames).union(NoModalsMatrixInventory.images(layouts, prefix: "layout-"))
        let actual = Set(screenshotNames)
        try require(actual == expected && screenshotNames.count == expected.count,
            "Screenshot inventory: missing=\(expected.subtracting(actual).sorted()), extra=\(actual.subtracting(expected).sorted()), duplicates=\(screenshotNames.count - actual.count)")
    }

    func matrixOpener(_ window: NSWindow) throws -> NSView {
        if let opener = nodes(window).compactMap({ $0 as? UIProbeFocusView.Probe }).first { return opener }
        // The video owns a separate content window. Mount a test-only opener in
        // that owner; its identity, visibility and native first responder matter.
        guard let content = window.contentView else { throw Failure.check("Matrix owner has no content") }
        let opener = UIProbeFocusView.Probe(title: "Popup matrix opener", target: nil, action: nil)
        opener.frame = NSRect(x: 24, y: 24, width: 180, height: 28)
        content.addSubview(opener)
        return opener
    }

    func matrixPrepare(_ window: NSWindow) throws {
        guard !captureOnly else { return }
        let opener = try matrixOpener(window)
        try require(window.makeFirstResponder(opener) && window.firstResponder === opener, "Matrix opener could not receive native focus")
    }

    func matrixReturn(_ window: NSWindow, coordinator: PopupCoordinator, name: String) async throws {
        guard !captureOnly, phaseThreeMenuDelegate != nil else { return }
        // Cancel a child decision returns to its retained parent. Close that
        // parent through native Escape before checking the original opener.
        if coordinator.isPresented {
            let parent = try dialog(window, title: coordinator.page!.presentationTitle)
            try require(focusIsInside(parent, window: window), "\(name) Cancel did not focus its parent")
            key("\u{1b}", code: 53, in: window)
            await settle()
        }
        let opener = try matrixOpener(window)
        try await eventually("\(name) did not restore its native opener") {
            !coordinator.isPresented && window.firstResponder === opener
        }
    }

    func matrixAwaitInitialFocus(window: NSWindow, title: String, name: String) async throws -> String {
        // Native fields and SwiftUI focus requests mount asynchronously after
        // reopening. Wait for the required state without assigning focus here.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            do { return try matrixInitialFocus(try dialog(window, title: title), window: window, name: name) }
            catch {
                if ContinuousClock.now >= deadline { throw error }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func matrixInitialFocus(_ panel: NSView, window: NSWindow, name: String) throws -> String {
        guard let expectation = NoModalsMatrixInventory.firstField(name) else {
            throw Failure.check("\(name) has no declared first-field expectation")
        }
        let fields = nodes(panel).compactMap { $0 as? NSView }.filter { view in
            if let field = view as? NSTextField { return field.isEditable && field.isEnabled }
            if let editor = view as? NSTextView { return editor.isEditable && !editor.isFieldEditor }
            return false
        }
        let matches: [NSView]
        let label: String
        switch expectation {
        case .fieldless:
            try require(!fields.contains { !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty },
                        "\(name) declares a fieldless state but has an eligible editable field")
            try require(focusIsInside(panel, window: window), "\(name) fieldless state did not focus its dialog/control")
            return "declared fieldless; dialog/control focused"
        case .identifier(let identifier, let placeholder):
            label = "id=\(identifier)"
            let identified = nodes(panel).filter { attribute($0, "accessibilityIdentifier") as? String == identifier }
            let identifiedFields = fields.filter { field in
                identified.contains { object in
                    if nodes(object).contains(where: { $0 === field }) { return true }
                    // SwiftUI can put the ID on a virtual AX node instead of
                    // its NSTextField/NSTextView. Bind that node to the native
                    // field by its screen frame; ambiguity still fails below.
                    let target = phaseThreeFrame(object)
                    let native = window.convertToScreen(field.convert(field.bounds, to: nil))
                    return !target.isEmpty && !native.isEmpty && target.contains(native)
                }
            }
            // Nested SwiftUI groups can propagate their ID to descendants.
            // Only an explicitly declared native selector may substitute for it.
            if identifiedFields.isEmpty, let placeholder {
                matches = fields.filter { ($0 as? NSTextField)?.placeholderString == placeholder }
            } else { matches = identifiedFields }
        case .placeholder(let placeholder):
            label = "placeholder=\(placeholder)"
            matches = fields.filter { ($0 as? NSTextField)?.placeholderString == placeholder }
        }
        try require(matches.count == 1, "\(name) expected first field '\(label)' is missing, disabled or ambiguous (matches=\(matches.count))")
        let first = matches[0]
        try require(first.window === window && !first.isHiddenOrHasHiddenAncestor && !first.visibleRect.isEmpty,
                    "\(name) expected first field '\(label)' is hidden or unmounted")
        try require(matrixFocusedView(window) === first,
                    "\(name) expected first field '\(label)' is not focused; actual=\(String(describing: window.firstResponder))")
        return label
    }

    func matrixFocusedView(_ window: NSWindow) -> NSView? {
        guard let responder = window.firstResponder as? NSView else { return nil }
        if let editor = responder as? NSTextView, editor.isFieldEditor { return editor.delegate as? NSView }
        return responder
    }

    func matrixTabTraversal(_ panel: NSView, window: NSWindow, name: String) async throws -> String {
        try await AgentPadFirstLaunchSelfCheck.assertTraversal(panel, window: window, name: name)
    }

    func matrixDisabledChrome(_ name: String, window: NSWindow, coordinator: PopupCoordinator) async throws {
        let original = coordinator.page?.id
        for identifier in ["popup-close", "popup-back"] {
            guard let object = element(identifier, in: window) else {
                try require(identifier == "popup-back" && !coordinator.canGoBack, "\(name) lost its close control")
                continue
            }
            try require((attribute(object, "accessibilityEnabled") as? NSNumber)?.boolValue == false,
                "\(name) enabled destructive \(identifier)")
            // Dispatch a real click even on the disabled control. AX enabled
            // alone does not prove it is inert.
            let frame = phaseThreeFrame(object)
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                AgentPadQuietUI.send(event, to: window)
            }
            await settle()
            try require(coordinator.page?.id == original && coordinator.locksDismissal,
                "\(name) destructive \(identifier) was not inert")
        }
        coordinator.back()
        try require(coordinator.page?.id == original && !coordinator.canGoBack, "\(name) allowed destructive Back")
    }

    func matrixInteractions(_ name: String, title: String, store: WorkspaceStore, window: NSWindow,
                            coordinator: PopupCoordinator? = nil, light: Bool, destructive: Bool = false,
                            reopen: @escaping @MainActor () async throws -> Void) async throws {
        guard !captureOnly, phaseThreeMenuDelegate != nil else { return }
        let coordinator = coordinator ?? store.popups
        try require(coordinator.window === window, "\(name) popup coordinator lost its fixture window")
        let attempt = 1
        try await phaseThreeAcquireFocus(window, context: name)
        do {
            if !destructive {
                coordinator.dismiss(reason: .dismiss)
                await settle()
                try matrixPrepare(window)
                try await reopen(); await settle()
            }
            let firstField = try await matrixAwaitInitialFocus(window: window, title: title, name: name)
            let panel = try dialog(window, title: title)
            try require(focusIsInside(panel, window: window), "\(name) lost its first responder")
            try AgentPadQuietUI.assertQuiet()
            try screenshot(window, name: "popups-" + name + (light ? "-light" : ""), record: false)
            let traversal: String
            do { traversal = try await matrixTabTraversal(panel, window: window, name: name) }
            catch {
                let failure = "\(name) \(light ? "light" : "dark"): \(error)"
                matrixFailures.append(failure)
                traversal = "FAIL: " + failure
                print("Matrix traversal FAIL: \(failure)")
            }
            try phaseThreeMenus(name, dismissalLocked: destructive)
            if destructive {
                for action in ["escape", "scrim"] {
                    if action == "escape" { key("\u{1b}", code: 53, in: window) } else { scrim(window) }
                    await settle()
                    try require(coordinator.isPresented && coordinator.locksDismissal, "\(name) dismissed through \(action)")
                }
                try await matrixDisabledChrome(name, window: window, coordinator: coordinator)
                let cancel: String
                switch name {
                case "remove-member", "file-replace": cancel = "inline-confirmation-cancel"
                case "close-workspaces": cancel = "close-workspaces-cancel"
                default: cancel = "popup-confirm-cancel"
                }
                try press(cancel, in: window); await settle()
                try await matrixReturn(window, coordinator: coordinator, name: name)
            } else {
                for action in ["escape", "scrim", "command-w", "close"] {
                    if action == "escape" { key("\u{1b}", code: 53, in: window) }
                    else if action == "scrim" { scrim(window) }
                    else if action == "command-w" { try shortcut("w") }
                    else { try press("popup-close", in: window) }
                    await settle()
                    try await eventually("\(name) did not dismiss through \(action)") {
                        !coordinator.isPresented && window.isVisible
                    }
                    try await matrixReturn(window, coordinator: coordinator, name: name + "/" + action)
                    if action != "close" {
                        try await reopen(); await settle()
                        _ = try await matrixAwaitInitialFocus(window: window, title: title, name: name)
                    }
                }
            }
            try AgentPadQuietUI.assertQuiet()
            matrixEvidence.append(["frame": name, "theme": light ? "light" : "dark", "firstFocus": firstField,
                "focus": "pass", "tabTraversal": traversal, "menu": "pass", "escape": "pass", "scrim": "pass",
                "close": destructive ? "pass: disabled and inert" : "pass", "return": destructive ? "pass: explicit Cancel, then parent dismissal" : "pass",
                "ownership": "pass", "attempt": String(attempt)])
            try writeMatrixEvidence()
            print("Matrix \(traversal.hasPrefix("FAIL") ? "FAIL" : "PASS"): \(name) \(light ? "light" : "dark"); first=\(firstField); attempt=\(attempt)")
            return
        } catch {
            try? screenshot(window, name: "failure-" + name)
            throw error
        }
    }

    func writeMatrixEvidence() throws {
        try JSONSerialization.data(withJSONObject: matrixEvidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: shots.appendingPathComponent("matrix.json"))
    }

    func matrixToolInteractions(_ name: String, title: String, store: WorkspaceStore, window: NSWindow, light: Bool) async throws {
        guard !captureOnly, phaseThreeMenuDelegate != nil, case .tool(let session) = store.popups.page,
              let route = session.toolRoute else { return }
        let show: @MainActor () async throws -> Void = { _ = store.popups.present(route) }
        try await matrixInteractions(name, title: title, store: store, window: window, light: light, reopen: show)
        try await show(); await settle()
    }

    func matrixSettings(_ store: WorkspaceStore, window: NSWindow) async throws {
        guard let profile = profiles.profiles.first,
              let unusedAccount = profiles.claudeAccounts.list.first(where: { $0.name == "Personal" }) else {
            throw Failure.check("Settings matrix fixtures missing")
        }
        for light in [false, true] {
            await phaseThreeTheme(light)
            for section in SettingsTabSection.allCases {
                let show: @MainActor () async throws -> Void = {
                    store.popups.presentSettings(section: section)
                }
                try await show(); await settle()
                let name = NoModalsMatrixInventory.settingsFrames[SettingsTabSection.allCases.firstIndex(of: section)!]
                _ = try dialog(window, title: "Settings")
                try screenshot(window, name: "popups-" + name + (light ? "-light" : ""))
                try await matrixInteractions(name, title: "Settings", store: store, window: window, light: light, reopen: show)
            }
            for nested in [true, false] {
                let show: @MainActor () async throws -> Void = {
                    if nested { store.popups.presentSettings(section: .agents) }
                    store.popups.present(.agentProfile(profile.id))
                }
                try await show(); await settle()
                let name = nested ? "edit-profile" : "edit-profile-direct"
                try require(store.popups.canGoBack == nested, "Profile Back does not match its entry")
                try screenshot(window, name: "popups-" + name + (light ? "-light" : ""))
                try await matrixInteractions(name, title: "Edit profile", store: store, window: window, light: light, reopen: show)
            }
            for replace in [false, true] {
                let show: @MainActor () async throws -> Void = {
                    store.popups.presentSettings(section: .claudeAccounts)
                    store.popups.presentAccount(profiles: self.profiles, replacing: replace ? unusedAccount.id : nil)
                }
                try await show(); await settle()
                let name = replace ? "replace-token" : "add-claude-account"
                let title = replace ? "Replace Claude token" : "Add Claude account"
                try screenshot(window, name: "popups-" + name + (light ? "-light" : ""))
                try await matrixInteractions(name, title: title, store: store, window: window, light: light, reopen: show)
            }
            try matrixPrepare(window)
            let remove: @MainActor () async throws -> Void = {
                store.popups.presentSettings(section: .claudeAccounts); await self.settle()
                try self.press("claude-account-select-" + unusedAccount.id.uuidString, in: window); await self.settle()
                try self.press("claude-account-remove-" + unusedAccount.id.uuidString, in: window); await self.settle()
            }
            try await remove()
            try screenshot(window, name: "popups-remove-confirmation" + (light ? "-light" : ""))
            try await matrixInteractions("remove-confirmation", title: "Remove Claude account?", store: store,
                window: window, light: light, destructive: true, reopen: remove)
            if captureOnly { try press("popup-confirm-cancel", in: window); await settle() }
            try require(profiles.claudeAccounts.account(unusedAccount.id) != nil, "Cancel removed the fixture account")
        }
    }

    /// Batches bound native runs and allow retrying a family without rerendering
    /// unrelated states. The named inventory validates every required frame.
    func phaseThree(_ name: String) async throws {
        guard let batch = PhaseThreeBatch(rawValue: name) else {
            throw Failure.check("Unknown phase-three batch: \(name)")
        }
        support.navigation.finishStartup()
        let store = newWindow(appController: !captureOnly), window = windows[0]
        if !captureOnly {
            let delegate = AppDelegate(appPersistence: appPersistence, agentProfiles: profiles)
            phaseThreeMenuDelegate = delegate; delegate.installMainMenu()
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false; windows.append(other)
            phaseThreeOtherWindow = other
            NSApp.addWindowsItem(other, title: "Phase-three other window", filename: false)
            phaseThreeWindowItem = NSApp.windowsMenu?.item(withTitle: "Phase-three other window")
            try await phaseThreeAcquireFocus(window, context: "Phase-three workspace")
            await settle()
            // The controller's production content was replaced by the fixture.
            // Its delayed SwiftUI teardown detaches the shared coordinator;
            // bind the replacement after teardown, before opening any popup.
            store.popups.attach(to: window)
            try matrixPrepare(window)
        }
        switch batch {
        case .settings: try await matrixSettings(store, window: window)
        case .local:
            for light in [false, true] {
                await phaseThreeTheme(light)
                try await phaseTwoLocalScreenshots(store, window: window, light: light)
            }
        case .connection:
            for light in [false, true] {
                await phaseThreeTheme(light)
                try await phaseTwoConnectScreenshots(store, window: window, light: light)
            }
        case .composition: try await phaseTwoScreenshots(store, window: window)
        case .publication: try await phaseThreePublication(store, window: window)
        case .organization: try await phaseThreeOrganization(store, window: window)
        case .operations: try await phaseThreeOperations(store, window: window)
        case .folders: try await phaseThreeFolders(store, window: window)
        case .telegram: try await phaseThreeTelegram(store, window: window)
        case .video: try await phaseThreeVideo(store, window: window)
        }
        try checkScreenshotInventory(batch.frames, layouts: batch == .composition ? NoModalsMatrixInventory.layoutFrames : [])
        try require(captureOnly || matrixEvidence.count == NoModalsMatrixInventory.images(batch.frames).count,
                    "\(name) is missing native matrix rows")
        try require(matrixEvidence.allSatisfy { $0["return"]?.hasPrefix("pass") == true }, "\(name) is missing a focus-return assertion")
        try require(!unexpectedWindow && processRequests == 0, "Phase-three created an unexpected window or process")
        try require(NSApp.modalWindow == nil && windows.allSatisfy { $0.attachedSheet == nil },
                    "A phase-three popup used a modal window or attached sheet")
        await telegram.shutdown()
        let interaction = captureOnly
            ? "Capture-only mode: native focus/menu/Escape/scrim/Cmd-W checks were NOT run; see the separate session probe for desktop state."
            : "FirstResponder focus, product Tab dispatch, installed menu validation, Escape, scrim, Cmd-W and close-button rows are recorded per state in matrix.json; destructive pages ignored incidental dismissal. Native key-window Tab traversal is NOT RUN: quiet mode uses following/preceding responder APIs without acquiring OS focus."
        let videoRendering = batch == .video
            ? "NOT RUN: real fullscreen entry/exit and Space transitions require visible UI; the media popup was tested off screen."
            : ""
        let body = """
        # Phase-three \(name) popup check

        \(matrixFailures.isEmpty ? "PASS" : "FAIL"): \(checks) checks; \(screenshotCount) screenshots.
        \(interaction)
        \(videoRendering)
        \(matrixFailures.joined(separator: "\n"))
        Exact production popup bodies and the existing PopupHost use isolated fixture models.
        No Telegram or server sign-in, real transport, process signal, terminal launch or external URL opening.
        First-launch Ghostty import is explicitly pending-decision and is not included in this batch.

        \(screenshotNames.sorted().map { "- " + $0 }.joined(separator: "\n"))
        """
        try body.write(to: shots.appendingPathComponent("report-" + name + ".md"), atomically: true, encoding: .utf8)
        print("UI profile and screenshots: \(shots.path)")
        try require(matrixFailures.isEmpty, "Native matrix failures: " + matrixFailures.joined(separator: "; "))
    }

    func phaseThreeAcquireFocus(_ window: NSWindow, context: String) async throws {
        AgentPadQuietUI.select(window)
        window.contentView?.layoutSubtreeIfNeeded()
        try AgentPadQuietUI.assertQuiet()
        print("Quiet responder model [\(context)]: \(String(describing: window.firstResponder))")
    }

    func phaseThreeTheme(_ light: Bool) async {
        model.appearanceMode = light ? .light : .dark
        NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        await settle()
    }

    func phaseThreeLabels(_ window: NSWindow) -> [String] {
        nodes(window).flatMap { node in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { attribute(node, $0) as? String }
        }
    }

    func phaseThreeFrame(_ object: NSObject) -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { return .zero }
        typealias ReadFrame = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: ReadFrame.self)(object, selector)
    }

    func phaseThreeCapture(_ name: String, title: String, store: WorkspaceStore, window: NSWindow,
                           coordinator: PopupCoordinator? = nil, light: Bool, destructive: Bool = false,
                           controls: [String] = [], reopen: @escaping @MainActor () async throws -> Void) async throws {
        let coordinator = coordinator ?? store.popups
        await settle()
        let panel = try dialog(window, title: title)
        try require(coordinator.locksDismissal == destructive, "\(name) has the wrong incidental-dismissal policy")
        try await eventually("Phase-three popup clipped its panel or controls: \(name)") {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let content = window.contentView, panel.visibleRect.contains(panel.bounds) else { return false }
            let measured: CGFloat?
            switch coordinator.page {
            case .tool(let session): measured = session.tabState?.popupContentHeight
            case .native(let native): measured = native.contentHeight
            case .confirmation: measured = coordinator.confirmationContentHeight
            case .account, .conversation, .none: measured = nil
            }
            guard let measured else { return false }
            let expectedHeight = min(measured + 63 + (coordinator.showsDraftNotice ? 30 : 0), content.bounds.height - 48)
            guard abs(panel.bounds.height - expectedHeight) <= 1 else { return false }
            let panelFrame = window.convertToScreen(panel.convert(panel.visibleRect, to: nil))
            let contentFrame = window.convertToScreen(content.convert(content.bounds, to: nil))
            return (["popup-close"] + controls).allSatisfy { identifier in
                guard let object = element(identifier, in: window) else { return false }
                let frame = phaseThreeFrame(object)
                return !frame.isEmpty && panelFrame.contains(frame) && contentFrame.contains(frame)
            }
        }
        try require(NSApp.modalWindow == nil && window.attachedSheet == nil, "\(name) opened a native modal or sheet")
        try require(store.allSessions.allSatisfy { $0.toolRoute?.presentation != .popup }, "\(name) inserted a popup into a tab")
        try screenshot(window, name: "popups-" + name + (light ? "-light" : ""))
        if captureOnly { return }
        try await matrixInteractions(name, title: title, store: store, window: window, coordinator: coordinator,
            light: light, destructive: destructive, reopen: reopen)
    }

    func phaseThreeMenus(_ name: String, dismissalLocked: Bool) throws {
        guard let delegate = phaseThreeMenuDelegate, let menu = NSApp.mainMenu,
              let windowMenu = NSApp.windowsMenu, let otherWindow = phaseThreeOtherWindow else {
            throw Failure.check("\(name) has no installed menu fixture")
        }
        // Fullscreen rebuilds AppKit's dynamic window list. Validate the live
        // navigation item, never the detached instance from before that rebuild.
        let windowTitle = "Phase-three other window"
        if windowMenu.item(withTitle: windowTitle) == nil {
            NSApp.addWindowsItem(otherWindow, title: windowTitle, filename: false)
        }
        guard let windowItem = windowMenu.item(withTitle: windowTitle) else {
            throw Failure.check("\(name) lost its live Window-menu fixture")
        }
        try require(windowItem.menu === windowMenu && windowMenu.items.contains(where: { $0 === windowItem }),
                    "\(name) Window-menu item is detached")
        if phaseThreeWindowItem !== windowItem {
            print("Matrix menu [\(name)]: AppKit replaced dynamic item; cachedAttached=\(phaseThreeWindowItem?.menu === windowMenu); liveTarget=\(String(describing: windowItem.target)); action=\(String(describing: windowItem.action))")
        }
        phaseThreeWindowItem = windowItem
        func flatten(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(flatten) ?? []) } }
        let selectors = Set(["handleNewTab", "handleNewWorkspace", "handleNewWindow", "handleQuickOpen", "handleAllSessions",
            "handleNextWaitingSession", "handleNextTab", "handlePreviousTab", "handleFocusNextPane", "handleFocusPreviousPane",
            "handleSwitchTab:", "handleSwitchWorkspace:", "handleNavigationCommand:"])
        let items = flatten(menu).filter { $0.action.map { selectors.contains(NSStringFromSelector($0)) } == true }
        try require(Set(items.compactMap { $0.action.map(NSStringFromSelector) }) == selectors, "\(name) lost installed navigation commands")
        for item in items { try require(!delegate.validateMenuItem(item), "\(name) left \(item.title) enabled behind its popup") }
        guard let close = flatten(menu).first(where: { $0.action.map(NSStringFromSelector) == "handleCloseTab" }) else {
            throw Failure.check("\(name) lost the installed Close Tab command")
        }
        close.menu?.update()
        try require(delegate.validateMenuItem(close) == !dismissalLocked && close.isEnabled == !dismissalLocked,
                    "\(name) has the wrong Close Tab menu availability")
        delegate.menuNeedsUpdate(windowMenu)
        try require(!windowItem.isEnabled, "\(name) left background Window-menu navigation enabled")
    }

    func phaseThreePublication(_ store: WorkspaceStore, window: NSWindow) async throws {
        let fixture = try await Pop2UIChatFixture(root: directory.appendingPathComponent("phase-three-publication"))
        let publications = TeamTabs(router: .shared)
        publications.serviceProvider = { fixture.team }; publications.organization = { fixture.organization }
        publications.connectionIdentity = { "phase-three-ui" }; publications.assignment = { _ in nil }
        publications.chosenTeams = { _, _ in [Pop2UIChatFixture.teamID] }
        let original = NativeTabEngine.content
        NativeTabEngine.content = { state in
            if case .publish(let scope, _, _, _) = state.route {
                return AnyView(TeamPublicationEditor(state: state, form: publications.form(state), scope: scope, tabs: publications))
            }
            return original(state)
        }
        defer {
            store.popups.dismiss(reason: .dismiss); NativeTabEngine.content = original
            fixture.team.calls.stopAll(); fixture.team.calls.useServer(nil, key: nil)
            fixture.service.orgSessions.values.forEach { $0.sync?.stop(); $0.outbox?.hold() }
            fixture.service.stopFeed(); fixture.socket.stop()
        }
        try await sessionNames.rename("Review notification banners",
            for: SessionNameKey(AgentTemplate.claudeCodeID, fixture.publicationConversationID))
        let route = ToolRoute.publish(.server(OrgKey(fixture.key)), draftID: fixture.sessionPublishDraftID,
            sourceSessionID: fixture.sourceID, conversationID: fixture.publicationConversationID)
        for light in [false, true] {
            await phaseThreeTheme(light)
            let show: @MainActor () async throws -> Void = {
                guard let state = self.support.navigation.open(route, from: store)?.tabState else { throw Failure.check("Session Publish did not open") }
                await publications.loadSource(state)
                try self.require(publications.form(state).fields.sessionTitle == "Review notification banners", "Source title missing from session publication")
            }
            try await show(); await settle()
            let sourceLabels = Set(phaseThreeLabels(window).filter { $0.hasPrefix("Source conversation:") })
            try require(sourceLabels == ["Source conversation: Review notification banners"], "Session Publish rendered an ID instead of its source name")
            try await phaseThreeCapture("publish-session", title: "Publish agent", store: store, window: window, light: light, reopen: show)
            store.popups.dismiss(reason: .dismiss)
        }
        try require(fixture.transport.openCount == 0, "Publication capture opened a transport")
        let queued = try await fixture.cache.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM outbox") }
        try require(queued == 0, "Publication capture queued a server mutation")
    }

    func phaseThreeOrganization(_ store: WorkspaceStore, window: NSWindow) async throws {
        let fixture = try await Pop2UIChatFixture(root: directory.appendingPathComponent("phase-three-organization"))
        let org = ChatOrgModel(me: Pop2UIChatFixture.meID) { _, _ in throw Failure.check("Organization capture must not send a command") }
        org.key = fixture.key
        org.set(ChatOrgView(orgName: "AgentPad", members: [
            .init(accountId: Pop2UIChatFixture.meID, handle: "andrew", name: "Andrew", role: "owner"),
            .init(accountId: Pop2UIChatFixture.peerID, handle: "sasha", name: "Sasha", role: "member")], teams: [
                .init(teamId: "general", name: "General", isGeneral: true, archived: false, mine: true, members: [Pop2UIChatFixture.meID, Pop2UIChatFixture.peerID]),
                .init(teamId: Pop2UIChatFixture.teamID, name: "Engineering", isGeneral: false, archived: false, mine: true, members: [Pop2UIChatFixture.meID])],
            invitations: [ChatSnapshot.Invitation(invitationId: "phase-three-invitation", email: "marina@example.test", role: "member",
                state: "open", expiresAt: ChatCallStore.timestamp(Date().addingTimeInterval(86400)))], followsAdmin: true))
        org.readAudit = { _ in .init(records: [.init(id: 1, at: "2026-10-20T15:30:00Z", actorAccountId: Pop2UIChatFixture.meID,
            action: "team.create", object: "Engineering", result: "ok")], next: nil) }
        await org.loadAudit()
        let devices = ChatDevicesModel()
        devices.listSessions = { [.init(sessionId: "phase-three-current", deviceName: "MacBook Pro", createdAt: "2026-10-20T09:00:00Z",
            lastSeenAt: "2026-10-20T15:30:00Z", current: true), .init(sessionId: "phase-three-other", deviceName: "Mac mini",
                createdAt: "2026-10-19T09:00:00Z", lastSeenAt: "2026-10-20T15:20:00Z", current: false)] }
        await devices.load()
        let original = NativeTabEngine.content
        let shared = TeamTabs.shared, oldService = shared.serviceProvider, oldOrg = shared.organization, oldIdentity = shared.connectionIdentity
        shared.serviceProvider = { fixture.team }; shared.organization = { org }; shared.connectionIdentity = { "phase-three-ui" }
        NativeTabEngine.content = { state in
            if case .organization = state.route {
                return AnyView(ChatOrgTabContent(state: state, form: OrganizationFormState.form(state, model: org), model: org, devices: devices))
            }
            return original(state)
        }
        defer {
            store.popups.dismiss(reason: .cancel); NativeTabEngine.content = original
            shared.serviceProvider = oldService; shared.organization = oldOrg; shared.connectionIdentity = oldIdentity
            org.stop(); fixture.team.calls.stopAll(); fixture.team.calls.useServer(nil, key: nil)
            fixture.service.orgSessions.values.forEach { $0.sync?.stop(); $0.outbox?.hold() }
            fixture.service.stopFeed(); fixture.socket.stop()
        }
        let route = ToolRoute.organization(OrgKey(fixture.key))
        for light in [false, true] {
            await phaseThreeTheme(light)
            for section in ["members", "teams", "invitations", "devices", "audit"] {
                let show: @MainActor () async throws -> Void = {
                    guard let state = self.support.navigation.open(route, from: store)?.tabState else { throw Failure.check("Organization did not open") }
                    state.navigation.selection = section; state.changed()
                }
                try await show(); await settle()
                try press("organization-section-" + section, in: window)
                try await phaseThreeCapture("organization-" + section, title: "Organization", store: store, window: window,
                    light: light, controls: ["organization-section-" + section], reopen: show)
                store.popups.dismiss(reason: .dismiss)
            }
            guard let state = support.navigation.open(route, from: store)?.tabState else { throw Failure.check("Organization remove did not open") }
            state.navigation.selection = "members"; state.changed()
            await settle()
            if captureOnly { state.confirmation.canShow = { true } }
            try press("organization-remove-member-" + Pop2UIChatFixture.peerID, in: window)
            try await eventually("Remove member confirmation did not appear") { state.confirmation.isAwaiting }
            try await phaseThreeCapture("remove-member", title: "Remove member", store: store, window: window,
                light: light, destructive: true, controls: ["inline-confirmation-cancel", "inline-confirmation-accept"], reopen: {
                    _ = self.support.navigation.open(route, from: store)
                    state.navigation.selection = "members"; state.changed(); await self.settle()
                    try self.press("organization-remove-member-" + Pop2UIChatFixture.peerID, in: window)
                    try await self.eventually("Remove member retry did not appear") { state.confirmation.isAwaiting }
                })
            if captureOnly { try press("inline-confirmation-cancel", in: window); await settle() }
            try require(org.members.count == 2, "Cancelling remove member changed the organization")
            store.popups.dismiss(reason: .dismiss)
        }
        try require(fixture.transport.openCount == 0, "Organization capture opened a transport")
    }

    func phaseThreeOperations(_ store: WorkspaceStore, window: NSWindow) async throws {
        let process = ProcessTabs(router: .shared)
        let main = store.active!, child = store.addEmptyWorkspace()
        main.customTitle = "AgentPad"; main.workingDirectory = directory.appendingPathComponent("agentpad")
        child.customTitle = "Popup review"; child.workingDirectory = directory.appendingPathComponent("popup-review")
        child.worktreeParentId = main.id; child.worktreePath = child.workingDirectory; child.worktreeBranch = "popup-review"
        for light in [false, true] {
            await phaseThreeTheme(light)
            let link: @MainActor () async throws -> Void = {
                self.support.linkFailed("This conversation is no longer available. Open Notifications to review the event.")
            }
            try await link()
            try await phaseThreeCapture("link-failure", title: "Link could not be opened", store: store, window: window,
                light: light, controls: ["link-failure-ok"], reopen: link)
            store.popups.dismiss(reason: .dismiss)

            guard let close = process.close([main, child], from: store) else { throw Failure.check("Close workspaces did not open") }
            let before = Set(store.workspaces.map(\.id))
            try await phaseThreeCapture("close-workspaces", title: "Close workspaces", store: store, window: window,
                light: light, destructive: true, controls: ["close-workspaces-cancel", "close-workspaces-accept"], reopen: {
                    _ = process.close([main, child], from: store)
                })
            try require(!close.completed && Set(store.workspaces.map(\.id)) == before, "Incidental dismissal closed a workspace")
            if captureOnly { try press("close-workspaces-cancel", in: window); await settle() }
            try require(!store.popups.isPresented && Set(store.workspaces.map(\.id)) == before, "Cancel changed a workspace")

            let fileRoot = directory.appendingPathComponent(light ? "files-light" : "files-dark")
            let sourceDirectory = fileRoot.appendingPathComponent("Downloads"), destination = fileRoot.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let source = sourceDirectory.appendingPathComponent("config.json")
            try Data("{\"fixture\":\"new\"}\n".utf8).write(to: source)
            let oldBytes = Data("{\"fixture\":\"existing\"}\n".utf8)
            try oldBytes.write(to: destination.appendingPathComponent("config.json"))
            guard let batch = process.transfer([source], into: destination, mode: .copy, from: store), let state = batch.state else {
                throw Failure.check("File conflict did not open")
            }
            let operation = Task { await batch.start() }
            defer { batch.stopIfWaiting() }
            try await eventually("Fixture copy did not reach its real conflict") { batch.conflict != nil }
            let showConflict: @MainActor () async throws -> Void = { _ = self.support.navigation.open(state.route, from: store) }
            try await phaseThreeCapture("file-conflict", title: "File conflict", store: store, window: window,
                light: light, controls: ["file-operation-keep-both", "file-operation-replace", "file-operation-skip", "file-operation-stop"], reopen: showConflict)
            try require(batch.running && batch.conflict != nil && !batch.interrupted, "Closing conflict resolved or cancelled the copy")
            try await showConflict()
            await settle()
            if captureOnly { state.confirmation.canShow = { true } }
            batch.replace()
            try await eventually("Replace file did not require confirmation") { state.confirmation.isAwaiting }
            try await phaseThreeCapture("file-replace", title: "Replace file", store: store, window: window,
                light: light, destructive: true, controls: ["inline-confirmation-cancel", "inline-confirmation-accept"], reopen: {
                    try await showConflict(); await self.settle(); batch.replace()
                    try await self.eventually("Replace retry did not appear") { state.confirmation.isAwaiting }
                })
            let preservedBytes = try Data(contentsOf: destination.appendingPathComponent("config.json"))
            try require(preservedBytes == oldBytes, "Incidental dismissal replaced a file")
            if captureOnly { try press("inline-confirmation-cancel", in: window); await settle() }
            try require(batch.running && batch.conflict != nil && !batch.interrupted, "Cancel Replace stopped its pending copy")
            batch.choose(.skip)
            _ = await operation.value
            store.popups.dismiss(reason: .dismiss)
            try require(!batch.running, "Skipping the fixture conflict left a task waiting")

            let progressSource = sourceDirectory.appendingPathComponent("notes.md")
            try Data("Fixture transfer, no external file.\n".utf8).write(to: progressSource)
            guard let progress = process.transfer([progressSource], into: destination, mode: .copy, from: store), let progressState = progress.state else {
                throw Failure.check("File progress did not open")
            }
            let gate = Pop3CopyGate()
            progress.fileManager = TransferFileIO(gate)
            let copying = Task { await progress.start() }
            defer { gate.release() }
            try await eventually("Fixture copy did not enter its controlled I/O pause") { gate.isWaiting && progress.running }
            let showProgress: @MainActor () async throws -> Void = { _ = self.support.navigation.open(progressState.route, from: store) }
            try await phaseThreeCapture("file-progress", title: "File operations progress", store: store, window: window,
                light: light, controls: ["file-operation-close"], reopen: showProgress)
            store.popups.dismiss(reason: .dismiss)
            try require(progress.running && !progress.interrupted, "Closing progress cancelled its operation")
            try await eventually("Status-bar reopening control did not appear after dismissing progress") {
                element("file-operations-status", in: window) != nil
            }
            try require(element("file-operations-status", in: window) != nil, "Hidden operation has no status-bar reopening control")
            try await showProgress()
            try require(store.popups.page?.id == ObjectIdentifier(store.popups.find(progressState.route)!.session), "Progress did not reopen its retained operation")
            gate.release(); _ = await copying.value
            try require(progress.snapshot.finished && progress.snapshot.result.doneSources == [progressSource.standardizedFileURL], "Background copy did not finish")
            store.popups.dismiss(reason: .dismiss)

            let monitor = ExternalSessionMonitor()
            let sourceSession = ExternalAgentSession(pid: 424242, sessionId: UUID().uuidString.lowercased(), kind: "interactive",
                cwd: directory.appendingPathComponent("external-project"), name: "Review notification banners", status: .idle,
                statusSince: nil, startedAt: Date(timeIntervalSince1970: 43), tty: "ttys999", processStart: 42)
            var signals = 0, resumed = 0
            monitor.snapshotProvider = { [sourceSession] }
            monitor.conversationVisibility = { ChannelConversationFilter(channelIds: []) }
            monitor.processInfo = { _ in .init(ppid: 1, tty: "ttys999", startTime: 42, name: "claude") }
            monitor.sendSignal = { _, _ in signals += 1; return 0 }
            monitor.resume = { _, _ in resumed += 1; return .failure(.agentCannotResume) }
            await monitor.refresh()
            defer { monitor.stop() }
            guard let importing = process.importExternal(sourceSession, from: store, monitor: monitor), let importState = importing.state else {
                throw Failure.check("Import session did not open")
            }
            let showImport: @MainActor () async throws -> Void = { _ = self.support.navigation.open(importState.route, from: store) }
            try require(importing.current(), "Import source fixture was not verified")
            try await phaseThreeCapture("import-session", title: "Import session", store: store, window: window,
                light: light, controls: ["import-session-cancel", "import-session-move", "import-session-source"], reopen: showImport)
            store.popups.dismiss(reason: .dismiss)
            try require(signals == 0 && resumed == 0 && importing.step == .checking, "Closing Import performed a process action")
        }
    }

    func phaseThreeFolders(_ store: WorkspaceStore, window: NSWindow) async throws {
        let folders = SidebarFoldersModel(store: SidebarFoldersStore(url: directory.appendingPathComponent("phase-three-folders.json")))
        let chats = TelegramChatsModel(), customID = UUID(), item = SidebarItemReference.agentpad(.myAgent(UUID()))
        let loaded = await folders.perform(.load(defaults: ["myAgents"]), binding: nil)
        let created = await folders.perform(.create(customID, name: "Release", symbol: "folder"), binding: nil)
        try require(loaded && created, "Isolated folder fixtures could not be created")
        let entries = [SidebarFolderEntry(id: "myAgents", title: "My agents", kind: .myAgents, symbol: "person.crop.square", count: 0)]
        let actions = SidebarFolderActions(folders: folders)
        let show: @MainActor () async throws -> Void = {
            folders.presentPopup(in: store.popups, entries: { entries }, telegram: chats)
        }
        defer { store.popups.dismiss(reason: .cancel) }
        for light in [false, true] {
            await phaseThreeTheme(light)
            try await show()
            try await phaseThreeCapture("folders", title: "Folders…", store: store, window: window,
                light: light, controls: ["folders-done"], reopen: show)
            try await show(); await settle()
            folders.deleting = folders.snapshot.catalog.custom.first { $0.id == customID }
            try await eventually("Delete custom folder did not use the popup host") { store.popups.locksDismissal }
            try await phaseThreeCapture("delete-folder", title: "Delete custom folder", store: store, window: window,
                light: light, destructive: true, controls: ["popup-confirm-cancel", "popup-confirm-accept"], reopen: {
                    try await show(); await self.settle()
                    folders.deleting = folders.snapshot.catalog.custom.first { $0.id == customID }
                    try await self.eventually("Delete folder retry did not appear") { store.popups.locksDismissal }
                })
            if captureOnly { try press("popup-confirm-cancel", in: window); await settle() }
            try require(folders.snapshot.catalog.custom.contains { $0.id == customID }, "Cancelling Delete removed the fixture folder")
            store.popups.dismiss(reason: .cancel)

            let chooser: @MainActor () async throws -> Void = {
                actions.present(item, windowID: store.windowID, anchor: "phase-three-fixture")
                try self.require(actions.request?.item == item, "Add to folder lost its item")
            }
            try await chooser()
            try await phaseThreeCapture("add-to-folder", title: "Add to folder…", store: store, window: window,
                light: light, controls: ["add-folder-cancel", "add-folder-apply"], reopen: chooser)
            store.popups.dismiss(reason: .cancel)
            try require(folders.snapshot.catalog.custom.first?.items.isEmpty == true, "Closing Add to folder changed membership")
        }
    }

    func phaseThreeTelegram(_ store: WorkspaceStore, window: NSWindow) async throws {
        let id = TelegramChatID(environment: .test, account: 101, chat: 202), pane = UUID()
        let conversation = TelegramConversationModel(id: id)
        conversation.receive(phaseThreeTelegramSnapshot(id)); conversation.panes.insert(pane)
        let ad = conversation.snapshot.sponsored.messages[0]
        // No provider is installed: these fixture dialogs cannot make a Telegram
        // request or open a URL even if a regression invokes a primary action.
        defer { store.popups.dismiss(reason: .cancel); conversation.panes.remove(pane) }
        for light in [false, true] {
            await phaseThreeTheme(light)
            for urlMode in [false, true] {
                let show: @MainActor () async throws -> Void = {
                    if urlMode {
                        conversation.applyBotResult(.answerWithURL("This link was supplied by the bot.", alert: false,
                            url: URL(string: "https://example.com/bot-details")!), pane: pane)
                    } else { conversation.applyBotResult(.alert("Your request is ready. You can continue in this conversation."), pane: pane) }
                    guard let dialog = conversation.botDialog,
                          let page = TelegramBotPopup.makePage(model: conversation, dialog: dialog, pane: pane, coordinator: store.popups) else {
                        throw Failure.check("Telegram bot factory rejected its current fixture")
                    }
                    store.popups.presentNative(page)
                }
                try await show()
                try await phaseThreeCapture(urlMode ? "telegram-bot-url" : "telegram-bot", title: "Telegram bot", store: store,
                    window: window, light: light, controls: urlMode ? ["telegram-bot-cancel", "telegram-bot-open"] : ["telegram-bot-done"], reopen: show)
                store.popups.dismiss(reason: .dismiss)
                try require(conversation.botDialog == nil, "Telegram bot dismissal kept a stale dialog")
            }
            for mode in ["info", "report", "url"] {
                let show: @MainActor () async throws -> Void = {
                    if mode == "info" { conversation.sponsoredInfo(ad, pane: pane, why: true) }
                    else if mode == "report" {
                        conversation.sponsoredDialog = .init(epoch: conversation.snapshot.epoch, pane: pane, ref: ad.ref,
                            title: "Report sponsored message", text: "Choose the option supplied by Telegram.", step: UUID(),
                            options: [.init(id: "fixture-choice-one", text: "I am not interested"), .init(id: "fixture-choice-two", text: "Other reason")])
                    } else {
                        conversation.sponsoredDialog = .init(epoch: conversation.snapshot.epoch, pane: pane, ref: ad.ref,
                            title: "Open example.com?", text: ad.url, click: .button)
                    }
                    guard let dialog = conversation.sponsoredDialog,
                          let page = TelegramSponsoredPopup.makePage(model: conversation, dialog: dialog, pane: pane, coordinator: store.popups) else {
                        throw Failure.check("Telegram sponsored factory rejected its current fixture")
                    }
                    store.popups.presentNative(page)
                }
                try await show()
                let name = mode == "info" ? "telegram-sponsored" : "telegram-sponsored-" + mode
                let controls = mode == "info" ? ["telegram-sponsored-done"]
                    : mode == "report" ? ["telegram-sponsored-cancel"] : ["telegram-sponsored-cancel", "telegram-sponsored-open"]
                try await phaseThreeCapture(name, title: "Sponsored message", store: store, window: window,
                    light: light, controls: controls, reopen: show)
                store.popups.dismiss(reason: .dismiss)
                try require(conversation.sponsoredDialog == nil && !conversation.sponsoredBusy, "Sponsored dismissal kept an active dialog")
            }
            TelegramSettingsView.presentLocalRemoval(model: telegram, coordinator: store.popups)
            try await phaseThreeCapture("telegram-local-data", title: "Remove Telegram local data", store: store, window: window,
                light: light, destructive: true, controls: ["popup-confirm-cancel", "popup-confirm-accept"], reopen: {
                    TelegramSettingsView.presentLocalRemoval(model: self.telegram, coordinator: store.popups)
                })
            if captureOnly { try press("popup-confirm-cancel", in: window); await settle() }
            try require(!store.popups.isPresented, "Local-data cancel kept a destructive confirmation")
        }
    }

    func phaseThreeTelegramSnapshot(_ id: TelegramChatID) -> TelegramConversationSnapshot {
        var value = TelegramConversationSnapshot(destination: id)
        value.kind = .channel; value.capabilities.canRead = true; value.title = "Harbor Notes"
        value.sponsored.state = .ready; value.sponsored.result = UUID(); value.sponsored.expiresAt = Date().addingTimeInterval(300)
        let raw = TDLibMessage("sponsoredMessage", ["message_id": .integer(901), "can_be_reported": .bool(true),
            "title": .string("Quiet Atlas"), "button_text": .string("Explore the guides ↗"),
            "sponsor": .typed("advertisementSponsor", ["url": .string("https://example.com/guides"),
                "info": .string("Sponsored by Quiet Atlas · Example sponsor information")]),
            "additional_info": .string("Discover considered places for your next journey."),
            "content": .typed("messageText", ["text": .typed("formattedText", ["text": .string("Independent travel guides and useful local details."), "entities": .array([])])])])
        value.sponsored.messages = [TelegramSponsoredDecoder.decode(raw, result: value.sponsored.result!)!.message]
        return value
    }

    func phaseThreeVideo(_ store: WorkspaceStore, window: NSWindow) async throws {
        let id = TelegramChatID(environment: .test, account: 101, chat: 202), pane = UUID(), lease = UUID()
        let conversation = TelegramConversationModel(id: id), controller = TelegramSponsoredVideoWindow.shared
        let movie = directory.appendingPathComponent("phase-three-video.mp4")
        try await phaseThreeMovie(movie)
        var snapshot = phaseThreeTelegramSnapshot(id)
        snapshot.sponsored.messages[0].media = [.init(id: 1, kind: .video, role: .content, width: 24, height: 24, size: 1024, url: movie)]
        conversation.receive(snapshot); conversation.panes.insert(pane)
        let ad = conversation.snapshot.sponsored.messages[0], url = URL(string: ad.url)!
        TelegramSponsoredRenderCache.shared.retain(lease, media: ad.media)
        defer { controller.close(); TelegramSponsoredRenderCache.shared.release(lease); conversation.panes.remove(pane) }
        try await eventually("Fixture video did not decode") { TelegramSponsoredRenderCache.shared.assets[movie] != nil }
        print("NOT RUN: real fullscreen entry/exit and Space transitions require visible UI; quiet mode tests the media popup off screen.")
        controller.show(ad, model: conversation, pane: pane, openChat: { _ in })
        try require(controller.confirm(url, ref: ad.ref, model: conversation, pane: pane, target: .fullscreenButton, openChat: { _ in }),
                    "Video confirmation rejected its current owner")
        guard let mediaWindow = NSApp.windows.first(where: { controller.popupCoordinator(for: $0) === controller.popups }) else {
            throw Failure.check("Video confirmation is not owned by the video window")
        }
        windows.append(mediaWindow)
        try await eventually("Video popup host did not attach") { controller.popups.window === mediaWindow }
        try require(!mediaWindow.styleMask.contains(.fullScreen), "Quiet video entered fullscreen")
        if !captureOnly {
            try await phaseThreeAcquireFocus(mediaWindow, context: "Sponsored video")
        }
        controller.popups.dismiss(reason: .cancel)
        await settle()
        try require(!controller.popups.isPresented && !controller.popups.canGoBack,
                    "Video owner discovery left a bootstrap popup in history")
        for light in [false, true] {
            await phaseThreeTheme(light)
            mediaWindow.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            let show: @MainActor () async throws -> Void = {
                try self.require(!controller.popups.isPresented && !controller.popups.canGoBack,
                                 "Video confirmation started with an unrelated popup parent")
                try self.require(controller.confirm(url, ref: ad.ref, model: conversation, pane: pane,
                    target: .fullscreenButton, openChat: { _ in }), "Video confirmation lost its media owner")
                try self.require(!controller.popups.canGoBack, "Video confirmation acquired an unrelated Back destination")
            }
            try await show()
            try require(!store.popups.isPresented && controller.popups.window === mediaWindow && mediaWindow !== window,
                        "Video confirmation escaped into the workspace window")
            try AgentPadQuietUI.assertQuiet()
            try await phaseThreeCapture("telegram-video-url", title: "Sponsored message", store: store, window: mediaWindow,
                coordinator: controller.popups, light: light, controls: ["telegram-video-website-cancel", "telegram-video-website-open"], reopen: show)
            try AgentPadQuietUI.assertQuiet()
            controller.popups.dismiss(reason: .dismiss)
            try require(!conversation.sponsoredBusy, "Video dismissal started an external action")
        }
        controller.close()
        try await eventually("Quiet video fixture did not close its owner and terminate its popup") {
            !mediaWindow.isVisible && !controller.popups.isPresented
                && controller.popups.sessions.isEmpty && !controller.popups.canGoBack
        }
        try require(!controller.confirm(url, ref: ad.ref, model: conversation, pane: pane,
            target: .fullscreenButton, openChat: { _ in }), "Closed video retained a popup owner")
    }

    func phaseThreeMovie(_ url: URL) async throws {
        try await Task.detached {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video,
                outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 24, AVVideoHeightKey: 24])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 24, kCVPixelBufferHeightKey as String: 24])
            writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 24, 24, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw TelegramConversationError.files }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let bytes = CVPixelBufferGetBaseAddress(buffer) { memset(bytes, 0, CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for index in 0..<2 {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !input.isReadyForMoreMediaData {
                    guard ContinuousClock.now < deadline else { throw TelegramConversationError.files }
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 2)) else { throw TelegramConversationError.files }
            }
            input.markAsFinished(); await writer.finishWriting()
            guard writer.status == .completed else { throw TelegramConversationError.files }
        }.value
    }
}

/// A real isolated copy pauses inside I/O so progress and dismissal can be
/// captured deterministically. The pause is bounded and is always released.
private final class Pop3CopyGate: FileManager, @unchecked Sendable {
    private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var waiting = false, released = false
    var isWaiting: Bool { lock.withLock { waiting } }
    func release() {
        let signal = lock.withLock { if released { return false }; released = true; return true }
        if signal { gate.signal() }
    }
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        lock.withLock { waiting = true }
        guard gate.wait(timeout: .now() + 30) == .success else { throw CocoaError(.fileWriteUnknown) }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private struct UIProbeWorkspaceRoot: View {
    let workspace: Workspace
    let store: WorkspaceStore
    var body: some View {
        VStack(spacing: 18) {
            Text("AgentPad").font(Theme.display(24, weight: .semibold))
            Text("Isolated popup UI profile").foregroundStyle(Theme.chromeMuted)
            UIProbeFocusView().frame(width: 180, height: 32)
            PopupFileOperationsStatus(coordinator: store.popups)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.chromeBackground).foregroundStyle(Theme.chromeForeground)
            .popupHost(store.popups)
            .preferredColorScheme(Theme.chromeColorScheme)
    }
}

private struct UIProbeFocusView: NSViewRepresentable {
    final class Probe: NSButton {
        override var acceptsFirstResponder: Bool { true }
    }
    func makeNSView(context: Context) -> Probe {
        let view = Probe(title: "Workspace focus target", target: nil, action: nil)
        view.setAccessibilityIdentifier("ui-probe-opener")
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {}
}

private final class UIProbeTokens: ChatTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(account: String) throws -> String? { lock.withLock { values[account] } }
    func write(_ token: String, account: String) throws { lock.withLock { values[account] = token } }
    func delete(account: String) throws { lock.withLock { values[account] = nil } }
    func accounts() throws -> [String] { lock.withLock { Array(values.keys) } }
    func clear() { lock.withLock { values.removeAll() } }
}

private actor UIProbeTelegramConnector: TelegramConnector {
    func snapshots() -> AsyncStream<TelegramSnapshot> {
        AsyncStream { continuation in
            continuation.yield(TelegramSnapshot())
            continuation.finish()
        }
    }
    func restore() {}
    func connect() {}
    func retry() {}
    func usePhone(attemptID: UUID, revision: UInt64) {}
    func useQR(attemptID: UUID, revision: UInt64) {}
    func submit(_ input: TelegramAuthInput, attemptID: UUID, revision: UInt64) {}
    func disconnect() {}
    func removeLocalData() {}
    func close() -> Bool { true }
}
extension NoModalsUIProbe {
    /// Render-only evidence uses the same quiet window containment as the full
    /// firstResponder, Escape, scrim and traversal checks.
    private func capturePhaseTwo() async throws {
        support.navigation.finishStartup()
        let store = host(), window = windows[0]
        let reviewFixesOnly = ProcessInfo.processInfo.environment["AGENTPAD_POPUP_REVIEW_FIXES_ONLY"] == "1"
        if !reviewFixesOnly {
            for light in [false, true] {
                model.appearanceMode = light ? .light : .dark
                NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
                await settle()
                try await phaseTwoLocalScreenshots(store, window: window, light: light, exerciseInput: false)
                try await phaseTwoConnectScreenshots(store, window: window, light: light)
            }
        }
        try await phaseTwoScreenshots(store, window: window, reviewFixesOnly: reviewFixesOnly)
        try checkScreenshotInventory(reviewFixesOnly
            ? ["forward", "request-approval", "request-approval-draft", "publish", "publish-session"]
            : NoModalsMatrixInventory.phaseTwoFrames, layouts: NoModalsMatrixInventory.layoutFrames)
        try require(!unexpectedWindow && processRequests == 0, "Forbidden surface or terminal process")
        await telegram.shutdown()
        let coverage = reviewFixesOnly
            ? "Step-0 review frames only: Forward, Request approval with/without retained reason, Publish and session-based Publish."
            : "All groups C–F rendered in dark/light using the actual PopupHost and views with isolated fixtures."
        let body = """
        # Popup rendered capture check

        PASS: \(checks) rendered-view and model checks; \(screenshotCount) screenshots.
        Native keyboard focus, menu isolation, Escape and scrim input were NOT checked in capture-only mode.
        \(coverage)
        No real server sign-in, socket connection, terminal/worktree creation or request execution.

        \(screenshotNames.sorted().map { "- " + $0 }.joined(separator: "\n"))
        """
        let report = reviewFixesOnly ? "pop3-review-capture-report.md" : "pop2-capture-report.md"
        try body.write(to: shots.deletingLastPathComponent().appendingPathComponent(report),
                       atomically: true, encoding: .utf8)
        print("UI profile and screenshots: \(shots.path)")
    }

    private func phaseTwoLocalScreenshots(_ store: WorkspaceStore, window: NSWindow, light: Bool,
                                         exerciseInput: Bool = true) async throws {
        func dismiss(_ action: String) async throws {
            if exerciseInput {
                try await dismissAndCheck(store, window: window, action: action)
            } else {
                store.popups.dismiss(reason: .dismiss)
                await settle()
                try require(!store.popups.isPresented, "Model dismissal did not hide the popup")
            }
        }
        let suffix = light ? "-light" : ""
        let tabs = LocalFormTabs.shared
        store.popups.dismiss(reason: .dismiss)
        guard let workspace = store.active,
              let newAgent = tabs.newAgent(from: store), let state = newAgent.tabState else {
            throw Failure.check("New agent popup is unavailable")
        }
        let form = tabs.form(state)
        form.newAgent.templateID = AgentTemplate.claudeCode.id
        form.newAgent.folder = directory.appendingPathComponent("project").path
        form.newAgent.name = ""
        await settle()
        _ = try dialog(window, title: "New agent")
        try require(element("new-agent-folder", in: window) != nil && element("add-agent", in: window) != nil,
                    "New agent fields/footer are missing")
        try screenshot(window, name: "popups-new-agent" + suffix)
        try await matrixToolInteractions("new-agent", title: "New agent", store: store, window: window, light: light)
        let expected = state.draft
        try await dismiss("scrim")
        let reopenedAgent = tabs.newAgent(from: store)
        // A native field-editor commit can advance revision without changing
        // the retained form. Compare its complete payload, identity and route.
        try require(reopenedAgent === newAgent && state.draft?.id == expected?.id
                    && state.draft?.route == expected?.route && state.draft?.payload == expected?.payload,
                    "New agent scrim dismissal lost the draft")
        print("New Agent retained draft: revision \(expected?.revision ?? 0) -> \(state.draft?.revision ?? 0), identical payload")
        await settle()
        try press("new-agent-cancel", in: window); await settle()
        try require(!store.popups.contains(newAgent.id), "New agent Cancel did not consume the form")

        guard let ssh = tabs.newSSH(from: store), let sshState = ssh.tabState else { throw Failure.check("SSH popup missing") }
        let sshForm = tabs.form(sshState)
        sshForm.name = "Staging"; sshForm.host = "deploy@staging"
        await settle(); _ = try dialog(window, title: "New SSH workspace")
        try screenshot(window, name: "popups-new-ssh" + suffix)
        try await matrixToolInteractions("new-ssh", title: "New SSH workspace", store: store, window: window, light: light)
        try await dismiss("escape")
        try require(tabs.newSSH(from: store) === ssh && sshForm.host == "deploy@staging", "SSH draft lost after Escape")
        await settle(); try press("local-form-cancel", in: window); await settle()

        let route = ToolRoute.newWorktree(repository: directory.path, sourceWorkspaceID: workspace.id, draftID: UUID())
        let worktree = store.openToolTab(route)
        guard let worktreeState = worktree.tabState else { throw Failure.check("Worktree popup missing") }
        let worktreeForm = tabs.form(worktreeState)
        // Inject the existing loaded state before the SwiftUI task mounts. No
        // branch, worktree or filesystem operation is requested by this probe.
        worktreeForm.loaded = true
        worktreeForm.worktree.branch = "popup-navigation"
        worktreeForm.worktree.startRef = "HEAD"
        worktreeForm.worktree.templateID = AgentTemplate.claudeCode.id
        await settle(); _ = try dialog(window, title: "New worktree")
        try screenshot(window, name: "popups-new-worktree" + suffix)
        try await matrixToolInteractions("new-worktree", title: "New worktree", store: store, window: window, light: light)
        try await dismiss("close")
        try require(store.openToolTab(route) === worktree && worktreeForm.worktree.branch == "popup-navigation",
                    "Worktree draft lost after X")
        await settle(); try press("local-form-cancel", in: window); await settle()

        guard let details = tabs.details(workspace, from: store), let detailsState = details.tabState else {
            throw Failure.check("Workspace details popup missing")
        }
        let detailsForm = tabs.form(detailsState)
        detailsForm.tag.name = "Review"
        detailsForm.tag.hex = WorkspaceColorTag.blue.hex
        await settle(); _ = try dialog(window, title: "Workspace details")
        try screenshot(window, name: "popups-workspace-details" + suffix)
        try await matrixToolInteractions("workspace-details", title: "Workspace details", store: store, window: window, light: light)
        try press("local-form-cancel", in: window); await settle()
        try require(!store.popups.isPresented && !store.popups.contains(details.id), "Workspace details Cancel failed")
        try require(store.allSessions.allSatisfy { $0.toolRoute?.presentation != .popup }, "Group C route entered a pane")
    }
}


private extension NoModalsUIProbe {
    func phaseTwoConnectScreenshots(_ store: WorkspaceStore, window: NSWindow, light: Bool) async throws {
        let suffix = light ? "-light" : ""
        let fixtureTokens = UIProbeTokens()
        let service = ChatService(files: ChatFiles(directory: directory.appendingPathComponent("phase2-connect" + suffix)),
                                  tokens: fixtureTokens)
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [PhaseTwoConnectProbeProtocol.self]) }
        // Exercise the actual sign-in form and queue without starting a feed,
        // switching the app's Team mode or writing a real connection record.
        let form = ChatConnectModel(service: service, switchToServer: {})
        form.teamWorkIdle = { true }
        form.email = "andrew@example.com"
        let popup = store.popups.present(.connection)
        guard let state = popup.tabState else { throw Failure.check("Connect popup has no runtime form state") }
        state.connectionForm = form
        var inFlight: Task<Void, Never>?
        do {
            await settle()
            _ = try dialog(window, title: "Server + email")
            try require(store.allSessions.allSatisfy { $0.toolRoute != .connection }, "Connect was inserted into a tab")
            try require(element("connect-server", in: window) != nil, "Connect server field is missing")
            try require(element("connect-email", in: window) != nil, "Connect email field is missing")
            try require(element("connect-progress", in: window) != nil, "Connect step progress is missing")
            try screenshot(window, name: "popups-connect-server" + suffix)
            try await matrixToolInteractions("connect-server", title: "Server + email", store: store, window: window, light: light)

            if phaseThreeMenuDelegate != nil { PhaseTwoConnectProbeProtocol.holdCode() }
            defer { PhaseTwoConnectProbeProtocol.releaseCode() }
            let sending = Task { await form.sendCode() }
            inFlight = sending
            try await eventually("Connect did not enter its in-flight state") { form.busy }
            await settle()
            try require(form.busy, "Connect progress disappeared before the delayed fixture replied")
            try require(element("connect-busy", in: window) != nil, "Connect in-flight progress is missing")
            try screenshot(window, name: "popups-connect-busy" + suffix)
            try await matrixToolInteractions("connect-busy", title: "Server + email", store: store, window: window, light: light)
            PhaseTwoConnectProbeProtocol.releaseCode()
            await sending.value
            inFlight = nil
            try require(form.step == .code && form.error == nil, "Connect did not reach the Code step")
            await settle()
            _ = try dialog(window, title: "Verification code")

            form.code = "12345678"
            try press("popup-close", in: window)
            await settle()
            try require(!store.popups.isPresented && !form.isClosed, "Connect X discarded the code draft")
            let reopened = store.popups.present(.connection)
            await settle()
            try require(reopened === popup && state.connectionForm === form, "Connect reopened a different runtime form")
            try require(form.step == .code && form.code == "12345678", "Connect lost the code-step draft")
            try require(store.popups.draftKept, "Connect reopened without Draft kept")
            try screenshot(window, name: "popups-connect-code" + suffix)
            try await matrixToolInteractions("connect-code", title: "Verification code", store: store, window: window, light: light)

            await form.submitCode()
            guard case .chooseOrg(let organizations) = form.step else {
                throw Failure.check("Connect did not offer its fixture organizations")
            }
            try require(organizations.map(\.orgName) == ["AgentPad", "Anysite"], "Connect organization choices changed")
            await settle()
            _ = try dialog(window, title: "Choose organization")
            try screenshot(window, name: "popups-connect-organization" + suffix)
            try await matrixToolInteractions("connect-organization", title: "Choose organization", store: store, window: window, light: light)

            await form.choose(PhaseTwoConnectProbeProtocol.agentPadOrg)
            guard case .name = form.step else { throw Failure.check("Connect did not reach the Name step") }
            form.displayName = "Andrew"
            await settle()
            _ = try dialog(window, title: "Your name")
            try screenshot(window, name: "popups-connect-name" + suffix)
            try await matrixToolInteractions("connect-name", title: "Your name", store: store, window: window, light: light)

            await form.saveName()
            try require(form.step == .done && form.error == nil, "Connect did not reach its completed state")
            try require(form.connectedSummary == "AgentPad · andrew@example.com", "Connect completed summary is missing")
            let key = ChatOrgKey(server: try ChatServerAddress(parsing: ChatConnectModel.defaultServer),
                                 accountId: PhaseTwoConnectProbeProtocol.account, orgId: PhaseTwoConnectProbeProtocol.agentPadOrg)
            let queuedTypes = try service.session(for: key).store?.commands().map(\.type)
            try require(queuedTypes == ["member.set_name"],
                        "Connect Name Save did not use the existing send queue")
            await settle()
            _ = try dialog(window, title: "Connected")
            try screenshot(window, name: "popups-connect-connected" + suffix)
            try await matrixToolInteractions("connect-connected", title: "Connected", store: store, window: window, light: light)
            try press("connect-close", in: window)
            await settle()
            try require(!store.popups.contains(popup.id), "Connected Close retained a completed form")
            try require(service.connection != nil, "Connected Close undid the completed fixture connection")
        } catch {
            store.popups.dismiss(popup, reason: .cancel)
            await inFlight?.value
            await service.discardSignIn()
            fixtureTokens.clear()
            throw error
        }
        await service.discardSignIn()
        fixtureTokens.clear()
    }
}

// Every request is intercepted, including cleanup; this fixture never falls
// through to the network. There is no mutable global response configuration.
private final class PhaseTwoConnectProbeProtocol: URLProtocol, @unchecked Sendable {
    private static let gateLock = NSLock()
    nonisolated(unsafe) private static var codeGate: DispatchSemaphore?
    static func holdCode() { gateLock.withLock { codeGate = DispatchSemaphore(value: 0) } }
    static func releaseCode() { gateLock.withLock { codeGate?.signal(); codeGate = nil } }
    static let account = "fa121200-0000-4000-8000-000000000001"
    static let agentPadOrg = "fa121200-0000-4000-8000-000000000002"
    private static let anysiteOrg = "fa121200-0000-4000-8000-000000000003"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status: Int
        let body: Data
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/v1/server"):
            status = 200
            body = Data(#"{"name":"agentpad-server","version":"0.1.0","generation":"phase2-probe","api_versions":["v1"],"capabilities":["auth.email_code","events.ws"]}"#.utf8)
        case ("POST", "/v1/auth/code"):
            status = 202
            body = Data("{}".utf8)
        case ("POST", "/v1/auth/session"):
            status = 200
            body = Data("""
            {"token":"\(UUID().uuidString)","session_id":"phase2-ui-only-session","account_id":"\(Self.account)","orgs":[
            {"org_id":"\(Self.agentPadOrg)","org_name":"AgentPad","role":"owner","handle":"andrew","name":"andrew"},
            {"org_id":"\(Self.anysiteOrg)","org_name":"Anysite","role":"owner","handle":"andrew","name":"andrew"}]}
            """.utf8)
        case ("DELETE", "/v1/auth/session"):
            status = 204
            body = Data()
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(350)) { [self] in
            if request.url?.path == "/v1/auth/code", let gate = Self.gateLock.withLock({ Self.codeGate }) {
                guard gate.wait(timeout: .now() + 30) == .success else {
                    client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
                }
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}


extension NoModalsUIProbe {
    func phaseTwoScreenshots(_ store: WorkspaceStore, window: NSWindow, reviewFixesOnly: Bool = false) async throws {
        let originalSessionIDs = Set(store.popups.sessions.map(\.id))
        let fixture = try await Pop2UIChatFixture(root: directory.appendingPathComponent("phase-two-chat"))
        let composition = CompositionTabs(router: .shared, chat: fixture.service, team: fixture.team, orgModel: { fixture.organization })
        let requests = RequestTabs(router: .shared, chat: fixture.service, team: fixture.team, versions: ClaudeVersionApprovals())
        let publications = TeamTabs(router: .shared)
        publications.serviceProvider = { fixture.team }
        publications.organization = { fixture.organization }
        publications.connectionIdentity = { "phase-two-ui-session|g1" }
        publications.assignment = { id in id == fixture.agent.id ? fixture.key : nil }
        publications.chosenTeams = { _, _ in [Pop2UIChatFixture.teamID] }
        let originalContent = NativeTabEngine.content
        NativeTabEngine.content = { state in
            switch state.route {
            case .newDM(let key):
                return AnyView(ChatDMNewView(state: state, scope: key, service: fixture.service))
            case .newChannel:
                return AnyView(NewChannelTab(model: composition.channelModel(state)))
            case .forward:
                return AnyView(ForwardTab(state: state, tabs: composition))
            case .ask:
                return AnyView(PersonalAskTab(state: state, model: composition.askModel(state)))
            case .agent:
                return AnyView(AgentTab(state: state, tabs: composition))
            case .request:
                return AnyView(RequestTabView(state: state, model: requests.model(state)))
            case .publish(let scope, _, _, _), .publication(let scope, _):
                return AnyView(TeamScopeView(scope: scope, tabs: publications) {
                    TeamPublicationEditor(state: state, form: publications.form(state), scope: scope, tabs: publications)
                })
            default: return originalContent(state)
            }
        }
        defer {
            NativeTabEngine.content = originalContent
            store.popups.dismiss(reason: .dismiss)
            for session in store.popups.sessions where !originalSessionIDs.contains(session.id) {
                store.popups.dismiss(session, reason: .applied)
            }
            fixture.team.calls.stopAll()
            fixture.team.calls.useServer(nil, key: nil)
            fixture.service.orgSessions.values.forEach { $0.sync?.stop(); $0.outbox?.hold() }
            fixture.service.stopFeed()
            fixture.socket.stop()
        }
        let scope = OrgKey(fixture.key)
        try await sessionNames.rename("Review notification banners",
            for: SessionNameKey(AgentTemplate.claudeCodeID, fixture.publicationConversationID))
        func present(_ route: ToolRoute) throws -> TabState {
            guard let state = support.navigation.open(route, from: store)?.tabState else {
                throw Failure.check("Phase two could not open \(route.title)")
            }
            return state
        }
        func capture(_ name: String, title: String, light: Bool) async throws {
            await settle()
            let panel = try dialog(window, title: title)
            if case .tool(let session) = store.popups.page, let state = session.tabState {
                // Window restoration and the body's measured size settle in
                // separate layout passes. Capture the fitted result, not the
                // initial fallback frame immediately after a resize.
                let header: CGFloat = 63 + (store.popups.showsDraftNotice ? 30 : 0)
                let maximum = window.contentView!.bounds.height - 48
                try await eventually("Phase two popup did not fit its content: \(name)") {
                    window.contentView?.layoutSubtreeIfNeeded()
                    guard let measured = state.popupContentHeight else { return false }
                    let natural = session.engine.view.fittingSize.height
                    return abs(measured - natural) <= 1
                        && abs(panel.bounds.height - min(natural + header, maximum)) <= 1
                        && panel.visibleRect.contains(panel.bounds)
                }
                var requiredControls = ["popup-close"]
                if case .publish = state.route {
                    requiredControls += ["publication-cancel", "publication-save"]
                }
                func frame(_ control: NSObject) -> NSRect {
                    let selector = NSSelectorFromString("accessibilityFrame")
                    guard control.responds(to: selector) else { return .zero }
                    typealias ReadFrame = @convention(c) (AnyObject, Selector) -> NSRect
                    let readFrame = unsafeBitCast(control.method(for: selector), to: ReadFrame.self)
                    return readFrame(control, selector)
                }
                func controlFrame(_ identifier: String, elements: [NSObject]) -> NSRect {
                    let identified = elements.filter { attribute($0, "accessibilityIdentifier") as? String == identifier }
                    if let visible = identified.map(frame).first(where: { !$0.isEmpty }) { return visible }
                    // Nested SwiftUI accessibility groups can propagate their
                    // identifier to descendants. A unique named button still
                    // provides its real visible frame; this is not an ID check.
                    let labels: [String] = switch identifier {
                    case "publication-cancel": ["Cancel"]
                    case "publication-save": ["Publish…", "Save…"]
                    default: []
                    }
                    let named = elements.filter { object in
                        attribute(object, "accessibilityRole") as? String == "AXButton"
                            && ["accessibilityLabel", "accessibilityTitle"].contains { key in
                                labels.contains(attribute(object, key) as? String ?? "")
                            }
                    }
                    return named.count == 1 ? frame(named[0]) : .zero
                }
                func writeGeometry(_ filename: String) throws {
                    let elements = nodes(panel)
                    let buttons = elements.filter {
                        attribute($0, "accessibilityRole") as? String == "AXButton"
                            || requiredControls.contains(attribute($0, "accessibilityIdentifier") as? String ?? "")
                    }
                    let geometry = ["bounds=\(panel.bounds)", "frame=\(panel.frame)", "visibleRect=\(panel.visibleRect)",
                        "visibleScreenFrame=\(window.convertToScreen(panel.convert(panel.visibleRect, to: nil)))"]
                        + requiredControls.map { id in
                            let count = elements.filter { attribute($0, "accessibilityIdentifier") as? String == id }.count
                            return "\(id): identifierMatches=\(count), resolvedFrame=\(controlFrame(id, elements: elements))"
                        }
                        + buttons.map {
                            "\(type(of: $0)) id=\(attribute($0, "accessibilityIdentifier") ?? "") label=\(attribute($0, "accessibilityLabel") ?? "") title=\(attribute($0, "accessibilityTitle") ?? "") role=\(attribute($0, "accessibilityRole") ?? "") frame=\(frame($0))"
                        }
                    try geometry.joined(separator: "\n").write(to: shots.appendingPathComponent(filename + ".txt"),
                        atomically: true, encoding: .utf8)
                }
                do {
                    try await eventually("Phase two popup clipped its chrome: \(name)") {
                        window.contentView?.layoutSubtreeIfNeeded()
                        let visibleFrame = window.convertToScreen(panel.convert(panel.visibleRect, to: nil))
                        let content = window.contentView!
                        let contentFrame = window.convertToScreen(content.convert(content.bounds, to: nil))
                        let elements = nodes(panel)
                        return requiredControls.allSatisfy { identifier in
                            let frame = controlFrame(identifier, elements: elements)
                            return !frame.isEmpty && visibleFrame.contains(frame) && contentFrame.contains(frame)
                        }
                    }
                    if case .publish = state.route {
                        try writeGeometry("layout-" + name + "-chrome" + (light ? "-light" : ""))
                    }
                } catch {
                    let failureName = "failure-" + name + "-chrome" + (light ? "-light" : "")
                    try? writeGeometry(failureName)
                    try? screenshot(window, name: failureName)
                    throw error
                }
            }
            try require(store.popups.isPresented, "Phase two capture lost its popup: \(name)")
            try screenshot(window, name: "popups-" + name + (light ? "-light" : ""))
            try await matrixToolInteractions(name, title: title, store: store, window: window, light: light)
            store.popups.dismiss(reason: .dismiss)
            await settle()
        }
        try await eventually("Offline chat fixture did not publish its cached organization view") {
            fixture.organization.agentsVisible && fixture.organization.visibleChannel(Pop2UIChatFixture.channelID) != nil
        }
        for light in [false, true] {
            model.appearanceMode = light ? .light : .dark
            NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            await settle()

            if !reviewFixesOnly {
                let newMessage = try present(.newDM(scope))
                await settle()
                try require(newMessage.newDMModel?.people.count == 2, "New message did not render cached people")
                newMessage.newDMModel?.query = "Sasha"
                await settle()
                try require(newMessage.newDMModel?.people.count == 1, "New message search did not filter")
                store.popups.dismiss(reason: .dismiss)
                _ = try present(.newDM(scope))
                try require(newMessage.newDMModel?.query == "Sasha", "New message dismissal lost search draft")
                newMessage.newDMModel?.query = ""
                try await capture("new-message", title: "New message", light: light)

                composition.newChannel(key: fixture.key, teamID: Pop2UIChatFixture.teamID, from: store)
                guard case .tool(let channelSession) = store.popups.page, let channelState = channelSession.tabState else {
                    throw Failure.check("New channel was not presented")
                }
                composition.channelModel(channelState).fields.name = "design-review"
                try await capture("new-channel", title: "New channel", light: light)
            }

            let forwardRoute = ToolRoute.forward(sourceSessionID: fixture.sourceID, answerSnapshotID: fixture.snapshotID)
            let forward = try present(forwardRoute)
            if forward.draft == nil {
                forward.edit(.forwardForm(.init(snapshot: Pop2UIChatFixture.answer, markdown: Pop2UIChatFixture.answer,
                    sourceTitle: "Claude Code · Review notification banners", destination: scope,
                    channelID: Pop2UIChatFixture.channelID)))
            }
            let forwardModel = composition.forwardModel(forward)
            await forwardModel?.loadInitialDestinations()
            try require(forwardModel?.online == true, "Forward fixture must expose verified cached destinations")
            try require(forwardModel?.channel == Pop2UIChatFixture.channelID, "Forward lost its selected channel")
            try require(forwardModel?.accountSignature == "Andrew", "Forward did not resolve the cached sender name")
            try await capture("forward", title: "Forward", light: light)

            if !reviewFixesOnly {
                let askRoute = ToolRoute.ask(scope, agentID: Pop2UIChatFixture.askAgentID)
                let askState = try present(askRoute), ask = composition.askModel(askState)
                if ask.sentRequest != nil { try ask.discard() }
                ask.prompt = "Проверь, как устроены настройки и служебные формы."
                try require(ask.canSend, "Offline Ask fixture could not prepare an explicit request")
                try await capture("ask-agent", title: "Ask agent", light: light)
                _ = try present(askRoute)
                let beforeAsk = try fixture.cache.outbox.commands().count
                ask.send()
                try require(ask.sentRequest != nil && store.popups.isPresented, "Ask did not retain its sent receipt")
                let afterAsk = try fixture.cache.outbox.commands().count
                try require(afterAsk == beforeAsk + 1, "Ask did not queue exactly one request")
                try await capture("ask-sent", title: "Sent — Open request", light: light)
                guard let sentID = ask.sentRequest?.requestId else { throw Failure.check("Ask receipt lost request identity") }
                try await fixture.cache.queue.write { db in
                    try db.execute(sql: "UPDATE requests SET state = 'running', version = version + 1 WHERE request_id = ?", arguments: [sentID])
                }
                let waiting = try present(askRoute)
                try await eventually("Ask request stopped updating after dismissal") { composition.askModel(waiting).sentRequest?.state == .running }
                let afterReopen = try fixture.cache.outbox.commands().count
                try require(afterReopen == beforeAsk + 1, "Closing/reopening Ask queued an action")
                store.popups.dismiss(reason: .dismiss)
                try ask.discard()
            }

            let approval = try present(.request(.server(scope), requestID: Pop2UIChatFixture.approvalID))
            await requests.model(approval).load()
            try require(requests.model(approval).canDecide, "Approval screenshot has no real model decision state")
            await settle()
            let hasDecisionActions = element("request-allow", in: window) != nil && element("request-decline", in: window) != nil
            if !hasDecisionActions {
                try screenshot(window, name: "failure-request-footer")
                let tree = nodes(window).map {
                    "\(type(of: $0)) id=\(attribute($0, "accessibilityIdentifier") ?? "") role=\(attribute($0, "accessibilityRole") ?? "") label=\(attribute($0, "accessibilityLabel") ?? "")"
                }.joined(separator: "\n")
                try tree.write(to: shots.appendingPathComponent("request-footer-accessibility.txt"), atomically: true, encoding: .utf8)
            }
            try require(hasDecisionActions, "Request decision actions are not accessible")
            try await capture("request-approval", title: "Request approval", light: light)
            _ = try present(approval.route)
            try await checkCompactConfirmation(approval, window: window, name: "request-approval", light: light)
            store.popups.dismiss(reason: .dismiss)

            if !reviewFixesOnly {
                let folder = try present(.request(.server(scope), requestID: Pop2UIChatFixture.folderID))
                try require(requests.model(folder).folders.count == 1, "Folder screenshot lacks pending runtime folder request")
                try await capture("request-folder", title: "Folder permission", light: light)

                let result = try present(.request(.server(scope), requestID: Pop2UIChatFixture.publicationRequestID))
                try require(requests.model(result).result == Pop2UIChatFixture.answer, "Publication screenshot lacks exact retained run text")
                try await capture("request-publish", title: "Publish result", light: light)
            }

            let publishRoute = ToolRoute.publish(.server(scope), draftID: fixture.publishDraftID, sourceSessionID: nil, conversationID: nil)
            let publish = try present(publishRoute), form = publications.form(publish)
            form.fields.name = "backend-fresh"
            form.fields.description = "Review migrations and release changes."
            form.fields.folder = fixture.project.path
            form.fields.access = .readGit
            form.fields.teamIDs = [Pop2UIChatFixture.teamID]
            try await capture("publish", title: "Publish agent", light: light)
            _ = try present(publishRoute)
            try await checkCompactConfirmation(publish, window: window, name: "publish", light: light)
            store.popups.dismiss(reason: .dismiss)

            let sessionPublish = try present(.publish(.server(scope), draftID: fixture.sessionPublishDraftID,
                sourceSessionID: fixture.sourceID, conversationID: fixture.publicationConversationID))
            let sessionForm = publications.form(sessionPublish)
            await publications.loadSource(sessionPublish)
            try await eventually("Session publication did not load the isolated source conversation") { sessionForm.loaded }
            try require(sessionForm.error == nil && sessionForm.fields.folder == fixture.project.path,
                        "Session publication did not retain its source folder")
            try require(sessionForm.fields.sourceConversationID == fixture.publicationConversationID
                        && sessionForm.fields.mode == .session && sessionForm.fields.sessionTitle == "Review notification banners",
                        "Session publication is missing its source, mode or explicit session name")
            await settle()
            let sessionLabels = nodes(window).flatMap { node in
                [attribute(node, "accessibilityLabel"), attribute(node, "accessibilityValue")].compactMap { $0 as? String }
            }
            for text in ["Source conversation:", "This session", "Session's name", "Each call uses a copy of this conversation."] {
                try require(sessionLabels.contains { $0.contains(text) }, "Session publication is missing rendered content: \(text)")
            }
            try await capture("publish-session", title: "Publish agent", light: light)

            if !reviewFixesOnly {
                _ = try present(.publication(.server(scope), publicationID: fixture.agent.id.uuidString.lowercased()))
                try await capture("publication", title: "Publication", light: light)

                let card = try present(.agent(scope, agentID: fixture.agent.id.uuidString.lowercased()))
                card.navigation.anchor = Pop2UIChatFixture.channelID
                card.changed()
                try await capture("published-agent", title: "Published agent card", light: light)
            }
        }
        // Keep the edited-draft scenario separate from the baseline form and
        // compact-window matrix. Each scenario restores its own fixture state.
        for light in [false, true] {
            model.appearanceMode = light ? .light : .dark
            NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            let approval = try present(.request(.server(scope), requestID: Pop2UIChatFixture.approvalID))
            try require(!store.popups.showsDraftNotice, "A request without a reason showed a draft notice")
            requests.model(approval).reason = "Please narrow the scope first."
            store.popups.dismiss(reason: .dismiss)
            _ = try present(approval.route)
            await settle()
            try require(requests.model(approval).reason == "Please narrow the scope first.", "Request dismissal lost its reason")
            try require(store.popups.showsDraftNotice && element("popup-draft-kept", in: window) != nil,
                        "Restored decline reason is missing the accessible Draft kept notice")
            try await capture("request-approval-draft", title: "Request approval", light: light)
            requests.clearReason(approval)
            try require(approval.draft == nil, "The draft capture did not clean up its reason fixture")
        }
        let disallowed = try fixture.cache.outbox.commands().filter { $0.type != "request.create" }
        try require(disallowed.isEmpty, "Screenshot navigation queued a decision, publication, message or channel creation")
        if reviewFixesOnly {
            let commands = try fixture.cache.outbox.commands()
            try require(commands.isEmpty, "Review captures queued a request")
        }
        let executorCommands = try fixture.journal.commands(for: fixture.key)
        try require(executorCommands == fixture.seededExecutorCommands, "Screenshot navigation changed the fixture's executor commands")
        try require(fixture.transport.openCount == 0, "Screenshot fixture opened a socket")
        try require(!unexpectedWindow && processRequests == 0, "Phase two opened a forbidden window or process")
    }

    func checkCompactConfirmation(_ state: TabState, window: NSWindow, name: String, light: Bool) async throws {
        let originalSize = window.contentView!.bounds.size
        let canShow = state.confirmation.canShow
        // This rendered-layout check never accepts a decision. The regular
        // interaction run retains the real key-window eligibility checks.
        if captureOnly { state.confirmation.canShow = { true } }
        defer {
            state.confirmation.cancel()
            state.confirmation.canShow = canShow
            state.saveError = nil
            window.setContentSize(originalSize)
        }
        window.setContentSize(NSSize(width: 900, height: 640))
        state.saveError = "The draft could not be saved. Keep editing or retry."
        state.confirmation.request(.init(tabID: UUID(), targetID: "layout-check"), title: "Review this decision",
            consequences: "The named action requires confirmation. Closing or cancelling applies nothing.",
            verb: "Confirm", stillValid: { true }, operation: { throw Failure.check("Layout check must never execute") })
        await settle()
        let panel = try dialog(window, title: state.route == .connection ? "Server + email" : name == "publish" ? "Publish agent" : "Request approval")
        // Autosave can remove the error block during this resize. Wait for the
        // resulting layout, while retaining the exact containment requirement.
        try await eventually("Compact popup clipped confirmation Cancel") {
            guard let cancel = element("inline-confirmation-cancel", in: window) else { return false }
            let selector = NSSelectorFromString("accessibilityFrame")
            typealias ReadFrame = @convention(c) (AnyObject, Selector) -> NSRect
            let readFrame = unsafeBitCast(cancel.method(for: selector), to: ReadFrame.self)
            let cancelFrame = readFrame(cancel, selector)
            let panelFrame = window.convertToScreen(panel.convert(panel.bounds, to: nil))
            return panelFrame.insetBy(dx: -1, dy: -1).contains(cancelFrame)
        }
        try screenshot(window, name: "layout-" + name + "-confirmation" + (light ? "-light" : ""))
        try require(state.confirmation.isAwaiting, "Layout confirmation did not remain pending")
    }
}

@MainActor
private final class Pop2UISocket: ChatSocketTransport {
    private(set) var openCount = 0
    func open(_ request: URLRequest, onEvent: @escaping @MainActor (ChatTransportEvent) -> Void) { openCount += 1 }
    func send(_ text: String) {}
    func close(code: Int) {}
}

// Every HTTP request is intercepted. Unknown requests fail locally; URLSession
// cannot fall through to a real server, keychain or token validation endpoint.
private final class Pop2UIProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let body: Data
        if url.path.hasSuffix("/dms") { body = Data(#"{"dms":[],"next":null}"#.utf8) }
        else if url.path.hasSuffix("/channels") {
            body = Data("{\"channels\":[{\"channel_id\":\"\(Pop2UIChatFixture.channelID)\",\"team_id\":\"\(Pop2UIChatFixture.teamID)\",\"name\":\"agentpad\",\"archived\":false,\"version\":1}],\"next\":null}".utf8)
        } else if url.path.hasSuffix("/messages") { body = Data(#"{"messages":[],"next":null,"head":0}"#.utf8) }
        else if url.path.hasSuffix("/content") {
            let value: [String: Any] = ["request_id": url.deletingLastPathComponent().lastPathComponent,
                "text": Pop2UIChatFixture.question,
                "context": [["message_id": Pop2UIChatFixture.messageID, "revision": 1,
                    "author_account_id": Pop2UIChatFixture.peerID, "text": "Проверь миграции перед релизом."]]]
            body = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        } else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class Pop2UIChatFixture {
    nonisolated static let meID = "8c2b3b55-6b1e-4f5e-9a39-0e3c1f7a2d40"
    nonisolated static let peerID = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    nonisolated static let agentID = "2d7c6e0a-1f3b-4c5d-9e8f-0a1b2c3d4e5f"
    nonisolated static let askAgentID = "3d7c6e0a-1f3b-4c5d-9e8f-0a1b2c3d4e5f"
    nonisolated static let teamID = "f5000000-0000-4000-8000-000000000004"
    nonisolated static let channelID = "f5000000-0000-4000-8000-000000000001"
    nonisolated static let messageID = "f5000000-0000-4000-8000-000000000002"
    nonisolated static let approvalID = "f5000000-0000-4000-8000-000000000003"
    nonisolated static let folderID = "f5000000-0000-4000-8000-000000000006"
    nonisolated static let publicationRequestID = "f5000000-0000-4000-8000-000000000007"
    nonisolated static let question = "Проверь миграции перед релизом."
    nonisolated static let answer = "Checked the notification preferences. Settings stay in a focused popup; conversations and terminals keep their tabs."
    let service: ChatService
    let cache: ChatStore
    let journal: ChatJournal
    let key: ChatOrgKey
    let team: TeamService
    let organization: ChatOrgModel
    let agent: TeamPublishedAgent
    let project: URL
    let socket: ChatSocket
    let transport: Pop2UISocket
    private(set) var seededExecutorCommands: [ChatCommandRecord] = []
    let sourceID = UUID(), snapshotID = UUID(), publishDraftID = UUID()
    let sessionPublishDraftID = UUID(), publicationConversationID = UUID().uuidString.lowercased()

    init(root: URL) async throws {
        let server = try ChatServerAddress(parsing: "https://popup-ui.invalid")
        key = ChatOrgKey(server: server, accountId: Self.meID, orgId: "f5000000-0000-4000-8000-000000000005")
        service = ChatService(files: ChatFiles(directory: root.appendingPathComponent("chat")), tokens: UIProbeTokens())
        service.followsFeed = false
        service.closeRemoteSession = { _, _ in }
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [Pop2UIProtocol.self]) }
        service.isServerKnown = { _, _ in true }
        service.claudeProjectsRoot = root.appendingPathComponent("claude-projects")
        let session = "phase-two-ui-session", credential = UUID().uuidString
        try service.saveSignIn(.init(server: server, accountId: key.accountId, sessionId: session,
            deviceName: "MacBook Pro", orgId: key.orgId), token: credential)
        try await service.start(mode: .server)
        guard let madeCache = service.orgSessions[key]?.store, let madeJournal = service.journal else { throw NoModalsUIProbe.Failure.check("Offline fixture store unavailable") }
        cache = madeCache; journal = madeJournal
        try cache.finishGeneration("g1"); try journal.finish(key, "g1")
        project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var published = TeamPublishedAgent(name: "backend", description: "Review migrations and release changes.", folder: project.path)
        published.id = UUID(uuidString: Self.agentID)!
        published.access = .read
        agent = published
        let storage = TeamStorage(directory: root.appendingPathComponent("team"))
        try storage.save([published], to: storage.agentsURL)
        team = TeamService(storage: storage, offCalls: TeamOffCallStore())
        let conversationDirectory = service.claudeProjectsRoot.appendingPathComponent("-popup-fixture")
        try FileManager.default.createDirectory(at: conversationDirectory, withIntermediateDirectories: true)
        let conversation = try JSONSerialization.data(withJSONObject: [
            "type": "user", "cwd": project.path, "sessionId": publicationConversationID])
        try conversation.write(to: conversationDirectory.appendingPathComponent(publicationConversationID + ".jsonl"))
        team.calls.sessionFilesRoot = service.claudeProjectsRoot
        try team.calls.load()
        team.calls.serverMode = true; team.calls.useServer(cache.calls, key: key); team.calls.deliversAsks = true
        _ = ChatOwnerSide.install(service: service, calls: team.calls)
        service.localAgent = { id in id == published.id.uuidString.lowercased() ? published : nil }
        try journal.save(.init(server: server.description, accountId: key.accountId, orgId: key.orgId,
            agentId: Self.agentID, state: .active, name: published.name, description: published.description,
            access: published.access.rawValue, teamIds: "[\"\(Self.teamID)\"]", createdAt: Date(), publishedSession: session))
        try cache.apply(ChatSnapshot(cursors: [:], members: [
            .init(accountId: key.accountId, handle: "andrew", name: "Andrew", role: "owner"),
            .init(accountId: Self.peerID, handle: "sasha", name: "Sasha", role: "member"),
            .init(accountId: "4a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", handle: "marina", name: "Marina", role: "member")],
            teams: [.init(teamId: Self.teamID, name: "Engineering", mine: true)],
            teamMembers: [.init(teamId: Self.teamID, accountId: key.accountId), .init(teamId: Self.teamID, accountId: Self.peerID)],
            channels: [.init(channelId: Self.channelID, teamId: Self.teamID, name: "agentpad", archived: false, version: 1)],
            channelsComplete: true, agentChannels: []), confirmsRights: session)
        try cache.endChannelsRead(since: 0, seen: [Self.channelID])
        service.orgSessions[key]?.snapshotOwed = false
        let publishedDescription = published.description
        try await cache.queue.write { db in
            try db.execute(sql: "UPDATE meta SET org_name = 'AgentPad' WHERE id = 1")
            try ChatCallStore.replaceCatalog(db, [
                ChatAgentCard(agentId: Self.agentID, ownerAccountId: Self.meID, name: "backend", description: publishedDescription,
                    access: "read-git", enabled: true, executorSessionId: session, executorDeviceName: "MacBook Pro", available: true, teamIds: [Self.teamID]),
                ChatAgentCard(agentId: Self.askAgentID, ownerAccountId: Self.peerID, name: "alexander", description: "Review changes.",
                    access: "read-git", enabled: true, executorSessionId: "peer-session", executorDeviceName: "Sasha's Mac", available: true, teamIds: [Self.teamID])])
            for (id, name, owner) in [(Self.agentID, "backend", Self.meID), (Self.askAgentID, "alexander", Self.peerID)] {
                try db.execute(sql: "INSERT INTO agent_channels (channel_id, agent_id, name, owner_account_id, access, enabled, available, executor_session_id) VALUES (?, ?, ?, ?, 'read-git', 1, 1, ?)",
                    arguments: [Self.channelID, id, name, owner, id == Self.agentID ? session : "peer-session"])
            }
        }
        service.serverCapabilities[server] = ["chat.channel_ux1", "chat.session_tools", "chat.dm"]
        let fixtureTransport = Pop2UISocket()
        transport = fixtureTransport
        socket = ChatSocket(server: server, token: credential, makeTransport: { fixtureTransport })
        let sync = ChatSync(key: key, store: cache, api: service.makeAPI(server), socket: socket, outbox: nil, token: credential)
        service.orgSessions[key]?.sync = sync
        sync.dm.sessionId = session; sync.dm.configure(true)
        try await sync.dm.reloadCatalog(valid: { true })
        guard let org = ChatOrgModel.current(service) else { throw NoModalsUIProbe.Failure.check("Offline organization unavailable") }
        organization = org; organization.showsOffline = { false }
        try seedRequest(Self.approvalID, state: "awaiting_decision", run: nil, publication: nil)
        try await seedApproval(Self.folderID, result: nil)
        try await seedApproval(Self.publicationRequestID, result: Self.answer)
        seededExecutorCommands = try journal.commands(for: key)
        guard seededExecutorCommands.count == 2 else { throw NoModalsUIProbe.Failure.check("Fixture Allow did not queue exactly two decisions") }
        var approvedRequests = Set<String>()
        for command in seededExecutorCommands {
            let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: command.bodyBytes)
            guard let id = envelope.args["request_id"]?.string,
                  [Self.folderID, Self.publicationRequestID].contains(id), command.type == "request.decide",
                  envelope == ChatCommandEnvelope(commandId: command.commandId, org: key.orgId, type: "request.decide",
                      args: .object(["request_id": .string(id), "allow": .bool(true)])) else {
                throw NoModalsUIProbe.Failure.check("Fixture Allow queued an unexpected command")
            }
            approvedRequests.insert(id)
        }
        guard approvedRequests == Set([Self.folderID, Self.publicationRequestID]) else {
            throw NoModalsUIProbe.Failure.check("Fixture Allow did not approve both requests")
        }
        team.calls.reload()
        let requested = root.appendingPathComponent("requested-folder")
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        _ = try await team.calls.requestAccess(callId: Self.folderID, path: requested.path, reason: "Read the project files to review the migration.")
    }

    private func seedRequest(_ id: String, state: String, run: String?, publication: String?) throws {
        let at = ChatCallStore.timestamp(Date()), deadline = ChatCallStore.timestamp(Date().addingTimeInterval(3600))
        var body: [String: Any] = ["request_id": id, "kind": "channel", "agent_id": Self.agentID,
            "owner_account_id": Self.meID, "initiator_account_id": Self.peerID, "executor_device_name": "MacBook Pro",
            "text": Self.question, "channel_id": Self.channelID, "thread_root_id": Self.messageID,
            "conditions_version": 1, "deliver_by": deadline, "created_at": at, "updated_at": at,
            "version": 2, "state": state, "on_this_device": true, "run_id": run ?? NSNull(),
            "decline_reason": NSNull(), "failure_reason": NSNull()]
        if let publication { body["publication"] = publication }
        let wire = try JSONDecoder().decode(ChatRequestWire.self, from: JSONSerialization.data(withJSONObject: body))
        try cache.queue.write { try ChatCallStore.apply($0, wire, onThisDevice: true) }
    }

    private func seedApproval(_ id: String, result: String?) async throws {
        try seedRequest(id, state: "awaiting_decision", run: nil, publication: nil)
        guard let owner = service.owner else { throw NoModalsUIProbe.Failure.check("Fixture Allow is unavailable") }
        if let problem = await owner.decideChannel(key, requestId: id, allow: true, reason: nil) {
            throw NoModalsUIProbe.Failure.check("Fixture Allow failed: \(problem)")
        }
        guard let approval = try journal.approval(key, requestId: id) else { throw NoModalsUIProbe.Failure.check("Fixture Allow made no approval") }
        let params = try TeamLaunchParams.decode(approval.params), now = Date()
        var record = ChatRunRecord(runId: approval.runId, requestId: id, approvalId: approval.id, agentId: Self.agentID,
            conversationId: params.conversationId, startedAt: now)
        record.kind = "channel"; record.org = key.orgId; record.channelId = Self.channelID; record.threadRootId = Self.messageID
        if let result { record.endedAt = now; record.outcome = .finished; record.resultText = result; record.processesGoneAt = now }
        guard try journal.consume(approval, run: record, at: now) else { throw NoModalsUIProbe.Failure.check("Fixture approval could not be consumed") }
        let wire = ChatRequestWire(requestId: id, state: result == nil ? "running" : "finished", version: 3,
            runId: approval.runId, publication: result == nil ? nil : "awaiting_publish")
        try await cache.queue.write { try ChatCallStore.apply($0, wire, onThisDevice: true) }
    }
}

#endif
