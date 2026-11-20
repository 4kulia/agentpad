import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

/// Width, reveal and edge rules of the compressing tab strip
/// (docs/agentpad/mockups/tab-overflow.html). Mockup-number cases feed the
/// mockup's own title widths (measured by its canvas in -apple-system 12 px),
/// never Onest, so they test the rule and not the font.
@MainActor
final class TabStripLayoutTests: XCTestCase {
    /// Mockup TABS: (regular width, medium width, agent-backed). Read from the
    /// mockup's `tw()` in headless Chrome (probe in the job's scratch folder).
    private static let mockupTitles: [(CGFloat, CGFloat, Bool)] = [
        (54, 55, false), (227, 232, true), (163, 166, true), (83, 86, true), (88, 90, false),
        (147, 151, true), (79, 80, false), (80, 82, false), (201, 205, true), (47, 49, false),
        (185, 189, true), (46, 47, false), (200, 203, true), (124, 127, true), (93, 95, false),
        (57, 58, false), (112, 114, true), (67, 69, false), (150, 153, true), (59, 61, false),
        (199, 204, true), (20, 21, false), (150, 154, true), (72, 74, false), (71, 72, false),
        (215, 219, true), (35, 36, false), (149, 152, true), (40, 41, false), (116, 119, true),
    ]

    private let ids = (0..<64).map { _ in UUID() }

    private func mockupTabs(_ count: Int, active: Int) -> [TabStripLayout.Tab] {
        (0..<count).map { index in
            let (regular, medium, agent) = Self.mockupTitles[index]
            let isActive = index == active
            return .init(id: ids[index], natural: TabStripMetrics.natural(
                titleWidth: isActive ? medium : regular, hasForward: isActive && agent, renaming: false))
        }
    }

    private func tabs(_ naturals: [CGFloat]) -> [TabStripLayout.Tab] {
        naturals.enumerated().map { .init(id: ids[$0.offset], natural: $0.element) }
    }

    // MARK: Natural width

    func testNaturalWidthMatchesTabBarItemChrome() {
        XCTAssertEqual(TabStripMetrics.natural(titleWidth: 54, hasForward: false, renaming: false), 144)
        XCTAssertEqual(TabStripMetrics.natural(titleWidth: 232, hasForward: true, renaming: false), 347)
        XCTAssertEqual(TabStripMetrics.natural(titleWidth: 53.2, hasForward: false, renaming: false), 144)
        // InlineNameField has minWidth 100: a renaming tab never gets narrower than that.
        XCTAssertEqual(TabStripMetrics.natural(titleWidth: 20, hasForward: false, renaming: true), 190)
        XCTAssertEqual(TabStripMetrics.natural(titleWidth: 20, hasForward: true, renaming: true), 215)
        XCTAssertEqual(TabStripMetrics.natural(titleWidth: 140, hasForward: false, renaming: true), 230)
    }

    // MARK: Widths

    func testFiveTabsKeepNaturalWidthsWithInactiveCapAt240() {
        // Mockup f1 "предлагается": viewport 1240, active #1 uncapped (347), #2 capped 253 → 240.
        let layout = TabStripLayout(tabs: mockupTabs(5, active: 1), activeIndex: 1, viewport: 1240)
        XCTAssertEqual(layout, TabStripLayout(
            widths: [144, 347, 240, 173, 178], caps: [144, 347, 240, 173, 178],
            positions: [10, 158, 509, 753, 930], compressed: [false, false, false, false, false],
            scrollMode: false, level: nil, contentWidth: 1118, viewport: 1240))
    }

    func testTwelveTabsAtMockupWidthShareOneLevelAndActiveKeeps200() {
        // Mockup f2 measured: viewport 1240, level 88, widths [88, 88, 200, 88 …].
        let layout = TabStripLayout(tabs: mockupTabs(12, active: 2), activeIndex: 2, viewport: 1240)
        XCTAssertEqual(layout.level, 88)
        XCTAssertFalse(layout.scrollMode)
        XCTAssertEqual(layout.widths, [88, 88, 200, 88, 88, 88, 88, 88, 88, 88, 88, 88])
        XCTAssertEqual(layout.compressed, Array(repeating: true, count: 12))
        XCTAssertLessThanOrEqual(layout.contentWidth, 1240)
    }

