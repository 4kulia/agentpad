import AgentPadTelegram
import SwiftUI

/// Backend-independent navigation and viewport contract. AgentPad retains its
/// server read semantics; Telegram never synthesizes a ChatOrgKey or seq.
enum ConversationDestination: Hashable {
    case channel(ChatOrgKey, chat: String, thread: String?)
    case directMessage(ChatDMRef, thread: String?)
    case telegram(TelegramChatID)
}

struct PresentationObservation {
    let destination: ConversationDestination
    let epoch: UUID
    let pane: UUID
    let active: Bool
    let shown: Bool
    let ordinaryIDs: Set<String>
    var readableIDs: Set<String> { active && shown ? ordinaryIDs : [] }
}

struct ConversationSnapshot {
    let destination: ConversationDestination
    let epoch: UUID
    let revision: UInt64
    let rows: [ConversationRow]
    let hasOlder: Bool
    let draftRevision: UUID?
    let presence: String
    let canSend: Bool
}

enum ConversationRow: Identifiable {
    case message(String), service(String), unsupported(String)
    case sponsored(TelegramSponsoredRef)
    var id: String { switch self { case .message(let id), .service(let id), .unsupported(let id): id; case .sponsored(let ref): ref.id } }
}

@MainActor protocol ConversationActions: AnyObject {
    var presentation: ConversationSnapshot { get }
    func loadOlder()
    func send()
    func reply(to id: String)
    func retry(_ id: String)
}

/// Frames describe content, not lazy-row registration. A header/avatar alone
/// is insufficient to read a message. Both timelines share these primitives.
struct ConversationFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, rhs in rhs })
    }
    static func visible(_ frames: [String: CGRect], viewport: CGRect) -> Set<String> {
        Set(frames.filter { !$0.value.isEmpty && !$0.value.intersection(viewport).isEmpty && !$0.value.intersection(viewport).isNull }.keys)
    }
    static func anchor(_ frames: [String: CGRect], viewport: CGRect) -> String? {
        let ids = visible(frames, viewport: viewport)
        return frames.filter { ids.contains($0.key) }.min { $0.value.minY < $1.value.minY }?.key
    }
    static func fullyVisible(_ frame: CGRect, viewport: CGRect) -> Bool {
        !frame.isEmpty && !frame.isInfinite && !frame.isNull && viewport.contains(frame)
    }
}

extension ChatConversationPresentation {
    /// The existing backend keeps its feed, seq/read gates and drafts. Only
    /// presentation identity, rows and viewport facts cross the shared seam.
    func presentation(root: String?, epoch: UUID, revision: UInt64) -> ConversationSnapshot {
        .init(destination: destination(root: root), epoch: epoch, revision: revision,
              rows: conversationMessages(root: root).map { $0.loading ? .unsupported($0.id) : .message($0.id) },
              hasOlder: root == nil ? feed.hasOlder : threadHasEarlier, draftRevision: nil, presence: "", canSend: !feed.archived)
    }
}

@MainActor protocol ConversationAttachmentBackend: AnyObject {
    associatedtype Message
    var importing: Bool { get }
    func importFiles(_ inputs: [ChatAttachmentWorker.Input])
    func removeFile(_ id: UUID)
    func download(_ message: Message, cancel: Bool)
    func preview(_ message: Message)
    func save(_ message: Message)
}
