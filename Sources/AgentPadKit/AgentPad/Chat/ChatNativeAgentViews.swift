import AppKit
import CoreText
import SwiftUI

/// These operands are shared by the native draw path and parity observation.
/// Frames are local to the view exposing them; layout plans use cell coordinates.
@MainActor struct ChatNativeAgentTextOperand {
    let id: String
    let text: NSAttributedString
    let frame: CGRect
    let drawingFrame: CGRect
    var truncates = false
    init(id: String, text: NSAttributedString, frame: CGRect, drawingFrame: CGRect? = nil, truncates: Bool = false) {
        self.id = id; self.text = text; self.frame = frame; self.drawingFrame = drawingFrame ?? frame
        self.truncates = truncates
    }
    func draw() {
        var options: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        if truncates { options.insert(.truncatesLastVisibleLine) }
        text.draw(with: drawingFrame, options: options)
    }
}

@MainActor struct ChatNativeAgentImageOperand {
    let id: String
    let image: NSImage
    let frame: CGRect
    let drawingFrame: CGRect
    let color: NSColor
    var tintsMask = false
    func draw() {
        guard tintsMask, let context = NSGraphicsContext.current?.cgContext else {
            image.draw(in: drawingFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        // Match the native document symbol's existing source-in recipe. Tint
        // after rasterizing alpha so palette conversion cannot round its edges.
        context.saveGState(); context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: drawingFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.setBlendMode(.sourceIn); color.setFill(); context.fill(drawingFrame)
        context.endTransparencyLayer(); context.restoreGState()
    }
}

@MainActor struct ChatNativeAgentFillOperand {
    let id: String
    let frame: CGRect
    let color: NSColor
    let cornerRadius: CGFloat
    var strokeWidth: CGFloat = 0
    func draw(in context: CGContext) {
        if strokeWidth > 0 {
            color.setStroke()
            context.addPath(ChatNativeShapes.roundedRect(frame.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2),
                radius: cornerRadius - strokeWidth / 2))
            context.setLineWidth(strokeWidth); context.strokePath()
        } else {
            color.setFill(); context.addPath(ChatNativeShapes.roundedRect(frame, radius: cornerRadius)); context.fillPath()
        }
    }
}

@MainActor private enum ChatNativeAgentDrawing {
    static func text(_ value: String, style: NativeTimelineSnapshot.Style, size: CGFloat = 10,
                     weight: NSFont.Weight = .regular, color: String = "foreground", mono: Bool = false,
                     system: Bool = false, single: Bool = false, actualColor: NSColor? = nil,
                     pushOut: Bool = false) -> NSAttributedString {
        let font = system ? NSFont.systemFont(ofSize: size, weight: weight)
            : ChatNativeTextStyle.font(mono ? style.metrics.monoFont : style.metrics.displayFont, size: size, weight: weight)
        let text = NSMutableAttributedString(attributedString: ChatNativeTextStyle.label(value, font: font,
            color: actualColor ?? style.color(color)))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = single ? .byTruncatingTail : .byWordWrapping
        paragraph.tighteningFactorForTruncation = 0
        if pushOut { paragraph.lineBreakStrategy = .pushOut }
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        return text
    }
    static func size(_ value: NSAttributedString, width: CGFloat, scale: CGFloat, lines: Int? = nil) -> CGSize {
        let measured = ChatNativeTextStyle.size(value, width: lines == 1 ? .greatestFiniteMagnitude : max(1, width), scale: scale)
        var result = CGSize(width: min(max(1, width), measured.width), height: measured.height)
        if let lines, value.length > 0 {
            let single = ChatNativeTextStyle.size(value, scale: scale)
            result.height = min(result.height, single.height * CGFloat(lines))
            if lines > 1, measured.height > result.height {
                // Measure the same limited drawing, including its final
                // ellipsis, instead of the widths of hidden wrapped lines.
                let truncated = value.boundingRect(with: CGSize(width: max(1, width), height: result.height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                result.width = min(max(1, width), ceil(truncated.width * scale) / scale)
            }
            if lines == 1, measured.width > width {
                let line = CTLineCreateWithAttributedString(value)
                let token = NSAttributedString(string: "…", attributes: value.attributes(at: 0, effectiveRange: nil))
                if let truncated = CTLineCreateTruncatedLine(line, max(1, width), .end, CTLineCreateWithAttributedString(token)) {
                    result.width = ceil(CTLineGetTypographicBounds(truncated, nil, nil, nil) * scale) / scale
                }
            }
        }
        return result
    }
    static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
                .applying(.init(paletteColors: [color])))
    }
    static func symbolSize(_ image: NSImage?) -> CGSize {
        CGSize(width: image?.alignmentRect.width ?? 0, height: image?.size.height ?? 0)
    }
    static func image(_ id: String, name: String, size: CGFloat, color: NSColor, frame: CGRect) -> ChatNativeAgentImageOperand? {
        guard let image = symbol(name, size: size, color: color) else { return nil }
        return .init(id: id, image: image, frame: frame,
            drawingFrame: CGRect(x: frame.minX - image.alignmentRect.minX, y: frame.minY,
                                 width: image.size.width, height: image.size.height), color: color)
    }
}

struct ChatNativeMembershipLayout: Equatable, Sendable {
    struct Hint: Equatable, Sendable {
        let value: NativeTimelineSnapshot.MembershipHint
        let frame: CGRect
        let title: CGRect
        let titleText: CGRect
        let icon: CGRect
        let guidance: CGRect
        let add: CGRect
    }
    let hints: [Hint]
    let frame: CGRect
    let bottom: CGFloat

