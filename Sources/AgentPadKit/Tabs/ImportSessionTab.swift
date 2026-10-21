import SwiftUI

extension ProcessTabs {
    @discardableResult
    func importExternal(_ source: ExternalAgentSession, from store: WorkspaceStore? = nil,
                        monitor: ExternalSessionMonitor = .shared) -> ImportSessionModel? {
        let route = ToolRoute.importSession(agentID: AgentTemplate.claudeCodeID, conversationID: source.sessionId,
            externalSourceID: "\(source.pid):\(source.processStart.map(String.init(describing:)) ?? "unknown")")
        guard let session = router.open(route, from: store), let state = session.tabState else { return nil }
        if let model = state.importSession { return model }
        let model = ImportSessionModel(source: source, state: state, tabID: session.id, router: router, monitor: monitor)
        state.importSession = model
        return model
    }
}

@MainActor @Observable
final class ImportSessionModel {
    let source: ExternalAgentSession
    weak var state: TabState?
    let tabID: UUID
    let router: TabRouter
    let monitor: ExternalSessionMonitor
    var message: String?
    private(set) var step: ExternalSessionMonitor.TakeOverStep = .checking
    var completed: Bool { step == .resumed }
    init(source: ExternalAgentSession, state: TabState, tabID: UUID, router: TabRouter, monitor: ExternalSessionMonitor) {
        self.source = source; self.state = state; self.tabID = tabID; self.router = router; self.monitor = monitor
    }
    func current() -> Bool {
        source.canTakeOver && monitor.sessions.contains { $0.id == source.id && $0.processStart == source.processStart && $0.cwd == source.cwd && $0.canTakeOver }
    }
    func request() {
        guard let state, !completed else { return }
        if case .failed = state.confirmation.phase { state.confirmation.cancel() }
        state.confirmation.request(.init(tabID: tabID, targetID: source.id, revision: source.processStart.map(String.init(describing:))),
            title: "Move “\(source.displayTitle)” here?",
            consequences: "The original process will receive SIGTERM and this conversation will be resumed here. Other work running in that terminal tab is not kept. If resuming fails after it stops, the original process cannot be restored.",
            verb: "Move here", destructive: true, stillValid: { [weak self] in self?.current() == true },
            operation: { [weak self] in
                guard let self, let owner = self.router.owner(of: self.tabID) else { throw ProcessOperationError("The import tab is no longer available.") }
                self.message = nil
                let result = await self.monitor.takeOver(self.source, into: owner.store,
                    destination: { [weak self] in self.flatMap { $0.router.owner(of: $0.tabID)?.store } },
                    progress: { self.step = $0 })
                switch result {
                case .success: self.message = "The original process stopped. The conversation was opened here."
                case .failure(let error):
                    let text = Self.failure(error, step: self.step)
                    self.message = text
                    throw ProcessOperationError(text)
                }
            })
    }
    func retryResume() {
        guard let state, step == .sourceStopped else { return }
        if case .failed = state.confirmation.phase { state.confirmation.cancel() }
        state.confirmation.request(.init(tabID: tabID, targetID: source.sessionId),
            title: "Resume the stopped conversation?", consequences: "The original process already stopped. Open a new local session from the saved conversation.",
            verb: "Resume conversation", stillValid: { [weak self] in self?.step == .sourceStopped }, operation: { [weak self] in
                guard let self, let owner = self.router.owner(of: self.tabID) else { throw ProcessOperationError("The import tab is no longer available.") }
                switch owner.store.resumeAgentSession(agentId: AgentTemplate.claudeCodeID, conversationId: self.source.sessionId, cwd: self.source.cwd) {
                case .success: self.step = .resumed; self.message = "The saved conversation was opened here."
                case .failure(let error): throw ProcessOperationError(error.message(agentId: AgentTemplate.claudeCodeID, conversationId: self.source.sessionId))
                }
            })
    }
    static func failure(_ error: ExternalSessionMonitor.TakeOverError, step: ExternalSessionMonitor.TakeOverStep) -> String {
        let reason: String
        switch error {
        case .notIdle: reason = "The session is busy. Only an idle session can be moved."
        case .stillRunning: reason = "The original process has not been confirmed stopped."
        case .changed: reason = "The session ended, changed or restarted."
        case .noTranscript: reason = "The conversation is not saved on this Mac."
        case .resumeRefused(let text): reason = text
        }
        let effect: String
        switch step {
        case .checking: effect = "No signal was sent and no session was opened here."
        case .signalSent: effect = "SIGTERM was sent. No session was opened here; the original process may still be running."
        case .sourceStopped, .resumed: effect = "The original process stopped. Resuming here failed; it has not been restarted."
        }
        return reason + "\n" + effect
    }
}

struct ImportSessionView: View {
    let state: TabState
    var body: some View {
        VStack(spacing: 0) {
            PopupScrollBody {
                VStack(alignment: .leading, spacing: 18) {
                    if !state.isPopup { Text("Import session").font(.title2) }
                    if let model = state.importSession {
                        HStack(spacing: 12) {
                            AgentIconView(asset: AgentTemplate.claudeCode.iconAsset,
                                fallbackSymbol: AgentTemplate.claudeCode.symbol, size: 32)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Claude Code · " + model.source.displayTitle).font(.headline)
                                Text(model.source.kind.map { "External session · " + $0.capitalized } ?? "External session")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                            GridRow {
                                Text("Folder").foregroundStyle(.secondary)
                                Text(model.source.cwd.path).textSelection(.enabled)
                            }
                            GridRow {
                                Text("Conversation").foregroundStyle(.secondary)
                                Text(model.source.displayTitle).textSelection(.enabled)
                            }
                        }.font(.subheadline)
                        Text("Move here stops the original process before resuming this conversation in AgentPad. Closing this popup takes no process action.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                        if let message = model.message { Text(message).textSelection(.enabled) }
                        if !model.completed, model.step != .sourceStopped {
                            Button("Go to source") { ExternalSessionActions.focus(model.source) }
                                .accessibilityIdentifier("import-session-source")
                        }
                    } else {
                        Text(state.message ?? "This import ended. Choose the live source again; no process action is restored.")
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button(state.importSession?.completed == true ? "Done" : "Cancel") { close() }
                    .disabled(state.confirmation.isExecuting)
                    .accessibilityIdentifier("import-session-cancel")
                if let model = state.importSession, !model.completed {
                    if model.step == .sourceStopped {
                        Button("Resume conversation…") { model.retryResume() }
                            .buttonStyle(PopupPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                            .disabled(state.confirmation.showsBlock)
                            .accessibilityIdentifier("import-session-resume")
                    } else {
                        Button(model.message == nil ? "Move here…" : "Retry…") { model.request() }
                            .buttonStyle(PopupPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                            .disabled(!model.current() || state.confirmation.showsBlock)
                            .accessibilityIdentifier("import-session-move")
                    }
                }
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("import-session-content")
    }
    private func close() {
        let model = state.importSession
        let owner = model.flatMap { $0.router.owner(of: $0.tabID) } ?? SupportTabs.shared.owner(state)
        guard let owner, !state.confirmation.isExecuting else { return }
        owner.store.popups.dismiss(owner.session, reason: model?.completed == true ? .applied : .cancel)
    }
}
