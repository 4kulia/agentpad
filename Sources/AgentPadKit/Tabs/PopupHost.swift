import AppKit
import SwiftUI

/// Window-owned presentation. Sessions retain the existing form models outside
/// runtime panes. File-operation recovery reuses its existing persisted tab
/// carrier, then restores the operation into this popup coordinator.
@MainActor @Observable
final class PopupCoordinator {
    enum DismissReason { case dismiss, cancel, applied }
    /// Runtime content from the native surfaces in the approved Inventory. It
    /// shares this host's ownership, focus, sizing, Back and draft lifecycle.
    @MainActor @Observable final class NativePage {
        var title: String
        let width: CGFloat
        var contentHeight: CGFloat?
        var viewportHeight: CGFloat?
        var maximumBodyHeight: CGFloat = 520
        @ObservationIgnored var keepsDraft: () -> Bool
        @ObservationIgnored var locksDismissal: () -> Bool
        @ObservationIgnored var onDismiss: (DismissReason) -> Void
        @ObservationIgnored var content: () -> AnyView
        @ObservationIgnored fileprivate var active = false
        init(title: String, width: CGFloat = 580, keepsDraft: @escaping () -> Bool = { false },
             locksDismissal: @escaping () -> Bool = { false },
             onDismiss: @escaping (DismissReason) -> Void = { _ in },
             content: @escaping () -> AnyView = { AnyView(EmptyView()) }) {
            self.title = title; self.width = width; self.keepsDraft = keepsDraft; self.locksDismissal = locksDismissal
            self.onDismiss = onDismiss; self.content = content
        }
    }
    @MainActor enum Page {
        case tool(Session)
        case conversation(Session)
        case account(ClaudeAccountForm)
        case confirmation(ConfirmationCoordinator)
        case native(NativePage)
        var id: ObjectIdentifier {
            switch self {
            case .conversation(let session): ObjectIdentifier(session)
            case .tool(let session): ObjectIdentifier(session)
            case .account(let form): ObjectIdentifier(form)
            case .confirmation(let confirmation): ObjectIdentifier(confirmation)
            case .native(let page): ObjectIdentifier(page)
            }
        }
        var title: String {
            switch self {
            case .conversation(let session): session.conversationTitle
            case .tool(let session):
                if case .ask = session.toolRoute { session.tabState?.askForm?.receiptTitle ?? "Ask agent" }
                else { session.toolRoute?.title ?? "" }
            case .account(let form): form.isReplacing ? "Replace Claude token" : "Add Claude account"
            case .confirmation(let confirmation): confirmation.title
            case .native(let page): page.title
            }
        }
        var presentationTitle: String {
            switch self {
            case .conversation(let session): return session.conversationTitle
            case .tool(let session):
                if let state = session.tabState, state.presentsPopupDecision {
                    if case .fileOperations = state.route { return "Replace file" }
                    if state.confirmation.verb == "Remove member" { return "Remove member" }
                    return state.confirmation.title
                }
                return switch session.toolRoute {
                case .ask: session.tabState?.askForm?.receiptTitle ?? "Ask agent"
                case .connection:
                    switch session.tabState?.connectionForm?.step {
                    case .code: "Verification code"
                    case .chooseOrg, .noOrganization: "Choose organization"
                    case .name: "Your name"
                    case .done: "Connected"
                    default: "Server + email"
                    }
                case .request:
                    if session.tabState?.requestForm?.folders.isEmpty == false { "Folder permission" }
                    else if session.tabState?.requestForm?.request?.publication == "awaiting_publish" { "Publish result" }
                    else if session.tabState?.requestForm?.canDecide == true { "Request approval" }
                    else { "Request" }
                case .workspaceDetails where session.tabState?.navigation.selection == "close": "Close workspaces"
                case .publish: "Publish agent"
                case .agent: "Published agent card"
                case .fileOperations:
                    session.tabState?.fileOperation?.conflict == nil ? "File operations progress" : "File conflict"
                default: session.toolRoute?.title ?? ""
                }
            case .account(let form): return form.isReplacing ? "Replace Claude token" : "Add Claude account"
            case .confirmation(let confirmation): return confirmation.title
            case .native(let page): return page.title
            }
        }
        var keepsDraft: Bool {
            switch self {
            case .conversation(let session): session.hasConversationDraft
            case .tool(let session):
                switch session.toolRoute {
                case .settings, .linkFailure, .fileOperations, .importSession, .closeWorkspaces: false
                default: true
                }
            case .account: true
            case .confirmation: false
            case .native(let page): page.keepsDraft()
            }
        }
    }
    private(set) var page: Page?
    private(set) var backStack: [Page] = []
    private(set) var sessions: [Session] = []
    private(set) var draftKept = false
    var showConversationPicker = false { didSet { syncGate() } }
    private(set) var conversationSaving = false
    private(set) var conversationSaveError: String?
    private(set) var conversationDraftReceipt: String?
    @ObservationIgnored private weak var receiptConversation: Session?
    @ObservationIgnored private var pendingConversationTransition: (() -> Void)?
    @ObservationIgnored private var conversationSaveTask: Task<Void, Never>?
    var confirmationContentHeight: CGFloat?
    @ObservationIgnored private weak var store: WorkspaceStore?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private weak var opener: NSResponder?
    @ObservationIgnored private let overlayID = UUID()
    private var kept: Set<ObjectIdentifier> = []
    private var accountForms: [UUID: ClaudeAccountForm] = [:]
    private var nativePages: [NativePage] = []
    @ObservationIgnored private var added: [ObjectIdentifier: (ClaudeAccount) -> Void] = [:]
    private let newAccountID = UUID()
    let claudeAccountSSHSelection = ClaudeAccountSSHSelection()

