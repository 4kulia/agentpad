import AppKit
import ObjectiveC.runtime
import SwiftUI
import XCTest
@testable import AgentPadKit

/// Observation only. Neither legacy geometry nor a reference image is derived
/// from the candidate's layout; glyph masks replay the actual drawing operands.
@MainActor enum ChatNativeMediaParity {
    typealias Metadata = ChatTimelineParityMetadata
    typealias Element = Metadata.Element

    static func legacy(_ collector: ChatTimelineParityLegacyCollector, in host: NSView) throws -> Metadata {
        let observed = try collector.snapshot(in: host)
        // The older row-level marker describes initials even when ContactAvatar
        // displays a photo. W06 uses ContactAvatar's actual selected branch.
        return try ChatTimelineParityLayout.finish(observeEmptyContainers(observed.elements.filter {
            !($0.role == "avatar" && !$0.id.hasPrefix("w06/avatar/"))
        }, in: host))
    }

    static func native(coordinator: NativeChatTimelineCoordinator, cell: ChatNativeShellCell,
                       in host: NSView) throws -> Metadata {
        let base = try ChatTimelineParityLayout.snapshot(coordinator: coordinator, in: host)
        var elements = base.elements.filter { $0.role != "avatar" }
        if cell.mainAvatar.superview != nil, !cell.mainAvatar.isHiddenOrHasHiddenAncestor,
           !cell.mainAvatar.bounds.isEmpty {
            elements.append(try avatar(cell.mainAvatar, shell: cell, in: host))
        }
        for card in cell.attachments.cards where !card.isHiddenOrHasHiddenAncestor {
            guard let plan = card.plan else { throw ChatTimelineParityLayout.failure("Displayed attachment lacks its installed plan") }
            let id = "w06/attachment/" + plan.file.id
            elements.append(try control(card, id: id, in: host))
            if plan.file.isImage {
                elements.append(try control(card.imageButton, id: id + "/image",
                    colors: ["background": card.imageButton.backgroundColor], in: host))
                if card.imageButton.failed, card.imageButton.preview == nil {
                    guard let style = card.imageButton.style else { throw ChatTimelineParityLayout.failure("Image failure has no drawing style") }
                    elements.append(Element(id: id + "/failure-icon", role: "control",
                        frame: ChatTimelineParityLayout.frame(card.imageButton.failureDrawingRect, from: card.imageButton, in: host),
                        colorTokens: ["foreground": try ChatTimelineParityLayout.color(style.color("secondary"), in: host)]))
                }
            } else {
                elements.append(Element(id: id + "/background", role: "control",
                    frame: ChatTimelineParityLayout.frame(plan.background, from: card, in: host),
                    colorTokens: ["background": try ChatTimelineParityLayout.color(card.backgroundColor, in: host)]))
                elements.append(try control(card.document, id: id + "/document",
                    colors: ["foreground": try XCTUnwrap(card.document.contentTintColor)], in: host))
                if !card.download.isHiddenOrHasHiddenAncestor {
                    elements.append(try control(card.download, id: id + "/save", in: host))
                }
            }
            for (suffix, label) in [("name", card.name), ("detail", card.detail), ("problem", card.problem)] {
                if !label.isHiddenOrHasHiddenAncestor, !label.bounds.isEmpty, label.text.length > 0 {
                    elements.append(try text(label.text, view: label, id: id + "/" + suffix, in: host,
                        draw: { label.draw(label.bounds) }))
                }
            }
            if !card.retry.isHiddenOrHasHiddenAncestor, !card.retry.bounds.isEmpty {
                elements.append(try text(card.retry.text, view: card.retry, id: id + "/retry",
                    drawing: card.retry.drawingRect, in: host, draw: { card.retry.draw(card.retry.bounds) }))
            }
            if !card.spinner.isHiddenOrHasHiddenAncestor, !card.spinner.bounds.isEmpty {
                elements.append(try control(card.spinner, id: id + "/spinner", in: host))
            }
        }
        let replies = cell.replySummary
        if !replies.isHiddenOrHasHiddenAncestor, !replies.bounds.isEmpty {
            if !replies.parityButton.isHiddenOrHasHiddenAncestor {
                elements.append(try control(replies.parityButton, id: "w06/replies/button", in: host))
            }
            for operand in replies.parityTexts where operand.text.length > 0 && !operand.frame.isEmpty {
                elements.append(try text(operand.text, view: replies, id: operand.id,
                    drawing: operand.id == "w06/replies/request" ? replies.parityRequestDrawingFrame : operand.frame,
                    elementFrame: operand.frame, in: host, draw: {
                        if let context = NSGraphicsContext.current?.cgContext { replies.drawParityText(id: operand.id, in: context) }
                    }))
            }
            if let badge = replies.parityUnread {
                elements.append(Element(id: "w06/replies/unread", role: "control",
                    frame: ChatTimelineParityLayout.frame(badge.frame, from: replies, in: host),
                    colorTokens: ["background": try ChatTimelineParityLayout.color(badge.color, in: host)]))
            }
            // Request-only footers keep the summary button hidden. Its
            // retained drawing operand is not a rendered control.
            if !replies.parityButton.isHiddenOrHasHiddenAncestor, let chevron = replies.parityChevron {
                elements.append(Element(id: "w06/replies/chevron", role: "control",
                    frame: ChatTimelineParityLayout.frame(chevron.frame, from: replies, in: host),
                    colorTokens: ["foreground": try ChatTimelineParityLayout.color(chevron.color, in: host)]))
            }
            for view in replies.parityAvatars where !view.isHiddenOrHasHiddenAncestor {
                elements.append(try avatar(view, in: host))
            }
        }
        return try ChatTimelineParityLayout.finish(observeEmptyContainers(elements, in: host))
    }

