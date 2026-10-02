import Foundation

/// `git worktree` wrapper for the write paths (create / remove / list).
/// Distinct from `GitStatusFetcher.runGit` because that one drops stderr
/// and caps at 1s — both fine for status-bar reads, neither acceptable
/// here: failed worktree creation must surface a real message to the user,
/// and a big repo's first worktree can legitimately take several seconds.
enum WorktreeManager {
    enum BranchMode: Equatable, Sendable {
        case existing(branch: String)
        case newBranch(name: String, base: String?)
    }

    struct GitError: Swift.Error, CustomStringConvertible, Equatable, Sendable {
        var stderr: String
        var exitCode: Int32
        var description: String {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "git exited with status \(exitCode)" : trimmed
        }
    }

    struct Info: Equatable, Sendable {
        var path: URL
        var branch: String?
    }

    /// `git -C <repo> worktree add [-b <new>] <path> [<branch>|<base>]`.
    /// Caller is responsible for picking `path` — typically sibling of the
    /// source repo so the worktree shows up next to it in Finder.
    static func add(repoPath: URL, path: URL, mode: BranchMode) -> Result<Void, GitError> {
        var args = ["-C", repoPath.path, "worktree", "add"]
        switch mode {
        case .existing(let branch):
            args.append(path.path)
            args.append(branch)
        case .newBranch(let name, let base):
            args.append("-b")
            args.append(name)
            args.append(path.path)
            if let base, !base.isEmpty { args.append(base) }
        }
        return runGit(args, timeout: 30).map { _ in () }
    }

    /// `git -C <repo> worktree remove [--force] <path>`. `force = true` is
    /// the close-workspace path's choice — the user already confirmed they
    /// want the directory gone even if it has uncommitted changes.
    static func remove(repoPath: URL, path: URL, force: Bool) -> Result<Void, GitError> {
        var args = ["-C", repoPath.path, "worktree", "remove"]
        if force { args.append("--force") }
        args.append(path.path)
        return runGit(args, timeout: 10).map { _ in () }
    }

    /// `git -C <repo> branch -d <branch>` — safe-delete (lowercase d). Git
    /// itself refuses to drop branches with unmerged / unpushed commits,
    /// so we can call this unconditionally after `worktree remove` without
    /// risking data loss. Merged branches go away (next worktree of the
    /// same name builds cleanly); unmerged ones survive and surface again
    /// next time the user types that name into Create Worktree.
    static func deleteBranchIfMerged(repoPath: URL, branch: String) -> Result<Void, GitError> {
        runGit(["-C", repoPath.path, "branch", "-d", branch], timeout: 5).map { _ in () }
    }

    /// `git -C <repo> worktree list --porcelain` parsed into one `Info`
    /// per record. Used at restore time to drop persisted worktree
    /// workspaces whose dirs the user already removed externally.
    static func list(repoPath: URL) -> Result<[Info], GitError> {
        runGit(["-C", repoPath.path, "worktree", "list", "--porcelain"], timeout: 5)
            .map(parseList)
    }

    /// Branches that are already checked out by one of the repo's worktrees.
    /// Git refuses `worktree add <path> <branch>` for these, so the create
    /// sheet can disable them up-front instead of letting submit bounce.
    static func checkedOutBranches(in infos: [Info]) -> Set<String> {
        Set(infos.compactMap(\.branch))
    }

