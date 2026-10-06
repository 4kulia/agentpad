import AppKit
import SwiftUI

struct ChatMentionCandidate: Equatable, Identifiable {
    var id: String
    var address: String
    var label: String
    var addToChannel = false
    var agentId: String?

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
    var key: (UInt16, NSEvent.ModifierFlags) -> Bool

    final class Editor: NSTextView {
        var consume: ((UInt16, NSEvent.ModifierFlags) -> Bool)?
        override func keyDown(with event: NSEvent) {
            if consume?(event.keyCode, event.modifierFlags) != true { super.keyDown(with: event) }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatMentionEditor
        init(_ parent: ChatMentionEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.selection = view.selectedRange()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.selection = view.selectedRange()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = Editor()
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 3, height: 5)
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
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
        view.consume = key
        if view.string != text { view.string = text }
        let length = (text as NSString).length
        let range = NSRange(location: 0, length: length)
        view.textStorage?.setAttributes([.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor], range: range)
        for candidate in candidates {
            for match in ChatMentions.ranges(candidate.address, in: text) {
                view.textStorage?.addAttributes([.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.15),
                    .toolTip: "@" + candidate.address], range: match)
            }
        }
        if selection.location <= length, selection.location + selection.length <= length, view.selectedRange() != selection { view.setSelectedRange(selection) }
    }
}
