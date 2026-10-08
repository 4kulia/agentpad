import Foundation

/// Evidence collected before acknowledging the hook, while its sender is alive.
/// The socket peer must descend from the TTY's sole signed Claude through
/// shell helpers, including detached hooks without a controlling terminal.
/// Foreground process-group leaders may be AgentPad's bash launch wrapper.
struct AgentAnswerProvenance: Equatable, Sendable {
    struct Snapshot: Equatable, Sendable {
        let process: ChatSessionIdentity.Process
        let image: ChatClaudeProcess.ImageIdentity
        let isForeground: Bool

        var name: String { URL(fileURLWithPath: image.path).lastPathComponent.lowercased() }
        var isShell: Bool { ["sh", "bash", "zsh", "dash", "ksh", "fish"].contains(name) }
        var isMultiplexer: Bool { ["tmux", "screen", "zellij", "dtach", "abduco"].contains(name) }
    }

    struct Inspector: Sendable {
        var kernel = ChatSessionIdentity.Kernel()
        var scan: @Sendable (Int32) -> [SessionProcessScanner.Raw] = SessionProcessScanner.identityProcesses
        var signed: @Sendable (Int32) -> Bool = ChatClaudeProcess.hasTrustedSignature
    }

    let process: ChatSessionIdentity.Process
    let snapshots: [Snapshot]

    static func capture(parentPID: Int32?, origin: AgentPadCallerOrigin,
                        inspector: Inspector = Inspector()) -> Self? {
        try? verify(parentPID: parentPID, origin: origin, inspector: inspector)
    }

    static func verify(parentPID: Int32?, origin: AgentPadCallerOrigin,
                       inspector: Inspector = Inspector()) throws(AgentAnswerTranscript.Problem) -> Self {
        guard let parentPID, parentPID > 1,
              case .localProcess(let peerPID, let start) = origin,
              let peer = inspector.kernel.process(peerPID), peer.startedAtUs == start,
              peer.parent == parentPID else { throw .hookIdentity }

        // Claude can launch hooks with setsid(): neither the hook nor its
        // shell then appears in a TTY scan. First prove their kernel ancestry,
        // then scan the signed owner's terminal, never a payload-supplied PID.
        var hookLineage: [Snapshot] = [], visited = Set<Int32>(), next = peerPID
        var signed: [Int32: Bool] = [:]
        while next > 1 {
            guard hookLineage.count < 256, visited.insert(next).inserted,
                  let process = inspector.kernel.process(next),
                  let image = inspector.kernel.image(next) else { throw .processUnavailable }
            let snapshot = Snapshot(process: process, image: image, isForeground: false)
            hookLineage.append(snapshot)
            let trusted = inspector.signed(next)
            signed[next] = trusted
            if trusted {
                guard next != peerPID else { throw .hookAncestry }
                break
            }
            if next != peerPID, snapshot.isMultiplexer { throw .multiplexer }
            next = process.parent
        }
        guard hookLineage.first?.process == peer else { throw .processUnavailable }
        guard let owner = hookLineage.last, signed[owner.process.pid] == true else { throw .claudeSignature }
        guard hookLineage.dropFirst().dropLast().allSatisfy(\.isShell) else { throw .hookAncestry }
        let claude = owner.process
        guard let tty = claude.terminal else { throw .claudeTerminal }
        guard hookLineage.allSatisfy({ $0.process.terminal == nil || $0.process.terminal == tty }) else {
            throw .hookAncestry
        }
        let rows = inspector.scan(claude.pid)
        var snapshots: [Snapshot] = []
        var candidates: [ChatSessionIdentity.Process] = []
        for row in rows {
            guard let process = inspector.kernel.process(row.pid), process.startedAtUs == row.startedAtUs,
                  process.parent == row.ppid, process.terminal == tty,
                  let image = inspector.kernel.image(row.pid) else { throw .processUnavailable }
            if signed[row.pid] ?? inspector.signed(row.pid) { candidates.append(process) }
            snapshots.append(Snapshot(process: process, image: image, isForeground: row.isForeground))
        }
        // Count every signed image, including renamed/background/nested Claude.
        guard !candidates.isEmpty else { throw .processUnavailable }
        guard candidates.count == 1 else { throw .ambiguousClaude }
        var known = Dictionary(snapshots.map { ($0.process.pid, $0) }, uniquingKeysWith: { a, _ in a })
        guard known.count == rows.count, candidates.first == claude else { throw .processUnavailable }
        guard known[claude.pid]?.isForeground == true else { throw .claudeBackground }
        for snapshot in hookLineage {
            if let scanned = known[snapshot.process.pid] {
                guard scanned.process == snapshot.process, scanned.image == snapshot.image else { throw .processUnavailable }
            } else {
                guard snapshot.process.terminal == nil else { throw .processUnavailable }
                snapshots.append(snapshot)
                known[snapshot.process.pid] = snapshot
            }
        }
        for snapshot in snapshots where snapshot.process.pid != claude.pid {
            if snapshot.isMultiplexer { throw .multiplexer }
            guard !snapshot.name.contains("claude") else { throw .ambiguousClaude }
            if ["node", "nodejs"].contains(snapshot.name) {
                // Normal MCP servers are Claude descendants. A runtime on the
                // hook lineage cannot borrow its ancestor's native signature;
                // a runtime elsewhere on the TTY is another possible session.
                guard let chain = ancestry(of: snapshot.process.pid, in: known),
                      chain.contains(where: { $0.process == claude }) else { throw .ambiguousClaude }
            }
        }
        guard snapshots.allSatisfy({ inspector.kernel.process($0.process.pid) == $0.process
            && inspector.kernel.image($0.process.pid) == $0.image }) else { throw .processUnavailable }
        let evidence = Self(process: claude, snapshots: snapshots)
        guard evidence.isCurrent(inspector: inspector) else { throw .processUnavailable }
        return evidence
    }

