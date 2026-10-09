import Foundation
import GRDB

extension ChatService {
    func dmSync(_ key: ChatOrgKey) -> ChatDMSync? {
        guard state == .signedIn, connection?.orgKey == key, supports("chat.dm", key: key),
              let session = orgSessions[key], !session.snapshotOwed, !session.doubtNotWritten else { return nil }
        return session.sync?.dm
    }
    func dmAllowed(_ key: ChatOrgKey, _ id: String? = nil) -> Bool { dmSync(key)?.readable(id) == true }
    private func writableDM(_ key: ChatOrgKey, _ id: String) throws -> (ChatStore, ChatDMCard) {
        guard dmAllowed(key, id), let store = orgSessions[key]?.store,
              let card = try store.dmRead({ try ChatDMStore.card($0, id) }) else { throw ChatError.notConnected }
        guard card.writable else { throw ChatError.storage("This conversation is read-only.") }
        return (store, card)
    }
    /// Consume a person's draft immediately, even before a server DM exists.
    /// The outbox owns both protocol steps and their stable IDs from now on.
    @discardableResult func postDMToPeer(_ key: ChatOrgKey, peer: String, text: String, mentions: [String], draftVersion: String) throws -> String {
        guard dmAllowed(key), peer != key.accountId, let store = orgSessions[key]?.store else { throw ChatError.notConnected }
        if let problem = ChatChannelModel.textProblem(text) { throw ChatError.storage(problem) }
        let draftID = "peer:\(peer)"
        let current = try store.dmRead { db in
            let card = try ChatDMStore.cardForPeer(db, peer)
            return (member: try ChatOrgView.Member.read(db, account: peer).first, card: card,
                sent: try String.fetchOne(db, sql: "SELECT message_id FROM dm_sends WHERE draft_version = ? AND dm_id IN (?, ?)", arguments: [draftVersion, draftID, card?.dmId]))
        }
        guard current.member != nil, current.card?.writable != false else { throw ChatError.notConnected }
        if let sent = current.sent { return sent }
        if let card = current.card {
            let source = try store.dmRead { try ChatDMStore.draft($0, draftID, root: nil) == nil ? card.dmId : draftID }
            return try postDM(key, dm: card.dmId, root: nil, text: text, mentions: mentions, draftVersion: draftVersion, draftID: source)
        }
        let id = UUID().uuidString.lowercased()
        let allowedMentions = Set(mentions).intersection([key.accountId, peer]).sorted()
        let prepared = try prepareCommand(key, type: "dm.message.post", args: .object([
            "peer_account_id": .string(peer), "open_command_id": .string(ChatUUID.v7()),
            "message_id": .string(id), "text": .string(text),
            "mentions": .array(allowedMentions.map { .object(["account_id": .string($0)]) })]))
        try store.dmWrite { db in
            guard let draft = try ChatDMStore.draft(db, draftID, root: nil), draft.version == draftVersion, draft.text == text else {
                throw ChatError.storage("The draft changed in another window. Review it before sending.")
            }
            _ = try prepared.table.insert(db, prepared.record, seq: prepared.record.seq)
            try db.execute(sql: "INSERT INTO dm_sends (draft_version, dm_id, message_id) VALUES (?, ?, ?)", arguments: [draftVersion, draftID, id])
            try db.execute(sql: "DELETE FROM dm_drafts WHERE dm_id = ? AND version = ?", arguments: [draftID, draftVersion])
        }
        prepared.sent(); return id
    }
    func retryDMToPeer(_ key: ChatOrgKey, peer: String, command: String) throws {
        guard dmAllowed(key), let store = orgSessions[key]?.store,
              try store.dmRead({ try ChatOrgView.Member.read($0, account: peer).first }) != nil,
              try store.dmRead({ try ChatDMStore.cardForPeer($0, peer)?.writable }) != false,
              let original = try store.outbox.commands().first(where: { $0.commandId == command }),
              original.type == "dm.message.post", Self.args(original)["peer_account_id"]?.string == peer,
              original.state != .pending, original.state != .sent, !["dismissed", "retried"].contains(original.error ?? "") else { return }
        var args = Self.args(original)
        if args["dm_id"] == nil { args["open_command_id"] = .string(ChatUUID.v7()) }
        let prepared = try prepareCommand(key, type: original.type, args: .object(args))
        try store.dmWrite { db in
            try db.execute(sql: "UPDATE outbox SET state = 'dropped', error = 'retried', dismissed = 1 WHERE command_id = ?", arguments: [command])
            _ = try prepared.table.insert(db, prepared.record, seq: prepared.record.seq)
        }
        prepared.sent()
    }
    @discardableResult func postDM(_ key: ChatOrgKey, dm: String, root: String?, text: String, mentions: [String], draftVersion: String? = nil, draftID: String? = nil) throws -> String {
        let (store, card) = try writableDM(key, dm)
        let draftID = draftID ?? dm
        if let problem = ChatChannelModel.textProblem(text) { throw ChatError.storage(problem) }
        if let draftVersion, let sent = try store.dmRead({ try String.fetchOne($0, sql: "SELECT message_id FROM dm_sends WHERE draft_version = ? AND dm_id = ?", arguments: [draftVersion, dm]) }) { return sent }
        let id = UUID().uuidString.lowercased()
        let members = Set([key.accountId, card.peer.accountId])
        let mentions = Array(Set(mentions).intersection(members)).sorted()
        var args: [String: ChatJSON] = ["dm_id": .string(dm), "message_id": .string(id), "text": .string(text),
            "mentions": .array(mentions.map { .object(["account_id": .string($0)]) })]
        if let root { args["thread_root_id"] = .string(root) }
        let prepared = try prepareCommand(key, type: "dm.message.post", args: .object(args))
        try store.dmWrite { db in
            if let draftVersion {
                guard let draft = try ChatDMStore.draft(db, draftID, root: root), draft.version == draftVersion, draft.text == text else {
                    throw ChatError.storage("The draft changed in another window. Review it before sending.")
                }
            }
            if let root {
                guard try ChatDMStore.messages(db, dm).contains(where: { $0.id == root && $0.threadRootId == nil && $0.hasFixed }) else { throw ChatError.storage("The thread is no longer available.") }
            }
            let m = ChatDMMessageWire(messageId: id, dmId: dm, threadRootId: root, authorAccountId: key.accountId, text: text,
                mentions: mentions.map { .init(accountId: $0) }, revision: 0, seq: 0, createdAt: Self.now())
            try db.execute(sql: "INSERT INTO dm_messages (dm_id, message_id, body, seq, root, revision, deleted, local_state, command_id) VALUES (?, ?, ?, 0, ?, 0, 0, 'sending', ?)",
                           arguments: [dm, id, try JSONEncoder().encode(m), root, prepared.record.commandId])
            _ = try prepared.table.insert(db, prepared.record, seq: prepared.record.seq)
            try db.execute(sql: "UPDATE dm_cards SET last_activity = MAX(last_activity, ?) WHERE dm_id = ?", arguments: [m.createdAt, dm])
            if let draftVersion {
                try db.execute(sql: "INSERT INTO dm_sends (draft_version, dm_id, message_id) VALUES (?, ?, ?)", arguments: [draftVersion, dm, id])
                try db.execute(sql: "DELETE FROM dm_drafts WHERE dm_id = ? AND root = ? AND version = ?", arguments: [draftID, root ?? "", draftVersion])
            }
        }
        prepared.sent(); return id
    }
    func changeDM(_ key: ChatOrgKey, dm: String, message: String, text: String?, mentions: [String] = [], revision: Int) throws {
        let (store, card) = try writableDM(key, dm)
        if let text, let problem = ChatChannelModel.textProblem(text) { throw ChatError.storage(problem) }
        guard let current = try store.dmRead({ try ChatDMStore.messages($0, dm).first { $0.id == message } }),
              current.authorAccountId == key.accountId, current.hasFixed, !current.deleted, !current.loading, !current.changing else {
            throw ChatError.storage("This message cannot be changed.")
        }
        var args: [String: ChatJSON] = ["dm_id": .string(dm), "message_id": .string(message), "expected_revision": .number(Double(revision))]
        if let text {
            args["text"] = .string(text)
            args["mentions"] = .array(Set(mentions).intersection([key.accountId, card.peer.accountId]).sorted().map { .object(["account_id": .string($0)]) })
        }
        let kind = text == nil ? "delete" : "edit", prepared = try prepareCommand(key, type: "dm.message.\(text == nil ? "delete" : "edit")", args: .object(args))
        try store.dmWrite { db in
            try db.execute(sql: "INSERT OR REPLACE INTO dm_changes (dm_id, message_id, kind, text, command_id, state) VALUES (?, ?, ?, ?, ?, 'saving')", arguments: [dm, message, kind, text, prepared.record.commandId])
            _ = try prepared.table.insert(db, prepared.record, seq: prepared.record.seq)
        }
        prepared.sent()
    }
    func retryDM(_ key: ChatOrgKey, dm: String, message: String) throws {
        let (store, card) = try writableDM(key, dm)
        guard let row = try store.dmRead({ try ChatDMStore.messages($0, dm).first { $0.id == message && $0.localState == .failed } }),
              let original = try store.outbox.commands().last(where: {
                  let args = Self.args($0)
                  return $0.type == "dm.message.post" && args["message_id"]?.string == row.id
                      && (args["dm_id"]?.string == dm || args["peer_account_id"]?.string == card.peer.accountId)
              }) else { return }
        var args = Self.args(original)
        if args["dm_id"] == nil { args["open_command_id"] = .string(ChatUUID.v7()) }
        let prepared = try prepareCommand(key, type: original.type, args: .object(args))
        try store.dmWrite { db in
            try db.execute(sql: "UPDATE dm_messages SET local_state = 'sending', local_error = NULL, command_id = ? WHERE dm_id = ? AND message_id = ?", arguments: [prepared.record.commandId, dm, message])
            _ = try prepared.table.insert(db, prepared.record, seq: prepared.record.seq)
        }
        prepared.sent()
    }
    func discardDM(_ key: ChatOrgKey, dm: String, message: String) throws {
        guard dmAllowed(key, dm), let store = orgSessions[key]?.store else { return }
        try store.dmWrite { db in
            let peer = try ChatDMStore.card(db, dm)?.peer.accountId
            // Check the current row in the cancellation transaction: either
            // the feed or HTTP may have accepted what the UI still shows sending.
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM dm_messages m LEFT JOIN outbox o ON o.command_id = m.command_id
                    WHERE m.dm_id = ? AND m.message_id = ? AND m.local_state IN ('sending', 'failed') AND o.state IS NOT 'sent')
                """, arguments: [dm, message]) == true else { return }
            let commands = try ChatCommandRecord.fetchAll(db, sql: "SELECT * FROM outbox WHERE type = 'dm.message.post' AND state != 'sent'")
            for command in commands {
                let args = Self.args(command)
                guard args["message_id"]?.string == message,
                      args["dm_id"]?.string == dm || (peer != nil && args["peer_account_id"]?.string == peer) else { continue }
                try db.execute(sql: "UPDATE outbox SET state = 'dropped', error = 'dismissed', dismissed = 1, next_attempt_at = NULL WHERE command_id = ?", arguments: [command.commandId])
            }
            try db.execute(sql: "DELETE FROM dm_messages WHERE dm_id = ? AND message_id = ?", arguments: [dm, message])
        }
        orgSessions[key]?.outbox?.pump()
    }
    func installDMCommands() {
        for type in ChatDMStore.commands {
            commandOwners[type] = { [weak self] key, record, outcome in self?.dmAnswered(key, record, outcome) }
        }
    }
    private func dmAnswered(_ key: ChatOrgKey, _ record: ChatCommandRecord, _ outcome: ChatCommandOutcome) {
        guard let store = orgSessions[key]?.store else { return }
        let args = Self.args(record)
        if record.type == "dm.open" {
            if case .taken(let answer) = outcome, let dm = answer?.result["dm_id"]?.string {
                dmSync(key)?.opened(dm)
            }
            return
        }
        guard let dm = args["dm_id"]?.string, let id = args["message_id"]?.string else { return }
        switch outcome {
        case .taken(let answer):
            try? store.dmWrite { try $0.execute(sql: "DELETE FROM dm_changes WHERE dm_id = ? AND message_id = ? AND command_id = ?", arguments: [dm, id, record.commandId]) }
            let seq = answer?.result["seq"]?.int ?? (try? store.dmRead { try Int.fetchOne($0, sql: "SELECT seq FROM dm_messages WHERE dm_id = ? AND message_id = ?", arguments: [dm, id]) })
            if let seq, seq > 0 { orgSessions[key]?.sync?.dm.readOne(dm, id: id, seq: seq, revision: answer?.result["revision"]?.int ?? 0, live: false) }
        case .refused(let code):
            try? store.dmWrite { db in
                try db.execute(sql: "UPDATE dm_messages SET local_state = 'failed', local_error = ? WHERE dm_id = ? AND message_id = ? AND command_id = ? AND local_state IS NOT NULL", arguments: [code, dm, id, record.commandId])
                try db.execute(sql: "UPDATE dm_changes SET state = 'failed', error = ? WHERE dm_id = ? AND message_id = ? AND command_id = ?", arguments: [code, dm, id, record.commandId])
            }
            if ["dm_read_only", "revision_conflict"].contains(code), let sync = orgSessions[key]?.sync?.dm { Task { _ = try? await sync.refresh(dm) } }
            if ["forbidden", "not_found"].contains(code) {
                try? store.dmWrite { try ChatDMStore.remove($0, dm) }; orgSessions[key]?.sync?.rightsInDoubt()
            }
        }
    }
}
