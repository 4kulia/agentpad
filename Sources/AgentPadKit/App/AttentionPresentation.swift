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

/// No positive decision is exported. The live tab owns its single-shot callback.
@MainActor
final class PendingConfirmations {
    static let shared = PendingConfirmations()
    private let ledger: AttentionLedger
    private var tabs: [UUID: WeakConfirmation] = [:]
    private final class WeakConfirmation {
        weak var coordinator: ConfirmationCoordinator?
        let tabID: TabID
        init(_ coordinator: ConfirmationCoordinator, tabID: TabID) { self.coordinator = coordinator; self.tabID = tabID }
    }
    func register(_ id: UUID, tabID: TabID, coordinator: ConfirmationCoordinator) {
        guard coordinator.isAwaiting, coordinator.isVisible else { return }
        tabs[id] = WeakConfirmation(coordinator, tabID: tabID)
        ledger.upsert(AttentionEvent(source: "tab-confirmation", object: id.uuidString, kind: .confirmation,
                                    destination: .tabAction(tabID: tabID, actionID: id)))
    }
    init(ledger: AttentionLedger = .shared) { self.ledger = ledger }
    func end(_ id: UUID) {
        if let tab = tabs.removeValue(forKey: id) {
            ledger.resolve(AttentionEvent(source: "tab-confirmation", object: id.uuidString, kind: .confirmation,
                destination: .tabAction(tabID: tab.tabID, actionID: id)).id)
        }
    }
    func valid(_ id: UUID) -> Bool {
        if let coordinator = tabs[id]?.coordinator { coordinator.validate(); return coordinator.isAwaiting && coordinator.isVisible }
        return false
    }
    func open(_ id: UUID) -> Bool {
        if let coordinator = tabs[id]?.coordinator {
            coordinator.validate()
            guard coordinator.isAwaiting else { end(id); return false }
            return coordinator.reveal()
        }
        end(id); return false
    }
}

extension View {
    func attentionPlace(_ destinations: Set<AttentionDestination>) -> some View {
        background(AttentionPlaceProbe(destinations: destinations).allowsHitTesting(false))
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
