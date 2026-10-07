import Foundation

struct FilePreviewLocation: Equatable {
    let id = UUID()
    let line: Int
    let column: Int?

    /// AppKit ranges use UTF-16, while source columns are one-based characters.
    /// Clamp stale locations after an edit (or beyond the 5 MB preview limit).
    func range(in text: String) -> NSRange {
        let string = text as NSString
        var start = 0
        var currentLine = 1
        while currentLine < max(1, line), start < string.length {
            start = NSMaxRange(string.lineRange(for: NSRange(location: start, length: 0)))
            currentLine += 1
        }
        guard start < string.length else { return NSRange(location: string.length, length: 0) }
        var end = 0
        string.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: start, length: 0))
        let body = string.substring(with: NSRange(location: start, length: end - start))
        guard let column else { return NSRange(location: start, length: end - start) }
        let offset = body.index(body.startIndex, offsetBy: max(0, column - 1), limitedBy: body.endIndex) ?? body.endIndex
        let length = offset == body.endIndex ? 0 : String(body[offset]).utf16.count
        return NSRange(location: start + body[..<offset].utf16.count, length: length)
    }
}
