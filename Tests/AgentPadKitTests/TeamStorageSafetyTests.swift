import Darwin
import XCTest
@testable import AgentPadKit

final class TeamStorageSafetyTests: XCTestCase {
    func testUserProfileIsRejectedBeforeStorageCanBeUsed() {
        XCTAssertTrue(TeamStorage.isTestProcess, "the automatic guard must be active under swift test")
        let home = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        let profile = home.appendingPathComponent("Library/Application Support/agentpad")
        for path in [profile, profile.appendingPathComponent("team-server"), profile.appendingPathComponent("team/../team-server")] {
            XCTAssertFalse(TeamStorage.testDirectoryIsSafe(path), path.path)
        }
        XCTAssertTrue(TeamStorage.testDirectoryIsSafe(home.appendingPathComponent("Library/Application Support/agentpad-tests")))
    }

    func testTemporaryStorageIsPrivateAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(TeamStorage.testDirectoryIsSafe(root))
        let storage = TeamStorage(directory: root)
        try storage.save(["temporary"], to: storage.agentsURL)
        XCTAssertEqual(try storage.load([String].self, from: storage.agentsURL, default: []), ["temporary"])
        let permissions = try FileManager.default.attributesOfItem(atPath: storage.agentsURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testSymlinkIntoUserProfileIsRejected() throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("team-storage-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: link) }
        // Point only at the home directory; never create a file in the profile.
        let home = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        XCTAssertFalse(TeamStorage.testDirectoryIsSafe(link.appendingPathComponent("Library/Application Support/agentpad/team-server")))
    }
}
