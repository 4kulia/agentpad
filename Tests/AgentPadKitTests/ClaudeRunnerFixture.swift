import Foundation
@testable import AgentPadKit

/// Older process/stop tests deliberately run shell fixtures. Y2 is mocked in
/// those tests; production rejects scripts (TeamRunnerVersionTests).
extension ClaudeCodeRunner {
    init(fixturePath: String, stopTiming: TeamRunStop.Timing = .standard) {
        self.init(claudePath: fixturePath, stopTiming: stopTiming, preflight: FixtureVersionCheck())
    }
}

private struct FixtureVersionCheck: ClaudeVersionChecking {
    func prepare(selectedPath: String, request: TeamRunRequest,
                 onActivity: @escaping @Sendable (String) -> Void) async throws -> ClaudeVersionPreflight.Ready {
        try ClaudeVersionPreflight.checkCancellation()
        return .init(executable: .init(selectedPath: selectedPath, file: .init(
            resolvedPath: URL(fileURLWithPath: selectedPath).resolvingSymlinksInPath().path,
            device: 0, inode: 0, size: 0, modifiedSeconds: 0, modifiedNanoseconds: 0)), version: "fixture", basis: "fixture")
    }
    func verify(_ executable: ClaudeExecutable) throws {}
}
