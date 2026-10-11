import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramProfileTests: XCTestCase {
    func testNoProfileOnFirstRestoreAndSingleProcessLease() throws {
        let fixture = try TelegramFixture()
        XCTAssertNil(try fixture.profiles.open(environment: .test, create: false))
        let profile = try XCTUnwrap(fixture.profiles.open(environment: .test, create: true))
        XCTAssertThrowsError(try fixture.profiles.open(environment: .test, create: true)) {
            XCTAssertEqual($0 as? TelegramStorageError, .lockedProfile)
        }
        XCTAssertEqual(profile.manifest.environment, .test)
        for directory in [profile.directory, profile.database, profile.files] {
            try TelegramProfileStore.validate(directory, directory: true)
        }
        try TelegramProfileStore.validate(profile.directory.appendingPathComponent("profile.json"), directory: false)
    }
    func testAccountAndEnvironmentBindingAreStrict() throws {
        let fixture = try TelegramFixture()
        let profile = try XCTUnwrap(fixture.profiles.open(environment: .test, create: true))
        try profile.bind(userID: 9007199254740991, environment: .test)
        XCTAssertThrowsError(try profile.bind(userID: 7, environment: .test))
        XCTAssertThrowsError(try profile.bind(userID: 9007199254740991, environment: .production))
        XCTAssertEqual(profile.manifest.userID, "9007199254740991")
        let bytes = try Data(contentsOf: profile.directory.appendingPathComponent("profile.json"))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("\"9007199254740991\""))
    }
    func testSymlinkAndUnsafePermissionsAreRejected() throws {
        let fixture = try TelegramFixture()
        let link = fixture.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
        XCTAssertThrowsError(try TelegramProfileStore(root: link).open(environment: .test, create: true))
        let profile = try XCTUnwrap(fixture.profiles.open(environment: .test, create: true))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: profile.directory.appendingPathComponent("profile.json").path)
        XCTAssertThrowsError(try profile.save())
    }
    func testCleanupIntentSurvivesRestart() throws {
        let fixture = try TelegramFixture()
        var profile = try fixture.profiles.open(environment: .test, create: true)
        profile?.manifest.cleanup = .logout
        try profile?.save()
        profile = nil
        let restored = try XCTUnwrap(fixture.profiles.open(environment: .test, create: false))
        XCTAssertEqual(restored.manifest.cleanup, .logout)
    }
}
