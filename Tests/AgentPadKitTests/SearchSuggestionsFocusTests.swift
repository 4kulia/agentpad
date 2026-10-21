import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

@MainActor
final class SearchSuggestionsFocusTests: XCTestCase {
    private var root: URL!
    private var store: WorkspaceStore!
    private var model: EverywhereSearchModel!
    private var window: SearchTestWindow!
    private var host: NSHostingView<SearchEverywhereField>!
    private var previousEnhancedUI: Any?

    override func setUp() async throws {
        _ = NSApplication.shared
        previousEnhancedUI = NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("search-focus-\(UUID())")
        store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            agentProfiles: AgentProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            drafts: DraftRepository(fileURL: root.appendingPathComponent("drafts.json")), engineFactory: { TestEngine(view: InputSink()) })
        store.addWorkspace()
        model = EverywhereSearchModel(messages: .init(context: { nil }, availability: { .noTeam }, fetch: { _, _ in
            XCTFail("Focus tests must not use the network"); return .init(hits: [], next: nil)
        }), indexing: .init(index: ConversationIndex(directory: root.appendingPathComponent("index"), roots: [:])),
            catalog: .init(scan: { _ in .init(records: [], scanned: 0, total: 0, skipped: 0) }),
            names: SessionNames(url: root.appendingPathComponent("names.sqlite")),
            telegram: .init(chats: TelegramChatsModel()))
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
        NSApp.accessibilitySetValue(previousEnhancedUI, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
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

    func testCommandCommaRestoresFocusedPersistentSearchAfterSettingsDismissal() async throws {
        let content = try XCTUnwrap(window.contentView)
        let popupHost = NSHostingView(rootView: SearchPopupTestContent(content: content).popupHost(store.popups))
        popupHost.frame = content.frame
        window.contentView = popupHost
        popupHost.layoutSubtreeIfNeeded()
        let terminal = try XCTUnwrap(store.active?.activeSession?.engine.view as? InputSink)
        let router = TabRouter.shared
        let previousAdmit = router.admit, previousStores = router.stores, previousHost = router.ensureHost
        let previousSettings = SupportTabs.shared.settingsModel
        let previousMenu = NSApp.mainMenu, previousWindows = NSApp.windowsMenu, previousHelp = NSApp.helpMenu
        router.admit = nil; router.stores = { [self.store] }; router.ensureHost = { self.store }
        SupportTabs.shared.settingsModel = { AgentPadSettingsModel(read: { [:] }, write: { _ in }, appliesRuntimeEffects: false) }
        defer {
            router.admit = previousAdmit; router.stores = previousStores; router.ensureHost = previousHost
            SupportTabs.shared.settingsModel = previousSettings
            NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindows; NSApp.helpMenu = previousHelp
        }
        let delegate = AppDelegate(appPersistence: AppPersistence(fileURL: root.appendingPathComponent("windows.json")),
                                   agentProfiles: store.agentProfiles)
        delegate.installMainMenu()
        _ = try await open()
        let field = try XCTUnwrap(model.fieldFocus.field)
        XCTAssertTrue(window.firstResponder === field.currentEditor())
        XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: try key(43, ",", modifiers: .command)) == true)
        guard case .tool(let settings) = store.popups.page else { return XCTFail("Command-comma must open Settings") }
        XCTAssertEqual(settings.toolRoute, .settings)
        try await assertPopupInventoryPresentation(in: window, root: popupHost, coordinator: store.popups,
            title: "Settings", content: settings.engine.view)
        XCTAssertFalse(model.fieldFocused); XCTAssertFalse(model.suggestions)
        let query = model.query
        NSApp.sendEvent(try key(7, "x"))
        XCTAssertEqual(model.query, query)
        XCTAssertEqual(terminal.input, "", "Typing while Settings is open must not reach the terminal")

