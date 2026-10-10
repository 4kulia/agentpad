import Foundation
import GRDB

@MainActor
enum SearchNavigation {
    /// Re-read the actual message at its sequence before opening a destination.
    /// Neither snippets nor read marks are written into the conversation here.
    static func open(_ hit: ChatSearchHit, model: EverywhereSearchModel, from owner: WorkspaceStore, service: ChatService = .shared) async {
        model.navigationError = nil
        guard let connection = service.connection, let key = connection.orgKey, let token = service.token,
              let store = service.orgSessions[key]?.store, ChatAttention.personalAllowed(key, service),
              let generation = try? store.generation else { unavailable(model); return }
        let context = ChatSearchContext(key: key, session: connection.sessionId, generation: generation, revision: 0)
        func current() -> Bool {
            !owner.isTerminated && service.connection?.orgKey == key && service.connection?.sessionId == context.session
                && service.orgSessions[key]?.store === store
                && (try? store.generation) == context.generation && ChatAttention.personalAllowed(key, service)
        }
        let api = service.makeAPI(key.server)
        do {
            switch hit.kind {
            case .channel:
                guard ChatNotifications.allowed(service, key, channel: hit.targetID) else { unavailable(model); return }
                let epoch = try SearchCache.read(store.queue) { try ChatMessages.epoch($0, hit.targetID) }
                let page = try await api.messagesPage(key.orgId, channel: hit.targetID, root: hit.threadRootID, before: hit.messageSeq + 1, token: token)
                guard current(), ChatNotifications.allowed(service, key, channel: hit.targetID),
                      try SearchCache.read(store.queue, { try ChatMessages.current($0, hit.targetID, epoch: epoch) }),
                      let message = page.messages.first(where: { $0.messageId == hit.messageID && $0.channelId == hit.targetID && $0.seq == hit.messageSeq }) else {
                    unavailable(model); return
                }
                guard message.deletedAt == nil else { unavailable(model, deleted: true); return }
                try SearchCache.write(store.queue) { _ = try ChatMessages.write($0, message) }
                guard let tab = owner.showChannel(ChannelRef(key, channel: hit.targetID)) else { unavailable(model); return }
                ChatMessageNavigation.request(.init(key: key, channel: hit.targetID, message: hit.messageID, sequence: hit.messageSeq), key: key, destination: tab.engine.view)
            case .dm:
                guard service.dmAllowed(key, hit.targetID) else { unavailable(model); return }
                let epoch = try store.dmRead { try ChatDMStore.windowEpoch($0, hit.targetID) }
                let page = try await api.dmMessages(key.orgId, id: hit.targetID, root: hit.threadRootID, before: hit.messageSeq + 1, token: token)
                guard current(), service.dmAllowed(key, hit.targetID),
                      try store.dmRead({ try ChatDMStore.windowEpoch($0, hit.targetID) }) == epoch,
                      let message = page.messages.first(where: { $0.messageId == hit.messageID && $0.dmId == hit.targetID && $0.seq == hit.messageSeq }) else {
                    unavailable(model); return
                }
                guard message.deletedAt == nil else { unavailable(model, deleted: true); return }
                try store.dmWrite { try ChatDMStore.write($0, message) }
                guard let tab = ChatDMTabs.open(.init(key, dm: hit.targetID), from: owner, service: service) else { unavailable(model); return }
                tab.tabState?.dmSearchTarget = hit.messageID
                tab.tabState?.dmModel?.navigateToSearchMessage(hit.messageID)
            }
            model.dismiss(); model.returnAvailable = true
        } catch { unavailable(model) }
    }
    private static func unavailable(_ model: EverywhereSearchModel, deleted: Bool = false) {
        model.messages.invalidate(); model.navigationError = deleted ? "This message was deleted." : "Message unavailable."
        model.openResults()
    }
}

extension ChatDMModel {
    func navigateToSearchMessage(_ id: String) {
        guard readable, let store = service.orgSessions[key]?.store,
              let current = try? store.dmRead({ try ChatDMStore.messages($0, ref.dm) }),
              let message = current.first(where: { $0.id == id }), !message.deleted else { return }
        revealSearchMessage(message, in: current)
    }
}

enum SearchLoadedHistory {
    static func matches(_ messages: [ChatMessage], request: ChatSearchRequest) -> [ChatSearchHit] {
        guard let query = try? SearchQuery(request.query) else { return [] }
        return messages.compactMap { message -> ChatSearchHit? in
            guard !message.deleted, !message.loading, let seq = message.seq, seq > 0,
                  request.authorAccountID.map({ $0 == message.authorAccountId }) ?? true,
                  request.targetID.map({ $0 == (message.dmId ?? message.channelId) }) ?? true else { return nil }
            let kind: ChatSearchHit.Kind = message.dmId == nil ? .channel : .dm
            guard request.scope == .all || request.scope.rawValue == kind.rawValue else { return nil }
            let date = ChatStore.date(message.createdAt ?? "")
            if let from = request.from.flatMap(ChatStore.date), date.map({ $0 >= from }) != true { return nil }
            if let to = request.to.flatMap(ChatStore.date), date.map({ $0 < to }) != true { return nil }
            let tokens = Set(message.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(.nonBaseCharacters).inverted))
            guard query.words.allSatisfy({ tokens.contains($0.lowercased()) }) else { return nil }
            return ChatSearchHit(kind: kind, targetID: message.dmId ?? message.channelId, messageID: message.id, threadRootID: message.threadRootId,
                messageSeq: seq, revision: message.revision, authorAccountID: message.authorAccountId, authorAgentID: message.authorAgentId,
                authorSessionName: message.authorSessionName, createdAt: message.createdAt ?? "", snippet: SearchSnippet.text(message.text, words: query.words))
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            if $0.kind != $1.kind { return $0.kind.rawValue > $1.kind.rawValue }
            return $0.messageID > $1.messageID
        }
    }
}

enum SearchCache {
    static func read<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    static func write<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try queue.write(body) }
}
