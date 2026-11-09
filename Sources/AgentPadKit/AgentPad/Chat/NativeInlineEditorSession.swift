import AppKit

/// The footer's HStack measures its least flexible labels first, sharing the
/// remaining width before handing unused space to the spacer. Keep these
/// measurements in the row plan so the table and the attached host agree.
struct ChatNativeEditorFooterLayout: Equatable, Sendable {
    struct Label: Equatable, Sendable {
        let text: String
        let frame: CGRect
    }
    let frame: CGRect
    let loading: Label
    let problem: Label
    let readOnly: Label
    let cancel: CGRect
    let save: CGRect

    @MainActor static func label(_ text: String, color: NSColor) -> NSAttributedString {
        ChatNativeTextStyle.label(text, font: .systemFont(ofSize: 10), color: color,
            pushOut: true, hyphenates: true)
    }

    @MainActor init(message: NativeTimelineSnapshot.Message, state: NativeTimelineSnapshot.State,
                    width: CGFloat, scale: CGFloat) {
        let strings = [message.content.message.loading ? "Loading the current message…" : "",
                       message.content.editing?.problem ?? "",
                       state.archived ? (state.isDM ? "Read-only: it can't be changed" : "Archived: it can't be changed") : ""]
        // Share the displayed caption's system wrapping and automatic
        // hyphenation policy, including the initial proposal before resizing.
        let labels = strings.map { Self.label($0, color: .labelColor) }
        func size(_ text: NSAttributedString, width: CGFloat = .greatestFiniteMagnitude) -> CGSize {
            ChatNativeTextStyle.size(text, width: width, scale: scale)
        }
        let titles = ["Cancel", "Save"]
        let visible = labels.indices.filter { labels[$0].length > 0 }
        let spacing: CGFloat = 8 + (strings[2].isEmpty ? 0 : 8)
            + (strings[0].isEmpty || strings[1].isEmpty ? 0 : 8)
        var remaining = width - spacing - 8
        let labelIdeals = labels.map { size($0).width }
        let buttonIdeals = titles.map { ChatNativeActionButton.measuredSize($0, width: .greatestFiniteMagnitude, scale: scale).width }
        let ordered = (visible + [3, 4]).sorted { lhs, rhs in
            let left = lhs < 3 ? labelIdeals[lhs] : buttonIdeals[lhs - 3] - ChatNativeActionButton.minimumTitlePadding
            let right = rhs < 3 ? labelIdeals[rhs] : buttonIdeals[rhs - 3] - ChatNativeActionButton.minimumTitlePadding
            return left == right ? lhs < rhs : left < right
        }
        var sizes = Array(repeating: CGSize.zero, count: 5)
        for (offset, index) in ordered.enumerated() {
            let proposal = max(0, remaining / CGFloat(ordered.count - offset))
            sizes[index] = index < 3 ? size(labels[index], width: max(1, proposal))
                : ChatNativeActionButton.measuredSize(titles[index - 3], width: proposal, scale: scale)
            remaining -= sizes[index].width
        }
        let cancelSize = sizes[3], saveSize = sizes[4]
        let height = max(cancelSize.height, saveSize.height, sizes.map(\.height).max() ?? 0)
        func rect(_ size: CGSize, x: CGFloat) -> CGRect {
            CGRect(x: x, y: 204 + (height - size.height) / 2, width: size.width, height: size.height)
        }
        frame = CGRect(x: 0, y: 204, width: width, height: height)
        save = rect(saveSize, x: width - saveSize.width)
        cancel = rect(cancelSize, x: save.minX - 8 - cancelSize.width)
        readOnly = Label(text: strings[2], frame: rect(sizes[2], x: cancel.minX - 8 - sizes[2].width))
        loading = Label(text: strings[0], frame: rect(sizes[0], x: 0))
        problem = Label(text: strings[1], frame: rect(sizes[1], x: sizes[0].width > 0 ? sizes[0].width + 8 : 0))
    }
}

/// A single presentation session for an authoritative domain edit. It owns the
/// actual input client, not a serialization of its selection/IME/undo state.
@MainActor final class NativeInlineEditorSession: NSObject, NSTextViewDelegate {
    let identity: NativeTimelineSnapshot.RowID
    let root: String?
    let host = ChatNativeEditorHost()
    let editor = ChatMentionEditor.Editor()
    let control = ChatEditorControl()
    let undo = UndoManager()
    private weak var actions: ChatTimelineActions?
    private(set) var draft: ChatChannelModel.Editing
    private var updating = false
    private var disposed = false
    private var attached = false
    private var didAutofocus = false
    private var foreground = NSColor.labelColor
    var requestsChanged: (() -> Void)?

