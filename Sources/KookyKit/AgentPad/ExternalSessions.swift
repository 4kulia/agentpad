import AppKit
import Darwin
import Foundation

// MARK: - Model

/// A Claude Code session that is alive right now but NOT running inside one of
/// our own tabs — typically a `claude` started in Terminal.app or iTerm2.
/// These are invisible to `AgentMonitor`, which only walks our own panes.
struct ExternalAgentSession: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case busy
        case waiting(reason: String?)
        case idle
        /// A value this build doesn't know. Shown neutrally rather than guessed.
        case other(String)

        init(raw: String, waitingFor: String?) {
            switch raw {
            case "busy", "shell": self = .busy
            case "waiting": self = .waiting(reason: waitingFor)
            case "idle": self = .idle
            default: self = .other(raw)
            }
        }
    }

    let pid: pid_t
    let sessionId: String
    /// `interactive` or `background` (Claude Code's own agent view sessions).
    let kind: String?
    let cwd: URL
    /// Claude Code's own name for the session (often derived from the folder).
    let name: String?
    let status: Status
    /// When the session entered `status`. Nil when the source doesn't say.
    let statusSince: Date?
    let startedAt: Date?
    /// `ttys034`-style device name of the controlling terminal, when known.
    var tty: String?
    /// Conversation title from the transcript (`ai-title`, rename, or first prompt).
    var title: String?
    /// Exact start time of the process we verified as this session's `claude`.
    /// Together with `pid` it identifies the process instance, so a PID that
    /// was recycled after the session ended can't be mistaken for it.
    var processStart: TimeInterval?

    /// Two processes can hold the same conversation, so the row is the process.
    var id: String { "\(pid):\(sessionId)" }

    /// Only an explicitly idle, verified, interactive session can be moved:
    /// a busy one would lose its in-flight turn, a waiting one may be mid
    /// permission prompt, and a background one has no terminal of its own.
    var canTakeOver: Bool {
        status == .idle && kind != "background" && processStart != nil
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let name, !name.isEmpty { return name }
        return cwd.lastPathComponent
    }

    var monitorState: AgentMonitor.State {
        switch status {
        case .waiting: return .attention
        case .busy: return .running
        case .idle, .other: return .idle
        }
    }
}

// MARK: - Parsing

/// Pure parsers for Claude Code's live-session sources. Both formats are
/// Claude Code internals with no stability promise, so every field is
/// optional except the three a row can't exist without (pid, id, cwd).
enum ExternalSessionParser {
    /// One `~/.claude/sessions/<pid>.json` file, or one element of
    /// `claude agents --json` — the two share field names.
    static func session(from object: [String: Any]) -> ExternalAgentSession? {
        guard let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0,
              let sessionId = object["sessionId"] as? String, !sessionId.isEmpty,
              let cwd = object["cwd"] as? String, cwd.hasPrefix("/")
        else { return nil }
        // A missing status is unknown, not idle — it must not unlock "Move Here".
        let raw = (object["status"] as? String) ?? "unknown"
        return ExternalAgentSession(
            pid: pid,
            sessionId: sessionId,
            kind: object["kind"] as? String,
            cwd: URL(fileURLWithPath: cwd),
            name: object["name"] as? String,
            status: .init(raw: raw, waitingFor: object["waitingFor"] as? String),
            statusSince: date(ms: object["statusUpdatedAt"]),
            startedAt: date(ms: object["startedAt"])
        )
    }

