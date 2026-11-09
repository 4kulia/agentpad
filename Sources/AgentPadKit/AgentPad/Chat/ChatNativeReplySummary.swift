import AppKit

/// Immutable inputs shared by the production draw path and capture observation.
@MainActor struct ChatNativeReplyTextOperand {
    let id: String
    let text: NSAttributedString
    let frame: CGRect
    func draw() { text.draw(with: frame, options: [.usesLineFragmentOrigin]) }
}

@MainActor struct ChatNativeReplyImageOperand {
    let image: NSImage
    let frame: CGRect
    let drawingFrame: CGRect
    let color: NSColor
    func draw() {
        image.draw(in: drawingFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

@MainActor struct ChatNativeReplyFillOperand {
    let frame: CGRect
    let color: NSColor
    let cornerRadius: CGFloat
    func draw(in context: CGContext) {
        color.setFill()
        context.addPath(ChatNativeShapes.roundedRect(frame, radius: cornerRadius)); context.fillPath()
    }
}

/// Cell-coordinate operands only. Measuring replies never obtains a service,
/// registers an avatar consumer, or starts a read.
struct ChatNativeReplySummaryLayout: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case local, server }
    struct Participant: Equatable, Sendable {
        let identity: ChatAuthorIdentity
        let name: String
        let reference: ChatAvatarReference
        let frame: CGRect
    }
    let kind: Kind?
    let frame: CGRect
    let bottom: CGFloat
    let summaryFrame: CGRect
    let participants: [Participant]
    let label: String
    let labelFrame: CGRect
    let unread: String
    let unreadFrame: CGRect
    let unreadTextFrame: CGRect
    let latest: String
    let latestFrame: CGRect
    let chevronFrame: CGRect
    let request: String
    let requestFrame: CGRect
    let help: String
    let accessibilityLabel: String

    @MainActor static func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular,
                               color: NSColor, style: NativeTimelineSnapshot.Style) -> NSAttributedString {
        ChatNativeTextStyle.label(value, font: ChatNativeTextStyle.font(style.metrics.displayFont, size: size, weight: weight), color: color)
    }
    @MainActor static func chevron(style: NativeTimelineSnapshot.Style) -> NSImage? {
        NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
                .applying(.init(paletteColors: [style.color("accent")])))
    }

    @MainActor init(message: NativeTimelineSnapshot.Message, snapshot: NativeTimelineSnapshot, body: CGRect) {
        let content = message.content, style = snapshot.style, scale = style.metrics.scale
        var kind: Kind?, identities: [(ChatAuthorIdentity, String)] = []
        var label = "", latest: Date?, help = "", names = ""
        if !message.inThread {
            if content.metadata?.summarySupported == true, let summary = content.metadata?.value?.threadSummary {
                if summary.replyCount > 0 {
                    kind = .server; label = summary.label; latest = summary.lastReplyAt.flatMap(ChatFeedLayout.date)
                    help = "Open thread"
                    identities = summary.lastParticipants.map { participant in
                        (participant.identity, participant.authorAgentName ?? participant.authorSessionName
                         ?? snapshot.members.first { $0.accountId == participant.authorAccountId }?.name ?? "Former member")
                    }
                    names = identities.map(\.1).joined(separator: ", ")
                } else if content.unreadReplyCount > 0, let summary = content.replySummary, summary.count > 0 {
                    kind = .local; label = summary.label; latest = summary.latest.flatMap { ChatFeedLayout.date($0.createdAt) }
                    help = summary.complete ? "Open thread" : "Loaded replies · more may exist"
                    identities = summary.participants.map { participant in
                        (ChatAuthorIdentity(participant), snapshot.members.first { $0.accountId == participant.authorAccountId }?.name ?? "?")
                    }
                }
            } else if let summary = content.replySummary, summary.count > 0 {
                kind = .local; label = summary.label; latest = summary.latest.flatMap { ChatFeedLayout.date($0.createdAt) }
                help = summary.complete ? "Open thread" : "Loaded replies · more may exist"
                identities = summary.participants.map { participant in
                    (ChatAuthorIdentity(participant), snapshot.members.first { $0.accountId == participant.authorAccountId }?.name ?? "?")
                }
            }
        }
        let unread = kind != nil && content.unreadReplyCount > 0 ? "\(content.unreadReplyCount) new" : ""
        let latestText = latest.map { date in
            date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: style.metrics.locale,
                                           calendar: style.metrics.calendar, timeZone: style.metrics.calendar.timeZone))
        } ?? ""
        let request = !message.inThread && content.requestCount > 0
            ? "\(content.requestCount) \(content.requestCount == 1 ? "request" : "requests") to agents" : ""
        func measure(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular,
                     width: CGFloat = .greatestFiniteMagnitude) -> CGSize {
            ChatNativeTextStyle.size(Self.text(value, size: size, weight: weight, color: .labelColor, style: style), width: width, scale: scale)
        }
        var y = body.maxY
        var summaryFrame = CGRect.zero, labelFrame = CGRect.zero, unreadFrame = CGRect.zero
        var unreadTextFrame = CGRect.zero, latestFrame = CGRect.zero, chevronFrame = CGRect.zero
        var participants: [Participant] = []
        if kind != nil {
            let avatarWidth = identities.isEmpty ? 0 : CGFloat(identities.count) * 21 - CGFloat(identities.count - 1) * 4
            let latestSize = measure(latestText, size: 9)
            let symbol = Self.chevron(style: style)
            let chevronSize = CGSize(width: symbol?.alignmentRect.width ?? 0, height: symbol?.size.height ?? 0)
            let gaps = CGFloat(2 + (unread.isEmpty ? 0 : 1) + (latestText.isEmpty ? 0 : 1)) * 8
            let flexibleWidth = max(1, body.width - avatarWidth - latestSize.width - chevronSize.width - gaps)
            // Both the label and unread text are flexible in the legacy HStack.
            // Propose the badge's share before measuring the remaining label;
            // its declared horizontal padding is six points on each side.
            let badgeHorizontalPadding: CGFloat = 12
            let unreadSize = measure(unread, size: 11, weight: .semibold,
                                     width: max(1, flexibleWidth / 2 - badgeHorizontalPadding))
            let badgeSize = unread.isEmpty ? CGSize.zero
                : CGSize(width: unreadSize.width + badgeHorizontalPadding, height: unreadSize.height + 4)
            let labelSize = measure(label, size: 11, weight: .medium,
                                    width: max(1, flexibleWidth - badgeSize.width))
            let height = [identities.isEmpty ? 0 : CGFloat(21), labelSize.height, badgeSize.height, latestSize.height, chevronSize.height].max() ?? 0
            y += 3
            let top = y + 5
            var x = body.minX
            for (identity, name) in identities {
                let ref = ChatAvatarReference(key: snapshot.conversation.key, subject: identity.agent.map { .agent($0) } ?? .account(identity.account))
                participants.append(.init(identity: identity, name: name, reference: ref,
                                          frame: CGRect(x: x, y: top + (height - 21) / 2, width: 21, height: 21)))
                x += 17
            }
            x = body.minX + avatarWidth + 8
            labelFrame = CGRect(x: x, y: top + (height - labelSize.height) / 2, width: labelSize.width, height: labelSize.height)
            x = labelFrame.maxX + 8
            if !unread.isEmpty {
                unreadFrame = CGRect(x: x, y: top + (height - badgeSize.height) / 2, width: badgeSize.width, height: badgeSize.height)
                unreadTextFrame = unreadFrame.insetBy(dx: 6, dy: 2)
                x = unreadFrame.maxX + 8
            }
            if !latestText.isEmpty {
                latestFrame = CGRect(x: x, y: top + (height - latestSize.height) / 2, width: latestSize.width, height: latestSize.height)
                x = latestFrame.maxX + 8
            }
            chevronFrame = CGRect(x: x, y: top + (height - chevronSize.height) / 2, width: chevronSize.width, height: chevronSize.height)
            summaryFrame = CGRect(x: body.minX, y: y, width: chevronFrame.maxX - body.minX, height: height + 10)
            y = summaryFrame.maxY
        }
        var requestFrame = CGRect.zero
        if !request.isEmpty {
            y += 3
            let size = measure(request, size: 10, width: body.width)
            requestFrame = CGRect(x: body.minX, y: y, width: size.width, height: size.height)
            y = requestFrame.maxY
        }
        self.kind = kind; self.bottom = y
        self.frame = summaryFrame.isEmpty ? requestFrame : requestFrame.isEmpty ? summaryFrame : summaryFrame.union(requestFrame)
        self.summaryFrame = summaryFrame; self.participants = participants
        self.label = label; self.labelFrame = labelFrame
        self.unread = unread; self.unreadFrame = unreadFrame; self.unreadTextFrame = unreadTextFrame
        self.latest = latestText; self.latestFrame = latestFrame; self.chevronFrame = chevronFrame
        self.request = request; self.requestFrame = requestFrame; self.help = help
        self.accessibilityLabel = kind == nil ? "" : label + (content.unreadReplyCount > 0 ? ", \(content.unreadReplyCount) new" : "")
            + (kind == .server ? ", " + names : "") + ", open thread"
    }
}

