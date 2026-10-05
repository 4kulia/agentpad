import Foundation
import XCTest

/// Private deployment details are supplied by the operator, never by defaults
/// in the public test suite. See Tests/LIVE-TESTS.md for the environment contract.
struct ChatLiveConfiguration {
    struct OperatorFailure: Error, CustomStringConvertible {
        let description: String
    }

    struct Invocation {
        let arguments: [String]
        let input: String
    }

    static let requiredVariables = [
        "AGENTPAD_LIVE_HOST", "AGENTPAD_LIVE_OPERATOR",
        "AGENTPAD_LIVE_ISSUE_CODE_OPERATOR", "AGENTPAD_LIVE_EMAIL",
    ]

    private let host: String
    private let operatorPrefix: String
    private let issueCodePrefix: String
    private let emailTemplate: String
    private let emailPattern: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let missing = Self.requiredVariables.filter {
            environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }
        guard missing.isEmpty else {
            throw XCTSkip("live server tests require \(missing.joined(separator: ", ")); see Tests/LIVE-TESTS.md")
        }
        host = environment["AGENTPAD_LIVE_HOST"]!
        operatorPrefix = environment["AGENTPAD_LIVE_OPERATOR"]!
        issueCodePrefix = environment["AGENTPAD_LIVE_ISSUE_CODE_OPERATOR"]!
        emailTemplate = environment["AGENTPAD_LIVE_EMAIL"]!
        guard host.range(of: #"\A[a-zA-Z0-9][a-zA-Z0-9._@-]*\z"#, options: .regularExpression) != nil else {
            throw OperatorFailure(description: "AGENTPAD_LIVE_HOST must be an SSH alias")
        }
        // Exactly one placeholder in the local part, with an explicit E2E
        // marker: a typo must not turn the operator loose on real accounts.
        let parts = emailTemplate.components(separatedBy: "{id}")
        let sample = emailTemplate.replacingOccurrences(of: "{id}", with: "test")
        guard parts.count == 2, !parts[0].contains("@"),
              sample.range(of: #"\A[a-zA-Z0-9._%+-]*e2e-[a-zA-Z0-9._%+-]+@[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+\z"#,
                           options: .regularExpression) != nil else {
            throw OperatorFailure(description: "AGENTPAD_LIVE_EMAIL must be an E2E address template with one {id} in its local part")
        }
        emailPattern = #"\A"# + NSRegularExpression.escapedPattern(for: parts[0])
            + "[a-z0-9-]+" + NSRegularExpression.escapedPattern(for: parts[1]) + #"\z"#
    }

    func email(id: String) throws -> String {
        let address = emailTemplate.replacingOccurrences(of: "{id}", with: id)
        try validate(email: address)
        return address
    }

    func validate(email: String) throws {
        guard email.range(of: emailPattern, options: .regularExpression) != nil else {
            throw OperatorFailure(description: "operator requires an E2E address matching AGENTPAD_LIVE_EMAIL")
        }
    }

    func invocation(email: String, organizationName: String? = nil) throws -> Invocation {
        try validate(email: email)
        let arguments: [String]
        let prefix: String
        if let name = organizationName {
            guard name.hasPrefix("E2E "), name.count <= 64,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw OperatorFailure(description: "operator requires an E2E organization name")
            }
            arguments = ["create-org", "--name", name, "--owner", email]
            prefix = operatorPrefix
        } else {
            arguments = ["issue-code", email]
            prefix = issueCodePrefix
        }
        return Invocation(
            arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", host,
                        "bash -s -- " + arguments.map(Self.shellQuoted).joined(separator: " ")],
            input: "set -euo pipefail\n\(prefix) \"$@\"\n"
        )
    }

    func createOrg(name: String, owner: String) throws -> String {
        try run(invocation(email: owner, organizationName: name), operation: "create-org",
                pattern: #"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#)
    }

    func issueCode(_ address: String) throws -> String {
        try run(invocation(email: address), operation: "issue-code", pattern: #"\b\d{8}\b"#)
    }

    /// A configured operator failure is never a skip. Output may hold a code
    /// or credentials, so diagnostics include only the operation and status.
    static func operatorValue(_ text: String, status: Int32, operation: String, pattern: String) throws -> String {
        guard status == 0 else {
            throw OperatorFailure(description: "operator \(operation) failed (exit \(status)); output suppressed")
        }
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            throw OperatorFailure(description: "operator \(operation) gave no value; output suppressed")
        }
        return String(text[range])
    }

    private func run(_ invocation: Invocation, operation: String, pattern: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = invocation.arguments
        let input = Pipe(), out = Pipe()
        process.standardInput = input
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(invocation.input.utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return try Self.operatorValue(text, status: process.terminationStatus, operation: operation, pattern: pattern)
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