    init(store: WorkspaceStore? = nil) { self.store = store }
    var ownerStore: WorkspaceStore? { store }
    var isPresented: Bool { page != nil }
    var visibleConversation: Session? {
        guard case .conversation(let session) = page else { return nil }
        return session
    }
    var presentedConversations: [Session] {
        (backStack + (page.map { [$0] } ?? [])).compactMap {
            if case .conversation(let session) = $0 { return session }; return nil
        }
    }
    var showsDraftNotice: Bool {
        guard draftKept else { return false }
        if case .conversation(let session) = page { return session.hasConversationDraft }
        if case .native(let page) = page { return page.keepsDraft() }
        guard case .tool(let session) = page else { return true }
        if session.tabState?.presentsPopupDecision == true { return false }
        if session.tabState?.isCloseWorkspacesReview == true { return false }
        switch session.toolRoute {
        case .connection: return session.tabState?.connectionForm?.step != .done
        case .ask: return session.tabState?.askForm?.sentRequest == nil
        case .request:
            guard case .reason(let reason) = session.tabState?.draft?.payload else { return false }
            return !reason.isEmpty
        case .agent, .linkFailure, .fileOperations, .importSession, .closeWorkspaces: return false
        default: return true
        }
    }
    /// These forms already live in the window's retained runtime models. The
    /// notification list exposes them without adding a persisted payload.
    var retainedRuntimeDrafts: [Page] {
        let presented = Set(backStack.map(\.id) + (page.map { [$0.id] } ?? []))
        let forms = sessions.compactMap { session -> Page? in
            guard let state = session.tabState, state.draft == nil else { return nil }
            switch state.route {
            case .connection: guard state.connectionForm != nil else { return nil }
            case .newDM: guard state.newDMModel != nil else { return nil }
            case .ask: guard let ask = state.askForm, ask.sentRequest == nil, !ask.prompt.isEmpty else { return nil }
            default: return nil
            }
            return .tool(session)
        } + accountForms.values.map(Page.account) + nativePages.filter { $0.keepsDraft() }.map(Page.native)
        return forms.filter { kept.contains($0.id) && !presented.contains($0.id) }
            .sorted { $0.title < $1.title }
    }
    func reopenRuntimeDraft(_ draft: Page) {
        guard retainedRuntimeDrafts.contains(where: { $0.id == draft.id }) else { return }
        show(draft)
    }
    func discardRuntimeDraft(_ draft: Page) throws {
        guard retainedRuntimeDrafts.contains(where: { $0.id == draft.id }) else { return }
        switch draft {
        case .conversation: break // Chat drafts keep their backend's own discard actions.
        case .tool(let session):
            guard session.tabState?.connectionForm?.busy != true else { return }
            try session.tabState?.askForm?.discard()
            dismiss(session, reason: .cancel)
        case .account(let form):
            form.cancel()
            accountForms = accountForms.filter { $0.value !== form }
            added[draft.id] = nil; kept.remove(draft.id)
        case .confirmation: break
        case .native(let page): dismiss(page, reason: .cancel)
        }
    }
    var canGoBack: Bool { !backStack.isEmpty && !locksDismissal }
    var locksDismissal: Bool {
        if conversationSaving { return true }
        switch page {
        case .confirmation: return true
        case .conversation(let session):
            let confirmation = session.channelConversation?.confirmation ?? session.tabState?.confirmation
            return confirmation?.destructive == true && confirmation?.showsBlock == true
        case .native(let native): return native.locksDismissal()
        case .tool(let session):
            if let state = session.tabState, state.isCloseWorkspacesReview { return state.closeWorkspaces?.completed != true }
            return session.tabState?.confirmation.destructive == true && session.tabState?.confirmation.showsBlock == true
        default: return false
        }
    }
    func contains(_ id: UUID) -> Bool {
        sessions.contains { $0.id == id && (!$0.content.isConversation || $0.isConversationPopup || store?.allSessions.contains(where: { $0.id == id }) != true) }
    }
    func find(_ route: ToolRoute) -> TabRouter.Location? {
        guard let session = sessions.first(where: { $0.toolRoute == route }) else { return nil }
        return location(of: session.id)
    }
    func location(of id: UUID) -> TabRouter.Location? {
        guard let store, contains(id), let session = sessions.first(where: { $0.id == id }),
              let workspace = store.active ?? store.workspaces.first,
              let pane = workspace.activePane ?? workspace.root.firstPane else { return nil }
        return .init(store: store, workspace: workspace, pane: pane, session: session)
    }

