import AppKit

/// Scroll state belongs to this mounted pane. Geometry is captured at commit,
/// never at the start of a page/layout request, and published only after tiling.
@MainActor final class ChatTimelineScrollController {
    enum Alignment { case top, center }
    struct Anchor {
        let id: String
        let offset: CGFloat
        let character: Int?
        let text: String?
    }
    struct Geometry {
        let origin: CGFloat
        let anchor: Anchor?
        let neighbors: [Anchor]
        let input: UInt64
        let navigation: UInt64
    }
    unowned let owner: NativeChatTimelineCoordinator
    var scroll: NSScrollView? { owner.scrollView }
    private var clip: NSClipView { owner.scrollView.contentView }
    private var table: ChatNativeTableView { owner.tableView }
    private(set) var following = true
    private(set) var atBottom = false
    private(set) var inputGeneration: UInt64 = 0
    private(set) var navigationGeneration: UInt64 = 0
    private(set) var selectedID: String?
    private(set) var position = ChatScrollPosition()
    private(set) var visibleIDs = Set<String>()
    /// A boundary clamp is an expected geometry change, recorded separately.
    private(set) var lastClamp: CGFloat = 0
    var changed: (() -> Void)?
    private let observers = ChatTimelineScrollObservers()
    private var depth = 0
    private var captured: Geometry?
    private var retainedID: String?
    private var pendingCommands: [NativeTimelineSnapshot.Command] = []
    private var consumedToken: UInt64 = 0
    private var lastMessages: [ChatMessage] = []
    private var publishing = false
    private var disposed = false
    private var wheelGesture = false
    private var scrollerTracking = false
    private var userMovement = false
    private var liveScrolling = false
    private var viewportWidth: CGFloat = 0
    private var suspended = false
    var observerCount: Int { observers.tokens.count }
    var inputMonitorCount: Int { observers.monitor == nil ? 0 : 1 }
    var pendingPublicationCount: Int { publishing ? 1 : 0 }
    var restoringReadingPosition: Bool {
        pendingCommands.contains { if case .restore = $0.kind { true } else { false } }
    }

