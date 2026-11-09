import AppKit
import SwiftUI

struct ChatNativeAccessoryLayout: Equatable, Sendable {
    enum Command: Equatable, Sendable { case retry, discard, recover, copyFailed, discardEdit, replySource }
    struct Item: Equatable, Sendable {
        let text: String
        let color: String
        let size: CGFloat
        let command: Command?
        let enabled: Bool
        let frame: CGRect
        var pushOut = false
        var hyphenates = false
    }
    var items: [Item] = []
    var confirmation: CGRect = .zero
    var bottom: CGFloat = 0

    @MainActor static func font(size: CGFloat, command: Command?, style: NativeTimelineSnapshot.Style) -> NSFont {
        size == 9 || command == .replySource
            ? ChatNativeTextStyle.font(style.metrics.displayFont, size: size)
            : .systemFont(ofSize: size)
    }

    @MainActor init(message: NativeTimelineSnapshot.Message, state: NativeTimelineSnapshot.State,
                    style: NativeTimelineSnapshot.Style, body: CGRect, includeReplySource: Bool = true) {
        let content = message.content, source = content.message, scale = style.metrics.scale
        var y = body.maxY
        func item(_ text: String, color: String = "secondary", size: CGFloat = 10,
                  command: Command? = nil, enabled: Bool = true) {
            let font = Self.font(size: size, command: command, style: style)
            let attributed = ChatNativeTextStyle.label(text, font: font, color: style.color(color))
            let measured = ChatNativeTextStyle.size(attributed, width: body.width, scale: scale)
            y += 3
            items.append(.init(text: text, color: color, size: size, command: command, enabled: enabled,
                               frame: CGRect(x: body.minX, y: y, width: measured.width, height: measured.height)))
            y += measured.height
        }
        if let local = source.localEdit, local.state == "failed", content.editing == nil, !source.deleted {
            let text = local.error == "revision_conflict" ? "It was changed elsewhere: this is the current version."
                : (local.kind == "delete" ? "Not deleted: " : "Not changed: ") + ChatChannelModel.reason(local.error)
            var buttons: [(String, Command, Bool)] = []
            if local.kind == "edit" { buttons += [("Edit again", .recover, content.actions.recoverEdit), ("Copy", .copyFailed, true)] }
            buttons.append(("Discard", .discardEdit, true))
            let labels = ([text] + buttons.map(\.0)).enumerated().map { index, value in
                ChatNativeTextStyle.label(value, font: .systemFont(ofSize: 10), color: .labelColor,
                    pushOut: true, alignment: index == 0 ? .left : .center, hyphenates: index == 0)
            }
            let ideals = labels.map { ChatNativeTextStyle.size($0, scale: scale) }
            let ordered = labels.indices.sorted {
                ideals[$0].width == ideals[$1].width ? $0 < $1 : ideals[$0].width < ideals[$1].width
            }
            var remaining = max(1, body.width - CGFloat(buttons.count) * 8)
            var sizes = Array(repeating: CGSize.zero, count: labels.count)
            for (offset, index) in ordered.enumerated() {
                sizes[index] = ChatNativeTextStyle.size(labels[index],
                    width: max(1, remaining / CGFloat(ordered.count - offset)), scale: scale)
                remaining -= sizes[index].width
            }
            let textSize = sizes[0], height = sizes.map(\.height).max() ?? 0
            y += 3
            items.append(.init(text: text, color: "attention", size: 10, command: nil, enabled: true,
                               frame: CGRect(x: body.minX, y: y + (height - textSize.height) / 2, width: textSize.width, height: textSize.height), pushOut: true, hyphenates: true))
            var x = body.minX + textSize.width + 8
            for (index, button) in buttons.enumerated() {
                let size = sizes[index + 1]
                items.append(.init(text: button.0, color: "systemLink", size: 10, command: button.1, enabled: button.2,
                                   frame: CGRect(x: x, y: y + (height - size.height) / 2, width: size.width, height: size.height), pushOut: true))
                x += size.width + 8
            }
            y += height
        }
        if source.editedAt != nil, !source.deleted { item("edited", size: 9) }
        switch source.localState {
        case .sending:
            item(source.attachments.isEmpty ? "sending…" : content.attachments.pauseReason ?? "sending…", color: "systemSecondary")
            if state.isDM { item("Don't send", color: "systemLink", command: .discard) }
        case .failed:
            item("not sent: " + ChatChannelModel.reason(source.localError), color: "failure")
            if !state.archived && content.actions.retry { item("Retry", color: "systemLink", command: .retry) }
            item("Delete", color: "systemLink", command: .discard)
        case nil:
            if let local = source.localEdit, local.state == "saving" { item(local.kind == "delete" ? "deleting…" : "saving…", color: "systemSecondary") }
        }
        if let value = content.confirmation {
            y += 3
            let plan = ChatNativeConfirmationLayout(value, width: body.width, scale: scale)
            confirmation = CGRect(x: body.minX, y: y, width: body.width, height: plan.height)
            y += plan.height
        }
        bottom = y
        if includeReplySource { appendReplySource(message: message, style: style, body: body) }
    }

