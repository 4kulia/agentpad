#if DEBUG
import Foundation
import XCTest

/// Each child has its own settings/state files and its first-ever libghostty
/// runtime. It drives PopupHost and the real AppDelegate startup entries.
/// Structural/configuration checks also run while locked; the child explicitly
/// reports whether native keyboard/focus checks ran on an unlocked console.
final class FirstLaunchTests: XCTestCase {
    private func check(_ modes: [String]) throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent(".build/pop3c-first-launch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for mode in modes {
            let log = root.appendingPathComponent(mode + ".log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = repository.appendingPathComponent(".build/debug/AgentPad")
            process.arguments = ["--self-check-first-launch", mode]
            var environment = ProcessInfo.processInfo.environment
            environment["TMPDIR"] = repository.appendingPathComponent(".build/tmp").path
            environment["CFFIXED_USER_HOME"] = repository.appendingPathComponent(".build/test-home").path
            environment["AGENTPAD_DEBUG_CONFIG_DIRECTORY"] = root.appendingPathComponent("config").path
            environment["AGENTPAD_DEBUG_STATE_PATH"] = root.appendingPathComponent("state-v2.json").path
            let libraries = ["libAgentPadQuietInterposer.dylib", "libAgentPadQuietTestSupport.dylib"]
                .map { repository.appendingPathComponent(".build/debug/\($0)").path }
            for library in libraries {
                guard FileManager.default.fileExists(atPath: library) else {
                    throw NSError(domain: "QuietHarness", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing quiet library: \(library)"])
                }
            }
            environment["AGENTPAD_QUIET_TEST"] = "1"
            environment["DYLD_INSERT_LIBRARIES"] = libraries.joined(separator: ":")
            process.environment = environment
            process.standardOutput = output; process.standardError = output
            try process.run()
            let deadline = Date().addingTimeInterval(40)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try output.close()
            let text = try String(contentsOf: log, encoding: .utf8)
            XCTAssertEqual(process.terminationStatus, 0, "\(mode); diagnostic log: \(log.path): \(text.suffix(6000))")
            XCTAssertTrue(text.contains("First launch \(mode): PASS"), "\(mode): \(text.suffix(6000))")
            XCTAssertTrue(text.contains("QUIET PASS:"), "\(mode): containment proof is missing")
            for line in text.split(separator: "\n") where line.hasPrefix("First launch ") || line.hasPrefix("First-launch native interactions:") {
                print(line)
            }
            print("First-launch log: \(log.path)")
            if process.terminationStatus != 0 { return }
        }
    }
    func testImportWithoutGlassFirstEditorCancelAndRestart() throws { try check(["import-opaque", "restart"]) }
    func testImportWithGlassFirstEditorCancelAndRestart() throws { try check(["import-glass", "restart"]) }
    func testStartFreshThenSettingsEditsSurviveRestart() throws { try check(["fresh", "restart"]) }
    func testNoGhosttyConfigWritesTemplate() throws { try check(["no-config"]) }
    func testExistingSettingsSkipWelcomeAndStayUnchanged() throws { try check(["existing"]) }
    func testQuitLeavesChoicePendingOnNextLaunch() throws { try check(["quit", "fresh", "restart"]) }
    func testPendingStartupWindowIsRevealedByWindowOpeningEntries() throws { try check(["window-entries"]) }

    func testSelfChecksFailClosedWithoutInjectedSupport() throws {
        try checkMissingContainment(library: nil, diagnostic: "QUIET FAIL: missing injected test support")
    }

    func testSelfChecksFailClosedWithoutAudioInterposer() throws {
        try checkMissingContainment(library: "libAgentPadQuietTestSupport.dylib",
                                    diagnostic: "QUIET FAIL: launch with DYLD_INSERT_LIBRARIES")
    }

    private func checkMissingContainment(library: String?, diagnostic: String) throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent(".build/quiet-missing-support-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for arguments in [["--self-check-first-launch", "existing"], ["--self-check-no-modals"]] {
            let process = Process(), output = Pipe()
            process.executableURL = repository.appendingPathComponent(".build/debug/AgentPad")
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
            if let library {
                environment["DYLD_INSERT_LIBRARIES"] = repository.appendingPathComponent(".build/debug/\(library)").path
            }
            environment["HOME"] = root.path
            environment["CFFIXED_USER_HOME"] = root.path
            environment["AGENTPAD_DEBUG_CONFIG_DIRECTORY"] = root.appendingPathComponent("config").path
            environment["AGENTPAD_DEBUG_STATE_PATH"] = root.appendingPathComponent("state.json").path
            process.environment = environment
            process.standardOutput = output; process.standardError = output
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationReason, .exit, text)
            XCTAssertEqual(process.terminationStatus, 1, text)
            XCTAssertTrue(text.contains(diagnostic), text)
        }
    }
}
#endif
