import AppKit
import SwiftUI

/// Per-pane tab strip — each split region renders its own. The "+" button
/// targets the pane it sits in.
///
/// Tabs compress like Safari's (TabStripLayout): natural widths while they
/// fit, then one shared width down to 80 pt with the selected tab at 200 pt,
/// then the row scrolls with edge counters. Every selection of a tab
/// (`activeTabId` or `revealSerial` change, rename start) brings it into view.
struct TabBarView: View {
    @Bindable var pane: Pane
    @Bindable var workspace: Workspace
    let store: WorkspaceStore
    var attention = AttentionSidebarModel.shared

    @State private var isAddMenuOpen = false
    /// Width of the scrolling area; 0 until laid out (hidden workspaces mount at .zero).
    @State private var viewport: CGFloat = 0
    @State private var position = ScrollPosition(edge: .leading)
    /// Scroll offset, pending reveal and frozen widths: read by actions, never
    /// observed, so scrolling does not re-render the tab rows.
    @State private var strip = TabStripScrollState()
    @State private var edges = TabStripEdgesModel()
    /// Bumped to re-render when frozen widths are released.
    @State private var frozenEpoch = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(pane: Pane, workspace: Workspace, store: WorkspaceStore,
         attention: AttentionSidebarModel = .shared, strip: TabStripScrollState = TabStripScrollState()) {
        self.pane = pane
        self.workspace = workspace
        self.store = store
        self.attention = attention
        _strip = State(initialValue: strip)
    }

