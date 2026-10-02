import Foundation

/// Snapshot of a working tree's git state for the pane footer.
/// `branch == nil` means "not in a repo" (or git unavailable / errored).
struct GitStatus: Equatable {
    var branch: String?
    /// Absolute worktree root (`rev-parse --show-toplevel`). Drives the
    /// status bar's repo pill: name = basename, popover = Finder reveal +
    /// remote lookup. Nil inside a bare repo / `.git` dir — the pill hides,
    /// branch still shows.
    var repoRoot: String?
    var filesChanged: Int
    var insertions: Int
    var deletions: Int

    static let empty = GitStatus(branch: nil, repoRoot: nil, filesChanged: 0, insertions: 0, deletions: 0)
}

/// Per-file slice of the same diff `GitStatus` aggregates — insertions /
/// deletions for one path. Both zero means no countable lines (binary
/// file — numstat prints `-` — or a mode-only change); shortstat still
/// counts such files in `filesChanged`.
struct GitFileDiff: Equatable {
    var insertions: Int
    var deletions: Int
}

/// One row of the diff pill's popover: repo-root-relative path (numstat's
/// native form — right for display) plus its slice of the diff.
struct GitDiffFileEntry: Equatable, Sendable {
    var path: String
    var insertions: Int
    var deletions: Int
}

/// One atomic `git diff --numstat` result for the diff pill. Rows, totals,
/// AND the repo root come from the same click-time fetch, so the popover can
/// never disagree with the numbers it refreshes on the pill, and "Show in
/// File Tree" can never jump to a repo other than the one listed (the pill's
/// own `gitStatus.repoRoot` can be stale mid-`cd` across repos).
struct GitDiffSnapshot: Equatable, Sendable {
    var repoRoot: String
    var entries: [GitDiffFileEntry]

    var filesChanged: Int { entries.count }
    var insertions: Int { entries.reduce(0) { $0 + $1.insertions } }
    var deletions: Int { entries.reduce(0) { $0 + $1.deletions } }
}

/// Spawns `git` on a background queue to populate `Session.gitStatus`.
/// Refreshes are kicked from `WorkspaceStore` on (a) tab spawn, (b) cwd
/// change via OSC 7, and (c) command finished via OSC 133;D. No polling.
///
/// A monotonic per-session generation token drops stale results: if the user
/// `cd`s rapidly, several fetches may be in flight, but only the latest one's
/// result lands on the session.
/// Accumulates a pipe's contents on a background thread so the owner can
/// wait for process exit without deadlocking on a full pipe buffer.
/// `@unchecked Sendable` is sound because `data` is written only by the
/// reader thread before `done.signal()`, and read only after `done.wait()`
/// — the semaphore provides the happens-before edge. Shared by
/// `GitStatusFetcher.runGit`, `WorktreeManager.runGit`, and
/// `ClosedLidSleep` (same deadlock class).
final class PipeDrain: @unchecked Sendable {
    var data = Data()
    let done = DispatchSemaphore(value: 0)

    /// Starts draining `pipe` to EOF on a background thread.
    static func draining(_ pipe: Pipe) -> PipeDrain {
        let drain = PipeDrain()
        DispatchQueue.global(qos: .utility).async {
            drain.data = pipe.fileHandleForReading.readDataToEndOfFile()
            drain.done.signal()
        }
        return drain
    }
}

@MainActor
final class GitStatusFetcher {
    /// Keys are caller-chosen strings from three disjoint shapes — session
    /// UUID strings, absolute gitdir paths (leading `/`), and the
    /// `"file-tree"` constant — so the lanes cannot collide.
    private var generation: [String: Int] = [:]

    /// Coalesces same-target refires: fish fires OSC 7 and OSC 133;D
    /// microseconds apart on every prompt, and zsh/bash double-fire on any
    /// prompt that follows a `cd` — the second dispatch's subprocesses were
    /// pure waste because the token bump constructively dropped the first
    /// dispatch's result. Within the window the in-flight run's result
    /// stands in for the dropped call (same cwd, same disk state).
    private var lastDispatch: [String: (cwdPath: String, at: DispatchTime)] = [:]

    /// Test-visible count of real status subprocess batches admitted past
    /// the coalescing gate. File-tree numstat fetches intentionally do not
    /// contribute: this probe pins the same-repo tab fan-in invariant.
    private(set) var statusDispatchCount = 0

