import AppKit

/// Persisted preferences belong to one window. Temporary navigation never
/// changes these values, including when a narrow window overlays its panel.
struct LeftNavigationPreferences: Codable, Equatable {
    enum Panel: String, Codable, CaseIterable { case chat, files, team }
    var railVisible = true
    var panelVisible = true
    var panelContent = Panel.chat

    init(railVisible: Bool = true, panelVisible: Bool = true, panelContent: Panel = .chat) {
        self.railVisible = railVisible
        self.panelVisible = panelVisible
        self.panelContent = panelContent
    }

    private enum CodingKeys: String, CodingKey { case railVisible, panelVisible, panelContent }
    init(from decoder: Decoder) throws {
        // A malformed layout must not send an otherwise intact window into recovery.
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        railVisible = (try? values.decode(Bool.self, forKey: .railVisible)) ?? true
        panelVisible = (try? values.decode(Bool.self, forKey: .panelVisible)) ?? true
        panelContent = (try? values.decode(Panel.self, forKey: .panelContent)) ?? .chat
    }

    static func migrate(mode: SidebarMode?, content: SidebarContent?) -> Self {
        let mode = mode ?? .full
        return Self(railVisible: mode != .hidden, panelVisible: mode == .full,
                    panelContent: content.flatMap { Panel(rawValue: $0.rawValue) } ?? .chat)
    }

    var legacyMode: SidebarMode { panelVisible ? .full : railVisible ? .compact : .hidden }
    var legacySelectedContent: SidebarContent {
        panelVisible ? SidebarContent(rawValue: panelContent.rawValue)! : .workspaces
    }
}

struct LeftNavigationPresentation: Equatable {
    enum List: Equatable { case closed, expanded, peek }
    var list = List.closed
    var narrowPanelOpen = false
    var previewWorkspaceID: UUID?
    var dragPeek = false
    var isNarrow = false
    var expandedOverlays = false
    var query = ""
    var focusRevision = 0

    var obscuresContent: Bool {
        list == .peek || (list == .expanded && expandedOverlays) || narrowPanelOpen || previewWorkspaceID != nil
    }

    mutating func close() {
        list = .closed
        narrowPanelOpen = false
        previewWorkspaceID = nil
        dragPeek = false
        query = ""
    }
}

/// All widths include their separator. This same calculation drives drawing
/// and the native window minimum, with no IO or preference writes on resize.
struct LeftNavigationLayout: Equatable {
    static let railWidth: CGFloat = 58
    static let expandedWidth: CGFloat = 252
    static let peekWidth: CGFloat = 268
    static let defaultPanelWidth: CGFloat = 268
    static let narrowPanelWidth: CGFloat = 216
    static let narrowThreshold: CGFloat = 900

    let narrow: Bool
    let railWidth: CGFloat
    let dockedPanelWidth: CGFloat
    let listOverlayWidth: CGFloat
    let panelOverlayWidth: CGFloat
    var leadingWidth: CGFloat { railWidth + dockedPanelWidth }

    init(preferences: LeftNavigationPreferences, presentation: LeftNavigationPresentation,
         availableWidth: CGFloat, panelWidth: CGFloat, trailingWidth: CGFloat = 0,
         minimumTreeWidth: CGFloat = 200) {
        let baseRail = preferences.railVisible ? Self.railWidth : 0
        narrow = availableWidth < Self.narrowThreshold
            || availableWidth < baseRail + panelWidth + trailingWidth + minimumTreeWidth
        dockedPanelWidth = preferences.panelVisible && !narrow ? panelWidth : 0
        let expandedFits = availableWidth >= Self.expandedWidth + dockedPanelWidth + trailingWidth + minimumTreeWidth
        let expandedDocked = preferences.railVisible && presentation.list == .expanded && expandedFits
        railWidth = expandedDocked ? Self.expandedWidth : baseRail
        let overlay = presentation.list == .peek ? Self.peekWidth
            : presentation.list == .expanded && !expandedDocked ? Self.expandedWidth : 0
        listOverlayWidth = min(overlay, max(0, availableWidth - 16))
        panelOverlayWidth = narrow && presentation.narrowPanelOpen
            ? min(Self.narrowPanelWidth, max(0, availableWidth - baseRail - 16)) : 0
    }
}

extension WorkspaceStore {
    var panelIsPresented: Bool {
        navigationPresentation.isNarrow ? navigationPresentation.narrowPanelOpen : leftNavigation.panelVisible
    }

    var panelToggleTitle: String {
        if navigationPresentation.isNarrow {
            return navigationPresentation.narrowPanelOpen ? "Close Panel Overlay" : "Open Panel Overlay"
        }
        return leftNavigation.panelVisible ? "Hide Panel" : "Show Panel"
    }

    func toggleWorkspaceRail() {
        closeNavigation()
        leftNavigation.railVisible.toggle()
        scheduleSave()
    }

