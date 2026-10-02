import Foundation

// Team work, stage 2: agents this Mac publishes to colleagues, and the
// catalog colleagues see (docs/agentpad/TEAM.md 6.2, 7.4, 7.6).

/// What an agent may do on this Mac, chosen by its owner (A-2).
enum TeamAccessProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case read
    case readGit = "read-git"
    case edit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: "Read"
        case .readGit: "Read and git"
        case .edit: "Edit"
        }
    }

    var summary: String {
        switch self {
        case .read: "Reads and searches files in the folder. Nothing else."
        case .readGit: "Reads files and runs git log, diff, show, status, blame and branch."
        case .edit: "Reads, edits and creates files in the folder; runs git read commands and the commands you list."
        }
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
        TeamCatalogEntry(name: name, description: description, access: access, remotes: remotes)
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

    var isFinal: Bool {
        switch self {
        case .queued, .awaitingApproval, .running: false
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
                if process.isRunning, timedOut.claim() { TeamProcesses.signal(process.processIdentifier, SIGKILL) }
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
    static func resolve(_ handle: String, in contacts: [TeamContact]) -> TeamContact? {
        let h = make(handle)
        guard !h.isEmpty else { return nil }
        let exact = contacts.filter { make($0.displayName) == h || make($0.name) == h }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        let first = contacts.filter {
            make($0.displayName).split(separator: "-").first.map(String.init) == h
                || make($0.name).split(separator: "-").first.map(String.init) == h
        }
        if first.count == 1 { return first[0] }
        if handle.count >= 8, handle.allSatisfy(\.isHexDigit) {
            let byKey = contacts.filter { $0.id.hasPrefix(handle.lowercased()) }
            if byKey.count == 1 { return byKey[0] }
        }
        return nil
    }
}
