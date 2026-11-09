import AppKit
import CoreText
import SwiftUI
@testable import AgentPadKit

/// Exact point geometry. There is deliberately no epsilon, pixel snapping,
/// integralization, candidate-derived reference value, or layout reconstruction.
struct ChatTimelineParityMetadata: Codable, Equatable {
    struct Color: Codable, Equatable {
        var red: CGFloat; var green: CGFloat; var blue: CGFloat; var alpha: CGFloat
    }
    struct Insets: Codable, Equatable {
        var top: CGFloat; var left: CGFloat; var bottom: CGFloat; var right: CGFloat
    }
    struct Line: Codable, Equatable {
        var location: Int; var length: Int
    }
    struct ColorRun: Codable, Equatable {
        var location: Int; var length: Int; var colors: [String: Color]
    }
    struct FontDescriptor: Codable, Equatable {
        var family: String
        var size: CGFloat
        var traits: [String: Double]
        var variations: [String: Double]

        init(_ font: NSFont) {
            let ct = font as CTFont
            family = CTFontCopyFamilyName(ct) as String
            size = CTFontGetSize(ct)
            traits = (CTFontCopyTraits(ct) as NSDictionary).reduce(into: [:]) { result, item in
                if let key = item.key as? String, let value = item.value as? NSNumber { result[key] = value.doubleValue }
            }
            variations = [:]
            let values = CTFontCopyVariation(ct) as? [NSNumber: NSNumber] ?? [:]
            for axis in CTFontCopyVariationAxes(ct) as? [[CFString: Any]] ?? [] {
                if let id = axis[kCTFontVariationAxisIdentifierKey] as? NSNumber,
                   let fallback = axis[kCTFontVariationAxisDefaultValueKey] as? NSNumber {
                    variations[id.stringValue] = (values[id] ?? fallback).doubleValue
                }
            }
        }
    }
    struct TextRun: Codable, Equatable {
        var location: Int
        var length: Int
        var font: FontDescriptor
        var colors: [String: Color]
        /// Observed glyph extents, in host points, used only to scope check 2.
        /// Element frames and insets remain the exact geometry contract. Ink
        /// extents may differ by the sub-pixel origin that check 2 measures.
        var rasterBounds: [CGRect]
        var inkMasks: [InkMask]? = nil

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.location == rhs.location && lhs.length == rhs.length
                && lhs.font == rhs.font && lhs.colors == rhs.colors
        }
    }
    struct InkMask: Codable, Equatable {
        struct Span: Codable, Equatable {
            var x: Int; var y: Int; var length: Int
        }
        var origin: CGPoint
        var scale: CGFloat
        var spans: [Span]
    }
    struct Element: Codable, Equatable {
        var id: String
        var role: String
        var frame: CGRect
        var text: String? = nil
        var lineBreaks: [Line]? = nil
        var colorTokens: [String: Color] = [:]
        /// Exact opaque 0xRRGGBB sRGB source tokens. Preserve the integer that
        /// both avatar renderers consume, rather than a lossy Color bridge.
        var srgbTokens: [String: UInt32] = [:]
        var colorRuns: [ColorRun]? = nil
        var textRuns: [TextRun]? = nil
        var opacity: Double = 1
        var insets: Insets? = nil
        var textContainerWidth: CGFloat? = nil
        var lineFragmentPadding: CGFloat? = nil
        var textContainerInset: CGSize? = nil
        var textContainerOrigin: CGPoint? = nil
    }
    var elements: [Element]
    /// A passing geometry comparison is insufficient while any drawing
    /// primitive lacks observable line-break metadata.
    var captureGaps: [String] = []

    /// Union IDs keeps a moved or missing element in both sides' scope. Using
    /// independent intersection filters could silently lose precisely that bug.
    static func scoped(_ legacy: Self, _ native: Self, to regions: [CGRect]) -> (legacy: Self, native: Self) {
        let ids = Set((legacy.elements + native.elements).filter { element in
            regions.contains { $0.intersects(element.frame) }
        }.map(\.id))
        return (.init(elements: legacy.elements.filter { ids.contains($0.id) }, captureGaps: legacy.captureGaps.filter { gap in ids.contains(where: { gap.hasPrefix($0 + ":") }) }),
                .init(elements: native.elements.filter { ids.contains($0.id) }, captureGaps: native.captureGaps.filter { gap in ids.contains(where: { gap.hasPrefix($0 + ":") }) }))
    }
}