    var body: some View {
        let _ = frozenEpoch
        #if DEBUG
        let _ = TabStripRenderCount.strips += 1
        #endif
        let layout = currentLayout(updatingFrozenWidths: true)
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TabStripMetrics.spacing) {
                    ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                        DraggableTabRow(
                            tab: tab,
                            pane: pane,
                            workspace: workspace,
                            store: store,
                            myIndex: index,
                            canCloseToRight: index < pane.tabs.count - 1,
                            attention: attention,
                            width: layout.widths.indices.contains(index) ? layout.widths[index] : nil,
                            compressed: layout.compressed.indices.contains(index) && layout.compressed[index]
                        )
                    }
                }
                .padding(.horizontal, TabStripMetrics.rowEdge)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in
                strip.offset = offset
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.width } action: { _, width in
                strip.contentWidth = width
                // A tab just added: the reveal waited for the content to grow.
                if strip.pendingReveal { scheduleReveal() }
            }
            .onScrollGeometryChange(for: TabStripEdges.self) { geometry in
                layout.edges(offset: geometry.contentOffset.x)
            } action: { _, value in
                edges.edges = value
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                let previous = viewport
                viewport = width
                if previous != width, !strip.frozen.isEmpty { releaseFrozenWidths() }
                if previous <= 0, width > 0 {
                    strip.instantReveal = true
                    scheduleReveal()
                }
            }
            .overlay {
                TabStripEdgeOverlay(model: edges, pane: pane, attention: attention, page: page)
            }
            .onHover { inside in
                strip.pointerInside = inside
                if !inside, !strip.frozen.isEmpty { releaseFrozenWidths() }
            }
            .background {
                // A mouse wheel only scrolls vertically; the strip turns it sideways.
                TabStripWheelForwarder { delta in
                    scroll(to: currentLayout().clampedOffset(strip.offset + delta), animated: false)
                }
            }

            // "+" and the pane controls stay outside the ScrollView: they never
            // scroll away with the tabs.
            addButton
                .padding(.leading, 2)
                .padding(.trailing, Theme.space1)
            paneButtons
        }
        .frame(height: Theme.contentHeaderHeight)
        .background {
            TabBarDoubleClickHandler {
                NSApplication.shared.keyWindow?.performZoom(nil)
            }
        }
        .onChange(of: pane.activeTabId, initial: true) { requestReveal() }
        .onChange(of: pane.revealSerial) { requestReveal() }
        .onChange(of: pane.activeTab?.nameEdit.isEditing == true) { _, editing in
            if editing { requestReveal() }
        }
        .onChange(of: store.activeWorkspaceId == workspace.id) { _, visible in
            // A hidden workspace keeps a stale frame, so no viewport change
            // announces it: becoming the visible one applies a pending reveal.
            guard visible else { return }
            strip.instantReveal = true
            scheduleReveal()
        }
    }

    /// The strip's layout for the current tabs, titles and viewport. The body
    /// also records the widths, freezing them when a tab closes under the pointer.
    private func currentLayout(updatingFrozenWidths: Bool = false) -> TabStripLayout {
        let measure = TabTitleMeasure.shared
        let activeIndex = pane.tabs.firstIndex { $0.id == pane.activeTabId }
        let tabs = pane.tabs.enumerated().map { index, tab in
            let isActive = index == activeIndex
            let renaming = tab.nameEdit.isEditing
            let titleWidth = measure.width(attention.tabTitle(tab), medium: isActive || renaming)
            return TabStripLayout.Tab(id: tab.id, natural: TabStripMetrics.natural(
                titleWidth: titleWidth, hasForward: isActive && AgentAnswerSource.supports(tab), renaming: renaming))
        }
        guard updatingFrozenWidths else {
            return TabStripLayout(tabs: tabs, activeIndex: activeIndex, viewport: viewport, frozen: strip.frozen)
        }
        let ids = tabs.map(\.id)
        if ids != strip.ids {
            let previous = Set(strip.ids), current = Set(ids)
            if !current.subtracting(previous).isEmpty {
                // A new tab gets its room at once.
                strip.frozen = [:]
            } else if !previous.subtracting(current).isEmpty, strip.pointerInside {
                // Safari: after a close under the pointer the remaining tabs keep
                // their widths, so the next close button lands under the pointer.
                strip.frozen = strip.widths.filter { current.contains($0.key) }
            }
            strip.ids = ids
        }
        let layout = TabStripLayout(tabs: tabs, activeIndex: activeIndex, viewport: viewport, frozen: strip.frozen)
        strip.widths = Dictionary(uniqueKeysWithValues: zip(ids, layout.widths))
        return layout
    }

    private func releaseFrozenWidths() {
        withAnimation(.easeOut(duration: TabStripMetrics.unfreezeDuration)) {
            strip.frozen = [:]
            frozenEpoch &+= 1
        }
    }

    private func requestReveal() {
        strip.pendingReveal = true
        scheduleReveal()
    }

    /// After this update's layout: the ScrollView knows the new content size.
    private func scheduleReveal() {
        DispatchQueue.main.async { applyPendingReveal() }
    }

    /// A reveal waits until the strip is laid out in the visible workspace;
    /// one applied as the strip appears (launch, workspace switch) is instant.
    private func applyPendingReveal() {
        guard viewport > 0, store.activeWorkspaceId == workspace.id else { return }
        let instant = strip.instantReveal
        strip.instantReveal = false
        guard strip.pendingReveal else { return }
        let layout = currentLayout()
        // The ScrollView has not grown to a just-added tab yet: scrolling now
        // would clamp short of it. The content-size change retries.
        if layout.contentWidth > layout.viewport, abs(layout.contentWidth - strip.contentWidth) > 0.5 {
            strip.instantReveal = instant
            return
        }
        strip.pendingReveal = false
        guard let index = pane.tabs.firstIndex(where: { $0.id == pane.activeTabId }),
              let target = layout.revealOffset(for: index, offset: strip.offset)
        else { return }
        scroll(to: target, animated: !instant)
    }

    private func page(_ direction: Int) {
        scroll(to: currentLayout().pageOffset(from: strip.offset, direction: direction), animated: true)
    }

    private func scroll(to x: CGFloat, animated: Bool) {
        if animated, !reduceMotion {
            withAnimation(.easeOut(duration: TabStripMetrics.revealDuration)) { position.scrollTo(x: x) }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(x: x) }
        }
    }

    /// Split-right / split-down buttons. Mirror ⌘D / ⌘⇧D exactly: Split
    /// Right is the `.horizontal` orientation (panes side by side), Split
    /// Down is `.vertical` (panes stacked) — same mapping as
    /// `AppDelegate.handleSplitRight` / `handleSplitDown`.
    private var paneButtons: some View {
        HStack(spacing: Theme.chromeControlSpacing) {
            HoverableIconButton(
                systemName: "square.split.2x1",
                fontSize: 12,
                size: Theme.chromeToolbarButtonSize,
                help: "Split Right (⌘D)"
            ) {
                store.splitPane(pane, orientation: .horizontal, in: workspace)
            }
            HoverableIconButton(
                systemName: "square.split.1x2",
                fontSize: 12,
                size: Theme.chromeToolbarButtonSize,
                help: "Split Down (⌘⇧D)"
            ) {
                store.splitPane(pane, orientation: .vertical, in: workspace)
            }
            if pane.tabs.isEmpty && workspace.root.hasMultiplePanes {
                HoverableIconButton(
                    systemName: "xmark",
                    fontSize: 12,
                    size: Theme.chromeToolbarButtonSize,
                    help: "Close pane"
                ) {
                    guard pane.tabs.isEmpty, workspace.root.hasMultiplePanes else { return }
                    store.focusPane(pane, in: workspace)
                    store.closePane(pane, in: workspace)
                }
                // Leave an 8pt gap after the split pair.
                .padding(.leading, Theme.space2 - Theme.chromeControlSpacing)
            }
        }
        .padding(.trailing, Theme.space2)
    }

    private var addButton: some View {
        AddTabButton(
            pane: pane,
            workspace: workspace,
            store: store,
            isMenuOpen: $isAddMenuOpen
        )
    }
}

