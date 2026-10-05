import Foundation

/// Whether new Claude Code sessions get the team tools (`agentpad-cli mcp`):
/// in server mode, with a session that can be used (DESIGN-D6).
enum TeamTools {
    static func on(mode: TeamMode, sessionProblem: String?) -> Bool { mode == .server && sessionProblem == nil }
}

/// Team work on this Mac: the agents published here and the calls they
/// serve, in one of two modes — off, or through a server (C0). Calls reach
/// other Macs only through the server; until its delivery is in (D8, D4–D6)
/// asking a colleague says so.
@MainActor
@Observable
final class TeamService {
    private static let standard = TeamService(storage: .standard, offCalls: TeamOffCallStore())
    /// Window tests also render views that use the app's shared service.
    /// An explicit scoped replacement keeps those views on temporary storage.
    static var sharedForTesting: TeamService?
    static var shared: TeamService { sharedForTesting ?? standard }

    private(set) var mode: TeamMode = .off
    /// Why team work is off although it was set up, e.g. a damaged
    /// `servers.json`; shown in the Team window.
    private(set) var modeProblem: String?
    /// Team work moved to the server: new Claude Code sessions get the team
    /// tools only then (D6).
    var onTeamToolsChange: @MainActor (Bool) -> Void = { _ in }
    /// Why the server's session cannot be used now — signed out, not a
    /// member — or nil when it can; set by the app (DESIGN-D6).
    var sessionProblem: @MainActor () -> String? = { nil }

    /// The one point that turns the team tools on or off: on only in server
    /// mode with a session that can be used (DESIGN-D6, правка 1).
    func updateTeamTools() {
        onTeamToolsChange(TeamTools.on(mode: mode, sessionProblem: sessionProblem()))
    }

    /// Published agents and calls.
    let calls: TeamCalls
    private let storage: TeamStorage

    /// `offCalls`: the calls while team work is off (none in the app; the
    /// file store of tests when not given).
    init(storage: TeamStorage, runner: TeamAgentRunner = ClaudeCodeRunner(), offCalls: TeamCallStore? = nil) {
        self.storage = storage
        self.calls = TeamCalls(storage: storage, runner: runner, offStore: offCalls)
    }

    // MARK: Lifecycle

    /// Reads the agents published here.
    func load(mode: TeamMode = .off, problem: String? = nil) async {
        self.mode = mode
        calls.serverMode = mode == .server
        modeProblem = problem
        calls.beginLoading()
        do { try calls.load() } catch { modeProblem = error.localizedDescription }
    }

    /// The move to a server is not possible while a run of this app is not
    /// confirmed gone, or a call still runs.
    var canMoveToServer: Bool { !calls.hasRunningCalls && TeamProcesses.shared.runs().isEmpty }

    func enterServerMode() {
        mode = .server
        calls.serverMode = true
        modeProblem = nil
    }

    /// The server service did not start, or was disconnected: team work is off.
    func leaveServerMode(problem: String? = nil) {
        mode = .off
        calls.serverMode = false
        if let problem { modeProblem = problem }
    }
}
