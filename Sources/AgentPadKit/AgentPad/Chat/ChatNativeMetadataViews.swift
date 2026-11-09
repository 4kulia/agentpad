import AppKit
import Observation
import SwiftUI

/// The same attributed strings and rectangles feed drawing and parity capture.
@MainActor struct ChatNativeMetadataTextOperand {
    let id: String
    let text: NSAttributedString
    let frame: CGRect
    let drawingFrame: CGRect
    func draw() { text.draw(with: drawingFrame, options: [.usesLineFragmentOrigin]) }
}

@MainActor struct ChatNativeMetadataImageOperand {
    let id: String
    let image: NSImage
    let frame: CGRect
    let drawingFrame: CGRect
    let color: NSColor
    func draw() {
        image.draw(in: drawingFrame, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }
}

/// Cell-coordinate geometry. This value never reads a service or starts a task.
struct ChatNativeMetadataLayout: Equatable, Sendable {
    enum Font: Equatable, Sendable { case display(CGFloat), medium(CGFloat), system(CGFloat) }
    struct Text: Equatable, Sendable {
        let id: String
        let value: String
        let font: Font
        let color: String
        var frame: CGRect
        var drawingFrame: CGRect
        var pushOut = false
        @MainActor func attributed(style: NativeTimelineSnapshot.Style) -> NSAttributedString {
            let native: NSFont
            switch font {
            case .display(let size): native = ChatNativeTextStyle.font(style.metrics.displayFont, size: size)
            case .medium(let size): native = ChatNativeTextStyle.font(style.metrics.displayFont, size: size, weight: .medium)
            case .system(let size): native = .systemFont(ofSize: size)
            }
            return ChatNativeTextStyle.label(value, font: native, color: style.color(color), pushOut: pushOut)
        }
    }
    struct Symbol: Equatable, Sendable {
        let id: String
        let name: String
        let size: CGFloat
        let color: String
        let frame: CGRect
        @MainActor func image(style: NativeTimelineSnapshot.Style) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
                    .applying(.init(paletteColors: [style.color(color)])))
        }
    }
    struct Reaction: Equatable, Sendable {
        let emoji: String
        let count: Int?
        let mine: Bool
        let pending: Bool
        let error: String?
        let frame: CGRect
        let texts: [Text]
        let spinner: CGRect
        let warning: Symbol?
        var isServerReaction: Bool { count != nil }
        var id: String { "w07/metadata/" + (isServerReaction ? "reaction/" : "intent/") + emoji }
    }
    var frame: CGRect = .zero
    var bottom: CGFloat
    var texts: [Text] = []
    var symbols: [Symbol] = []
    var retry: CGRect = .zero
    var pinSpinner: CGRect = .zero
    var strip: CGRect = .zero
    var reactions: [Reaction] = []

    @MainActor init(message: NativeTimelineSnapshot.Message, style: NativeTimelineSnapshot.Style, body: CGRect) {
        bottom = body.maxY
        guard !message.content.message.deleted, let metadata = message.content.metadata else { return }
        let scale = style.metrics.scale
        var y = body.maxY
        func aligned(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        func text(_ id: String, _ value: String, font: Font, color: String = "foreground", width: CGFloat = .greatestFiniteMagnitude,
                  pushOut: Bool = false) -> Text {
            var item = Text(id: "w07/metadata/" + id, value: value, font: font, color: color, frame: .zero, drawingFrame: .zero)
            item.pushOut = pushOut
            let size = ChatNativeTextStyle.size(item.attributed(style: style), width: max(1, width), scale: scale)
            item.frame.size = size; item.drawingFrame.size = size
            return item
        }
        func add(_ item: Text, x: CGFloat, top: CGFloat) -> Text {
            var item = item
            item.frame.origin = CGPoint(x: x, y: top); item.drawingFrame.origin = item.frame.origin
            return item
        }
        func line(_ id: String, _ value: String, font: Font, color: String) {
            let item = text(id, value, font: font, color: color, width: body.width)
            y += 3; texts.append(add(item, x: body.minX, top: y)); y += item.frame.height
        }
        if metadata.value == nil, message.content.message.seq != nil,
           metadata.reactionsSupported || metadata.pinsSupported || metadata.summarySupported {
            if let error = metadata.loadError {
                let retryText = text("retry", "Retry", font: .display(9))
                let failure = text("loading", error, font: .display(9), width: body.width - retryText.frame.width - 8, pushOut: true)
                let height = max(failure.frame.height, retryText.frame.height)
                y += 3
                texts.append(add(failure, x: body.minX, top: y + (height - failure.frame.height) / 2))
                let action = add(retryText, x: body.minX + failure.frame.width + 8, top: y + (height - retryText.frame.height) / 2)
                texts.append(action); retry = action.frame
                y += height
            } else {
                line("loading", "Loading message details…", font: .display(9), color: "secondary")
            }
        }
        if metadata.pinsSupported, metadata.value?.pin != nil {
            let title = text("pin", "Pinned", font: .display(9), color: "secondary")
            let icon = Symbol(id: "w07/metadata/pin/icon", name: "pin.fill", size: 9, color: "secondary", frame: .zero)
            let image = icon.image(style: style)
            let size = CGSize(width: image?.alignmentRect.width ?? 0, height: image?.size.height ?? 0)
            // The existing 9-point Label resolves to a 12.5-point symbol
            // layout with an 8-point title gap. Its native symbol canvas
            // extends half a point above the resolved label frame.
            let height = max(ceil(12.5 * scale) / scale, title.frame.height)
            y += 3
            let iconFrame = CGRect(x: body.minX, y: y - 0.5, width: size.width, height: size.height)
            symbols.append(.init(id: icon.id, name: icon.name, size: icon.size, color: icon.color, frame: iconFrame))
            var label = add(title, x: iconFrame.maxX + 8, top: aligned(y + (height - title.frame.height) / 2))
            label.frame = CGRect(x: body.minX, y: y, width: label.drawingFrame.maxX - body.minX, height: height)
            texts.append(label); y += height
        }
        if metadata.pinsSupported, metadata.intents.contains(where: { $0.choice == "pin" && $0.error == nil }) {
            y += 3
            pinSpinner = CGRect(x: body.minX, y: y, width: 10, height: 10)
            y += pinSpinner.height
        }
        let values = metadata.value?.reactions ?? []
        if metadata.reactionsSupported, !values.isEmpty || !metadata.intents.isEmpty {
            let intents = metadata.intents.filter { $0.choice != "pin" }
            let width = min(body.width, CGFloat(max(1, values.count + intents.count)) * 86)
            let columns = max(1, Int((width + 5) / 75))
            let columnWidth = min(100, (width - CGFloat(columns - 1) * 5) / CGFloat(columns))
            struct Candidate {
                let emoji: String, count: Int?, mine: Bool, pending: Bool, error: String?
                let texts: [Text], width: CGFloat, height: CGFloat, spinner: CGRect, warning: Symbol?
            }
            var candidates: [Candidate] = []
            func candidate(emoji: String, count: Int?, mine: Bool, pending: Bool, error: String?) {
                let server = count != nil
                let prefix = (server ? "reaction/" : "intent/") + emoji + "/"
                let gap: CGFloat = server ? 5 : 4, padding: CGFloat = server ? 8 : 5
                var parts = [text(prefix + (server ? "emoji" : "choice"), emoji, font: server ? .system(12) : .display(11))]
                if let count { parts.append(text(prefix + "count", String(count), font: .display(11))) }
                if mine { parts.append(text(prefix + "you", "you", font: .medium(9))) }
                var warning: Symbol?
                var accessorySize = CGSize.zero
                if pending { accessorySize = CGSize(width: 10, height: 10) }
                else if !server, error != nil {
                    let symbol = Symbol(id: "w07/metadata/" + prefix + "warning", name: "exclamationmark.circle", size: 11, color: "foreground", frame: .zero)
                    if let image = symbol.image(style: style) { accessorySize = CGSize(width: image.alignmentRect.width, height: image.size.height) }
                    warning = symbol
                }
                let gaps = CGFloat(max(0, parts.count - 1) + (accessorySize == .zero ? 0 : 1)) * gap
                let idealWidth = parts.map { $0.frame.width }.reduce(0, +) + gaps + accessorySize.width + padding * 2
                let width = min(columnWidth, idealWidth)
                // The emoji/you runs have fixed intrinsic word widths. Count is
                // the flexible run in the existing HStack when a track narrows.
                if server, parts.count > 1, idealWidth > width {
                    let available = max(1, parts[1].frame.width - (idealWidth - width))
                    parts[1] = text(prefix + "count", String(count ?? 0), font: .display(11), width: available)
                }
                let contentHeight = max(parts.map { $0.frame.height }.max() ?? 0, accessorySize.height)
                let height = server ? max(25, contentHeight) : contentHeight + 10
                var x = padding
                parts = parts.map { item in
                    defer { x += item.frame.width + gap }
                    return add(item, x: x, top: (height - item.frame.height) / 2)
                }
                let accessory = CGRect(x: x, y: (height - accessorySize.height) / 2, width: accessorySize.width, height: accessorySize.height)
                if let symbol = warning {
                    warning = .init(id: symbol.id, name: symbol.name, size: symbol.size, color: symbol.color, frame: accessory)
                }
                candidates.append(.init(emoji: emoji, count: count, mine: mine, pending: pending, error: error,
                                        texts: parts, width: width, height: height, spinner: pending ? accessory : .zero, warning: warning))
            }
            for reaction in values {
                candidate(emoji: reaction.emoji, count: reaction.count, mine: reaction.mine,
                          pending: intents.contains { $0.choice == reaction.emoji && $0.error == nil }, error: nil)
            }
            for intent in intents where !values.contains(where: { $0.emoji == intent.choice }) {
                candidate(emoji: intent.choice, count: nil, mine: false, pending: intent.error == nil, error: intent.error)
            }
            y += 6 // The outer VStack gap and the strip's own top padding.
            let top = y
            for start in stride(from: 0, to: candidates.count, by: columns) {
                let row = candidates[start..<min(candidates.count, start + columns)]
                let height = row.map(\.height).max() ?? 0
                for (column, value) in row.enumerated() {
                    let rect = CGRect(x: aligned(body.minX + CGFloat(column) * (columnWidth + 5)),
                                      y: y + (height - value.height) / 2, width: value.width, height: value.height)
                    let rectOrigin = rect.origin
                    func translated(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: rectOrigin.x, dy: rectOrigin.y) }
                    let parts = value.texts.map { item in
                        var item = item; item.frame = translated(item.frame); item.drawingFrame = translated(item.drawingFrame); return item
                    }
                    let warning = value.warning.map { Symbol(id: $0.id, name: $0.name, size: $0.size, color: $0.color, frame: translated($0.frame)) }
                    reactions.append(.init(emoji: value.emoji, count: value.count, mine: value.mine, pending: value.pending, error: value.error,
                                           frame: rect, texts: parts, spinner: value.spinner.isEmpty ? .zero : translated(value.spinner), warning: warning))
                }
                y += height
                if start + columns < candidates.count { y += 5 }
            }
            strip = CGRect(x: body.minX, y: top, width: width, height: y - top)
        }
        if let problem = metadata.problem { line("problem", problem, font: .system(10), color: "failure") }
        for intent in metadata.intents where intent.error != nil {
            line("error/\(intent.choice)", intent.error ?? "", font: .system(10), color: "failure")
        }
        bottom = y
        let occupied = texts.map(\.frame) + symbols.map(\.frame) + reactions.map(\.frame)
            + [retry, pinSpinner, strip]
        let right = occupied.filter { !$0.isEmpty }.map(\.maxX).max() ?? body.minX
        frame = CGRect(x: body.minX, y: body.maxY, width: right - body.minX, height: y - body.maxY)
    }
}