/// Double-clicking the tab bar triggers macOS Zoom (filled screen, dock and
/// menu kept) — the same behavior as double-clicking the system title bar.
/// Capture it at the AppKit event boundary: a gesture recognizer attached to
/// SwiftUI's background host is not guaranteed to sit on the event-hit view,
/// so it can silently miss clicks from tab rows.
private struct TabBarDoubleClickHandler: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> AnchorView {
        AnchorView(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.action = action
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }
    }

    @MainActor
    final class AnchorView: NSView {
        private let coordinator: Coordinator
        private var monitor: Any?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard let self,
                      event.clickCount == 2,
                      event.window === self.window,
                      bounds.contains(convert(event.locationInWindow, from: nil))
                else { return event }
                coordinator.action()
                return event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { removeMonitor() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// `+` button doubling as the "drop at end" target — dragging a tab here
/// (from this pane or another) appends it after the last tab, which is
/// otherwise unreachable inside a horizontal `ScrollView` where there's no
/// flex space for a trailing drop zone.
struct AddTabButton: View {
    @Bindable var pane: Pane
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    @Binding var isMenuOpen: Bool
    var size: CGFloat = Theme.chromeToolbarButtonSize

    @State private var isTargeted = false

    var trigger: HoverableIconButton<AnyView> {
        HoverableIconButton(
            systemName: "plus",
            fontSize: 12,
            size: size,
            help: "New tab"
        ) {
            // The mouse picker must remain reachable even with a default.
            // ⌘T is the shortcut for opening that default immediately.
            isMenuOpen.toggle()
        }
    }

    var body: some View {
        trigger
        // Indicator sits in the gap just left of the `+` (offset by half its
        // hit-area), not on the button itself, so it reads as "tab will land
        // here, after the last one" rather than "drop on +".
        .dropIndicator(active: isTargeted, on: .leading, offset: -3)
        .attentionPopover(isPresented: $isMenuOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                // In an SSH workspace every choice opens on the remote — the
                // suffix keeps that from surprising anyone mid-click.
                let sshSuffix = workspace.sshRemoteHost == nil ? "" : " on SSH"
                ForEach(AgentTemplate.visibleOrdered(model: AgentPadSettingsModel.shared)) { template in
                    AgentPadMenuRow(
                        title: template.title + sshSuffix,
                        localizesTitle: false
                    ) {
                        AgentIconView(asset: template.iconAsset, fallbackSymbol: template.symbol, size: 16)
                    } action: {
                        store.addTab(in: workspace, pane: pane, template: template)
                        isMenuOpen = false
                    }
                }
            }
            .padding(Theme.space1)
            .frame(minWidth: 220)
            .background(Theme.chromeBackground)
        }
        .dropDestination(for: String.self) { dropped, _ in
            defer { store.draggingTabId = nil }
            guard let id = dropped.first.flatMap(UUID.init) else { return false }
            return withAnimation(.easeInOut(duration: 0.18)) {
                store.handleTabDrop(droppedId: id, to: pane, at: pane.tabs.count, in: workspace)
            }
        } isTargeted: { isTargeted = $0 }
    }
}

/// Wraps `TabBarItem` with drag source + drop target. Same-pane drops
/// reorder; cross-pane drops move the session into this pane, leaving an
/// emptied source pane available for another task. The 2pt indicator follows drag
/// direction — `leading` for left-of-target sources, `trailing` for
/// right-of-target — so the line always shows where the dropped tab lands.
private struct DraggableTabRow: View {
    @Bindable var tab: Session
    @Bindable var pane: Pane
    @Bindable var workspace: Workspace
    @Bindable var store: WorkspaceStore
    let myIndex: Int
    let canCloseToRight: Bool
    let attention: AttentionSidebarModel
    let width: CGFloat?
    let compressed: Bool

    @State private var isTargeted = false

    var body: some View {
        let originIndex: Int? = {
            guard let id = store.draggingTabId, id != tab.id else { return nil }
            return pane.tabs.firstIndex(where: { $0.id == id })
        }()
        let dragsRightward = (originIndex ?? Int.max) < myIndex
        let edge: Alignment = dragsRightward ? .trailing : .leading
        let isSelfDrag = store.draggingTabId == tab.id

        TabBarItem(
            tab: tab,
            store: store,
            isActive: pane.activeTabId == tab.id,
            canCloseToRight: canCloseToRight,
            onActivate: { store.activateTab(tab, in: workspace) },
            onClose: { ConfirmCloseTab.request(tab, in: workspace, store: store) },
            onCloseOthers: { store.closeOtherTabs(keeping: tab, in: workspace) },
            onCloseToRight: { store.closeTabsToRight(of: tab, in: workspace) },
            onDuplicate: { store.duplicateTab(tab, in: workspace) },
            onRename: { store.renameTab(tab, to: $0) },
            onSplit: { store.splitPane(pane, orientation: $0, in: workspace) },
            onMoveToNewWindow: { store.moveTabToNewWindow(tab.id) },
            onLastAnswer: { CompositionTabs.shared.forward(session: tab, store: store, copyOnly: $0) },
            attention: attention,
            width: width,
            compressed: compressed
        )
        .dropIndicator(active: isTargeted && !isSelfDrag, on: edge)
        .dropDestination(for: String.self) { dropped, _ in
            defer { store.draggingTabId = nil }
            guard let id = dropped.first.flatMap(UUID.init) else { return false }
            return withAnimation(.easeInOut(duration: 0.18)) {
                store.handleTabDrop(droppedId: id, to: pane, at: myIndex, in: workspace)
            }
        } isTargeted: { isTargeted = $0 }
    }
}

/// Non-observed per-strip state: written on every scroll frame and read only
/// by actions (reveal, paging, freezing), so it never invalidates the body.
@MainActor
final class TabStripScrollState {
    var offset: CGFloat = 0
    var contentWidth: CGFloat = 0
    var pendingReveal = false
    var instantReveal = false
    var pointerInside = false
    var ids: [UUID] = []
    var widths: [UUID: CGFloat] = [:]
    var frozen: [UUID: CGFloat] = [:]
}

/// Hidden-tab counts, observed only by the edge overlay.
@MainActor
@Observable
final class TabStripEdgesModel {
    var edges = TabStripEdges.none
}

/// Fades and counters over the edges of a scrolling strip (mockup f3): the
/// count of hidden tabs with the strongest mark among them; a click pages.
private struct TabStripEdgeOverlay: View {
    let model: TabStripEdgesModel
    let pane: Pane
    let attention: AttentionSidebarModel
    let page: (Int) -> Void

    var body: some View {
        let edges = model.edges
        ZStack {
            if edges.left > 0 {
                cap(TabStripEdgeSummary(side: .left, tabIDs: pane.tabs.prefix(edges.left).map(\.id),
                                        indicators: attention.tabIndicators, title: title))
            }
            if edges.right > 0 {
                cap(TabStripEdgeSummary(side: .right, tabIDs: pane.tabs.suffix(edges.right).map(\.id),
                                        indicators: attention.tabIndicators, title: title))
            }
        }
    }

    private func title(_ id: UUID) -> String {
        pane.tabs.first { $0.id == id }.map { attention.tabTitle($0) } ?? ""
    }

    private func cap(_ summary: TabStripEdgeSummary) -> some View {
        let leading = summary.side == .left
        let surface = Color(nsColor: Theme.terminalSurface)
        return ZStack(alignment: leading ? .leading : .trailing) {
            LinearGradient(stops: [.init(color: surface, location: 0),
                                   .init(color: surface, location: TabStripMetrics.fadeSolid / TabStripMetrics.fadeWidth),
                                   .init(color: surface.opacity(0), location: 1)],
                           startPoint: leading ? .leading : .trailing, endPoint: leading ? .trailing : .leading)
                .frame(width: TabStripMetrics.fadeWidth)
                .allowsHitTesting(false)
            TabStripEdgeChip(summary: summary) { page(leading ? -1 : 1) }
                .padding(leading ? .leading : .trailing, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: leading ? .leading : .trailing)
    }
}

private struct TabStripEdgeChip: View {
    let summary: TabStripEdgeSummary
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let leading = summary.side == .left
        let surface = Color(nsColor: Theme.terminalSurface)
        Button(action: action) {
            HStack(spacing: 3) {
                if leading { chevron("chevron.left") }
                if !leading { mark }
                Text(verbatim: "\(summary.count)")
                    .font(Theme.display(10.5, weight: .semibold))
                    .monospacedDigit()
                if leading { mark }
                if !leading { chevron("chevron.right") }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 34, minHeight: 24, maxHeight: 24)
            .foregroundStyle(isHovered ? Theme.chromeForeground : Theme.chromeMuted)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(surface)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.chromeForeground.opacity(isHovered ? 0.1 : 0)))
            }
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.chromeHairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay { TabStripChipWheelProbe() }
        .onHover { isHovered = $0 }
        .help(summary.help)
        .accessibilityLabel(summary.help)
    }

    @ViewBuilder private var mark: some View {
        if let indicator = summary.indicator {
            AttentionIndicatorView(indicator: indicator)
                .scaleEffect(12 / 14)
                .frame(width: 12, height: 12)
        }
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 8, weight: .bold))
    }
}

