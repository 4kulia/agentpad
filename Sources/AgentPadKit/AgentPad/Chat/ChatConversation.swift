import Foundation
import GRDB

/// The service's side of channel conversations (DESIGN-F3): which channels
/// are open in tabs, sending, editing and deleting through the queue, and
/// the server's final word on each.
extension ChatService {
    // MARK: Open channels

    /// A channel tab came or went: the organization follows what is open now.
    func channelTab(_ ref: ChannelRef, open: Bool) {
        openChannelTabs[ref, default: 0] += open ? 1 : -1
        if openChannelTabs[ref] ?? 0 <= 0 { openChannelTabs[ref] = nil }
        for (key, session) in orgSessions { session.sync?.setOpenChannels(openChannels(key)) }
    }

    func openChannels(_ key: ChatOrgKey) -> Set<String> {
        Set(openChannelTabs.keys.filter { $0.belongs(to: key) }.map(\.channel))
    }

    // MARK: Commands

    /// Queues `message.post` with its local row in one write (`prepare`, as
    /// D5); the row shows "sending…" until a message with its id comes from
    /// anywhere (review F3-2). Returns the message id.
    @discardableResult
    func post(_ key: ChatOrgKey, channel: String, root: String?, text: String, mentions: [String],
              messageId: String = UUID().uuidString.lowercased(), draftVersion: String? = nil) throws -> String {
        guard let store = orgSessions[key]?.store else { throw ChatError.notConnected }
        if let draftVersion, let sent = try store.queue.read({ try String.fetchOne($0,
            sql: "SELECT message_id FROM channel_sends WHERE draft_version = ?", arguments: [draftVersion]) }) { return sent }
        let prepared = try prepareCommand(key, type: "message.post", args: Self.postArgs(messageId, channel, root, text, mentions))
        try store.queue.write { db in
            if let draftVersion {
                guard try String.fetchOne(db, sql: "SELECT version FROM drafts WHERE channel_id = ? AND thread_root_id = ? AND text = ?",
                                          arguments: [channel, root ?? "", text]) == draftVersion else {
                    throw ChatError.storage("The draft changed in another window. Review it before sending.")
                }
            }
            try ChatMessages.insertSending(db, id: messageId, channel: channel, root: root, author: key.accountId, text: text,
                                           mentions: mentions, at: Self.now())
            _ = try prepared.table.insert(db, prepared.record, seq: prepared.record.seq)
            if let draftVersion {
                try db.execute(sql: "INSERT INTO channel_sends (draft_version, channel_id, thread_root_id, message_id, command_id) VALUES (?, ?, ?, ?, ?)",
                               arguments: [draftVersion, channel, root, messageId, prepared.record.commandId])
                try db.execute(sql: "DELETE FROM drafts WHERE channel_id = ? AND thread_root_id = ? AND version = ?",
                               arguments: [channel, root ?? "", draftVersion])
            }
        }
        prepared.sent()
        return messageId
    }

    static func postArgs(_ id: String, _ channel: String, _ root: String?, _ text: String, _ mentions: [String]) -> ChatJSON {
        var args: [String: ChatJSON] = [
            "message_id": .string(id), "channel_id": .string(channel), "text": .string(text),
            "mentions": .array(mentions.map { .object(["account_id": .string($0)]) }),
        ]
        if let root { args["thread_root_id"] = .string(root) }
        return .object(args)
    }