    @MainActor mutating func appendReplySource(message: NativeTimelineSnapshot.Message,
                                               style: NativeTimelineSnapshot.Style, body: CGRect) {
        guard let text = message.content.replyToText else { return }
        let title = "Reply to: " + text
        let font = Self.font(size: 10, command: .replySource, style: style)
        let attributed = ChatNativeTextStyle.label(title, font: font, color: style.color("systemLink"),
            pushOut: true, alignment: .center)
        // Use the same centered TextKit layout as the button, proposed the full
        // content column before fitting its control frame to the used text.
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: body.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size
        let scale = style.metrics.scale
        let size = CGSize(width: ceil(used.width * scale) / scale, height: ceil(used.height * scale) / scale)
        items.append(.init(text: title, color: "systemLink", size: 10, command: .replySource, enabled: true,
            frame: CGRect(x: body.minX, y: bottom + 3, width: size.width, height: size.height), pushOut: true))
        bottom += 3 + size.height
    }
}

struct ChatNativeConfirmationLayout {
    var title: CGRect, consequences: CGRect, error: CGRect, cancel: CGRect, accept: CGRect, spinner: CGRect
    let height: CGFloat
    @MainActor static func label(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: ChatNativeTextStyle.label(text, font: font, color: color))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakStrategy = .pushOut
        value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
        return value
    }
    @MainActor init(_ value: NativeTimelineSnapshot.Confirmation, width: CGFloat, scale: Double) {
        let available = max(1, width - 32)
        func size(_ text: String, font: NSFont) -> CGSize {
            ChatNativeTextStyle.size(Self.label(text, font: font, color: .labelColor), width: available, scale: scale)
        }
        let heading = size(value.title, font: .systemFont(ofSize: 13, weight: .bold))
        title = CGRect(origin: CGPoint(x: 16, y: 16), size: heading)
        let subtitle = size(value.consequences, font: .systemFont(ofSize: 13))
        consequences = CGRect(origin: CGPoint(x: 16, y: title.maxY + 10), size: subtitle)
        var y = consequences.maxY + 10
        error = .zero; accept = .zero; spinner = .zero
        if case .failed(let message) = value.phase {
            error = CGRect(origin: CGPoint(x: 16, y: y), size: size(message, font: .systemFont(ofSize: 13)))
            y = error.maxY + 10
            cancel = CGRect(x: 16, y: y, width: size("Keep editing", font: .systemFont(ofSize: 13)).width + 24, height: 24)
        } else {
            let cancelWidth = size(value.cancelTitle, font: .systemFont(ofSize: 13)).width + 24
            let acceptWidth = size(value.verb, font: .systemFont(ofSize: 13)).width + 24
            cancel = CGRect(x: 16, y: y, width: cancelWidth, height: 24)
            let wrap = cancelWidth + 8 + acceptWidth + (value.phase == .executing ? 24 : 0) > available
            accept = CGRect(x: wrap ? 16 : cancel.maxX + 8, y: wrap ? cancel.maxY + 8 : y, width: acceptWidth, height: 24)
            if value.phase == .executing { spinner = CGRect(x: wrap ? 16 : accept.maxX + 8, y: wrap ? accept.maxY + 8 : y + 4, width: 16, height: 16) }
        }
        height = max(cancel.maxY, accept.maxY, spinner.maxY) + 16
    }
}

