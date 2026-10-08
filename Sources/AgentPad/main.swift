import AppKit
import AgentPadKit

if CommandLine.arguments.contains("--self-check-emoji-resources") {
    exit(AgentPadResourceSelfCheck.run() ? 0 : 1)
}

#if DEBUG
if CommandLine.arguments.contains("--self-check-no-modals") { AgentPadNoModalsSelfCheck.run() }
if CommandLine.arguments.contains("--self-check-first-launch") { AgentPadFirstLaunchSelfCheck.run() }
#endif

CrashForensics.install()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
