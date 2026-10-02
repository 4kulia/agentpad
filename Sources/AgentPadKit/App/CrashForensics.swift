import AppKit
import Darwin

/// Black-box flight recorder for the "silent exit(1)" class of death: a
/// Dock-launched app's stderr is /dev/null, so a low-level component
/// (libghostty Zig panic, C-library fatal path) that prints its reason and
/// calls exit(1) leaves nothing behind — no crash report (a "clean" exit,
/// not a signal), no unified-log entry. Observed twice on 2026-07-07 after
/// clicking the agent panel on a long-lived instance; the reason line was
/// lost both times. stderr is rerouted to ~/Library/Logs/agentpad/stderr.log,
/// and exit() / uncaught-exception hooks stamp it with who died and why.
public enum CrashForensics {
    /// Call once, before NSApplication starts — a panic during app/delegate
    /// construction must already be captured. Never runs in tests (they link
    /// AgentPadKit but not the executable's main.swift), so the atexit /
    /// exception hooks can't pollute the suite's exit.
    public static func install() {
        redirectStderrIfDiscarded()
        atexit { CrashForensics.dumpExitBacktrace() }
        NSSetUncaughtExceptionHandler { exc in
            fputs("\n=== AgentPad uncaught exception \(exc.name.rawValue): \(exc.reason ?? "?") ===\n", stderr)
            for line in exc.callStackSymbols { fputs(line + "\n", stderr) }
            fflush(stderr)
        }
    }

    /// Redirect only a *discarded* stderr — one that is literally /dev/null
    /// (the Dock/launchd case). Anything else (a terminal tty, `2>file`, a
    /// pipe) already has a reader, so the death note isn't lost and hijacking
    /// it would strand a developer's own redirect.
    private static func redirectStderrIfDiscarded() {
        var fdStat = stat(), nullStat = stat()
        guard fstat(STDERR_FILENO, &fdStat) == 0,
              stat("/dev/null", &nullStat) == 0,
              (fdStat.st_mode & S_IFMT) == S_IFCHR,
              fdStat.st_rdev == nullStat.st_rdev else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/agentpad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("stderr.log").path
        // Rotate past ~2MB so the append-only log can't grow unbounded.
        if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int,
           size > 2_000_000 {
            let old = dir.appendingPathComponent("stderr.log.old").path
            try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.moveItem(atPath: path, toPath: old)
        }
        guard freopen(path, "a", stderr) != nil else { return }
        // freopen onto a regular file leaves stderr *fully buffered* (libc
        // re-derives buffering from the new fd) — force it back to unbuffered
        // so a dying process can't strand its last line in a libc buffer.
        setvbuf(stderr, nil, _IONBF, 0)
        fputs("\n=== AgentPad \(AgentPadApp.displayVersion) launched \(timestamp()) pid \(getpid()) ===\n", stderr)
    }

    /// exit() runs atexit handlers on the calling thread, so this backtrace
    /// names whoever called exit. A normal quit logs the AppKit termination
    /// path — that's what makes an abnormal caller stand out.
    private static func dumpExitBacktrace() {
        fputs("\n=== AgentPad exit() called @ \(timestamp()) pid \(getpid()) ===\n", stderr)
        fflush(stderr)
        var addrs = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&addrs, Int32(addrs.count))
        backtrace_symbols_fd(&addrs, count, STDERR_FILENO)
        fputs("=== end backtrace ===\n", stderr)
        fflush(stderr)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