    /// Directory-safe branch suffix for the default sibling worktree path.
    /// Keeps the branch readable (`feature/foo` -> `feature-foo`) while
    /// avoiding path separators in the generated directory name.
    static func branchDirectorySlug(_ branch: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "/:\\"))
        var result = String()
        var previousWasDash = false
        for scalar in branch.unicodeScalars {
            if separators.contains(scalar) {
                if !result.isEmpty && !previousWasDash {
                    result.append("-")
                    previousWasDash = true
                }
            } else {
                result.unicodeScalars.append(scalar)
                previousWasDash = false
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func defaultDirectoryName(sourceName: String, branch: String) -> String {
        let slug = branchDirectorySlug(branch)
        return slug.isEmpty ? "\(sourceName)-" : "\(sourceName)-\(slug)"
    }

    /// Stable working-tree root for a cwd inside a repo. Distinct from the
    /// app-level `Workspace.workingDirectory`, which tracks the active shell's
    /// OSC 7 cwd and may be a nested folder or an unrelated directory after
    /// `cd`. Worktree create/reconcile/remove paths need the repo root.
    static func repoRoot(near cwd: URL) -> URL? {
        guard case .success(let output) = runGit([
            "-C", cwd.path,
            "--no-optional-locks",
            "rev-parse",
            "--show-toplevel",
        ], timeout: 2) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL
    }

    /// Records are blank-line-separated; each starts with `worktree <path>`
    /// and may carry `branch refs/heads/<name>` (or `detached` — branch nil).
    static func parseList(_ output: String) -> [Info] {
        var infos: [Info] = []
        var path: URL?
        var branch: String?
        func flush() {
            if let p = path { infos.append(Info(path: p, branch: branch)) }
            path = nil
            branch = nil
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                path = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        flush()
        return infos
    }

    // MARK: - Subprocess

    /// Internal (not private) purely as the test seam for the pipe-drain
    /// and timeout-escalation behavior; production callers stay in this file.
    static func runGit(_ args: [String], timeout: TimeInterval) -> Result<String, GitError> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git"] + args
        // Same PATH list as GitStatusFetcher — covers Apple's /usr/bin/git
        // stub plus Homebrew's git on both Intel and Apple Silicon.
        task.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do {
            try task.run()
        } catch {
            return .failure(GitError(
                stderr: "failed to launch git: \(error.localizedDescription)",
                exitCode: -1
            ))
        }
        // Drain both pipes CONCURRENTLY with the exit wait — reading only
        // after termination deadlocks once either stream passes the ~64KB
        // pipe buffer (git blocks writing, never exits, the timeout fires
        // and misreports). `worktree add` progress on a big repo and
        // `worktree list --porcelain` on worktree-heavy repos both produce
        // enough output to hit this; stderr must be drained too because
        // failed worktree commands surface it to the user.
        let outDrain = PipeDrain.draining(stdout)
        let errDrain = PipeDrain.draining(stderr)
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // Escalate until the process is CONFIRMED dead before returning.
            // These are write commands — reporting failure while git still
            // runs would let it keep mutating the worktree behind the
            // caller's back. After SIGKILL the process cannot execute
            // another instruction, so the bounded wait only covers reaping.
            task.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(task.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
            return .failure(GitError(stderr: "git timed out after \(Int(timeout))s", exitCode: -1))
        }
        // Exit closes git's pipe ends so EOF is imminent; one shared
        // absolute deadline (the drains run concurrently) guards against a
        // leaked write end — a git hook can background a child that
        // inherits our pipes and outlives git itself. On timeout the drain
        // thread may still be WRITING `data`, so reading it would be a
        // data race (the semaphore is the only happens-before edge) —
        // treat that stream as unavailable instead; the exit status is
        // still accurate and GitError falls back to "git exited with
        // status N" when stderr comes up empty.
        let drainDeadline = DispatchTime.now() + 5
        let outDrained = outDrain.done.wait(timeout: drainDeadline) == .success
        let errDrained = errDrain.done.wait(timeout: drainDeadline) == .success
        let stdoutString = outDrained ? (String(data: outDrain.data, encoding: .utf8) ?? "") : ""
        let stderrString = errDrained ? (String(data: errDrain.data, encoding: .utf8) ?? "") : ""
        if task.terminationStatus == 0 {
            return .success(stdoutString)
        }
        return .failure(GitError(stderr: stderrString, exitCode: task.terminationStatus))
    }
}
