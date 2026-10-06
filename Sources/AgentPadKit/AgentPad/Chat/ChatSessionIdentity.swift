import Darwin
import Foundation

/// A live tab and the Claude process that owns the MCP caller. Neither a hook
/// conversation UUID nor AGENTPAD_SURFACE_ID is consulted for attribution.
struct ChatLocalCaller: Codable, Equatable, Sendable {
    var surface: String
    var claudePID: Int32
    var claudeStart: UInt64
    var signature: String

    var provenance: String { "\(surface)/\(claudePID)/\(claudeStart)" }
}

@MainActor
enum ChatSessionIdentity {
    enum VerificationError: String, Error {
        case processUnavailable = "session_process_unavailable"
        case notInTab = "session_not_in_tab"
        case unrecognizedSignature = "unrecognized_claude_code_signature"
        case ambiguous = "ambiguous_session"
        case teamRun = "team_run_not_allowed"
        case imageChanged = "session_image_changed"

        var message: String {
            switch self {
            case .processUnavailable:
                "The calling process has ended or cannot be verified. Restart Claude in this tab and retry."
            case .notInTab:
                "The calling process is not attached to an open AgentPad terminal tab. Start or restart Claude in this tab and retry."
            case .unrecognizedSignature:
                "AgentPad: unrecognized Claude Code signature. Install the official native Claude Code and restart it in this tab. npm/node installations cannot be verified because the node executable is not signed by Anthropic."
            case .ambiguous:
                "More than one Claude process or tab matches this call. Close nested Claude sessions and retry."
            case .teamRun:
                "Channel tools are not available to an agent executing a team call."
            case .imageChanged:
                "The calling process or Claude executable changed during verification. Restart Claude in this tab and retry."
            }
        }
    }

    struct Tab: Sendable {
        var id: UUID
        var customTitle: String?
        var folderName: String
        var processes: [SessionProcessScanner.Raw]
    }

    struct Process: Equatable, Sendable {
        let pid: Int32
        let parent: Int32
        let startedAtUs: UInt64
        let terminal: Int32?

        nonisolated static func read(_ pid: Int32) -> Process? {
            guard pid > 1 else { return nil }
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride,
                  info.kp_proc.p_pid == pid, info.kp_proc.p_stat != SZOMB else { return nil }
            let time = info.kp_proc.p_starttime
            let start = UInt64(time.tv_sec) * 1_000_000 + UInt64(time.tv_usec)
            guard start != 0 else { return nil }
            return Process(pid: pid, parent: info.kp_eproc.e_ppid, startedAtUs: start,
                           terminal: info.kp_eproc.e_tdev == -1 ? nil : info.kp_eproc.e_tdev)
        }
    }

    struct Kernel: Sendable {
        var process: @Sendable (Int32) -> Process? = Process.read
        var image: @Sendable (Int32) -> ChatClaudeProcess.ImageIdentity? = ChatClaudeProcess.imageIdentity
    }

    /// Request-local evidence, never persisted or reused under a PID alone.
    struct Verification: Sendable {
        let caller: ChatLocalCaller
        let foreground: Process
        let lineage: [Process]
        let signatures: [Int32: ChatClaudeProcess.SignatureKey]
    }

    static func resolve(_ origin: AgentPadCallerOrigin, sessions: [Session],
                        signatureVerifier: @escaping @Sendable (Int32) -> Bool = ChatClaudeProcess.hasTrustedSignature) async -> ChatLocalCaller? {
        try? await verify(origin, sessions: sessions, signatureVerifier: signatureVerifier).caller
    }

