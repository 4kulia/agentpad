import AppKit
import SwiftUI

/// Native viewport facts also cover text reflow and a resized split pane. A
/// lazy stack's estimated geometry alone is not a reliable read receipt.
@MainActor
final class ChatScrollViewport {
    weak var scroll: NSScrollView?
    var changed: ((Bool) -> Void)?
    private(set) var atBottom = false
    private(set) var following = true
    private let observers = ChatScrollObservers()
    private var documentSize = CGSize.zero
    private var viewportSize = CGSize.zero

    func attach(_ scroll: NSScrollView) {
        guard self.scroll !== scroll else { return }
        observers.removeAll()
        self.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.documentView?.postsFrameChangedNotifications = true
        observe(NSView.boundsDidChangeNotification, object: scroll.contentView) { $0.boundsChanged() }
        if let document = scroll.documentView {
            observe(NSView.frameDidChangeNotification, object: document) { viewport in
                if viewport.following { viewport.jumpToBottom() } else { viewport.measure() }
            }
        }
        observe(NSScrollView.willStartLiveScrollNotification, object: scroll) { $0.following = false }
        observe(NSScrollView.didLiveScrollNotification, object: scroll) { $0.measure() }
        observe(NSScrollView.didEndLiveScrollNotification, object: scroll) { viewport in
            viewport.measure(); viewport.following = viewport.atBottom
        }
        if following { jumpToBottom() } else { measure() }
    }

    private func observe(_ name: Notification.Name, object: AnyObject, action: @escaping @MainActor (ChatScrollViewport) -> Void) {
        observers.tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            // AppKit delivers these on the main thread. Defer SwiftUI state
            // updates out of the native layout/scroll transaction.
            DispatchQueue.main.async { if let self { action(self) } }
        })
    }

    func stopFollowing() { following = false }
    private func boundsChanged() {
        guard let scroll, let document = scroll.documentView else { return }
        let resized = document.bounds.size != documentSize || scroll.contentView.bounds.size != viewportSize
        documentSize = document.bounds.size; viewportSize = scroll.contentView.bounds.size
        if resized && following { jumpToBottom() }
        else {
            measure()
            // Mouse wheels without live-scroll phases must detach too.
            if !atBottom { following = false }
        }
    }
    func jumpToBottom() {
        following = true
        guard let scroll, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        documentSize = document.bounds.size; viewportSize = clip.bounds.size
        let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height) : document.bounds.minY
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
        measure()
    }

    func measure() {
        guard let scroll, let document = scroll.documentView else { return }
        let visible = scroll.contentView.bounds
        atBottom = ChatScrollGeometry.isAtBottom(document: document.bounds, visible: visible, flipped: document.isFlipped)
        changed?(atBottom)
    }

}

/// NotificationCenter removal does not require AppKit or the main actor.
/// Avoid executor-hopping deinit when SwiftUI releases a temporary viewport
/// during layout (Swift's back-deployed isolated teardown can abort there).
private final class ChatScrollObservers {
    var tokens: [NSObjectProtocol] = []
    func removeAll() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }
    deinit { removeAll() }
}

enum ChatScrollGeometry {
    static func isAtBottom(document: CGRect, visible: CGRect, flipped: Bool) -> Bool {
        flipped ? visible.maxY >= document.maxY - 16 : visible.minY <= document.minY + 16
    }
}

struct ChatScrollAccess: NSViewRepresentable {
    let viewport: ChatScrollViewport
    let changed: (Bool) -> Void
    final class Reader: NSView {
        weak var viewport: ChatScrollViewport?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        func attach() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                self.viewport?.attach(scroll)
            }
        }
    }
    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) {
        viewport.changed = changed
        view.viewport = viewport
        view.attach()
    }
}
