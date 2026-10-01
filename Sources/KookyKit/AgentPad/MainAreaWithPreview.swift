import SwiftUI

/// The terminal area with the file preview docked underneath. The terminal
/// view is always the first child and never conditional, so opening or
/// closing the preview only resizes it — kooky's pane host must not be
/// torn down and rebuilt.
struct MainAreaWithPreview<Terminal: View>: View {
    let store: WorkspaceStore
    @ViewBuilder let terminal: () -> Terminal

    @State private var dragStartFraction: CGFloat?
    /// Whether we pushed the resize cursor, so it's popped exactly once —
    /// also when the divider disappears under the pointer.
    @State private var cursorPushed = false

    static var minFraction: CGFloat { 0.15 }
    static var maxFraction: CGFloat { 0.85 }

    var body: some View {
        let preview = FilePreviewModel.for(store)
        GeometryReader { geo in
            let total = geo.size.height
            let previewHeight = preview.isOpen ? (total * preview.heightFraction).rounded() : 0
            VStack(spacing: 0) {
                terminal()
                    .frame(height: max(0, total - previewHeight - (preview.isOpen ? 1 : 0)))
                if preview.isOpen {
                    Rectangle()
                        .fill(Theme.chromeSeparator)
                        .frame(height: 1)
                        .overlay {
                            // A taller invisible grab area than the 1pt line.
                            Color.clear
                                .frame(height: 9)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside, !cursorPushed { NSCursor.resizeUpDown.push(); cursorPushed = true }
                                    if !inside, cursorPushed { NSCursor.pop(); cursorPushed = false }
                                }
                                .onDisappear {
                                    if cursorPushed { NSCursor.pop(); cursorPushed = false }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                        .onChanged { value in
                                            let start = dragStartFraction ?? preview.heightFraction
                                            dragStartFraction = start
                                            let proposed = start - value.translation.height / max(total, 1)
                                            preview.heightFraction = min(Self.maxFraction, max(Self.minFraction, proposed))
                                        }
                                        .onEnded { _ in dragStartFraction = nil }
                                )
                        }
                    // The folder the tree shows — an external session's when one is shown.
                    FilePreviewPanel(model: preview, root: ExternalTreeRoot.for(store).url ?? store.fileTreeRoot)
                        .frame(height: previewHeight)
                }
            }
        }
        // A closed window stops watching its file right away.
        .onDisappear { preview.close() }
    }
}