    static func verify(_ origin: AgentPadCallerOrigin, sessions: [Session],
                       scan: @escaping @Sendable (Int32) -> [SessionProcessScanner.Raw] = SessionProcessScanner.identityProcesses,
                       signatureVerifier: @escaping @Sendable (Int32) -> Bool = ChatClaudeProcess.hasTrustedSignature,
                       kernel: Kernel = Kernel()) async throws -> Verification {
        MainThreadWatchdog.shared.checkpoint()
        if origin.isTeamRun { throw VerificationError.teamRun }
        guard case .localProcess(let pid, let start) = origin else { throw VerificationError.processUnavailable }
        // Only AppKit/session state is read here. Kernel walks for every tab,
        // SecCode signature checks and author name formatting run away from the UI.
        // The action later checks only these PID/image identities synchronously.
        let seeds = sessions.filter { $0.channel == nil }.map { (tab($0, processes: []), $0.engine.foregroundPid ?? 0) }
        return try await Task.detached(priority: .userInitiated) {
            func identity(_ pid: Int32, _ start: UInt64) -> Bool {
                start != 0 && kernel.process(pid)?.startedAtUs == start
            }
            guard identity(pid, start) else { throw VerificationError.processUnavailable }
            guard TeamProcesses.shared.run(containing: pid) == .notFound else { throw VerificationError.teamRun }
            let foregrounds = seeds.map { kernel.process($0.1) }
            let tabs = seeds.map { seed, foreground in
                var tab = seed
                tab.processes = scan(foreground)
                return tab
            }
            var cache: [ChatClaudeProcess.SignatureKey: Bool] = [:]
            var signatures: [Int32: ChatClaudeProcess.SignatureKey] = [:]
            func signed(_ candidate: Int32) -> Bool {
                guard let process = kernel.process(candidate), let image = kernel.image(candidate) else { return false }
                let key = ChatClaudeProcess.SignatureKey(pid: candidate, startedAtUs: process.startedAtUs, image: image)
                let trusted = cache[key] ?? signatureVerifier(candidate)
                guard identity(candidate, key.startedAtUs), kernel.image(candidate) == image else { return false }
                cache[key] = trusted
                signatures[candidate] = key
                return trusted
            }
            let caller = try verify(pid: pid, startedAt: start, tabs: tabs, identity: identity, signatureVerifier: signed)
            guard let index = tabs.firstIndex(where: { $0.id.uuidString.lowercased() == caller.surface }),
                  let foreground = foregrounds[index], let tty = foreground.terminal else { throw VerificationError.notInTab }
            let rows = Dictionary(tabs[index].processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            var lineage: [Process] = [], next = pid
            while next > 1, let row = rows[next], lineage.count < 256, !lineage.contains(where: { $0.pid == next }) {
                guard let process = kernel.process(next), process.startedAtUs == row.startedAtUs,
                      process.parent == row.ppid, process.terminal == tty,
                      signatures[next]?.startedAtUs == process.startedAtUs else { throw VerificationError.processUnavailable }
                lineage.append(process)
                next = process.parent
            }
            guard lineage.first?.pid == pid, lineage.contains(where: { $0.pid == caller.claudePID && $0.startedAtUs == caller.claudeStart }) else {
                throw VerificationError.processUnavailable
            }
            return Verification(caller: caller, foreground: foreground, lineage: lineage, signatures: signatures)
        }.value
    }

    /// No await and no Security API: this must run in the action's actor turn.
    static func revalidate(_ verified: Verification, sessions: [Session], kernel: Kernel = Kernel()) throws {
        guard let peer = verified.lineage.first, let tty = verified.foreground.terminal else { throw VerificationError.processUnavailable }
        guard kernel.process(peer.pid)?.startedAtUs == peer.startedAtUs,
              kernel.process(verified.caller.claudePID)?.startedAtUs == verified.caller.claudeStart else { throw VerificationError.processUnavailable }
        for expected in verified.lineage {
            guard let now = kernel.process(expected.pid), now.startedAtUs == expected.startedAtUs else { throw VerificationError.processUnavailable }
            guard now == expected else { throw VerificationError.notInTab }
            guard let key = verified.signatures[expected.pid], key.pid == now.pid, key.startedAtUs == now.startedAtUs,
                  kernel.image(now.pid) == key.image else { throw VerificationError.imageChanged }
        }
        let matches = sessions.filter { session in
            guard session.channel == nil, let pid = session.engine.foregroundPid,
                  let foreground = kernel.process(pid), foreground.terminal == tty else { return false }
            return pid != verified.foreground.pid || foreground.startedAtUs == verified.foreground.startedAtUs
        }
        guard matches.count == 1, matches[0].id.uuidString.lowercased() == verified.caller.surface else { throw VerificationError.notInTab }
        guard TeamProcesses.shared.run(containing: peer.pid) == .notFound else { throw VerificationError.teamRun }
        // Image and tab reads must not outlive either endpoint or its parent links.
        guard verified.lineage.allSatisfy({ kernel.process($0.pid) == $0 }) else { throw VerificationError.processUnavailable }
    }

    static func tab(_ session: Session, processes: [SessionProcessScanner.Raw]) -> Tab {
        Tab(id: session.id, customTitle: session.customTitle, folderName: session.currentDirectory.lastPathComponent, processes: processes)
    }

    nonisolated static func resolve(pid: Int32, startedAt: UInt64, tabs: [Tab], identity: (Int32, UInt64) -> Bool,
                        signatureVerifier: ChatClaudeProcess.SignatureVerifier = ChatClaudeProcess.hasTrustedSignature) -> ChatLocalCaller? {
        try? verify(pid: pid, startedAt: startedAt, tabs: tabs, identity: identity, signatureVerifier: signatureVerifier)
    }

    nonisolated static func verify(pid: Int32, startedAt: UInt64, tabs: [Tab], identity: (Int32, UInt64) -> Bool,
                       signatureVerifier: ChatClaudeProcess.SignatureVerifier = ChatClaudeProcess.hasTrustedSignature) throws -> ChatLocalCaller {
        guard identity(pid, startedAt) else { throw VerificationError.processUnavailable }
        func isLiveClaude(_ row: SessionProcessScanner.Raw) -> Bool {
            identity(row.pid, row.startedAtUs) && signatureVerifier(row.pid) && identity(row.pid, row.startedAtUs)
        }
        var found: [(Tab, SessionProcessScanner.Raw)] = []
        var hasTab = false
        for tab in tabs {
            let byPID = Dictionary(tab.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            guard byPID[pid]?.startedAtUs == startedAt else { continue }
            hasTab = true
            var chain = Set<Int32>(), next = pid
            while next > 1, chain.insert(next).inserted, chain.count <= 256, let row = byPID[next] { next = row.ppid }
            let candidates = tab.processes.filter { chain.contains($0.pid) && isLiveClaude($0) }
            // Ambiguous nested Claude processes refuse, even in one terminal.
            guard candidates.count <= 1 else { throw VerificationError.ambiguous }
            guard let claude = candidates.first else { continue }
            found.append((tab, claude))
        }
        guard !found.isEmpty else { throw hasTab ? VerificationError.unrecognizedSignature : VerificationError.notInTab }
        guard found.count == 1 else { throw VerificationError.ambiguous }
        let (tab, claude) = found[0]
        let base = name(tab)
        let duplicates = tabs.filter { name($0) == base && $0.processes.contains(where: isLiveClaude) }.count
        let suffix = duplicates > 1 ? " \(tab.id.uuidString.lowercased().prefix(8))" : ""
        guard identity(pid, startedAt), isLiveClaude(claude) else { throw VerificationError.processUnavailable }
        return ChatLocalCaller(surface: tab.id.uuidString.lowercased(), claudePID: claude.pid, claudeStart: claude.startedAtUs,
                               signature: limited(base, scalars: 120 - suffix.unicodeScalars.count) + suffix)
    }

    nonisolated static func normalized(_ text: String) -> String {
        let clean = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !(0x202A...0x202E).contains($0.value)
                && !(0x2066...0x2069).contains($0.value) && ![0x200E, 0x200F, 0x061C].contains($0.value)
        }
        return limited(String(String.UnicodeScalarView(clean)).split(whereSeparator: \.isWhitespace).joined(separator: " "), scalars: 120)
    }

    /// PostgreSQL char_length counts Unicode scalars, while Swift's prefix
    /// counts graphemes. Keep whole graphemes within the server's 120 limit.
    nonisolated static func limited(_ text: String, scalars maximum: Int) -> String {
        var result = "", count = 0
        for character in text {
            let size = character.unicodeScalars.count
            guard count + size <= maximum else { break }
            result.append(character); count += size
        }
        return result
    }

    nonisolated static func name(_ tab: Tab) -> String {
        for value in [tab.customTitle, tab.folderName] {
            if let value, !normalized(value).isEmpty { return normalized(value) }
        }
        return "Claude Code \(tab.id.uuidString.lowercased().prefix(8))"
    }
}
