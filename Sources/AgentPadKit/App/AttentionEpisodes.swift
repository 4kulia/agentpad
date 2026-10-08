import Foundation

/// A disappearance followed by a new wait is a new episode, while a restart
/// or another snapshot of the same live wait keeps the old ID.
@MainActor
final class AttentionEpisodes {
    static let shared = AttentionEpisodes(defaults: .standard)
    struct Episode: Codable { var number: Int; var active: Bool }
    private let defaults: UserDefaults?
    private var entries: [String: Episode]
    private let storageKey = "AgentPad.attentionEpisodes.v1"
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        entries = defaults?.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([String: Episode].self, from: $0) } ?? [:]
    }
    func begin(_ key: String) -> String {
        if let existing = entries[key], existing.active { return String(existing.number) }
        let number = (entries[key]?.number ?? 0) + 1
        entries[key] = Episode(number: number, active: true); save()
        return String(number)
    }
    func reconcile(keeping keys: Set<String>) {
        var changed = false
        for key in entries.keys where !keys.contains(key) && entries[key]?.active == true {
            entries[key]?.active = false; changed = true
        }
        if changed { save() }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults?.set(data, forKey: storageKey) }
    }
}
