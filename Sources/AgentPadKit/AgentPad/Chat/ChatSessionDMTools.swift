import Foundation
import GRDB

enum ChatDMSettings {
    static func enabled(in parsed: [String: Any]) -> Bool {
        (parsed["agents"] as? [String: Any])?["directMessages"] as? Bool ?? true
    }
}

struct ChatDMToolCursor {
    var key: ChatOrgKey
    var scope: String
    var session: String
    var generation: String
    var epoch: Int
    var after: String
}

extension ChatSessionTools {
    static func callDM(_ args: [String: ChatJSON], caller: ChatLocalCaller, service: ChatService,
                       isCallerWaiting: @escaping @MainActor () -> Bool,
                       personalConversation: @escaping @MainActor () throws -> ChatPersonalAccess.Conversation,
                       revalidate: @escaping @MainActor () throws -> Bool) async throws -> ChatJSON {
        guard service.state == .signedIn, let connection = service.connection else { throw Failure(code: "not_connected") }
        let org = args["org_id"]?.string?.lowercased() ?? connection.orgId
        guard let org else { throw Failure(code: "not_connected") }
        let key = ChatOrgKey(server: connection.server, accountId: connection.accountId, orgId: org)
        guard service.supports("chat.dm", key: key), service.supports("chat.dm.session_signature", key: key) else { throw Failure(code: "unsupported") }
        guard service.dmToolsEnabled() else { service.mcpDownloads.removeDM(); throw Failure(code: "dm_access_disabled") }
        let personal = try ChatPersonalAccess.Authorization(caller: caller, service: service,
            personalConversation: personalConversation, revalidate: revalidate)
        let conversation = personal.conversation
        let dm = args["dm_id"]?.string?.lowercased(), root = args["thread_root_id"]?.string?.lowercased()
        let attachment = args["attachment_id"]?.string?.lowercased()
        func attachmentsAvailable() -> Bool {
            service.supports("chat.attachments", key: key) && service.supports("chat.dm.attachments", key: key)
                && service.serverAttachmentLimits[key.server]?.valid == true
                && (service.serverAttachmentLimits[key.server]?.dmSenderBytes ?? 0) > 0
        }
        if attachment != nil, !attachmentsAvailable() { throw Failure(code: "unsupported") }
        guard isCallerWaiting(), !Task.isCancelled, service.dmAllowed(key), let sync = service.dmSync(key),
              let store = service.orgSessions[key]?.store, let token = service.token else { throw Failure(code: "not_connected") }
        let epoch = sync.epoch
        let attachmentEpoch = service.attachmentEpoch
        let stamp = try store.dmRead { db in
            (try String.fetchOne(db, sql: "SELECT generation FROM meta WHERE id = 1"),
             try Int.fetchOne(db, sql: "SELECT epoch FROM dm_meta") ?? -1,
             try dm.flatMap { try ChatDMStore.windowEpoch(db, $0) },
             try dm.flatMap { try ChatDMStore.card(db, $0)?.version })
        }
        guard let generation = stamp.0 else { throw Failure(code: "not_connected") }
        func current() throws {
            guard service.dmToolsEnabled() else { service.mcpDownloads.removeDM(); throw Failure(code: "dm_access_disabled") }
            guard service.supports("chat.dm", key: key), service.supports("chat.dm.session_signature", key: key) else { throw Failure(code: "unsupported") }
            if attachment != nil, !attachmentsAvailable() { throw Failure(code: "unsupported") }
            guard isCallerWaiting(), !Task.isCancelled, service.state == .signedIn, let now = service.connection,
                  now.server == connection.server, now.accountId == connection.accountId, now.orgId == connection.orgId,
                  now.sessionId == connection.sessionId, service.dmSync(key) === sync, sync.epoch == epoch, service.dmAllowed(key),
                  service.orgSessions[key]?.store === store,
                  try store.dmRead({ db in
                      try String.fetchOne(db, sql: "SELECT generation FROM meta WHERE id = 1") == generation
                          && Int.fetchOne(db, sql: "SELECT epoch FROM dm_meta") == stamp.1
                          && String.fetchOne(db, sql: "SELECT pending_generation FROM meta WHERE id = 1") == nil
                          && (attachment == nil || (service.attachmentEpoch == attachmentEpoch
                              && dm.flatMap { try ChatDMStore.windowEpoch(db, $0) } == stamp.2
                              && dm.flatMap { try ChatDMStore.card(db, $0)?.version } == stamp.3))
                  }) else { throw Failure(code: "not_found") }
            try personal.requireCurrent()
        }
        func recordUse() throws {
            try current()
            do { try ChatDMHistory(files: service.files).record(conversation.ids) }
            catch { throw Failure(code: "dm_not_allowed") }
        }
        try current()
        let api = service.makeAPI(connection.server)
        var result: ChatJSON
        let tool = args["tool"]?.string ?? ""
        switch tool {
        case "chat_channels":
            let scope = args["scope"]?.string ?? "dms"
            var after: String?
            if let cursor = args["after"]?.string {
                guard let saved = service.dmToolCursors[cursor], saved.key == key, saved.scope == scope,
                      saved.session == connection.sessionId, saved.generation == generation, saved.epoch == stamp.1 else { throw Failure(code: "invalid_args") }
                after = saved.after
            }
            var next: String?
            if scope == "members" {
                let people = try store.dmRead { try ChatOrgView.Member.read($0) }.filter { $0.accountId != key.accountId }.sorted { $0.accountId < $1.accountId }
                let page = Array(people.filter { after == nil || $0.accountId > after! }.prefix(100))
                if let last = page.last, people.contains(where: { $0.accountId > last.accountId }) { next = last.accountId }
                result = .object(["org_id": .string(org), "members": .array(page.map {
                    .object(["account_id": .string($0.accountId), "name": .string($0.name), "handle": .string($0.handle)])
                })])
            } else {
                let page = try await api.dmPage(org, after: after, token: token)
                try current()
                next = page.next
                result = .object(["org_id": .string(org), "dms": .array(page.dms.map { card in
                    .object(["kind": .string("dm"), "dm_id": .string(card.dmId), "state": .string(card.state), "can_post": .bool(card.writable),
                        "peer": .object(["account_id": .string(card.peer.accountId), "name": .string(card.peer.name), "handle": .string(card.peer.handle)])])
                })])
            }
            var cursor: ChatJSON = .null
            if let next {
                let id = UUID().uuidString.lowercased()
                if service.dmToolCursors.count >= 256 { service.dmToolCursors.removeAll() }
                service.dmToolCursors[id] = .init(key: key, scope: scope, session: connection.sessionId, generation: generation, epoch: stamp.1, after: next)
                cursor = .string(id)
            }
            if case .object(var fields) = result { fields["next"] = cursor; result = .object(fields) }
        case "chat_read":
            guard let dm else { throw Failure(code: "invalid_args") }
            let page = try await api.dmMessages(org, id: dm, root: root, before: args["before"]?.int, token: token)
            try current()
            guard page.messages.count <= 100, page.messages.allSatisfy({ $0.dmId == dm && (root == nil || $0.messageId == root || $0.threadRootId == root) }) else { throw Failure(code: "not_found") }
            if let attachment {
                guard let message = page.messages.first(where: { $0.deletedAt == nil && $0.attachments.contains(where: { $0.id == attachment }) }),
                      let file = message.attachments.first(where: { $0.id == attachment }),
                      let limits = service.serverAttachmentLimits[key.server], file.size > 0,
                      file.size <= min(limits.fileBytes, 10 * 1024 * 1024) else { throw Failure(code: "not_found") }
                func fileCurrent() throws {
                    try current()
                    guard try store.dmRead({ try ChatAttachmentManager.dmRevisionCurrent($0, dm: dm, message: message.messageId, revision: message.revision) }) else { throw Failure(code: "not_found") }
                }
                try fileCurrent()
                let reservation = try service.mcpDownloads.reserve(file, surface: caller.surface, key: key, store: store,
                    dmSource: .init(dm: dm, message: message.messageId, revision: message.revision))
                var completed = false
                defer { if !completed { service.mcpDownloads.remove(reservation) } }
                let bytes = try await service.mcpDownloads.transfer(reservation) {
                    try fileCurrent()
                    return try await api.attachmentBytes(path: "/v1/orgs/\(org)/attachments/\(attachment)/original", token: token, limit: file.size)
                }
                try fileCurrent()
                let result = try service.mcpDownloads.finish(reservation, bytes: bytes)
                try fileCurrent()
                try recordUse()
                completed = true
                return result
            }
            // A member pointer may have arrived while the fresh page was in flight.
            // Refuse stale private data without creating a UI cache or read mark.
            guard try store.dmRead({ db in try page.messages.allSatisfy {
                try $0.deletedAt != nil || ChatAttachmentManager.dmRevisionCurrent(db, dm: dm, message: $0.messageId, revision: $0.revision)
            } }) else { throw Failure(code: "not_found") }
            result = .object(["org_id": .string(org), "kind": .string("dm"), "dm_id": .string(dm),
                "thread_root_id": root.map(ChatJSON.string) ?? .null,
                "messages": .array(try page.messages.map { message in
                    let json = try JSONDecoder().decode(ChatJSON.self, from: JSONEncoder().encode(message))
                    guard case .object(var fields) = json else { throw Failure(code: "not_found") }
                    fields["text"] = .string(message.deletedAt == nil ? (message.canonicalText ?? message.text) : "")
                    fields["canonical_text"] = nil
                    fields["attachments"] = .array(attachmentsAvailable() && message.deletedAt == nil ? message.attachments.map(\.mcpDescriptor) : [])
                    return .object(fields)
                }), "next": page.next.map { .number(Double($0)) } ?? .null])
        default:
            result = try await postDM(args, key: key, caller: caller, conversation: conversation, generation: generation,
                                      service: service, store: store, api: api, token: token, current: current, recordUse: recordUse)
        }
        try current()
        guard try JSONEncoder().encode(result).count <= 1024 * 1024 else { throw Failure(code: "too_large") }
        try recordUse()
        return result
    }
}