@MainActor final class ChatNativeInlineConfirmation: NSView {
    let title = ChatNativeLabel(), consequences = ChatNativeLabel(), error = ChatNativeLabel()
    let cancel = ChatNativeActionButton("Cancel"), accept = ChatNativeActionButton("Delete")
    let spinner = NSProgressIndicator()
    private weak var coordinator: ConfirmationCoordinator?
    private var value: NativeTimelineSnapshot.Confirmation?
    private var style: NativeTimelineSnapshot.Style?
    private var mounted = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        for view in [title, consequences, error, cancel, accept, spinner] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityIdentifier("inline-confirmation")
        error.setAccessibilityIdentifier("inline-confirmation-error")
        cancel.setAccessibilityIdentifier("inline-confirmation-cancel"); accept.setAccessibilityIdentifier("inline-confirmation-accept")
        cancel.invoke = { [weak self] in self?.coordinator?.cancel() }
        accept.invoke = { [weak self] in self?.coordinator?.confirm() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ value: NativeTimelineSnapshot.Confirmation, style: NativeTimelineSnapshot.Style, coordinator: ConfirmationCoordinator?) {
        if self.value?.actionID != value.actionID { unbind() }
        self.coordinator = coordinator; self.value = value; self.style = style
        title.text = ChatNativeConfirmationLayout.label(value.title, font: .systemFont(ofSize: 13, weight: .bold), color: style.color("foreground"))
        consequences.text = ChatNativeConfirmationLayout.label(value.consequences, font: .systemFont(ofSize: 13), color: style.color("foreground"))
        if case .failed(let text) = value.phase {
            error.text = ChatNativeConfirmationLayout.label(text, font: .systemFont(ofSize: 13), color: NSColor(Color.red))
            cancel.title = "Keep editing"; cancel.setAccessibilityLabel("Keep editing")
        } else { error.text = NSAttributedString(); cancel.title = value.cancelTitle; cancel.setAccessibilityLabel(value.cancelTitle) }
        accept.title = value.verb; accept.setAccessibilityLabel(value.verb)
        cancel.chromeForeground = style.color("foreground")
        accept.chromeForeground = style.color("foreground")
        cancel.isEnabled = value.phase != .executing; accept.isEnabled = value.phase == .awaiting
        if value.phase == .executing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        mount(); needsLayout = true; needsDisplay = true
    }
    private func mount() {
        guard !mounted, let window, let coordinator else { return }
        mounted = true; coordinator.shown(true)
        if coordinator.isVisible, coordinator.isAwaiting { window.makeFirstResponder(cancel) }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { unbind() } else { mount() } }
    override func cancelOperation(_ sender: Any?) { coordinator?.cancel() }
    override func layout() {
        super.layout()
        guard let value else { return }
        let plan = ChatNativeConfirmationLayout(value, width: bounds.width, scale: style?.metrics.scale ?? 2)
        title.frame = plan.title; consequences.frame = plan.consequences; error.frame = plan.error
        cancel.frame = plan.cancel; accept.frame = plan.accept; spinner.frame = plan.spinner
        error.isHidden = plan.error.isEmpty; accept.isHidden = plan.accept.isEmpty; spinner.isHidden = plan.spinner.isEmpty
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let style, let context = NSGraphicsContext.current?.cgContext else { return }
        style.color("chrome").setFill(); context.addPath(ChatNativeShapes.roundedRect(bounds, radius: 10)); context.fillPath()
        style.color("separator").setStroke(); context.addPath(ChatNativeShapes.roundedRect(bounds, radius: 10))
        context.setLineWidth(1); context.strokePath()
    }
    func unbind() {
        if mounted { coordinator?.shown(false) }
        mounted = false; coordinator = nil; value = nil; spinner.stopAnimation(nil)
    }
}

