import AppKit
import SwiftUI

/// The models of the connection's organization and session, shared by the
/// left panel and the Organization window. Each counts only while it stands
/// for the connection now — checked on every read, not by a view's task
/// (review C6 p1-4) — and is made anew for a new one.
@MainActor
@Observable
final class ChatOrgCurrent {
    static let shared = ChatOrgCurrent()
    @ObservationIgnored private var org: (identity: String, model: ChatOrgModel)?
    @ObservationIgnored private var session: (identity: String, model: ChatDevicesModel)?
    /// Moves when a model is made, so views read them again.
    private var revision = 0

    var model: ChatOrgModel? {
        _ = revision
        guard let model = org?.model, model.isCurrent() else { return nil }
        return model
    }

    var devices: ChatDevicesModel? {
        _ = revision
        guard let model = session?.model, model.isCurrent() else { return nil }
        return model
    }

    /// What the organization's model stands for: server, account,
    /// organization, session and the cache.
    static func identity(_ service: ChatService = .shared) -> String? {
        guard let connection = service.connection, let key = connection.orgKey,
              let store = service.orgSessions[key]?.store else { return sessionIdentity(service) }
        return "\(key.server)|\(key.accountId)|\(key.orgId)|\(connection.sessionId)|\(ObjectIdentifier(store).hashValue)"
    }

    /// What the devices' model stands for: server, account and session.
    static func sessionIdentity(_ service: ChatService = .shared) -> String? {
        service.connection.map { "\($0.server)|\($0.accountId)|\($0.sessionId)" }
    }

    func refresh(_ service: ChatService = .shared) {
        let orgIdentity = Self.identity(service), sessionIdentity = Self.sessionIdentity(service)
        if org?.identity != orgIdentity {
            org = orgIdentity.flatMap { id in ChatOrgModel.current(service).map { (id, $0) } }
            revision += 1
        }
        if session?.identity != sessionIdentity {
            session = sessionIdentity.flatMap { id in ChatDevicesModel.current(service).map { (id, $0) } }
            revision += 1
        }
    }
}

/// Shared F5 wording kept for the composer and channel tools.
enum ChatOrgSidebarSection {
    /// What the owner agrees to (AG-1, DESIGN-F5 §1): who sees the answers,
    /// the agent's rights with their warnings (EX-7), its session's memory.
    static func addAgentText(_ agent: ChatAgentCard, team: String, fromSession: Bool) -> String {
        var lines = ["Its answers are seen by the members of team \(team), future ones included. Calls made on the executor Mac publish automatically; channel trust also enables automatic answers. "
            + "With each request it reads the messages of the channel it is given."]
        if let access = TeamAccessProfile(rawValue: agent.access) {
            lines.append("\(access.title): \(access.summary)")
            lines += TeamPublishWarnings.lines(access: access, fromSession: fromSession, teamNames: [team])
        } else {
            lines.append("Rights: \(agent.access)")
        }
        return lines.joined(separator: "\n\n")
    }

    /// Why this Mac is no longer in the organization: the session closed, or
    /// the account removed.
    static func reason(_ state: ChatService.State) -> String? {
        switch state {
        case .needsSignIn(let text), .notMember(_, let text): text
        default: nil
        }
    }}

@MainActor
enum ChatOrgWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: ChatOrgWindowView())
            host.sizingOptions = .preferredContentSize
            let made = NSWindow(contentViewController: host)
            made.title = "Organization"
            made.styleMask = [.titled, .closable, .resizable]
            made.isReleasedWhenClosed = false
            made.appearance = Theme.windowAppearance
            made.center()
            window = made
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Asks before a change that cannot be taken back or that others see,
    /// as a sheet of the Organization window, for as long as `valid` holds:
    /// once the object or the right is gone — another Mac, a lower role,
    /// another connection — the sheet closes as cancelled and keeps nothing
    /// it showed (review C6b p1-4). `field`: a line to edit; its text is the
    /// answer. Nil when cancelled.
    static func ask(_ title: String, _ text: String, _ button: String, field initial: String? = nil,
                    while valid: @escaping @MainActor () -> Bool) async -> String? {
        guard valid() else { return nil }
        show()
        guard let host = window else { return nil }
        // One sheet at a time.
        while host.attachedSheet != nil { try? await Task.sleep(for: .milliseconds(200)) }
        guard valid() else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let field = initial.map { value in
            let made = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            made.stringValue = value
            return made
        }
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let watcher = SheetWatcher(valid: valid) { host.endSheet(alert.window, returnCode: .abort) }
        watcher.watch()
        let answer = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: host) { continuation.resume(returning: $0) }
        }
        watcher.open = false
        let text = field?.stringValue ?? ""
        field?.stringValue = ""
        alert.messageText = ""
        alert.informativeText = ""
        guard answer == .alertFirstButtonReturn, valid() else { return nil }
        return text
    }

    static func confirm(_ title: String, _ text: String, _ button: String,
                        while valid: @escaping @MainActor () -> Bool) async -> Bool {
        await ask(title, text, button, while: valid) != nil
    }
}

