import Foundation

/// Values only: no model, view, closure, image or service crosses this boundary.
/// Revisions describe presentation, independently of the server message revision.
struct NativeTimelineSnapshot: Equatable, Sendable {
    struct Conversation: Hashable, Sendable {
        enum Address: Hashable, Sendable { case channel(String), directMessage(ChatDMRef) }
        let key: ChatOrgKey
        let address: Address
        let root: String?
    }
    struct RowID: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case message(String), dayBoundary(String), unreadBoundary(String)
            case earlierUnread, olderControl, empty, threadSummary(String), legacyRequest(String), topInset, bottomInset
        }
        let conversation: Conversation
        let kind: Kind
    }
    struct Mention: Equatable, Sendable { let account: String; let handle: String }
    struct Metrics: Equatable, Sendable {
        let displayFont: String
        let monoFont: String
        let scale: Double
        let locale: Locale
        let calendar: Calendar
    }
    struct Color: Equatable, Sendable { let red: Double; let green: Double; let blue: Double; let alpha: Double }
    struct Style: Equatable, Sendable {
        let metrics: Metrics
        let colors: [String: Color]
        let appearance: String
        let increasedContrast: Bool
        let alwaysShowTime: Bool
    }
    struct Position: Equatable, Sendable {
        /// Retain the existing known-ID/sequence bookkeeping across mounts;
        /// copying just the visible fields would count loaded history as new.
        let value: ChatScrollPosition
        var atBottom: Bool { value.atBottom }
        var initialized: Bool { value.initialized }
        var anchor: String? { value.anchor }
        var unseen: Set<String> { value.unseen }

        init(_ value: ChatScrollPosition) { self.value = value }
        init(atBottom: Bool, initialized: Bool, anchor: String?, unseen: Set<String>) {
            var value = ChatScrollPosition()
            value.atBottom = atBottom; value.initialized = initialized
            value.anchor = anchor; value.unseen = unseen
            self.value = value
        }
    }
    struct State: Equatable, Sendable {
        let isDM: Bool
        let archived: Bool
        let hasOlder: Bool
        let earlierUnread: Bool
        let unreadID: String?
        let searching: Bool
        let hasNavigationReturn: Bool
        let position: Position
        let accessibilityLabel: String
        var readingPositionRevision: Int = 0
    }
    struct Availability: Equatable, Sendable {
        let reply: Bool
        let edit: Bool
        let delete: Bool
        let retry: Bool
        let save: Bool
        let recoverEdit: Bool
        let copyLink: String?
    }
    struct Metadata: Equatable, Sendable {
        struct Intent: Equatable, Sendable { let choice: String; let present: Bool; let error: String? }
        let value: ChatB1.Metadata?
        let intents: [Intent]
        let reactionsSupported: Bool
        let pinsSupported: Bool
        let summarySupported: Bool
        let accessible: Bool
        let canChange: Bool
        let loadError: String?
        let problem: String?
    }
    struct Confirmation: Equatable, Sendable {
        enum Phase: Equatable, Sendable { case awaiting, executing, failed(String) }
        let actionID: UUID
        let phase: Phase
        let title: String
        let consequences: String
        let verb: String
        let cancelTitle: String
        let destructive: Bool
    }
    struct SourceStatus: Equatable, Sendable {
        let value: ChatSourceStatus
        let word: String
        let activity: String?
        let connected: Bool
        let canGoToAnswer: Bool
    }
    struct MembershipHint: Equatable, Sendable {
        let agentID: String
        let address: String
        let canAdd: Bool
        let guidance: String
    }
    struct Attachments: Equatable, Sendable {
        /// Quotas govern service operations; rows only render the capability gate.
        /// Retaining their numeric values would invalidate identical file geometry.
        let limitsAvailable: Bool
        let available: Bool
        let availableFileIDs: Set<String>
        let pauseReason: String?
        var problems: [String: String] = [:]
        var busyFileIDs: Set<String> = []

        init(limits: ChatAttachmentLimits?, available: Bool, availableFileIDs: Set<String>, pauseReason: String?, problems: [String: String] = [:], busyFileIDs: Set<String> = []) {
            limitsAvailable = limits != nil
            self.available = available
            self.availableFileIDs = availableFileIDs
            self.pauseReason = pauseReason
            self.problems = problems
            self.busyFileIDs = busyFileIDs
        }
    }
    struct AttachmentOperation: Equatable, Sendable {
        var busy = false
        var retry = 0
    }
    struct MessageContent: Equatable, Sendable {
        let message: ChatMessage
        let author: String
        let authorTooltip: String
        let addresses: [String]
        let replyToText: String?
        let replySummary: ChatReplySummary?
        let replyCount: Int
        let unreadReplyCount: Int
        let requestCount: Int
        let editing: ChatChannelModel.Editing?
        let confirmation: Confirmation?
        let actions: Availability
        let metadata: Metadata?
        let sources: [SourceStatus]
        let membershipHints: [MembershipHint]
        let attachments: Attachments
        // Full ordered representable input: even unmatched addresses can cause
        // TextKit to resize after the initial whole-point reservation.
        var bodyAddresses: [String]? = nil
        var sourcesExpanded = false
        var sourceProblem: String? = nil
    }
    struct Avatar: Equatable, Sendable {
        let reference: ChatAvatarReference
        let metadata: ChatAvatarMetadata?
        let generation: Int
        let context: ChatAvatarContext?
    }
    /// Changes that repaint a row without resetting text or invalidating height.
    struct Visual: Equatable, Sendable {
        let selected: Bool
        let avatars: [Avatar]
        let avatarAccess: Int
        let attachmentPreviews: [String: Data]
        let attachmentEpoch: Int
        let metadataTicket: Int?
        let metadataHead: Int?
        var attachmentOperations: [String: AttachmentOperation] = [:]
    }
    struct Message: Equatable, Sendable {
        let content: MessageContent
        let startsGroup: Bool
        let inThread: Bool
    }
    struct Request: Equatable, Sendable {
        let id: String
        let agentName: String
        let initiatorAccountID: String?
        let ownerAccountID: String?
        let state: String
        let publication: String?
        let publishReason: String?
        let cause: String?
        let title: String
        let stateWord: String
        let help: String
        let canOpenRequest: Bool
        let canOpenSession: Bool
        var problem: String? = nil
    }
    enum Payload: Equatable, Sendable {
        case message(Message)
        case day(Date, label: String)
        case unread, earlierUnread, olderControl(String), empty(String)
        case threadSummary(String), legacyRequest(Request), inset(Double)
    }
    struct Row: Equatable, Sendable {
        let id: RowID
        let contentRevision: UInt64
        let layoutRevision: UInt64
        let payload: Payload
        let visual: Visual?
        var messageID: String? { if case .message(let id) = id.kind { id } else { nil } }
    }
    struct Command: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case reveal(String), edit(String), focusMessage(String), focusArea(Int), restore(Position)
            var slot: Int {
                switch self { case .reveal: 0; case .edit: 1; case .focusMessage: 2; case .focusArea: 3; case .restore: 4 }
            }
        }
        let token: UInt64
        let kind: Kind
    }
    let conversation: Conversation
    let presentationEpoch: UUID
    let generation: UInt64
    let rows: [Row]
    let messageIDs: [String]
    /// Explicit domain-provided replacements only; never guessed from text.
    let messageAliases: [String: String]
    let members: [ChatOrgView.Member]
    let mentionable: [Mention]
    let me: String
    let style: Style
    let state: State
    let commands: [Command]
    var rowIDs: [RowID] { rows.map(\.id) }
}