    @MainActor init(message: NativeTimelineSnapshot.Message, style: NativeTimelineSnapshot.Style, body: CGRect) {
        let content = message.content, source = content.message
        // A stale mutable message still enters the legacy text/hint branch.
        guard !source.deleted, content.editing == nil, source.hasMutable || source.localState != nil,
              !content.membershipHints.isEmpty else {
            hints = []; frame = .zero; bottom = body.maxY; return
        }
        let scale = style.metrics.scale
        func measure(_ text: String, width: CGFloat) -> CGSize {
            ChatNativeAgentDrawing.size(ChatNativeAgentDrawing.text(text, style: style, size: 11, color: "secondary", pushOut: true),
                width: width, scale: scale)
        }
        let iconSize = ChatNativeAgentDrawing.symbolSize(ChatNativeAgentDrawing.symbol(
            "person.crop.circle.badge.exclamationmark", size: 11, color: style.color("secondary")))
        var y = body.maxY
        var result: [Hint] = []
        for value in content.membershipHints {
            y += 2
            // Label uses an eight-point icon gap and preserves this symbol's
            // 14.5-point baseline-aligned slot at the inherited 11-point font.
            let top = y, titleSize = measure("@\(value.address) isn't in this channel.", width: max(1, body.width - iconSize.width - 8))
            let titleHeight = max(titleSize.height, 14.5)
            let title = CGRect(x: body.minX, y: y + 4, width: iconSize.width + 8 + titleSize.width, height: titleHeight)
            let titleText = CGRect(x: body.minX + iconSize.width + 8, y: title.minY,
                width: titleSize.width, height: titleSize.height)
            // Label aligns the symbol with its first text line when the title wraps.
            let icon = CGRect(x: body.minX, y: ((title.minY + (14.5 - iconSize.height) / 2) * scale).rounded() / scale,
                width: iconSize.width, height: iconSize.height)
            let guidanceSize = measure(value.guidance, width: body.width)
            let guidance = CGRect(origin: CGPoint(x: body.minX, y: title.maxY + 4), size: guidanceSize)
            var add = CGRect.zero
            y = guidance.maxY
            if value.canAdd {
                add = CGRect(origin: CGPoint(x: body.minX, y: y + 4), size: measure("Add to channel", width: body.width))
                y = add.maxY
            }
            y += 4
            result.append(.init(value: value, frame: CGRect(x: body.minX, y: top, width: body.width, height: y - top),
                title: title, titleText: titleText, icon: icon, guidance: guidance, add: add))
        }
        hints = result; bottom = y
        frame = CGRect(x: body.minX, y: body.maxY + 2, width: body.width, height: y - body.maxY - 2)
    }
}

@MainActor final class ChatNativeMembershipView: NSView {
    private var plan: ChatNativeMembershipLayout?
    private var texts: [ChatNativeAgentTextOperand] = []
    private var images: [ChatNativeAgentImageOperand] = []
    private var buttons: [String: ChatNativeTextButton] = [:]
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { let hit = super.hitTest(point); return hit === self ? nil : hit }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.group) }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ plan: ChatNativeMembershipLayout, messageID: String, style: NativeTimelineSnapshot.Style,
                   actions: ChatTimelineActions?) {
        self.plan = plan; frame = plan.frame; texts = []; images = []
        func local(_ rect: CGRect) -> CGRect { rect.isEmpty ? .zero : rect.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        let keep = Set(plan.hints.filter { !$0.add.isEmpty }.map { $0.value.agentID })
        for key in Array(buttons.keys) where !keep.contains(key) {
            buttons[key]?.invoke = nil; buttons.removeValue(forKey: key)?.removeFromSuperview()
        }
        for hint in plan.hints {
            let value = hint.value, prefix = "w07/membership/\(value.agentID)/"
            texts.append(.init(id: prefix + "title",
                text: ChatNativeAgentDrawing.text("@\(value.address) isn't in this channel.", style: style, size: 11, color: "secondary", pushOut: true),
                frame: local(hint.title), drawingFrame: local(hint.titleText)))
            texts.append(.init(id: prefix + "guidance", text: ChatNativeAgentDrawing.text(value.guidance, style: style, size: 11,
                color: "secondary", pushOut: true), frame: local(hint.guidance)))
            if let image = ChatNativeAgentDrawing.image(prefix + "icon", name: "person.crop.circle.badge.exclamationmark",
                size: 11, color: style.color("secondary"), frame: local(hint.icon)) { images.append(image) }
            if !hint.add.isEmpty {
                let button = buttons[value.agentID] ?? ChatNativeTextButton()
                if button.superview == nil { addSubview(button); buttons[value.agentID] = button }
                button.frame = local(hint.add)
                button.text = ChatNativeAgentDrawing.text("Add to channel", style: style, size: 11, color: "accent")
                button.setAccessibilityLabel("Add @\(value.address) to channel")
                button.invoke = { [weak actions] in actions?.addAgent(messageID: messageID, agentID: value.agentID) }
            }
        }
        setAccessibilityLabel(plan.hints.map { "@\($0.value.address) isn't in this channel. \($0.value.guidance)" }.joined(separator: " "))
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) { texts.forEach { $0.draw() }; images.forEach { $0.draw() } }
    func unbind() {
        buttons.values.forEach { $0.invoke = nil; $0.removeFromSuperview() }; buttons = [:]
        texts = []; images = []; plan = nil; setAccessibilityLabel(nil); needsDisplay = true
    }
    #if DEBUG
    var parityPlan: ChatNativeMembershipLayout? { plan }
    var parityTexts: [ChatNativeAgentTextOperand] {
        texts + buttons.map { id, button in .init(id: "w07/membership/\(id)/add", text: button.text,
            frame: button.frame, drawingFrame: convert(button.drawingRect, from: button)) }
    }
    var parityImages: [ChatNativeAgentImageOperand] { images }
    var parityFills: [ChatNativeAgentFillOperand] { [] }
    var parityControls: [String: NSButton] { Dictionary(uniqueKeysWithValues: buttons.map { ("w07/membership/\($0.key)/add", $0.value) }) }
    func drawParityText(id: String, in context: CGContext) { parityTexts.first { $0.id == id }?.draw() }
    func drawParityImage(id: String, in context: CGContext) { images.first { $0.id == id }?.draw() }
    #endif
}

