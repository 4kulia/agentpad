import AppKit
import Observation

enum ChatEditingKey: Equatable {
    case save, cancel, native
    static func action(code: UInt16, modifiers: NSEvent.ModifierFlags, markedText: Bool = false) -> Self {
        guard !markedText else { return .native }
        let modifiers = modifiers.intersection([.command, .control, .option, .shift])
        if (code == 36 || code == 76), modifiers == .command { return .save }
        if code == 53, modifiers.isEmpty { return .cancel }
        return .native
    }
}

enum ChatComposerKey: Equatable {
    case send, editLast, previousCandidate, nextCandidate, chooseCandidate, dismissCandidates, closeThread, native

    static func action(code: UInt16, modifiers: NSEvent.ModifierFlags, markedText: Bool = false,
                       hasCandidates: Bool, text: String, inThread: Bool) -> Self {
        guard !markedText else { return .native }
        let modifiers = modifiers.intersection([.command, .control, .option, .shift])
        if (code == 36 || code == 76) && modifiers == .command { return .send }
        guard modifiers.isEmpty else { return .native }
        if hasCandidates {
            switch code {
            case 125: return .nextCandidate
            case 126: return .previousCandidate
            case 36, 48, 76: return .chooseCandidate
            case 53: return .dismissCandidates
            default: return .native
            }
        }
        if code == 126 && text.isEmpty { return .editLast }
        if code == 53 && inThread { return .closeThread }
        return .native
    }
}

enum ChatMarkdownInsertion: String, CaseIterable {
    case bold, italic, strike, code, link, list, quote
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strike: "strikethrough"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .list: "list.bullet"
        case .quote: "text.quote"
        }
    }

    struct Edit: Equatable {
        var range: NSRange
        var replacement: String
        var selection: NSRange
    }

    func edit(text: String, selection: NSRange) -> Edit {
        let string = text as NSString
        let start = min(max(0, selection.location), string.length)
        let range = NSRange(location: start, length: min(max(0, selection.length), string.length - start))
        let selected = string.substring(with: range)
        if self == .list || self == .quote {
            let lines = string.lineRange(for: range)
            let source = string.substring(with: lines)
            let prefix = self == .list ? "- " : "> "
            var parts = source.components(separatedBy: "\n")
            for index in parts.indices where index < parts.count - 1 || !parts[index].isEmpty || parts.count == 1 { parts[index] = prefix + parts[index] }
            let replacement = parts.joined(separator: "\n")
            return Edit(range: lines, replacement: replacement,
                        selection: NSRange(location: lines.location + (replacement as NSString).length, length: 0))
        }
        let delimiters: (String, String)
        switch self {
        case .bold: delimiters = ("**", "**")
        case .italic: delimiters = ("*", "*")
        case .strike: delimiters = ("~~", "~~")
        case .code: delimiters = selected.contains("\n") ? ("```\n", "\n```") : ("`", "`")
        case .link: delimiters = ("[", "](https://)")
        default: delimiters = ("", "")
        }
        let content = selected.isEmpty && self == .link ? "link text" : selected
        let replacement = delimiters.0 + content + delimiters.1
        let target = self == .link && !selected.isEmpty
            ? NSRange(location: start + 1 + (content as NSString).length + 2, length: 8)
            : NSRange(location: start + (delimiters.0 as NSString).length, length: (content as NSString).length)
        return Edit(range: range, replacement: replacement, selection: target)
    }
}

/// Toolbar mutations go through NSTextView, preserving its undo stack, IME and
/// UTF-16 selection, instead of replacing the SwiftUI string behind the editor.
@MainActor
@Observable
final class ChatEditorControl {
    @ObservationIgnored weak var view: ChatMentionEditor.Editor?
    var focused = false
    func clearAfterSend() {
        // AppKit can receive another keystroke before SwiftUI updates the view.
        // Clear synchronously so it cannot save the sent text as a new draft.
        view?.string = ""
        view?.setSelectedRange(NSRange(location: 0, length: 0))
        view?.needsDisplay = true
    }
    func focus() {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return }
        window.makeFirstResponder(view)
    }
    func format(_ command: ChatMarkdownInsertion) {
        guard let view, !view.hasMarkedText() else { return }
        let edit = command.edit(text: view.string, selection: view.selectedRange())
        view.insertText(edit.replacement, replacementRange: edit.range)
        view.setSelectedRange(edit.selection)
        view.window?.makeFirstResponder(view)
    }
    func insert(_ text: String) {
        guard let view, !view.hasMarkedText() else { return }
        view.insertText(text, replacementRange: view.selectedRange())
        view.window?.makeFirstResponder(view)
    }
    func emoji() {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
        NSApp.orderFrontCharacterPalette(view)
    }
    func replace(_ range: NSRange, with text: String) {
        guard let view, !view.hasMarkedText() else { return }
        view.insertText(text, replacementRange: range)
        view.window?.makeFirstResponder(view)
    }
}
