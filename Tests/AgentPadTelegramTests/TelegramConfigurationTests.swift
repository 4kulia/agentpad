import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramConfigurationTests: XCTestCase {
    func testMissingConfigurationDisablesOnlyTelegram() throws {
        XCTAssertNil(try TelegramCredentials.load(environment: [:], resource: nil))
    }

    func testPartialOrInvalidConfigurationFailsClosed() {
        for values in [["AGENTPAD_TELEGRAM_API_ID": "123"],
                       ["AGENTPAD_TELEGRAM_API_ID": "-1", "AGENTPAD_TELEGRAM_API_HASH": String(repeating: "a", count: 32)],
                       ["AGENTPAD_TELEGRAM_API_ID": "123", "AGENTPAD_TELEGRAM_API_HASH": "invalid"]] {
            XCTAssertThrowsError(try TelegramCredentials.load(environment: values, resource: nil))
        }
    }

    func testExplicitBuildEnvironment() throws {
        let credentials = try XCTUnwrap(TelegramCredentials.load(environment: [
            "AGENTPAD_TELEGRAM_API_ID": "123",
            "AGENTPAD_TELEGRAM_API_HASH": String(repeating: "a", count: 32)
        ], resource: nil))
        XCTAssertEqual(credentials.apiID, 123)
    }

    func testPrivateBuildInputAndBundledCredentialsHaveDistinctPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("telegram-build-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("private.plist")
        let resources = directory.appendingPathComponent("AgentPad.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let bundled = resources.appendingPathComponent("TelegramCredentials.plist")
        // Synthetic values travel only over stdin; the real release configuration
        // and the test runner's environment are never read by these subprocesses.
        let synthetic = try JSONSerialization.data(withJSONObject: ["api_id": "123", "api_hash": String(repeating: "a", count: 32)])
        try runBuildConfig(["--generate", input.path], input: synthetic)
        try runBuildConfig(["--bundle", input.path, bundled.path])
        let privateMode = try FileManager.default.attributesOfItem(atPath: input.path)[.posixPermissions] as? NSNumber
        let bundledMode = try FileManager.default.attributesOfItem(atPath: bundled.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(privateMode?.intValue, 0o600)
        XCTAssertEqual(bundledMode?.intValue, 0o644, "The distributed resource must be readable by users other than its owner")
        XCTAssertNotNil(try TelegramCredentials.load(environment: [:], resource: bundled))
        // Compare without including either value in failure output.
        XCTAssertTrue(try Data(contentsOf: input) == Data(contentsOf: bundled))
    }

    private func runBuildConfig(_ arguments: [String], input: Data = Data()) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), stdin = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", root.appendingPathComponent("scripts/telegram-build-config.py").path] + arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = stdin; process.standardOutput = output; process.standardError = output
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(bytes.isEmpty, "Build configuration must not print credentials")
    }
}
