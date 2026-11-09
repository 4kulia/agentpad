import AppKit
import AgentPadQuietTestSupport
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class EmptyPaneCloseTests: XCTestCase {
    private var scope: TeamServiceTestScope!
    private var store: WorkspaceStore!
    private var persistence: InMemoryPersistence!
    private var controller: AgentPadWindowController!
    private var delegate: AppDelegate!
    private var originalMenus: (NSMenu?, NSMenu?, NSMenu?)!
    private var previousEnhancedUI: Any?
    private let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    override func setUp() async throws {
        _ = NSApplication.shared
        previousEnhancedUI = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        scope = TeamServiceTestScope()
        originalMenus = (NSApp.mainMenu, NSApp.windowsMenu, NSApp.helpMenu)
        persistence = InMemoryPersistence()
        // A split collapse remounts the surviving view. Exercise Ghostty's
        // real mount-time focus path; TestEngine never supplies pendingConfig,
        // so no terminal process or libghostty surface is started.
        store = WorkspaceStore(persistence: persistence, sessionNames: .testing,
            engineFactory: { TestEngine(view: GhosttySurfaceView(frame: .zero)) },
            optionsProvider: { _ in nil }, resumeProvider: { true },
            claudeProjectsRoot: FileManager.default.temporaryDirectory.appendingPathComponent("agentpad-no-claude-sessions"))
        controller = AgentPadWindowController(windowId: UUID(), store: store)
        delegate = AppDelegate(appPersistence: AppPersistence(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-pane-windows-\(UUID()).json")), agentProfiles: store.agentProfiles,
            windowControllers: [controller])
        delegate.installMainMenu()
        APQuietSelectWindow(try XCTUnwrap(controller.window))
        try await settle()
        let surfaceView = try XCTUnwrap(store.active?.activeSession?.engine.view as? GhosttySurfaceView)
        XCTAssertNil(surfaceView.pendingConfig)
        XCTAssertNil(surfaceView.surface)
    }

    override func tearDown() async throws {
        NSApp.accessibilitySetValue(previousEnhancedUI, forAttribute: enhancedUI)
        NSApp.mainMenu = originalMenus.0
        NSApp.windowsMenu = originalMenus.1
        NSApp.helpMenu = originalMenus.2
        controller.close()
        store.terminate()
        delegate = nil
        controller = nil
        store = nil
        persistence = nil
        scope.close()
        scope = nil
    }

    private func settle() async throws {
        // Invisible windows need explicit layout after SwiftUI applies a
        // structural split change, followed by the surface's deferred focus.
        for _ in 0..<3 {
            controller.paneHost.renderNow()
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(35))
        }
    }

    private func focusDetails(_ session: Session) -> String {
        let view = session.engine.view
        let window = controller.window
        return "responder=\(String(describing: window?.firstResponder)); target=\(view); mounted=\(view.window === window); hidden=\(view.isHiddenOrHasHiddenAncestor); mountFocus=\(session.engine.grabsFocusOnMount); surfaceMountFocus=\((view as? GhosttySurfaceView)?.grabsFocusOnMount == true); parent=\(String(describing: view.superview))"
    }

    private func closeItem() throws -> NSMenuItem {
        func flatten(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(flatten) ?? []) }
        }
        return try XCTUnwrap(flatten(try XCTUnwrap(NSApp.mainMenu)).first {
            $0.action.map(NSStringFromSelector) == "handleCloseTab"
        })
    }

    private func performKeyEquivalent(_ characters: String, keyCode: UInt16,
                                      modifiers: NSEvent.ModifierFlags = .command) throws -> Bool {
        let window = try XCTUnwrap(controller.window)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        return try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: event)
    }

    private func commandW() throws {
        XCTAssertTrue(try performKeyEquivalent("w", keyCode: 13))
    }

    private func clickEmptyPane(in workspace: Workspace) async throws {
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(controller.paneHost.workspaceRootView(for: workspace.id))
        // Blank lower-right content, away from the add button and header controls.
        let point = root.convert(NSPoint(x: root.bounds.width * 0.85, y: root.bounds.height * 0.75), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            APQuietSendEvent(event, window)
        }
        try await settle()
    }

    private func buttons(_ label: String, in root: NSView) -> [FoldersAXNode] {
        func walk(_ object: NSObject) -> [FoldersAXNode] {
            let node = FoldersAXNode(object: object)
            return [node] + node.children.flatMap(walk)
        }
        return walk(root).filter {
            $0.attribute("accessibilityRole") as? String == NSAccessibility.Role.button.rawValue
                && $0.accessibilityLabel() == label
        }
    }

    private func closeButtons(in workspace: Workspace) throws -> [FoldersAXNode] {
        buttons("Close pane", in: try XCTUnwrap(controller.paneHost.workspaceRootView(for: workspace.id)))
    }

    private func click(_ button: FoldersAXNode) async throws {
        let window = try XCTUnwrap(controller.window)
        let frame = window.convertFromScreen(button.accessibilityFrame())
        XCTAssertFalse(frame.isEmpty)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            APQuietSendEvent(event, window)
        }
        try await settle()
    }

    func testCloseButtonAppearsOnlyOnEmptySplitPanes() async throws {
        let workspace = try XCTUnwrap(store.active)
        let original = try XCTUnwrap(workspace.activePane)
        XCTAssertTrue(try closeButtons(in: workspace).isEmpty)
        let empty = try XCTUnwrap(store.splitPane(original, orientation: .horizontal, in: workspace))
        try await settle()
        XCTAssertEqual(try closeButtons(in: workspace).count, 1)
        let button = try XCTUnwrap(try closeButtons(in: workspace).first)
        XCTAssertEqual(button.attribute("accessibilityHelp") as? String, "Close pane")
        _ = store.addTab(in: workspace, pane: empty)
        try await settle()
        XCTAssertTrue(try closeButtons(in: workspace).isEmpty)
    }

    private func assertCloseButtonRestoresTerminalFocus(fromSidebar: Bool) async throws {
        let workspace = try XCTUnwrap(store.active)
        let original = try XCTUnwrap(workspace.activePane)
        let session = try XCTUnwrap(original.activeTab)
        let empty = try XCTUnwrap(store.splitPane(original, orientation: .horizontal, in: workspace))
        if fromSidebar { store.focusPane(original, in: workspace) }
        try await settle()
        if fromSidebar {
            XCTAssertTrue(try performKeyEquivalent("0", keyCode: 29, modifiers: [.option, .command]))
            try await settle()
            XCTAssertTrue(controller.window?.firstResponder is NSTextView)
            XCTAssertEqual(workspace.activePaneId, original.id)
        } else {
            XCTAssertEqual(workspace.activePaneId, empty.id)
        }
        try await click(XCTUnwrap(try closeButtons(in: workspace).first))
        XCTAssertEqual(workspace.root.allPanes.map(\.id), [original.id])
        XCTAssertEqual(workspace.activePaneId, original.id)
        XCTAssertTrue(workspace.activeSession === session)
        XCTAssertTrue(controller.window?.firstResponder === session.engine.view, focusDetails(session))
        XCTAssertEqual((session.engine as? TestEngine)?.terminateCount, 0)
        XCTAssertTrue(try closeButtons(in: workspace).isEmpty)
    }

    func testCloseButtonClickClosesFocusedEmptyPaneAndRestoresTerminalFocus() async throws {
        try await assertCloseButtonRestoresTerminalFocus(fromSidebar: false)
    }

    func testCloseButtonClickClosesInactiveEmptyPaneAndReclaimsSidebarFocus() async throws {
        try await assertCloseButtonRestoresTerminalFocus(fromSidebar: true)
    }

    func testCloseButtonLeavesFinalEmptyPaneWithoutButton() async throws {
        let workspace = try XCTUnwrap(store.addEmptyWorkspace())
        let first = try XCTUnwrap(workspace.activePane)
        try await settle()
        XCTAssertTrue(try closeButtons(in: workspace).isEmpty)
        _ = try XCTUnwrap(store.splitPane(first, orientation: .horizontal, in: workspace))
        try await settle()
        let buttons = try closeButtons(in: workspace).sorted { $0.accessibilityFrame().minX < $1.accessibilityFrame().minX }
        XCTAssertEqual(buttons.count, 2)
        try await click(XCTUnwrap(buttons.last))
        XCTAssertEqual(workspace.root.allPanes.map(\.id), [first.id])
        XCTAssertEqual(workspace.activePaneId, first.id)
        XCTAssertTrue(first.tabs.isEmpty)
        XCTAssertTrue(try closeButtons(in: workspace).isEmpty)
        XCTAssertTrue(controller.paneHost.hasKeyboardFocus)
    }

    func testCloseButtonMatchesSplitControlsInDarkAndLight() async throws {
        XCTAssertTrue(APQuietIsEnabled())
        let workspace = try XCTUnwrap(store.active)
        let original = try XCTUnwrap(workspace.activePane)
        let empty = try XCTUnwrap(store.splitPane(original, orientation: .horizontal, in: workspace))
        AgentPadFonts.registerOnce()
        let previousSettings = AgentPadSettingsModel.testModel
        defer { AgentPadSettingsModel.testModel = previousSettings }
        for dark in [true, false] {
            controller.close()
            AgentPadSettingsModel.testModel = AgentPadSettingsModel(
                read: { ["appearance": ["mode": dark ? "dark" : "light"],
                         "terminal": ["background-blur": false]] },
                write: { _ in }, appliesRuntimeEffects: false)
            XCTAssertEqual(Theme.resolved.isLight, !dark)
            XCTAssertFalse(Theme.glassEnabled)
            controller = AgentPadWindowController(windowId: UUID(), store: store)
            let window = try XCTUnwrap(controller.window)
            let content = try XCTUnwrap(window.contentView as? NSHostingView<ContentView>)
            APQuietSelectWindow(window)
            try await settle()
            // Match the mockup's pane size by resizing the real window, keeping
            // ContentView's background, chrome and mounted split tree intact.
            var frame = window.frame
            frame.size.width += 1281 - controller.paneHost.bounds.width
            frame.size.height += 320 - controller.paneHost.bounds.height
            window.setFrame(frame, display: false)
            try await settle()
            XCTAssertEqual(controller.paneHost.bounds.width, 1281, accuracy: 0.5)
            XCTAssertEqual(controller.paneHost.bounds.height, 320, accuracy: 0.5)
            XCTAssertEqual(workspace.activePaneId, empty.id)
            let paneRect = controller.paneHost.convert(NSRect(x: 641, y: 0, width: 640, height: 320), to: content)
            let root = try XCTUnwrap(controller.paneHost.workspaceRootView(for: workspace.id))
            XCTAssertTrue(root.window === window)
            let controls = try ["Split Right (⌘D)", "Split Down (⌘⇧D)", "Close pane"].map {
                let button = try XCTUnwrap(buttons($0, in: root).max {
                    $0.accessibilityFrame().minX < $1.accessibilityFrame().minX
                })
                return content.convert(window.convertFromScreen(button.accessibilityFrame()), from: nil)
            }
            for frame in controls {
                XCTAssertEqual(frame.width, 28, accuracy: 0.5)
                XCTAssertEqual(frame.height, 28, accuracy: 0.5)
                XCTAssertEqual(frame.midY, controls[0].midY, accuracy: 0.5)
                XCTAssertTrue(paneRect.contains(frame))
            }
            XCTAssertEqual(controls[1].minX - controls[0].maxX, 2, accuracy: 0.5)
            XCTAssertEqual(controls[2].minX - controls[1].maxX, 8, accuracy: 0.5)
            XCTAssertEqual(paneRect.maxX - controls[2].maxX, 8, accuracy: 0.5)
            XCTAssertEqual(abs(controls[0].midY - paneRect.minY), 21, accuracy: 0.5)
            // Render the complete production composition before cropping. A
            // leaf-only cache omits the background inherited from ContentView.
            let windowBitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: windowBitmap)
            let scaleX = CGFloat(windowBitmap.pixelsWide) / content.bounds.width
            let scaleY = CGFloat(windowBitmap.pixelsHigh) / content.bounds.height
            let pixelRect = NSRect(x: paneRect.minX * scaleX,
                y: (content.isFlipped ? paneRect.minY : content.bounds.maxY - paneRect.maxY) * scaleY,
                width: paneRect.width * scaleX, height: paneRect.height * scaleY)
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(windowBitmap.cgImage?.cropping(to: pixelRect)))
            // Compare raw samples after converting the reference into the capture's colour profile.
            let expectedSurface = try XCTUnwrap(NSColor(hex: dark ? "#282C34" : "#FAFAFA")?
                .usingColorSpace(bitmap.colorSpace))
            var background = [Int](repeating: 0, count: bitmap.samplesPerPixel)
            bitmap.getPixel(&background, atX: 32, y: bitmap.pixelsHigh - 32)
            XCTAssertEqual(background, [expectedSurface.redComponent, expectedSurface.greenComponent,
                                        expectedSurface.blueComponent, expectedSurface.alphaComponent]
                .map { Int(($0 * 255).rounded()) })
            XCTAssertEqual(window.alphaValue, 0)
            XCTAssertFalse(APQuietWindowHasOSFocus(window))
            XCTAssertNil(APQuietFailure())
            let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(bytes.count, 500)
            if let output = ProcessInfo.processInfo.environment["AGENTPAD_PANE_CLOSE_CAPTURE"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let mode = dark ? "dark" : "light"
                try bytes.write(to: directory.appendingPathComponent("empty-pane-close-\(mode).png"))
                try XCTUnwrap(windowBitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("window-content-\(mode).png"))
                let geometry: [String: Any] = [
                    "cropPixels": [pixelRect.minX, pixelRect.minY, pixelRect.width, pixelRect.height],
                    "panePoints": [paneRect.width, paneRect.height],
                    "controlsInPanePoints": controls.map {
                        [$0.minX - paneRect.minX, $0.minY - paneRect.minY, $0.width, $0.height]
                    },
                    "themeID": Theme.resolved.cacheKey.themeId ?? "default",
                    "glassEnabled": Theme.glassEnabled
                ]
                try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("capture-\(mode).json"))
            }
        }
    }

    private func assertCloseIgnored(in workspace: Workspace, file: StaticString = #filePath, line: UInt = #line) throws {
        let panes = workspace.root.allPanes.map(\.id)
        let active = workspace.activePaneId
        let responder = controller.window?.firstResponder
        let item = try closeItem()
        XCTAssertFalse(delegate.validateMenuItem(item), file: file, line: line)
        XCTAssertFalse(try performKeyEquivalent("w", keyCode: 13), file: file, line: line)
        XCTAssertEqual(workspace.root.allPanes.map(\.id), panes, file: file, line: line)
        // Also dispatch directly: validation may have happened before focus moved.
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item), file: file, line: line)
        XCTAssertEqual(workspace.root.allPanes.map(\.id), panes, file: file, line: line)
        XCTAssertEqual(workspace.activePaneId, active, file: file, line: line)
        XCTAssertTrue(controller.window?.firstResponder === responder, file: file, line: line)
    }

    func testCommandWDoesNotCloseEmptyPaneWhileSidebarSearchHasFocus() async throws {
        let workspace = try XCTUnwrap(store.active)
        let original = try XCTUnwrap(workspace.activePane)
        let empty = try XCTUnwrap(store.splitPane(original, orientation: .horizontal, in: workspace))
        try await settle()
        XCTAssertTrue(try performKeyEquivalent("0", keyCode: 29, modifiers: [.option, .command]))
        try await settle()
        let editor = try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertFalse(editor.isDescendant(of: controller.paneHost))
        XCTAssertEqual(workspace.activePaneId, empty.id)
        try assertCloseIgnored(in: workspace)
    }

    func testCommandWDoesNotCloseEmptyPaneWhileChatComposerHasFocus() async throws {
        let workspace = try XCTUnwrap(store.active)
        let original = try XCTUnwrap(workspace.activePane)
        let empty = try XCTUnwrap(store.splitPane(original, orientation: .horizontal, in: workspace))
        try await settle()
        let window = try XCTUnwrap(controller.window)
        // Mount the real chat editor outside the pane area, as in the sidebar,
        // without creating a network connection or signing into a chat service.
        let composer = ChatMentionEditor.Editor(frame: NSRect(x: 64, y: 64, width: 220, height: 80))
        composer.string = "Unsent message"
        try XCTUnwrap(window.contentView).addSubview(composer)
        defer { composer.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(composer))
        XCTAssertTrue(window.firstResponder === composer)
        XCTAssertFalse(composer.isDescendant(of: controller.paneHost))
        XCTAssertEqual(workspace.activePaneId, empty.id)
        try assertCloseIgnored(in: workspace)
        XCTAssertEqual(composer.string, "Unsent message")
    }

    func testClickingSelectedEmptyPaneReclaimsFocusFromSidebarSearch() async throws {
        let workspace = try XCTUnwrap(store.active)
        let original = try XCTUnwrap(workspace.activePane)
        let empty = try XCTUnwrap(store.splitPane(original, orientation: .horizontal, in: workspace))
        try await settle()
        XCTAssertTrue(try performKeyEquivalent("0", keyCode: 29, modifiers: [.option, .command]))
        try await settle()
        XCTAssertTrue(controller.window?.firstResponder is NSTextView)
        XCTAssertEqual(workspace.activePaneId, empty.id)
        try await clickEmptyPane(in: workspace)
        let responder = try XCTUnwrap(controller.window?.firstResponder as? NSView)
        XCTAssertTrue(responder.isDescendant(of: controller.paneHost), "A click must return keyboard focus to the pane area")
        XCTAssertEqual(workspace.activePaneId, empty.id)
        XCTAssertTrue(delegate.validateMenuItem(try closeItem()))
        try commandW()
        try await settle()
        XCTAssertEqual(workspace.root.allPanes.map(\.id), [original.id])
        XCTAssertTrue(controller.window?.firstResponder === original.activeTab?.engine.view)
    }

    func testGlobalSearchKeepsEmptyPaneUntilCloseCommandIsChosen() async throws {
        let workspace = try XCTUnwrap(store.active)
        let original = try XCTUnwrap(workspace.activePane)
        _ = try XCTUnwrap(store.splitPane(original, orientation: .horizontal, in: workspace))
        try await settle()
        delegate.handleQuickOpen()
        store.search.query = "Close Tab"
        try await settle()
        XCTAssertTrue(store.search.fieldFocused)
        XCTAssertTrue(controller.window?.firstResponder === store.search.fieldFocus.field?.currentEditor())
        let close = try XCTUnwrap(store.search.quick.first { $0.title == "Close Tab" })
        try assertCloseIgnored(in: workspace)
        store.search.activate("q:" + close.id)
        try await settle()
        XCTAssertFalse(store.search.suggestions)
        XCTAssertEqual(workspace.root.allPanes.map(\.id), [original.id])
        XCTAssertTrue(controller.window?.firstResponder === original.activeTab?.engine.view)
    }

    func testCommandWClosesThreeEmptyPanesAndFocusesSurvivingTab() async throws {
        let workspace = try XCTUnwrap(store.active)
        let original = try XCTUnwrap(workspace.activePane)
        let session = try XCTUnwrap(original.activeTab)
        let second = try XCTUnwrap(store.splitPane(original, orientation: .horizontal, in: workspace))
        let third = try XCTUnwrap(store.splitPane(second, orientation: .vertical, in: workspace))
        let fourth = try XCTUnwrap(store.splitPane(third, orientation: .horizontal, in: workspace))
        try await settle()
        for expected in [[original.id, second.id, third.id], [original.id, second.id], [original.id]] {
            XCTAssertTrue(delegate.validateMenuItem(try closeItem()))
            try commandW()
            try await settle()
            XCTAssertEqual(workspace.root.allPanes.map(\.id), expected)
            XCTAssertEqual(workspace.activePaneId, expected.last)
        }
        XCTAssertNil(workspace.root.pane(id: fourth.id))
        XCTAssertTrue(workspace.activeSession === session)
        XCTAssertTrue(controller.window?.firstResponder === session.engine.view, focusDetails(session))
        XCTAssertEqual((session.engine as? TestEngine)?.terminateCount, 0)
        XCTAssertEqual(store.workspaces.map(\.id), [workspace.id])
    }

    func testFileCloseTabKeepsLastEmptyPaneAndSavedLayoutRestoresCollapsedTree() async throws {
        let workspace = try XCTUnwrap(store.addEmptyWorkspace())
        let first = try XCTUnwrap(workspace.activePane)
        let second = try XCTUnwrap(store.splitPane(first, orientation: .horizontal, in: workspace))
        _ = store.splitPane(second, orientation: .vertical, in: workspace)
        try await settle()
        let item = try closeItem()
        for count in [2, 1] {
            XCTAssertTrue(delegate.validateMenuItem(item))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(workspace.root.allPanes.count, count)
        }
        XCTAssertFalse(delegate.validateMenuItem(item))
        // Direct dispatch must be safe even if a menu's validation was stale.
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertTrue(store.workspaces.contains { $0 === workspace })
        XCTAssertEqual(workspace.root.allPanes.map(\.id), [first.id])
        XCTAssertTrue(first.tabs.isEmpty)
        XCTAssertTrue(store.flushPersistence())
        let saved = try XCTUnwrap(persistence.saved)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(saved))
        let restored = makeTestStore(persistence: InMemoryPersistence(initial: decoded))
        defer { restored.terminate() }
        let restoredWorkspace = try XCTUnwrap(restored.workspaces.first { $0.id == workspace.id })
        XCTAssertEqual(restoredWorkspace.root.allPanes.map(\.id), [first.id])
        XCTAssertEqual(restoredWorkspace.activePaneId, first.id)
        XCTAssertTrue(restoredWorkspace.root.allPanes.flatMap(\.tabs).isEmpty)
    }

    func testClickingEmptyPaneBackgroundMakesCommandWTargetIt() async throws {
        let workspace = try XCTUnwrap(store.active)
        let original = try XCTUnwrap(workspace.activePane)
        let session = try XCTUnwrap(original.activeTab)
        let empty = try XCTUnwrap(store.splitPane(original, orientation: .horizontal, in: workspace))
        store.focusPane(original, in: workspace)
        try await settle()
        let window = try XCTUnwrap(controller.window)
        try await clickEmptyPane(in: workspace)
        XCTAssertEqual(workspace.activePaneId, empty.id)
        XCTAssertFalse(window.firstResponder === session.engine.view)
        try commandW()
        try await settle()
        XCTAssertEqual(workspace.root.allPanes.map(\.id), [original.id])
        XCTAssertTrue(workspace.activeSession === session)
        XCTAssertTrue(window.firstResponder === session.engine.view, focusDetails(session))
    }

    func testNonemptyPaneCommandWKeepsConfirmationAndClosesOnlyItsTab() async throws {
        let workspace = try XCTUnwrap(store.active)
        let pane = try XCTUnwrap(workspace.activePane)
        let original = try XCTUnwrap(pane.activeTab)
        let empty = try XCTUnwrap(store.splitPane(pane, orientation: .horizontal, in: workspace))
        let session = store.addTab(in: workspace, pane: pane)
        let engine = try XCTUnwrap(session.engine as? TestEngine)
        engine.needsConfirmQuit = true
        try await settle()
        try commandW()
        try await settle()
        XCTAssertEqual(pane.tabs.map(\.id), [original.id, session.id])
        XCTAssertTrue(session.terminalConfirmation.isVisible)
        XCTAssertEqual(session.terminalConfirmation.context?.targetID, "close")
        XCTAssertEqual(engine.terminateCount, 0)
        session.terminalConfirmation.cancel()
        XCTAssertEqual(pane.tabs.map(\.id), [original.id, session.id])
        try commandW()
        try await settle()
        session.terminalConfirmation.confirm()
        try await settle()
        XCTAssertEqual(pane.tabs.map(\.id), [original.id])
        XCTAssertEqual(workspace.root.allPanes.map(\.id), [pane.id, empty.id])
        XCTAssertEqual(engine.terminateCount, 1)
    }

    func testDropIntoEmptyPanePreservesLiveTabAndEmptySource() throws {
        let workspace = try XCTUnwrap(store.active)
        let source = try XCTUnwrap(workspace.activePane)
        let session = try XCTUnwrap(source.activeTab)
        let destination = try XCTUnwrap(store.splitPane(source, orientation: .horizontal, in: workspace))
        XCTAssertTrue(store.handleTabDrop(droppedId: session.id, to: destination, at: 0, in: workspace))
        XCTAssertEqual(workspace.root.allPanes.map(\.id), [source.id, destination.id])
        XCTAssertTrue(source.tabs.isEmpty)
        XCTAssertEqual(destination.tabs.map(\.id), [session.id])
        XCTAssertTrue(workspace.activeSession === session)
        XCTAssertEqual((session.engine as? TestEngine)?.terminateCount, 0)
    }

    func testClosingEmptyPaneBesidePopulatedSplitFocusesNearestActiveTab() async throws {
        let workspace = try XCTUnwrap(store.active)
        let empty = try XCTUnwrap(workspace.activePane)
        let moved = try XCTUnwrap(empty.activeTab)
        let neighbour = try XCTUnwrap(store.splitPane(empty, orientation: .horizontal, in: workspace))
        let target = store.addTab(in: workspace, pane: neighbour)
        let far = try XCTUnwrap(store.splitPane(neighbour, orientation: .vertical, in: workspace))
        let farTab = store.addTab(in: workspace, pane: far)
        XCTAssertTrue(store.handleTabDrop(droppedId: moved.id, to: far, at: 1, in: workspace))
        store.focusPane(empty, in: workspace)
        try await settle()
        try commandW()
        try await settle()
        XCTAssertEqual(workspace.root.allPanes.map(\.id), [neighbour.id, far.id])
        XCTAssertEqual(neighbour.tabs.map(\.id), [target.id])
        XCTAssertEqual(far.tabs.map(\.id), [farTab.id, moved.id])
        XCTAssertTrue(workspace.activeSession === target)
        XCTAssertTrue(controller.window?.firstResponder === target.engine.view, focusDetails(target))
        XCTAssertTrue([target, farTab, moved].allSatisfy { ($0.engine as? TestEngine)?.terminateCount == 0 })
    }

    func testPaletteCloseTabUsesSameEmptyPaneActionAndAvailability() async throws {
        let workspace = try XCTUnwrap(store.addEmptyWorkspace())
        let pane = try XCTUnwrap(workspace.activePane)
        _ = store.splitPane(pane, orientation: .horizontal, in: workspace)
        try await settle()
        delegate.prepareSearch(in: store)
        let items = store.search.quickItems()
        let close = try XCTUnwrap(items.first { $0.title == "Close Tab" })
        XCTAssertTrue(store.search.quickAllowedIDs(items).contains(close.id))
        store.search.activateQuick(close)
        XCTAssertEqual(workspace.root.allPanes.map(\.id), [pane.id])
        XCTAssertFalse(store.search.quickAllowedIDs(items).contains(close.id))
        store.search.activateQuick(close)
        XCTAssertTrue(store.workspaces.contains { $0 === workspace })
        XCTAssertEqual(workspace.root.allPanes.map(\.id), [pane.id])
    }
}
