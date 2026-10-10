import AppKit
import SwiftUI

/// A request can mount/focus the field, but only confirmed keyboard focus in
/// the key window can display suggestions. Retained queries never grant focus.
struct SearchSuggestionsState {
    private(set) var requested = false
    private(set) var fieldFocused = false
    private(set) var focusRequest = 0
    var visible: Bool { requested && fieldFocused }

    mutating func requestFocus() { requested = true; focusRequest += 1 }
    mutating func updateFocus(ownsFirstResponder: Bool, isKeyWindow: Bool) {
        let focused = ownsFirstResponder && isKeyWindow
        if fieldFocused && !focused { dismiss() }
        fieldFocused = focused
        if focused { focusRequest = 0 }
    }
    mutating func queryChanged(isEmpty: Bool) {
        requested = (fieldFocused || focusRequest > 0) && !isEmpty
    }
    mutating func dismiss() { requested = false; fieldFocused = false; focusRequest = 0 }
}

/// The field and suggestions are SwiftUI siblings. Keep their hit regions
/// together so an outside click dismisses without swallowing the destination's
/// mouse event, including clicks on nonfocusable sidebar/chat content.
@MainActor
final class SearchFieldFocus {
    weak var field: SearchTextField?
    weak var fieldRegion: NSView?
    weak var suggestionsRegion: NSView?
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }

    func contains(_ event: NSEvent, suggestions: Bool) -> Bool {
        contains(event, in: fieldRegion) || (suggestions && contains(event, in: suggestionsRegion))
    }
    func contains(_ event: NSEvent, in view: NSView?) -> Bool {
        guard let view else { return false }
        return view.window === event.window && !view.isHiddenOrHasHiddenAncestor
            && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }
    func contains(_ screenPoint: NSPoint, suggestions: Bool) -> Bool {
        [fieldRegion, suggestions ? suggestionsRegion : nil].contains { view in
            guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return false }
            return view.bounds.contains(view.convert(window.convertPoint(fromScreen: screenPoint), from: nil))
        }
    }
}

/// Shared by all mounted search fields. Local monitors run before NSView event
/// delivery, including libghostty's mouseDown and window title-bar tracking.
/// The weak registry and weak callbacks let the last field release the monitor.
@MainActor
private final class SearchFieldEventMonitor {
    private static weak var current: SearchFieldEventMonitor?
    private let fields = NSHashTable<SearchTextField>.weakObjects()
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var menuActions = 0

    static func register(_ field: SearchTextField) -> SearchFieldEventMonitor {
        let monitor = current ?? SearchFieldEventMonitor()
        current = monitor
        monitor.fields.add(field)
        return monitor
    }

    private init() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.fields.allObjects.forEach { $0.handleMouseDown(event) }
            }
            return event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuActions += 1
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let actions = self.menuActions
                self.fields.allObjects.forEach { field in
                    field.handleMenuEndTracking { [weak self] in self?.menuActions != actions }
                }
            }
        })
        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.willMiniaturizeNotification, NSWindow.willCloseNotification,
                     NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let changedWindow = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    for field in self?.fields.allObjects ?? [] {
                        if name == NSWindow.didBecomeKeyNotification, field.window === changedWindow {
                            field.focusIfRequested()
                            field.synchronizeFocus()
                        } else if name == NSApplication.didResignActiveNotification
                                    || name == NSWindow.didBecomeKeyNotification
                                    || field.window === changedWindow {
                            field.dismissSearch()
                        }
                    }
                }
            })
        }
    }

    isolated deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

struct SearchInteractionRegion: NSViewRepresentable {
    let focus: SearchFieldFocus
    let suggestions: Bool
    func makeNSView(context: Context) -> NSView {
        let view = RegionView()
        if suggestions { focus.suggestionsRegion = view } else { focus.fieldRegion = view }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class RegionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct SearchTextFieldRepresentable: NSViewRepresentable {
    let store: WorkspaceStore
    @Bindable var model: EverywhereSearchModel
    func makeNSView(context: Context) -> SearchTextField { SearchTextField(store: store, model: model) }
    func updateNSView(_ field: SearchTextField, context: Context) {
        if field.stringValue != model.query { field.stringValue = model.query }
        if model.focusRequest > 0 {
            DispatchQueue.main.async { [weak field] in field?.focusIfRequested() }
        }
    }
    static func dismantleNSView(_ field: SearchTextField, coordinator: ()) { field.disconnect() }
}

/// AppKit's field editor is the keyboard authority, just as it is for the
/// terminal. Its end-editing callback also covers focus changes outside the
/// SwiftUI focus tree; window/app notifications cover losing key while AppKit
/// deliberately retains the same first responder.
final class SearchTextField: NSTextField, NSTextFieldDelegate {
    private let store: WorkspaceStore
    private let model: EverywhereSearchModel
    private var eventMonitor: SearchFieldEventMonitor?
    private var responderObservation: NSKeyValueObservation?
    private var handlingSuggestionClick = false

    init(store: WorkspaceStore, model: EverywhereSearchModel) {
        self.store = store; self.model = model
        super.init(frame: .zero)
        delegate = self
        isEditable = true; isSelectable = true; usesSingleLineMode = true
        isBordered = false; drawsBackground = false; focusRingType = .none
        font = NSFont(name: "Onest", size: 11) ?? .systemFont(ofSize: 11); textColor = .labelColor
        placeholderString = "Search everywhere…"
        setAccessibilityLabel("Search everywhere")
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        responderObservation = nil
        guard let window else { disconnect(); return }
        model.fieldFocus.field = self
        if eventMonitor == nil { eventMonitor = SearchFieldEventMonitor.register(self) }
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.synchronizeFocus() }
        }
        synchronizeFocus()
        DispatchQueue.main.async { [weak self] in self?.focusIfRequested() }
    }