@MainActor final class ChatTimelineParityLegacyCollector {
    func snapshot(in host: NSView, includingW05: Bool = false,
                  scopingMediaToMessageRows: Bool = false, omittingEmptyTimestamp: Bool = false,
                  omittingEmptyTextLabels: Bool = false) throws -> ChatTimelineParityMetadata {
        typealias Element = ChatTimelineParityMetadata.Element
        let probes = ChatTimelineReferenceCapture.descendants(host, ChatTimelineParityProbeView.self)
            .filter { !$0.isHiddenOrHasHiddenAncestor && (includingW05 || !$0.semanticID.hasPrefix("w05/")) }
        guard !probes.isEmpty else { throw ChatTimelineParityLayout.failure("No rendered legacy geometry probes") }
        let messageRows = probes.filter { $0.role == "row" && $0.semanticID.hasPrefix("message:") }
        var elements = try probes.filter { $0.role != "container"
            // An empty SwiftUI Text has no rendered label. The native
            // collector likewise omits labels whose attributed text is empty.
            && !(omittingEmptyTextLabels && $0.role == "text" && $0.text == ""
                && ($0.semanticID.hasSuffix("/header") || $0.semanticID.hasSuffix("/timestamp")))
            && !(omittingEmptyTimestamp && $0.semanticID.hasSuffix("/timestamp") && $0.text == "") }.map { probe in
            let frame = ChatTimelineParityLayout.frame(probe.bounds, from: probe, in: host)
            var id = probe.semanticID
            if scopingMediaToMessageRows && id.hasPrefix("w06/") {
                // Isolated W06 canvases share an avatar's identity. Full
                // timelines must also identify the actual owning message row.
                // Ownership comes only from rendered legacy row geometry.
                let owners = messageRows.filter {
                    ChatTimelineParityLayout.frame($0.bounds, from: $0, in: host).contains(frame)
                }
                guard owners.count == 1 else {
                    throw ChatTimelineParityLayout.failure("Ambiguous rendered media owner: " + id)
                }
                id = owners[0].semanticID + "/" + id
            }
            var element = try ChatTimelineParityLayout.probe(probe, in: host)
            element.id = id
            return element
        }
        for view in ChatTimelineReferenceCapture.descendants(host, NSTextView.self) where !view.isHiddenOrHasHiddenAncestor {
            guard let marker = view.identifier?.rawValue, marker.hasPrefix("chat-parity:") else { continue }
            elements.append(try ChatTimelineParityLayout.text(view, id: String(marker.dropFirst("chat-parity:".count)), in: host))
        }
        let containers = Dictionary(uniqueKeysWithValues: probes.filter { $0.role == "container" }.map { ($0.semanticID, $0) })
        if let content = containers["timeline/content"], let padded = containers["timeline/padded"] {
            let inner = ChatTimelineParityLayout.frame(content.bounds, from: content, in: host)
            let outer = ChatTimelineParityLayout.frame(padded.bounds, from: padded, in: host)
            elements.append(Element(id: "topInset", role: "inset", frame: CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: inner.minY - outer.minY)))
        } else {
            // Standalone reference rows contain a real clear spacer. Its size is
            // the observed gap from the wrapper origin to the rendered row.
            guard let first = elements.filter({ $0.role == "row" }).min(by: { $0.frame.minY < $1.frame.minY }) else {
                throw ChatTimelineParityLayout.failure("Legacy capture has neither timeline padding nor a standalone row")
            }
            elements.append(Element(id: "topInset", role: "inset", frame: CGRect(x: 0, y: 0, width: host.bounds.width, height: first.frame.minY)))
        }
        return try ChatTimelineParityLayout.finish(elements)
    }
}

@MainActor enum ChatTimelineParityLayout {
    typealias Metadata = ChatTimelineParityMetadata
    typealias Element = Metadata.Element

    static func probe(_ probe: ChatTimelineParityProbeView, in host: NSView) throws -> Element {
        var element = Element(id: probe.semanticID, role: probe.role,
            frame: frame(probe.bounds, from: probe, in: host), text: probe.text,
            lineBreaks: probe.role == "avatar" ? nil : probe.lineBreaks?.map { .init(location: $0.location, length: $0.length) },
            colorTokens: try probe.colors.mapValues { try color($0, in: host) },
            srgbTokens: probe.srgbTokens, opacity: probe.opacity)
        if let text = probe.text, let font = probe.font {
            element.textRuns = [.init(location: 0, length: (text as NSString).length,
                font: .init(font), colors: [NSAttributedString.Key.foregroundColor.rawValue: try color(probe.colors["foreground"] ?? .labelColor, in: host)],
                rasterBounds: probe.textBounds.map { frame($0, from: probe, in: host) },
                inkMasks: try probe.renderTextInk?().map {
                    [try inkMask($0, origin: element.frame.origin, scale: CGFloat($0.width) / element.frame.width)]
                })]
        }
        return element
    }

