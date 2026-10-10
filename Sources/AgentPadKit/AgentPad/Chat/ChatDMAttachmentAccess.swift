import Foundation
import GRDB

extension ChatAttachmentManager {
    func draftVersion(owner: ChatAttachmentOwner, root: String?) -> String? {
        try? store.queue.read { db in
            if let dm = owner.dmID { return try ChatDMStore.draft(db, dm, root: root)?.version }
            return try String.fetchOne(db, sql: "SELECT version FROM drafts WHERE channel_id = ? AND thread_root_id = ?", arguments: [owner.id, root ?? ""])
        }
    }

    func dmStamp(_ dm: String, message: ChatMessage?, file: ChatAttachment?) -> Stamp? {
        _ = revision
        guard let service, limits(for: .dm(dm)) != nil, service.orgSessions[key]?.store === store,
              service.dmAllowed(key, dm), let sync = service.dmSync(key), let connection = service.connection else { return nil }
        return try? store.dmRead { db in
            guard let meta = try Row.fetchOne(db, sql: "SELECT generation, pending_generation FROM meta WHERE id = 1"),
                  let generation: String = meta["generation"], (meta["pending_generation"] as String?) == nil,
                  let epoch = try Int.fetchOne(db, sql: "SELECT epoch FROM dm_meta"),
                  let card = try ChatDMStore.card(db, dm), let window = try ChatDMStore.windowEpoch(db, dm) else { return nil }
            if let message, let file {
                guard message.dmId == dm, let current = try ChatDMStore.messages(db, dm).first(where: { $0.id == message.id }),
                      !current.deleted, !current.loading, current.hasFixed, current.revision == message.revision,
                      current.attachments.contains(file),
                      try Self.dmRevisionCurrent(db, dm: dm, message: message.id, revision: message.revision) else { return nil }
            }
            return Stamp(session: connection.sessionId, generation: generation, access: epoch, window: window,
                connection: service.attachmentEpoch, owner: .dm(dm), dmEpoch: sync.epoch, dmVersion: card.version,
                dmWritable: card.writable, message: message?.id, revision: message?.revision, file: file, executionAccess: -1)
        }
    }

    /// Member pointers fence a file even when the message has never been cached.
    static func dmRevisionCurrent(_ db: Database, dm: String, message: String, revision: Int) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT revision, deleted FROM dm_revisions WHERE dm_id = ? AND message_id = ?", arguments: [dm, message]) else { return true }
        return !(row["deleted"] as Bool) && (row["revision"] as Int) <= revision
    }
}


extension ChatService {
    func reconcileDMScopes(_ me: ChatMe, connection: ChatConnection) {
        let allowed = Set(me.orgs.map(\.orgId))
        let known = files.attachmentScopes(server: connection.server, account: connection.accountId)
            .union(orgSessions.keys.filter { $0.server == connection.server && $0.accountId == connection.accountId })
        for key in known where !allowed.contains(key.orgId) && key != connection.orgKey { membershipLost(key) }
    }

    func reconcileDMAttachments(_ key: ChatOrgKey) {
        if let manager = attachmentManagers[key] { manager.reconcile(); return }
        guard let store = orgSessions[key]?.store,
              let owned = try? store.dmRead({ try ChatAttachments.drafts($0, includingQueued: true) }) else { return }
        files.attachmentStorage.prune(key, keeping: Set(owned.map(\.id)))
    }
}
