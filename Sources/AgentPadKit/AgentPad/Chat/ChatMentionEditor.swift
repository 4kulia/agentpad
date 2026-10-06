import AppKit
import SwiftUI

struct ChatMentionCandidate: Equatable, Identifiable {
    var id: String
    var address: String
    var label: String
    var addToChannel = false
    var agentId: String?
    var accessibilityName: String { "\(label), \(agentId == nil ? "person" : "BOT agent"), @\(address)" }

    static func token(_ text: String, caret: Int) -> (range: NSRange, query: String)? {
        let string = text as NSString
        guard caret >= 0, caret <= string.length else { return nil }
        let prefix = string.substring(to: caret)
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\w@])@[\\p{L}\\p{N}_@-]*$"),
              let match = regex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) else { return nil }
        return (match.range, (prefix as NSString).substring(with: match.range).dropFirst().description)
    }

    static func filtered(_ candidates: [Self], query: String) -> [Self] {
        candidates.filter { query.isEmpty || $0.address.localizedCaseInsensitiveContains(query) || $0.label.localizedCaseInsensitiveContains(query) }
    }
}

/// Canonical text is retained for copying; highlighting/tooltips are display
/// attributes only. AppKit supplies the actual caret and consumes popup keys.
struct ChatMentionEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var candidates: [ChatMentionCandidate]
    var autofocus = false
    var navigationTarget: ChannelRef? = nil
    var control: ChatEditorControl? = nil
    var heightChanged: ((CGFloat) -> Void)? = nil
    var placeholder = ""
    var accessibilityName = "Message"
    var suggestions: ChatMentionPopup.Content? = nil
    var key: (UInt16, NSEvent.ModifierFlags) -> Bool

    final class Editor: NSTextView {
        let mentionPopup = ChatMentionPopup()
        var navigationTarget: ChannelRef?
        var consume: ((UInt16, NSEvent.ModifierFlags) -> Bool)?
        var focusOnAttach = false
        var placeholder = "" { didSet { needsDisplay = true } }
        private var didAutofocus = false
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if string.isEmpty && !hasMarkedText() {
                (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                    withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            mentionPopup.attach(to: self)
            focusIfNeeded()
            ChatSidebarMention.editorReady(self)
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            mentionPopup.detach()
            super.viewWillMove(toWindow: newWindow)
        }
        override func layout() {
            super.layout()
            mentionPopup.refresh()
        }
        override func viewDidHide() {
            super.viewDidHide()
            mentionPopup.hide()
        }
        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            mentionPopup.scheduleRefresh()
            return result
        }
        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result { mentionPopup.hide() }
            return result
        }
        func focusIfNeeded() {
            guard focusOnAttach, !didAutofocus else { return }
            // SwiftUI attaches lazy rows after updateNSView. Focus only once,
            // after attachment, so later model updates never steal it back.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusOnAttach, !self.didAutofocus, let window = self.window else { return }
                self.didAutofocus = window.makeFirstResponder(self)
            }
        }
        override func keyDown(with event: NSEvent) {
            if hasMarkedText() || consume?(event.keyCode, event.modifierFlags) != true { super.keyDown(with: event) }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatMentionEditor
        var updating = false
        init(_ parent: ChatMentionEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.selection = view.selectedRange()
            view.needsDisplay = true
            measure(view)
        }
        func measure(_ view: NSTextView) {
            guard let container = view.textContainer, let layout = view.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = min(160, max(58, ceil(layout.usedRect(for: container).height + 24)))
            let callback = parent.heightChanged
            let control = parent.control
            DispatchQueue.main.async { [weak view] in
                callback?(height)
                control?.focused = view != nil && view?.window?.firstResponder === view
            }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.selection = view.selectedRange()
            measure(view)
        }
        func textDidBeginEditing(_ notification: Notification) { parent.control?.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.control?.focused = false }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = Editor()
        ChatSidebarMention.register(view)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 8, height: 12)
        view.font = NSFont(name: "Onest", size: 13) ?? .systemFont(ofSize: 13)
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? Editor else { return }
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        control?.view = view
        view.consume = key
        view.navigationTarget = navigationTarget
        view.placeholder = placeholder
        view.setAccessibilityLabel(accessibilityName)
        view.setAccessibilityHelp("Command Return to send or save. Return for a new line. Escape to close editing or thread.")
        view.focusOnAttach = autofocus
        view.focusIfNeeded()
        view.mentionPopup.update(suggestions)
        guard !view.hasMarkedText() else { return }
        if view.string != text { view.string = text }
        let length = (text as NSString).length
        let range = NSRange(location: 0, length: length)
        // Do not disturb a marked range while the input method owns it.
        view.textStorage?.setAttributes([.font: NSFont(name: "Onest", size: 13) ?? NSFont.systemFont(ofSize: 13),
                                        .foregroundColor: Theme.resolved.foregroundColor], range: range)
        for candidate in candidates {
            for match in ChatMentions.ranges(candidate.address, in: text) {
                view.textStorage?.addAttributes([.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.15),
                    .toolTip: "@" + candidate.address], range: match)
            }
        }
        if selection.location <= length, selection.location + selection.length <= length, view.selectedRange() != selection { view.setSelectedRange(selection) }
        context.coordinator.measure(view)
        ChatSidebarMention.editorReady(view)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? Editor)?.mentionPopup.detach()
    }
}
