import AppKit
import SwiftUI

/// Right-click detector designed to sit in `.overlay()` above SwiftUI content.
/// Its `hitTest` returns `self` only for secondary-mouse events, so left
/// clicks/hovers pass through to the SwiftUI gestures behind it.
///
/// The action callback receives the click location as a `UnitPoint`
/// (origin top-left, both axes in [0, 1]) so callers can feed it to
/// `.popover(attachmentAnchor: .point(...))` and the popover anchors at
/// the click site instead of the view's bounds. Callers that don't care
/// about position pass `{ _ in ... }`.
struct RightClickCatcher: NSViewRepresentable {
    let action: (UnitPoint) -> Void

    func makeNSView(context: Context) -> SecondaryClickView {
        let view = SecondaryClickView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: SecondaryClickView, context: Context) {
        nsView.action = action
    }

    final class SecondaryClickView: NSView {
        var action: ((UnitPoint) -> Void)?

        override func rightMouseDown(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            // NSView's default coordinate system is bottom-left origin
            // (`isFlipped == false`); SwiftUI's UnitPoint is top-left.
            // Invert Y so the popover anchors where the user actually
            // clicked, not at the vertically-mirrored position.
            let w = max(bounds.width, 1)
            let h = max(bounds.height, 1)
            let unit = UnitPoint(
                x: min(max(local.x / w, 0), 1),
                y: min(max(1 - (local.y / h), 0), 1)
            )
            action?(unit)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let type = NSApp.currentEvent?.type else { return nil }
            switch type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return bounds.contains(point) ? self : nil
            default:
                return nil
            }
        }
    }
}
