import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class SearchSuggestionsFocusTests: XCTestCase {
    private var root: URL!
    private var store: WorkspaceStore!
    private var model: EverywhereSearchModel!
    private var window: SearchTestWindow!
    private var host: NSHostingView<SearchEverywhereField>!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("search-focus-\(UUID())")
        store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            agentProfiles: AgentProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            drafts: DraftRepository(fileURL: root.appendingPathComponent("drafts.json")), engineFactory: { TestEngine(view: InputSink()) })
        store.addWorkspace()
        model = EverywhereSearchModel(messages: .init(context: { nil }, availability: { .noTeam }, fetch: { _, _ in
            XCTFail("Focus tests must not use the network"); return .init(hits: [], next: nil)
        }), indexing: .init(index: ConversationIndex(directory: root.appendingPathComponent("index"), roots: [:])),
            catalog: .init(scan: { _ in .init(records: [], scanned: 0, total: 0, skipped: 0) }),
            names: SessionNames(url: root.appendingPathComponent("names.sqlite")))
        store.searchModel = model
        host = NSHostingView(rootView: SearchEverywhereField(store: store, model: model))
        host.frame = NSRect(x: 0, y: 250, width: 600, height: 40)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        content.addSubview(host)
        let terminal = try XCTUnwrap(store.active?.activeSession?.engine.view)
        terminal.frame = NSRect(x: 180, y: 0, width: 420, height: 240)
        content.addSubview(terminal)
        window = SearchTestWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content; window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
    }

    override func tearDown() async throws {
        window.close(); store.terminate()
        host = nil; window = nil; model = nil; store = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Search focus did not settle: key=\(window.isKeyWindow), requested=\(model.focusRequest), focused=\(model.fieldFocused), field=\(String(describing: model.fieldFocus.field)), responder=\(String(describing: window.firstResponder))")
    }

    private func open() async throws -> NSTextView {
        model.begin()
        try await settle { self.window.firstResponder is NSTextView }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("release", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle { self.model.suggestions }
        return editor
    }

    private func key(_ code: UInt16, _ text: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }

    private func endMenuTracking(_ menu: NSMenu = NSMenu(), action: () -> Void = {}) async {
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        action()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func click(_ view: NSView, type: NSEvent.EventType = .leftMouseDown) throws {
        let targetWindow = try XCTUnwrap(view.window)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: targetWindow.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        if type == .leftMouseDown, view is SearchTextField {
            // NSTextView tracks text selection until the corresponding mouse-up.
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: event.timestamp, windowNumber: targetWindow.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 0))
            NSApp.postEvent(up, atStart: true)
        }
        NSApp.sendEvent(event)
    }

    private func click(at localPoint: NSPoint, in panel: NSView, beforeMouseUp: () -> Void = {}) throws {
        let point = panel.convert(localPoint, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: down.timestamp, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        beforeMouseUp()
        // Native controls may consume mouse-up in their tracking loop; SwiftUI
        // buttons can leave it queued for the normal application event loop.
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
    }

    func testAutomaticKeyViewSelectionAndUnrequestedFocusSkipSearch() async throws {
        try await settle { self.model.fieldFocus.field != nil }
        let field = try XCTUnwrap(model.fieldFocus.field)
        let terminal = try XCTUnwrap(store.active?.activeSession?.engine.view)
        window.autorecalculatesKeyViewLoop = false
        terminal.nextKeyView = field; field.nextKeyView = terminal
        XCTAssertFalse(field.canBecomeKeyView)
        window.selectNextKeyView(terminal)
        XCTAssertFalse(model.fieldFocused); XCTAssertFalse(model.suggestions)
        window.makeFirstResponder(field) // AppKit may return true after falling back to the window.
        XCTAssertFalse(window.firstResponder === field)
        XCTAssertNil(field.currentEditor(), "Only a click or a search command may request search focus")
        XCTAssertFalse(model.fieldFocused); XCTAssertFalse(model.suggestions)
    }

    func testNativeTabActivationCannotFallThroughToSearch() async throws {
        let previousContent = NativeTabEngine.content
        // Exercise the shared fallback when native content has no key view yet.
        NativeTabEngine.content = { AnyView(Text($0.route.title)) }
        defer { NativeTabEngine.content = previousContent }
        try await settle { self.model.fieldFocus.field != nil }
        let field = try XCTUnwrap(model.fieldFocus.field)
        store.active?.activeSession?.engine.view.isHidden = true
        window.simulatesKeyWindow = true
        window.initialFirstResponder = field
        let key = ChatOrgKey(server: try ChatServerAddress(parsing: "https://example.com"), accountId: "me", orgId: "org")
        let dm = ChatDMRef(key, dm: "dm")
        for route in [ToolRoute.agentProfile(UUID()), .allSessions, .directMessage(dm), .settings] {
            let tab = store.openToolTab(route)
            let native = try XCTUnwrap(tab.engine as? NativeTabEngine)
            let content = native.view
            content.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
            window.contentView?.addSubview(content)
            content.layoutSubtreeIfNeeded()
            window.autorecalculatesKeyViewLoop = false
            content.nextKeyView = field; field.nextKeyView = content
            try await Task.sleep(for: .milliseconds(30))
            model.dismiss()
            window.makeFirstResponder(nil)
            native.focus()
            XCTAssertFalse(model.fieldFocused, "\(route)")
            XCTAssertFalse(model.suggestions, "\(route)")
            XCTAssertFalse(window.firstResponder === field, "\(route)")
            XCTAssertNil(field.currentEditor(), "\(route)")
            model.dismiss()
            window.makeFirstResponder(nil)
            content.removeFromSuperview()
        }
    }

    func testMovingFocusToTerminalClosesSuggestions() async throws {
        _ = try await open()
        let terminal = try XCTUnwrap(store.active?.activeSession?.engine.view)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        try await settle { !self.model.suggestions }
        XCTAssertTrue(window.firstResponder === terminal)
    }

    func testClearingQueryClosesSuggestionsAndTypingReopensThem() async throws {
        let editor = try await open()
        editor.selectAll(nil); editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle { !self.model.suggestions }
        XCTAssertEqual(model.query, "")
        editor.insertText("new", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle { self.model.suggestions }
        XCTAssertEqual(model.query, "new")
    }

    func testCommandPTogglesVisibilityAfterClearingTheFocusedField() async throws {
        let editor = try await open()
        editor.selectAll(nil); editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(model.suggestions); XCTAssertTrue(model.fieldFocused)
        model.toggle()
        XCTAssertTrue(model.suggestions); XCTAssertTrue(model.fieldFocused)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(model.focusRequest, 0)
        model.toggle()
        XCTAssertFalse(model.suggestions); XCTAssertFalse(model.fieldFocused)
        XCTAssertTrue(window.firstResponder === store.active?.activeSession?.engine.view)
    }

    func testViewAllResultsEndsEditingAndRestoresTerminalFocus() async throws {
        _ = try await open()
        var opened = 0
        model.openResults = { opened += 1 }
        model.showResults()
        try await settle { self.window.firstResponder === self.store.active?.activeSession?.engine.view }
        XCTAssertFalse(model.suggestions); XCTAssertEqual(opened, 1)
    }

    func testEscapeRoutesTypingBackToTerminalAndCommandPReopens() async throws {
        _ = try await open()
        let terminal = try XCTUnwrap(store.active?.activeSession?.engine.view as? InputSink)
        window.sendEvent(try key(7, "x"))
        XCTAssertEqual(model.query, "releasex"); XCTAssertEqual(terminal.input, "")
        window.sendEvent(try key(53, "\u{1b}"))
        XCTAssertFalse(model.suggestions); XCTAssertFalse(model.fieldFocused); XCTAssertEqual(model.focusRequest, 0)
        XCTAssertTrue(window.firstResponder === terminal)
        window.sendEvent(try key(8, "c"))
        XCTAssertEqual(terminal.input, "c"); XCTAssertEqual(model.query, "releasex")
        model.toggle()
        try await settle { self.model.fieldFocused && self.model.suggestions }
        window.sendEvent(try key(16, "y"))
        XCTAssertEqual(model.query, "y"); XCTAssertEqual(terminal.input, "c")
        model.toggle()
        XCTAssertFalse(model.suggestions); XCTAssertTrue(window.firstResponder === terminal)
    }

    func testCommandReturnClosesBeforeOpeningResults() async throws {
        _ = try await open()
        var opened = false
        model.openResults = {
            XCTAssertFalse(self.model.suggestions)
            XCTAssertFalse(self.model.fieldFocused)
            opened = true
        }
        XCTAssertTrue(window.performKeyEquivalent(with: try key(36, "\r", modifiers: .command)))
        XCTAssertTrue(opened); XCTAssertFalse(model.suggestions)
        XCTAssertTrue(window.firstResponder === store.active?.activeSession?.engine.view)
    }

    func testOutsideClicksReachTerminalChatAndNonfocusableSidebar() async throws {
        let terminal = try XCTUnwrap(store.active?.activeSession?.engine.view as? InputSink)
        let sidebar = InputSink(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        sidebar.focusOnClick = false
        let chat = InputSink(frame: NSRect(x: 0, y: 120, width: 160, height: 100))
        window.contentView?.addSubview(sidebar); window.contentView?.addSubview(chat)
        for destination in [terminal, sidebar, chat] {
            _ = try await open()
            let before = destination.clicks
            try click(destination)
            XCTAssertFalse(model.suggestions); XCTAssertEqual(destination.clicks, before + 1)
            XCTAssertTrue(window.firstResponder === (destination.focusOnClick ? destination : terminal),
                          "Click at \(destination.frame) left responder \(String(describing: window.firstResponder))")
        }
    }

    func testAllMouseButtonsDismissBeforeAnUnfocusableNativeViewSwallowsTheClick() async throws {
        let terminal = InputSink(frame: NSRect(x: 180, y: 0, width: 420, height: 240))
        terminal.focusOnClick = false // No responder change and no SwiftUI gesture propagation.
        window.contentView?.addSubview(terminal)
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let editor = try await open()
            terminal.onMouseDown = {
                XCTAssertFalse(self.model.suggestions, "Must dismiss before the destination handles \(type)")
                XCTAssertFalse(self.window.firstResponder === editor)
            }
            let before = terminal.clicks
            try click(terminal, type: type)
            XCTAssertEqual(terminal.clicks, before + 1, "The monitor must pass the event through")
            XCTAssertFalse(model.fieldFocused); XCTAssertEqual(model.focusRequest, 0)
        }
        terminal.onMouseDown = nil
    }

    func testMenuTrackingEndDismissesAfterASwallowedOutsideClick() async throws {
        let terminal = try XCTUnwrap(store.active?.activeSession?.engine.view)
        let point = window.convertPoint(toScreen: terminal.convert(NSPoint(x: 20, y: 20), to: nil))
        model.fieldFocus.mouseLocation = { point }
        for highlighted in [false, true] {
            let editor = try await open()
            let menu = SearchTestMenu()
            // Cancellation can leave the last hovered item highlighted.
            if highlighted { menu.selectedItem = NSMenuItem(title: "Select All", action: nil, keyEquivalent: "") }
            // Menu tracking consumes the click without sendEvent or a responder change.
            XCTAssertTrue(window.firstResponder === editor)
            await endMenuTracking(menu)
            XCTAssertFalse(model.suggestions)
            XCTAssertFalse(model.fieldFocused); XCTAssertEqual(model.focusRequest, 0)
            XCTAssertTrue(window.firstResponder === terminal)
        }
    }

    func testMenuTrackingEndKeepsClicksInsideTheFieldAndSuggestions() async throws {
        let editor = try await open()
        let panel = NSHostingView(rootView: SearchSuggestionsView(model: model))
        panel.frame = NSRect(x: 80, y: 0, width: 450, height: 240)
        window.contentView?.addSubview(panel); panel.layoutSubtreeIfNeeded()
        defer { panel.removeFromSuperview() }
        for region in [try XCTUnwrap(model.fieldFocus.fieldRegion), try XCTUnwrap(model.fieldFocus.suggestionsRegion)] {
            let point = window.convertPoint(toScreen: region.convert(NSPoint(x: region.bounds.midX, y: region.bounds.midY), to: nil))
            model.fieldFocus.mouseLocation = { point }
            await endMenuTracking()
            XCTAssertTrue(model.suggestions); XCTAssertTrue(window.firstResponder === editor)
        }
    }

    func testMenuItemSelectionKeepsSearchFocusEvenOutsideItsRegions() async throws {
        let editor = try await open()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        item.target = editor; menu.addItem(item)
        model.fieldFocus.mouseLocation = { NSPoint(x: -10_000, y: -10_000) }
        // AppKit ends tracking before dispatching the highlighted item's action.
        await endMenuTracking(menu) { menu.performActionForItem(at: 0) }
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: model.query.utf16.count))
        XCTAssertTrue(model.suggestions); XCTAssertTrue(window.firstResponder === editor)
    }

    func testClicksInAnotherNonKeyWindowDismissEvenWithoutAKeyWindowNotification() async throws {
        let other = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        let sink = InputSink(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        sink.focusOnClick = false
        other.contentView = sink
        defer { other.close() }
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let editor = try await open()
            try click(sink, type: type)
            XCTAssertFalse(model.suggestions); XCTAssertFalse(window.firstResponder === editor)
        }
    }

    func testTitleBarMouseDownDismissesBeforeWindowTracking() async throws {
        _ = try await open()
        let titleBarPoint = NSPoint(x: window.frame.width / 2, y: window.contentLayoutRect.maxY + 10)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: titleBarPoint,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: titleBarPoint,
            modifierFlags: [], timestamp: down.timestamp, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        XCTAssertFalse(model.suggestions); XCTAssertFalse(model.fieldFocused)
    }

    func testResponderObservationDismissesWithoutAnEndEditingDelegateCallback() async throws {
        _ = try await open()
        let field = try XCTUnwrap(model.fieldFocus.field)
        field.delegate = nil
        defer { field.delegate = field }
        let chat = NSTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        window.contentView?.addSubview(chat)
        XCTAssertTrue(window.makeFirstResponder(chat))
        XCTAssertFalse(model.suggestions); XCTAssertFalse(model.fieldFocused)
        XCTAssertTrue(window.firstResponder === chat)
    }

    func testKeyboardTabMovesFocusAndDismissesSuggestions() async throws {
        _ = try await open()
        let field = try XCTUnwrap(model.fieldFocus.field)
        let chat = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        window.contentView?.addSubview(chat)
        window.autorecalculatesKeyViewLoop = false
        field.nextKeyView = chat
        window.sendEvent(try key(48, "\t"))
        XCTAssertFalse(model.suggestions); XCTAssertFalse(model.fieldFocused)
        XCTAssertTrue(window.firstResponder === chat.currentEditor())
    }

    func testPendingRequestInBackgroundWindowCannotShowOrStealFocus() async throws {
        try await settle { self.model.fieldFocus.field != nil }
        window.simulatesKeyWindow = false
        model.begin()
        model.query = "pending"
        XCTAssertFalse(model.suggestions); XCTAssertFalse(model.fieldFocused)
        XCTAssertNil(model.fieldFocus.field?.currentEditor())
        window.simulatesKeyWindow = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await settle { self.model.suggestions }
        XCTAssertTrue(model.fieldFocused)
    }

    func testSearchFieldsInTwoWindowsShareOutsideClickHandlingAndReleaseOnUnmount() async throws {
        let otherModel = EverywhereSearchModel(messages: .init(context: { nil }, availability: { .noTeam }, fetch: { _, _ in
            XCTFail("Focus tests must not use the network"); return .init(hits: [], next: nil)
        }), indexing: model.indexing, catalog: model.catalog, names: model.names)
        let other = SearchTestWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        var field: SearchTextField? = SearchTextField(store: store, model: otherModel)
        weak var releasedField = field
        field?.frame = NSRect(x: 10, y: 25, width: 180, height: 24)
        other.contentView?.addSubview(try XCTUnwrap(field))
        otherModel.fieldFocus.fieldRegion = field
        defer { other.close() }

        _ = try await open()
        try click(try XCTUnwrap(field))
        XCTAssertFalse(model.suggestions); XCTAssertFalse(model.fieldFocused)
        XCTAssertTrue(otherModel.suggestions); XCTAssertTrue(otherModel.fieldFocused)
        try click(try XCTUnwrap(model.fieldFocus.field))
        XCTAssertFalse(otherModel.suggestions); XCTAssertFalse(otherModel.fieldFocused)
        XCTAssertTrue(model.suggestions); XCTAssertTrue(model.fieldFocused)

        field?.removeFromSuperview(); field = nil
        await Task.yield() // Drain the weak, deferred focus synchronization.
        XCTAssertNil(releasedField, "The shared monitor must not retain a removed field")
        XCTAssertNil(otherModel.fieldFocus.field)
        try click(try XCTUnwrap(store.active?.activeSession?.engine.view))
        XCTAssertFalse(model.suggestions, "Unmounting one field must leave monitoring active for the other")
    }

    func testMovingFocusToChatWithoutClickClosesWithoutStealingFocus() async throws {
        _ = try await open()
        let chat = NSTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        window.contentView?.addSubview(chat)
        XCTAssertTrue(window.makeFirstResponder(chat))
        XCTAssertFalse(model.suggestions); XCTAssertTrue(window.firstResponder === chat)
    }

    func testWindowResigningKeyAndAppDeactivationCloseWithoutReopeningOnReturn() async throws {
        _ = try await open()
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        XCTAssertTrue(model.suggestions, "A different window's lifecycle must not dismiss this field")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(model.suggestions); XCTAssertEqual(model.focusRequest, 0)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertFalse(model.suggestions)
        XCTAssertTrue(window.firstResponder === store.active?.activeSession?.engine.view)
        _ = try await open()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(model.suggestions); XCTAssertFalse(model.fieldFocused)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertFalse(model.suggestions)
        _ = try await open()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        XCTAssertFalse(model.suggestions); XCTAssertFalse(model.fieldFocused)
    }

    func testNavigationToTabPaneAndWorkspaceDismissesSearch() async throws {
        let workspace = try XCTUnwrap(store.active)
        _ = try await open()
        _ = store.addTab(in: workspace, template: .terminal)
        try await settle { !self.model.suggestions }
        _ = try await open()
        store.splitPane(try XCTUnwrap(workspace.activePane), orientation: .horizontal, in: workspace)
        try await settle { !self.model.suggestions }
        _ = try await open()
        store.addWorkspace()
        try await settle { !self.model.suggestions }
        XCTAssertEqual(model.focusRequest, 0)
    }

    func testRemountAfterDismissalDoesNotReplayAnOldFocusRequest() async throws {
        _ = try await open()
        model.dismiss()
        host.removeFromSuperview()
        host = NSHostingView(rootView: SearchEverywhereField(store: store, model: model))
        host.frame = NSRect(x: 0, y: 250, width: 600, height: 40)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.suggestions); XCTAssertEqual(model.focusRequest, 0)
        XCTAssertTrue(window.firstResponder === store.active?.activeSession?.engine.view)
        model.begin()
        try await settle { self.model.fieldFocused && self.model.suggestions }
    }

    func testResultActivationClosesEvenWhenDestinationIsAlreadyActive() async throws {
        let items = (1...2).map {
            PaletteItem(id: "tab-\($0)", title: "release \($0)", subtitle: "tab", kind: .agent(templateId: "terminal"), symbol: "terminal", iconAsset: nil)
        }
        model.quickItems = { items }
        _ = try await open()
        try await settle { self.model.quick.count == 2 }
        window.sendEvent(try key(125, "\u{f701}"))
        XCTAssertEqual(model.selected, "q:tab-1")
        window.sendEvent(try key(125, "\u{f701}"))
        XCTAssertEqual(model.selected, "q:tab-2")
        var picked: String?
        model.activateQuick = { picked = $0.id }
        model.activate("q:tab-2") // The same action as a suggestion row click.
        XCTAssertEqual(picked, "tab-2"); XCTAssertFalse(model.suggestions)
        XCTAssertTrue(window.firstResponder === store.active?.activeSession?.engine.view)
    }

    func testToggleKeepsPendingFocusUntilExplicitDismissalWithoutAField() {
        host.removeFromSuperview()
        model.begin(); XCTAssertFalse(model.suggestions); XCTAssertGreaterThan(model.focusRequest, 0)
        model.toggle()
        XCTAssertFalse(model.suggestions); XCTAssertGreaterThan(model.focusRequest, 0)
        model.dismiss()
        XCTAssertFalse(model.suggestions); XCTAssertEqual(model.focusRequest, 0)
        model.query = "late change"; model.update(debounce: false)
        XCTAssertFalse(model.suggestions)
    }

    func testFieldClickReopensAfterDismissalAndUnmountEndsTheSession() async throws {
        _ = try await open()
        model.dismiss()
        let field = try XCTUnwrap(model.fieldFocus.field)
        try click(field)
        XCTAssertTrue(model.suggestions); XCTAssertTrue(model.fieldFocused)
        XCTAssertEqual(model.focusRequest, 0)
        host.removeFromSuperview()
        XCTAssertFalse(model.suggestions); XCTAssertFalse(model.fieldFocused)
    }

    func testClickInAlreadyFocusedFieldReopensEmptySuggestions() async throws {
        let editor = try await open()
        editor.selectAll(nil); editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(model.suggestions); XCTAssertTrue(model.fieldFocused)
        try click(try XCTUnwrap(model.fieldFocus.field))
        XCTAssertTrue(model.suggestions); XCTAssertTrue(window.firstResponder === editor)
    }

    func testChannelTabSwitchDismissesSearchAndSkipsAutomaticSearchFocus() async throws {
        _ = try await open()
        let workspace = try XCTUnwrap(store.active)
        let ref = ChannelRef(server: "https://example.com:443", account: "me", org: "org", channel: "channel")
        let tab = store.openChannelTab(ref, in: workspace)
        let content = tab.engine.view
        content.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
        window.contentView?.addSubview(content); content.layoutSubtreeIfNeeded()
        defer { content.removeFromSuperview() }
        try await settle { !self.model.suggestions && !self.model.fieldFocused }
        window.initialFirstResponder = model.fieldFocus.field
        window.makeFirstResponder(nil)
        window.selectNextKeyView(content)
        XCTAssertFalse(model.fieldFocused); XCTAssertFalse(model.suggestions)
        XCTAssertEqual(model.focusRequest, 0)
    }

    func testSuggestionsHitRegionPreservesThePendingResultAction() async throws {
        let item = PaletteItem(id: "release", title: "Release tab", subtitle: "tab", kind: .agent(templateId: "terminal"), symbol: "terminal", iconAsset: nil)
        model.quickItems = { [item] }
        _ = try await open()
        try await settle { !self.model.quick.isEmpty }
        let panel = NSHostingView(rootView: SearchSuggestionsView(model: model))
        panel.frame = NSRect(x: 80, y: 0, width: 450, height: 240)
        window.contentView?.addSubview(panel); panel.layoutSubtreeIfNeeded()
        defer { panel.removeFromSuperview() }
        let region = try XCTUnwrap(model.fieldFocus.suggestionsRegion)
        XCTAssertGreaterThan(region.bounds.width, 0); XCTAssertGreaterThan(region.bounds.height, 0)
        XCTAssertTrue(model.suggestions, "Mounting suggestions must keep field focus: \(String(describing: window.firstResponder))")
        try click(region, type: .rightMouseDown)
        XCTAssertTrue(model.suggestions, "Clicks inside suggestions must keep field focus: \(String(describing: window.firstResponder))")
        var picked = false
        model.activateQuick = { picked = $0.id == item.id }
        model.activate("q:" + item.id)
        XCTAssertTrue(picked); XCTAssertFalse(model.suggestions)
        XCTAssertTrue(window.firstResponder === store.active?.activeSession?.engine.view)
    }

    func testPopoverResultViewAllAndSearchSettingsButtonsReceiveMouseClicks() async throws {
        let item = PaletteItem(id: "release", title: "Release tab", subtitle: "tab", kind: .agent(templateId: "terminal"), symbol: "terminal", iconAsset: nil)
        model.quickItems = { [item] }
        await model.indexing.enable()
        await model.indexing.pause(true) // Show the real Search settings button.
        let panel = NSHostingView(rootView: SearchSuggestionsView(model: model))
        panel.frame = NSRect(x: 80, y: 0, width: 450, height: 240)
        window.contentView?.addSubview(panel)
        defer { panel.removeFromSuperview() }
        var picked = false, opened = false
        model.activateQuick = { picked = $0.id == item.id }
        model.openResults = { opened = true }

        _ = try await open()
        try await settle { !self.model.quick.isEmpty && !self.model.localLoading }
        panel.layoutSubtreeIfNeeded()
        // This fixed-size fixture has one quick row below its heading.
        try click(at: NSPoint(x: 220, y: 48), in: panel) {
            if !picked { XCTAssertTrue(self.model.suggestions, "Keep the row mounted until its action runs") }
        }
        XCTAssertTrue(picked); XCTAssertFalse(model.suggestions)

        _ = try await open()
        try await settle { !self.model.quick.isEmpty && !self.model.localLoading }
        panel.layoutSubtreeIfNeeded()
        try click(at: NSPoint(x: 65, y: panel.bounds.maxY - 20), in: panel) {
            if !opened { XCTAssertTrue(self.model.suggestions, "Keep View all results mounted until mouse-up") }
        }
        XCTAssertTrue(opened); XCTAssertFalse(model.suggestions)

        let router = TabRouter.shared
        let previousAdmit = router.admit, previousStores = router.stores, previousHost = router.ensureHost
        let previousSettings = SupportTabs.shared.settingsModel
        router.admit = nil; router.stores = { [self.store] }; router.ensureHost = { self.store }
        SupportTabs.shared.settingsModel = { AgentPadSettingsModel(read: { [:] }, write: { _ in }, appliesRuntimeEffects: false) }
        defer {
            router.admit = previousAdmit; router.stores = previousStores; router.ensureHost = previousHost
            SupportTabs.shared.settingsModel = previousSettings
        }
        _ = try await open()
        try await settle { !self.model.quick.isEmpty && !self.model.localLoading }
        panel.layoutSubtreeIfNeeded()
        try click(at: NSPoint(x: 218, y: 110), in: panel) {
            if self.store.active?.activeSession?.toolRoute != .settings { XCTAssertTrue(self.model.suggestions) }
        }
        try await settle { !self.model.suggestions }
        XCTAssertEqual(store.active?.activeSession?.toolRoute, .settings)
        XCTAssertEqual(store.active?.activeSession?.tabState?.navigation.settingsSection, .search)
    }
}

