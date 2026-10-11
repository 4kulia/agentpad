import AppKit
import SwiftUI

struct TelegramFeedOverlayFrames: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

/// Geometry and window notifications share one evaluation on the next main
/// run-loop turn, using the latest state from the burst.
@MainActor final class TelegramFeedVisibilityUpdates {
    private var pending: (() -> Void)?
    private var scheduled = false

    func schedule(_ evaluate: @escaping () -> Void) {
        pending = evaluate
        guard !scheduled else { return }
        scheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let evaluate = self.pending
                self.pending = nil; self.scheduled = false
                evaluate?()
            }
        }
    }

    func cancel() { pending = nil }
}

/// All rectangles use the feed's top-left coordinate space. Ordinary content
/// needs an exposed area; sponsored text must be exposed in its entirety.
struct TelegramFeedVisibility {
    enum Requirement { case partial, full }
    var viewport: CGRect
    var clip: CGRect
    var screens: [CGRect]
    var overlays: [CGRect]
    var key: Bool
    var visible: Bool
    var occlusion: NSWindow.OcclusionState

    func isVisible(_ frame: CGRect, requiring requirement: Requirement) -> Bool {
        guard key, visible, occlusion.contains(.visible), Self.hasArea(frame) else { return false }
        let clipped = frame.intersection(viewport).intersection(clip)
        var exposed = screens.map { clipped.intersection($0) }.filter(Self.hasArea)
        for overlay in overlays { exposed = exposed.flatMap { Self.subtract(overlay, from: $0) } }
        switch requirement {
        case .partial: return !exposed.isEmpty
        case .full:
            var missing = [frame]
            for area in exposed { missing = missing.flatMap { Self.subtract(area, from: $0) } }
            return missing.isEmpty
        }
    }

    private static func hasArea(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty
            && [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
    }
    private static func subtract(_ cover: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = rect.intersection(cover)
        guard hasArea(overlap) else { return [rect] }
        return [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
                CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
                CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
                CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)].filter(hasArea)
    }

    @MainActor static func capture(scroll: NSScrollView?, viewport: CGRect, overlays: [CGRect]) -> Self? {
        guard let clip = scroll?.contentView, let window = clip.window, !clip.isHiddenOrHasHiddenAncestor else { return nil }
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX - clip.bounds.minX,
                   y: clip.isFlipped ? rect.minY - clip.bounds.minY : clip.bounds.maxY - rect.maxY,
                   width: rect.width, height: rect.height)
        }
        func fromScreen(_ rect: CGRect) -> CGRect { local(clip.convert(window.convertFromScreen(rect), from: nil)) }
        return Self(viewport: viewport, clip: local(clip.visibleRect),
                    screens: NSScreen.screens.map { fromScreen($0.frame) }, overlays: overlays,
                    key: window.isKeyWindow, visible: window.isVisible && !window.isMiniaturized,
                    occlusion: window.occlusionState)
    }
}
