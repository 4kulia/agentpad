import Foundation
import GRDB

@MainActor
enum CLIListAccess {
    /// Local tab callers can see display titles without Claude signatures,
    /// conversation bindings or a Team connection. Published tabs, executor
    /// history, live runs and unverified history receive only names/fallbacks.
    static func allowsDisplayTitles(_ origin: AgentPadCallerOrigin, sessions: [Session],
                                    service: ChatService = .shared,
                                    executors: ExecutorConversations = .init(files: .standard),
                                    run: @escaping @Sendable (Int32) -> TeamProcesses.RunLookup = { TeamProcesses.shared.run(containing: $0) },
                                    process: @escaping @Sendable (Int32) -> ChatSessionIdentity.Process? = ChatSessionIdentity.Process.read) async -> Bool {
        guard case .localProcess(let pid, let start) = origin, start != 0, service.journalProblem == nil else { return false }
        struct Seed: Equatable, Sendable {
            let id: UUID
            let pid: Int32?
            let local: Bool
            let conversations: [String]
        }
        func snapshot() -> [Seed] {
            sessions.map { session in
                Seed(id: session.id, pid: session.engine.foregroundPid,
                     local: session.hasProcess && session.effectiveRemoteHost == nil,
                     conversations: [session.conversationId, session.launchedConversationId, session.resumedConversationId].compactMap { $0?.lowercased() })
            }
        }
        let seeds = snapshot(), journal = service.journal, root = service.claudeProjectsRoot
        let publicationRevision = service.publishRevision
        let result = try? await BackgroundInspection.run { () -> (Seed, [String])? in
            guard let peer = process(pid), peer.startedAtUs == start, run(pid) == .notFound else { return nil }
            var lineage = [peer]
            while let last = lineage.last, last.parent > 1, lineage.count < 256,
                  !lineage.contains(where: { $0.pid == last.parent }), let parent = process(last.parent) {
                lineage.append(parent)
            }
            let matches = seeds.compactMap { seed -> (Seed, ChatSessionIdentity.Process)? in
                guard seed.local, let pid = seed.pid, let foreground = process(pid),
                      lineage.contains(foreground) || (peer.terminal != nil && peer.terminal == foreground.terminal) else { return nil }
                return (seed, foreground)
            }
            guard matches.count == 1, let (seed, foreground) = matches.first,
                  try executors.ids().isDisjoint(with: seed.conversations) else { return nil }
            let incomplete = try executors.seedIncompleteBefore()
            guard incomplete == nil || !seed.conversations.isEmpty,
                  seed.conversations.allSatisfy({ ExecutorConversations.allowsHistory($0, incompleteBefore: incomplete, root: root) }) else { return nil }
            var publications: [String] = []
            if let journal {
                guard let ids = try journal.queue.read({ db -> [String]? in
                    guard try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM publication_surfaces WHERE surface_id = ?)",
                                            arguments: [seed.id.uuidString.lowercased()])! else { return nil }
                    return try String.fetchAll(db, sql: "SELECT DISTINCT agent_id FROM assignments")
                }) else { return nil }
                publications = ids
            }
            guard run(pid) == .notFound, process(foreground.pid) == foreground,
                  lineage.allSatisfy({ process($0.pid) == $0 }) else { return nil }
            return (seed, publications)
        }
        guard let (seed, publications) = result, snapshot() == seeds, service.journal === journal, service.journalProblem == nil, service.publishRevision == publicationRevision else { return false }
        return !publications.contains { service.localAgent($0)?.sessionId.map { seed.conversations.contains($0.lowercased()) } == true }
    }
}
