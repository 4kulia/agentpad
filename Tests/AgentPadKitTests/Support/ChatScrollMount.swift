import AppKit
import AgentPadQuietTestSupport
import GRDB
import Observation
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor protocol ChatScrollControlling: AnyObject {
    var scroll: NSScrollView? { get }
    var following: Bool { get }
    var atBottom: Bool { get }
    func stopFollowing(preservingAnchor: Bool)
    func jumpToBottom()
}
extension ChatScrollControlling {
    func stopFollowing() { stopFollowing(preservingAnchor: false) }
}
extension ChatTimelineScrollController: ChatScrollControlling {}

@MainActor protocol ChatScrollMountAdapter {
    var name: String { get }
    func timeline(model: any ChatConversationPresentation, root: String?, probe: ChatScrollProbe) -> AnyView
    func viewport(in host: NSView, probe: ChatScrollProbe) throws -> any ChatScrollControlling
    func belongs(_ view: NSTextView, to messageID: String, probe: ChatScrollProbe) -> Bool
}

@MainActor struct ChatScrollNativeAdapter: ChatScrollMountAdapter {
    let name = "native-product"
    func timeline(model: any ChatConversationPresentation, root: String?, probe: ChatScrollProbe) -> AnyView {
        AnyView(ChatTimelineView(model: model, root: root, members: [], mentionable: [],
            me: model.key.accountId, archived: false, ownerModel: nil))
    }
    func viewport(in host: NSView, probe: ChatScrollProbe) throws -> any ChatScrollControlling {
        let view = try XCTUnwrap(ChatScrollMounted<ChatScrollFixture>.descendants(host, NativeChatTimelineContainer.self).first)
        probe.frameProvider = { [weak coordinator = view.coordinator] in coordinator?.scrollController.bodyFrames ?? [:] }
        probe.messageFrameProvider = { [weak coordinator = view.coordinator] id in
            guard let controller = coordinator?.scrollController, let frame = controller.bodyFrame(id), let scroll = controller.scroll else { return nil }
            return frame.offsetBy(dx: -scroll.contentView.bounds.minX, dy: -scroll.contentView.bounds.minY)
        }
        return view.coordinator.scrollController
    }
    func belongs(_ view: NSTextView, to messageID: String, probe: ChatScrollProbe) -> Bool {
        (view.superview as? ChatNativeShellCell)?.binding?.id.kind == .message(messageID)
    }
}

@MainActor enum ChatScrollMounts {
    static var benchmark: (any ChatScrollMountAdapter)? {
        guard let name = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_BENCH_RENDERER"] else { return nil }
        switch name {
        case "native-product": return ChatScrollNativeAdapter()
        default: preconditionFailure("Unknown benchmark renderer: \(name)")
        }
    }
    static var bothPanes: [(String?, any ChatScrollMountAdapter)] {
        let adapters: [any ChatScrollMountAdapter] = benchmark.map { [$0] } ?? [ChatScrollNativeAdapter()]
        return adapters.flatMap { adapter in
            [(nil, adapter), ("fixture-root", adapter)]
        }
    }
}

@MainActor final class ChatScrollProbe {
    var frameProvider: (() -> [String: CGRect])?
    var messageFrameProvider: ((String) -> CGRect?)?
    func frame(_ id: String) -> CGRect? { messageFrameProvider?(id) ?? frames[id] }
    weak var scroll: NSScrollView?
    var frames: [String: CGRect] { frameProvider?() ?? [:] }
    var samples: [[String: Any]] = []
}