    private func conversation(_ content: TabContent) -> Session? {
        guard content.isConversation, let store else { return nil }
        if let current = visibleConversation, current.content == content { return current }
        let local = store.allSessions.sorted {
            if $0.lastActivated != $1.lastActivated { return $0.lastActivated > $1.lastActivated }
            return $0.id.uuidString < $1.id.uuidString
        }
        if let existing = (local + sessions).first(where: { $0.content == content && $0.tabState?.isClosed != true }) {
            return existing
        }
        let workspace = store.active ?? store.addEmptyWorkspace()
        switch content {
        case .channel(let ref): return store.makeChannelSession(ref, cwd: workspace.workingDirectory)
        case .tool(let route): return store.makeToolSession(route, cwd: workspace.workingDirectory)
        default: return nil
        }
    }
    @discardableResult func presentConversation(_ content: TabContent) -> Session? {
        guard !locksDismissal, let session = conversation(content), presentConversation(session) else { return nil }
        return session
    }
    @discardableResult func presentConversation(_ session: Session) -> Bool {
        guard session.content.isConversation, !locksDismissal else { return false }
        session.conversationPopupSource = nil
        if !sessions.contains(where: { $0 === session }) { sessions.append(session) }
        if let native = session.engine as? NativeTabEngine { native.owner = store }
        if page?.id == ObjectIdentifier(session) { showConversationPicker = false; return true }
        show(.conversation(session))
        return true
    }
    @discardableResult func openConversationAsTab(_ content: TabContent) -> Session? {
        guard !locksDismissal, let session = conversation(content), let store else { return nil }
        afterSavingConversations { [weak self, weak store] in
            guard let self, let store else { return }
            self.dismissSaved(reason: .dismiss)
            guard !self.isPresented else { return }
            session.setConversationPopup(false)
            self.sessions.removeAll { $0 === session }
            self.kept.remove(ObjectIdentifier(session))
            self.conversationDraftReceipt = nil; self.receiptConversation = nil
            store.adoptConversationTab(session)
        }
        return session
    }
    func promoteConversation() {
        guard let session = visibleConversation else { return }
        _ = openConversationAsTab(session.content)
    }
    func reopenConversationDraft() {
        guard let session = receiptConversation else { return }
        _ = presentConversation(session.content)
    }
    /// The backend's existing logout/revocation path also owns retained popup
    /// sessions. It must not leave an old account's view or observer alive.
    func forgetConversation(_ session: Session) {
        guard session.content.isConversation, sessions.contains(where: { $0 === session }) else { return }
        if presentedConversations.contains(where: { $0 === session }) {
            conversationSaveTask?.cancel(); conversationSaveTask = nil
            conversationSaving = false; pendingConversationTransition = nil; conversationSaveError = nil
        }
        if visibleConversation === session { dismissSaved(reason: .applied) }
        backStack.removeAll { $0.id == ObjectIdentifier(session) }
        session.setConversationPopup(false)
        sessions.removeAll { $0 === session }; kept.remove(ObjectIdentifier(session))
        if store?.allSessions.contains(where: { $0 === session }) != true { session.engine.terminate() }
        syncGate()
    }
    /// Explicit content commands can be asynchronous only while a Telegram
    /// draft is being flushed. Do not select a covered tab on a failed save.
    func leaveForContent(_ action: @escaping () -> Void) {
        guard !locksDismissal else { return }
        afterSavingConversations { [weak self] in
            guard let self else { return }
            self.dismissSaved(reason: .dismiss)
            guard !self.isPresented else { return }
            action()
        }
    }
    func retryConversationSave() {
        guard let pendingConversationTransition, !conversationSaving else { return }
        afterSavingConversations(pendingConversationTransition)
    }
    private func afterSavingConversations(_ action: @escaping () -> Void) {
        guard !conversationSaving else { return }
        let conversations = presentedConversations
        pendingConversationTransition = action
        do { for session in conversations { try session.flushConversationDrafts() } }
        catch { conversationSaveError = error.localizedDescription; return }
        let telegram = conversations.compactMap { $0.tabState?.telegramModel }.filter(\.hasUnsavedDraft)
        guard !telegram.isEmpty else {
            conversationSaveError = nil; pendingConversationTransition = nil; action(); return
        }
        conversationSaving = true
        conversationSaveTask = Task { [weak self] in
            do {
                for model in telegram { try await model.flushDraft() }
                guard let self, !Task.isCancelled else { return }
                self.conversationSaving = false; self.conversationSaveError = nil
                self.pendingConversationTransition = nil; self.conversationSaveTask = nil
                action()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.conversationSaving = false; self.conversationSaveTask = nil
                self.conversationSaveError = error.localizedDescription
            }
        }
    }
    @discardableResult
    func present(_ route: ToolRoute, navigation: TabNavigation = TabNavigation()) -> Session {
        precondition(route.presentation == .popup)
        guard let store else { preconditionFailure("Popup owner has closed") }
        let session: Session
        if let existing = sessions.first(where: { $0.toolRoute == route }) { session = existing }
        else {
            let workspace = store.active ?? store.addEmptyWorkspace()
            session = store.makeToolSession(route, navigation: navigation, cwd: workspace.workingDirectory)
            session.tabState?.isPopup = true
            sessions.append(session)
            configure(session)
            if session.tabState?.draft != nil { kept.insert(ObjectIdentifier(session)) }
        }
        show(.tool(session))
        return session
    }
    private func configure(_ session: Session) {
        guard let state = session.tabState else { return }
        state.confirmation.canShow = { [weak self, weak session] in
            guard let self, let session, case .tool(let visible) = self.page else { return false }
            return visible === session && self.window?.isKeyWindow == true
        }
        state.confirmation.reveal = { [weak self, weak session] in
            guard let self, let route = session?.toolRoute else { return false }
            self.present(route); self.window?.makeKeyAndOrderFront(nil); return true
        }
    }
    func presentSettings(section: SettingsTabSection) {
        present(.settings).tabState?.select(section)
    }
    func presentAccount(profiles: AgentProfileStore, replacing: UUID? = nil, onAdded: ((ClaudeAccount) -> Void)? = nil) {
        let key = replacing ?? newAccountID
        let form = accountForms[key] ?? ClaudeAccountForm(profiles: profiles, replacing: replacing)
        accountForms[key] = form
        added[ObjectIdentifier(form)] = onAdded
        show(.account(form))
    }
    @discardableResult func presentNative(_ native: NativePage) -> Bool {
        show(.native(native))
        guard page?.id == ObjectIdentifier(native) else { return false }
        if !nativePages.contains(where: { $0 === native }) { nativePages.append(native) }
        native.active = true
        return true
    }
    func dismiss(_ native: NativePage, reason: DismissReason) {
        if page?.id == ObjectIdentifier(native) { dismiss(reason: reason); return }
        guard nativePages.contains(where: { $0 === native }) else { return }
        backStack.removeAll { $0.id == ObjectIdentifier(native) }
        finishNative(native, reason: reason)
    }
    private func finishNative(_ native: NativePage, reason: DismissReason) {
        if native.active || reason != .dismiss {
            native.active = false
            native.onDismiss(reason)
        }
        if reason != .dismiss || !native.keepsDraft() {
            kept.remove(ObjectIdentifier(native))
            nativePages.removeAll { $0 === native }
        }
    }
    func completeAccount(_ account: ClaudeAccount, form: ClaudeAccountForm) {
        added.removeValue(forKey: ObjectIdentifier(form))?(account)
        dismiss(reason: .applied)
    }
    func openTerminal() {
        guard let store else { return }
        dismiss(reason: .dismiss)
        guard !isPresented else { return }
        let workspace = store.active ?? store.addEmptyWorkspace()
        _ = store.addTab(in: workspace, template: .terminal)
    }
    func presentConfirmation(title: String, message: String, verb: String, action: @escaping () throws -> Void) {
        confirmationContentHeight = nil
        let confirmation = ConfirmationCoordinator()
        confirmation.canShow = { [weak self, weak confirmation] in
            guard case .confirmation(let visible) = self?.page else { return false }
            return visible === confirmation
        }
        confirmation.request(.init(tabID: UUID(), targetID: title), title: title, consequences: message,
            verb: verb, destructive: true, stillValid: { true }, completion: { [weak self] accepted in
                if accepted { self?.dismiss(reason: .applied) }
            }, operation: { try action() })
        show(.confirmation(confirmation))
    }
    /// Quick matches can navigate before presenting a popup. Keep the same
    /// window-owned opener for the whole synchronous action; content-only
    /// actions must not leave a stale opener for a later popup.
    func performSearchAction<Result>(_ action: () -> Result) -> Result {
        captureOpenerAndDismissSearch()
        defer { if !isPresented { opener = nil } }
        return action()
    }
    private func captureOpenerAndDismissSearch() {
        if page == nil, opener == nil {
            if let editor = window?.firstResponder as? NSTextView, let field = editor.delegate as? NSView { opener = field }
            else { opener = window?.firstResponder }
        }
        store?.searchModel?.dismiss()
    }
    private func show(_ next: Page) {
        guard page?.id != next.id, !locksDismissal else { return }
        if !presentedConversations.isEmpty {
            afterSavingConversations { [weak self] in self?.showSaved(next) }
        } else { showSaved(next) }
    }
    private func showSaved(_ next: Page) {
        if page?.id == next.id { return }
        if let current = page {
            guard !locksDismissal else { return }
            suspend(current)
            if current.keepsDraft { kept.insert(current.id) }
            // Reopening a parent replaces its descendants rather than forming a cycle.
            if let index = backStack.firstIndex(where: { $0.id == next.id }) {
                let discarded = Array(backStack.dropFirst(index + 1)) + [current]
                for old in discarded {
                    if case .native(let native) = old { finishNative(native, reason: .dismiss) }
                    if case .conversation(let session) = old { session.setConversationPopup(false) }
                }
                backStack.removeSubrange(index...)
            }
            else if case .conversation(let previous) = current, case .conversation = next {
                previous.setConversationPopup(false)
            } else { backStack.append(current) }
        } else {
            captureOpenerAndDismissSearch()
        }
        store?.invalidateTabConfirmations()
        draftKept = kept.contains(next.id)
        page = next
        showConversationPicker = false
        conversationDraftReceipt = nil
        if case .conversation(let session) = next { session.setConversationPopup(true) }
        if case .native(let native) = next { native.active = true }
        syncGate()
    }
    func back() {
        guard !presentedConversations.isEmpty else { backSaved(); return }
        afterSavingConversations { [weak self] in self?.backSaved() }
    }
    private func backSaved() {
        guard canGoBack, let previous = backStack.popLast() else { return }
        if let page { suspend(page) }
        if let page, page.keepsDraft { kept.insert(page.id) }
        if case .native(let native) = page { finishNative(native, reason: .dismiss) }
        if case .conversation(let session) = page { session.setConversationPopup(false) }
        page = previous; draftKept = kept.contains(previous.id)
        if case .conversation(let session) = previous { session.setConversationPopup(true) }
        if case .native(let native) = previous { native.active = true }
        syncGate()
    }
    func dismiss(_ session: Session, reason: DismissReason) {
        guard contains(session.id) else { return }
        if visibleConversation === session { dismiss(reason: reason); return }
        guard case .tool(let visible) = page, visible === session else {
            // Completion may arrive after the popup was dismissed or replaced.
            // Consume that completed form without navigating the current page.
            if reason != .dismiss, finish(session, reason: reason) {
                backStack.removeAll { $0.id == ObjectIdentifier(session) }
                kept.remove(ObjectIdentifier(session))
            }
            return
        }
        dismiss(reason: reason)
    }
    func dismiss(reason: DismissReason) {
        if reason == .dismiss, !presentedConversations.isEmpty {
            guard !locksDismissal else { return }
            afterSavingConversations { [weak self] in self?.dismissSaved(reason: reason) }
        } else { dismissSaved(reason: reason) }
    }
    private func dismissSaved(reason: DismissReason) {
        guard let current = page, reason != .dismiss || !locksDismissal else { return }
        if reason == .dismiss {
            do { try saveDrafts() }
            catch {
                if case .tool(let session) = current { session.tabState?.saveError = error.localizedDescription }
                return
            }
            suspend(current)
            if current.keepsDraft { kept.insert(current.id) }
            backStack.filter(\.keepsDraft).forEach { kept.insert($0.id) }
            for old in backStack + [current] {
                if case .native(let native) = old { finishNative(native, reason: .dismiss) }
                if case .conversation(let session) = old {
                    if session.hasConversationDraft {
                        conversationDraftReceipt = "Draft kept · \(session.conversationTitle)"
                        receiptConversation = session
                    }
                    session.setConversationPopup(false)
                }
            }
            backStack.removeAll()
            page = nil
        } else {
            if case .conversation(let session) = current {
                session.setConversationPopup(false)
            } else if case .tool(let session) = current {
                guard finish(session, reason: reason) else { return }
            } else if case .account(let form) = current {
                form.cancel()
                accountForms = accountForms.filter { $0.value !== form }
                added[current.id] = nil
            } else if case .confirmation(let confirmation) = current, reason == .cancel { confirmation.cancel() }
            else if case .native(let native) = current { finishNative(native, reason: reason) }
            kept.remove(current.id)
            page = backStack.popLast()
            draftKept = page.map { kept.contains($0.id) } ?? false
        }
        syncGate()
        if page == nil { restoreFocus() }
    }
    private func finish(_ session: Session, reason: DismissReason) -> Bool {
        if let id = session.tabState?.navigation.draftID {
            do { try store?.drafts.discard(id) }
            catch { session.tabState?.saveError = error.localizedDescription; return false }
        }
        if reason == .cancel { session.tabState?.discardEdits?(); session.tabState?.profileEditor?.reload() }
        session.engine.terminate()
        sessions.removeAll { $0 === session }
        return true
    }
    func saveDrafts() throws {
        for session in sessions {
            guard let state = session.tabState else { continue }
            do { try store?.tabCloseCoordinator.save(state) }
            catch { state.saveError = error.localizedDescription; throw error }
        }
    }
    private func suspend(_ page: Page) {
        guard case .tool(let session) = page, let state = session.tabState else { return }
        state.confirmation.invalidate()
        state.revision += 1
        // Models and explicitly started operations outlive their view. Revision
        // changes still reject stale file-picker results; dismissal never sends
        // or cancels a request, connection step or Forward already in flight.
    }
    func invalidateConfirmations() { sessions.forEach { $0.tabState?.confirmation.invalidate() } }
    func attach(to window: NSWindow?) { self.window = window; syncGate() }
    private func syncGate() {
        NavigationPresentationGate.setOverlay(overlayID, window: window, presented: isPresented,
            visibleContent: showConversationPicker ? nil : visibleConversation?.engine.view)
    }
    private func restoreFocus() {
        guard let window else { return }
        defer { opener = nil }
        if let view = opener as? NSView, view.window === window, !view.isHiddenOrHasHiddenAncestor {
            if let field = view as? SearchTextField, let search = store?.searchModel, search.fieldFocus.field === field {
                // Search rejects automatic responder changes. Restore its
                // still-mounted opener through the explicit request path.
                search.begin()
                return
            } else if window.makeFirstResponder(view) { return }
        }
        // A temporary search field can unmount while the popup is open.
        // Restore content explicitly: the pane reconciler only focuses on a
        // tab change, which need not have happened during this presentation.
        guard let session = store?.active?.activeSession, session.engine.view.window === window else {
            window.makeFirstResponder(nil)
            return
        }
        session.focusPrimaryInput()
    }
    func terminate() {
        conversationSaveTask?.cancel(); conversationSaveTask = nil; pendingConversationTransition = nil
        conversationSaving = false
        page = nil; backStack.removeAll(); syncGate()
        for session in sessions {
            session.setConversationPopup(false)
            if store?.allSessions.contains(where: { $0 === session }) != true { session.engine.terminate() }
        }
        sessions.removeAll()
        accountForms.values.forEach { $0.cancel() }; accountForms.removeAll(); added.removeAll()
        for native in nativePages { finishNative(native, reason: .cancel) }
        nativePages.removeAll()
    }
}

