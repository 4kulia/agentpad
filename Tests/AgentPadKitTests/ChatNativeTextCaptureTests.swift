import AppKit
import AgentPadQuietTestSupport
import Observation
import SwiftUI
import XCTest
@testable import AgentPadKit

/// Native text lifecycle, per-message selection and rendered mutation guards.
/// Historical whole-row SwiftUI pairs remain in the external W03/W09 archive.
@MainActor final class ChatNativeTextCaptureTests: XCTestCase {
    private typealias S = NativeTimelineSnapshot

    func testW03StableBodyMountMatchesActualLegacySizingAndCapture() async throws {
        try await bodyLifecycle(lateAddresses: false)
    }

    func testW03LateAddressUpdatesMatchActualLegacySizingAndCapture() async throws {
        try await bodyLifecycle(lateAddresses: true)
    }

    private func bodyLifecycle(lateAddresses: Bool) async throws {
        XCTAssertTrue(APQuietIsEnabled())
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce(); _ = NSApplication.shared
        let cases = [
            ("headings", "# Heading one\n## Heading two\n### Heading three\n#### Heading four\n##### Heading five\n###### Heading six\n\nParagraph after headings."),
            ("selection", "Selectable **native text**, @anna, and a [checked link](https://example.com/reference).")
        ]
        var records: [[String: Any]] = []
        let output = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_PARITY_EVIDENCE"].map {
            URL(fileURLWithPath: $0).appendingPathComponent(lateAddresses ? "body-lifecycle-late" : "body-lifecycle-stable")
        }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for dark in [false, true] {
            for width in ChatNativeParityCaptureWidths.standard {
                let inThread = ChatNativeParityCaptureWidths.inThread(width)
                let referenceWidth = ChatNativeParityCaptureWidths.reference(width)
                let bodyWidth = width - (inThread ? 80 : 92)
                let fontSize: CGFloat = inThread ? 13 : 14
                for (name, markdown) in cases {
                    let input = W03BodyLifecycleInput(addresses: lateAddresses ? [] : ["anna"])
                    let legacyHost = ChatQuietHost(content: AnyView(W03BodyLifecycleSharedText(input: input,
                        markdown: markdown, width: bodyWidth, fontSize: fontSize)),
                        dark: dark, width: width, height: 600)
                    let adapter = ChatTimelineAdapter(), layout = ChatTimelineLayout()
                    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("w03-body-lifecycle-\(UUID())")
                    let model = ChatTimelineW01Model(directory: scratch)
                    model.isDM = true
                    let native = ChatNativeShellCell(kind: .message)
                    let nativeHost = ChatQuietHost(view: native, dark: dark, width: width, height: 600)
                    defer {
                        adapter.invalidate(); legacyHost.close(); nativeHost.close()
                        try? FileManager.default.removeItem(at: scratch)
                    }
                    var message = ChatTimelineW01.message("body-lifecycle-" + name); message.text = markdown
                    model.feed.messages = [message]
                    var previousAddresses: [String]?
                    var previousRevision: UInt64?
                    func configure() throws {
                        let style = ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
                            increasedContrast: false, alwaysShowTime: false)
                        let snapshot = adapter.snapshot(model: model, root: inThread ? message.id : nil,
                            members: ChatTimelineW01.members,
                            mentionable: input.addresses.enumerated().map { ("address-\($0.offset)", $0.element) },
                            me: "w01-me", archived: false, ownerModel: nil, style: style, now: ChatTimelineW01.day)
                        let row = try XCTUnwrap(snapshot.rows.first { $0.messageID == message.id })
                        if let previousAddresses, let previousRevision, previousAddresses != input.addresses {
                            XCTAssertNotEqual(row.contentRevision, previousRevision,
                                "Every changed legacy address input must reach the native body, including unmatched addresses")
                        }
                        previousAddresses = input.addresses; previousRevision = row.contentRevision
                        let size = ChatTimelineWidth(width, scale: 2)
                        native.configure(row: row, epoch: snapshot.presentationEpoch,
                            plan: layout.plan(row, snapshot: snapshot, width: size),
                            content: layout.content(row, snapshot: snapshot, width: size))
                    }
                    try await legacyHost.settle()
                    try configure(); try await nativeHost.settle()
                    let legacy = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(legacyHost.view, NSTextView.self).first)
                    var lastAttributedInput = ChatMentionText.attributed(markdown, addresses: input.addresses,
                        fontSize: fontSize)
                    let stages = lateAddresses ? ["initial", "mention-arrived", "unmatched-address-arrived", "unchanged-repaint"]
                        : ["initial", "unchanged-repaint"]
                    for stage in stages {
                        if stage == "mention-arrived" { input.addresses = ["anna"] }
                        if stage == "unmatched-address-arrived" { input.addresses = ["anna", "unused-address"] }
                        if stage != "initial" {
                            let attributed = ChatMentionText.attributed(markdown, addresses: input.addresses,
                                fontSize: fontSize)
                            if stage == "unmatched-address-arrived" {
                                XCTAssertEqual(attributed, lastAttributedInput,
                                    "A changed address input must refresh legacy even when rendered attributes are equal")
                            }
                            lastAttributedInput = attributed
                            try await legacyHost.settle()
                            try configure(); try await nativeHost.settle()
                        }
                        if name == "selection" {
                            let selection = NSRange(location: 0, length: 16)
                            if stage == "initial" {
                                APQuietSelectWindow(legacyHost.window)
                                XCTAssertTrue(legacyHost.window.makeFirstResponder(legacy))
                                legacy.setSelectedRange(selection)
                                APQuietSelectWindow(nativeHost.window)
                                XCTAssertTrue(nativeHost.window.makeFirstResponder(native.body))
                                native.body.setSelectedRange(selection)
                            }
                            XCTAssertEqual(legacy.selectedRange(), selection, "Legacy selection survives \(stage)")
                            XCTAssertEqual(native.body.selectedRange(), selection, "Native selection survives \(stage)")
                        }
                        func bitmap(_ text: NSTextView) throws -> NSBitmapImageRep {
                            let image = try ChatTimelineCaptureColor.bitmap(text)
                            return image
                        }
                        APQuietSelectWindow(legacyHost.window)
                        let current = ChatTimelineParityMetadata(elements: [
                            .init(id: "viewport", role: "viewport", frame: legacy.bounds),
                            try ChatTimelineParityLayout.text(legacy, id: "body", in: legacy)
                        ])
                        let expected = try bitmap(legacy)
                        APQuietSelectWindow(nativeHost.window)
                        let candidate = ChatTimelineParityMetadata(elements: [
                            .init(id: "viewport", role: "viewport", frame: native.body.bounds),
                            try ChatTimelineParityLayout.text(native.body, id: "body", in: native.body)
                        ])
                        let actual = try bitmap(native.body)
                        XCTAssertEqual(legacy.bounds.width, bodyWidth, "Actual legacy body width follows its rendered pane")
                        XCTAssertEqual(native.body.bounds.width, bodyWidth, "Actual native body width follows its rendered pane")
                        if !lateAddresses && !ChatNativeParityCaptureWidths.narrow && referenceWidth == 420 {
                            let expectedHeight: CGFloat = name == "headings" ? 137 : 20
                            XCTAssertEqual(legacy.frame.height, expectedHeight, "Stable legacy reservation: \(name), \(stage)")
                            XCTAssertEqual(native.body.frame.height, expectedHeight, "Stable native reservation: \(name), \(stage)")
                        }
                        let result = ChatTimelineParity.compare(currentLayout: current, candidateLayout: candidate,
                            current: try .init(expected), candidate: try .init(actual))
                        let id = "\(name)-\(Int(width))-\(dark ? "dark" : "light")-\(stage)"
                        XCTAssertEqual(current, candidate, "Exact legacy body lifecycle geometry: \(id)")
                        XCTAssertTrue(result.passes, "Legacy body lifecycle capture: \(id)")
                        if let output {
                            for (suffix, image) in [("current", expected), ("candidate", actual)] {
                                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(
                                    to: output.appendingPathComponent("\(id)-\(suffix).png"), options: .withoutOverwriting)
                            }
                        }
                        records.append(["id": id,
                            "fixture": ["width": width, "referenceWidth": referenceWidth, "inThread": inThread,
                                "bodyWidth": bodyWidth, "fontSize": fontSize, "dark": dark, "stage": stage],
                            "current": try Self.jsonObject(current),
                            "candidate": try Self.jsonObject(candidate), "result": try Self.jsonObject(result)])
                    }
                }
            }
        }
        XCTAssertEqual(records.count, lateAddresses ? 32 : 16)
        if let output {
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(
                to: output.appendingPathComponent("pairs.json"), options: .withoutOverwriting)
        }
        XCTAssertNil(APQuietFailure())
    }


    func testW03MouseSelectionStaysWithinOneNativeMessage() async throws {
        XCTAssertTrue(APQuietIsEnabled())
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce(); _ = NSApplication.shared
        for width: CGFloat in [760, 420] {
            var first = ChatTimelineW01.message("selection-first")
            first.text = "Select this message and [web](https://example.com)."
            var second = ChatTimelineW01.message("selection-second", seq: 2)
            second.text = "The next message has its own selection."
            let style = ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
                increasedContrast: false, alwaysShowTime: false)
            let snapshot = ChatTimelineSnapshotBuilder().build(ChatTimelineW01.input(
                messages: [ChatTimelineW01.content(first), ChatTimelineW01.content(second)],
                root: width == 420 ? first.id : nil, style: style))
            let coordinator = NativeChatTimelineCoordinator(), view: NativeChatTimelineContainer
            view = NativeChatTimelineContainer(coordinator: coordinator)
            let host = ChatQuietHost(view: view, dark: false, width: width, height: 600)
            defer { coordinator.dispose(); host.close() }
            view.update(snapshot); try await host.settle()
            let cells = try [first.id, second.id].map { id in
                let index = try XCTUnwrap(coordinator.rows.firstIndex { $0.messageID == id })
                return try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? ChatNativeShellCell)
            }
            let text = cells[0].body, next = cells[1].body
            let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
            manager.ensureLayout(for: container)
            func point(_ character: Int, middle: Bool = false) -> CGPoint {
                let glyph = manager.glyphRange(forCharacterRange: NSRange(location: character, length: 1), actualCharacterRange: nil)
                let bounds = manager.boundingRect(forGlyphRange: glyph, in: container)
                return text.convert(CGPoint(x: middle ? bounds.midX : bounds.minX + 0.1, y: bounds.midY), to: nil)
            }
            XCTAssertTrue(host.window.makeFirstResponder(text))
            try Self.mouse(from: point(0), to: point(6), window: host.window)
            XCTAssertTrue(host.window.firstResponder === text)
            XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 6))
            XCTAssertEqual(next.selectedRange().length, 0)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            XCTAssertTrue(text.writeSelection(to: board, types: text.writablePasteboardTypes))
            XCTAssertEqual(board.string(forType: .string), "Select")
            try Self.mouse(from: point(0), to: next.convert(CGPoint(x: 80, y: 10), to: nil), window: host.window)
            XCTAssertEqual(next.selectedRange().length, 0, "Dragging into another row cannot create cross-row selection")
            XCTAssertEqual(coordinator.tableView.numberOfSelectedRows, 0)
            XCTAssertNil(APQuietFailure())
        }
    }

    private static func mouse(from start: CGPoint, to end: CGPoint?, window: NSWindow) throws {
        // Track real NSTextView selection through the hit-tested native view.
        // The quiet window cannot receive hardware mouse input. Tracking-mode
        // timers deliver the synthetic drag/up only after mouseDown starts.
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ location: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: time + (type == .leftMouseUp ? 0.02 : type == .leftMouseDragged ? 0.01 : 0), windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        let up = try event(.leftMouseUp, end ?? start)
        let drag = try end.map { try event(.leftMouseDragged, $0) }
        let sender = W03MouseEvents(up: up, drag: drag)
        let timer = Timer(timeInterval: 0.02, target: sender, selector: #selector(W03MouseEvents.post), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }
        try XCTUnwrap(window.contentView?.hitTest(start)).mouseDown(with: event(.leftMouseDown, start))
    }

    func testW03ParityGateRejectsRenderedMutationsAndRestores() async throws {
        XCTAssertTrue(APQuietIsEnabled())
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce(); _ = NSApplication.shared
        var message = ChatTimelineW01.message("parity-mutations")
        message.text = String(repeating: "The measured body keeps its real line breaks and insets. ", count: 8)
        let style = ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
            increasedContrast: false, alwaysShowTime: false)
        let snapshot = ChatTimelineSnapshotBuilder().build(ChatTimelineW01.input(
            messages: [ChatTimelineW01.content(message)], style: style))
        let coordinator = NativeChatTimelineCoordinator()
        let view = NativeChatTimelineContainer(coordinator: coordinator)
        let host = ChatQuietHost(view: view, dark: false, width: 760, height: 600)
        defer { coordinator.dispose(); host.close() }
        view.update(snapshot); try await host.settle()
        let rowIndex = try XCTUnwrap(coordinator.rows.firstIndex { $0.messageID == message.id })
        let cell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? ChatNativeShellCell)
        let original = try ChatTimelineParityLayout.snapshot(coordinator: coordinator, in: view)
        let bitmap = try ChatTimelineCaptureColor.bitmap(view)
        let raster = try ChatTimelineParity.Raster(bitmap)
        let bodyFrame = cell.body.frame
        let container = try XCTUnwrap(cell.body.textContainer)
        let containerSize = container.containerSize
        let headerText = cell.header.text
        let changedColor = NSMutableAttributedString(attributedString: headerText)
        changedColor.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: changedColor.length))
        let headerFont = try XCTUnwrap(headerText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let changedWeight = NSMutableAttributedString(attributedString: headerText)
        changedWeight.addAttribute(.font, value: ChatNativeTextStyle.font(style.metrics.displayFont, size: headerFont.pointSize),
            range: NSRange(location: 0, length: changedWeight.length))
        let changedSize = NSMutableAttributedString(attributedString: headerText)
        changedSize.addAttribute(.font, value: try XCTUnwrap(NSFont(descriptor: headerFont.fontDescriptor, size: headerFont.pointSize + 1)),
            range: NSRange(location: 0, length: changedSize.length))
        let mutations: [(String, () -> Void, () -> Void)] = [
            ("one-point-frame-shift", { cell.body.frame.origin.x += 1 }, { cell.body.frame = bodyFrame }),
            ("changed-line-break", { container.containerSize.width = containerSize.width / 2 }, { container.containerSize = containerSize }),
            ("changed-colour-token", { cell.header.text = changedColor }, { cell.header.text = headerText }),
            ("changed-font-weight", { cell.header.text = changedWeight }, { cell.header.text = headerText }),
            ("one-point-font-size", { cell.header.text = changedSize }, { cell.header.text = headerText }),
            ("missing-element", { cell.header.isHidden = true }, { cell.header.isHidden = false })
        ]
        var records: [[String: Any]] = []
        for (name, mutate, restore) in mutations {
            mutate()
            let changed = try ChatTimelineParityLayout.snapshot(coordinator: coordinator, in: view)
            // Keep the bitmap identical to prove each failure comes from live
            // metadata, independent of the glyph rasterization allowance.
            let result = ChatTimelineParity.compare(currentLayout: original, candidateLayout: changed,
                current: raster, candidate: raster)
            if name == "changed-line-break" {
                let bodyID = "message:" + message.id + "/body"
                XCTAssertNotEqual(original.elements.first { $0.id == bodyID }?.lineBreaks,
                    changed.elements.first { $0.id == bodyID }?.lineBreaks)
            }
            restore()
            let restored = try ChatTimelineParityLayout.snapshot(coordinator: coordinator, in: view)
            let restoredResult = ChatTimelineParity.compare(currentLayout: original, candidateLayout: restored,
                current: raster, candidate: raster)
            XCTAssertFalse(result.passes, "The gate must reject \(name)")
            XCTAssertEqual(result.bitmap.differentPixels, 0, "This mutation isolates metadata from raster changes")
            XCTAssertTrue(restoredResult.passes, "Restoring \(name) must restore exact parity")
            records.append(["mutation": name, "rejected": !result.passes, "restored": restoredResult.passes,
                            "before": try Self.jsonObject(original), "mutated": try Self.jsonObject(changed),
                            "after": try Self.jsonObject(restored)])
        }
        if let path = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_PARITY_EVIDENCE"] {
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(
                to: URL(fileURLWithPath: path).appendingPathComponent("mutation-results.json"))
        }
        XCTAssertEqual(records.count, 6)
        XCTAssertNil(APQuietFailure())
    }

    func testW03ParityGateRejectsTemporaryDisplayColourMutationsAndRestores() async throws {
        XCTAssertTrue(APQuietIsEnabled())
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce(); _ = NSApplication.shared
        let settings = AgentPadSettingsModel.shared
        let previous = (settings.appearanceMode, settings.lightTerminalThemeSelection, settings.pairedThemeSchemaEnabled)
        settings.prepareFirstLaunchAppearance()
        settings.appearanceMode = .light
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        defer {
            if !previous.2 { settings.load() }
            settings.appearanceMode = previous.0; settings.lightTerminalThemeSelection = previous.1
        }
        var message = ChatTimelineW01.message("display-colour-mutations")
        message.text = "Selected text and [linked words](https://example.com) keep their displayed colours."
        let style = ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
            increasedContrast: false, alwaysShowTime: false)
        let snapshot = ChatTimelineSnapshotBuilder().build(ChatTimelineW01.input(
            messages: [ChatTimelineW01.content(message)], style: style))
        let coordinator = NativeChatTimelineCoordinator()
        let view = NativeChatTimelineContainer(coordinator: coordinator)
        let host = ChatQuietHost(view: view, dark: false, width: 760, height: 600)
        defer { coordinator.dispose(); host.close() }
        view.update(snapshot); try await host.settle()
        let row = try XCTUnwrap(coordinator.rows.firstIndex { $0.messageID == message.id })
        let cell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ChatNativeShellCell)
        let body = cell.body, bodyID = "message:" + message.id + "/body"
        XCTAssertTrue(host.window.makeFirstResponder(body))
        body.setSelectedRange(NSRange(location: 0, length: 8))
        try await host.settle()
        let linkAttributes = body.linkTextAttributes, selectionAttributes = body.selectedTextAttributes
        defer { body.linkTextAttributes = linkAttributes; body.selectedTextAttributes = selectionAttributes }
        let original = try ChatTimelineParityLayout.snapshot(coordinator: coordinator, in: view)
        let originalStorage = NSAttributedString(attributedString: try XCTUnwrap(body.textStorage))
        func raster() throws -> ChatTimelineParity.Raster {
            let bitmap = try ChatTimelineCaptureColor.bitmap(view)
            return try ChatTimelineParity.Raster(bitmap)
        }
        let before = try raster()
        let linkRange = (body.string as NSString).range(of: "linked words")
        XCTAssertNotEqual(linkRange.location, NSNotFound)
        var records: [[String: Any]] = []
        for name in ["link-text-colour", "selected-text-colour", "selected-storage-colour"] {
            let selection = name != "link-text-colour", storageMutation = name == "selected-storage-colour"
            let attributes = selection ? selectionAttributes : (linkAttributes ?? [:])
            let oldValue = storageMutation ? originalStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                : attributes[.foregroundColor]
            let oldInput = try XCTUnwrap(oldValue as? NSColor)
            let oldColor = try ChatTimelineParityLayout.color(oldInput, in: view)
            let position = selection ? 0 : linkRange.location
            let originalRun = try XCTUnwrap(original.elements.first { $0.id == bodyID }?.textRuns?.first {
                NSLocationInRange(position, NSRange(location: $0.location, length: $0.length))
            })
            let token = (storageMutation ? "" : selection ? "selection." : "link.") + NSAttributedString.Key.foregroundColor.rawValue
            XCTAssertEqual(originalRun.colors[token], oldColor)
            if selection { XCTAssertEqual(originalRun.length, 8, "The selection endpoint must split the displayed run") }
            var changedAttributes = attributes
            let changedColor = NSColor(srgbRed: oldColor.red + (oldColor.red < 0.5 ? 1 : -1) / 255,
                green: oldColor.green, blue: oldColor.blue, alpha: oldColor.alpha)
            changedAttributes[.foregroundColor] = changedColor
            if storageMutation {
                body.textStorage?.addAttribute(.foregroundColor, value: changedColor, range: body.selectedRange())
            } else if selection { body.selectedTextAttributes = changedAttributes } else { body.linkTextAttributes = changedAttributes }
            body.needsDisplay = true
            try await host.settle()
            let changed = try ChatTimelineParityLayout.snapshot(coordinator: coordinator, in: view)
            let changedPixels = ChatTimelineParity.exactDifference(before, try raster())
            let result = ChatTimelineParity.compare(currentLayout: original, candidateLayout: changed,
                current: before, candidate: before)
            if !storageMutation { XCTAssertEqual(body.textStorage, originalStorage, "Display overrides must leave storage unchanged") }
            XCTAssertGreaterThan(changedPixels, 0, "The mutated property must affect the actual rendered text")
            XCTAssertFalse(result.passes, "A one-channel 1/255 display colour change must fail exact metadata")
            XCTAssertEqual(result.bitmap.differentPixels, 0, "Identical bitmaps isolate the exact colour-token check")
            body.linkTextAttributes = linkAttributes; body.selectedTextAttributes = selectionAttributes
            if storageMutation { body.textStorage?.addAttribute(.foregroundColor, value: oldInput, range: body.selectedRange()) }
            body.needsDisplay = true
            try await host.settle()
            let restored = try ChatTimelineParityLayout.snapshot(coordinator: coordinator, in: view)
            let restoredResult = ChatTimelineParity.compare(currentLayout: original, candidateLayout: restored,
                current: before, candidate: before)
            XCTAssertTrue(restoredResult.passes)
            XCTAssertEqual(ChatTimelineParity.exactDifference(before, try raster()), 0)
            records.append(["mutation": name, "rejected": !result.passes, "restored": restoredResult.passes,
                "changedPixels": changedPixels, "before": try Self.jsonObject(original),
                "mutated": try Self.jsonObject(changed), "after": try Self.jsonObject(restored)])
        }
        if let path = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_PARITY_EVIDENCE"] {
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(
                to: URL(fileURLWithPath: path).appendingPathComponent("display-colour-mutation-results.json"))
        }
        XCTAssertEqual(records.count, 3)
        XCTAssertNil(APQuietFailure())
    }

    func testW09ParserBoundaryUsesNativeRowsAtTheSharedMarkdownLimit() throws {
        AgentPadFonts.registerOnce()
        for width: CGFloat in [760, 420] {
            for offset in [-1, 0, 1] {
                let size = 128 * 1024 + offset
                let prefix = "**Boundary marker**\n\n", padding = size - prefix.utf8.count
                var message = ChatTimelineW01.message("parser-\(offset)")
                message.text = prefix + String(repeating: "a ", count: padding / 2) + (padding.isMultiple(of: 2) ? "" : "a")
                XCTAssertEqual(message.text.utf8.count, size)
                let snapshot = ChatTimelineSnapshotBuilder().build(ChatTimelineW01.input(
                    messages: [ChatTimelineW01.content(message)], root: width == 420 ? message.id : nil))
                let row = try XCTUnwrap(snapshot.rows.first { $0.messageID == message.id })
                let engine = ChatTimelineLayout(), normalized = ChatTimelineWidth(width, scale: 2)
                let plan = engine.plan(row, snapshot: snapshot, width: normalized)
                let cell = ChatNativeShellCell(kind: .message)
                defer { cell.unbind() }
                cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: plan,
                    content: engine.content(row, snapshot: snapshot, width: normalized), actions: nil)
                XCTAssertTrue(cell.body.string.hasPrefix(offset > 0 ? "**Boundary marker**" : "Boundary marker"))
                XCTAssertTrue(cell.body.isSelectable); XCTAssertFalse(cell.body.isEditable)
            }
        }
    }

    private static func jsonObject(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}

@MainActor @Observable private final class W03BodyLifecycleInput {
    var addresses: [String]
    init(addresses: [String]) { self.addresses = addresses }
}

private struct W03BodyLifecycleSharedText: View {
    var input: W03BodyLifecycleInput
    let markdown: String
    let width: CGFloat
    let fontSize: CGFloat
    var body: some View {
        ChatMentionText(markdown: markdown, addresses: input.addresses, fontSize: fontSize)
            .frame(width: width).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}


@MainActor private final class W03MouseEvents: NSObject {
    let up: NSEvent
    let drag: NSEvent?
    init(up: NSEvent, drag: NSEvent?) { self.up = up; self.drag = drag }
    @objc func post() {
        NSApp.postEvent(up, atStart: true)
        if let drag { NSApp.postEvent(drag, atStart: true) }
    }
}
