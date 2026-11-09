import AppKit
import CoreText
import SwiftUI

/// Lives in table document coordinates, outside AppKit's recyclable row views.
/// Empty space must still hit the table/text underneath it.
@MainActor final class ChatNativeDocumentLayer: NSView {
    override var isFlipped: Bool { true }
    override func accessibilityChildren() -> [Any]? {
        // Row controls are exposed by their owning cell. An editor whose row
        // has scrolled away remains accessible in its stable attached host.
        NSAccessibility.unignoredChildren(from: subviews.filter {
            guard let editor = $0 as? ChatNativeEditorHost else { return false }
            return editor.accessibilityOwner == nil
        })
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor final class ChatNativeActionButton: NSButton {
    weak var accessibilityOwner: NSView?
    override func accessibilityParent() -> Any? { accessibilityOwner ?? super.accessibilityParent() }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityFrame() -> NSRect {
        // The element is this control, not NSButtonCell's inset bezel. Match
        // its actual hit target, including borderless toolbar icons.
        guard let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(bounds, to: nil))
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil); return true
    }
    var invoke: (() -> Void)?
    var focusChanged: (() -> Void)?
    var accent = NSColor.controlAccentColor
    var focusRingWidth: CGFloat = 2 { didSet { needsDisplay = true } }
    static let minimumTitlePadding: CGFloat = 10
    var constrainsTitle = false
    static func measuredSize(_ title: String, width: CGFloat, scale: CGFloat) -> CGSize {
        let text = ChatNativeTextStyle.label(title, font: .systemFont(ofSize: 13), color: .labelColor)
        let ideal = ChatNativeTextStyle.size(text, scale: scale)
        let height = ceil(ideal.height) + 8
        guard width < ideal.width + 24 else { return CGSize(width: ideal.width + 24, height: height) }
        let titleWidth = max(0, width - minimumTitlePadding)
        guard ideal.width > titleWidth else { return CGSize(width: max(minimumTitlePadding, width), height: height) }
        let fitted = truncatedTitleWidth(text, width: titleWidth, scale: scale)
        return CGSize(width: fitted + minimumTitlePadding, height: height)
    }
    private static func truncatedTitleWidth(_ text: NSAttributedString, width: CGFloat, scale: CGFloat) -> CGFloat {
        guard let line = truncatedTitleLine(text, width: width) else { return 0 }
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) * scale) / scale
    }
    private static func truncatedTitleLine(_ text: NSAttributedString, width: CGFloat) -> CTLine? {
        guard width > 0, text.length > 0 else { return nil }
        let line = CTLineCreateWithAttributedString(text)
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: text.attributes(at: 0, effectiveRange: nil)))
        return CTLineCreateTruncatedLine(line, Double(width), .end, token)
    }
    var chromeForeground: NSColor? { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    private var themedOpacity: CGFloat {
        image == nil && chromeForeground != nil && !isEnabled ? 0.5 : 1
    }
    override var isFlipped: Bool { true }
    var drawingTitle: NSAttributedString {
        let text = NSMutableAttributedString(attributedString: ChatNativeTextStyle.label(title, font: font ?? .systemFont(ofSize: 13),
            color: (chromeForeground ?? .controlTextColor).withAlphaComponent((isEnabled ? 1 : 0.5) * themedOpacity)))
        if constrainsTitle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        }
        return text
    }
    var titleDrawingRect: CGRect {
        var size = drawingTitle.size()
        if constrainsTitle, size.width > bounds.width - Self.minimumTitlePadding {
            let line = Self.truncatedTitleLine(drawingTitle, width: max(0, bounds.width - Self.minimumTitlePadding))
            size.width = line.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) } ?? 0
        }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    var truncatedDrawingTitle: CTLine? {
        let text = drawingTitle
        guard constrainsTitle, text.size().width > bounds.width - Self.minimumTitlePadding else { return nil }
        return Self.truncatedTitleLine(text, width: max(0, bounds.width - Self.minimumTitlePadding))
    }
    var titleTypographicRect: CGRect {
        var rect = titleDrawingRect
        if let line = truncatedDrawingTitle {
            rect.size.width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        return rect
    }
    func drawTitle() {
        guard let line = truncatedDrawingTitle, let context = NSGraphicsContext.current?.cgContext else {
            drawingTitle.draw(with: titleDrawingRect, options: [.usesLineFragmentOrigin])
            return
        }
        // Use the same truncated line that determines the intrinsic width.
        // The semantic title and accessibility label remain the full string.
        let rect = titleDrawingRect
        let font = font ?? .systemFont(ofSize: 13)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY + NSLayoutManager().defaultBaselineOffset(for: font))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
    init(_ title: String, symbol: String? = nil) {
        super.init(frame: .zero)
        self.title = title
        target = self; action = #selector(pressed)
        // NSButton normally exposes its NSButtonCell. These controls can have
        // a logical row parent outside their physical overlay, so expose the
        // native control itself once, with its own action and focus identity.
        setAccessibilityElement(true); setAccessibilityRole(.button)
        focusRingType = .none
        if let symbol {
            isBordered = false
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = .imageOnly
            symbolConfiguration = .init(pointSize: 13, weight: .regular)
            toolTip = title
        } else { bezelStyle = .roundRect; font = .systemFont(ofSize: 13) }
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { guard isEnabled else { return }; invoke?() }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); needsDisplay = true; focusChanged?(); return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); needsDisplay = true
        DispatchQueue.main.async { [weak self] in self?.focusChanged?() }
        return result
    }
    override func draw(_ dirtyRect: NSRect) {
        if image == nil, let foreground = chromeForeground, let context = NSGraphicsContext.current?.cgContext {
            // Preserve the legacy bordered control's themed face. AppKit's
            // default bezel ignores the row foreground and uses a different
            // background; the control remains a native NSButton for input/AX.
            // The resting SwiftUI face composes two continuous fills. Each
            // receives disabled opacity independently; fading the completed
            // bezel changes the antialiased corner pixels.
            let face = ChatNativeShapes.roundedRect(bounds, radius: 6)
            foreground.withAlphaComponent((isHighlighted ? 0.3 : 0.18) * themedOpacity).setFill()
            context.addPath(face); context.fillPath()
            if !isHighlighted {
                let shade: NSColor = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
                shade.withAlphaComponent(0.03 * themedOpacity).setFill()
                context.addPath(face); context.fillPath()
            }
            drawTitle()
        } else { super.draw(dirtyRect) }
        if window?.firstResponder === self, let context = NSGraphicsContext.current?.cgContext {
            accent.withAlphaComponent(accent.alphaComponent * themedOpacity).setStroke()
            context.addPath(ChatNativeShapes.roundedRect(bounds.insetBy(dx: focusRingWidth / 2, dy: focusRingWidth / 2), radius: 5 - focusRingWidth / 2))
            context.setLineWidth(focusRingWidth); context.strokePath()
        }
    }
}