extension View {
    func popupHost(_ coordinator: PopupCoordinator) -> some View {
        self.accessibilityHidden(coordinator.isPresented)
            .overlay { PopupHost(coordinator: coordinator) }
    }
}

private struct PopupHost: View {
    @Bindable var coordinator: PopupCoordinator
    var body: some View {
        GeometryReader { geometry in
            if let page = coordinator.page {
                ZStack {
                    Button { coordinator.dismiss(reason: .dismiss) } label: {
                        Color.black.opacity(Theme.chromeColorScheme == .dark ? 0.48 : 0.32).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Dismiss popup")
                        .accessibilityIdentifier("popup-scrim").accessibilityHidden(true)
                    PopupDialog(coordinator: coordinator, page: page,
                                maximumBodyHeight: maximumBodyHeight(page, windowHeight: geometry.size.height))
                        .frame(width: min(width(page), max(0, geometry.size.width - 40)),
                               height: min(height(page), max(0, geometry.size.height - 48)))
                        .background(Theme.chromeBackground, in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.chromeHairline))
                        .shadow(color: .black.opacity(0.35), radius: 32, y: 18)
                }.frame(width: geometry.size.width, height: geometry.size.height)
            } else if let receipt = coordinator.conversationDraftReceipt {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                    Text(receipt)
                    Button("Reopen") { coordinator.reopenConversationDraft() }
                        .buttonStyle(.plain).foregroundStyle(ChatAppearance.accent)
                        .accessibilityIdentifier("popup-draft-reopen")
                }
                    .font(Theme.display(11)).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.chromeBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.chromeHairline))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .accessibilityIdentifier("popup-draft-receipt")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(42)
            }
        }
        .background(PopupWindowProbe(coordinator: coordinator).allowsHitTesting(false))
        .allowsHitTesting(coordinator.isPresented || coordinator.conversationDraftReceipt != nil)
        .preferredColorScheme(Theme.chromeColorScheme)
    }
    private func width(_ page: PopupCoordinator.Page) -> CGFloat {
        if case .conversation = page { return 720 }
        if case .native(let native) = page { return native.width }
        if case .tool(let session) = page {
            if session.tabState?.presentsPopupDecision == true { return 580 }
            switch session.toolRoute {
            case .settings: return session.tabState?.navigation.settingsSection == .claudeAccounts ? 1000 : 880
            case .organization: return 880
            case .newAgent, .forward, .publish, .publication: return 700
            case .request:
                return page.presentationTitle == "Folder permission" || page.presentationTitle == "Publish result" ? 580 : 700
            default: break
            }
        }
        return 580
    }
    private func height(_ page: PopupCoordinator.Page) -> CGFloat {
        switch page {
        case .conversation(let session):
            if coordinator.showConversationPicker { return 390 }
            if case .telegram = session.toolRoute { return 700 }
            if session.conversationHasBack { return 600 }
            if session.channel != nil { return 620 }
            return 500
        case .tool(let session):
            if session.toolRoute?.fitsPopupContent == true, let height = session.tabState?.popupContentHeight {
                return height + 63 + (coordinator.showsDraftNotice ? 30 : 0)
            }
            return switch session.toolRoute {
            case .settings: session.tabState?.navigation.settingsSection == .claudeAccounts ? 700 : 680
            case .newAgent: 628
            case .newSSH: 420
            case .connection: 480
            case .newChannel: 370
            case .newDM: 520
            case .ask: 480
            case .newWorktree, .workspaceDetails: 564
            case .publish, .publication, .forward, .request: 680
            default: 604
            }
        case .account: return 460
        case .confirmation: return (coordinator.confirmationContentHeight ?? 197) + 63
        case .native(let native): return (native.contentHeight ?? 400) + 63 + (coordinator.showsDraftNotice ? 30 : 0)
        }
    }
    private func maximumBodyHeight(_ page: PopupCoordinator.Page, windowHeight: CGFloat) -> CGFloat {
        let chromeHeight: CGFloat = 63 + (coordinator.showsDraftNotice ? 30 : 0)
        var outsideBody: CGFloat = 80
        if case .tool(let session) = page, let state = session.tabState,
           let total = state.popupContentHeight, let viewport = state.popupViewportHeight {
            // The footer, validation and inline confirmation all need their
            // natural height. Reduce the scrolling body when any of them grows.
            outsideBody = max(0, total - viewport)
        }
        if case .native(let native) = page, let total = native.contentHeight, let viewport = native.viewportHeight {
            outsideBody = max(0, total - viewport)
        }
        return max(0, windowHeight - 48 - chromeHeight - outsideBody)
    }
}

