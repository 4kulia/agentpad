import Foundation

/// Layout direction of a split. `horizontal` puts the two children side-by-side
/// (divider runs vertically). `vertical` stacks them top-to-bottom (divider
/// runs horizontally).
enum SplitOrientation: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

/// A node in a workspace's split tree. Either wraps a `Pane` (a leaf region
/// with its own tab strip) or holds two child `PaneNode`s separated by a
/// divider at `fraction` (0..1 — first child's share of the available axis).
@MainActor
@Observable
final class PaneNode: Identifiable {
    let id: UUID
    var content: PaneContent

    init(id: UUID = UUID(), content: PaneContent) {
        self.id = id
        self.content = content
    }

    convenience init(pane: Pane) {
        self.init(id: pane.id, content: .pane(pane))
    }
}

enum PaneContent {
    case pane(Pane)
    indirect case split(orientation: SplitOrientation, first: PaneNode, second: PaneNode, fraction: Double)
}

extension PaneNode {
    /// DFS list of leaf panes in display order.
    var allPanes: [Pane] {
        var out: [Pane] = []
        collectPanes(into: &out)
        return out
    }

    /// Every tab's engine under this node — the set a size-propagation
    /// suspension must cover (background tabs share the pane's NSView
    /// geometry). Single spelling for the five suspend owners.
    var allEngines: [any TerminalEngine] {
        allPanes.flatMap { $0.tabs.map(\.engine) }
    }

    private func collectPanes(into out: inout [Pane]) {
        switch content {
        case .pane(let p): out.append(p)
        case .split(_, let a, let b, _):
            a.collectPanes(into: &out)
            b.collectPanes(into: &out)
        }
    }

    var firstPane: Pane? {
        switch content {
        case .pane(let p): return p
        case .split(_, let a, _, _): return a.firstPane
        }
    }

    /// Short-circuiting lookup. Prefer this to `allPanes.first(where:)` —
    /// avoids walking the whole tree when the match is found early.
    func pane(id: UUID) -> Pane? {
        switch content {
        case .pane(let p):
            return p.id == id ? p : nil
        case .split(_, let a, let b, _):
            return a.pane(id: id) ?? b.pane(id: id)
        }
    }

    /// Subtree membership — same short-circuit walk as `pane(id:)`, just
    /// without resurfacing the leaf when callers only need the boolean.
    func contains(paneId: UUID) -> Bool { pane(id: paneId) != nil }

    /// True when this subtree contains more than one leaf pane (i.e. it
    /// has any split node). O(1) vs `allPanes.count > 1`'s O(n) array
    /// allocation — used in hot-path render code that asks "is zoom
    /// meaningful here?" on every status-bar layout.
    var hasMultiplePanes: Bool {
        switch content {
        case .pane: return false
        case .split: return true
        }
    }

    func paneNode(paneId: UUID) -> PaneNode? {
        switch content {
        case .pane(let p):
            return p.id == paneId ? self : nil
        case .split(_, let a, let b, _):
            return a.paneNode(paneId: paneId) ?? b.paneNode(paneId: paneId)
        }
    }

    /// Pane that contains the given session, or nil.
    func pane(containingSessionId sessionId: UUID) -> Pane? {
        switch content {
        case .pane(let p):
            return p.tabs.contains(where: { $0.id == sessionId }) ? p : nil
        case .split(_, let a, let b, _):
            return a.pane(containingSessionId: sessionId) ?? b.pane(containingSessionId: sessionId)
        }
    }

    /// For a leaf with the given pane id, returns the parent split node, the
    /// leaf node itself, and its sibling. nil if the leaf is the root or is
    /// not in this subtree.
    func parentInfo(forPane paneId: UUID) -> (parent: PaneNode, leaf: PaneNode, sibling: PaneNode)? {
        guard case .split(_, let first, let second, _) = content else { return nil }
        if case .pane(let p) = first.content, p.id == paneId {
            return (self, first, second)
        }
        if case .pane(let p) = second.content, p.id == paneId {
            return (self, second, first)
        }
        return first.parentInfo(forPane: paneId) ?? second.parentInfo(forPane: paneId)
    }
}
