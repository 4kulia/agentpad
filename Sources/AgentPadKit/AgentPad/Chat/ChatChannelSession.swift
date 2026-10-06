import Foundation
import Observation

enum ChatFocusArea: Int, CaseIterable {
    case navigation, feed, thread, composer
    var title: String {
        switch self {
        case .navigation: "Focus Chat Navigation"
        case .feed: "Focus Chat Feed"
        case .thread: "Focus Chat Thread"
        case .composer: "Focus Chat Composer"
        }
    }
}

struct ChatFocusRequest: Equatable {
    let area: ChatFocusArea
    let id = UUID()
}

/// Owned by the tab engine, outside the conditional F2 ready view. A snapshot
/// may hide the content temporarily without discarding its edit or position.
@MainActor @Observable
final class ChatChannelSession {
    private(set) var model: ChatChannelModel?
    private(set) var ownerModel: ChatChannelOwnerModel?

    func update(_ state: ChannelTabState, key: ChatOrgKey?, store: ChatStore?, service: ChatService) {
        switch state {
        case .checking: model?.setAccessConfirmed(false)
        case .ready(let card, _, _):
            guard let key, let store else { return }
            if model?.key != key || model?.channel != card.channelId {
                // ChannelTabEngine has an immutable ref: a different scope
                // here is a lost identity/access context, never navigation.
                model?.setAccessConfirmed(false)
                model?.cancelEditing(all: true)
                let made = ChatChannelModel(key: key, channel: card.channelId)
                made.service = service
                made.follow(store)
                model = made
                ownerModel = ChatChannelOwnerModel(service: service, key: key, channel: card.channelId)
            } else if model?.follows(store) != true {
                model?.setAccessConfirmed(false)
                model?.follow(store)
            }
            model?.setAccessConfirmed(true)
        case .notConnected, .noAccess, .noChannels:
            model?.setAccessConfirmed(false)
            model?.cancelEditing(all: true)
            model = nil
            ownerModel = nil
        }
    }
}
