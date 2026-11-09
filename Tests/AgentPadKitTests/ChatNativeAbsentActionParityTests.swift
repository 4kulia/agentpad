import AppKit
import AgentPadQuietTestSupport
import GRDB
import ObjectiveC.runtime
import Quartz
import XCTest
@testable import AgentPadKit

@MainActor final class ChatNativeAbsentActionParityTests: XCTestCase {
    private var fixtures: [ChatNativeActionFixture] = []
    private var previousWindow: NSWindow?

    override func setUp() async throws {
        guard APQuietIsEnabled() else { throw NSError(domain: "Quiet harness required", code: 1) }
        _ = NSApplication.shared
        previousWindow = NSApp.keyWindow
    }

    override func tearDown() async throws {
        for fixture in fixtures.reversed() {
            fixture.base.service.attachmentManagers.values.forEach { $0.revoke() }
            await fixture.close()
        }
        fixtures = []
        if let previousWindow { APQuietSelectWindow(previousWindow) }
        previousWindow = nil
        XCTAssertNil(APQuietFailure())
    }

    private func mounted() async throws -> (ChatNativeActionFixture, ChatNativeShellCell) {
        let fixture = try await ChatNativeActionFixture()
        fixtures.append(fixture)
        fixture.host.window.setContentSize(NSSize(width: 760, height: 600))
        let base = fixture.base
        let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        base.service.serverCapabilities[base.key.server] = ["chat.attachments", "chat.attachments_context", "chat.channel_ux1"]
        base.service.serverAttachmentLimits[base.key.server] = limits
        base.service.isServerKnown = { _, _ in true }
        let image = ChatAttachment(attachmentId: UUID().uuidString.lowercased(), position: 0,
            name: "absence-image.png", mime: "image/png", size: 1024, hasPreview: false,
            width: 320, height: 160)
        let file = ChatAttachment(attachmentId: UUID().uuidString.lowercased(), position: 1,
            name: "quiet-notes.txt", mime: "text/plain", size: 128, hasPreview: false)
        let message = try XCTUnwrap(fixture.messages.first)
        let fields: [String: Any] = [
            "message_id": message.id, "channel_id": message.channelId,
            "author_account_id": base.key.accountId, "seq": try XCTUnwrap(message.seq),
            "created_at": message.createdAt, "revision": 4, "text": message.text,
            "attachments": try [image, file].map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        ]
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: fields))
        try await base.store.queue.write { _ = try ChatMessages.write($0, wire) }
        try await fixture.settle()
        let cell = try fixture.row(message.id)
        cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.model.message(message.id)?.attachments.map(\.id), [image.id, file.id])
        XCTAssertEqual(cell.attachments.cards.compactMap { $0.plan?.file.id }, [image.id, file.id])
        let imageCard = try XCTUnwrap(cell.attachments.cards.first)
        let fileCard = try XCTUnwrap(cell.attachments.cards.dropFirst().first)
        XCTAssertTrue(imageCard.imageButton.isEnabled)
        XCTAssertTrue(fileCard.download.isEnabled)
        XCTAssertFalse(imageCard.imageButton.isHidden)
        XCTAssertFalse(fileCard.document.isHidden)
        XCTAssertTrue(ChatTimelineReferenceCapture.descendants(cell, NSView.self)
            .allSatisfy { !String(reflecting: type(of: $0)).contains("Hosting") })
        return (fixture, cell)
    }

    func testNativeAttachmentSpaceDoesNotRequestQuickLook() async throws {
        let (fixture, cell) = try await mounted()
        let panel = try ChatQuietSavePanel(directory: fixture.directory.appendingPathComponent("space-save"))
        defer { panel.close() }
        let guardrail = try W09AbsentActionBoundary()
        defer { guardrail.close() }
        let actions = try XCTUnwrap(fixture.adapter.actions)
        let originalViewer = actions.attachmentViewer
        defer { actions.attachmentViewer = originalViewer }
        var opened: [String] = []
        actions.attachmentViewer = { key, message, file in
            XCTAssertEqual(key, fixture.base.key)
            opened.append(message.id + "/" + file.id)
        }
        let originalQuickLookExists = QLPreviewPanel.sharedPreviewPanelExists()
        let image = cell.attachments.cards[0], file = cell.attachments.cards[1]
        for control in [image.imageButton as NSView, file.download as NSView] {
            try guardrail.verify(on: control, window: fixture.host.window)
            try W09AbsentInput.space(on: control, in: fixture.host)
            try await fixture.host.settle()
            while panel.pending > 0 { try panel.complete(.cancel) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: panel.output.path))
            XCTAssertEqual(guardrail.quickLookRequests, 0)
            XCTAssertTrue(guardrail.exports.isEmpty)
            XCTAssertEqual(QLPreviewPanel.sharedPreviewPanelExists(), originalQuickLookExists)
        }
        let beforeClick = opened.count
        image.imageButton.performClick(nil)
        XCTAssertEqual(opened.count, beforeClick + 1)
        let message = try XCTUnwrap(fixture.messages.first)
        let imageID = try XCTUnwrap(image.plan?.file.id)
        XCTAssertTrue(opened.allSatisfy { $0 == message.id + "/" + imageID })
        XCTAssertEqual(guardrail.quickLookRequests, 0)
        XCTAssertNil(APQuietFailure())
    }

    func testNativeAttachmentDragDoesNotExportFileURLOrPromise() async throws {
        let (fixture, cell) = try await mounted()
        let panel = try ChatQuietSavePanel(directory: fixture.directory.appendingPathComponent("drag-save"))
        defer { panel.close() }
        let guardrail = try W09AbsentActionBoundary()
        defer { guardrail.close() }
        let actions = try XCTUnwrap(fixture.adapter.actions)
        let originalViewer = actions.attachmentViewer
        defer { actions.attachmentViewer = originalViewer }
        actions.attachmentViewer = { _, _, file in XCTAssertTrue(file.isImage) }
        let image = cell.attachments.cards[0].imageButton
        let document = cell.attachments.cards[1].document
        for (target, point) in [
            (image as NSView, NSPoint(x: image.bounds.width / 4, y: image.bounds.height / 4)),
            (document as NSView, NSPoint(x: document.bounds.midX, y: document.bounds.midY))
        ] {
            try guardrail.verify(on: target, window: fixture.host.window)
            try W09AbsentInput.drag(target, point: point, in: fixture.host)
            try await fixture.host.settle()
            while panel.pending > 0 { try panel.complete(.cancel) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: panel.output.path))
            XCTAssertTrue(guardrail.fileExports.isEmpty, guardrail.fileExports.map(\.description).joined(separator: "\n"))
            XCTAssertEqual(guardrail.quickLookRequests, 0)
        }
        let text = cell.body, pasteboard = NSPasteboard.withUniqueName()
        let previousSelection = text.selectedRange(), previousResponder = fixture.host.window.firstResponder
        defer {
            text.setSelectedRange(previousSelection)
            _ = fixture.host.window.makeFirstResponder(previousResponder)
            pasteboard.releaseGlobally()
        }
        let selected = NSRange(location: 0, length: 4)
        XCTAssertGreaterThanOrEqual((text.string as NSString).length, NSMaxRange(selected))
        XCTAssertTrue(fixture.host.window.makeFirstResponder(text))
        text.setSelectedRange(selected)
        XCTAssertTrue(text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), (text.string as NSString).substring(with: selected))
        XCTAssertEqual(text.selectedRange(), selected)
        XCTAssertNil(APQuietFailure())
    }

    func testQuietAbsenceInterceptorsDetectQuickLookAndFileExports() async throws {
        let guardrail = try W09AbsentActionBoundary()
        defer { guardrail.close() }
        let target = W09AbsentSensitivityView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        let host = ChatQuietHost(view: target, dark: false, width: 240, height: 160)
        defer { host.close() }
        try await host.settle()
        try guardrail.verify(on: target, window: host.window)
        let originalQuickLookExists = QLPreviewPanel.sharedPreviewPanelExists()
        try W09AbsentInput.space(on: target, in: host)
        XCTAssertEqual(target.spaceEvents, 1)
        XCTAssertEqual(guardrail.quickLookRequests, 1)
        XCTAssertEqual(QLPreviewPanel.sharedPreviewPanelExists(), originalQuickLookExists)
        let promiseDelegate = W09AbsentPromiseDelegate()
        let promise = NSFilePromiseProvider(fileType: "public.plain-text", delegate: promiseDelegate)
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("w09-absent-sensitivity-\(UUID()).txt")
        let writers: [any NSPasteboardWriting] = [localURL as NSURL, promise]
        for writer in writers {
            target.writer = writer
            let before = guardrail.fileExports.count
            try W09AbsentInput.drag(target, point: NSPoint(x: 20, y: 20), in: host)
            XCTAssertEqual(guardrail.fileExports.count, before + 1)
        }
        XCTAssertEqual(target.downEvents, 2)
        XCTAssertEqual(target.dragStarts, 2)
        XCTAssertEqual(target.upEvents, 2)
        XCTAssertEqual(guardrail.fileExports.count, 2)
        let urlExport = try XCTUnwrap(guardrail.fileExports.first)
        let promiseExport = try XCTUnwrap(guardrail.fileExports.dropFirst().first)
        XCTAssertTrue(urlExport.types.contains(NSPasteboard.PasteboardType.fileURL.rawValue))
        XCTAssertTrue(promiseExport.promiseProvider)
        XCTAssertEqual(promiseDelegate.writeRequests, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertNil(APQuietFailure())
    }
}

