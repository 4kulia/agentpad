import Foundation
@testable import AgentPadKit

/// In-memory `Persistence` for tests — captures `save` calls so assertions
/// can inspect the most recent snapshot without touching the filesystem.
@MainActor
final class InMemoryPersistence: Persistence {
    var saved: PersistedState?
    /// Number of `save` calls — lets tests assert on debounced `scheduleSave`
    /// behaviour (e.g. an unchanged cwd must NOT trigger an extra save).
    private(set) var saveCount = 0
    private let initial: PersistedState?

    init(initial: PersistedState? = nil) {
        self.initial = initial
    }

    func load() -> PersistedState? {
        initial
    }

    func save(_ state: PersistedState) {
        saved = state
        saveCount += 1
    }
}
