import AppKit
import AgentPadQuietTestSupport
import ObjectiveC.runtime
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor final class ChatQuietMethodOverride {
    private let method: Method
    private let original: IMP
    private let replacement: IMP
    private var closed = false
    init(_ type: AnyClass, _ selector: Selector, block: Any) throws {
        guard APQuietIsEnabled() else { throw NSError(domain: "Quiet override requires test containment", code: 1) }
        let inherited = try XCTUnwrap(class_getInstanceMethod(type, selector))
        class_addMethod(type, selector, method_getImplementation(inherited), method_getTypeEncoding(inherited))
        method = try XCTUnwrap(class_getInstanceMethod(type, selector))
        original = method_getImplementation(method)
        replacement = imp_implementationWithBlock(block)
        method_setImplementation(method, replacement)
    }
    func close() {
        guard !closed else { return }
        closed = true
        method_setImplementation(method, original)
        imp_removeBlock(replacement)
    }
    func isInstalled(on receiver: AnyObject, selector: Selector) -> Bool {
        guard let type = object_getClass(receiver), let current = class_getMethodImplementation(type, selector) else { return false }
        return unsafeBitCast(current, to: UInt.self) == unsafeBitCast(replacement, to: UInt.self)
    }
}

@MainActor final class ChatQuietSavePanel {
    typealias Reply = @convention(block) (Int) -> Void
    struct Request {
        let panel: NSSavePanel
        let window: NSWindow
        let reply: Reply
    }
    private static var active = false
    private var overrides: [ChatQuietMethodOverride] = []
    private var urls: [ObjectIdentifier: URL] = [:]
    private(set) var requests: [Request] = []
    private(set) var calls = 0
    private let destination: URL
    private var closed = false

    init(directory: URL) throws {
        guard !Self.active else { throw NSError(domain: "Overlapping save-panel adapters", code: 1) }
        guard directory.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/") else {
            throw NSError(domain: "Panel destination must be fixture temporary storage", code: 1)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        destination = directory.appendingPathComponent("saved-fixture.txt")
        Self.active = true
        do {
            // Inspect only a public, unordered receiver. Never call AppKit's
            // original presentation method to discover a concrete implementation.
            let probe = NSSavePanel()
            defer { probe.close() }
            let concrete: AnyClass = type(of: probe)
            let types: [AnyClass] = ObjectIdentifier(concrete) == ObjectIdentifier(NSSavePanel.self)
                ? [NSSavePanel.self] : [concrete, NSSavePanel.self]
            let begin: @convention(block) (NSSavePanel, NSWindow, @escaping Reply) -> Void = { [weak self] panel, window, reply in
                guard let self, !self.closed else { reply(NSApplication.ModalResponse.cancel.rawValue); return }
                self.calls += 1
                self.urls[ObjectIdentifier(panel)] = self.destination
                self.requests.append(Request(panel: panel, window: window, reply: reply))
            }
            let url: @convention(block) (NSSavePanel) -> NSURL? = { [weak self] panel in
                self?.urls[ObjectIdentifier(panel)] as NSURL?
            }
            for type in types {
                let selector = NSSelectorFromString("beginSheetModalForWindow:completionHandler:")
                let sheet = try ChatQuietMethodOverride(type, selector, block: begin)
                overrides.append(sheet)
                let destination = try ChatQuietMethodOverride(type, NSSelectorFromString("URL"), block: url)
                overrides.append(destination)
                if ObjectIdentifier(type) == ObjectIdentifier(concrete) {
                    guard sheet.isInstalled(on: probe, selector: selector),
                          destination.isInstalled(on: probe, selector: NSSelectorFromString("URL")) else {
                        throw NSError(domain: "Panel adapter dispatch was not installed on public receiver", code: 1)
                    }
                }
            }
            // Check a second public constructor receiver before any production
            // content is mounted or any Save action can run. Unsupported public
            // entry dispatch is a hard error, never a fallback to AppKit.
            let fresh = NSSavePanel()
            defer { fresh.close() }
            for selector in [NSSelectorFromString("beginSheetModalForWindow:completionHandler:"), NSSelectorFromString("URL")] {
                guard overrides.contains(where: { $0.isInstalled(on: fresh, selector: selector) }) else {
                    throw NSError(domain: "Unsupported NSSavePanel entry dispatch; native Save must not run", code: 1)
                }
            }
        } catch {
            close()
            throw error
        }
    }
    var pending: Int { requests.count }
    var output: URL { destination }
    func complete(_ response: NSApplication.ModalResponse) throws {
        guard !requests.isEmpty else { throw NSError(domain: "No held fixture panel", code: 1) }
        let request = requests.removeFirst()
        XCTAssertEqual(request.panel.nameFieldStringValue, "quiet-notes.txt")
        XCTAssertFalse(APQuietWindowHasOSFocus(request.window))
        XCTAssertNil(request.window.attachedSheet, "Adapter must not start a real sheet")
        request.reply(response.rawValue)
    }
    func close() {
        guard !closed else { return }
        closed = true
        let pending = requests
        requests.removeAll()
        pending.forEach { $0.reply(NSApplication.ModalResponse.cancel.rawValue) }
        overrides.reversed().forEach { $0.close() }
        overrides.removeAll()
        urls.removeAll()
        Self.active = false
    }
}

