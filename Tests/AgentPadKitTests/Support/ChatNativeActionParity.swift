import AppKit
import XCTest
@testable import AgentPadKit

/// W05-only observations. Reads displayed views/cells and their actual drawing
/// operands; never reconstructs a legacy layout from the native layout plan.
@MainActor enum ChatNativeActionParity {
    typealias Metadata = ChatTimelineParityMetadata
    typealias Element = Metadata.Element

    static func legacy(_ collector: ChatTimelineParityLegacyCollector, in host: NSView,
                       omittingEmptyTimestamp: Bool = false) throws -> Metadata {
        var value = try collector.snapshot(in: host, includingW05: true, omittingEmptyTimestamp: omittingEmptyTimestamp)
        if let editor = ChatTimelineReferenceCapture.descendants(host, NSTextView.self).first(where: { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }) {
            value.elements.append(try ChatTimelineParityLayout.text(editor, id: "w05/editor/text", in: host))
        }
        let probes = ChatTimelineReferenceCapture.descendants(host, ChatTimelineParityProbeView.self)
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        for probe in probes where probe.semanticID.hasPrefix("w05/") && probe.text != nil && probe.colors.isEmpty {
            value.captureGaps.append(probe.semanticID + ": styled title source color has not been observed")
            if let index = value.elements.firstIndex(where: { $0.id == probe.semanticID }), var runs = value.elements[index].textRuns {
                for run in runs.indices { runs[run].colors = [:] }
                value.elements[index].textRuns = runs
            }
        }
        value.elements.sort { $0.id < $1.id }
        return value
    }