    func disconnect() {
        responderObservation = nil
        eventMonitor = nil
        if model.fieldFocus.field === self {
            model.dismiss()
            model.fieldFocus.field = nil
        }
    }
    fileprivate func handleMouseDown(_ event: NSEvent) {
        guard window != nil, model.fieldFocus.field === self else { return }
        // A popover's scroll view/buttons may try to take the field editor's
        // responder during mouseDown. Keep keyboard focus until the action can
        // run; explicit dismissal below always releases this protection.
        handlingSuggestionClick = model.suggestions && model.fieldFocus.contains(event, in: model.fieldFocus.suggestionsRegion)
        if handlingSuggestionClick {
            DispatchQueue.main.async { [weak self] in self?.handlingSuggestionClick = false }
        }
        // Also handles an existing field editor after clearing the query.
        if event.type == .leftMouseDown, event.window === window, !isHiddenOrHasHiddenAncestor,
           bounds.contains(convert(event.locationInWindow, from: nil)) {
            (NSApp.delegate as? AppDelegate)?.prepareSearch(in: store)
            model.begin()
        } else if !model.fieldFocus.contains(event, suggestions: model.suggestions) {
            dismissSearch()
        }
    }
    fileprivate func dismissSearch() {
        if model.fieldFocus.field === self { model.dismiss() }
    }
    fileprivate func handleMenuEndTracking(menuActionSent: @escaping () -> Bool) {
        // Menu tracking can swallow an outside click without changing the
        // responder. Capture its location before returning to the event loop.
        let location = model.fieldFocus.mouseLocation()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.fieldFocus.field === self else { return }
            self.synchronizeFocus()
            // A chosen menu item may lie outside both search regions. Let its
            // action run with the field editor intact (tracking ends first).
            if !menuActionSent() && !self.model.fieldFocus.contains(location, suggestions: self.model.suggestions) {
                self.dismissSearch()
            }
        }
    }
    fileprivate func synchronizeFocus() {
        guard model.fieldFocus.field === self else { return }
        // NSWindow briefly assigns the NSTextField before asking it to become
        // first responder. Only the installed field editor confirms acceptance.
        model.updateFieldFocus(ownsFirstResponder: !isHiddenOrHasHiddenAncestor && ownsEditor,
                               isKeyWindow: window?.isKeyWindow == true)
    }
    private var ownsEditor: Bool {
        guard let editor = currentEditor() else { return false }
        return window?.firstResponder === editor
    }
    func focusIfRequested() {
        guard model.focusRequest > 0, let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { return }
        if !ownsEditor { window.makeFirstResponder(self) }
        synchronizeFocus()
    }
    // Native SwiftUI tabs can fall back to the window's key-view loop while
    // mounting. Global search only takes focus for an explicit search request.
    override var canBecomeKeyView: Bool { false }
    override func becomeFirstResponder() -> Bool {
        guard model.focusRequest > 0 || ownsEditor else { return false }
        let became = super.becomeFirstResponder()
        if became {
            (NSApp.delegate as? AppDelegate)?.prepareSearch(in: store)
            // becomeFirstResponder runs before NSWindow commits its responder.
            DispatchQueue.main.async { [weak self] in self?.synchronizeFocus() }
        }
        return became
    }
    func endSearchEditing() {
        handlingSuggestionClick = false
        guard let window, ownsEditor || window.firstResponder === self else { return }
        window.makeFirstResponder(nil)
        guard let engine = store.active?.activeSession?.engine, engine.view.window === window else { return }
        if let native = engine as? NativeTabEngine { native.focus() }
        else { window.makeFirstResponder(engine.view) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if model.fieldFocus.field === self { model.dismiss(restoreFocus: false) }
    }
    func controlTextDidBeginEditing(_ notification: Notification) { synchronizeFocus() }
    func controlTextDidChange(_ notification: Notification) { synchronizeFocus(); model.query = stringValue }
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool { !handlingSuggestionClick }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)): model.dismiss()
        case #selector(NSResponder.moveDown(_:)):
            if !model.suggestions { model.begin() }
            model.move(1)
        case #selector(NSResponder.moveUp(_:)): model.move(-1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true { model.showResults() }
            else { model.activate() }
        default: return false
        }
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ownsEditor, event.keyCode == 36, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            model.showResults(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