    static func legacy(content: AnyView, enabled: Bool = true) -> (content: AnyView, collector: ChatTimelineParityLegacyCollector) {
        (AnyView(content.chatParity("viewport", "viewport", colors: ["background": ChatAppearance.surface])
            .environment(\.chatParityEnabled, enabled)), ChatTimelineParityLegacyCollector())
    }

    static func scoped(current: Metadata, candidate: Metadata, regions: [CGRect]) -> (current: Metadata, candidate: Metadata) {
        let pair = Metadata.scoped(current, candidate, to: regions)
        return (pair.legacy, pair.native)
    }

    static func snapshot(coordinator: NativeChatTimelineCoordinator, in host: NSView,
                         observingLabelOperands: Bool = false) throws -> Metadata {
        guard coordinator.snapshot != nil, !coordinator.rows.isEmpty else { throw failure("Native snapshot missing") }
        var elements: [Element] = []
        guard let container = host as? NativeChatTimelineContainer else { throw failure("Native capture host must be its rendered container") }
        elements.append(Element(id: "viewport", role: "viewport", frame: frame(container.bounds, from: container, in: host),
            colorTokens: ["background": try color(container.paritySurfaceColor, in: host)]))
        if container.focusBorder.focused && !container.focusBorder.isHiddenOrHasHiddenAncestor {
            elements.append(Element(id: "viewport/focus", role: "focus", frame: frame(container.focusBorder.bounds, from: container.focusBorder, in: host),
                colorTokens: ["stroke": try color(container.focusBorder.color, in: host)]))
        }
        for (index, row) in coordinator.rows.enumerated() {
            let id = identifier(row.id.kind)
            let rowFrame = frame(coordinator.tableView.rect(ofRow: index), from: coordinator.tableView, in: host)
            // Insets have exact table geometry even while offscreen. Retain
            // that observation for structural validation; viewport scoping
            // below removes them from a mid-history bitmap comparison.
            if case .inset = row.payload {
                elements.append(Element(id: id, role: "inset", frame: rowFrame)); continue
            }
            // Observe only realized content; never materialize a hidden cell
            // merely to make the capture pass.
            guard rowFrame.intersects(CGRect(origin: .zero, size: host.bounds.size)) else { continue }
            guard let cell = coordinator.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell,
                  let plan = cell.plan, let content = cell.parityDrawContent else {
                throw failure("Visible native row has no displayed cell: " + id)
            }
            var rowColors: [String: Metadata.Color] = [:]
            if case .message = row.payload {
                rowColors["background"] = try color(cell.parityBackgroundColor, in: host)
            }
            elements.append(Element(id: id, role: "row", frame: frame(cell.bounds, from: cell, in: host), colorTokens: rowColors))
            if cell.paritySelected {
                elements.append(Element(id: id + "/selection", role: "selection",
                    frame: frame(CGRect(x: 0, y: 0, width: 2, height: cell.bounds.height), from: cell, in: host),
                    colorTokens: ["fill": try color(content.style.color("accent"), in: host)]))
            }
            for (suffix, label) in [("header", cell.header), ("timestamp", cell.timestamp), ("footnote", cell.footnote), ("body", cell.placeholder)] {
                guard label.superview === cell, !label.isHiddenOrHasHiddenAncestor, label.text.length > 0 else { continue }
                if observingLabelOperands {
                    // Match the legacy Font.resolve operand with the mounted
                    // label's original operand, and capture its real drawing.
                    // TextKit's temporary measurement storage resolves fallback
                    // fonts differently; its font is not the label's input.
                    var element = try ChatNativeMetadataParity.text(label.text, id: id + "/" + suffix,
                        frame: label.bounds, drawing: label.bounds, from: label, in: host) { _ in label.draw(label.bounds) }
                    element.opacity = label.alphaValue
                    elements.append(element)
                } else {
                    elements.append(try labelElement(label.text, id: id + "/" + suffix, role: "text", frame: frame(label.bounds, from: label, in: host), opacity: label.alphaValue, in: host))
                }
            }
            if cell.body.superview === cell, !cell.body.isHiddenOrHasHiddenAncestor {
                elements.append(try text(cell.body, id: id + "/body", in: host))
            }
            if cell.actionButton.superview === cell, !cell.actionButton.isHiddenOrHasHiddenAncestor, cell.actionButton.text.length > 0 {
                elements.append(try labelElement(cell.actionButton.text, id: id + "/action", role: "control",
                    frame: frame(cell.actionButton.bounds, from: cell.actionButton, in: host), opacity: cell.actionButton.alphaValue,
                    drawingFrame: frame(cell.actionButton.drawingRect, from: cell.actionButton, in: host), in: host))
            }
            for (number, rule) in plan.rules.enumerated() {
                let fill: NSColor = if case .unread = row.payload { content.style.color("attention").withAlphaComponent(0.45) } else { content.style.color("hairline") }
                elements.append(Element(id: id + "/rule:\(number)", role: "rule", frame: frame(rule, from: cell, in: host), colorTokens: ["fill": try color(fill, in: host)]))
            }
            if !plan.capsule.isEmpty {
                elements.append(Element(id: id + "/capsule", role: "capsule", frame: frame(plan.capsule, from: cell, in: host), colorTokens: ["stroke": try color(content.style.color("hairline"), in: host)]))
            }
            if !plan.badge.isEmpty {
                var badge = try labelElement(content.badge, id: id + "/badge", role: "badge", frame: frame(plan.badge, from: cell, in: host), in: host)
                badge.colorTokens["stroke"] = try color(content.style.color("foreground").withAlphaComponent(0.19), in: host)
                elements.append(badge)
            }
            if let avatar = content.avatar, !plan.avatar.isEmpty {
                let rgb = avatar.color(isLight: content.style.color("surface").relativeLuminance > 0.55)
                elements.append(Element(id: id + "/avatar", role: "avatar", frame: frame(plan.avatar, from: cell, in: host), text: avatar.letter,
                    colorTokens: ["foreground": try color(.white, in: host)], srgbTokens: ["fill": rgb],
                    textRuns: try avatarRuns(cell, in: host)))
            }
        }
        return try finish(elements)
    }

