import AppKit
import CoreText

/// A visible consumer of the existing avatar pool. Snapshot changes supply
/// invalidation; this view owns neither an observer nor a second image cache.
@MainActor final class ChatNativeAvatarView: NSView {
    enum Fallback: Equatable { case shell, own }
    private struct Content: Equatable {
        let service: ObjectIdentifier
        let reference: ChatAvatarReference
        let context: ChatAvatarContext
        let metadata: ChatAvatarMetadata?
    }
    private struct Load: Equatable {
        let content: Content
        let generation: Int
    }
    private var placeholder: AvatarPlaceholder?
    private var source: NativeTimelineSnapshot.Avatar?
    private var owner: ChatNativeShellCell.Binding?
    private var style: NativeTimelineSnapshot.Style?
    private weak var service: ChatService?
    private var fallback = Fallback.shell
    private let visibilityID = UUID()
    private var registered: ChatAvatarReference?
    private var visible = false
    private var serial: UInt64 = 0
    private var load: Load?
    private var task: Task<Void, Never>?
    private var held: (content: Content, image: NSImage)?
    var imageChanged: (() -> Void)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(placeholder: AvatarPlaceholder, source: NativeTimelineSnapshot.Avatar?,
                   owner: ChatNativeShellCell.Binding, style: NativeTimelineSnapshot.Style,
                   service: ChatService?, fallback: Fallback) {
        let changedOwner = self.owner?.id != owner.id || self.owner?.epoch != owner.epoch
        if self.owner != owner || self.service !== service { cancelLoad() }
        if changedOwner || self.service !== service {
            self.service?.avatars.setVisible(nil, id: visibilityID)
            registered = nil; held = nil
        }
        self.placeholder = placeholder; self.source = source; self.owner = owner
        self.style = style; self.service = service; self.fallback = fallback
        reconcile()
        repaint()
    }

    /// Creation and measurement do not imply visibility. The owning cell calls
    /// this at its actual clip/window boundary, including retained hidden cells.
    func setVisible(_ value: Bool) {
        guard value != visible else { return }
        visible = value
        if value { reconcile() }
        else {
            cancelLoad()
            service?.avatars.setVisible(nil, id: visibilityID)
            registered = nil; held = nil
        }
        repaint()
    }

    func unbind() {
        setVisible(false)
        cancelLoad()
        service?.avatars.setVisible(nil, id: visibilityID)
        registered = nil; held = nil; source = nil; owner = nil
        placeholder = nil; style = nil; service = nil
        repaint()
        imageChanged = nil
    }

    isolated deinit {
        task?.cancel()
        service?.avatars.setVisible(nil, id: visibilityID)
    }

    private func currentContent() -> Content? {
        guard let source, let service, let owner,
              source.reference.key == owner.id.conversation.key,
              let context = service.avatarDisplayContext(source.reference.key),
              source.context == context,
              source.metadata == service.avatars.metadata[source.reference.subject] else { return nil }
        return .init(service: ObjectIdentifier(service), reference: source.reference,
                     context: context, metadata: source.metadata)
    }

    private func cancelLoad() {
        serial &+= 1
        task?.cancel(); task = nil; load = nil
    }

    private func reconcile() {
        guard visible else { return }
        guard let content = currentContent(), let source, let service, let owner else {
            cancelLoad(); held = nil
            service?.avatars.setVisible(nil, id: visibilityID); registered = nil
            return
        }
        if held?.content != content { held = nil }
        if registered != content.reference {
            service.avatars.setVisible(content.reference, id: visibilityID)
            registered = content.reference
        }
        // A newer captured visual will reconcile a changed pool generation.
        // Generation is deliberately absent from held-image validity.
        guard source.generation == service.avatars.imageGeneration(source.reference) else {
            cancelLoad()
            return
        }
        let next = Load(content: content, generation: source.generation)
        guard load != next else { return }
        cancelLoad(); load = next
        let ticket = serial, ref = content.reference, expectedOwner = owner
        task = Task { @MainActor [weak self, service] in
            let image = await service.avatars.load(ref)
            guard !Task.isCancelled, let self, self.visible, self.serial == ticket,
                  self.owner == expectedOwner, self.load == next else { return }
            self.task = nil
            guard self.currentContent() == next.content,
                  service.avatars.imageGeneration(ref) == next.generation else { return }
            self.held = image.map { (next.content, $0) }
            self.repaint()
        }
    }

