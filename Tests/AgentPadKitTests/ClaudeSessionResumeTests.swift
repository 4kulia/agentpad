import XCTest
@testable import AgentPadKit

final class ClaudeSessionResumeTests: XCTestCase {
    func testProjectsRootHonorsClaudeConfigDirectory() {
        XCTAssertEqual(ClaudeSessionResume.projectsRoot(environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-profile"]),
                       URL(fileURLWithPath: "/tmp/claude-profile/projects"))
        XCTAssertEqual(ClaudeSessionResume.projectsRoot(environment: ["CLAUDE_CONFIG_DIR": "~/claude-profile"]),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("claude-profile/projects"))
        XCTAssertEqual(ClaudeSessionResume.projectsRoot(environment: [:]), TeamSessionFiles.root)
        XCTAssertEqual(ClaudeSessionResume.projectsRoot(environment: ["CLAUDE_CONFIG_DIR": ""]), TeamSessionFiles.root)
    }

    func testResumeUsesConfiguredProjectsRoot() throws {
        let fixture = try ClaudeResumeFixture()
        let root = ClaudeSessionResume.projectsRoot(environment: [
            "CLAUDE_CONFIG_DIR": fixture.root.deletingLastPathComponent().appendingPathComponent("profile-\(UUID())").path
        ])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.root, to: root)

        XCTAssertEqual(try ClaudeSessionResume.resolve(fixture.id, root: root, visibility: .init(channelIds: [])).get(), fixture.id)
        let config = AgentTemplate.claudeCode.makeSessionConfig(resumeId: fixture.id, claudeProjectsRoot: root,
                                                               visibility: .init(channelIds: []))
        XCTAssertEqual(config.environment["AGENTPAD_AGENT"], "claude --resume \(fixture.id)")
    }
}
