import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

/// W07 observations use the operands actually installed in the views. Neither
/// the legacy measurements nor the reference bitmap come from a native plan.
@MainActor enum ChatNativeMetadataParity {
    typealias Metadata = ChatTimelineParityMetadata
    typealias Element = Metadata.Element

    static func legacy(_ collector: ChatTimelineParityLegacyCollector, in host: NSView) throws -> Metadata {
        try collector.snapshot(in: host)
    }

    static func native(coordinator: NativeChatTimelineCoordinator, cell: ChatNativeShellCell,
                       in host: NSView) throws -> Metadata {
        var elements = try ChatTimelineParityLayout.snapshot(coordinator: coordinator, in: host).elements
        let metadata = cell.metadata
        for operand in metadata.parityTexts {
            elements.append(try text(operand.text, id: operand.id, frame: operand.frame,
                drawing: operand.drawingFrame, from: metadata, in: host) { context in
                    metadata.drawParityText(id: operand.id, in: context)
                })
        }
        for operand in metadata.parityImages where !operand.id.hasSuffix("/pin/icon") {
            elements.append(try control(operand.id, frame: operand.frame, from: metadata,
                colors: ["foreground": operand.color], in: host))
        }
        for (id, view) in metadata.parityControls where !view.isHiddenOrHasHiddenAncestor {
            guard !elements.contains(where: { $0.id == id }) else { continue }
            let tokens = metadata.parityControlColors[id] ?? [:]
            var colors: [String: NSColor] = [:]
            colors["background"] = tokens["fill"]; colors["border"] = tokens["stroke"]
            elements.append(try control(id, frame: view.bounds, from: view, colors: colors, in: host))
        }
        try appendAgent(cell.membership, texts: cell.membership.parityTexts,
            images: cell.membership.parityImages, fills: cell.membership.parityFills,
            controls: cell.membership.parityControls, to: &elements, in: host)
        try appendAgent(cell.sources, texts: cell.sources.parityTexts,
            images: cell.sources.parityImages, fills: cell.sources.parityFills,
            controls: cell.sources.parityControls, to: &elements, in: host)
        try appendAgent(cell.request, texts: cell.request.parityTexts,
            images: cell.request.parityImages, fills: cell.request.parityFills,
            controls: cell.request.parityControls, to: &elements, in: host)
        for label in cell.inlineControls.subviews.compactMap({ $0 as? ChatNativeLabel })
            where !label.isHiddenOrHasHiddenAncestor && label.text.string == "edited" {
            elements.append(try text(label.text, id: "w07/edited", frame: label.bounds,
                drawing: label.bounds, from: label, in: host) { _ in label.draw(label.bounds) })
        }
        let replies = cell.replySummary
        if !replies.isHiddenOrHasHiddenAncestor, !replies.bounds.isEmpty {
            if !replies.parityButton.isHiddenOrHasHiddenAncestor {
                // Reuse W06's actual footer operands and renderer ink. Select
                // participant observations by the displayed native subtree,
                // never by differing pixels; the full bitmap stays compared.
                let avatarFrames = replies.parityAvatars.filter { !$0.isHiddenOrHasHiddenAncestor }
                    .map { ChatTimelineParityLayout.frame($0.bounds, from: $0, in: host) }
                let media = try ChatNativeMediaParity.native(coordinator: coordinator, cell: cell, in: host)
                elements += media.elements.filter { element in
                    element.id.hasPrefix("w06/replies/")
                        || element.role == "avatar" && avatarFrames.contains(element.frame)
                }
            } else if !replies.parityRequestButton.isHiddenOrHasHiddenAncestor {
                // A request-only footer has no displayed summary or chevron.
                // Observe its actual visible request button directly; a zero
                // slot retained by the hidden summary is not rendered content.
                let operand = try XCTUnwrap(replies.parityTexts.first { $0.id == "w06/replies/request" })
                elements.append(try text(operand.text, id: operand.id, frame: operand.frame,
                    drawing: replies.parityRequestDrawingFrame, from: replies, in: host) { context in
                        replies.drawParityText(id: operand.id, in: context)
                    })
            }
        }
        return try ChatTimelineParityLayout.finish(elements)
    }

