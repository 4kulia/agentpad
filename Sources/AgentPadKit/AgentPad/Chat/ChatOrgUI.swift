import AppKit
import SwiftUI

/// The models of the connection's organization and session, shared by the
/// left panel and Organization tabs. Each counts only while it stands
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
    }
}

struct ChatOrgTabContent: View {
    @Bindable var state: TabState
    @Bindable var form: OrganizationFormState
    let model: ChatOrgModel?
    let devices: ChatDevicesModel?
    private var selected: Binding<AttentionOrganizationSection> {
        Binding(get: { AttentionOrganizationSection(rawValue: state.navigation.selection ?? "") ?? .members }, set: {
            state.confirmation.invalidate(); state.navigation.selection = $0.rawValue; state.changed()
        })
    }
    private var sections: [AttentionOrganizationSection] {
        var sections: [AttentionOrganizationSection] = model == nil ? [] : [.members, .teams]
        if model?.actions.contains(.invite) == true { sections.append(.invitations) }
        if devices != nil { sections.append(.devices) }
        if model?.actions.contains(.seeAudit) == true { sections.append(.audit) }
        return sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model == nil, let reason = ChatOrgSidebarSection.reason(ChatService.shared.state) {
                Text(reason).font(Theme.display(11)).foregroundStyle(.orange)
            }
            if let notice = model?.notice {
                Text(notice).font(Theme.display(11)).foregroundStyle(.orange)
            }
            TabView(selection: selected) {
                if let model {
                    ChatOrgMembersTab(model: model, state: state, form: form, act: act).tabItem { Text("Members") }.tag(AttentionOrganizationSection.members)
                    ChatOrgTeamsTab(model: model, state: state, form: form, act: act).tabItem { Text("Teams") }.tag(AttentionOrganizationSection.teams)
                    if model.actions.contains(.invite) {
                        ChatOrgInvitationsTab(model: model, state: state, form: form, act: act).tabItem { Text("Invitations") }.tag(AttentionOrganizationSection.invitations)
                    }
                }
                // The account's devices, in an organization or not (review C6 p1-9).
                if let devices {
                    ChatOrgDevicesTab(model: devices, state: state).tabItem { Text("Devices") }.tag(AttentionOrganizationSection.devices)
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
            if let answer = form.error { Text(answer).font(Theme.display(11)).foregroundStyle(.orange) }
            if let problem = model?.problem { Text(problem).font(Theme.display(11)).foregroundStyle(.orange) }
        }
        .padding(12)
        .attentionPlace(ChatService.shared.connection?.orgKey.map { [.organization($0.orgId, section: selected.wrappedValue)] } ?? [])
        .onChange(of: sections, initial: true) { _, sections in
            if !sections.contains(selected.wrappedValue), let first = sections.first { selected.wrappedValue = first }
        }
    }

    /// Runs a change; a refusal before it is sent shows here.
    private func act(_ change: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await change()
                form.error = nil
            } catch {
                form.error = error.localizedDescription
            }
        }
    }
}

typealias ChatOrgAct = (@escaping @MainActor () async throws -> Void) -> Void

private struct ChatOrgMembersTab: View {
    let model: ChatOrgModel
    let state: TabState
    @Bindable var form: OrganizationFormState
    let act: ChatOrgAct

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Your name", text: $form.fields.name)
                Button("Change Name") {
                    let text = form.fields.name
                    act { try model.setName(text) }
                }
                .disabled(form.fields.name.trimmingCharacters(in: .whitespaces).isEmpty || !model.actions.contains(.setOwnName))
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
                                Button("Make \(role.capitalized)") {
                                    OrganizationTabs.confirm(state, target: member.id, title: "Make \(member.name) \(role)?",
                                        text: "Their organization permissions will change.", verb: "Change Role",
                                        valid: { model.member(member.id) == member && model.roles(for: member).contains(role) }) {
                                            try model.setRole(member, to: role)
                                        }
                                }
                            }
                        }
                        .fixedSize()
                    }
                    if model.canRemove(member) {
                        Button("Remove…") {
                            OrganizationTabs.confirm(state, target: member.id, title: "Remove \(member.name) from the organization?",
                                text: "Their devices lose access to the organization; they leave every team.", verb: "Remove", destructive: true,
                                valid: { model.member(member.id) == member && model.canRemove(member) }) { try model.remove(member) }
                        }
                    }
                }
            }
        }
        .padding(8)

    }
}

