#if DEBUG
import AppKit
import SwiftUI

/// Runs inside the standalone no-modals application's real AppKit event loop.
/// Only the terminal engine is substituted: the window, menu, search opener,
/// popup host, native editors and terminal Command-L composer are production UI.
@MainActor
enum AgentPadPopupFallbackSelfCheck {
    static var screenshotNames: Set<String> {
        Set(FallbackRow.allCases.flatMap { row in
            ["native-fallback-\(row.rawValue)-popup.png", "native-fallback-\(row.rawValue)-restored.png"]
        })
    }

    static func run() async throws -> Int {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/native-popup-fallback-\(UUID())")
        let shots = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENTPAD_POPUP_SHOTS"]
            ?? FileManager.default.currentDirectoryPath + "/.build/pop1-shots")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = SupportTabs.shared
        let previousTeam = TeamService.sharedForTesting
        TeamService.sharedForTesting = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("team")),
            offCalls: TeamOffCallStore())
        let previousPill = AgentPadSettingsModel.shared.showSearchPill
        AgentPadSettingsModel.shared.showSearchPill = false
        defer {
            TeamService.sharedForTesting = previousTeam
            AgentPadSettingsModel.shared.showSearchPill = previousPill
        }

        var checks = 0
        var evidence: [FallbackEvidence] = []
        func saveEvidence() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(evidence).write(to: shots.appendingPathComponent("native-fallback.json"), options: .atomic)
        }
        for row in FallbackRow.allCases {
            let host = try FallbackHost(root: root.appendingPathComponent(row.rawValue), shots: shots)
            do {
                let count = try await host.run(row)
                host.close()
                evidence.append(.init(row: row.rawValue, attempt: 1, result: "pass", checks: count, detail: "Quiet firstResponder model; Command-P opener unmounted by Command-comma; Escape restored primary input without a tab switch."))
                checks += count
                try saveEvidence()
                print("Native popup fallback: PASS \(row.rawValue) (\(count) checks, quiet)")
            } catch {
                try? host.capture("native-fallback-\(row.rawValue)-failure")
                host.close()
                evidence.append(.init(row: row.rawValue, attempt: 1, result: "fail", checks: host.checks, detail: String(describing: error)))
                try saveEvidence()
                throw error
            }
        }
        return checks
    }
}

private enum FallbackRow: String, CaseIterable {
    case terminalComposer = "terminal-composer"
    case terminalSurface = "terminal-surface"
    case allSessions = "all-sessions"
    case filesName = "files-name"
    case noInput = "no-input"
}

private enum FallbackFailure: Error {
    case check(String)
}

private struct FallbackEvidence: Encodable {
    let row: String
    let attempt: Int
    let result: String
    let checks: Int
    let detail: String
}

@MainActor
private final class FallbackHost {
    let root: URL
    let shots: URL
    let store: WorkspaceStore
    let controller: AgentPadWindowController
    let window: NSWindow
    let terminals: [FallbackTerminalEngine]
    let menuDelegate: AppDelegate
    private let previousContent: (TabState) -> AnyView
    private let previousStores: () -> [WorkspaceStore]
    private let previousAdmit: ((@escaping () -> Void) -> Bool)?
    private let previousEnsureHost: () -> WorkspaceStore?
    private let previousMenu: NSMenu?
    private let previousWindowsMenu: NSMenu?
    private let previousHelpMenu: NSMenu?
    private var closed = false
    private(set) var checks = 0