    private static func appendAgent(_ view: NSView, texts: [ChatNativeAgentTextOperand],
                                    images: [ChatNativeAgentImageOperand], fills: [ChatNativeAgentFillOperand],
                                    controls: [String: NSButton], to elements: inout [Element], in host: NSView) throws {
        guard !view.isHiddenOrHasHiddenAncestor else { return }
        for operand in texts {
            var observed = try text(operand.text, id: operand.id, frame: operand.frame,
                drawing: operand.drawingFrame, from: view, in: host) { _ in operand.draw() }
            if let stroke = fills.first(where: { $0.id == operand.id + "-border" }) {
                observed.colorTokens["stroke"] = try ChatTimelineParityLayout.color(stroke.color, in: host)
            }
            elements.append(observed)
        }
        for fill in fills where fill.strokeWidth == 0 {
            var colors = ["background": fill.color]
            if let stroke = fills.first(where: { $0.id == fill.id + "-border" }) { colors["border"] = stroke.color }
            elements.append(try control(fill.id, frame: fill.frame, from: view, colors: colors, in: host))
        }
        for image in images where image.id.hasPrefix("w07/source/") && image.id.hasSuffix("/icon") {
            elements.append(try control(image.id, frame: image.frame, from: view,
                colors: ["foreground": image.color], in: host))
        }
        for (id, button) in controls where !button.isHiddenOrHasHiddenAncestor {
            guard !elements.contains(where: { $0.id == id }) else { continue }
            elements.append(try control(id, frame: button.bounds, from: button, in: host))
        }
    }

    static func control(_ id: String, frame: CGRect, from view: NSView,
                        colors: [String: NSColor] = [:], in host: NSView) throws -> Element {
        Element(id: id, role: "control", frame: ChatTimelineParityLayout.frame(frame, from: view, in: host),
            colorTokens: try colors.mapValues { try ChatTimelineParityLayout.color($0, in: host) })
    }