@MainActor private final class ChatNativeReplyAvatarBorder: NSView {
    var color = NSColor.clear
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        color.setStroke()
        context.addPath(ChatNativeShapes.roundedRect(bounds.insetBy(dx: 1, dy: 1), radius: 6))
        context.setLineWidth(2); context.strokePath()
    }
}

@MainActor final class ChatNativeReplySummaryView: NSView {
    private let button = ChatNativeReplySummaryButton()
    private let requestButton = ChatNativeTextButton()
    private var avatars: [ChatNativeAvatarView] = []
    private var borders: [ChatNativeReplyAvatarBorder] = []
    private var plan: ChatNativeReplySummaryLayout?
    private var style: NativeTimelineSnapshot.Style?
    private var visible = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(button); addSubview(requestButton)
        setAccessibilityElement(false)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(plan: ChatNativeReplySummaryLayout, row: NativeTimelineSnapshot.Row, snapshot: NativeTimelineSnapshot,
                   actions: ChatTimelineActions?, ownerBinding: ChatNativeShellCell.Binding) {
        self.plan = plan; self.style = snapshot.style
        frame = plan.frame
        button.configure(plan: plan, style: snapshot.style)
        button.frame = local(plan.summaryFrame); button.isHidden = plan.summaryFrame.isEmpty
        button.toolTip = plan.help; button.setAccessibilityLabel(plan.accessibilityLabel)
        button.canFocus = plan.kind == .server || row.visual?.selected == true
        let id = row.messageID
        button.invoke = { [weak actions] in if let id { actions?.perform(.openExistingThread, messageID: id) } }
        requestButton.text = ChatNativeReplySummaryLayout.text(plan.request, size: 10, color: snapshot.style.color("foreground"), style: snapshot.style)
        requestButton.alignment = .center
        requestButton.frame = local(plan.requestFrame); requestButton.isHidden = plan.requestFrame.isEmpty
        requestButton.invoke = { [weak actions] in if let id { actions?.perform(.openExistingThread, messageID: id) } }
        while avatars.count < plan.participants.count {
            let avatar = ChatNativeAvatarView(), border = ChatNativeReplyAvatarBorder(frame: .zero)
            border.setAccessibilityElement(false)
            avatar.addSubview(border); addSubview(avatar, positioned: .below, relativeTo: button)
            avatars.append(avatar); borders.append(border)
        }
        for index in avatars.indices {
            let avatar = avatars[index]
            guard plan.participants.indices.contains(index) else { avatar.unbind(); avatar.isHidden = true; continue }
            let participant = plan.participants[index]
            avatar.isHidden = false
            avatar.frame = local(participant.frame)
            if !avatarShouldBeVisible(avatar, index: index) { avatar.setVisible(false) }
            let source = row.visual?.avatars.first { $0.reference == participant.reference }
            avatar.configure(placeholder: .init(stableID: participant.identity.avatarID, name: participant.name,
                                               kind: participant.identity.isBot ? .agent : .person),
                             source: source, owner: ownerBinding, style: snapshot.style,
                             service: id.flatMap { actions?.avatarService(messageID: $0) }, fallback: .own)
            borders[index].frame = avatar.bounds; borders[index].color = snapshot.style.color("surface")
            borders[index].needsDisplay = true
        }
        updateAvatarVisibility()
        button.needsDisplay = true
    }
    private func local(_ rect: CGRect) -> CGRect {
        guard let plan, !rect.isEmpty else { return .zero }
        return rect.offsetBy(dx: -plan.frame.minX, dy: -plan.frame.minY)
    }
    func setVisible(_ value: Bool) {
        visible = value
        updateAvatarVisibility()
    }
    private func updateAvatarVisibility() {
        for (index, avatar) in avatars.enumerated() {
            avatar.setVisible(avatarShouldBeVisible(avatar, index: index))
        }
    }
    private func avatarShouldBeVisible(_ avatar: ChatNativeAvatarView, index: Int) -> Bool {
        visible && index < (plan?.participants.count ?? 0) && avatar.window != nil
            && !avatar.isHiddenOrHasHiddenAncestor && avatar.bounds.intersects(avatar.visibleRect)
    }
    func setNavigationSelected(_ selected: Bool) { button.canFocus = plan?.kind == .server || selected }
    @discardableResult func focusLocalReply() -> Bool {
        guard visible, plan?.kind == .local else { return false }
        button.canFocus = true
        return window?.makeFirstResponder(button) == true
    }
    func unbind() {
        setVisible(false); avatars.forEach { $0.unbind(); $0.isHidden = true }
        button.invoke = nil; button.clear(); button.toolTip = nil
        button.setAccessibilityLabel(nil); button.isHidden = true
        requestButton.invoke = nil; requestButton.text = NSAttributedString(); requestButton.isHidden = true
        plan = nil; style = nil
    }
    #if DEBUG
    var parityPlan: ChatNativeReplySummaryLayout? { plan }
    var parityStyle: NativeTimelineSnapshot.Style? { style }
    var parityAvatars: [ChatNativeAvatarView] { Array(avatars.prefix(plan?.participants.count ?? 0)) }
    var parityButton: NSButton { button }
    var parityRequestButton: NSButton { requestButton }
    var parityRequestDrawingFrame: CGRect { convert(requestButton.drawingRect, from: requestButton) }
    /// All capture frames use this summary view's local coordinates.
    var parityTexts: [ChatNativeReplyTextOperand] {
        var result = button.texts.map { ChatNativeReplyTextOperand(id: $0.id, text: $0.text, frame: convert($0.frame, from: button)) }
        if !requestButton.isHidden {
            result.append(.init(id: "w06/replies/request", text: requestButton.text,
                                frame: convert(requestButton.bounds, from: requestButton)))
        }
        return result
    }
    var parityChevron: ChatNativeReplyImageOperand? {
        button.chevron.map { .init(image: $0.image, frame: convert($0.frame, from: button),
                                  drawingFrame: convert($0.drawingFrame, from: button), color: $0.color) }
    }
    var parityUnread: ChatNativeReplyFillOperand? {
        button.unread.map { .init(frame: convert($0.frame, from: button), color: $0.color, cornerRadius: $0.cornerRadius) }
    }
    /// Caller supplies a current NSGraphicsContext using this CGContext, as for avatar text capture.
    func drawParityText(id: String, in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        if id == "w06/replies/request" {
            guard !requestButton.isHidden else { return }
            context.translateBy(x: requestButton.frame.minX, y: requestButton.frame.minY)
            requestButton.draw(requestButton.bounds)
        } else {
            context.translateBy(x: button.frame.minX, y: button.frame.minY)
            button.drawText(id: id)
        }
    }
    func drawParityChevron(in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: button.frame.minX, y: button.frame.minY)
        button.chevron?.draw()
    }
    #endif
}