    func testShortTabsKeepTheirNaturalWidthUnderTheLevel() {
        // Level lands at 110: the 100 pt tab stays 100 and is not compressed.
        let layout = TabStripLayout(tabs: tabs([100, 300, 300, 300, 300]), activeIndex: 0, viewport: 20 + 16 + 100 + 4 * 110)
        XCTAssertEqual(layout.level, 110)
        XCTAssertEqual(layout.widths, [100, 110, 110, 110, 110])
        XCTAssertEqual(layout.compressed, [false, true, true, true, true])
    }

    func testThirtyTabsScrollAt80With200Active() {
        // Mockup f3 measured: viewport 1240, all 80, active #13 200, last x 2566. (The mockup
        // centres #13 by frame configuration; by the reveal rule #13 at 1102…1302 is partly
        // visible from offset 0, so the minimal shift is 1302 − (1240 − 48) = 110.)
        let layout = TabStripLayout(tabs: mockupTabs(30, active: 13), activeIndex: 13, viewport: 1240)
        XCTAssertTrue(layout.scrollMode)
        XCTAssertEqual(layout.level, 80)
        XCTAssertEqual(layout.widths, (0..<30).map { $0 == 13 ? 200 : 80 })
        XCTAssertEqual(layout.positions.last, 2566)
        XCTAssertEqual(layout.contentWidth, 2566 + 80 + 10)
        XCTAssertEqual(layout.revealOffset(for: 13, offset: 0), 110)
    }

    func testActiveTabNarrowerThan200KeepsItsNaturalWidthInScrollMode() {
        // Mockup f4 "после": #24 "#release-1.3" natural 162 < 200, viewport 1048.
        let layout = TabStripLayout(tabs: mockupTabs(30, active: 24), activeIndex: 24, viewport: 1048)
        XCTAssertEqual(layout.widths[24], 162)
        XCTAssertEqual(layout.positions.last, 2528)
        // Off-screen far right: centring would pass the end, so it clamps to M = 2618 − 1048.
        XCTAssertEqual(layout.revealOffset(for: 24, offset: 0), 1570)
    }

    func testActiveGetsTheRemainderWhenInactiveTabsFitAtTheirCaps() {
        // Σcap = 600 + 3·150 = 1050 > A = 900, f(240) = 450 + 240 = 690 ≤ A:
        // inactive tabs keep their caps and the active tab takes A − 450 = 450.
        let viewport: CGFloat = 900 + 20 + 12
        let layout = TabStripLayout(tabs: tabs([150, 600, 150, 150]), activeIndex: 1, viewport: viewport)
        XCTAssertEqual(layout.widths, [150, 450, 150, 150])
        XCTAssertEqual(layout.compressed, [false, true, false, false])
        XCTAssertEqual(layout.level, 240)
        XCTAssertFalse(layout.scrollMode)
        XCTAssertEqual(layout.contentWidth, viewport)
    }

    func testNoActiveTabCompressesEveryTabToTheLevel() {
        let layout = TabStripLayout(tabs: tabs([200, 200, 200]), activeIndex: nil, viewport: 20 + 8 + 300)
        XCTAssertEqual(layout.widths, [100, 100, 100])
        XCTAssertEqual(layout.level, 100)
    }

    func testEmptyStripHasOnlyItsEdges() {
        let layout = TabStripLayout(tabs: [], activeIndex: nil, viewport: 500)
        XCTAssertEqual(layout, TabStripLayout(widths: [], caps: [], positions: [], compressed: [],
            scrollMode: false, level: nil, contentWidth: 20, viewport: 500))
        XCTAssertNil(layout.revealOffset(for: 0, offset: 0))
        XCTAssertEqual(layout.edges(offset: 0), .none)
    }

    func testLevelEqualsFloorOfTheMockupBisectionOver1000RandomCases() {
        var generator = SeededGenerator(seed: 0x7AB5)
        for _ in 0..<1_000 {
            let count = Int.random(in: 1...40, using: &generator)
            let naturals = (0..<count).map { _ in CGFloat(Int.random(in: 100...420, using: &generator)) }
            let active = Bool.random(using: &generator) ? Int.random(in: 0..<count, using: &generator) : nil
            let viewport = CGFloat(Int.random(in: 200...3_000, using: &generator))
            let layout = TabStripLayout(tabs: tabs(naturals), activeIndex: active, viewport: viewport)
            let reference = Self.mockupLayout(naturals, active: active, viewport: viewport)
            let message = "naturals \(naturals) active \(String(describing: active)) viewport \(viewport)"
            XCTAssertEqual(layout.scrollMode, reference.scroll, message)
            XCTAssertEqual(layout.level, reference.level, message)
            // The remainder branch is a deliberate deviation (spec-table text over the JS cap).
            if !reference.remainderBranch { XCTAssertEqual(layout.widths, reference.widths, message) }
            XCTAssertTrue(layout.scrollMode || layout.contentWidth <= viewport + 0.001, message)
        }
    }