    static func text(_ attributed: NSAttributedString, id: String, frame: CGRect, drawing: CGRect,
                     from view: NSView, in host: NSView, draw: (CGContext) -> Void) throws -> Element {
        guard attributed.length > 0 else { throw ChatTimelineParityLayout.failure("Empty W07 text operand: " + id) }
        let storage = NSTextStorage(attributedString: attributed), manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: drawing.size)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        var lines: [Metadata.Line] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
            let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines.append(.init(location: range.location, length: range.length))
        }
        if !lines.isEmpty { lines[lines.count - 1].length = attributed.length - lines[lines.count - 1].location }
        let foreground = try XCTUnwrap(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            "W07 text must expose its real drawing foreground: " + id)
        let drawingFrame = ChatTimelineParityLayout.frame(drawing, from: view, in: host)
        var runs = try ChatTimelineParityLayout.labelRuns(attributed, drawingFrame: drawingFrame, in: host)
        let ink = try drawingInk(view: view, bounds: frame.union(drawing), in: host, draw: draw)
        for index in runs.indices {
            // The production operand is drawn unchanged. TextKit may mutate
            // its private measurement storage to a fallback font (emoji),
            // while the legacy probe records the actual Font.resolve input.
            // Observe each original native operand font at the same range;
            // retain the actual renderer's ink and measured line segmentation.
            let font = try XCTUnwrap(attributed.attribute(.font, at: runs[index].location, effectiveRange: nil) as? NSFont)
            runs[index].font = .init(font)
            runs[index].inkMasks = [ink]
        }
        return Element(id: id, role: "text", frame: ChatTimelineParityLayout.frame(frame, from: view, in: host),
            text: attributed.string, lineBreaks: lines,
            colorTokens: ["foreground": try ChatTimelineParityLayout.color(foreground, in: host)], textRuns: runs)
    }

    private static func drawingInk(view: NSView, bounds: CGRect, in host: NSView,
                                   draw: (CGContext) -> Void) throws -> Metadata.InkMask {
        let scale = host.window?.backingScaleFactor ?? 1
        let pixels = CGRect(x: bounds.minX * scale, y: bounds.minY * scale,
            width: bounds.width * scale, height: bounds.height * scale).integral
        guard pixels.width > 0, pixels.height > 0,
              let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ChatTimelineParityLayout.failure("Cannot observe W07 text ink")
        }
        context.translateBy(x: -pixels.minX, y: pixels.maxY); context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { draw(context) }
        let image = try XCTUnwrap(context.makeImage())
        let origin = ChatTimelineParityLayout.frame(CGRect(x: pixels.minX / scale, y: pixels.minY / scale,
            width: pixels.width / scale, height: pixels.height / scale), from: view, in: host).origin
        return try ChatTimelineParityLayout.inkMask(image, origin: origin, scale: scale)
    }

    static func embeddedNative(_ container: NativeChatTimelineContainer, in host: NSView) throws -> Metadata {
        let coordinator = container.coordinator
        let scoped = try outerSiblingElements(in: host)
        var local = try ChatTimelineParityLayout.snapshot(coordinator: coordinator, in: container).elements
        for index in coordinator.rows.indices {
            guard let cell = coordinator.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell else { continue }
            local += try native(coordinator: coordinator, cell: cell, in: container).elements.filter {
                $0.id.hasPrefix("w07/") || $0.id.hasPrefix("w06/")
            }
        }
        let origin = ChatTimelineParityLayout.frame(container.bounds, from: container, in: host).origin
        let converted = local.filter { $0.id != "viewport" }.map { original in
            var element = original
            element.frame = element.frame.offsetBy(dx: origin.x, dy: origin.y)
            // NSTextView.textContainerOrigin is local to its text view. Only
            // the host-coordinate frame and glyph observations move here.
            element.textRuns = element.textRuns?.map { value in
                var run = value
                run.rasterBounds = run.rasterBounds.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
                run.inkMasks = run.inkMasks?.map { value in
                    var ink = value; ink.origin.x += origin.x; ink.origin.y += origin.y; return ink
                }
                return run
            }
            return element
        }
        return try ChatTimelineParityLayout.finish(scoped + converted)
    }

    /// The generic legacy collector also infers a standalone timeline inset.
    /// These outer sibling observations may start at y=0; they are raw marker
    /// facts, not another timeline. Final validation in embeddedNative composes
    /// them with the actual table's independently measured inset.
    private static func outerSiblingElements(in host: NSView) throws -> [Element] {
        let probes = ChatTimelineReferenceCapture.descendants(host, ChatTimelineParityProbeView.self).filter {
            !$0.isHiddenOrHasHiddenAncestor && ($0.semanticID == "viewport" || $0.semanticID == "timelineViewport"
                || $0.semanticID.hasPrefix("embedding/") || $0.semanticID.hasPrefix("w07/boundary/"))
        }
        guard !probes.isEmpty else { throw ChatTimelineParityLayout.failure("No rendered outer sibling observations") }
        return try probes.map { probe in
            var element = Element(id: probe.semanticID, role: probe.role,
                frame: ChatTimelineParityLayout.frame(probe.bounds, from: probe, in: host), text: probe.text,
                lineBreaks: probe.role == "avatar" ? nil : probe.lineBreaks?.map { .init(location: $0.location, length: $0.length) },
                colorTokens: try probe.colors.mapValues { try ChatTimelineParityLayout.color($0, in: host) },
                srgbTokens: probe.srgbTokens, opacity: probe.opacity)
            if let text = probe.text, let font = probe.font {
                element.textRuns = [.init(location: 0, length: (text as NSString).length, font: .init(font),
                    colors: [NSAttributedString.Key.foregroundColor.rawValue: try ChatTimelineParityLayout.color(probe.colors["foreground"] ?? .labelColor, in: host)],
                    rasterBounds: probe.textBounds.map { ChatTimelineParityLayout.frame($0, from: probe, in: host) },
                    inkMasks: try probe.renderTextInk?().map {
                        [try ChatTimelineParityLayout.inkMask($0, origin: element.frame.origin,
                            scale: CGFloat($0.width) / element.frame.width)]
                    })]
            }
            return element
        }
    }

    static func externalEditor(_ metadata: Metadata, text: String, in host: NSView) throws -> Metadata {
        guard !text.isEmpty else { return metadata }
        let editors = ChatTimelineReferenceCapture.descendants(host, NSTextView.self).filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.string == text && $0.isEditable
        }
        XCTAssertEqual(editors.count, 1)
        let editor = try XCTUnwrap(editors.first, "Exactly one actual sibling channel-question editor must be observed")
        return try ChatTimelineParityLayout.finish(metadata.elements + [ChatTimelineParityLayout.text(editor,
            id: "w07/boundary/ask/editor-text", in: host)])
    }

    static func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let result = try ChatTimelineCaptureColor.bitmap(view)
        return result
    }
    static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    static func record(id: String, testName: String, inventory: [String], current: Metadata, candidate: Metadata,
                       expected: NSBitmapImageRep, actual: NSBitmapImageRep, fixture: Any,
                       observations: [String: Any], output: URL) throws {
        let result = ChatTimelineParity.compare(currentLayout: current, candidateLayout: candidate,
            current: try .init(expected), candidate: try .init(actual))
        let accepted = result.passes && observations["instrumentationNeutral"] as? Bool == true
            && observations["requiredBranchesVerified"] as? Bool == true
        let referencePath = output.appendingPathComponent(id + "-legacy.png")
        let candidatePath = output.appendingPathComponent(id + "-native.png")
        for (suffix, image) in [("legacy", expected), ("native", actual)] {
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(
                to: output.appendingPathComponent(id + "-" + suffix + ".png"), options: .withoutOverwriting)
        }
        let evidence: [String: Any] = ["captureID": id, "testName": testName, "inventoryIDs": inventory, "legacy": try json(current),
            "native": try json(candidate), "result": try json(result), "fixture": fixture, "observations": observations,
            "fullAcceptance": accepted, "status": accepted ? "PASS" : "FAIL", "checkExitStatus": accepted ? 0 : 1,
            "comparisonExitStatus": result.passes ? 0 : 1,
            "checkExitStatusMeaning": "Per-pair comparison, required branch, and marker-neutrality checks; process exit status is bound by the quiet run manifest.",
            "referencePNG": referencePath.path, "candidatePNG": candidatePath.path,
            "cropped": false, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "locale": Locale.current.identifier, "timeZone": TimeZone.current.identifier,
            "accent": NSColor.controlAccentColor.description, "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(
            to: output.appendingPathComponent(id + ".json"), options: .withoutOverwriting)
        XCTAssertTrue(result.passes, "W07 three-check gate: " + id + ": " + (current.captureGaps + candidate.captureGaps).joined(separator: "; "))
    }
}