@MainActor private final class W09AbsentActionBoundary {
    struct Export {
        let route: String
        let types: Set<String>
        let promiseProvider: Bool
        let explicitFile: Bool
        var isFile: Bool {
            explicitFile || promiseProvider || types.contains(NSPasteboard.PasteboardType.fileURL.rawValue)
                || types.contains("NSFilenamesPboardType") || types.contains("NSFilesPromisePboardType")
                || types.contains { $0.hasPrefix("com.apple.pasteboard.promised-file") }
        }
        var description: String { "\(route): \(types.sorted()), promiseProvider=\(promiseProvider), explicitFile=\(explicitFile)" }
    }
    private static var active = false
    private let pasteboard = NSPasteboard.withUniqueName()
    private var overrides: [ChatQuietMethodOverride] = []
    private var closed = false
    private(set) var quickLookRequests = 0
    private(set) var exports: [Export] = []
    var fileExports: [Export] { exports.filter(\.isFile) }
    private let begin = NSSelectorFromString("beginDraggingSessionWithItems:event:source:")
    private let legacy = NSSelectorFromString("dragImage:at:offset:event:pasteboard:source:slideBack:")

    init() throws {
        guard APQuietIsEnabled(), !Self.active else { throw NSError(domain: "Overlapping or non-quiet absence interception", code: 1) }
        Self.active = true
        do {
            let quickLook: @convention(block) (AnyObject) -> QLPreviewPanel? = { [weak self] _ in
                MainActor.assumeIsolated { self?.quickLookRequests += 1; return nil }
            }
            overrides.append(try ChatQuietMethodOverride(try XCTUnwrap(object_getClass(QLPreviewPanel.self)),
                NSSelectorFromString("sharedPreviewPanel"), block: quickLook))
            let modern: @convention(block) (AnyObject, NSArray, NSEvent, AnyObject) -> NSDraggingSession? = { [weak self] _, items, _, _ in
                MainActor.assumeIsolated { self?.record(items, route: "beginDraggingSessionWithItems:event:source:") }
                return nil
            }
            let old: @convention(block) (AnyObject, NSImage, NSPoint, NSSize, NSEvent, NSPasteboard, AnyObject, Bool) -> Void = {
                [weak self] _, _, _, _, _, pasteboard, _, _ in
                MainActor.assumeIsolated {
                    self?.exports.append(Export(route: "dragImage", types: Set((pasteboard.types ?? []).map(\.rawValue)),
                        promiseProvider: false, explicitFile: false))
                }
            }
            for type: AnyClass in [NSView.self, NSWindow.self] {
                overrides.append(try ChatQuietMethodOverride(type, begin, block: modern))
                overrides.append(try ChatQuietMethodOverride(type, legacy, block: old))
            }
            let file: @convention(block) (NSView, NSString, NSRect, Bool, NSEvent) -> Bool = { [weak self] _, _, _, _, _ in
                MainActor.assumeIsolated {
                    self?.exports.append(Export(route: "dragFile", types: [], promiseProvider: false, explicitFile: true))
                    return false
                }
            }
            overrides.append(try ChatQuietMethodOverride(NSView.self,
                NSSelectorFromString("dragFile:fromRect:slideBack:event:"), block: file))
            let promise: @convention(block) (NSView, NSArray, NSRect, AnyObject, Bool, NSEvent) -> Bool = { [weak self] _, _, _, _, _, _ in
                MainActor.assumeIsolated {
                    self?.exports.append(Export(route: "dragPromisedFilesOfTypes", types: [], promiseProvider: true, explicitFile: true))
                    return false
                }
            }
            overrides.append(try ChatQuietMethodOverride(NSView.self,
                NSSelectorFromString("dragPromisedFilesOfTypes:fromRect:source:slideBack:event:"), block: promise))
        } catch { close(); throw error }
    }

