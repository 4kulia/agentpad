import AgentPadQuietTestSupport
import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

/// The real TabBarView in a quiet off-screen host (no activation, alpha 0,
/// ignores mouse events): every selection path reveals the selected tab by
/// the rule, manual scrolling survives pane focus, hidden strips reveal
/// instantly once visible, and f1–f5 captures for the mockup comparison.
/// Run through scripts/test-quiet.py.
@MainActor
final class TabStripQuietRenderTests: XCTestCase {
    /// Mockup TABS titles, kinds and marks (docs/agentpad/mockups/tab-overflow.html).
    private static let mockup: [(title: String, agent: AgentTemplate?, mark: SessionAlertKind?)] = [
        ("agentpad", nil, nil), ("Публикация приложения в Apple Store", .claudeCode, .attention),
        ("Нативная лента чата — W11", .claudeCode, nil), ("fix-W10-jumps", .codex, .completed),
        ("#agentpad-dev", nil, nil), ("Рефакторинг TabBarView", .claudeCode, nil), ("Саша Петров", nil, nil),
        ("ssh prod-eu-1", nil, nil), ("Разбор падений Sentry за неделю", .claudeCode, .failure), ("Settings", nil, nil),
        ("Обзор PR #412: Telegram папки", .claudeCode, nil), ("#design", nil, nil),
        ("Проверка подписи DMG и Sparkle", .codex, nil), ("Миграция release-33", .claudeCode, nil),
        ("~/agentpad-attn", nil, nil), ("Лена Ким", nil, nil), ("Переводы zh-Hans", .claudeCode, nil),
        ("All sessions", nil, nil), ("Ревьюер: popups phase 3", .claudeCode, nil), ("#incidents", nil, nil),
        ("Sparkle 2.7: проверка обновления", .claudeCode, nil), ("zsh", nil, nil),
        ("codex: тесты TerminalLink", .codex, nil), ("Notifications", nil, nil), ("#release-1.3", nil, nil),
        ("Онбординг второго аккаунта Claude", .claudeCode, nil), ("Миша", nil, nil),
        ("Профилирование xctrace", .claudeCode, .completed), ("Search", nil, nil), ("Документация 1.3.0", .claudeCode, nil),
    ]

