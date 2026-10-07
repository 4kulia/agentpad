import Foundation

/// Evidence collected before acknowledging the hook, while its sender is alive.
/// No ancestor search: the hook's direct parent must be the tab's Claude PID.
struct AgentAnswerProvenance: Equatable, Sendable {
    struct Snapshot: Equatable, Sendable {
        let process: ChatSessionIdentity.Process
        let image: ChatClaudeProcess.ImageIdentity
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
              peer.parent == parentPID,
              let claude = inspector.kernel.process(parentPID), let tty = claude.terminal,
              peer.terminal == tty else { return nil }
        let rows = inspector.scan(parentPID)
        guard rows.contains(where: { $0.pid == peerPID && $0.startedAtUs == start }),
              rows.contains(where: { $0.pid == parentPID && $0.startedAtUs == claude.startedAtUs }) else { return nil }
        var snapshots: [Snapshot] = []
        for row in rows {
            guard let process = inspector.kernel.process(row.pid), process.startedAtUs == row.startedAtUs,
                  process.parent == row.ppid, process.terminal == tty,
                  let image = inspector.kernel.image(row.pid) else { return nil }
            // Every other signed Claude is ambiguous, including background or
            // nested processes. Unverifiable Claude/node runtimes also refuse.
            let signed = inspector.signed(row.pid)
            if row.pid == parentPID {
                guard signed else { return nil }
            } else {
                let name = URL(fileURLWithPath: image.path).lastPathComponent.lowercased()
                guard !signed, !name.contains("claude"), name != "node", name != "nodejs" else { return nil }
            }
            snapshots.append(Snapshot(process: process, image: image))
        }
        guard snapshots.allSatisfy({ inspector.kernel.process($0.process.pid) == $0.process
            && inspector.kernel.image($0.process.pid) == $0.image }) else { return nil }
        let evidence = Self(process: claude, snapshots: snapshots)
        return evidence.isCurrent(inspector: inspector) ? evidence : nil
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
                  inspector.kernel.process(row.pid) == expected.process,
                  inspector.kernel.image(row.pid) == expected.image else { return false }
        }
        return inspector.kernel.process(process.pid) == process
    }
}
