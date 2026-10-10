import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    /// The window's persistent AppKit pane-tree host, owned by
    /// `AgentPadWindowController`. Passing the instance (instead of building it
    /// here) is what guarantees SwiftUI structure changes can never tear the
    /// terminal tree down — the representable always re-mounts the same view.
    let paneHost: PaneTreeHostView
    /// Narrow AppKit seam: the store remains the source of truth for sidebar
    /// state; the owning window controller only mirrors those widths into
    /// `NSWindow.minSize`. `expandIfNeeded` asks it to grow the window frame
    /// to the new minimum when it's narrower (mode toggles, pane-tree
    /// changes); drag-driven width changes pass `false` — the window must
    /// never jump while a sidebar drag is in flight. `animate` animates that
    /// expansion (mode toggles only).
    var onWindowLayoutChange: (_ expandIfNeeded: Bool, _ animate: Bool) -> Void = { _, _ in }

    var body: some View {
        VStack(spacing: 0) {
            topStrip
            Rectangle().fill(Theme.chromeSeparator).frame(height: 1)

            GeometryReader { geo in
                let layout = navigationLayout(width: geo.size.width)
                let panelShown = layout.dockedPanelWidth > 0 || layout.panelOverlayWidth > 0
                ZStack(alignment: .topLeading) {
                    mainPane
                        .frame(width: max(0, geo.size.width - layout.leadingWidth - trailingWidth), height: geo.size.height)
                        .offset(x: layout.leadingWidth)
                    if store.leftNavigation.railVisible {
                        WorkspaceRailView(store: store, width: layout.railWidth,
                                          expanded: layout.railWidth == LeftNavigationLayout.expandedWidth)
                    }
                    if store.rightSidebarMode != .hidden {
                        Rectangle().fill(Theme.chromeSeparator)
                            .frame(width: 1)
                            .offset(x: geo.size.width - trailingWidth)
                        AgentOverviewSidebar(store: store, mode: store.rightSidebarMode)
                            .frame(width: rightSidebarWidth)
                            .offset(x: geo.size.width - rightSidebarWidth)
                    }
                    if layout.listOverlayWidth > 0 || layout.panelOverlayWidth > 0 {
                        Color.black.opacity(0.12).contentShape(Rectangle())
                            .onTapGesture { store.closeNavigation() }
                            .accessibilityLabel("Close navigation overlay")
                            .zIndex(1)
                    }
                    // Stable identity and width while hidden preserve panel scroll and drafts.
                    SidebarPanelHost(store: store,
                                     width: layout.panelOverlayWidth > 0 ? layout.panelOverlayWidth : store.sidebarDisplayWidth,
                                     isOverlay: layout.panelOverlayWidth > 0, presented: panelShown)
                        .frame(width: layout.panelOverlayWidth > 0 ? layout.panelOverlayWidth : store.sidebarDisplayWidth,
                               height: geo.size.height)
                        .allowsHitTesting(panelShown)
                        .accessibilityHidden(!panelShown)
                        .offset(x: layout.railWidth)
                        .zIndex(layout.panelOverlayWidth > 0 ? 2 : 0)
                    if layout.listOverlayWidth > 0 {
                        WorkspaceRailView(store: store, width: layout.listOverlayWidth, expanded: true)
                            .shadow(color: .black.opacity(0.2), radius: 15, x: 4, y: 6)
                            .zIndex(2)
                    }
                }
                .onChange(of: layout, initial: true) { _, value in
                    store.updateNavigationGeometry(value)
                    onWindowLayoutChange(false, false)
                }
            }
        }
        .overlay(alignment: .top) {
            if store.search.suggestions {
                SearchSuggestionsView(model: store.search).frame(maxWidth: 600).padding(.horizontal, 20).padding(.top, 34)
            }
        }
        .glassWindowBackground(fallback: chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        .ignoresSafeArea(.all)
        .onChange(of: store.navigationPresentation.obscuresContent || store.search.suggestions) { _, _ in
            NavigationPresentationGate.recheck(store.navigationWindow)
        }
        .onChange(of: store.leftNavigation) { _, _ in
            onWindowLayoutChange(false, false)
        }
        .onChange(of: store.rightSidebarMode) { _, _ in
            onWindowLayoutChange(true, true)
        }
        .onChange(of: store.isSidebarResizing) { _, active in
            // Never expand the window during an interactive sidebar drag;
            // updating `minSize` is enough and avoids a per-frame window jump.
            if active { onWindowLayoutChange(false, false) }
        }
        .onChange(of: store.sidebarDisplayWidth) { _, _ in
            onWindowLayoutChange(false, false)
        }
        .onChange(of: store.rightSidebarWidth) { _, _ in
            onWindowLayoutChange(false, false)
        }
        .onChange(of: minimumTerminalTreeWidth) { _, _ in
            // Split/close/workspace-switch is discrete. Expand immediately:
            // unlike sidebar mode changes, split creation does not suspend
            // existing engines for an animation-wide SIGWINCH burst.
            // A smaller tree only relaxes the future resize limit.
            onWindowLayoutChange(true, false)
        }
    }
    private var hiddenRailIndicator: AttentionIndicator? {
        store.leftNavigation.railVisible ? nil : AttentionSidebarModel.shared.windowIndicators[store.windowID]
    }

    /// Top chrome strip. `window.isMovable = false` is set globally, so the
    /// `WindowDragHandle` background is the only place AppKit allows
    /// window dragging. The responsive `SearchTriggerPill` is scoped to the
    /// drag-handle area (not the whole strip), with an explicit safety gap
    /// from the controls on either side. It condenses before disappearing,
    /// so narrow windows keep a usable quick-open target whenever possible;
    /// `⌘P` + the File menu remain available when it is fully hidden.
    private var topStrip: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: Theme.topStripLeadingReservedWidth)
                .allowsHitTesting(false)
            HoverableIconButton(
                systemName: "rectangle.leadingthird.inset.filled",
                fontSize: 12, size: Theme.chromeToolbarButtonSize,
                help: store.leftNavigation.railVisible ? "Hide workspaces rail · ⌃⌘R" : "Show workspaces rail · ⌃⌘R"
            ) { store.toggleWorkspaceRail() }
            .accessibilityLabel(store.leftNavigation.railVisible ? "Hide workspaces rail" : "Show workspaces rail")
            .accessibilityValue(hiddenRailIndicator.map { "In workspaces of this window: " + $0.accessibleSummary } ?? "")
            .overlay(alignment: .topTrailing) {
                if let hiddenRailIndicator {
                    AttentionIndicatorView(indicator: hiddenRailIndicator)
                        .background(Theme.chromeBackground, in: Circle()).offset(x: 3, y: -2)
                }
            }
            .help((store.leftNavigation.railVisible ? "Hide workspaces rail · ⌃⌘R" : "Show workspaces rail · ⌃⌘R")
                + (hiddenRailIndicator.map { "\nIn workspaces of this window: " + $0.accessibleSummary } ?? ""))
            .onDrop(of: [.text], delegate: HiddenRailDrop(store: store))
            HoverableIconButton(
                systemName: "sidebar.left",
                fontSize: 12, size: Theme.chromeToolbarButtonSize,
                help: store.panelToggleTitle + " · ⌃⌘S"
            ) { store.toggleNavigationPanel() }
            .accessibilityLabel(store.panelToggleTitle)
            WindowDragHandle()
                .overlay {
                    GeometryReader { proxy in
                        if (AgentPadSettingsModel.shared.showSearchPill && proxy.size.width >= SearchTriggerPill.minimumContainerWidth) || store.search.focusRequest > 0 || store.search.fieldFocused {
                            SearchEverywhereField(store: store, model: store.search)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                    }
                }
            HStack(spacing: Theme.chromeControlSpacing) {
                OpenInButton(store: store)
                HoverableIconButton(
                    systemName: "sidebar.right",
                    fontSize: 12,
                    size: Theme.chromeToolbarButtonSize,
                    help: "Agent Panel"
                ) {
                    withAnimation(Theme.chromeTransition) {
                        store.setRightSidebarMode(store.rightSidebarMode.next)
                    }
                }
                InboxBell()
                // Rightmost on purpose: a status light lives in the corner —
                // like a hardware power LED — not mixed into content buttons.
                KeepAwakeButton()
            }
            .padding(.trailing, Theme.chromeBarEdgeInset)
        }
        .frame(height: 32)
    }

    private var mainPane: some View {
        // No `.id`, no conditional: the host view is permanent and handles
        // "no workspace" itself. The old `.id(workspace.id)` teardown/rebuild
        // per switch was the root of the mount-churn bug class (issues #8,
        // #24, workspace-switch flicker) — the AppKit host switches by
        // visibility instead.
        // AgentPad: file preview docked under the terminal.
        VStack(spacing: 0) {
            if let workspace = store.active {
                HStack(spacing: 6) {
                    Button { store.openWorkspaceList() } label: {
                        HStack(spacing: 6) {
                            Text(workspace.title).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9))
                        }.font(Theme.display(11, weight: .medium))
                    }.buttonStyle(.plain)
                        .help("Workspaces… · ⌥⌘0")
                        .accessibilityLabel("\(workspace.title), open workspace list")
                    Spacer(minLength: 0)
                }.padding(.horizontal, 12).frame(height: 26)
                    .foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
            }
            MainAreaWithPreview(store: store) {
                PaneTreeHostRepresentable(host: paneHost)
            }
        }
    }

    private var chromeBackground: Color {
        let color = store.active?.activeSession?.engine.backgroundColor ?? Theme.terminalSurface
        return Color(nsColor: color)
    }

    private var minimumTerminalTreeWidth: CGFloat {
        AgentPadWindowLayout.minimumTerminalTreeWidth(for: store.active?.root)
    }

    private func navigationLayout(width: CGFloat) -> LeftNavigationLayout {
        LeftNavigationLayout(preferences: store.leftNavigation, presentation: store.navigationPresentation,
                             availableWidth: width, panelWidth: store.sidebarDisplayWidth,
                             trailingWidth: trailingWidth, minimumTreeWidth: minimumTerminalTreeWidth)
    }

    private var rightSidebarWidth: CGFloat {
        switch store.rightSidebarMode {
        case .full: return store.rightSidebarWidth
        case .compact: return AgentOverviewSidebar.compactWidth
        case .hidden: return 0
        }
    }

    private var trailingWidth: CGFloat {
        rightSidebarWidth + (store.rightSidebarMode == .hidden ? 0 : 1)
    }
}