@MainActor final class ChatNativeMetadataView: NSView {
    private var plan: ChatNativeMetadataLayout?
    private var style: NativeTimelineSnapshot.Style?
    private var labels: [ChatNativeLabel] = []
    private let retry = ChatNativeTextButton()
    private let pinSpinner = NSProgressIndicator()
    private var chips: [String: ChatNativeReactionItem] = [:]
    private var accounts: [String: Set<String>] = [:]
    private weak var actions: ChatTimelineActions?
    private var rowID: NativeTimelineSnapshot.RowID?
    private var epoch: UUID?
    private var visible = false
    private var texts: [ChatNativeMetadataTextOperand] = []
    private var images: [ChatNativeMetadataImageOperand] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        addSubview(retry); addSubview(pinSpinner)
        pinSpinner.style = .spinning; pinSpinner.controlSize = .mini; pinSpinner.isDisplayedWhenStopped = false
        pinSpinner.setAccessibilityLabel("Updating pin")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ plan: ChatNativeMetadataLayout, row: NativeTimelineSnapshot.Row, snapshot: NativeTimelineSnapshot,
                   actions: ChatTimelineActions?) {
        if rowID != row.id || epoch != snapshot.presentationEpoch { unbind() }
        self.plan = plan; style = snapshot.style; self.actions = actions; rowID = row.id; epoch = snapshot.presentationEpoch
        frame = plan.frame
        func local(_ rect: CGRect) -> CGRect { rect.isEmpty ? .zero : rect.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        texts = plan.texts.map { .init(id: $0.id, text: $0.attributed(style: snapshot.style), frame: local($0.frame), drawingFrame: local($0.drawingFrame)) }
        images = plan.symbols.compactMap { item in
            item.image(style: snapshot.style).map { .init(id: item.id, image: $0, frame: local(item.frame),
                drawingFrame: CGRect(origin: local(item.frame).origin, size: $0.size), color: snapshot.style.color(item.color)) }
        }
        while labels.count < texts.count { let label = ChatNativeLabel(frame: .zero); addSubview(label); labels.append(label) }
        for index in labels.indices {
            guard texts.indices.contains(index), texts[index].id != "w07/metadata/retry" else { labels[index].isHidden = true; continue }
            labels[index].text = texts[index].text; labels[index].frame = texts[index].drawingFrame; labels[index].isHidden = false
        }
        retry.frame = local(plan.retry); retry.isHidden = plan.retry.isEmpty
        retry.text = texts.first { $0.id == "w07/metadata/retry" }?.text ?? NSAttributedString()
        retry.invoke = { [weak self] in self?.actions?.retryMetadata() }
        pinSpinner.frame = local(plan.pinSpinner); pinSpinner.isHidden = plan.pinSpinner.isEmpty
        let wanted = Set(plan.reactions.map(\.emoji))
        for key in Array(chips.keys) where !wanted.contains(key) {
            chips.removeValue(forKey: key)?.unbindAndRemove(); accounts[key] = nil
        }
        for item in plan.reactions {
            let chip = chips[item.emoji] ?? ChatNativeReactionItem()
            if chips[item.emoji] == nil { chips[item.emoji] = chip; addSubview(chip) }
            chip.frame = local(item.frame)
            chip.accountsChanged = { [weak self] values in
                guard let self else { return }
                self.accounts[item.emoji] = values.isEmpty ? nil : values
                self.publishAccounts()
            }
            chip.configure(item, row: row, epoch: snapshot.presentationEpoch, style: snapshot.style, members: snapshot.members, actions: actions)
            chip.setVisible(visible)
        }
        publishAccounts(); updateSpinner(); needsDisplay = true
    }
    private func publishAccounts() {
        guard case .message(let id) = rowID?.kind else { return }
        actions?.setReactorAccounts(accounts.values.reduce(into: Set<String>()) { $0.formUnion($1) }, messageID: id)
    }
    func setVisible(_ value: Bool) {
        visible = value
        chips.values.forEach { $0.setVisible(value) }
        updateSpinner()
    }
    private func updateSpinner() {
        if visible, !pinSpinner.isHidden, window != nil { pinSpinner.startAnimation(nil) } else { pinSpinner.stopAnimation(nil) }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { setVisible(false) }; updateSpinner() }
    func unbind() {
        setVisible(false)
        chips.values.forEach { $0.unbindAndRemove() }; chips = [:]; accounts = [:]; publishAccounts()
        retry.invoke = nil; retry.text = NSAttributedString(); retry.isHidden = true
        pinSpinner.isHidden = true
        labels.forEach { $0.text = NSAttributedString(); $0.isHidden = true }
        plan = nil; style = nil; actions = nil; rowID = nil; epoch = nil; texts = []; images = []
    }
    override func draw(_ dirtyRect: NSRect) { images.forEach { $0.draw() } }

    #if DEBUG
    var parityPlan: ChatNativeMetadataLayout? { plan }
    var parityStyle: NativeTimelineSnapshot.Style? { style }
    var parityTexts: [ChatNativeMetadataTextOperand] {
        texts + orderedChips.flatMap { chip in chip.texts.map {
            .init(id: $0.id, text: $0.text, frame: convert($0.frame, from: chip), drawingFrame: convert($0.drawingFrame, from: chip))
        } }
    }
    var parityImages: [ChatNativeMetadataImageOperand] {
        images + orderedChips.flatMap { chip in chip.images.map {
            .init(id: $0.id, image: $0.image, frame: convert($0.frame, from: chip), drawingFrame: convert($0.drawingFrame, from: chip), color: $0.color)
        } }
    }
    private var orderedChips: [ChatNativeReactionItem] { plan?.reactions.compactMap { chips[$0.emoji] } ?? [] }
    var parityControls: [(id: String, view: NSView)] {
        var result: [(String, NSView)] = []
        if !retry.isHidden { result.append(("w07/metadata/retry", retry)) }
        if !pinSpinner.isHidden { result.append(("w07/metadata/pin/spinner", pinSpinner)) }
        for chip in orderedChips {
            if chip.plan?.isServerReaction == true { result.append((chip.plan!.id + "/chip", chip)) }
            if !chip.spinner.isHidden { result.append(((chip.plan?.id ?? "") + "/spinner", chip.spinner)) }
        }
        return result
    }
    var parityControlColors: [String: [String: NSColor]] {
        guard let style else { return [:] }
        return Dictionary(uniqueKeysWithValues: orderedChips.compactMap { chip in
            guard let item = chip.plan, item.isServerReaction else { return nil }
            return (item.id + "/chip", ["fill": item.mine ? style.color("accent").withAlphaComponent(0.11) : style.color("hover"),
                                       "stroke": item.mine ? style.color("accent").withAlphaComponent(0.45) : style.color("border")])
        })
    }
    var parityPopovers: [String: ChatNativeAttentionPopover] { chips.mapValues(\.popup) }
    func drawParityText(id: String, in context: CGContext) { parityTexts.first { $0.id == id }?.draw() }
    func drawParityImage(id: String, in context: CGContext) { parityImages.first { $0.id == id }?.draw() }
    #endif
}