struct ChatNativeSourceLayout: Equatable, Sendable {
    enum Action: String, Equatable, Sendable {
        case stop = "Stop agent", cancel = "Cancel request", answer = "Go to answer", details = "Request details"
        var symbol: String { switch self { case .stop: "stop.circle"; case .cancel: "xmark.circle"; case .answer: "arrow.turn.down.right"; case .details: "ellipsis" } }
    }
    struct Control: Equatable, Sendable { let action: Action; let frame: CGRect }
    struct Card: Equatable, Sendable {
        let value: NativeTimelineSnapshot.SourceStatus
        let tone: String
        let answered: Bool
        let frame: CGRect
        let icon: CGRect
        let iconDrawing: CGRect
        let agent: CGRect
        let bot: CGRect
        let botText: CGRect
        let status: CGRect
        let activity: CGRect
        let offline: CGRect
        let controls: [Control]
    }
    let cards: [Card]
    let frame: CGRect
    let expand: CGRect
    let expandText: String
    let problem: CGRect
    let problemText: String?
    let bottom: CGFloat

    @MainActor init(message: NativeTimelineSnapshot.Message, snapshot: NativeTimelineSnapshot, body: CGRect) {
        let content = message.content, style = snapshot.style, scale = style.metrics.scale
        guard !snapshot.state.isDM, !content.sources.isEmpty else {
            cards = []; frame = .zero; expand = .zero; expandText = ""; problem = .zero; problemText = nil; bottom = body.maxY; return
        }
        func measure(_ text: String, width: CGFloat, size: CGFloat = 10, weight: NSFont.Weight = .regular,
                     mono: Bool = false, lines: Int? = nil) -> CGSize {
            ChatNativeAgentDrawing.size(ChatNativeAgentDrawing.text(text, style: style, size: size, weight: weight,
                mono: mono, single: lines == 1, pushOut: lines == 2), width: width, scale: scale, lines: lines)
        }
        var result: [Card] = [], y = body.maxY + 3 + 6
        let visible = content.sourcesExpanded ? content.sources : Array(content.sources.prefix(3))
        for value in visible {
            let presentation = ChatSourcePresentation(value.value, me: snapshot.me, connected: value.connected)
            let tone = switch presentation.tone { case .running: "accent"; case .attention: "attention"; case .failure: "failure"; case .success: "success" }
            var commands: [Action] = []
            if presentation.action == .stop { commands.append(.stop) }
            else if presentation.action == .cancel { commands.append(.cancel) }
            if presentation.answered && value.canGoToAnswer { commands.append(.answer) }
            commands.append(.details)
            let controlsWidth = CGFloat(commands.count) * 28 + CGFloat(commands.count - 1) * 10
            let available = max(1, body.width - 24 - 27 - 10 - 20 - controlsWidth)
            // The title's HStack shares proposals among its least flexible
            // children first. The padded BOT label can wrap just like the
            // status; reserving their ideal widths would starve the name.
            let titleTexts = [
                ChatNativeAgentDrawing.text(value.value.agent, style: style, size: 11, weight: .medium, single: true),
                ChatNativeAgentDrawing.text("BOT", style: style, size: 9, mono: true),
                ChatNativeAgentDrawing.text("answered", style: style)
            ]
            let titleIndices = presentation.answered ? [0, 1, 2] : [0, 1]
            let ideals = titleTexts.map { ChatNativeTextStyle.size($0, scale: scale).width }
            let ordered = titleIndices.sorted { ideals[$0] == ideals[$1] ? $0 < $1 : ideals[$0] < ideals[$1] }
            var remaining = available - CGFloat(titleIndices.count - 1) * 7
            var titleSizes = Array(repeating: CGSize.zero, count: 3)
            for (offset, index) in ordered.enumerated() {
                let padding: CGFloat = index == 1 ? 8 : 0
                let proposal = max(1 / scale, remaining / CGFloat(ordered.count - offset) - padding)
                let textWidth = ceil(proposal * scale) / scale
                var size = ChatNativeAgentDrawing.size(titleTexts[index], width: textWidth, scale: scale,
                    lines: index == 0 ? 1 : nil)
                size.width = min(textWidth, size.width)
                size.width += padding
                if index == 1 { size.height += 2 }
                titleSizes[index] = size
                remaining -= size.width
            }
            let name = titleSizes[0], bot = titleSizes[1], answered = titleSizes[2]
            let titleHeight = max(name.height, bot.height, answered.height)
            let status = presentation.answered ? answered : measure(value.word, width: available, lines: 2)
            let activity = presentation.showsActivity ? value.activity.map { measure($0, width: available, size: 9, mono: true, lines: 1) } ?? .zero : .zero
            let offline = value.connected ? .zero : measure("Offline · status may have changed", width: available)
            var textHeight = titleHeight
            if !presentation.answered { textHeight += 4 + status.height }
            if activity.height > 0 { textHeight += 4 + activity.height }
            if offline.height > 0 { textHeight += 4 + offline.height }
            let symbolName = presentation.answered ? "checkmark.circle" : presentation.tone == .failure ? "exclamationmark.circle" : "sparkles"
            let symbol = ChatNativeAgentDrawing.symbol(symbolName,
                size: presentation.answered ? 14 : 22, color: style.color(tone))
            let symbolSize = ChatNativeAgentDrawing.symbolSize(symbol)
            let padding: CGFloat = presentation.answered ? 6 : 10
            let height = max(presentation.answered ? 32 : 64, max(symbolSize.height, textHeight, 28) + padding * 2)
            let cardFrame = CGRect(x: body.minX, y: y, width: body.width, height: height)
            let iconDrawing = CGRect(x: body.minX + 12 + (27 - symbolSize.width) / 2, y: y + (height - symbolSize.height) / 2,
                width: symbolSize.width, height: symbolSize.height)
            // SwiftUI preserves the sparkles symbol's half-point optical
            // layout height; NSImage's canvas rounds that height to 29 points.
            let alignmentHeight = symbolName == "sparkles" ? 28.5 : symbolSize.height
            let icon = CGRect(x: body.minX + 12,
                y: ((y + (height - alignmentHeight) / 2) * scale).rounded() / scale,
                width: 27, height: alignmentHeight)
            let textX = body.minX + 12 + 27 + 10, textY = y + (height - textHeight) / 2
            let agentFrame = CGRect(x: textX, y: textY + (titleHeight - name.height) / 2, width: name.width, height: name.height)
            let botFrame = CGRect(x: agentFrame.maxX + 7, y: textY + (titleHeight - bot.height) / 2, width: bot.width, height: bot.height)
            let statusFrame = presentation.answered
                ? CGRect(x: botFrame.maxX + 7, y: textY + (titleHeight - status.height) / 2, width: status.width, height: status.height)
                : CGRect(x: textX, y: textY + titleHeight + 4, width: status.width, height: status.height)
            var detailY = presentation.answered ? textY + titleHeight : statusFrame.maxY
            var activityFrame = CGRect.zero, offlineFrame = CGRect.zero
            if activity.height > 0 {
                activityFrame = CGRect(origin: CGPoint(x: textX, y: detailY + 4), size: activity); detailY = activityFrame.maxY
            }
            if offline.height > 0 { offlineFrame = CGRect(origin: CGPoint(x: textX, y: detailY + 4), size: offline) }
            let controls = commands.enumerated().map { index, command in
                Control(action: command, frame: CGRect(x: cardFrame.maxX - 12 - controlsWidth + CGFloat(index) * 38,
                    y: y + (height - 28) / 2, width: 28, height: 28))
            }
            result.append(.init(value: value, tone: tone, answered: presentation.answered, frame: cardFrame, icon: icon, iconDrawing: iconDrawing,
                agent: agentFrame, bot: botFrame, botText: botFrame.insetBy(dx: 4, dy: 1), status: statusFrame,
                activity: activityFrame, offline: offlineFrame, controls: controls))
            y = cardFrame.maxY + 6
        }
        y -= 6
        var expand = CGRect.zero
        let expandText = content.sources.count > 3 ? content.sourcesExpanded ? "Show less" : "\(content.sources.count - 3) more requests" : ""
        if !expandText.isEmpty {
            expand = CGRect(origin: CGPoint(x: body.minX, y: y + 6), size: measure(expandText, width: body.width)); y = expand.maxY
        }
        var problem = CGRect.zero
        if let value = content.sourceProblem {
            let text = ChatNativeAgentDrawing.text(value, style: style, pushOut: true)
            problem = CGRect(origin: CGPoint(x: body.minX, y: y + 6),
                size: ChatNativeAgentDrawing.size(text, width: body.width, scale: scale)); y = problem.maxY
        }
        y += 6
        cards = result; self.expand = expand; self.expandText = expandText; self.problem = problem
        problemText = content.sourceProblem; bottom = y
        frame = CGRect(x: body.minX, y: body.maxY + 3, width: body.width, height: y - body.maxY - 3)
    }
}

