import Foundation

// Team work, stage 2: agents this Mac publishes to colleagues, and the
// catalog colleagues see (docs/agentpad/TEAM.md 6.2, 7.4, 7.6).

/// What an agent may do on this Mac, chosen by its owner (A-2).
enum TeamAccessProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case read
    /// Edit and Write without a shell (owner's decision after Y1: profiles
    /// without Bash).
    case editFiles = "edit-files"
    case readGit = "read-git"
    case edit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: "Read"
        case .editFiles: "Edit files (no shell)"
        case .readGit: "Read and git"
        case .edit: "Edit"
        }
    }

    var summary: String {
        switch self {
        case .read: "Reads and searches files in the folder. Nothing else."
        case .editFiles: "Reads, edits and creates files in its folders. Runs no commands."
        case .readGit: "Reads files and runs git log, diff, show, status, blame and branch."
        case .edit: "Reads, edits and creates files in the folder; runs git read commands and the commands you list."
        }
    }

    /// The agent gets a shell (Bash): the Y1 report found its limits do not hold.
    var runsShell: Bool { self == .readGit || self == .edit }
    /// The agent runs git, which reads the whole repository: published only
    /// at a repository's top folder.
    var usesGit: Bool { self == .readGit || self == .edit }
    /// The owner lists the commands the agent may run.
    var takesCommands: Bool { self == .edit }

    /// Said when an agent with a shell is published and on its decision card (Y1).
    static let shellWarning = "Shell commands can reach outside the project folder, read your environment variables, and run code from the repository's settings and from your shell's configuration. Choose \"Read\" or \"Edit files (no shell)\" if the agent does not need to run commands."
    static let editFilesWarning = "The agent reads, edits and creates files in its folders, including CLAUDE.md, Makefile, package.json and build scripts, which you or your next Claude Code session may later run: check its changes. It runs no commands."

    /// The profiles the server takes (its `agents.access` check): every one
    /// since the server's migration for `editFiles` (server fdb6b70).
    static let serverAccepts = Set(TeamAccessProfile.allCases)

    /// Why `agents` cannot be published to the server yet, or nil.
    static func notOnServerYet(_ agents: [TeamPublishedAgent]) -> String? {
        guard let agent = agents.first(where: { !serverAccepts.contains($0.access) }) else { return nil }
        return "\(agent.name) is not published: the server does not take the \"\(agent.access.title)\" rights yet; choose Read for now"
    }
}

/// An agent published by this Mac (A-1…A-6). Lives in `agents.json`.
struct TeamPublishedAgent: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    /// Part of its address, `name@colleague`: lowercase letters, digits, dashes.
    var name: String
    /// What to ask it about; colleagues' agents read this to choose.
    var description: String
    /// The project folder it works in.
    var folder: String
    var access: TeamAccessProfile = .readGit
    /// Read rules that keep secrets out of reach (A-3).
    var deniedPaths: [String] = TeamPublishedAgent.defaultDeniedPaths
    /// Edit profile: command prefixes allowed besides git reads, e.g. `swift test`.
    var allowedCommands: [String] = []
    var maxTurns = 30
    var timeoutMinutes = 15
    var model: String?
    var maxBudgetUSD: Double?
    /// Colleagues who may call it, by key; nil means every colleague (A-5).
    var audience: [String]?
    var enabled = true
    /// The folder's git remotes, normalized; refreshed on every save.
    var remotes: [String] = []
    /// A session agent: the Claude Code conversation each call continues a
    /// copy of (`--resume <id> --fork-session`). Nil for a folder agent.
    /// Optional fields, so agents saved before them still load.
    var sessionId: String?
    /// The session's title when it was published, for the catalog.
    var sessionTitle: String?
    /// More folders the agent may work in besides `folder` (`--add-dir`),
    /// e.g. a second checkout or a shared knowledge repository.
    var extraFolders: [String]?

    var isSession: Bool { sessionId != nil }

    static let defaultDeniedPaths = [
        ".env", ".env.*", "*.pem", "*.key", "id_rsa*", "~/.ssh/**", "~/.aws/**", "~/.config/gh/**",
    ]

    static func isValidName(_ name: String) -> Bool {
        guard (1...32).contains(name.count), let first = name.first, first.isASCII, first.isLetter || first.isNumber else {
            return false
        }
        return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    func isOpen(to peer: String) -> Bool {
        enabled && (audience?.contains(peer) ?? true)
    }

    var catalogEntry: TeamCatalogEntry {
        TeamCatalogEntry(
            name: name, description: description, access: access, remotes: remotes,
            kind: isSession ? "session" : "agent", session: isSession ? sessionTitle : nil
        )
    }

    /// An ASCII name for an address: transliterated, lowercase, dashes —
    /// "Починить логин" → `pochinit-login`. Empty when nothing is left.
    static func suggestedName(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? text
        var out = ""
        for ch in latin.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) } else if !out.isEmpty && out.last != "-" { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        while out.count > 32 { out = String(out.prefix(32)); while out.hasSuffix("-") { out.removeLast() } }
        return out
    }
}

/// An agent as a colleague sees it. Field names follow A2A's agent card; the
/// folder and the exact rules stay on the owner's Mac (7.4).
struct TeamCatalogEntry: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var skills: [String] = []
    var runner = "claude-code"
    var access: TeamAccessProfile
    var remotes: [String]
    var approval = "ask"
    /// "agent" (a fresh run in a folder) or "session" (a copy of a live
    /// conversation). Optional: older AgentPads do not send it.
    var kind: String?
    /// session: the conversation's title.
    var session: String?
}