    /// An attachment-only row still owns a real zero-length NSTextStorage.
    /// Keep its complete geometry, but do not claim that it draws a font run.
    private static func observeEmptyContainers(_ elements: [Element], in host: NSView) -> [Element] {
        let empty = ChatTimelineReferenceCapture.descendants(host, NSTextView.self).filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.string.isEmpty && $0.textStorage?.length == 0
        }.map { ChatTimelineParityLayout.frame($0.bounds, from: $0, in: host) }
        return elements.map { original in
            guard original.text == "", empty.contains(original.frame) else { return original }
            var result = original
            result.role = "empty-text"; result.text = nil; result.textRuns = nil
            return result
        }
    }

    /// Use the real AppKit control action. An invisible window's AX press return
    /// value is not an accessibility certification; state transitions are checked.
    static func click(_ title: String, in view: NSView) throws {
        let button = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(view, NSButton.self).first {
            !$0.isHiddenOrHasHiddenAncestor && ($0.title == title || $0.accessibilityLabel() == title)
        }, "Missing actual native button: " + title)
        XCTAssertTrue(button.isEnabled)
        button.performClick(nil)
    }

    static func symbolObservations(_ cards: [ChatNativeAttachmentCard]) -> [[String: Any]] {
        cards.compactMap { card in
            guard let plan = card.plan else { return nil }
            let image = plan.file.isImage ? card.imageButton.failureSymbol : card.document.image
            guard let image else { return nil }
            return ["attachmentID": plan.file.id, "symbol": plan.file.isImage ? "photo.badge.exclamationmark" : "doc.text",
                "size": NSStringFromSize(image.size), "alignmentRect": NSStringFromRect(image.alignmentRect),
                "viewFrame": NSStringFromRect(plan.file.isImage ? card.imageButton.failureDrawingRect : card.document.frame)]
        }
    }

    static func replySymbolObservations(_ replies: ChatNativeReplySummaryView) -> [String: String] {
        guard let symbol = replies.parityChevron else { return [:] }
        // The frame is its actual layout slot; the full bitmap still draws the
        // image through the production path using its separate drawingFrame.
        return ["size": NSStringFromSize(symbol.image.size), "alignmentRect": NSStringFromRect(symbol.image.alignmentRect),
            "frame": NSStringFromRect(symbol.frame), "drawingFrame": NSStringFromRect(symbol.drawingFrame)]
    }

    static func avatar(_ view: ChatNativeAvatarView, shell: ChatNativeShellCell? = nil,
                       in host: NSView) throws -> Element {
        let placeholder = try XCTUnwrap(view.parityPlaceholder)
        let id = "w06/avatar/\(placeholder.stableID)/\(placeholder.name)/\(Int(view.bounds.width))"
        var element = Element(id: id, role: "avatar",
            frame: ChatTimelineParityLayout.frame(view.bounds, from: view, in: host))
        guard view.parityImage == nil else { return element }
        let attributed = try XCTUnwrap(shell?.avatarText ?? view.parityText)
        let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let foreground = try XCTUnwrap(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let white = try ChatTimelineParityLayout.color(foreground, in: host)
        let drawingView: NSView = shell.map { $0 as NSView } ?? view
        let clip = shell?.avatarTextClip ?? view.parityTextClip
        let bounds = shell?.avatarTextTypographicFrame ?? view.parityTextTypographicFrame
        let ink = try drawingInk(view: drawingView, bounds: clip, in: host) { context in
            if let shell { shell.drawAvatarText(in: context) }
            else { view.drawFallbackText(in: context) }
        }
        element.text = attributed.string
        element.colorTokens = ["foreground": white]
        element.srgbTokens = ["fill": try XCTUnwrap(view.parityFillRGB)]
        element.textRuns = [.init(location: 0, length: attributed.length, font: .init(font),
            colors: [NSAttributedString.Key.foregroundColor.rawValue: white],
            rasterBounds: [ChatTimelineParityLayout.frame(bounds, from: drawingView, in: host)], inkMasks: [ink])]
        return element
    }

    static func control(_ view: NSView, id: String, colors: [String: NSColor] = [:], in host: NSView) throws -> Element {
        Element(id: id, role: "control", frame: ChatTimelineParityLayout.frame(view.bounds, from: view, in: host),
            colorTokens: try colors.mapValues { try ChatTimelineParityLayout.color($0, in: host) })
    }

    private static func text(_ attributed: NSAttributedString, view: NSView, id: String,
                             drawing: CGRect? = nil, elementFrame: CGRect? = nil,
                             in host: NSView, draw: () -> Void) throws -> Element {
        let drawing = drawing ?? view.bounds
        let frame = ChatTimelineParityLayout.frame(drawing, from: view, in: host)
        let storage = NSTextStorage(attributedString: attributed), manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: drawing.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let maximumNumberOfLines = (view as? ChatNativeLabel)?.maximumNumberOfLines ?? 0
        container.maximumNumberOfLines = maximumNumberOfLines
        if maximumNumberOfLines > 0 { container.lineBreakMode = .byTruncatingTail }
        storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        var lines: [Metadata.Line] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
            let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines.append(.init(location: range.location, length: range.length))
        }
        let foreground = try XCTUnwrap(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let ink = try drawingInk(view: view, bounds: view.bounds, in: host) { _ in draw() }
        var runs = try ChatTimelineParityLayout.labelRuns(attributed, drawingFrame: frame, in: host,
            maximumNumberOfLines: maximumNumberOfLines)
        for index in runs.indices { runs[index].inkMasks = [ink] }
        return Element(id: id, role: "text", frame: ChatTimelineParityLayout.frame(elementFrame ?? view.bounds, from: view, in: host),
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
            throw ChatTimelineParityLayout.failure("Cannot observe native media text ink")
        }
        context.translateBy(x: -pixels.minX, y: pixels.maxY)
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { draw(context) }
        let image = try XCTUnwrap(context.makeImage())
        let origin = ChatTimelineParityLayout.frame(CGRect(x: pixels.minX / scale, y: pixels.minY / scale,
            width: pixels.width / scale, height: pixels.height / scale), from: view, in: host).origin
        return try ChatTimelineParityLayout.inkMask(image, origin: origin, scale: scale)
    }
}