    /// Bounded git worker pool. `runGit` blocks its thread on the exit
    /// semaphore (plus one drain block per call), so dispatching every fetch
    /// onto the unbounded global queue let a same-repo fan-out pin a dozen
    /// GCD workers at once. Three keeps prompt + watcher + file-tree fetches
    /// concurrent without thread pileup; the rest queue for milliseconds.
    private static let gitQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .utility
        return queue
    }()

    /// Schedules a fetch for `cwd`. `completion` fires on main with the
    /// freshest result; older in-flight results are silently dropped.
    func fetch(id: String, cwd: URL, completion: @MainActor @escaping (GitStatus) -> Void) {
        if fetchTokened(id: id, cwd: cwd, work: Self.run, completion: completion) {
            statusDispatchCount += 1
        }
    }

    /// Per-file companion to `fetch`: `git diff --numstat HEAD` is the same
    /// diff `--shortstat HEAD` summarizes, so the per-file numbers sum to
    /// exactly what the status bar shows. Keys are absolute standardized
    /// paths (repo-root-joined), matching the file tree's row ids.
    func fetchFileDiffs(id: String, cwd: URL, completion: @MainActor @escaping ([String: GitFileDiff]) -> Void) {
        fetchTokened(id: id, cwd: cwd, work: Self.runFileDiffs, completion: completion)
    }

    /// Marks any in-flight fetch for `id` stale — its completion is dropped
    /// when it lands. For results that arrive from OUTSIDE the fetch pipeline
    /// (the diff pill's click-time numstat): applying one without bumping the
    /// token would let a slower, older prompt-driven fetch overwrite it.
    /// Also clears the coalescing stamp: the invalidated run no longer
    /// stands in for anything, so the next fetch must dispatch for real.
    /// This is the CONTRACT for edge-triggered callers — a result produced
    /// outside the fetch pipeline invalidates every lane it supersedes, and
    /// polling lanes accept the 50ms stand-in.
    func invalidateInFlight(id: String) {
        generation[id] = (generation[id] ?? 0) + 1
        lastDispatch.removeValue(forKey: id)
    }

    /// Current generation token for a lane. The shared-gitdir broadcast
    /// snapshots each subscriber's own session lane at dispatch and skips
    /// sessions whose lane moved while the shared run was in flight — their
    /// own fetch read a NEWER disk state, and the two lanes don't invalidate
    /// each other (Codex review P2).
    func currentToken(id: String) -> Int { generation[id] ?? 0 }

    /// Shared dispatch shape for both fetches: bump the caller's generation
    /// token, run `work` on the bounded git queue, drop the result on main
    /// unless a newer fetch superseded it.
    @discardableResult
    private func fetchTokened<T: Sendable>(
        id: String,
        cwd: URL,
        work: @escaping @Sendable (String) -> T,
        completion: @MainActor @escaping (T) -> Void
    ) -> Bool {
        let path = cwd.path
        // Dropping the call (not just its result) is safe because callers
        // only ever write the fetched value into observable state — the
        // in-flight twin delivers the same bytes moments later.
        if let last = lastDispatch[id], last.cwdPath == path,
           DispatchTime.now().uptimeNanoseconds - last.at.uptimeNanoseconds < 50_000_000 {
            return false
        }
        lastDispatch[id] = (path, .now())
        let token = (generation[id] ?? 0) + 1
        generation[id] = token
        Self.gitQueue.addOperation { [weak self] in
            let result = work(path)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.generation[id] == token else { return }
                completion(result)
            }
        }
        return true
    }

    nonisolated private static func runFileDiffs(cwd: String) -> [String: GitFileDiff] {
        // numstat paths are repo-root-relative regardless of cwd; resolve the
        // root so keys can be absolute. Failure (not a repo / no commits yet)
        // mirrors the shortstat path: empty result, badges hide.
        guard let top = runGit(["-C", cwd, "--no-optional-locks", "rev-parse", "--show-toplevel"]),
              let raw = runGit(["-C", cwd, "--no-optional-locks", "diff", "--numstat", "-z", "HEAD"])
        else { return [:] }
        var result: [String: GitFileDiff] = [:]
        for entry in parseNumstat(raw) {
            let abs = URL(fileURLWithPath: top).appendingPathComponent(entry.path).standardizedFileURL.path
            result[abs] = GitFileDiff(insertions: entry.insertions, deletions: entry.deletions)
        }
        return result
    }

    /// Popover companion to `fetchFileDiffs` — the same numstat diff, but
    /// ordered by path and keeping the repo-root-relative paths for display.
    /// Called off-main on pill click, so an unclicked pill costs zero extra
    /// subprocesses and a slow repo cannot block the UI thread. Nil means a
    /// git command failed/timed out (or no worktree); an empty snapshot is a
    /// real clean tree.
    nonisolated static func diffSnapshot(cwd: String) -> GitDiffSnapshot? {
        guard let root = runGit(["-C", cwd, "--no-optional-locks", "rev-parse", "--show-toplevel"]),
              let raw = runGit(["-C", cwd, "--no-optional-locks", "diff", "--numstat", "-z", "HEAD"])
        else { return nil }
        return GitDiffSnapshot(repoRoot: root, entries: orderedDiffEntries(numstat: raw))
    }

    /// Pure sort behind `diffSnapshot`, split out for tests.
    nonisolated static func orderedDiffEntries(numstat raw: String) -> [GitDiffFileEntry] {
        parseNumstat(raw).sorted { $0.path < $1.path }
    }

    /// Parses `git diff --numstat -z` output. Records are NUL-separated:
    /// `ins\tdel\tpath` for normal entries; a rename emits `ins\tdel\t`
    /// followed by TWO extra NUL fields (pre-path, post-path) — we keep the
    /// post-path (the name on disk now). Binary files print `-` for both
    /// counts → (0, 0).
    nonisolated static func parseNumstat(_ raw: String) -> [GitDiffFileEntry] {
        var entries: [GitDiffFileEntry] = []
        let fields = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < fields.count {
            let record = fields[i]
            i += 1
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let ins = Int(parts[0]) ?? 0
            let del = Int(parts[1]) ?? 0
            var path = String(parts[2])
            if path.isEmpty {
                // Rename record: consume the pre/post fields, keep post.
                guard i + 1 < fields.count else { continue }
                path = fields[i + 1]
                i += 2
            }
            guard !path.isEmpty else { continue }
            entries.append(GitDiffFileEntry(path: path, insertions: ins, deletions: del))
        }
        return entries
    }

    nonisolated private static func run(cwd: String) -> GitStatus {
        // One spawn answers both "what branch" (`--abbrev-ref HEAD` — the
        // name, or "HEAD" when detached) and "where's the root" for every
        // healthy worktree, keeping the per-prompt spawn count flat. Outside
        // one (bare repo, inside .git) the combined form exits non-zero and
        // its stdout is untrustworthy (an unborn-HEAD repo echoes
        // `--show-toplevel` literally), so fall back to the branch-only
        // probe: its failure means "not a repo" (footer hides); success
        // means a rootless-but-real repo (branch shows, repo pill hides).
        let head: String
        let repoRoot: String?
        if let combined = runGit([
            "-C", cwd, "--no-optional-locks", "rev-parse", "--abbrev-ref", "HEAD", "--show-toplevel",
        ]), let newline = combined.firstIndex(of: "\n") {
            head = String(combined[..<newline])
            repoRoot = String(combined[combined.index(after: newline)...])
        } else if let solo = runGit(["-C", cwd, "--no-optional-locks", "rev-parse", "--abbrev-ref", "HEAD"]) {
            head = solo
            repoRoot = nil
        } else {
            return .empty
        }
        let branch: String
        if head == "HEAD" {
            branch = runGit(["-C", cwd, "--no-optional-locks", "rev-parse", "--short", "HEAD"]) ?? "HEAD"
        } else {
            branch = head
        }
        let stat = runGit(["-C", cwd, "--no-optional-locks", "diff", "--shortstat", "HEAD"]) ?? ""
        let (files, ins, del) = parseShortstat(stat)
        return GitStatus(branch: branch, repoRoot: repoRoot, filesChanged: files, insertions: ins, deletions: del)
    }

    /// Runs `git <args>` with a 1-second timeout; returns trimmed stdout on
    /// exit 0, nil otherwise. Uses `/usr/bin/env` so the spawned subprocess
    /// resolves git via PATH (covers Apple's /usr/bin/git stub + Homebrew).
    ///
    /// stdout is drained CONCURRENTLY with the exit wait — reading only
    /// after termination deadlocks once output exceeds the ~64KB pipe
    /// buffer (git blocks writing, never exits, the timeout kills it and
    /// the caller sees nil). Small outputs (branch, shortstat) never hit
    /// it; `--numstat` on a large changeset (~2k files) and `for-each-ref`
    /// on branch-heavy repos do. stderr goes to the null device — it was
    /// never read, so a chatty-stderr git had the same latent deadlock.
    nonisolated static func runGit(_ args: [String], timeout: TimeInterval = 1.0) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git"] + args
        task.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }

        do {
            try task.run()
        } catch {
            return nil
        }

        let drain = PipeDrain.draining(stdout)

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            _ = exited.wait(timeout: .now() + 0.1)
            // The terminate closes the pipe; the drain thread unblocks and
            // finishes on its own — nothing waits on it.
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        // Exit closes git's end of the pipe, so EOF is imminent; the extra
        // timeout is pure paranoia against a leaked write end.
        guard drain.done.wait(timeout: .now() + timeout) == .success else { return nil }
        return String(data: drain.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses `git diff --shortstat` lines like
    /// ` 3 files changed, 47 insertions(+), 12 deletions(-)`.
    /// Returns `(0, 0, 0)` for empty / unparseable input — all fields drop.
    nonisolated static func parseShortstat(_ s: String) -> (files: Int, insertions: Int, deletions: Int) {
        var files = 0
        var ins = 0
        var del = 0
        for token in s.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let n = Int(parts[0]) else { continue }
            let label = parts[1]
            if label.hasPrefix("file") {
                files = n
            } else if label.hasPrefix("insertion") {
                ins = n
            } else if label.hasPrefix("deletion") {
                del = n
            }
        }
        return (files, ins, del)
    }
}