    private func picture() -> NSImage? {
        guard visible, let content = currentContent(), let service else {
            held = nil
            return nil
        }
        if let held, held.content == content { return held.image }
        return service.avatars.image(content.reference)
    }
    var hasImage: Bool { picture() != nil }
    private func repaint() { needsDisplay = true; imageChanged?() }

    private var fillRGB: UInt32? {
        guard let placeholder, let style else { return nil }
        return placeholder.color(isLight: style.color("surface").relativeLuminance > 0.55)
    }
    private var radius: CGFloat { placeholder?.cornerRadius(size: bounds.width) ?? 0 }
    private var text: NSAttributedString? {
        guard let placeholder, let style else { return nil }
        let font = ChatNativeTextStyle.font(style.metrics.displayFont, size: (bounds.width * 0.46).rounded(), weight: .semibold)
        return ChatNativeTextStyle.label(placeholder.letter, font: font, color: .white)
    }
    private var textGeometry: (drawing: CGRect, typographic: CGRect, scale: CGFloat)? {
        guard let text, let style else { return nil }
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let fit = width > 0 ? min(1, max(0.6, bounds.width / width)) : 1
        let scale = max(1, style.metrics.scale)
        let measured = ceil(width * fit * scale) / scale
        let x = ((bounds.midX - measured / 2) * scale).rounded() / scale
        let baseline = ((bounds.midY + (ascent - descent) * fit / 2) * scale).rounded() / scale
        return (CGRect(x: x, y: baseline - ceil(ascent * fit), width: measured, height: text.size().height * fit),
                CGRect(x: x, y: baseline - ascent * fit, width: width * fit, height: (ascent + descent + leading) * fit), fit)
    }
    private func imageFrame(_ image: NSImage) -> CGRect {
        guard image.size.width > 0, image.size.height > 0 else { return bounds }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let placeholder, let context = NSGraphicsContext.current?.cgContext else { return }
        if let picture = picture() {
            context.saveGState()
            context.addPath(ChatNativeShapes.roundedRect(bounds, radius: radius)); context.clip()
            picture.draw(in: imageFrame(picture), from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            context.restoreGState()
        } else if fallback == .own, let rgb = fillRGB {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                    blue: CGFloat(rgb & 255) / 255, alpha: 1).setFill()
            if placeholder.kind == .person { context.fillEllipse(in: bounds) }
            else { context.addPath(ChatNativeShapes.roundedRect(bounds, radius: radius)); context.fillPath() }
            drawFallbackText(in: context)
        }
    }

    func drawFallbackText(in context: CGContext) {
        guard let text, let geometry = textGeometry else { return }
        context.saveGState(); context.clip(to: geometry.drawing)
        context.translateBy(x: geometry.drawing.minX, y: geometry.drawing.minY)
        context.scaleBy(x: geometry.scale, y: geometry.scale)
        text.draw(at: .zero)
        context.restoreGState()
    }

    #if DEBUG
    var parityPlaceholder: AvatarPlaceholder? { placeholder }
    var parityText: NSAttributedString? { text }
    var parityTextFrame: CGRect { textGeometry?.drawing ?? .zero }
    var parityTextClip: CGRect { parityTextFrame }
    var parityTextTypographicFrame: CGRect { textGeometry?.typographic ?? .zero }
    var parityFillRGB: UInt32? { fillRGB }
    var parityCornerRadius: CGFloat { radius }
    var parityImage: NSImage? { picture() }
    var parityImageFrame: CGRect { picture().map(imageFrame) ?? .zero }
    var parityVisible: Bool { visible }
    var hasLoadTask: Bool { task != nil }
    var registeredReference: ChatAvatarReference? { registered }
    var heldImage: NSImage? { held?.image }
    var requestSerial: UInt64 { serial }
    var boundOwner: ChatNativeShellCell.Binding? { owner }
    #endif
}
