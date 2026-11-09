import AppKit

/// One visit per mounted native pane. Rows, prefetch and measurement never own
/// read acknowledgement. Reuse the legacy window/presentation and model gates.
@MainActor final class ChatTimelineLifecycle {
    unowned let owner: NativeChatTimelineCoordinator
    let box = WindowBox()
    private weak var observedWindow: NSWindow?
    private weak var visitingActions: ChatTimelineActions?
    private var place: String?
    private let observations = ChatTimelineLifecycleObservers()
    private var pending: DispatchWorkItem?
    private var detached = false
    private var disposed = false

    var observerCount: Int { observations.tokens.count }
    var pendingWorkCount: Int { pending == nil ? 0 : 1 }

    init(owner: NativeChatTimelineCoordinator) { self.owner = owner }

    isolated deinit {
        pending?.cancel()
        visitingActions?.endReading()
        if let place { ChatNotifications.hide(place, view: box.id) }
    }

    func bind(_ view: NSView) { box.view = view; attached() }
    func attached() { detached = false; schedule() }
    func hidden() {
        cancelPublication()
        endVisit()
    }
    func detach() {
        detached = true
        cancelPublication()
        endVisit()
        unregister()
        observations.removeAll(); observedWindow = nil
    }
    func actionsChanged() {
        endVisit(); unregister()
        schedule()
    }

    /// Coalesce native/window/model changes after AppKit's table transaction.
    /// The closure always reads the current scope and geometry, not old facts.
    func schedule() {
        guard !disposed, !detached, pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = nil
                self.refresh()
            }
        }
        pending = work
        DispatchQueue.main.async(execute: work)
    }

    private var ready: Bool {
        !disposed && !detached && owner.presentationIsReady
            && owner.actions?.matchesPresented(owner.snapshot) == true
            && !owner.scrollController.restoringReadingPosition
    }
    private var looking: Bool {
        // Legacy suppresses notices for the visible bottom pane even while its
        // model is ahead of presentation. Only durable reads need that fence.
        !disposed && !detached && box.shown && owner.scrollController.atBottom
            && owner.actions?.matches(owner.snapshot?.conversation) == true
            && owner.actions?.permitsNotificationSuppression == true
    }

    private func refresh() {
        guard !disposed, !detached, let view = box.view, let window = view.window else { return }
        if observedWindow !== window {
            observations.removeAll()
            observedWindow = window
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification, NavigationPresentationGate.didChange] {
                observe(name, object: window)
            }
            observe(NSApplication.didBecomeActiveNotification, object: nil)
            observe(NSApplication.didResignActiveNotification, object: nil)
            observations.tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.detach() }
            })
        }
        guard let actions = owner.actions, actions.matches(owner.snapshot?.conversation),
              let nextPlace = actions.notificationPlace else { endVisit(); unregister(); return }
        if place != nextPlace {
            unregister(); place = nextPlace
            ChatNotifications.show(nextPlace, view: box.id) { [weak self] in self?.looking == true }
        }
        guard !view.isHiddenOrHasHiddenAncestor else { endVisit(); return }
        if visitingActions !== actions { endVisit(); visitingActions = actions }
        // Models may have reset their own visit on a store/access transition.
        // beginReading is idempotent and retains each backend's boundary policy.
        actions.beginReading()
        guard ready else { return }
        let scroll = owner.scrollController
        box.atBottom = scroll.atBottom
        actions.setPosition(scroll.position)
        // Actual body intersections are the only message visibility evidence.
        // Header-only, empty, prefetched and fully clipped rows cannot read.
        guard !scroll.visibleIDs.isEmpty else { return }
        actions.readIfLooking(appActive: ChatNotifications.appActive(), shown: box.shown, atBottom: box.atBottom)
    }
    private func observe(_ name: Notification.Name, object: AnyObject?) {
        observations.tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        })
    }
    private func endVisit() { visitingActions?.endReading(); visitingActions = nil }
    private func unregister() {
        if let place { ChatNotifications.hide(place, view: box.id) }
        place = nil; box.atBottom = false
    }
    private func cancelPublication() { pending?.cancel(); pending = nil }
    func dispose() { detach(); disposed = true; box.view = nil }
}

private final class ChatTimelineLifecycleObservers {
    var tokens: [NSObjectProtocol] = []
    func removeAll() { tokens.forEach(NotificationCenter.default.removeObserver); tokens = [] }
    deinit { removeAll() }
}
