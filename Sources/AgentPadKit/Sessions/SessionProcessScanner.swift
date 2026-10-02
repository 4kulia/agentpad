import Darwin
import Foundation

/// One process running on a session's terminal.
struct SessionProcess: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    /// Nesting under the session's shell — 0 is the shell itself.
    let depth: Int
    /// In the terminal's foreground process group: what a keystroke would
    /// reach, and what the user means by "what is this tab running". A
    /// pipeline puts several processes in one group, so this is a set, not a
    /// single pid.
    let isForeground: Bool
    /// TCP ports this process is LISTENING on, ascending. Listen-only on
    /// purpose: established connections and UDP binds (mDNS etc.) are noise,
    /// while "which port did my dev server take" is the question this
    /// answers.
    let ports: [UInt16]
    /// Whole-percent CPU over the last poll window (can exceed 100 on
    /// multi-core, like `top`). nil until a second sample exists — the first
    /// sighting has no window to diff — or when the pid isn't ours to
    /// inspect. Quantized to whole percent so an idle tree stays
    /// Equatable-stable tick over tick and the poll's equality gate holds.
    let cpuPercent: Int?
    /// Resident set in MB, same quantization rationale. nil when unreadable.
    let residentMB: Int?
    /// Kernel start time (µs since epoch) captured at scan time. PIDs
    /// recycle; (pid, start time) doesn't — this is the identity a kill must
    /// re-verify, because a context menu can sit open long after the target
    /// exited and its number was handed to an innocent process.
    let startedAtUs: UInt64

    var id: pid_t { pid }
}

/// Lists the processes attached to a session's pty.
///
/// Membership is by CONTROLLING TERMINAL, the same rule `ps -t` uses — not by
/// walking down from AgentPad. AgentPad's own child is `/usr/bin/login`, the shell is
/// its child, and a tree walk would have to guess which branch belongs to which
/// tab; every process on the tty belongs to exactly one tab by construction.
enum SessionProcessScanner {
    /// Flattened kernel row, split out so the tree logic is testable without
    /// a live pty.
    struct Raw: Equatable {
        let pid: pid_t
        let ppid: pid_t
        let name: String
        let isForeground: Bool
        var ports: [UInt16] = []
        var cpuPercent: Int? = nil
        var residentMB: Int? = nil
        var startedAtUs: UInt64 = 0
    }

    /// One tick's cumulative CPU times, handed back to the NEXT tick to diff
    /// against. The caller owns it (the scanner is stateless) and drops it on
    /// a tab switch so one session's counters never window against another's.
    struct CPUSamples: Sendable {
        let atNs: UInt64
        let cpuNs: [pid_t: UInt64]
    }