    init(owner: NativeChatTimelineCoordinator) {
        self.owner = owner
        attach()
    }
    func attach() {
        guard !disposed, observers.tokens.isEmpty else { return }
        suspended = false
        let scroll = owner.scrollView
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        observe(NSView.boundsDidChangeNotification, object: scroll.contentView) { $0.boundsChanged() }
        observe(NSView.frameDidChangeNotification, object: scroll.contentView) { $0.boundsChanged() }
        observe(NSScrollView.willStartLiveScrollNotification, object: scroll) { $0.liveScrolling = true }
        observe(NSScrollView.didEndLiveScrollNotification, object: scroll) { controller in
            controller.liveScrolling = false; controller.scrollerTracking = false
            controller.measure(); controller.following = controller.atBottom
        }
        observers.monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.willHandle(event) }
            return event
        }
        (scroll.verticalScroller as? ChatTimelineScroller)?.beforeInput = { [weak self] in self?.userWillScroll() }
        table.navigate = { [weak self] direction in self?.move(direction) }
        table.dismiss = { [weak owner] in owner?.actions?.dismissTransient() ?? false }
    }

    func detach() {
        suspended = true; observers.removeAll(); publishing = false
        (owner.scrollView.verticalScroller as? ChatTimelineScroller)?.beforeInput = nil
        table.navigate = nil; table.dismiss = nil
        wheelGesture = false; scrollerTracking = false; liveScrolling = false
    }
    func resumePendingCommands() {
        guard !disposed, !suspended else { return }
        transaction(preservingGeometry: false) {}
    }

    private func observe(_ name: Notification.Name, object: AnyObject, _ action: @escaping @MainActor (ChatTimelineScrollController) -> Void) {
        observers.tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    func transaction(preservingGeometry: Bool = true, _ update: () -> Void) {
        if depth == 0 { captured = preservingGeometry ? capture() : nil; userMovement = false }
        depth += 1
        update()
        depth -= 1
        guard depth == 0 else { return }
        depth = 1
        if following { setOrigin(bottomOrigin) }
        else if let captured, captured.input == inputGeneration, captured.navigation == navigationGeneration { restore(captured) }
        captured = nil
        consumePendingCommands()
        table.layoutSubtreeIfNeeded()
        depth = 0
        measure()
    }

    func applied(_ snapshot: NativeTimelineSnapshot, reset: Bool, requestInput: UInt64, requestNavigation: UInt64) {
        let messages = snapshot.rows.compactMap { row -> ChatMessage? in
            if case .message(let value) = row.payload { value.content.message } else { nil }
        }
        if reset {
            pendingCommands = []; consumedToken = 0; selectedID = nil; retainedID = nil
            captured = nil
            let saved = snapshot.state.position
            position = saved.value
            following = saved.atBottom || !saved.initialized
            if !following, let id = saved.anchor {
                pendingCommands.append(.init(token: 0, kind: .restore(saved)))
                retainedID = id
            }
        }
        // Use the live measured position, not the position saved in an older
        // preparation. Match the legacy message-change follow/unseen contract.
        let contentChanged = reset || messages != lastMessages
        let follow = contentChanged ? position.update(messages, me: snapshot.me) : false
        lastMessages = messages
        if contentChanged && follow && !hasReveal(in: snapshot) { following = true }
        let commands = snapshot.commands.filter { $0.token > consumedToken }.sorted { $0.token < $1.token }
        consumedToken = max(consumedToken, snapshot.commands.map(\.token).max() ?? 0)
        pendingCommands.removeAll { pending in pending.token != 0 && !snapshot.commands.contains(where: { $0.token == pending.token }) }
        // A prepared snapshot may still supply content after input, but cannot
        // bring its old reveal/focus/return correction along with it.
        if requestInput == inputGeneration, requestNavigation == navigationGeneration {
            // Fence previously waiting commands before their targets can be
            // realized by this same snapshot and move a visible focus target.
            if commands.contains(where: { takesNavigation($0.kind, in: snapshot) }) { pendingCommands = [] }
            pendingCommands.append(contentsOf: commands)
        }
        if let selectedID, !snapshot.messageIDs.contains(selectedID) {
            self.selectedID = snapshot.messageAliases[selectedID]
        }
        owner.refreshSelection()
    }

    private func hasReveal(in snapshot: NativeTimelineSnapshot) -> Bool {
        snapshot.commands.contains {
            if case .reveal(let id) = $0.kind { snapshot.messageIDs.contains(id) } else { false }
        }
    }

    private func takesNavigation(_ kind: NativeTimelineSnapshot.Command.Kind, in snapshot: NativeTimelineSnapshot) -> Bool {
        switch kind {
        case .focusArea: false
        case .restore: !hasReveal(in: snapshot)
        default: true
        }
    }

    func bodyFrame(_ messageID: String) -> CGRect? {
        guard let index = owner.messageIndex(messageID), let plan = owner.layoutPlan(at: index) else { return nil }
        return plan.contentBody.offsetBy(dx: table.rect(ofRow: index).minX, dy: table.rect(ofRow: index).minY)
    }
    var bodyFrames: [String: CGRect] {
        let range = table.rows(in: clip.bounds)
        guard range.location != NSNotFound, range.length > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: (range.location..<NSMaxRange(range)).compactMap { index in
            guard owner.rows.indices.contains(index), let id = owner.rows[index].messageID, let frame = bodyFrame(id),
                  frame.intersects(clip.bounds), !frame.isEmpty else { return nil }
            return (id, frame.offsetBy(dx: -clip.bounds.minX, dy: -clip.bounds.minY))
        })
    }

    private func capture() -> Geometry {
        let frames = bodyFrames
        let visible = frames.sorted { $0.value.minY < $1.value.minY }
        let id = retainedID.flatMap { frames[$0] != nil ? $0 : nil }
            ?? visible.first(where: { $0.value.minY >= 0 && $0.value.maxY <= clip.bounds.height })?.key
            ?? visible.first?.key
        var anchor: Anchor?
        if let id, let frame = frames[id] {
            if frame.height > clip.bounds.height, frame.minY < 0,
               let text = textLayout(id), text.manager.numberOfGlyphs > 0 {
                let glyph = min(text.manager.glyphIndex(for: CGPoint(x: 0, y: -frame.minY), in: text.container), text.manager.numberOfGlyphs - 1)
                let character = text.manager.characterIndexForGlyph(at: glyph)
                let line = text.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                anchor = Anchor(id: id, offset: frame.minY + line.minY, character: character, text: text.storage.string)
            } else { anchor = Anchor(id: id, offset: frame.minY, character: nil, text: nil) }
        }
        let ids = owner.snapshot?.messageIDs ?? []
        var neighbors: [Anchor] = []
        if let id, let index = ids.firstIndex(of: id) {
            // Successors precede predecessors, even when the deleted body was
            // the only visible row. Keep their old offsets, not new row tops.
            let ordered = Array(ids.dropFirst(index + 1)) + Array(ids.prefix(index).reversed())
            neighbors = ordered.compactMap { id in bodyFrame(id).map { Anchor(id: id, offset: $0.minY - clip.bounds.minY, character: nil, text: nil) } }
        }
        return Geometry(origin: clip.bounds.minY, anchor: anchor, neighbors: neighbors,
                        input: inputGeneration, navigation: navigationGeneration)
    }

    private func restore(_ geometry: Geometry) {
        let candidates = geometry.anchor.map { [$0] } ?? []
        for anchor in candidates + geometry.neighbors {
            let id = owner.snapshot?.messageAliases[anchor.id] ?? anchor.id
            guard let frame = bodyFrame(id) else { continue }
            var y = frame.minY
            if let character = anchor.character, let text = textLayout(id), text.storage.length > 0 {
                let mapped = Self.mappedCharacter(character, from: anchor.text ?? "", to: text.storage.string)
                let glyph = text.manager.glyphIndexForCharacter(at: min(mapped, text.storage.length - 1))
                y += text.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            }
            setOrigin(y - anchor.offset)
            retainedID = id
            return
        }
        setOrigin(geometry.origin)
    }

    /// Preserve an unchanged suffix when hydration/editing inserts text before
    /// the reading character; ordinary width reflow retains its UTF-16 offset.
    private static func mappedCharacter(_ index: Int, from old: String, to new: String) -> Int {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        if index < prefix { return index }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        if index >= a.count - suffix { return max(0, index + b.count - a.count) }
        return min(index, max(0, b.count - 1))
    }

    private func textLayout(_ id: String) -> (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer)? {
        guard let index = owner.messageIndex(id), let snapshot = owner.snapshot, let plan = owner.layoutPlan(at: index) else { return nil }
        let content = owner.layoutEngine.content(owner.rows[index], snapshot: snapshot, width: plan.width)
        guard content.selectable, content.body.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: content.body)
        let manager = NSLayoutManager(); manager.backgroundLayoutEnabled = false
        let container = NSTextContainer(size: CGSize(width: plan.body.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        return (storage, manager, container)
    }

    private var bottomOrigin: CGFloat { max(0, table.bounds.maxY - clip.bounds.height) }
    private func setOrigin(_ y: CGFloat) {
        let clamped = min(max(0, y), bottomOrigin)
        lastClamp = clamped - y
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: clamped))
        owner.scrollView.reflectScrolledClipView(clip)
    }

    func stopFollowing(preservingAnchor: Bool = false) {
        following = false
        if !preservingAnchor { retainedID = nil; pendingCommands = []; navigationGeneration &+= 1 }
    }
    func followBottom() {
        userMovement = false
        following = true; pendingCommands = []; retainedID = nil; navigationGeneration &+= 1
        depth += 1; setOrigin(bottomOrigin); depth -= 1; measure()
    }
    func jumpToBottom() { followBottom() }
    func jumpToLatest() { owner.actions?.finishNavigation(); followBottom() }
    @discardableResult func scrollTo(messageID: String, alignment: Alignment, requestToken: UInt64? = nil) -> Bool {
        guard let frame = bodyFrame(messageID) else { return false }
        if let requestToken {
            guard requestToken > consumedToken else { return false }
            consumedToken = requestToken
        }
        userMovement = false
        following = false; pendingCommands = []; navigationGeneration &+= 1; retainedID = messageID
        depth += 1
        setOrigin(alignment == .top ? frame.minY : frame.midY - clip.bounds.height / 2)
        table.layoutSubtreeIfNeeded()
        depth -= 1; measure()
        return true
    }
    func reveal(messageID: String) {
        if scrollTo(messageID: messageID, alignment: .center) { select(messageID) }
    }
    /// ScrollViewReader restores the entire legacy ForEach wrapper: its
    /// day/unread/thread-summary decorations precede the message row. Live
    /// body/character anchors and explicit body alignment remain separate.
    @discardableResult private func restoreSavedAnchorTop(_ messageID: String) -> Bool {
        guard let index = owner.messageIndex(messageID),
              case .message(let message) = owner.rows[index].payload else { return false }
        var first = index
        wrapper: while first > 0 {
            switch owner.rows[first - 1].id.kind {
            case .dayBoundary(let id), .unreadBoundary(let id):
                guard id == messageID else { break wrapper }
            case .threadSummary(let root):
                guard root == message.content.message.threadRootId,
                      root == owner.snapshot?.conversation.root else { break wrapper }
            default: break wrapper
            }
            first -= 1
        }
        userMovement = false
        following = false; pendingCommands = []; navigationGeneration &+= 1; retainedID = messageID
        depth += 1
        setOrigin(table.rect(ofRow: first).minY)
        table.layoutSubtreeIfNeeded()
        depth -= 1; measure()
        return true
    }
    func restoreReadingPosition(_ saved: NativeTimelineSnapshot.Position) {
        position = saved.value
        if saved.atBottom { followBottom() }
        else if let id = saved.anchor { _ = restoreSavedAnchorTop(id) }
    }

    private func consumePendingCommands() {
        guard let snapshot = owner.snapshot else { return }
        var waiting: [NativeTimelineSnapshot.Command] = []
        let input = inputGeneration
        for command in pendingCommands {
            guard input == inputGeneration else { break }
            let navigates = takesNavigation(command.kind, in: snapshot)
            // A newer applicable command supersedes older waiting navigation,
            // even when its target is unloaded or focus needs no scrolling.
            if navigates { waiting = [] }
            switch command.kind {
            case .reveal(let id):
                if bodyFrame(id) == nil { waiting.append(command) } else { reveal(messageID: id) }
            case .edit(let id):
                if !scrollTo(messageID: id, alignment: .center) { waiting.append(command) }
            case .focusMessage(let id):
                guard let index = owner.messageIndex(id) else { waiting.append(command); continue }
                pendingCommands = []; navigationGeneration &+= 1
                select(id)
                if !bodyFrames.keys.contains(id) { _ = scrollTo(messageID: id, alignment: .center) }
                if case .message(let message) = owner.rows[index].payload,
                   owner.snapshot?.conversation.root != nil || (message.content.replySummary?.count ?? 0) == 0 {
                    if owner.permitsModelFocus { table.window?.makeFirstResponder(table) }
                } else if owner.permitsModelFocus {
                    (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell)?.replySummary.focusLocalReply()
                }
                if owner.defersModelFocus { waiting.append(command) }
            case .focusArea(let area):
                // A newer focus request also replaces deferred message focus,
                // including when the composer or another pane owns the request.
                waiting.removeAll {
                    switch $0.kind { case .focusMessage, .focusArea: true; default: false }
                }
                let expected: ChatFocusArea = snapshot.conversation.root == nil ? .feed : .thread
                if area == expected.rawValue {
                    if owner.permitsModelFocus { table.window?.makeFirstResponder(table) }
                    else if owner.defersModelFocus { waiting.append(command) }
                }
            case .restore(let position):
                guard navigates else { continue }
                if !position.atBottom, let id = position.anchor, bodyFrame(id) == nil { waiting.append(command) }
                else if command.token == 0 {
                    // Initial restoration uses the saved geometry, but keeps
                    // the arrivals counted against that saved history above.
                    if let id = position.anchor { _ = restoreSavedAnchorTop(id) }
                } else { restoreReadingPosition(position) }
            }
        }
        pendingCommands = input == inputGeneration ? waiting : []
    }

    private func select(_ id: String?) { selectedID = id; owner.refreshSelection() }
    private func move(_ direction: Int) {
        let id = ChatFeedLayout.selection(moving: direction, in: owner.snapshot?.messageIDs ?? [], from: selectedID)
        stopFollowing()
        select(id)
        if let id { _ = scrollTo(messageID: id, alignment: .center) }
    }

    /// AXValue setters have no NSEvent. Both scroller actions and monitored
    /// native events use this boundary before AppKit can move the clip view.
    func userWillScroll() {
        inputGeneration &+= 1
        following = false; pendingCommands = []; retainedID = nil
        userMovement = true
    }
    private func willHandle(_ event: NSEvent) {
        guard event.window === table.window, table.window != nil, !table.isHiddenOrHasHiddenAncestor else { return }
        let scroll = owner.scrollView
        switch event.type {
        case .keyDown:
            // Rejoin row controls after AppKit's automatic loop rebuild, even
            // when Shift-Tab starts in the adjacent composer or pane.
            table.rebuildKeyViewLoop()
            var responder = table.window?.firstResponder
            while let current = responder {
                if current === scroll || (current as? NSView)?.isDescendant(of: scroll) == true { userWillScroll(); break }
                responder = current.nextResponder
            }
        case .scrollWheel:
            let inside = scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
            if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) { wheelGesture = inside }
            // Momentum remains routed to its starting pane, even if the
            // pointer now lies over the adjacent pane in the same window.
            let routedHere = event.momentumPhase.isEmpty ? (inside || wheelGesture) : wheelGesture
            if routedHere { userWillScroll() }
            if event.phase == .cancelled || event.momentumPhase == .ended { wheelGesture = false }
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            if event.type == .leftMouseDown, let scroller = scroll.verticalScroller {
                scrollerTracking = !scroller.isHidden && scroller.bounds.contains(scroller.convert(event.locationInWindow, from: nil))
            }
            if scrollerTracking { userWillScroll() }
            if event.type == .leftMouseUp { scrollerTracking = false }
        default: break
        }
    }
    private func boundsChanged() {
        guard depth == 0 else { return }
        // A native scrollbar-style change can resize the clip independently
        // of the outer SwiftUI container. Row heights still use the old plans
        // until this commit captures their body/character positions.
        if viewportWidth != clip.bounds.width, let snapshot = owner.snapshot {
            owner.update(snapshot, width: clip.bounds.width)
        }
        measure()
        if userMovement && !liveScrolling && !scrollerTracking { following = atBottom }
        else if !atBottom { following = false }
    }
    private func measure() {
        guard depth == 0, !disposed, !suspended else { return }
        owner.refreshMediaVisibility()
        viewportWidth = clip.bounds.width
        atBottom = ChatScrollGeometry.isAtBottom(document: table.bounds, visible: clip.bounds, flipped: true)
        let frames = bodyFrames
        visibleIDs = Set(frames.keys)
        if retainedID.flatMap({ frames[$0] }) == nil {
            retainedID = frames.filter { $0.value.minY >= 0 }.min { $0.value.minY < $1.value.minY }?.key
                ?? frames.min { $0.value.minY < $1.value.minY }?.key
        }
        position.measured(bottom: atBottom, anchor: retainedID)
        guard !publishing else { return }
        publishing = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.disposed, !self.suspended else { return }
            self.publishing = false
            guard self.depth == 0 else { return }
            if !self.restoringReadingPosition, self.owner.actions?.matchesPresented(self.owner.snapshot) == true {
                self.owner.actions?.setPosition(self.position)
            }
            self.owner.lifecycle.schedule()
            self.changed?()
        }
    }
    func dispose() {
        detach()
        disposed = true; observers.removeAll(); pendingCommands = []; lastMessages = []; captured = nil; changed = nil
        (owner.scrollView.verticalScroller as? ChatTimelineScroller)?.beforeInput = nil
        table.navigate = nil; table.dismiss = nil
    }
}

/// Keep the standard native operation: interception adds only cancellation.
@MainActor final class ChatTimelineScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    var beforeInput: (() -> Void)?
    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        beforeInput?()
        super.setAccessibilityValue(accessibilityValue)
    }
    override func accessibilityPerformIncrement() -> Bool {
        beforeInput?()
        return super.accessibilityPerformIncrement()
    }
    override func accessibilityPerformDecrement() -> Bool {
        beforeInput?()
        return super.accessibilityPerformDecrement()
    }
}

private final class ChatTimelineScrollObservers {
    var tokens: [NSObjectProtocol] = []
    var monitor: Any?
    func removeAll() {
        tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    }
    deinit { removeAll() }
}
