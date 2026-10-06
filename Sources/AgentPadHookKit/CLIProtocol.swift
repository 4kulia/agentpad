import Foundation

// Wire types for the AgentPad CLI control channel (`agentpad-cli` ⇄ `HookServer`).
//
// The CLI shares the hook socket (`AgentPadHookKit.socketPath`) but not its
// fire-and-forget shape: a CLI connection is strictly one request line up,
// one response line back, then close. `kind: "cli"` is the discriminator
// that routes a line into the request/response branch instead of the hook
// event parser — hook payloads either carry a different `kind` or none at
// all, and never this one.
//
// These types live in AgentPadHookKit so the `agentpad-cli` binary and the app
// compile the SAME request/response structs — the wire shape can't drift
// between the two ends the way a comment-synced dict contract could.

/// Protocol constants shared by both ends of the CLI channel.
public enum AgentPadCLIProtocol {
    /// Bumped only on breaking wire changes. The server refuses requests
    /// from a NEWER protocol (old app + new CLI must fail loud, not
    /// half-work); older requests keep working as long as the shape decodes.
    /// The `kind` / `protocolVersion` / `verb` envelope fields are the
    /// never-reshaped core that makes that refusal reachable — the server
    /// peeks `protocolVersion` BEFORE decoding the full request, so a v2
    /// that changes any other field still gets a readable version error
    /// instead of "malformed".
    public static let version = 1

    /// The `kind` value that marks a socket line as a CLI request.
    public static let kind = "cli"

    /// Upper bound for one REQUEST line — enforced by the server's read
    /// loop and pre-checked by the CLI before sending, so an oversized
    /// `open -e` command fails with a readable local error instead of a
    /// server-side truncation.
    public static let maxRequestLineBytes = 65_536

    /// Upper bound for one RESPONSE line read back by the CLI. A `list` of
    /// hundreds of tabs stays well under this; anything larger is a
    /// protocol error, not data.
    public static let maxResponseLineBytes = 4 * 1024 * 1024

    /// One JSON line (trailing `\n`) ready for the socket — the single
    /// framing rule for this channel (both read loops split on `0x0A`).
    public static func encodeLine(_ value: some Encodable) -> Data? {
        guard var data = try? JSONEncoder().encode(value) else { return nil }
        data.append(0x0A)
        return data
    }

    public static func decodeLine<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    /// The one spelling of the too-new refusal — the transport peek is what
    /// users actually hit (it runs before the typed decode); the controller
    /// keeps a deliberate second gate for direct callers, and sharing the
    /// message keeps the two from drifting.
    public static func tooNewRequestMessage(requested: Int) -> String {
        "this \(AppIdentity.appName) speaks CLI protocol \(version) but the request is protocol \(requested) — update \(AppIdentity.appName)"
    }
}

/// The verbs the CLI speaks. The wire carries the raw string so an unknown
/// future verb reaches the server as data (→ a readable "unknown verb"
/// response) instead of failing the whole request decode.
public enum AgentPadCLIVerb: String, Sendable {
    case open
    case resume
    case list
    case focus
    case close
    case status
    case rename
    /// AgentPad: team work (TeamCLI.swift).
    case team
}

public struct AgentPadCLIRequest: Codable, Equatable, Sendable {
    public var kind: String
    public var protocolVersion: Int
    public var verb: String
    /// `open` / `resume`: absolute directory path.
    public var cwd: String?
    /// `open -e`: a shell command line, evaluated verbatim by the spawned
    /// shell's AGENTPAD_AGENT hook. Local-process trust boundary — never
    /// reachable from URLs (deep links stay command-free by design).
    public var command: String?
    /// `open --agent`: an AgentTemplate id. `resume --agent`: a roster id.
    public var agent: String?
    /// `resume --id`.
    public var conversationId: String?
    /// `focus` / `close` / `rename`: session UUID string from `list`.
    public var tab: String?
    /// `open --title` / `rename --title`: the user override that outranks
    /// the tab's automatic (OSC / cwd-derived) title — the same field tab
    /// rename writes. OPTIONAL on the wire (like `noFocus`) so a v1 request
    /// without it still decodes: additive fields must never force a
    /// protocol bump.
    public var title: String?
    /// `open --no-focus`: land the tab in the background — no app
    /// activation, no window fronting, and the tab is not made its pane's
    /// active tab.
    public var noFocus: Bool?
    /// AgentPad, `team`: the subcommand and its values. Optional on the wire,
    /// like every field added after v1.
    public var teamAction: String?
    public var teamAgent: String?
    public var teamPrompt: String?
    public var teamThread: String?
    public var teamCall: String?
    /// check: seconds the app may hold the request waiting for news.
    public var teamWaitSeconds: Int?
    /// check: the calls the follow began in (`Call.scope`); others refuse.
    public var teamScope: String?
    public var teamFolder: String?
    public var teamDescription: String?
    public var teamAccess: String?
    public var teamMine: Bool?
    /// invite (C7): the address, the role, the teams by name.
    public var teamEmail: String?
    public var teamRole: String?
    public var teamTeams: [String]?
    /// The caller's working directory, for the project it is in.
    public var teamCwd: String?
    // AgentPad: validated channel MCP arguments; identity comes from the socket.
    public var chatArguments: String?