/// A real pending fixture request without a sleeping worker. Every request is
/// either delivered once or cancelled by its production URLSession owner.
final class W07CaptureReactorsProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static let delivery = DispatchQueue(label: "w07-reactors-capture")
    nonisolated(unsafe) private static var path = ""
    nonisolated(unsafe) private static var held = false
    nonisolated(unsafe) private static var failure = false
    nonisolated(unsafe) private static var first = Data()
    nonisolated(unsafe) private static var more = Data()
    nonisolated(unsafe) private static var pending: [ObjectIdentifier: W07CaptureReactorsProtocol] = [:]
    private let completionLock = NSLock()
    private var stopped = false
    private var delivered = false
    static var heldCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    static func configure(path: String, held: Bool, failure: Bool, first: Data, more: Data) {
        lock.lock(); defer { lock.unlock() }
        self.path = path; self.held = held; self.failure = failure; self.first = first; self.more = more
    }
    static func release() {
        lock.lock(); held = false
        let requests = Array(pending.values); pending.removeAll(); lock.unlock()
        for request in requests { delivery.async { request.complete(.failure(URLError(.cancelled))) } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        guard request.url?.path == Self.path else {
            Self.lock.unlock(); Self.delivery.async { self.complete(.failure(URLError(.unsupportedURL))) }; return
        }
        if Self.held { Self.pending[ObjectIdentifier(self)] = self; Self.lock.unlock(); return }
        let after = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "after" }?.value
        let result: Result<ChatStubProtocol.Answer, URLError> = Self.failure ? .failure(URLError(.networkConnectionLost))
            : .success(.init(status: 200, body: after == nil ? Self.first : Self.more))
        Self.lock.unlock(); Self.delivery.async { self.complete(result) }
    }
    override func stopLoading() {
        completionLock.lock(); stopped = true; completionLock.unlock()
        Self.lock.lock(); Self.pending[ObjectIdentifier(self)] = nil; Self.lock.unlock()
    }
    private func complete(_ result: Result<ChatStubProtocol.Answer, URLError>) {
        completionLock.lock()
        guard !stopped, !delivered else { completionLock.unlock(); return }
        delivered = true; completionLock.unlock()
        switch result {
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        case .success(let answer):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body); client?.urlProtocolDidFinishLoading(self)
        }
    }
}