    // MARK: Positions and reveal

    func testPositionsStartAtTheRowEdgeAndStepByWidthPlusSpacing() {
        let layout = TabStripLayout(tabs: tabs([100, 120, 130]), activeIndex: 0, viewport: 1_000)
        XCTAssertEqual(layout.positions, [10, 114, 238])
        XCTAssertEqual(layout.contentWidth, 378)
    }

    private func scrolling(_ count: Int = 30, active: Int = 0, viewport: CGFloat = 1_000) -> TabStripLayout {
        TabStripLayout(tabs: tabs(Array(repeating: 300, count: count)), activeIndex: active, viewport: viewport)
    }

    func testRevealCentresATabOffScreenOnTheRight() {
        let layout = scrolling()
        // #20: x = 10 + 19·84 + 204 = 1810 (active #0 is 200 wide), centre → 1810 + 40 − 500.
        XCTAssertEqual(layout.positions[20], 1810)
        XCTAssertEqual(layout.revealOffset(for: 20, offset: 0), 1350)
    }

    func testRevealCentresATabOffScreenOnTheLeft() {
        let layout = scrolling()
        // #15 at x 1390 ends at 1470 < offset 1600: centre 1390 + 40 − 500.
        XCTAssertEqual(layout.positions[15], 1390)
        XCTAssertEqual(layout.revealOffset(for: 15, offset: 1_600), 930)
    }

    func testRevealClampsAtTheStartAndTheEnd() {
        let layout = scrolling()
        XCTAssertEqual(layout.revealOffset(for: 0, offset: 1_500), 0)
        let end = layout.contentWidth - 1_000
        XCTAssertEqual(layout.revealOffset(for: 29, offset: 0), end)
    }

    func testPartlyVisibleOnTheLeftShiftsMinimallyWith48Margin() {
        let layout = scrolling()
        // #10 at x 970; offset 950 → a = 20 → shift left by 28.
        XCTAssertEqual(layout.positions[10], 970)
        XCTAssertEqual(layout.revealOffset(for: 10, offset: 950), 922)
        // a = 47.6: inside 48 by 0.4 → still under the 0.5 pt dead band → no move.
        XCTAssertNil(layout.revealOffset(for: 10, offset: 922.4))
    }

    func testPartlyVisibleOnTheRightShiftsMinimallyWith48Margin() {
        let layout = scrolling()
        // #10 at x 970, width 80; offset 0 → b = 1050 > 952 → shift right by 98.
        XCTAssertEqual(layout.revealOffset(for: 10, offset: 0), 98)
        // Barely off-screen (b = 50 − 60 < 0 on the left) is centring, not a minimal shift.
        XCTAssertEqual(layout.revealOffset(for: 10, offset: 1_060), 970 + 40 - 500)
    }

    func testFullyVisibleTabDoesNotMove() {
        let layout = scrolling()
        XCTAssertNil(layout.revealOffset(for: 10, offset: 500))
        XCTAssertNil(layout.revealOffset(for: 0, offset: 0))
    }

    func testTabWiderThanTheMarginedViewportIsCentred() {
        // 300-wide active in a 380 viewport: 300 > 380 − 96, so centre even though it is visible.
        let layout = TabStripLayout(tabs: tabs([300, 300, 300, 300, 300, 300, 300]), activeIndex: 3, viewport: 380)
        XCTAssertTrue(layout.scrollMode)
        XCTAssertEqual(layout.widths[3], 200)
        let wide = TabStripLayout(widths: [80, 80, 300, 80], caps: [300, 300, 300, 300],
            positions: [10, 94, 178, 482], compressed: [true, true, false, true],
            scrollMode: true, level: 80, contentWidth: 572, viewport: 380)
        XCTAssertEqual(wide.revealOffset(for: 2, offset: 140), 178 + 150 - 190)
    }

    func testFittingStripNeverScrolls() {
        let layout = TabStripLayout(tabs: tabs([150, 150]), activeIndex: 1, viewport: 1_000)
        XCTAssertNil(layout.revealOffset(for: 0, offset: 0))
        XCTAssertNil(layout.revealOffset(for: 1, offset: 0))
    }