    static func finish(_ input: [Element]) throws -> Metadata {
        guard !input.isEmpty, input.contains(where: { $0.role == "row" }), input.contains(where: { $0.role == "inset" }) else {
            throw failure("Incomplete layout metadata: rows and insets are required")
        }
        return try validated(input)
    }

    /// A real external popup has its own viewport, not timeline rows/insets.
    /// Its geometry and every text observation retain the same strict checks.
    static func finishExternalViewport(_ input: [Element]) throws -> Metadata {
        guard input.filter({ $0.role == "viewport" }).count == 1 else {
            throw failure("External popup metadata requires exactly one observed viewport")
        }
        return try validated(input)
    }

    private static func validated(_ input: [Element]) throws -> Metadata {
        guard Set(input.map(\.id)).count == input.count else { throw failure("Duplicate semantic layout IDs") }
        let rows = Dictionary(uniqueKeysWithValues: input.filter { $0.role == "row" }.map { ($0.id, $0.frame) })
        var result = input
        for index in result.indices {
            let element = result[index]
            guard element.frame.minX.isFinite, element.frame.minY.isFinite, element.frame.width.isFinite, element.frame.height.isFinite,
                  element.frame.width > 0, element.frame.height > 0 else { throw failure("Missing or non-finite rendered frame: " + element.id) }
            if let separator = element.id.lastIndex(of: "/"), let row = rows[String(element.id[..<separator])] {
                result[index].insets = .init(top: element.frame.minY - row.minY, left: element.frame.minX - row.minX,
                    bottom: row.maxY - element.frame.maxY, right: row.maxX - element.frame.maxX)
            }
        }
        let ordered = result.sorted { $0.id < $1.id }
        return Metadata(elements: ordered, captureGaps: ordered.flatMap { element -> [String] in
            guard element.text != nil else { return [] }
            var gaps: [String] = []
            if element.role != "avatar" && element.lineBreaks == nil { gaps.append(element.id + ": actual drawn label line breaks are not exposed") }
            if element.textRuns?.isEmpty != false { gaps.append(element.id + ": resolved font runs are not exposed") }
            if element.opacity > 0 && element.textRuns?.contains(where: { $0.rasterBounds.isEmpty }) == true {
                gaps.append(element.id + ": rendered glyph bounds are not exposed")
            }
            if element.opacity > 0 && element.textRuns?.contains(where: { $0.inkMasks == nil }) == true {
                gaps.append(element.id + ": glyph coverage is not exposed")
            }
            return gaps
        })
    }

