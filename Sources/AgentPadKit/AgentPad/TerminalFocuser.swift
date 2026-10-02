import AppKit
import Foundation

/// Brings an external session's terminal tab to the front.
///
/// Terminal.app and iTerm2 both expose each tab's tty over AppleScript, which
/// is the one identifier we share with the session (its controlling terminal).
/// Any other terminal just gets activated. Runs `osascript` rather than
/// NSAppleScript so a slow or permission-blocked script never stalls the main
/// thread; the Automation prompt still names this app as the requester.
enum TerminalFocuser {
    enum Outcome: Equatable {
        case focusedTab
        case activatedAppOnly
        case noTerminalFound
    }

    static let terminalBundleId = "com.apple.Terminal"
    static let iTermBundleId = "com.googlecode.iterm2"

    @MainActor
    static func focus(_ session: ExternalAgentSession) async -> Outcome {
        guard let app = ProcessInfoReader.hostingApp(of: session.pid) else { return .noTerminalFound }
        // Cheap guard against focusing a stranger: the row's process must
        // still be the instance we listed.
        if let start = session.processStart, ProcessInfoReader.info(of: session.pid)?.startTime != start {
            return .noTerminalFound
        }
        if let tty = session.tty, let script = script(for: app.bundleIdentifier, tty: "/dev/\(tty)") {
            let found = await Task.detached { runOSAScript(script) }.value
            if found { return .focusedTab }
        }
        app.activate()
        return .activatedAppOnly
    }

    /// Nil for terminals without a scriptable tty lookup.
    static func script(for bundleId: String?, tty: String) -> String? {
        let quoted = "\"\(tty.replacingOccurrences(of: "\"", with: ""))\""
        switch bundleId {
        case terminalBundleId:
            return """
            tell application id "\(terminalBundleId)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(quoted) then
                            set selected tab of w to t
                            set index of w to 1
                            activate
                            return "found"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        case iTermBundleId:
            return """
            tell application id "\(iTermBundleId)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is \(quoted) then
                                select w
                                tell t to select
                                tell s to select
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        default:
            return nil
        }
    }

    /// tty of the selected tab in the terminal's front window, or nil when
    /// the terminal isn't one we can ask.
    static func frontTabTTY(of bundleId: String?) async -> String? {
        let script: String
        switch bundleId {
        case terminalBundleId:
            script = "tell application id \"\(terminalBundleId)\" to return tty of selected tab of front window"
        case iTermBundleId:
            script = "tell application id \"\(iTermBundleId)\" to return tty of current session of current window"
        default:
            return nil
        }
        return await Task.detached { runOSAScriptOutput(script) }.value
    }

    private static func runOSAScript(_ source: String) -> Bool {
        runOSAScriptOutput(source) == "found"
    }

    private static func runOSAScriptOutput(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
