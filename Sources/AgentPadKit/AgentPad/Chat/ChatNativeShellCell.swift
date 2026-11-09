import AppKit
import CoreText

/// Structural reuse IDs never contain a message ID or a mutable payload value.
enum ChatNativeShellKind: String, CaseIterable {
    case message, day, unread, older, notice, thread, request, inset
    init(_ payload: NativeTimelineSnapshot.Payload) {
        switch payload {
        case .message: self = .message
        case .day: self = .day
        case .unread: self = .unread
        case .olderControl: self = .older
        case .earlierUnread, .empty: self = .notice
        case .threadSummary: self = .thread
        case .legacyRequest: self = .request
        case .inset: self = .inset
        }
    }
    var identifier: NSUserInterfaceItemIdentifier { .init("chat-native-" + rawValue) }
}

@MainActor final class ChatNativeShellCell: NSTableCellView {
    struct Binding: Equatable {
        let id: NativeTimelineSnapshot.RowID
        let epoch: UUID
        let contentRevision: UInt64
        let reuseGeneration: UInt64
    }
    let header = ChatNativeLabel()
    let textDelegate: ChatMessageText.Coordinator
    let body: ChatMessageText.View
    let placeholder = ChatNativeLabel()
    let timestamp = ChatNativeLabel()
    let footnote = ChatNativeLabel()
    let actionButton = ChatNativeTextButton()
    let rowActions = ChatNativeRowActions()
    let inlineControls = ChatNativeInlineControls()
    let mainAvatar = ChatNativeAvatarView(frame: .zero)
    let attachments = ChatNativeAttachmentsView(frame: .zero)
    let replySummary = ChatNativeReplySummaryView(frame: .zero)
    let membership = ChatNativeMembershipView(frame: .zero)
    let metadata = ChatNativeMetadataView(frame: .zero)
    let sources = ChatNativeSourceView(frame: .zero)
    let request = ChatNativeRequestView(frame: .zero)
    private var active = false
    private(set) var binding: Binding?
    private(set) var plan: ChatTimelineRowLayoutPlan?
    private var generation: UInt64 = 0
    private var cancellations: [() -> Void] = []
    private var content: ChatTimelineShellContent?
    private var previousMessage: ChatMessage?
    weak var accessibilityEditor: ChatNativeEditorHost?
    var keyViewsChanged: (() -> Void)?
    #if DEBUG
    // Inspection exposes the exact operands used by draw(_:), never a rebuilt plan.
    var parityDrawContent: ChatTimelineShellContent? { content }
    var paritySelected: Bool { selected }
    var parityBackgroundColor: NSColor {
        selected || active ? content?.style.color("hover", fallback: .clear) ?? .clear : .clear
    }
    #endif
    private var renderedBody: NSAttributedString?
    private var renderedBodyInput: ChatTimelineShellContent.BodyInput?
    private var bodyNeedsSizing = true
    private var selected = false
    private var mediaVisible = false
    private var kind: ChatNativeShellKind
    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: max(newSize.width, plan?.renderedWidth ?? 0), height: newSize.height))
    }

    /// These are the drawing operands as well as the parity observer's source;
    /// avatar text must not be reconstructed with different font metrics.
    var avatarText: NSAttributedString? {
        guard let content, let avatar = content.avatar, let plan, !plan.avatar.isEmpty else { return nil }
        return ChatNativeTextStyle.label(avatar.letter,
            // SwiftUI resolves this custom font's requested 14.72 pt to 15 pt.
            font: ChatNativeTextStyle.font(content.style.metrics.displayFont, size: (plan.avatar.width * 0.46).rounded(),
                                           weight: .semibold), color: .white)
    }
    var avatarTextFrame: CGRect {
        avatarTextGeometry?.drawing ?? .zero
    }
    var avatarTextClip: CGRect { avatarTextFrame }
    var avatarTextTypographicFrame: CGRect { avatarTextGeometry?.typographic ?? .zero }
    private var avatarTextGeometry: (drawing: CGRect, typographic: CGRect)? {
        guard let plan, let text = avatarText else { return nil }
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let scale = plan.width.scale
        let measuredWidth = ceil(width * scale) / scale
        let x = ((plan.avatar.midX - measuredWidth / 2) * scale).rounded() / scale
        let baseline = ((plan.avatar.midY + (ascent - descent) / 2) * scale).rounded() / scale
        return (CGRect(x: x, y: baseline - ceil(ascent), width: measuredWidth, height: text.size().height),
                CGRect(x: x, y: baseline - ascent, width: width, height: ascent + descent + leading))
    }
    func drawAvatarText(in context: CGContext) {
        guard let text = avatarText else { return }
        // SwiftUI's text raster is placed on a backing pixel and clipped to its
        // measured width. Preserve that clipping for overhanging initials.
        context.saveGState()
        context.clip(to: avatarTextClip)
        text.draw(at: avatarTextFrame.origin)
        context.restoreGState()
    }

    init(kind: ChatNativeShellKind) {
        self.kind = kind
        let delegate = ChatMessageText.Coordinator()
        textDelegate = delegate
        body = ChatMessageText.makeView(delegate: delegate)
        super.init(frame: .zero)
        identifier = kind.identifier
        // The author Text draws inside its measured rectangle, including
        // negative-bearing antialias coverage at the left edge.
        header.clipsTextToBounds = true
        header.setAccessibilityElement(false)
        timestamp.setAccessibilityElement(false)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        for view in [header, body, placeholder, timestamp, footnote, actionButton, inlineControls,
                     attachments, replySummary, mainAvatar, membership, metadata, sources, request] { addSubview(view) }
        mainAvatar.imageChanged = { [weak self] in self?.needsDisplay = true }
        rowActions.changed = { [weak self] active in
            guard let self else { return }
            self.active = active
            self.timestamp.alphaValue = active || self.content?.style.alwaysShowTime == true ? 1 : 0
            self.needsDisplay = true
            self.keyViewsChanged?()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityChildren() -> [Any]? {
        guard binding != nil else { return [] }
        // The editor and hover controls live outside recyclable row views, but
        // belong to this message in the accessibility tree. Keep body order.
        var children: [NSView] = [body, placeholder]
        if let accessibilityEditor { children.append(accessibilityEditor) }
        children += [membership, footnote, attachments]
        children += inlineControls.accessibilityBeforeMetadata
        children.append(metadata)
        children += inlineControls.accessibilityAfterMetadata
        children += [sources, replySummary, request, actionButton]
        children += rowActions.toolbar.buttons
        return NSAccessibility.unignoredChildren(from: children.filter { !$0.isHiddenOrHasHiddenAncestor && !$0.frame.isEmpty })
    }

    func configure(row: NativeTimelineSnapshot.Row, epoch: UUID, plan: ChatTimelineRowLayoutPlan,
                   content: ChatTimelineShellContent, actions: ChatTimelineActions? = nil) {
        let sameIdentity = binding?.id == row.id && binding?.epoch == epoch
        if !sameIdentity { unbind() }
        if binding?.contentRevision != row.contentRevision || self.plan != plan {
            cancelWork()
            generation &+= 1
        }
        if self.plan?.width != plan.width || self.plan?.body.size != plan.body.size { bodyNeedsSizing = true }
        binding = .init(id: row.id, epoch: epoch, contentRevision: row.contentRevision, reuseGeneration: generation)
        self.plan = plan
        setFrameSize(NSSize(width: plan.renderedWidth, height: frame.height))
        self.content = content
        kind = ChatNativeShellKind(row.payload)
        setNavigationSelected(row.visual?.selected == true)
        header.text = content.header; header.toolTip = content.headerTooltip
        timestamp.text = content.timestamp; timestamp.toolTip = content.timeTooltip
        timestamp.alphaValue = selected || content.style.alwaysShowTime ? 1 : 0
        footnote.text = content.footnote
        body.isSelectable = content.selectable
        if content.selectable {
            // Match the representable's input cache, including address changes
            // that leave the rendered attributed string unchanged.
            if renderedBodyInput != content.bodyInput || renderedBody?.isEqual(to: content.body) != true {
                ChatMessageText.setContent(content.body, in: body)
                renderedBody = content.body
                renderedBodyInput = content.bodyInput
                if !bodyNeedsSizing, let container = body.textContainer, let manager = body.layoutManager {
                    manager.ensureLayout(for: container)
                    // A real late update can resize normalized rich text inside
                    // its existing reservation. Match SwiftUI's backing pixels.
                    let height = ceil(body.frame.height * plan.width.scale) / plan.width.scale
                    if body.frame.height != height { body.setFrameSize(NSSize(width: body.frame.width, height: height)) }
                }
            }
        } else { body.string = ""; renderedBody = nil; renderedBodyInput = nil; bodyNeedsSizing = true }
        if !sameIdentity { body.setSelectedRange(NSRange(location: 0, length: 0)) }
        placeholder.text = content.selectable ? NSAttributedString() : content.body
        actionButton.text = content.action
        actionButton.alignment = kind == .older ? .center : .left
        actionButton.setAccessibilityRole(kind == .unread ? .button : .link)
        switch row.payload {
        case .unread: actionButton.invoke = { [weak actions] in actions?.markRead() }
        case .olderControl: actionButton.invoke = { [weak actions] in actions?.loadOlder() }
        default: actionButton.invoke = nil
        }
        setAccessibilityLabel(content.accessibilityLabel.isEmpty ? nil : content.accessibilityLabel)
        setAccessibilityIdentifier(row.messageID.map { "chat-message:" + $0 })
        if case .message(let message) = row.payload {
            if let previousMessage, let announcement = ChatAccessibility.delivery(from: previousMessage, to: message.content.message) {
                ChatAccessibility.announce(announcement, in: self)
            }
            previousMessage = message.content.message
        }
        needsLayout = true; needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let plan else { return }
        header.frame = plan.header; header.isHidden = plan.header.height == 0
        if bodyNeedsSizing, renderedBody != nil, let container = body.textContainer, let manager = body.layoutManager {
            container.containerSize = NSSize(width: plan.body.width, height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            body.frame = plan.body
            // Initial mount and width changes install sizeThatFits' whole-point
            // reservation. Layout alone must not synthesize an input refresh.
            bodyNeedsSizing = false
        } else if content?.selectable == true {
            body.setFrameOrigin(plan.body.origin)
        } else {
            body.frame = plan.body
        }
        body.isHidden = plan.body.height == 0 || content?.selectable != true || !plan.editor.isEmpty
        placeholder.frame = plan.body; placeholder.isHidden = plan.body.height == 0 || content?.selectable == true || !plan.editor.isEmpty
        timestamp.frame = plan.timestamp; timestamp.isHidden = plan.timestamp.height == 0
        footnote.frame = plan.footnote; footnote.isHidden = plan.footnote.height == 0
        actionButton.frame = plan.action; actionButton.isHidden = plan.action.height == 0
        inlineControls.frame = bounds
        attachments.frame = bounds
        membership.frame = plan.membership?.frame ?? .zero
        metadata.frame = plan.metadata?.frame ?? .zero
        sources.frame = plan.sources?.frame ?? .zero
        request.frame = plan.request?.frame ?? .zero
        mainAvatar.frame = plan.avatar; mainAvatar.isHidden = plan.avatar.isEmpty
        refreshMediaVisibility()
        rowActions.layout()
    }

    func configureActions(row: NativeTimelineSnapshot.Row, snapshot: NativeTimelineSnapshot, actions: ChatTimelineActions?, layer: ChatNativeDocumentLayer) {
        rowActions.configure(cell: self, row: row, snapshot: snapshot, actions: actions, layer: layer)
        rowActions.setSelected(selected)
        if case .message(let message) = row.payload, let accessories = plan?.accessories {
            request.unbind()
            inlineControls.configure(accessories, message: message, style: snapshot.style, actions: actions)
            if let plan = plan?.membership {
                membership.configure(plan, messageID: message.content.message.id, style: snapshot.style, actions: actions)
            }
            if let plan = plan?.metadata { metadata.configure(plan, row: row, snapshot: snapshot, actions: actions) }
            if let plan = plan?.sources { sources.configure(plan, row: row, snapshot: snapshot, actions: actions) }
            if let plan = plan?.attachments, let binding {
                attachments.configure(plan, messageID: message.content.message.id, owner: binding, style: snapshot.style, actions: actions)
            }
            if let plan = plan?.replySummary, let binding {
                replySummary.configure(plan: plan, row: row, snapshot: snapshot, actions: actions, ownerBinding: binding)
            }
            if let placeholder = content?.avatar, let binding {
                mainAvatar.imageChanged = { [weak self] in self?.needsDisplay = true }
                mainAvatar.configure(placeholder: placeholder, source: row.visual?.avatars.first, owner: binding,
                    style: snapshot.style, service: actions?.avatarService(messageID: message.content.message.id), fallback: .shell)
            } else { mainAvatar.unbind() }
        } else {
            inlineControls.unbind(); membership.unbind(); metadata.unbind(); sources.unbind()
            if case .legacyRequest(let value) = row.payload, let plan = plan?.request {
                request.configure(plan, request: value, style: snapshot.style, actions: actions)
            } else { request.unbind() }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if kind == .message {
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }
    override func mouseEntered(with event: NSEvent) { rowActions.hover(true) }
    override func mouseExited(with event: NSEvent) { rowActions.hover(false) }
    override func menu(for event: NSEvent) -> NSMenu? { rowActions.makeMenu() }

    func setNavigationSelected(_ value: Bool) {
        guard value != selected else { return }
        selected = value
        rowActions.setSelected(value)
        replySummary.setNavigationSelected(value)
        timestamp.alphaValue = value || content?.style.alwaysShowTime == true ? 1 : 0
        setAccessibilitySelected(value)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let plan, let content else { return }
        let style = content.style
        if selected || active {
            style.color("hover", fallback: .clear).setFill(); bounds.fill()
        }
        if selected {
            style.color("accent").setFill(); CGRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        }
        let rule = kind == .unread ? style.color("attention").withAlphaComponent(0.45) : style.color("hairline")
        rule.setFill(); plan.rules.forEach { $0.fill() }
        if !plan.capsule.isEmpty {
            style.color("hairline").setStroke()
            let rect = plan.capsule.insetBy(dx: 0.5, dy: 0.5)
            if let context = NSGraphicsContext.current?.cgContext {
                context.addPath(ChatNativeShapes.roundedRect(rect, radius: rect.height / 2))
                context.setLineWidth(1); context.strokePath()
            }
        }
        if !plan.badge.isEmpty {
            style.color("foreground").withAlphaComponent(0.19).setStroke()
            if let context = NSGraphicsContext.current?.cgContext {
                context.addPath(ChatNativeShapes.roundedRect(plan.badge.insetBy(dx: 0.5, dy: 0.5), radius: 3.5))
                context.setLineWidth(1); context.strokePath()
            }
            content.badge.draw(in: plan.badge.insetBy(dx: 4, dy: 1))
        }
        if let avatar = content.avatar, !plan.avatar.isEmpty, !mainAvatar.hasImage {
            let rgb = avatar.color(isLight: style.color("surface").relativeLuminance > 0.55)
            NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                    blue: CGFloat(rgb & 255) / 255, alpha: 1).setFill()
            let radius = avatar.cornerRadius(size: plan.avatar.width)
            if avatar.kind == .person { NSGraphicsContext.current?.cgContext.fillEllipse(in: plan.avatar) }
            else if let context = NSGraphicsContext.current?.cgContext {
                context.addPath(ChatNativeShapes.roundedRect(plan.avatar, radius: radius)); context.fillPath()
            }
            if let context = NSGraphicsContext.current?.cgContext { drawAvatarText(in: context) }
        }
    }

    /// Register cancellation of cell-owned observation/rendering only. A user
    /// download or model edit is never owned or cancelled by a recyclable cell.
    func cancelOnUnbind(_ cancel: @escaping () -> Void) { cancellations.append(cancel) }

    @discardableResult func apply(ifCurrent expected: Binding, _ update: (ChatNativeShellCell) -> Void) -> Bool {
        guard binding == expected else { return false }
        update(self)
        return true
    }

    func unbind() {
        keyViewsChanged = nil
        if accessibilityEditor?.accessibilityOwner === self { accessibilityEditor?.accessibilityOwner = nil }
        accessibilityEditor = nil; previousMessage = nil
        mediaVisible = false
        mainAvatar.unbind(); attachments.unbind(); replySummary.unbind()
        membership.unbind(); metadata.unbind(); sources.unbind(); request.unbind()
        rowActions.unbind(); inlineControls.unbind()
        cancelWork(); generation &+= 1
        binding = nil; plan = nil; content = nil; renderedBody = nil; renderedBodyInput = nil; bodyNeedsSizing = true
        setNavigationSelected(false)
        toolTip = nil; menu = nil
        setAccessibilityLabel(nil); setAccessibilityHelp(nil); setAccessibilityIdentifier(nil)
        header.clipsTextToBounds = true
        header.text = NSAttributedString(); header.toolTip = nil
        body.string = ""; body.setSelectedRange(NSRange(location: 0, length: 0)); body.toolTip = nil
        placeholder.text = NSAttributedString(); timestamp.text = NSAttributedString(); timestamp.toolTip = nil
        footnote.text = NSAttributedString(); actionButton.text = NSAttributedString(); actionButton.invoke = nil
        for area in trackingAreas { removeTrackingArea(area) }
    }

    func setMediaVisible(_ visible: Bool) {
        mediaVisible = visible
        refreshMediaVisibility()
    }
    private func refreshMediaVisibility() {
        mainAvatar.setVisible(mediaVisible && plan?.avatar.isEmpty == false
            && mainAvatar.bounds.intersects(mainAvatar.visibleRect))
        attachments.setVisible(mediaVisible)
        replySummary.setVisible(mediaVisible)
        metadata.setVisible(mediaVisible)
    }

    private func cancelWork() {
        let work = cancellations; cancellations.removeAll()
        work.forEach { $0() }
    }
}

@MainActor final class ChatNativeShellRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
}