@MainActor final class ChatNativeHoverToolbar: NSView {
    var buttons: [ChatNativeActionButton] = []
    var pointerChanged: ((Bool) -> Void)?
    var style: NativeTimelineSnapshot.Style?
    override var isFlipped: Bool { true }
    func install(_ buttons: [ChatNativeActionButton]) {
        self.buttons.forEach { $0.invoke = nil; $0.focusChanged = nil; $0.accessibilityOwner = nil; $0.removeFromSuperview() }
        self.buttons = buttons
        var x: CGFloat = 3
        for button in buttons {
            let menu = button.title == "More message actions"
            button.frame = CGRect(x: x, y: menu ? 10 : 3, width: menu ? 20 : 28, height: menu ? 14 : 28)
            x = button.frame.maxX + 2
            addSubview(button)
        }
        setFrameSize(NSSize(width: buttons.isEmpty ? 0 : x + 1, height: 34))
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { pointerChanged?(true) }
    override func mouseExited(with event: NSEvent) { pointerChanged?(false) }
    override func draw(_ dirtyRect: NSRect) {
        guard let style, let context = NSGraphicsContext.current?.cgContext else { return }
        style.color("surface").setFill()
        context.addPath(ChatNativeShapes.roundedRect(bounds, radius: 8)); context.fillPath()
        style.color("foreground").withAlphaComponent(0.18).setStroke()
        context.addPath(ChatNativeShapes.roundedRect(bounds.insetBy(dx: 0.5, dy: 0.5), radius: 7.5))
        context.setLineWidth(1); context.strokePath()
    }
}

/// Match SwiftUI's whole-point popup content sizing so a fractional intrinsic
/// width cannot leave an uncovered edge inside AppKit's integral window frame.
@MainActor private final class ChatNativePopoverHostingController: NSHostingController<AnyView> {
    override var preferredContentSize: NSSize {
        get { enclosing(super.preferredContentSize) }
        set { super.preferredContentSize = enclosing(newValue) }
    }

