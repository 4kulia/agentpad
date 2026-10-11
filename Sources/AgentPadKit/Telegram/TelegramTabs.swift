import AgentPadTelegram
import SwiftUI

@MainActor enum TelegramTabs {
    @discardableResult static func openAttention(_ summary: TelegramAttentionSummary, from store: WorkspaceStore?,
                                                 router: TabRouter = .shared) -> Bool {
        let binding = TelegramService.chats.snapshot.account
        guard binding?.account == summary.destination.account, binding?.environment == summary.destination.environment,
              let session = router.open(.telegram(summary.destination), from: store) else { return false }
        let model = TelegramService.conversations.model(summary.destination)
        session.tabState?.telegramModel = model
        model.showMessage(summary.firstMessage)
        Task { session.tabState?.telegramRow = await TelegramService.chats.row(summary.destination.root) }
        return true
    }
    @discardableResult static func openTopic(_ id: TelegramChatID, title: String?, state: TabState,
                                            router: TabRouter = .shared) -> Session? {
        let origin = router.stores().first { $0.allSessions.contains { $0.tabState === state } }
        guard let session = router.open(.telegram(id), from: origin) else { return nil }
        session.tabState?.telegramRow = state.telegramRow
        session.tabState?.telegramTopicTitle = title
        return session
    }
    @discardableResult static func open(_ row: TelegramChatRow, from store: WorkspaceStore,
                                       beside: Bool = false, router: TabRouter = .shared) -> Session? {
        let route = ToolRoute.telegram(row.id)
        let existing = router.find(route, windowID: store.windowID)
        guard let session = router.open(route, from: store) else { return nil }
        session.tabState?.telegramRow = row
        if beside, existing == nil, let location = store.location(ofSessionId: session.id),
           let pane = store.splitPane(location.pane, orientation: .horizontal, in: location.workspace) {
            _ = store.handleTabDrop(droppedId: session.id, to: pane, at: 0, in: location.workspace)
        }
        return session
    }
}

extension TelegramTabs {
    @MainActor static func openSponsored(_ id: TelegramChatID, state: TabState, router: TabRouter = .shared) {
        let origin = router.stores().first { $0.allSessions.contains { $0.tabState === state } }
        guard let session = router.open(.telegram(id), from: origin), let tab = session.tabState else { return }
        Task { tab.telegramRow = await TelegramService.chats.row(id.root) }
    }
}
