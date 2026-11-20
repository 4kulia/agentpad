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

    // The cases below never create anything in the profile: each target name
    // carries a fresh UUID, so the folder is missing on every machine.

    func testSymlinkIntoMissingProfileFolderIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-storage-missing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("safe"), withIntermediateDirectories: true)
        let toHome = root.appendingPathComponent("home")
        try FileManager.default.createSymbolicLink(at: toHome, withDestinationURL: Self.home)
        let missing = "Library/Application Support/agentpad/team-server-\(UUID().uuidString)/nested"
        XCTAssertFalse(TeamStorage.testDirectoryIsSafe(toHome.appendingPathComponent(missing)))
        // A link to a temporary folder stays usable when its tail is missing.
        let toSafe = root.appendingPathComponent("to-safe")
        try FileManager.default.createSymbolicLink(at: toSafe, withDestinationURL: root.appendingPathComponent("safe"))
        XCTAssertTrue(TeamStorage.testDirectoryIsSafe(toSafe.appendingPathComponent("missing/team-server")))
    }

    func testDanglingSymlinkIntoProfileIsRejected() throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("team-storage-dangling-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Self.profile.appendingPathComponent("team-server-\(UUID().uuidString)"))
        XCTAssertFalse(TeamStorage.testDirectoryIsSafe(link))
        XCTAssertFalse(TeamStorage.testDirectoryIsSafe(link.appendingPathComponent("runs")))
    }

    func testDotDotAfterSymlinkFollowsTheLinkTarget() throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("team-storage-dotdot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: link) }
        // `link/..` is the home folder on disk, not the temporary folder.
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Self.home.appendingPathComponent("Library"))
        let path = link.appendingPathComponent("../Library/Application Support/agentpad/team-server-\(UUID().uuidString)")
        XCTAssertFalse(TeamStorage.testDirectoryIsSafe(path))
    }

    func testOtherCaseSpellingOfProfileFollowsTheVolumeRules() throws {
        let path = Self.home.appendingPathComponent("library/application support/AgentPad/team-server-\(UUID().uuidString)")
        let sensitive = try XCTUnwrap(Self.home.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
        // On a case-insensitive volume this spelling is the profile itself.
        XCTAssertEqual(TeamStorage.testDirectoryIsSafe(path), sensitive)
    }

    func testUnresolvableLinkLoopIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-storage-loop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("a").path, withDestinationPath: "b")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("b").path, withDestinationPath: "a")
        XCTAssertFalse(TeamStorage.testDirectoryIsSafe(root.appendingPathComponent("a/team-server")))
    }

    private static let home = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
    private static let profile = home.appendingPathComponent("Library/Application Support/agentpad")
}