/// The same real owner/session route used by production Save. Both hosts remain
/// terminal-free; NativeTabEngine only contains the selected fixture content.
@MainActor final class W06CaptureOwners {
    private let previousContent = NativeTabEngine.content
    private let previousStores = TabRouter.shared.stores
    private let store: WorkspaceStore
    private var contents: [UUID: AnyView] = [:]
    private var closed = false
    init() {
        store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            engineFactory: { XCTFail("W06 Save must never create a terminal"); return TestEngine() })
        NativeTabEngine.content = { [weak self] state in
            guard case .unavailable(let id) = state.route else { return AnyView(Color.clear) }
            return self?.contents[id] ?? AnyView(Color.clear)
        }
        let fixtureStore = store
        TabRouter.shared.stores = { [fixtureStore] }
    }
    func host(_ content: AnyView, dark: Bool, width: CGFloat) throws -> ChatQuietHost {
        let id = UUID()
        contents[id] = AnyView(content.environment(\.colorScheme, dark ? .dark : .light))
        let session = store.openToolTab(.unavailable(id))
        let engine = try XCTUnwrap(session.engine as? NativeTabEngine)
        XCTAssertFalse(session.hasProcess); XCTAssertEqual(engine.starts, 0)
        return ChatQuietHost(view: engine.view, dark: dark, width: width, height: 600)
    }
    func close() {
        guard !closed else { return }; closed = true
        store.terminate(); NativeTabEngine.content = previousContent; TabRouter.shared.stores = previousStores
        contents.removeAll()
    }
}

struct W06NativeMediaHost: NSViewRepresentable {
    let view: NativeChatTimelineContainer
    func makeNSView(context: Context) -> NativeChatTimelineContainer { view }
    func updateNSView(_ nsView: NativeChatTimelineContainer, context: Context) {}
}