    public init(
        verb: AgentPadCLIVerb,
        cwd: String? = nil,
        command: String? = nil,
        agent: String? = nil,
        conversationId: String? = nil,
        tab: String? = nil,
        title: String? = nil,
        noFocus: Bool? = nil
    ) {
        self.kind = AgentPadCLIProtocol.kind
        self.protocolVersion = AgentPadCLIProtocol.version
        self.verb = verb.rawValue
        self.cwd = cwd
        self.command = command
        self.agent = agent
        self.conversationId = conversationId
        self.tab = tab
        self.title = title
        self.noFocus = noFocus
    }
}

public struct AgentPadCLIResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    /// One human-readable line; the CLI prints it to stderr and exits 1.
    public var error: String?
    /// Server's protocol version — the CLI warns on mismatch.
    public var protocolVersion: Int?
    /// The running app's display version. Rides every response for
    /// uniformity, but today only `status` renders it.
    public var appVersion: String?
    /// `open`: the created tab's session UUID (usable with focus/close).
    public var tabId: String?
    /// Optional human-readable postscript ("close requested — AgentPad may
    /// ask for confirmation").
    public var note: String?
    /// `list` payload.
    public var windows: [AgentPadCLIWindowInfo]?
    /// AgentPad: `team` payload.
    public var team: AgentPadCLITeamInfo?
    // AgentPad: structured channel result, without credentials or local paths.
    public var chatResult: String?

    public init(
        ok: Bool,
        error: String? = nil,
        protocolVersion: Int? = AgentPadCLIProtocol.version,
        appVersion: String? = nil,
        tabId: String? = nil,
        note: String? = nil,
        windows: [AgentPadCLIWindowInfo]? = nil
    ) {
        self.ok = ok
        self.error = error
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.tabId = tabId
        self.note = note
        self.windows = windows
    }

    public static func failure(_ message: String, appVersion: String? = nil) -> AgentPadCLIResponse {
        AgentPadCLIResponse(ok: false, error: message, appVersion: appVersion)
    }
}

public struct AgentPadCLIWindowInfo: Codable, Equatable, Sendable {
    /// 1-based position in the app's window list — stable only for the
    /// lifetime of one `list` call; tabs are addressed by UUID, never index.
    public var index: Int
    public var isKey: Bool
    public var workspaces: [AgentPadCLIWorkspaceInfo]

    public init(index: Int, isKey: Bool, workspaces: [AgentPadCLIWorkspaceInfo]) {
        self.index = index
        self.isKey = isKey
        self.workspaces = workspaces
    }
}

public struct AgentPadCLIWorkspaceInfo: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// The workspace's disk root (worktree path when it is a worktree).
    public var path: String
    public var isActive: Bool
    public var tabs: [AgentPadCLITabInfo]

    public init(id: String, title: String, path: String, isActive: Bool, tabs: [AgentPadCLITabInfo]) {
        self.id = id
        self.title = title
        self.path = path
        self.isActive = isActive
        self.tabs = tabs
    }
}

public struct AgentPadCLITabInfo: Codable, Equatable, Sendable {
    /// Session UUID — the id `focus --tab` / `close --tab` take.
    public var id: String
    public var title: String
    public var cwd: String
    /// Active tab of its pane (the visible one when its workspace shows).
    public var isActive: Bool
    /// Display agent's template id; plain shells report "terminal".
    public var agent: String
    /// running / waiting / failed / idle — only for agent tabs.
    public var agentState: String?
    /// A channel tab (`agent` "channel"): its channel, only while the user
    /// may see it — the title is then its name, else "Channel".
    public var channelId: String?

    public init(id: String, title: String, cwd: String, isActive: Bool, agent: String, agentState: String?, channelId: String? = nil) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.isActive = isActive
        self.agent = agent
        self.agentState = agentState
        self.channelId = channelId
    }
}

extension AgentPadCLIRequest {
    public func encodedLine() -> Data? { AgentPadCLIProtocol.encodeLine(self) }

    /// Decodes a socket line that already passed the `kind == "cli"` gate.
    public static func decode(from data: Data) -> AgentPadCLIRequest? {
        AgentPadCLIProtocol.decodeLine(AgentPadCLIRequest.self, from: data)
    }
}

extension AgentPadCLIResponse {
    public func encodedLine() -> Data? { AgentPadCLIProtocol.encodeLine(self) }

    public static func decode(from data: Data) -> AgentPadCLIResponse? {
        AgentPadCLIProtocol.decodeLine(AgentPadCLIResponse.self, from: data)
    }
}
