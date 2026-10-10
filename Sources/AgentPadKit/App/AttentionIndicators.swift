import Foundation

/// A readout of eligible reasons, never an acknowledgement store.
struct AttentionIndicator: Equatable, Sendable {
    enum Kind: Int, CaseIterable, Comparable, Sendable {
        case needsInput, failed, finished, unread
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        init?(_ kind: AttentionKind) {
            switch kind {
            case .input, .decision, .folder, .publicationReview, .confirmation: self = .needsInput
            case .failure, .recovery: self = .failed
            case .completion: self = .finished
            case .mention, .dm: self = .unread
            default: return nil
            }
        }
        var label: String {
            switch self {
            case .needsInput: return "Needs input or approval"
            case .failed: return "Failed — not viewed"
            case .finished: return "Turn finished — waiting for you"
            case .unread: return "Unread activity"
            }
        }
    }
    struct Reason: Equatable, Sendable {
        var id: String
        var kind: Kind
        var summary: String
        var titleTabID: UUID?
        var conversation: AttentionTabDestination?
        var readMarks: [String: Int] = [:]
    }
    let kind: Kind
    let reasons: [Reason]
    let reasonIDs: [String]
    let accessibleSummary: String

    init?(_ reasons: [Reason]) {
        var seen = Set<String>()
        let unique = reasons.filter { seen.insert($0.id).inserted }.sorted {
            $0.kind == $1.kind ? $0.id < $1.id : $0.kind < $1.kind
        }
        guard let first = unique.first else { return nil }
        kind = first.kind; self.reasons = unique
        reasonIDs = unique.map(\.id)
        accessibleSummary = Kind.allCases.compactMap { kind in
            let count = unique.filter { $0.kind == kind }.count
            return count > 0 ? "\(kind.label): \(count)" : nil
        }.joined(separator: "; ")
    }

    /// Terminal names change independently of the reasons that own a mark.
    func tooltip(titleForTab: (UUID) -> String?) -> String {
        reasons.map { reason in
            let title = reason.titleTabID.flatMap(titleForTab)
            return (title.map { $0 + ": " } ?? "") + reason.summary
        }.joined(separator: "\n")
    }
}

struct AttentionWorkspaceID: Hashable, Sendable {
    var window: UUID
    var workspace: UUID
}

/// Scope includes the cache generation; names never identify a destination.
enum AttentionTabDestination: Hashable, Sendable {
    case tab(UUID)
    case channel(AttentionScope, String)
    case dm(AttentionScope, String)
    case request(TeamScope, String)

    @MainActor static func event(_ event: AttentionEvent) -> [Self] {
        switch event.destination {
        case .terminal(let id), .tabAction(let id, _): return [.tab(id)]
        case .message(let channel, _, _, _): return event.scope.map { [.channel($0, channel)] } ?? []
        case .directMessage(let dm, _, _, _): return event.scope.map { [.dm($0, dm)] } ?? []
        case .channel(let channel, let request):
            guard let scope = event.scope, let key = ChatAttention.key(scope) else { return [] }
            return [.channel(scope, channel), .request(.server(OrgKey(key)), request)]
        case .team(let request?, _), .folder(_, let request):
            if let scope = event.scope, let key = ChatAttention.key(scope) { return [.request(.server(OrgKey(key)), request)] }
            return [.request(.local, request)]
        default: return []
        }
    }
}

struct AttentionTabSnapshot: Equatable, Sendable {
    var id: UUID
    var owner: AttentionWorkspaceID
    var pane: UUID
    var available: Bool
    var destinations: [AttentionTabDestination]
    var channel: ChannelRef? = nil
}
