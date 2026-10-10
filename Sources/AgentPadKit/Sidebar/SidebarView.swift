import SwiftUI

/// Native hiding keeps SwiftUI state alive while removing every descendant
/// from hit testing, the key-view loop and accessibility navigation.
struct SidebarPanelHost: NSViewRepresentable {
    let store: WorkspaceStore
    let width: CGFloat
    let isOverlay: Bool
    let presented: Bool
    func makeNSView(context: Context) -> NSHostingView<SidebarView> {
        NSHostingView(rootView: SidebarView(store: store, width: width, isOverlay: isOverlay))
    }
    func updateNSView(_ view: NSHostingView<SidebarView>, context: Context) {
        view.rootView = SidebarView(store: store, width: width, isOverlay: isOverlay)
        if !presented, let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: view) {
            view.window?.makeFirstResponder(store.active?.activeSession?.engine.view)
        }
        view.isHidden = !presented
    }
}

/// The panel stays mounted while hidden so search, selection and scroll survive.
struct SidebarView: View {
    static let fullWidth: CGFloat = 220
    static let compactWidth: CGFloat = 52
    /// Ceiling for the user-draggable full-mode width (`fullWidth` is the
    /// floor — the sidebar only grows from its design width).
    static let maxWidth: CGFloat = 480

    /// Single source for the width policy — floor `fullWidth`, ceiling
    /// `maxWidth`, and whole points (fractional widths land row text on
    /// per-frame-shifting sub-pixel boundaries → the mono diff badges
    /// visibly shimmer during a drag). Shared by the drag gesture and the
    /// state.json restore path so the two can't diverge.
    static func clampWidth(_ width: CGFloat) -> CGFloat {
        width.isFinite ? min(max(width, fullWidth), maxWidth).rounded() : LeftNavigationLayout.defaultPanelWidth
    }

    // Trailing-edge resize drag (full mode only). Mirrors the split
    // divider's suspend pattern: begin once per drag (gated), capture the
    // engines so onEnded / the handle's onDisappear end the SAME set.
    @State private var resizeDragStartWidth: CGFloat?
    @State private var sidebarResizeSuspended = false
    @State private var sidebarSuspendedEngines: [any TerminalEngine] = []
    @Bindable var store: WorkspaceStore
    var width: CGFloat
    var isOverlay = false

    /// Invisible trailing-edge strip that widens the sidebar by drag —
    /// full mode only (compact is fixed, hidden is hidden). A width drag
    /// re-frames every libghostty NSView per frame → SIGWINCH storm (conda
    /// scrollback-wipe, issue #29) without the divider-style suspension.
    private var resizeHandle: some View {
        DividerHandle(orientation: .horizontal)
            .frame(width: 7)
            .gesture(resizeGesture)
            .onDisappear {
                // Backstop: ⌘⌃S mid-drag unmounts the handle before onEnded
                // can fire — end the captured engines so the suspension
                // refcount stays balanced (mirrors the split divider).
                resizeDragStartWidth = nil
                if sidebarResizeSuspended {
                    sidebarResizeSuspended = false
                    for engine in sidebarSuspendedEngines { engine.endSizePropagationSuspension() }
                    sidebarSuspendedEngines = []
                }
                store.endSidebarResize()
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if resizeDragStartWidth == nil {
                    resizeDragStartWidth = store.sidebarDisplayWidth
                    store.beginSidebarResize()
                }
                let proposed = (resizeDragStartWidth ?? store.sidebarDisplayWidth) + value.translation.width
                let clamped = store.sidebarContent == .chat
                    ? CGFloat(ChatSidebarPreferences.clampWidth(Double(proposed))) : Self.clampWidth(proposed)
                guard abs(clamped - store.sidebarDisplayWidth) > .ulpOfOne else { return }
                if !sidebarResizeSuspended {
                    sidebarResizeSuspended = true
                    sidebarSuspendedEngines = store.active?.root.allEngines ?? []
                    for engine in sidebarSuspendedEngines { engine.beginSizePropagationSuspension() }
                }
                store.setSidebarDisplayWidth(clamped)
            }
            .onEnded { _ in
                resizeDragStartWidth = nil
                // End + flush once — only when the engine's refcount hits 0
                // (a concurrent zoom / status-bar suspension flushes on ITS
                // own release).
                if sidebarResizeSuspended {
                    sidebarResizeSuspended = false
                    for engine in sidebarSuspendedEngines {
                        engine.endSizePropagationSuspension()
                        if !engine.suspendsSizePropagation { engine.flushSize() }
                    }
                    sidebarSuspendedEngines = []
                }
                store.endSidebarResize()
                store.flushPersistence()
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch store.leftNavigation.panelContent {
                case .chat:
                    ChatSidebarView(store: store, navigation: store.chatNavigation, model: ChatOrgCurrent.shared.model)
                case .files:
                    FileTreeView(store: store, model: store.fileTree)
                case .team:
                    TeamCallsSidebar()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if !store.leftNavigation.railVisible {
                ChatSidebarModePicker(store: store, compact: false, model: ChatOrgCurrent.shared.model)
            }
        }
        .frame(width: width)
        .glassChromeBackground()
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.chromeSeparator).frame(width: 1).allowsHitTesting(false)
            if !isOverlay { resizeHandle }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation panel")
    }
}
