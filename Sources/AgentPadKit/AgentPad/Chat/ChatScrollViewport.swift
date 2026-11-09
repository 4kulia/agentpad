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
    private var adjustingOffset = false
    private var publishing = false
    private var publishedBottom: Bool?
    private var wheelGesture = false
    private var scrollerTracking = false

    func attach(_ scroll: NSScrollView) {
        guard self.scroll !== scroll else { return }
        observers.removeAll()
        wheelGesture = false; scrollerTracking = false
        self.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.documentView?.postsFrameChangedNotifications = true
        observe(NSView.boundsDidChangeNotification, object: scroll.contentView) { $0.boundsChanged() }
        if let document = scroll.documentView {
            observe(NSView.frameDidChangeNotification, object: document) { viewport in
                if viewport.following { viewport.jumpToBottom() }
                else { viewport.measure() }
            }
        }
        // Bounds and didLiveScroll notifications are too late: restoration can
        // already have reversed the first native scroll. Release at dispatch,
        // before key interpretation or the scroller's nested tracking loop.
        observers.inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self, weak scroll] event in
            MainActor.assumeIsolated {
                if let scroll { self?.willHandleInput(event, in: scroll) }
            }
            return event
        }
        observe(NSScrollView.willStartLiveScrollNotification, object: scroll) { $0.userScrolled() }
        observe(NSScrollView.didLiveScrollNotification, object: scroll) { $0.userScrolled(); $0.measure() }
        observe(NSScrollView.didEndLiveScrollNotification, object: scroll) { viewport in
            viewport.measure(); viewport.following = viewport.atBottom
        }
        if following { jumpToBottom() } else { measure() }
    }

    private func willHandleInput(_ event: NSEvent, in scroll: NSScrollView) {
        guard let window = scroll.window, event.window === window else { return }
        switch event.type {
        case .keyDown:
            // Include native/custom key bindings and commands forwarded from
            // selectable message text; an editor in another pane is unrelated.
            var responder = scroll.window?.firstResponder
            while let current = responder {
                if current === scroll || (current as? NSView)?.isDescendant(of: scroll) == true {
                    userScrolled(); break
                }
                responder = current.nextResponder
            }
        case .scrollWheel:
            let inside = scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
            if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
                wheelGesture = inside
            }
            // AppKit keeps routing a gesture's momentum to its original view
            // even when the pointer has left that view.
            if inside || wheelGesture {
                if event.scrollingDeltaY != 0 || !event.phase.isEmpty || !event.momentumPhase.isEmpty { userScrolled() }
            }
            if event.phase == .cancelled || event.momentumPhase == .ended { wheelGesture = false }
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            if event.type == .leftMouseDown {
                scrollerTracking = [scroll.verticalScroller, scroll.horizontalScroller].compactMap { $0 }.contains {
                    !$0.isHidden && $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
                }
            }
            if scrollerTracking { userScrolled() }
            if event.type == .leftMouseUp { scrollerTracking = false }
        default: break
        }
    }

    private func observe(_ name: Notification.Name, object: AnyObject, action: @escaping @MainActor (ChatScrollViewport) -> Void) {
        observers.tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            // Capture native facts in the transaction that produced them.
            // Only publishing into SwiftUI is deferred/coalesced (measure).
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    // Telegram's SwiftUI conversation still uses these native viewport facts.
    func stopFollowing() { following = false }

    private func userScrolled() { following = false }

    func preserveContentOffset(_ delta: CGFloat) {
        guard !following, !adjustingOffset, abs(delta) > 0.5, let scroll, let document = scroll.documentView else { return }
        adjustingOffset = true
        defer { adjustingOffset = false }
        let clip = scroll.contentView
        let offset = document.isFlipped ? delta : -delta
        let y = min(max(document.bounds.minY, clip.bounds.minY + offset), max(document.bounds.minY, document.bounds.maxY - clip.bounds.height))
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y)); scroll.reflectScrolledClipView(clip)
        measure()
    }
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
        if abs(clip.bounds.minY - y) > 0.5 {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        measure()
    }

    func measure() {
        guard let scroll, let document = scroll.documentView else { return }
        let visible = scroll.contentView.bounds
        atBottom = ChatScrollGeometry.isAtBottom(document: document.bounds, visible: visible, flipped: document.isFlipped)
        guard !publishing, publishedBottom != atBottom else { return }
        publishing = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishing = false
            guard self.publishedBottom != self.atBottom else { return }
            self.publishedBottom = self.atBottom
            self.changed?(self.atBottom)
        }
    }

}

/// NotificationCenter removal does not require AppKit or the main actor.
/// Avoid executor-hopping deinit when SwiftUI releases a temporary viewport
/// during layout (Swift's back-deployed isolated teardown can abort there).
private final class ChatScrollObservers {
    var tokens: [NSObjectProtocol] = []
    var inputMonitor: Any?
    func removeAll() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
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