@MainActor final class ChatScrollMounted<Model: ChatConversationPresentation> {
    let model: Model
    let adapter: any ChatScrollMountAdapter
    let probe = ChatScrollProbe()
    let host: NSHostingView<AnyView>
    let window: NSWindow
    var scroll: NSScrollView!
    var viewport: (any ChatScrollControlling)!
    init(model: Model, root: String?, resizable: Bool = false, adapter: any ChatScrollMountAdapter = ChatScrollNativeAdapter()) throws {
        guard APQuietIsEnabled() else { throw NSError(domain: "Quiet harness required", code: 1) }
        ChatScrollAppKitSettings.install()
        AgentPadFonts.registerOnce()
        self.model = model
        self.adapter = adapter
        let probe = probe
        host = NSHostingView(rootView: AnyView(adapter.timeline(model: model, root: root, probe: probe)
            .frame(width: resizable ? nil : (root == nil ? 760 : 420), height: 600)))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: root == nil ? 760 : 420, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.layoutSubtreeIfNeeded()
        ChatScrollAppKitSettings.apply(to: host)
        APQuietSelectWindow(window)
        settle()
        viewport = try adapter.viewport(in: host, probe: probe)
        scroll = try XCTUnwrap(viewport.scroll)
        probe.scroll = scroll
        ChatScrollAppKitSettings.apply(to: host)
        _ = ChatScrollAppKitSettings.snapshot(scroll)
    }
    static func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }
    func settle() {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.010))
        }
        host.layoutSubtreeIfNeeded()
    }
    func close() {
        host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
        window.contentView = nil; window.close()
    }
    func clickEarlierButton() throws {
        // Timeline top padding (16) + button vertical padding (8) +
        // half its 11-point label. Route only to the quiet fixture window.
        let point = host.convert(NSPoint(x: host.bounds.midX, y: 31), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            APQuietSendEvent(event, window)
        }
    }
    func anchor() -> (String, CGRect)? {
        probe.frames.filter { $0.value.maxY > 20 && $0.value.minY < 580 }
            .min { $0.value.minY < $1.value.minY }.map { ($0.key, $0.value) }
    }
    func drive(_ workload: ChatScrollWorkload) throws {
        for direction: Int32 in [-1, 1] {
            for step in workload.events(direction: direction) {
                try event(step.requested, phase: step.phase, decaying: step.decaying, precise: step.precise)
            }
            settle()
        }
    }
    func recordFixture(_ workload: ChatScrollWorkload, root: String?, prefix: String = "") throws {
        try ChatScrollRecords.writeFixture(model.conversationMessages(root: root), workload: workload, root: root,
            settings: ChatScrollAppKitSettings.snapshot(scroll), renderer: adapter.name, prefix: prefix)
    }
    func event(_ delta: Int32, phase: Int64, decaying: Bool = false, precise: Bool = true) throws {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -delta, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        // AppKit ignores CG momentum phases in the invisible test window.
        // Exercise a decaying precise gesture instead; the evidence labels
        // it separately and does not claim hardware momentum coverage.
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        let center = window.convertPoint(toScreen: NSPoint(x: window.frame.width / 2, y: window.frame.height / 2))
        cg.location = CGPoint(x: center.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - center.y)
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertEqual(event.hasPreciseScrollingDeltas, precise)
        if precise { XCTAssertEqual(event.scrollingDeltaY, CGFloat(-delta), accuracy: 0.001) }
        let before = probe.frames.filter { $0.value.maxY > 20 && $0.value.minY < 580 }
            .sorted { $0.value.minY < $1.value.minY }
        let views = Self.descendants(host, NSTextView.self)
        let native = before.compactMap { id, frame -> (String, NSTextView, CGFloat)? in
            guard let view = views.first(where: {
                let y = $0.convert(.zero, to: host).y
                return !$0.string.isEmpty && y >= frame.minY - 0.5 && y < frame.maxY
            }) else { return nil }
            return (id, view, view.convert(.zero, to: host).y)
        }
        let origin = scroll.contentView.bounds.minY
        var waiting: CFTimeInterval = 0
        var waitStart: CFTimeInterval?
        let observer = CFRunLoopObserverCreateWithHandler(nil,
            CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, activity in
            if activity == .beforeWaiting { waitStart = CACurrentMediaTime() }
            else if let start = waitStart { waiting += CACurrentMediaTime() - start; waitStart = nil }
        }!
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        let start = CACurrentMediaTime()
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        APQuietSendEvent(event, window)
        host.layoutSubtreeIfNeeded()
        // Trackpad cadence; include work serviced during the run loop, but
        // exclude its idle wait from main-thread processing time.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.018))
        host.layoutSubtreeIfNeeded()
        // AppKit can defer a precise event until its next scroll timer.
        // Drain that event before submitting another, rather than calling
        // its eventual coalesced displacement a row-layout jump.
        while delta != 0 && scroll.contentView.bounds.minY == origin && CACurrentMediaTime() - start < 0.1 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
            host.layoutSubtreeIfNeeded()
        }
        let cost = (CACurrentMediaTime() - start - waiting) * 1000
        let cpuCost = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
        let actual = scroll.contentView.bounds.minY - origin
        let tracked = native.first { $0.1.window === window && probe.frames[$0.0] != nil && adapter.belongs($0.1, to: $0.0, probe: probe) }
        let afterY = tracked.map { $0.1.convert(.zero, to: host).y }
        let movement = tracked.flatMap { old in afterY.map { $0 - old.2 } }
        let error = movement.map { $0 + CGFloat(delta) }
        var sample: [String: Any] = ["kind": delta == 0 ? "phase-end" : (delta < 0 ? "up" : "down"), "requested": delta, "actual": actual,
            "anchor": tracked?.0 ?? "", "valid": tracked != nil,
            "heights": probe.frames.mapValues { $0.height },
            "documentHeight": scroll.documentView?.bounds.height ?? 0,
            "milliseconds": cost, "threadCpuMilliseconds": cpuCost, "phase": phase, "segment": precise ? (decaying ? "decaying-precise" : "precise") : "wheel",
            "nativePhase": event.phase.rawValue, "nativeMomentum": event.momentumPhase.rawValue]
        if let tracked, let afterY, let movement, let error {
            sample["anchorBefore"] = tracked.2; sample["anchorAfter"] = afterY
            sample["error"] = Double(error); sample["layoutError"] = Double(movement + actual)
        }
        probe.samples.append(sample)
    }
}
