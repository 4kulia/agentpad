import Foundation
import GRDB
import Observation

/// The native surfaces observe one shared projection and one shared pending intent.
@MainActor @Observable
final class ChatB1Channel {
    struct Intent: Equatable { var choice: String; var present: Bool; var error: String? }
    struct Version: Hashable { var ticket: Int; var head: Int }
    struct State: Equatable {
        var metadata: [String: ChatB1.Metadata] = [:]
        var versions: [String: Version] = [:]
        var pins: [ChatB1.PinnedMessage]?
        var pinMessages: [String: ChatMessage] = [:]
        var bannerHidden = false
        var loadError: String?
        var intents: [String: [Intent]] = [:]
        var accessible = false
    }
    let key: ChatOrgKey
    let channel: String
    let store: ChatStore
    let service: ChatService
    private var cachedState = State()
    var state: State {
        // The synchronous service gate also covers a failed rights-doubt write
        // and the interval before the database observation reaches this window.
        if let session = service.orgSessions[key], session.doubtNotWritten || session.snapshotOwed { return State() }
        return cachedState
    }
    private var problems: [String: String] = [:]
    func problem(_ message: String) -> String? { problems[message] }
    private let owner = UUID()
    private let pinsOwner = UUID()
    private var pinReadRevisions: [String: Int] = [:]
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    private var reader: ChatB1Sync? { service.orgSessions[key]?.sync?.b1 }