@MainActor private final class ChatNativeReplySummaryButton: NSButton {
    var plan: ChatNativeReplySummaryLayout?
    var style: NativeTimelineSnapshot.Style?
    private(set) var texts: [ChatNativeReplyTextOperand] = []
    private(set) var chevron: ChatNativeReplyImageOperand?
    private(set) var unread: ChatNativeReplyFillOperand?
    var invoke: (() -> Void)?
    var canFocus = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { canFocus || window?.firstResponder === self }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    init() {
        super.init(frame: .zero)
        isBordered = false; title = ""; focusRingType = .none
        target = self; action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, invoke != nil else { return false }
        // Navigation may synchronously replace or detach the owning row.
        // Report the handled dispatch, as the other native row buttons do.
        performClick(nil)
        return true
    }
    @objc private func pressed() { invoke?() }
    func configure(plan: ChatNativeReplySummaryLayout, style: NativeTimelineSnapshot.Style) {
        self.plan = plan; self.style = style
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -plan.summaryFrame.minX, dy: -plan.summaryFrame.minY) }
        func text(_ id: String, _ value: String, rect: CGRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> ChatNativeReplyTextOperand {
            .init(id: "w06/replies/" + id,
                  text: ChatNativeReplySummaryLayout.text(value, size: size, weight: weight, color: color, style: style), frame: local(rect))
        }
        let accent = style.color("accent")
        texts = [text("label", plan.label, rect: plan.labelFrame, size: 11, weight: .medium, color: accent),
                 text("unread-text", plan.unread, rect: plan.unreadTextFrame, size: 11, weight: .semibold, color: accent),
                 text("latest", plan.latest, rect: plan.latestFrame, size: 9, color: style.color("secondary"))]
            .filter { !$0.frame.isEmpty }
        unread = plan.unreadFrame.isEmpty ? nil : .init(frame: local(plan.unreadFrame), color: accent.withAlphaComponent(0.12), cornerRadius: 4)
        chevron = ChatNativeReplySummaryLayout.chevron(style: style).map {
            .init(image: $0, frame: local(plan.chevronFrame), drawingFrame: CGRect(origin: local(plan.chevronFrame).origin, size: $0.size), color: accent)
        }
    }
    func clear() { plan = nil; style = nil; texts = []; chevron = nil; unread = nil }
    func drawText(id: String) { texts.first { $0.id == id }?.draw() }
    override func draw(_ dirtyRect: NSRect) {
        guard let plan, let style else { return }
        drawText(id: "w06/replies/label")
        if let context = NSGraphicsContext.current?.cgContext {
            unread?.draw(in: context)
            drawText(id: "w06/replies/unread-text")
        }
        drawText(id: "w06/replies/latest")
        chevron?.draw()
        if window?.firstResponder === self, let context = NSGraphicsContext.current?.cgContext {
            let width: CGFloat = plan.kind == .server && style.increasedContrast ? 3 : 2
            style.color("accent").setStroke()
            context.addPath(ChatNativeShapes.roundedRect(bounds.insetBy(dx: width / 2, dy: width / 2), radius: 5 - width / 2))
            context.setLineWidth(width); context.strokePath()
        }
    }
}