    private func enclosing(_ size: NSSize) -> NSSize {
        NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }
}

/// External native-row popup only; the legacy picker stays unchanged.
/// Capture permission in the body so an observed problem update also changes
/// each quick-button closure, rather than retaining its database-derived value.
struct ChatNativeReactionPicker: View {
    let b1: ChatB1Channel
    let message: String
    @State private var emoji = ""
    var body: some View {
        let canChange = b1.canChange
        VStack(alignment: .leading, spacing: 12) {
            Text("Add reaction").font(Theme.display(12, weight: .semibold))
                #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                .chatReviewParity("picker/title", text: "Add reaction", colors: ["foreground": Theme.chromeForeground], font: Theme.display(12, weight: .semibold))
                #endif
            HStack(spacing: 4) {
                ForEach(ChatEmoji.quick, id: \.self) { value in
                    Button(value) { b1.toggle(message, emoji: value) }
                        #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                        .chatReviewParity("picker/quick/" + value, text: value)
                        #endif
                        .buttonStyle(.plain).font(.system(size: 21)).frame(width: 32, height: 32)
                        .disabled(!canChange || b1.pending(message, choice: value)).chatFocusRing()
                }
            }
            HStack {
                TextField("Emoji", text: $emoji).frame(width: 110).accessibilityLabel("Choose or paste one emoji")
                Button("Emoji & Symbols") { NSApp.orderFrontCharacterPalette(nil) }
                    #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                    .chatReviewParity("picker/palette", text: "Emoji & Symbols")
                    #endif
                Button("Add") { b1.toggle(message, emoji: emoji); emoji = "" }
                    #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                    .chatReviewParity("picker/add", text: "Add")
                    #endif
                    .disabled(ChatEmoji.canonical(emoji) == nil || !canChange || b1.pending(message, choice: ChatEmoji.canonical(emoji) ?? ""))
            }
            if let problem = b1.problem(message) { Text(problem).font(.caption).foregroundStyle(ChatAppearance.failure)
                    #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                    .chatReviewParity("picker/problem", text: problem, colors: ["foreground": ChatAppearance.failure], font: .caption)
                    #endif
                    }
        }.padding(14).background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
    }
}


/// Only external popup content may remain SwiftUI. The anchor and attention
/// registration belong to this row identity and disappear with it.
@MainActor final class ChatNativeAttentionPopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private let id = UUID()
    private weak var anchor: NSView?
    private weak var ownerWindow: NSWindow?
    private weak var responder: NSView?
    private var returnsFocus = true
    func show(_ content: AnyView, from anchor: NSView) {
        if popover.isShown, self.anchor === anchor { refresh(); return }
        close(returnFocus: false)
        guard let window = anchor.window, !anchor.isHiddenOrHasHiddenAncestor else { return }
        self.anchor = anchor; ownerWindow = window; responder = window.firstResponder as? NSView
        popover.delegate = self; popover.behavior = .transient; popover.animates = true
        returnsFocus = true
        let controller = ChatNativePopoverHostingController(rootView: content)
        // The SwiftUI reference fills the system popup, including its chevron.
        // Its content remains inside AppKit's automatically supplied safe area.
        popover.hasFullSizeContent = true
        // Let the popup own sizing around its anchor when asynchronous content
        // changes, instead of imposing hosting-view bounds on its window.
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        controller.preferredContentSize = controller.view.fittingSize
        popover.contentSize = controller.preferredContentSize
        NavigationPresentationGate.setOverlay(id, window: window, presented: true)
        // The existing attentionPopover defaults to the physical top edge.
        // Native cells/chips are flipped, so their top is minY.
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .minY : .maxY)
        if !popover.isShown { release(returnFocus: false) }
    }
    func refresh() {
        guard popover.isShown else { return }
        guard let anchor, anchor.window === ownerWindow, !anchor.isHiddenOrHasHiddenAncestor,
              !anchor.visibleRect.isEmpty else { close(returnFocus: false); return }
        popover.positioningRect = anchor.bounds
    }
    func updateContent(_ content: AnyView) {
        guard popover.isShown, let controller = popover.contentViewController as? NSHostingController<AnyView> else { return }
        controller.rootView = content
        controller.preferredContentSize = controller.view.fittingSize
        popover.contentSize = controller.preferredContentSize
        refresh()
    }
    func close(returnFocus: Bool = true) {
        returnsFocus = returnFocus
        if popover.isShown {
            // Revocation/reuse removes private content immediately. Keep the
            // attention gate until AppKit has actually finished dismissal.
            if !returnFocus { popover.animates = false }
            popover.close()
        } else { release(returnFocus: returnFocus) }
    }
    func popoverDidClose(_ notification: Notification) { release(returnFocus: returnsFocus) }
    private func release(returnFocus: Bool) {
        let popupWindow = popover.contentViewController?.view.window
        NavigationPresentationGate.setOverlay(id, window: ownerWindow, presented: false)
        // Closing a row popup must not take focus back from a different control.
        if returnFocus, let responder, let window = ownerWindow,
           responder.window === window, !responder.isHiddenOrHasHiddenAncestor,
           window.firstResponder == nil || window.firstResponder === responder || NSApp.keyWindow === popupWindow {
            window.makeFirstResponder(responder)
        }
        popover.contentViewController = nil
        anchor = nil; ownerWindow = nil; responder = nil
    }
}

