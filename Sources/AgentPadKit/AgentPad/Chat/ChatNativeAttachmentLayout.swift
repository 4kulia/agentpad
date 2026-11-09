import AppKit
import CoreText

/// Pure geometry from declared attachment metadata. A decoded bitmap never
/// participates in measurement, and measuring an offscreen row starts no work.
struct ChatNativeAttachmentLayout: Equatable, Sendable {
    struct Card: Equatable, Sendable {
        let file: ChatAttachment
        var frame: CGRect = .zero
        var background: CGRect = .zero
        var image: CGRect = .zero
        var name: CGRect = .zero
        var detail: CGRect = .zero
        var detailLineLimit: Int?
        var document: CGRect = .zero
        var save: CGRect = .zero
        var problem: CGRect = .zero
        var retry: CGRect = .zero
        var problemText: String?
    }
    var cards: [Card] = []
    let bottom: CGFloat

    @MainActor static func text(_ string: String, style: NativeTimelineSnapshot.Style,
                                size: CGFloat = 10, weight: NSFont.Weight = .regular,
                                color: String = "secondary", truncates: Bool = false) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: ChatNativeTextStyle.label(string,
            font: ChatNativeTextStyle.font(style.metrics.displayFont, size: size, weight: weight), color: style.color(color)))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncates ? .byTruncatingTail : .byWordWrapping
        if !truncates { paragraph.lineBreakStrategy = .pushOut }
        paragraph.tighteningFactorForTruncation = 0
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        return text
    }
    @MainActor init(message: NativeTimelineSnapshot.Message, style: NativeTimelineSnapshot.Style, body: CGRect,
                    constrainsHeight: Bool = false) {
        let content = message.content, files = content.message.attachments
        guard !content.message.deleted, content.attachments.available else { bottom = body.maxY; return }
        let scale = style.metrics.scale
        func size(_ string: String, width: CGFloat, font: CGFloat = 10, weight: NSFont.Weight = .regular,
                  single: Bool = false, lines: Int? = nil) -> CGSize {
            let value = Self.text(string, style: style, size: font, weight: weight, truncates: single)
            if let lines, lines > 1 {
                let storage = NSTextStorage(attributedString: value), manager = NSLayoutManager()
                let container = NSTextContainer(containerSize: CGSize(width: width, height: .greatestFiniteMagnitude))
                container.lineFragmentPadding = 0; container.maximumNumberOfLines = lines
                container.lineBreakMode = .byTruncatingTail
                storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
                let measured = manager.usedRect(for: container)
                return CGSize(width: min(width, ceil(measured.width * scale) / scale), height: ceil(measured.height * scale) / scale)
            }
            let measured = ChatNativeTextStyle.size(value, width: single ? .greatestFiniteMagnitude : width, scale: scale)
            if single, measured.width > width {
                let line = CTLineCreateWithAttributedString(value)
                let token = CTLineCreateWithAttributedString(Self.text("…", style: style, size: font, weight: weight))
                if let truncated = CTLineCreateTruncatedLine(line, width, .end, token) {
                    return CGSize(width: ceil(CTLineGetTypographicBounds(truncated, nil, nil, nil) * scale) / scale, height: measured.height)
                }
            }
            return CGSize(width: min(width, measured.width), height: measured.height)
        }
        func card(_ file: ChatAttachment, width: CGFloat, declared: CGFloat, maximumHeight: CGFloat) -> Card {
            var value = Card(file: file, problemText: content.attachments.problems[file.id])
            if file.isImage {
                let height: CGFloat
                if let w = file.width, let h = file.height, w > 0, h > 0 {
                    height = max(44, min(maximumHeight, declared * CGFloat(h) / CGFloat(w)))
                } else { height = maximumHeight }
                value.image = CGRect(x: 0, y: 0, width: min(width, declared), height: height)
                value.background = value.image
                value.name = CGRect(origin: CGPoint(x: 0, y: height + 4), size: size(file.name, width: width, single: true))
                value.frame.size = CGSize(width: max(value.image.width, value.name.width), height: value.name.maxY)
            } else {
                let symbol = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 23, weight: .regular))
                // SwiftUI preserves the 23-point symbol's half-point optical
                // height; NSImage rounds its representation up to whole points.
                let docSize = CGSize(width: symbol?.alignmentRect.width ?? 25, height: ceil(28.5 * scale) / scale)
                let controlSide: CGFloat = content.attachments.busyFileIDs.contains(file.id) ? 10 : 28
                let textWidth = max(1, width - 20 - docSize.width - 30 - 4 - controlSide)
                let name = size(file.name, width: textWidth, font: 12, weight: .medium, single: true)
                let detailText = "\(file.mime) · \(file.sizeText)"
                var detail = size(detailText, width: textWidth)
                if constrainsHeight, let problem = value.problemText {
                    let singleDetail = size(detailText, width: textWidth, single: true)
                    let naturalHeight = max(docSize.height, name.height + 3 + detail.height, controlSide) + 20
                    let minimumHeight = max(docSize.height, name.height + 3 + singleDetail.height, controlSide) + 20
                    let retry = content.attachments.availableFileIDs.contains(file.id) ? size("Retry", width: width) : .zero
                    let problemWidth = max(1, width - (retry.width > 0 ? retry.width + 8 : 0))
                    let footerHeight = max(retry.height, size(problem, width: problemWidth).height)
                    let minimumFooter = max(retry.height, size(problem, width: problemWidth, single: true).height)
                    if naturalHeight - minimumHeight <= footerHeight - minimumFooter {
                        let proposal = (naturalHeight + footerHeight) / 2
                        let detailProposal = max(0, proposal - 20 - name.height - 3)
                        let lineLimit = max(1, Int(floor(detailProposal / max(1, singleDetail.height))))
                        if CGFloat(lineLimit) * singleDetail.height < detail.height {
                            value.detailLineLimit = lineLimit
                            detail = lineLimit == 1 ? singleDetail : size(detailText, width: textWidth, lines: lineLimit)
                        }
                    }
                }
                let textHeight = name.height + 3 + detail.height
                let height = max(docSize.height, textHeight, controlSide) + 20
                value.background = CGRect(x: 0, y: 0, width: width, height: height)
                value.document = CGRect(x: 10, y: ((height - docSize.height) * scale / 2).rounded() / scale, width: docSize.width, height: docSize.height)
                let x = value.document.maxX + 10, y = (height - textHeight) / 2
                value.name = CGRect(origin: CGPoint(x: x, y: y), size: name)
                value.detail = CGRect(origin: CGPoint(x: x, y: y + name.height + 3), size: detail)
                value.save = CGRect(x: width - 10 - controlSide, y: (height - controlSide) / 2, width: controlSide, height: controlSide)
                value.frame.size = value.background.size
            }
            if let problem = value.problemText {
                let retry = content.attachments.availableFileIDs.contains(file.id) ? size("Retry", width: width) : .zero
                let problemSize = size(problem, width: max(1, width - (retry.width > 0 ? retry.width + 8 : 0)))
                let height = max(problemSize.height, retry.height), y = value.frame.height + 4
                value.problem = CGRect(origin: CGPoint(x: 0, y: y + (height - problemSize.height) / 2), size: problemSize)
                if retry.width > 0 { value.retry = CGRect(origin: CGPoint(x: problemSize.width + 8, y: y + (height - retry.height) / 2), size: retry) }
                value.frame.size.height = y + height
                value.frame.size.width = max(value.frame.width, value.problem.maxX, value.retry.maxX)
            }
            return value
        }
        // The empty authorized container still contributes top padding and its
        // parent VStack's spacing, just as ChatMessageAttachments does today.
        var y = body.maxY + 3 + 5
        let images = files.filter(\.isImage), width = min(body.width, message.inThread ? 280 : 360)
        if images.count > 1 {
            let minimum: CGFloat = message.inThread ? 110 : 150
            let columns = max(1, Int((width + 8) / (minimum + 8)))
            let columnWidth = (width - CGFloat(columns - 1) * 8) / CGFloat(columns)
            for start in stride(from: 0, to: images.count, by: columns) {
                var group: [Card] = []
                for offset in 0..<min(columns, images.count - start) {
                    var value = card(images[start + offset], width: columnWidth, declared: message.inThread ? 132 : 172,
                                     maximumHeight: message.inThread ? 130 : 180)
                    value.frame.origin = CGPoint(x: body.minX + CGFloat(offset) * (columnWidth + 8), y: y)
                    group.append(value)
                }
                y += (group.map { $0.frame.height }.max() ?? 0) + 8
                cards += group
            }
            y -= 8
        } else if let image = images.first {
            var value = card(image, width: width, declared: message.inThread ? 280 : 360, maximumHeight: message.inThread ? 180 : 240)
            value.frame.origin = CGPoint(x: body.minX, y: y); y = value.frame.maxY; cards.append(value)
        }
        for file in files where !file.isImage {
            if !cards.isEmpty { y += 8 }
            var value = card(file, width: width, declared: width, maximumHeight: 52)
            value.frame.origin = CGPoint(x: body.minX, y: y); y = value.frame.maxY; cards.append(value)
        }
        bottom = y
    }
}
