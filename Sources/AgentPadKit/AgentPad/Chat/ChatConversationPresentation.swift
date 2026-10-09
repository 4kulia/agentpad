import Foundation

/// Rendering, scrolling, editing and threads are shared. Backends retain their
/// own typed addresses, access gates, observers and command paths.
@MainActor
protocol ChatConversationPresentation: AnyObject {
    var key: ChatOrgKey { get }
    var service: ChatService { get }
    var isDM: Bool { get }
    var feed: ChatChannelModel.Feed { get }
    var b1: ChatB1Channel? { get }
    var confirmation: ConfirmationCoordinator? { get }
    var deletionRoot: String? { get }
    var editing: ChatChannelModel.Editing? { get set }
    var threadRoot: String? { get }
    var threadHasEarlier: Bool { get }
    var threadUnreadID: String? { get }
    var positions: [String: ChatScrollPosition] { get set }
    var focusedMessageID: String? { get }
    var revealMessageID: String? { get }
    var focusRequest: ChatFocusRequest? { get }
    var readingPositionRestored: Int { get }
    var searching: Bool { get }
    var hasNavigationReturn: Bool { get }
    var sourceStatuses: [ChatSourceStatus] { get }
    var threadRequests: [ChatChannelRequests.Card] { get }
    func notificationPlace(root: String?) -> String
    func message(_ id: String) -> ChatMessage?
    func conversationMessages(root: String?) -> [ChatMessage]
    func openThread(_ id: String?)
    func loadOlder()
    func earlierReplies()
    func beginReading(root: String?)
    func endReading(root: String?)
    func readIfLooking(root: String?, appActive: Bool, shown: Bool, atBottom: Bool)
    func markConversationRead(root: String?, clearingBoundary: Bool)
    func finishNavigation()
    @discardableResult func dismissTransient() -> Bool
    func canEdit(_ message: ChatMessage) -> Bool
    func canDelete(_ message: ChatMessage) -> Bool
    func canRetry(_ message: ChatMessage) -> Bool
    @discardableResult func beginEditing(_ message: ChatMessage, root: String?, recovering: Bool) -> Bool
    func cancelEditing(messageID: String?, all: Bool)
    @discardableResult func saveEditing(members: [(account: String, handle: String)]) -> Bool
    @discardableResult func requestDelete(_ message: ChatMessage, root: String?) -> Bool
    func retry(_ message: ChatMessage)
    func discard(_ message: ChatMessage)
    func discardEdit(_ message: ChatMessage)
}

extension ChatConversationPresentation {
    func cancelEditing() { cancelEditing(messageID: nil, all: false) }
    @discardableResult func beginEditing(_ message: ChatMessage, root: String?) -> Bool { beginEditing(message, root: root, recovering: false) }
    func markConversationRead(root: String?) { markConversationRead(root: root, clearingBoundary: true) }
    func copyText(_ shown: ChatMessage) -> String? {
        guard let current = message(shown.id), !current.deleted, !current.loading else { return nil }
        return current.text
    }
}

extension ChatChannelModel: ChatConversationPresentation {
    var isDM: Bool { false }
    func notificationPlace(root: String?) -> String { root.map { "t:\($0)" } ?? "c:\(channel)" }
    func canRetry(_ message: ChatMessage) -> Bool { service.canRetryPost(key, row: message) }
    func canDelete(_ message: ChatMessage) -> Bool {
        message.authorAccountId == key.accountId && message.hasFixed && !message.deleted && !message.changing && message.localState == nil
    }
}
