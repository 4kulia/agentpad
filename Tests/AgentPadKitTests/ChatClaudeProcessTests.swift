import Darwin
import Security
import XCTest
@testable import AgentPadKit

final class ChatClaudeProcessTests: XCTestCase {
    private var root: URL!
    private var child: Process?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-signature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let child, child.isRunning { child.terminate(); child.waitUntilExit() }
        child = nil
        try FileManager.default.removeItem(at: root)
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: executable)
        command.arguments = arguments
        command.standardOutput = FileHandle.nullDevice
        command.standardError = FileHandle.nullDevice
        try command.run(); command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0, executable)
    }

    private func fixture(_ version: Int) throws -> URL {
        let source = root.appendingPathComponent("fixture.c")
        try """
        #include <unistd.h>
        int main(int argc, char **argv) {
            if (argc == 3) {
                while (access(argv[1], F_OK)) usleep(1000);
                execl(argv[2], argv[2], (char *)0);
                return 127;
            }
            sleep(30);
            return IMAGE;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("image-\(version)")
        try run("/usr/bin/clang", [source.path, "-DIMAGE=\(version)", "-o", binary.path])
        // Ad-hoc only: no keychain, signing certificate or real Claude involved.
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "com.anthropic.claude-code", binary.path])
        return binary
    }

    private func start(_ binary: URL, arguments: [String] = []) throws -> Int32 {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        child = process
        return process.processIdentifier
    }

    private func fixtureRequirement() throws -> SecRequirement {
        var result: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(#"identifier "com.anthropic.claude-code""# as CFString, [], &result), errSecSuccess)
        return try XCTUnwrap(result)
    }

    func testRequirementNeedsAnthropicIdentifierAndAppleIssuedTeam() throws {
        XCTAssertEqual(ChatClaudeProcess.signingRequirement,
                       #"anchor apple generic and identifier "com.anthropic.claude-code" and certificate leaf[subject.OU] = "Q6L2SF6YDW""#)
        var parsed: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(ChatClaudeProcess.signingRequirement as CFString, [], &parsed), errSecSuccess)
        let pid = try start(fixture(1))
        XCTAssertTrue(ChatClaudeProcess.hasValidSignature(pid, requirement: try fixtureRequirement(), auditToken: nil))
        XCTAssertFalse(ChatClaudeProcess.hasTrustedSignature(pid), "an ad-hoc signature can copy the identifier, not the trusted team")
        XCTAssertFalse(ChatClaudeProcess.hasTrustedSignature(0))
    }

    func testAuditTokenAndPIDFallbackValidateLiveCodeAndFailClosed() throws {
        let pid = try start(fixture(1)), requirement = try fixtureRequirement()
        XCTAssertTrue(ChatClaudeProcess.hasValidSignature(pid, requirement: requirement, auditToken: nil))
        let token = try XCTUnwrap(ChatClaudeProcess.auditToken(of: pid))
        XCTAssertTrue(ChatClaudeProcess.hasValidSignature(pid, requirement: requirement, auditToken: token,
            executablePath: { _ in XCTFail("audit token must not fall back to a path"); return nil }))
        XCTAssertFalse(ChatClaudeProcess.hasValidSignature(pid, requirement: requirement, auditToken: Data(),
            executablePath: { _ in XCTFail("a bad token must not fall back to PID/path"); return nil }))
        XCTAssertFalse(ChatClaudeProcess.hasValidSignature(pid, requirement: requirement, auditToken: nil, executablePath: { _ in nil }))
        child?.terminate(); child?.waitUntilExit()
        XCTAssertFalse(ChatClaudeProcess.hasValidSignature(pid, requirement: requirement, auditToken: token))
        XCTAssertFalse(ChatClaudeProcess.hasValidSignature(pid, requirement: requirement, auditToken: nil))
    }

    func testPIDFallbackRejectsDifferentValidlySignedFileAtImagePath() throws {
        let first = try fixture(1), replacement = try fixture(2)
        let pid = try start(first), requirement = try fixtureRequirement()
        // Both files satisfy the test requirement. Simulate the kernel path
        // resolving to another signed file during verification.
        var checkedPath = false
        XCTAssertFalse(ChatClaudeProcess.hasValidSignature(pid, requirement: requirement, auditToken: nil,
            executablePath: { _ in checkedPath = true; return replacement.path }))
        XCTAssertTrue(checkedPath, "exercise the static/dynamic identity comparison")
    }

    func testPIDFallbackRejectsExecBetweenSignatureCheckAndDecision() throws {
        let first = try fixture(1), replacement = try fixture(2)
        let trigger = root.appendingPathComponent("exec")
        let pid = try start(first, arguments: [trigger.path, replacement.path])
        let oldToken = try XCTUnwrap(ChatClaudeProcess.auditToken(of: pid))
        var didExec = false
        XCTAssertFalse(ChatClaudeProcess.hasValidSignature(pid, requirement: try fixtureRequirement(), auditToken: nil,
            executablePath: { _ in
                do { try Data().write(to: trigger) } catch { XCTFail("\(error)"); return nil }
                let until = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < until {
                    if let path = ChatClaudeProcess.executablePath(of: pid),
                       URL(fileURLWithPath: path).resolvingSymlinksInPath() == replacement.resolvingSymlinksInPath() {
                        didExec = true; break
                    }
                    usleep(1000)
                }
                return first.path // the earlier file still has a valid signature
            }))
        XCTAssertTrue(didExec, "same PID really changed its executable image")
        XCTAssertFalse(ChatClaudeProcess.hasValidSignature(pid, requirement: try fixtureRequirement(), auditToken: oldToken),
                       "a token for the previous image must not downgrade to PID lookup")
    }

    func testImageIdentityDetectsExecAndFileReplacementAtTheSamePIDAndStart() throws {
        let first = try fixture(1), replacement = try fixture(2)
        let trigger = root.appendingPathComponent("exec")
        let pid = try start(first, arguments: [trigger.path, replacement.path])
        let start = try XCTUnwrap(ChatSessionIdentity.Process.read(pid)?.startedAtUs)
        let image = try XCTUnwrap(ChatClaudeProcess.imageIdentity(of: pid))
        XCTAssertEqual(ChatClaudeProcess.imageIdentity(of: pid), image)
        try Data().write(to: trigger)
        let until = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < until,
              ChatClaudeProcess.executablePath(of: pid).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) != replacement.resolvingSymlinksInPath() {
            usleep(1000)
        }
        XCTAssertEqual(ChatSessionIdentity.Process.read(pid)?.startedAtUs, start)
        let changed = try XCTUnwrap(ChatClaudeProcess.imageIdentity(of: pid))
        XCTAssertNotEqual(changed, image, "exec must invalidate the earlier signature")
        XCTAssertNotEqual(changed.inode, image.inode)
        // Same kernel executable path, but it now resolves to another vnode.
        try FileManager.default.removeItem(at: replacement)
        try FileManager.default.copyItem(at: first, to: replacement)
        XCTAssertNotEqual(ChatClaudeProcess.imageIdentity(of: pid), changed)
        child?.terminate(); child?.waitUntilExit()
        XCTAssertNil(ChatSessionIdentity.Process.read(pid))
        XCTAssertNil(ChatClaudeProcess.imageIdentity(of: pid))
        XCTAssertNil(ChatClaudeProcess.imageIdentity(of: 0))
    }
}
