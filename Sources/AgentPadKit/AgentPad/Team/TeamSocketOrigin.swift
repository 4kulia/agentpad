import AgentPadHookKit
import Darwin
import Foundation

/// Who sent a request on the control socket (docs/agentpad/CHAT-PLAN.md Y4,
/// narrowed after the fifth client review): a best-effort measure. Only a
/// sender confirmed at `accept` to be a registered run's process is limited;
/// A missing kernel PID is refused (G6); an unrelated caller with a kernel
/// PID is served as in 1.0.6.
/// What keeps a run from starting agents is elsewhere: no socket or CLI
/// command makes a local approval (D9).
enum AgentPadCallerOrigin: Equatable, Sendable {
    /// Not confirmed to be part of a team run.
    case outside
    /// Captured by the kernel at accept, never from the request payload.
    case localProcess(pid: Int32, startedAtUs: UInt64)
    /// A process of a team run: the run itself, its group or a descendant.
    /// `callId` is the call the run serves, when it has run tools.
    case teamRun(callId: String?)

    var isTeamRun: Bool {
        if case .teamRun = self { return true }
        return false
    }

    static let teamRunRefusal = "not available to a team run"

    /// The origin of the process `pid`.
    static func of(peerPID pid: pid_t?, processes: TeamProcesses = .shared) -> AgentPadCallerOrigin {
        guard let pid, pid > 0 else { return .teamRun(callId: nil) }
        if case .run(let callId) = processes.run(containing: pid) { return .teamRun(callId: callId) }
        guard let start = SessionProcessScanner.startTimeUs(of: pid), start != 0 else { return .outside }
        return .localProcess(pid: pid, startedAtUs: start)
    }

    /// The PID of the process at the other end of a Unix socket.
    static func peerPID(of fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    /// Why this caller may not make `request`; nil when it may. A team run
    /// may only ask for folders for its own call (`team access`,
    /// `team access-check` — checked against the call in `TeamCLIHandler`).
    func refusal(for request: AgentPadCLIRequest) -> String? {
        let verb = AgentPadCLIVerb(rawValue: request.verb)
        let action = request.teamAction.flatMap(AgentPadCLITeamAction.init(rawValue:))
        switch self {
        case .outside, .localProcess:
            return nil
        case .teamRun:
            guard verb == .team, action == .access || action == .accessCheck else { return Self.teamRunRefusal }
            return nil
        }
    }
}

extension TeamProcesses {
    enum RunLookup: Equatable {
        case run(callId: String?)
        /// Not confirmed to be a run's (also when it could not be inspected).
        case notFound
    }

    /// The run `pid` belongs to: it is a run's process, is in a run's process
    /// group, or it or any ancestor (by the kernel's parent links) is a run's
    /// process or one seen under it. Only what could be read counts.
    func run(containing pid: pid_t,
             parentAndGroup: (pid_t) -> (parent: pid_t, group: pid_t)? = TeamProcesses.parentAndGroup(of:)) -> RunLookup {
        guard let first = parentAndGroup(pid) else { return .notFound }
        var chain: [pid_t] = [pid]
        var groups: Set<pid_t> = [first.group]
        var next = first.parent
        while next > 1, chain.count < 256, !chain.contains(next), let info = parentAndGroup(next) {
            chain.append(next)
            groups.insert(info.group)
            next = info.parent
        }
        for run in runs() {
            let members = Set((run.leader.map { [$0] } ?? []) + run.seen.alive)
            if run.leader.map(groups.contains) == true || chain.contains(where: members.contains) {
                return .run(callId: run.callId)
            }
        }
        return .notFound
    }

    /// `ancestor` is `pid` itself or one of its ancestors.
    static func isSelfOrAncestor(_ ancestor: pid_t, of pid: pid_t) -> Bool {
        var current = pid
        for _ in 0..<256 {
            if current == ancestor { return true }
            guard current > 1, let info = parentAndGroup(of: current) else { return false }
            current = info.parent
        }
        return false
    }

    static func parentAndGroup(of pid: pid_t) -> (parent: pid_t, group: pid_t)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return (info.kp_eproc.e_ppid, info.kp_eproc.e_pgid)
    }
}
