import AppKit

/// Sizes of the tab strip and its tabs (docs/agentpad/mockups/tab-overflow.html,
/// spec table). `TabBarItem` draws with the same numbers.
enum TabStripMetrics {
    static let padding: CGFloat = 11
    static let compactPadding: CGFloat = 8
    static let markSlot: CGFloat = 16
    static let gap: CGFloat = 7
    static let compactGap: CGFloat = 6
    static let icon: CGFloat = 15
    static let close: CGFloat = 16
    static let forward: CGFloat = 18
    /// Spacing between tabs (`Theme.space1`).
    static let spacing: CGFloat = 4
    /// Inset of the first and last tab from the strip's scroll edges.
    static let rowEdge: CGFloat = 10
    static let minimum: CGFloat = 80
    static let activeMinimum: CGFloat = 200
    static let inactiveMaximum: CGFloat = 240
    /// A revealed tab keeps this distance from either viewport edge.
    static let revealMargin: CGFloat = 48
    /// InlineNameField's minimum width while a tab is renamed.
    static let renameFieldMinimum: CGFloat = 100
    static let fadeWidth: CGFloat = 92
    static let fadeSolid: CGFloat = 58
    /// An edge counter pages the strip by the viewport less this overlap.
    static let pageOverlap: CGFloat = 120
    static let revealDuration: TimeInterval = 0.22
    static let unfreezeDuration: TimeInterval = 0.18

    /// Width of a tab showing its whole title: padding, mark slot, icon,
    /// title, optional forward button, close button, padding.
    static func natural(titleWidth: CGFloat, hasForward: Bool, renaming: Bool) -> CGFloat {
        let chrome = padding + markSlot + gap + icon + gap + gap + (hasForward ? forward + gap : 0) + close + padding
        let title = titleWidth.rounded(.up)
        return chrome + (renaming ? max(title, renameFieldMinimum) : title)
    }
}

/// Body evaluations of tab strips and tab rows. The scroll test reads them:
/// scrolling must not re-render the rows (plan Acceptance 8).
#if DEBUG
@MainActor
enum TabStripRenderCount {
    static var strips = 0
    static var rows = 0
}
#endif

/// Title widths in the tab font (Onest 12, medium when selected), cached per
/// title and weight so a strip of many tabs measures each title once.
@MainActor
final class TabTitleMeasure {
    static let shared = TabTitleMeasure()

    private struct Key: Hashable { let title: String; let medium: Bool }
    private var cache: [Key: CGFloat] = [:]
    private var fonts: [Bool: NSFont] = [:]

    var cacheCount: Int { cache.count }

    func width(_ title: String, medium: Bool) -> CGFloat {
        guard !title.isEmpty else { return 0 }
        let key = Key(title: title, medium: medium)
        if let cached = cache[key] { return cached }
        let font = fonts[medium] ?? ChatNativeTextStyle.font("Onest", size: 12, weight: medium ? .medium : .regular)
        fonts[medium] = font
        // CTLine's typographic width, as SwiftUI Text lays it out (it then rounds
        // up to a whole point). NSAttributedString.size() drops run joins: on a
        // mixed Cyrillic/Latin title it measured 154.32 where Text needs 156.
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [.font: font]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        // Titles change rarely; a bound keeps renamed history from growing forever.
        if cache.count > 2_000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = width
        return width
    }
}

/// Tabs hidden past each edge of a scrolling strip. Equatable so a scroll
/// re-renders the edge overlay only when a count changes.
struct TabStripEdges: Equatable {
    var left: Int
    var right: Int
    static let none = TabStripEdges(left: 0, right: 0)
}

/// Widths and positions of one tab strip. Fits: every tab at its natural
/// width (inactive capped at 240). Otherwise inactive tabs share one level
/// L in 80…240 and the selected tab keeps max(200, L); below 80 the strip
/// scrolls with inactive tabs at 80 and the selected one at 200.
struct TabStripLayout: Equatable {
    struct Tab: Equatable {
        var id: UUID
        var natural: CGFloat
    }

    let widths: [CGFloat]
    /// Natural width, capped at 240 for inactive tabs.
    let caps: [CGFloat]
    /// Leading x of each tab in the scrolling content.
    let positions: [CGFloat]
    /// Narrower than its cap: compact paddings, close button over the title.
    let compressed: [Bool]
    let scrollMode: Bool
    /// The shared inactive width; nil when every tab fits at its cap.
    let level: CGFloat?
    let contentWidth: CGFloat
    let viewport: CGFloat
}

