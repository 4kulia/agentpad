import Foundation
@testable import AgentPadKit

/// Windows and the chat notification badge use the app-wide service. Replace
/// it for each test and restore it without constructing the real one.
@MainActor
final class TeamServiceTestScope {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-window-\(UUID().uuidString)")
    private let previous = TeamService.sharedForTesting

    init() {
        TeamService.sharedForTesting = TeamService(storage: TeamStorage(directory: root), offCalls: TeamOffCallStore())
    }

    func close() {
        TeamService.sharedForTesting = previous
        try? FileManager.default.removeItem(at: root)
    }
}