    func toggleNavigationPanel() {
        let wasOpen = panelIsPresented
        closeNavigation()
        if navigationPresentation.isNarrow {
            if !wasOpen { captureNavigationFocus(); navigationPresentation.narrowPanelOpen = true }
        } else {
            leftNavigation.panelVisible.toggle()
            scheduleSave()
        }
    }

    func selectNavigationPanel(_ panel: LeftNavigationPreferences.Panel, toggle: Bool = true) {
        let wasOpen = panelIsPresented && leftNavigation.panelContent == panel
        closeNavigation()
        navigationPanelChanged(to: panel)
        leftNavigation.panelContent = panel
        if navigationPresentation.isNarrow {
            if !toggle || !wasOpen { captureNavigationFocus(); navigationPresentation.narrowPanelOpen = true }
        } else {
            leftNavigation.panelVisible = !toggle || !wasOpen
        }
        scheduleSave()
    }

    func openWorkspaceList(forDrag: Bool = false) {
        captureNavigationFocus()
        navigationPresentation.close()
        navigationPresentation.list = leftNavigation.railVisible ? .expanded : .peek
        navigationPresentation.dragPeek = forDrag
        if !forDrag { navigationPresentation.focusRevision += 1 }
    }

    func updateNavigationGeometry(_ layout: LeftNavigationLayout) {
        if navigationPresentation.isNarrow != layout.narrow {
            navigationPresentation.isNarrow = layout.narrow
            if !layout.narrow { closeNavigation() }
        }
        navigationPresentation.expandedOverlays = layout.listOverlayWidth > 0
    }

    func captureNavigationFocus() {
        guard navigationReturnResponder == nil else { return }
        let responder = navigationWindow?.firstResponder
        // AppKit reuses a field editor for the rail search field. Remember
        // its owning control so closing navigation returns to the original editor.
        if let editor = responder as? NSTextView, editor.isFieldEditor,
           let control = editor.delegate as? NSView {
            navigationReturnResponder = control
        } else {
            navigationReturnResponder = responder
        }
    }

    func closeNavigation(restoreFocus: Bool = true) {
        navigationPresentation.close()
        let responder = navigationReturnResponder
        navigationReturnResponder = nil
        if restoreFocus, let responder, let view = responder as? NSView,
           view.window === navigationWindow, !view.isHiddenOrHasHiddenAncestor,
           view !== active?.activeSession?.engine.view {
            navigationWindow?.makeFirstResponder(responder)
        } else if restoreFocus, responder != nil {
            (navigationWindow?.windowController as? AgentPadWindowController)?.paneHost.restoreFocus()
        }
    }

    func requestRenameWorkspace(_ workspace: Workspace) {
        guard workspaces.contains(where: { $0 === workspace }) else { return }
        openWorkspaceList()
        pendingRenameWorkspace = workspace
        workspace.nameEdit.begin(workspace.customTitle ?? workspace.title)
    }

    /// A detached tab inherits preferences before its window is constructed.
    /// Search, hover, overlays and focus are deliberately fresh.
    func inheritNavigation(from source: WorkspaceStore) {
        leftNavigation = source.leftNavigation
        sidebarWidth = source.sidebarWidth
        chatSidebarPreferences = source.chatSidebarPreferences
        rightSidebarMode = source.rightSidebarMode
        rightSidebarContent = source.rightSidebarContent
        rightSidebarWidth = source.rightSidebarWidth
    }
}

@MainActor
enum NavigationPresentationGate {
    static let didChange = Notification.Name("AgentPadNavigationPresentationDidChange")
    private final class WindowReference {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    private static var overlays: [UUID: WindowReference] = [:]
    static func setOverlay(_ id: UUID, window: NSWindow?, presented: Bool) {
        let previous = overlays[id]?.window
        let next = presented ? window : nil
        guard previous !== next else {
            if next == nil { overlays[id] = nil }
            return
        }
        overlays[id] = next.map(WindowReference.init)
        if let previous { recheck(previous) }
        if let next { recheck(next) }
    }
    static func recheck(_ window: NSWindow?) {
        guard let window else { return }
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            AttentionLedger.shared.markFocusedAttentionViewed()
            NotificationCenter.default.post(name: didChange, object: window)
        }
    }
    static func obscures(_ window: NSWindow) -> Bool {
        if window.attachedSheet != nil || overlays.values.contains(where: { $0.window === window }) { return true }
        guard let store = (window.windowController as? AgentPadWindowController)?.store else { return false }
        return store.navigationPresentation.obscuresContent || store.search.suggestions
    }

    static func allowsAcknowledgement(_ view: NSView, appActive: Bool) -> Bool {
        guard appActive, let window = view.window, window.isKeyWindow, window.isVisible, !window.isMiniaturized,
              !obscures(window), !view.isHiddenOrHasHiddenAncestor, !view.frame.isEmpty, !view.visibleRect.isEmpty else { return false }
        return true
    }
}
