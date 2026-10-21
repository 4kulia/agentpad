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
    /// Called after the startup choice, before any workspace or runtime can be
    /// made (including the runtime used by glass backing).
    func loadConfiguration(load: () -> Void) {
        guard !configurationLoaded else { return }
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
    var telegramSettings: () -> TelegramSettingsViewModel = { TelegramService.settings }
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
        case .telegram(let id): return AnyView(TelegramConversationView(state: state, id: id).id(id))
        case .directMessage(let ref): return AnyView(ChatDMTab(state: state, ref: ref))
        case .directMessageDraft(let key, let peer): return AnyView(ChatDMPeerTab(state: state, scope: key, peer: peer))
        case .newDM(let key): return AnyView(ChatDMNewView(state: state, scope: key))
        case .search:
            if let store = owner(state)?.store { return AnyView(SearchResultsTab(model: store.search, state: state, store: store)) }
            return AnyView(Text("Search is available in its window."))
        case .allSessions:
            if state.allSessionsModel == nil { state.allSessionsModel = AllSessionsModel(state: state) }
            return AnyView(AllSessionsTab(model: state.allSessionsModel!, owner: { [weak self, weak state] in
                guard let state else { return nil }; return self?.owner(state)?.store
            }))
        case .agentProfile(let id):
            if let store = owner(state)?.store, let profile = store.agentProfiles.profile(id) {
                if state.profileEditor == nil { state.profileEditor = AgentProfileEditor(profile: profile, profiles: store.agentProfiles) }
                return AnyView(AgentProfileEditorView(state: state, editor: state.profileEditor!))
            }
            return AnyView(Text("This agent is no longer available."))
        case .agent: return AnyView(AgentTab(state: state, tabs: .shared))
        case .ask: return AnyView(PersonalAskTab(state: state, model: CompositionTabs.shared.askModel(state)))
        case .newChannel: return AnyView(NewChannelTab(model: CompositionTabs.shared.channelModel(state)))
        case .forward: return AnyView(ForwardTab(state: state, tabs: .shared))
        case .viewer, .dmViewer: return AnyView(AttachmentViewerTab(model: CompositionTabs.shared.viewerModel(state)))
        case .connection:
            return AnyView(ConnectionTabView(state: state, tabs: .shared))
        case .fileOperations:
            if state.fileOperation == nil, let snapshot = state.navigation.fileTransfer {
                state.fileOperation = FileTransferBatch(snapshot, state: state, tabID: owner(state)?.session.id ?? UUID(), restored: true)
            }
            if let batch = state.fileOperation { return AnyView(FileOperationTab(batch: batch)) }
            return AnyView(Text("Interrupted. Start a new file operation after reviewing the files."))
        case .closeWorkspaces:
            if let batch = state.closeWorkspaces { return AnyView(CloseWorkspacesView(batch: batch)) }
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
        case .newAgent:
            return AnyView(NewAgentFormView(state: state, tabs: .shared, form: LocalFormTabs.shared.form(state)))
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
                }, telegram: telegramSettings())
                .environment(\.popupCoordinator, owner(state)?.store.popups))
        case .notifications:
            return AnyView(NotificationTabView(state: state, support: self))
        case .linkFailure:
            return AnyView(LinkFailureView(reason: state.message ?? LinkFailureMessage.unavailable.text,
                close: { [weak self, weak state] in
                    guard let self, let state, let owner = self.owner(state) else { return }
                    owner.store.popups.dismiss(owner.session, reason: .applied)
                },
                openInbox: { [weak self, weak state] in
                    guard let self, let state else { return }
                    self.navigation.open(.notifications, from: self.owner(state)?.store)
                }))
        case .unavailable:
            if let owner = owner(state), let block = owner.session.remoteClaudeAccountBlock {
                let current = RemoteClaudeAccountBlock(accountID: block.accountID, accountName: block.accountName,
                    host: block.host, status: owner.store.agentProfiles.remoteClaudeAccounts.state(accountID: block.accountID, host: block.host),
                    profileName: block.profileName, folder: block.folder)
                return AnyView(RemoteClaudeAccountBlockedView(block: current, onInstall: {
                    owner.store.openRemoteClaudeAccountInstall(accountID: block.accountID, host: block.host, profileName: block.profileName,
                        onInstalled: owner.store.remoteClaudeAccountStartAfterInstall(sessionID: owner.session.id,
                            accountID: block.accountID, host: block.host))
                }, onManage: { owner.store.openRemoteClaudeAccountManagement(accountID: block.accountID) },
                    onStart: { owner.store.retryRemoteClaudeAccount(sessionID: owner.session.id) },
                    onRetry: { owner.store.retryRemoteClaudeAccount(sessionID: owner.session.id) }))
            }
            return AnyView(VStack(spacing: 12) {
                Label(state.route.title, systemImage: state.route.symbol).font(.title2)
                Text(state.message ?? "This screen is not available in this version.").foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity))
        default:
            return AnyView(VStack(spacing: 12) {
                Label(state.route.title, systemImage: state.route.symbol).font(.title2)
                Text(state.message ?? "This screen is not available in this version.").foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity))
        }
    }
    func owner(_ state: TabState) -> TabRouter.Location? {
        navigation.router.owner(of: state)
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
        session.applyTerminalTitle("settings.json")
        location.store.popups.dismiss(reason: .dismiss)
    }
}

