#if DEBUG
import Foundation
import CoreGraphics
import XCTest

/// Each child has its own settings/state files and its first-ever libghostty
/// runtime. It drives the existing NSAlert and the real AppDelegate entries.
final class FirstLaunchTests: XCTestCase {
    private func check(_ modes: [String]) throws {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else {
            throw XCTSkip("First-launch checks require an unlocked, logged-in GUI session on the console.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentpad-first-launch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var succeeded = false
        defer { if succeeded { try? FileManager.default.removeItem(at: root) } }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for mode in modes {
            let log = root.appendingPathComponent(mode + ".log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = repository.appendingPathComponent(".build/debug/AgentPad")
            process.arguments = ["--self-check-first-launch", mode]
            var environment = ProcessInfo.processInfo.environment
            environment["AGENTPAD_DEBUG_CONFIG_DIRECTORY"] = root.appendingPathComponent("config").path
            environment["AGENTPAD_DEBUG_STATE_PATH"] = root.appendingPathComponent("state-v2.json").path
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
            if process.terminationStatus != 0 { return }
        }
        succeeded = true
    }
    func testImportWithoutGlassFirstEditorCancelAndRestart() throws { try check(["import-opaque", "restart"]) }
    func testImportWithGlassFirstEditorCancelAndRestart() throws { try check(["import-glass", "restart"]) }
    func testStartFreshThenSettingsEditsSurviveRestart() throws { try check(["fresh", "restart"]) }
    func testNoGhosttyConfigWritesTemplate() throws { try check(["no-config"]) }
    func testExistingSettingsSkipWelcomeAndStayUnchanged() throws { try check(["existing"]) }
}
#endif
