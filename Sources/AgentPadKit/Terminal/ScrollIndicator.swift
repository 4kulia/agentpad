import AppKit

/// A thin right-edge overlay that briefly shows a small knob during active
/// scrolling, then fades out. Used by both engines as a Terminal.app/Warp-style
/// visual feedback layer; bypasses NSScroller entirely.
@MainActor
final class ScrollIndicator: NSView {
    static let totalWidth: CGFloat = 12

    private static let knobWidthIdle: CGFloat = 4
    private static let knobWidthHover: CGFloat = 6
    private static let knobWidthDrag: CGFloat = 7
    private static let knobAlphaIdle: CGFloat = 0.35
    private static let knobAlphaHover: CGFloat = 0.55
    private static let knobAlphaDrag: CGFloat = 0.75
    private static let knobRightInset: CGFloat = 4
    private static let knobMinHeight: CGFloat = 24
    private static let fadeOutDelay: TimeInterval = 2.5
    private static let fadeOutDuration: TimeInterval = 0.4

    private let knobLayer = CALayer()
    private var fadeTask: Task<Void, Never>?

    private var position: Double = 0
    private var proportion: Double = 0

    private var dragOffsetWithinKnob: CGFloat?
    private var isHovered = false {
        didSet { updateKnobAppearance() }
    }
    /// Fired during knob drag with the desired position 0…1 (0 = bottom = latest,
    /// 1 = top = oldest). Owner translates this into a scroll command.
    var onDragKnobTo: ((Double) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        layer?.addSublayer(knobLayer)
        updateKnobAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let options: NSTrackingArea.Options = [.activeAlways, .mouseEnteredAndExited, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func updateKnobAppearance() {
        let alpha: CGFloat
        let width: CGFloat
        if dragOffsetWithinKnob != nil {
            alpha = Self.knobAlphaDrag
            width = Self.knobWidthDrag
        } else if isHovered {
            alpha = Self.knobAlphaHover
            width = Self.knobWidthHover
        } else {
            alpha = Self.knobAlphaIdle
            width = Self.knobWidthIdle
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        knobLayer.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        knobLayer.cornerRadius = width / 2
        CATransaction.commit()
        updateKnobFrame()
    }

    private var currentKnobWidth: CGFloat {
        if dragOffsetWithinKnob != nil { return Self.knobWidthDrag }
        if isHovered { return Self.knobWidthHover }
        return Self.knobWidthIdle
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Pin a `ScrollIndicator` to the right edge of `host`, full height, with
    /// `totalWidth` reserved. Replaces hand-rolled constraint blocks at every
    /// engine that hosts a terminal surface.
    static func install(_ indicator: ScrollIndicator, in host: NSView) {
        indicator.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.topAnchor.constraint(equalTo: host.topAnchor),
            indicator.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            indicator.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            indicator.widthAnchor.constraint(equalToConstant: ScrollIndicator.totalWidth),
        ])
    }

    override func layout() {
        super.layout()
        updateKnobFrame()
    }

    func update(position: Double, proportion: Double) {
        // While the user is dragging, local position is authoritative — don't
        // let the action_cb roundtrip overwrite the knob mid-drag (causes
        // visible jitter / "doesn't follow finger").
        if dragOffsetWithinKnob == nil {
            self.position = position
        }
        self.proportion = max(0.01, min(1.0, proportion))
        updateKnobFrame()
    }

    private func updateKnobFrame() {
        let trackHeight = bounds.height
        guard trackHeight > 0 else { return }

        let knobHeight = max(Self.knobMinHeight, trackHeight * CGFloat(proportion))
        let knobMaxY = max(0, trackHeight - knobHeight)
        // scrollPosition: 0 = latest (bottom), 1 = oldest (top).
        // AppKit origin is bottom-left, so position 1 → top = high y.
        let knobY = knobMaxY * CGFloat(position)
        let width = currentKnobWidth
        let knobX = bounds.width - width - Self.knobRightInset

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        knobLayer.frame = CGRect(
            x: knobX,
            y: knobY,
            width: width,
            height: knobHeight
        )
        CATransaction.commit()
    }

    func flash() {
        fadeTask?.cancel()
        alphaValue = 1
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeOutDelay))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeOutDuration
                self.animator().alphaValue = 0
            }, completionHandler: nil)
        }
    }

    // MARK: - Drag-to-scroll

    /// Only intercept clicks when the indicator is visible AND the click lands
    /// on the knob's pill (with a small horizontal grab margin). Everything
    /// else passes through so the terminal can handle selection / text input.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.1 else { return nil }
        let local = convert(point, from: superview)
        let knobGrabRect = knobLayer.frame.insetBy(dx: -6, dy: 0)
        return knobGrabRect.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        dragOffsetWithinKnob = local.y - knobLayer.frame.origin.y
        fadeTask?.cancel()
        alphaValue = 1
        updateKnobAppearance()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let offset = dragOffsetWithinKnob else { return }
        let local = convert(event.locationInWindow, from: nil)
        let knobMaxY = max(0, bounds.height - knobLayer.frame.height)
        let clampedY = max(0, min(knobMaxY, local.y - offset))
        let newPosition = knobMaxY > 0 ? clampedY / knobMaxY : 0
        // Apply locally first so the knob tracks the cursor 1:1; the scroll
        // command and its eventual SCROLLBAR action_cb arrive a frame later.
        self.position = Double(newPosition)
        updateKnobFrame()
        onDragKnobTo?(Double(newPosition))
    }

    override func mouseUp(with event: NSEvent) {
        dragOffsetWithinKnob = nil
        updateKnobAppearance()
        flash()
    }
}
