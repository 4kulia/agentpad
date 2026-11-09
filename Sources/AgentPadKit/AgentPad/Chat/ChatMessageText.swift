import AppKit
import SwiftUI

/// The existing chat formatter and native text view, shared by both timelines.
/// Syntax, link policy, fonts, paragraph metrics and mention matching stay here.
@MainActor enum ChatMessageText {
    final class View: NSTextView {
        override var canBecomeKeyView: Bool { false }
    }

    struct Style: Hashable {
        let foreground: NSColor
        let accent: NSColor
        let appearance: String
    }
    private struct Content: Hashable {
        let markdown: String
        let addresses: [String]
        let fontSize: CGFloat
        let style: Style
    }
    private final class CacheKey: NSObject {
        let content: Content
        init(_ content: Content) { self.content = content }
        override var hash: Int { content.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? CacheKey)?.content == content }
    }
    private static let textCache: NSCache<CacheKey, NSAttributedString> = {
        let cache = NSCache<CacheKey, NSAttributedString>()
        cache.countLimit = 512
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    private static let fontCache: NSCache<NSString, NSFont> = {
        let cache = NSCache<NSString, NSFont>()
        cache.countLimit = 64
        return cache
    }()
    static var style: Style {
        Style(foreground: Theme.resolved.foregroundColor,
              accent: NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .controlAccentColor,
              appearance: NSApp.effectiveAppearance.name.rawValue)
    }
    private static func font(_ size: CGFloat, intent: InlinePresentationIntent) -> NSFont {
        let key = "\(size):\(intent.rawValue)" as NSString
        if let cached = fontCache.object(forKey: key) { return cached }
        var font = intent.contains(.code)
            ? (NSFont(name: "JetBrainsMono-Regular", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
            : (NSFont(name: "Onest", size: size) ?? NSFont.systemFont(ofSize: size))
        if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        fontCache.setObject(font, forKey: key)
        return font
    }
    static func attributed(_ markdown: String, addresses: [String], fontSize: CGFloat = 14,
                           style: Style? = nil) -> NSAttributedString {
        let style = style ?? Self.style
        let key = CacheKey(Content(markdown: markdown, addresses: addresses, fontSize: fontSize, style: style))
        if let cached = textCache.object(forKey: key) { return cached }
        let rendered = ChatMarkdownText.attributed(markdown)
        let text = NSMutableAttributedString(attributedString: NSAttributedString(rendered))
        let all = NSRange(location: 0, length: text.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = fontSize * 1.5
        paragraph.maximumLineHeight = fontSize * 1.5
        let baseFont = font(fontSize, intent: [])
        var fonts: [InlinePresentationIntent: NSFont] = [ []: baseFont]
        text.addAttributes([.font: baseFont,
                            .foregroundColor: style.foreground, .paragraphStyle: paragraph], range: all)
        var offset = 0
        for run in rendered.runs {
            let length = String(rendered[run.range].characters).utf16.count
            let range = NSRange(location: offset, length: length)
            let intent = run.inlinePresentationIntent ?? []
            let traits = intent.intersection([.code, .stronglyEmphasized, .emphasized])
            let runFont = fonts[traits] ?? font(fontSize, intent: traits)
            fonts[traits] = runFont
            text.addAttribute(.font, value: runFont, range: range)
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
        let result = NSAttributedString(attributedString: text)
        let cost = markdown.utf16.count * 2 + text.length * 24 + addresses.reduce(0) { $0 + $1.utf16.count * 2 }
        textCache.setObject(result, forKey: key, cost: max(1, cost))
        return result
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var markdown: String?
        var addresses: [String] = []
        var fontSize: CGFloat = 0
        var style: Style?
        /// Tests inject an opener; production retains the checked workspace route.
        var open: (URL) -> Void = { _ = ChatMarkdownText.open($0) }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL, let target = MarkdownRenderer.chatLinkTarget(url) { open(target) }
            return true
        }
    }

    static func makeView(delegate: NSTextViewDelegate) -> View {
        let view = View()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false
        view.delegate = delegate
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    /// A repaint of the same characters must preserve native selection/focus.
    static func setContent(_ content: NSAttributedString, in view: NSTextView) {
        guard view.textStorage?.isEqual(to: content) != true else { return }
        if view.string != content.string {
            view.textStorage?.setAttributedString(content)
        } else {
            view.textStorage?.beginEditing()
            content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attributes, range, _ in
                view.textStorage?.setAttributes(attributes, range: range)
            }
            view.textStorage?.endEditing()
        }
    }
}
