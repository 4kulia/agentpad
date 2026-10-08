import AppKit
import SwiftUI

/// AppKit owns the drag lifetime, including Escape and drops outside a
/// window. SwiftUI's onDrag has no completion callback to clear highlights.
/// Attached only to the tab label, leaving buttons and menus to SwiftUI.
struct TabDragSource: NSViewRepresentable {
    let session: Session
    let store: WorkspaceStore
    let onActivate: () -> Void

    func makeNSView(context: Context) -> Anchor {
        Anchor(session: session, store: store, onActivate: onActivate)
    }

    func updateNSView(_ nsView: Anchor, context: Context) { nsView.onActivate = onActivate }

    @MainActor
    final class Anchor: NSView, NSDraggingSource {
        private let session: Session
        private weak var store: WorkspaceStore?
        var onActivate: () -> Void

        init(session: Session, store: WorkspaceStore, onActivate: @escaping () -> Void) {
            self.session = session
            self.store = store
            self.onActivate = onActivate
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let start = convert(event.locationInWindow, from: nil)
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let point = convert(next.locationInWindow, from: nil)
                if next.type == .leftMouseUp {
                    if bounds.contains(point) { onActivate() }
                    return
                }
                guard hypot(point.x - start.x, point.y - start.y) >= 6 else { continue }
                let item = NSDraggingItem(pasteboardWriter: session.id.uuidString as NSString)
                item.setDraggingFrame(bounds, contents: dragImage())
                beginDraggingSession(with: [item], event: next, source: self)
                return
            }
        }

        private func dragImage() -> NSImage {
            let title = session.title as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
            let size = NSSize(width: max(bounds.width, 80), height: max(bounds.height, 30))
            return NSImage(size: size, flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
                title.draw(in: rect.insetBy(dx: 11, dy: 8), withAttributes: attributes)
                return true
            }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // SwiftUI's String drop destinations propose copy; the store
            // performs the live-session move after accepting the payload.
            context == .withinApplication ? [.copy, .move] : []
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            store?.draggingTabId = self.session.id
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            store?.draggingTabId = nil
        }
    }
}