/// Public sheet callback interception, as in ChatQuietSavePanel. Verify dispatch
/// before mounting Save controls, never invoke original presentation, and limit
/// all destinations to this run's explicit evidence root.
@MainActor final class W06CaptureSavePanel {
    private typealias Reply = @convention(block) (Int) -> Void
    private struct Request { let panel: NSSavePanel; let window: NSWindow; let reply: Reply }
    private static var active = false
    private var overrides: [ChatQuietMethodOverride] = []
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var requests: [Request] = []
    private let expectedName: String
    private(set) var calls = 0
    private var closed = false
    var pending: Int { requests.count }
    var outputs: [URL] { destinations.values.filter { FileManager.default.fileExists(atPath: $0.path) } }
    init(directory: URL, expectedName: String) throws {
        self.expectedName = expectedName
        guard !Self.active else { throw ChatTimelineParityLayout.failure("Overlapping W06 save-panel adapters") }
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["AGENTPAD_CHAT_PARITY_EVIDENCE"]))
        guard directory.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw ChatTimelineParityLayout.failure("W06 save destination must stay in fixture evidence storage")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.active = true
        do {
            let probe = NSSavePanel()
            defer { probe.close() }
            let concrete: AnyClass = type(of: probe)
            let types: [AnyClass] = ObjectIdentifier(concrete) == ObjectIdentifier(NSSavePanel.self) ? [NSSavePanel.self] : [concrete, NSSavePanel.self]
            let begin: @convention(block) (NSSavePanel, NSWindow, @escaping Reply) -> Void = { [weak self] panel, window, reply in
                guard let self, !self.closed else { reply(NSApplication.ModalResponse.cancel.rawValue); return }
                XCTAssertEqual(panel.nameFieldStringValue, expectedName)
                self.calls += 1
                self.destinations[ObjectIdentifier(panel)] = directory.appendingPathComponent("save-\(self.calls).txt")
                self.requests.append(Request(panel: panel, window: window, reply: reply))
            }
            let destination: @convention(block) (NSSavePanel) -> NSURL? = { [weak self] panel in
                self?.destinations[ObjectIdentifier(panel)] as NSURL?
            }
            for type in types {
                overrides.append(try ChatQuietMethodOverride(type, NSSelectorFromString("beginSheetModalForWindow:completionHandler:"), block: begin))
                overrides.append(try ChatQuietMethodOverride(type, NSSelectorFromString("URL"), block: destination))
            }
            let fresh = NSSavePanel()
            defer { fresh.close() }
            for receiver in [probe, fresh] {
                for selector in [NSSelectorFromString("beginSheetModalForWindow:completionHandler:"), NSSelectorFromString("URL")] {
                    guard overrides.contains(where: { $0.isInstalled(on: receiver, selector: selector) }) else {
                        throw ChatTimelineParityLayout.failure("Unsupported NSSavePanel dispatch; W06 Save must not run")
                    }
                }
            }
        } catch { close(); throw error }
    }
    func complete(_ response: NSApplication.ModalResponse, for window: NSWindow) throws {
        let index = try XCTUnwrap(requests.firstIndex { $0.window === window }, "No held production Save request for window")
        let request = requests.remove(at: index)
        XCTAssertEqual(request.panel.nameFieldStringValue, expectedName)
        XCTAssertNil(window.attachedSheet)
        request.reply(response.rawValue)
    }
    func close() {
        guard !closed else { return }; closed = true
        let pending = requests; requests.removeAll()
        pending.forEach { $0.reply(NSApplication.ModalResponse.cancel.rawValue) }
        overrides.reversed().forEach { $0.close() }; overrides.removeAll(); destinations.removeAll()
        Self.active = false
    }
}

/// Controlled fixture transfer. Loading captures retain a real pending request;
/// no worker sleep, network access, spinner replacement or animation reset.
final class W06CapturePreviewProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static let delivery = DispatchQueue(label: "w06-capture-preview")
    nonisolated(unsafe) private static var held = false
    nonisolated(unsafe) private static var answer: Result<ChatStubProtocol.Answer, URLError> = .failure(URLError(.unsupportedURL))
    nonisolated(unsafe) private static var pending: [ObjectIdentifier: W06CapturePreviewProtocol] = [:]
    private let completionLock = NSLock()
    private var stopped = false
    private var delivered = false

    static func configure(held: Bool, failure: Bool, bytes: Data, headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        self.held = held
        answer = failure ? .failure(URLError(.cannotDecodeContentData)) : .success(.init(status: 200, headers: headers, body: bytes))
    }
    static func release() {
        lock.lock()
        held = false
        let requests = Array(pending.values), result = answer
        pending.removeAll()
        lock.unlock()
        for request in requests { delivery.async { request.complete(result) } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.path.hasSuffix("/preview") == true || request.url?.path.hasSuffix("/original") == true
                || request.url?.path.contains("/avatar") == true else {
            Self.delivery.async { self.complete(.failure(URLError(.unsupportedURL))) }
            return
        }
        Self.lock.lock()
        if Self.held {
            Self.pending[ObjectIdentifier(self)] = self
            Self.lock.unlock()
        } else {
            let result = Self.answer
            Self.lock.unlock()
            Self.delivery.async { self.complete(result) }
        }
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
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
