import Foundation

// AgentPad: `agentpad-cli team …` — team work from scripts (TEAM.md 7.5).
// Wire types and rendering live here so the CLI and the app compile the same
// structs, like the rest of CLIProtocol.swift.

public struct AgentPadCLITeamInfo: Codable, Equatable, Sendable {
    public struct Colleague: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var online: Bool
        public var lastSeen: Date?
        public init(id: String, name: String, online: Bool, lastSeen: Date?) {
            self.id = id; self.name = name; self.online = online; self.lastSeen = lastSeen
        }
    }

    public struct Pending: Codable, Equatable, Sendable {
        public var peer: String
        public var name: String
        public var code: String
        public init(peer: String, name: String, code: String) { self.peer = peer; self.name = name; self.code = code }
    }

    /// off / starting / on / failed
    public var status: String
    public var detail: String?
    public var name: String
    public var id: String?
    public var colleagues: [Colleague]
    public var pending: [Pending]
    /// `invite`: the new link. `join`: nil.
    public var inviteURL: String?
    /// This Mac's own join waiting for an answer, with the code to compare.
    public var outgoing: Pending?

    public init(status: String, detail: String?, name: String, id: String?, colleagues: [Colleague], pending: [Pending], inviteURL: String? = nil, outgoing: Pending? = nil) {
        self.status = status; self.detail = detail; self.name = name; self.id = id
        self.colleagues = colleagues; self.pending = pending; self.inviteURL = inviteURL; self.outgoing = outgoing
    }
}

/// The `team` subcommands.
public enum AgentPadCLITeamAction: String, Sendable, CaseIterable {
    case status, on, off, invite, join, approve, deny, remove
}

extension AgentPadHookKit {
    static let teamUsage = """
    usage: agentpad-cli team status [--json]
           agentpad-cli team on [--name <name>]
           agentpad-cli team off
           agentpad-cli team invite
           agentpad-cli team join --link <agentpad://team/join?…>
           agentpad-cli team approve|deny|remove --peer <id>
    """

    static func parseTeamCommand(_ args: [String]) -> Result<AgentPadCLICommand, AgentPadCLIParseFailure> {
        guard let raw = args.first, let action = AgentPadCLITeamAction(rawValue: raw) else {
            return .failure(AgentPadCLIParseFailure("team expects a subcommand.\n\(teamUsage)"))
        }
        var values: [String: String] = [:]
        var json = false
        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--json":
                json = true; i += 1
            case "--name", "--link", "--peer":
                guard i + 1 < args.count else { return .failure(AgentPadCLIParseFailure("\(arg) expects a value.\n\(teamUsage)")) }
                values[arg] = args[i + 1]; i += 2
            case "--help", "-h":
                return .success(.help)
            default:
                return .failure(AgentPadCLIParseFailure("unknown argument '\(arg)'.\n\(teamUsage)"))
            }
        }
        switch action {
        case .join where values["--link"] == nil:
            return .failure(AgentPadCLIParseFailure("--link is required.\n\(teamUsage)"))
        case .approve, .deny, .remove:
            guard values["--peer"] != nil else { return .failure(AgentPadCLIParseFailure("--peer is required.\n\(teamUsage)")) }
        default:
            break
        }
        return .success(.team(action: action.rawValue, name: values["--name"], link: values["--link"], peer: values["--peer"], json: json))
    }

    public static func renderCLITeam(_ info: AgentPadCLITeamInfo, action: String) -> String {
        if action == AgentPadCLITeamAction.invite.rawValue, let url = info.inviteURL {
            return plain(url)
        }
        var lines = ["team work: \(plain(info.status))" + (info.detail.map { " — \(plain($0))" } ?? "")]
        if let id = info.id { lines.append("you: \(plain(info.name))  \(plain(id))") }
        if let outgoing = info.outgoing {
            lines.append("joining \(plain(outgoing.name)): waiting for approval, code \(plain(outgoing.code))")
        }
        for pending in info.pending {
            lines.append("join request: \(plain(pending.name))  code \(plain(pending.code))  peer \(plain(pending.peer))")
        }
        if info.colleagues.isEmpty {
            lines.append("no colleagues yet")
        } else {
            for colleague in info.colleagues {
                let seen = colleague.online ? "online" : (colleague.lastSeen.map { "last seen \(ISO8601DateFormatter().string(from: $0))" } ?? "never seen")
                lines.append("  \(colleague.online ? "●" : "○") \(plain(colleague.name))  \(seen)  \(plain(colleague.id))")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func renderCLITeamJSON(_ info: AgentPadCLITeamInfo) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