@MainActor final class ChatNativeInlineControls: NSView {
    let confirmation = ChatNativeInlineConfirmation()
    private var controls: [NSView] = []
    private struct Key: Equatable {
        let message: String
        let text: String
        let command: ChatNativeAccessoryLayout.Command?
    }
    private var keys: [Key] = []
    // Marks and confirmation precede metadata; the reply-source link follows
    // it. They share a drawing container, but occupy distinct reading slots.
    var accessibilityBeforeMetadata: [NSView] {
        zip(controls, keys).compactMap { $1.command == .replySource ? nil : $0 }
            + (confirmation.superview === self ? [confirmation] : [])
    }
    var accessibilityAfterMetadata: [NSView] {
        zip(controls, keys).compactMap { $1.command == .replySource ? $0 : nil }
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { let hit = super.hitTest(point); return hit === self ? nil : hit }
    func configure(_ plan: ChatNativeAccessoryLayout, message: NativeTimelineSnapshot.Message,
                   style: NativeTimelineSnapshot.Style, actions: ChatTimelineActions?) {
        let nextKeys = plan.items.map { Key(message: message.content.message.id, text: $0.text, command: $0.command) }
        if nextKeys != keys {
            controls.forEach { ($0 as? ChatNativeTextButton)?.invoke = nil; $0.removeFromSuperview() }
            controls = plan.items.map { $0.command == nil ? ChatNativeLabel() : ChatNativeTextButton() }
            controls.forEach(addSubview)
            keys = nextKeys
        }
        for (item, view) in zip(plan.items, controls) {
            let color: NSColor = switch item.color {
            case "systemLink": style.color("foreground")
            case "systemSecondary":
                // Match the resolved SwiftUI secondary foreground used by the
                // legacy delivery label, including its sRGB drawing operands.
                // Passing the unresolved NSColor directly retains different
                // component precision from SwiftUI's Color resolution.
                Self.resolvedSecondary(style.color("foreground"))
            default: style.color(item.color)
            }
            // The legacy recovery link keeps its full foreground while another
            // message is being edited. Its disabled state prevents dispatch;
            // it does not apply the generic accessory dimming treatment.
            let drawingColor = !item.enabled && item.command == .recover
                ? Self.resolvedRecoveryForeground(color)
                : item.enabled ? color : color.withAlphaComponent(0.5)
            let text = ChatNativeTextStyle.label(item.text,
                font: ChatNativeAccessoryLayout.font(size: item.size, command: item.command, style: style),
                color: drawingColor, pushOut: item.pushOut,
                alignment: item.pushOut && item.command != nil ? .center : .left, hyphenates: item.hyphenates)
            if let command = item.command, let button = view as? ChatNativeTextButton {
                if item.pushOut {
                    button.alignment = .left
                }
                button.text = text; button.isEnabled = item.enabled
                let id = message.content.message.id
                button.invoke = { [weak actions] in
                    switch command {
                    case .retry: actions?.perform(.retry, messageID: id)
                    case .discard: actions?.perform(.discard, messageID: id)
                    case .recover: actions?.perform(.recoverEdit, messageID: id)
                    case .discardEdit: actions?.perform(.discardEdit, messageID: id)
                    case .replySource: actions?.perform(.replySource, messageID: id)
                    case .copyFailed:
                        guard let text = actions?.copyFailedEdit(messageID: id) else { return }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            } else { (view as? ChatNativeLabel)?.text = text }
            view.frame = item.frame
        }
        if let value = message.content.confirmation {
            if confirmation.superview == nil { addSubview(confirmation) }
            confirmation.frame = plan.confirmation
            confirmation.configure(value, style: style, coordinator: actions?.confirmation(messageID: message.content.message.id, actionID: value.actionID))
        } else { confirmation.unbind(); confirmation.removeFromSuperview() }
    }

    private static func resolvedRecoveryForeground(_ foreground: NSColor) -> NSColor {
        let resolved = Color(foreground).resolve(in: EnvironmentValues())
        // Preserve the resolved extended-sRGB drawing operand. Rebuilding it
        // as standard sRGB lets attributed-string interning substitute this
        // near-equal dark color for subsequent Copy/Discard foregrounds.
        if let color = NSColor(cgColor: resolved.cgColor) { return color }
        // The public CGColor initializer is failable; retain the previous exact
        // resolved components if a future platform cannot bridge this space.
        return NSColor(srgbRed: CGFloat(resolved.red), green: CGFloat(resolved.green),
                       blue: CGFloat(resolved.blue), alpha: CGFloat(resolved.opacity))
    }
    private static func resolvedSecondary(_ foreground: NSColor) -> NSColor {
        let resolved = Color(foreground).opacity(0.5).resolve(in: EnvironmentValues())
        return NSColor(srgbRed: CGFloat(resolved.red), green: CGFloat(resolved.green),
                       blue: CGFloat(resolved.blue), alpha: CGFloat(resolved.opacity))
    }
    func unbind() {
        confirmation.unbind(); confirmation.removeFromSuperview()
        controls.forEach { ($0 as? ChatNativeTextButton)?.invoke = nil; $0.removeFromSuperview() }
        controls.removeAll(); keys.removeAll()
    }
}
