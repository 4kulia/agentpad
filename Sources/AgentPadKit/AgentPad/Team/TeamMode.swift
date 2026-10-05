import Foundation

/// How team work runs in this process (docs/agentpad/CHAT-PLAN.md 6.11, C0):
/// `server` when `chat/servers.json` holds a connection, else `off`. Direct
/// mode over iroh is gone (decision "Прямой режим удаляется сейчас, старые
/// данные не переносятся"): the files of AgentPad 1.0.x in `team/` are
/// neither read nor moved.
enum TeamMode: String, Equatable, Sendable {
    case server
    case off

    struct Resolution: Equatable, Sendable {
        let mode: TeamMode
        /// Shown in the Team window when the saved connection could not be read.
        let problem: String?
    }

    static let damagedConnectionText = "Server connection settings are damaged; team work is off."

    /// `Application Support/agentpad/chat/` — created on the first connection
    /// to a server (C1), never by reading.
    static var standardChatDirectory: URL {
        AgentPadShellIntegration.agentPadAppSupport("chat", isDirectory: true)
    }

    static func serversURL(in chatDirectory: URL) -> URL {
        chatDirectory.appendingPathComponent("servers.json")
    }

    /// Reads, never writes: no file or folder is created, nothing touches the
    /// network.
    static func resolve(chatDirectory: URL = standardChatDirectory) -> Resolution {
        switch savedConnections(at: serversURL(in: chatDirectory)) {
        case .some(let count) where count > 0: Resolution(mode: .server, problem: nil)
        case .none: Resolution(mode: .off, problem: damagedConnectionText)
        default: Resolution(mode: .off, problem: nil)
        }
    }

    /// How many connections `servers.json` holds: 0 when there is no file,
    /// nil when it is not the expected `{"servers": [{…}, …]}`. The record's
    /// fields belong to `ChatConnection` (C1); only the shape is checked here.
    static func savedConnections(at url: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["servers"] as? [Any],
              servers.allSatisfy({ $0 is [String: Any] })
        else { return nil }
        return servers.count
    }

    /// At launch: saved team state loads, then a saved server connection
    /// starts. The team tools of new Claude Code sessions follow the outcome:
    /// on in server mode, off otherwise (review C14-3).
    @MainActor
    static func startAtLaunch(_ resolution: Resolution, service: TeamService = .shared,
                              startServer: @MainActor (TeamMode) async throws -> Void) async {
        await service.load(mode: resolution.mode, problem: resolution.problem)
        guard resolution.mode == .server else { return service.updateTeamTools() }
        do {
            try await startServer(.server)
        } catch {
            service.leaveServerMode(problem: error.localizedDescription)
        }
        service.updateTeamTools()
    }

    /// Connecting to a server (C5): team work moves to it once signed in.
    /// Not while a run of this app is not confirmed gone — it would run on
    /// beside the server's — checked first, with nothing awaited before.
    /// When starting the server service fails, team work is off and the
    /// error is thrown.
    @MainActor
    static func switchToServer(service: TeamService = .shared, startServer: @MainActor (TeamMode) async throws -> Void) async throws {
        guard service.canMoveToServer else { throw TeamError.teamWorkOn }
        service.enterServerMode()
        do {
            try await startServer(.server)
        } catch {
            service.leaveServerMode()
            throw error
        }
        service.updateTeamTools()
    }
}
