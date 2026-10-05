import Darwin
import Foundation
import AgentPadHookKit

// agentpad-cli: the local control channel for a running AgentPad. External tools
// (Wake, Raycast, plain scripts) drive AgentPad through it: open a tab and run
// a command, resume an agent conversation, list / focus / close tabs. Talks
// the request/response branch of the hook socket (`kind: "cli"`); parsing,
// rendering, and transport live in AgentPadHookKit so they're unit-testable —
// this file is a thin dispatcher, like AgentPadHook's main.swift.
//
// Exit codes:
//   0 — request accepted by the app (for `close` that means "close
//       requested"; in-app confirmation rules still apply).
//   1 — any failure: app couldn't be launched, bad arguments, unknown tab,
//       refused request, timeout. One human-readable line on stderr.
//   2 — AgentPad `team logout` / `team invite`: started or sent, the outcome
//       not known (also `team ask` / `check`: still in progress).
//
// Every verb except `status` launches AgentPad first when it isn't running,
// then waits (up to 10s) for the socket to come up.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agentpad-cli: \(AgentPadHookKit.plain(message))\n".utf8))
    exit(1)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("agentpad-cli: warning: \(AgentPadHookKit.plain(message))\n".utf8))
}

/// Launch the app this CLI shipped with. Walking up from the (symlink-
/// resolved) executable finds the .app for in-bundle installs; the
/// Application Support mirror copy falls back to LaunchServices by name.
///
/// `background` (open --no-focus on a cold start) adds `-g` so Launch
/// Services doesn't activate AgentPad. Necessary but possibly not sufficient:
/// the app's own launch sequence calls NSApp.activate itself, which
/// macOS 14's cooperative activation MAY refuse without an activation
/// token — verified on hardware, not guaranteed by contract.
func launchAgentPad(background: Bool) -> Bool {
    let exePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let bundle = URL(fileURLWithPath: exePath).resolvingSymlinksInPath()
        .deletingLastPathComponent()  // MacOS
        .deletingLastPathComponent()  // Contents
        .deletingLastPathComponent()  // AgentPad.app
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    var arguments = bundle.pathExtension == "app" ? [bundle.path] : ["-a", AppIdentity.appName]
    if background { arguments.insert("-g", at: 0) }
    process.arguments = arguments
    // `open` writes its own diagnostics (app missing, LaunchServices errors)
    // to the stderr it inherits from us. We report the failure ourselves in
    // one line, which is the contract this CLI states — so its output would
    // be a second, uncontrolled line on top of ours.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func printSuccess(_ response: AgentPadCLIResponse, for command: AgentPadCLICommand) {
    switch command {
    case .list(let json):
        let windows = response.windows ?? []
        print(json ? AgentPadHookKit.renderCLIListJSON(windows) : AgentPadHookKit.renderCLIList(windows))
    case .status(let json):
        if json {
            print(AgentPadHookKit.renderCLIStatusJSON(
                running: true,
                appVersion: response.appVersion,
                serverProtocol: response.protocolVersion
            ))
        } else {
            let version = response.appVersion ?? "unknown version"
            let proto = response.protocolVersion.map(String.init) ?? "?"
            print("\(AppIdentity.appName) \(AgentPadHookKit.plain(version)) is running (protocol \(proto))")
        }
    case .open:
        // One line either way; the id stays the third word for scripts.
        let head = response.tabId.map { "opened tab \(AgentPadHookKit.plain($0))" } ?? "opened"
        print(response.note.map { "\(head) — \(AgentPadHookKit.plain($0))" } ?? head)
    case .resume, .focus, .close, .rename:
        print(AgentPadHookKit.plain(response.note ?? "ok"))
    case .team(let command):
        guard let team = response.team else { print(AgentPadHookKit.plain(response.note ?? "ok")); break }
        print(command.json ? AgentPadHookKit.renderCLITeamJSON(team) : AgentPadHookKit.renderCLITeam(team, action: command.action.rawValue))
    case .help:
        break
    }
}

// MARK: - Main flow

let arguments = Array(CommandLine.arguments.dropFirst())