    /// `claude agents --json` output: a JSON array of sessions.
    static func sessions(fromAgentsJSON data: Data) -> [ExternalAgentSession]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        return array.compactMap(session(from:))
    }

    private static func date(ms value: Any?) -> Date? {
        guard let ms = (value as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// The title candidates found in some transcript lines. Kept apart so a
    /// later partial read can't replace a rename it didn't see.
    struct TitleParts: Equatable, Sendable {
        var custom: String?
        var ai: String?
        var firstPrompt: String?

        /// Newer reads win field by field; a field the newer read didn't find
        /// keeps its earlier value.
        func updated(with newer: TitleParts) -> TitleParts {
            TitleParts(
                custom: newer.custom ?? custom,
                ai: newer.ai ?? ai,
                firstPrompt: firstPrompt ?? newer.firstPrompt
            )
        }

        /// What Claude Code itself shows: a /rename, then the generated title,
        /// then the first prompt.
        var best: String? {
            guard let best = custom ?? ai ?? firstPrompt else { return nil }
            let cleaned = AgentSessionScanner.cleanedTitle(best)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    static func title(fromTranscriptLines lines: [Data]) -> String? {
        titleParts(fromTranscriptLines: lines).best
    }

    static func titleParts(fromTranscriptLines lines: [Data]) -> TitleParts {
        var custom: String?
        var ai: String?
        var firstPrompt: String?
        for line in lines {
            guard let object = AgentSessionScanner.jsonObject(line) else { continue }
            switch object["type"] as? String {
            case "custom-title":
                if let value = object["customTitle"] as? String { custom = value }
            case "ai-title":
                if let value = object["aiTitle"] as? String { ai = value }
            case "user":
                if firstPrompt == nil,
                   object["isSidechain"] as? Bool != true,
                   let message = object["message"] as? [String: Any] {
                    firstPrompt = AgentSessionScanner.displayableUserText(
                        AgentSessionScanner.messageContent(message["content"])
                    )
                }
            default:
                break
            }
        }
        return TitleParts(custom: custom, ai: ai, firstPrompt: firstPrompt)
    }
}

// MARK: - Processes

/// Thin libproc wrappers. Cheap enough to call for every session on every poll.
enum ProcessInfoReader {
    struct Info: Equatable {
        let ppid: pid_t
        let tty: String?
        /// Process start, seconds since 1970 — stable for the life of the process.
        let startTime: TimeInterval
        /// Short command name (`claude`).
        let name: String
    }

    static func info(of pid: pid_t) -> Info? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        var tty: String?
        // e_tdev is NODEV (all ones) when there's no controlling terminal.
        let dev = dev_t(bitPattern: bsd.e_tdev)
        if bsd.e_tdev != UInt32.max, dev != 0, let name = devname(dev, mode_t(S_IFCHR)) {
            tty = String(cString: name)
        }
        let name = withUnsafeBytes(of: bsd.pbi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let start = TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000
        return Info(ppid: pid_t(bsd.pbi_ppid), tty: tty, startTime: start, name: name)
    }

    /// Whether `info` plausibly is the process that wrote a session file
    /// claiming `startedAt`: a `claude` executable that started shortly before
    /// the session did. Rejects stale files whose PID now belongs to
    /// something else.
    static func matchesClaudeSession(_ info: Info, startedAt: Date?) -> Bool {
        guard info.name.lowercased().contains("claude") else { return false }
        // Without the session's own start time there's nothing to tie the
        // record to THIS process instance, so it doesn't count as verified.
        guard let startedAt else { return false }
        let delta = startedAt.timeIntervalSince1970 - info.startTime
        return delta >= -10 && delta <= 300
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Ancestors of `pid`, nearest first, stopping at launchd.
    static func ancestors(of pid: pid_t, parent: (pid_t) -> pid_t? = { info(of: $0)?.ppid }) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        while let next = parent(current), next > 1, !chain.contains(next), chain.count < 64 {
            chain.append(next)
            current = next
        }
        return chain
    }

    /// The GUI app hosting the session's terminal (Terminal, iTerm2, Ghostty…),
    /// found by walking up the process tree. Nil for tmux/ssh-detached shells.
    @MainActor
    static func hostingApp(of pid: pid_t) -> NSRunningApplication? {
        for ancestor in ancestors(of: pid) {
            if let app = NSRunningApplication(processIdentifier: ancestor),
               app.bundleIdentifier != nil {
                return app
            }
        }
        return nil
    }
}

// MARK: - Sources

/// Reads the live-session sources off the main actor.
enum ExternalSessionSource {
    static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Fast path: one small JSON file per live process. Returns nil when the
    /// directory is missing, so the caller can fall back to the CLI.
    static func readSessionFiles(in directory: URL = sessionsDirectory) -> [ExternalAgentSession]? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }
        return files.compactMap { file in
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            return ExternalSessionParser.session(from: object)
        }
    }

    /// Documented path: `claude agents --json`. Slower (~0.25s), used when the
    /// session files aren't available.
    static func runAgentsCommand() -> [ExternalAgentSession]? {
        guard let claude = claudeExecutable() else { return nil }
        let process = Process()
        process.executableURL = claude
        process.arguments = ["agents", "--json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return ExternalSessionParser.sessions(fromAgentsJSON: data)
    }

    /// GUI apps don't inherit the login shell's PATH, so look in the places the
    /// installers actually use.
    static func claudeExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    /// Transcript for a session id. The folder name is a lossy encoding of the
    /// cwd, so match on the file name across project folders instead.
    static func transcript(for sessionId: String, under root: URL = projectsDirectory) -> URL? {
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return nil }
        let name = "\(sessionId).jsonl"
        for project in projects {
            let candidate = project.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Title candidates from a transcript, read incrementally: the first read
    /// takes the head and tail; later reads take only the bytes appended
    /// since `offset`, so everything they find is newer than what's cached
    /// and a rename can never be replaced by an older one.
    static func titleParts(for sessionId: String, after offset: UInt64, under root: URL = projectsDirectory) -> (parts: ExternalSessionParser.TitleParts, offset: UInt64, isFullRead: Bool)? {
        guard let file = transcript(for: sessionId, under: root),
              let handle = try? FileHandle(forReadingFrom: file)
        else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        if offset > 0, size >= offset, size - offset <= incrementalByteLimit {
            guard size > offset else { return (.init(), offset, false) }
            try? handle.seek(toOffset: offset)
            let data = (try? handle.readToEnd()) ?? Data()
            // Only consume complete lines: a line still being written is read
            // again, whole, next time.
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return (.init(), offset, false) }
            let complete = data[data.startIndex...lastNewline]
            let lines = complete.split(separator: UInt8(ascii: "\n"))
            let consumed = UInt64(complete.count)
            return (ExternalSessionParser.titleParts(fromTranscriptLines: lines), offset + consumed, false)
        }
        // First read, a rewritten (shrunk) file, or a burst too big to scan:
        // head + tail from one snapshot of `size` bytes. The cursor is the end
        // of the last complete line IN THAT SNAPSHOT, so anything appended
        // while we read is picked up by the next incremental read.
        let tailStart = size > UInt64(tailByteLimit) ? size - UInt64(tailByteLimit) : 0
        try? handle.seek(toOffset: tailStart)
        let tail = (try? handle.read(upToCount: Int(size - tailStart))) ?? Data()
        let head = tailStart > 0 ? AgentSessionScanner.headLines(of: file) : []
        // No complete line in the tail window (one long line still being
        // written): keep what the head says and re-read the tail next time.
        guard let lastNewline = tail.lastIndex(of: UInt8(ascii: "\n")) else {
            return (ExternalSessionParser.titleParts(fromTranscriptLines: head), tailStart, true)
        }
        let complete = tail[tail.startIndex...lastNewline]
        let lines = head + complete.split(separator: UInt8(ascii: "\n"))
        let cursor = tailStart + UInt64(complete.count)
        return (ExternalSessionParser.titleParts(fromTranscriptLines: lines), cursor, true)
    }

    /// Larger bursts than this between title refreshes re-read head + tail instead.
    static let incrementalByteLimit: UInt64 = 16 * 1_048_576

    static let tailByteLimit = 256 * 1024

    static func tailLines(of file: URL) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > UInt64(AgentSessionScanner.headByteLimit) else {
            return []
        }
        try? handle.seek(toOffset: size - UInt64(min(UInt64(tailByteLimit), size)))
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        // The first slice is almost always a partial line; it fails to parse and is skipped.
        return data.split(separator: UInt8(ascii: "\n"))
    }
}
