import AppKit
import AgentPadQuietTestSupport
import GRDB
import Observation
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
@Observable final class ChatScrollFixture: ChatConversationPresentation {
    let key = ChatOrgKey(server: try! ChatServerAddress(parsing: "https://chat.example.com"), accountId: "fixture-me", orgId: "fixture-org")
    let service: ChatService
    let isDM = false
    var feed = ChatChannelModel.Feed()
    var b1: ChatB1Channel? { nil }
    var confirmation: ConfirmationCoordinator? { nil }
    var deletionRoot: String? { nil }
    var editing: ChatChannelModel.Editing?
    var threadRoot: String?
    var threadHasEarlier: Bool { feed.hasOlder }
    var threadUnreadID: String? { feed.unreadID }
    var positions: [String: ChatScrollPosition] = [:]
    var focusedMessageID: String?
    var revealMessageID: String?
    var focusRequest: ChatFocusRequest?
    var readingPositionRestored = 0
    var searching = false
    var hasNavigationReturn = false
    var sourceStatuses: [ChatSourceStatus] { [] }
    var threadRequests: [ChatChannelRequests.Card] { [] }
    var root: String?
    init(root: String?, directory: URL) {
        self.root = root; threadRoot = root
        service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        feed.messages = (40..<360).map { Self.message($0, root: root) }
        feed.hasOlder = true; feed.archived = false; feed.unreadID = "fixture-190"
    }
    static func message(_ index: Int, root: String?) -> ChatMessage {
        let text: String
        switch index % 6 {
        case 0: text = "One line \(index)."
        case 1: text = String(repeating: "A **long paragraph** with [a link](https://example.com), _emphasis_ and enough words to wrap. ", count: 16)
        case 2: text = "```swift\n" + (0..<18).map { "let value\($0) = \($0) // fixture code" }.joined(separator: "\n") + "\n```"
        case 3: text = "> Quoted context\n\n- first item\n- second item\n\n# Heading\n\nFollow-up \(index)"
        case 4: text = "[Attachment reference](https://example.com/file)\n\n" + String(repeating: "Short wrap. ", count: 18)
        default: text = "Message \(index) with `inline code`."
        }
        return ChatMessage(row: Row(["message_id": "fixture-\(index)", "channel_id": "fixture-channel", "thread_root_id": root,
            "author_account_id": index % 3 == 0 ? "fixture-other" : "fixture-me", "seq": index + 1,
            "created_at": "2026-10-21T12:00:00Z", "has_fixed": true, "has_mutable": true,
            "text": text, "mentions": "[]", "revision": 1]))
    }
    func notificationPlace(root: String?) -> String { "fixture-" + (root ?? "channel") }
    func destination(root: String?) -> ConversationDestination { .channel(key, chat: "fixture-channel", thread: root) }
    func message(_ id: String) -> ChatMessage? { feed.messages.first { $0.id == id } }
    func conversationMessages(root: String?) -> [ChatMessage] { feed.messages }
    func openThread(_ id: String?) { threadRoot = id }
    func loadOlder() { feed.messages.insert(contentsOf: (0..<40).map { Self.message($0, root: root) }, at: 0); feed.hasOlder = false }
    func earlierReplies() { loadOlder() }
    func beginReading(root: String?) {}
    func endReading(root: String?) {}
    func readIfLooking(root: String?, appActive: Bool, shown: Bool, atBottom: Bool) {}
    func markConversationRead(root: String?, clearingBoundary: Bool) {}
    func finishNavigation() { revealMessageID = nil }
    func dismissTransient() -> Bool { false }
    func canEdit(_ message: ChatMessage) -> Bool { true }
    func canDelete(_ message: ChatMessage) -> Bool { false }
    func canRetry(_ message: ChatMessage) -> Bool { false }
    func beginEditing(_ message: ChatMessage, root: String?, recovering: Bool) -> Bool { false }
    func cancelEditing(messageID: String?, all: Bool) { editing = nil }
    func saveEditing(members: [(account: String, handle: String)]) -> Bool { false }
    func requestDelete(_ message: ChatMessage, root: String?) -> Bool { false }
    func retry(_ message: ChatMessage) {}
    func discard(_ message: ChatMessage) {}
    func discardEdit(_ message: ChatMessage) {}
}
