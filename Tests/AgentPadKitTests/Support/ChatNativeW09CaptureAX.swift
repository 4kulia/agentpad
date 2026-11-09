import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

/// AX supplies control identity, geometry and enabled state. Typography comes
/// independently from the mounted Text.Layout probe or native drawing operands;
/// AX font dictionaries are never promoted into exact font descriptors.
@MainActor enum ChatNativeW09CaptureAX {
    struct Observation: Codable, Equatable {
        let id: String
        let title: String
        let frame: CGRect
        let enabled: Bool?
        var drawing: ChatTimelineParityMetadata.Element? = nil
        private enum CodingKeys: String, CodingKey { case id, title, frame, enabled }
        var element: ChatTimelineParityMetadata.Element { drawing ?? .init(id: id, role: "text", frame: frame, text: title) }
    }

    static func appending(_ elements: [ChatTimelineParityMetadata.Element], to base: ChatTimelineParityMetadata,
                          externalViewport: Bool = false) throws -> ChatTimelineParityMetadata {
        let replaced = Set(elements.map(\.id))
        let observed = base.elements.filter { !replaced.contains($0.id) } + elements
        var result = try externalViewport ? ChatTimelineParityLayout.finishExternalViewport(observed)
            : ChatTimelineParityLayout.finish(observed)
        let retained = base.captureGaps.filter { gap in !replaced.contains { gap.hasPrefix($0 + ":") } }
        let missingColors = elements.filter { $0.text != nil && $0.textRuns?.contains(where: { $0.colors.isEmpty }) == true }
            .map { $0.id + ": styled title source color has not been observed" }
        result.captureGaps = Array(Set(retained + result.captureGaps + missingColors)).sorted()
        return result
    }

