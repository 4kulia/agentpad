import AppKit
import SwiftUI

/// HSplitView ignores the thread's idealWidth during initial distribution.
/// Set its native divider once; subsequent resizing stays under AppKit's control.
struct ChatThreadSplitPosition: NSViewRepresentable {
    let enabled: Bool

    final class Reader: NSView {
        var enabled = true
        private weak var initialized: NSSplitView?

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); initializePosition() }
        override func layout() { super.layout(); initializePosition() }

        func initializePosition() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.enabled, self.window != nil else { return }
                var ancestor = self.superview
                while let view = ancestor {
                    if let split = view as? NSSplitView {
                        guard self.initialized !== split, split.isVertical,
                              split.arrangedSubviews.count == 2, split.bounds.width >= 784 else { return }
                        self.initialized = split
                        split.setPosition(split.bounds.width - 344 - split.dividerThickness, ofDividerAt: 0)
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }

    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) {
        view.enabled = enabled
        view.initializePosition()
    }
}
