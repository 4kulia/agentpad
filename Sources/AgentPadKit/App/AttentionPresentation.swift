import AppKit
import SwiftUI

/// A route request contains metadata only; the target view still uses its own gates.
@MainActor @Observable
final class AttentionSelection {
    static let shared = AttentionSelection()
    var destination: AttentionDestination?
    var revision = 0
    func select(_ destination: AttentionDestination) { self.destination = destination; revision += 1 }
}

@MainActor
final class NotificationNavigation {
    let ledger: AttentionLedger
    var ready = false
    var shouldWait: (AttentionEvent) -> Bool = { _ in false }
    var validate: (AttentionEvent) -> Bool = { _ in false }
    var open: (AttentionEvent) -> Bool = { _ in false }
    var unavailable: () -> Void = {}
    private var pending: [String] = []
    init(ledger: AttentionLedger) { self.ledger = ledger }
    func activate(_ id: String) {
        guard ready else { if !pending.contains(id) { pending.append(id) }; return }
        if let event = ledger.event(id), shouldWait(event) {
            if !pending.contains(id) { pending.append(id) }; return
        }
        guard let event = ledger.event(id), validate(event), open(event) else {
            ledger.resolve(id); unavailable(); return
        }
        ledger.markRead(id)
    }
    func finishStartup() {
        ready = true
        retryPending()
    }
    func retryPending() {
        guard ready else { return }
        let ids = pending; pending = []
        for id in ids { activate(id) }
    }
}

@MainActor
enum AttentionFocus {
    static var places: [UUID: (destinations: Set<AttentionDestination>, view: WeakView)] = [:]
    final class WeakView { weak var view: NSView?; init(_ view: NSView) { self.view = view } }
    static func window(for destination: AttentionDestination) -> NSWindow? {
        places.values.first { $0.destinations.contains(destination) && $0.view.view?.window != nil }?.view.view?.window
    }
    static func focused(_ destination: AttentionDestination) -> Bool {
        guard NSApp?.isActive == true else { return false }
        return places.values.contains { entry in
            guard entry.destinations.contains(destination), let view = entry.view.view,
                  let window = view.window, window.isVisible, !window.isMiniaturized,
                  window.isKeyWindow, !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return false }
            return true
        }
    }
}

private struct AttentionPlaceProbe: NSViewRepresentable {
    var destinations: Set<AttentionDestination>
    final class Probe: NSView { let id = UUID() }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        AttentionFocus.places[view.id] = (destinations, AttentionFocus.WeakView(view))
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { AttentionFocus.places[view.id] = nil }
}

/// No positive decision is exported. The live sheet owns its single-shot callback.
@MainActor
final class PendingConfirmations {
    static let shared = PendingConfirmations()
    private let ledger: AttentionLedger
    private var windows: [UUID: WeakWindow] = [:]
    private final class WeakWindow { weak var window: NSWindow?; init(_ value: NSWindow) { window = value } }
    init(ledger: AttentionLedger = .shared) { self.ledger = ledger }
    func register(_ id: UUID, window: NSWindow, busy: Bool = false) {
        windows[id] = WeakWindow(window)
        var event = AttentionEvent(source: "sheet", object: id.uuidString, kind: .confirmation, destination: .sheet(id))
        event.actionInFlight = busy
        ledger.upsert(event)
    }
    func end(_ id: UUID) {
        windows[id] = nil
        ledger.resolve(AttentionEvent(source: "sheet", object: id.uuidString, kind: .confirmation, destination: .sheet(id)).id)
    }
    func valid(_ id: UUID) -> Bool { windows[id]?.window != nil }
    func open(_ id: UUID) -> Bool {
        guard let window = windows[id]?.window else { end(id); return false }
        let parent = window.sheetParent ?? window
        parent.deminiaturize(nil); parent.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

private struct AttentionConfirmationProbe: NSViewRepresentable {
    var busy: Bool
    final class Probe: NSView {
        let id = UUID()
        var busy = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { PendingConfirmations.shared.register(id, window: window, busy: busy) }
            else { PendingConfirmations.shared.end(id) }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.busy = busy
        if let window = view.window { PendingConfirmations.shared.register(view.id, window: window, busy: busy) }
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { PendingConfirmations.shared.end(view.id) }
}

extension View {
    func attentionPlace(_ destinations: Set<AttentionDestination>) -> some View {
        background(AttentionPlaceProbe(destinations: destinations).allowsHitTesting(false))
    }
    func attentionConfirmation(busy: Bool = false) -> some View {
        background(AttentionConfirmationProbe(busy: busy).allowsHitTesting(false))
    }
}

/// Opening an interactive login or choosing a binary never retries the old run.
struct ClaudeLaunchHelpView: View {
    let key: ChatOrgKey
    let request: String
    var service = ChatService.shared
    var body: some View {
        if let kind = ChatAttention.launchHelp(ChatAttention.localLaunchFailure(key, request: request, service: service)) {
            if kind == .signIn {
                Button("Open Claude to sign in") { TeamUI.openClaudeForSignIn(key, request: request) }
            } else {
                Button("Choose Claude…") { TeamUI.chooseClaudeExecutable() }
            }
        }
    }
}