@MainActor final class ChatQuietTraits {
    private static var active = false
    private var overrides: [ChatQuietMethodOverride] = []
    var accent: NSColor
    var increased: Bool
    private var closed = false
    init(accent: NSColor, increased: Bool) throws {
        guard !Self.active else { throw NSError(domain: "Overlapping sampled trait adapters", code: 1) }
        self.accent = accent; self.increased = increased
        Self.active = true
        do {
            let accentGetter: @convention(block) (AnyObject) -> NSColor = { [weak self] _ in self?.accent ?? .systemBlue }
            overrides.append(try ChatQuietMethodOverride(try XCTUnwrap(object_getClass(NSColor.self)),
                NSSelectorFromString("controlAccentColor"), block: accentGetter))
            let contrastGetter: @convention(block) (NSWorkspace) -> Bool = { [weak self] _ in self?.increased ?? false }
            overrides.append(try ChatQuietMethodOverride(NSWorkspace.self,
                NSSelectorFromString("accessibilityDisplayShouldIncreaseContrast"), block: contrastGetter))
        } catch {
            close()
            throw error
        }
    }
    func close() {
        guard !closed else { return }
        closed = true
        overrides.reversed().forEach { $0.close() }
        overrides.removeAll()
        Self.active = false
    }
}

@MainActor final class ChatQuietHost {
    let window: NSWindow
    let view: NSView
    /// Observe the actual child window created by a production popup without
    /// moving its content into a replacement canvas or ordering another window.
    init(observing window: NSWindow, capturingFullWindow: Bool = false) throws {
        XCTAssertTrue(APQuietIsEnabled())
        self.window = window
        let content = try XCTUnwrap(window.contentView)
        if capturingFullWindow {
            // NSPopover's contentView may be inset inside its actual frame;
            // SwiftUI's contentView can already include that same surrounding
            // area. Observe the outermost existing view spanning this window.
            // No synthesized wrapper, padding, crop or coordinate adjustment.
            let windowBounds = window.convertFromScreen(window.frame)
            var ancestor: NSView? = content, fullFrame: NSView?
            var observed: [String] = []
            while let current = ancestor, current.window === window {
                let frame = current.convert(current.bounds, to: nil)
                observed.append(String(reflecting: type(of: current)) + " " + NSStringFromRect(frame))
                if frame == windowBounds { fullFrame = current }
                ancestor = current.superview
            }
            view = try XCTUnwrap(fullFrame, "No actual full-window capture root: " + observed.joined(separator: "; "))
            XCTAssertTrue(content === view || content.isDescendant(of: view))
            XCTAssertEqual(view.convert(view.bounds, to: nil), windowBounds)
        } else { view = content }
        APQuietSelectWindow(window)
    }
    init(view: NSView, dark: Bool, width: CGFloat = 760, height: CGFloat = 260) {
        self.view = view
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.colorSpace = ChatTimelineCaptureColor.colorSpace
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        APQuietSelectWindow(window)
    }
    convenience init(content: AnyView, dark: Bool, width: CGFloat = 760, height: CGFloat = 260) {
        self.init(view: NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light)),
            dark: dark, width: width, height: height)
    }
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(70))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(APQuietWindowHasOSFocus(window))
        XCTAssertNil(APQuietFailure())
    }
    var nodes: [NSObject] { ChatTimelineReferenceCapture.accessibilityNodes(window) }
    var strings: [String] {
        nodes.flatMap { node in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap {
            ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String
        } }
    }
    func control(_ title: String) throws -> NSObject {
        try XCTUnwrap(nodes.first { node in
            ["accessibilityLabel", "accessibilityTitle"].contains {
                ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String == title
            }
        }, "Missing production control: \(title)")
    }
    func enabled(_ title: String) throws -> Bool {
        let node = try control(title)
        if let control = node as? NSControl { return control.isEnabled }
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        if node.responds(to: legacy), let value = node.perform(legacy, with: "AXEnabled")?.takeUnretainedValue() as? NSNumber {
            return value.boolValue
        }
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard node.responds(to: selector) else { throw NSError(domain: "Control has no public AX enabled getter: " + title, code: 1) }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: selector), to: Getter.self)(node, selector)
    }
    func press(_ title: String, diagnosticContext: String? = nil) throws {
        XCTAssertTrue(try enabled(title))
        XCTAssertTrue(ChatTimelineReferenceCapture.press(title, window: window, diagnosticContext: diagnosticContext),
            "Actual AX action failed: \(title)")
    }
    func snapshot(_ capture: ChatTimelineReferenceCapture?, id: String, labels: [String], dark: Bool, messages: [ChatMessage],
                  detail: [String: Any] = [:]) throws {
        guard let capture else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try ChatTimelineCaptureColor.bitmap(view)
        var metadata = detail
        metadata["fixtureValues"] = try messages.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        metadata["stateLabels"] = labels
        metadata["nativeAccessibilityStrings"] = strings
        metadata["panelPixels"] = false
        metadata["menuPixels"] = false
        metadata["tooltipPixels"] = false
        try capture.write(bitmap, id: id + (dark ? "-dark" : "-light"), inventory: [],
            width: view.bounds.width, height: view.bounds.height, dark: dark,
            scale: window.backingScaleFactor, detail: metadata)
    }
    func close() {
        window.contentView = nil
        window.close()
    }
}