struct NotificationTabView: View {
    @Bindable var state: TabState
    let support: SupportTabs
    private var repository: DraftRepository? { support.owner(state)?.store.drafts }
    private var openDraftIDs: Set<UUID> {
        let sessions = support.navigation.router.stores().filter { !$0.isTerminated }.flatMap { store -> [Session] in
            let pages = store.popups.backStack + (store.popups.page.map { [$0] } ?? [])
            let presented = pages.compactMap { page -> Session? in
                if case .tool(let session) = page { return session }
                return nil
            }
            return store.allSessions + presented
        }
        return Set(sessions.compactMap { $0.tabState?.navigation.draftID })
    }
    private var drafts: [TabDraft] {
        (repository?.drafts ?? []).filter { !openDraftIDs.contains($0.id) && Self.mayRead($0) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private var runtimeDrafts: [(owner: WorkspaceStore, page: PopupCoordinator.Page)] {
        support.navigation.router.stores().filter { !$0.isTerminated }.flatMap { store in
            store.popups.retainedRuntimeDrafts.filter { page in
                if case .tool(let session) = page { return Self.mayRead(scope: session.toolRoute?.organizationScope) }
                return true
            }.map { (owner: store, page: $0) }
        }
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
                Text("Drafts (\(drafts.count + runtimeDrafts.count))").tag("drafts")
            }.pickerStyle(.segmented).padding(16).accessibilityIdentifier("notifications-sections")
            if selection.wrappedValue == "drafts" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if drafts.isEmpty && runtimeDrafts.isEmpty { Text("No saved drafts").foregroundStyle(.secondary) }
                        ForEach(runtimeDrafts, id: \.page.id) { draft in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(draft.page.title).font(.headline)
                                Text("Kept until AgentPad quits").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Open draft") {
                                        draft.owner.popups.reopenRuntimeDraft(draft.page)
                                        support.navigation.router.revealWindow(draft.owner)
                                    }
                                    Button("Discard…", role: .destructive) { discardRuntime(draft.page, owner: draft.owner) }
                                        .disabled(runtimeBusy(draft.page))
                                }
                            }
                        }
                        ForEach(drafts) { draft in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(draft.route.title).font(.headline)
                                HStack {
                                    Button("Open draft") {
                                        open(draft)
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
    private func runtimeBusy(_ page: PopupCoordinator.Page) -> Bool {
        if case .tool(let session) = page { return session.tabState?.connectionForm?.busy == true }
        return false
    }
    private func discardRuntime(_ page: PopupCoordinator.Page, owner: WorkspaceStore) {
        guard let location = support.owner(state) else { return }
        state.confirmation.request(.init(tabID: location.session.id, targetID: String(describing: page.id)),
            title: "Discard \(page.title) draft?", consequences: "The unfinished form will be cleared from this window.",
            verb: "Discard draft", destructive: true, stillValid: {
                !owner.isTerminated && !runtimeBusy(page) && runtimeDrafts.contains { $0.page.id == page.id }
            }) { try owner.popups.discardRuntimeDraft(page) }
    }
    private func open(_ draft: TabDraft) {
        guard Self.mayRead(draft), let repository, repository.draft(draft.id) == draft else { return }
        // A shared draft archive can be shown from another window. Reuse the
        // retained form in its owner instead of creating a competing copy.
        let retainedOwner = support.navigation.router.stores().first { store in
            !store.isTerminated && store.drafts === repository
                && store.popups.sessions.contains { $0.tabState?.draft == draft }
        }
        guard let target = retainedOwner ?? support.owner(state)?.store else { return }
        if let cached = target.popups.find(draft.route)?.session, let cachedState = cached.tabState,
           let older = cachedState.draft, older.id == draft.id, older.revision < draft.revision,
           cachedState.savedRevision == older.revision {
            // Another window saved a newer revision. Retire only this saved
            // cache, preserving both the newer archive and any unsaved forms.
            cachedState.draft = nil
            cachedState.navigation.draftID = nil
            target.popups.dismiss(cached, reason: .applied)
        }
        support.navigation.open(draft.route, from: target)
    }
    private func discard(_ draft: TabDraft) {
        guard let owner = support.owner(state), let repository else { return }
        state.confirmation.request(.init(tabID: owner.session.id, targetID: draft.id.uuidString,
            scope: draft.route.organizationScope, revision: String(draft.revision)),
            title: "Discard \(draft.route.title) draft?", consequences: "The saved local text will be deleted.", verb: "Discard draft",
            destructive: true, stillValid: { repository.draft(draft.id) == draft && !openDraftIDs.contains(draft.id) && Self.mayRead(draft) }) {
                try repository.discard(draft.id)
                for store in support.navigation.router.stores() where !store.isTerminated && store.drafts === repository {
                    for session in store.popups.sessions where session.tabState?.navigation.draftID == draft.id {
                        // The archive write succeeded. Remove the retained form
                        // without another draft write, so a later save cannot
                        // resurrect the text the user explicitly discarded.
                        session.tabState?.draft = nil
                        session.tabState?.navigation.draftID = nil
                        store.popups.dismiss(session, reason: .cancel)
                    }
                }
            }
    }
    static func mayRead(_ draft: TabDraft) -> Bool {
        let scope: OrgKey?
        if case .forwardForm(let fields) = draft.payload { scope = fields.destination }
        else if case .forward(_, _, let destination, _, _, _) = draft.payload { scope = destination }
        else { scope = draft.route.organizationScope }
        return mayRead(scope: scope)
    }
    private static func mayRead(scope: OrgKey?) -> Bool {
        guard let scope else { return true }
        guard let model = ChatOrgCurrent.shared.model, model.isCurrent(), model.visible, !model.inDoubt, !model.snapshotOwed(),
              let key = model.key else { return false }
        return OrgKey(key) == scope
    }
}

extension ToolRoute {
    var organizationScope: OrgKey? {
        switch self {
        case .directMessageDraft(let key, _), .newDM(let key), .organization(let key), .agent(let key, _), .ask(let key, _), .newChannel(let key, _, _), .viewer(let key, _, _, _), .dmViewer(let key, _, _, _): return key
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
    let close: () -> Void
    let openInbox: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            PopupScrollBody {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "info.circle").foregroundStyle(.orange).accessibilityHidden(true)
                    Text(reason).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("OK", action: close).accessibilityIdentifier("link-failure-ok")
                Spacer()
                Button("Open Notifications", action: openInbox)
                    .buttonStyle(PopupPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("link-failure-notifications")
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("link-failure-content")
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