/// The adapter captures observable inputs on the main actor. This builder owns
/// only values and counters, and never publishes visibility or performs actions.
@MainActor final class ChatTimelineSnapshotBuilder {
    typealias Snapshot = NativeTimelineSnapshot
    struct Navigation: Equatable, Sendable {
        let reveal: String?
        let editing: String?
        let focused: String?
        let focusID: UUID?
        let focusArea: Int?
        let restored: Int
        var revealRequest: UInt64 = 0
    }
    struct Input: Equatable, Sendable {
        let conversation: Snapshot.Conversation
        let epoch: UUID
        let messages: [Snapshot.MessageContent]
        let visuals: [Snapshot.Visual]
        let requests: [Snapshot.Request]
        let threadSummary: String?
        let members: [ChatOrgView.Member]
        let mentionable: [Snapshot.Mention]
        let me: String
        let style: Snapshot.Style
        let state: Snapshot.State
        let navigation: Navigation
        let aliases: [String: String]
        let today: Date
        var reactorAccounts: [String: Set<String>] = [:]
    }
    private var previous: Input?
    private var snapshot: Snapshot?
    private var generation: UInt64 = 0
    private var commandToken: UInt64 = 0
    private var requested: [Snapshot.Command.Kind] = []
    private var layoutMessages: [ChatMessage] = []
    private var layoutUnread: String?
    private var layoutCalendar: Calendar?
    private var layoutRows: [ChatFeedLayout.Row] = []

