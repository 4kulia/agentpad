import Foundation
import XCTest

final class ChatLiveOperatorTests: XCTestCase {
    private let environment = [
        "AGENTPAD_LIVE_HOST": "test-deployment",
        "AGENTPAD_LIVE_OPERATOR": "create_fixture() { printf '<%s>\\n' create \"$@\"; }; create_fixture",
        "AGENTPAD_LIVE_ISSUE_CODE_OPERATOR": "code_fixture() { printf '<%s>\\n' code \"$@\"; }; code_fixture",
        "AGENTPAD_LIVE_EMAIL": "tester+e2e-{id}@example.com",
    ]

    func testMissingOrBlankSettingsSkipWithoutExposingConfiguredValues() {
        let required = ["AGENTPAD_LIVE_HOST", "AGENTPAD_LIVE_OPERATOR",
                        "AGENTPAD_LIVE_ISSUE_CODE_OPERATOR", "AGENTPAD_LIVE_EMAIL"]
        XCTAssertThrowsError(try ChatLiveConfiguration(environment: [:])) { error in
            XCTAssertTrue(error is XCTSkip)
            let message = (error as? XCTSkip)?.message ?? ""
            for name in required { XCTAssertTrue(message.contains(name)) }
        }
        for name in required {
            for value in [nil, "", " \n\t"] as [String?] {
                var env = environment
                env[name] = value
                XCTAssertThrowsError(try ChatLiveConfiguration(environment: env)) { error in
                    XCTAssertTrue(error is XCTSkip)
                    let message = (error as? XCTSkip)?.message ?? ""
                    XCTAssertTrue(message.contains(name))
                    for configured in env.values where !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        XCTAssertFalse(message.contains(configured))
                    }
                }
            }
        }
    }

    func testEmailTemplateExpandsEveryRunAndAcceptsOnlyMatchingE2EAddresses() throws {
        let config = try ChatLiveConfiguration(environment: environment)
        XCTAssertEqual(try config.email(id: "ask-20261005-120000-a"), "tester+e2e-ask-20261005-120000-a@example.com")
        XCTAssertNotEqual(try config.email(id: "run-a"), try config.email(id: "run-b"))
        for address in ["someone@example.com", "tester+e2e-test@example.org",
                        "tester+e2e-test@example.com; false", "tester+e2e-test@example.com\n"] {
            XCTAssertThrowsError(try config.invocation(email: address))
        }
        for id in ["", "bad\n", "bad@other.example", "$(false)", "a/b"] {
            XCTAssertThrowsError(try config.email(id: id))
        }
        var other = environment
        other["AGENTPAD_LIVE_EMAIL"] = "e2e-client-{id}@example.org"
        XCTAssertEqual(try ChatLiveConfiguration(environment: other).email(id: "org-b"), "e2e-client-org-b@example.org")
    }

    func testInvalidConfigurationFailsWithoutExposingValues() {
        let badValues = [
            "AGENTPAD_LIVE_HOST": ["-oProxyCommand=false", "test host", "test\nhost", "test;false"],
            "AGENTPAD_LIVE_EMAIL": ["person@example.com", "tester+{id}@example.com", "e2e-{id}-{id}@example.com",
                                     "e2e-user@{id}.example.com", "e2e-{id}@example.com\n", "e2e-{id}@example.com;false"],
        ]
        for (key, values) in badValues {
            for value in values {
                var env = environment
                env[key] = value
                XCTAssertThrowsError(try ChatLiveConfiguration(environment: env)) { error in
                    XCTAssertTrue(error is ChatLiveConfiguration.OperatorFailure)
                    XCTAssertTrue(String(describing: error).contains(key))
                    XCTAssertFalse(String(describing: error).contains(value))
                }
            }
        }
    }

    func testConfiguredCommandsReceiveOnlyQuotedAuthorizedOperations() throws {
        let config = try ChatLiveConfiguration(environment: environment)
        let address = try config.email(id: "operator")
        let prefix = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", "test-deployment"]
        let name = "E2E owner's $(exit 7) `exit 8`"
        let create = try config.invocation(email: address, organizationName: name)
        XCTAssertEqual(create.arguments, prefix + ["bash -s -- 'create-org' '--name' 'E2E owner'\\''s $(exit 7) `exit 8`' '--owner' '\(address)'"])
        let code = try config.invocation(email: address)
        XCTAssertEqual(code.arguments, prefix + ["bash -s -- 'issue-code' '\(address)'"])
        // Execute the exact remote shell command locally with harmless fake
        // operators: metacharacters must reach them as data, never as code.
        XCTAssertEqual(try runLocally(create), "<create>\n<create-org>\n<--name>\n<\(name)>\n<--owner>\n<\(address)>\n")
        XCTAssertEqual(try runLocally(code), "<code>\n<issue-code>\n<\(address)>\n")
        for invocation in [create, code] {
            XCTAssertFalse(invocation.arguments.joined().contains("printf"), "operator configuration travels only on stdin")
        }
        for name in ["Customer organization", "E2E bad\nname", "E2E bad\0name", "E2E " + String(repeating: "a", count: 61)] {
            XCTAssertThrowsError(try config.invocation(email: address, organizationName: name))
        }
    }

    func testOperatorFailureCannotBecomeASkipOrExposeOutput() throws {
        let syntheticSecret = "aps_synthetic_do_not_print"
        for status: Int32 in [0, 1] {
            XCTAssertThrowsError(try ChatLiveConfiguration.operatorValue(syntheticSecret, status: status, operation: "create-org", pattern: #"\b\d{8}\b"#)) { error in
                XCTAssertTrue(error is ChatLiveConfiguration.OperatorFailure)
                XCTAssertFalse(String(describing: error).contains(syntheticSecret))
            }
        }
        XCTAssertThrowsError(try ChatLiveConfiguration.operatorValue("12345678", status: 1, operation: "issue-code", pattern: #"\b\d{8}\b"#))
        XCTAssertEqual(try ChatLiveConfiguration.operatorValue("12345678\n", status: 0, operation: "issue-code", pattern: #"\b\d{8}\b"#), "12345678")
    }

    func testLiveSourcesCannotBypassConfigurationOrEmbedPrivateMailDomains() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let domains = try NSRegularExpression(pattern: #"@([a-zA-Z0-9.-]+\.[a-zA-Z]{2,})"#)
        for name in ["ChatLiveFeedTests.swift", "ChatLiveTests.swift"] {
            let source = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(source.contains("\"/usr/bin/ssh\""),
                         "\(name): operator execution belongs in ChatLiveConfiguration")
            for match in domains.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let range = try XCTUnwrap(Range(match.range(at: 1), in: source))
                XCTAssertTrue(["example.com", "example.org", "example.net"].contains(source[range].lowercased()),
                              "\(name): use the configured email template or a reserved example domain")
            }
        }
    }

    private func runLocally(_ invocation: ChatLiveConfiguration.Invocation) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try XCTUnwrap(invocation.arguments.last)]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(invocation.input.utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return text
    }
}