    static func frame(_ rect: CGRect, from view: NSView, in host: NSView) -> CGRect {
        let value = view.convert(rect, to: host)
        return CGRect(x: value.minX - host.bounds.minX,
            y: host.isFlipped ? value.minY - host.bounds.minY : host.bounds.maxY - value.maxY,
            width: value.width, height: value.height)
    }

    static func color(_ value: NSColor, in host: NSView) throws -> Metadata.Color {
        var resolved: NSColor?
        host.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = value.usingColorSpace(.sRGB) }
        guard let resolved else { throw failure("Unresolvable color token") }
        return .init(red: resolved.redComponent, green: resolved.greenComponent, blue: resolved.blueComponent, alpha: resolved.alphaComponent)
    }

    private static func labelElement(_ text: NSAttributedString, id: String, role: String, frame: CGRect,
                                     opacity: Double = 1, drawingFrame: CGRect? = nil, in host: NSView) throws -> Element {
        guard text.length > 0, let foreground = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor else {
            throw failure("Displayed label has no foreground: " + id)
        }
        let drawingFrame = drawingFrame ?? (role == "badge" ? frame.insetBy(dx: 4, dy: 1) : frame)
        return Element(id: id, role: role, frame: frame, text: text.string,
            lineBreaks: labelLines(text, width: role == "badge" ? frame.width - 8 : frame.width),
            colorTokens: ["foreground": try color(foreground, in: host)],
            textRuns: try labelRuns(text, drawingFrame: drawingFrame, in: host), opacity: opacity)
    }

    static func labelRuns(_ text: NSAttributedString, drawingFrame: CGRect, in host: NSView,
                          maximumNumberOfLines: Int = 0) throws -> [Metadata.TextRun] {
        let storage = NSTextStorage(attributedString: text), manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: drawingFrame.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maximumNumberOfLines
        if maximumNumberOfLines > 0 { container.lineBreakMode = .byTruncatingTail }
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return try textRuns(storage, manager: manager, container: container, in: host) {
            $0.offsetBy(dx: drawingFrame.minX, dy: drawingFrame.minY)
        }
    }

    private static func avatarRuns(_ cell: ChatNativeShellCell, in host: NSView) throws -> [Metadata.TextRun] {
        guard let text = cell.avatarText, text.length > 0,
              let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            throw failure("Avatar has no resolved drawing font")
        }
        let origin = frame(.zero, from: cell, in: host).origin
        let ink = try drawingInk(bounds: [frame(cell.avatarTextClip, from: cell, in: host)],
            scale: host.window?.backingScaleFactor ?? 1) { context in
                context.translateBy(x: origin.x, y: origin.y)
                cell.drawAvatarText(in: context)
            }
        var colors: [String: Metadata.Color] = [:]
        for (key, value) in colorInputs(text.attributes(at: 0, effectiveRange: nil)) {
            colors[key.rawValue] = try color(value, in: host)
        }
        return [.init(location: 0, length: text.length, font: .init(font), colors: colors,
            rasterBounds: [frame(cell.avatarTextTypographicFrame, from: cell, in: host)], inkMasks: [ink])]
    }

    private static func textRuns(_ storage: NSAttributedString, manager: NSLayoutManager, container: NSTextContainer,
                                 in host: NSView, clip: CGRect? = nil,
                                 convert: @escaping (CGRect) -> CGRect) throws -> [Metadata.TextRun] {
        var result: [Metadata.TextRun] = []
        var error: Error?
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            do {
                guard let font = attributes[.font] as? NSFont else { throw failure("Text run has no resolved font") }
                var colors: [String: Metadata.Color] = [:]
                for (key, value) in colorInputs(attributes) {
                    colors[key.rawValue] = try color(value, in: host)
                }
                var bounds: [CGRect] = []
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, line, _ in
                    let part = NSIntersectionRange(glyphs, line)
                    if part.length > 0 {
                        let observed = convert(manager.boundingRect(forGlyphRange: part, in: container))
                        let visible = clip.map { observed.intersection($0) } ?? observed
                        if !visible.isNull && !visible.isEmpty { bounds.append(visible) }
                    }
                }
                // A fully clipped semantic run still retains its actual
                // viewport as conservative sampling scope. Its empty ink mask
                // exempts no pixels; fonts, colors and full ranges stay exact.
                if bounds.isEmpty, let clip, !clip.isEmpty { bounds = [clip] }
                let descriptor = Metadata.FontDescriptor(font)
                let ink = try glyphInk(manager: manager, glyphs: glyphs, origin: convert(.zero).origin,
                    bounds: bounds, clip: clip, scale: host.window?.backingScaleFactor ?? 1)
                if let last = result.last, last.font == descriptor, last.colors == colors,
                   last.location + last.length == range.location {
                    result[result.count - 1].length += range.length
                    result[result.count - 1].rasterBounds += bounds
                    result[result.count - 1].inkMasks?.append(ink)
                } else {
                    result.append(.init(location: range.location, length: range.length, font: descriptor, colors: colors,
                        rasterBounds: bounds, inkMasks: [ink]))
                }
            } catch let caught { error = caught }
        }
        if let error { throw error }
        return result
    }

    private static let colorKeys: [NSAttributedString.Key] = [
        .foregroundColor, .backgroundColor, .underlineColor, .strikethroughColor
    ]

    private static func colorInputs(_ attributes: [NSAttributedString.Key: Any]) -> [(NSAttributedString.Key, NSColor)] {
        attributes.compactMap { key, value in
            guard colorKeys.contains(key) || ["link.", "temporary.", "selection."].contains(where: { key.rawValue.hasPrefix($0) }),
                  let value = value as? NSColor else { return nil }
            return (key, value)
        }
    }

    /// Observe every colour input, without guessing AppKit's compositing of
    /// semantic selection colours. In light mode it can preserve the storage
    /// foreground despite a selectedTextAttributes foreground. Keep both exact
    /// tokens, and split runs at each link, temporary and selection boundary.
    private static func displayAttributes(_ view: NSTextView, storage: NSTextStorage,
                                          manager: NSLayoutManager) -> NSAttributedString {
        let displayed = NSMutableAttributedString(attributedString: storage)
        let all = NSRange(location: 0, length: storage.length)
        func overlay(_ attributes: [NSAttributedString.Key: Any], layer: String, range: NSRange) {
            let colors = Dictionary(uniqueKeysWithValues: attributes.compactMap { key, value -> (NSAttributedString.Key, Any)? in
                guard colorKeys.contains(key) else { return nil }
                return (.init(layer + "." + key.rawValue), value)
            })
            if !colors.isEmpty { displayed.addAttributes(colors, range: range) }
        }
        storage.enumerateAttribute(.link, in: all) { link, range, _ in
            if link != nil { overlay(view.linkTextAttributes ?? [:], layer: "link", range: range) }
        }
        var location = 0
        while location < storage.length {
            var range = NSRange()
            let attributes = manager.temporaryAttributes(atCharacterIndex: location, effectiveRange: &range)
            range = NSIntersectionRange(range, all)
            overlay(attributes, layer: "temporary", range: range)
            location = max(location + 1, NSMaxRange(range))
        }
        for selection in view.selectedRanges {
            let range = NSIntersectionRange(selection.rangeValue, all)
            if range.length > 0 { overlay(view.selectedTextAttributes, layer: "selection", range: range) }
        }
        return displayed
    }

    private static func glyphInk(manager: NSLayoutManager, glyphs: NSRange, origin: CGPoint,
                                 bounds: [CGRect], clip: CGRect? = nil, scale: CGFloat) throws -> Metadata.InkMask {
        try drawingInk(bounds: bounds, scale: scale) { context in
            if let clip { context.clip(to: clip) }
            manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
    }

    static func drawingInk(bounds: [CGRect], scale: CGFloat,
                                   draw: (CGContext) -> Void) throws -> Metadata.InkMask {
        let union = bounds.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -1 / scale, dy: -1 / scale)
        guard !union.isNull, !union.isEmpty else { return .init(origin: .zero, scale: scale, spans: []) }
        let pixels = CGRect(x: union.minX * scale, y: union.minY * scale, width: union.width * scale, height: union.height * scale).integral
        guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
            bitsPerComponent: 8, bytesPerRow: Int(pixels.width) * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw failure("Cannot capture native glyph coverage")
        }
        context.translateBy(x: -pixels.minX, y: pixels.maxY)
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw failure("No native glyph coverage image") }
        return try inkMask(image, origin: CGPoint(x: pixels.minX / scale, y: pixels.minY / scale), scale: scale)
    }

    static func inkMask(_ image: CGImage, origin: CGPoint, scale: CGFloat) throws -> Metadata.InkMask {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw failure("Cannot decode glyph coverage")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var spans: [Metadata.InkMask.Span] = []
        for y in 0..<image.height {
            var x = 0
            while x < image.width {
                if bytes[(y * image.width + x) * 4 + 3] == 0 { x += 1; continue }
                let start = x
                repeat { x += 1 } while x < image.width && bytes[(y * image.width + x) * 4 + 3] > 0
                spans.append(.init(x: start, y: y, length: x - start))
            }
        }
        return .init(origin: origin, scale: scale, spans: spans)
    }

    /// NSAttributedString.draw(.usesLineFragmentOrigin) uses the attributed
    /// string's text layout contract. Only character segmentation is compared;
    /// glyph positions remain the bitmap gate's rasterization allowance.
    private static func labelLines(_ text: NSAttributedString, width: CGFloat) -> [Metadata.Line] {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var lines: [Metadata.Line] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
            let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines.append(.init(location: range.location, length: range.length))
        }
        return lines
    }

    static func text(_ view: NSTextView, id: String, in host: NSView) throws -> Element {
        guard let manager = view.layoutManager, let container = view.textContainer, let storage = view.textStorage else {
            throw failure("Displayed text lacks TextKit layout: " + id)
        }
        manager.ensureLayout(for: container)
        var lines: [Metadata.Line] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines.append(.init(location: characters.location, length: characters.length))
        }
        let displayed = displayAttributes(view, storage: storage, manager: manager)
        var runs: [Metadata.ColorRun] = []
        var colorError: Error?
        displayed.enumerateAttributes(in: NSRange(location: 0, length: displayed.length)) { attributes, range, _ in
            do {
                var colors: [String: Metadata.Color] = [:]
                for (key, value) in colorInputs(attributes) {
                    colors[key.rawValue] = try color(value, in: host)
                }
                // Attribute runs can split for font fallback; merge equal
                // adjacent colors so rasterizer font substitution is not a token.
                if let last = runs.last, last.colors == colors, last.location + last.length == range.location {
                    runs[runs.count - 1].length += range.length
                } else { runs.append(.init(location: range.location, length: range.length, colors: colors)) }
            } catch { colorError = error }
        }
        if let colorError { throw colorError }
        guard storage.length == 0 || !lines.isEmpty else { throw failure("No displayed line breaks: " + id) }
        // Composite inline editors draw through their actual inner clip view.
        // Preserve full-document semantics and standalone editor bitmap scope;
        // ordinary readonly timeline text keeps its existing observations.
        let clip: CGRect?
        if view !== host, view.isEditable, let scroll = view.enclosingScrollView,
           scroll.documentView === view {
            clip = frame(scroll.contentView.bounds, from: scroll.contentView, in: host)
        } else { clip = nil }
        return Element(id: id, role: "text", frame: frame(view.bounds, from: view, in: host), text: view.string,
            lineBreaks: lines, colorRuns: runs,
            textRuns: try textRuns(displayed, manager: manager, container: container, in: host, clip: clip) {
                frame($0.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view, in: host)
            }, opacity: view.alphaValue,
            textContainerWidth: container.containerSize.width, lineFragmentPadding: container.lineFragmentPadding,
            textContainerInset: view.textContainerInset, textContainerOrigin: view.textContainerOrigin)
    }

    private static func identifier(_ kind: NativeTimelineSnapshot.RowID.Kind) -> String {
        switch kind {
        case .message(let id): "message:" + id
        case .dayBoundary(let id): "day:" + id
        case .unreadBoundary(let id): "unread:" + id
        case .threadSummary(let id): "threadSummary:" + id
        case .legacyRequest(let id): "legacyRequest:" + id
        case .earlierUnread: "earlierUnread"
        case .olderControl: "olderControl"
        case .empty: "empty"
        case .topInset: "topInset"
        case .bottomInset: "bottomInset"
        }
    }

    static func failure(_ message: String) -> NSError { NSError(domain: "ChatTimelineParityLayout: " + message, code: 1) }
}