extension ToolRoute {
    var fitsPopupContent: Bool {
        switch self {
        case .newAgent, .newSSH, .newWorktree, .workspaceDetails, .connection,
             .newDM, .newChannel, .forward, .ask, .request, .publish, .publication, .agent,
             .linkFailure, .organization, .closeWorkspaces, .fileOperations, .importSession: true
        default: false
        }
    }
}

/// The existing popup host sizes forms to their content. Only the body scrolls
/// once it reaches the available window height; decision buttons stay visible.
private struct PopupMaximumBodyHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 520
}
private struct PopupCoordinatorKey: EnvironmentKey {
    static let defaultValue: PopupCoordinator? = nil
}
extension EnvironmentValues {
    var popupCoordinator: PopupCoordinator? {
        get { self[PopupCoordinatorKey.self] }
        set { self[PopupCoordinatorKey.self] = newValue }
    }
    var popupMaximumBodyHeight: CGFloat {
        get { self[PopupMaximumBodyHeightKey.self] }
        set { self[PopupMaximumBodyHeightKey.self] = newValue }
    }
}
struct PopupFormHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
struct PopupViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct PopupBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
struct PopupScrollBody<Content: View>: View {
    @Environment(\.popupMaximumBodyHeight) private var availableHeight
    @State private var contentHeight: CGFloat?
    var maxHeight: CGFloat = 520
    @ViewBuilder var content: () -> Content