@MainActor private final class ChatNativeSourceIconButton: NSButton {
    var invoke: (() -> Void)?
    var operand: ChatNativeAgentImageOperand?
    var accent = NSColor.controlAccentColor
    var ringWidth: CGFloat = 2
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero); isBordered = false; title = ""; focusRingType = .none
        target = self; action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { if isEnabled { invoke?() } }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func draw(_ dirtyRect: NSRect) {
        operand?.draw()
        if window?.firstResponder === self, let context = NSGraphicsContext.current?.cgContext {
            accent.setStroke(); context.setLineWidth(ringWidth)
            context.addPath(ChatNativeShapes.roundedRect(bounds.insetBy(dx: ringWidth / 2, dy: ringWidth / 2), radius: 5 - ringWidth / 2))
            context.strokePath()
        }
    }
}

@MainActor private final class ChatNativeAgentAccessibilityGroup: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { let hit = super.hitTest(point); return hit === self ? nil : hit }
}

@MainActor final class ChatNativeSourceView: NSView {
    private var plan: ChatNativeSourceLayout?
    private var identity: NativeTimelineSnapshot.RowID?
    private var previous: [ChatSourceStatus] = []
    private var texts: [ChatNativeAgentTextOperand] = []
    private var images: [ChatNativeAgentImageOperand] = []
    private var fills: [ChatNativeAgentFillOperand] = []
    private var buttons: [String: ChatNativeSourceIconButton] = [:]
    private let expand = ChatNativeTextButton()
    private var cards: [String: ChatNativeAgentAccessibilityGroup] = [:]
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { let hit = super.hitTest(point); return hit === self ? nil : hit }
    override init(frame: NSRect) { super.init(frame: frame); addSubview(expand); setAccessibilityElement(false) }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ plan: ChatNativeSourceLayout, row: NativeTimelineSnapshot.Row, snapshot: NativeTimelineSnapshot,
                   actions: ChatTimelineActions?) {
        guard case .message(let message) = row.payload, let messageID = row.messageID else { unbind(); return }
        if identity != row.id { unbind() }
        identity = row.id; self.plan = plan; frame = plan.frame; texts = []; images = []; fills = []
        let style = snapshot.style
        func local(_ rect: CGRect) -> CGRect { rect.isEmpty ? .zero : rect.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        let controlIDs = Set(plan.cards.flatMap { card in card.controls.map { "w07/source/\(card.value.value.id)/\($0.action.rawValue)" } })
        for key in Array(buttons.keys) where !controlIDs.contains(key) {
            buttons[key]?.invoke = nil; buttons.removeValue(forKey: key)?.removeFromSuperview()
        }
        let cardIDs = Set(plan.cards.map { $0.value.value.id })
        for key in Array(cards.keys) where !cardIDs.contains(key) { cards.removeValue(forKey: key)?.removeFromSuperview() }
        for card in plan.cards {
            let value = card.value, id = value.value.id, prefix = "w07/source/\(id)/", tone = style.color(card.tone)
            let group = cards[id] ?? ChatNativeAgentAccessibilityGroup()
            if group.superview == nil { addSubview(group); cards[id] = group }
            group.frame = local(card.frame); group.setAccessibilityElement(true); group.setAccessibilityRole(.group)
            group.setAccessibilityLabel("\(value.value.agent), BOT, \(value.word)\(value.connected ? "" : ", Offline, status may have changed")")
            fills.append(.init(id: prefix + "card", frame: local(card.frame), color: tone.withAlphaComponent(0.04), cornerRadius: 8))
            fills.append(.init(id: prefix + "card-border", frame: local(card.frame), color: tone.withAlphaComponent(0.20), cornerRadius: 8, strokeWidth: 1))
            fills.append(.init(id: prefix + "bot-border", frame: local(card.bot), color: style.color("foreground").withAlphaComponent(0.19), cornerRadius: 4, strokeWidth: 1))
            let symbolName = card.answered ? "checkmark.circle" : card.tone == "failure" ? "exclamationmark.circle" : "sparkles"
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: card.answered ? 14 : 22, weight: .regular)) {
                let canvas = local(card.iconDrawing)
                images.append(.init(id: prefix + "icon", image: image, frame: local(card.icon),
                    drawingFrame: CGRect(x: canvas.minX - image.alignmentRect.minX, y: canvas.minY,
                        width: image.size.width, height: image.size.height), color: tone, tintsMask: true))
            }
            texts.append(.init(id: prefix + "agent", text: ChatNativeAgentDrawing.text(value.value.agent, style: style, size: 11,
                weight: .medium, single: true), frame: local(card.agent), truncates: true))
            texts.append(.init(id: prefix + "bot", text: ChatNativeAgentDrawing.text("BOT", style: style, size: 9,
                color: "secondary", mono: true), frame: local(card.bot), drawingFrame: local(card.botText)))
            texts.append(.init(id: prefix + "status", text: ChatNativeAgentDrawing.text(card.answered ? "answered" : value.word,
                style: style, color: card.tone, pushOut: !card.answered), frame: local(card.status), truncates: !card.answered))
            if !card.activity.isEmpty, let activity = value.activity {
                texts.append(.init(id: prefix + "activity", text: ChatNativeAgentDrawing.text(activity, style: style, size: 9,
                    color: "secondary", mono: true, single: true), frame: local(card.activity), truncates: true))
            }
            if !card.offline.isEmpty {
                texts.append(.init(id: prefix + "offline", text: ChatNativeAgentDrawing.text("Offline · status may have changed",
                    style: style, color: "secondary"), frame: local(card.offline)))
            }
            group.removeAllToolTips()
            if !card.activity.isEmpty, let activity = value.activity {
                group.addToolTip(card.activity.offsetBy(dx: -card.frame.minX, dy: -card.frame.minY),
                    owner: activity as NSString, userData: nil)
            }
            for control in card.controls {
                let controlID = prefix + control.action.rawValue
                let button = buttons[controlID] ?? ChatNativeSourceIconButton()
                if button.superview !== group { group.addSubview(button); buttons[controlID] = button }
                button.frame = control.frame.offsetBy(dx: -card.frame.minX, dy: -card.frame.minY); button.title = control.action.rawValue
                button.toolTip = control.action.rawValue; button.setAccessibilityLabel(control.action.rawValue)
                button.accent = style.color("accent"); button.ringWidth = style.increasedContrast ? 3 : 2
                if let image = NSImage(systemSymbolName: control.action.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .regular)) {
                    let size = ChatNativeAgentDrawing.symbolSize(image)
                    // SwiftUI places the centered alignment rectangle on the
                    // backing grid, including the arrow and three-dot glyphs.
                    let imageFrame = CGRect(x: (((28 - size.width) / 2) * style.metrics.scale).rounded() / style.metrics.scale,
                        y: (28 - size.height) / 2, width: size.width, height: size.height)
                    button.operand = .init(id: controlID, image: image, frame: imageFrame,
                        drawingFrame: CGRect(x: imageFrame.minX - image.alignmentRect.minX, y: imageFrame.minY,
                            width: image.size.width, height: image.size.height), color: style.color("secondary"), tintsMask: true)
                } else {
                    button.operand = nil
                }
                button.invoke = { [weak actions] in
                    let action: ChatTimelineActions.SourceAction = switch control.action {
                    case .stop: .stop; case .cancel: .cancel; case .answer: .answer; case .details: .details
                    }
                    actions?.performSource(action, messageID: messageID, requestID: id)
                }
                button.needsDisplay = true
            }
        }
        expand.frame = local(plan.expand); expand.isHidden = plan.expand.isEmpty
        expand.text = ChatNativeAgentDrawing.text(plan.expandText, style: style)
        expand.invoke = { [weak actions] in actions?.toggleSources(messageID: messageID) }
        if let problem = plan.problemText, !plan.problem.isEmpty {
            texts.append(.init(id: "w07/source/problem", text: ChatNativeAgentDrawing.text(problem, style: style, color: "failure", pushOut: true),
                frame: local(plan.problem)))
        }
        let next = message.content.sources.map(\.value)
        for status in next {
            if let old = previous.first(where: { $0.id == status.id }), let announcement = ChatAccessibility.agent(from: old, to: status) {
                ChatAccessibility.announce(announcement, in: self)
            }
        }
        previous = next; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if let context = NSGraphicsContext.current?.cgContext { fills.forEach { $0.draw(in: context) } }
        texts.forEach { $0.draw() }; images.forEach { $0.draw() }
    }
    func unbind() {
        buttons.values.forEach { $0.invoke = nil; $0.operand = nil; $0.removeFromSuperview() }; buttons = [:]
        cards.values.forEach { $0.removeFromSuperview() }; cards = [:]
        expand.invoke = nil; expand.text = NSAttributedString(); expand.isHidden = true
        plan = nil; identity = nil; previous = []; texts = []; images = []; fills = []; needsDisplay = true
    }
    #if DEBUG
    var parityPlan: ChatNativeSourceLayout? { plan }
    var parityTexts: [ChatNativeAgentTextOperand] {
        texts + (expand.isHidden ? [] : [.init(id: "w07/source/expand", text: expand.text, frame: expand.frame,
            drawingFrame: convert(expand.drawingRect, from: expand))])
    }
    var parityImages: [ChatNativeAgentImageOperand] {
        images + buttons.values.compactMap { button in button.operand.map { .init(id: $0.id, image: $0.image,
            frame: convert(button.bounds, from: button), drawingFrame: convert($0.drawingFrame, from: button), color: $0.color,
            tintsMask: $0.tintsMask) } }
    }
    var parityFills: [ChatNativeAgentFillOperand] { fills }
    var parityControls: [String: NSButton] {
        var result: [String: NSButton] = Dictionary(uniqueKeysWithValues: buttons.map { ($0.key, $0.value) })
        if !expand.isHidden { result["w07/source/expand"] = expand }; return result
    }
    func drawParityText(id: String, in context: CGContext) { parityTexts.first { $0.id == id }?.draw() }
    func drawParityImage(id: String, in context: CGContext) { parityImages.first { $0.id == id }?.draw() }
    #endif
}

