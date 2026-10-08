import SwiftUI

struct OrganizationDraft: Codable, Equatable {
    var name = ""
    var newTeam = ""
    var email = ""
    var role = "member"
    var teams: Set<String> = []
    var renameTeamID: String?
    var renameText = ""
}

@MainActor @Observable
final class OrganizationFormState {
    var fields = OrganizationDraft() { didSet { changed(fields) } }
    var error: String?
    var renameError: String?
    @ObservationIgnored var changed: (OrganizationDraft) -> Void = { _ in }

    static func form(_ state: TabState, model: ChatOrgModel?) -> OrganizationFormState {
        if let form = state.organizationForm { return form }
        let form = OrganizationFormState()
        if case .organizationForm(let fields) = state.draft?.payload { form.fields = fields }
        else { form.fields.name = model?.member(model?.me ?? "")?.name ?? "" }
        form.changed = { [weak state] fields in
            guard let state else { return }
            state.confirmation.invalidate(); state.edit(.organizationForm(fields))
        }
        state.organizationForm = form
        state.discardEdits = { [weak state, weak form] in
            guard let state, let form else { return }
            let changed = form.changed; form.changed = { _ in }
            if case .organizationForm(let fields) = state.draft?.payload { form.fields = fields }
            else { form.fields = OrganizationDraft() }
            form.changed = changed; form.error = nil; form.renameError = nil
        }
        return form
    }
    func rename(_ team: ChatOrgView.Team, model: ChatOrgModel) {
        do {
            guard !fields.renameText.trimmingCharacters(in: .whitespaces).isEmpty else { throw ChatError.storage("Enter a team name.") }
            if let problem = InlineNameEdit.problem(fields.renameText) { throw ChatError.storage(problem) }
            try model.renameTeam(team, to: fields.renameText)
            fields.renameTeamID = nil; renameError = nil
        } catch { renameError = error.localizedDescription }
    }
}

@MainActor
enum OrganizationTabs {
    @discardableResult
    static func show(key: OrgKey? = nil) -> Session? {
        guard let key = key ?? ChatService.shared.connection?.orgKey.map(OrgKey.init) else {
            return TeamTabs.shared.showActivity()
        }
        return SupportTabs.shared.navigation.open(.organization(key))
    }
    static func confirm(_ state: TabState, target: String, title: String, text: String, verb: String,
                        destructive: Bool = false, requiresOrganization: Bool = true, valid: @escaping @MainActor () -> Bool,
                        operation: @escaping @MainActor () async throws -> Void) {
        guard let owner = TeamTabs.shared.owner(state) else { return }
        let identity = TeamTabs.shared.connectionIdentity()
        request(state, tabID: owner.session.id, generation: identity, target: target, title: title, text: text, verb: verb,
                destructive: destructive, valid: {
                    TeamTabs.shared.connectionIdentity() == identity && valid()
                        && (!requiresOrganization || state.route.organizationScope.map { TeamTabs.shared.canRead(.server($0)) } == true)
                }, operation: operation)
    }
    /// The same entry is directly testable without an AppKit window.
    static func request(_ state: TabState, tabID: TabID, generation: String? = nil, target: String, title: String, text: String, verb: String,
                        destructive: Bool = false, valid: @escaping @MainActor () -> Bool,
                        operation: @escaping @MainActor () async throws -> Void) {
        state.confirmation.request(.init(tabID: tabID, targetID: target, scope: state.route.organizationScope,
            generation: generation, deadline: Date().addingTimeInterval(120)),
            title: title, consequences: text, verb: verb, destructive: destructive,
            stillValid: { !state.isClosed && valid() }, operation: operation)
    }
}

struct OrganizationTabView: View {
    let state: TabState
    let key: OrgKey
    private var current: ChatOrgCurrent { .shared }
    private var model: ChatOrgModel? {
        guard let model = current.model, model.key.map(OrgKey.init) == key else { return nil }
        return model
    }
    private var devices: ChatDevicesModel? {
        guard let connection = ChatService.shared.connection,
              connection.server == key.server, connection.accountId == key.accountID else { return nil }
        return current.devices
    }
    var body: some View {
        Group {
            if let model, model.visible, !model.inDoubt, !model.snapshotOwed(), !model.showsOffline() {
                ChatOrgTabContent(state: state, form: OrganizationFormState.form(state, model: model), model: model, devices: devices)
            } else if state.navigation.selection == AttentionOrganizationSection.devices.rawValue, let devices {
                // Device sessions belong to the whole server, even after losing org membership.
                ChatOrgDevicesTab(model: devices, state: state)
            } else {
                VStack(spacing: 12) {
                    Text("Connect to this organization and wait for access to be checked.").foregroundStyle(.secondary)
                    Button("Connect to a Server…") { ConnectionTabs.shared.show() }
                    if devices != nil { Button("Devices on this server") { selectDevices() } }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ChatOrgCurrent.identity()) { current.refresh() }
        .onChange(of: AttentionSelection.shared.revision, initial: true) { _, _ in
            if case .organization(let org, let section?) = AttentionSelection.shared.destination, org == key.orgID {
                state.confirmation.invalidate(); state.navigation.selection = section.rawValue; state.changed()
            }
        }
    }
    private func selectDevices() {
        state.confirmation.invalidate(); state.navigation.selection = AttentionOrganizationSection.devices.rawValue; state.changed()
    }
}
