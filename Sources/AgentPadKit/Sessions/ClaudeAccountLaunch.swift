import Foundation
import Darwin
import AgentPadHookKit

typealias ClaudeAccountSettings = AgentPadClaudeAccountSettings

/// One launch's private, one-shot credential source. Configs can wait in hidden
/// tabs for days: write only when the terminal actually starts its shell.
/// Neither the config nor this object retains a credential value.
@MainActor
final class ClaudeAccountLaunch {
    let fileURL: URL
    private let accountName: String
    private let tokenProvider: () throws -> String
    private let timeout: TimeInterval
    private var prepared = false
    var onFailure: ((String) -> Void)?

    init(accountName: String,
         temporaryDirectory: URL = ClaudeAccountLaunch.tokenDirectory,
         timeout: TimeInterval = 60, tokenProvider: @escaping () throws -> String) {
        self.accountName = accountName
        self.tokenProvider = tokenProvider
        self.timeout = timeout
        fileURL = temporaryDirectory
            .appendingPathComponent("agentpad-claude-\(getuid())-\(UUID())", isDirectory: true)
            .appendingPathComponent("oauth")
    }

    /// Stable, user-owned private root, so a later app start can remove sources
    /// left behind by Force Quit. The existing one-shot file format is unchanged.
    nonisolated static var tokenDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/agentpad/claude-account-tokens", isDirectory: true)
    }

    nonisolated private static func secureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw CocoaError(.fileWriteUnknown) }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, chmod(directory.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    nonisolated static func sweepAtStartup(directory: URL, legacyDirectory: URL? = nil) throws {
        try secureDirectory(directory)
        for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: item)
        }
        // The previous release put each private launch directory directly in
        // the user's temporary directory. Remove only that exact owned shape.
        if let legacyDirectory {
            let prefix = "agentpad-claude-\(getuid())-"
            for item in try FileManager.default.contentsOfDirectory(at: legacyDirectory, includingPropertiesForKeys: nil) {
                let name = item.lastPathComponent
                guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
                var info = stat()
                guard lstat(item.path, &info) == 0, info.st_uid == getuid(),
                      info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else { continue }
                try FileManager.default.removeItem(at: item)
            }
        }
    }

    private var unavailable: String {
        "Claude account “\(accountName)” is unavailable. Replace its token in Settings → Claude accounts."
    }

    /// Called at actual process creation. Settings are checked later by the
    /// bundled helper, after rc files can change the environment and cwd.
    func prepare() -> Bool {
        guard !prepared else { return true }
        let directory = fileURL.deletingLastPathComponent()
        do {
            let token = try tokenProvider()
            try Self.secureDirectory(directory.deletingLastPathComponent())
            guard mkdir(directory.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
            let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: Data((token + "\n").utf8))
            try handle.close()
            prepared = true
            let source = fileURL
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                Self.remove(source)
            }
            return true
        } catch {
            cleanup()
            onFailure?(unavailable)
            return false
        }
    }

    func cleanup() { Self.remove(fileURL) }
    deinit { Self.remove(fileURL) }

    nonisolated private static func remove(_ source: URL) {
        unlink(source.path)
        rmdir(source.deletingLastPathComponent().path)
    }

    nonisolated func command(_ launch: String) -> String {
        let file = AgentPadShellIntegration.quote(fileURL.path)
        let directory = AgentPadShellIntegration.quote(fileURL.deletingLastPathComponent().path)
        // A native shell assignment on exec keeps the value out of every argv.
        // `env KEY="$(...)"` would expose it in env's argv. This fresh non-login
        // sh also works when the tab's own shell is fish. +x prevents inherited
        // shell tracing from printing the expanded assignment.
        let script = """
        IFS= read -r _agentpad_oauth < \(file)
        _agentpad_read=$?
        /bin/rm -f -- \(file) || exit 1
        /bin/rmdir -- \(directory) 2>/dev/null
        [ "$_agentpad_read" -eq 0 ] && [ -n "$_agentpad_oauth" ] || exit 1
        CLAUDE_CODE_OAUTH_TOKEN="$_agentpad_oauth" exec \(launch)
        """
        let removals = (ClaudeAccountSettings.competingEnvironmentKeys + ["BASH_ENV", "ENV"])
            .map { "-u " + $0 }.joined(separator: " ")
        // Probe the existing command's argument validation before handing it
        // the launch. This needs no token, settings read, or running app, and
        // distinguishes a missing/stale helper from a real preflight refusal.
        let helperUnavailable = "Claude account “\(AgentPadHookKit.plain(accountName))” could not start because agentpad-cli is unavailable or does not support claude-account-check. Rebuild AgentPad or reinstall the app."
        let helperCheck = """
        _agentpad_check=$("$1" claude-account-check 2>&1)
        _agentpad_check_status=$?
        if [ "$_agentpad_check_status" -ne 1 ] || [ "$_agentpad_check" != 'agentpad-cli: invalid Claude account check arguments' ]; then
            /bin/rm -f -- "$4"
            /bin/rmdir -- \(directory) 2>/dev/null
            printf '%s\\n' \(AgentPadShellIntegration.quote(helperUnavailable)) >&2
            exit 1
        fi
        exec "$@"
        """
        return "/usr/bin/env \(removals) /bin/sh +x -c \(AgentPadShellIntegration.quote(helperCheck)) agentpad-claude-launch \(AgentPadShellIntegration.quote(AgentPadShellIntegration.agentPadCLIBinaryPath)) claude-account-check \(AgentPadShellIntegration.quote(accountName)) \(file) \(AgentPadShellIntegration.quote(script))"
    }
}