    /// "Retry": the same message id again with a new command — the server
    /// takes a repeat of the same post as the post it has.
    func retry(_ key: ChatOrgKey, messageId: String) throws {
        // MCP provenance/attribution cannot be rebuilt by the manual retry button.
        if (try? orgSessions[key]?.store?.queue.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM session_posts WHERE message_id = ?)", arguments: [messageId]) }) == true {
            throw ChatError.storage("Retry this post from the same Claude tab with its message_id.")
        }
        guard let store = orgSessions[key]?.store,
              let row = try store.queue.read({ db in
                  try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE message_id = ? AND local_state = 'failed'", arguments: [messageId])
              }).map(ChatMessage.init(row:)) else { return }
        guard try store.queue.read({ try Bool.fetchOne($0, sql: "SELECT archived FROM channels WHERE channel_id = ?", arguments: [row.channelId]) }) == false else {
            throw ChatAttachmentError.unavailable
        }
        let original = try store.outbox.commands().last { $0.type == "message.post_with_attachments" && Self.args($0)["message_id"]?.string == messageId }
        if !row.attachments.isEmpty || row.attachmentOnly || original != nil {
            guard let original, canRepeatAttachmentPost(key, row: row, original: original) else { throw ChatAttachmentError.unavailable }
            try retryAttachmentPost(key, row: row, original: original)
            return
        }
        let prepared = try prepareCommand(key, type: "message.post",
                                          args: Self.postArgs(messageId, row.channelId, row.threadRootId, row.text, row.mentions))
        try store.queue.write { db in
            try db.execute(sql: "UPDATE messages SET local_state = 'sending', local_error = NULL WHERE message_id = ?", arguments: [messageId])
            _ = try prepared.table.insert(db, prepared.record, seq: prepared.record.seq)
        }
        prepared.sent()
    }

    private func canRepeatAttachmentPost(_ key: ChatOrgKey, row: ChatMessage, original: ChatCommandRecord) -> Bool {
        supports("chat.attachments", key: key) && original.sessionId == connection?.sessionId
            && original.state != .dropped && original.state != .unconfirmed
            && !row.attachments.isEmpty
            && Self.args(original)["attachment_ids"] == .array(row.attachments.map { .string($0.id) })
    }

    func canRetryPost(_ key: ChatOrgKey, row: ChatMessage) -> Bool {
        guard row.localState == .failed, let store = orgSessions[key]?.store,
              (try? store.queue.read { try Bool.fetchOne($0, sql: "SELECT archived FROM channels WHERE channel_id = ?", arguments: [row.channelId]) }) == false else { return false }
        let original = try? store.outbox.commands().last { $0.type == "message.post_with_attachments" && Self.args($0)["message_id"]?.string == row.id }
        if !row.attachments.isEmpty || row.attachmentOnly || original != nil {
            guard let original else { return false }
            return canRepeatAttachmentPost(key, row: row, original: original) && attachments(key)?.uploadStamp(channel: row.channelId) != nil
        }
        return true
    }

    /// "Delete" of a post not sent: its row goes; its commands are failed already.
    func discard(_ key: ChatOrgKey, messageId: String) throws {
        guard let store = orgSessions[key]?.store else { return }
        let removed = try store.queue.write { db -> [String] in
            guard try String.fetchOne(db, sql: "SELECT local_state FROM messages WHERE message_id = ?", arguments: [messageId]) == "failed" else { return [] }
            let owned = try ChatAttachments.drafts(db, includingQueued: true).filter { $0.queued == true && $0.messageId == messageId }
            for file in owned { try db.execute(sql: "DELETE FROM attachment_drafts WHERE attachment_id = ?", arguments: [file.id]) }
            try db.execute(sql: "DELETE FROM messages WHERE message_id = ? AND local_state = 'failed'", arguments: [messageId])
            return owned.map(\.id)
        }
        for id in removed { files.attachmentStorage.remove(key, id: id) }
        attachmentManagers[key]?.reconcile()
    }

    /// `message.edit` / `message.delete` of the user's own message, marked
    /// on the row until the server's word (no change shown before it).
    /// `expectedRevision`: the revision the user saw when the editor or the
    /// confirmation opened — a newer one since is the server's conflict to
    /// tell, never overwritten in silence (review F3-p1-1).
    func change(_ key: ChatOrgKey, messageId: String, text: String?, mentions: [String] = [], expectedRevision revision: Int) throws {
        guard let store = orgSessions[key]?.store else { throw ChatError.notConnected }
        var args: [String: ChatJSON] = ["message_id": .string(messageId), "expected_revision": .number(Double(revision))]
        if let text {
            args["text"] = .string(text)
            args["mentions"] = .array(mentions.map { .object(["account_id": .string($0)]) })
        }
        let prepared = try prepareCommand(key, type: text == nil ? "message.delete" : "message.edit", args: .object(args))
        try store.queue.write { db in
            // One change at a time — only while the one before is alive in the
            // queue: a command dropped or held for the user frees it (review F3c-1).
            let busy = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM local_edits le JOIN outbox o ON o.command_id = le.command_id
                              WHERE le.message_id = ? AND le.state = 'saving' AND o.state = 'pending')
                """, arguments: [messageId]) ?? false
            guard !busy else { throw ChatChangeError.busy }
            guard let channel = try String.fetchOne(db, sql: "SELECT channel_id FROM messages WHERE message_id = ?", arguments: [messageId])
            else { throw ChatError.notConnected }
            try db.execute(sql: """
                INSERT OR REPLACE INTO local_edits (message_id, channel_id, kind, text, command_id, state, error)
                VALUES (?, ?, ?, ?, ?, 'saving', NULL)
                """, arguments: [messageId, channel, text == nil ? "delete" : "edit", text, prepared.record.commandId])
            _ = try prepared.table.insert(db, prepared.record, seq: prepared.record.seq)
        }
        prepared.sent()
    }

    /// "Discard" of an edit that did not go: its text goes too.
    func discardEdit(_ key: ChatOrgKey, messageId: String) {
        try? orgSessions[key]?.store?.queue.write { db in
            try db.execute(sql: "DELETE FROM local_edits WHERE message_id = ? AND state != 'saving' OR message_id = ? AND command_id NOT IN (SELECT command_id FROM outbox WHERE state = 'pending')",
                           arguments: [messageId, messageId])
        }
    }

    // MARK: The server's word

    /// Owners of `message.*` answers, by the one dispatcher (D5's way).
    func installConversations() {
        installDMCommands()
        installB1()
        commandOwners["message.post_with_attachments"] = { [weak self] key, record, outcome in self?.postAnswered(key, record, outcome) }
        commandOwners["message.post"] = { [weak self] key, record, outcome in self?.postAnswered(key, record, outcome) }
        commandOwners["message.post_from_session"] = { [weak self] key, record, outcome in
            if case .taken(let answer) = outcome, let answer, let store = self?.orgSessions[key]?.store,
               answer.result["message_id"]?.string == Self.args(record)["message_id"]?.string,
               answer.result["channel_id"]?.string == Self.args(record)["channel_id"]?.string,
               answer.result["author_account_id"]?.string == key.accountId,
               let json = try? JSONEncoder().encode(answer.result) {
                try? store.queue.write { try $0.execute(sql: "UPDATE session_posts SET result = ? WHERE command_id = ?",
                    arguments: [String(decoding: json, as: UTF8.self), record.commandId]) }
            }
            self?.postAnswered(key, record, outcome)
        }
        for type in ["message.edit", "message.delete"] {
            commandOwners[type] = { [weak self] key, record, outcome in self?.changeAnswered(key, record, outcome) }
        }
    }

    static func args(_ record: ChatCommandRecord) -> [String: ChatJSON] {
        guard let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes),
              case .object(let args) = envelope.args else { return [:] }
        return args
    }

    /// Taken: the message is read once (a repeat's `200` brings no event,
    /// review F3-2) unless it came already. Refused: "not sent", with why.
    private func postAnswered(_ key: ChatOrgKey, _ record: ChatCommandRecord, _ outcome: ChatCommandOutcome) {
        let args = Self.args(record)
        guard let id = args["message_id"]?.string, let channel = args["channel_id"]?.string,
              let store = orgSessions[key]?.store else { return }
        switch outcome {
        case .taken(let answer):
            let came = (try? store.queue.read { db in
                try Bool.fetchOne(db, sql: "SELECT has_fixed FROM messages WHERE message_id = ?", arguments: [id])
            }) ?? nil
            if came != true, let seq = answer?.result["seq"]?.int, let sync = orgSessions[key]?.sync {
                sync.readOne(channel, id: id, seq: seq)
            }
        case .refused(let code):
            try? store.queue.write { db in
                try db.execute(sql: "UPDATE messages SET local_state = 'failed', local_error = ? WHERE message_id = ? AND has_fixed = 0",
                               arguments: [code, id])
            }
        }
    }

    /// Taken: the mark goes (the event brings the change). A revision
    /// conflict: the current version is read, the user's text kept.
    private func changeAnswered(_ key: ChatOrgKey, _ record: ChatCommandRecord, _ outcome: ChatCommandOutcome) {
        let args = Self.args(record)
        guard let id = args["message_id"]?.string, let store = orgSessions[key]?.store else { return }
        switch outcome {
        case .taken:
            // Its own command only: a later edit in its place stays (review F3b-p1-1).
            try? store.queue.write { db in
                try db.execute(sql: "DELETE FROM local_edits WHERE message_id = ? AND command_id = ?", arguments: [id, record.commandId])
            }
        case .refused(let code):
            // Any refusal: failed, the text kept for "Edit again" (review F3c-1).
            try? store.queue.write { db in
                try db.execute(sql: "UPDATE local_edits SET state = 'failed', error = ? WHERE message_id = ? AND command_id = ?",
                               arguments: [code, id, record.commandId])
            }
            if code == "revision_conflict", let row = try? store.queue.read({ db in
                try Row.fetchOne(db, sql: "SELECT channel_id, seq FROM messages WHERE message_id = ?", arguments: [id])
            }), let seq = row["seq"] as Int?, let sync = orgSessions[key]?.sync {
                sync.readOne(row["channel_id"], id: id, seq: seq)
            }
        }
    }

    /// At an organization's start: a post still "sending" with no command
    /// of it in the queue is sent again with the same id — the server takes
    /// it as the post it has, or as new; its answer settles the row
    /// (review F3b-3).
    func resendPosts(_ key: ChatOrgKey) {
        guard let store = orgSessions[key]?.store else { return }
        _ = try? store.queue.write { try ChatAttachments.reconcileOwnership($0) }
        reconcileSessionPosts(key)
        let rows = (try? store.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages WHERE local_state = 'sending' AND has_fixed = 0").map(ChatMessage.init(row:))
        }) ?? []
        guard !rows.isEmpty else { return }
        // A post's commands, by its id: pending goes on; unconfirmed (a new
        // generation) waits for the user's word, as C2 has it; dropped (its
        // session ended) is "not sent" for the user to retry (review F3-p1-5).
        var states: [String: Set<ChatCommandRecord.State>] = [:]
        var filePosts: [String: ChatCommandRecord] = [:]
        for command in (try? store.outbox.commands()) ?? [] where ["message.post", "message.post_with_attachments"].contains(command.type) {
            if let id = Self.args(command)["message_id"]?.string { states[id, default: []].insert(command.state) }
            if command.type == "message.post_with_attachments", let id = Self.args(command)["message_id"]?.string { filePosts[id] = command }
        }
        for row in rows {
            if (try? store.queue.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM session_posts WHERE message_id = ?)", arguments: [row.messageId]) }) == true { continue }
            let kept = states[row.messageId] ?? []
            if kept.contains(.pending) || kept.contains(.unconfirmed) { continue }
            if kept.contains(.dropped) {
                try? store.queue.write { db in
                    try db.execute(sql: "UPDATE messages SET local_state = 'failed', local_error = 'dropped' WHERE message_id = ?",
                                   arguments: [row.messageId])
                }
                continue
            }
            let type: String, args: ChatJSON
            if !row.attachments.isEmpty || row.attachmentOnly || filePosts[row.messageId] != nil {
                guard let original = filePosts[row.messageId], original.state == .sent,
                      canRepeatAttachmentPost(key, row: row, original: original) else {
                    try? store.queue.write { db in
                        try db.execute(sql: "UPDATE messages SET local_state = 'failed', local_error = ? WHERE message_id = ?",
                            arguments: [filePosts[row.messageId]?.error ?? "attachment_expired", row.messageId])
                    }
                    continue
                }
                type = original.type; args = .object(Self.args(original))
            } else {
                type = "message.post"; args = Self.postArgs(row.messageId, row.channelId, row.threadRootId, row.text, row.mentions)
            }
            guard let prepared = try? prepareCommand(key, type: type, args: args)
            else { continue }
            _ = try? store.queue.write { db in try prepared.table.insert(db, prepared.record, seq: prepared.record.seq) }
            prepared.sent()
        }
    }

    static func now() -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: Date())
    }
}

enum ChatChangeError: LocalizedError {
    case busy
    var errorDescription: String? { "A change of this message is still on its way." }
}
