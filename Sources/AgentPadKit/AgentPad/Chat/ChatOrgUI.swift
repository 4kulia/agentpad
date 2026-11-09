import AppKit
import SwiftUI

/// The models of the connection's organization and session, shared by the
/// left panel and Organization tabs. Each counts only while it stands
/// for the connection now — checked on every read, not by a view's task
/// (review C6 p1-4) — and is made anew for a new one.
@MainActor
@Observable
final class ChatOrgCurrent {
    static var shared: ChatOrgCurrent {
        #if DEBUG
        if let sharedForTesting { return sharedForTesting }
        #endif
        return ChatService.shared.orgCurrent
    }
    #if DEBUG
    /// Keep fixture observations attached to their isolated service across
    /// asynchronous UI work, without replacing the production connection.
    static var sharedForTesting: ChatOrgCurrent?
    #endif
    @ObservationIgnored private var org: (identity: String, model: ChatOrgModel)?
    @ObservationIgnored private var session: (identity: String, model: ChatDevicesModel)?
    /// Moves when a model is made, so views read them again.
    private var revision = 0

    /// Connection ownership also starts the snapshot when no Chat UI is mounted.
    func follow(_ service: ChatService) {
        withObservationTracking {
            _ = service.state
            refresh(service)
            let model = model
            let allowed = model.map { $0.visible && !$0.inDoubt && !$0.snapshotOwed() && $0.view.pendingGeneration == nil } == true
            let scope = model?.key.map {
                AttentionScope(server: $0.server.description, account: $0.accountId, organization: $0.orgId,
                               generation: model?.view.generation ?? "")
            }
            service.attentionAggregates.update(scope.map {
                .init(scope: $0, session: service.connection?.sessionId ?? "", allowed: allowed)
            }) { service.connection?.orgKey.flatMap { service.orgSessions[$0]?.store } }
        } onChange: { [weak self, weak service] in
            Task { @MainActor in
                guard let self, let service else { return }
                self.follow(service)
            }
        }
    }

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
        let orgIdentity = service.state == .signedIn ? Self.identity(service) : nil
        let sessionIdentity = Self.sessionIdentity(service)
        if org?.identity != orgIdentity {
            org?.model.stop()
            org = orgIdentity.flatMap { id in ChatOrgModel.current(service, coalescingUpdates: true).map { (id, $0) } }
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
        OrganizationTabs.sections(actions: model?.actions, hasDevices: devices != nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            PopupScrollBody(maxHeight: 560) {
                VStack(alignment: .leading, spacing: 18) {
                    if model == nil, let reason = ChatOrgSidebarSection.reason(ChatService.shared.state) {
                        Text(reason).font(.caption).foregroundStyle(.orange)
                    }
                    if let notice = model?.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                    sectionContent
                    if let model, !model.refused.isEmpty {
                        ForEach(model.refused, id: \.id) { item in
                            Text("\(item.title): refused by the server (\(item.code)).").font(.caption).foregroundStyle(.orange)
                        }
                        Button("Dismiss") { model.dismissRefusals(Set(model.refused.map(\.id))) }
                    }
                    if let answer = form.error { Text(answer).font(.caption).foregroundStyle(.orange) }
                    if let problem = model?.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(alignment: .leading) {
            HStack(spacing: 0) {
                Theme.chromeHover.opacity(0.25).frame(width: 176)
                Rectangle().fill(Theme.chromeHairline).frame(width: 1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("organization-content")
        .attentionPlace(ChatService.shared.connection?.orgKey.map { [.organization($0.orgId, section: selected.wrappedValue)] } ?? [])
        .onChange(of: sections, initial: true) { _, sections in
            if !sections.contains(selected.wrappedValue), let first = sections.first { selected.wrappedValue = first }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(String((model?.orgName ?? "Organization").prefix(1)).uppercased())
                    .font(.headline).foregroundStyle(.white).frame(width: 30, height: 30)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 7))
                Text(model?.orgName ?? "Organization").font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }.padding(.horizontal, 7).padding(.bottom, 12)
            ForEach(sections, id: \.self) { section in
                Button { selected.wrappedValue = section } label: {
                    Label(section.popupTitle, systemImage: section.popupSymbol)
                        .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9).padding(.vertical, 9)
                        .background(selected.wrappedValue == section ? Theme.chromeHover : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selected.wrappedValue == section ? .isSelected : [])
                    .accessibilityIdentifier("organization-section-" + section.rawValue)
            }
        }.padding(12).frame(width: 177, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityLabel("Organization sections")
    }

    @ViewBuilder private var sectionContent: some View {
        switch selected.wrappedValue {
        case .members:
            if let model { ChatOrgMembersTab(model: model, state: state, form: form, act: act) }
        case .teams:
            if let model { ChatOrgTeamsTab(model: model, state: state, form: form, act: act) }
        case .invitations:
            if let model, model.actions.contains(.invite) { ChatOrgInvitationsTab(model: model, state: state, form: form, act: act) }
        case .devices:
            if let devices { ChatOrgDevicesTab(model: devices, state: state) }
        case .audit:
            if let model, model.actions.contains(.seeAudit) { ChatOrgAuditTab(model: model) }
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

private extension AttentionOrganizationSection {
    var popupTitle: String {
        switch self {
        case .members: "Members"
        case .teams: "Teams"
        case .invitations: "Invitations"
        case .devices: "Devices"
        case .audit: "Audit"
        }
    }
    var popupSymbol: String {
        switch self {
        case .members: "person.2"
        case .teams: "sidebar.left"
        case .invitations: "envelope"
        case .devices: "desktopcomputer"
        case .audit: "clock"
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
        VStack(alignment: .leading, spacing: 18) {
            OrganizationSectionHeading(title: "Members",
                subtitle: (model.orgName.map { $0 + " · " } ?? "") + "Manage who has access to this organization.")
            VStack(alignment: .leading, spacing: 7) {
                Text("Your name").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Your name", text: $form.fields.name).textFieldStyle(.roundedBorder)
                    Button("Change Name") {
                        let text = form.fields.name
                        act { try model.setName(text) }
                    }
                    .disabled(form.fields.name.trimmingCharacters(in: .whitespaces).isEmpty || !model.actions.contains(.setOwnName))
                }
                Text("Use Change Name to apply your name. Role changes require confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.members) { member in
                HStack(spacing: 12) {
                    ContactAvatar(stableID: member.accountId, name: member.name, kind: .person, size: 32)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(member.name + (member.accountId == model.me ? " (you)" : "")).font(.subheadline.weight(.semibold))
                        Text("@\(member.handle) · \(member.role)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let roles = model.roles(for: member)
                    if !roles.isEmpty {
                        Menu(member.role.capitalized) {
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
                        .accessibilityLabel("Role for " + member.name)
                    } else {
                        Text(member.role.capitalized).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 5))
                    }
                    if model.canRemove(member) {
                        Button("Remove…", role: .destructive) {
                            OrganizationTabs.confirm(state, target: member.id, title: "Remove \(member.name) from the organization?",
                                text: "Their devices lose access to the organization; they leave every team.", verb: "Remove member", destructive: true,
                                valid: { model.member(member.id) == member && model.canRemove(member) }) { try model.remove(member) }
                        }.buttonStyle(PopupDestructiveButtonStyle())
                            .accessibilityIdentifier("organization-remove-member-" + member.id)
                    }
                }
                Divider()
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("organization-members")
    }
}

private struct ChatOrgTeamsTab: View {
    let model: ChatOrgModel
    let state: TabState
    @Bindable var form: OrganizationFormState
    let act: ChatOrgAct
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OrganizationSectionHeading(title: "Teams", subtitle: "Create a team and manage its members.")
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
                    .buttonStyle(PopupPrimaryButtonStyle())
                    .disabled(form.fields.newTeam.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .textFieldStyle(.roundedBorder)
            }
            ForEach(model.teams) { team in
                teamRow(team)
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("organization-teams")
    }

    private func teamRow(_ team: ChatOrgView.Team) -> some View {
        VStack(alignment: .leading, spacing: 14) {
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
                if team.archived { Text("Archived").font(.caption).foregroundStyle(.secondary) }
                if team.mine { Text("You are in it").font(.caption).foregroundStyle(.green) }
                Spacer()
            }
            members(team)
            ViewThatFits(in: .horizontal) {
                HStack { actions(team) }
                VStack(alignment: .leading) { actions(team) }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chromeHover.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.chromeHairline))
    }

    @ViewBuilder private func actions(_ team: ChatOrgView.Team) -> some View {
                if model.canChange(team) {
                    Button("Rename…") {
                        form.fields.renameTeamID = team.id; form.fields.renameText = team.name; form.renameError = nil
                    }
                    Button("Archive…", role: .destructive) {
                        OrganizationTabs.confirm(state, target: team.id, title: "Archive \(team.name)?",
                            text: "An archived team cannot be changed.", verb: "Archive", destructive: true,
                            valid: { current(team) == team && model.canChange(team) }) { try model.archiveTeam(team) }
                    }.buttonStyle(PopupDestructiveButtonStyle())
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

    private func members(_ team: ChatOrgView.Team) -> some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), alignment: .leading)], alignment: .leading, spacing: 8) {
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
                            .buttonStyle(.bordered)
                            .help("Remove \(name) from \(team.name)")
                    } else {
                        Text(name).font(.caption).padding(.horizontal, 7).padding(.vertical, 5)
                            .background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 5))
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 18) {
            OrganizationSectionHeading(title: "Invitations",
                subtitle: model.orgName.map { "Invite a colleague to \($0)." } ?? "Invite a colleague to this organization.")
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Email").font(.caption).foregroundStyle(.secondary)
                    TextField("Email", text: $form.fields.email)
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Role").font(.caption).foregroundStyle(.secondary)
                    Picker("Role", selection: $form.fields.role) {
                        Text("Member").tag("member")
                        Text("Admin").tag("admin")
                    }.labelsHidden().frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }.textFieldStyle(.roundedBorder)
            if !form.fields.teams.isSubset(of: Set(choosable.map(\.teamId))) {
                Text("A chosen team is no longer available. Update the invitation before sending.").font(.caption).foregroundStyle(.orange)
                Button("Remove unavailable teams") { form.fields.teams.formIntersection(choosable.map(\.teamId)) }
            }
            if !model.teams.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Teams").font(.subheadline.weight(.semibold))
                    if let general = model.teams.first(where: \.isGeneral) {
                        Toggle(general.name, isOn: .constant(true)).disabled(true)
                    }
                    ForEach(choosable) { team in
                        Toggle(team.name, isOn: Binding(get: { form.fields.teams.contains(team.teamId) },
                                                        set: { if $0 { form.fields.teams.insert(team.teamId) } else { form.fields.teams.remove(team.teamId) } }))
                    }
                }
            }
            Button("Invite") {
                let (address, chosen, ids) = (form.fields.email, form.fields.role, Array(form.fields.teams))
                OrganizationTabs.confirm(state, target: address, title: "Invite \(address)?",
                    text: "They will join as \(chosen), with access to General and the selected teams.", verb: "Invite",
                    valid: { model.manages && Set(ids).isSubset(of: Set(model.invitable.map(\.teamId))) }) {
                    try model.invite(email: address, role: chosen, teams: ids)
                    form.fields.email = ""
                    form.fields.teams = []
                }
            }.buttonStyle(PopupPrimaryButtonStyle()).disabled(!form.fields.email.contains("@"))
            Text("Pending invitations").font(.headline).padding(.top, 6)
            ForEach(model.invitations, id: \.invitationId) { invitation in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(invitation.email).font(.subheadline.weight(.semibold))
                        Text("\(invitation.role.capitalized) · until \(OrganizationTabs.readableDate(invitation.expiresAt, includesTime: false))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) {
                        OrganizationTabs.confirm(state, target: invitation.invitationId, title: "Revoke invitation for \(invitation.email)?",
                            text: "This invitation can no longer be accepted.", verb: "Revoke", destructive: true,
                            valid: { model.invitations.contains(invitation) }) { try model.revoke(invitation) }
                    }.buttonStyle(PopupDestructiveButtonStyle())
                }
                Divider()
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("organization-invitations")
    }
}

struct ChatOrgDevicesTab: View {
    let model: ChatDevicesModel
    let state: TabState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OrganizationSectionHeading(title: "Devices", subtitle: "Devices signed in to your account on this server.")
            Button("Refresh") { Task { await model.load() } }
            if let problem = model.problem {
                Text(problem).font(Theme.display(11)).foregroundStyle(.orange)
            }
            ForEach(model.devices ?? []) { device in
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "desktopcomputer").padding(.top, 3)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(device.deviceName + (device.current ? " (this Mac)" : "")).font(.headline)
                            Text("Signed in \(OrganizationTabs.readableDate(device.createdAt, includesTime: false)) · last seen \(OrganizationTabs.readableDate(device.lastSeenAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if device.current {
                        // This Mac: the core's Disconnect, with its own confirmation (review C6e p1-5).
                        Button("Disconnect…", role: .destructive) { Task { await model.close(device) } }
                            .buttonStyle(PopupDestructiveButtonStyle())
                    } else {
                        Button("Close Session…", role: .destructive) {
                            OrganizationTabs.confirm(state, target: device.id, title: "Close the session of \(device.deviceName)?",
                                text: "Closes that device's access to the whole server, every organization on it included.",
                                verb: "Close Session", destructive: true, requiresOrganization: false,
                                valid: { model.isCurrent() && model.devices?.contains(device) == true }) {
                                    await model.close(device)
                                    if let problem = model.problem { throw ChatError.storage(problem) }
                                }
                        }.buttonStyle(PopupDestructiveButtonStyle())
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.chromeHover.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.chromeHairline))
            }
            Text("Closing a device session affects the whole server, every organization on it included.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("organization-devices")
        .task { if model.devices == nil { await model.load() } }
    }
}

private struct ChatOrgAuditTab: View {
    let model: ChatOrgModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OrganizationSectionHeading(title: "Security Log", subtitle: "Audit · Organization activity and access changes.")
            Button("Refresh") { Task { await model.loadAudit() } }
            ForEach(model.audit ?? []) { record in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(record.action) · \(record.result)").font(.subheadline.weight(.semibold))
                    Text("\(OrganizationTabs.readableDate(record.at)) · \(record.actorAccountId.flatMap { model.member($0)?.name } ?? record.actorAccountId ?? "operator") · \(record.object ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
            }
            if model.auditNext != nil {
                Button("Older") { Task { await model.loadAudit(more: true) } }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("organization-audit")
        .task { if model.audit == nil { await model.loadAudit() } }
    }
}

private struct OrganizationSectionHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}