@MainActor final class ChatNativeRowActions: NSObject {
    private weak var cell: ChatNativeShellCell?
    private weak var actions: ChatTimelineActions?
    private var message: NativeTimelineSnapshot.Message?
    private var style: NativeTimelineSnapshot.Style?
    private var state: NativeTimelineSnapshot.State?
    let toolbar = ChatNativeHoverToolbar()
    let popup = ChatNativeAttentionPopover()
    private var menuCallbacks: [ObjectIdentifier: () -> Void] = [:]
    private var pointerInside = false
    private var toolbarInside = false
    private var hovering = false
    private var selected = false
    private var hoverGeneration: UInt64 = 0
    private var identity: NativeTimelineSnapshot.RowID?
    private(set) var active = false
    var changed: ((Bool) -> Void)?
    // Tests use a private pasteboard; product uses the standard native pasteboard.
    var pasteboard: NSPasteboard = .general

    func configure(cell: ChatNativeShellCell, row: NativeTimelineSnapshot.Row, snapshot: NativeTimelineSnapshot,
                   actions: ChatTimelineActions?, layer: ChatNativeDocumentLayer?) {
        guard case .message(let message) = row.payload else { unbind(); return }
        if identity != row.id { unbind() }
        self.cell = cell; self.actions = actions; self.message = message
        style = snapshot.style; state = snapshot.state; identity = row.id
        if toolbar.superview !== layer, let layer { layer.addSubview(toolbar) }
        toolbar.style = snapshot.style
        toolbar.pointerChanged = { [weak self] inside in self?.hover(inside, toolbar: true) }
        var buttons: [ChatNativeActionButton] = []
        func button(_ title: String, _ symbol: String, enabled: Bool = true, _ invoke: @escaping () -> Void) {
            let button = ChatNativeActionButton(title, symbol: symbol)
            button.isEnabled = enabled; button.invoke = invoke
            // The legacy borderless Menu uses the system label ink, while its
            // neighbouring plain icon buttons use the row's secondary ink.
            button.contentTintColor = symbol == "ellipsis" ? .labelColor : snapshot.style.color("secondary")
            button.accent = snapshot.style.color("accent")
            button.focusChanged = { [weak self] in self?.refreshActive() }
            buttons.append(button)
        }
        let value = message.content, id = value.message.id
        if value.actions.reply || value.actions.delete {
            if value.metadata?.reactionsSupported == true, !value.message.deleted {
                button("Add reaction", "face.smiling", enabled: value.metadata?.canChange == true) { [weak self] in self?.showReactions() }
            }
            if value.actions.reply { button("Reply in thread", "arrowshape.turn.up.left") { [weak self] in self?.perform(.reply) } }
            if value.actions.save { button("Edit message", "pencil", enabled: value.actions.edit) { [weak self] in self?.perform(.edit) } }
            if value.actions.delete { button("Delete message…", "trash") { [weak self] in self?.perform(.requestDelete(revision: value.message.revision)) } }
            button("More message actions", "ellipsis") { [weak self] in
                guard let self, let button = self.toolbar.buttons.last else { return }
                self.makeMenu()?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
            }
        }
        // Do not replace a focused action button on an unrelated repaint.
        if toolbar.buttons.map(\.title) == buttons.map(\.title) {
            for (old, new) in zip(toolbar.buttons, buttons) {
                old.invoke = new.invoke; old.isEnabled = new.isEnabled
                old.contentTintColor = new.contentTintColor; old.accent = new.accent
            }
        } else { toolbar.install(buttons) }
        toolbar.buttons.forEach { $0.accessibilityOwner = cell }
        if actions?.reactionPicker(messageID: id) == nil { popup.close(returnFocus: false) }
        refreshActive(); layout()
    }
    func layout() {
        guard let cell, let message, let layer = toolbar.superview else { return }
        let rect = cell.convert(cell.bounds, to: layer)
        toolbar.setFrameOrigin(NSPoint(x: rect.maxX - (message.inThread ? 8 : 20) - toolbar.frame.width, y: rect.minY - 12))
        popup.refresh()
    }
    func setSelected(_ value: Bool) { selected = value; refreshActive() }
    func hover(_ inside: Bool, toolbar: Bool = false) {
        hoverGeneration &+= 1
        if toolbar { toolbarInside = inside } else { pointerInside = inside }
        if inside { hovering = true; refreshActive() }
        else {
            let generation = hoverGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.hoverGeneration == generation else { return }
                self.hovering = self.pointerInside || self.toolbarInside
                self.refreshActive()
            }
        }
    }
    private func refreshActive() {
        let focused = toolbar.buttons.contains { $0.window?.firstResponder === $0 }
        active = hovering || selected || focused
        toolbar.isHidden = !active || message?.content.editing != nil || toolbar.buttons.isEmpty
        changed?(active)
    }
    @discardableResult private func perform(_ action: ChatTimelineActions.MessageAction) -> Bool {
        guard let id = message?.content.message.id else { return false }
        return actions?.perform(action, messageID: id) == true
    }
    private func copy(_ value: String?) {
        guard let value else { return }; pasteboard.clearContents(); pasteboard.setString(value, forType: .string)
    }
    func showReactions() {
        guard let cell, let id = message?.content.message.id, let content = actions?.reactionPicker(messageID: id) else { return }
        popup.show(content, from: cell)
    }
    func makeMenu() -> NSMenu? {
        guard let value = message?.content, let state else { return nil }
        let source = value.message, id = source.id, menu = NSMenu()
        menu.autoenablesItems = false
        menuCallbacks.removeAll()
        func item(_ title: String, enabled: Bool = true, checked: Bool = false, _ callback: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self; item.isEnabled = enabled; item.state = checked ? .on : .off
            let binding = identity
            menuCallbacks[ObjectIdentifier(item)] = { [weak self] in
                guard let self, self.identity == binding else { return }; callback()
            }
            menu.addItem(item)
        }
        let full = source.hasFixed && (!source.deleted || state.isDM)
        if full {
            if value.metadata?.reactionsSupported == true { item("Add reaction…", enabled: value.metadata?.canChange == true) { [weak self] in self?.showReactions() } }
            if let metadata = value.metadata, metadata.pinsSupported {
                item(metadata.value?.pin == nil ? "Pin message" : "Unpin message",
                     enabled: metadata.canChange && metadata.value != nil && !metadata.intents.contains { $0.choice == "pin" && $0.error == nil }) { [weak self] in self?.perform(.togglePin) }
            }
            if value.actions.reply { item("Reply in Thread") { [weak self] in self?.perform(.reply) } }
        }
        if source.hasFixed, source.localState == nil { item("Open as tab") { [weak self] in self?.perform(.openAsTab) } }
        if full {
            if value.actions.copyLink != nil { item("Copy message link") { [weak self] in self?.copy(self?.actions?.copyLink(messageID: id)) } }
            item("Always show time", checked: style?.alwaysShowTime == true) {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "chat.ux2.alwaysShowTime"), forKey: "chat.ux2.alwaysShowTime")
            }
            item("Copy text") { [weak self] in self?.copy(self?.actions?.copyText(messageID: id)) }
            if value.actions.save, !state.archived { item("Edit", enabled: value.actions.edit) { [weak self] in self?.perform(.edit) } }
            if value.actions.delete { item("Delete…") { [weak self] in self?.perform(.requestDelete(revision: source.revision)) } }
        }
        return menu.items.isEmpty ? nil : menu
    }
    @objc private func menuAction(_ sender: NSMenuItem) { menuCallbacks[ObjectIdentifier(sender)]?() }
    func unbind() {
        popup.close(returnFocus: false); toolbar.removeFromSuperview(); toolbar.install([])
        toolbar.pointerChanged = nil; menuCallbacks.removeAll()
        pointerInside = false; toolbarInside = false; hovering = false; selected = false; active = false; hoverGeneration &+= 1
        identity = nil; message = nil; actions = nil; cell = nil; changed?(false)
    }
}