private final class SearchTestMenu: NSMenu {
    var selectedItem: NSMenuItem?
    override var highlightedItem: NSMenuItem? { selectedItem }
}

@MainActor
final class SearchTestWindow: NSWindow {
    // Exercise the same focus rule without activating the test runner's app.
    var simulatesKeyWindow = true
    override var isKeyWindow: Bool { simulatesKeyWindow }
}

@MainActor
private final class InputSink: NSView {
    var input = ""
    var clicks = 0
    var focusOnClick = true
    var onMouseDown: (() -> Void)?
    override var acceptsFirstResponder: Bool { focusOnClick }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) { input += event.characters ?? "" }
    override func mouseDown(with event: NSEvent) {
        clicks += 1
        onMouseDown?()
        if focusOnClick { window?.makeFirstResponder(self) }
    }
    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }
}

final class SearchSuggestionsStateTests: XCTestCase {
    func testVisibilityRequiresBothTheFieldResponderAndKeyWindow() {
        for responder in [false, true] {
            for keyWindow in [false, true] {
                var state = SearchSuggestionsState()
                state.requestFocus()
                XCTAssertFalse(state.visible, "A focus request alone cannot display the popover")
                state.updateFocus(ownsFirstResponder: responder, isKeyWindow: keyWindow)
                XCTAssertEqual(state.visible, responder && keyWindow)
            }
        }
    }

    func testLosingFocusCancelsTheSessionAndLateQueriesCannotReopenIt() {
        for responderLost in [false, true] {
            var state = SearchSuggestionsState()
            state.requestFocus()
            state.updateFocus(ownsFirstResponder: true, isKeyWindow: true)
            XCTAssertTrue(state.visible)
            state.updateFocus(ownsFirstResponder: !responderLost, isKeyWindow: responderLost)
            state.queryChanged(isEmpty: false)
            state.updateFocus(ownsFirstResponder: true, isKeyWindow: true)
            XCTAssertFalse(state.visible); XCTAssertEqual(state.focusRequest, 0)
        }
    }

    func testDismissalCancelsPendingFocusAndUnrequestedFocusNeverShowsSuggestions() {
        var state = SearchSuggestionsState()
        state.requestFocus(); state.dismiss()
        state.updateFocus(ownsFirstResponder: true, isKeyWindow: true)
        XCTAssertFalse(state.visible); XCTAssertEqual(state.focusRequest, 0)
    }
}
