import AppKit
import SwiftUI

/// Native timeline mounted by the shared product wrapper.
struct NativeChatTimelineRepresentable: NSViewRepresentable {
    let snapshot: NativeTimelineSnapshot
    var actions: ChatTimelineActions? = nil

    func makeCoordinator() -> NativeChatTimelineCoordinator { NativeChatTimelineCoordinator() }
    func makeNSView(context: Context) -> NativeChatTimelineContainer {
        context.coordinator.actions = actions
        let view = NativeChatTimelineContainer(coordinator: context.coordinator)
        view.update(snapshot)
        return view
    }
    func updateNSView(_ view: NativeChatTimelineContainer, context: Context) {
        context.coordinator.actions = actions
        view.update(snapshot)
    }
    static func dismantleNSView(_ view: NativeChatTimelineContainer, coordinator: NativeChatTimelineCoordinator) { coordinator.dispose() }
}

@MainActor final class NativeChatTimelineContainer: NSView {
    let coordinator: NativeChatTimelineCoordinator
    private var latest: NativeTimelineSnapshot?
    let focusBorder = ChatNativeTimelineFocusBorder()
    #if DEBUG
    var paritySurfaceColor: NSColor {
        latest.map { $0.style.color("surface", fallback: .windowBackgroundColor) } ?? .windowBackgroundColor
    }
    #endif
    init(coordinator: NativeChatTimelineCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        addSubview(coordinator.scrollView)
        addSubview(focusBorder)
        coordinator.lifecycle.bind(self)
        coordinator.tableView.focusChanged = { [weak self] focused in self?.focusBorder.focused = focused }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ snapshot: NativeTimelineSnapshot) {
        latest = snapshot
        focusBorder.color = snapshot.style.color("accent")
        needsLayout = true; needsDisplay = true
        layoutSubtreeIfNeeded()
    }
    override func draw(_ dirtyRect: NSRect) {
        let surface = latest?.style.colors["surface"]
        let color = surface.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) } ?? .windowBackgroundColor
        // AppKit may request an extended dirty region while the representable
        // is composited. The timeline's background must not cover its siblings.
        color.setFill(); dirtyRect.intersection(bounds).fill()
    }
    override func layout() {
        super.layout()
        let update = { [self] in
            coordinator.scrollView.frame = bounds
            focusBorder.frame = bounds
            coordinator.scrollView.tile()
            if let latest, bounds.width > 0 {
                coordinator.update(latest, width: coordinator.scrollView.contentSize.width)
            }
        }
        if coordinator.scrollView.frame != bounds { coordinator.scrollController.transaction(update) }
        else { update() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, window !== newWindow { coordinator.windowWillDetach() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { coordinator.windowDidAttach() }
    }
    override func viewDidHide() {
        super.viewDidHide()
        coordinator.lifecycle.hidden()
        coordinator.refreshMediaVisibility(forceHidden: true)
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        // Ancestor visibility and AppKit's available row views settle after
        // this callback. Recheck once on the next turn, using the live window.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            self.coordinator.refreshMediaVisibility()
            self.coordinator.scrollController.resumePendingCommands()
            self.coordinator.lifecycle.schedule()
        }
    }
}

