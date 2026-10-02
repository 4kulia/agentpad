import AgentPadHookKit
import Foundation

/// `agentpad-cli team …` inside the app. The CLI is a local, same-user
/// process — the same trust boundary as `open -e` — so a join it asks for
/// needs no extra dialog here; the inviter still approves on their screen.
@MainActor
enum TeamCLIHandler {
    static func handle(_ request: AgentPadCLIRequest, service: TeamService = .shared) async -> AgentPadCLIResponse {
        guard let raw = request.teamAction, let action = AgentPadCLITeamAction(rawValue: raw) else {
            return .failure("unknown team action")
        }
        do {
            var inviteURL: String?
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
            }
            var response = AgentPadCLIResponse(ok: true, appVersion: AgentPadApp.displayVersion)
            response.team = info(service, inviteURL: inviteURL)
            return response
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
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
