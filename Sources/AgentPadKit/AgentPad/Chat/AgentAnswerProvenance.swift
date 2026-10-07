import Foundation

/// Evidence collected before acknowledging the hook, while its sender is alive.
/// The socket peer must descend from the TTY's sole signed Claude through
/// shell helpers. Foreground process-group leaders may be launch wrappers.
struct AgentAnswerProvenance: Equatable, Sendable {
    struct Snapshot: Equatable, Sendable {
        let process: ChatSessionIdentity.Process
        let image: ChatClaudeProcess.ImageIdentity
        let isForeground: Bool

        var name: String { URL(fileURLWithPath: image.path).lastPathComponent.lowercased() }
        var isShell: Bool { ["sh", "bash", "zsh", "dash", "ksh", "fish"].contains(name) }
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
        guard let parentPID, parentPID > 1,
              case .localProcess(let peerPID, let start) = origin,
              let peer = inspector.kernel.process(peerPID), peer.startedAtUs == start,
              peer.parent == parentPID, let tty = peer.terminal else { return nil }
        let rows = inspector.scan(peerPID)
        var snapshots: [Snapshot] = []
        var candidates: [ChatSessionIdentity.Process] = []
        for row in rows {
            guard let process = inspector.kernel.process(row.pid), process.startedAtUs == row.startedAtUs,
                  process.parent == row.ppid, process.terminal == tty,
                  let image = inspector.kernel.image(row.pid) else { return nil }
            if inspector.signed(row.pid) { candidates.append(process) }
            snapshots.append(Snapshot(process: process, image: image, isForeground: row.isForeground))
        }
        // Count every signed image, including renamed/background/nested Claude.
        guard candidates.count == 1, let claude = candidates.first else { return nil }
        let known = Dictionary(snapshots.map { ($0.process.pid, $0) }, uniquingKeysWith: { a, _ in a })
        guard known.count == rows.count, known[peerPID]?.process == peer,
              known[claude.pid]?.isForeground == true,
              let lineage = ancestry(of: peerPID, in: known),
              let ownerIndex = lineage.firstIndex(where: { $0.process == claude }), ownerIndex > 0,
              lineage[1..<ownerIndex].allSatisfy(\.isShell) else { return nil }
        for snapshot in snapshots where snapshot.process.pid != claude.pid {
            guard !snapshot.name.contains("claude"),
                  !["tmux", "screen", "zellij", "dtach", "abduco"].contains(snapshot.name) else { return nil }
            if ["node", "nodejs"].contains(snapshot.name) {
                // Normal MCP servers are Claude descendants. A runtime on the
                // hook lineage cannot borrow its ancestor's native signature;
                // a runtime elsewhere on the TTY is another possible session.
                guard let chain = ancestry(of: snapshot.process.pid, in: known),
                      chain.contains(where: { $0.process == claude }) else { return nil }
            }
        }
        guard snapshots.allSatisfy({ inspector.kernel.process($0.process.pid) == $0.process
            && inspector.kernel.image($0.process.pid) == $0.image }) else { return nil }
        let evidence = Self(process: claude, snapshots: snapshots)
        return evidence.isCurrent(inspector: inspector) ? evidence : nil
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
        return inspector.kernel.process(process.pid) == process
    }
}
