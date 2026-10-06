import AppKit
import SwiftUI

/// Read-only native text keeps Markdown selection and per-address tooltips.
/// The address itself stays canonical in the attributed string and clipboard.
struct ChatMentionText: NSViewRepresentable {
    var markdown: String
    var addresses: [String]

    static func attributed(_ markdown: String, addresses: [String]) -> NSAttributedString {
        let rendered = ChatMarkdownText.attributed(markdown)
        let text = NSMutableAttributedString(attributedString: NSAttributedString(rendered))
        let all = NSRange(location: 0, length: text.length)
        text.addAttributes([.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor], range: all)
        var offset = 0
        for run in rendered.runs {
            let length = String(rendered[run.range].characters).utf16.count
            let range = NSRange(location: offset, length: length)
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                : NSFont.systemFont(ofSize: NSFont.systemFontSize)
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            text.addAttribute(.font, value: font, range: range)
            if intent.contains(.code) { text.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range) }
            if intent.contains(.strikethrough) { text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            offset += length
        }
        for address in addresses {
            for range in ChatMentions.ranges(address, in: text.string) {
                text.addAttributes([.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.15),
                                    .toolTip: "@" + address], range: range)
            }
        }
        return text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { _ = ChatMarkdownText.open(url) }
            return true
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        let content = Self.attributed(markdown, addresses: addresses)
        if view.textStorage?.isEqual(to: content) != true { view.textStorage?.setAttributedString(content) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}
