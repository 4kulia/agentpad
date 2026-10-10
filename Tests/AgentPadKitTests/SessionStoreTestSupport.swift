import Foundation
@testable import AgentPadKit

/// The canonical zero-config test store: TestEngine (no libghostty/PTY),
/// in-memory persistence, no real settings reads. Third verbatim copy
/// (DeepLink / PaneTreeHost / CLIController) earned it the shared home —
/// a new WorkspaceStore injection seam lands here once, not per file.
@MainActor
func makeTestStore(persistence: any Persistence = InMemoryPersistence(), claudeProjectsRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("agentpad-no-claude-sessions"), agentProfiles: AgentProfileStore? = nil) -> WorkspaceStore {
    WorkspaceStore(
        persistence: persistence,
        agentProfiles: agentProfiles,
        engineFactory: { TestEngine() },
        optionsProvider: { _ in nil },
        resumeProvider: { true },
        claudeProjectsRoot: claudeProjectsRoot
    )
}

/// An actual transcript for resume tests, entirely outside the user's stores.
final class ClaudeResumeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-resume-\(UUID().uuidString)")
    let id: String

    init(id: String = UUID().uuidString.lowercased()) throws {
        self.id = id
        try add(id)
    }

    @discardableResult
    func add(_ id: String) throws -> URL {
        try SessionStoreFixtures.writeFile("\(id).jsonl", in: root.appendingPathComponent("-tmp"), lines: [
            #"{"type":"user","cwd":"/tmp","message":{"content":"fixture"}}"#
        ])
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

/// Shared fixture helpers for the session-store tests and benchmarks.
/// `isolatedRoots` is also the privacy guard with one home: a test scan must
/// NEVER touch the developer's real agent stores — every store gets an
/// explicit root, defaulting to a nonexistent dir that yields zero records.
/// (`PerformanceBenchmarks.testSessionScanRealStores` is the one sanctioned
/// exception, via the explicitly-named `scanDefaultRoots`.)
enum SessionStoreFixtures {
    /// A resumable record with placeholder title/id — the History filter
    /// and resume tests care about agent + cwd, nothing else.
    static func record(
        agentId: String = AgentTemplate.claudeCodeID,
        cwd: URL,
        title: String = "old conversation",
        conversationId: String = "11111111-2222-3333-4444-555555555555"
    ) -> AgentSessionRecord {
        AgentSessionRecord(agentId: agentId, conversationId: conversationId, title: title, cwd: cwd, lastActivity: Date())
    }

    @discardableResult
    static func writeFile(_ name: String, in dir: URL, lines: [String], mtime: Date? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    static func isolatedRoots(base: URL, overrides: [String: URL] = [:]) -> [String: URL] {
        var roots = overrides
        for id in AgentSessionScanner.supportedAgentIds where roots[id] == nil {
            roots[id] = base.appendingPathComponent("empty-\(id)")
        }
        return roots
    }
}