    init(root: URL, shots: URL) throws {
        self.root = root
        self.shots = shots
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let profiles = AgentProfileStore(fileURL: root.appendingPathComponent("profiles.json"),
            details: AgentProfileDetailsStore(fileURL: root.appendingPathComponent("profile-details.json")),
            accountTokens: FallbackTokens())
        let names = SessionNames(url: root.appendingPathComponent("names.sqlite"))
        let catalog = SessionCatalog(profiles: profiles) { _ in
            .init(records: [], scanned: 0, total: 0, skipped: 0)
        }
        let persistence = AppPersistence(fileURL: root.appendingPathComponent("windows.json"))
        let windowID = UUID()
        var engines: [FallbackTerminalEngine] = []
        let store = WorkspaceStore(persistence: WindowPersistence(windowId: windowID, app: persistence), initiallyEmpty: true,
            agentProfiles: profiles, sessionCatalog: catalog, sessionNames: names,
            engineFactory: { let engine = FallbackTerminalEngine(); engines.append(engine); return engine },
            optionsProvider: { _ in nil }, resumeProvider: { false },
            conversationVisibility: { .init(channelIds: []) },
            claudeProjectsRoot: root.appendingPathComponent("claude"), codexSessionsRoot: root.appendingPathComponent("codex"))
        self.store = store
        guard let workspace = store.active else { throw FallbackFailure.check("Fallback fixture has no workspace") }
        _ = store.addTab(in: workspace, template: .terminal, initialCwd: root)
        _ = store.addTab(in: workspace, template: .terminal, initialCwd: root)
        terminals = engines

        previousContent = NativeTabEngine.content
        previousStores = TabRouter.shared.stores
        previousAdmit = TabRouter.shared.admit
        previousEnsureHost = TabRouter.shared.ensureHost
        previousMenu = NSApp.mainMenu
        previousWindowsMenu = NSApp.windowsMenu
        previousHelpMenu = NSApp.helpMenu
        TabRouter.shared.admit = nil
        TabRouter.shared.stores = { [store] }
        TabRouter.shared.ensureHost = { store }
        NativeTabEngine.content = { state in
            if state.route == .allSessions {
                if state.allSessionsModel == nil {
                    state.allSessionsModel = AllSessionsModel(state: state, catalog: catalog, names: names, profiles: profiles)
                }
                return AnyView(AllSessionsTab(model: state.allSessionsModel!, autoload: false, liveSnapshot: { [] }, owner: { store }))
            }
            return SupportTabs.shared.content(state)
        }
        controller = AgentPadWindowController(windowId: windowID, store: store)
        guard let window = controller.window else { throw FallbackFailure.check("Fallback controller has no window") }
        self.window = window
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.title = "AgentPad · native popup fallback test"
        menuDelegate = AppDelegate(appPersistence: persistence, agentProfiles: profiles, windowControllers: [controller])
        menuDelegate.installMainMenu()
    }

    func close() {
        guard !closed else { return }
        closed = true
        store.terminate()
        controller.close()
        NativeTabEngine.content = previousContent
        TabRouter.shared.stores = previousStores
        TabRouter.shared.admit = previousAdmit
        TabRouter.shared.ensureHost = previousEnsureHost
        NSApp.mainMenu = previousMenu
        NSApp.windowsMenu = previousWindowsMenu
        NSApp.helpMenu = previousHelpMenu
    }

    private func quietOwnership() throws {
        try AgentPadQuietUI.assertQuiet()
        guard NSApp.keyWindow === window else {
            throw FallbackFailure.check("Quiet menu routing lost its selected window")
        }
    }