    static func native(coordinator: NativeChatTimelineCoordinator, cell: ChatNativeShellCell, in host: NSView) throws -> Metadata {
        var base = try ChatTimelineParityLayout.snapshot(coordinator: coordinator, in: host)
        var elements = base.elements, gaps: [String] = []
        func frame(_ view: NSView) -> CGRect { ChatTimelineParityLayout.frame(view.bounds, from: view, in: host) }
        func control(_ view: NSView, _ id: String, colors: [String: NSColor] = [:]) throws {
            guard !view.isHiddenOrHasHiddenAncestor, !view.bounds.isEmpty else { return }
            elements.append(Element(id: id, role: "control", frame: frame(view),
                colorTokens: try colors.mapValues { try ChatTimelineParityLayout.color($0, in: host) }))
        }
        func text(_ attributed: NSAttributedString, view: NSView, id: String, drawing: CGRect? = nil,
                  ink: Metadata.InkMask? = nil, typographicBounds: CGRect? = nil) throws {
            guard !view.isHiddenOrHasHiddenAncestor, attributed.length > 0 else { return }
            let drawing = drawing.map { ChatTimelineParityLayout.frame($0, from: view, in: host) } ?? frame(view)
            let storage = NSTextStorage(attributedString: attributed), manager = NSLayoutManager()
            let container = NSTextContainer(containerSize: CGSize(width: drawing.width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
            var lines: [Metadata.Line] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
                let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                lines.append(.init(location: range.location, length: range.length))
            }
            var colors: [String: Metadata.Color] = [:]
            if let color = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
                colors["foreground"] = try ChatTimelineParityLayout.color(color, in: host)
            } else { gaps.append(id + ": native title foreground is not exposed in attributedTitle") }
            let hasFont = attributed.attribute(.font, at: 0, effectiveRange: nil) is NSFont
            if !hasFont { gaps.append(id + ": native title font is not exposed in attributedTitle") }
            var runs = hasFont ? try ChatTimelineParityLayout.labelRuns(attributed, drawingFrame: drawing, in: host) : nil
            if let ink, var observed = runs {
                for index in observed.indices {
                    observed[index].inkMasks = [ink]
                    if let typographicBounds {
                        observed[index].rasterBounds = [ChatTimelineParityLayout.frame(typographicBounds, from: view, in: host)]
                    }
                }
                runs = observed
            }
            elements.append(Element(id: id, role: "text", frame: frame(view), text: attributed.string,
                lineBreaks: lines, colorTokens: colors,
                textRuns: runs))
        }
        func label(_ label: ChatNativeLabel, _ id: String) throws { try text(label.text, view: label, id: id) }
        func button(_ button: ChatNativeActionButton, _ id: String) throws {
            guard !button.isHiddenOrHasHiddenAncestor, !button.bounds.isEmpty else { return }
            guard button.chromeForeground != nil else { throw ChatTimelineParityLayout.failure("Plain action button has no observed drawing foreground: " + id) }
            let titleRect = button.titleDrawingRect
            let ink = try buttonInk(button, in: host)
            let visibleTitle = NSMutableAttributedString(attributedString: button.drawingTitle)
            if let color = visibleTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
                visibleTitle.addAttribute(.foregroundColor,
                    value: color.withAlphaComponent(color.alphaComponent * button.alphaValue),
                    range: NSRange(location: 0, length: visibleTitle.length))
            }
            try text(visibleTitle, view: button, id: id, drawing: titleRect, ink: ink,
                typographicBounds: button.truncatedDrawingTitle == nil ? nil : button.titleTypographicRect)
        }
        let toolbar = cell.rowActions.toolbar
        if !toolbar.isHiddenOrHasHiddenAncestor, toolbar.superview != nil {
            let colors = toolbar.style.map { ["background": $0.color("surface"), "border": $0.color("foreground").withAlphaComponent(0.18)] } ?? [:]
            try control(toolbar, "w05/toolbar", colors: colors)
            for button in toolbar.buttons { try control(button, "w05/toolbar/" + button.title) }
        }
        let confirmation = cell.inlineControls.confirmation
        if confirmation.superview != nil, !confirmation.isHiddenOrHasHiddenAncestor {
            let colors = coordinator.snapshot.map { ["background": $0.style.color("chrome"), "border": $0.style.color("separator")] } ?? [:]
            try control(confirmation, "w05/confirmation", colors: colors)
            try label(confirmation.title, "w05/confirmation/title")
            try label(confirmation.consequences, "w05/confirmation/consequences")
            try label(confirmation.error, "w05/confirmation/error")
            try button(confirmation.cancel, "w05/confirmation/cancel")
            try button(confirmation.accept, "w05/confirmation/accept")
            try control(confirmation.spinner, "w05/confirmation/spinner")
        }
        if let session = coordinator.editorSession {
            let editor = session.host
            try control(editor, "w05/editor")
            try control(editor.scroll, "w05/editor/scroll", colors: editor.style.map {
                ["border": $0.color(editor.focused ? "accent" : "border")]
            } ?? [:])
            elements.append(Element(id: "w05/editor/formatting", role: "control",
                frame: ChatTimelineParityLayout.frame(editor.formattingBackgroundRect, from: editor, in: host),
                colorTokens: try (editor.style.map { ["background": $0.color("hover"), "separator": $0.color("separator")] } ?? [:])
                    .mapValues { try ChatTimelineParityLayout.color($0, in: host) }))
            elements.append(Element(id: "w05/editor/formatting-separator", role: "control",
                frame: ChatTimelineParityLayout.frame(editor.formattingSeparatorRect, from: editor, in: host)))
            elements.append(Element(id: "w05/editor/footer", role: "control",
                frame: ChatTimelineParityLayout.frame(editor.footerFrame, from: editor, in: host)))
            for button in editor.formatting { try control(button, "w05/editor/format/" + button.title) }
            try label(editor.loading, "w05/editor/loading")
            try label(editor.problem, "w05/editor/problem")
            try label(editor.readOnly, "w05/editor/archive")
            try button(editor.cancel, "w05/editor/Cancel")
            try button(editor.save, "w05/editor/Save")
            elements.append(try ChatTimelineParityLayout.text(session.editor, id: "w05/editor/text", in: host))
        }
        // These are the actual accessory children. Their displayed text, rather
        // than a candidate-derived legacy expectation, identifies the controls.
        for child in cell.inlineControls.subviews where child !== confirmation {
            if let label = child as? ChatNativeLabel {
                try text(label.text, view: label, id: "w05/recovery/problem")
            } else if let button = child as? ChatNativeTextButton {
                let id = button.text.string.hasPrefix("Reply to: ") ? "w05/reply-source" : "w05/recovery/" + button.text.string
                try text(button.text, view: button, id: id, drawing: button.drawingRect)
            }
        }
        let complete = try ChatTimelineParityLayout.finish(elements)
        base.elements = complete.elements
        base.captureGaps = Array(Set(base.captureGaps + complete.captureGaps + gaps)).sorted()
        return base
    }

    /// Observes the same spinner frames present in the full pair. No stopping,
    /// timing changes, replacement drawing or exclusion from the full gate.
    static func spinnerEvidence(legacyHost: NSView, native: NSProgressIndicator,
                                currentLayout: Metadata, candidateLayout: Metadata,
                                currentImage: NSBitmapImageRep, candidateImage: NSBitmapImageRep) throws -> [String: Any] {
        let currentFrame = try XCTUnwrap(currentLayout.elements.first { $0.id == "w05/confirmation/spinner" }).frame
        let candidateFrame = try XCTUnwrap(candidateLayout.elements.first { $0.id == "w05/confirmation/spinner" }).frame
        let matches = ChatTimelineReferenceCapture.descendants(legacyHost, NSProgressIndicator.self).filter {
            !$0.isHiddenOrHasHiddenAncestor && ChatTimelineParityLayout.frame($0.bounds, from: $0, in: legacyHost) == currentFrame
        }
        XCTAssertEqual(matches.count, 1, "The observed legacy spinner must have one public native control")
        let legacy = try XCTUnwrap(matches.first)
        func describe(_ view: NSProgressIndicator) -> [String: Any] {
            ["class": String(reflecting: type(of: view)), "style": String(describing: view.style),
             "controlSize": String(describing: view.controlSize), "indeterminate": view.isIndeterminate,
             "usesThreadedAnimation": view.usesThreadedAnimation, "displayedWhenStopped": view.isDisplayedWhenStopped,
             "layerAnimationKeys": view.layer?.animationKeys() ?? []]
        }
        func crop(_ image: NSBitmapImageRep, frame: CGRect, layout: Metadata) throws -> ChatTimelineParity.Raster {
            let raster = try ChatTimelineParity.Raster(image)
            let viewport = try XCTUnwrap(layout.elements.first { $0.id == "viewport" }).frame
            let scale = CGFloat(raster.width) / viewport.width
            let coordinates = [frame.minX * scale, frame.minY * scale, frame.width * scale, frame.height * scale]
            guard coordinates.allSatisfy({ $0.isFinite && $0.rounded(.down) == $0 }) else {
                throw ChatTimelineParityLayout.failure("Spinner frame is not aligned to the observed capture pixels")
            }
            let x = Int(coordinates[0]), y = Int(coordinates[1]), width = Int(coordinates[2]), height = Int(coordinates[3])
            guard x >= 0, y >= 0, width > 0, height > 0, x + width <= raster.width, y + height <= raster.height else {
                throw ChatTimelineParityLayout.failure("Spinner is outside the captured viewport")
            }
            var pixels: [UInt8] = []
            for row in y..<(y + height) {
                let start = (row * raster.width + x) * 4
                pixels.append(contentsOf: raster.rgba[start..<(start + width * 4)])
            }
            return .init(width: width, height: height, rgba: pixels)
        }
        let current = try crop(currentImage, frame: currentFrame, layout: currentLayout)
        let candidate = try crop(candidateImage, frame: candidateFrame, layout: candidateLayout)
        let result = ChatTimelineParity.bitmap(current, candidate)
        XCTAssertEqual(currentFrame, candidateFrame)
        XCTAssertEqual(legacy.style, native.style)
        XCTAssertEqual(legacy.controlSize, native.controlSize)
        XCTAssertEqual(legacy.isIndeterminate, native.isIndeterminate)
        XCTAssertTrue(result.passes, "Actual spinner frames must pass the unchanged non-text gate")
        func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        return ["legacy": describe(legacy), "native": describe(native), "legacyFrame": try json(currentFrame),
            "nativeFrame": try json(candidateFrame), "bitmap": try json(result),
            "exactDifferentPixels": ChatTimelineParity.exactDifference(current, candidate), "phaseAdjusted": false]
    }

    /// Replays the actual button's attributed drawing operands,
    /// to isolate glyph coverage. This is only a mask; the reference/candidate
    /// comparison still uses each real mounted view's cacheDisplay bitmap.
    private static func buttonInk(_ button: ChatNativeActionButton, in host: NSView) throws -> Metadata.InkMask {
        let scale = host.window?.backingScaleFactor ?? 1
        let size = button.bounds.size
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ChatTimelineParityLayout.failure("Cannot observe native button title ink")
        }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -button.bounds.minX, y: button.bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.drawTitle()
        }
        guard let image = context.makeImage() else { throw ChatTimelineParityLayout.failure("Missing native button title ink") }
        return try ChatTimelineParityLayout.inkMask(image,
            origin: ChatTimelineParityLayout.frame(button.bounds, from: button, in: host).origin, scale: scale)
    }
}