    var body: some View {
        let limit = min(maxHeight, availableHeight)
        ScrollView {
            content().fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: PopupBodyHeightKey.self, value: geometry.size.height)
                })
        }
        .frame(height: min(contentHeight ?? limit, limit))
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PopupViewportHeightKey.self, value: geometry.size.height)
        })
        .onPreferenceChange(PopupBodyHeightKey.self) { height in
            if height > 0 { contentHeight = height }
        }
    }
}

struct PopupPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var destructive = false
    private var fill: Color {
        if destructive {
            return Theme.resolved.isLight
                ? Color(.sRGB, red: 179 / 255, green: 55 / 255, blue: 64 / 255)
                : Theme.activityFailure
        }
        return Theme.resolved.isLight
            ? Color(.sRGB, red: 40 / 255, green: 121 / 255, blue: 168 / 255)
            : Theme.activityRunning
    }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(destructive ? Color.white : Theme.chromeBackground)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .frame(minHeight: 29)
            .background(fill.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.4)
    }
}

/// macOS's automatic bordered button ignores a destructive foreground tint in
/// inactive windows. Keep the role and make its warning treatment explicit.
struct PopupDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12))
            .foregroundStyle(enabled ? Color.red : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.chromeHover.opacity(configuration.isPressed ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.chromeHairline))
            .contentShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct PopupWindowProbe: NSViewRepresentable {
    let coordinator: PopupCoordinator
    final class Probe: NSView {
        weak var coordinator: PopupCoordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); coordinator?.attach(to: window) }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.coordinator = coordinator; return view }
    func updateNSView(_ view: Probe, context: Context) { view.coordinator = coordinator }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.coordinator?.attach(to: nil) }
}

