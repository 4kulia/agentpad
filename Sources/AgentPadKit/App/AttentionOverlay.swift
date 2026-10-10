import AppKit
import SwiftUI

/// Popovers participate in the same conservative, window-wide gate as rail
/// overlays. Closing one schedules a fresh visibility/read-boundary check.
private struct AttentionOverlayProbe: NSViewRepresentable {
    let presented: Bool
    final class Probe: NSView {
        let id = UUID()
        var presented = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); update() }
        func update() { NavigationPresentationGate.setOverlay(id, window: window, presented: presented) }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.presented = presented; view.update()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        NavigationPresentationGate.setOverlay(view.id, window: view.window, presented: false)
    }
}

extension View {
    func attentionPopover<Content: View>(isPresented: Binding<Bool>,
        attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds), arrowEdge: Edge = .top,
        @ViewBuilder content: @escaping () -> Content) -> some View {
        background(AttentionOverlayProbe(presented: isPresented.wrappedValue).allowsHitTesting(false))
            .popover(isPresented: isPresented, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge, content: content)
    }

    func attentionPopover<Item: Identifiable, Content: View>(item: Binding<Item?>,
        attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds), arrowEdge: Edge = .top,
        @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        background(AttentionOverlayProbe(presented: item.wrappedValue != nil).allowsHitTesting(false))
            .popover(item: item, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge, content: content)
    }
}