/// Closes a sheet once what it asks about is no longer valid: looked at
/// again on every change of what `valid` reads.
@MainActor
private final class SheetWatcher {
    var open = true
    let valid: @MainActor () -> Bool
    let close: @MainActor () -> Void

    init(valid: @escaping @MainActor () -> Bool, close: @escaping @MainActor () -> Void) {
        self.valid = valid
        self.close = close
    }

    func watch() {
        withObservationTracking { _ = valid() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.open else { return }
                if self.valid() { self.watch() } else { self.close() }
            }
        }
    }
}

/// The Organization window. Its forms belong to one organization and
/// session: another one starts them empty (review C6 p1-5).
private struct ChatOrgWindowView: View {
    private var current = ChatOrgCurrent.shared

    var body: some View {
        Group {
            if current.model != nil || current.devices != nil {
                ChatOrgWindowContent(model: current.model, devices: current.devices)
                    .id(ChatOrgCurrent.identity())
                    .attentionPlace(ChatService.shared.connection?.orgKey.map { [.organization($0.orgId)] } ?? [])
            } else {
                VStack(spacing: 10) {
                    Text(ChatOrgSidebarSection.reason(ChatService.shared.state) ?? "Not connected to a server.")
                    Button("Connect to a Server…") { ChatConnectWindow.show() }
                }
                .padding(30)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task(id: ChatOrgCurrent.identity()) { current.refresh() }
    }
}

private struct ChatOrgWindowContent: View {
    let model: ChatOrgModel?
    let devices: ChatDevicesModel?
    @State private var answer: String?
    @State private var selected: AttentionOrganizationSection = .members

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model == nil, let reason = ChatOrgSidebarSection.reason(ChatService.shared.state) {
                Text(reason).font(Theme.display(11)).foregroundStyle(.orange)
            }
            if let notice = model?.notice {
                Text(notice).font(Theme.display(11)).foregroundStyle(.orange)
            }
            TabView(selection: $selected) {
                if let model {
                    ChatOrgMembersTab(model: model, act: act).tabItem { Text("Members") }.tag(AttentionOrganizationSection.members)
                    ChatOrgTeamsTab(model: model, act: act).tabItem { Text("Teams") }.tag(AttentionOrganizationSection.teams)
                    if model.actions.contains(.invite) {
                        ChatOrgInvitationsTab(model: model, act: act).tabItem { Text("Invitations") }.tag(AttentionOrganizationSection.invitations)
                    }
                }
                // The account's devices, in an organization or not (review C6 p1-9).
                if let devices {
                    ChatOrgDevicesTab(model: devices).tabItem { Text("Devices") }.tag(AttentionOrganizationSection.devices)
                }
                if let model, model.actions.contains(.seeAudit) {
                    ChatOrgAuditTab(model: model).tabItem { Text("Security Log") }.tag(AttentionOrganizationSection.audit)
                }
            }
            if let model, !model.refused.isEmpty {
                ForEach(model.refused, id: \.id) { item in
                    Text("\(item.title): refused by the server (\(item.code)).").font(Theme.display(11)).foregroundStyle(.orange)
                }
                Button("Dismiss") { model.dismissRefusals(Set(model.refused.map(\.id))) }
            }
            if let answer { Text(answer).font(Theme.display(11)).foregroundStyle(.orange) }
            if let problem = model?.problem { Text(problem).font(Theme.display(11)).foregroundStyle(.orange) }
        }
        .padding(12)
        .attentionPlace(ChatService.shared.connection?.orgKey.map { [.organization($0.orgId, section: selected)] } ?? [])
        .onChange(of: AttentionSelection.shared.revision, initial: true) { _, _ in
            if model == nil { selected = .devices }
            guard case .organization(let org, let section?) = AttentionSelection.shared.destination,
                  ChatService.shared.connection?.orgKey?.orgId == org else { return }
            if section == .invitations && model?.actions.contains(.invite) != true { return }
            if section == .audit && model?.actions.contains(.seeAudit) != true { return }
            if section == .devices && devices == nil { return }
            if section != .devices && model == nil { return }
            selected = section
        }
    }