/// Claude Code's conversation files, `~/.claude/projects/<folder>/<id>.jsonl`.
enum TeamSessionFiles {
    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects") }

    static func isValidId(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    /// The conversation's file, or nil once it is gone.
    static func file(for sessionId: String, root: URL = root, visibility: ChannelConversationFilter = .current()) -> URL? {
        guard visibility.allows(conversationId: sessionId), isValidId(sessionId),
              let projects = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return nil }
        let name = "\(sessionId.lowercased()).jsonl"
        return projects.lazy.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func exists(_ sessionId: String, root: URL = root) -> Bool { file(for: sessionId, root: root) != nil }

    /// The folder the conversation ran in, from its first lines: resuming
    /// it only works from there.
    static func workingDirectory(of sessionId: String, root: URL = root) -> String? {
        guard let url = file(for: sessionId, root: root), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        for line in head.split(separator: 0x0A).prefix(200) {
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let cwd = object["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
        }
        return nil
    }
}

/// Where a call comes from, as the caller describes it.
struct TeamCallOrigin: Codable, Equatable, Sendable {
    var session: String?
    var project: String?
}

enum TeamCallState: String, Codable, Sendable {
    case queued
    case awaitingApproval = "awaiting_approval"
    case running, done, failed, denied, cancelled, expired
    /// A server's state this AgentPad does not know: not final, nothing to
    /// do, said so (server `docs/api.md`).
    case unknown

    var isFinal: Bool {
        switch self {
        case .queued, .awaitingApproval, .running, .unknown: false
        case .done, .failed, .denied, .cancelled, .expired: true
        }
    }
}

/// A call as the owner reports it to the caller (`call.status`).
struct TeamCallReport: Codable, Equatable, Sendable {
    var callId: String
    var state: TeamCallState
    var threadId: String?
    /// done: the answer.
    var text: String?
    var truncated: Bool?
    var turns: Int?
    var durationMs: Int?
    /// running: what the agent is doing now, e.g. "Grep".
    var activity: String?
    /// failed, denied, expired: why, in a few plain words.
    var detail: String?
}

/// Git remotes as hosts and paths — `github.com/acme/shop` — so two clones
/// of one project match whatever protocol or credentials they use (7.4).
enum TeamGitRemote {
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        // A local repository is not a shared project, and its path is private.
        guard !s.isEmpty, !s.lowercased().hasPrefix("file:") else { return nil }
        if let scheme = s.range(of: "://") {
            s = String(s[scheme.upperBound...])
            // Credentials and port go; the path stays.
            if let slash = s.firstIndex(of: "/") {
                var host = String(s[..<slash])
                if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
                if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
                s = host + String(s[slash...])
            }
        } else if let colon = s.firstIndex(of: ":"), !s.hasPrefix("/") {
            // scp-like: git@github.com:acme/shop.git
            var host = String(s[..<colon])
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            s = host + "/" + s[s.index(after: colon)...]
        } else {
            return nil  // a local path is not a shared project
        }
        if s.hasSuffix(".git") { s.removeLast(4) }
        while s.hasSuffix("/") { s.removeLast() }
        let lowered = s.lowercased()
        return lowered.contains("/") ? lowered : nil
    }

    /// The remotes of the repository at `folder`; empty when it has none.
    static func remotes(of folder: String) async -> [String] {
        guard let (status, output) = await git(["-C", folder, "remote", "-v"]), status == 0 else { return [] }
        var seen: [String] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let remote = normalize(String(parts[1])), !seen.contains(remote) else { continue }
            seen.append(remote)
        }
        return seen
    }

    /// The top folder of the repository holding `folder`, or nil outside
    /// one. Throws when git could not tell, so a check built on it fails closed.
    static func topLevel(of folder: String) async throws -> String? {
        guard let (status, output) = await git(["-C", folder, "rev-parse", "--show-toplevel"]) else {
            throw TeamError.storage("git did not answer for \(folder)")
        }
        if status == 0 { return output.trimmingCharacters(in: .whitespacesAndNewlines) }
        if status == 128 { return nil }  // not a repository
        throw TeamError.storage("git could not read \(folder)")
    }

    /// Runs git for metadata, stopped after three seconds: these answers are
    /// optional and must not hold a request.
    private static func git(_ arguments: [String]) async -> (Int32, String)? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let timedOut = TeamOnce()
            let timer = DispatchWorkItem {
                if process.isRunning, timedOut.claim() { kill(process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            guard timedOut.claim(), process.terminationReason == .exit else { return nil }
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}

/// How a colleague is written in an agent's address: their name in lowercase,
/// with dashes for spaces — `backend@alexander-eliseenko`.
enum TeamHandle {
    static func make(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch) } else if out.last != "-" && !out.isEmpty { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// The colleague an address names: by handle of their shown or own name,
    /// by first name when only one colleague has it, or by key prefix.
    static func resolve(_ handle: String, in contacts: [TeamCaller]) -> TeamCaller? {
        let h = make(handle)
        guard !h.isEmpty else { return nil }
        let exact = contacts.filter { make($0.displayName) == h }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        let first = contacts.filter { make($0.displayName).split(separator: "-").first.map(String.init) == h }
        if first.count == 1 { return first[0] }
        if handle.count >= 8, handle.allSatisfy(\.isHexDigit) {
            let byKey = contacts.filter { $0.id.hasPrefix(handle.lowercased()) }
            if byKey.count == 1 { return byKey[0] }
        }
        return nil
    }
}
