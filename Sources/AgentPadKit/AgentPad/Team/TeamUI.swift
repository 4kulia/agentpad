import AppKit
import SwiftUI

/// Team menu actions, the pairing dialogs and the Colleagues window
/// (docs/agentpad/TEAM.md 6.1).
@MainActor
enum TeamUI {
    static var service: TeamService { .shared }

    /// Saved state may still be loading when a link opens the app.
    private static var loading: Task<Void, Never>?
    /// One join at a time from the UI; a second link waits its turn.
    private static var joining = false

    /// Wires approval and loads saved state. Called once at launch.
    static func install() {
        // Join requests wait in the right panel (TeamPanelSection); the Dock
        // asks for attention and counts them like sessions that need you.
        service.approvePairing = { _ in
            NSApp.requestUserAttention(.criticalRequest)
            return nil
        }
        service.onPendingChange = { AttentionCoordinator.shared.refreshBadge() }
        // Colleagues' calls wait there too; when AgentPad is in the
        // background a notification says who calls which agent (R-1).
        service.calls.onPendingChange = { AttentionCoordinator.shared.refreshBadge() }
        service.calls.onAccessRequest = { request, call in
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
            let title: String
            switch call.report.state {
            case .done: title = "\(call.address) answered"
            case .denied: title = "\(call.colleague) declined your call"
            case .expired:
                title = call.delivered
                    ? "\(call.colleague) did not decide on your call in time"
                    : "Your call to \(call.address) was not delivered"
            case .cancelled: title = "Your call to \(call.address) was cancelled"
            default: title = "Your call to \(call.address) failed"
            }
            let body = (call.report.state == .done ? call.report.text : call.report.detail) ?? ""
            AttentionCoordinator.shared.notificationManager?.postTeam(
                title: title, body: String(body.replacingOccurrences(of: "\n", with: " ").prefix(160))
            )
        }
        // Waking up or a new network: retry deliveries now (D-3).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                service.calls.nudge()
                await service.pingContacts()
            }
        }
        TeamNetworkWatch.shared.start {
            service.calls.nudge()
            Task { await service.pingContacts() }
        }
        service.onTeamToolsChange = { on in
            if on { AgentPadShellIntegration.writeTeamMCPConfig() } else { AgentPadShellIntegration.removeTeamMCPConfig() }
        }
        // Off until it starts: a file left by a crash must not outlive it.
        AgentPadShellIntegration.removeTeamMCPConfig()
        loading = Task { await service.load() }
    }

    // MARK: Menu actions

    static func toggleTeamWork() {
        Task {
            await loading?.value
            if service.isOn || service.status == .starting {
                let alert = NSAlert()
                alert.messageText = "Turn off team work?"
                alert.informativeText = "Colleagues will see you as offline. Your colleagues list and identity are kept."
                alert.addButton(withTitle: "Turn Off")
                alert.addButton(withTitle: "Cancel")
                guard await present(alert) == .alertFirstButtonReturn else { return }
                do { try await service.disable() } catch { await showError("Team work is off, but this was not saved", error) }
            } else {
                _ = await turnOn()
            }
        }
    }

    static func invite() {
        Task {
            guard await ensureOn() else { return }
            do {
                let url = try await service.createInvite()
                TeamWindows.showInvite(url)
            } catch {
                await showError("Could not create an invitation", error)
            }
        }
    }

    /// "Join with Link…": the same path a clicked link takes.
    static func joinFromPrompt() {
        Task {
            let alert = NSAlert()
            alert.messageText = "Join a colleague"
            alert.informativeText = "Paste the invitation link your colleague sent you."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.placeholderString = "agentpad://team/join?…"
            if let clip = NSPasteboard.general.string(forType: .string), clip.hasPrefix("agentpad://team/") {
                field.stringValue = clip
            }
            alert.accessoryView = field
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard await present(alert) == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text) else { return await showError("Not an invitation link", nil) }
            if !handleLink(url) { await showError("Not an invitation link", nil) }
        }
    }

    static func showColleagues() {
        TeamWindows.showColleagues()
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
    static func canWatch(_ call: TeamCalls.Incoming) -> Bool {
        switch call.state {
        case .queued, .running: true
        case .done, .failed, .cancelled: FileManager.default.fileExists(atPath: TeamStorage.standard.runLogURL(callId: call.id).path)
        default: false
        }
    }

    /// A tab with `agentpad-cli team watch`: what the agent does, live.
    static func watch(_ call: TeamCalls.Incoming) {
        let folder = service.calls.agents.first { $0.id == call.agentId }?.folder ?? NSHomeDirectory()
        let cli = shellQuoted(AgentPadShellIntegration.agentPadCLIBinaryPath)
        openTab(folder, "\(cli) team watch \(call.id)", "Team · \(call.peerName) → \(call.agentName)")
    }

    /// The owner carries on with the call's conversation in a normal tab.
    static func continueYourself(_ call: TeamCalls.Incoming) {
        guard UUID(uuidString: call.threadId) != nil,
              let folder = service.calls.agents.first(where: { $0.id == call.agentId })?.folder
        else { return }
        openTab(folder, "claude --resume \(call.threadId)", "Team · \(call.peerName) → \(call.agentName) · yours")
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

    // MARK: Links

    /// True when `url` is a team link; the caller then does nothing else.
    @discardableResult
    static func handleLink(_ url: URL) -> Bool {
        let parsed: TeamInviteLink?
        do { parsed = try TeamInviteLink.parse(url) } catch {
            Task { await showError("This invitation link cannot be used", error) }
            return true
        }
        guard let link = parsed else { return false }
        Task { await join(link) }
        return true
    }

    private static func join(_ link: TeamInviteLink) async {
        guard !joining else {
            return await showError("A join is already waiting", TeamError.refused("join_in_progress"))
        }
        joining = true
        defer { joining = false }
        NSApp.activate(ignoringOtherApps: true)
        guard await ensureOn() else { return }
        let attempt: TeamService.JoinAttempt
        do { attempt = try service.prepareJoin(link) } catch {
            return await showError("This invitation link cannot be used", error)
        }
        let alert = NSAlert()
        alert.messageText = "Join \(link.inviterName)?"
        alert.informativeText = """
        Next you will see a six-digit code, and \(link.inviterName) will see one \
        too. Compare them — over a call or a message — before \(link.inviterName) \
        allows the request. Different codes mean someone else is answering.
        """
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        guard await present(alert) == .alertFirstButtonReturn else { return }
        TeamWindows.showWaiting(name: link.inviterName, code: nil)
        do {
            let contact = try await service.join(attempt) { code in
                TeamWindows.showWaiting(name: link.inviterName, code: code)
            }
            TeamWindows.closeWaiting()
            let done = NSAlert()
            done.messageText = "You and \(contact.displayName) are now colleagues"
            done.informativeText = "Team → Colleagues shows when \(contact.displayName) is online."
            await present(done)
        } catch {
            TeamWindows.closeWaiting()
            await showError("Could not join \(link.inviterName)", error)
        }
    }

    // MARK: Turning on

    private static func ensureOn() async -> Bool {
        await loading?.value
        if service.isOn { return true }
        if case .failed(let reason) = service.status, service.config.enabled {
            await showError("Team work could not start", TeamError.storage(reason))
            return false
        }
        return await turnOn()
    }

    private static func turnOn() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Turn on team work"
        alert.informativeText = """
        Colleagues you invite will see this name. AgentPad then connects to other \
        Macs directly, through the relays of iroh (n0.computer) when a direct path \
        is not possible. Traffic is end-to-end encrypted.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = service.config.displayName.isEmpty
            ? (Host.current().localizedName ?? NSFullUserName())
            : service.config.displayName
        alert.accessoryView = field
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard await present(alert) == .alertFirstButtonReturn else { return false }
        await service.enable(displayName: field.stringValue)
        if case .failed(let reason) = service.status {
            await showError("Team work could not start", TeamError.storage(reason))
            return false
        }
        return service.isOn
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
            // No window to attach to: the Colleagues window serves as one.
            TeamWindows.showColleagues()
            window = TeamWindows.colleaguesWindow
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
    private static var colleagues: NSWindow?
    static var colleaguesWindow: NSWindow? { colleagues }
    private static var invite: NSWindow?
    private static var waiting: NSWindow?
    private static var agents: NSWindow?
    private static var publishSession: NSWindow?
    /// The Team tab of the front window's left sidebar.
    static var showCallsTab: @MainActor () -> Void = {}

    static func showCalls() { showCallsTab() }

    static func showPublishSession(sessionId: String, title: String, audience: [String]?) {
        publishSession?.close()
        // Closing is bound to this window: a save that ends after it was
        // replaced must not close the next one.
        final class Handle { weak var window: NSWindow? }
        let handle = Handle()
        let made = window(title: "Publish to Team", content: TeamPublishSessionView(
            sessionId: sessionId, title: title, audience: audience, service: .shared
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

    static func showColleagues() {
        if colleagues == nil {
            colleagues = window(title: "Colleagues", content: TeamColleaguesView(service: .shared))
        }
        present(colleagues)
    }

    static func showInvite(_ url: URL) {
        invite?.close()
        invite = window(title: "Invite a Colleague", content: TeamInviteView(url: url) { invite?.close() })
        present(invite)
    }

    static func showWaiting(name: String, code: String?) {
        waiting?.close()
        waiting = window(title: "Joining", content: TeamWaitingView(name: name, code: code))
        present(waiting)
    }

    static func closeWaiting() {
        waiting?.close()
        waiting = nil
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

private struct TeamInviteView: View {
    let url: URL
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send this link to your colleague")
                .font(Theme.display(14, weight: .semibold))
            Text(url.absoluteString)
                .font(Theme.mono(11))
                .textSelection(.enabled)
                .lineLimit(4)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.chromeHover)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Works once, for 24 hours. It holds a secret: send it in a private message, not a public channel. When your colleague opens it, you will be asked to allow them and to compare a six-digit code.")
                .font(Theme.display(11))
                .foregroundStyle(Theme.chromeMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    copied = true
                }
                .keyboardShortcut(.defaultAction)
                Button("Done", action: onClose)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}

private struct TeamWaitingView: View {
    let name: String
    let code: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(code == nil ? "Connecting to \(name)…" : "Waiting for \(name) to allow the request…")
                    .font(Theme.display(13, weight: .medium))
            }
            Text("Pairing code: \(code ?? "…")")
                .font(Theme.mono(13))
            Text(code == nil ? "The code appears once \(name)'s Mac answers." : "Compare it with \(name). They have two minutes to answer.")
                .font(Theme.display(11))
                .foregroundStyle(Theme.chromeMuted)
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
    }
}

struct TeamColleaguesView: View {
    let service: TeamService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // Join requests are answered here too, for when the right panel is hidden.
            TeamPanelSection(service: service)
            Divider()
            if service.contacts.isEmpty {
                Text(service.isOn ? "No colleagues yet. Team → Invite Colleague… creates a link." : "Team work is off.")
                    .font(Theme.display(12))
                    .foregroundStyle(Theme.chromeMuted)
                    .padding(.vertical, 8)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(service.contacts) { contact in
                            row(contact, now: context.date)
                        }
                    }
                }
            }
            HStack {
                Button("Invite Colleague…") { TeamUI.invite() }
                Spacer()
                Button(service.isOn ? "Turn Off…" : "Turn On…") { TeamUI.toggleTeamWork() }
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(service.config.displayName.isEmpty ? "Team work" : service.config.displayName)
                .font(Theme.display(14, weight: .semibold))
            switch service.status {
            case .off:
                Text("Off — AgentPad makes no team connections.").font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
            case .starting:
                Text("Starting…").font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
            case .on(let id):
                Text("On · \(String(id.prefix(12)))…").font(Theme.mono(10.5)).foregroundStyle(Theme.chromeMuted)
            case .failed(let reason):
                Text(reason).font(Theme.display(11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ contact: TeamContact, now: Date) -> some View {
        let online = contact.isOnline(now: now)
        return HStack(spacing: 8) {
            Circle()
                .fill(online ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.displayName).font(Theme.display(13, weight: .medium))
                Text(presence(contact, online: online, now: now))
                    .font(Theme.display(10.5))
                    .foregroundStyle(Theme.chromeMuted)
            }
            Spacer()
            Button("Rename…") { rename(contact) }.buttonStyle(.borderless)
            Button("Remove…") { remove(contact) }.buttonStyle(.borderless)
        }
        .help(contact.id)
    }

    private func presence(_ contact: TeamContact, online: Bool, now: Date) -> String {
        if online { return "online" }
        guard let seen = contact.lastSeen else { return "not seen yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "last seen " + formatter.localizedString(for: seen, relativeTo: now)
    }

    private func rename(_ contact: TeamContact) { Task { await renameAsync(contact) } }
    private func remove(_ contact: TeamContact) { Task { await removeAsync(contact) } }

    private func renameAsync(_ contact: TeamContact) async {
        let alert = NSAlert()
        alert.messageText = "Name for \(contact.name)"
        alert.informativeText = "Only you see this name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = contact.displayName
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard await TeamUI.present(alert) == .alertFirstButtonReturn else { return }
        do { try service.rename(contact.id, alias: field.stringValue) } catch {
            await TeamUI.showError("The name was not saved", error)
        }
    }

    private func removeAsync(_ contact: TeamContact) async {
        let alert = NSAlert()
        alert.messageText = "Remove \(contact.displayName)?"
        alert.informativeText = "This Mac stops accepting anything from them at once. To work together again, they need a new invitation."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard await TeamUI.present(alert) == .alertFirstButtonReturn else { return }
        do { try service.remove(contact.id) } catch {
            await TeamUI.showError("\(contact.displayName) is removed until restart, but this was not saved", error)
        }
    }
}
