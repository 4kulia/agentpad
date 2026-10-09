import AppKit
import SwiftUI

/// The gate is deliberately independent of SettingsModel and any NSWindow.
/// Requests made inside the existing startup step cannot begin autosaving.
@MainActor
final class SupportTabNavigation {
    let router: TabRouter
    private(set) var ready = false
    private(set) var configurationLoaded = false
    private var pending: [() -> Void] = []
    init(router: TabRouter) {
        self.router = router
        router.admit = { [weak self] in self?.admit($0) ?? false }
    }
    /// The existing startup step commits the choice before any workspace or
    /// runtime can be made (including the runtime used by glass backing).
    func loadConfiguration(onboarding: () -> Void, load: () -> Void) {
        guard !configurationLoaded else { return }
        onboarding()
        load()
        configurationLoaded = true
    }
    func admit(_ deferred: @escaping () -> Void) -> Bool {
        guard ready else { pending.append(deferred); return false }
        return true
    }
    @discardableResult
    func open(_ route: ToolRoute, from store: WorkspaceStore? = nil, section: SettingsTabSection? = nil) -> Session? {
        return router.open(route, from: store, section: section)
    }
    func finishStartup() {
        ready = true
        let requests = pending; pending.removeAll()
        for request in requests { request() }
    }
}

@MainActor @Observable
final class SettingsScreenState {
    var expandedAgentID: String?
    var expandedPresetID: String?
    var iconErrors: [String: String] = [:]
    #if DEBUG
    let diagnostics = SettingsDiagnostics()
    #endif
}

@MainActor
final class SupportTabs {
    static let shared = SupportTabs()
    let navigation: SupportTabNavigation
    var settingsModel: () -> AgentPadSettingsModel = { .shared }
    var ledger: AttentionLedger
    var updates = UpdatesTabModel()
    var activateNotice: (NotificationInbox.Event) -> Void = { _ in }
    init(router: TabRouter = .shared, ledger: AttentionLedger = .shared) {
        navigation = SupportTabNavigation(router: router); self.ledger = ledger
    }

    func install() {
        let history = ledger.metadata.markers.values.compactMap(\.locator).filter { $0.source == "link-failure" }
        ledger.upsert(history, live: { _ in false })
        NativeTabEngine.content = { [weak self] state in
            guard let self else { return AnyView(EmptyView()) }
            return self.content(state)
        }
    }
    @discardableResult
    func settings(_ section: SettingsTabSection? = nil) -> Session? {
        if navigation.ready { settingsModel().reloadIfClean() }
        return navigation.open(.settings, section: section)
    }

