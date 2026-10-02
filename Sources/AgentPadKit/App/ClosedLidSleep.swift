import AppKit
import AgentPadHookKit

/// Privileged plumbing for closed-lid mode. A closed lid *forces* sleep and
/// no user-space assertion can stop it — the only public lever is
/// `pmset -a disablesleep`, which needs root. Same model as Capsomnia:
/// a one-time admin authorization installs a root-owned helper that can run
/// exactly two fixed pmset commands, plus a sudoers rule letting this user
/// invoke it without a password. From then on AgentPad toggles lid sleep
/// automatically around agent/SSH activity.
///
/// Security invariants:
/// - The helper lives in root-owned `/Library/PrivilegedHelperTools`, mode
///   755 — a non-admin user can't rewrite what the sudoers rule trusts.
/// - The sudoers rule whitelists the helper's absolute path with exact
///   arguments (`on` / `off`), nothing else.
/// - The sudoers file is validated with `visudo -cf` BEFORE it lands in
///   `/etc/sudoers.d` — a malformed file there breaks sudo system-wide.
/// - Runtime calls use `sudo -n` (never prompt): if the rule is missing the
///   call fails fast instead of hanging.
enum ClosedLidSleep {
    /// Where `installScript` puts the helper.
    static let installedHelperPath = "/Library/PrivilegedHelperTools/agentpad-sleepctl"
    /// No dot in the filename — sudoers.d silently ignores files containing one.
    static let sudoersPath = "/etc/sudoers.d/agentpad-sleepctl"

    /// AgentPad: the helper to call — the current one, else one authorized
    /// under the name an earlier build used (`LegacyNames`), so an upgrade
    /// keeps a granted authorization working.
    static var helperPath: String {
        if pairExists(installedHelperPath, sudoersPath) { return installedHelperPath }
        if pairExists(LegacyNames.sleepHelperPath, LegacyNames.sleepSudoersPath) {
            return LegacyNames.sleepHelperPath
        }
        return installedHelperPath
    }

    /// Both artifacts present = the one-time authorization already happened.
    static var isInstalled: Bool {
        pairExists(installedHelperPath, sudoersPath)
            || pairExists(LegacyNames.sleepHelperPath, LegacyNames.sleepSudoersPath)
    }

    private static func pairExists(_ helper: String, _ sudoers: String) -> Bool {
        FileManager.default.fileExists(atPath: helper) && FileManager.default.fileExists(atPath: sudoers)
    }

    /// The root helper: a fixed two-verb wrapper around pmset. `exec` so the
    /// exit status is pmset's own.
    static let helperScript = """
    #!/bin/sh
    case "$1" in
      on)  exec /usr/bin/pmset -a disablesleep 1 ;;
      off) exec /usr/bin/pmset -a disablesleep 0 ;;
      *)   exit 64 ;;
    esac
    """

    /// Installer, run once as root via macOS's admin-password prompt.
    /// Takes the invoking user's short name as $1 (the script itself runs
    /// as root, so $USER would be "root"). `set -e` + visudo gate: nothing
    /// lands in sudoers.d unless it validates.
    static let installScript = """
    #!/bin/sh
    set -e
    u="$1"
    case "$u" in
      *[!A-Za-z0-9._-]*|"") echo "bad username" >&2; exit 65 ;;
    esac
    mkdir -p /Library/PrivilegedHelperTools
    cat > /Library/PrivilegedHelperTools/agentpad-sleepctl <<'HELPER'
    \(helperScript)
    HELPER
    chown root:wheel /Library/PrivilegedHelperTools/agentpad-sleepctl
    chmod 755 /Library/PrivilegedHelperTools/agentpad-sleepctl
    t=$(mktemp)
    printf '%s ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/agentpad-sleepctl on, /Library/PrivilegedHelperTools/agentpad-sleepctl off\\n' "$u" > "$t"
    /usr/sbin/visudo -cf "$t"
    cp "$t" /etc/sudoers.d/agentpad-sleepctl
    chown root:wheel /etc/sudoers.d/agentpad-sleepctl
    chmod 440 /etc/sudoers.d/agentpad-sleepctl
    rm -f "$t"
    """

