import AppKit

extension NativeTimelineSnapshot.Style {
    func color(_ name: String, fallback: NSColor = .labelColor) -> NSColor {
        guard let value = colors[name] else { return fallback }
        return NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }
}

/// Labels have no AppKit field-cell padding. Their measured text rectangle is
/// also their drawing rectangle, including fractional baselines at Retina scale.
@MainActor final class ChatNativeLabel: NSView {
    var text = NSAttributedString() { didSet { needsDisplay = true; setAccessibilityLabel(text.string) } }
    var clipsTextToBounds = false
    var maximumNumberOfLines = 0
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { clipsTextToBounds }
    override func draw(_ dirtyRect: NSRect) {
        let context = NSGraphicsContext.current?.cgContext
        if clipsTextToBounds {
            context?.saveGState()
            context?.clip(to: bounds)
        }
        defer { if clipsTextToBounds { context?.restoreGState() } }
        var options: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        if maximumNumberOfLines > 0 { options.insert(.truncatesLastVisibleLine) }
        text.draw(with: bounds, options: options)
    }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.staticText) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor final class ChatNativeTextButton: NSButton {
    var text = NSAttributedString() { didSet { title = text.string; needsDisplay = true } }
    var invoke: (() -> Void)?
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        isBordered = false; focusRingType = .none
        target = self; action = #selector(pressed)
        setAccessibilityElement(true); setAccessibilityRole(.link)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var drawingRect: CGRect {
        alignment == .center ? bounds.offsetBy(dx: (bounds.width - text.size().width) / 2, dy: 0) : bounds
    }
    override func draw(_ dirtyRect: NSRect) { text.draw(with: drawingRect, options: [.usesLineFragmentOrigin]) }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, invoke != nil else { return false }
        // A handled action may synchronously remove or unbind its row. Report
        // that dispatch, rather than the cell's state after performClick returns.
        performClick(nil)
        return true
    }
    @objc private func pressed() { invoke?() }
}

/// The legacy rounded rectangles use continuous corners. AppKit's rounded
/// rectangle convenience path uses circular corners and changes their outline.
enum ChatNativeShapes {
    static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let radius = min(radius, min(rect.width, rect.height) / 2)
        // The rendered legacy primitive retains overlapping corner segments.
        // Clamping their extents to half-height changes a capsule's tip stroke.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        for corner in 0..<4 {
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                switch corner {
                case 0: CGPoint(x: rect.maxX - x * radius, y: rect.maxY - y * radius)
                case 1: CGPoint(x: rect.minX + y * radius, y: rect.maxY - x * radius)
                case 2: CGPoint(x: rect.minX + x * radius, y: rect.minY + y * radius)
                default: CGPoint(x: rect.maxX - y * radius, y: rect.minY + x * radius)
                }
            }
            path.addLine(to: point(0, 1.5286649465560913))
            path.addCurve(to: point(0.07491140067577362, 0.6314939856529236),
                control1: point(0, 1.0884900093078613), control2: point(0, 0.8684070110321045))
            path.addCurve(to: point(0.6314939856529236, 0.07491140067577362),
                control1: point(0.16906000673770905, 0.3728240132331848),
                control2: point(0.3728240132331848, 0.16906000673770905))
            path.addCurve(to: point(1.5286649465560913, 0), control1: point(0.8684070110321045, 0),
                control2: point(1.0884900093078613, 0))
        }
        path.closeSubpath()
        return path
    }
}