        NSApp.sendEvent(try key(53, "\u{1b}"))
        XCTAssertFalse(store.popups.isPresented)
        try await settle { self.model.fieldFocused }
        XCTAssertTrue(model.fieldFocus.field === field, "The persistent search opener remains mounted")
        XCTAssertTrue(window.firstResponder === field.currentEditor())
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        NSApp.sendEvent(try key(6, "z"))
        XCTAssertEqual(model.query, query + "z", "Typing after dismissal must return to search")
        XCTAssertEqual(terminal.input, "")
    }

    private func withPopupRouting(_ body: (NSView) async throws -> Void) async throws {
        _ = SupportTabs.shared
        let content = try XCTUnwrap(window.contentView)
        let popupHost = NSHostingView(rootView: SearchPopupTestContent(content: content).popupHost(store.popups))
        popupHost.frame = content.frame
        window.contentView = popupHost
        popupHost.layoutSubtreeIfNeeded()
        let router = TabRouter.shared
        let previousAdmit = router.admit, previousStores = router.stores, previousHost = router.ensureHost
        router.admit = nil; router.stores = { [self.store] }; router.ensureHost = { self.store }
        defer {
            router.admit = previousAdmit; router.stores = previousStores; router.ensureHost = previousHost
        }
        try await body(popupHost)
    }

    private func closePopupBackToSearch(in popupHost: NSView, field: SearchTextField) async throws {
        let page = try XCTUnwrap(store.popups.page, "Expected a search popup")
        let content: NSView?
        if case .tool(let session) = page { content = session.engine.view } else { content = nil }
        try await assertPopupInventoryPresentation(in: window, root: popupHost, coordinator: store.popups,
            title: page.presentationTitle, content: content)
        let terminals = store.allSessions.compactMap { $0.engine.view as? InputSink }
        XCTAssertFalse(terminals.isEmpty)
        let query = model.query
        XCTAssertFalse(model.suggestions); XCTAssertFalse(model.fieldFocused)
        NSApp.sendEvent(try key(7, "x"))
        XCTAssertEqual(model.query, query)
        XCTAssertEqual(terminals.map(\.input), Array(repeating: "", count: terminals.count), "A search popup must isolate terminal input")
        NSApp.sendEvent(try key(53, "\u{1b}"))
        XCTAssertFalse(store.popups.isPresented)
        try await settle { self.model.fieldFocused }
        XCTAssertTrue(model.fieldFocus.field === field)
        XCTAssertTrue(window.firstResponder === field.currentEditor())
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        NSApp.sendEvent(try key(6, "z"))
        XCTAssertEqual(model.query, query + "z")
        XCTAssertEqual(terminals.map(\.input), Array(repeating: "", count: terminals.count))
    }

    func testAllQuickPopupRoutesRestoreSurvivingSearchOpener() async throws {
        try await withPopupRouting { popupHost in
            let workspace = try XCTUnwrap(self.store.active)
            let scope = try OrgKey(server: "https://example.com", accountID: "me", orgID: "org")
            let entries: [(String, PaletteItemKind, () -> Void)] = [
                ("New SSH Workspace…", .createSSHWorkspace, { self.store.requestCreateSSHWorkspace() }),
                ("Create Worktree", .createWorktree(workspaceId: workspace.id, windowId: self.store.windowID), {
                    self.store.requestCreateWorktree(workspace)
                }),
                ("Published agent", .teamAgent(scope, "agent"), {
                    SupportTabs.shared.navigation.open(.agent(scope, agentID: "agent"), from: self.store)
                })
            ]
            for (title, kind, action) in entries {
                let item = PaletteItem(id: title, title: title, subtitle: "release", kind: kind, symbol: "network", iconAsset: nil)
                self.model.quickItems = { [item] }
                self.model.activateQuick = { picked in XCTAssertEqual(picked, item); action() }
                self.model.dismiss()
                _ = try await self.open()
                try await self.settle { self.model.quick == [item] }
                let field = try XCTUnwrap(self.model.fieldFocus.field)
                self.model.activate("q:" + item.id)
                try await self.closePopupBackToSearch(in: popupHost, field: field)
            }
        }
    }

    private func searchButton(_ title: String, in root: NSView) throws -> FoldersAXNode {
        var queue: [NSObject] = [root], seen: Set<ObjectIdentifier> = []
        while let object = queue.popLast() {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            let node = FoldersAXNode(object: object)
            if (node.accessibilityLabel() == title || node.accessibilityTitle() == title),
               object.responds(to: NSSelectorFromString("accessibilityPerformPress")) { return node }
            queue += node.children
            if let view = object as? NSView { queue += view.subviews }
        }
        return try XCTUnwrap(nil as FoldersAXNode?, "Missing button: \(title)")
    }

    func testBothTelegramSuggestionButtonsRestoreSearchAfterMouseClick() async throws {
        try await withPopupRouting { popupHost in
            for source in [SearchSource.all, .telegram] {
                self.model.source = source
                let panel = NSHostingView(rootView: SearchSuggestionsView(model: self.model))
                panel.frame = NSRect(x: 70, y: 0, width: 460, height: 240)
                self.host.superview?.addSubview(panel)
                defer { panel.removeFromSuperview() }
                _ = try await self.open()
                try await self.settle { !self.model.localLoading }
                panel.layoutSubtreeIfNeeded()
                let field = try XCTUnwrap(self.model.fieldFocus.field)
                let button = try self.searchButton("Connect Telegram…", in: panel)
                let frame = panel.convert(self.window.convertFromScreen(button.accessibilityFrame()), from: nil)
                try self.click(at: NSPoint(x: frame.midX, y: frame.midY), in: panel)
                XCTAssertEqual(self.store.popups.sessions.last?.tabState?.navigation.settingsSection, .telegram)
                panel.removeFromSuperview()
                try await self.closePopupBackToSearch(in: popupHost, field: field)
                @MainActor func hasDialog(_ view: NSView) -> Bool {
                    view.accessibilityIdentifier() == "popup-dialog" || view.subviews.contains(where: hasDialog)
                }
                // Closing restores the responder synchronously; wait for the
                // SwiftUI overlay to unmount before the next physical click.
                try await self.settle {
                    popupHost.layoutSubtreeIfNeeded()
                    return !hasDialog(popupHost)
                }
            }
        }
    }

    func testResultsPopupButtonsRestoreSurvivingSearchOpener() async throws {
        await model.indexing.enable()
        await model.indexing.pause(true)
        try await withPopupRouting { popupHost in
            let state = TabState(route: .search)
            let panel = NSHostingView(rootView: SearchResultsTab(model: self.model, state: state, store: self.store))
            panel.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
            self.host.superview?.addSubview(panel)
            defer { panel.removeFromSuperview() }
            for title in ["Connect Telegram…", "Connect a team…", "Search settings"] {
                _ = try await self.open()
                try await self.settle { !self.model.localLoading }
                panel.layoutSubtreeIfNeeded()
                let field = try XCTUnwrap(self.model.fieldFocus.field)
                // Keyboard/AX activation preserves the focused search opener;
                // an ordinary click outside search first focuses the results.
                XCTAssertTrue(try self.searchButton(title, in: panel).accessibilityPerformPress())
                try await self.closePopupBackToSearch(in: popupHost, field: field)
            }
        }
    }

    func testTelegramCommandShiftReturnFolderPopupRestoresSurvivingSearchOpener() async throws {
        try await telegramFolderPopup(existingInOtherWindow: false)
    }

    func testTelegramFolderPopupPreservesSearchBeforeRevealingAnotherWindow() async throws {
        try await telegramFolderPopup(existingInOtherWindow: true)
    }

    private func telegramFolderPopup(existingInOtherWindow: Bool) async throws {
        let row = TelegramChatRow(id: .init(environment: .test, account: 42, chat: 7), title: "release folder",
            username: "", kind: .person, unreadCount: 0, unreadMentionCount: 0, inMain: true, inArchive: false,
            pinned: false, hidden: false, lastMessageDate: 100, knownRelevant: true)
        var snapshot = TelegramChatSnapshot()
        snapshot.state = .complete
        snapshot.account = .init(environment: .test, account: 42, chat: 0)
        snapshot.binding = .init(environment: .test, account: 42, connectionID: UUID())
        snapshot.mainRows = [row]; snapshot.suggestionRows = [row]
        snapshot.mainList.capacity = 1; snapshot.mainList.counts.rows = 1
        let provider = FoldersUIProvider(snapshot: snapshot, rows: [.main: [row]])
        model.telegram.chats.attach(provider)
        try await settle { self.model.telegram.chats.connected }
        model.source = .telegram
        let completed = expectation(description: "Telegram selection and folder popup completed")
        model.openTelegram = { hit, beside, addToFolder in
            XCTAssertFalse(beside); XCTAssertTrue(addToFolder)
            Task {
                let opened = await self.model.telegram.open(hit, from: self.store, beside: beside, addToFolder: addToFolder)
                XCTAssertTrue(opened)
                if opened { self.model.dismiss() }
                completed.fulfill()
            }
        }
        try await withPopupRouting { popupHost in
            let other = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, engineFactory: {
                XCTFail("Opening Telegram must not create a terminal"); return TestEngine()
            })
            defer { other.terminate() }
            let router = TabRouter.shared, previousReveal = TabRouter.shared.revealWindow
            defer { router.revealWindow = previousReveal }
            if existingInOtherWindow {
                router.stores = { [self.store, other] }
                _ = TelegramTabs.open(row, from: other)
                router.revealWindow = { owner in
                    if owner === other {
                        // Revealing an existing chat's window ends the source
                        // field's editing before the folder chooser opens.
                        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: self.window)
                    }
                }
            }
            _ = try await self.open()
            try await self.settle { self.model.telegram.hits.count == 1 }
            let field = try XCTUnwrap(self.model.fieldFocus.field)
            self.model.selected = "t:" + self.model.telegram.hits[0].id
            XCTAssertTrue(self.window.performKeyEquivalent(with: try self.key(36, "\r", modifiers: [.command, .shift])))
            await self.fulfillment(of: [completed], timeout: 2)
            guard case .native(let page) = self.store.popups.page else { return XCTFail("Expected Add to folder popup") }
            XCTAssertEqual(page.title, "Add to folder…")
            XCTAssertEqual((existingInOtherWindow ? other : self.store).active?.activeSession?.toolRoute, .telegram(row.id))
            try await self.closePopupBackToSearch(in: popupHost, field: field)
        }
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
        let content = try XCTUnwrap(window.contentView)
        let popupHost = NSHostingView(rootView: SearchPopupTestContent(content: content).popupHost(store.popups))
        popupHost.frame = content.frame
        window.contentView = popupHost
        popupHost.layoutSubtreeIfNeeded()
        let originalSession = try XCTUnwrap(store.active?.activeSession)
        let originalTabs = store.allSessions.map(\.id)
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
            if self.store.popups.sessions.first(where: { $0.toolRoute == .settings }) == nil {
                XCTAssertTrue(self.model.suggestions, "Keep Search settings mounted until its action runs")
            }
        }
        guard case .tool(let settings) = store.popups.page else { return XCTFail("Search settings must open a popup") }
        XCTAssertEqual(settings.toolRoute, .settings)
        XCTAssertEqual(settings.tabState?.navigation.settingsSection, .search)
        XCTAssertEqual(store.popups.sessions.map(\.id), [settings.id])
        try await assertPopupInventoryPresentation(in: window, root: popupHost, coordinator: store.popups,
            title: "Settings", content: settings.engine.view)
        try await settle { !self.model.suggestions }
        XCTAssertFalse(model.fieldFocused)
        func insidePopup(_ view: NSView) -> Bool {
            if view.accessibilityIdentifier() == "popup-dialog" { return true }
            return view.superview.map(insidePopup) ?? false
        }
        let responder = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertTrue(insidePopup(responder) || (responder as? NSTextView).flatMap { $0.delegate as? NSView }.map(insidePopup) == true,
                      "Search settings must move keyboard focus inside the popup")
        XCTAssertTrue(store.active?.activeSession === originalSession)
        XCTAssertEqual(store.allSessions.map(\.id), originalTabs, "Opening Settings must preserve the underlying tabs")
        let terminal = try XCTUnwrap(originalSession.engine.view as? InputSink)
        let query = model.query
        NSApp.sendEvent(try key(7, "x"))
        XCTAssertEqual(model.query, query)
        XCTAssertEqual(terminal.input, "", "Search settings must isolate terminal input")
        // The suggestions popover disappears on dismissal. Its keyboard
        // opener is the still-mounted search field, not the transient button.
        panel.removeFromSuperview()
        NSApp.sendEvent(try key(53, "\u{1b}"))
        XCTAssertFalse(store.popups.isPresented)
        try await settle { self.model.fieldFocused }
        let field = try XCTUnwrap(model.fieldFocus.field)
        XCTAssertTrue(window.firstResponder === field.currentEditor())
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        NSApp.sendEvent(try key(6, "z"))
        XCTAssertEqual(model.query, query + "z", "Closing Search settings must restore its surviving search opener")
        XCTAssertEqual(terminal.input, "")
    }
}

private struct SearchPopupTestContent: NSViewRepresentable {
    let content: NSView
    func makeNSView(context: Context) -> NSView { content }
    func updateNSView(_ view: NSView, context: Context) {}
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