    /// Runs the one-time install through the system admin-auth dialog.
    /// Completion on the main actor: true = installed, false = user
    /// cancelled or the script failed.
    static func install(completion: @escaping @MainActor (Bool) -> Void) {
        let user = NSUserName()
        // Same charset the install script enforces; refuse odd names early.
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            Task { @MainActor in completion(false) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let dir = FileManager.default.temporaryDirectory
            let scriptURL = dir.appendingPathComponent("agentpad-lid-install-\(UUID().uuidString.prefix(8)).sh")
            do {
                try installScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            } catch {
                Task { @MainActor in completion(false) }
                return
            }
            defer { try? FileManager.default.removeItem(at: scriptURL) }

            // osascript shows the native admin prompt; the quoted-form path +
            // validated username are the only interpolations.
            let apple = """
            do shell script "/bin/sh '\(scriptURL.path)' '\(user)'" with administrator privileges with prompt "\(AppIdentity.appName) needs a one-time authorization to keep working with the lid closed."
            """
            let ok = runProcess("/usr/bin/osascript", ["-e", apple], timeout: 180)
            Task { @MainActor in completion(ok && isInstalled) }
        }
    }

    /// Toggle lid sleep through the installed helper. `sudo -n` fails fast
    /// (no prompt) when the rule is missing. Completion on the main actor.
    static func setDisabled(_ disabled: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = runProcess("/usr/bin/sudo", ["-n", helperPath, disabled ? "on" : "off"], timeout: 10)
            Task { @MainActor in completion(ok) }
        }
    }

    /// Synchronous best-effort "off" for app termination — the one moment a
    /// completion handler can't help. Bounded by the same short timeout.
    static func forceOffSynchronously() {
        _ = runProcess("/usr/bin/sudo", ["-n", helperPath, "off"], timeout: 5)
    }

    /// Whether the system currently has sleep disabled (`pmset -g` reports
    /// `SleepDisabled 1`). Readable without root. Returns nil when the
    /// query fails or the output is unrecognizable — callers must treat
    /// "unknown" differently from "confirmed off" (mistaking a query
    /// hiccup for an external release would veto the user's dial).
    static func systemSleepCurrentlyDisabled() -> Bool? {
        guard let out = runProcessCapture("/usr/bin/pmset", ["-g"], timeout: 5),
              let line = out.split(separator: "\n").first(where: { $0.lowercased().contains("sleepdisabled") })
        else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("1") { return true }
        if trimmed.hasSuffix("0") { return false }
        return nil
    }

    // MARK: - Ownership marker

    /// Marker file recording "AgentPad engaged SleepDisabled". Written before
    /// every engage, removed after a confirmed release. Lets launch
    /// reconciliation distinguish AgentPad's own crash straggler (safe to
    /// clear) from a SleepDisabled the user or another tool set on purpose
    /// (absorb, never clear).
    private static var ownershipMarkerURL: URL {
        AgentPadShellIntegration.agentPadAppSupport("lid-engaged", isDirectory: false)
    }

    static var ownsLidState: Bool {
        FileManager.default.fileExists(atPath: ownershipMarkerURL.path)
    }

    static func markLidOwnership() {
        FileManager.default.createFile(atPath: ownershipMarkerURL.path, contents: nil)
    }

    static func clearLidOwnership() {
        try? FileManager.default.removeItem(at: ownershipMarkerURL)
    }

    // MARK: - Process plumbing

    /// stdio → null (a filling, never-drained pipe is the runGit deadlock
    /// class); watchdog kill so a hung sudo can't strand the caller.
    private static func runProcess(_ path: String, _ args: [String], timeout: TimeInterval) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let deadline = DispatchTime.now() + timeout
        let sema = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sema.signal() }
        if sema.wait(timeout: deadline) == .timedOut {
            p.terminate()
            return false
        }
        return p.terminationStatus == 0
    }

    private static func runProcessCapture(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Read concurrently with the exit wait (pipe-deadlock rule).
        let drain = PipeDrain.draining(pipe)
        let deadline = DispatchTime.now() + timeout
        let exitSema = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exitSema.signal() }
        if exitSema.wait(timeout: deadline) == .timedOut {
            p.terminate()
            return nil
        }
        drain.done.wait()
        return String(data: drain.data, encoding: .utf8)
    }
}