    @MainActor private final class Strip {
        let store: WorkspaceStore
        let workspace: Workspace
        let pane: Pane
        let state: TabStripScrollState
        let host: ChatQuietHost
        init(store: WorkspaceStore, workspace: Workspace, pane: Pane, state: TabStripScrollState, host: ChatQuietHost) {
            self.store = store; self.workspace = workspace; self.pane = pane; self.state = state; self.host = host
        }
        var scrollView: NSScrollView { Self.find(host.view)! }
        var offset: CGFloat { scrollView.contentView.bounds.origin.x }
        var viewport: CGFloat { scrollView.frame.width }
        /// Leading x of a tab in the viewport, from the widths the strip rendered.
        func leading(_ index: Int) -> CGFloat {
            var x = TabStripMetrics.rowEdge
            for tab in pane.tabs.prefix(index) { x += (state.widths[tab.id] ?? 0) + TabStripMetrics.spacing }
            return x - offset
        }
        func width(_ index: Int) -> CGFloat { state.widths[pane.tabs[index].id] ?? 0 }
        func scrollManually(to x: CGFloat) {
            scrollView.contentView.scroll(to: NSPoint(x: x, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        func close() { host.close(); store.terminate() }
        var forwarder: TabStripWheelForwarder.AnchorView? { Self.find(host.view) }
        static func find<T: NSView>(_ view: NSView) -> T? {
            if let found = view as? T { return found }
            for child in view.subviews { if let found: T = find(child) { return found } }
            return nil
        }
        static func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for child in view.subviews { if let scroll = find(child) { return scroll } }
            return nil
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        // The app registers its bundled fonts at launch (AppDelegate); without
        // them tab titles render and measure in a fallback face.
        AgentPadFonts.registerOnce()
    }

    /// A store whose active workspace holds `count` mockup tabs.
    private func populate(_ store: WorkspaceStore, _ workspace: Workspace, count: Int) throws -> Pane {
        let pane = try XCTUnwrap(workspace.activePane)
        while pane.tabs.count < count {
            let spec = Self.mockup[pane.tabs.count]
            _ = store.addTab(in: workspace, pane: pane, template: spec.agent ?? .terminal)
        }
        for (index, tab) in pane.tabs.enumerated() { _ = store.renameTab(tab, to: Self.mockup[index].title) }
        return pane
    }

    /// - Parameter scrim: covers the strip like PopupHost's scrim (Tabs/PopupHost.swift).
    private func makeStrip(count: Int, active: Int, width: CGFloat = 1_000, dark: Bool = true,
                           attention: AttentionSidebarModel = .shared, reduceMotion: Bool = false,
                           scrim: Bool = false) async throws -> Strip {
        let store = makeTestStore()
        let workspace = try XCTUnwrap(store.active)
        let pane = try populate(store, workspace, count: count)
        store.activateTab(pane.tabs[active], in: workspace)
        let state = TabStripScrollState()
        let view = TabBarView(pane: pane, workspace: workspace, store: store, attention: attention, strip: state)
            .environment(\._accessibilityReduceMotion, reduceMotion)
            .frame(width: width, height: Theme.contentHeaderHeight)
            .background(Color(nsColor: Theme.terminalSurface))
            .overlay {
                if scrim {
                    Button {} label: { Color.black.opacity(0.48).contentShape(Rectangle()) }.buttonStyle(.plain)
                }
            }
        let host = ChatQuietHost(content: AnyView(view), dark: dark, width: width, height: Theme.contentHeaderHeight)
        let strip = Strip(store: store, workspace: workspace, pane: pane, state: state, host: host)
        try await settle(strip, seconds: 0.4)
        return strip
    }

    private func settle(_ strip: Strip, seconds: Double = 0) async throws {
        try await strip.host.settle()
        if seconds > 0 { try await Task.sleep(for: .seconds(seconds)); try await strip.host.settle() }
    }

    private func assertRevealed(_ strip: Strip, _ index: Int, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let leading = strip.leading(index), trailing = leading + strip.width(index)
        // At the row's ends the strip cannot scroll further: the tab keeps the row edge instead.
        let atStart = strip.offset < 0.5
        let atEnd = strip.leading(strip.pane.tabs.count - 1) + strip.width(strip.pane.tabs.count - 1)
            + TabStripMetrics.rowEdge <= strip.viewport + 0.5
        XCTAssertGreaterThanOrEqual(leading, atStart ? TabStripMetrics.rowEdge - 0.5 : TabStripMetrics.revealMargin - 0.5,
                                    message, file: file, line: line)
        XCTAssertLessThanOrEqual(trailing, atEnd ? strip.viewport - TabStripMetrics.rowEdge + 0.5
                                 : strip.viewport - TabStripMetrics.revealMargin + 0.5, message, file: file, line: line)
    }

    // MARK: Selection paths reveal

    func testEverySelectionPathRevealsTheSelectedTab() async throws {
        let strip = try await makeStrip(count: 30, active: 0)
        defer { strip.close() }
        XCTAssertTrue(APQuietIsEnabled())
        XCTAssertEqual(strip.offset, 0)

        // Sidebar / popup / tab click: activateTab.
        strip.store.activateTab(strip.pane.tabs[24], in: strip.workspace)
        try await settle(strip, seconds: 0.4)
        assertRevealed(strip, 24, "activateTab")

        // ⌘-number: AppDelegate selects pane.tabs[index] through activateTab.
        strip.store.activateTab(strip.pane.tabs[2], in: strip.workspace)
        try await settle(strip, seconds: 0.4)
        assertRevealed(strip, 2, "⌘3")

        // ⌃Tab.
        strip.store.cycleTab(in: strip.workspace, direction: -1)
        try await settle(strip, seconds: 0.4)
        assertRevealed(strip, 1, "cycleTab")

        // A new tab (⌘T, "+", templates) lands at the end and is revealed.
        let added = strip.store.addTab(in: strip.workspace, pane: strip.pane)
        try await settle(strip, seconds: 0.4)
        XCTAssertEqual(strip.pane.activeTabId, added.id)
        assertRevealed(strip, strip.pane.tabs.count - 1, "addTab")

        // A tab dropped on "+" from another pane lands at the end, selected and in view.
        let other = try XCTUnwrap(strip.store.splitPane(strip.pane, orientation: .horizontal, in: strip.workspace))
        let moved = other.tabs.last ?? strip.store.addTab(in: strip.workspace, pane: other)
        strip.store.activateTab(strip.pane.tabs[0], in: strip.workspace)
        try await settle(strip, seconds: 0.4)
        XCTAssertTrue(strip.store.handleTabDrop(droppedId: moved.id, to: strip.pane, at: strip.pane.tabs.count, in: strip.workspace))
        try await settle(strip, seconds: 0.4)
        XCTAssertEqual(strip.pane.tabs.last?.id, moved.id)
        XCTAssertEqual(strip.pane.activeTabId, moved.id)
        assertRevealed(strip, strip.pane.tabs.count - 1, "drop on +")
    }

    func testManualScrollSurvivesPaneFocusAndTitleChangesButNotReselection() async throws {
        let strip = try await makeStrip(count: 30, active: 3)
        defer { strip.close() }
        strip.scrollManually(to: 900)
        try await settle(strip, seconds: 0.1)
        XCTAssertEqual(strip.offset, 900)

        // Terminal click / right-click / terminal focus: pane focus, no reveal.
        strip.store.focusPaneTab(strip.pane.tabs[3], in: strip.workspace)
        _ = strip.store.renameTab(strip.pane.tabs[3], to: "Миграция release-34")
        _ = strip.store.renameTab(strip.pane.tabs[20], to: "Sparkle 2.8")
        try await settle(strip, seconds: 0.4)
        XCTAssertEqual(strip.offset, 900, "pane focus and title changes keep the manual scroll")

        // Selecting the already selected tab again (sidebar, ⌘4, Attention) brings it back.
        strip.store.activateTab(strip.pane.tabs[3], in: strip.workspace)
        try await settle(strip, seconds: 0.4)
        assertRevealed(strip, 3, "re-selection")

        // Rename (double click or tab menu) reveals the renamed tab.
        strip.scrollManually(to: 1_200)
        try await settle(strip, seconds: 0.1)
        strip.pane.tabs[3].nameEdit.begin("Миграция")
        try await settle(strip, seconds: 0.4)
        assertRevealed(strip, 3, "rename")
        XCTAssertGreaterThanOrEqual(strip.width(3), TabStripMetrics.activeMinimum)
        strip.pane.tabs[3].nameEdit.handle(.escape) { _ in nil }
    }

    func testRevealIsInstantUnderReduceMotion() async throws {
        let strip = try await makeStrip(count: 30, active: 0, reduceMotion: true)
        defer { strip.close() }
        strip.store.activateTab(strip.pane.tabs[26], in: strip.workspace)
        // One settle (70 ms) is well inside the 0.22 s animation: only an instant scroll is done by now.
        try await settle(strip)
        assertRevealed(strip, 26, "reduce motion")
    }

    // MARK: Hidden strips (review B1, R2-S1)

    func testLaunchRestoreRevealsInstantlyOnceLaidOut() async throws {
        let store = makeTestStore()
        let workspace = try XCTUnwrap(store.active)
        let pane = try populate(store, workspace, count: 30)
        store.activateTab(pane.tabs[24], in: workspace)
        let state = TabStripScrollState()
        let host = ChatQuietHost(content: AnyView(TabBarView(pane: pane, workspace: workspace, store: store, strip: state)
            .frame(maxWidth: .infinity).frame(height: Theme.contentHeaderHeight)), dark: true, width: 0, height: Theme.contentHeaderHeight)
        let strip = Strip(store: store, workspace: workspace, pane: pane, state: state, host: host)
        defer { strip.close() }
        try await settle(strip, seconds: 0.2)
        XCTAssertTrue(state.pendingReveal, "a zero-width strip keeps the reveal pending")
        host.window.setContentSize(NSSize(width: 1_000, height: Theme.contentHeaderHeight))
        try await settle(strip)
        assertRevealed(strip, 24, "launch restore, instant")
        XCTAssertFalse(state.pendingReveal)
    }

    func testSwitchIntoAHiddenWorkspaceWithAStaleFrameRevealsInstantly() async throws {
        let store = makeTestStore()
        let visible = try XCTUnwrap(store.active)
        let hidden = store.addWorkspace(activate: false)
        let pane = try populate(store, hidden, count: 30)
        store.activateWorkspace(visible)
        let state = TabStripScrollState()
        // The hidden workspace's strip keeps a non-zero (stale) frame.
        let host = ChatQuietHost(content: AnyView(TabBarView(pane: pane, workspace: hidden, store: store, strip: state)
            .frame(width: 1_000, height: Theme.contentHeaderHeight)), dark: true, width: 1_000, height: Theme.contentHeaderHeight)
        let strip = Strip(store: store, workspace: hidden, pane: pane, state: state, host: host)
        defer { strip.close() }
        try await settle(strip, seconds: 0.2)
        strip.scrollManually(to: 0)
        // TabRouter.swift:134-136 / AgentProfileActions: select into the hidden workspace, then switch.
        store.activateTab(pane.tabs[24], in: hidden)
        try await settle(strip, seconds: 0.3)
        XCTAssertEqual(strip.offset, 0, "nothing scrolls while the workspace is hidden")
        XCTAssertTrue(state.pendingReveal)
        store.activateWorkspace(hidden)
        try await settle(strip)
        assertRevealed(strip, 24, "workspace switch, instant")
    }

    // MARK: Frozen widths

    func testCloseUnderThePointerKeepsTheNextTabInPlace() async throws {
        let strip = try await makeStrip(count: 12, active: 2, width: 1_340)
        defer { strip.close() }
        strip.state.pointerInside = true
        let closedLeading = strip.leading(5), closedWidth = strip.width(5), nextWidth = strip.width(6)
        XCTAssertEqual(closedWidth, nextWidth, "12 tabs in a 1,240 pt viewport share one level")
        strip.store.closeTab(strip.pane.tabs[5], in: strip.workspace)
        try await settle(strip, seconds: 0.1)
        XCTAssertEqual(strip.pane.tabs.count, 11)
        XCTAssertFalse(strip.state.frozen.isEmpty)
        // The next tab moves into the closed one's place at the same width, so its
        // close button (trailing end) is where the pointer already is.
        XCTAssertEqual(strip.leading(5), closedLeading, accuracy: 0.5)
        XCTAssertEqual(strip.leading(5) + strip.width(5), closedLeading + closedWidth, accuracy: 0.5)
        // Without the pointer the remaining tabs widen at once.
        strip.state.frozen = [:]
        strip.state.pointerInside = false
        strip.store.closeTab(strip.pane.tabs[5], in: strip.workspace)
        try await settle(strip, seconds: 0.3)
        XCTAssertTrue(strip.state.frozen.isEmpty)
        XCTAssertGreaterThan(strip.width(5), closedWidth)
    }

    // MARK: Wheel

    func testVerticalWheelScrollsTheStripSideways() async throws {
        let strip = try await makeStrip(count: 30, active: 0)
        defer { strip.close() }
        let forwarder = try XCTUnwrap(strip.forwarder)
        let inside = forwarder.convert(NSPoint(x: forwarder.bounds.midX, y: forwarder.bounds.midY), to: nil)
        // A line-based mouse wheel notch down (3 lines) over the strip.
        XCTAssertTrue(forwarder.handle(window: strip.host.window, location: inside, deltaX: 0, deltaY: -3, precise: false))
        try await settle(strip, seconds: 0.2)
        XCTAssertEqual(strip.offset, 30, "a mouse wheel scrolls the strip sideways (mockup f3)")
        // Trackpad pixels pass as they are; scrolling up goes back.
        XCTAssertTrue(forwarder.handle(window: strip.host.window, location: inside, deltaX: 0, deltaY: 12, precise: true))
        try await settle(strip, seconds: 0.2)
        XCTAssertEqual(strip.offset, 18)
        // A horizontal gesture is the ScrollView's own; another window or a point outside is ignored.
        XCTAssertFalse(forwarder.handle(window: strip.host.window, location: inside, deltaX: -40, deltaY: 5, precise: true))
        XCTAssertFalse(forwarder.handle(window: nil, location: inside, deltaX: 0, deltaY: -3, precise: false))
        XCTAssertFalse(forwarder.handle(window: strip.host.window, location: NSPoint(x: -5, y: -5), deltaX: 0, deltaY: -3, precise: false))
        XCTAssertEqual(strip.offset, 18)
    }

    /// The wheel goes to the strip only when the strip is what the pointer is
    /// over and the gesture began there (review-1 S1).
    func testWheelLeavesOverlaysAndForeignGesturesAlone() async throws {
        // A popup's scrim over the strip takes the wheel, line and trackpad alike.
        let covered = try await makeStrip(count: 30, active: 0, scrim: true)
        let coveredForwarder = try XCTUnwrap(covered.forwarder)
        let coveredPoint = coveredForwarder.convert(NSPoint(x: coveredForwarder.bounds.midX, y: coveredForwarder.bounds.midY), to: nil)
        XCTAssertFalse(coveredForwarder.handle(window: covered.host.window, location: coveredPoint, deltaX: 0, deltaY: -3, precise: false))
        XCTAssertFalse(coveredForwarder.handle(window: covered.host.window, location: coveredPoint, deltaX: 0, deltaY: 0, precise: true, phase: .began))
        XCTAssertFalse(coveredForwarder.handle(window: covered.host.window, location: coveredPoint, deltaX: 0, deltaY: -6, precise: true, phase: .changed))
        try await settle(covered, seconds: 0.2)
        XCTAssertEqual(covered.offset, 0, "the strip under a scrim does not scroll")
        // Nor does the counter chip under the scrim.
        let coveredChip = NSPoint(x: coveredPoint.x + coveredForwarder.bounds.width / 2 - 6 - 17, y: coveredPoint.y)
        XCTAssertFalse(coveredForwarder.handle(window: covered.host.window, location: coveredChip, deltaX: 0, deltaY: -3, precise: false))
        covered.close()

        let strip = try await makeStrip(count: 30, active: 0)
        defer { strip.close() }
        let forwarder = try XCTUnwrap(strip.forwarder)
        let window = strip.host.window
        let inside = forwarder.convert(NSPoint(x: forwarder.bounds.midX, y: forwarder.bounds.midY), to: nil)
        let elsewhere = NSPoint(x: inside.x, y: -20)
        // Momentum of a gesture that began elsewhere (the terminal) drifts over the strip.
        XCTAssertFalse(forwarder.handle(window: window, location: elsewhere, deltaX: 0, deltaY: 0, precise: true, phase: .began))
        XCTAssertFalse(forwarder.handle(window: window, location: inside, deltaX: 0, deltaY: -6, precise: true, phase: .changed))
        XCTAssertFalse(forwarder.handle(window: window, location: inside, deltaX: 0, deltaY: -6, precise: true, phase: .ended))
        XCTAssertFalse(forwarder.handle(window: window, location: inside, deltaX: 0, deltaY: -4, precise: true, momentumPhase: .began))
        XCTAssertFalse(forwarder.handle(window: window, location: inside, deltaX: 0, deltaY: -4, precise: true, momentumPhase: .changed))
        try await settle(strip, seconds: 0.2)
        XCTAssertEqual(strip.offset, 0, "a foreign gesture and its momentum leave the strip alone")
        // A gesture that began over the strip keeps it through its momentum, as a scroll view latches.
        XCTAssertFalse(forwarder.handle(window: window, location: inside, deltaX: 0, deltaY: 0, precise: true, phase: .began))
        XCTAssertTrue(forwarder.handle(window: window, location: inside, deltaX: 0, deltaY: -6, precise: true, phase: .changed))
        try await settle(strip, seconds: 0.1)
        XCTAssertTrue(forwarder.handle(window: window, location: elsewhere, deltaX: 0, deltaY: -4, precise: true, momentumPhase: .changed))
        try await settle(strip, seconds: 0.2)
        XCTAssertEqual(strip.offset, 10)
        // A line wheel has no phases: it is judged where it happens.
        XCTAssertTrue(forwarder.handle(window: window, location: inside, deltaX: 0, deltaY: -1, precise: false))
        try await settle(strip, seconds: 0.1)
        XCTAssertFalse(forwarder.handle(window: window, location: elsewhere, deltaX: 0, deltaY: -1, precise: false))
        try await settle(strip, seconds: 0.2)
        XCTAssertEqual(strip.offset, 20)
    }

    /// The 34-pt edge counter chip is part of the strip: a wheel over it scrolls
    /// (mockup: the chip sits inside .viewport, onwheel on the viewport) (review-2 F1).
    func testWheelOverTheEdgeChipScrollsTheStrip() async throws {
        let strip = try await makeStrip(count: 30, active: 0)
        defer { strip.close() }
        let forwarder = try XCTUnwrap(strip.forwarder)
        let window = strip.host.window
        let mid = forwarder.convert(NSPoint(x: forwarder.bounds.midX, y: forwarder.bounds.midY), to: nil)
        // The right chip: 6 pt from the trailing edge, 34 pt wide at least.
        let chip = NSPoint(x: mid.x + forwarder.bounds.width / 2 - 6 - 17, y: mid.y)
        XCTAssertTrue(forwarder.handle(window: window, location: chip, deltaX: 0, deltaY: -3, precise: false))
        try await settle(strip, seconds: 0.2)
        XCTAssertEqual(strip.offset, 30, "a wheel over the chip scrolls the strip")
        // A trackpad gesture beginning over the chip is the strip's too.
        XCTAssertFalse(forwarder.handle(window: window, location: chip, deltaX: 0, deltaY: 0, precise: true, phase: .began))
        XCTAssertTrue(forwarder.handle(window: window, location: chip, deltaX: 0, deltaY: -6, precise: true, phase: .changed))
        try await settle(strip, seconds: 0.2)
        XCTAssertEqual(strip.offset, 36)
    }

    // MARK: Scrolling does not re-render rows (plan Acceptance 8)

    func testScrollingDoesNotReRenderTabRows() async throws {
        let strip = try await makeStrip(count: 30, active: 0)
        defer { strip.close() }
        let forwarder = try XCTUnwrap(strip.forwarder)
        let inside = forwarder.convert(NSPoint(x: forwarder.bounds.midX, y: forwarder.bounds.midY), to: nil)
        TabStripRenderCount.rows = 0
        TabStripRenderCount.strips = 0
        // Trackpad / scroller: the clip view moves, as a horizontal gesture moves it.
        for step in 1...40 {
            strip.scrollManually(to: CGFloat(step) * 9)
            try await strip.host.settle()
        }
        XCTAssertEqual(strip.offset, 360)
        XCTAssertEqual(TabStripRenderCount.rows, 0, "trackpad scrolling re-rendered tab rows")
        XCTAssertEqual(TabStripRenderCount.strips, 0, "trackpad scrolling re-rendered the strip")
        // Mouse wheel through the forwarder (ScrollPosition): rows stay as they are.
        for _ in 1...40 {
            XCTAssertTrue(forwarder.handle(window: strip.host.window, location: inside, deltaX: 0, deltaY: -6, precise: true))
            try await strip.host.settle()
        }
        XCTAssertEqual(strip.offset, 600)
        XCTAssertEqual(TabStripRenderCount.rows, 0, "wheel scrolling re-rendered tab rows")
    }

    // MARK: Compressed titles (review-1 B1)

    /// At 80 pt every mockup title shows at least one letter before "…"
    /// (mockup f3/f5: «иконка, 3–4 буквы и «…»»).
    func testEveryMockupTitleShowsALetterAt80Points() async throws {
        let store = makeTestStore()
        let workspace = try XCTUnwrap(store.active)
        let pane = try populate(store, workspace, count: Self.mockup.count)
        let ellipsis = store.addTab(in: workspace, pane: pane)
        _ = store.renameTab(ellipsis, to: "…")
        defer { store.terminate() }
        /// Rightmost ink, in points, of one inactive 80-pt tab drawn 10 pt from the left.
        func rightmostInk(_ tab: Session) async throws -> CGFloat {
            let item = TabBarItem(tab: tab, store: store, isActive: false, canCloseToRight: false,
                                  onActivate: {}, onClose: {}, onCloseOthers: {}, onCloseToRight: {}, onDuplicate: {},
                                  onRename: { _ in }, onSplit: { _ in }, onMoveToNewWindow: {}, width: 80, compressed: true)
                .padding(10).background(Color(nsColor: Theme.terminalSurface))
            let host = ChatQuietHost(content: AnyView(item), dark: true, width: 100, height: 52)
            defer { host.close() }
            try await host.settle()
            let bitmap = try ChatTimelineCaptureColor.bitmap(host.view)
            let scale = CGFloat(bitmap.pixelsWide) / host.view.bounds.width
            let background = try XCTUnwrap(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
            func ink(_ x: Int) -> Bool {
                (0..<bitmap.pixelsHigh).contains { y in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                    return max(abs(color.redComponent - background.redComponent), abs(color.greenComponent - background.greenComponent),
                               abs(color.blueComponent - background.blueComponent)) > 0.15
                }
            }
            // The title slot: after padding, mark slot and icon, up to the tab's end.
            let first = Int(61 * scale), last = Int(90 * scale)
            let rightmost = (first..<last).last(where: ink) ?? first
            return CGFloat(rightmost) / scale
        }
        let reference = try await rightmostInk(ellipsis)
        XCTAssertGreaterThan(reference, 62, "the ellipsis alone draws")
        for (index, spec) in Self.mockup.enumerated() {
            let right = try await rightmostInk(pane.tabs[index])
            // One letter of Onest 12 is at least ~5 pt wide ("i" excluded by the mockup's titles).
            XCTAssertGreaterThan(right, reference + 3, "«\(spec.title)» shows only «…» at 80 pt")
        }
    }

    // MARK: Captures for the mockup comparison

    func testCaptureMockupFramesDarkAndLight() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TAB_OVERFLOW_CAPTURES"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tab-overflow-captures").path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = AgentPadSettingsModel.shared
        let oldAppearance = (settings.appearanceMode, settings.lightTerminalThemeSelection,
                             settings.darkTerminalThemeSelection, settings.pairedThemeSchemaEnabled)
        settings.prepareFirstLaunchAppearance()
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        settings.darkTerminalThemeSelection = AgentPadSettingsModel.defaultDarkThemeSelection
        defer {
            if !oldAppearance.3 { settings.load() }
            settings.appearanceMode = oldAppearance.0
            settings.lightTerminalThemeSelection = oldAppearance.1
            settings.darkTerminalThemeSelection = oldAppearance.2
        }
        // Mockup viewports: f1/f2/f3 1240, f4 1048; "+" and pane buttons take 100 pt beside it.
        let frames: [(name: String, count: Int, active: Int, viewport: CGFloat, reveal: Int?)] = [
            ("f1-five", 5, 1, 1_240, nil), ("f2-twelve", 12, 2, 1_240, nil), ("f3-thirty", 30, 13, 1_240, nil),
            ("f4-before", 30, 0, 1_048, nil), ("f4-after", 30, 0, 1_048, 24),
        ]
        for dark in [true, false] {
            settings.appearanceMode = dark ? .dark : .light
            for frame in frames {
                let ledger = AttentionLedger()
                let store = makeTestStore()
                let workspace = try XCTUnwrap(store.active)
                let pane = try populate(store, workspace, count: frame.count)
                for (index, tab) in pane.tabs.enumerated() {
                    guard let mark = Self.mockup[index].mark,
                          let event = AttentionCoordinator.terminalEvent(tab, kind: mark, workspaceTitle: "agentpad",
                                                                         visibility: .init(channelIds: [])) else { continue }
                    ledger.upsert(event)
                }
                let attention = AttentionSidebarModel(ledger: ledger, storesProvider: { [store] in [store] })
                attention.refresh(ledger: ledger)
                store.activateTab(pane.tabs[frame.active], in: workspace)
                let state = TabStripScrollState()
                let width = frame.viewport + 100
                let view = TabBarView(pane: pane, workspace: workspace, store: store, attention: attention, strip: state)
                    .frame(width: width, height: Theme.contentHeaderHeight)
                    .background(Color(nsColor: Theme.terminalSurface))
                let host = ChatQuietHost(content: AnyView(view), dark: dark, width: width, height: Theme.contentHeaderHeight)
                let strip = Strip(store: store, workspace: workspace, pane: pane, state: state, host: host)
                defer { strip.close() }
                try await settle(strip, seconds: 0.4)
                if frame.name == "f3-thirty" {
                    // Mockup f3 shows #13 centred (its frame configuration).
                    strip.scrollManually(to: 582)
                    try await settle(strip, seconds: 0.2)
                }
                if let reveal = frame.reveal {
                    store.activateTab(pane.tabs[reveal], in: workspace)
                    try await settle(strip, seconds: 0.4)
                    assertRevealed(strip, reveal, frame.name)
                }
                XCTAssertEqual(abs(strip.viewport - frame.viewport) < 1, true, "\(frame.name) viewport \(strip.viewport)")
                let png = try XCTUnwrap(ChatTimelineCaptureColor.bitmap(host.view).representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("\(frame.name)-\(dark ? "dark" : "light").png"))
            }
            // f5: the compressed tab anatomy, 80 pt inactive with a mark and 200 pt selected.
            let store = makeTestStore()
            let workspace = try XCTUnwrap(store.active)
            let pane = try populate(store, workspace, count: 14)
            defer { store.terminate() }
            let anatomy = HStack(spacing: 24) {
                ForEach([13, 1, 2], id: \.self) { index in
                    TabBarItem(tab: pane.tabs[index], store: store, isActive: index == 2, canCloseToRight: false,
                               onActivate: {}, onClose: {}, onCloseOthers: {}, onCloseToRight: {}, onDuplicate: {},
                               onRename: { _ in }, onSplit: { _ in }, onMoveToNewWindow: {},
                               width: index == 2 ? 200 : 80, compressed: true)
                }
            }
            .padding(10)
            .background(Color(nsColor: Theme.terminalSurface))
            let host = ChatQuietHost(content: AnyView(anatomy), dark: dark, width: 440, height: 52)
            defer { host.close() }
            try await host.settle()
            let png = try XCTUnwrap(ChatTimelineCaptureColor.bitmap(host.view).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("f5-anatomy-\(dark ? "dark" : "light").png"))
        }
    }
}
