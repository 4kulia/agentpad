import Foundation

struct TerminalTextLink: Equatable {
    let value: String
    let range: NSRange
}

/// Only visible terminal text is inspected; this never reads or opens a file.
enum TerminalTextLinkDetector {
    private static let quoted = try! NSRegularExpression(pattern:
        #"(?:"[^"\r\n]+"|'[^'\r\n]+'|`[^`\r\n]+`)(?::[1-9][0-9]*(?::[1-9][0-9]*)?|#L[1-9][0-9]*(?:C[1-9][0-9]*)?)?"#)
    private static let token = try! NSRegularExpression(pattern: #"[^\s<>\"'`|()\[\]{}]+"#)

    static func urlPreview(in text: String, at offset: Int) -> String? {
        let string = text as NSString
        guard let match = token.matches(in: text, range: NSRange(location: 0, length: string.length))
            .first(where: { NSLocationInRange(offset, $0.range) }) else { return nil }
        let value = string.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: "()[],;"))
        guard URL(string: value)?.scheme != nil,
              value.contains("://") || value.hasPrefix("mailto:") || value.hasPrefix("file:") else { return nil }
        return value
    }

    static func link(in text: String, at offset: Int) -> TerminalTextLink? {
        let string = text as NSString
        let whole = NSRange(location: 0, length: string.length)
        for match in quoted.matches(in: text, range: whole) where NSLocationInRange(offset, match.range) {
            let value = string.substring(with: match.range)
            let path = TerminalOpenTargetResolver.unquote(value)
            guard TerminalOpenTargetResolver.looksLikePath(path) else { return nil }
            return TerminalTextLink(value: value, range: match.range)
        }
        for match in token.matches(in: text, range: whole) where NSLocationInRange(offset, match.range) {
            var range = match.range
            while range.length > 0, "([{".utf16.contains(string.character(at: range.location)) {
                range.location += 1
                range.length -= 1
            }
            while range.length > 0, ")]},;.!?:".utf16.contains(string.character(at: NSMaxRange(range) - 1)) {
                range.length -= 1
            }
            guard NSLocationInRange(offset, range) else { return nil }
            let value = string.substring(with: range)
            // URLs stay with the core, including its punctuation heuristics.
            guard !value.contains("://"), !value.hasPrefix("file:"),
                  TerminalOpenTargetResolver.looksLikePath(value) else { return nil }
            if URL(string: value)?.scheme != nil,
               !TerminalOpenTargetResolver.looksLikePath(value.components(separatedBy: ":")[0]) { return nil }
            return TerminalTextLink(value: value, range: range)
        }
        return nil
    }
}