@MainActor private final class ChatNativeReactionItem: NSButton {
    private(set) var plan: ChatNativeMetadataLayout.Reaction?
    private var style: NativeTimelineSnapshot.Style?
    private(set) var texts: [ChatNativeMetadataTextOperand] = []
    private(set) var images: [ChatNativeMetadataImageOperand] = []
    let spinner = NSProgressIndicator()
    let popup = ChatNativeAttentionPopover()
    var accountsChanged: ((Set<String>) -> Void)?
    private weak var actions: ChatTimelineActions?
    private var rowID: NativeTimelineSnapshot.RowID?
    private var epoch: UUID?
    private var contentRevision: UInt64 = 0
    private var members: [ChatOrgView.Member] = []
    private var visible = false
    private var hovering = false
    private var tooltipTask: Task<Void, Never>?
    private var serial: UInt64 = 0
    private var observationSerial: UInt64 = 0
    private var observationArmed = false
    private var observedContext: ObjectIdentifier?
    private var reuseSerial: UInt64 = 0
    private var popupSerial: UInt64 = 0
    private var hoverAccounts = Set<String>()
    private var hoverAccountIDs: [String] = []
    private var hoverHasMore = false
    private var popupAccounts = Set<String>()
    private var version: ChatB1Channel.Version?
    private var messageID: String? { if case .message(let id) = rowID?.kind { id } else { nil } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { plan?.isServerReaction == true }
    init() {
        super.init(frame: .zero)
        isBordered = false; title = ""; focusRingType = .none
        target = self; action = #selector(pressed)
        spinner.style = .spinning; spinner.controlSize = .mini; spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ value: ChatNativeMetadataLayout.Reaction, row: NativeTimelineSnapshot.Row, epoch: UUID,
                   style: NativeTimelineSnapshot.Style, members: [ChatOrgView.Member], actions: ChatTimelineActions?) {
        if rowID != row.id || self.epoch != epoch || plan?.emoji != value.emoji || plan?.isServerReaction != value.isServerReaction { clear() }
        let refresh = contentRevision != row.contentRevision || self.members != members
        self.plan = value; self.style = style; self.rowID = row.id; self.epoch = epoch
        contentRevision = row.contentRevision; self.members = members; self.actions = actions
        func local(_ rect: CGRect) -> CGRect { rect.isEmpty ? .zero : rect.offsetBy(dx: -value.frame.minX, dy: -value.frame.minY) }
        texts = value.texts.map { .init(id: $0.id, text: $0.attributed(style: style), frame: local($0.frame), drawingFrame: local($0.drawingFrame)) }
        images = value.warning.flatMap { symbol in symbol.image(style: style).map {
            [ChatNativeMetadataImageOperand(id: symbol.id, image: $0, frame: local(symbol.frame),
                drawingFrame: CGRect(origin: local(symbol.frame).origin, size: $0.size), color: style.color(symbol.color))]
        } } ?? []
        spinner.frame = local(value.spinner); spinner.isHidden = value.spinner.isEmpty
        setAccessibilityElement(true)
        setAccessibilityRole(value.isServerReaction ? .button : .staticText)
        if let count = value.count {
            setAccessibilityLabel("\(value.emoji), \(count)\(value.mine ? ", including you" : "")")
            setAccessibilityValue(value.mine ? "Selected" : "Not selected")
        } else { setAccessibilityLabel(value.emoji); setAccessibilityValue(nil) }
        if !hovering { toolTip = value.isServerReaction ? "Who reacted · right-click for the full list" : value.error }
        if let b1 = actions?.reactionContext(messageID: messageID ?? "") {
            if hovering {
                if version != b1.state.versions[messageID ?? ""] || (refresh && tooltipTask != nil) { loadTooltip() }
                else { updateTooltip() }
            }
        } else { clearTransient() }
        if popup.popover.isShown { updatePopup() }
        armObservation(); updateSpinner(); needsDisplay = true
    }
    @objc private func pressed() {
        guard plan?.isServerReaction == true, let id = messageID, let emoji = plan?.emoji else { return }
        actions?.perform(.toggleReaction(emoji), messageID: id)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard plan?.isServerReaction == true else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Who reacted", action: #selector(showReactors), keyEquivalent: "")
        item.target = self; menu.addItem(item)
        return menu
    }
    @objc private func showReactors() {
        guard visible else { return }
        if !popup.popover.isShown { popupSerial &+= 1 }
        guard let content = reactorsContent() else { return }
        popup.show(content, from: self)
    }
    private func reactorsContent() -> AnyView? {
        guard let id = messageID, let emoji = plan?.emoji, plan?.isServerReaction == true else { return nil }
        let expectedRow = rowID, expectedEpoch = epoch, expectedReuse = reuseSerial, expectedPopup = popupSerial
        return actions?.reactorsView(messageID: id, emoji: emoji, members: members, accountsChanged: { [weak self] values in
            guard let self, self.rowID == expectedRow, self.epoch == expectedEpoch,
                  self.reuseSerial == expectedReuse, self.popupSerial == expectedPopup, self.plan?.emoji == emoji else { return }
            self.popupAccounts = values; self.publishAccounts()
        })
    }
    private func updatePopup() {
        guard let content = reactorsContent() else { popup.close(returnFocus: false); return }
        popup.updateContent(content); popup.refresh()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if plan?.isServerReaction == true {
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }
    override func mouseEntered(with event: NSEvent) {
        guard visible, plan?.isServerReaction == true else { return }
        hovering = true; loadTooltip()
    }
    override func mouseExited(with event: NSEvent) { clearHover() }
    private func clearHover() {
        hovering = false; serial &+= 1; tooltipTask?.cancel(); tooltipTask = nil
        hoverAccounts = []; hoverAccountIDs = []; hoverHasMore = false
        toolTip = plan?.isServerReaction == true ? "Who reacted · right-click for the full list" : plan?.error
        publishAccounts()
    }
    private func publishAccounts() { accountsChanged?(hoverAccounts.union(popupAccounts)) }
    private func updateTooltip() {
        let names = hoverAccountIDs.map { id in members.first { $0.accountId == id }?.name ?? "Former member" }
            .joined(separator: ", ") + (hoverHasMore ? "…" : "")
        toolTip = names.isEmpty ? "Who reacted · right-click for the full list" : names
    }
    private func loadTooltip() {
        serial &+= 1; tooltipTask?.cancel(); tooltipTask = nil
        // Keep already loaded directory dependencies until the replacement
        // page arrives. Publishing an empty set here would itself invalidate
        // the row and restart this request before it can settle.
        toolTip = "Who reacted · right-click for the full list"
        guard visible, hovering, let id = messageID, let emoji = plan?.emoji,
              let b1 = actions?.reactionContext(messageID: id) else { return }
        let request = serial, revision = contentRevision, expectedRow = rowID, expectedEpoch = epoch
        let requestedVersion = b1.state.versions[id]
        version = requestedVersion
        tooltipTask = Task { @MainActor [weak self] in
            do {
                let page = try await b1.reactors(message: id, emoji: emoji, after: nil, at: nil)
                guard !Task.isCancelled, let self, self.serial == request, self.contentRevision == revision,
                      self.rowID == expectedRow, self.epoch == expectedEpoch, self.visible, self.hovering,
                      self.actions?.reactionContext(messageID: id) === b1, b1.state.versions[id] == requestedVersion else { return }
                self.tooltipTask = nil
                self.hoverAccounts = Set(page.accountIds)
                self.hoverAccountIDs = page.accountIds; self.hoverHasMore = page.next != nil
                self.updateTooltip()
                self.publishAccounts()
            } catch {
                guard let self, self.serial == request else { return }
                self.tooltipTask = nil
            }
        }
    }
    private func armObservation() {
        guard visible, plan?.isServerReaction == true, let id = messageID,
              let b1 = actions?.reactionContext(messageID: id) else { return }
        if observationArmed, observedContext == ObjectIdentifier(b1) { return }
        observationSerial &+= 1
        observationArmed = true; observedContext = ObjectIdentifier(b1)
        let expected = observationSerial
        withObservationTracking {
            _ = b1.state.accessible; _ = b1.state.versions[id]; _ = b1.supports("chat.reactions")
        } onChange: { [weak self, weak b1] in
            Task { @MainActor [weak self, weak b1] in
                guard let self, let b1, self.observationSerial == expected else { return }
                self.observationArmed = false; self.observedContext = nil
                guard self.actions?.reactionContext(messageID: id) === b1 else { self.clearTransient(); return }
                if self.hovering, self.version != b1.state.versions[id] { self.loadTooltip() }
                if self.popup.popover.isShown { self.popup.refresh() }
                self.armObservation()
            }
        }
    }
    func setVisible(_ value: Bool) {
        if visible != value {
            visible = value
            if !value { clearTransient() } else { armObservation() }
        }
        updateSpinner()
    }
    private func updateSpinner() {
        if visible, !spinner.isHidden, window != nil { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    private func clearTransient() {
        observationSerial &+= 1; observationArmed = false; observedContext = nil
        popupSerial &+= 1
        clearHover(); popup.close(returnFocus: false); popupAccounts = []; publishAccounts()
    }
    private func clear() {
        reuseSerial &+= 1
        clearTransient(); spinner.stopAnimation(nil); plan = nil; style = nil; actions = nil
        rowID = nil; epoch = nil; texts = []; images = []; version = nil
        setAccessibilityLabel(nil); setAccessibilityValue(nil); toolTip = nil
    }
    func unbindAndRemove() { clear(); accountsChanged = nil; removeFromSuperview() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { setVisible(false) }; updateSpinner() }
    override func layout() { super.layout(); popup.refresh() }
    override func draw(_ dirtyRect: NSRect) {
        guard let plan, let style else { return }
        if plan.isServerReaction, let context = NSGraphicsContext.current?.cgContext {
            (plan.mine ? style.color("accent").withAlphaComponent(0.11) : style.color("hover")).setFill()
            context.addPath(ChatNativeShapes.roundedRect(bounds, radius: 6)); context.fillPath()
            (plan.mine ? style.color("accent").withAlphaComponent(0.45) : style.color("border")).setStroke()
            context.addPath(ChatNativeShapes.roundedRect(bounds.insetBy(dx: 0.5, dy: 0.5), radius: 5.5))
            context.setLineWidth(1); context.strokePath()
        }
        texts.forEach { $0.draw() }; images.forEach { $0.draw() }
    }
}

/// Existing reactor content remains in its external popup. The callback only
/// identifies loaded directory dependencies; it owns no additional fetch.
struct ChatNativeReactorsContent: View {
    let b1: ChatB1Channel
    let message: String
    let emoji: String
    let members: [ChatOrgView.Member]
    let accountsChanged: ((Set<String>) -> Void)?
    @State private var list: ChatReactionAccounts
    init(b1: ChatB1Channel, message: String, emoji: String, members: [ChatOrgView.Member],
         onAccountsChanged: ((Set<String>) -> Void)? = nil) {
        self.b1 = b1; self.message = message; self.emoji = emoji; self.members = members; self.accountsChanged = onAccountsChanged
        _list = State(initialValue: ChatReactionAccounts(b1: b1, message: message, emoji: emoji))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(emoji) · Who reacted").font(Theme.display(13, weight: .semibold))
                .chatMetadataParity("reactors/title", "text", text: "\(emoji) · Who reacted",
                    colors: ["foreground": Theme.chromeForeground], font: Theme.display(13, weight: .semibold))
            if !b1.state.accessible { Text("Channel unavailable")
                    .chatMetadataParity("reactors/unavailable", "text", text: "Channel unavailable", colors: ["foreground": Theme.chromeForeground], font: Theme.display(12)) }
            else {
                ForEach(list.accounts, id: \.self) { id in
                    Text(members.first { $0.accountId == id }?.name ?? "Former member")
                        .chatMetadataParity("reactors/account/" + id, "text", text: members.first { $0.accountId == id }?.name ?? "Former member",
                            colors: ["foreground": Theme.chromeForeground], font: Theme.display(12))
                }
                if list.loading { ProgressView().controlSize(.small).chatMetadataParity("reactors/spinner", "control") }
                else if let error = list.error {
                    Text(error).foregroundStyle(ChatAppearance.failure)
                        .chatMetadataParity("reactors/error", "text", text: error, colors: ["foreground": ChatAppearance.failure], font: Theme.display(12))
                    Button("Retry") { Task { await list.load(restart: true) } }
                        .chatMetadataParity("reactors/retry", "text", text: "Retry", colors: ["foreground": Theme.chromeForeground], font: .system(size: 13))
                }
                else if list.next != nil { Button("Show more") { Task { await list.load(restart: false) } }
                        .chatMetadataParity("reactors/more", "text", text: "Show more", colors: ["foreground": Theme.chromeForeground], font: .system(size: 13)) }
                else if list.accounts.isEmpty { Text("No reactions yet").foregroundStyle(ChatAppearance.secondary)
                        .chatMetadataParity("reactors/empty", "text", text: "No reactions yet", colors: ["foreground": ChatAppearance.secondary], font: Theme.display(12)) }
            }
        }.font(Theme.display(12)).padding(16).frame(minWidth: 220)
            .background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
            .task(id: b1.state.versions[message]) { await list.load(restart: true) }
            .onChange(of: list.accounts) { _, accounts in accountsChanged?(Set(accounts)) }
            .onDisappear { list.clear(); accountsChanged?([]) }
            .onChange(of: b1.state.accessible) { _, access in if !access { list.clear(); accountsChanged?([]) } }
    }
}
