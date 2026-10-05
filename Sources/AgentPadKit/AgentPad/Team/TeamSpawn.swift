import Darwin
import Foundation

/// A process created suspended (`POSIX_SPAWN_START_SUSPENDED`) as the
/// leader of its own process group; continued with `SIGCONT`. Its identity —
/// PID, start time, group — is known before it is continued.
///
/// Once it ends it is not reaped until `release()`: while it is held, its PID
/// — and so its group's number — cannot be given to another process, so the
/// group can still be signalled as the run's after the leader ended.
final class TeamSpawned: @unchecked Sendable {
    let pid: pid_t
    /// The kernel's start time (microseconds since 1970): with `pid`, the
    /// process's identity — a PID given to another process later does not match.
    let startTime: UInt64
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var released = false
    /// Nothing holds it any more: reaped as soon as it has ended, now or later
    /// (review Y5-p2, 3: a leader that ended after its last holder let go
    /// stayed a zombie).
    private var letGo = false
    private var exitHandlers: [(Int32) -> Void] = []

    var identity: TeamProcessStart { TeamProcessStart(pid: pid, pgid: pid, startTime: startTime) }

    /// Runs `body` with whether its PID is still ours (alive, or ended and
    /// not yet reaped), under the lock `release()` takes: it cannot be reaped
    /// while `body` runs, so a signal sent in it reaches no one else (review C6-1).
    func whileHeld<T>(_ body: (Bool) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(!released)
    }

    init(pid: pid_t, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
        // Watched by a thread of its own: the exit status, once, without reaping.
        Thread.detachNewThread { [self] in
            let code = TeamSpawn.waitForExit(pid)
            let handlers = lock.withLock { () -> [(Int32) -> Void] in
                exitStatus = code
                if letGo, !released {
                    released = true
                    _ = TeamSpawn.reap(pid)
                }
                defer { exitHandlers = [] }
                return exitHandlers
            }
            handlers.forEach { $0(code) }
        }
    }

    func onExit(_ handler: @escaping (Int32) -> Void) {
        let done = lock.withLock { () -> Int32? in
            if let exitStatus { return exitStatus }
            exitHandlers.append(handler)
            return nil
        }
        if let done { handler(done) }
    }

    /// SIGKILL to it and its group — only while it is held.
    func kill() {
        lock.withLock {
            guard !released else { return }
            TeamProcesses.sendSignal(pid, SIGKILL, true)
            TeamProcesses.sendSignal(pid, SIGKILL, false)
            // A suspended process takes a kill only once continued.
            Darwin.kill(pid, SIGCONT)
        }
    }

    /// Lets it go: reaped once it has ended — at once, or when it ends; from
    /// then on its group is no longer ours to signal.
    func release() {
        lock.withLock {
            letGo = true
            guard !released, exitStatus != nil else { return }
            released = true
            _ = TeamSpawn.reap(pid)
        }
    }
}

enum TeamSpawn {
    struct Failed: Error, LocalizedError {
        let step: String
        let code: Int32
        var errorDescription: String? { "\(step): \(String(cString: strerror(code)))" }
    }

