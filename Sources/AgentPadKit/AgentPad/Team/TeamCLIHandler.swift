import AgentPadHookKit
import Foundation

/// `agentpad-cli team …` inside the app. The CLI is a local, same-user
/// process — the same trust boundary as `open -e`.
@MainActor
enum TeamCLIHandler {
    static func handle(
        _ request: AgentPadCLIRequest, service: TeamService = .shared,
        origin: AgentPadCallerOrigin = .outside,
        chatSessions: @escaping @MainActor () -> [Session] = { [] },
        isCallerWaiting: @escaping @MainActor () -> Bool = { true }
    ) async -> AgentPadCLIResponse {
        if let refusal = origin.refusal(for: request) { return .failure(refusal) }
        // A team run asks for folders only for its own call (Y4).
        let isOwnCall: (String?) -> Bool = { id in
            guard case .teamRun(let own) = origin else { return true }
            guard let own, let id else { return false }
            return own.lowercased() == id.lowercased()
        }
        guard let raw = request.teamAction, let action = AgentPadCLITeamAction(rawValue: raw) else {
            return .failure("unknown team action")
        }
        // In server mode without a session that can be used (signed out, the
        // session ended by the server, not a member), what needs the server
        // is refused before anything is written — also for an `agentpad-cli
        // mcp` started earlier (DESIGN-D6, правка 2). `team mine` is local.
        // Team work off (after Disconnect too): the same refusal, not an
        // empty catalog or "no such call" (review D6-3).
        // (A run's folder requests are this Mac's own: `access`, `access-check`.)
        let needsServer: Set<AgentPadCLITeamAction> = [.ask, .check, .cancel, .watch]
        let serverAction = needsServer.contains(action) || (action == .agents && request.teamMine != true)
        func sessionRefusal() -> String? {
            guard serverAction else { return nil }
            return service.mode == .server ? service.sessionProblem() : "not connected to a server"
        }
        if let problem = sessionRefusal() { return .failure(problem) }
        do {
            var extra: (inout AgentPadCLITeamInfo) -> Void = { _ in }
            switch action {
            case .chat:
                return await ChatSessionTools.handle(request, origin: origin, sessions: chatSessions, isCallerWaiting: isCallerWaiting)
            case .status:
                extra = ChatCLI.status()
            case .login:
                return response(ChatCLI.login(), service)
            case .logout:
                return response(await ChatCLI.logout(isCallerWaiting: isCallerWaiting), service)
            case .members:
                return response(ChatCLI.members(), service)
            case .invite:
                guard let email = request.teamEmail else { return .failure("invite expects an email address") }
                return response(ChatCLI.invite(email: email, role: request.teamRole, teams: request.teamTeams ?? []), service)
            case .agents:
                if request.teamMine == true {
                    let published = published(service)
                    extra = { $0.published = published }
                } else {
                    let remotes = await cwdRemotes(request)
                    let agents = await service.calls.catalog(projectRemotes: remotes).map {
                        AgentPadCLITeamInfo.Agent(
                            address: $0.address, colleague: $0.colleague, description: $0.entry.description,
                            access: $0.entry.access.rawValue, sameProject: $0.sameProject,
                            kind: $0.entry.kind, session: $0.entry.session
                        )
                    }
                    extra = { $0.agents = agents }
                }
            case .ask:
                guard let address = request.teamAgent, let prompt = request.teamPrompt else {
                    return .failure("ask needs an agent address and a request")
                }
                let asked = ContinuousClock.now
                // The organization is fixed now, before anything waits: a
                // switch meanwhile refuses rather than asks the other one (review D8d-p2-7).
                let area = service.calls.serverKey
                let remotes = await cwdRemotes(request)
                // The CLI gives up after 15 s; a call it never heard of must
                // not be sent behind its back.
                guard ContinuousClock.now - asked < .seconds(8), isCallerWaiting() else {
                    return .failure("reading the project's git remotes took too long; nothing was sent")
                }
                // The session may have ended while git was read: looked at
                // again right before the write, with no wait between (review D6-1).
                if let problem = sessionRefusal() { return .failure(problem) }
                let call = try service.calls.ask(
                    address, prompt: prompt, threadId: request.teamThread,
                    origin: TeamCallOrigin(session: nil, project: remotes.first), area: .some(area)
                )
                extra = { $0.call = callInfo(call) }
            case .check, .cancel:
                guard let id = request.teamCall else { return .failure("which call? pass its id") }
                if action == .cancel, service.calls.outgoing(id) == nil, service.calls.storeProblem == nil,
                   let cancel = service.calls.cancelChannelOnServer {
                    if let problem = cancel(id) { return .failure(problem) }
                    return response(.done("requested", "Cancellation requested."), service)
                }
                // A refused cancel is a failure, with the call as it goes on (review D8d-p3-4).
                // A final call answers with its outcome, as in 1.0.x (review D8e-p3-11).
                if action == .cancel, let call = service.calls.outgoing(id),
                   !call.report.state.isFinal, let refusal = service.calls.refusal(.cancel, for: call) {
                    var response = AgentPadCLIResponse.failure("\(refusal) Call \(call.id) goes on.", appVersion: AgentPadApp.displayVersion)
                    var team = info(service)
                    team.call = callInfo(call)
                    response.team = team
                    return response
                }
                let wait = min(max(request.teamWaitSeconds ?? 0, 0), AgentPadHookKit.teamCheckRoundSeconds)
                let call = action == .check
                    ? try await service.calls.check(id, wait: wait, scope: request.teamScope)
                    : await service.calls.cancel(id)
                // The calls could not be read: said so, not "no such call" (review D8e-p3-10).
                guard let call else {
                    return .failure(service.calls.storeProblem ?? "no call \(id) on this Mac (calls are kept for 30 days)")
                }
                extra = { $0.call = callInfo(call) }
            case .publish:
                // Publishing to a server is the window's button only until D10 (lead's decision on D3).
                if service.calls.refuses(nil) { return .failure(TeamServerCore.publishFromWindow) }
                guard let name = request.teamAgent else { return .failure("publish needs a name") }
                var agent = service.calls.agents.first { $0.name == name.lowercased() }
                    ?? TeamPublishedAgent(name: name, description: "", folder: "")
                if let folder = request.teamFolder { agent.folder = folder }
                if let description = request.teamDescription { agent.description = description }
                if let raw = request.teamAccess {
                    guard let access = TeamAccessProfile(rawValue: raw) else { return .failure("--access is read, read-git or edit") }
                    agent.access = access
                }
                guard !agent.folder.isEmpty else { return .failure("--folder is required for a new agent") }
                guard !agent.description.isEmpty else { return .failure("--description is required: colleagues' agents read it to decide what to ask") }
                try await service.calls.save(agent)
                let published = published(service)
                extra = { $0.published = published }
            case .access:
                guard let callId = request.teamCall, let path = request.teamFolder else { return .failure("access needs a call and a path") }
                guard isOwnCall(callId) else { return .failure(AgentPadCallerOrigin.teamRunRefusal) }
                let made = try await service.calls.requestAccess(callId: callId, path: path, reason: request.teamDescription ?? "")
                extra = { $0.access = .init(id: made.id, state: made.state.rawValue, path: made.path) }
            case .accessCheck:
                guard isOwnCall(service.calls.accessRequests.first(where: { $0.id == request.teamAgent })?.callId) else {
                    return .failure(AgentPadCallerOrigin.teamRunRefusal)
                }
                guard let id = request.teamAgent,
                      let found = await service.calls.accessStatus(id, wait: min(max(request.teamWaitSeconds ?? 0, 0), AgentPadHookKit.teamCheckRoundSeconds))
                else { return .failure("no such access request") }
                extra = { $0.access = .init(id: found.id, state: found.state.rawValue, path: found.path) }
            case .watch:
                // The CLI reads the run's log itself; it asks here first
                // whether the call may be watched (review D8d-p1-2).
                guard let id = request.teamCall?.lowercased() else { return .failure("which call? pass its id") }
                // Only a call found here, and watchable: an unknown one is no (review D8f-p1-1).
                guard let call = service.calls.incoming.first(where: { $0.id == id }) else {
                    return .failure("no call \(id) on this Mac to watch")
                }
                if let refusal = service.calls.refusal(.watch, for: call) { return .failure(refusal) }
            case .unpublish:
                guard let name = request.teamAgent, let agent = service.calls.agents.first(where: { $0.name == name.lowercased() }) else {
                    return .failure("no published agent by that name")
                }
                try service.calls.unpublish(agent.id)
                let published = published(service)
                extra = { $0.published = published }
            }
            var response = AgentPadCLIResponse(ok: true, appVersion: AgentPadApp.displayVersion)
            var team = info(service)
            extra(&team)
            response.team = team
            return response
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    /// A server action's answer (C7): refused ones carry their outcome too,
    /// for `--json`.
    private static func response(_ answer: ChatCLI.Answer, _ service: TeamService) -> AgentPadCLIResponse {
        var response = AgentPadCLIResponse(ok: answer.ok, error: answer.error, appVersion: AgentPadApp.displayVersion)
        var team = info(service)
        answer.fill(&team)
        response.team = team
        return response
    }

    private static func published(_ service: TeamService) -> [AgentPadCLITeamInfo.Published] {
        service.calls.agents.map {
            AgentPadCLITeamInfo.Published(
                name: $0.name, description: $0.description, folder: $0.folder,
                access: $0.access.rawValue, enabled: $0.enabled
            )
        }
    }

    private static func cwdRemotes(_ request: AgentPadCLIRequest) async -> [String] {
        guard let cwd = request.teamCwd else { return [] }
        return await TeamGitRemote.remotes(of: cwd)
    }

    static func callInfo(_ call: TeamCalls.Outgoing) -> AgentPadCLITeamInfo.Call {
        let r = call.report
        var info = AgentPadCLITeamInfo.Call(
            id: call.id, address: call.address, state: r.state.rawValue, final: r.state.isFinal,
            text: r.text, truncated: r.truncated, threadId: r.threadId, activity: r.activity,
            detail: r.detail, note: call.note, turns: r.turns, durationMs: r.durationMs
        )
        info.scope = TeamCalls.scopeToken(call.scope)
        // Server mode (D10): the request's own state, and whether its answer came.
        info.serverState = call.serverState
        info.answered = call.answered
        info.answerTrimmed = call.answerTrimmed
        return info
    }

    static func info(_ service: TeamService) -> AgentPadCLITeamInfo {
        AgentPadCLITeamInfo(status: service.mode.rawValue, detail: service.modeProblem)
    }
}
