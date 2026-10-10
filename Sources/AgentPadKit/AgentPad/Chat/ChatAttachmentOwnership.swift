import Foundation
import GRDB

extension ChatAttachments {
    /// One row owns one original: either the composer or its outgoing post.
    /// End an owner and its pending command together, keeping the bytes for
    /// explicit deletion. Unconfirmed commands retain their anti-replay state.
    static func reconcileOwnership(_ db: Database, now: Date = Date()) throws -> [ChatAttachmentDraft] {
        let all = try drafts(db, includingQueued: true)
        struct Post: Hashable { var owner: ChatAttachmentOwner; var message: String }
        let owned = Dictionary(grouping: all.filter { $0.queued == true }) { Post(owner: $0.owner, message: $0.messageId) }
        var posts: [Post: [ChatCommandRecord]] = [:]
        for record in try ChatCommandRecord.fetchAll(db, sql: "SELECT * FROM outbox WHERE type IN ('message.post_with_attachments', 'dm.message.post_with_attachments') ORDER BY seq") {
            let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes)
            if let id = envelope.args["message_id"]?.string, let owner = ChatAttachmentOwner(args: envelope.args) { posts[Post(owner: owner, message: id), default: []].append(record) }
        }
        for id in Set(owned.keys).union(posts.keys) {
            let files = owned[id] ?? [], commands = posts[id] ?? []
            let confirmed: Bool
            switch id.owner {
            case .channel(let channel):
                confirmed = try Bool.fetchOne(db, sql: "SELECT has_fixed FROM messages WHERE channel_id = ? AND message_id = ?", arguments: [channel, id.message]) == true
            case .dm(let dm):
                confirmed = try Bool.fetchOne(db, sql: "SELECT seq > 0 AND local_state IS NULL FROM dm_messages WHERE dm_id = ? AND message_id = ?", arguments: [dm, id.message]) == true
            }
            if confirmed || commands.contains(where: { $0.state == .sent }) {
                for file in files { try db.execute(sql: "DELETE FROM attachment_drafts WHERE attachment_id = ?", arguments: [file.id]) }
                continue
            }
            let code: String?
            if let last = commands.last { code = try postFailure(db, last, files: files, now: now) }
            else { code = "attachment_upload_failed" }
            guard let code else { continue }
            for file in files { try fail(db, file, reason: reason(ChatAPIError.server(status: 409, code: code, retryAfter: nil), owner: file.owner)) }
            for record in commands where record.state == .pending {
                try db.execute(sql: "UPDATE outbox SET state = 'failed', error = ?, next_attempt_at = NULL WHERE command_id = ? AND state = 'pending'",
                    arguments: [code, record.commandId])
            }
            if case .dm(let dm) = id.owner {
                try db.execute(sql: "UPDATE dm_messages SET local_state = 'failed', local_error = ? WHERE dm_id = ? AND message_id = ? AND seq = 0 AND (local_state IS NOT 'failed' OR local_error IS NOT ?)", arguments: [code, dm, id.message, code])
            } else { try db.execute(sql: """
                UPDATE messages SET local_state = 'failed', local_error = ? WHERE message_id = ? AND has_fixed = 0
                    AND (local_state IS NOT 'failed' OR local_error IS NOT ?)
                """, arguments: [code, id.message, code]) }
        }
        for file in all where file.queued != true {
            if let dm = file.owner.dmID, try ChatDMStore.card(db, dm)?.writable == false {
                var closed = file
                closed.expiresAt = .distantPast
                closed.state = .failed; closed.progress = 0
                closed.problem = "This conversation is read-only. Your file is saved locally."
                if closed != file { try put(db, closed) }
            }
            if try Bool.fetchOne(db, sql: "SELECT archived FROM channels WHERE channel_id = ?", arguments: [file.channel]) == true {
                try fail(db, file, reason: "The channel is archived. Your file is saved locally.")
            }
        }
        return try drafts(db, includingQueued: true)
    }

    /// Also used at the outbox gate, before an observer has refreshed the UI.
    static func postFailure(_ db: Database, _ record: ChatCommandRecord, now: Date = Date()) throws -> String? {
        guard postCommands.contains(record.type) else { return nil }
        let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes)
        let files = try drafts(db, includingQueued: true).filter { $0.queued == true && $0.messageId == envelope.args["message_id"]?.string && $0.owner == ChatAttachmentOwner(args: envelope.args) }
        return try postFailure(db, record, files: files, now: now)
    }

    private static func postFailure(_ db: Database, _ record: ChatCommandRecord, files: [ChatAttachmentDraft], now: Date) throws -> String? {
        if record.state == .sent { return nil }
        if record.state == .unconfirmed { return "attachment_unconfirmed" }
        if record.state == .dropped { return record.error ?? "dropped" }
        let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes)
        if try Bool.fetchOne(db, sql: "SELECT archived FROM channels WHERE channel_id = ?", arguments: [envelope.args["channel_id"]?.string]) == true {
            return "channel_archived"
        }
        if let dm = envelope.args["dm_id"]?.string, try ChatDMStore.card(db, dm)?.writable == false {
            // Closing a pair is not a receipt. A ready post may already have
            // committed: replay its exact command before declaring it refused.
            // The server still rejects a first publication into a closed DM.
            if record.state != .pending || files.isEmpty || !files.allSatisfy({ $0.state == .ready }) { return "dm_read_only" }
        }
        if record.state == .failed { return record.error ?? "attachment_upload_failed" }
        if files.contains(where: { $0.state == .failed }) { return "attachment_upload_failed" }
        // A ready post may have lost its receipt: replay its exact command.
        // Unfinished uploads cannot make that progress after their TTL.
        if files.contains(where: { $0.state != .ready && $0.expiresAt <= now }) { return "attachment_expired" }
        return nil
    }

    static func fail(_ db: Database, _ file: ChatAttachmentDraft, reason: String) throws {
        guard file.state != .failed || file.problem != reason else { return }
        var failed = file
        failed.state = .failed; failed.problem = reason
        try put(db, failed)
    }
}
