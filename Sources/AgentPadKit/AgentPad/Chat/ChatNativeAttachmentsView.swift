import AppKit

@MainActor final class ChatNativeAttachmentImageButton: NSButton {
    var invoke: (() -> Void)?
    var preview: CGImage? { didSet { needsDisplay = true } }
    var failed = false { didSet { needsDisplay = true } }
    var style: NativeTimelineSnapshot.Style? { didSet { needsDisplay = true } }
    var authorized: (() -> Bool)?
    var backgroundColor: NSColor { style?.color("hover") ?? .clear }
    var imageDrawingRect: CGRect {
        guard let preview else { return .zero }
        let ratio = min(bounds.width / CGFloat(preview.width), bounds.height / CGFloat(preview.height))
        let size = CGSize(width: CGFloat(preview.width) * ratio, height: CGFloat(preview.height) * ratio)
        let fitted = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        // SwiftUI snaps the fitted image's edges to backing pixels before
        // resampling. Keep the image control and declared layout unchanged.
        if window != nil { return backingAlignedRect(fitted, options: .alignAllEdgesNearest) }
        let scale = style?.metrics.scale ?? 1
        let minX = (fitted.minX * scale).rounded() / scale
        let minY = (fitted.minY * scale).rounded() / scale
        let maxX = (fitted.maxX * scale).rounded() / scale
        let maxY = (fitted.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    var failureSymbol: NSImage? {
        NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(.init(paletteColors: [style?.color("secondary") ?? .secondaryLabelColor])))
    }
    var failureDrawingRect: CGRect {
        let image = failureSymbol, scale = style?.metrics.scale ?? 2
        let size = CGSize(width: image?.alignmentRect.width ?? 0, height: image?.size.height ?? 0)
        return CGRect(x: ((bounds.midX - size.width / 2) * scale).rounded() / scale,
            y: ((bounds.midY - size.height / 2) * scale).rounded() / scale, width: size.width, height: size.height)
    }
    override var isFlipped: Bool { true }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isBordered = false; title = ""; focusRingType = .none
        target = self; action = #selector(pressed)
        toolTip = "Open image"; setAccessibilityLabel("Open image")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { if isEnabled { invoke?() } }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        backgroundColor.setFill(); context.addPath(ChatNativeShapes.roundedRect(bounds, radius: 7)); context.fillPath()
        if let preview, authorized?() == true {
            NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
                .draw(in: imageDrawingRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else if failed, let symbol = failureSymbol {
            let alignment = symbol.alignmentRect, frame = failureDrawingRect
            let drawing = CGRect(x: frame.minX - alignment.minX, y: frame.minY,
                                 width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: drawing, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if window?.firstResponder === self {
            (style?.color("accent") ?? .controlAccentColor).setStroke()
            let width: CGFloat = style?.increasedContrast == true ? 3 : 2
            context.addPath(ChatNativeShapes.roundedRect(bounds.insetBy(dx: width / 2, dy: width / 2), radius: 5 - width / 2))
            context.setLineWidth(width); context.strokePath()
        }
    }
}

/// The symbol's layout box is fractional; its AppKit representation includes
/// the transparent optical padding. Draw that representation without scaling it
/// into the smaller layout box (which changes the folded-page stroke).
@MainActor final class ChatNativeAttachmentDocumentView: NSImageView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: CGRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
        context.setBlendMode(.sourceIn)
        (contentTintColor ?? .labelColor).setFill()
        context.fill(CGRect(origin: .zero, size: image.size))
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

@MainActor final class ChatNativeAttachmentCard: NSView {
    let imageButton = ChatNativeAttachmentImageButton(frame: .zero)
    let name = ChatNativeLabel(), detail = ChatNativeLabel(), problem = ChatNativeLabel()
    let document = ChatNativeAttachmentDocumentView()
    let download = ChatNativeActionButton("Save…", symbol: "arrow.down.to.line")
    let retry = ChatNativeTextButton()
    let spinner = NSProgressIndicator()
    private(set) var plan: ChatNativeAttachmentLayout.Card?
    private(set) var binding: ChatNativeShellCell.Binding?
    private(set) var currentTask: Task<Void, Never>?
    private(set) var visible = false
    private var serial: UInt64 = 0
    private struct Request: Equatable {
        let manager: ObjectIdentifier
        let stamp: ChatAttachmentManager.Stamp
        let retry: Int
    }
    private var request: Request?
    private var completed: Request?
    private var context: ChatTimelineActions.AttachmentContext?
    private weak var actions: ChatTimelineActions?
    private var style: NativeTimelineSnapshot.Style?
    private var operation = NativeTimelineSnapshot.AttachmentOperation()
    var backgroundColor: NSColor { style?.color("hover") ?? .clear }
    override var isFlipped: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [imageButton, name, detail, document, download, spinner, problem, retry] { addSubview(view) }
        // The reference detail Text clips a leading glyph's negative bearing
        // at its actual text frame, including after a wrapped line break.
        detail.clipsTextToBounds = true
        document.imageScaling = .scaleNone
        document.setAccessibilityElement(false)
        spinner.style = .spinning; spinner.isDisplayedWhenStopped = false
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ plan: ChatNativeAttachmentLayout.Card, messageID: String, owner: ChatNativeShellCell.Binding,
                   style: NativeTimelineSnapshot.Style, actions: ChatTimelineActions?) {
        let next = actions?.attachmentContext(messageID: messageID, fileID: plan.file.id)
        let operation = next.flatMap { actions?.attachmentPresentation($0).operation } ?? .init()
        let request = next.map { Request(manager: ObjectIdentifier($0.manager), stamp: $0.stamp, retry: operation.retry) }
        if binding?.id != owner.id || binding?.epoch != owner.epoch || self.request != request {
            stop(); completed = nil; imageButton.preview = nil
        } else if binding != owner {
            stop()
        }
        self.binding = owner; self.plan = plan; self.style = style; self.actions = actions
        context = next; self.request = request; self.operation = operation
        name.text = ChatNativeAttachmentLayout.text(plan.file.name, style: style, size: plan.file.isImage ? 10 : 12,
            weight: plan.file.isImage ? .regular : .medium, color: plan.file.isImage ? "secondary" : "foreground", truncates: true)
        detail.text = ChatNativeAttachmentLayout.text("\(plan.file.mime) · \(plan.file.sizeText)", style: style,
            truncates: plan.detailLineLimit == 1)
        detail.maximumNumberOfLines = plan.detailLineLimit ?? 0
        problem.text = ChatNativeAttachmentLayout.text(plan.problemText ?? "", style: style)
        retry.text = ChatNativeAttachmentLayout.text("Retry", style: style)
        retry.invoke = { [weak self, weak actions] in
            guard let self else { return }
            actions?.retryAttachment(messageID: messageID, fileID: plan.file.id, from: self)
        }
        download.invoke = { [weak self, weak actions] in
            guard let self else { return }
            actions?.saveAttachment(messageID: messageID, fileID: plan.file.id, from: self)
        }
        download.contentTintColor = style.color("foreground"); download.accent = style.color("accent")
        download.focusRingWidth = style.increasedContrast ? 3 : 2
        download.isEnabled = next != nil
        download.setAccessibilityLabel("Save \(plan.file.name)")
        imageButton.style = style; imageButton.failed = plan.problemText != nil
        imageButton.isEnabled = next != nil && !operation.busy
        imageButton.invoke = { [weak actions] in actions?.openAttachment(messageID: messageID, fileID: plan.file.id) }
        imageButton.authorized = { [weak self] in
            guard let self, visible, let context else { return false }
            return context.manager.current(context.stamp)
        }
        document.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 23, weight: .regular))
        document.contentTintColor = style.color("accent")
        setAccessibilityLabel("\(plan.file.mime), \(plan.file.name), \(plan.file.sizeText)")
        frame = plan.frame; needsLayout = true; needsDisplay = true
        updatePreview()
    }
    override func layout() {
        super.layout()
        guard let plan else { return }
        imageButton.frame = plan.image; imageButton.isHidden = !plan.file.isImage
        name.frame = plan.name; detail.frame = plan.detail; detail.isHidden = plan.detail.isEmpty
        document.frame = plan.document; document.isHidden = plan.document.isEmpty
        download.frame = plan.save; download.isHidden = plan.save.isEmpty || operation.busy
        problem.frame = plan.problem; problem.isHidden = plan.problem.isEmpty
        retry.frame = plan.retry; retry.isHidden = plan.retry.isEmpty
        let area = plan.file.isImage ? plan.image : plan.save
        spinner.controlSize = plan.file.isImage ? .small : .mini
        let side: CGFloat = plan.file.isImage ? 16 : 10
        spinner.frame = CGRect(x: area.midX - side / 2, y: area.midY - side / 2, width: side, height: side)
        updateSpinner()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let plan, !plan.file.isImage, let context = NSGraphicsContext.current?.cgContext else { return }
        backgroundColor.setFill(); context.addPath(ChatNativeShapes.roundedRect(plan.background, radius: 7)); context.fillPath()
    }
    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        if !value { stop(); completed = nil; imageButton.preview = nil }
        updatePreview(); updateSpinner()
    }
    private func updateSpinner() {
        let show = visible && (plan?.file.isImage == true ? imageButton.preview == nil && !imageButton.failed : operation.busy)
        spinner.isHidden = !show
        if show { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    private func updatePreview() {
        guard visible, let context, let request, let plan, plan.file.isImage else { updateSpinner(); return }
        imageButton.preview = context.manager.image(context.message, file: context.file)
        updateSpinner()
        guard imageButton.preview == nil, context.file.hasPreview, completed != request, currentTask == nil else { return }
        // Match the legacy task: remove a previous error when loading restarts,
        // so successful decode only replaces pixels, never the error row.
        actions?.previewFinished(context, problem: nil)
        let ticket = serial, owner = binding
        currentTask = Task { [weak self, weak actions] in
            var failed = false
            do { _ = try await context.manager.load(context.message, file: context.file, preview: true) }
            catch { failed = true }
            guard !Task.isCancelled, let self, self.visible, self.serial == ticket,
                  self.request == request, self.binding == owner else { return }
            self.currentTask = nil; self.completed = request
            // image() rechecks the file stamp. A still-authorized owner can
            // display "File unavailable" during message hydration; publishing
            // that error never grants access or mutates installed geometry.
            self.imageButton.preview = context.manager.image(context.message, file: context.file)
            if failed { actions?.previewFinished(context, problem: "Preview failed to load.") }
            self.updateSpinner()
        }
    }
    private func stop() { serial &+= 1; currentTask?.cancel(); currentTask = nil; spinner.stopAnimation(nil) }
    func unbind() {
        visible = false; stop(); binding = nil; request = nil; completed = nil; context = nil; actions = nil; plan = nil
        imageButton.preview = nil; imageButton.invoke = nil; imageButton.authorized = nil
        download.invoke = nil; retry.invoke = nil
    }
    isolated deinit { currentTask?.cancel() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { setVisible(false) } }
}

@MainActor final class ChatNativeAttachmentsView: NSView {
    private(set) var cards: [ChatNativeAttachmentCard] = []
    private var visible = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { let hit = super.hitTest(point); return hit === self ? nil : hit }
    func configure(_ plan: ChatNativeAttachmentLayout, messageID: String, owner: ChatNativeShellCell.Binding,
                   style: NativeTimelineSnapshot.Style, actions: ChatTimelineActions?) {
        if cards.map({ $0.plan?.file.id }) != plan.cards.map({ Optional($0.file.id) }) {
            cards.forEach { $0.unbind(); $0.removeFromSuperview() }
            cards = plan.cards.map { _ in ChatNativeAttachmentCard(frame: .zero) }; cards.forEach(addSubview)
        }
        for (view, value) in zip(cards, plan.cards) {
            view.configure(value, messageID: messageID, owner: owner, style: style, actions: actions)
            view.setVisible(visible)
        }
    }
    func setVisible(_ value: Bool) {
        visible = value
        cards.forEach { $0.setVisible(value && !$0.frame.intersection(visibleRect).isEmpty) }
    }
    override func layout() { super.layout(); setVisible(visible) }
    func unbind() { visible = false; cards.forEach { $0.unbind(); $0.removeFromSuperview() }; cards.removeAll() }
}