    private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        try quietOwnership()
        checks += 1
        if !value() { throw FallbackFailure.check(message) }
    }

    private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        try require(value != nil, message)
        guard let value else { throw FallbackFailure.check(message) }
        return value
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(180))
        try quietOwnership()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func key(_ character: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
        try quietOwnership()
        let event = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code), "Could not create native key event")
        AgentPadQuietUI.send(event, to: window)
        try quietOwnership()
    }

    private func shortcut(_ character: String, code: UInt16) throws {
        try quietOwnership()
        let event = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code), "Could not create native shortcut")
        try require(NSApp.mainMenu?.performKeyEquivalent(with: event) == true, "Installed Command-\(character) did not dispatch")
    }

    private func fieldEditorFocus(_ field: NSTextField) -> Bool {
        (window.firstResponder as? NSTextView)?.delegate === field
    }

    func capture(_ name: String) throws {
        guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw FallbackFailure.check("Could not capture \(name)")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw FallbackFailure.check("Could not encode \(name)") }
        try png.write(to: shots.appendingPathComponent(name + ".png"), options: .atomic)
    }

    func run(_ row: FallbackRow) async throws -> Int {
        AgentPadQuietUI.select(window)
        try quietOwnership()
        controller.paneHost.renderNow()
        try await settle()
        let session: Session
        var composer: ComposerNSTextView?
        var field: NSTextField?
        switch row {
        case .terminalComposer, .terminalSurface:
            session = try unwrap(store.active?.activeSession, "No active terminal")
            try require(session.hasProcess, "Terminal fixture is not a process tab")
            try shortcut("l", code: 37)
            try await settle()
            composer = try unwrap(descendants(try unwrap(window.contentView, "No content view")).compactMap { $0 as? ComposerNSTextView }.first,
                "Command-L did not mount the production composer")
            try require(session.composerActive && window.firstResponder === composer, "Command-L did not focus the production composer")
            if row == .terminalSurface {
                try key("\u{1b}", code: 53)
                try await settle()
                try require(!session.composerActive && composer?.window == nil, "Escape did not unmount the composer")
            }
        case .allSessions:
            session = store.openToolTab(.allSessions)
            try await settle()
            field = try unwrap(descendants(session.engine.view).compactMap { $0 as? NSTextField }.first {
                $0.placeholderString == "Search names, first prompts and folders"
            }, "All Sessions search is not mounted")
        case .filesName:
            let files = root.appendingPathComponent("files")
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            session = store.openToolTab(.files(canonicalPath: files.path))
            try await settle()
            let state = try unwrap(session.tabState, "Files tab has no state")
            LocalFormTabs.shared.filesModel(state).nameEdit.beginNew(in: files)
            try await settle()
            field = try unwrap(descendants(session.engine.view).compactMap { $0 as? NSTextField }.first {
                $0.placeholderString == "New file name"
            }, "Files name editor is not mounted")
        case .noInput:
            session = store.openToolTab(.unavailable(UUID()))
            try await settle()
        }

        try require((session.engine as? NativeTabEngine)?.rememberedFocus == nil, "Fixture injected or retained a remembered primary responder")
        try require(store.search.fieldFocus.field == nil, "The temporary search opener must start unmounted")
        let terminalInput = terminals.map { $0.surface.input }
        let composerDraft = session.composerDraft
        let fieldValue = field?.stringValue
        try shortcut("p", code: 35)
        try await settle()
        try require(store.search.fieldFocused && store.search.fieldFocus.field != nil, "Command-P did not focus the temporary search opener")
        try shortcut(",", code: 43)
        try await settle()
        try require(store.search.fieldFocus.field == nil, "Settings did not unmount its search opener")
        let dialog = try unwrap(descendants(try unwrap(window.contentView, "No window content")).first {
            $0.accessibilityIdentifier() == "popup-dialog"
        }, "Settings has no native popup boundary")
        let responder = window.firstResponder as? NSView
        let editorOwner = (responder as? NSTextView)?.delegate as? NSView
        try require(responder?.isDescendant(of: dialog) == true || editorOwner?.isDescendant(of: dialog) == true,
            "Settings did not contain native focus")
        try key("x", code: 7)
        try require(terminals.map { $0.surface.input } == terminalInput, "Popup typing leaked to a terminal")
        try require(session.composerDraft == composerDraft && field?.stringValue == fieldValue, "Popup typing leaked to the active primary input")
        try capture("native-fallback-\(row.rawValue)-popup")
        try key("\u{1b}", code: 53)
        try await settle()
        try require(!store.popups.isPresented, "Escape did not dismiss Settings")
        try require(store.active?.activeSession === session, "A tab switch repaired focus")
        try require(store.search.fieldFocus.field == nil, "Fallback remounted the vanished search opener")
        try require((session.engine as? NativeTabEngine)?.rememberedFocus == nil, "Fallback relied on a remembered responder")
        switch row {
        case .terminalComposer:
            let composer = try unwrap(composer, "Lost composer reference")
            try require(session.composerActive && composer.window === window && !composer.isHiddenOrHasHiddenAncestor,
                "Fallback lost the mounted terminal composer")
            try require(window.firstResponder === composer, "Fallback did not focus the production terminal composer")
            try key("z", code: 6)
            try require(composer.string == "z" && session.composerDraft == "z", "Native typing did not update the terminal composer draft")
            try require(terminals.map { $0.surface.input } == terminalInput, "Composer typing reached the terminal surface")
        case .terminalSurface:
            let engine = try unwrap(session.engine as? FallbackTerminalEngine, "Terminal lost its fixture engine")
            try require(window.firstResponder === engine.surface, "Closed-composer fallback did not focus the terminal surface")
            try key("z", code: 6)
            try require(engine.surface.input == "z", "Native typing did not reach the terminal surface")
        case .allSessions:
            let field = try unwrap(field, "Lost All Sessions field")
            try require(fieldEditorFocus(field), "Fallback did not focus All Sessions search")
            try key("z", code: 6)
            try require(session.tabState?.allSessionsModel?.query == "z", "Native typing did not update All Sessions search")
        case .filesName:
            let field = try unwrap(field, "Lost Files field")
            try require(fieldEditorFocus(field), "Fallback did not focus the Files name editor")
            try key("z", code: 6)
            let state = try unwrap(session.tabState, "Files lost its state")
            try require(LocalFormTabs.shared.filesModel(state).nameEdit.draft?.name.contains("z") == true,
                "Native typing did not update the Files name draft")
        case .noInput:
            try require(window.firstResponder === session.engine.view, "A tab without input did not retain hosting-view focus")
        }
        try await settle()
        try capture("native-fallback-\(row.rawValue)-restored")
        return checks
    }
}