    private func record(_ items: NSArray, route: String) {
        for item in items {
            guard let dragging = item as? NSDraggingItem, let writer = dragging.item as? any NSPasteboardWriting else {
                XCTFail("A drag entry contained an uninspectable writer")
                exports.append(Export(route: route, types: [], promiseProvider: false, explicitFile: true))
                continue
            }
            exports.append(Export(route: route, types: Set(writer.writableTypes(for: pasteboard).map(\.rawValue)),
                promiseProvider: writer is NSFilePromiseProvider, explicitFile: (writer as? NSURL)?.isFileURL == true))
        }
    }

    func verify(on view: NSView, window: NSWindow) throws {
        let shared = NSSelectorFromString("sharedPreviewPanel")
        guard overrides.contains(where: { $0.isInstalled(on: QLPreviewPanel.self, selector: shared) }) else {
            throw NSError(domain: "Quick Look entry is not intercepted", code: 1)
        }
        for receiver: AnyObject in [view, window] {
            for selector in [begin, legacy] {
                guard overrides.contains(where: { $0.isInstalled(on: receiver, selector: selector) }) else {
                    throw NSError(domain: "Actual drag receiver bypasses the public interception", code: 1)
                }
            }
        }
        for selector in [NSSelectorFromString("dragFile:fromRect:slideBack:event:"),
                         NSSelectorFromString("dragPromisedFilesOfTypes:fromRect:source:slideBack:event:")] {
            guard overrides.contains(where: { $0.isInstalled(on: view, selector: selector) }) else {
                throw NSError(domain: "Actual legacy file-drag receiver bypasses interception", code: 1)
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        overrides.reversed().forEach { $0.close() }
        overrides = []
        pasteboard.releaseGlobally()
        Self.active = false
    }
}

@MainActor private enum W09AbsentInput {
    // AppKit's queued mouse events normalize eventNumber to signed 16 bits.
    // Keep owned fixture IDs representable so delivery checks remain exact.
    private static var serial = 19_550

    static func space(on view: NSView, in host: ChatQuietHost) throws {
        guard view.window === host.window, !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else {
            throw NSError(domain: "Space target is not a visible mounted attachment control", code: 1)
        }
        let previous = host.window.firstResponder
        defer { _ = host.window.makeFirstResponder(previous) }
        APQuietSelectWindow(host.window)
        guard host.window.makeFirstResponder(view), host.window.firstResponder === view else {
            throw NSError(domain: "The actual attachment control did not acquire keyboard focus", code: 1)
        }
        var observed: [NSEvent.EventType] = []
        let monitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            MainActor.assumeIsolated {
                if event.windowNumber == host.window.windowNumber, event.keyCode == 49 {
                    XCTAssertTrue(host.window.firstResponder === view)
                    observed.append(event.type)
                }
            }
            return event
        })
        defer { NSEvent.removeMonitor(monitor) }
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            APQuietSendEvent(event, host.window)
        }
        XCTAssertEqual(observed, [.keyDown, .keyUp])
    }

    static func drag(_ target: NSView, point: NSPoint, in host: ChatQuietHost) throws {
        guard target.window === host.window, target.visibleRect.contains(point),
              !target.isHiddenOrHasHiddenAncestor else { throw NSError(domain: "Drag target is not visible", code: 1) }
        let content = try XCTUnwrap(host.window.contentView)
        let start = target.convert(point, to: nil)
        let contentPoint = content.convert(start, from: nil)
        let hit = try XCTUnwrap(content.hitTest(content.convert(contentPoint, to: content.superview)))
        guard hit === target || hit.isDescendant(of: target) else {
            throw NSError(domain: "Drag starts outside the actual attachment hit target", code: 1)
        }
        let end = content.convert(NSPoint(x: content.bounds.maxX - 8, y: content.bounds.maxY - 8), to: nil)
        XCTAssertGreaterThan(hypot(end.x - start.x, end.y - start.y), 40)
        let reader = try W09AbsentEventReads()
        defer { reader.close() }
        let previous = host.window.firstResponder
        defer { _ = host.window.makeFirstResponder(previous) }
        APQuietSelectWindow(host.window)
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ location: NSPoint) throws -> NSEvent {
            serial += 1
            let offset: TimeInterval = type == .leftMouseUp ? 0.02 : type == .leftMouseDragged ? 0.01 : 0
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: time + offset, windowNumber: host.window.windowNumber, context: nil,
                eventNumber: serial, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        let down = try event(.leftMouseDown, start)
        let dragged = try event(.leftMouseDragged, end)
        let up = try event(.leftMouseUp, end)
        let tail = [dragged, up], owned = Set(tail.map(\.eventNumber))
        let sender = W09AbsentMouseTail(events: tail)
        let timer = Timer(timeInterval: 0.02, target: sender, selector: #selector(W09AbsentMouseTail.post), userInfo: nil, repeats: false)
        var direct: Set<Int> = []
        func receipt(_ stage: String) {
            let value: [String: Any] = ["stage": stage, "target": String(reflecting: type(of: target)),
                "hit": String(reflecting: type(of: hit)), "window": host.window.windowNumber,
                "down": down.eventNumber, "expectedTail": owned.sorted(), "timerPosted": sender.posted,
                "trackingConsumed": owned.intersection(reader.consumed).sorted(), "directlyDelivered": direct.sorted()]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                FileHandle.standardOutput.write(Data(("W09_ABSENT_INPUT " + json + "\n").utf8))
            }
        }
        // Same input boundary as the frozen W03 real native selection helper:
        // call the actual hit receiver, then let its AppKit tracking loop read
        // real NSEvents. No default-mode event pump or NSApp.currentEvent shim.
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer {
            timer.invalidate()
            // No queue event exists in the nontracking path. On a failed
            // tracking path remove only our remaining tail, preserving other
            // events rather than dispatching an incomplete gesture later.
            if sender.posted && !owned.isSubset(of: reader.consumed) {
                var unrelated: [NSEvent] = []
                while let pending = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                    until: .distantPast, inMode: .eventTracking, dequeue: true) {
                    if pending.windowNumber != host.window.windowNumber || !owned.contains(pending.eventNumber) {
                        unrelated.append(pending)
                    }
                }
                unrelated.reversed().forEach { NSApp.postEvent($0, atStart: true) }
                receipt("failed-tracking-queue-cleaned")
            }
        }
        receipt("before-hit-mouseDown")
        hit.mouseDown(with: down)
        timer.invalidate()
        receipt("after-hit-mouseDown")
        if !sender.posted {
            // AppKit captures a nontracking mouse stream at the initial hit
            // receiver. Exercise its actual responder methods, not a proxy.
            receipt("before-direct-mouseDragged")
            hit.mouseDragged(with: dragged)
            direct.insert(dragged.eventNumber)
            receipt("after-direct-mouseDragged")
            hit.mouseUp(with: up)
            direct.insert(up.eventNumber)
        }
        let consumedByTracking = owned.intersection(reader.consumed)
        guard owned.isSubset(of: consumedByTracking.union(direct)) else {
            receipt("incomplete-delivery")
            XCTFail("Every drag/up must reach real tracking or the hit receiver; expected \(owned.sorted()), tracking \(consumedByTracking.sorted()), direct \(direct.sorted())")
            throw NSError(domain: "Incomplete owned drag event delivery", code: 1)
        }
        receipt("complete")
        XCTAssertNil(APQuietFailure())
    }

}

