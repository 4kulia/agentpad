#if DEBUG
import AppKit
import CoreGraphics
import SwiftUI

/// Standalone AppKit/AX run, outside XCTest's host. It starts no app services,
/// reads no saved workspaces and writes only its temporary test profile.
@MainActor
public enum AgentPadNoModalsSelfCheck {
    public static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        AgentPadFonts.registerOnce()
        app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                    with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        let probe = NoModalsUIProbe()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))
            fputs("No-modals UI/AX: FAIL: timed out\n", stderr); exit(1)
        }
        Task { @MainActor in
            do { try await probe.run(); print("No-modals UI/AX: PASS"); exit(0) }
            catch { fputs("No-modals UI/AX: FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
        exit(1)
    }
}

@MainActor
private final class NoModalsUIProbe: NSObject {
    enum Failure: Error { case check(String) }
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentpad-no-modals-ui-\(UUID())")
    private lazy var appPersistence = AppPersistence(fileURL: directory.appendingPathComponent("state-v2.json"))
    private var stores: [WorkspaceStore] = []
    private var windows: [NSWindow] = []
    private var current: WorkspaceStore?
    private var processRequests = 0
    private var modalWatch: Timer?
    private var unexpectedWindow = false
    private let support = SupportTabs.shared
    private var storedSettings: [String: Any] = [:]
    private lazy var model = AgentPadSettingsModel(read: { [weak self] in self?.storedSettings },
        write: { [weak self] in self?.storedSettings = $0 }, appliesRuntimeEffects: false)

    private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.check(message) }
    }
    private func settle() async { try? await Task.sleep(for: .milliseconds(180)) }
    private func host() -> WorkspaceStore {
        if let current { return current }
        return newWindow()
    }
    private func workspaceView(_ workspace: Workspace, store: WorkspaceStore) -> NSView {
        NSHostingView(rootView: UIProbeWorkspaceRoot(workspace: workspace, store: store))
    }
    @discardableResult private func newWindow() -> WorkspaceStore {
        let persistence = WindowPersistence(windowId: UUID(), app: appPersistence)
        let store = WorkspaceStore(persistence: persistence, initiallyEmpty: true, engineFactory: { [weak self] in
            self?.processRequests += 1
            return NativeTabEngine(state: TabState(route: .unavailable(UUID())), tabID: UUID())
        }, peerStores: { [weak self] in self?.stores ?? [] })
        let window = NSWindow(contentRect: NSRect(x: 80 + stores.count * 32, y: 80, width: 1060, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AgentPad · no-modals test profile"
        window.isReleasedWhenClosed = false
        window.contentView = workspaceView(store.active!, store: store)
        stores.append(store); windows.append(window); current = store
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return store
    }
    private func reveal(_ store: WorkspaceStore) {
        guard let index = stores.firstIndex(where: { $0 === store }) else { return }
        current = store; windows[index].makeKeyAndOrderFront(nil)
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
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let key = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier", "accessibilityLabel": "AXDescription"][name]
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
            try dump.write(to: directory.appendingPathComponent("accessibility.txt"), atomically: true, encoding: .utf8)
            print("UI profile and screenshots: \(directory.path)")
            throw Failure.check("AX missing: \(identifier)")
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        if object.responds(to: selector) {
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let function = unsafeBitCast(object.method(for: selector), to: Press.self)
            try require(function(object, selector), "AX press failed: \(identifier)")
        } else {
            let actions = object.perform(NSSelectorFromString("accessibilityActionNames"))?.takeUnretainedValue() as? [String] ?? []
            try require(actions.contains("AXPress"), "AX button has no press action: \(identifier)")
            object.perform(NSSelectorFromString("accessibilityPerformAction:"), with: "AXPress")
        }
    }
    private func screenshot(_ window: NSWindow, name: String) throws {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }
    private func scrollToEnd(_ tab: Session) throws {
        guard let probe = nodes(tab.engine.view).compactMap({ $0 as? TabScrollPosition.Probe }).first,
              let clip = probe.clip, let document = clip.documentView else { throw Failure.check("Settings scroll view is unavailable") }
        clip.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - clip.bounds.height)))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
    }
    func run() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { modalWatch?.invalidate(); stores.forEach { $0.terminate() }; windows.forEach { $0.orderOut(nil) } }
        AgentPadSettingsModel.testModel = model
        model.appearanceMode = .light
        model.activatePairedThemeSchemaAndSave()
        support.settingsModel = { [weak self] in self!.model }
        support.ledger = AttentionLedger()
        support.updates = UpdatesTabModel(packaged: { false }, attention: UpdateAttention(ledger: support.ledger),
                                         fetch: { _ in .upToDate(current: "1.1.8") })
        let router = support.navigation.router
        router.stores = { [weak self] in self?.stores ?? [] }
        router.ensureHost = { [weak self] in self?.host() }
        router.revealWindow = { [weak self] in self?.reveal($0) }
        support.install(); menu()
        try shortcut(",")
        try require(windows.isEmpty, "Settings created a window before startup completed")
        support.navigation.finishStartup()
        await settle()
        try require(windows.count == 1 && processRequests == 0, "no-window entry started a process or a second window")
        let first = stores[0], firstWindow = windows[0]
        let tab = first.allSessions[0], state = tab.tabState!
        guard let terminalHost = firstWindow.contentView.flatMap({ root in
            nodes(root).compactMap { $0 as? TerminalTabHostView }.first
        }) else { throw Failure.check("native tab host was not mounted") }
        let interceptors = nodes(firstWindow.contentView!).compactMap { $0 as? RightClickCatcher.SecondaryClickView }
        let contentFrame = terminalHost.convert(terminalHost.bounds, to: firstWindow.contentView)
        try require(!interceptors.contains { view in
            let frame = view.convert(view.bounds, to: firstWindow.contentView)
            return frame.intersection(contentFrame).height > 1
        }, "terminal right-click interceptor covers the native editor")
        modalWatch = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSApp.windows.contains(where: { $0.isVisible && !self.windows.contains($0) }) {
                    self.unexpectedWindow = true
                    fputs("Forbidden auxiliary window in no-modals UI test\n", stderr)
                    exit(1)
                }
            }
        }
        try press("settings-section-about", in: firstWindow)
        await settle()
        try require(state.navigation.settingsSection == .about, "About did not select its section")
        try shortcut(","); await settle()
        try require(first.allSessions.count == 1 && state.navigation.settingsSection == .about, "Cmd-, lost Settings identity/section")
        for section in SettingsTabSection.allCases {
            try press("settings-section-" + section.rawValue, in: firstWindow)
            await settle()
            try require(state.navigation.settingsSection == section, "section navigation failed")
        }
        try press("settings-check-updates", in: firstWindow); await settle()
        try require(!support.updates.checking, "fake update did not settle")
        try press("settings-section-agents", in: firstWindow); await settle()
        model.addCustomAgent(); state.settingsScreen.expandedAgentID = model.customAgents.last!.id
        let agentID = model.customAgents.last!.id
        SettingsIconImport.apply(URL(fileURLWithPath: "/tmp/damaged.png"), agentID: agentID,
            model: model, screen: state.settingsScreen, importIcon: { _, _ in throw CocoaError(.fileReadCorruptFile) })
        await settle(); try scrollToEnd(tab); await settle()
        let scrollOffset = state.navigation.settingsScrollOffsets?["agents"] ?? 0
        try require(scrollOffset > 0, "scroll position was not captured")
        state.select(.about); await settle(); state.select(.agents); await settle()
        try require(abs((state.navigation.settingsScrollOffsets?["agents"] ?? 0) - scrollOffset) < 2, "section switch lost scroll position")
        let workspace = first.active!, pane = workspace.activePane!
        let split = first.splitPane(pane, orientation: .horizontal, in: workspace)!
        try require(split.tabs.isEmpty && processRequests == 0, "split created a process")
        workspace.zoomedPaneId = split.id
        try shortcut(","); await settle()
        try require(workspace.zoomedPaneId == nil && workspace.activeSession === tab, "Settings was hidden behind zoom")
        let second = newWindow(), secondWindow = windows[1]
        try shortcut(","); await settle()
        let duplicate = second.allSessions[0]
        try require(!second.handleTabDrop(droppedId: tab.id, in: second.active!), "window singleton conflict merged edits")
        second.closeTab(duplicate, in: second.active!)
        let destination = second.active ?? second.addEmptyWorkspace()
        // The test root follows the new empty workspace after closing its last tab.
        secondWindow.contentView = workspaceView(destination, store: second)
        try require(second.handleTabDrop(droppedId: tab.id, in: destination), "transfer failed")
        await settle()
        try require(tab.tabState === state && (tab.engine as? NativeTabEngine)?.owner === second, "transfer remade the editor")
        secondWindow.selectNextKeyView(nil)
        let focusedBefore = secondWindow.firstResponder
        secondWindow.selectNextKeyView(nil)
        try require(secondWindow.firstResponder != nil, "Tab navigation lost keyboard focus")
        secondWindow.selectPreviousKeyView(nil)
        try require(secondWindow.firstResponder != nil && focusedBefore != nil, "Shift-Tab navigation lost keyboard focus")
        try press("settings-section-agents", in: secondWindow); await settle()
        try require(state.settingsScreen.expandedAgentID == agentID, "move lost the expanded editor")
        try scrollToEnd(tab); await settle()
        try require(element("agent-icon-error-" + agentID, in: secondWindow) != nil, "icon error is not accessible at its field")
        reveal(second); NSApp.activate(ignoringOtherApps: true); await settle()
        secondWindow.makeKey(); await settle()
        if secondWindow.isKeyWindow {
            var operations = 0
            state.confirmation.request(.init(tabID: tab.id, targetID: "ui-probe"), title: "Discard test change?",
                consequences: "Only this isolated profile is affected.", verb: "Discard", destructive: true, stillValid: { true }) { operations += 1 }
            await settle()
            try require(state.confirmation.isVisible, "inline decision did not become visible")
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: secondWindow.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)!
            secondWindow.sendEvent(escape); await settle()
            try require(state.confirmation.phase == .cancelled && operations == 0 && second.allSessions.contains(where: { $0 === tab }),
                        "Escape did not cancel only the inline decision")
        } else {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            try require(session?["CGSSessionScreenIsLocked"] as? Bool == true, "test window could not acquire focus")
            print("No-modals UI/AX: SKIP real key-window focus/Escape: macOS desktop is locked")
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            model.appearanceMode = appearance == .aqua ? .light : .dark
            NSApp.appearance = NSAppearance(named: appearance)
            await settle()
            try screenshot(secondWindow, name: appearance.rawValue)
        }
        secondWindow.setContentSize(NSSize(width: 360, height: 640)); await settle()
        try require(element("settings-section-picker", in: secondWindow) != nil, "narrow Settings lacks section navigation")
        try screenshot(secondWindow, name: "narrow")
        state.select(.general); await settle()
        try screenshot(secondWindow, name: "narrow-general")
        state.select(.agents); await settle()
        try require(second.flushPersistence(), "profile save failed")
        let saved = appPersistence.state(for: second.windowID)!
        try shortcut("w"); await settle()
        try require(!second.allSessions.contains { $0.id == tab.id }, "Cmd-W did not close active tool")
        let reopened = second.reopenLastClosedTab()
        try require(reopened?.tabState?.navigation.settingsSection == .agents, "reopen lost section")
        let restored = WorkspaceStore(persistence: UIProbePersistence(state: saved), initiallyEmpty: true,
            engineFactory: { fatalError("restore started a terminal") })
        defer { restored.terminate() }
        try require(restored.allSessions.first?.tabState?.navigation.settingsSection == .agents, "restore lost Settings section")
        try shortcut("i"); await settle()
        support.linkFailed("Invalid agentpad://resume?token=SECRET-UI-MARKER")
        support.linkFailed("Invalid agentpad://resume?token=SECRET-UI-MARKER")
        await settle()
        try require(second.allSessions.filter { $0.toolRoute == .linkFailure }.count == 1, "link failure duplicated tabs")
        try require(!unexpectedWindow && processRequests == 0, "forbidden surface/process")
        print("UI profile and screenshots: \(directory.path)")
    }
}

private struct UIProbeWorkspaceRoot: View {
    let workspace: Workspace
    let store: WorkspaceStore
    var body: some View {
        WorkspaceSplitRoot(workspace: workspace, store: store)
            .background(Theme.chromeBackground).foregroundStyle(Theme.chromeForeground)
            .preferredColorScheme(Theme.chromeColorScheme)
    }
}

@MainActor
private final class UIProbePersistence: Persistence {
    let state: PersistedState
    init(state: PersistedState) { self.state = state }
    func load() -> PersistedState? { state }
    func save(_ state: PersistedState) {}
}
#endif