    /// The processes on `foregroundPid`'s terminal, depth-first from the shell.
    /// Empty when the pid is gone or has no controlling terminal.
    static func scan(
        foregroundPid: pid_t,
        previousCPU: CPUSamples? = nil
    ) -> (processes: [SessionProcess], cpu: CPUSamples) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        guard foregroundPid > 0, let tty = controllingTerminal(of: foregroundPid) else {
            return ([], CPUSamples(atNs: nowNs, cpuNs: [:]))
        }
        var raw = processes(onTerminal: tty)
        var samples: [pid_t: UInt64] = [:]
        let elapsedNs = previousCPU.flatMap { nowNs > $0.atNs ? nowNs - $0.atNs : nil }
        for i in raw.indices {
            raw[i].ports = listeningPorts(of: raw[i].pid)
            guard let usage = usage(of: raw[i].pid) else { continue }
            samples[raw[i].pid] = usage.cpuNs
            raw[i].residentMB = Int(usage.residentBytes / (1024 * 1024))
            if let elapsedNs, let prev = previousCPU?.cpuNs[raw[i].pid] {
                raw[i].cpuPercent = cpuPercent(currentNs: usage.cpuNs, previousNs: prev, elapsedNs: elapsedNs)
            }
        }
        return (tree(from: raw), CPUSamples(atNs: nowNs, cpuNs: samples))
    }

    /// Whole-percent CPU between two cumulative samples. nil (not 0) when the
    /// window is unusable — a clock hiccup or a recycled pid whose counter
    /// went backwards must read as "unknown", not "idle".
    static func cpuPercent(currentNs: UInt64, previousNs: UInt64, elapsedNs: UInt64) -> Int? {
        guard elapsedNs > 0, currentNs >= previousNs else { return nil }
        return Int((Double(currentNs - previousNs) / Double(elapsedNs) * 100).rounded())
    }

    /// Cumulative CPU (as ns of CPU time) + resident set, or nil for pids we
    /// can't inspect (other-uid — the row just shows no usage). `ri_user_time`
    /// / `ri_system_time` are Mach time units, which on Apple Silicon are NOT
    /// nanoseconds (timebase 125/3) — the conversion is mandatory.
    private static func usage(of pid: pid_t) -> (cpuNs: UInt64, residentBytes: UInt64)? {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) == 0
            }
        }
        guard ok else { return nil }
        let machTicks = info.ri_user_time &+ info.ri_system_time
        let ns = machTicks &* UInt64(machTimebase.numer) / UInt64(machTimebase.denom)
        return (ns, info.ri_resident_size)
    }

    private static let machTimebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Depth-first order, children by pid, rooted at the session's shell.
    ///
    /// A root named `login` is replaced by its children: on macOS libghostty
    /// spawns the shell through `/usr/bin/login`, which is plumbing the user
    /// never started. Only a ROOT is stripped, so a `login` the user ran
    /// themselves — which sits under the shell — still shows up.
    static func tree(from raw: [Raw]) -> [SessionProcess] {
        let byPid = Dictionary(raw.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [pid_t: [Raw]] = [:]
        var roots: [Raw] = []
        for entry in raw {
            if byPid[entry.ppid] != nil {
                children[entry.ppid, default: []].append(entry)
            } else {
                roots.append(entry)
            }
        }

        var start = roots.sorted { $0.pid < $1.pid }
        while start.count == 1, start[0].name == "login" {
            start = (children[start[0].pid] ?? []).sorted { $0.pid < $1.pid }
        }

        var result: [SessionProcess] = []
        func visit(_ entry: Raw, depth: Int) {
            result.append(SessionProcess(
                pid: entry.pid,
                name: entry.name,
                depth: depth,
                isForeground: entry.isForeground,
                ports: entry.ports,
                cpuPercent: entry.cpuPercent,
                residentMB: entry.residentMB,
                startedAtUs: entry.startedAtUs
            ))
            for child in (children[entry.pid] ?? []).sorted(by: { $0.pid < $1.pid }) {
                visit(child, depth: depth + 1)
            }
        }
        for root in start { visit(root, depth: 0) }
        return result
    }

    // MARK: - Kernel

    private static func controllingTerminal(of pid: pid_t) -> dev_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &proc, &size, nil, 0) == 0, size > 0 else { return nil }
        let tty = proc.kp_eproc.e_tdev
        // NODEV — the process has no controlling terminal.
        return tty == -1 ? nil : tty
    }

    private static func processes(onTerminal tty: dev_t) -> [Raw] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(tty)]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // The set can grow between sizing and fetching; ask for slack and trust
        // the size sysctl writes back rather than the one we requested.
        size += MemoryLayout<kinfo_proc>.stride * 8
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &list, &size, nil, 0) == 0 else { return [] }

        return list.prefix(size / MemoryLayout<kinfo_proc>.stride).map { entry in
            Raw(
                pid: entry.kp_proc.p_pid,
                ppid: entry.kp_eproc.e_ppid,
                name: processName(entry),
                // The tty's foreground process group — the textbook definition,
                // and it covers every process of a pipeline rather than the one
                // pid libghostty hands back.
                isForeground: entry.kp_eproc.e_pgid == entry.kp_eproc.e_tpgid,
                startedAtUs: startUs(entry)
            )
        }
    }

    /// Kernel start time of `pid` right now, or nil when the pid is gone.
    /// Pairing this against a scan-time snapshot is what makes the pid a
    /// durable identity instead of a recyclable number.
    static func startTimeUs(of pid: pid_t) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &proc, &size, nil, 0) == 0, size > 0,
              proc.kp_proc.p_pid == pid
        else { return nil }
        return startUs(proc)
    }

    /// True when `pid` still names the process captured at scan time. The
    /// verify-then-signal pair still has a microsecond TOCTOU window, but it
    /// replaces the minutes-long one a parked context menu had.
    static func identityMatches(pid: pid_t, startedAtUs: UInt64) -> Bool {
        startedAtUs != 0 && startTimeUs(of: pid) == startedAtUs
    }

    private static func startUs(_ entry: kinfo_proc) -> UInt64 {
        // `p_starttime` is a C macro over the union member, which Swift
        // doesn't import — reach through `p_un` directly.
        let tv = entry.kp_proc.p_un.__p_starttime
        return UInt64(bitPattern: Int64(tv.tv_sec)) &* 1_000_000 &+ UInt64(bitPattern: Int64(tv.tv_usec))
    }

    /// TCP ports `pid` is listening on, ascending — the same libproc walk
    /// `lsof -sTCP:LISTEN` performs, without the subprocess: list the fds,
    /// then fetch socket info for the SOCKET-type ones. Same-uid processes
    /// are readable without privileges; anything unreadable just reports no
    /// ports. v4 + v6 listeners on one port collapse via the Set.
    static func listeningPorts(of pid: pid_t) -> [UInt16] {
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let bytesNeeded = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytesNeeded > 0 else { return [] }
        // The fd table can grow between sizing and fetching — same slack
        // pattern as `processes(onTerminal:)`.
        var fds = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(bytesNeeded) / fdSize + 8
        )
        let bytesRead = fds.withUnsafeMutableBytes { buf in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf.baseAddress, Int32(buf.count))
        }
        guard bytesRead > 0 else { return [] }

        var ports: Set<UInt16> = []
        for fd in fds.prefix(Int(bytesRead) / fdSize) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { continue }
            // `insi_lport` carries the 16-bit port in network byte order.
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    /// `p_comm` is the kernel's accounting name — already the bare executable
    /// name (`zsh`, not the login shell's `-/bin/zsh` argv[0]), capped at
    /// `MAXCOMLEN`.
    private static func processName(_ entry: kinfo_proc) -> String {
        withUnsafePointer(to: entry.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(cString: $0)
            }
        }
    }
}
