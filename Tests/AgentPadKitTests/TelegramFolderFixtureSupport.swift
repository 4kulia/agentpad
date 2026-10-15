@testable import AgentPadTelegram

/// Fixture conveniences use the same list/window shape as the real provider.
extension TelegramChatSnapshot {
    mutating func prepareAttention(keys: [TelegramAttentionOrderKey]? = nil, liveChats: Set<Int64>? = nil) {
        guard let binding else { return }
        let keys = keys ?? attentionKeys ?? attentionRows.compactMap { row in
            row.attentionOrderKey ?? row.attention.map { .init(chat: row.id.chat,tier: $0.kind.tier,rankingTime: $0.lastDate) }
        }
        let order: TelegramAttentionOrder
        if let existing = attentionState?.order, existing.binding == binding, existing.revision == attentionRevision, existing.keys == keys {
            order = existing
        } else {
            order = .init(binding: binding,revision: attentionRevision,keys: keys)
        }
        attentionState = .init(order: order,liveChats: liveChats ?? attentionLiveChats ?? Set(keys.map(\.chat)))
    }

    var mainList: TelegramListSnapshot {
        get { lists.first { $0.key == .main } ?? .init(key: .main, name: "All chats", icon: "All", visible: true,
            complete: true, generation: 0, revision: 1, counts: .init(), capacity: 8, expanded: false, windows: [:], collapsedWindows: []) }
        set { if let index = lists.firstIndex(where: { $0.key == .main }) { lists[index] = newValue } else { lists.insert(newValue, at: 0) } }
    }
    var mainRows: [TelegramChatRow] {
        get { mainList.windows[0]?.rows ?? [] }
        set { mainList.windows[0] = .init(revision: mainList.revision, offset: 0, rows: newValue) }
    }
}