private struct ChatOrgTeamsTab: View {
    let model: ChatOrgModel
    let state: TabState
    @Bindable var form: OrganizationFormState
    let act: ChatOrgAct
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.actions.contains(.createTeam) {
                HStack {
                    TextField("New team name", text: $form.fields.newTeam)
                    Button("Create Team") {
                        let text = form.fields.newTeam
                        act {
                            try model.createTeam(text)
                            form.fields.newTeam = ""
                        }
                    }
                    .disabled(form.fields.newTeam.trimmingCharacters(in: .whitespaces).isEmpty)
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
                if form.fields.renameTeamID == team.id {
                    VStack(alignment: .leading) {
                        TextField("Team name", text: $form.fields.renameText)
                            .focused($renameFocused).accessibilityIdentifier("rename-team-" + team.id)
                            .onSubmit { form.rename(team, model: model) }
                            .onExitCommand { form.fields.renameTeamID = nil; form.renameError = nil }
                            .onAppear { renameFocused = true }
                        if let error = form.renameError { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                } else { Text(team.name).font(.headline) }
                if team.archived { Text("archived").font(.caption).foregroundStyle(.secondary) }
                if team.mine { Text("you are in it").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.canChange(team) {
                    Button("Rename…") {
                        form.fields.renameTeamID = team.id; form.fields.renameText = team.name; form.renameError = nil
                    }
                    Button("Archive…") {
                        OrganizationTabs.confirm(state, target: team.id, title: "Archive \(team.name)?",
                            text: "An archived team cannot be changed.", verb: "Archive", destructive: true,
                            valid: { current(team) == team && model.canChange(team) }) { try model.archiveTeam(team) }
                    }
                }
                if model.canJoin(team) {
                    Button("Join…") {
                        OrganizationTabs.confirm(state, target: team.id, title: "Join \(team.name)?",
                            text: "This is written to the security log and seen by the team's members.", verb: "Join",
                            valid: { current(team) == team && model.canJoin(team) }) { try model.join(team) }
                    }
                }
                if model.canLeave(team) {
                    Button("Leave…") {
                        OrganizationTabs.confirm(state, target: team.id, title: "Leave \(team.name)?",
                            text: "You stop seeing this team.", verb: "Leave", destructive: true,
                            valid: { current(team) == team && model.canLeave(team) }) { try model.leave(team) }
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(team.members, id: \.self) { account in
                    let name = model.member(account)?.name ?? "unknown"
                    if model.canRemoveMember(account, from: team) {
                        Button("\(name) ✕") {
                            OrganizationTabs.confirm(state, target: team.id + ":" + account, title: "Remove \(name) from \(team.name)?",
                                text: "They lose access to this team.", verb: "Remove", destructive: true,
                                valid: { current(team) == team && model.canRemoveMember(account, from: team) }) {
                                    try model.removeMember(account, from: team)
                                }
                        }
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
                            Button(member.name) {
                                OrganizationTabs.confirm(state, target: team.id + ":" + member.id, title: "Add \(member.name) to \(team.name)?",
                                    text: "They will be able to read the team's channels and call its agents.", verb: "Add",
                                    valid: { current(team) == team && model.candidates(for: team).contains(member) }) {
                                        try model.addMember(member.accountId, to: team)
                                    }
                            }
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
    let state: TabState
    @Bindable var form: OrganizationFormState
    let act: ChatOrgAct

    private var choosable: [ChatOrgView.Team] { model.invitable }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Email", text: $form.fields.email)
                Picker("", selection: $form.fields.role) {
                    Text("Member").tag("member")
                    Text("Admin").tag("admin")
                }
                .labelsHidden()
                .fixedSize()
                Button("Invite") {
                    let (address, chosen, ids) = (form.fields.email, form.fields.role, Array(form.fields.teams))
                    OrganizationTabs.confirm(state, target: address, title: "Invite \(address)?",
                        text: "They will join as \(chosen), with access to General and the selected teams.", verb: "Invite",
                        valid: { model.manages && Set(ids).isSubset(of: Set(model.invitable.map(\.teamId))) }) {
                        try model.invite(email: address, role: chosen, teams: ids)
                        form.fields.email = ""
                        form.fields.teams = []
                    }
                }
                 .disabled(!form.fields.email.contains("@"))
            }
            if !form.fields.teams.isSubset(of: Set(choosable.map(\.teamId))) {
                Text("A chosen team is no longer available. Update the invitation before sending.").font(.caption).foregroundStyle(.orange)
                Button("Remove unavailable teams") { form.fields.teams.formIntersection(choosable.map(\.teamId)) }
            }
            if !choosable.isEmpty {
                HStack {
                    Text("Teams:").font(.caption)
                    ForEach(choosable) { team in
                        Toggle(team.name, isOn: Binding(get: { form.fields.teams.contains(team.teamId) },
                                                        set: { if $0 { form.fields.teams.insert(team.teamId) } else { form.fields.teams.remove(team.teamId) } }))
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
                    Button("Revoke") {
                        OrganizationTabs.confirm(state, target: invitation.invitationId, title: "Revoke invitation for \(invitation.email)?",
                            text: "This invitation can no longer be accepted.", verb: "Revoke", destructive: true,
                            valid: { model.invitations.contains(invitation) }) { try model.revoke(invitation) }
                    }
                }
            }
        }
        .padding(8)
    }
}

struct ChatOrgDevicesTab: View {
    let model: ChatDevicesModel
    let state: TabState

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
                            OrganizationTabs.confirm(state, target: device.id, title: "Close the session of \(device.deviceName)?",
                                text: "Closes that device's access to the whole server, every organization on it included.",
                                verb: "Close Session", destructive: true, requiresOrganization: false,
                                valid: { model.isCurrent() && model.devices?.contains(device) == true }) {
                                    await model.close(device)
                                    if let problem = model.problem { throw ChatError.storage(problem) }
                                }
                        }
                    }
                }
            }
        }
        .padding(8)
        .task { if model.devices == nil { await model.load() } }
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
        .task { if model.audit == nil { await model.loadAudit() } }
    }
}