// AgentPad: `agentpad-cli mcp` — the team tools as an MCP server on stdio,
// started by Claude Code sessions in AgentPad (TeamMCPServer.swift).
// AgentPad: `agentpad-cli run-tools <call-id>` — the same server for a
// colleague's call running here: it may ask the owner for another folder.
let runToolsCallId: String? = arguments.count == 2 && arguments[0] == "run-tools" && UUID(uuidString: arguments[1]) != nil
    ? arguments[1].lowercased() : nil
if arguments == ["mcp"] || runToolsCallId != nil {
    let socket = AgentPadHookKit.socketPath
    let out = FileHandle.standardOutput
    let server = AgentPadTeamMCPServer(
        cwd: FileManager.default.currentDirectoryPath,
        version: AgentPadCLIProtocol.version.description,
        runCallId: runToolsCallId,
        send: { request, timeout in
            guard let line = request.encodedLine() else { return .failure(.init("internal error: request encoding failed")) }
            switch AgentPadCLITransport.roundTrip(line: line, socketPath: socket, timeout: timeout) {
            case .success(let data):
                guard let response = AgentPadCLIResponse.decode(from: data) else { return .failure(.init("AgentPad sent a reply this tool cannot read; update AgentPad.")) }
                return .success(response)
            case .failure(.connectFailed):
                return .failure(.init("AgentPad is not running, so team work is not available."))
            case .failure:
                return .failure(.init("AgentPad did not answer in time."))
            }
        },
        write: { data in out.write(data) }
    )
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty else { continue }
        server.handle(line: Data(line.utf8))
    }
    // stdin closed: the session is gone. Let replies already made go out.
    server.drain()
    exit(0)
}

// AgentPad: `team … --json` answers with one JSON object whatever happens,
// and exits 2 when a change was asked for but its outcome is not known (C7).
let teamJSON = arguments.first == "team" && arguments.contains("--json")

func teamFail(_ outcome: String, _ message: String, exitCode: Int32 = 1) -> Never {
    if teamJSON {
        print(AgentPadHookKit.renderCLITeamResultJSON(ok: false, outcome: outcome, message: message))
        exit(exitCode)
    }
    FileHandle.standardError.write(Data("agentpad-cli: \(AgentPadHookKit.plain(message))\n".utf8))
    exit(exitCode)
}

let parsed: AgentPadCLICommand
switch AgentPadHookKit.parseCLICommand(arguments) {
case .success(let value): parsed = value
case .failure(let error): teamJSON ? teamFail("usage", error.message) : fail(error.message)
}

if parsed == .help {
    print(AgentPadHookKit.renderCLIHelp())
    exit(0)
}

