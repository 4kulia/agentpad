import AgentPadHookKit
import Foundation

/// `agentpad-cli team status|login|logout|members|invite` against the server
/// (docs/agentpad/DESIGN-C7.md): another view of the organization's window —
/// the same model (`ChatOrgModel`), rights, visibility and ways of the core.
@MainActor
enum ChatCLI {
    /// One answer: done or not, why, and what to tell.
    struct Answer {
        var ok: Bool
        var error: String?
        var fill: (inout AgentPadCLITeamInfo) -> Void = { _ in }

        static func refused(_ outcome: String, _ text: String) -> Answer {
            Answer(ok: false, error: text) { $0.outcome = outcome; $0.detail = text }
        }

        static func done(_ outcome: String, _ text: String, _ more: @escaping (inout AgentPadCLITeamInfo) -> Void = { _ in }) -> Answer {
            Answer(ok: true) {
                $0.outcome = outcome
                $0.detail = text
                more(&$0)
            }
        }
    }

    // MARK: status

    /// What the window and the panel say of the connection, in any state.
    static func status(_ service: ChatService = .shared) -> (inout AgentPadCLITeamInfo) -> Void {
        let connection = service.connection
        let model = ChatOrgModel.current(service)
        let state: String
        var detail: String?
        switch service.state {
        case .off: state = "off"
        case .needsSignIn(let text): state = "closed"; detail = text
        case .notMember(_, let text): state = "not a member"; detail = text
        case .signedIn: state = service.socket?.state == .connected ? "connected" : "connecting"
        }
        var problems = service.problems
        if let model, let notice = model.notice, !problems.contains(notice) { problems.append(notice) }
        if let model, let problem = model.problem, !problems.contains(problem) { problems.append(problem) }
        let org = model?.orgName
        let inDoubt = model.map { $0.visible && $0.inDoubt }
        let me = model?.members.first { $0.accountId == model?.me }
        return { info in
            info.server = connection?.server.description
            info.account = me.map { "\($0.name) @\($0.handle)" } ?? connection?.accountId
            info.connection = state
            info.org = org
            info.rightsInDoubt = inDoubt == true ? true : nil
            info.problems = problems.isEmpty ? nil : problems
            if let detail, info.detail == nil { info.detail = detail }
        }
    }

    // MARK: login

    /// Tests: what opens the Connection tab.
    static var openConnection: @MainActor () -> Void = { ConnectionTabs.shared.show() }
    static var connectionTabs: ConnectionTabs = .shared

    /// Opens Connection: the code from the mail is entered there only.
    static func login() -> Answer {
        openConnection()
        return .done("opened", "finish signing in in the Connection tab")
    }

    // MARK: logout

    /// The window's confirmation, then the core's Disconnect of the
    /// connection there was when asked (DESIGN-C7).
    static func logout(_ service: ChatService = .shared, isCallerWaiting: @escaping @MainActor () -> Bool,
                       now: Date = Date()) async -> Answer {
        guard let connection = service.connection else { return .refused("not_connected", "not connected to a server") }
        let outcome = await connectionTabs.confirmAndDisconnect(
            expecting: connection, service: service, deadline: now.addingTimeInterval(45), isCallerWaiting: isCallerWaiting,
            answerBy: now.addingTimeInterval(110))
        switch outcome {
        case .disconnected: return .done("disconnected", "disconnected")
        case .started: return .done("started", "Disconnect has started; its outcome is not known yet — see `agentpad-cli team status`")
        case .cancelled: return .refused("cancelled", "cancelled in the window")
        case .noAnswer: return .refused("no_answer", "no answer in the window")
        case .stale: return .refused("stale", "the connection changed meanwhile; nothing was done")
        case .busy: return .refused("busy", "a Disconnect is already waiting for an answer or under way")
        case .notFinished(let text): return .refused("not_finished", text)
        }
    }

    // MARK: members, invite

    /// The organization's model, or why there is none to show.
    static func model(_ service: ChatService = .shared) -> Result<ChatOrgModel, AnswerError> {
        switch service.state {
        case .off: return .failure(.init("not_connected", "not connected to a server"))
        case .needsSignIn(let text): return .failure(.init("closed", text))
        case .notMember(_, let text): return .failure(.init("not_member", text))
        case .signedIn: break
        }
        guard let connection = service.connection, let key = connection.orgKey else {
            return .failure(.init("not_connected", "not connected to a server"))
        }
        guard let model = ChatOrgModel.current(service) else {
            let problem = service.orgSessions[key]?.problem ?? "the organization's local copy could not be opened"
            return .failure(.init("no_organization", problem))
        }
        guard model.visible else {
            return .failure(.init("unavailable", model.notice ?? model.problem ?? "the organization cannot be shown now"))
        }
        return .success(model)
    }

    struct AnswerError: Error {
        let outcome, text: String
        init(_ outcome: String, _ text: String) { self.outcome = outcome; self.text = text }
    }

    /// What the window shows this role: members and teams; in doubt, the
    /// user's own name only.
    static func members(_ service: ChatService = .shared) -> Answer {
        let model: ChatOrgModel
        switch Self.model(service) {
        case .failure(let error): return .refused(error.outcome, error.text)
        case .success(let found): model = found
        }
        let members = model.members.map {
            AgentPadCLITeamInfo.Member(name: $0.name, handle: $0.handle, role: $0.role, you: $0.accountId == model.me)
        }
        let teams = model.teams.map { team in
            AgentPadCLITeamInfo.Team(name: team.name, members: team.members.compactMap { model.member($0)?.name },
                                     mine: team.mine, archived: team.archived)
        }
        let org = model.orgName, inDoubt = model.inDoubt
        return Answer(ok: true) {
            $0.outcome = "members"
            $0.detail = inDoubt
                ? "your rights are being checked with the server; only your own name is shown"
                : "\(members.count) member\(members.count == 1 ? "" : "s"), \(teams.count) team\(teams.count == 1 ? "" : "s")"
            $0.org = org
            $0.members = members
            $0.teams = teams
            $0.rightsInDoubt = inDoubt ? true : nil
        }
    }

    /// The window's Invite: the same rights, the teams by name among those
    /// it offers. Answered once queued; the server's answer is the window's.
    static func invite(email: String, role: String?, teams names: [String], _ service: ChatService = .shared) -> Answer {
        let model: ChatOrgModel
        switch Self.model(service) {
        case .failure(let error): return .refused(error.outcome, error.text)
        case .success(let found): model = found
        }
        guard model.actions.contains(.invite) else {
            return model.inDoubt
                ? .refused("rights_in_doubt", "your rights in the organization are being checked with the server; try again in a moment")
                : .refused("forbidden", "only owners and admins invite")
        }
        var ids: [String] = []
        for name in names {
            let offered = model.invitable.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            switch offered.count {
            case 1: ids.append(offered[0].teamId)
            case 0:
                let archived = model.teams.contains { $0.archived && $0.name.caseInsensitiveCompare(name) == .orderedSame }
                return archived ? .refused("archived_team", "team \(name) is archived") : .refused("unknown_team", "no team \(name)")
            default:
                return .refused("ambiguous_team", "more than one team is named \(name)")
            }
        }
        do {
            try model.invite(email: email, role: role ?? "member", teams: ids)
        } catch ChatOrgError.notAllowed {
            return .refused("forbidden", "only owners and admins invite")
        } catch {
            return .refused("not_queued", "the invitation could not be queued: \(error.localizedDescription)")
        }
        return .done("queued", "invited \(email): queued; the server's answer shows in the Organization window")
    }
}