/// Marks an edge counter chip for the wheel forwarder: invisible to every hit
/// test except the forwarder's own probe, so clicks and hovers are untouched.
private struct TabStripChipWheelProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ nsView: Anchor, context: Context) {}

    @MainActor
    final class Anchor: NSView {
        static var probing = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            Self.probing && bounds.contains(convert(point, from: superview)) ? self : nil
        }
    }
}

/// Turns a vertical wheel over the strip into a sideways scroll (mockup f3:
/// «Колесо мыши прокручивает полосу вбок»). Horizontal gestures keep going
/// to the ScrollView. Observed at the AppKit event boundary like the
/// double-click handler; the anchor itself never takes hits.
struct TabStripWheelForwarder: NSViewRepresentable {
    let scrollBy: (CGFloat) -> Void

    func makeNSView(context: Context) -> AnchorView { AnchorView(scrollBy: scrollBy) }

    func updateNSView(_ nsView: AnchorView, context: Context) { nsView.scrollBy = scrollBy }

    @MainActor
    final class AnchorView: NSView {
        var scrollBy: (CGFloat) -> Void
        private var monitor: Any?
        /// A trackpad gesture that began over the strip: its later events and
        /// momentum stay with it wherever the pointer drifts, as a scroll view latches.
        private var ownsGesture = false