    func testPagingMovesByViewportMinus120AndClamps() {
        let layout = scrolling()
        XCTAssertEqual(layout.pageOffset(from: 0, direction: 1), 880)
        XCTAssertEqual(layout.pageOffset(from: 500, direction: -1), 0)
        XCTAssertEqual(layout.pageOffset(from: layout.contentWidth - 1_100, direction: 1), layout.contentWidth - 1_000)
    }

    // MARK: Edges

    func testEdgesCountHiddenTabsWithTwoPointTolerance() {
        let layout = scrolling()
        // Offset 1000: #9 (886…966) is hidden; #10 (970…1050) shows 50 pt → visible.
        // Right: #23 starts at 2062 ≥ 1000 + 998 → hidden; #22 at 1978 → visible.
        XCTAssertEqual(layout.edges(offset: 1_000), TabStripEdges(left: 10, right: 7))
        // #10 ends at 1050: with offset 1048 its visible part is 2 pt → counts as hidden.
        XCTAssertEqual(layout.edges(offset: 1_048).left, 11)
        XCTAssertEqual(layout.edges(offset: 1_047).left, 10)
        // Right: #k hidden when x − s ≥ V − 2.
        XCTAssertEqual(layout.edges(offset: 0), TabStripEdges(left: 0, right: 30 - 11))
        XCTAssertEqual(layout.edges(offset: 56).right, 30 - 11)
        XCTAssertEqual(layout.edges(offset: 57).right, 30 - 12)
    }

    func testNoEdgesOutsideScrollMode() {
        let layout = TabStripLayout(tabs: mockupTabs(12, active: 2), activeIndex: 2, viewport: 1240)
        XCTAssertEqual(layout.edges(offset: 200), .none)
    }

    func testEdgeSummaryCarriesTheStrongestHiddenMarkAndItsTitle() {
        func reason(_ id: String, _ kind: AttentionIndicator.Kind, _ tab: UUID) -> AttentionIndicator.Reason {
            .init(id: id, kind: kind, summary: id, titleTabID: tab)
        }
        let indicators: [UUID: AttentionIndicator] = [
            ids[1]: AttentionIndicator([reason("u1", .unread, ids[1])])!,
            ids[2]: AttentionIndicator([reason("f2", .finished, ids[2])])!,
            ids[4]: AttentionIndicator([reason("n4", .needsInput, ids[4])])!,
        ]
        let titles = [ids[1]: "#incidents", ids[2]: "Профилирование xctrace", ids[4]: "Публикация"]
        let right = TabStripEdgeSummary(side: .right, tabIDs: [ids[1], ids[2], ids[3]],
            indicators: indicators, title: { titles[$0] ?? "" })
        XCTAssertEqual(right.count, 3)
        XCTAssertEqual(right.indicator?.kind, .finished)
        XCTAssertEqual(right.indicator?.reasonIDs, ["f2", "u1"])
        XCTAssertEqual(right.help, "3 tabs hidden on the right · Профилирование xctrace — Turn finished — waiting for you")
        let left = TabStripEdgeSummary(side: .left, tabIDs: [ids[4], ids[5]], indicators: indicators, title: { titles[$0] ?? "" })
        XCTAssertEqual(left.indicator?.kind, .needsInput)
        XCTAssertEqual(left.help, "2 tabs hidden on the left · Публикация — Needs input or approval")
        let plain = TabStripEdgeSummary(side: .left, tabIDs: [ids[5]], indicators: indicators, title: { _ in "" })
        XCTAssertNil(plain.indicator)
        XCTAssertEqual(plain.help, "1 tab hidden on the left")
    }

    // MARK: Frozen widths

    func testFrozenWidthsOverrideComputedWidthsAndPositionsFollow() {
        let naturals: [CGFloat] = Array(repeating: 300, count: 6)
        let free = TabStripLayout(tabs: tabs(naturals), activeIndex: 0, viewport: 900)
        XCTAssertEqual(free.widths, [200, 132, 132, 132, 132, 132])
        let frozen = TabStripLayout(tabs: tabs(naturals), activeIndex: 0, viewport: 900,
            frozen: [ids[1]: 120, ids[2]: 120, UUID(): 50])
        XCTAssertEqual(frozen.widths, [200, 120, 120, 132, 132, 132])
        XCTAssertEqual(frozen.positions, [10, 214, 338, 462, 598, 734])
        XCTAssertEqual(frozen.compressed, [true, true, true, true, true, true])
        // A newly active frozen tab keeps its frozen width.
        let reactivated = TabStripLayout(tabs: tabs(naturals), activeIndex: 2, viewport: 900, frozen: [ids[2]: 120])
        XCTAssertEqual(reactivated.widths[2], 120)
        XCTAssertEqual(TabStripLayout(tabs: tabs(naturals), activeIndex: 0, viewport: 900, frozen: [:]), free)
    }