struct ChatNativeRequestLayout: Equatable, Sendable {
    let frame: CGRect
    let title: CGRect
    let status: CGRect
    let openRequest: CGRect
    let openSession: CGRect
    let problem: CGRect
    let height: CGFloat

    @MainActor init(request: NativeTimelineSnapshot.Request, style: NativeTimelineSnapshot.Style, width: ChatTimelineWidth) {
        let available = width.content(inset: 36 + 16)
        func measure(_ text: String, size: CGFloat) -> CGSize {
            ChatNativeAgentDrawing.size(ChatNativeAgentDrawing.text(text, style: style, size: size, system: true, pushOut: true),
                width: available, scale: width.scale)
        }
        title = CGRect(origin: CGPoint(x: 26, y: 8), size: measure(request.title, size: 12))
        status = CGRect(origin: CGPoint(x: 26, y: title.maxY + 2), size: measure(request.stateWord, size: 10))
        var y = status.maxY
        func button(_ text: String) -> CGRect {
            // The enclosing themed button style supplies the system-13 label
            // and 12-point horizontal padding even under `.font(.caption)`.
            let value = CGRect(x: 26, y: y + 2, width: measure(text, size: 13).width + 24, height: 24)
            y = value.maxY; return value
        }
        openRequest = request.canOpenRequest ? button("Open Request…") : .zero
        openSession = request.canOpenSession ? button("Open Session") : .zero
        if request.canOpenSession, let value = request.problem {
            problem = CGRect(origin: CGPoint(x: 26, y: y + 2), size: measure(value, size: 10)); y = problem.maxY
        } else { problem = .zero }
        height = y + 8
        frame = CGRect(x: 18, y: 0, width: width.content(inset: 36), height: height)
    }
}