    static func observe(_ title: String, id: String, host: ChatQuietHost, button: Bool = false) throws -> Observation {
        let press = NSSelectorFromString("accessibilityPerformPress")
        let probes = ChatTimelineReferenceCapture.descendants(host.view, ChatTimelineParityProbeView.self)
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.semanticID == id && $0.text == title }
        guard probes.count <= 1 else { throw ChatTimelineParityLayout.failure("Ambiguous mounted typography probe: " + id) }
        let probeFrame = probes.first.map { ChatTimelineParityLayout.frame($0.bounds, from: $0, in: host.view) }
        let candidates = try host.nodes.filter { node in
            // The raw inventory also walks NSView descendants. A marker can
            // inherit its owner's AX label and NSView's default press method;
            // it is an operand observer, never a production control or text node.
            guard !(node is ChatTimelineParityProbeView),
                  node.responds(to: NSSelectorFromString("accessibilityFrame")) else { return false }
            if let view = node as? NSView,
               view.isHiddenOrHasHiddenAncestor || view.visibleRect.isEmpty { return false }
            if button {
                guard node.responds(to: press),
                      let role = ChatTimelineReferenceCapture.accessibilityAttribute(node, "accessibilityRole") as? String,
                      [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.link.rawValue,
                       NSAccessibility.Role.menuButton.rawValue].contains(role) else { return false }
            }
            if ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains(where: {
                ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String == title
            }) { return true }
            // Accessibility labels may intentionally describe an action instead
            // of repeating its visible title. The mounted attributed string and
            // rendered frame still have to identify this exact text uniquely.
            guard let probeFrame, try frame(node, in: host).contains(probeFrame) else { return false }
            return attributed(node, text: title)?.string == title
        }
        var matching = try candidates.filter { node in
            // A uniquely labeled production control identifies itself. AppKit
            // can snap the observing NSView to a different fractional origin
            // without changing this control's AX frame or rendered pixels.
            // Preserve that actual frame; containment is only a fallback for
            // controls whose action label differs from their visible title.
            if ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains(where: {
                ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String == title
            }) { return true }
            guard let probeFrame else { return true }
            let frame = try frame(node, in: host)
            return frame == probeFrame || frame.contains(probeFrame)
        }
        if matching.count > 1, let probeFrame {
            // Repeated visible titles (dual composers or several saved drafts)
            // are identified by their unique mounted semantic probe. Keep the
            // actual AX frame and require a unique geometric match.
            let exact = try matching.filter { try frame($0, in: host) == probeFrame }
            matching = exact.isEmpty
                ? try matching.filter { try frame($0, in: host).contains(probeFrame) }
                : exact
        }
        guard matching.count == 1 else {
            if matching.isEmpty, button,
               ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W09_TYPOGRAPHY_DIAGNOSTIC"] == "1" {
                let named = host.nodes.filter { node in
                    !(node is ChatTimelineParityProbeView)
                        && node.responds(to: NSSelectorFromString("accessibilityFrame"))
                        && ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                            ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String == title
                        }
                }
                for (index, candidate) in named.enumerated() {
                    try typographyDiagnostic(candidate, id: id + "/title-before-role/\(index)", title: title,
                        frame: frame(candidate, in: host), enabled: nil, candidateCount: named.count, host: host)
                }
            }
            for (index, candidate) in matching.enumerated() {
                try typographyDiagnostic(candidate, id: id + "/candidate/\(index)", title: title,
                    frame: frame(candidate, in: host), enabled: nil, candidateCount: matching.count, host: host)
            }
            if matching.isEmpty, let probeFrame,
               ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W09_TYPOGRAPHY_DIAGNOSTIC"] == "1" {
                // A control can intentionally override its AX label. Inspect
                // only actual nodes at this exact mounted probe frame without
                // treating geometry alone as acceptance or selecting a node.
                let sameFrame = try host.nodes.filter { node in
                    guard node.responds(to: NSSelectorFromString("accessibilityFrame")) else { return false }
                    return try frame(node, in: host) == probeFrame
                }
                for (index, candidate) in sameFrame.enumerated() {
                    try typographyDiagnostic(candidate, id: id + "/exact-frame-candidate/\(index)", title: title,
                        frame: frame(candidate, in: host), enabled: nil, candidateCount: sameFrame.count, host: host)
                }
            }
            throw ChatTimelineParityLayout.failure("Expected one observed W09 text/frame: " + title + " (\(matching.count) matches)")
        }
        let node = matching[0], frame = try frame(node, in: host)
        XCTAssertGreaterThan(frame.width, 0, title)
        XCTAssertGreaterThan(frame.height, 0, title)
        let isEnabled = button ? try enabled(node, title: title) : nil
        try typographyDiagnostic(node, id: id, title: title, frame: frame, enabled: isEnabled,
                                 candidateCount: candidates.count, host: host)
        return .init(id: id, title: title, frame: frame, enabled: isEnabled,
                     drawing: try drawing(node, title: title, id: id, host: host))
    }

    /// Static titles already have a mounted Text.Layout, exact font and explicit
    /// source color. They are drawing observations, never invented AX controls.
    static func observedProbeText(_ title: String, id: String, host: ChatQuietHost) throws -> Observation {
        let probes = ChatTimelineReferenceCapture.descendants(host.view, ChatTimelineParityProbeView.self)
            .filter { $0.semanticID == id && $0.text == title && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }
        guard probes.count == 1, let probe = probes.first, probe.colors["foreground"] != nil,
              probe.font != nil, probe.renderTextInk != nil else {
            throw ChatTimelineParityLayout.failure("Missing unique mounted static-text operands: " + id)
        }
        let element = try ChatTimelineParityLayout.probe(probe, in: host.view)
        guard element.frame.width > 0, element.frame.height > 0,
              let runs = element.textRuns, runs.count == 1, let run = runs.first,
              run.location == 0, run.length == (title as NSString).length,
              !run.rasterBounds.isEmpty, run.inkMasks?.isEmpty == false else {
            throw ChatTimelineParityLayout.failure("Mounted static text lacks complete glyph observations: " + id)
        }
        return .init(id: id, title: title, frame: element.frame, enabled: nil, drawing: element)
    }

    /// Select the actual NSTextField and its own cell, not an arbitrary member
    /// of a mixed NSView/AX inventory that contains both representations.
    static func observedField(_ title: String, id: String, host: ChatQuietHost, includeDrawing: Bool = true) throws -> Observation {
        let fields = ChatTimelineReferenceCapture.descendants(host.view, NSTextField.self).filter { field in
            !field.isHiddenOrHasHiddenAncestor && !field.visibleRect.isEmpty
                && ChatTimelineReferenceCapture.accessibilityAttribute(field, "accessibilityLabel") as? String == title
        }
        guard fields.count == 1, let field = fields.first, let cell = field.cell,
              host.nodes.contains(where: { $0 === cell }),
              ChatTimelineReferenceCapture.accessibilityAttribute(cell, "accessibilityRole") as? String == NSAccessibility.Role.textField.rawValue,
              ChatTimelineReferenceCapture.accessibilityAttribute(cell, "accessibilityLabel") as? String == title else {
            throw ChatTimelineParityLayout.failure("Missing unique actual field and owned AX text-field cell: " + id)
        }
        let cellFrame = try frame(cell, in: host)
        let cellEnabled = try enabled(cell, title: title)
        guard cellEnabled == field.isEnabled else {
            throw ChatTimelineParityLayout.failure("Actual field and its AX cell disagree about enabled state: " + id)
        }
        guard includeDrawing else {
            return .init(id: id, title: title, frame: cellFrame, enabled: cellEnabled)
        }
        let visible = field.stringValue.isEmpty ? field.placeholderString ?? "" : field.stringValue
        try typographyDiagnostic(field, id: id + "/actual-field", title: visible,
            frame: frame(field, in: host), enabled: field.isEnabled, candidateCount: 1, host: host)
        try typographyDiagnostic(cell, id: id + "/owned-cell", title: visible,
            frame: cellFrame, enabled: cellEnabled, candidateCount: 1, host: host)
        return .init(id: id, title: title, frame: cellFrame, enabled: cellEnabled,
            drawing: try fieldText(field, id: id, host: host.view))
    }

    private static func frame(_ node: NSObject, in host: ChatQuietHost) throws -> CGRect {
        let screen = try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let local = host.view.convert(host.window.convertFromScreen(screen), from: nil)
        return CGRect(x: local.minX - host.view.bounds.minX,
            y: host.view.isFlipped ? local.minY - host.view.bounds.minY : host.view.bounds.maxY - local.maxY,
            width: local.width, height: local.height)
    }

    private static func drawing(_ node: NSObject, title: String, id: String,
                                host: ChatQuietHost) throws -> ChatTimelineParityMetadata.Element? {
        let probes = ChatTimelineReferenceCapture.descendants(host.view, ChatTimelineParityProbeView.self)
            .filter { !$0.isHiddenOrHasHiddenAncestor && ($0.semanticID == id || $0.text == title) }
        let exact = probes.filter { $0.semanticID == id }
        let matches = exact.isEmpty ? probes : exact
        if matches.count == 1, let probe = matches.first {
            var element = try ChatTimelineParityLayout.probe(probe, in: host.view)
            element.id = id
            // The collector's legacy default labelColor is not evidence for a
            // system style. Read its actual mounted attributed text instead.
            if probe.colors["foreground"] == nil {
                let color = try foreground(node, text: title, in: host.view)
                element.colorTokens["foreground"] = color
                element.textRuns = element.textRuns?.map { run in
                    var value = run
                    value.colors[NSAttributedString.Key.foregroundColor.rawValue] = color
                    return value
                }
            }
            return element
        }
        if let label = node as? ChatNativeLabel {
            return try nativeText(label.text, in: label, id: id, host: host.view)
        }
        if let button = node as? ChatNativeTextButton {
            return try nativeText(button.text, in: button, id: id, drawing: button.drawingRect, host: host.view)
        }
        let fields = ChatTimelineReferenceCapture.descendants(host.view, NSTextField.self).filter { field in
            !field.isHiddenOrHasHiddenAncestor && (field === node ||
                ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                    ChatTimelineReferenceCapture.accessibilityAttribute(field, $0) as? String == title
                })
        }
        if fields.count == 1, let field = fields.first { return try fieldText(field, id: id, host: host.view) }
        return nil
    }

    static func fieldText(_ field: NSTextField, id: String, host: NSView) throws -> ChatTimelineParityMetadata.Element {
        if field.stringValue.isEmpty {
            return try placeholderLabel(field, id: id, host: host)
        }
        let source = field.attributedStringValue
        guard source.length > 0, let cell = field.cell else {
            throw ChatTimelineParityLayout.failure("Displayed text field has no attributed drawing text: " + id)
        }
        let text = NSMutableAttributedString(attributedString: source)
        let all = NSRange(location: 0, length: text.length)
        var missingColor = false
        source.enumerateAttributes(in: all) { attributes, range, _ in
            if attributes[.font] == nil, let font = field.font { text.addAttribute(.font, value: font, range: range) }
            if attributes[.foregroundColor] == nil {
                if let color = field.textColor { text.addAttribute(.foregroundColor, value: color, range: range) }
                else { missingColor = true }
            }
        }
        guard !missingColor else { throw ChatTimelineParityLayout.failure("Text-field foreground is not exposed: " + id) }
        return try nativeText(text, in: field, id: id, drawing: cell.titleRect(forBounds: field.bounds), host: host)
    }

    /// Current AppKit paints plain placeholders with a separate NSSimpleLabel.
    /// Read that mounted label's stored string and attributes, rather than the
    /// empty field value or a guessed default color. This private test observer
    /// deliberately fails closed if AppKit changes its drawing configuration.
    private static func placeholderLabel(_ field: NSTextField, id: String,
                                         host: NSView) throws -> ChatTimelineParityMetadata.Element {
        let labels = field.subviews.filter {
            String(reflecting: type(of: $0)) == "AppKit.NSSimpleLabel"
                && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
        }
        guard labels.count == 1, let label = labels.first, label.superview === field,
              let window = field.window, window === host.window, label.window === window,
              let cell = field.cell, cell.controlView === field,
              label.layer?.delegate === label, label.alphaValue > 0,
              !label.convert(label.visibleRect, to: host).intersection(host.visibleRect).isEmpty,
              field.stringValue.isEmpty, let placeholder = field.placeholderString, !placeholder.isEmpty else {
            throw ChatTimelineParityLayout.failure("Actual placeholder drawing label is not uniquely mounted: " + id)
        }
        func member(_ value: Any, _ name: String) throws -> Any {
            let matches = Mirror(reflecting: value).children.filter { $0.label == name }
            guard matches.count == 1 else { throw ChatTimelineParityLayout.failure("Placeholder drawing operand missing: " + name) }
            return matches[0].value
        }
        let before = try ChatTimelineCaptureColor.bitmap(field)
        let frameBefore = label.frame, boundsBefore = label.bounds, responderBefore = window.firstResponder
        let fieldFrame = field.frame, fieldBounds = field.bounds, enabledBefore = field.isEnabled
        let fieldAX = field.accessibilityFrame(), cellAX = cell.accessibilityFrame()
        let fontBefore = field.font, alphaBefore = label.alphaValue
        let configuration = try member(label, "labelConfiguration")
        let content = try member(configuration, "content")
        let contentMirror = Mirror(reflecting: content)
        guard contentMirror.displayStyle == .enum, contentMirror.children.count == 1,
              let payload = contentMirror.children.first, payload.label == "string" else {
            throw ChatTimelineParityLayout.failure("Placeholder label is not drawing a plain attributed string: " + id)
        }
        let values = Array(Mirror(reflecting: payload.value).children)
        guard values.count == 2, let title = values[0].value as? String, title == placeholder,
              let attributes = values[1].value as? [NSAttributedString.Key: Any],
              let font = attributes[.font] as? NSFont, let foreground = attributes[.foregroundColor] as? NSColor,
              font.isEqual(field.font), !title.contains("\n") else {
            throw ChatTimelineParityLayout.failure("Placeholder label lacks exact original text/font/color: " + id)
        }
        let frame = ChatTimelineParityLayout.frame(label.bounds, from: label, in: host)
        let ink = try ChatTimelineParityLayout.drawingInk(bounds: [frame], scale: host.window?.backingScaleFactor ?? 1) { context in
            context.translateBy(x: frame.minX, y: label.isFlipped ? frame.minY : frame.maxY)
            if !label.isFlipped { context.scaleBy(x: 1, y: -1) }
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: label.isFlipped)
            label.effectiveAppearance.performAsCurrentDrawingAppearance { label.draw(label.bounds) }
            NSGraphicsContext.current = previous
        }
        guard let minX = ink.spans.map(\.x).min(), let maxX = ink.spans.map({ $0.x + $0.length }).max(),
              let minY = ink.spans.map(\.y).min(), let maxY = ink.spans.map(\.y).max() else {
            throw ChatTimelineParityLayout.failure("Actual placeholder drawing has no observed glyph ink: " + id)
        }
        let bounds = CGRect(x: ink.origin.x + CGFloat(minX) / ink.scale, y: ink.origin.y + CGFloat(minY) / ink.scale,
            width: CGFloat(maxX - minX) / ink.scale, height: CGFloat(maxY - minY + 1) / ink.scale)
        let after = try ChatTimelineCaptureColor.bitmap(field)
        guard ChatTimelineParity.bitmap(try .init(before), try .init(after)).differentPixels == 0,
              label.superview === field, label.frame == frameBefore, label.bounds == boundsBefore,
              field.window === window, label.window === window, label.layer?.delegate === label,
              field.cell === cell, cell.controlView === field, field.font == fontBefore,
              field.frame == fieldFrame, field.bounds == fieldBounds, field.isEnabled == enabledBefore,
              field.accessibilityFrame() == fieldAX, cell.accessibilityFrame() == cellAX,
              label.alphaValue == alphaBefore,
              field.stringValue.isEmpty, field.placeholderString == title,
              window.firstResponder === responderBefore else {
            throw ChatTimelineParityLayout.failure("Placeholder operand observation changed the actual field: " + id)
        }
        let color = try ChatTimelineParityLayout.color(foreground, in: host)
        // Preserve all original attributes while collecting exact font/color
        // operands. The ink remains the actual label's draw, not a substitute
        // TextKit rendering or a mask selected from differing image pixels.
        var runs = try ChatTimelineParityLayout.labelRuns(NSAttributedString(string: title, attributes: attributes),
            drawingFrame: frame, in: host)
        guard runs.count == 1, runs[0].font == .init(font), runs[0].length == (title as NSString).length else {
            throw ChatTimelineParityLayout.failure("Placeholder drawing attributes do not cover one complete run: " + id)
        }
        runs[0].rasterBounds = [bounds]; runs[0].inkMasks = [ink]
        return .init(id: id, role: "text", frame: frame, text: title,
            lineBreaks: [.init(location: 0, length: (title as NSString).length)], colorTokens: ["foreground": color],
            textRuns: runs,
            opacity: label.alphaValue)
    }

    static func probeElements(in host: ChatQuietHost, prefixes: [String],
                              excluding roots: [NSView] = []) throws -> [ChatTimelineParityMetadata.Element] {
        let probes = ChatTimelineReferenceCapture.descendants(host.view, ChatTimelineParityProbeView.self)
            .filter { probe in
                probe.role != "container" && !probe.isHiddenOrHasHiddenAncestor && !probe.visibleRect.isEmpty
                    && prefixes.contains { probe.semanticID.hasPrefix($0) }
                    && !roots.contains { probe === $0 || probe.isDescendant(of: $0) }
            }
        return try probes.map { probe in
            if let title = probe.text, probe.colors["foreground"] == nil {
                return try observe(title, id: probe.semanticID, host: host).element
            }
            return try ChatTimelineParityLayout.probe(probe, in: host.view)
        }
    }

    /// The exact RGBA value exposed by the same mounted text node, including
    /// system secondary/disabled styling. A partial, mixed or absent attribute
    /// fails; no color is inferred from the native candidate or sampled pixels.
    private static func foreground(_ node: NSObject, text: String, in host: NSView) throws -> ChatTimelineParityMetadata.Color {
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let attributed = attributed(node, text: text),
              attributed.string == text, attributed.length == range.length else {
            throw ChatTimelineParityLayout.failure("Styled foreground does not cover the complete drawn text: " + text)
        }
        var observed: ChatTimelineParityMetadata.Color?, failure: Error?
        attributed.enumerateAttribute(.init("AXForegroundColor"), in: range) { value, _, _ in
            do {
                let color: NSColor
                if let value = value as? NSColor { color = value }
                else if let value, CFGetTypeID(value as AnyObject) == CGColor.typeID,
                        let converted = NSColor(cgColor: unsafeBitCast(value as AnyObject, to: CGColor.self)) { color = converted }
                else { throw ChatTimelineParityLayout.failure("Styled text range lacks its foreground color: " + text) }
                let current = try ChatTimelineParityLayout.color(color, in: host)
                if let observed, observed != current {
                    throw ChatTimelineParityLayout.failure("Styled text has multiple foreground colors: " + text)
                }
                observed = current
            } catch { failure = error }
        }
        if let failure { throw failure }
        return try XCTUnwrap(observed, "No observed styled foreground: " + text)
    }

    private static func attributed(_ node: NSObject, text: String) -> NSAttributedString? {
        let selector = NSSelectorFromString("accessibilityAttributedStringForRange:")
        guard !text.isEmpty else { return nil }
        guard node.responds(to: selector) else { return advertisedAttributedDescription(node, text: text) }
        // A semantic AX label is not proof that this node exposes a text range.
        // Disabled SwiftUI buttons can implement the selector but expose no
        // character count/value; querying label.length is not a valid fallback.
        let countSelector = NSSelectorFromString("accessibilityNumberOfCharacters")
        var count: Int?
        if node.responds(to: countSelector) {
            typealias CountGetter = @convention(c) (AnyObject, Selector) -> Int
            let value = unsafeBitCast(node.method(for: countSelector), to: CountGetter.self)(node, countSelector)
            if value >= 0 { count = value }
        }
        if count == nil {
            for name in ["accessibilityValue", "accessibilityTitle"] {
                if let value = ChatTimelineReferenceCapture.accessibilityAttribute(node, name) as? String, value == text {
                    count = (value as NSString).length; break
                }
            }
        }
        guard count == (text as NSString).length else { return advertisedAttributedDescription(node, text: text) }
        typealias Getter = @convention(c) (AnyObject, Selector, NSRange) -> Unmanaged<AnyObject>?
        let getter = unsafeBitCast(node.method(for: selector), to: Getter.self)
        return getter(node, selector, NSRange(location: 0, length: (text as NSString).length))?.takeUnretainedValue() as? NSAttributedString
    }

    /// Some SwiftUI controls expose their actual styled text through the public
    /// legacy AX attribute API without exposing a text-storage range. Read only
    /// the attribute this exact mounted node advertises; do not infer a color
    /// from its semantic label. The caller still checks every foreground run.
    private static func advertisedAttributedDescription(_ node: NSObject, text: String) -> NSAttributedString? {
        let names = NSSelectorFromString("accessibilityAttributeNames")
        let value = NSSelectorFromString("accessibilityAttributeValue:")
        guard node.responds(to: names), node.responds(to: value),
              let advertised = node.perform(names)?.takeUnretainedValue() as? [String],
              advertised.contains("AXAttributedDescription"),
              let attributed = node.perform(value, with: "AXAttributedDescription")?.takeUnretainedValue() as? NSAttributedString,
              attributed.string == text, attributed.length == (text as NSString).length else { return nil }
        return attributed
    }

    /// Inventory every visible root Text.Layout run. Timeline text is discharged
    /// only by that same host's collected glyph bounds; ancestor exclusions below
    /// prevent duplicate native-view collection, never establish text coverage.
    static func caller(in host: ChatQuietHost, excluding roots: [NSView],
                       observedTimeline: [ChatTimelineParityMetadata.Element],
                       additionalProbePrefixes: [String] = []) throws
        -> (elements: [ChatTimelineParityMetadata.Element], gaps: [String], runCount: Int, clippedRuns: [[String: Any]]) {
        func outside(_ view: NSView) -> Bool {
            !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
                && !roots.contains { view === $0 || view.isDescendant(of: $0) }
        }
        var elements = try probeElements(in: host,
            prefixes: ["w09/caller/", "w09/overlay/", "w06/avatar/"] + additionalProbePrefixes, excluding: roots)
        let textViews = ChatTimelineReferenceCapture.descendants(host.view, NSTextView.self)
            .filter { outside($0) && !$0.isFieldEditor }.sorted { position($0, host.view) < position($1, host.view) }
        for (index, view) in textViews.enumerated() {
            let id = "w09/caller/native-text/\(index)"
            if let editor = view as? ChatMentionEditor.Editor, editor.string.isEmpty,
               !editor.hasMarkedText(), !editor.placeholder.isEmpty {
                let text = NSAttributedString(string: editor.placeholder, attributes: editor.placeholderDrawingAttributes)
                let font = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                let foreground = try ChatTimelineParityLayout.color(XCTUnwrap(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor), in: host.view)
                let bounds = ChatTimelineParityLayout.frame(CGRect(origin: editor.placeholderDrawingOrigin, size: text.size()), from: editor, in: host.view)
                let ink = try ChatTimelineParityLayout.drawingInk(bounds: [bounds], scale: host.window.backingScaleFactor) { _ in
                    text.draw(at: bounds.origin)
                }
                elements.append(.init(id: id, role: "text", frame: ChatTimelineParityLayout.frame(editor.bounds, from: editor, in: host.view),
                    text: text.string, lineBreaks: [.init(location: 0, length: text.length)], colorTokens: ["foreground": foreground],
                    textRuns: [.init(location: 0, length: text.length, font: .init(font), colors: [NSAttributedString.Key.foregroundColor.rawValue: foreground], rasterBounds: [bounds], inkMasks: [ink])]))
            } else if !view.string.isEmpty {
                elements.append(try ChatTimelineParityLayout.text(view, id: id, in: host.view))
            }
        }
        let fields = ChatTimelineReferenceCapture.descendants(host.view, NSTextField.self)
            .filter(outside).sorted { position($0, host.view) < position($1, host.view) }
        for (index, field) in fields.enumerated() where !field.stringValue.isEmpty || !(field.placeholderString ?? "").isEmpty {
            elements.append(try fieldText(field, id: "w09/caller/field/\(index)", host: host.view))
        }
        // A repeated avatar can occur in both a header and an empty-state body.
        // Order only those repeated rendered instances; retain their exact frames.
        let repeated = Dictionary(grouping: elements.indices, by: { elements[$0].id }).filter { $0.value.count > 1 }
        for (_, indices) in repeated {
            for (occurrence, index) in indices.sorted(by: { elements[$0].frame.minY == elements[$1].frame.minY
                ? elements[$0].frame.minX < elements[$1].frame.minX : elements[$0].frame.minY < elements[$1].frame.minY }).enumerated() {
                elements[index].id += "/occurrence:\(occurrence)"
            }
        }
        let inventories = ChatTimelineReferenceCapture.descendants(host.view, ChatTimelineParityProbeView.self)
            .filter { $0.semanticID == "w09/caller/text-inventory" && !$0.isHiddenOrHasHiddenAncestor }
        guard inventories.count == 1, let inventory = inventories.first else {
            throw ChatTimelineParityLayout.failure("Missing unique caller Text.Layout inventory")
        }
        let inventoryFrame = inventory.swiftUIGlobalFrame
        guard !inventoryFrame.isNull, !inventoryFrame.isInfinite else {
            throw ChatTimelineParityLayout.failure("Missing raw SwiftUI caller inventory geometry")
        }
        // A child NSView marker can be backing-pixel aligned while the root's
        // Text.Layout preference retains its fractional SwiftUI origin. Match
        // both observed copies in this host's raw SwiftUI coordinate space.
        // Only a probe with an exact ID/text/frame drawing observation supplies
        // coverage; parent rectangles and other hosts cannot discharge a run.
        let probes = ChatTimelineReferenceCapture.descendants(host.view, ChatTimelineParityProbeView.self)
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.text != nil && !$0.textBounds.isEmpty }
        var clippedRuns: [[String: Any]] = []
        let visibleRuns = inventory.textBounds.filter { run in
            guard !run.isEmpty,
                  ChatTimelineParityLayout.frame(run, from: inventory, in: host.view).intersects(host.view.bounds) else { return false }
            // Text.Layout preferences propagate out of a scroll viewport even
            // when their owning text is wholly clipped. Discharge only an exact
            // raw run belonging to mounted probes whose own visibleRect clips
            // it completely; an ancestor rectangle alone proves nothing.
            let owners = probes.compactMap { probe -> (ChatTimelineParityProbeView, CGRect)? in
                let source = probe.swiftUIGlobalFrame
                guard !source.isNull, !source.isInfinite,
                      let local = probe.textBounds.first(where: {
                          $0.offsetBy(dx: source.minX - inventoryFrame.minX,
                              dy: source.minY - inventoryFrame.minY) == run
                      }) else { return nil }
                return (probe, local)
            }
            guard !owners.isEmpty, owners.allSatisfy({ !$0.1.intersects($0.0.visibleRect) }) else { return true }
            clippedRuns.append(["rawRun": NSStringFromRect(run), "owners": owners.map { probe, local in
                ["id": probe.semanticID, "text": probe.text ?? "", "localRun": NSStringFromRect(local),
                 "visibleRect": NSStringFromRect(probe.visibleRect), "windowNumber": host.window.windowNumber] as [String: Any]
            }])
            return false
        }
        func swiftUIBounds(_ observed: [ChatTimelineParityMetadata.Element]) throws -> [CGRect] {
            try probes.flatMap { probe -> [CGRect] in
                let frame = ChatTimelineParityLayout.frame(probe.bounds, from: probe, in: host.view)
                let matched = observed.contains { element in
                    let idMatches = element.id == probe.semanticID
                        || element.id.hasSuffix("/" + probe.semanticID)
                        || element.id.hasPrefix(probe.semanticID + "/occurrence:")
                    return idMatches && element.text == probe.text && element.frame == frame
                        && element.textRuns?.isEmpty == false
                }
                guard matched else { return [] }
                let source = probe.swiftUIGlobalFrame
                guard !source.isNull, !source.isInfinite else {
                    throw ChatTimelineParityLayout.failure("Missing raw SwiftUI drawing geometry: " + probe.semanticID)
                }
                return probe.textBounds.map { $0.offsetBy(dx: source.minX - inventoryFrame.minX,
                    dy: source.minY - inventoryFrame.minY) }
            }
        }
        let timelineSwiftUI = try swiftUIBounds(observedTimeline)
        let callerSwiftUI = try swiftUIBounds(elements)
        // Native AppKit drawing bounds already use host coordinates. Keep their
        // exact match path for text which does not have a SwiftUI probe.
        let timelineBounds = observedTimeline.flatMap { $0.textRuns?.flatMap(\.rasterBounds) ?? [] }
        let runs = visibleRuns.filter {
            !timelineSwiftUI.contains($0)
                && !timelineBounds.contains(ChatTimelineParityLayout.frame($0, from: inventory, in: host.view))
        }
        let observed = elements.flatMap { $0.textRuns?.flatMap(\.rasterBounds) ?? [] }
        var gaps = runs.filter {
            !callerSwiftUI.contains($0)
                && !observed.contains(ChatTimelineParityLayout.frame($0, from: inventory, in: host.view))
        }.map { "caller/text-inventory: unobserved Text.Layout run "
            + NSStringFromRect(ChatTimelineParityLayout.frame($0, from: inventory, in: host.view)) }
        // AppKit-backed controls need their own inventory: Text.Layout does not
        // necessarily propagate through a native segmented control or button.
        func observedTitle(_ title: String, in control: NSView) -> Bool {
            let bounds = ChatTimelineParityLayout.frame(control.bounds, from: control, in: host.view)
            return elements.contains { $0.text == title && bounds.contains($0.frame) && $0.textRuns?.isEmpty == false }
        }
        for control in ChatTimelineReferenceCapture.descendants(host.view, NSSegmentedControl.self).filter(outside) {
            let frame = ChatTimelineParityLayout.frame(control.bounds, from: control, in: host.view)
            try typographyDiagnostic(control, id: "caller/native-segment/control", title: "Authors",
                frame: frame, enabled: control.isEnabled, candidateCount: 1, host: host)
            if let cell = control.cell {
                try typographyDiagnostic(cell, id: "caller/native-segment/cell", title: "Authors",
                    frame: frame, enabled: control.isEnabled, candidateCount: 1, host: host)
                if ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W09_TYPOGRAPHY_DIAGNOSTIC"] == "1" {
                    let segments = ChatTimelineReferenceCapture.accessibilityAttribute(cell, "accessibilityChildren") as? [NSObject] ?? []
                    for (index, segment) in segments.enumerated() {
                        let title = ChatTimelineReferenceCapture.accessibilityAttribute(segment, "accessibilityTitle") as? String
                            ?? ChatTimelineReferenceCapture.accessibilityAttribute(segment, "accessibilityLabel") as? String ?? ""
                        try typographyDiagnostic(segment, id: "caller/native-segment/cell-child/\(index)", title: title,
                            frame: try self.frame(segment, in: host), enabled: nil, candidateCount: segments.count, host: host)
                    }
                }
            }
            if ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W09_TYPOGRAPHY_DIAGNOSTIC"] == "1" {
                let children = ChatTimelineReferenceCapture.accessibilityAttribute(control, "accessibilityChildren") as? [NSObject] ?? []
                for (index, child) in children.enumerated() {
                    let title = ChatTimelineReferenceCapture.accessibilityAttribute(child, "accessibilityTitle") as? String
                        ?? ChatTimelineReferenceCapture.accessibilityAttribute(child, "accessibilityLabel") as? String ?? ""
                    try typographyDiagnostic(child, id: "caller/native-segment/child/\(index)", title: title,
                        frame: try self.frame(child, in: host), enabled: nil, candidateCount: children.count, host: host)
                }
            }
            for segment in 0..<control.segmentCount {
                if let title = control.label(forSegment: segment), !title.isEmpty, !observedTitle(title, in: control) {
                    gaps.append("caller/native-segment: drawing operands are not observed for " + title)
                }
            }
        }
        for control in ChatTimelineReferenceCapture.descendants(host.view, NSButton.self).filter(outside)
            where !control.title.isEmpty && !observedTitle(control.title, in: control) {
            gaps.append("caller/native-button: drawing operands are not observed for " + control.title)
        }
        return (elements, gaps, runs.count, clippedRuns)
    }

    private static func position(_ view: NSView, _ host: NSView) -> (CGFloat, CGFloat) {
        let frame = ChatTimelineParityLayout.frame(view.bounds, from: view, in: host)
        return (frame.minY, frame.minX)
    }

    static func nativeText(_ attributed: NSAttributedString, in view: NSView, id: String,
                           drawing: CGRect? = nil, host: NSView) throws -> ChatTimelineParityMetadata.Element {
        typealias M = ChatTimelineParityMetadata
        let bounds = drawing ?? view.bounds
        let storage = NSTextStorage(attributedString: attributed), manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        var lines: [M.Line] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
            let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines.append(.init(location: range.location, length: range.length))
        }
        var colors: [String: M.Color] = [:]
        if attributed.length > 0, let foreground = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
            colors["foreground"] = try ChatTimelineParityLayout.color(foreground, in: host)
        }
        return .init(id: id, role: "text", frame: ChatTimelineParityLayout.frame(view.bounds, from: view, in: host),
            text: attributed.string, lineBreaks: lines, colorTokens: colors,
            textRuns: try ChatTimelineParityLayout.labelRuns(attributed,
                drawingFrame: ChatTimelineParityLayout.frame(bounds, from: view, in: host), in: host), opacity: view.alphaValue)
    }

    private static var diagnosticSequence = 0

    /// Investigation only: these values never populate parity metadata. Optional
    /// AX attributes may omit a drawing operand or report a semantic value that
    /// does not include a button style's compositing opacity.
    private static func typographyDiagnostic(_ node: NSObject, id: String, title: String,
                                             frame: CGRect, enabled: Bool?, candidateCount: Int,
                                             host: ChatQuietHost) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AGENTPAD_CHAT_NATIVE_W09_TYPOGRAPHY_DIAGNOSTIC"] == "1" else { return }
        let root = try ChatTimelineReferencePaths.root(XCTUnwrap(environment["AGENTPAD_CHAT_PARITY_EVIDENCE"],
            "The W09 typography diagnostic requires an external evidence directory"))
        let directory = root.appendingPathComponent("w09-typography-diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var strings: [String: String] = [:], rawPublicValues: [String: Any] = [:]
        for name in ["accessibilityValue", "accessibilityTitle", "accessibilityLabel", "accessibilityAttributedUserInputLabels"] {
            if let value = ChatTimelineReferenceCapture.accessibilityAttribute(node, name) {
                rawPublicValues[name] = diagnosticValue(value)
                if let value = value as? String { strings[name] = value }
            }
        }
        // Query only text-related attributes actually advertised by this mounted
        // node through the public legacy API. Do not invent a private selector.
        let namesSelector = NSSelectorFromString("accessibilityAttributeNames")
        let advertised = node.responds(to: namesSelector)
            ? node.perform(namesSelector)?.takeUnretainedValue() as? [String] ?? [] : []
        let parameterNamesSelector = NSSelectorFromString("accessibilityParameterizedAttributeNames")
        let parameters = node.responds(to: parameterNamesSelector)
            ? node.perform(parameterNamesSelector)?.takeUnretainedValue() as? [String] ?? [] : []
        let allowedTextNames: Set<String> = ["AXValue", "AXTitle", "AXDescription", "AXHelp", "AXNumberOfCharacters",
            "AXVisibleCharacterRange", "AXSelectedText", "AXSelectedTextRange", "AXAttributedDescription",
            "AXAttributedTitle", "AXAttributedValue", "AXAttributedUserInputLabels",
            "AXPlaceholderValue", "AXPlaceholderAttributedDescription"]
        let valueSelector = NSSelectorFromString("accessibilityAttributeValue:")
        var advertisedTextValues: [String: Any] = [:]
        if node.responds(to: valueSelector) {
            for name in advertised.filter({ allowedTextNames.contains($0) }).sorted() {
                if let value = node.perform(valueSelector, with: name)?.takeUnretainedValue() {
                    advertisedTextValues[name] = diagnosticValue(value)
                }
            }
        }
        var length: Int?, lengthSource: String?
        let countSelector = NSSelectorFromString("accessibilityNumberOfCharacters")
        if node.responds(to: countSelector) {
            typealias CountGetter = @convention(c) (AnyObject, Selector) -> Int
            let count = unsafeBitCast(node.method(for: countSelector), to: CountGetter.self)(node, countSelector)
            if count >= 0 { length = count; lengthSource = "accessibilityNumberOfCharacters" }
        }
        if length == nil {
            // AXDescription can be a field's instruction, so never use its
            // length as a range in that field's actual text storage.
            for name in ["accessibilityValue", "accessibilityTitle"] {
                if let value = strings[name] {
                    length = (value as NSString).length; lengthSource = name
                    break
                }
            }
        }

        // Diagnostic-only public text ranges. An AX semantic label alone is
        // never converted to a range in the node's text storage.
        var exposedRanges: [String: [String: Int]] = [:]
        for name in ["accessibilityVisibleCharacterRange", "accessibilitySharedCharacterRange"] {
            let rangeSelector = NSSelectorFromString(name)
            guard node.responds(to: rangeSelector) else { continue }
            typealias RangeGetter = @convention(c) (AnyObject, Selector) -> NSRange
            let range = unsafeBitCast(node.method(for: rangeSelector), to: RangeGetter.self)(node, rangeSelector)
            exposedRanges[name] = ["location": range.location, "length": range.length]
            if length == nil, name == "accessibilityVisibleCharacterRange", range.location == 0,
               range.length > 0, range.length == (title as NSString).length {
                length = range.length; lengthSource = name
            }
        }
        let selector = NSSelectorFromString("accessibilityAttributedStringForRange:")
        let supported = node.responds(to: selector)
        let role = ChatTimelineReferenceCapture.accessibilityAttribute(node, "accessibilityRole") as? String
        let actionNames = NSSelectorFromString("accessibilityActionNames")
        let actions = node.responds(to: actionNames)
            ? node.perform(actionNames)?.takeUnretainedValue() as? [String] ?? [] : []
        var record: [String: Any] = [
            "schema": 1, "diagnosticOnly": true, "acceptanceMetadataUpdated": false,
            "id": id, "matchedTitle": title, "matchingNodeCount": candidateCount,
            "nodeType": String(reflecting: type(of: node)),
            "publicRole": role.map { $0 as Any } ?? NSNull(),
            "advertisedActions": actions.sorted(),
            "respondsToPress": node.responds(to: NSSelectorFromString("accessibilityPerformPress")),
            "nodeIdentity": String(describing: ObjectIdentifier(node)),
            "hostIdentity": String(describing: ObjectIdentifier(host.view)),
            "windowNumber": host.window.windowNumber,
            "appearance": host.view.effectiveAppearance.name.rawValue,
            "hostSize": ["width": host.view.bounds.width, "height": host.view.bounds.height],
            "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height],
            "enabled": enabled.map { $0 as Any } ?? NSNull(), "strings": strings,
            "selector": NSStringFromSelector(selector), "responds": supported,
            "requestedLengthSource": lengthSource.map { $0 as Any } ?? NSNull(),
            "observedPublicTextRanges": exposedRanges,
            "rawPublicValues": rawPublicValues,
            "advertisedAttributeNames": advertised.sorted(),
            "advertisedParameterizedAttributeNames": parameters.sorted(),
            "advertisedTextValues": advertisedTextValues
        ]
        if let field = node as? NSTextField {
            record["actualFieldDrawing"] = ["fieldIdentity": String(describing: ObjectIdentifier(field)),
                "cellIdentity": field.cell.map { String(describing: ObjectIdentifier($0)) } ?? "absent",
                "cellControlViewIsField": field.cell?.controlView === field,
                "font": field.font.map { diagnosticValue($0) } ?? [:],
                "attributedValue": diagnosticValue(field.attributedStringValue),
                "placeholder": field.placeholderAttributedString.map { diagnosticValue($0) } ?? [:],
                "placeholderString": field.placeholderString ?? ""] as [String: Any]
        }
        if let control = node as? NSSegmentedControl {
            record["actualSegmentedControl"] = [
                "font": control.font.map { diagnosticValue($0) } ?? [:],
                "style": control.segmentStyle.rawValue, "distribution": control.segmentDistribution.rawValue,
                "selectedSegment": control.selectedSegment,
                "cellIdentity": control.cell.map { String(describing: ObjectIdentifier($0)) } ?? "absent",
                "segments": (0..<control.segmentCount).map { index in
                    ["index": index, "label": control.label(forSegment: index) ?? "",
                     "enabled": control.isEnabled(forSegment: index), "selected": control.isSelected(forSegment: index),
                     "width": control.width(forSegment: index)] as [String: Any]
                },
                "mountedViews": ChatTimelineReferenceCapture.descendants(control, NSView.self).map { view in
                    ["type": String(reflecting: type(of: view)), "frame": NSStringFromRect(view.frame),
                     "hidden": view.isHiddenOrHasHiddenAncestor] as [String: Any]
                }
            ] as [String: Any]
        }
        if let cell = node as? NSSegmentedCell {
            record["actualSegmentedCell"] = ["font": cell.font.map { diagnosticValue($0) } ?? [:],
                "attributedValue": diagnosticValue(cell.attributedStringValue), "trackingMode": cell.trackingMode.rawValue,
                "controlViewIdentity": cell.controlView.map { String(describing: ObjectIdentifier($0)) } ?? "absent"] as [String: Any]
        }
        // Inventory only actual descendants. This does not borrow typography
        // from a sibling button or populate acceptance metadata.
        if length == nil {
            var queue = ChatTimelineReferenceCapture.accessibilityAttribute(node, "accessibilityChildren") as? [NSObject] ?? []
            var seen = Set<ObjectIdentifier>(), children: [[String: Any]] = []
            while let child = queue.popLast(), children.count < 100 {
                guard seen.insert(ObjectIdentifier(child)).inserted else { continue }
                var entry: [String: Any] = ["type": String(reflecting: type(of: child)),
                    "identity": String(describing: ObjectIdentifier(child)),
                    "hasAttributedRangeGetter": child.responds(to: selector)]
                for name in ["accessibilityRole", "accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                    if let value = ChatTimelineReferenceCapture.accessibilityAttribute(child, name) as? String { entry[name] = value }
                }
                if child.responds(to: NSSelectorFromString("accessibilityFrame")), let value = child.value(forKey: "accessibilityFrame") as? NSValue {
                    entry["frame"] = NSStringFromRect(value.rectValue)
                }
                let childCount = NSSelectorFromString("accessibilityNumberOfCharacters")
                if child.responds(to: childCount) {
                    typealias Getter = @convention(c) (AnyObject, Selector) -> Int
                    entry["characterCount"] = unsafeBitCast(child.method(for: childCount), to: Getter.self)(child, childCount)
                }
                children.append(entry)
                queue += ChatTimelineReferenceCapture.accessibilityAttribute(child, "accessibilityChildren") as? [NSObject] ?? []
            }
            record["actualDescendants"] = children
        }
        if supported, let length {
            let range = NSRange(location: 0, length: length)
            record["requestedRange"] = ["location": range.location, "length": range.length]
            // NSRange is passed by value. NSObject.perform(_:with:) would pass
            // an object pointer and is not the ABI of this public AX method.
            typealias AttributedGetter = @convention(c) (AnyObject, Selector, NSRange) -> Unmanaged<AnyObject>?
            let getter = unsafeBitCast(node.method(for: selector), to: AttributedGetter.self)
            if let returned = getter(node, selector, range)?.takeUnretainedValue() {
                record["returnedType"] = String(reflecting: type(of: returned))
                if let value = returned as? NSAttributedString {
                    var runs: [[String: Any]] = []
                    host.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in
                            runs.append(["range": ["location": range.location, "length": range.length],
                                "attributes": attributes.keys.sorted { $0.rawValue < $1.rawValue }.map { key in
                                    ["name": key.rawValue, "value": diagnosticValue(attributes[key]!)] as [String: Any]
                                }])
                        }
                    }
                    record["status"] = "returned-attributed-string"
                    record["returnedString"] = value.string
                    record["returnedLength"] = value.length
                    record["runs"] = runs
                } else {
                    record["status"] = "returned-unexpected-type"
                    record["returnedValue"] = diagnosticValue(returned)
                }
            } else { record["status"] = "returned-nil" }
        } else {
            record["status"] = supported ? "text-length-unavailable" : "selector-unavailable"
        }
        diagnosticSequence += 1
        record["sequence"] = diagnosticSequence
        let name = String(format: "%05d", diagnosticSequence) + "-" + UUID().uuidString + ".json"
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// Preserve what AX returned. In particular, an AXFont dictionary remains a
    /// dictionary: a name and point size do not establish variable font traits.
    private static func diagnosticValue(_ value: Any, depth: Int = 0) -> [String: Any] {
        var result: [String: Any] = ["type": String(reflecting: type(of: value))]
        guard depth < 8 else { result["unserialized"] = "depth-limit"; return result }
        if let value = value as? NSAttributedString {
            result["string"] = value.string; result["length"] = value.length
            var runs: [[String: Any]] = []
            value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in
                runs.append(["range": ["location": range.location, "length": range.length],
                    "attributes": attributes.keys.sorted { $0.rawValue < $1.rawValue }.map { key in
                        ["name": key.rawValue, "value": diagnosticValue(attributes[key]!, depth: depth + 1)] as [String: Any]
                    }])
            }
            result["runs"] = runs
        } else if let font = value as? NSFont {
            let descriptor = ChatTimelineParityMetadata.FontDescriptor(font)
            result["fontName"] = font.fontName
            result["fontDescriptor"] = ["family": descriptor.family, "size": descriptor.size,
                "traits": descriptor.traits, "variations": descriptor.variations]
        } else if let color = value as? NSColor {
            result["description"] = color.description
            if let resolved = color.usingColorSpace(.sRGB) {
                result["sRGB"] = ["red": resolved.redComponent, "green": resolved.greenComponent,
                    "blue": resolved.blueComponent, "alpha": resolved.alphaComponent]
            }
        } else if CFGetTypeID(value as AnyObject) == CGColor.typeID {
            let color = unsafeBitCast(value as AnyObject, to: CGColor.self)
            result["components"] = color.components ?? []
            result["alpha"] = color.alpha
            if let space = color.colorSpace {
                result["colorSpaceModel"] = space.model.rawValue
                if let name = space.name { result["colorSpaceName"] = name as String }
            }
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let resolved = color.converted(to: space, intent: .defaultIntent, options: nil) {
                result["sRGBComponents"] = resolved.components ?? []
            }
        } else if let value = value as? String {
            result["value"] = value
        } else if let value = value as? NSNumber {
            result["objCType"] = String(cString: value.objCType)
            if value.doubleValue.isFinite { result["value"] = value }
            else { result["nonFiniteValue"] = value.stringValue }
        } else if let value = value as? NSDictionary {
            result["entries"] = value.allKeys.sorted { String(describing: $0) < String(describing: $1) }.map { key in
                ["key": diagnosticValue(key, depth: depth + 1),
                 "value": diagnosticValue(value[key]!, depth: depth + 1)]
            }
        } else if let value = value as? NSArray {
            result["values"] = value.map { diagnosticValue($0, depth: depth + 1) }
        } else {
            result["description"] = String(describing: value)
        }
        return result
    }

    private static func enabled(_ node: NSObject, title: String) throws -> Bool {
        if let control = node as? NSControl { return control.isEnabled }
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        if node.responds(to: legacy), let value = node.perform(legacy, with: "AXEnabled")?.takeUnretainedValue() as? NSNumber {
            return value.boolValue
        }
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard node.responds(to: selector) else { throw ChatTimelineParityLayout.failure("Missing enabled observation: " + title) }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: selector), to: Getter.self)(node, selector)
    }
}

/// Mutates only the existing capture environment in an already mounted body.
@MainActor @Observable final class ChatW09ProbeMode { var enabled = true }

@MainActor struct ChatW09ProbeEnvironment: View {
    let content: AnyView
    let mode: ChatW09ProbeMode
    var includeViewport = false
    var body: some View {
        if includeViewport { ChatTimelineParityLayout.legacy(content: content, enabled: mode.enabled).content }
        else { content.environment(\.chatParityEnabled, mode.enabled) }
    }
}
