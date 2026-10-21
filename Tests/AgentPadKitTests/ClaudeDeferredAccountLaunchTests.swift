import XCTest
@testable import AgentPadKit

@MainActor
final class ClaudeDeferredAccountLaunchTests: XCTestCase {
    private var root: URL!
    private var profiles: AgentProfileStore!
    private var owners: [WorkspaceStore] = []
    private var engines: [TestEngine] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("deferred-account-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        profiles = AgentProfileStore(fileURL: root.appendingPathComponent("agent-profiles.json"),
                                     accountTokens: MemoryClaudeTokens())
    }

    override func tearDown() async throws {
        owners.forEach { $0.terminate() }
        for source in engines.flatMap(\.startedConfigs).compactMap(\.claudeAccountLaunch) {
            source.cleanup()
        }
        owners = []
        engines = []
        try profiles.flush()
        try FileManager.default.removeItem(at: root)
    }

    private func owner(persistence: InMemoryPersistence) -> WorkspaceStore {
        let owner = WorkspaceStore(persistence: persistence, initiallyEmpty: true, agentProfiles: profiles,
            sessionNames: .testing,
            engineFactory: { [weak self] in
                let engine = TestEngine()
                engine.preparesClaudeAccountLaunch = false
                self?.engines.append(engine)
                return engine
            },
            optionsProvider: { _ in nil }, resumeProvider: { true },
            conversationVisibility: { .init(channelIds: []) }, peerStores: { [] },
            claudeProjectsRoot: root.appendingPathComponent("empty-projects"))
        owners.append(owner)
        return owner
    }

    private func restoredSession(accountID: UUID?) throws -> (Session, UUID) {
        let profile = try profiles.add(template: .claudeCode, folder: root, launchOptions: "--model opus")
        try profiles.setClaudeAccount(profileID: profile.id, accountID: accountID)
        let disk = InMemoryPersistence()
        let original = owner(persistence: disk)
        let session = try original.startAgentProfile(profile.id).get()
        XCTAssertTrue(original.flushPersistence())
        original.terminate()
        let restored = owner(persistence: InMemoryPersistence(initial: try XCTUnwrap(disk.saved)))
        return (try XCTUnwrap(restored.allSessions.first { $0.id == session.id }), profile.id)
    }

    private func reveal(_ session: Session) throws -> TerminalSessionConfig {
        let engine = try XCTUnwrap(session.engine as? TestEngine)
        let pending = try XCTUnwrap(engine.startedConfigs.last)
        engine.preparesClaudeAccountLaunch = true
        engine.start(config: pending)
        return try XCTUnwrap(engine.startedConfigs.last)
    }

    func testRestoredAccountAToBUsesSelectionAtProcessStart() throws {
        let first = try profiles.claudeAccounts.add(name: "A", token: UUID().uuidString)
        let expected = UUID().uuidString
        let second = try profiles.claudeAccounts.add(name: "B", token: expected)
        let (session, profileID) = try restoredSession(accountID: first.id)
        try profiles.setClaudeAccount(profileID: profileID, accountID: second.id)
        let config = try reveal(session)
        let source = try XCTUnwrap(config.claudeAccountLaunch)
        XCTAssertTrue(try Data(contentsOf: source.fileURL) == Data((expected + "\n").utf8))
        XCTAssertTrue(session.claudeAccountLaunch === source)
    }

    func testRestoredAccountAToMainUsesOriginalMainCommand() throws {
        let first = try profiles.claudeAccounts.add(name: "A", token: UUID().uuidString)
        let (session, profileID) = try restoredSession(accountID: first.id)
        try profiles.setClaudeAccount(profileID: profileID, accountID: nil)
        let config = try reveal(session)
        XCTAssertTrue(config.claudeAccountLaunch == nil)
        XCTAssertTrue(session.claudeAccountLaunch == nil)
        XCTAssertTrue(config.environment["AGENTPAD_AGENT"] == "claude --model opus")
    }

    func testRestoredMainToAccountAUsesSelectionAtProcessStart() throws {
        let expected = UUID().uuidString
        let account = try profiles.claudeAccounts.add(name: "A", token: expected)
        let (session, profileID) = try restoredSession(accountID: nil)
        try profiles.setClaudeAccount(profileID: profileID, accountID: account.id)
        let config = try reveal(session)
        XCTAssertTrue(config.claudeAccountLaunch != nil)
        if let source = config.claudeAccountLaunch {
            XCTAssertTrue(try Data(contentsOf: source.fileURL) == Data((expected + "\n").utf8))
            XCTAssertTrue(session.claudeAccountLaunch === source)
        }
    }
}