    init(identity: NativeTimelineSnapshot.RowID, draft: ChatChannelModel.Editing, actions: ChatTimelineActions?) {
        self.identity = identity; root = draft.root; self.draft = draft; self.actions = actions
        super.init()
        // Same native input client and formatting policy as ChatMentionEditor.
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 12)
        editor.font = NSFont(name: "Onest", size: 13) ?? .systemFont(ofSize: 13)
        editor.backgroundColor = .clear; editor.drawsBackground = false
        editor.delegate = self
        editor.setAccessibilityLabel("Edit message")
        editor.setAccessibilityHelp("Command Return to send or save. Return for a new line. Escape to close editing or thread.")
        editor.consume = { [weak self] code, modifiers in
            guard let self else { return false }
            switch ChatEditingKey.action(code: code, modifiers: modifiers, markedText: self.editor.hasMarkedText()) {
            case .save: self.save(); return true
            case .cancel: self.cancel(); return true
            case .native: return false
            }
        }
        control.view = editor
        // Like ChatMentionEditor.makeNSView/updateNSView, install the empty
        // document before populating its storage and laying out its contents.
        host.scroll.documentView = editor
        editor.string = draft.text
        // ChatMentionEditor measures the populated document before SwiftUI
        // supplies its first viewport width. Preserve that initial TextKit
        // layout so AppKit carries the same reading position into resizing.
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        host.save.invoke = { [weak self] in self?.save() }
        host.cancel.invoke = { [weak self] in self?.cancel() }
        host.attachedToWindow = { [weak self] in self?.focusOnceAfterAttachment() }
        for command in ChatMarkdownInsertion.allCases {
            let button = ChatNativeActionButton(command.title, symbol: command.symbol)
            button.invoke = { [weak self] in self?.control.format(command) }
            host.formatting.append(button); host.addSubview(button)
        }
    }
    func attach(to layer: ChatNativeDocumentLayer) {
        guard !disposed, !attached else { return }
        attached = true
        layer.addSubview(host)
        host.layoutSubtreeIfNeeded()
        // Preserve the original draft-end selection after the editor
        // has its layout. Do this once; later updates retain selection/IME.
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        focusOnceAfterAttachment()
    }
    private func focusOnceAfterAttachment() {
        // A restored draft is configured by makeNSView before its window exists.
        // Consume initial focus only on actual attachment, never on repaint.
        guard attached, !disposed, !didAutofocus, !host.isHiddenOrHasHiddenAncestor,
              host.window != nil else { return }
        // Match the existing input client's deferred attachment autofocus.
        // AppKit must see the laid-out document before becoming first responder.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.attached, !self.disposed, !self.didAutofocus,
                  !self.host.isHiddenOrHasHiddenAncestor, let window = self.host.window else { return }
            self.didAutofocus = window.makeFirstResponder(self.editor)
            let focused = window.firstResponder === self.editor
            self.control.focused = focused; self.host.focused = focused
        }
    }
    var ownsFocus: Bool {
        guard let responder = host.window?.firstResponder as? NSView else { return false }
        return responder === host || responder.isDescendant(of: host)
    }
    func update(_ draft: ChatChannelModel.Editing, message: NativeTimelineSnapshot.Message,
                style: NativeTimelineSnapshot.Style, frame: CGRect, footer: ChatNativeEditorFooterLayout) {
        guard !disposed else { return }
        // A snapshot may be prepared before a keystroke/durable draft adoption.
        // Resolve the domain owner again before touching the live input client.
        self.draft = actions?.activeEditing(messageID: draft.messageId) ?? draft
        foreground = style.color("foreground")
        host.frame = frame; host.style = style; host.footer = footer
        host.save.isEnabled = message.content.actions.save
        host.save.chromeForeground = foreground; host.cancel.chromeForeground = foreground
        host.loading.text = label(footer.loading.text, color: style.color("secondary"))
        host.problem.text = label(footer.problem.text, color: style.color("failure"))
        host.readOnly.text = label(footer.readOnly.text, color: foreground.withAlphaComponent(0.5))
        for button in host.formatting { button.contentTintColor = style.color("secondary"); button.accent = style.color("accent") }
        host.needsLayout = true; host.layoutSubtreeIfNeeded()
        refreshText()
    }
    private func label(_ text: String, color: NSColor) -> NSAttributedString {
        ChatNativeEditorFooterLayout.label(text, color: color)
    }
    private func refreshText() {
        // The existing editor update contract never rewrites a marked range.
        guard !editor.hasMarkedText() else { return }
        updating = true; defer { updating = false }
        let selection = editor.selectedRange()
        if editor.string != draft.text {
            editor.string = draft.text
            let length = (draft.text as NSString).length
            editor.setSelectedRange(NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location))))
        }
        editor.textStorage?.setAttributes([.font: editor.font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: foreground],
            range: NSRange(location: 0, length: (editor.string as NSString).length))
        // Match ChatMentionEditor: keep AppKit's inherited typing attributes.
        // Overriding them changes the stored foreground of live marked text.
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
    }
    func undoManager(for view: NSTextView) -> UndoManager? { undo }
    func textDidChange(_ notification: Notification) {
        guard !disposed, !updating else { return }
        actions?.updateEditing(messageID: draft.messageId, version: draft.version, text: editor.string)
        if let current = actions?.activeEditing(messageID: draft.messageId) { draft = current }
        host.needsDisplay = true
    }
    func textDidBeginEditing(_ notification: Notification) { control.focused = true; host.focused = true }
    func textDidEndEditing(_ notification: Notification) { control.focused = false; host.focused = false }
    func textViewDidChangeSelection(_ notification: Notification) {
        host.focused = host.window?.firstResponder === editor
    }
    func save() {
        guard !disposed, host.save.isEnabled, !editor.hasMarkedText() else { return }
        _ = actions?.saveEditing(messageID: draft.messageId)
        refreshAfterRequest()
    }
    func cancel() {
        guard !disposed else { return }
        actions?.cancelEditing(messageID: draft.messageId)
        refreshAfterRequest()
    }
    private func refreshAfterRequest() {
        if let current = actions?.activeEditing(messageID: draft.messageId) {
            draft = current; refreshText()
            host.problem.text = label(current.problem ?? "", color: host.style?.color("failure") ?? .systemRed)
        }
        // The controller observes the authoritative edit. Intent and even a
        // successful save Boolean are never a reason to dispose this session.
        requestsChanged?()
    }
    func dispose() {
        guard !disposed else { return }; disposed = true
        // Do not send save/cancel from UI cleanup. In particular unmarking must
        // not write a draft after the domain owner has removed it.
        editor.delegate = nil; editor.consume = nil
        editor.inputContext?.discardMarkedText(); editor.unmarkText()
        editor.mentionPopup.detach()
        if ownsFocus { host.window?.makeFirstResponder(nil) }
        if host.accessibilityOwner?.accessibilityEditor === host { host.accessibilityOwner?.accessibilityEditor = nil }
        host.accessibilityOwner = nil
        host.removeFromSuperview()
        editor.string = ""; undo.removeAllActions(); control.view = nil
        actions = nil; requestsChanged = nil
        host.save.invoke = nil; host.cancel.invoke = nil
        host.attachedToWindow = nil
        host.formatting.forEach { $0.invoke = nil }
    }
}

