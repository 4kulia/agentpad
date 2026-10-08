import Foundation

/// Sparkle's UI lifecycle is not an installation verdict. Only a changed
/// running bundle confirms installation; errors retain the attempted phase.
@MainActor
final class UpdateAttention {
    static let shared = UpdateAttention(ledger: .shared, defaults: .standard)
    enum Choice { case later, skip, install }
    private let ledger: AttentionLedger
    private let defaults: UserDefaults?
    private(set) var version: String?
    private(set) var installing = false
    private var cycle = UUID().uuidString
    init(ledger: AttentionLedger, defaults: UserDefaults? = nil) {
        self.ledger = ledger; self.defaults = defaults
    }
    func beginCheck() { cycle = UUID().uuidString; installing = false }
    func available(_ version: String, manual: Bool) {
        if let previous = self.version, previous != version {
            ledger.resolve(AttentionEvent(source: "update", object: previous, kind: .update, destination: .update(previous)).id)
        }
        self.version = version
        var event = AttentionEvent(source: "update", object: version, kind: .update, destination: .update(version))
        guard ledger.metadata.markers[event.id]?.consumed != true else { return }
        event.suppressesDelivery = manual
        event.isRead = manual
        ledger.upsert(event)
    }
    func viewed() {
        guard let version else { return }
        let id = AttentionEvent(source: "update", object: version, kind: .update, destination: .update(version)).id
        if var event = ledger.events.first(where: { $0.id == id }) {
            event.suppressesDelivery = true; event.isRead = true
            ledger.delivery?.remove(ids: [id]); ledger.upsert(event)
        }
    }
    func chose(_ choice: Choice) {
        guard let version else { return }
        let id = AttentionEvent(source: "update", object: version, kind: .update, destination: .update(version)).id
        ledger.metadata.update(id) { $0.consumed = true }
        ledger.resolve(id)
        installing = choice == .install
        if installing { defaults?.set(version, forKey: "AgentPad.installingUpdate") }
    }
    func failed(shown: Bool = false) {
        if let version {
            ledger.resolve(AttentionEvent(source: "update", object: version, kind: .update, destination: .update(version)).id)
        }
        var event = AttentionEvent(source: "update-outcome", object: cycle, episode: installing ? "install" : "check",
                                   kind: .updateFailure, destination: .update(version ?? ""))
        event.localTitle = String(localized: String.LocalizationValue(installing ? "AgentPad update installation failed" : "Could not check for AgentPad updates"), bundle: .agentPadResources)
        event.isRead = shown
        ledger.upsert(event)
        defaults?.removeObject(forKey: "AgentPad.installingUpdate")
    }
    func launched(version: String) {
        guard defaults?.string(forKey: "AgentPad.installingUpdate") == version else { return }
        defaults?.removeObject(forKey: "AgentPad.installingUpdate")
        ledger.upsert(AttentionEvent(source: "update-outcome", object: version, episode: "installed",
                                    kind: .updateInstalled, destination: .update(version)))
    }
}