    /// Spawns `path` suspended, in `directory`, with the three pipes as its
    /// standard streams and nothing else inherited. Every step of the
    /// preparation is checked: a failure of any — or of reading the child's
    /// identity — throws, and a child already made is killed by its PID (it
    /// is ours, unreaped and never continued) (review C5-2, C5-3).
    static func suspended(path: String, arguments: [String], environment: [String: String], directory: String,
                          stdin: Pipe, stdout: Pipe, stderr: Pipe) throws -> TeamSpawned {
        // The parent's child ends go in every case: the child holds its own.
        defer {
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        func check(_ step: String, _ result: Int32) throws {
            guard result == 0 else { throw Failed(step: step, code: result) }
        }

        var attributes: posix_spawnattr_t?
        try check("posix_spawnattr_init", posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        try check("posix_spawnattr_setflags", posix_spawnattr_setflags(&attributes, Int16(flags)))
        try check("posix_spawnattr_setpgroup", posix_spawnattr_setpgroup(&attributes, 0))
        // Clean signal state, as `Process` gives: nothing blocked, every
        // signal at its default (the spawning thread's mask is not inherited).
        var none = sigset_t()
        sigemptyset(&none)
        try check("posix_spawnattr_setsigmask", posix_spawnattr_setsigmask(&attributes, &none))
        var all = sigset_t()
        sigfillset(&all)
        try check("posix_spawnattr_setsigdefault", posix_spawnattr_setsigdefault(&attributes, &all))

        var actions: posix_spawn_file_actions_t?
        try check("posix_spawn_file_actions_init", posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check("dup2 stdin", posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, 0))
        try check("dup2 stdout", posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, 1))
        try check("dup2 stderr", posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, 2))
        try check("chdir \(directory)", posix_spawn_file_actions_addchdir_np(&actions, directory))

        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func copy(_ text: String) throws -> UnsafeMutablePointer<CChar> {
            guard let made = strdup(text) else { throw Failed(step: "strdup", code: ENOMEM) }
            strings.append(made)
            return made
        }
        let argv: [UnsafeMutablePointer<CChar>?] = try ([path] + arguments).map(copy) + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = try environment.map { try copy("\($0.key)=\($0.value)") } + [nil]

        var pid: pid_t = 0
        try check("posix_spawn", posix_spawn(&pid, path, &actions, &attributes, argv, envp))
        // Its identity before anything else; read a few times, never made up.
        var found: TeamProcesses.ProcessFound?
        for attempt in 0..<20 {
            if case .success(let process?) = identityLookup(pid) {
                found = process
                break
            }
            if attempt < 19 { usleep(5_000) }
        }
        guard let found, found.pgid == pid else {
            Darwin.kill(pid, SIGKILL)
            Darwin.kill(pid, SIGCONT)
            _ = reap(pid)
            throw Failed(step: "reading the process's identity", code: found == nil ? ESRCH : EPERM)
        }
        return TeamSpawned(pid: pid, startTime: found.startTime)
    }

    /// Reads a new child's identity; replaced in tests to stand for a failing read.
    nonisolated(unsafe) static var identityLookup: (pid_t) -> Result<TeamProcesses.ProcessFound?, POSIXError> = TeamProcesses.lookup

    /// Waits for `pid` to end, leaving it unreaped; its exit code (128 +
    /// signal for a signal). By `kqueue` (`NOTE_EXIT`): `waitid` with
    /// `WNOWAIT` reports the suspended start as a stop, again and again.
    static func waitForExit(_ pid: pid_t) -> Int32 {
        let kq = kqueue()
        defer { if kq >= 0 { close(kq) } }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil)
        var event = kevent()
        var result: Int32 = -1
        if kq >= 0 {
            repeat { result = kevent(kq, &change, 1, &event, 1, nil) } while result < 0 && errno == EINTR
        }
        if result == 1, event.fflags & UInt32(NOTE_EXIT) != 0, event.flags & UInt16(EV_ERROR) == 0 {
            return code(Int32(truncatingIfNeeded: event.data))
        }
        // Not watchable (already ended, or no kqueue): its status as it stands.
        var info = siginfo_t()
        while true {
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 {
                if errno == EINTR { continue }
                return 0
            }
            switch info.si_code {
            case CLD_EXITED: return info.si_status
            case CLD_KILLED, CLD_DUMPED: return 128 + info.si_status
            default:
                // Not ended yet: look again shortly.
                usleep(50_000)
            }
        }
    }

    private static func code(_ status: Int32) -> Int32 {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }

    /// Waits for `pid` to end and reaps it; its exit code (128 + signal for a signal).
    static func reap(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        return code(status)
    }
}
