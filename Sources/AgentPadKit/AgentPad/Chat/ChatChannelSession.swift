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
    let confirmation = ConfirmationCoordinator()
    var tabID: UUID?
    var showingAgents = false
    private(set) var model: ChatChannelModel?
    private(set) var ownerModel: ChatChannelOwnerModel?

    var pinsShown: Bool {
        !showingAgents && model?.b1?.supports("chat.pins") == true && model?.pins.isPresented == true
    }

    func togglePins() {
        guard let model, model.b1?.supports("chat.pins") == true else { return }
        let wasShown = pinsShown
        showingAgents = false
        if wasShown { model.pins.close() } else { model.pins.open() }
    }

    /// Restore the channel composer before a deferred sidebar mention is
    /// delivered. Both a thread and a pin panel can remove it from the view.
    func showChannelComposer() {
        showingAgents = false
        model?.pins.close()
        model?.openThread(nil)
    }

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
            if ownerModel == nil { ownerModel = ChatChannelOwnerModel(service: service, key: key, channel: card.channelId) }
            model?.setAccessConfirmed(true)
            model?.confirmation = confirmation
            model?.tabID = tabID
        case .notConnected, .noAccess, .noChannels:
            // Hidden until the scope is readable again. Persistent drafts are
            // removed by confirmed membership loss, never by this UI gate.
            model?.setAccessConfirmed(false)
            ownerModel = nil
        }
    }
}