    /// A TTY match alone also matches sibling shells and multiplexer panes.
    /// The core returns the foreground group leader, which may be the shell
    /// waiting for Claude. Require that exact live ancestor and foreground set.
    func matchesForeground(_ pid: Int32?, inspector: Inspector = Inspector()) -> Bool {
        guard let pid, isCurrent(inspector: inspector) else { return false }
        let known = Dictionary(snapshots.map { ($0.process.pid, $0) }, uniquingKeysWith: { a, _ in a })
        guard let lineage = Self.ancestry(of: process.pid, in: known),
              let index = lineage.firstIndex(where: { $0.process.pid == pid }),
              inspector.kernel.process(pid) == lineage[index].process,
              lineage[0...index].allSatisfy(\.isForeground),
              lineage.prefix(index + 1).dropFirst().allSatisfy(\.isShell) else { return false }
        return true
    }

    private static func ancestry(of pid: Int32, in known: [Int32: Snapshot]) -> [Snapshot]? {
        var result: [Snapshot] = [], visited = Set<Int32>(), next = pid
        while let snapshot = known[next] {
            guard result.count < 256, visited.insert(next).inserted else { return nil }
            result.append(snapshot)
            next = snapshot.process.parent
        }
        return result
    }

    /// Only kernel/image metadata on the UI thread, never SecCode. A new
    /// process or exec needs a new hook's background verification. Exited
    /// helpers (including the hook itself) need not stay alive for export.
    func isCurrent(inspector: Inspector = Inspector()) -> Bool {
        guard inspector.kernel.process(process.pid) == process else { return false }
        let rows = inspector.scan(process.pid)
        guard rows.contains(where: { $0.pid == process.pid && $0.startedAtUs == process.startedAtUs }) else { return false }
        let known = Dictionary(snapshots.map { ($0.process.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for row in rows {
            guard let expected = known[row.pid], expected.process.startedAtUs == row.startedAtUs,
                  expected.process.parent == row.ppid,
                  expected.isForeground == row.isForeground,
                  inspector.kernel.process(row.pid) == expected.process,
                  inspector.kernel.image(row.pid) == expected.image else { return false }
        }
        for expected in snapshots where expected.process.terminal == nil {
            // A detached helper is needed only for the initial authentication.
            // A reused PID also means that the authenticated helper has exited.
            guard let current = inspector.kernel.process(expected.process.pid),
                  current.startedAtUs == expected.process.startedAtUs else { continue }
            if current != expected.process || inspector.kernel.image(current.pid) != expected.image {
                // It may have exited or its PID may have been reused between
                // process/image reads. Reject changes only to the same instance.
                guard inspector.kernel.process(current.pid)?.startedAtUs != expected.process.startedAtUs else { return false }
            }
        }
        return inspector.kernel.process(process.pid) == process
    }
}
