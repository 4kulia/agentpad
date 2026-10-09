#if DEBUG
import AppKit

/// A separate process per configuration: the first libghostty initialization
/// cannot be tested by reloading a singleton in the XCTest host.
@MainActor
public enum AgentPadFirstLaunchSelfCheck {
    enum Failure: Error { case check(String) }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure.check(message) }
    }
    static func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try require(condition(), "Timed out waiting for \(message); app active: \(NSApp.isActive), key window: \(String(describing: NSApp.keyWindow?.windowNumber))")
    }
    public static func run() -> Never {
        guard ProcessInfo.processInfo.environment["AGENTPAD_DEBUG_CONFIG_DIRECTORY"] != nil,
              ProcessInfo.processInfo.environment["AGENTPAD_DEBUG_STATE_PATH"] != nil,
              let mode = CommandLine.arguments.last else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        AgentPadFonts.registerOnce()
        let delegate = AppDelegate()
        Task { @MainActor in
            do {
                try await delegate.checkFirstLaunch(mode: mode)
                await delegate.endFirstLaunchCheck()
                print("First launch \(mode): PASS"); exit(0)
            } catch {
                await delegate.endFirstLaunchCheck()
                fputs("First launch \(mode): FAIL: \(error)\n", stderr); exit(1)
            }
        }
        app.run()
        exit(1)
    }
}
#endif