@MainActor final class ChatNativeRequestView: NSView {
    private var plan: ChatNativeRequestLayout?
    private var id: String?
    private var texts: [ChatNativeAgentTextOperand] = []
    private var fills: [ChatNativeAgentFillOperand] = []
    private let openRequest = ChatNativeActionButton("Open Request…"), openSession = ChatNativeActionButton("Open Session")
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { let hit = super.hitTest(point); return hit === self ? nil : hit }
    override init(frame: NSRect) {
        super.init(frame: frame); addSubview(openRequest); addSubview(openSession)
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ plan: ChatNativeRequestLayout, request: NativeTimelineSnapshot.Request,
                   style: NativeTimelineSnapshot.Style, actions: ChatTimelineActions?) {
        self.plan = plan; id = request.id; frame = plan.frame
        let prefix = "w07/request/\(request.id)/"
        func local(_ rect: CGRect) -> CGRect { rect.isEmpty ? .zero : rect.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        texts = [
            .init(id: prefix + "title", text: ChatNativeAgentDrawing.text(request.title, style: style, size: 12, system: true, pushOut: true), frame: local(plan.title)),
            .init(id: prefix + "status", text: ChatNativeAgentDrawing.text(request.stateWord, style: style, size: 10, system: true,
                actualColor: request.publication == "publish_failed" ? NSColor(Color.orange) : NSColor(Color.secondary), pushOut: true), frame: local(plan.status))
        ]
        if let problem = request.problem, !plan.problem.isEmpty {
            texts.append(.init(id: prefix + "problem", text: ChatNativeAgentDrawing.text(problem, style: style, size: 10,
                system: true, actualColor: NSColor(Color.red), pushOut: true), frame: local(plan.problem)))
        }
        fills = [.init(id: prefix + "card", frame: bounds,
            color: NSColor(Color.secondary.opacity(0.08)), cornerRadius: 6)]
        for button in [openRequest, openSession] {
            button.font = .systemFont(ofSize: 13); button.chromeForeground = style.color("foreground")
            button.accent = style.color("accent"); button.focusRingWidth = style.increasedContrast ? 3 : 2
        }
        openRequest.frame = local(plan.openRequest); openRequest.isHidden = plan.openRequest.isEmpty
        openSession.frame = local(plan.openSession); openSession.isHidden = plan.openSession.isEmpty
        openRequest.invoke = { [weak actions] in actions?.openRequest(requestID: request.id) }
        openSession.invoke = { [weak actions] in actions?.openRequestSession(requestID: request.id) }
        toolTip = request.help; setAccessibilityLabel(request.title + ", " + request.stateWord); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if let context = NSGraphicsContext.current?.cgContext { fills.forEach { $0.draw(in: context) } }
        texts.forEach { $0.draw() }
    }
    func unbind() {
        openRequest.invoke = nil; openSession.invoke = nil; openRequest.isHidden = true; openSession.isHidden = true
        texts = []; fills = []; plan = nil; id = nil; toolTip = nil; setAccessibilityLabel(nil); needsDisplay = true
    }
    #if DEBUG
    var parityPlan: ChatNativeRequestLayout? { plan }
    var parityTexts: [ChatNativeAgentTextOperand] {
        guard let id else { return [] }
        return texts + [openRequest, openSession].filter { !$0.isHidden }.map {
            .init(id: "w07/request/\(id)/\($0.title)", text: $0.drawingTitle, frame: $0.frame,
                drawingFrame: convert($0.titleDrawingRect, from: $0))
        }
    }
    var parityImages: [ChatNativeAgentImageOperand] { [] }
    var parityFills: [ChatNativeAgentFillOperand] { fills }
    var parityControls: [String: NSButton] {
        guard let id else { return [:] }
        return Dictionary(uniqueKeysWithValues: [openRequest, openSession].filter { !$0.isHidden }.map { ("w07/request/\(id)/\($0.title)", $0) })
    }
    func drawParityText(id: String, in context: CGContext) { parityTexts.first { $0.id == id }?.draw() }
    func drawParityImage(id: String, in context: CGContext) {}
    #endif
}
