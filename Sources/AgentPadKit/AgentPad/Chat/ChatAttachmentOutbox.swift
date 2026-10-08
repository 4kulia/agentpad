import Foundation
import GRDB

extension ChatAttachmentManager {
    /// A new reservation owns a copy before the transaction retires the old one.
    /// Callers never use this for a post whose outcome is still unknown.
    func renewed(_ draft: ChatAttachmentDraft, capture: Stamp) throws -> ChatAttachmentDraft {
        guard let limits else { throw ChatAttachmentError.paused }
        let data = try ChatAttachmentStorage.read(storage.url(key, id: draft.id), limit: limits.fileBytes)
        guard data.count == draft.file.size, ChatAttachments.digest(data) == draft.sha256 else { throw ChatAttachmentError.hash }
        var next = draft
        next.file.attachmentId = UUID().uuidString.lowercased()
        next.prepareCommand = ChatUUID.v7(); next.completeCommand = ChatUUID.v7()
        next.session = capture.session; next.generation = capture.generation
        next.expiresAt = Date().addingTimeInterval(Double(limits.draftTTLSeconds))
        next.state = .waiting; next.progress = 0; next.problem = nil
        try storage.save(data, key: key, id: next.id)
        return next
    }

    func replace(_ db: Database, draft: ChatAttachmentDraft, with next: ChatAttachmentDraft) throws {
        // Preserve selection and row order while replacing the reservation.
        for (table, column) in [("drafts", "attachment_selection"), ("channel_call_intents", "attachment_manifest")] {
            for row in try Row.fetchAll(db, sql: "SELECT rowid, \(column) FROM \(table) WHERE \(column) != '[]'") {
                var manifest = try JSONDecoder().decode([ChatAttachmentManifest].self, from: Data((row[column] as String).utf8))
                guard manifest.contains(where: { $0.id == draft.id }) else { continue }
                for i in manifest.indices where manifest[i].id == draft.id { manifest[i].file.attachmentId = next.id }
                try db.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE rowid = ?",
                    arguments: [String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self), row["rowid"] as Int64])
            }
        }
        try db.execute(sql: "UPDATE attachment_drafts SET attachment_id = ?, body = ? WHERE attachment_id = ?",
            arguments: [next.id, String(decoding: try JSONEncoder().encode(next), as: UTF8.self), draft.id])
        guard db.changesCount == 1 else { throw ChatAttachmentError.changed }
        if draft.queued != true { try ChatAttachments.bumpDraft(db, channel: draft.channel, root: draft.root) }
    }

    func postReady(_ record: ChatCommandRecord) -> Bool {
        guard record.type == "message.post_with_attachments" else { return true }
        return (try? store.queue.read { db in
            try ChatAttachments.drafts(db, includingQueued: true)
                .filter { $0.queued == true && $0.messageId == ChatService.args(record)["message_id"]?.string }
                .allSatisfy { $0.state == .ready }
        }) == true
    }
}

extension ChatService {
    /// Retry of a refused publication. An unanswered post must first replay its
    /// exact bytes: its receipt may have been lost after successful publication.
    func retryAttachmentPost(_ key: ChatOrgKey, row: ChatMessage, original: ChatCommandRecord) throws {
        guard let manager = attachments(key), let capture = manager.uploadStamp(channel: row.channelId) else { throw ChatAttachmentError.unavailable }
        let owned = try manager.store.queue.read { try ChatAttachments.drafts($0, includingQueued: true).filter { $0.queued == true && $0.messageId == row.id } }
        let renew = original.state == .failed && (["attachment_expired", "attachment_not_ready"].contains(original.error ?? "")
            || ["not_found", "attachment_upload_failed"].contains(original.error ?? "") && owned.contains { $0.expiresAt <= Date() })
        var replacements: [String: ChatAttachmentDraft] = [:]
        var committed = false
        defer {
            if !committed { for next in replacements.values { manager.storage.remove(key, id: next.id) } }
        }
        if renew {
            guard Set(owned.map(\.id)) == Set(row.attachments.map(\.id)), !owned.isEmpty else { throw ChatAttachmentError.unavailable }
            for draft in owned { replacements[draft.id] = try manager.renewed(draft, capture: capture) }
        }
        var args = Self.args(original)
        let files = row.attachments.map { file -> ChatAttachment in
            var next = file; next.attachmentId = replacements[file.id]?.id ?? file.id; return next
        }
        args["attachment_ids"] = .array(files.map { .string($0.id) })
        let prepared = try prepareCommand(key, type: original.type, args: .object(args))
        try manager.store.queue.write { db in
            for var draft in owned {
                if let next = replacements[draft.id] { try manager.replace(db, draft: draft, with: next) }
                else if draft.state == .failed { draft.state = .waiting; draft.problem = nil; try ChatAttachments.put(db, draft) }
            }
            try ChatAttachments.write(db, id: row.id, files: files, only: row.attachmentOnly)
            try db.execute(sql: "UPDATE messages SET local_state = 'sending', local_error = NULL WHERE message_id = ?", arguments: [row.id])
            _ = try prepared.table.insert(db, prepared.record, seq: prepared.record.seq)
            try db.execute(sql: "UPDATE channel_sends SET command_id = ? WHERE message_id = ?", arguments: [prepared.record.commandId, row.id])
        }
        committed = true
        manager.reconcile()
        prepared.sent()
    }
}