    // MARK: Measurement

    func testTitleMeasurementIsCachedPerTitleAndWeight() {
        let measure = TabTitleMeasure()
        let first = measure.width("Нативная лента чата — W11", medium: false)
        XCTAssertEqual(measure.cacheCount, 1)
        XCTAssertEqual(measure.width("Нативная лента чата — W11", medium: false), first)
        XCTAssertEqual(measure.cacheCount, 1)
        XCTAssertGreaterThan(measure.width("Нативная лента чата — W11", medium: true), first)
        XCTAssertEqual(measure.cacheCount, 2)
        XCTAssertEqual(measure.width("", medium: false), 0)
    }

    func testOnestMeasurementMatchesSwiftUITextWidth() {
        AgentPadFonts.registerOnce()
        XCTAssertNotNil(NSFont(name: "Onest", size: 12))
        let titles = [
            "agentpad", "Settings", "zsh", "ssh prod-eu-1", "~/agentpad-attn", "fix-W10-jumps", "#release-1.3",
            "Notifications", "Обзор PR #412: Telegram папки", "Публикация приложения в Apple Store",
            "Нативная лента чата — W11", "Саша Петров", "Миграция release-33", "Переводы zh-Hans",
            "Сборка 🚀 готова", "✅ tests", "WWWWWWWWWW", "iiiiiiiiii", "Ревьюер: popups phase 3", "Документация 1.3.0",
        ]
        let measure = TabTitleMeasure()
        for title in titles {
            for medium in [false, true] {
                let text = Text(title).font(Theme.display(12, weight: medium ? .medium : .regular)).lineLimit(1).fixedSize()
                let swiftUI = NSHostingView(rootView: text).fittingSize.width
                // Text rounds its width up to a whole point; the natural width does the same.
                XCTAssertEqual(measure.width(title, medium: medium).rounded(.up), swiftUI, "\(title) medium \(medium)")
            }
        }
    }

    func testLayoutOf60TabsStaysUnderBudget() {
        let naturals = (0..<60).map { CGFloat(120 + ($0 * 37) % 260) }
        let input = tabs(naturals)
        let start = ContinuousClock.now
        var level: CGFloat = 0
        for index in 0..<1_000 {
            level += TabStripLayout(tabs: input, activeIndex: index % 60, viewport: CGFloat(800 + index % 900)).level ?? 0
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertGreaterThan(level, 0)
        // Budget: 1,000 layouts of 60 tabs (one per frame at most in practice) under 100 ms.
        XCTAssertLessThan(elapsed, .milliseconds(100), "1,000 layouts took \(elapsed)")
    }

    // MARK: Reference

    /// The mockup's `layout()` (bisection, 40 steps) as the oracle for the level.
    private static func mockupLayout(_ naturals: [CGFloat], active: Int?, viewport: CGFloat)
        -> (widths: [CGFloat], level: CGFloat?, scroll: Bool, remainderBranch: Bool) {
        let caps = naturals.enumerated().map { $0.offset == active ? $0.element : min($0.element, 240) }
        let available = viewport - 20 - 4 * CGFloat(naturals.count - 1)
        if caps.reduce(0, +) <= available { return (caps, nil, false, false) }
        func widths(_ level: CGFloat) -> [CGFloat] {
            caps.enumerated().map { $0.offset == active ? min($0.element, max(200, level)) : min($0.element, level) }
        }
        var low: CGFloat = 0, high: CGFloat = 240
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if widths(mid).reduce(0, +) > available { high = mid } else { low = mid }
        }
        // Bisection converges to the exact level from below; 1e-6 recovers a level
        // that is itself an integer (f(L) == A), which a bare floor would miss by one.
        if (low + 1e-6).rounded(.down) >= 80 {
            let level = (low + 1e-6).rounded(.down)
            return (widths(level), level, false, widths(240).reduce(0, +) <= available)
        }
        return (widths(80), 80, true, false)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
