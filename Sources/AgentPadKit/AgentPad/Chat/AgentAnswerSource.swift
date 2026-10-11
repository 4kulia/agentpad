import Foundation

/// Export provenance is separate from the resumable ID used by history and
/// usage monitors. A cwd/mtime match never establishes a journal's owner.
@MainActor
enum AgentAnswerSource {
    struct Binding: Equatable, Sendable {
        let conversation: String
        let process: ChatSessionIdentity.Process
        var provenance: AgentAnswerProvenance? = nil
    }

    struct Check: Equatable, Sendable {
        let binding: Binding
        let foreground: Int32?
    }

    struct Answer {
        let text: String
        let caller: ChatLocalCaller
        let title: String
        /// Memory only, safe for SwiftUI and confirmation predicates.
        let isCurrent: @MainActor () -> Bool
        /// A timeout permits another explicit check, never use of the answer.
        let canRetry: @MainActor () -> Bool
        /// Fresh OS verification for an explicit action, with a deadline.
        let revalidate: @MainActor () async throws -> Void
    }

    static func supports(_ session: Session) -> Bool {
        session.hasProcess && [AgentTemplate.claudeCodeID, AgentTemplate.codex.id].contains(session.displayAgent.rosterId)
    }

    /// Evidence was authenticated on HookServer's worker before ACK. Applying
    /// it must never repeat kernel/image reads on the socket's MainActor hop.
    static func recordHook(conversation: String, session: Session, provenance: AgentAnswerProvenance?,
                           failure: AgentAnswerTranscript.Problem? = nil,
                           hook: AgentAnswerProvenance.Hook? = nil,
                           inspector: AgentAnswerProvenance.Inspector = .init()) {
        session.personalBinding = nil
        session.answerBinding = nil
        session.answerChecked = nil
        session.answerBindingProblem = failure ?? .hookIdentity
        guard session.displayAgent.rosterId == AgentTemplate.claudeCodeID,
              session.effectiveRemoteHost == nil, UUID(uuidString: conversation) != nil else { return }
        if let owner = hook?.owner ?? provenance?.snapshots.first(where: { $0.process == provenance?.process }) {
            session.personalBinding = .init(conversation: conversation, owner: owner)
        }
        guard let provenance else { return }
        guard provenance.containsForeground(session.engine.foregroundPid) else {
            session.answerBindingProblem = .foregroundMismatch
            return
        }
        session.answerBinding = Binding(conversation: conversation, process: provenance.process, provenance: provenance)
        session.answerBindingProblem = nil
        scheduleRefresh(session, inspector: inspector)
    }

    private static func bindingProblem(_ session: Session) -> AgentAnswerTranscript.Problem? {
        guard supports(session) else { return .unbound }
        guard session.effectiveRemoteHost == nil else { return .remote }
        guard session.displayAgent.rosterId != AgentTemplate.codex.id else { return .unverified }
        guard let binding = session.answerBinding else { return session.answerBindingProblem ?? .unbound }
        guard let provenance = binding.provenance, provenance.process == binding.process else { return .changed }
        return nil
    }

    /// Every UI getter (tab bar, menus, previews and publication forms) reads
    /// only this cached result. Reading it never starts work either.
    static func problem(_ session: Session) -> AgentAnswerTranscript.Problem? {
        if let problem = bindingProblem(session) { return problem }
        guard let binding = session.answerBinding, session.answerChecked?.binding == binding else { return .checking }
        return session.answerCheckProblem
    }

    static func scheduleRefresh(_ session: Session, inspector: AgentAnswerProvenance.Inspector = .init()) {
        session.answerRefresh?.cancel()
        session.answerRefresh = Task { [weak session] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let session else { return }
            try? await refresh(session, inspector: inspector)
        }
    }

    static func refresh(_ session: Session, inspector: AgentAnswerProvenance.Inspector = .init(),
                        timeout: TimeInterval = 2) async throws {
        if let problem = bindingProblem(session) { throw problem }
        guard let binding = session.answerBinding, let provenance = binding.provenance else { throw AgentAnswerTranscript.Problem.unbound }
        let check = Check(binding: binding, foreground: session.engine.foregroundPid)
        let problem: AgentAnswerTranscript.Problem?
        do {
            problem = try await BackgroundInspection.run(timeout: timeout) {
                provenance.matchesForeground(check.foreground, inspector: inspector) ? nil : .changed
            }
        } catch is CancellationError { throw CancellationError() }
        catch { problem = .inspectionTimeout }
        guard session.answerBinding == check.binding, session.engine.foregroundPid == check.foreground else {
            session.answerChecked = nil
            throw AgentAnswerTranscript.Problem.changed
        }
        session.answerChecked = check
        session.answerCheckProblem = problem
        if let problem { throw problem }
    }

    typealias Reader = @Sendable (AgentAnswerTranscript.Agent, String, URL) throws -> String

    static func read(session: Session, store: WorkspaceStore, inspector: AgentAnswerProvenance.Inspector = .init(),
                     reader: @escaping Reader = { try AgentAnswerTranscript.read(agent: $0, conversation: $1, root: $2) },
                     owner: (@MainActor () -> WorkspaceStore?)? = nil,
                     timeout: TimeInterval = 2) async throws -> Answer {
        try await refresh(session, inspector: inspector, timeout: timeout)
        guard let binding = session.answerBinding else { throw AgentAnswerTranscript.Problem.unbound }
        let attached: @MainActor () -> Bool = { [weak session, weak store] in
            guard let session, let store = owner?() ?? store else { return false }
            return session.answerBinding == binding
                && store.workspaces.contains { $0.root.allPanes.contains { $0.tabs.contains { $0 === session } } }
        }
        let current: @MainActor () -> Bool = { [weak session] in
            guard let session else { return false }
            return attached() && problem(session) == nil
        }
        let canRetry: @MainActor () -> Bool = { [weak session] in
            guard let session else { return false }
            return attached() && problem(session) == .inspectionTimeout
        }
        let revalidate: @MainActor () async throws -> Void = { [weak session] in
            guard let session, session.answerBinding == binding else { throw AgentAnswerTranscript.Problem.changed }
            try await refresh(session, inspector: inspector, timeout: timeout)
            guard current() else { throw AgentAnswerTranscript.Problem.changed }
        }
        guard current() else { throw AgentAnswerTranscript.Problem.changed }
        let caller = ChatLocalCaller(surface: session.id.uuidString.lowercased(), claudePID: binding.process.pid,
            claudeStart: binding.process.startedAtUs, signature: ChatSessionIdentity.name(ChatSessionIdentity.tab(session, processes: [])))
        let title = "\(session.displayAgent.title) · \(caller.signature)"
        let root = store.claudeProjectsRoot
        let text = try await BackgroundInspection.run(timeout: timeout) {
            try reader(.claude, binding.conversation, root)
        }
        try await revalidate()
        return Answer(text: text, caller: caller, title: title, isCurrent: current, canRetry: canRetry, revalidate: revalidate)
    }
}
