import AppKit
import SwiftUI

/// Team menu actions and the Team window: the server connection, what
/// stopped on it, and runs that need the owner (C0, C1, D11).
@MainActor
enum TeamUI {
    static var service: TeamService { .shared }

    /// Saved state may still be loading when a window opens.
    private static var loading: Task<Void, Never>?

    /// Wires notifications and loads saved state. Called once at launch.
    static func install() {
        // Server or off — decided before anything starts (C0).
        let mode = TeamMode.resolve()
        // Colleagues' calls wait in the right panel; when AgentPad is in the
        // background a notification says who calls which agent (R-1).
        service.calls.onPendingChange = { AttentionCoordinator.shared.refreshBadge() }
        ClaudeVersionApprovals.shared.onChange = {
            AttentionCoordinator.shared.refreshBadge()
            if !ClaudeVersionApprovals.shared.pending.isEmpty { NSApp.requestUserAttention(.criticalRequest) }
        }
        service.calls.onAccessRequest = { request, call in
            guard !request.isChannel else { return }
            NSApp.requestUserAttention(.criticalRequest)
            guard !NSApp.isActive, AgentPadSettingsModel.shared.notificationsEnabled else { return }
            AttentionCoordinator.shared.notificationManager?.postTeam(
                title: "\(call.agentName) asks for a folder",
                body: "\(request.path) — for \(call.peerName)'s call"
            )
        }
        service.calls.onIncomingCall = { call in
            NSApp.requestUserAttention(.criticalRequest)
            guard !NSApp.isActive, AgentPadSettingsModel.shared.notificationsEnabled else { return }
            let preview = call.prompt.replacingOccurrences(of: "\n", with: " ")
            AttentionCoordinator.shared.notificationManager?.postTeam(
                title: "\(call.peerName) calls \(call.agentName)",
                body: String(preview.prefix(160)) + (preview.count > 160 ? "…" : "")
            )
        }
        // An answer, or a call that ended without one, when AgentPad is in
        // the background (D-4).
        service.calls.onOutgoingFinished = { call in
            guard !NSApp.isActive, AgentPadSettingsModel.shared.notificationsEnabled else { return }
            let title = ChatOutgoing.outcomeTitle(call)
            let body = (call.report.state == .done ? call.report.text : call.report.detail) ?? ""
            AttentionCoordinator.shared.notificationManager?.postTeam(
                title: title, body: String(body.replacingOccurrences(of: "\n", with: " ").prefix(160))
            )
        }
        // Waking up or a new network: the server's feed reconnects at once (C3).
        TeamWake.shared.add { ChatService.shared.socket?.reconnectNow(force: true) }
        TeamNetworkWatch.shared.add { ChatService.shared.socket?.reconnectNow(force: true) }
        ChatService.shared.onNotice = { text in
            guard AgentPadSettingsModel.shared.notificationsEnabled else { return }
            AttentionCoordinator.shared.notificationManager?.postTeam(title: "AgentPad server", body: text)
        }
        service.onTeamToolsChange = { on in
            if on { AgentPadShellIntegration.writeTeamMCPConfig() } else { AgentPadShellIntegration.removeTeamMCPConfig() }
        }
        // The config was set before the windows came back (`prepareTeamTools`);
        // from here the session and the mode keep it (DESIGN-D6).
        service.sessionProblem = { ChatService.shared.sessionProblem }
        ChatService.shared.onStateChange = { service.updateTeamTools() }
        // In server mode the calls are the organization's requests (D8).
        ChatService.shared.onCallStore = { key, calls in service.calls.useServer(calls, key: key) }
        // Publishing to the organization (D3).
        service.calls.publishing = ChatService.shared
        // The caller's side through the server (D5).
        ChatOutgoing.install(calls: service.calls)
        // The owner's side (D4): its handlers, the buttons' decision, asks on.
        _ = ChatOwnerSide.install(service: .shared, calls: service.calls)
        // A request waits for this owner's decision: the notice of 1.0.x, once.
        // A server's request waiting for this owner: the list is read again;
        // its notice is F4's, without content (`ChatNotifications`).
        ChatService.shared.onDecisionWanted = { _ in
            service.calls.reload()
            NSApp.requestUserAttention(.criticalRequest)
        }
        ChatService.shared.onCallsChanged = { key in
            if service.calls.serverKey == key { service.calls.reload() }
        }
        // Leaving the server turns team work off (C0, C1).
        ChatService.shared.onDisconnected = {
            service.leaveServerMode()
            service.updateTeamTools()
        }
        loading = Task {
            // Runs an earlier app left are found, registered and stopped
            // first, in any mode (D11).
            await ChatService.shared.recoverRunsAtLaunch()
            await TeamMode.startAtLaunch(mode, service: service) { try await ChatService.shared.start(mode: $0) }
        }
    }