    private struct MemberInput: Equatable {
        let account: String
        let name: String?
        let handle: String?
    }
    private func members(for content: Snapshot.MessageContent, in input: Input) -> [MemberInput] {
        var ids = Set(content.message.mentions + [content.message.authorAccountId])
        ids.formUnion(content.replySummary?.participants.map(\.authorAccountId) ?? [])
        ids.formUnion(content.metadata?.value?.threadSummary?.lastParticipants.map(\.authorAccountId) ?? [])
        ids.formUnion(input.mentionable.filter { content.addresses.contains($0.handle) }.map(\.account))
        ids.formUnion(input.reactorAccounts[content.message.id] ?? [])
        return ids.sorted().map { id in
            let member = input.members.first { $0.accountId == id }
            return MemberInput(account: id, name: member?.name, handle: member?.handle)
        }
    }

    /// Allows repeated explicit requests for the same target without inventing
    /// a message mutation. W04 consumes tokens once in the native controller.
    func request(_ kind: Snapshot.Command.Kind) {
        guard snapshot != nil else { return }
        requested.removeAll { $0.slot == kind.slot }
        requested.append(kind)
    }

    func build(_ input: Input) -> Snapshot {
        if previous == input, requested.isEmpty, let snapshot { return snapshot }
        generation += 1
        let samePane = previous?.conversation == input.conversation && previous?.epoch == input.epoch
        let oldRows = samePane ? Dictionary(uniqueKeysWithValues: (snapshot?.rows ?? []).map { ($0.id, $0) }) : [:]
        let messages = input.messages.map(\.message)
        if messages != layoutMessages || input.state.unreadID != layoutUnread || input.style.metrics.calendar != layoutCalendar {
            layoutMessages = messages; layoutUnread = input.state.unreadID; layoutCalendar = input.style.metrics.calendar
            layoutRows = ChatFeedLayout.rows(messages, unreadID: input.state.unreadID, calendar: input.style.metrics.calendar)
        }
        let byID = Dictionary(uniqueKeysWithValues: zip(input.messages, input.visuals).map { ($0.0.message.id, ($0.0, $0.1)) })
        var rows: [Snapshot.Row] = []
        func append(_ kind: Snapshot.RowID.Kind, _ payload: Snapshot.Payload, visual: Snapshot.Visual? = nil) {
            let id = Snapshot.RowID(conversation: input.conversation, kind: kind)
            let old = oldRows[id]
            var sameLayout = old?.payload == payload && previous?.style.metrics == input.style.metrics
            var sameContext = true
            if case .message(let message) = payload, let previous {
                let content = message.content
                sameLayout = sameLayout && previous.state.isDM == input.state.isDM
                    && (content.editing == nil || previous.state.archived == input.state.archived)
                    && members(for: content, in: previous) == members(for: content, in: input)
                // Menus depend on read-only/current-account state even when the
                // message's action flags were already disabled for another reason.
                sameContext = previous.state.archived == input.state.archived
                    && (previous.me == content.message.authorAccountId) == (input.me == content.message.authorAccountId)
            }
            let sameContent = sameLayout && sameContext && old?.visual == visual && previous?.style == input.style
            rows.append(.init(id: id, contentRevision: sameContent ? old!.contentRevision : generation,
                              layoutRevision: sameLayout ? old!.layoutRevision : generation, payload: payload, visual: visual))
        }
        append(.topInset, .inset(16))
        if input.state.earlierUnread { append(.earlierUnread, .earlierUnread) }
        if input.state.hasOlder { append(.olderControl, .olderControl(input.conversation.root == nil ? "Load earlier messages" : "Earlier replies")) }
        if messages.isEmpty { append(.empty, .empty(input.conversation.root == nil ? "No messages yet" : "Loading thread…")) }
        // Match the legacy first actual reply, including its original input order.
        let firstReply = input.conversation.root.flatMap { root in messages.first { $0.threadRootId == root }?.id }
        for row in layoutRows {
            if let date = row.date {
                let metrics = input.style.metrics
                let format = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: metrics.locale,
                                              calendar: metrics.calendar, timeZone: metrics.calendar.timeZone)
                let label = (metrics.calendar.isDate(date, inSameDayAs: input.today) ? "Today, " : "") + date.formatted(format)
                append(.dayBoundary(row.id), .day(date, label: label))
            }
            if row.startsUnread { append(.unreadBoundary(row.id), .unread) }
            if row.id == firstReply, let root = input.conversation.root, let summary = input.threadSummary {
                append(.threadSummary(root), .threadSummary(summary))
            }
            if let (content, visual) = byID[row.id] {
                append(.message(row.id), .message(.init(content: content, startsGroup: row.startsGroup, inThread: input.conversation.root != nil)), visual: visual)
            }
        }
        for request in input.requests { append(.legacyRequest(request.id), .legacyRequest(request)) }
        append(.bottomInset, .inset(20))