// Absolutize caller-relative paths against THIS process's cwd — the app
// can't know it. The server still enforces absolute + existing.
let processCwd = FileManager.default.currentDirectoryPath
let command: AgentPadCLICommand
switch parsed {
case .open(let cwd, let cmd, let agent, let title, let noFocus):
    command = .open(
        cwd: cwd.map { AgentPadHookKit.normalizeCLIPath($0, relativeTo: processCwd) },
        command: cmd,
        agent: agent,
        title: title,
        noFocus: noFocus
    )
case .resume(let agent, let id, let cwd):
    command = .resume(
        agent: agent,
        id: id,
        cwd: cwd.map { AgentPadHookKit.normalizeCLIPath($0, relativeTo: processCwd) }
    )
case .team(var team):
    // AgentPad: a request read from stdin, a folder relative to here.
    if team.prompt == "-" {
        team.prompt = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    team.folder = team.folder.map { AgentPadHookKit.normalizeCLIPath($0, relativeTo: processCwd) }
    command = .team(team)
default:
    command = parsed
}

// AgentPad: `team watch` reads the run's log on disk, only once the app
// said this call may be watched (a server's request may not yet): no
// answer, or an unreadable one, is no (review D8e-p1-3).
if case .team(let team) = command, team.action == .watch {
    guard let id = team.call, let path = AgentPadTeamWatch.logPath(callId: id) else { fail("a call id is a UUID") }
    guard let check = AgentPadHookKit.cliRequest(for: command)?.encodedLine(),
          case .success(let data) = AgentPadCLITransport.roundTrip(line: check, socketPath: AgentPadHookKit.socketPath, timeout: 5),
          let answer = AgentPadCLIResponse.decode(from: data)
    else { fail("\(AppIdentity.appName) did not answer whether this call may be watched; start it and try again") }
    guard answer.ok else { fail(answer.error ?? "this call cannot be watched") }
    setvbuf(stdout, nil, _IONBF, 0)
    let session = AgentPadTeamWatch.follow(path: path) { print($0) }
    if let session, let id = UUID(uuidString: session), session.lowercased() == id.uuidString.lowercased() {
        print("\nTo continue this conversation yourself: agentpad-cli resume --agent claude-code --id \(id.uuidString.lowercased())")
    }
    exit(0)
}

guard var request = AgentPadHookKit.cliRequest(for: command) else {
    fail("internal error: request encoding failed")
}
// AgentPad: team calls name the project the caller works in.
if case .team = command { request.teamCwd = processCwd }
guard let line = request.encodedLine() else {
    fail("internal error: request encoding failed")
}
// Same limit the server's read loop enforces — fail here with the real
// reason instead of a server-side truncation.
guard line.count <= AgentPadCLIProtocol.maxRequestLineBytes else {
    fail("request is too large (over \(AgentPadCLIProtocol.maxRequestLineBytes) bytes) — shorten the -e command or the team request")
}

let socketPath = AgentPadHookKit.socketPath
// Reply deadline exceeds the app's own 10s resume-resolution deadline so a
// slow-but-answered resume never reads as a dead server.
// AgentPad: joining a team waits for the colleague's approval (up to 120 s).
let replyTimeout: TimeInterval = {
    if case .team(let team) = command { return team.replyTimeout }
    return 15
}()
let launchTimeout: TimeInterval = 10

func attempt() -> Result<Data, AgentPadCLITransport.Failure> {
    AgentPadCLITransport.roundTrip(line: line, socketPath: socketPath, timeout: replyTimeout)
}

var result = attempt()

if case .failure(.connectFailed) = result {
    if case .status(let json) = command {
        // `status` reports instead of launching.
        if json {
            print(AgentPadHookKit.renderCLIStatusJSON(running: false, appVersion: nil, serverProtocol: nil))
        } else {
            print("\(AppIdentity.appName) is not running")
        }
        exit(1)
    }
    let backgroundLaunch: Bool = {
        if case .open(_, _, _, _, let noFocus) = command { return noFocus }
        return false
    }()
    guard launchAgentPad(background: backgroundLaunch) else {
        teamJSON ? teamFail("unavailable", "\(AppIdentity.appName) is not running and couldn't be launched")
            : fail("\(AppIdentity.appName) is not running and couldn't be launched")
    }
    let deadline = DispatchTime.now() + launchTimeout
    while true {
        result = attempt()
        if case .failure(.connectFailed) = result, DispatchTime.now() < deadline {
            usleep(250_000)
            continue
        }
        break
    }
}

// AgentPad: a change asked of the server (C7) with no reliable answer once
// the request went: its outcome is unknown — exit 2, never "not done".
if case .team(let team) = command, AgentPadHookKit.teamActionIsServer(team.action) {
    let changes = AgentPadHookKit.teamActionChanges(team.action)
    func unknown() -> Never {
        changes ? teamFail("unknown", "the request went to \(AppIdentity.appName) but no answer came; its outcome is not known — see `agentpad-cli team status`", exitCode: 2)
            : teamFail("unavailable", "\(AppIdentity.appName) did not answer")
    }
    switch result {
    case .failure(.connectFailed):
        teamFail("unavailable", "\(AppIdentity.appName) did not start listening within \(Int(launchTimeout))s")
    case .failure(.writeFailed):
        teamFail("unavailable", "couldn't send the request to \(AppIdentity.appName)")
    case .failure:
        unknown()
    case .success(let data):
        guard let response = AgentPadCLIResponse.decode(from: data) else { unknown() }
        let outcome = response.team?.outcome
        if team.json {
            print(AgentPadHookKit.renderCLITeamResultJSON(ok: response.ok, outcome: outcome, message: response.error, info: response.team))
        } else if response.ok {
            printSuccess(response, for: command)
        } else {
            FileHandle.standardError.write(Data("agentpad-cli: \(AgentPadHookKit.plain(response.error ?? "request refused"))\n".utf8))
        }
        exit(!response.ok ? 1 : outcome == "started" ? 2 : 0)
    }
}

switch result {
case .failure(.connectFailed):
    fail("\(AppIdentity.appName) did not start listening within \(Int(launchTimeout))s")
case .failure(.timedOut), .failure(.closedWithoutReply):
    fail("\(AppIdentity.appName) is running but didn't answer — it may be older than this agentpad-cli (no CLI support). Update \(AppIdentity.appName), or use the agentpad-cli bundled with the running version.")
case .failure(.writeFailed):
    fail("couldn't send the request to \(AppIdentity.appName)")
case .failure(.replyTooLarge):
    fail("\(AppIdentity.appName) sent an oversized reply")
case .success(let data):
    guard let response = AgentPadCLIResponse.decode(from: data) else {
        fail("couldn't decode \(AppIdentity.appName)'s reply")
    }
    // Failures print exactly ONE line (the CLI's stated contract), so the
    // mismatch note waits until we know this is a success. A refusal caused
    // BY the mismatch already says so in its own message.
    guard response.ok else {
        fail(response.error ?? "request refused")
    }
    if let serverProtocol = response.protocolVersion, serverProtocol != AgentPadCLIProtocol.version {
        warn("protocol mismatch (cli \(AgentPadCLIProtocol.version), app \(serverProtocol)) — update \(AppIdentity.appName) or use its bundled agentpad-cli")
    }
    if case .team(let team) = command, team.action == .ask || team.action == .check, let call = response.team?.call {
        followTeamCall(call, team: team, first: response)
    }
    printSuccess(response, for: command)
    exit(0)
}

/// AgentPad: `team ask` / `team check` wait for the answer as a series of
/// short requests, so the socket keeps its one-request-one-reply rule (7.5).
/// Exit 0 with the answer, 1 when the call ended without one, 2 when it is
/// still in progress after the wait.
func followTeamCall(_ first: AgentPadCLITeamInfo.Call, team: AgentPadCLITeamCommand, first response: AgentPadCLIResponse) -> Never {
    var call = first
    var info = response.team!
    let defaultWait = team.action == .ask ? AgentPadHookKit.teamDefaultWaitMinutes : 0
    let deadline = Date().addingTimeInterval(TimeInterval((team.waitMinutes ?? defaultWait) * 60))
    var lastProgress = ""
    while !call.final {
        let progress = AgentPadHookKit.renderCLITeamProgress(call)
        if progress != lastProgress, !team.json {
            FileHandle.standardError.write(Data("\(progress)\n".utf8))
            lastProgress = progress
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 1 else { break }
        var check = AgentPadCLIRequest(verb: .team)
        check.teamAction = AgentPadCLITeamAction.check.rawValue
        check.teamCall = call.id
        check.teamScope = call.scope
        check.teamWaitSeconds = min(AgentPadHookKit.teamCheckRoundSeconds, Int(remaining))
        guard let line = check.encodedLine() else { fail("internal error: request encoding failed") }
        let timeout = TimeInterval(AgentPadHookKit.teamCheckRoundSeconds + 20)
        switch AgentPadCLITransport.roundTrip(line: line, socketPath: socketPath, timeout: timeout) {
        case .success(let data):
            guard let next = AgentPadCLIResponse.decode(from: data) else { fail("couldn't decode \(AppIdentity.appName)'s reply") }
            guard next.ok, let nextInfo = next.team, let nextCall = nextInfo.call else { fail(next.error ?? "request refused") }
            info = nextInfo
            call = nextCall
        case .failure:
            fail("lost \(AppIdentity.appName) while waiting; the call goes on — check it with: agentpad-cli team check \(call.id)")
        }
    }
    if team.json {
        print(AgentPadHookKit.renderCLITeamJSON(info))
    } else if call.final && call.state != "done" {
        fail(AgentPadHookKit.renderCLITeamCall(call))
    } else {
        print(AgentPadHookKit.renderCLITeamCall(call))
    }
    exit(AgentPadHookKit.teamCallExitCode(call))
}