    // MARK: Menu actions

    /// A damaged run journal blocks server runs until the user resets it (C4).
    static func resetRunJournal() {
        Task {
            let alert = NSAlert()
            alert.messageText = "Reset the run journal?"
            alert.informativeText = """
            The damaged journal is kept beside as journal.sqlite.corrupt. Results not yet delivered \
            and runs it recorded are forgotten; server runs on this Mac work again.
            """
            alert.addButton(withTitle: "Reset")
            alert.addButton(withTitle: "Cancel")
            guard await present(alert) == .alertFirstButtonReturn else { return }
            do { try ChatService.shared.resetJournal() } catch { await showError("The run journal could not be reset", error) }
        }
    }

    /// At launch, before windows come back: the team tools of the Claude
    /// Code sessions they restore follow what is known without a network — a
    /// saved connection with its token (a session ended by the server has
    /// none). A file left by a crash does not outlive it (DESIGN-D6 §7.2).
    static func prepareTeamTools() {
        if ChatService.shared.hasSavedSession {
            AgentPadShellIntegration.writeTeamMCPConfig()
        } else {
            AgentPadShellIntegration.removeTeamMCPConfig()
        }
    }

    static func showTeam() {
        TeamWindows.showTeam()
    }

    static func chooseClaudeExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Выберите конечный нативный бинарник Claude Code"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ClaudeVersionApprovals.shared.selectExecutable(url.path)
    }

    static func stopPublishing(_ agents: [TeamPublishedAgent]) async {
        let alert = NSAlert()
        alert.messageText = agents.count == 1 ? "Stop publishing \(agents[0].name)?" : "Stop publishing this session?"
        alert.informativeText = "Colleagues can no longer call it. Calls already allowed finish."
        alert.addButton(withTitle: "Stop Publishing")
        alert.addButton(withTitle: "Cancel")
        guard await present(alert) == .alertFirstButtonReturn else { return }
        do {
            for agent in agents { try service.calls.unpublish(agent.id) }
        } catch {
            await showError("Not all was unpublished", error)
        }
    }

    static func decideAccess(_ id: String, _ state: TeamCalls.AccessRequest.State) async {
        if let problem = await service.calls.decideAccess(id, state) {
            await showError("The folder was not given", TeamError.storage(problem))
        }
    }

    // MARK: Watching a call

    /// Opens a tab: (working directory, shell command, title).
    static var openTab: @MainActor (String, String, String) -> Void = { _, _, _ in }

    /// A call that ran or will run has a log to watch.
    static func canWatch(_ call: TeamCalls.Incoming, in calls: TeamCalls? = nil) -> Bool {
        if (calls ?? service.calls).refuses(call) { return false }
        return switch call.state {
        case .queued, .running: true
        case .done, .failed, .cancelled: FileManager.default.fileExists(atPath: TeamStorage.standard.runLogURL(callId: call.id).path)
        default: false
        }
    }

    /// A tab with `agentpad-cli team watch`: what the agent does, live.
    /// The refusal's text when the call may not be watched here.
    @discardableResult
    static func watch(_ call: TeamCalls.Incoming, in calls: TeamCalls? = nil) -> String? {
        if let refusal = (calls ?? service.calls).refusal(.watch, for: call) { return refusal }
        let folder = service.calls.agents.first { $0.id == call.agentId }?.folder ?? NSHomeDirectory()
        let cli = shellQuoted(AgentPadShellIntegration.agentPadCLIBinaryPath)
        openTab(folder, "\(cli) team watch \(call.id)", "Team · \(call.peerName) → \(call.agentName)")
        return nil
    }

    /// The owner carries on with the call's conversation in a normal tab.
    /// The refusal's text when the conversation may not be carried on here.
    @discardableResult
    static func continueYourself(_ call: TeamCalls.Incoming, in calls: TeamCalls? = nil) -> String? {
        let calls = calls ?? service.calls
        if let refusal = calls.refusal(.carryOn, for: call) { return refusal }
        // The thread's conversation as this Mac ran it: a server's call's is
        // its latest run's, never the thread's id (F6).
        let conversation = calls.refuses(call) ? calls.serverConversation?(call) : call.threadId
        guard let conversation,
              let folder = calls.agents.first(where: { $0.id == call.agentId })?.folder
        else { return "This call's conversation is not on this Mac." }
        let fullId: String
        switch ClaudeSessionResume.resolve(conversation, root: calls.sessionFilesRoot, visibility: calls.conversationVisibility()) {
        case .success(let id): fullId = id
        case .failure(let refusal): return refusal.message
        }
        // A copy: the conversation the caller goes on with stays as it was (AG-7/8).
        openTab(folder, "claude --resume \(fullId) --fork-session", "Team · \(call.peerName) → \(call.agentName) · yours")
        return nil
    }

    static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func showAgents() {
        Task {
            await loading?.value
            TeamWindows.showAgents()
        }
    }

    // MARK: Helpers

    /// Shows an alert as a sheet on the front window and waits without a
    /// nested modal loop — `runModal` inside an async task would hold every
    /// other main-actor continuation (incoming requests, CLI answers) until
    /// the alert closes. With no window to attach to, falls back to modal.
    @discardableResult
    static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        var window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        if window == nil {
            // No window to attach to: the Team window serves as one.
            TeamWindows.showTeam()
            window = TeamWindows.teamWindow
        }
        guard let host = window else { return .cancel }
        // One sheet at a time: wait for the current one instead of a modal loop.
        while host.attachedSheet != nil { try? await Task.sleep(for: .milliseconds(200)) }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: host) { continuation.resume(returning: $0) }
        }
    }

    static func showError(_ title: String, _ error: Error?) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        if let error { alert.informativeText = (error as? LocalizedError)?.errorDescription ?? String(describing: error) }
        await present(alert)
    }
}

