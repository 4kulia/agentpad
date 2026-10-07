import AppKit
import AgentPadKit

if CommandLine.arguments.contains("--self-check-emoji-resources") {
    exit(AgentPadResourceSelfCheck.run() ? 0 : 1)
}

CrashForensics.install()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