enum GitBranchInventory {
    static func localBranches(cwd: URL) -> [String] {
        let output = GitStatusFetcher.runGit([
            "-C", cwd.path,
            "--no-optional-locks",
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname:short)",
            "refs/heads",
        ]) ?? ""
        return parseBranches(output)
    }

    static func shellSwitchCommand(branch: String) -> String {
        "git switch \(AgentPadShellIntegration.quote(branch))\r"
    }

    static func parseBranches(_ output: String) -> [String] {
        var seen = Set<String>()
        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }
}

/// Browsable https page of a git remote, for the status bar's repo popover.
struct GitRemoteWebInfo: Equatable, Sendable {
    var webURL: URL

    var host: String { webURL.host ?? "" }

    /// Substring heuristic so self-hosted instances (github.company.com,
    /// gitlab.corp.net) still get the right forge name.
    var forgeName: String {
        let h = host.lowercased()
        if h.contains("github") { return "GitHub" }
        if h.contains("gitlab") { return "GitLab" }
        if h.contains("bitbucket") { return "Bitbucket" }
        return host
    }

    /// Synchronous remote lookup, dispatched off-main when the popover opens
    /// — never per prompt, so an unclicked pill costs zero subprocesses. One
    /// `git remote -v` answers the whole question (origin, else first remote),
    /// so a hung git costs one 1s timeout, not a chain of them.
    static func resolve(repoRoot: String) -> GitRemoteWebInfo? {
        let listing = GitStatusFetcher.runGit(["-C", repoRoot, "--no-optional-locks", "remote", "-v"]) ?? ""
        return preferredRemoteURL(inRemoteListing: listing).flatMap(parse(remoteURL:))
    }

