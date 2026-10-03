import AgentPadHookKit
import Foundation

/// `agentpad-cli team …` inside the app. The CLI is a local, same-user
/// process — the same trust boundary as `open -e` — so a join it asks for
/// needs no extra dialog here; the inviter still approves on their screen.
@MainActor
enum TeamCLIHandler {
    static func handle(
        _ request: AgentPadCLIRequest, service: TeamService = .shared,
        isCallerWaiting: @MainActor () -> Bool = { true }
    ) async -> AgentPadCLIResponse {
        guard let raw = request.teamAction, let action = AgentPadCLITeamAction(rawValue: raw) else {
            return .failure("unknown team action")
        }
        do {
            var inviteURL: String?
            var extra: (inout AgentPadCLITeamInfo) -> Void = { _ in }
            switch action {
            case .status:
                break
            case .on:
                await service.enable(displayName: request.teamName ?? service.config.displayName)
                if case .failed(let reason) = service.status { return .failure(reason) }
            case .off:
                try await service.disable()
            case .invite:
                inviteURL = try await service.createInvite().absoluteString
            case .join:
                guard let raw = request.teamLink, let url = URL(string: raw),
                      let link = try TeamInviteLink.parse(url)
                else { return .failure("not an AgentPad team invitation link") }
                // The code to compare is visible meanwhile in `team status`.
                try await service.join(try service.prepareJoin(link))
            case .approve, .deny:
                guard let peer = request.teamPeer, service.pendingPairings.contains(where: { $0.peerId == peer }) else {
                    return .failure("no join request from that peer")
                }
                service.decide(peer, approve: action == .approve)
            case .remove:
                guard let peer = request.teamPeer, service.contacts.contains(where: { $0.id == peer }) else {
                    return .failure("no colleague with that id")
                }
                try service.remove(peer)
            case .agents:
                if request.teamMine == true {
                    let published = published(service)
                    extra = { $0.published = published }
                } else {
                    guard service.isOn else { throw TeamError.notEnabled }
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
                let remotes = await cwdRemotes(request)
                // The CLI gives up after 15 s; a call it never heard of must
                // not be sent behind its back.
                guard ContinuousClock.now - asked < .seconds(8), isCallerWaiting() else {
                    return .failure("reading the project's git remotes took too long; nothing was sent")
                }
                let call = try service.calls.ask(
                    address, prompt: prompt, threadId: request.teamThread,
                    origin: TeamCallOrigin(session: nil, project: remotes.first)
                )
                extra = { $0.call = callInfo(call) }
            case .check, .cancel:
                guard let id = request.teamCall else { return .failure("which call? pass its id") }
                let wait = min(max(request.teamWaitSeconds ?? 0, 0), AgentPadHookKit.teamCheckRoundSeconds)
                let call = action == .check
                    ? await service.calls.check(id, wait: wait)
                    : await service.calls.cancel(id)
                guard let call else { return .failure("no call \(id) on this Mac (calls are kept for 30 days)") }
                extra = { $0.call = callInfo(call) }
            case .publish:
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
            case .unpublish:
                guard let name = request.teamAgent, let agent = service.calls.agents.first(where: { $0.name == name.lowercased() }) else {
                    return .failure("no published agent by that name")
                }
                try service.calls.unpublish(agent.id)
                let published = published(service)
                extra = { $0.published = published }
            }
            var response = AgentPadCLIResponse(ok: true, appVersion: AgentPadApp.displayVersion)
            var team = info(service, inviteURL: inviteURL)
            extra(&team)
            response.team = team
            return response
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
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
        return AgentPadCLITeamInfo.Call(
            id: call.id, address: call.address, state: r.state.rawValue, final: r.state.isFinal,
            text: r.text, truncated: r.truncated, threadId: r.threadId, activity: r.activity,
            detail: r.detail, note: call.note, turns: r.turns, durationMs: r.durationMs
        )
    }

    static func info(_ service: TeamService, inviteURL: String? = nil) -> AgentPadCLITeamInfo {
        let (status, detail): (String, String?) = switch service.status {
        case .off: ("off", nil)
        case .starting: ("starting", nil)
        case .on: ("on", nil)
        case .failed(let reason): ("failed", reason)
        }
        let now = Date()
        return AgentPadCLITeamInfo(
            status: status,
            detail: detail,
            name: service.config.displayName,
            id: service.localId,
            colleagues: service.contacts.map {
                .init(id: $0.id, name: $0.displayName, online: $0.isOnline(now: now), lastSeen: $0.lastSeen)
            },
            pending: service.pendingPairings.map { .init(peer: $0.peerId, name: $0.name, code: $0.code) },
            inviteURL: inviteURL,
            outgoing: service.outgoingJoin.map { .init(peer: $0.inviterId, name: $0.link.inviterName, code: $0.code ?? "(waiting for the other Mac)") }
        )
    }
}