// MARK: - Windows

@MainActor
enum TeamWindows {
    private static var team: NSWindow?
    static var teamWindow: NSWindow? { team }
    private static var agents: NSWindow?
    private static var publishSession: NSWindow?
    private static var publicationEditor: NSWindow?
    /// The Team tab of the front window's left sidebar.
    static var showCallsTab: @MainActor () -> Void = {}

    static func showCalls() { showCallsTab() }

    static func showAgentEditor(_ editing: TeamAgentEditing) {
        publicationEditor?.close()
        final class Handle { weak var window: NSWindow? }
        let handle = Handle()
        let made = window(title: "Edit publication", content: TeamPublicationEditor(open: editing, service: .shared) { handle.window?.close() })
        handle.window = made
        publicationEditor = made
        present(made)
    }

    static func showPublishSession(sessionId: String, title: String, surfaceId: UUID? = nil) {
        publishSession?.close()
        // Closing is bound to this window: a save that ends after it was
        // replaced must not close the next one.
        final class Handle { weak var window: NSWindow? }
        let handle = Handle()
        let made = window(title: "Publish to Team", content: TeamPublishSessionView(
            sessionId: sessionId, title: title, service: .shared, surfaceId: surfaceId
        ) { handle.window?.close() })
        handle.window = made
        publishSession = made
        present(made)
    }

    static func showAgents() {
        if agents == nil {
            agents = window(title: "Published Agents", content: TeamAgentsView(service: .shared))
        }
        present(agents)
    }