extension TabStripLayout {
    /// - Parameters:
    ///   - viewport: width of the scrolling area ("+" and pane buttons excluded).
    ///   - frozen: widths kept after a close while the pointer is over the strip.
    init(tabs: [Tab], activeIndex: Int?, viewport: CGFloat, frozen: [UUID: CGFloat] = [:]) {
        typealias M = TabStripMetrics
        let caps = tabs.enumerated().map { $0.offset == activeIndex ? $0.element.natural : min($0.element.natural, M.inactiveMaximum) }
        let available = viewport - 2 * M.rowEdge - M.spacing * CGFloat(max(tabs.count - 1, 0))
        func widths(at level: CGFloat) -> [CGFloat] {
            caps.enumerated().map { $0.offset == activeIndex ? min($0.element, max(M.activeMinimum, level)) : min($0.element, level) }
        }
        func total(at level: CGFloat) -> CGFloat { widths(at: level).reduce(0, +) }

        var computed: [CGFloat]
        var level: CGFloat?
        var scrollMode = false
        if caps.reduce(0, +) <= available {
            computed = caps
        } else if total(at: M.inactiveMaximum) <= available {
            // Only the selected tab is past 240: it shows as much of its title as
            // the row has room for (spec table: «Выбранная показывает полное
            // название, пока ряду хватает места»), not the mockup JS's 240 cap.
            level = M.inactiveMaximum
            computed = caps
            if let activeIndex {
                let others = caps.enumerated().filter { $0.offset != activeIndex }.reduce(0) { $0 + $1.element }
                computed[activeIndex] = min(caps[activeIndex], available - others)
            }
        } else if total(at: M.minimum) > available {
            scrollMode = true
            level = M.minimum
            computed = widths(at: M.minimum)
        } else {
            // Largest integer level whose total fits; total is nondecreasing in L.
            var low = Int(M.minimum), high = Int(M.inactiveMaximum)
            while low < high {
                let mid = (low + high + 1) / 2
                if total(at: CGFloat(mid)) <= available { low = mid } else { high = mid - 1 }
            }
            level = CGFloat(low)
            computed = widths(at: CGFloat(low))
        }
        if !frozen.isEmpty {
            for (index, tab) in tabs.enumerated() { if let width = frozen[tab.id] { computed[index] = width } }
        }
        var x = M.rowEdge
        var positions: [CGFloat] = []
        positions.reserveCapacity(computed.count)
        for width in computed {
            positions.append(x)
            x += width + M.spacing
        }
        let content = computed.isEmpty ? 2 * M.rowEdge : x - M.spacing + M.rowEdge
        self.init(widths: computed, caps: caps, positions: positions,
                  compressed: zip(computed, caps).map { $0 < $1 },
                  scrollMode: scrollMode, level: level, contentWidth: content, viewport: viewport)
    }

    var maxOffset: CGFloat { max(0, contentWidth - viewport) }

    func clampedOffset(_ offset: CGFloat) -> CGFloat { min(max(offset, 0), maxOffset) }
    private func clamped(_ offset: CGFloat) -> CGFloat { clampedOffset(offset) }

    /// Offset that brings tab `index` into view, or nil when it stays put.
    /// Off-screen (or wider than the margined viewport) → centred; partly
    /// visible → the smallest shift leaving 48 pt to the edge; fully
    /// visible → nil.
    func revealOffset(for index: Int, offset: CGFloat) -> CGFloat? {
        guard widths.indices.contains(index), viewport > 0 else { return nil }
        let margin = TabStripMetrics.revealMargin
        let x = positions[index], width = widths[index]
        let leading = x - offset, trailing = leading + width
        let target: CGFloat
        if trailing < 0 || leading > viewport || width > viewport - 2 * margin {
            target = clamped(x + width / 2 - viewport / 2)
        } else if leading < margin {
            target = clamped(offset - (margin - leading))
        } else if trailing > viewport - margin {
            target = clamped(offset + trailing - (viewport - margin))
        } else {
            return nil
        }
        return abs(target - offset) < 0.5 ? nil : target
    }

    /// Offset after an edge counter click: one viewport less 120 pt.
    func pageOffset(from offset: CGFloat, direction: Int) -> CGFloat {
        clamped(offset + CGFloat(direction.signum()) * (viewport - TabStripMetrics.pageOverlap))
    }

    /// Tabs hidden past each edge; a tab showing 2 pt or less counts as hidden.
    /// Only a scrolling strip has edges.
    func edges(offset: CGFloat) -> TabStripEdges {
        guard scrollMode else { return .none }
        var left = 0, right = 0
        for index in widths.indices {
            if positions[index] + widths[index] - offset <= 2 { left += 1 }
            else if positions[index] - offset >= viewport - 2 { right += 1 }
        }
        return TabStripEdges(left: left, right: right)
    }
}

/// What an edge counter shows: how many tabs are hidden on its side and the
/// strongest attention mark among them, with the tab that carries it.
struct TabStripEdgeSummary: Equatable {
    enum Side: Equatable { case left, right }

    let side: Side
    let count: Int
    let indicator: AttentionIndicator?
    let help: String

    init(side: Side, tabIDs: [UUID], indicators: [UUID: AttentionIndicator], title: (UUID) -> String) {
        self.side = side
        count = tabIDs.count
        let marked = tabIDs.compactMap { id in indicators[id].map { (id, $0) } }
        indicator = AttentionIndicator(marked.flatMap(\.1.reasons))
        var help = "\(count) tab\(count == 1 ? "" : "s") hidden on the \(side == .left ? "left" : "right")"
        if let kind = indicator?.kind, let top = marked.first(where: { $0.1.kind == kind }) {
            help += " · \(title(top.0)) — \(kind.label)"
        }
        self.help = help
    }
}
