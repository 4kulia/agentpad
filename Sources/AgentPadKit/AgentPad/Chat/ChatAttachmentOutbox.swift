import Foundation
import GRDB

extension ChatAttachmentManager {
    /// A new reservation owns a copy before the transaction retires the old one.
    /// Callers never use this for a post whose outcome is still unknown.
    func renewed(_ draft: ChatAttachmentDraft, capture: Stamp) throws -> ChatAttachmentDraft {
        guard let limits else { throw ChatAttachmentError.paused }
        var data = try ChatAttachmentStorage.read(storage.url(key, id: draft.id), limit: limits.fileBytes)
        guard data.count == draft.file.size, ChatAttachments.digest(data) == draft.sha256 else { throw ChatAttachmentError.hash }
        var next = draft
        next.file.attachmentId = UUID().uuidString.lowercased()
        if draft.file.isImage, draft.sanitizedImageSHA256 != draft.sha256 {
            // A legacy reservation may already exist on the server. New bytes
            // require a new ID as well as a new prepare command and digest.
            let sanitized = try ChatAttachmentWorker.sanitizedFile(data, name: draft.file.name, limits: limits)
            data = sanitized.0
            next.file = try ChatAttachmentStorage.descriptor(data: data, name: sanitized.1, limits: limits)
            next.file.position = draft.file.position
            next.sha256 = ChatAttachments.digest(data)
            next.sanitizedImageSHA256 = next.sha256
        }
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
                for i in manifest.indices where manifest[i].id == draft.id {
                    manifest[i].file = next.file; manifest[i].sha256 = next.sha256
                }
                try db.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE rowid = ?",
                    arguments: [String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self), row["rowid"] as Int64])
            }
        }
        try db.execute(sql: "UPDATE attachment_drafts SET attachment_id = ?, body = ? WHERE attachment_id = ?",
            arguments: [next.id, String(decoding: try JSONEncoder().encode(next), as: UTF8.self), draft.id])
        guard db.changesCount == 1 else { throw ChatAttachmentError.changed }
        if draft.queued != true { try ChatAttachments.bumpDraft(db, owner: draft.owner, root: draft.root) }
    }

    func postReady(_ record: ChatCommandRecord) -> Bool {
        guard ChatAttachments.postCommands.contains(record.type) else { return true }
        return (try? store.queue.read { db in
            try ChatAttachments.drafts(db, includingQueued: true)
                .filter { $0.queued == true && $0.messageId == ChatService.args(record)["message_id"]?.string && $0.owner == ChatAttachmentOwner(args: .object(ChatService.args(record))) }
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
            replacements[file.id]?.file ?? file
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

extension ChatService {
    func retryDMAttachmentPost(_ key: ChatOrgKey, row: ChatMessage, original: ChatCommandRecord) throws {
        guard let dm = row.dmId, let manager = attachments(key), let capture = manager.uploadStamp(owner: .dm(dm)),
              original.state != .sent, original.state != .pending, original.error != "dismissed" else { throw ChatAttachmentError.unavailable }
        let owned = try manager.store.dmRead { try ChatAttachments.drafts($0, includingQueued: true).filter { $0.owner == .dm(dm) && $0.messageId == row.id && $0.queued == true } }
        guard !owned.isEmpty, Set(owned.map(\.id)) == Set(row.attachments.map(\.id)) else { throw ChatAttachmentError.unavailable }
        let renew = original.state == .failed && ["attachment_expired", "attachment_not_ready", "not_found", "attachment_upload_failed", "dm_read_only"].contains(original.error ?? "")
        var next: [ChatAttachmentDraft] = []
        var committed = false
        defer { if !committed && renew { for draft in next { manager.storage.remove(key, id: draft.id) } } }
        for var draft in owned {
            if renew { draft = try manager.renewed(draft, capture: capture) }
            else {
                // Unknown outcome: first replay the original IDs, including after
                // reconnect. Never upload replacement bytes before this resolves.
                draft.state = .ready; draft.problem = nil
            }
            next.append(draft)
        }
        var args = Self.args(original)
        let files = row.attachments.compactMap { file in owned.firstIndex { $0.id == file.id }.map { next[$0].file } }
        args["attachment_ids"] = .array(files.map { .string($0.id) })
        let command = try prepareCommand(key, type: original.type, args: .object(args))
        try manager.store.dmWrite { db in
            for (old, new) in zip(owned, next) {
                if renew { try manager.replace(db, draft: old, with: new) }
                else { try ChatAttachments.put(db, new) }
            }
            guard let data = try Data.fetchOne(db, sql: "SELECT body FROM dm_messages WHERE dm_id = ? AND message_id = ? AND seq = 0", arguments: [dm, row.id]) else { throw ChatAttachmentError.changed }
            var message = try JSONDecoder().decode(ChatDMMessageWire.self, from: data); message.attachments = files
            try db.execute(sql: "UPDATE dm_messages SET body = ?, local_state = 'sending', local_error = NULL, command_id = ? WHERE dm_id = ? AND message_id = ?",
                arguments: [try JSONEncoder().encode(message), command.record.commandId, dm, row.id])
            _ = try command.table.insert(db, command.record, seq: command.record.seq)
        }
        committed = true
        if renew { for file in owned { manager.storage.remove(key, id: file.id) } }
        manager.reconcile(); command.sent()
    }
}