    func content(_ state: TabState) -> AnyView {
        switch state.route {
        case .directMessage(let ref): return AnyView(ChatDMTab(state: state, ref: ref))
        case .directMessageDraft(let key, let peer): return AnyView(ChatDMPeerTab(state: state, scope: key, peer: peer))
        case .newDM(let key): return AnyView(ChatDMNewView(state: state, scope: key))
        case .allSessions:
            if state.allSessionsModel == nil { state.allSessionsModel = AllSessionsModel(state: state) }
            return AnyView(AllSessionsTab(model: state.allSessionsModel!, owner: { [weak self, weak state] in
                guard let state else { return nil }; return self?.owner(state)?.store
            }))
        case .agent: return AnyView(AgentTab(state: state, tabs: .shared))
        case .ask: return AnyView(PersonalAskTab(state: state, model: CompositionTabs.shared.askModel(state)))
        case .newChannel: return AnyView(NewChannelTab(model: CompositionTabs.shared.channelModel(state)))
        case .forward: return AnyView(ForwardTab(state: state, tabs: .shared))
        case .viewer: return AnyView(AttachmentViewerTab(model: CompositionTabs.shared.viewerModel(state)))
        case .connection:
            return AnyView(ConnectionTabView(state: state, tabs: .shared))
        case .fileOperations:
            if state.fileOperation == nil, let snapshot = state.navigation.fileTransfer {
                state.fileOperation = FileTransferBatch(snapshot, state: state, tabID: owner(state)?.session.id ?? UUID(), restored: true)
            }
            if let batch = state.fileOperation { return AnyView(FileOperationTab(batch: batch)) }
            return AnyView(Text("Interrupted. Start a new file operation after reviewing the files."))
        case .closeWorkspaces:
            if let batch = state.closeWorkspaces { return AnyView(ScrollView { CloseWorkspacesView(batch: batch) }) }
            return AnyView(Text("This close review ended. Select the workspaces again to start a new review."))
        case .importSession:
            return AnyView(ImportSessionView(state: state))
        case .request:
            let model = RequestTabs.shared.model(state)
            state.canShowConfirmation = { model.readable }
            return AnyView(RequestTabView(state: state, model: model))
        case .organization(let key):
            state.canShowConfirmation = { [weak state] in
                if state?.navigation.selection == AttentionOrganizationSection.devices.rawValue,
                   let connection = ChatService.shared.connection {
                    return connection.server == key.server && connection.accountId == key.accountID && ChatOrgCurrent.shared.devices != nil
                }
                return TeamTabs.shared.canRead(.server(key))
            }
            return AnyView(OrganizationTabView(state: state, key: key))
        case .publishedAgents(let scope):
            state.canShowConfirmation = { TeamTabs.shared.canRead(scope) }
            return AnyView(TeamScopeView(scope: scope, tabs: .shared) {
                ScrollView { TeamAgentsView(state: state, scope: scope, tabs: .shared) }
            })
        case .publication(let scope, _), .publish(let scope, _, _, _):
            state.canShowConfirmation = { TeamTabs.shared.canRead(scope) }
            return AnyView(TeamScopeView(scope: scope, tabs: .shared) {
                TeamPublicationEditor(state: state, form: TeamTabs.shared.form(state), scope: scope, tabs: .shared)
            })
        case .teamActivity(let scope):
            state.canShowConfirmation = { TeamTabs.shared.canRead(scope) }
            return AnyView(TeamActivityTab(state: state, scope: scope, tabs: .shared))
        case .newSSH, .newWorktree, .workspaceDetails:
            return AnyView(LocalFormView(state: state, tabs: .shared, form: LocalFormTabs.shared.form(state)))
        case .files:
            return AnyView(FilesTabView(state: state, tabs: .shared))
        case .settings:
            let model = settingsModel()
            state.persistEdits = { try model.flushSaveChecked() }
            state.discardEdits = { model.discardUnsavedChanges() }
            return AnyView(AgentPadSettingsView(model: model, state: state, screen: state.settingsScreen,
                updates: updates, onOpenInTab: { [weak self, weak state] in
                    guard let self, let state else { return }; self.openSettingsFile(state)
                }))
        case .notifications:
            return AnyView(NotificationTabView(state: state, support: self))
        case .linkFailure:
            return AnyView(LinkFailureView(reason: state.message ?? LinkFailureMessage.unavailable.text,
                openInbox: { [weak self, weak state] in
                    guard let self, let state else { return }
                    self.navigation.open(.notifications, from: self.owner(state)?.store)
                }))
        default:
            return AnyView(VStack(spacing: 12) {
                Label(state.route.title, systemImage: state.route.symbol).font(.title2)
                Text(state.message ?? "This screen is not available in this version.").foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity))
        }
    }
    func owner(_ state: TabState) -> TabRouter.Location? {
        for store in navigation.router.stores() {
            if let session = store.allSessions.first(where: { $0.tabState === state }) { return navigation.router.owner(of: session.id) }
        }
        return nil
    }
    func linkFailed(_ reason: String) {
        let safe = LinkFailureMessage(reason: reason).text
        guard let tab = navigation.open(.linkFailure), let location = navigation.router.owner(of: tab.id) else { return }
        tab.tabState?.message = safe
        var notice = AttentionEvent(source: "link-failure", object: UUID().uuidString, kind: .failure,
            destination: .linkFailure(windowID: location.store.windowID))
        notice.localTitle = "Link could not be opened"
        notice.localBody = safe
        ledger.upsert(notice)
    }
    func noticeUnavailable() {
        navigation.open(.notifications)?.tabState?.message = "This item is no longer available or no longer needs a decision."
    }
    private func openSettingsFile(_ state: TabState) {
        guard let location = owner(state) else { return }
        let model = settingsModel()
        do { try model.flushSaveChecked() }
        catch { state.saveError = error.localizedDescription; return }
        let template = AgentTemplate(id: "agentpad-settings-editor", title: "settings.json", symbol: "doc.text", iconAsset: nil,
            tintHex: nil, initialCommand: "${EDITOR:-vi} \(AgentPadShellIntegration.quote(AgentPadSettings.url.path))")
        let session = location.store.addTab(in: location.workspace, pane: location.pane, template: template)
        session.customTitle = "settings.json"
    }
}

