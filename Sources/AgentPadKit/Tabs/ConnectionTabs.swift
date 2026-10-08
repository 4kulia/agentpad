import SwiftUI

/// One login flow and one Disconnect across all windows. Only the route is
/// persisted; the model and the confirmation live in the owning TabState.
@MainActor
final class ConnectionTabs {
    static let shared = ConnectionTabs()
    let navigation: SupportTabNavigation
    var service: ChatService
    private(set) var busy = false
    var now: () -> Date = Date.init
    var disconnectCall: (ChatService, ChatConnection) async -> ChatService.DisconnectOutcome = {
        await $0.disconnect(expecting: $1)
    }

    init(navigation: SupportTabNavigation = SupportTabs.shared.navigation, service: ChatService = .shared) {
        self.navigation = navigation; self.service = service
    }
    @discardableResult
    func show() -> Session? { navigation.open(.connection) }

    func close(_ state: TabState) {
        for store in navigation.router.stores() where !store.isTerminated {
            guard let session = store.allSessions.first(where: { $0.tabState === state }),
                  let location = store.location(ofSessionId: session.id) else { continue }
            store.closeTab(session, in: location.workspace)
            return
        }
    }

    func model(_ state: TabState) -> ChatConnectModel {
        if let model = state.connectionForm, !model.connectionChanged { return model }
        state.connectionForm?.close()
        let model = ChatConnectModel(service: service)
        state.connectionForm = model
        return model
    }

    func disconnect() {
        guard let session = show(), let state = session.tabState else { return }
        guard let connection = service.connection else {
            state.message = "Not connected to a server"; return
        }
        Task {
            let outcome = await confirmAndDisconnect(expecting: connection)
            if outcome == .busy { state.message = "A Disconnect is already waiting for an answer or under way." }
        }
    }

    enum LogoutOutcome: Equatable, Sendable {
        case disconnected, cancelled, noAnswer, stale, busy, started
        case notFinished(String)
    }

    /// The common coordinator owns consent. Connection, caller and deadline
    /// are checked again immediately before the serialized core operation.
    func confirmAndDisconnect(expecting expected: ChatConnection, service requestedService: ChatService? = nil,
                              deadline: Date? = nil, isCallerWaiting: @escaping @MainActor () -> Bool = { true },
                              answerBy: Date? = nil) async -> LogoutOutcome {
        guard !busy else { return .busy }
        let deadline = deadline ?? now().addingTimeInterval(120)
        let service = requestedService ?? self.service
        let generation = expected.orgKey.map { ChatAttention.scope($0, service).generation }
        func valid() -> Bool {
            service.connection == expected && isCallerWaiting() && now() < deadline
                && expected.orgKey.map { ChatAttention.scope($0, service).generation } == generation
        }
        func refusal() -> LogoutOutcome {
            if service.connection != expected || expected.orgKey.map({ ChatAttention.scope($0, service).generation }) != generation { return .stale }
            if now() >= deadline { return .noAnswer }
            return .cancelled
        }
        guard valid() else { return refusal() }
        guard let session = show(), let state = session.tabState, !state.confirmation.showsBlock else { return .busy }
        busy = true
        state.message = nil
        let coordinator = state.confirmation
        coordinator.now = now
        var watchman: Task<Void, Never>?
        return await withCheckedContinuation { continuation in
            var answered = false
            var result: LogoutOutcome?
            func answer(_ outcome: LogoutOutcome) {
                guard !answered else { return }
                answered = true; continuation.resume(returning: outcome)
            }
            let accepted = coordinator.request(.init(tabID: session.id, targetID: expected.sessionId,
                scope: expected.orgKey.map(OrgKey.init), generation: generation, deadline: deadline, callerWaiting: true),
                title: "Disconnect from the server?",
                consequences: "Agents started by requests will be stopped. This Mac stops receiving the organization's updates until you connect again.",
                verb: "Disconnect", destructive: true,
                stillValid: { !state.isClosed && valid() },
                completion: { [self] _ in
                    watchman?.cancel()
                    busy = false
                    answer(result ?? refusal())
                }, operation: { [self] in
                    var replyTimer: Task<Void, Never>?
                    if let answerBy {
                        replyTimer = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(max(0, answerBy.timeIntervalSince(now()))))
                            if !Task.isCancelled, coordinator.isExecuting { answer(.started) }
                        }
                    }
                    defer { replyTimer?.cancel() }
                    switch await disconnectCall(service, expected) {
                    case .done:
                        result = .disconnected
                        state.connectionForm?.close(); state.connectionForm = nil
                    case .stale:
                        result = .stale
                        throw ChatError.storage("The connection changed meanwhile; nothing was done.")
                    case .notFinished(let text):
                        result = .notFinished(text)
                        throw ChatError.storage(text)
                    }
                })
            if accepted {
                // Caller liveness is not observable; consent must end even if
                // the user never presses a button after the CLI goes away.
                watchman = Task { @MainActor in
                    while !Task.isCancelled, coordinator.isAwaiting {
                        try? await Task.sleep(for: .milliseconds(200))
                        if !Task.isCancelled { coordinator.validate() }
                    }
                }
            }
        }
    }
}

struct ConnectionTabView: View {
    let state: TabState
    let tabs: ConnectionTabs
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ChatConnectView(model: tabs.model(state), onClose: {
                    tabs.close(state)
                }, onDisconnect: { tabs.disconnect() })
                if let message = state.message { Text(message).foregroundStyle(.orange).padding(.horizontal, 18) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(state.confirmation.isAwaiting || state.confirmation.isExecuting)
    }
}
