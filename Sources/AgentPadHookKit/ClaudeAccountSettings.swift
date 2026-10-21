import Darwin
import Foundation

/// Shared with the app, but evaluated by the bundled CLI after shell startup.
/// Diagnostics contain source paths and key names only, never settings values.
public struct AgentPadClaudeAccountSettings {
    public var homeDirectory: URL
    public var environment: [String: String]
    public var managedSettings: URL

    public init(homeDirectory: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                managedSettings: URL = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")) {
        self.homeDirectory = homeDirectory
            ?? environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.environment = environment
        self.managedSettings = managedSettings
    }

    public static let competingEnvironmentKeys = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_OAUTH_TOKEN", "apiKeyHelper",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_USE_ANTHROPIC_AWS",
    ]

    public static func isCompeting(_ key: String) -> Bool {
        competingEnvironmentKeys.contains(key) || key.hasPrefix("CLAUDE_CODE_USE_")
    }

    /// Passed as separate argv entries to env; values never enter argv.
    public var environmentRemovals: [String] {
        Set(Self.competingEnvironmentKeys + ["BASH_ENV", "ENV"]
            + environment.keys.filter(Self.isCompeting)).sorted()
    }

    public static func optionsFailure(_ options: String?) -> String? {
        guard let options, options.contains("--settings") || options.contains("--setting-sources") else { return nil }
        return "Claude account launches cannot use --settings or --setting-sources. Remove those options or use Main account."
    }

    private var wrapperSettingsPath: String? {
        guard let surface = environment["AGENTPAD_SURFACE_ID"], !surface.isEmpty,
              let path = environment["AGENTPAD_HOOKS_PATH"], !path.isEmpty else { return nil }
        return path
    }

    private func wrapperSettings(in folder: URL) -> URL? {
        wrapperSettingsPath.map {
            URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: folder.path, isDirectory: true))
                .standardizedFileURL
        }
    }

    public func files(in folder: URL) -> [URL] {
        let userDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path,
                                    relativeTo: URL(fileURLWithPath: folder.path, isDirectory: true)).standardizedFileURL
        } ?? homeDirectory.appendingPathComponent(".claude")
        var files = [userDirectory.appendingPathComponent("settings.json")]
        var folders = [folder]
        if let root = gitPath("--show-toplevel", in: folder) { folders.append(root) }
        if let common = gitPath("--git-common-dir", in: folder), common.lastPathComponent == ".git" {
            folders.append(common.deletingLastPathComponent())
        }
        for directory in folders {
            files.append(directory.appendingPathComponent(".claude/settings.json"))
            files.append(directory.appendingPathComponent(".claude/settings.local.json"))
        }
        // The existing Claude shim injects this final-environment source with
        // --settings. Shell rc files can replace the app's generated hook path.
        if let wrapper = wrapperSettings(in: folder) { files.append(wrapper) }
        files.append(managedSettings)
        let fragments = managedSettings.deletingLastPathComponent().appendingPathComponent("managed-settings.d")
        var info = stat()
        if lstat(fragments.path, &info) == 0 || errno != ENOENT {
            do {
                let entries = try FileManager.default.contentsOfDirectory(at: fragments, includingPropertiesForKeys: nil)
                files += entries.filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                // Include the unreadable directory so the same fail-closed read
                // below names it instead of silently ignoring the policy.
                files.append(fragments)
            }
        }
        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func gitPath(_ option: String, in folder: URL) -> URL? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path, "rev-parse", option]
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: folder.path, isDirectory: true)).standardizedFileURL
    }

    public func failure(accountName: String, folder: URL) -> String? {
        if let path = wrapperSettingsPath, let file = wrapperSettings(in: folder) {
            var info = stat()
            // This variable is a file path in the shell integration. Do not let
            // inline --settings JSON bypass enumeration, or echo its values.
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
                  stat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  access(file.path, R_OK) == 0 else {
                return "AGENTPAD_HOOKS_PATH must name a readable settings file for a Claude account launch. Fix it or use Main account."
            }
        }
        for file in files(in: folder) {
            var info = stat()
            if lstat(file.path, &info) != 0, errno == ENOENT { continue }
            let prefix = "Claude account “\(accountName)” can’t be used here: \(file.path)"
            let settings: [String: Any]
            do {
                let data = try Data(contentsOf: file)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return "\(prefix) isn’t a valid JSON settings object. Fix it or use Main account."
                }
                settings = object
            } catch {
                return "\(prefix) is unreadable or contains invalid JSON. Fix it or use Main account."
            }
            let key: String?
            if settings["apiKeyHelper"] != nil {
                key = "apiKeyHelper"
            } else if let env = settings["env"] as? [String: Any] {
                key = env.keys.sorted().first(where: Self.isCompeting).map { "env." + $0 }
            } else {
                key = nil
            }
            if let key {
                return "\(prefix) sets \(key), which Claude Code prefers over the account. Remove it or use Main account."
            }
        }
        return nil
    }
}