struct NotificationTabView: View {
    @Bindable var state: TabState
    let support: SupportTabs
    private var repository: DraftRepository? { support.owner(state)?.store.drafts }
    private var openDraftIDs: Set<UUID> {
        Set(support.navigation.router.stores().flatMap(\.allSessions).compactMap { $0.tabState?.navigation.draftID })
    }
    private var drafts: [TabDraft] {
        (repository?.drafts ?? []).filter { !openDraftIDs.contains($0.id) && Self.mayRead($0) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private var selection: Binding<String> {
        Binding(get: { state.navigation.selection ?? "events" }, set: {
            state.confirmation.invalidate(); state.navigation.selection = $0; state.changed()
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            if let message = state.message {
                HStack {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss") { state.message = nil }
                }.padding(16).accessibilityIdentifier("notification-unavailable")
            }
            Picker("Notifications and drafts", selection: selection) {
                Text("Events").tag("events")
                Text("Drafts (\(drafts.count))").tag("drafts")
            }.pickerStyle(.segmented).padding(16).accessibilityIdentifier("notifications-sections")
            if selection.wrappedValue == "drafts" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if drafts.isEmpty { Text("No saved drafts").foregroundStyle(.secondary) }
                        ForEach(drafts) { draft in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(draft.route.title).font(.headline)
                                HStack {
                                    Button("Open draft") {
                                        guard Self.mayRead(draft) else { return }
                                        support.navigation.open(draft.route, from: support.owner(state)?.store)
                                    }
                                    Button("Discard…", role: .destructive) { discard(draft) }
                                }
                            }.accessibilityIdentifier("saved-draft-" + draft.id.uuidString)
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { InboxView(inbox: NotificationInbox(ledger: support.ledger), onActivate: support.activateNotice, onClear: {}) }
        }
    }
    private func discard(_ draft: TabDraft) {
        guard let owner = support.owner(state), let repository else { return }
        state.confirmation.request(.init(tabID: owner.session.id, targetID: draft.id.uuidString,
            scope: draft.route.organizationScope, revision: String(draft.revision)),
            title: "Discard \(draft.route.title) draft?", consequences: "The saved local text will be deleted.", verb: "Discard draft",
            destructive: true, stillValid: { repository.draft(draft.id) == draft && !openDraftIDs.contains(draft.id) && Self.mayRead(draft) }) {
                try repository.discard(draft.id)
            }
    }
    static func mayRead(_ draft: TabDraft) -> Bool {
        let scope: OrgKey?
        if case .forwardForm(let fields) = draft.payload { scope = fields.destination }
        else if case .forward(_, _, let destination, _, _, _) = draft.payload { scope = destination }
        else { scope = draft.route.organizationScope }
        guard let scope else { return true }
        guard let model = ChatOrgCurrent.shared.model, model.isCurrent(), model.visible, !model.inDoubt, !model.snapshotOwed(),
              let key = model.key else { return false }
        return OrgKey(key) == scope
    }
}

extension ToolRoute {
    var organizationScope: OrgKey? {
        switch self {
        case .directMessageDraft(let key, _), .newDM(let key), .organization(let key), .agent(let key, _), .ask(let key, _), .newChannel(let key, _, _), .viewer(let key, _, _, _): return key
        case .directMessage(let ref): return ref.key.map(OrgKey.init)
        case .request(let scope, _), .publishedAgents(let scope), .teamActivity(let scope), .publication(let scope, _), .publish(let scope, _, _, _):
            if case .server(let key) = scope { return key }; return nil
        default: return nil
        }
    }
}

/// No reflected URL, path, query parameter or server message is copied into UI
/// history or logs. The parser's safe explanation is classified at the boundary.
enum LinkFailureMessage: CaseIterable {
    case parameters, access, unavailable
    init(reason: String) {
        let value = reason.lowercased()
        if value.contains("connect") || value.contains("access") || value.contains("organization") { self = .access }
        else if value.contains("parameter") || value.contains("invalid") || value.contains("characters") || value.contains("too long") || value.contains("absolute path") { self = .parameters }
        else { self = .unavailable }
    }
    var text: String {
        switch self {
        case .parameters: "The link contains missing or invalid parameters. Ask for a new link."
        case .access: "Connect to the requested organization and confirm access, then open the link again."
        case .unavailable: "The requested session or message is unavailable. Check that it still exists and that you have access."
        }
    }
}

struct LinkFailureView: View {
    let reason: String
    let openInbox: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Link could not be opened", systemImage: "exclamationmark.triangle").font(.title2)
                Text(reason).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Button("Open Notifications", action: openInbox)
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("link-failure-content")
    }
}

/// The operation and result outlive the tab; returning does not check again.
@MainActor @Observable
final class UpdatesTabModel {
    private(set) var checking = false
    private(set) var outcome: UpdateChecker.Outcome?
    let currentVersion: String
    private let packaged: () -> Bool
    private let sparkleCheck: () -> Void
    private let fetch: (String) async -> UpdateChecker.Outcome
    private let attention: UpdateAttention
    init(currentVersion: String = ProcessInfo.processInfo.environment["AGENTPAD_FAKE_VERSION"] ?? AgentPadApp.displayVersion,
         packaged: @escaping () -> Bool = { AgentPadUpdater.shared.isAvailable },
         sparkleCheck: @escaping () -> Void = { AgentPadUpdater.shared.checkForUpdates() },
         attention: UpdateAttention = .shared,
         fetch: @escaping (String) async -> UpdateChecker.Outcome = { await UpdateChecker.check(currentVersion: $0) }) {
        self.currentVersion = currentVersion; self.packaged = packaged; self.sparkleCheck = sparkleCheck
        self.attention = attention; self.fetch = fetch
    }
    func check() {
        guard !checking else { return }
        if packaged() { sparkleCheck(); return }
        checking = true
        attention.beginCheck()
        Task {
            let result = await fetch(currentVersion)
            outcome = result; checking = false
            switch result {
            case .newer(let version, _, _): attention.available(version, manual: true)
            case .failed: attention.failed(shown: true)
            case .upToDate: break
            }
        }
    }
    func dismissResult() { outcome = nil; attention.chose(.later) }
}

struct SettingsUpdatesView: View {
    @Bindable var model: UpdatesTabModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AgentPad \(model.currentVersion)").font(.headline)
            Button(model.checking ? "Checking for Updates…" : "Check for Updates") { model.check() }
                .disabled(model.checking).accessibilityIdentifier("settings-check-updates")
            if model.checking { ProgressView().controlSize(.small) }
            if let outcome = model.outcome {
                UpdatePromptView(outcome: outcome, currentVersion: model.currentVersion,
                    onClose: { model.dismissResult() }, onDownload: { NSWorkspace.shared.open($0) })
            }
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-updates-content")
    }
}

/// System file pickers remain allowed, attached to the tab's current owner.
@MainActor
enum TabFilePicker {
    static func present(_ panel: NSOpenPanel, state: TabState, stillValid: @escaping () -> Bool,
                        onAccept: @escaping (URL) -> Void) {
        guard let location = SupportTabs.shared.owner(state), let window = location.session.engine.view.window else { return }
        let complete = completion(state: state, stillValid: stillValid, onAccept: onAccept)
        panel.beginSheetModal(for: window) { complete($0, panel.url) }
    }
    static func completion(state: TabState, stillValid: @escaping () -> Bool,
                           onAccept: @escaping (URL) -> Void) -> (NSApplication.ModalResponse, URL?) -> Void {
        let revision = state.revision
        return { response, url in
            guard response == .OK, let url, !state.isClosed, state.revision == revision, stillValid() else { return }
            onAccept(url)
        }
    }
}

#if DEBUG
@MainActor @Observable
final class SettingsDiagnostics {
    var name = ""
    private(set) var status: String?
    private(set) var sending = false
    func send(service: ChatService = .shared) {
        guard !sending else { return }
        guard let connection = service.connection, let key = connection.orgKey else { status = "Not signed in to a server"; return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { status = "Enter a display name."; return }
        sending = true; status = nil
        Task {
            defer { sending = false }
            do {
                guard service.connection?.orgKey == key, service.connection?.sessionId == connection.sessionId else {
                    status = "The connection changed before sending. Review the name and try again."; return
                }
                let record = try service.enqueue(key, type: "member.set_name", args: .object(["name": .string(value)]))
                let deadline = ContinuousClock.now + .seconds(15)
                var state = record.state
                while state == .pending, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(250))
                    guard service.connection?.orgKey == key, service.connection?.sessionId == connection.sessionId else {
                        status = "The connection changed. Check the command in Team activity."; return
                    }
                    state = try service.session(for: key).store?.commands().first { $0.commandId == record.commandId }?.state ?? state
                }
                status = "member.set_name: \(state.rawValue)"
            } catch { status = "member.set_name failed. Check the connection and Team activity." }
        }
    }
}

struct SettingsDiagnosticsView: View {
    @Bindable var model: SettingsDiagnostics
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics · DEBUG").font(.headline)
            Text("member.set_name changes your own display name in the connected organization.").foregroundStyle(.secondary)
            TextField("Display name", text: $model.name).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("diagnostics-display-name")
            Button("Run member.set_name") { model.send() }.disabled(model.sending)
            if let status = model.status { Text(status).textSelection(.enabled).accessibilityIdentifier("diagnostics-result") }
        }.padding(28).accessibilityElement(children: .contain).accessibilityIdentifier("settings-diagnostics")
    }
}
#endif
