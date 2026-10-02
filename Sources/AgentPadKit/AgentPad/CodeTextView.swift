import AppKit
import SwiftUI

/// Read-only code/text view: highlighted, with a line-number gutter and the
/// standard find bar (⌘F). AppKit's NSTextView handles multi-MB files and
/// selection/copy for free.
struct CodeTextView: NSViewRepresentable {
    let text: String
    /// Highlight spans, computed off the main thread when the file loaded.
    let spans: [SyntaxHighlighter.Span]
    /// Changes whenever the file is reloaded, so the view knows to re-render.
    let revision: Int

    final class Coordinator {
        var revision = -1
        var text = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        // No wrapping: code reads by line.
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]

        let ruler = LineNumberRulerView(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        apply(to: textView, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        apply(to: textView, context: context)
    }

    private func apply(to textView: NSTextView, context: Context) {
        guard context.coordinator.revision != revision || context.coordinator.text != text else { return }
        let sameFileReload = context.coordinator.revision != -1 && !context.coordinator.text.isEmpty
        context.coordinator.revision = revision
        context.coordinator.text = text
        let visible = textView.enclosingScrollView?.contentView.bounds.origin
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textStorage?.setAttributedString(SyntaxHighlighter.attributed(text, spans: spans, font: font))
        // A live reload keeps the reader's place.
        if sameFileReload, let visible {
            textView.enclosingScrollView?.contentView.scroll(to: visible)
            textView.enclosingScrollView?.reflectScrolledClipView(textView.enclosingScrollView!.contentView)
        } else {
            textView.scroll(.zero)
        }
        textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
}

/// Line numbers for an NSTextView, drawn for the visible range only.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    private var lineStartsFor = -1

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(
            self, selector: #selector(textReplaced), name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(invalidate), name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func invalidate() { needsDisplay = true }

    /// Any content change can move line breaks without changing the length.
    @objc private func textReplaced() {
        lineStartsFor = -1
        needsDisplay = true
    }

    private func recomputeLineStarts(_ string: NSString) {
        guard lineStartsFor != string.length else { return }
        var starts = [0]
        var index = 0
        while index < string.length {
            let range = string.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            if index < string.length || (index == string.length && string.length > 0 && string.character(at: string.length - 1) == 10) {
                starts.append(index)
            }
        }
        lineStarts = starts
        lineStartsFor = string.length
        let digits = max(3, String(starts.count).count)
        let width = CGFloat(digits) * 7.5 + 14
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let string = textView.string as NSString
        recomputeLineStarts(string)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // First visible line by binary search over line starts.
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= chars.location { lo = mid } else { hi = mid - 1 }
        }
        let inset = textView.textContainerInset.height
        let relative = convert(NSPoint.zero, from: textView)
        var line = lo
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(chars) {
            let lineRect: NSRect
            if lineStarts[line] >= string.length {
                // The empty last line after a trailing newline (or an empty
                // file) has no glyph; it lives in the extra line fragment.
                let extra = layout.extraLineFragmentRect
                lineRect = extra.height > 0 ? extra : NSRect(x: 0, y: 0, width: 0, height: 15)
            } else {
                let glyph = layout.glyphIndexForCharacter(at: lineStarts[line])
                lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = relative.y + lineRect.minY + inset + (lineRect.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y), withAttributes: attributes)
            line += 1
        }
    }
}