@MainActor enum ChatNativeTextStyle {
    static func font(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont(name: name, size: size) ?? .systemFont(ofSize: size)
        guard weight != .regular else { return base }
        if base.familyName == "Onest" {
            // Onest is a variable font. A weight trait alone retains its
            // regular named instance; SwiftUI selects the wght axis instead.
            let value = weight == .semibold ? 600 : weight == .medium ? 500 : 700
            let descriptor = base.fontDescriptor.addingAttributes([
                .variation: [NSNumber(value: 0x77676874): NSNumber(value: value)]
            ])
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
        let descriptor = base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
    private static let captionHyphenationFactor: Float = 0.25

    static func label(_ string: String, font: NSFont, color: NSColor, pushOut: Bool = false,
                      alignment: NSTextAlignment = .left, hyphenates: Bool = false) -> NSAttributedString {
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        guard pushOut || alignment != .left || hyphenates else { return text }
        let value = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        if pushOut { paragraph.lineBreakStrategy = .pushOut }
        paragraph.alignment = alignment
        // Caption parity uses conservative hyphenation: permit a word that
        // cannot fit, without filling an already occupied line aggressively.
        // The observed legacy caption proposals retain this policy at both
        // their initial and final widths; system default currently resolves 0.9.
        paragraph.hyphenationFactor = hyphenates ? captionHyphenationFactor : 0
        value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
        return value
    }
    static func size(_ text: NSAttributedString, width: CGFloat = .greatestFiniteMagnitude, scale: CGFloat) -> CGSize {
        guard text.length > 0 else { return .zero }
        let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return CGSize(width: ceil(rect.width * scale) / scale, height: ceil(rect.height * scale) / scale)
    }
}

@MainActor final class ChatNativeTableView: NSTableView {
    var keyViews: (() -> [Any])? {
        didSet {
            if keyViews == nil {
                installedKeyViews.forEach { $0.nextKeyView = nil }
                installedKeyViews = []; nextOutsideTimeline = nil
                super.nextKeyView = nil
            }
        }
    }
    private weak var nextOutsideTimeline: NSView?
    private var installedKeyViews: [NSView] = []
    var keyViewCount: Int { installedKeyViews.count }
    private var updatingKeyLoop = false
    override var nextKeyView: NSView? {
        get { super.nextKeyView }
        set {
            if updatingKeyLoop || keyViews == nil { super.nextKeyView = newValue }
            else {
                super.nextKeyView = newValue
                nextOutsideTimeline = newValue; rebuildKeyViewLoop()
            }
        }
    }
    override var nextValidKeyView: NSView? {
        if keyViews != nil { rebuildKeyViewLoop() }
        return super.nextValidKeyView
    }
    /// AppKit treats NSTableView as a key-loop leaf, so its native overlay and
    /// row controls need an explicit chain. Keep AppKit's eligibility policy
    /// and the next view outside this timeline, including reverse traversal.
    func rebuildKeyViewLoop() {
        guard keyViews != nil, !updatingKeyLoop else { return }
        updatingKeyLoop = true
        defer { updatingKeyLoop = false }
        // NSWindow can rebuild the loop internally without using our setter.
        // Adopt its new outside continuation before restoring the row chain.
        let current = super.nextKeyView
        if !installedKeyViews.contains(where: { $0 === current }) { nextOutsideTimeline = current }
        let outside = nextOutsideTimeline
        installedKeyViews.forEach { $0.nextKeyView = outside }
        installedKeyViews = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: Any) {
            guard let view = (object as? NSView) ?? (object as? NSCell)?.controlView,
                  view !== self, seen.insert(ObjectIdentifier(view)).inserted,
                  !view.isHiddenOrHasHiddenAncestor, view.bounds.intersects(view.visibleRect) else { return }
            if view.canBecomeKeyView { installedKeyViews.append(view) }
            else { (view.accessibilityChildren() ?? view.subviews).forEach(visit) }
        }
        (keyViews?() ?? []).forEach(visit)
        var previous: NSView = self
        for view in installedKeyViews { previous.nextKeyView = view; previous = view }
        previous.nextKeyView = outside
    }
    weak var documentLayer: ChatNativeDocumentLayer?
    var geometryChanged: (() -> Void)?
    override func layout() {
        super.layout()
        // Incremental inserts can leave retained row views at intermediate
        // origins after the table's row geometry has already settled. Keep
        // realized views on that authoritative geometry without resizing or
        // recreating their contents.
        enumerateAvailableRowViews { [self] row, index in
            guard index >= 0, index < numberOfRows else { return }
            let origin = rect(ofRow: index).origin
            if row.frame.origin != origin { row.setFrameOrigin(origin) }
        }
        // AppKit adds recyclable row views as the viewport moves. The live
        // editor and floating actions must remain above those new siblings.
        if let documentLayer, subviews.last !== documentLayer {
            addSubview(documentLayer, positioned: .above, relativeTo: nil)
        }
        geometryChanged?()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let documentLayer, let hit = documentLayer.hitTest(convert(point, from: superview)) { return hit }
        return super.hitTest(point)
    }
    var focusChanged: ((Bool) -> Void)?
    var navigate: ((Int) -> Void)?
    var dismiss: (() -> Bool)?
    override func keyDown(with event: NSEvent) {
        // Only the roving table focus owns these bindings. NSTextView keeps
        // editing, IME, selection extension and standard modified keys.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if window?.firstResponder === self, modifiers.isEmpty {
            if event.keyCode == 125 { navigate?(1); return }
            if event.keyCode == 126 { navigate?(-1); return }
            if event.keyCode == 53, dismiss?() == true { return }
        }
        super.keyDown(with: event)
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusChanged?(true) }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusChanged?(false) }
        return result
    }
}

@MainActor final class ChatNativeTimelineFocusBorder: NSView {
    var focused = false { didSet { needsDisplay = true } }
    var color = NSColor.controlAccentColor { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard focused else { return }
        color.setStroke()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(ChatNativeShapes.roundedRect(bounds.insetBy(dx: 1, dy: 1), radius: 3))
        context.setLineWidth(2); context.strokePath()
    }
}
