import Foundation

/// Export provenance is separate from the resumable ID used by history and
/// usage monitors. A cwd/mtime match never establishes a journal's owner.
@MainActor
enum AgentAnswerSource {
    struct Binding: Equatable {
        let conversation: String
        let process: ChatSessionIdentity.Process
        var provenance: AgentAnswerProvenance? = nil
    }

    struct Answer {
        let text: String
        let caller: ChatLocalCaller
        let title: String
        let isCurrent: @MainActor () -> Bool
    }

    static func supports(_ session: Session) -> Bool {
        !session.isChat && [AgentTemplate.claudeCodeID, AgentTemplate.codex.id].contains(session.displayAgent.rosterId)
    }

    /// Surface routing and history IDs alone never prove PID → journal.
    static func recordHook(conversation: String, session: Session, provenance: AgentAnswerProvenance?,
                           inspector: AgentAnswerProvenance.Inspector = .init()) {
        session.answerBinding = nil
        guard session.displayAgent.rosterId == AgentTemplate.claudeCodeID,
              session.effectiveRemoteHost == nil, UUID(uuidString: conversation) != nil,
              let provenance, provenance.matchesForeground(session.engine.foregroundPid, inspector: inspector) else { return }
        session.answerBinding = Binding(conversation: conversation, process: provenance.process, provenance: provenance)
    }

    static func problem(_ session: Session, inspector: AgentAnswerProvenance.Inspector = .init()) -> AgentAnswerTranscript.Problem? {
        guard supports(session) else { return .unbound }
        guard session.effectiveRemoteHost == nil else { return .remote }
        // There is currently no verified Codex journal binding provider. Keep
        // both actions disabled even for a resumed tab or a stable process.
        guard session.displayAgent.rosterId != AgentTemplate.codex.id else { return .unverified }
        guard let binding = session.answerBinding else { return .unbound }
        guard let provenance = binding.provenance, provenance.process == binding.process,
              provenance.matchesForeground(session.engine.foregroundPid, inspector: inspector) else { return .changed }
        return nil
    }

    typealias Reader = @Sendable (AgentAnswerTranscript.Agent, String, URL) throws -> String

    static func read(session: Session, store: WorkspaceStore, inspector: AgentAnswerProvenance.Inspector = .init(),
                     reader: @escaping Reader = { try AgentAnswerTranscript.read(agent: $0, conversation: $1, root: $2) }) async throws -> Answer {
        if let problem = problem(session, inspector: inspector) { throw problem }
        guard let binding = session.answerBinding else { throw AgentAnswerTranscript.Problem.unbound }
        let current: @MainActor () -> Bool = { [weak session, weak store] in
            guard let session, let store else { return false }
            return session.answerBinding == binding && problem(session, inspector: inspector) == nil
                && store.workspaces.contains { $0.root.allPanes.contains { $0.tabs.contains { $0 === session } } }
        }
        guard current() else { throw AgentAnswerTranscript.Problem.changed }
        let caller = ChatLocalCaller(surface: session.id.uuidString.lowercased(), claudePID: binding.process.pid,
            claudeStart: binding.process.startedAtUs, signature: ChatSessionIdentity.name(ChatSessionIdentity.tab(session, processes: [])))
        let title = "\(session.displayAgent.title) · \(caller.signature)"
        let root = store.claudeProjectsRoot
        let conversation = binding.conversation
        let text = try await Task.detached(priority: .userInitiated) {
            try reader(.claude, conversation, root)
        }.value
        guard current() else { throw AgentAnswerTranscript.Problem.changed }
        return Answer(text: text, caller: caller, title: title, isCurrent: current)
    }
}