@MainActor final class NativeChatTimelineCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Ticket: Equatable, Sendable {
        let serial: UInt64
        let conversation: NativeTimelineSnapshot.Conversation
        let epoch: UUID
        let generation: UInt64
        let width: ChatTimelineWidth
    }
    struct Request: Sendable {
        let ticket: Ticket
        let snapshot: NativeTimelineSnapshot
        let inputGeneration: UInt64
        let navigationGeneration: UInt64
    }
    struct Prepared: Sendable {
        let request: Request
        let plans: [NativeTimelineSnapshot.RowID: ChatTimelineRowLayoutPlan]
    }
    let scrollView = NSScrollView()
    let tableView = ChatNativeTableView()
    let editorLayer = ChatNativeDocumentLayer()
    private(set) var editorSession: NativeInlineEditorSession?
    private var suppressEditEndFocus = false
    private var windowDetached = false
    var defersModelFocus: Bool { windowDetached || tableView.window == nil || tableView.isHiddenOrHasHiddenAncestor }
    var permitsModelFocus: Bool {
        !defersModelFocus && !suppressEditEndFocus
    }
    lazy var scrollController = ChatTimelineScrollController(owner: self)
    lazy var lifecycle = ChatTimelineLifecycle(owner: self)
    weak var actions: ChatTimelineActions? {
        didSet {
            if oldValue !== actions { oldValue?.jumpToLatest = nil; lifecycle.actionsChanged() }
            actions?.jumpToLatest = { [weak self] in self?.scrollController.jumpToLatest() }
        }
    }
    let layoutEngine: ChatTimelineLayout
    private(set) var snapshot: NativeTimelineSnapshot?
    private(set) var rows: [NativeTimelineSnapshot.Row] = []
    private(set) var indexes: [NativeTimelineSnapshot.RowID: Int] = [:]
    private(set) var plans: [NativeTimelineSnapshot.RowID: ChatTimelineRowLayoutPlan] = [:]
    private(set) var fullReloads = 0
    private(set) var cellsCreated = 0
    private(set) var cellsReused = 0
    private(set) var lastDifference: ChatTimelineDifference?
    private var serial: UInt64 = 0
    private var latestTicket: Ticket?
    private var appliedTicket: Ticket?
    private var layoutWidth: ChatTimelineWidth?
    private var applying = false
    private var pending: Request?
    private var disposed = false
    var presentationIsReady: Bool { !disposed && !applying && appliedTicket != nil && appliedTicket == latestTicket }

    init(layout: ChatTimelineLayout = ChatTimelineLayout()) {
        layoutEngine = layout
        super.init()
        let column = NSTableColumn(identifier: .init("chat-timeline"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.intercellSpacing = .zero
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.backgroundColor = .clear
        tableView.dataSource = self; tableView.delegate = self
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = ChatTimelineScroller()
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = tableView
        tableView.addSubview(editorLayer)
        tableView.documentLayer = editorLayer
        tableView.geometryChanged = { [weak self] in self?.layoutDocumentLayer() }
        tableView.keyViews = { [weak self] in
            guard let self, !self.disposed, !self.windowDetached else { return [] }
            var children: [Any] = []
            var available: [(Int, ChatNativeShellCell)] = []
            self.tableView.enumerateAvailableRowViews { row, index in
                for cell in row.subviews.compactMap({ $0 as? ChatNativeShellCell }) {
                    available.append((index, cell))
                }
            }
            for (_, cell) in available.sorted(by: { $0.0 < $1.0 }) { children += cell.accessibilityChildren() ?? [] }
            if let host = self.editorSession?.host, host.accessibilityOwner == nil { children.append(host) }
            return children
        }
        _ = scrollController
    }

    /// Start a value-only preparation. The serial fences delayed work even when
    /// a reset returns to the same conversation, epoch, generation or width.
    func begin(_ snapshot: NativeTimelineSnapshot, width: CGFloat) -> Request? {
        guard !disposed, Set(snapshot.rowIDs).count == snapshot.rows.count,
              snapshot.rows.allSatisfy({ $0.id.conversation == snapshot.conversation }) else { return nil }
        if let latestTicket, latestTicket.conversation == snapshot.conversation, latestTicket.epoch == snapshot.presentationEpoch,
           snapshot.generation < latestTicket.generation { return nil }
        serial &+= 1
        let ticket = Ticket(serial: serial, conversation: snapshot.conversation, epoch: snapshot.presentationEpoch,
            generation: snapshot.generation, width: ChatTimelineWidth(width, scale: snapshot.style.metrics.scale))
        latestTicket = ticket
        return .init(ticket: ticket, snapshot: snapshot, inputGeneration: scrollController.inputGeneration,
                     navigationGeneration: scrollController.navigationGeneration)
    }

    func prepare(_ request: Request) -> Prepared? {
        guard !disposed, latestTicket == request.ticket else { return nil }
        let samePresentation = snapshot?.conversation == request.snapshot.conversation
            && snapshot?.presentationEpoch == request.snapshot.presentationEpoch
        // Current table geometry outlives the bounded LRU. Do no TextKit work
        // here: missing plans are resolved when AppKit requests a row's height.
        let plans = Dictionary(uniqueKeysWithValues: request.snapshot.rows.compactMap { row -> (NativeTimelineSnapshot.RowID, ChatTimelineRowLayoutPlan)? in
            guard samePresentation, let plan = self.plans[row.id],
                  plan.width == request.ticket.width, plan.layoutRevision == row.layoutRevision else { return nil }
            return (row.id, plan)
        })
        return .init(request: request, plans: plans)
    }

    @discardableResult func update(_ snapshot: NativeTimelineSnapshot, width: CGFloat) -> Bool {
        let normalized = ChatTimelineWidth(width, scale: snapshot.style.metrics.scale)
        if self.snapshot == snapshot, appliedTicket?.width == normalized, latestTicket == appliedTicket { return false }
        guard let request = begin(snapshot, width: width) else { return false }
        if applying { pending = request; return false }
        guard let prepared = prepare(request) else { return false }
        return commit(prepared)
    }

    @discardableResult func commit(_ prepared: Prepared) -> Bool {
        let request = prepared.request, next = request.snapshot
        guard !disposed, !applying, latestTicket == request.ticket,
              appliedTicket != request.ticket,
              let difference = ChatTimelineDifference(from: rows.map(\.id), to: next.rowIDs) else { return false }
        applying = true
        defer {
            applying = false
            suppressEditEndFocus = false
            lifecycle.schedule()
            if let pending {
                self.pending = nil
                if let prepared = prepare(pending) { _ = commit(prepared) }
            }
        }
        let reset = snapshot?.conversation != next.conversation || snapshot?.presentationEpoch != next.presentationEpoch
        let widthChanged = appliedTicket?.width != request.ticket.width
        let changed = IndexSet(next.rows.indices.filter { index in
            guard let previous = indexes[next.rows[index].id] else { return true }
            return widthChanged || rows[previous].layoutRevision != next.rows[index].layoutRevision
        })
        scrollController.transaction(preservingGeometry: !reset && (!difference.operations.isEmpty || !changed.isEmpty)) {
            let newRows = Dictionary(uniqueKeysWithValues: next.rows.map { ($0.id, $0) })
            snapshot = next
            layoutWidth = request.ticket.width
            // Keep the sequential indexes during AppKit's structural callbacks,
            // but measure retained identities using their incoming content.
            rows = rows.map { newRows[$0.id] ?? $0 }
            if reset { plans = prepared.plans }
            else { plans.merge(prepared.plans) { _, new in new } }
            tableView.tableColumns[0].width = request.ticket.width.points
            tableView.setFrameSize(NSSize(width: request.ticket.width.points, height: tableView.frame.height))
            tableView.setAccessibilityLabel(next.state.accessibilityLabel)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0; context.allowsImplicitAnimation = false
                if reset {
                    unbindVisibleCells()
                    rows = next.rows; rebuildIndexes()
                    tableView.reloadData(); fullReloads += 1
                } else {
                    tableView.beginUpdates()
                    for operation in difference.operations {
                        switch operation {
                        case .remove(let index):
                            rows.remove(at: index); rebuildIndexes()
                            tableView.removeRows(at: IndexSet(integer: index), withAnimation: [])
                        case .insert(let index, let id):
                            rows.insert(newRows[id]!, at: index); rebuildIndexes()
                            tableView.insertRows(at: IndexSet(integer: index), withAnimation: [])
                        case .move(let source, let destination):
                            rows.insert(rows.remove(at: source), at: destination); rebuildIndexes()
                            tableView.moveRow(at: source, to: destination)
                        }
                    }
                    rows = next.rows; rebuildIndexes()
                    if !changed.isEmpty { tableView.noteHeightOfRows(withIndexesChanged: changed) }
                    tableView.endUpdates()
                }
                // Preserve plans filled by height callbacks, dropping removed or
                // invalidated offscreen geometry instead of retaining stale plans.
                plans = plans.filter { id, plan in
                    newRows[id]?.layoutRevision == plan.layoutRevision && plan.width == request.ticket.width
                }
                tableView.layoutSubtreeIfNeeded()
                for index in rows.indices {
                    if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell {
                        configure(cell, at: index)
                    }
                }
            }
            appliedTicket = request.ticket
            lastDifference = difference
            layoutEngine.retain(snapshot: next)
            synchronizeEditor(reset: reset)
            scrollController.applied(next, reset: reset, requestInput: request.inputGeneration,
                                     requestNavigation: request.navigationGeneration)
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { layoutPlan(at: row)?.height ?? 1 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let kind = ChatNativeShellKind(rows[row].payload)
        let cell: ChatNativeShellCell
        if let reused = tableView.makeView(withIdentifier: kind.identifier, owner: self) as? ChatNativeShellCell {
            cell = reused; cellsReused += 1
        } else { cell = ChatNativeShellCell(kind: kind); cellsCreated += 1 }
        configure(cell, at: row)
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ChatNativeShellRowView() }
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        for cell in rowView.subviews.compactMap({ $0 as? ChatNativeShellCell }) { cell.unbind() }
    }
    private func configure(_ cell: ChatNativeShellCell, at index: Int) {
        guard let snapshot, let plan = layoutPlan(at: index) else { return }
        cell.configure(row: rows[index], epoch: snapshot.presentationEpoch, plan: plan,
                       content: layoutEngine.content(rows[index], snapshot: snapshot, width: plan.width), actions: actions)
        cell.configureActions(row: rows[index], snapshot: snapshot, actions: actions, layer: editorLayer)
        cell.keyViewsChanged = { [weak self] in self?.tableView.rebuildKeyViewLoop() }
        if let editorSession, editorSession.identity == rows[index].id {
            cell.accessibilityEditor = editorSession.host
            editorSession.host.accessibilityOwner = cell
        }
        cell.setNavigationSelected((rows[index].messageID != nil && rows[index].messageID == scrollController.selectedID) || rows[index].visual?.selected == true)
        cell.setMediaVisible(mediaVisible(at: index))
        if case .olderControl = rows[index].payload {
            cell.actionButton.invoke = { [weak self] in
                self?.scrollController.stopFollowing(preservingAnchor: true)
                self?.actions?.loadOlder()
            }
        }
    }
    func layoutPlan(at index: Int) -> ChatTimelineRowLayoutPlan? {
        guard rows.indices.contains(index), let snapshot, let width = layoutWidth else { return nil }
        let row = rows[index]
        if let plan = plans[row.id], plan.width == width, plan.layoutRevision == row.layoutRevision { return plan }
        let plan = layoutEngine.plan(row, snapshot: snapshot, width: width)
        plans[row.id] = plan
        return plan
    }
    private func rebuildIndexes() { indexes = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) }) }
    private func synchronizeEditor(reset: Bool) {
        guard !windowDetached else { return }
        let target = rows.first { row in
            guard case .message(let message) = row.payload else { return false }
            return message.content.editing != nil && !message.content.message.deleted
        }
        if reset || editorSession?.identity != target?.id {
            if let editorSession {
                suppressEditEndFocus = !editorSession.ownsFocus
                editorSession.dispose(); self.editorSession = nil
            }
        }
        guard let target, case .message(let message) = target.payload, let draft = message.content.editing,
              actions?.activeEditing(messageID: draft.messageId) != nil else {
            if let editorSession {
                suppressEditEndFocus = !editorSession.ownsFocus
                editorSession.dispose(); self.editorSession = nil
            }
            return
        }
        if editorSession == nil {
            editorSession = NativeInlineEditorSession(identity: target.id, draft: draft, actions: actions)
        }
        layoutDocumentLayer()
        editorSession?.attach(to: editorLayer)
    }
    private func layoutDocumentLayer() {
        defer { tableView.rebuildKeyViewLoop() }
        editorLayer.frame = tableView.bounds
        guard let editorSession, let snapshot, let index = indexes[editorSession.identity],
              case .message(let message) = rows[index].payload, let draft = message.content.editing,
              let plan = layoutPlan(at: index), let footer = plan.editorFooter else { return }
        let frame = plan.editor.offsetBy(dx: 0, dy: tableView.rect(ofRow: index).minY)
        editorSession.update(draft, message: message, style: snapshot.style, frame: frame, footer: footer)
        if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell {
            cell.accessibilityEditor = editorSession.host
            editorSession.host.accessibilityOwner = cell
        }
    }
    func messageIndex(_ id: String) -> Int? {
        guard let snapshot else { return nil }
        return indexes[.init(conversation: snapshot.conversation, kind: .message(id))]
    }
    func refreshSelection() {
        for index in rows.indices {
            (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell)?
                .setNavigationSelected((rows[index].messageID != nil && rows[index].messageID == scrollController.selectedID) || rows[index].visual?.selected == true)
        }
        tableView.rebuildKeyViewLoop()
    }
    private func unbindVisibleCells() {
        for index in rows.indices {
            (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell)?.unbind()
        }
    }
    private func mediaVisible(at index: Int) -> Bool {
        !windowDetached && tableView.window != nil && !tableView.isHiddenOrHasHiddenAncestor
            && tableView.rect(ofRow: index).intersects(scrollView.contentView.bounds)
    }
    /// AppKit may retain prefetched or hidden cells. Visibility is supplied by
    /// the existing scroll observer, never by height measurement or per-cell
    /// timers/notifications, and does not instantiate an offscreen row.
    func refreshMediaVisibility(forceHidden: Bool = false) {
        guard !disposed else { return }
        tableView.enumerateAvailableRowViews { [self] row, index in
            for cell in row.subviews.compactMap({ $0 as? ChatNativeShellCell }) {
                cell.setMediaVisible(!forceHidden && mediaVisible(at: index))
            }
        }
    }
    func windowWillDetach() {
        guard !disposed else { return }
        // Engine hosts are retained while moving between panes and popups.
        // End the attached presentation, keeping the controller reusable.
        windowDetached = true
        tableView.rebuildKeyViewLoop()
        lifecycle.detach()
        scrollController.detach()
        editorSession?.dispose(); editorSession = nil
        unbindVisibleCells()
    }
    func windowDidAttach() {
        guard !disposed else { return }
        scrollController.attach()
        lifecycle.attached()
        defer {
            refreshMediaVisibility(); scrollController.resumePendingCommands()
            tableView.window?.recalculateKeyViewLoop()
        }
        guard windowDetached else { return }
        windowDetached = false
        // The snapshot may be identical, so update's diff fast path cannot be
        // responsible for recreating presentation callbacks or the editor.
        for index in rows.indices {
            if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell {
                configure(cell, at: index)
            }
        }
        synchronizeEditor(reset: false)
    }
    func dispose() {
        guard !disposed else { return }
        lifecycle.dispose()
        disposed = true; serial &+= 1; latestTicket = nil; pending = nil
        scrollController.dispose()
        editorSession?.dispose(); editorSession = nil
        tableView.geometryChanged = nil; tableView.documentLayer = nil
        tableView.focusChanged = nil
        tableView.keyViews = nil; tableView.rebuildKeyViewLoop()
        actions?.jumpToLatest = nil
        editorLayer.removeFromSuperview()
        unbindVisibleCells()
        tableView.delegate = nil; tableView.dataSource = nil
        rows.removeAll(); indexes.removeAll(); plans.removeAll(); snapshot = nil; layoutWidth = nil
        layoutEngine.removeAll()
    }
}