    /// Runs a change; a refusal before it is sent shows here.
    private func act(_ change: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await change()
                answer = nil
            } catch {
                answer = error.localizedDescription
            }
        }
    }
}

typealias ChatOrgAct = (@escaping @MainActor () async throws -> Void) -> Void

private struct ChatOrgMembersTab: View {
    let model: ChatOrgModel
    let act: ChatOrgAct
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Your name", text: $name)
                Button("Change Name") {
                    let text = name
                    act { try model.setName(text) }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !model.actions.contains(.setOwnName))
            }
            List(model.members) { member in
                HStack {
                    VStack(alignment: .leading) {
                        Text(member.name + (member.accountId == model.me ? " (you)" : ""))
                        Text("@\(member.handle) · \(member.role)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let roles = model.roles(for: member)
                    if !roles.isEmpty {
                        Menu("Role") {
                            ForEach(roles, id: \.self) { role in
                                Button("Make \(role.capitalized)") { act { try model.setRole(member, to: role) } }
                            }
                        }
                        .fixedSize()
                    }
                    if model.canRemove(member) {
                        Button("Remove…") {
                            act {
                                guard await ChatOrgWindow.confirm("Remove \(member.name) from the organization?",
                                                                  "Their devices lose access to the organization; they leave every team.",
                                                                  "Remove", while: { model.member(member.accountId).map(model.canRemove) ?? false })
                                else { return }
                                try model.remove(member)
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .onAppear { name = model.member(model.me)?.name ?? "" }
    }
}

private struct ChatOrgTeamsTab: View {
    let model: ChatOrgModel
    let act: ChatOrgAct
    @State private var newTeam = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.actions.contains(.createTeam) {
                HStack {
                    TextField("New team name", text: $newTeam)
                    Button("Create Team") {
                        let text = newTeam
                        act {
                            try model.createTeam(text)
                            newTeam = ""
                        }
                    }
                    .disabled(newTeam.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            List(model.teams) { team in
                teamRow(team)
            }
        }
        .padding(8)
    }

    private func teamRow(_ team: ChatOrgView.Team) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(team.name).font(.headline)
                if team.archived { Text("archived").font(.caption).foregroundStyle(.secondary) }
                if team.mine { Text("you are in it").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.canChange(team) {
                    Button("Rename…") {
                        act {
                            guard let name = await ChatOrgWindow.ask("Rename \(team.name)", "", "Rename", field: team.name,
                                                                     while: { current(team).map(model.canChange) ?? false })
                            else { return }
                            try model.renameTeam(team, to: name)
                        }
                    }
                    Button("Archive…") {
                        act {
                            guard await ChatOrgWindow.confirm("Archive \(team.name)?", "An archived team cannot be changed.", "Archive",
                                                              while: { current(team).map(model.canChange) ?? false })
                            else { return }
                            try model.archiveTeam(team)
                        }
                    }
                }
                if model.canJoin(team) {
                    Button("Join…") {
                        act {
                            guard await ChatOrgWindow.confirm("Join \(team.name)?",
                                                              "This is written to the security log and seen by the team's members.",
                                                              "Join", while: { current(team).map(model.canJoin) ?? false })
                            else { return }
                            try model.join(team)
                        }
                    }
                }
                if model.canLeave(team) {
                    Button("Leave…") {
                        act {
                            guard await ChatOrgWindow.confirm("Leave \(team.name)?", "You stop seeing this team.", "Leave",
                                                              while: { current(team).map(model.canLeave) ?? false })
                            else { return }
                            try model.leave(team)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(team.members, id: \.self) { account in
                    let name = model.member(account)?.name ?? "unknown"
                    if model.canRemoveMember(account, from: team) {
                        Button("\(name) ✕") { act { try model.removeMember(account, from: team) } }
                            .buttonStyle(.borderless)
                            .help("Remove \(name) from \(team.name)")
                    } else {
                        Text(name).font(.caption)
                    }
                }
                let others = model.candidates(for: team)
                if !others.isEmpty {
                    Menu("Add") {
                        ForEach(others) { member in
                            Button(member.name) { act { try model.addMember(member.accountId, to: team) } }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The team as the model has it now; nil once it is gone or not visible.
    private func current(_ team: ChatOrgView.Team) -> ChatOrgView.Team? {
        model.teams.first { $0.teamId == team.teamId }
    }
}

private struct ChatOrgInvitationsTab: View {
    let model: ChatOrgModel
    let act: ChatOrgAct
    @State private var email = ""
    @State private var role = "member"
    @State private var teams: Set<String> = []
    /// Chosen teams that stopped being choosable (archived, gone) were taken
    /// off the form: said once, so the invitation is not refused unexplained
    /// (review C6b p2-6).
    @State private var takenOff = false

    private var choosable: [ChatOrgView.Team] { model.invitable }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Email", text: $email)
                Picker("", selection: $role) {
                    Text("Member").tag("member")
                    Text("Admin").tag("admin")
                }
                .labelsHidden()
                .fixedSize()
                Button("Invite") {
                    let (address, chosen, ids) = (email, role, Array(teams))
                    act {
                        try model.invite(email: address, role: chosen, teams: ids)
                        email = ""
                        teams = []
                        takenOff = false
                    }
                }
                .disabled(!email.contains("@"))
            }
            if takenOff {
                Text("A chosen team is no longer available and was taken off.").font(.caption).foregroundStyle(.orange)
            }
            if !choosable.isEmpty {
                HStack {
                    Text("Teams:").font(.caption)
                    ForEach(choosable) { team in
                        Toggle(team.name, isOn: Binding(get: { teams.contains(team.teamId) },
                                                        set: { if $0 { teams.insert(team.teamId) } else { teams.remove(team.teamId) } }))
                    }
                }
            }
            List(model.invitations, id: \.invitationId) { invitation in
                HStack {
                    VStack(alignment: .leading) {
                        Text(invitation.email)
                        Text("\(invitation.role) · until \(invitation.expiresAt ?? "—")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke") { act { try model.revoke(invitation) } }
                }
            }
        }
        .padding(8)
        .onChange(of: choosable.map(\.teamId)) { _, ids in
            let kept = teams.intersection(ids)
            if kept != teams {
                teams = kept
                takenOff = true
            }
        }
    }
}

private struct ChatOrgDevicesTab: View {
    let model: ChatDevicesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Devices signed in to your account on this server.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await model.load() } }
            }
            if let problem = model.problem {
                Text(problem).font(Theme.display(11)).foregroundStyle(.orange)
            }
            List(model.devices ?? []) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.deviceName + (device.current ? " (this Mac)" : ""))
                        Text("signed in \(device.createdAt) · last seen \(device.lastSeenAt ?? "—")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if device.current {
                        // This Mac: the core's Disconnect, with its own confirmation (review C6e p1-5).
                        Button("Disconnect…") { Task { await model.close(device) } }
                    } else {
                        Button("Close Session…") {
                            Task {
                                guard await ChatOrgWindow.confirm("Close the session of \(device.deviceName)?",
                                                                  "Closes that device's access to the whole server, every organization on it included.",
                                                                  "Close Session",
                                                                  while: { model.isCurrent() && model.devices?.contains { $0.id == device.id } == true })
                                else { return }
                                await model.close(device)
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .task { await model.load() }
    }
}

private struct ChatOrgAuditTab: View {
    let model: ChatOrgModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button("Refresh") { Task { await model.loadAudit() } }
            }
            List(model.audit ?? []) { record in
                VStack(alignment: .leading) {
                    Text("\(record.action) · \(record.result)")
                    Text("\(record.at) · \(record.actorAccountId.flatMap { model.member($0)?.name } ?? record.actorAccountId ?? "operator") · \(record.object ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.auditNext != nil {
                Button("Older") { Task { await model.loadAudit(more: true) } }
            }
        }
        .padding(8)
        .task { await model.loadAudit() }
    }
}

/// Problems of a channel action, said without naming anything (the
/// names are the dialogs', which close with their object).
@MainActor
enum ChannelPrompt {
    static func fail(_ error: Error) { fail(error.localizedDescription) }

    static func fail(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}