        init(scrollBy: @escaping (CGFloat) -> Void) {
            self.scrollBy = scrollBy
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { removeMonitor() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Consumes a mostly vertical wheel event over the strip.
        func handle(_ event: NSEvent) -> Bool {
            handle(window: event.window, location: event.locationInWindow, deltaX: event.scrollingDeltaX,
                   deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                   phase: event.phase, momentumPhase: event.momentumPhase)
        }

        func handle(window eventWindow: NSWindow?, location: NSPoint, deltaX: CGFloat, deltaY: CGFloat, precise: Bool,
                    phase: NSEvent.Phase = [], momentumPhase: NSEvent.Phase = []) -> Bool {
            guard eventWindow === window, !isHiddenOrHasHiddenAncestor else { return false }
            if phase.contains(.began) || phase.contains(.mayBegin) { ownsGesture = isTarget(location) }
            // A line wheel has no phases and is judged where it happens; a gesture
            // and its momentum belong to where the gesture began (the terminal's
            // momentum drifting over the strip stays the terminal's).
            let ours = phase.isEmpty && momentumPhase.isEmpty ? isTarget(location) : ownsGesture
            guard ours, abs(deltaY) > abs(deltaX) else { return false }
            // Line-based wheels report a few lines per notch.
            scrollBy(-(precise ? deltaY : deltaY * 10))
            return true
        }

        /// The strip's own scroll view is what the pointer is over, not a popup
        /// scrim or another overlay drawn above it.
        private func isTarget(_ location: NSPoint) -> Bool {
            guard bounds.contains(convert(location, from: nil)), let root = window?.contentView else { return false }
            TabStripChipWheelProbe.Anchor.probing = true
            let hit = root.hitTest(root.superview?.convert(location, from: nil) ?? location)
            TabStripChipWheelProbe.Anchor.probing = false
            // The edge counter chip lies inside the strip (mockup: inside .viewport);
            // a scrim above it hides its probe from the hit test.
            if hit is TabStripChipWheelProbe.Anchor { return true }
            guard let hit, let scroll = hit as? NSScrollView ?? hit.enclosingScrollView else { return false }
            // The anchor sits behind the ScrollView with the same frame.
            let frame = scroll.convert(scroll.bounds, to: nil), mine = convert(bounds, to: nil)
            return abs(frame.minX - mine.minX) < 1 && abs(frame.maxX - mine.maxX) < 1
                && abs(frame.minY - mine.minY) < 1 && abs(frame.maxY - mine.maxY) < 1
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
