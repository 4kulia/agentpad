import Foundation
import GRDB
import Observation
import XCTest
@testable import AgentPadKit

@MainActor @Observable final class ChatTimelineW01Model: ChatConversationPresentation {
    static let channel = "w01-channel"
    static let dm = "w01-direct-message"
    let key: ChatOrgKey
    var service: ChatService
    var channel = ChatTimelineW01Model.channel
    var isDM = false
    var feed = ChatChannelModel.Feed()
    var b1: ChatB1Channel?
    var confirmation: ConfirmationCoordinator?
    var deletionRoot: String?
    var editing: ChatChannelModel.Editing?
    var threadRoot: String?
    var threadHasEarlier = false
    var threadUnreadID: String?
    var positions: [String: ChatScrollPosition] = [:]
    var focusedMessageID: String?
    var revealMessageID: String?
    var focusRequest: ChatFocusRequest?
    var readingPositionRestored = 0
    var searching = false
    var hasNavigationReturn = false
    var sourceStatuses: [ChatSourceStatus] = []
    var threadRequests: [ChatChannelRequests.Card] = []
    var editable = true
    var deletable = true
    var retryable = true
    var events: [String] = []
    var readingCalls: [String] = []

    init(directory: URL, key: ChatOrgKey? = nil, service: ChatService? = nil) {
        self.key = key ?? ChatOrgKey(server: try! ChatServerAddress(parsing: "https://timeline.invalid"), accountId: "w01-me", orgId: "w01-org")
        self.service = service ?? ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        feed.archived = false
    }
    func destination(root: String?) -> ConversationDestination {
        isDM ? .directMessage(ChatDMRef(key, dm: Self.dm), thread: root) : .channel(key, chat: channel, thread: root)
    }
    func notificationPlace(root: String?) -> String { "w01:\(isDM):\(root ?? "feed")" }
    func message(_ id: String) -> ChatMessage? { feed.messages.first { $0.id == id } }
    func conversationMessages(root: String?) -> [ChatMessage] {
        feed.messages.filter { root == nil ? $0.threadRootId == nil : $0.id == root || $0.threadRootId == root }
    }
    func openThread(_ id: String?) { events.append("thread:\(id ?? "nil")"); threadRoot = id }
    func loadOlder() { events.append("older:feed") }
    func earlierReplies() { events.append("older:thread") }
    func beginReading(root: String?) { readingCalls.append("begin:\(root ?? "feed")") }
    func endReading(root: String?) { readingCalls.append("end:\(root ?? "feed")") }
    func readIfLooking(root: String?, appActive: Bool, shown: Bool, atBottom: Bool) {
        readingCalls.append("read:\(root ?? "feed"):\(appActive):\(shown):\(atBottom)")
    }
    func markConversationRead(root: String?, clearingBoundary: Bool) { events.append("read:\(root ?? "feed"):\(clearingBoundary)") }
    func finishNavigation() { events.append("finish") }
    func dismissTransient() -> Bool { events.append("dismiss"); return true }
    func canEdit(_ message: ChatMessage) -> Bool { editable && !message.deleted && message.localState == nil }
    func canDelete(_ message: ChatMessage) -> Bool { deletable && !message.deleted && message.localState == nil }
    func canRetry(_ message: ChatMessage) -> Bool { retryable }
    func beginEditing(_ message: ChatMessage, root: String?, recovering: Bool) -> Bool {
        events.append("edit:\(message.id):\(root ?? "feed"):\(recovering)")
        editing = .init(messageId: message.id, root: root, text: message.localEdit?.text ?? message.text,
                        revision: message.revision, message: message, version: "w01-edit-v1")
        return true
    }
    func cancelEditing(messageID: String?, all: Bool) { events.append("cancel:\(messageID ?? "nil"):\(all)"); editing = nil }
    func saveEditing(members: [(account: String, handle: String)]) -> Bool {
        events.append("save:" + members.map { "\($0.account)=\($0.handle)" }.joined(separator: ",")); return true
    }
    func requestDelete(_ message: ChatMessage, root: String?) -> Bool {
        guard let current = self.message(message.id), canDelete(current), current.revision == message.revision else { return false }
        events.append("delete:\(message.id):\(root ?? "feed")"); return true
    }
    func retry(_ message: ChatMessage) { events.append("retry:\(message.id)") }
    func discard(_ message: ChatMessage) { events.append("discard:\(message.id)") }
    func discardEdit(_ message: ChatMessage) { events.append("discard-edit:\(message.id)") }
}