private final class FallbackTokens: ChatTokenStore, @unchecked Sendable {
    func accounts() throws -> [String] { [] }
    func read(account: String) throws -> String? { nil }
    func write(_ token: String, account: String) throws {}
    func delete(account: String) throws {}
}

@MainActor
private final class FallbackTerminalEngine: TerminalEngine {
    final class Surface: NSView {
        var input = ""
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { input += event.characters ?? "" }
    }
    let surface = Surface()
    var view: NSView { surface }
    var backgroundColor: NSColor { .black }
    var onPwdChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCommandFinished: ((Int?, TimeInterval) -> Void)?
    var onUserInput: (() -> Void)?
    var onSearchStart: ((String) -> Void)?
    var onSearchEnd: (() -> Void)?
    var onSearchTotal: ((Int) -> Void)?
    var onSearchSelected: ((Int) -> Void)?
    var pasteUploadHostProvider: (() -> String?)?
    var isRemoteSessionProvider: (() -> Bool)?
    var foregroundPid: pid_t? { nil }
    var onProcessExitedCleanly: (() -> Void)?
    var onDesktopNotification: ((String, String) -> Void)?
    var needsConfirmQuit: Bool { false }
    var onLinkHover: ((String?) -> Void)?
    var suspendsSizePropagation: Bool { false }
    var grabsFocusOnMount = true
    var spawnsWhileHidden = false
    // Do not prepare, authorize or start any process: only the real UI mounts.
    func start(config: TerminalSessionConfig) {}
    func terminate() {}
    func renderNowIfNeeded() {}
    func beginSizePropagationSuspension() {}
    func endSizePropagationSuspension() {}
    func flushSize() {}
    func performAction(_ name: String) -> Bool { false }
    func sendInput(_ text: String) { surface.input += text }
    func paste(_ text: String) { surface.input += text }
    func pasteFromClipboardViaCore() -> Bool { false }
    func readSelection() -> String? { nil }
}
#endif