/// AXDialog is a subrole of AXGroup on macOS. This native boundary also
/// contains keyboard focus, including field editors, inside the popup.
private struct PopupDialog: NSViewRepresentable {
    let coordinator: PopupCoordinator
    let page: PopupCoordinator.Page
    let maximumBodyHeight: CGFloat
    final class Dialog: NSHostingView<AnyView> {
        weak var coordinator: PopupCoordinator?
        var pageID: ObjectIdentifier?
        private var monitor: Any?
        override var acceptsFirstResponder: Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override func accessibilitySubrole() -> NSAccessibility.Subrole? { .init(rawValue: "AXDialog") }
        override func isAccessibilityElement() -> Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            focusInside()
            // The hosted form's native fields mount after the dialog attaches.
            // Resolve the first key view again once that layout has completed.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.coordinator?.isPresented == true else { return }
                self.layoutSubtreeIfNeeded()
                self.window?.recalculateKeyViewLoop()
                if self.window?.firstResponder === self || !self.containsFocus() {
                    self.focusInside()
                }
                if let session = self.coordinator?.visibleConversation, self.coordinator?.showConversationPicker != true {
                    session.focusPrimaryInput()
                }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                guard let self, self.coordinator?.isPresented == true,
                      let window = self.window, event.window === window else { return event }
                if event.type == .leftMouseDown {
                    guard let content = window.contentView,
                          content.bounds.contains(content.convert(event.locationInWindow, from: nil)) else { return event }
                    if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                        self.coordinator?.dismiss(reason: .dismiss)
                        return nil
                    }
                    return event
                }
                if event.keyCode == 53 {
                    if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                    if let editor = window.firstResponder as? ChatMentionEditor.Editor,
                       editor.consume?(event.keyCode, event.modifierFlags) == true { return nil }
                    if self.coordinator?.showConversationPicker == true { self.coordinator?.showConversationPicker = false }
                    else { self.coordinator?.dismiss(reason: .dismiss) }
                    return nil
                }
                if event.keyCode == 35, event.modifierFlags.contains(.command), self.coordinator?.visibleConversation != nil {
                    self.coordinator?.showConversationPicker = true
                    return nil
                }
                // A delayed terminal mount must not receive the next key if
                // it reclaimed focus after the popup was presented.
                if !self.containsFocus() { self.focusInside() }
                guard self.containsFocus() else { return nil }
                if event.keyCode == 48 {
                    // Modified Tab navigates tabs/windows via AppKit's menu
                    // routing. Only ordinary Tab traversal belongs here.
                    guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
                    if event.modifierFlags.contains(.shift) { window.selectPreviousKeyView(nil) }
                    else { window.selectNextKeyView(nil) }
                    if !self.containsFocus() { self.focusInside(backwards: event.modifierFlags.contains(.shift)) }
                    return nil
                }
                // AppKit's window-cycle shortcut has no app-owned menu item
                // for validateMenuItem to disable.
                if event.keyCode == 50, event.modifierFlags.contains(.command) { return nil }
                return event
            }
        }
        func containsFocus() -> Bool {
            guard let responder = window?.firstResponder as? NSView else { return false }
            if responder.isDescendant(of: self) { return true }
            if let editor = responder as? NSTextView, let field = editor.delegate as? NSView { return field.isDescendant(of: self) }
            return false
        }
        func focusInside(backwards: Bool = false) {
            guard let window else { return }
            window.makeFirstResponder(self)
            if backwards { window.selectPreviousKeyView(self) } else { window.selectNextKeyView(self) }
            if !containsFocus() { window.makeFirstResponder(self) }
        }
    }
    func makeNSView(context: Context) -> Dialog {
        let view = Dialog(rootView: AnyView(PopupPanel(coordinator: coordinator, page: page)))
        view.coordinator = coordinator; view.pageID = page.id
        view.setAccessibilityIdentifier("popup-dialog"); view.setAccessibilityLabel(page.presentationTitle)
        return view
    }
    func updateNSView(_ view: Dialog, context: Context) {
        let presentationChanged = view.pageID != page.id || view.accessibilityLabel() != page.presentationTitle
        view.rootView = AnyView(PopupPanel(coordinator: coordinator, page: page))
        view.setAccessibilityLabel(page.presentationTitle)
        if case .tool(let session) = page, session.tabState?.popupMaximumBodyHeight != maximumBodyHeight {
            DispatchQueue.main.async { session.tabState?.popupMaximumBodyHeight = maximumBodyHeight }
        }
        if case .native(let native) = page, native.maximumBodyHeight != maximumBodyHeight {
            DispatchQueue.main.async { native.maximumBodyHeight = maximumBodyHeight }
        }
        if presentationChanged {
            view.pageID = page.id
            // Inline confirmations retain their page identity but replace the
            // focused form. Restore containment after its native fields unmount.
            DispatchQueue.main.async { [weak view] in
                guard let view, view.coordinator?.isPresented == true else { return }
                view.layoutSubtreeIfNeeded()
                view.window?.recalculateKeyViewLoop()
                if view.window?.firstResponder === view || !view.containsFocus() { view.focusInside() }
                if let session = view.coordinator?.visibleConversation, view.coordinator?.showConversationPicker != true {
                    session.focusPrimaryInput()
                }
            }
        }
    }
}