    static func showTeam() {
        if team == nil {
            team = window(title: "Team", content: TeamStatusView(service: .shared))
        }
        present(team)
    }

    private static func window(title: String, content: some View) -> NSWindow {
        let host = NSHostingController(rootView: content)
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.appearance = Theme.windowAppearance
        window.center()
        return window
    }

    private static func present(_ window: NSWindow?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The Team window: the server connection, what stopped on it, and runs
/// that need the owner.
struct TeamStatusView: View {
    let service: TeamService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack {
                Button("Claude Code…") { TeamUI.chooseClaudeExecutable() }
                if ClaudeVersionApprovals.shared.selectedPath != nil {
                    Button("Автовыбор") { ClaudeVersionApprovals.shared.selectExecutable(nil) }
                }
            }
            if let path = ClaudeVersionApprovals.shared.selectedPath {
                Text(path).font(Theme.mono(10.5)).textSelection(.enabled)
            }
            // Folder requests of running calls are answered here too.
            TeamPanelSection(service: service)
            // Results of runs here no server has taken: from the journal, also
            // after Disconnect and with no connection (D4, review D4b-4).
            let undelivered = ChatService.shared.undeliveredResults()
            if !undelivered.isEmpty {
                Text("Results not delivered").font(Theme.display(12, weight: .semibold))
                ForEach(undelivered) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(service.calls.agents.first { $0.id.uuidString.lowercased() == result.agentId }?.name ?? "An agent") · not delivered")
                            .font(Theme.display(11, weight: .medium))
                        Text(result.text).font(Theme.mono(10.5)).lineLimit(6).textSelection(.enabled)
                    }
                }
            }
            if service.mode == .server {
                if let problem = ChatService.shared.publishProblem {
                    Text(problem).font(Theme.display(11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                colleagues
            }
            Divider()
            HStack {
                Button("Published Agents…") { TeamUI.showAgents() }
                Spacer()
                if service.mode == .server {
                    Button("Disconnect…") { ChatConnectWindow.disconnect() }
                } else {
                    Button("Connect to a Server…") { ChatConnectWindow.show() }
                }
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    /// Colleagues' agents the member may call (D3, answer (а)).
    @ViewBuilder
    private var colleagues: some View {
        let agents = service.calls.colleaguesAgents
        Text("Colleagues' agents").font(Theme.display(12, weight: .semibold))
        if agents.isEmpty {
            Text("None published to your teams yet.").font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
        } else {
            ForEach(agents, id: \.address) { agent in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(agent.address) · \(agent.entry.access.title)\(agent.online ? "" : " · unavailable")")
                        .font(Theme.display(12, weight: .medium))
                    Text(agent.entry.description).font(Theme.display(11)).foregroundStyle(Theme.chromeMuted).lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Team work").font(Theme.display(14, weight: .semibold))
            if service.mode == .server, let connection = ChatService.shared.connection {
                Text("Through \(connection.server.description)").font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
            } else {
                Text("Off — connect to a server to work with colleagues.").font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
            }
            if let problem = service.modeProblem {
                Text(problem).font(Theme.display(11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = ChatService.shared.journalProblem {
                Text("Server runs on this Mac are off: \(problem)")
                    .font(Theme.display(11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Reset Run Journal…") { TeamUI.resetRunJournal() }
            }
            // What stopped on the server connection, with the way back (review C3-6).
            let problems = ChatService.shared.problems
            if !problems.isEmpty {
                ForEach(problems, id: \.self) { line in
                    Text(line).font(Theme.display(11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Try Again") { ChatService.shared.retryStopped() }
                    if ChatService.shared.hasRefused { Button("Dismiss") { ChatService.shared.dismissRefused() } }
                    if case .needsSignIn = ChatService.shared.state { Button("Connect to a Server…") { ChatConnectWindow.show() } }
                }
            }
            if let problem = ChatService.shared.recovery?.problem {
                // Nothing starts until the earlier runs can be checked (review C6-7).
                HStack {
                    Text("The earlier agent runs could not be checked: \(problem)")
                        .font(Theme.display(11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Button("Check Again") { Task { await ChatService.shared.recovery?.check() } }
                }
            }
            ForEach(ChatService.shared.recovery?.blocked ?? []) { item in
                // An earlier run whose processes are not confirmed gone blocks
                // its agent; the owner deals with them (D11, review C7).
                TeamBlockedRunRow(item: item)
            }
            // Runs of this app whose processes were not confirmed gone.
            TeamLeftOversSection()
        }
    }
}

/// A run whose processes are not confirmed gone: what AgentPad finds of it,
/// and the owner's two ways on (review C7).
private struct TeamBlockedRunRow: View {
    let item: TeamRunRecovery.Blocked
    @State private var answer: String?
    @State private var busy = false

    var body: some View {
        let name = ChatService.shared.localAgent(item.agentId)?.name ?? "agent"
        VStack(alignment: .leading, spacing: 4) {
            if item.run.preflightPID != nil {
                Text("Служебный процесс Claude Code --version: завершение не подтверждено.")
                    .font(Theme.display(11)).foregroundStyle(.orange)
            }
            Text("Agent \(name) is blocked: an earlier run may still have processes.")
                .font(Theme.display(11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            Group {
                switch item.found {
                case nil where item.leader == nil:
                    Text("AgentPad has no record of its process. Make sure no claude of this agent is running, then press They Are Gone.")
                case nil:
                    Text("AgentPad could not look for them.")
                case let found? where found.isEmpty:
                    Text("AgentPad finds none of them now.")
                case let found?:
                    Text("Running: PID " + found.map { String($0.pid) }.joined(separator: ", ") + ".")
                }
            }
            .font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
            if let answer { Text(answer).font(Theme.display(11)).foregroundStyle(.orange) }
            HStack {
                Button("Stop These Processes") { act { await ChatService.shared.recovery?.stopProcesses(item.id) } }
                    .disabled(busy || (item.found ?? []).isEmpty)
                Button("They Are Gone") { act { await ChatService.shared.recovery?.confirmGone(item.id) } }
                    .disabled(busy)
                Button("Check Again") { act { _ = await ChatService.shared.recovery?.check(); return nil } }
                    .disabled(busy)
            }
        }
    }

    private func act(_ work: @escaping @MainActor () async -> String?) {
        busy = true
        Task {
            answer = await work()
            busy = false
        }
    }
}


/// A run of this app that ended without its processes confirmed gone (any
/// mode): what is known of it, and the owner's two ways on (review C10-5).
struct TeamLeftOverRow: View {
    let left: TeamProcesses.LeftOver
    var onChange: @MainActor () -> Void = {}
    @State private var answer: String?
    @State private var busy = false

    var body: some View {
        let name = TeamService.shared.calls.agents.first { $0.id.uuidString.lowercased() == left.agentId }?.name ?? "agent"
        let pids: [pid_t] = [left.leader.pid] + left.processes.map(\.pid)
        let list: String = pids.map { String($0) }.joined(separator: ", ")
        let warning: String = left.incomplete ? " AgentPad could not see all of them; check yourself before saying they are gone." : ""
        VStack(alignment: .leading, spacing: 4) {
            Text("Agent \(name): an earlier run may still have processes (PID \(list)).\(warning)")
                .font(Theme.display(11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            if let answer { Text(answer).font(Theme.display(11)).foregroundStyle(.orange) }
            HStack {
                Button("Stop These Processes") {
                    busy = true
                    Task {
                        await TeamProcesses.shared.stopLeftOver(left.leader)
                        busy = false
                        onChange()
                    }
                }.disabled(busy)
                Button("They Are Gone") {
                    busy = true
                    Task {
                        answer = await TeamProcesses.shared.confirmGoneInTime(left.leader)
                        busy = false
                        onChange()
                    }
                }.disabled(busy)
            }
        }
    }
}


/// The left-over runs of this app, as the registry has them now.
struct TeamLeftOversSection: View {
    var body: some View {
        ForEach(TeamLeftOversModel.shared.items) { left in
            TeamLeftOverRow(left: left)
        }
    }
}