        var commands = samePane ? snapshot?.commands ?? [] : []
        let before = samePane ? previous?.navigation : nil
        func update(_ changed: Bool, slot: (Snapshot.Command.Kind) -> Bool, kind: Snapshot.Command.Kind?) {
            guard changed else { return }
            commands.removeAll { slot($0.kind) }
            if let kind { commandToken += 1; commands.append(.init(token: commandToken, kind: kind)) }
        }
        let nav = input.navigation
        update(before?.reveal != nav.reveal || before?.revealRequest != nav.revealRequest,
               slot: { if case .reveal = $0 { true } else { false } }, kind: nav.reveal.map { .reveal($0) })
        update(before?.editing != nav.editing, slot: { if case .edit = $0 { true } else { false } }, kind: nav.editing.map { .edit($0) })
        update(before?.focused != nav.focused, slot: { if case .focusMessage = $0 { true } else { false } }, kind: nav.focused.map { .focusMessage($0) })
        update(before?.focusID != nav.focusID, slot: { if case .focusArea = $0 { true } else { false } }, kind: nav.focusArea.map { .focusArea($0) })
        update(before != nil && before?.restored != nav.restored, slot: { if case .restore = $0 { true } else { false } }, kind: .restore(input.state.position))
        if samePane {
            for kind in requested {
                commands.removeAll { $0.kind.slot == kind.slot }
                commandToken += 1; commands.append(.init(token: commandToken, kind: kind))
            }
        }
        requested.removeAll()
        let ids = rows.compactMap(\.messageID)
        let oldIDs = Set(samePane ? snapshot?.messageIDs ?? [] : [])
        let newIDs = Set(ids)
        let aliases = input.aliases.filter { oldIDs.contains($0.key) && !newIDs.contains($0.key) && newIDs.contains($0.value) }
        let result = Snapshot(conversation: input.conversation, presentationEpoch: input.epoch, generation: generation,
                              rows: rows, messageIDs: ids, messageAliases: aliases, members: input.members, mentionable: input.mentionable,
                              me: input.me, style: input.style, state: input.state, commands: commands)
        previous = input; snapshot = result
        return result
    }
}