private struct PopupPanel: View {
    @Bindable var coordinator: PopupCoordinator
    let page: PopupCoordinator.Page
    var body: some View {
        VStack(spacing: 0) {
            if case .conversation(let session) = page {
                ChatPopupHeader(coordinator: coordinator, session: session)
            } else {
            HStack(spacing: 12) {
                if coordinator.canGoBack {
                    Button { coordinator.back() } label: { Image(systemName: "arrow.left") }
                        .buttonStyle(.plain).accessibilityLabel("Back").accessibilityIdentifier("popup-back")
                }
                Text(page.presentationTitle).font(Theme.display(16, weight: .semibold))
                Spacer()
                if case .tool(let session) = page, session.toolRoute == .settings {
                    let model = SupportTabs.shared.settingsModel()
                    Text(model.saveError != nil ? "Changes could not be saved" : model.isSaving ? "Saving…" : "Changes applied")
                        .font(Theme.display(10)).foregroundStyle(model.saveError == nil ? .green : .orange)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                }
                Button { coordinator.dismiss(reason: .dismiss) } label: { Image(systemName: "xmark").font(.system(size: 12)) }
                    .buttonStyle(.plain).disabled(coordinator.locksDismissal)
                    .accessibilityLabel("Close popup").accessibilityIdentifier("popup-close")
            }.padding(.horizontal, 20).frame(height: 62)
            }
            Divider()
            if case .conversation(let session) = page, !coordinator.showConversationPicker,
               let source = session.conversationPopupSource {
                HStack {
                    Label(source.label, systemImage: "bell").lineLimit(1)
                    Spacer()
                    Button(source.returnTitle) { coordinator.dismiss(reason: .dismiss) }.buttonStyle(.plain)
                        .accessibilityIdentifier("popup-back-to-source")
                }.font(Theme.display(11)).foregroundStyle(ChatAppearance.accent)
                    .padding(.horizontal, 20).frame(height: 34)
                    .background(ChatAppearance.accent.opacity(0.12)).accessibilityIdentifier("popup-source-context")
            }
            if coordinator.showsDraftNotice && coordinator.visibleConversation == nil {
                Text("Draft kept · nothing sent or applied by closing.")
                    .font(Theme.display(11)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                    .frame(height: 30).background(.orange.opacity(0.10))
                    .accessibilityIdentifier("popup-draft-kept")
            }
            if let error = coordinator.conversationSaveError {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Draft could not be saved").font(Theme.display(12, weight: .semibold))
                        Text(error).font(Theme.display(11)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Retry") { coordinator.retryConversationSave() }.accessibilityIdentifier("popup-save-retry")
                }.padding(12).foregroundStyle(ChatAppearance.failure)
                    .background(ChatAppearance.failure.opacity(0.08)).accessibilityIdentifier("popup-save-error")
            }
            ZStack {
                ForEach(coordinator.presentedConversations) { session in
                    ChatPopupMount(session: session, visible: coordinator.visibleConversation === session && !coordinator.showConversationPicker)
                        .accessibilityHidden(coordinator.visibleConversation !== session || coordinator.showConversationPicker)
                }
                if coordinator.showConversationPicker, coordinator.visibleConversation != nil {
                    ChatPopupPicker(coordinator: coordinator)
                }
                nonConversationContent
            }
        }.foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
    }
    @ViewBuilder private var nonConversationContent: some View {
            switch page {
            case .conversation: EmptyView()
            case .tool(let session): PopupToolContent(session: session).id(session.id)
            case .account(let form):
                ClaudeAccountFormView(form: form, onCancel: { coordinator.dismiss(reason: .cancel) },
                    onComplete: { coordinator.completeAccount($0, form: form) }, onOpenTerminal: { coordinator.openTerminal() })
            case .native(let native):
                native.content()
                    .environment(\.popupCoordinator, coordinator)
                    .environment(\.popupMaximumBodyHeight, native.maximumBodyHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: PopupFormHeightKey.self, value: geometry.size.height)
                    })
                    .onPreferenceChange(PopupFormHeightKey.self) { height in
                        if height > 0 { native.contentHeight = height }
                    }
                    .onPreferenceChange(PopupViewportHeightKey.self) { native.viewportHeight = $0 }
                    .id(ObjectIdentifier(native))
            case .confirmation(let confirmation):
                VStack(alignment: .leading, spacing: 16) {
                    let paragraphs = confirmation.consequences.components(separatedBy: "\n\n")
                    if paragraphs.count > 1 {
                        Text(paragraphs[0]).font(Theme.display(18, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(paragraphs.count > 1 ? paragraphs.dropFirst().joined(separator: "\n\n") : confirmation.consequences)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                    if case .failed(let message) = confirmation.phase { Text(message).foregroundStyle(.red) }
                    Divider()
                    HStack {
                        Spacer()
                        Button("Cancel") { coordinator.dismiss(reason: .cancel) }
                            .disabled(confirmation.isExecuting).accessibilityIdentifier("popup-confirm-cancel")
                        Button(confirmation.verb, role: .destructive) { confirmation.confirm() }
                            .buttonStyle(PopupPrimaryButtonStyle(destructive: true))
                            .disabled(confirmation.isExecuting).accessibilityIdentifier("popup-confirm-accept")
                    }
                }.padding(24).fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: PopupFormHeightKey.self, value: geometry.size.height)
                    })
                    .onPreferenceChange(PopupFormHeightKey.self) { if $0 > 0 { coordinator.confirmationContentHeight = $0 } }
                    .onAppear { confirmation.shown(true) }
            }
    }
}

private struct PopupToolContent: NSViewRepresentable {
    let session: Session
    func makeNSView(context: Context) -> NSView { session.engine.view }
    func updateNSView(_ view: NSView, context: Context) {}
}
