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
        session.hasProcess && [AgentTemplate.claudeCodeID, AgentTemplate.codex.id].contains(session.displayAgent.rosterId)
    }

    /// Surface routing and history IDs alone never prove PID → journal.
    static func recordHook(conversation: String, session: Session, provenance: AgentAnswerProvenance?,
                           failure: AgentAnswerTranscript.Problem? = nil,
                           hook: AgentAnswerProvenance.Hook? = nil,
                           inspector: AgentAnswerProvenance.Inspector = .init()) {
        session.personalBinding = nil
        session.answerBinding = nil
        session.answerBindingProblem = failure ?? .hookIdentity
        guard session.displayAgent.rosterId == AgentTemplate.claudeCodeID,
              session.effectiveRemoteHost == nil, UUID(uuidString: conversation) != nil else { return }
        // An MCP child starting/exiting can invalidate the export snapshot
        // after ACK. Retain the authenticated owner for personal tools, which
        // verify their own caller and tab before comparing this exact process.
        if let owner = hook?.owner ?? provenance?.snapshots.first(where: { $0.process == provenance?.process }),
           inspector.kernel.process(owner.process.pid) == owner.process,
           inspector.kernel.image(owner.process.pid) == owner.image {
            session.personalBinding = .init(conversation: conversation, owner: owner)
        }
        guard let provenance else { return }
        guard provenance.isCurrent(inspector: inspector) else { session.answerBindingProblem = .changed; return }
        guard provenance.matchesForeground(session.engine.foregroundPid, inspector: inspector) else {
            session.answerBindingProblem = .foregroundMismatch
            return
        }
        session.answerBinding = Binding(conversation: conversation, process: provenance.process, provenance: provenance)
        session.answerBindingProblem = nil
    }

    static func problem(_ session: Session, inspector: AgentAnswerProvenance.Inspector = .init()) -> AgentAnswerTranscript.Problem? {
        guard supports(session) else { return .unbound }
        guard session.effectiveRemoteHost == nil else { return .remote }
        // There is currently no verified Codex journal binding provider. Keep
        // both actions disabled even for a resumed tab or a stable process.
        guard session.displayAgent.rosterId != AgentTemplate.codex.id else { return .unverified }
        guard let binding = session.answerBinding else { return session.answerBindingProblem ?? .unbound }
        guard let provenance = binding.provenance, provenance.process == binding.process,
              provenance.matchesForeground(session.engine.foregroundPid, inspector: inspector) else { return .changed }
        return nil
    }

    typealias Reader = @Sendable (AgentAnswerTranscript.Agent, String, URL) throws -> String

    static func read(session: Session, store: WorkspaceStore, inspector: AgentAnswerProvenance.Inspector = .init(),
                     reader: @escaping Reader = { try AgentAnswerTranscript.read(agent: $0, conversation: $1, root: $2) },
                     owner: (@MainActor () -> WorkspaceStore?)? = nil) async throws -> Answer {
        if let problem = problem(session, inspector: inspector) { throw problem }
        guard let binding = session.answerBinding else { throw AgentAnswerTranscript.Problem.unbound }
        let current: @MainActor () -> Bool = { [weak session, weak store] in
            guard let session, let store = owner?() ?? store else { return false }
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
