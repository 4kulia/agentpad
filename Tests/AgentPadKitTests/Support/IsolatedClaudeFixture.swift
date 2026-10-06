import Foundation
import XCTest
@testable import AgentPadKit

/// Real Claude tests share this contract. The operator prepares an isolated
/// Claude profile and authenticates it themselves. Tests never copy
/// credentials, inspect the personal profile, or fall back to it.
struct IsolatedClaudeFixture: Sendable {
    final class VersionStore: Sendable {
        @MainActor private var value: ClaudeVersionApprovals?
        @MainActor func get() -> ClaudeVersionApprovals {
            if let value { return value }
            let made = ClaudeVersionApprovals(); value = made; return made
        }
    }
    private let versionStore = VersionStore()
    private let configuredExecutable: String?
    var executablePath: String? { configuredExecutable ?? ClaudeCodeRunner.locateClaude() }
    let root: URL
    let project: URL
    let profile: URL
    let config: URL
    var projects: URL { config.appendingPathComponent("projects") }

    init(environment: [String: String] = ProcessInfo.processInfo.environment, requireAuthentication: Bool = true,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        configuredExecutable = environment["AGENTPAD_LIVE_CLAUDE_EXECUTABLE"]
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = temp.appendingPathComponent("agentpad-e2e-run-\(UUID().uuidString)")
        project = root.appendingPathComponent("project")
        profile = root.appendingPathComponent("agentpad-profile")
        if requireAuthentication {
            guard let path = environment["AGENTPAD_LIVE_CLAUDE_CONFIG_DIR"] else {
                throw XCTSkip("Real Claude tests need an operator-authenticated isolated AGENTPAD_LIVE_CLAUDE_CONFIG_DIR; see Tests/LIVE-TESTS.md")
            }
            let supplied = URL(fileURLWithPath: path).standardizedFileURL
            let resolved = supplied.resolvingSymlinksInPath()
            let underTemp = resolved.path.hasPrefix(temp.path + "/") || resolved.path.hasPrefix("/private/tmp/")
            let persistent = homeDirectory.resolvingSymlinksInPath().appendingPathComponent(".agentpad-live-claude")
            let allowed = resolved.path == persistent.path || (underTemp
                && resolved.lastPathComponent.hasPrefix("agentpad-e2e-claude-")
                && FileManager.default.fileExists(atPath: resolved.appendingPathComponent("agentpad-e2e-ready").path))
            var isDirectory: ObjCBool = false
            guard allowed, FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw XCTSkip("Prepare an isolated ~/.agentpad-live-claude profile or a temporary agentpad-e2e-claude-* profile with its agentpad-e2e-ready marker; personal profiles are forbidden")
            }
            config = resolved
        } else { config = root.appendingPathComponent("claude-config") }
        for folder in [project, profile, projects] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    func runner(claudePath: String? = nil, preflight: (any ClaudeVersionChecking)? = nil) -> ClaudeCodeRunner {
        let isolatedPreflight = preflight ?? self.preflight()
        return ClaudeCodeRunner(claudePath: claudePath ?? executablePath ?? "/nonexistent/isolated-claude",
                                preflight: isolatedPreflight, sessionFilesRoot: projects, isolatedConfigDirectory: config)
    }

    func preflight(configuration: String = ClaudeVersionMatrix.configuration,
                   approvals: (@MainActor @Sendable () -> ClaudeVersionApprovals)? = nil) -> ClaudeVersionPreflight {
        let config = config
        return ClaudeVersionPreflight(configuration: configuration, readVersion: { executable, request in
            try await ClaudeVersionCommand.read(executable, request: request, timeout: .seconds(3), isolatedConfigDirectory: config)
        }, approvals: approvals ?? { versionStore.get() })
    }

    @MainActor func configure(service: ChatService, calls: TeamCalls? = nil) {
        service.claudeProjectsRoot = projects
        calls?.sessionFilesRoot = projects
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