@MainActor final class ChatNativeEditorHost: NSView {
    weak var accessibilityOwner: ChatNativeShellCell?
    override func accessibilityParent() -> Any? { accessibilityOwner ?? super.accessibilityParent() }
    override func accessibilityChildren() -> [Any]? {
        NSAccessibility.unignoredChildren(from: (formatting + [scroll, loading, problem, readOnly, cancel, save])
            .filter { !$0.isHiddenOrHasHiddenAncestor && !$0.frame.isEmpty })
    }
    var attachedToWindow: (() -> Void)?
    let scroll = NSScrollView()
    let save = ChatNativeActionButton("Save")
    let cancel = ChatNativeActionButton("Cancel")
    let loading = ChatNativeLabel(), problem = ChatNativeLabel(), readOnly = ChatNativeLabel()
    private let border = ChatNativeEditorBorder()
    static var minimumFormattingWidth: CGFloat {
        CGFloat(ChatMarkdownInsertion.allCases.count) * (28 + 2) + 16
    }
    var formatting: [ChatNativeActionButton] = []
    var style: NativeTimelineSnapshot.Style? { didSet { needsDisplay = true; border.needsDisplay = true } }
    var focused = false { didSet { border.needsDisplay = true } }
    var formattingBackgroundRect: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: 36) }
    var formattingSeparatorRect: CGRect { CGRect(x: 0, y: 35, width: bounds.width, height: 1) }
    private(set) var footerFrame: CGRect = .zero
    var footer: ChatNativeEditorFooterLayout?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        save.constrainsTitle = true; cancel.constrainsTitle = true
        for view in [scroll, save, cancel, loading, problem, readOnly, border] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Edit message")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attachedToWindow?() }
    }
    override func layout() {
        super.layout()
        for (index, button) in formatting.enumerated() { button.frame = CGRect(x: 8 + index * 30, y: 4, width: 28, height: 28) }
        scroll.frame = CGRect(x: 0, y: 40, width: bounds.width, height: 160)
        border.frame = scroll.frame
        guard let footer else { return }
        footerFrame = footer.frame
        save.frame = footer.save; cancel.frame = footer.cancel
        loading.frame = footer.loading.frame; problem.frame = footer.problem.frame; readOnly.frame = footer.readOnly.frame
        loading.isHidden = loading.text.length == 0; problem.isHidden = problem.text.length == 0; readOnly.isHidden = readOnly.text.length == 0
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        style.color("hover").setFill(); formattingBackgroundRect.fill()
        style.color("separator").setFill(); formattingSeparatorRect.fill()
    }
}

/// Like the legacy overlay, the border is above the scrolling text, including
/// partially clipped lines at either edge. It never intercepts editor input.
@MainActor private final class ChatNativeEditorBorder: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let host = superview as? ChatNativeEditorHost, let style = host.style,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let line: CGFloat = host.focused ? 2 : 1
        style.color(host.focused ? "accent" : "border").setStroke()
        context.addPath(ChatNativeShapes.roundedRect(bounds.insetBy(dx: line / 2, dy: line / 2), radius: 5 - line / 2))
        context.setLineWidth(line); context.strokePath()
    }
}