    /// Picks origin's fetch URL, else the first remote's, from
    /// `git remote -v` output (`name<TAB>url (fetch|push)` lines).
    static func preferredRemoteURL(inRemoteListing output: String) -> String? {
        var first: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasSuffix(" (fetch)"), let tab = line.firstIndex(of: "\t") else { continue }
            let url = line[line.index(after: tab)...]
                .dropLast(" (fetch)".count)
                .trimmingCharacters(in: .whitespaces)
            if line[..<tab] == "origin" { return url }
            if first == nil { first = url }
        }
        return first
    }

    /// Parses the common remote-URL shapes into an https page:
    ///   git@github.com:owner/repo.git         (scp-like)
    ///   ssh://git@github.com[:port]/owner/repo.git
    ///   https://github.com/owner/repo[.git]
    ///   git://github.com/owner/repo.git
    /// Returns nil for local remotes (`file://`, absolute / relative paths).
    static func parse(remoteURL raw: String) -> GitRemoteWebInfo? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let webOrigin: String
        var path: String
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  ["https", "http", "ssh", "git"].contains(scheme),
                  let host = url.host, !host.isEmpty
            else { return nil }
            if scheme == "http" || scheme == "https" {
                // An http(s) remote's scheme/host/port ARE the web page's —
                // keep them (a :8443 GitLab lives at :8443; an http-only
                // forge has no https side). ssh/git ports are transport
                // ports, not web ports, so those map to bare https below.
                webOrigin = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
            } else {
                webOrigin = "https://\(host)"
            }
            path = url.path
        } else if let colon = trimmed.firstIndex(of: ":") {
            // scp-like `[user@]host:path`. A user-less form is legal git but
            // indistinguishable from odd local paths, so require no "/" on
            // the host side.
            let head = String(trimmed[..<colon])
            let host = head.split(separator: "@").last.map(String.init) ?? head
            guard !host.isEmpty, !host.contains("/") else { return nil }
            webOrigin = "https://\(host)"
            path = String(trimmed[trimmed.index(after: colon)...])
        } else {
            return nil
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.lowercased().hasSuffix(".git") { path.removeLast(4) }
        guard !path.isEmpty, let web = URL(string: "\(webOrigin)/\(path)") else { return nil }
        return GitRemoteWebInfo(webURL: web)
    }
}