@MainActor enum ChatTimelineW01 {
    typealias S = NativeTimelineSnapshot
    static let epoch = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let otherEpoch = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let day = Date(timeIntervalSince1970: 1_791_288_000)
    static let members: [ChatOrgView.Member] = [.init(accountId: "w01-me", handle: "anna", name: "Anna", role: "owner")]
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    static func style(scale: Double = 2, appearance: String = "Aqua", alwaysShowTime: Bool = false) -> S.Style {
        .init(metrics: .init(displayFont: "Fixture Display", monoFont: "Fixture Mono", scale: scale,
                            locale: Locale(identifier: "en_US_POSIX"), calendar: calendar),
              colors: ["foreground": .init(red: 0, green: 0, blue: 0, alpha: 1)],
              appearance: appearance, increasedContrast: false, alwaysShowTime: alwaysShowTime)
    }
    static func message(_ id: String, seq: Int? = 1, root: String? = nil, day: String = "2026-10-06T12:00:00Z", dm: Bool = false) -> ChatMessage {
        var result = ChatMessage(row: Row(["message_id": id, "channel_id": dm ? "" : ChatTimelineW01Model.channel,
            "thread_root_id": root, "author_account_id": "w01-me", "seq": seq, "created_at": day,
            "has_fixed": true, "has_mutable": true, "text": "Text \(id)", "mentions": "[]", "revision": 1]))
        result.dmId = dm ? ChatTimelineW01Model.dm : nil
        return result
    }
    static func content(_ message: ChatMessage, author: String = "Anna", metadata: S.Metadata? = nil,
                        editing: ChatChannelModel.Editing? = nil, adapter: Bool = false, dm: Bool = false) -> S.MessageContent {
        .init(message: message, author: author, authorTooltip: "\(author) · @anna · w01-me", addresses: [],
              replyToText: nil, replySummary: nil, replyCount: 0, unreadReplyCount: 0, requestCount: 0,
              editing: editing, confirmation: nil,
              actions: .init(reply: message.hasFixed && !message.deleted && message.localState == nil,
                  edit: !message.deleted && message.localState == nil && editing == nil,
                  delete: !message.deleted && message.localState == nil, retry: adapter, save: !message.deleted && message.localState == nil,
                  recoverEdit: editing == nil,
                  copyLink: adapter && !dm && message.seq != nil ? "agentpad://chat?server=https://timeline.invalid:443&org=w01-org&channel=w01-channel&message=\(message.id)&seq=\(message.seq!)" : nil),
              metadata: metadata, sources: [], membershipHints: [],
              attachments: .init(limits: nil, available: false, availableFileIDs: [], pauseReason: nil),
              bodyAddresses: adapter && !message.deleted && (message.hasMutable || message.localState != nil) ? ["anna"] : nil)
    }
    static func visual(selected: Bool = false, message: ChatMessage? = nil, key: ChatOrgKey? = nil,
                       avatarAccess: Int = 0, avatarGeneration: Int = 0) -> S.Visual {
        .init(selected: selected, avatars: message.flatMap { message in key.map { key in
            [.init(reference: .init(key: key, subject: .account(message.authorAccountId)), metadata: nil, generation: avatarGeneration, context: nil)]
        } } ?? [], avatarAccess: avatarAccess, attachmentPreviews: [:], attachmentEpoch: 0, metadataTicket: nil, metadataHead: nil)
    }
    static func state(dm: Bool = false, root: String? = nil, older: Bool = false, earlierUnread: Bool = false, unread: String? = nil) -> S.State {
        .init(isDM: dm, archived: false, hasOlder: older, earlierUnread: earlierUnread, unreadID: unread,
              searching: false, hasNavigationReturn: false,
              position: .init(atBottom: false, initialized: false, anchor: nil, unseen: []),
              accessibilityLabel: root == nil ? (dm ? "Direct messages" : "Channel messages") : "Thread messages")
    }
    static func conversation(dm: Bool = false, root: String? = nil) -> S.Conversation {
        let key = ChatOrgKey(server: try! ChatServerAddress(parsing: "https://timeline.invalid"), accountId: "w01-me", orgId: "w01-org")
        return .init(key: key, address: dm ? .directMessage(ChatDMRef(key, dm: ChatTimelineW01Model.dm)) : .channel(ChatTimelineW01Model.channel), root: root)
    }
    static func input(messages: [S.MessageContent], visuals: [S.Visual]? = nil, dm: Bool = false, root: String? = nil,
                      epoch: UUID = ChatTimelineW01.epoch, style: S.Style = ChatTimelineW01.style(), state: S.State? = nil,
                      members: [ChatOrgView.Member] = ChatTimelineW01.members, aliases: [String: String] = [:],
                      navigation: ChatTimelineSnapshotBuilder.Navigation = .init(reveal: nil, editing: nil, focused: nil, focusID: nil, focusArea: nil, restored: 0),
                      requests: [S.Request] = []) -> ChatTimelineSnapshotBuilder.Input {
        .init(conversation: conversation(dm: dm, root: root), epoch: epoch, messages: messages,
              visuals: visuals ?? messages.map { _ in visual() }, requests: requests, threadSummary: root == nil ? nil : "2 replies",
              members: members, mentionable: [.init(account: "w01-me", handle: "anna")], me: "w01-me", style: style,
              state: state ?? self.state(dm: dm, root: root), navigation: navigation, aliases: aliases, today: day)
    }
    static func row(_ kind: S.RowID.Kind, _ payload: S.Payload, conversation: S.Conversation = conversation(),
                    content: UInt64 = 1, layout: UInt64 = 1, visual: S.Visual? = nil) -> S.Row {
        .init(id: .init(conversation: conversation, kind: kind), contentRevision: content, layoutRevision: layout, payload: payload, visual: visual)
    }
    static func expected(rows: [S.Row], ids: [String], generation: UInt64 = 1, dm: Bool = false, root: String? = nil,
                         epoch: UUID = ChatTimelineW01.epoch, style: S.Style = ChatTimelineW01.style(), state: S.State? = nil,
                         members: [ChatOrgView.Member] = ChatTimelineW01.members, aliases: [String: String] = [:], commands: [S.Command] = []) -> S {
        .init(conversation: conversation(dm: dm, root: root), presentationEpoch: epoch, generation: generation, rows: rows,
              messageIDs: ids, messageAliases: aliases, members: members, mentionable: [.init(account: "w01-me", handle: "anna")],
              me: "w01-me", style: style, state: state ?? self.state(dm: dm, root: root), commands: commands)
    }
}
