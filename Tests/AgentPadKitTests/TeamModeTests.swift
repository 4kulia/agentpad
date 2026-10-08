import Foundation
import AgentPadHookKit
import XCTest
@testable import AgentPadKit

@MainActor
final class TeamModeTests: XCTestCase {
    private var root: URL!

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("team-mode-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        try? FileManager.default.removeItem(at: root)
    }

    private var chat: URL { root.appendingPathComponent("support/chat") }
    private var team: TeamStorage { TeamStorage(directory: root.appendingPathComponent("support/team-server")) }
    /// What AgentPad 1.0.x left: direct mode on, a colleague, an identity.
    private var oldTeam: URL { root.appendingPathComponent("support/team") }

    private func writeServers(_ text: String) throws {
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: TeamMode.serversURL(in: chat))
    }

    private func writeOldTeam() throws {
        try FileManager.default.createDirectory(at: oldTeam, withIntermediateDirectories: true)
        try Data(#"{"enabled": true, "displayName": "Andrey"}"#.utf8).write(to: oldTeam.appendingPathComponent("config.json"))
        try Data("not json".utf8).write(to: oldTeam.appendingPathComponent("contacts.json"))
        try Data(#"[{"id": "x"}]"#.utf8).write(to: oldTeam.appendingPathComponent("agents.json"))
    }

    // MARK: Choosing at launch

    func testEmptyHomeIsOffAndCreatesNothing() async throws {
        let resolution = TeamMode.resolve(chatDirectory: chat)
        XCTAssertEqual(resolution, TeamMode.Resolution(mode: .off, problem: nil))
        let service = TeamService(storage: team, runner: FakeTeamRunner())
        await service.load(mode: resolution.mode, problem: resolution.problem)
        XCTAssertEqual(service.mode, .off)
        XCTAssertNil(service.modeProblem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chat.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: team.directory.path))
    }

    /// Stage E: the `team/` folder of 1.0.x is neither read nor moved — not
    /// even a damaged file in it is noticed, and it stays as it was.
    func testTeamFolderOf1_0_xIsNeverRead() async throws {
        try writeOldTeam()
        let before = try FileManager.default.contentsOfDirectory(atPath: oldTeam.path).sorted()
        let resolution = TeamMode.resolve(chatDirectory: chat)
        XCTAssertEqual(resolution, TeamMode.Resolution(mode: .off, problem: nil))
        let service = TeamService(storage: team, runner: FakeTeamRunner())
        await service.load(mode: resolution.mode)
        XCTAssertNil(service.modeProblem)
        XCTAssertTrue(service.calls.agents.isEmpty, "the old published agents are not picked up")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: oldTeam.path).sorted(), before)
        XCTAssertNotEqual(TeamStorage.directoryName, "team")
    }

    func testSavedServerIsServer() throws {
        try writeServers(#"{"servers": [{"server": "https://chat.example.com"}]}"#)
        XCTAssertEqual(TeamMode.resolve(chatDirectory: chat), TeamMode.Resolution(mode: .server, problem: nil))
    }

    func testEmptyServerListIsOff() throws {
        try writeOldTeam()
        try writeServers(#"{"servers": []}"#)
        XCTAssertEqual(TeamMode.resolve(chatDirectory: chat), TeamMode.Resolution(mode: .off, problem: nil))
    }

    func testDamagedServersFileIsOffWithAProblem() async throws {
        for damaged in ["{not json", #"["https://x"]"#, #"{"servers": "x"}"#, #"{"servers": [1]}"#] {
            try writeServers(damaged)
            XCTAssertEqual(TeamMode.resolve(chatDirectory: chat), TeamMode.Resolution(mode: .off, problem: TeamMode.damagedConnectionText), damaged)
        }
        let service = TeamService(storage: team, runner: FakeTeamRunner())
        let resolution = TeamMode.resolve(chatDirectory: chat)
        await service.load(mode: resolution.mode, problem: resolution.problem)
        XCTAssertEqual(service.mode, .off)
        XCTAssertEqual(service.modeProblem, TeamMode.damagedConnectionText)
    }

    // MARK: Subscribers

    func testEveryNetworkAndWakeSubscriberIsTold() async throws {
        let watch = TeamNetworkWatch(monitorsNetwork: false, coalescingDelay: .milliseconds(10))
        var told: [String] = []
        watch.add { told.append("a") }
        watch.add { told.append("b") }
        watch.pathChanged(.init(status: .unsatisfied))
        watch.pathChanged(.init(status: .satisfied))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(told, ["a", "b"])

        var woke: [String] = []
        TeamWake.shared.add { woke.append("a") }
        TeamWake.shared.add { woke.append("b") }
        TeamWake.shared.woke()
        XCTAssertEqual(woke, ["a", "b"])
    }

    // MARK: Launch

    /// C14-3: AgentPad restarts with a server saved: once it started, new
    /// Claude Code sessions get the team tools again; a start that fails or
    /// no server leaves them off.
    func testRestartInServerModeOffersTheTeamTools() async throws {
        try writeServers(#"{"servers": [{"server": "https://chat.example.com"}]}"#)
        let service = TeamService(storage: team, runner: FakeTeamRunner())
        var tools: [Bool] = []
        service.onTeamToolsChange = { tools.append($0) }
        var started: [TeamMode] = []
        await TeamMode.startAtLaunch(TeamMode.resolve(chatDirectory: chat), service: service) { started.append($0) }
        XCTAssertEqual(started, [.server])
        XCTAssertEqual(service.mode, .server)
        XCTAssertEqual(tools, [true])

        struct Down: Error {}
        let failing = TeamService(storage: team, runner: FakeTeamRunner())
        var failingTools: [Bool] = []
        failing.onTeamToolsChange = { failingTools.append($0) }
        await TeamMode.startAtLaunch(TeamMode.resolve(chatDirectory: chat), service: failing) { _ in throw Down() }
        XCTAssertEqual(failing.mode, .off)
        XCTAssertEqual(failingTools, [false])

        let off = TeamService(storage: team, runner: FakeTeamRunner())
        var offTools: [Bool] = []
        off.onTeamToolsChange = { offTools.append($0) }
        await TeamMode.startAtLaunch(TeamMode.Resolution(mode: .off, problem: nil), service: off) { _ in XCTFail("started") }
        XCTAssertEqual(offTools, [false])
    }

    // MARK: Moving to the server

    func testSwitchingFromOffOffersTheTeamTools() async throws {
        let service = TeamService(storage: team, runner: FakeTeamRunner())
        await service.load(mode: .off)
        var tools: [Bool] = []
        service.onTeamToolsChange = { tools.append($0) }
        try await TeamMode.switchToServer(service: service) { _ in }
        XCTAssertEqual(service.mode, .server)
        XCTAssertEqual(tools, [true])
    }

    func testFailedServerStartLeavesTeamWorkOff() async throws {
        let service = TeamService(storage: team, runner: FakeTeamRunner())
        await service.load(mode: .off)
        var tools: [Bool] = []
        service.onTeamToolsChange = { tools.append($0) }
        struct Down: Error {}
        do {
            try await TeamMode.switchToServer(service: service) { _ in throw Down() }
            XCTFail("expected the start error")
        } catch is Down {}
        XCTAssertEqual(service.mode, .off)
        XCTAssertTrue(tools.isEmpty, "the team tools are not offered")
        XCTAssertEqual(TeamMode.resolve(chatDirectory: chat).mode, .off)
    }

    /// A run of this app not confirmed gone keeps the move back.
    func testMoveWaitsForARunNotConfirmedGone() async throws {
        let service = TeamService(storage: team, runner: FakeTeamRunner())
        await service.load(mode: .off)
        var started = false
        let leader = TeamProcessStart(pid: 999_940, pgid: 999_940, startTime: 1)
        TeamProcesses.shared.add(leader, agentId: "agent-m")
        TeamProcesses.shared.markLeftOver(leader)
        XCTAssertFalse(service.canMoveToServer)
        do {
            try await TeamMode.switchToServer(service: service) { _ in started = true }
            XCTFail("switched")
        } catch {
            XCTAssertEqual(error as? TeamError, .teamWorkOn)
        }
        XCTAssertFalse(started)
        XCTAssertEqual(service.mode, .off)
        XCTAssertNil(TeamProcesses.shared.confirmGone(leader))
        XCTAssertTrue(service.canMoveToServer)
        try await TeamMode.switchToServer(service: service) { _ in started = true }
        XCTAssertTrue(started)
        XCTAssertEqual(service.mode, .server)
    }

    // MARK: A session the server ended (DESIGN-D6 §7.1–7.2)

    /// 401/4401, then a new app without a network: the session is not taken
    /// for a live one — no team tools, the CLI refuses before writing.
    func testAnEndedSessionStaysEndedAfterARestart() async throws {
        let files = ChatFiles(directory: chat)
        let tokens = FakeTokenStore()
        let server = try ChatServerAddress(parsing: "https://chat.example.com")
        let first = ChatService(files: files, tokens: tokens)
        try first.saveSignIn(ChatConnection(server: server, accountId: "acc", sessionId: "s1", deviceName: "Mac", orgId: "org"),
                             token: "aps_t")
        XCTAssertTrue(first.hasSavedSession)
        first.sessionEnded("The server closed this session. Sign in again.")
        XCTAssertFalse(first.hasSavedSession, "the token the server refused goes")
        XCTAssertEqual(try files.loadConnections().count, 1, "the connection stays for signing in again")

        // The next app: started with no server to ask.
        let next = ChatService(files: files, tokens: tokens)
        XCTAssertFalse(next.hasSavedSession, "launch writes no team tools' config")
        try await next.start(mode: .server)
        guard case .needsSignIn = next.state else { return XCTFail("\(next.state)") }
        XCTAssertNotNil(next.sessionProblem)

        let service = TeamService(storage: team, runner: FakeTeamRunner())
        await service.load(mode: .off)
        try await TeamMode.switchToServer(service: service) { _ in }
        service.sessionProblem = { next.sessionProblem }
        var tools: [Bool] = []
        service.onTeamToolsChange = { tools.append($0) }
        service.updateTeamTools()
        XCTAssertEqual(tools, [false])
        for action in [AgentPadCLITeamAction.ask, .check, .cancel, .watch, .agents] {
            var request = AgentPadCLIRequest(verb: .team)
            request.teamAction = action.rawValue
            request.teamAgent = "helper@boris"
            request.teamPrompt = "hi"
            request.teamCall = "r1"
            let answer = await TeamCLIHandler.handle(request, service: service)
            XCTAssertEqual(answer.error, "not connected to a server: sign in again in AgentPad", action.rawValue)
        }
        XCTAssertTrue(service.calls.outgoing.isEmpty, "nothing written")
    }

    /// The keychain refused to delete the ended session's token: the
    /// record says so, and a restart neither offers the tools nor signs in
    /// with it — and deletes it then (review D6-2).
    func testAnEndedSessionWhoseTokenCouldNotBeDeletedStaysEnded() async throws {
        let files = ChatFiles(directory: chat)
        let tokens = FakeTokenStore()
        let server = try ChatServerAddress(parsing: "https://chat.example.com")
        let connection = ChatConnection(server: server, accountId: "acc", sessionId: "s1", deviceName: "Mac", orgId: "org")
        let first = ChatService(files: files, tokens: tokens)
        try first.saveSignIn(connection, token: "aps_t")
        tokens.deleteFailure = .storage("keychain says no")
        first.sessionEnded("The server closed this session. Sign in again.")
        tokens.deleteFailure = nil
        XCTAssertNotNil(tokens.stored(connection.tokenAccount), "the delete failed")
        XCTAssertEqual(try files.loadConnections().first?.revoked, true)
        let next = ChatService(files: files, tokens: tokens)
        XCTAssertFalse(next.hasSavedSession)
        try await next.start(mode: .server)
        guard case .needsSignIn = next.state else { return XCTFail("\(next.state)") }
        XCTAssertNil(tokens.stored(connection.tokenAccount), "deleted at the start")
        // Signing in again makes a record of its own.
        try next.saveSignIn(ChatConnection(server: server, accountId: "acc", sessionId: "s2", deviceName: "Mac", orgId: "org"), token: "aps_u")
        XCTAssertNil(try files.loadConnections().first?.revoked)
        XCTAssertTrue(next.hasSavedSession)
    }

    /// Team work off: what needs the server says so — not an empty catalog
    /// or "no such call" (review D6-3); and a session that ends while git is
    /// read refuses before anything is written (review D6-1).
    func testServerActionsAreRefusedWithoutAUsableSession() async throws {
        let off = TeamService(storage: team, runner: FakeTeamRunner())
        await off.load(mode: .off)
        for action in [AgentPadCLITeamAction.ask, .check, .cancel, .agents] {
            var request = AgentPadCLIRequest(verb: .team)
            request.teamAction = action.rawValue
            request.teamAgent = "helper@boris"
            request.teamPrompt = "hi"
            request.teamCall = "r1"
            let answer = await TeamCLIHandler.handle(request, service: off)
            XCTAssertEqual(answer.error, "not connected to a server", action.rawValue)
        }
        var mine = AgentPadCLIRequest(verb: .team)
        mine.teamAction = AgentPadCLITeamAction.agents.rawValue
        mine.teamMine = true
        let local = await TeamCLIHandler.handle(mine, service: off)
        XCTAssertNil(local.error, "the agents of this Mac are local")

        let service = TeamService(storage: team, runner: FakeTeamRunner())
        await service.load(mode: .off)
        try await TeamMode.switchToServer(service: service) { _ in }
        var looks = 0
        service.sessionProblem = {
            looks += 1
            return looks > 1 ? "the session ended (test)" : nil
        }
        var ask = AgentPadCLIRequest(verb: .team)
        ask.teamAction = AgentPadCLITeamAction.ask.rawValue
        ask.teamAgent = "helper@boris"
        ask.teamPrompt = "hi"
        let answer = await TeamCLIHandler.handle(ask, service: service)
        XCTAssertEqual(answer.error, "the session ended (test)")
        XCTAssertEqual(looks, 2, "looked at again after git was read")
        XCTAssertTrue(service.calls.outgoing.isEmpty)
    }

    /// Rows say the server's state (DESIGN-D6 §7.4): a call the agent
    /// finished is not "running", one being stopped says so.
    func testRowWordsFollowTheServerState() {
        XCTAssertEqual(TeamCallsSidebar.word(.running, serverState: "finished", activity: nil), "finished · waiting for its result")
        XCTAssertEqual(TeamCallsSidebar.word(.done, serverState: "finished", activity: nil), "done")
        XCTAssertEqual(TeamCallsSidebar.word(.running, serverState: "stop_requested", activity: "Read"), "stop requested")
        XCTAssertEqual(TeamCallsSidebar.word(.running, serverState: "starting", activity: nil), "starting")
        XCTAssertEqual(TeamCallsSidebar.word(.running, serverState: "running", activity: "Read"), "running · Read")
        XCTAssertEqual(TeamCallsSidebar.word(.awaitingApproval, serverState: "awaiting_decision", activity: nil), "waiting for approval")
        XCTAssertEqual(TeamCallsSidebar.word(.failed, serverState: "failed_to_start", activity: nil), "failed to start")
        XCTAssertEqual(TeamCallsSidebar.word(.running, activity: nil), "running", "no server state: 1.0.x words")
    }

    /// The tools follow the session: on only in server mode with one that can be used.
    func testTeamToolsNeedServerModeAndASession() {
        XCTAssertTrue(TeamTools.on(mode: .server, sessionProblem: nil))
        XCTAssertFalse(TeamTools.on(mode: .server, sessionProblem: "not connected to a server"))
        XCTAssertFalse(TeamTools.on(mode: .off, sessionProblem: nil))
    }

    /// Disconnect: the sign-in and the server record go; nothing else is
    /// written on the way.
    func testDisconnectRemovesTheServerRecord() async throws {
        let files = ChatFiles(directory: chat)
        let chatService = ChatService(files: files, tokens: FakeTokenStore())
        let server = try ChatServerAddress(parsing: "https://chat.example.com")
        try chatService.saveSignIn(ChatConnection(server: server, accountId: "acc", sessionId: "s1", deviceName: "Mac", orgId: "org"),
                                   token: "aps_t")
        chatService.closeRemoteSession = { _, _ in }
        await chatService.disconnect()
        XCTAssertEqual(try files.loadConnections().count, 0)
        XCTAssertEqual(TeamMode.resolve(chatDirectory: chat).mode, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldTeam.path))
    }
}
