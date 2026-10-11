import Foundation
import XCTest
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
        sessionNames: .testing,
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

/// One disposable store for fixtures that do not supply a per-test database.
@MainActor extension SessionNames {
    static let testing = SessionNames(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("agentpad-test-names-\(UUID()).sqlite"))
}

@MainActor extension Session {
    func renameForTesting(_ name: String) {
        if displaySources == nil { displaySources = .init(names: .testing) }
        if displaySources?.names === SessionNames.shared { displaySources?.names = .testing }
        names.beginRename(name, for: explicitNameKey)
    }
}

/// Real closed transcript + profile binding. Both UI resume paths used to
/// promote this private record.title into the public author signature.
@MainActor final class ClosedSessionNameFixture {
    let record: AgentSessionRecord
    let catalog: SessionCatalog
    let names: SessionNames
    let profiles: AgentProfileStore
    let profile: AgentProfile
    let store: WorkspaceStore

    init(root: URL, metadata: String) throws {
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let projects = root.appendingPathComponent("projects")
        let file = try SessionStoreFixtures.writeFile("\(UUID().uuidString.lowercased()).jsonl",
            in: projects.appendingPathComponent("-project"), lines: [
                "{\"type\":\"user\",\"cwd\":\"\(folder.path)\",\"message\":{\"content\":\"PRIVATE-TITLE-MARKER first prompt\"}}",
                metadata
            ])
        record = try XCTUnwrap(AgentSessionScanner.readClaudeRecord(file: file, mtime: Date()))
        let record = record
        catalog = SessionCatalog { _ in .init(records: [record], scanned: 1, total: 1, skipped: 0) }
        names = SessionNames(url: root.appendingPathComponent("names.sqlite"))
        profiles = AgentProfileStore(canonicalize: { $0 })
        profile = try profiles.add(template: .claudeCode, folder: folder)
        try profiles.bind(record, to: profile.id)
        store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            agentProfiles: profiles, sessionCatalog: catalog, sessionNames: names,
            engineFactory: { TestEngine() }, optionsProvider: { _ in nil }, resumeProvider: { true },
            conversationVisibility: { .init(channelIds: []) }, peerStores: { [] }, claudeProjectsRoot: projects)
        store.profileTemplates = { [.claudeCode] }
    }

    func resume(allSessions: Bool) async throws -> Session {
        catalog.refresh()
        for _ in 0..<200 where catalog.isScanning { try await Task.sleep(for: .milliseconds(5)) }
        if allSessions {
            let model = AllSessionsModel(state: TabState(route: .allSessions), catalog: catalog,
                names: names, profiles: profiles)
            let item = AllSessionItem(id: record.id, record: record, source: .disk, status: .finished, title: record.title)
            let monitor = AgentMonitor(); monitor.storesProvider = { [] }
            await AllSessionsActions.activate(item, model: model, store: store, monitor: monitor)
            XCTAssertNil(model.resumeError)
            return try XCTUnwrap(store.allSessions.first)
        }
        let item = try XCTUnwrap(store.profileSessionItems(profile).first)
        return try store.openProfileSession(item, profileID: profile.id).get()
    }

    static let privateMetadata = ["",
        #"{"type":"summary","summary":"PRIVATE-TITLE-MARKER summary"}"#,
        #"{"type":"ai-title","aiTitle":"PRIVATE-TITLE-MARKER AI title"}"#,
        #"{"type":"custom-title","customTitle":"PRIVATE-TITLE-MARKER transcript custom title"}"#]
}