@MainActor private final class W09AbsentMouseTail: NSObject {
    let events: [NSEvent]
    private(set) var posted = false
    init(events: [NSEvent]) { self.events = events }
    @objc func post() {
        posted = true
        events.reversed().forEach { NSApp.postEvent($0, atStart: true) }
    }
}

@MainActor private final class W09AbsentEventReads {
    typealias Read = @convention(c) (AnyObject, Selector, UInt64, NSDate?, NSString, Bool) -> Unmanaged<NSEvent>?
    typealias ReadOne = @convention(c) (AnyObject, Selector, UInt64) -> Unmanaged<NSEvent>?
    typealias TrackHandler = @convention(block) (NSEvent?, UnsafeMutablePointer<ObjCBool>) -> Void
    typealias Track = @convention(c) (AnyObject, Selector, UInt64, Double, NSString, TrackHandler) -> Void
    private var overrides: [ChatQuietMethodOverride] = []
    private(set) var consumed: Set<Int> = []
    init() throws {
        do {
            let readSelector = NSSelectorFromString("nextEventMatchingMask:untilDate:inMode:dequeue:")
            for type: AnyClass in [NSApplication.self, NSWindow.self] {
                let method = try XCTUnwrap(class_getInstanceMethod(type, readSelector))
                let original = unsafeBitCast(method_getImplementation(method), to: Read.self)
                let block: @convention(block) (AnyObject, UInt64, NSDate?, NSString, Bool) -> NSEvent? = {
                    [weak self] receiver, mask, date, mode, dequeue in
                    let event = original(receiver, readSelector, mask, date, mode, dequeue)?.takeUnretainedValue()
                    if dequeue, let event, [.leftMouseDragged, .leftMouseUp].contains(event.type) {
                        MainActor.assumeIsolated { _ = self?.consumed.insert(event.eventNumber) }
                    }
                    return event
                }
                overrides.append(try ChatQuietMethodOverride(type, readSelector, block: block))
            }
            let singleSelector = NSSelectorFromString("nextEventMatchingMask:")
            let singleMethod = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, singleSelector))
            let singleOriginal = unsafeBitCast(method_getImplementation(singleMethod), to: ReadOne.self)
            let single: @convention(block) (AnyObject, UInt64) -> NSEvent? = { [weak self] receiver, mask in
                let event = singleOriginal(receiver, singleSelector, mask)?.takeUnretainedValue()
                if let event, [.leftMouseDragged, .leftMouseUp].contains(event.type) {
                    MainActor.assumeIsolated { _ = self?.consumed.insert(event.eventNumber) }
                }
                return event
            }
            overrides.append(try ChatQuietMethodOverride(NSWindow.self, singleSelector, block: single))
            let selector = NSSelectorFromString("trackEventsMatchingMask:timeout:mode:handler:")
            let method = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, selector))
            let original = unsafeBitCast(method_getImplementation(method), to: Track.self)
            let block: @convention(block) (AnyObject, UInt64, Double, NSString, @escaping TrackHandler) -> Void = {
                [weak self] receiver, mask, timeout, mode, handler in
                let observed: TrackHandler = { [weak self] event, stop in
                    if let event, [.leftMouseDragged, .leftMouseUp].contains(event.type) {
                        MainActor.assumeIsolated { _ = self?.consumed.insert(event.eventNumber) }
                    }
                    handler(event, stop)
                }
                original(receiver, selector, mask, timeout, mode, observed)
            }
            overrides.append(try ChatQuietMethodOverride(NSWindow.self, selector, block: block))
        } catch { close(); throw error }
    }
    func close() { overrides.reversed().forEach { $0.close() }; overrides = [] }
}

@MainActor private final class W09AbsentSensitivityView: NSView, NSDraggingSource {
    var writer: (any NSPasteboardWriting)?
    private(set) var spaceEvents = 0
    private(set) var downEvents = 0
    private(set) var dragStarts = 0
    private(set) var upEvents = 0
    private var started = false
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 49 else { super.keyDown(with: event); return }
        spaceEvents += 1
        _ = QLPreviewPanel.shared()
    }
    override func mouseDown(with event: NSEvent) { downEvents += 1; started = false }
    override func mouseDragged(with event: NSEvent) {
        guard !started, let writer else { return }
        started = true; dragStarts += 1
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 20, height: 20),
            contents: NSImage(size: NSSize(width: 20, height: 20)))
        _ = beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) { upEvents += 1 }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

private final class W09AbsentPromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    var writeRequests: Int { lock.lock(); defer { lock.unlock() }; return writes }
    @MainActor func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "absent-action-sensitivity.txt"
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        lock.lock(); writes += 1; lock.unlock()
        completionHandler(NSError(domain: "Sensitivity fixture must never write a promised file", code: 1))
    }
}