    init(key: ChatOrgKey, channel: String, store: ChatStore, service: ChatService) {
        self.key = key; self.channel = channel; self.store = store; self.service = service
        observation = ValueObservation.tracking { db -> State in
            guard try ChatB1.readToken(db, channel: channel) != nil else { return State() }
            var state = State(accessible: true)
            state.bannerHidden = try ChatPins.bannerHidden(db, channel: channel)
            state.loadError = try String.fetchOne(db, sql: "SELECT error FROM b1_pins WHERE channel_id = ? AND error IS NOT NULL UNION SELECT error FROM b1_metadata WHERE channel_id = ? AND error IS NOT NULL LIMIT 1", arguments: [channel, channel])
            for row in try Row.fetchAll(db, sql: "SELECT message_id, data, ticket, as_of_seq FROM b1_metadata WHERE channel_id = ?", arguments: [channel]) {
                state.versions[row["message_id"]] = Version(ticket: row["ticket"], head: row["as_of_seq"])
                if let data: Data = row["data"] { state.metadata[row["message_id"]] = try JSONDecoder().decode(ChatB1.Metadata.self, from: data) }
            }
            if let data = try Data.fetchOne(db, sql: "SELECT data FROM b1_pins WHERE channel_id = ?", arguments: [channel]) {
                state.pins = try JSONDecoder().decode([ChatB1.PinnedMessage].self, from: data)
            }
            for pin in state.pins ?? [] {
                if let row = try Row.fetchOne(db, sql: "\(ChatMessages.select) WHERE m.channel_id = ? AND m.message_id = ?", arguments: [channel, pin.id]) {
                    state.pinMessages[pin.id] = ChatMessage(row: row)
                }
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT i.*, o.state, o.error FROM b1_intents i JOIN outbox o USING(command_id) WHERE i.channel_id = ?
                """, arguments: [channel]) {
                let error: String? = (row["state"] as String) == "pending" ? nil : ((row["error"] as String?) ?? "Change not confirmed. Try again.")
                state.intents[row["message_id"], default: []].append(Intent(choice: row["choice"], present: row["present"], error: error))
            }
            return state
        }.removeDuplicates().start(in: store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] value in self?.cachedState = value }
    }
    func supports(_ capability: String) -> Bool { service.supports(capability, key: key) }
    var canChange: Bool {
        state.accessible && service.socket?.state == .connected && ChatNotifications.allowed(service, key, channel: channel)
            && (try? store.queue.read { db in
                try Bool.fetchOne(db, sql: "SELECT NOT c.archived AND t.archived_at IS NULL FROM channels c JOIN teams t USING(team_id) WHERE c.channel_id = ?", arguments: [channel])
            }) == true
    }
    func show(_ ids: Set<String>) { reader?.show(owner, channel: channel, ids: ids) }
    func hideMetadata() { reader?.hide(owner) }
    func hide() { hideMetadata(); reader?.hide(pinsOwner); pinReadRevisions = [:] }
    func retryReads() {
        try? store.queue.write { db in
            for table in ["b1_metadata", "b1_pins"] {
                try db.execute(sql: "UPDATE \(table) SET error = NULL, dirty = 1, ticket = ticket + 1 WHERE channel_id = ?", arguments: [channel])
            }
        }
        reader?.schedule()
    }
    func showPins(_ shown: Bool) { reader?.showPins(pinsOwner, channel: channel, shown: shown) }
    func setBannerHidden(_ hidden: Bool) {
        guard state.accessible else { return }
        try? store.queue.write { try ChatPins.setBannerHidden($0, channel: channel, hidden: hidden) }
    }
    /// Uses the same guarded, deduplicated reads as conversation navigation,
    /// without changing the selected message, thread, draft or read marks.
    func loadPinBodies(retry: Bool = false) {
        guard state.accessible, supports("chat.pins"), service.socket?.state == .connected,
              let sync = service.orgSessions[key]?.sync else { return }
        let missing = ChatPins.missing(state.pins ?? [], messages: state.pinMessages)
        let ids = Set(missing.map(\.id))
        pinReadRevisions = retry ? [:] : pinReadRevisions.filter { ids.contains($0.key) }
        for read in missing where pinReadRevisions[read.id] != read.revision {
            pinReadRevisions[read.id] = read.revision
            sync.readOne(channel, id: read.id, seq: read.sequence, atLeast: read.revision)
        }
    }
    func unpin(_ message: String) { set(message, choice: "pin", present: false) }
    func pending(_ message: String, choice: String) -> Bool {
        state.intents[message]?.contains { $0.choice == choice && $0.error == nil } == true
    }
    func toggle(_ message: String, emoji: String) {
        guard let canonical = ChatEmoji.canonical(emoji) else { problems[message] = "Choose one emoji."; return }
        let mine = state.metadata[message]?.reactions.first { $0.emoji == canonical }?.mine ?? false
        set(message, choice: canonical, present: !mine)
    }
    func togglePin(_ message: String) { set(message, choice: "pin", present: state.metadata[message]?.pin == nil) }
    private func set(_ message: String, choice: String, present: Bool) {
        do {
            guard canChange else { throw ChatError.storage("Connect to change reactions or pins.") }
            try service.setB1(key, channel: channel, message: message, choice: choice, present: present)
            problems[message] = nil
        } catch { problems[message] = error.localizedDescription }
    }
    func reactors(message: String, emoji: String, after: String?, at: Int?) async throws -> ChatB1.ReactorsPage {
        guard let reader else { throw ChatError.notConnected }
        return try await reader.reactors(channel: channel, message: message, emoji: emoji, after: after, at: at)
    }
}

/// Ephemeral pages belong to one panel. An invalidation can replace a request
/// still in flight without letting its old completion overwrite the new list.
@MainActor @Observable
final class ChatReactionAccounts {
    let b1: ChatB1Channel
    let message: String
    let emoji: String
    private var loadedAccounts: [String] = []
    var accounts: [String] { b1.state.accessible && b1.supports("chat.reactions") ? loadedAccounts : [] }
    private(set) var next: String?
    private var head: Int?
    private(set) var loading = false
    private(set) var error: String?
    private var request = UUID()
    @ObservationIgnored private var accessObservation: AnyDatabaseCancellable?
    init(b1: ChatB1Channel, message: String, emoji: String) {
        self.b1 = b1; self.message = message; self.emoji = emoji
        let channel = b1.channel
        accessObservation = ValueObservation.tracking { try ChatB1.readToken($0, channel: channel) }
            .removeDuplicates().start(in: b1.store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] _ in self?.clear() }
    }
    func clear() { request = UUID(); loadedAccounts = []; head = nil; next = nil; loading = false; error = nil }
    func load(restart: Bool, restarts: Int = 0) async {
        guard b1.state.accessible, b1.supports("chat.reactions") else { clear(); return }
        guard restart || !loading else { return }
        let current = UUID(); request = current
        loading = true; error = nil
        defer { if request == current { loading = false } }
        if restart { loadedAccounts = []; next = nil; head = nil }
        do {
            let page = try await b1.reactors(message: message, emoji: emoji, after: next, at: head)
            guard request == current, !Task.isCancelled, b1.state.accessible else { return }
            loadedAccounts += page.accountIds.filter { !loadedAccounts.contains($0) }; head = page.asOfSeq; next = page.next
        } catch ChatAPIError.server(_, "snapshot_changed", _) {
            guard request == current, !Task.isCancelled else { return }
            loadedAccounts = []; head = nil; next = nil; loading = false
            if restarts < 2 { await load(restart: true, restarts: restarts + 1) }
            else { error = "Reactions changed. Please retry." }
        } catch {
            if request == current, !Task.isCancelled { self.error = "Could not load reactions." }
        }
    }
}

enum ChatEmoji {
    private struct Fixture: Decodable { var version: String; var aliases: [String: String] }
    static let aliases: [String: String] = {
        guard let url = agentPadResourceBundle()?.url(forResource: "emoji-16.0", withExtension: "json"),
              let data = try? Data(contentsOf: url), let fixture = try? JSONDecoder().decode(Fixture.self, from: data), fixture.version == "16.0" else { return [:] }
        return fixture.aliases
    }()
    static let quick = ["👍", "❤️", "😂", "🎉", "✨", "👀"]
    static func canonical(_ input: String) -> String? {
        guard input.utf8.count <= 128 else { return nil }
        return aliases[input.precomposedStringWithCanonicalMapping]
    }
}

extension ChatService {
    func clearB1PrivateState(_ key: ChatOrgKey) {
        try? orgSessions[key]?.store?.queue.write { db in
            try db.execute(sql: "UPDATE meta SET rights_in_doubt = 1 WHERE id = 1")
            try db.execute(sql: "DELETE FROM edit_drafts")
            try ChatB1.cancelIntents(db, condition: "1")
            try ChatB1.reset(db)
        }
    }

    func setB1(_ key: ChatOrgKey, channel: String, message: String, choice: String, present: Bool) throws {
        let pin = choice == "pin", type = pin ? "message.pin.set" : "message.reaction.set"
        guard supports(ChatB1.capability(for: type), key: key), socket?.state == .connected,
              ChatNotifications.allowed(self, key, channel: channel), let store = orgSessions[key]?.store else { throw ChatError.notConnected }
        let canonical = pin ? "pin" : ChatEmoji.canonical(choice)
        guard let canonical else { throw ChatError.storage("Choose one emoji.") }
        var args: [String: ChatJSON] = ["channel_id": .string(channel), "message_id": .string(message), "present": .bool(present)]
        if !pin { args["emoji"] = .string(canonical) }
        let prepared = try prepareCommand(key, type: type, args: .object(args))
        var record = prepared.record
        record.orderKey = "b1:\(message):\(canonical)"
        try store.queue.write { db in
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM messages m JOIN channels c USING(channel_id) JOIN teams t USING(team_id)
                    WHERE m.message_id = ? AND m.channel_id = ? AND m.deleted_at IS NULL AND m.has_fixed = 1
                    AND NOT c.archived AND t.archived_at IS NULL AND t.mine = 1)
                """, arguments: [message, channel]) == true else { throw ChatError.storage("This message cannot be changed.") }
            let busy = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM b1_intents i JOIN outbox o USING(command_id)
                    WHERE i.message_id = ? AND i.choice = ? AND o.state = 'pending')
                """, arguments: [message, canonical]) == true
            guard !busy else { throw ChatChangeError.busy }
            try db.execute(sql: "INSERT OR REPLACE INTO b1_intents (command_id, channel_id, message_id, choice, present) VALUES (?, ?, ?, ?, ?)",
                           arguments: [record.commandId, channel, message, canonical, present])
            _ = try prepared.table.insert(db, record, seq: record.seq)
        }
        prepared.sent()
    }
    func installB1() {
        for type in ChatB1.commands {
            commandOwners[type] = { [weak self] key, record, outcome in
                guard let self, let store = self.orgSessions[key]?.store else { return }
                let args = Self.args(record)
                guard let id = args["message_id"]?.string, let channel = args["channel_id"]?.string else { return }
                if case .taken = outcome {
                    try? store.queue.write { db in
                        try db.execute(sql: "DELETE FROM b1_intents WHERE command_id = ?", arguments: [record.commandId])
                        // ACK is historical. Only a fresh read decides the current state.
                        try db.execute(sql: "UPDATE b1_metadata SET dirty = 1, ticket = ticket + 1 WHERE message_id = ?", arguments: [id])
                        try db.execute(sql: "UPDATE b1_pins SET dirty = 1, ticket = ticket + 1 WHERE channel_id = ?", arguments: [channel])
                    }
                } else if case .refused(let code) = outcome, ["unsupported", "not_found"].contains(code) {
                    self.socket?.checkCapabilitiesAgain()
                }
            }
        }
    }
}
