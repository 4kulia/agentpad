import AgentPadHookKit
import Foundation
import GRDB

enum ChatSessionAuthor: Codable, Equatable {
    case agent(String), session(String)

    var field: String {
        switch self { case .agent: "author_agent_id"; case .session: "author_session_name" }
    }
    var value: String {
        switch self { case .agent(let id): id; case .session(let name): name }
    }
}

@MainActor
enum ChatSessionTools {
    struct Failure: Error { var code: String; var retryAfter: Int? = nil }

    static func handle(_ request: AgentPadCLIRequest, origin: AgentPadCallerOrigin,
                       sessions: @escaping @MainActor () -> [Session], service: ChatService = .shared,
                       isCallerWaiting: @escaping @MainActor () -> Bool = { true },
                       signatureVerifier: @escaping @Sendable (Int32) -> Bool = ChatClaudeProcess.hasTrustedSignature,
                       scan: @escaping @Sendable (Int32) -> [SessionProcessScanner.Raw] = SessionProcessScanner.identityProcesses,
                       kernel: ChatSessionIdentity.Kernel = .init()) async -> AgentPadCLIResponse {
        var privateAccess = false
        do {
            guard let raw = request.chatArguments, raw.utf8.count <= 24 * 1024,
                  let json = try? JSONDecoder().decode(ChatJSON.self, from: Data(raw.utf8)) else { throw Failure(code: "invalid_args") }
            privateAccess = json["attachment_id"] != nil || json["kind"]?.string == "dm" || ["dms", "members"].contains(json["scope"]?.string ?? "")
            let verified = try await ChatSessionIdentity.verify(origin, sessions: sessions(), scan: scan,
                                                                signatureVerifier: signatureVerifier, kernel: kernel)
            if privateAccess {
                try await ChatPersonalAccess.waitForConversation(verified, sessions: sessions, kernel: kernel, isCallerWaiting: isCallerWaiting)
            }
            let result = try await call(json, caller: verified.caller, service: service, isCallerWaiting: isCallerWaiting,
                personalConversation: { try ChatPersonalAccess.conversation(caller: verified.caller, sessions: sessions(), kernel: kernel) }) {
                try ChatSessionIdentity.revalidate(verified, sessions: sessions(), kernel: kernel)
                return true
            }
            try ChatSessionIdentity.revalidate(verified, sessions: sessions(), kernel: kernel)
            var response = AgentPadCLIResponse(ok: true)
            response.chatResult = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            return response
        } catch let problem as ChatSessionIdentity.VerificationError {
            return privateAccess ? failure("dm_not_allowed") : failure(problem.rawValue, message: problem.message)
        }
        catch let problem as Failure { return failure(problem.code, retryAfter: problem.retryAfter) }
        catch let ChatAPIError.server(_, code, retryAfter) { return failure(code, retryAfter: retryAfter.map { Int(ceil($0)) }) }
        catch { return failure("not_connected") }
    }

    static func failure(_ code: String, retryAfter: Int? = nil, message: String? = nil) -> AgentPadCLIResponse {
        var result: [String: ChatJSON] = ["error": .string(code)]
        if let retryAfter { result["retry_after_seconds"] = .number(Double(retryAfter)) }
        if let message { result["message"] = .string(message) }
        var response = AgentPadCLIResponse.failure(code)
        response.chatResult = String(decoding: (try? JSONEncoder().encode(ChatJSON.object(result))) ?? Data(), as: UTF8.self)
        return response
    }

    static func call(_ json: ChatJSON, caller: ChatLocalCaller, service: ChatService,
                     isCallerWaiting: @escaping @MainActor () -> Bool = { true },
                     personalConversation: @escaping @MainActor () throws -> ChatPersonalAccess.Conversation = { throw Failure(code: "dm_not_allowed") },
                     preparePost: @escaping @MainActor (String) throws -> ChatSessionAuthor? = { _ in nil },
                     revalidate: @escaping @MainActor () throws -> Bool) async throws -> ChatJSON {
        let operation: @MainActor () async throws -> ChatJSON = {
            try await callChecked(json, caller: caller, service: service, isCallerWaiting: isCallerWaiting,
                                  personalConversation: personalConversation, preparePost: preparePost, revalidate: revalidate)
        }
        if json["attachment_id"] != nil {
            return try await withDownloadDeadline(seconds: service.mcpDownloadDeadline, isCallerWaiting: isCallerWaiting, operation: operation)
        }
        return try await operation()
    }

    private static func callChecked(_ json: ChatJSON, caller: ChatLocalCaller, service: ChatService,
                     isCallerWaiting: @escaping @MainActor () -> Bool = { true },
                     personalConversation: @escaping @MainActor () throws -> ChatPersonalAccess.Conversation = { throw Failure(code: "dm_not_allowed") },
                     preparePost: @escaping @MainActor (String) throws -> ChatSessionAuthor? = { _ in nil },
                     revalidate: @escaping @MainActor () throws -> Bool) async throws -> ChatJSON {
        guard case .object(let args) = json, let tool = args["tool"]?.string else { throw Failure(code: "invalid_args") }
        var payload = args; payload["tool"] = nil
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatJSON.object(payload))) as? [String: Any],
              AgentPadChatToolArguments.valid(tool, object) else { throw Failure(code: "invalid_args") }
        let privateDM = args["kind"]?.string == "dm" || ["dms", "members"].contains(args["scope"]?.string ?? "")
        if privateDM {
            return try await callDM(args, caller: caller, service: service, isCallerWaiting: isCallerWaiting,
                                    personalConversation: personalConversation, revalidate: revalidate)
        }
        guard try revalidate(), isCallerWaiting(), !Task.isCancelled, let connection = service.connection,
              service.state == .signedIn, let token = service.token else { throw Failure(code: "not_connected") }
        func uuid(_ key: String, optional: Bool = false) throws -> String? {
            guard let value = args[key] else {
                if optional { return nil }
                throw Failure(code: "invalid_args")
            }
            guard let raw = value.string, let id = UUID(uuidString: raw) else { throw Failure(code: "invalid_args") }
            return id.uuidString.lowercased()
        }
        let org = try uuid("org_id", optional: tool == "chat_channels") ?? connection.orgId
        guard let org else { throw Failure(code: "not_found") }
        let key = ChatOrgKey(server: connection.server, accountId: connection.accountId, orgId: org)
        guard let store = service.orgSessions[key]?.store, service.isServerKnown(service, key),
              ChatNotifications.allowed(service, key, channel: nil) else { throw Failure(code: "not_connected") }
        guard service.supports("chat.session_tools", key: key) else { throw Failure(code: "unsupported") }
        let channel = try uuid("channel_id", optional: tool == "chat_channels")
        let root = try uuid("thread_root_id", optional: true)
        let attachment = args["attachment_id"]?.string?.lowercased()
        var downloadConversation: ChatPersonalAccess.Conversation?
        if attachment != nil {
            let conversation = try personalConversation()
            try ChatPersonalAccess.require(conversation, caller: caller, service: service)
            downloadConversation = conversation
            guard service.supports("chat.attachments", key: key), service.serverAttachmentLimits[key.server]?.valid == true else { throw Failure(code: "unsupported") }
        }
        let attachmentEpoch = service.attachmentEpoch
        let stamp = try await store.queue.read { db -> (String?, Int) in
            (try String.fetchOne(db, sql: "SELECT generation FROM meta WHERE id = 1"),
             try Int.fetchOne(db, sql: "SELECT channel_access_epoch FROM meta WHERE id = 1") ?? -1)
        }
        func cacheIsCurrent() -> Bool {
            guard isCallerWaiting(), !Task.isCancelled, service.state == .signedIn, let now = service.connection,
                  now.server == connection.server, now.accountId == connection.accountId, now.sessionId == connection.sessionId,
                  service.isServerKnown(service, key), ChatNotifications.allowed(service, key, channel: channel) else { return false }
            return (try? store.queue.read { db in
                try String.fetchOne(db, sql: "SELECT generation FROM meta WHERE id = 1") == stamp.0
                    && Int.fetchOne(db, sql: "SELECT channel_access_epoch FROM meta WHERE id = 1") == stamp.1
            }) == true
        }
        func current() throws -> Bool {
            guard cacheIsCurrent() else { return false }
            if let downloadConversation {
                guard service.attachmentEpoch == attachmentEpoch, service.supports("chat.attachments", key: key),
                      try personalConversation() == downloadConversation else { return false }
                try ChatPersonalAccess.require(downloadConversation, caller: caller, service: service)
            }
            // Kernel identity follows the synchronous rights/DB read:
            // no suspension between this guard and queuing/returning data.
            return try revalidate()
        }
        guard try current() else { throw Failure(code: "not_found") }
        let api = service.makeAPI(connection.server)
        var result: ChatJSON
        switch tool {
        case "chat_channels":
            if let after = args["after"], after.string == nil || (after.string?.utf8.count ?? 0) > 512 { throw Failure(code: "invalid_args") }
            let page = try await api.channelsPage(org, after: args["after"]?.string, token: token)
            guard try current() else { throw Failure(code: "not_found") }
            let names = try await store.queue.read { db -> [String: String] in
                Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT team_id, name FROM teams WHERE mine = 1").map { ($0["team_id"], $0["name"]) })
            }
            result = .object(["org_id": .string(org), "channels": .array(page.channels.prefix(100).compactMap { c in
                guard let team = names[c.teamId] else { return nil }
                return .object(["channel_id": .string(c.channelId), "team_id": .string(c.teamId), "team_name": .string(team),
                    "name": .string(c.name), "archived": .bool(c.archived), "can_post": .bool(!c.archived)])
            }), "next": page.next.map(ChatJSON.string) ?? .null])
        case "chat_read":
            guard let channel else { throw Failure(code: "invalid_args") }
            var before: Int?
            if let value = args["before"] {
                guard case .number(let number) = value, number > 0, number < Double(Int.max), number.rounded() == number else { throw Failure(code: "invalid_args") }
                before = Int(number)
            }
            let page = try await api.messagesPage(org, channel: channel, root: root, before: before, token: token)
            guard try current(), page.messages.count <= 100 else { throw Failure(code: "not_found") }
            if let attachment {
                guard page.messages.allSatisfy({ $0.channelId == channel && (root == nil || $0.messageId == root || $0.threadRootId == root) }),
                      let file = page.messages.filter({ $0.deletedAt == nil }).flatMap(\.attachments).first(where: { $0.id == attachment }),
                      let limits = service.serverAttachmentLimits[key.server], file.size > 0, file.size <= min(limits.fileBytes, 10 * 1024 * 1024) else { throw Failure(code: "not_found") }
                let reservation = try service.mcpDownloads.reserve(file, surface: caller.surface, key: key, store: store)
                var completed = false
                defer { if !completed { service.mcpDownloads.remove(reservation) } }
                let bytes = try await service.mcpDownloads.transfer(reservation) {
                    guard try current() else { throw Failure(code: "not_found") }
                    return try await api.attachmentBytes(path: "/v1/orgs/\(org)/attachments/\(attachment)/original", token: token, limit: file.size)
                }
                guard try current() else { throw Failure(code: "not_found") }
                let result = try service.mcpDownloads.finish(reservation, bytes: bytes)
                guard try current() else { throw Failure(code: "not_found") }
                completed = true
                return result
            }
            // No cache writes and no user read-mark changes.
            result = .object(["org_id": .string(org), "channel_id": .string(channel),
                "thread_root_id": root.map(ChatJSON.string) ?? .null,
                "messages": try attachmentProjection(page.messages),
                "next": page.next.map { .number(Double($0)) } ?? .null])
        default:
            guard let channel, let text = args["text"]?.string, ChatChannelModel.textProblem(text) == nil,
                  let generation = stamp.0 else { throw Failure(code: "invalid_args") }
            let id = try uuid("message_id", optional: true) ?? UUID().uuidString.lowercased()
            // A fresh authenticated read makes access current even on an exact
            // repeat; the post command itself validates the root/author atomically.
            let page = try await api.messagesPage(org, channel: channel, root: root, before: nil, token: token)
            if let root, !page.messages.contains(where: { $0.messageId == root && $0.threadRootId == nil && $0.deletedAt == nil }) {
                throw Failure(code: "not_found")
            }
            guard try current() else { throw Failure(code: "not_found") }
            let author = try preparePost(generation)
            let command = try service.queueSessionPost(key, caller: caller, generation: generation, message: id,
                                                       channel: channel, root: root, text: text, author: author)
            let until = Date().addingTimeInterval(2)
            repeat {
                guard try current() else { throw Failure(code: "not_found") }
                if let outcome = try service.sessionPostOutcome(key, message: id, command: command) { return outcome }
                try await Task.sleep(for: .milliseconds(50))
            } while Date() < until
            result = .object(["status": .string("pending"), "message_id": .string(id), "org_id": .string(org),
                "channel_id": .string(channel), "thread_root_id": root.map(ChatJSON.string) ?? .null])
        }
        guard try current() else { throw Failure(code: "not_found") }
        guard try JSONEncoder().encode(result).count <= 1024 * 1024 else { throw Failure(code: "too_large") }
        return result
    }
}

extension ChatService {
    func reconcileSessionPosts(_ key: ChatOrgKey) {
        guard let connection, connection.orgKey == key, let store = orgSessions[key]?.store else { return }
        try? store.queue.write { db in
            try db.execute(sql: """
                UPDATE outbox SET state = 'pending' WHERE type = 'message.post_from_session' AND state = 'sent'
                    AND command_id IN (SELECT p.command_id FROM session_posts p JOIN meta m ON m.id = 1
                        WHERE p.result IS NULL AND p.session_id = ? AND p.generation = m.generation AND m.pending_generation IS NULL)
                """, arguments: [connection.sessionId])
            try db.execute(sql: """
                UPDATE messages SET local_state = 'failed', local_error = (SELECT o.error FROM session_posts p JOIN outbox o ON o.command_id = p.command_id WHERE p.message_id = messages.message_id)
                WHERE has_fixed = 0 AND message_id IN (SELECT p.message_id FROM session_posts p JOIN outbox o ON o.command_id = p.command_id WHERE o.state IN ('failed', 'dropped'))
                """)
        }
    }
    func bindPublication(_ key: ChatOrgKey, agent: String, surface: UUID?) throws {
        guard let journal, let connection, connection.orgKey == key, let generation = try journal.generation(key).generation else { throw ChatError.notConnected }
        try journal.queue.write { db in
            try db.execute(sql: "DELETE FROM publication_surfaces WHERE server = ? AND account_id = ? AND org_id = ? AND agent_id = ?",
                           arguments: [key.server.description, key.accountId, key.orgId, agent])
            if let surface {
                try db.execute(sql: "INSERT INTO publication_surfaces (server, account_id, org_id, agent_id, surface_id, session_id, generation) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    arguments: [key.server.description, key.accountId, key.orgId, agent, surface.uuidString.lowercased(), connection.sessionId, generation])
            }
        }
    }

    func sessionAuthor(_ key: ChatOrgKey, caller: ChatLocalCaller, generation: String) throws -> ChatSessionAuthor {
        guard let journal, let connection else { throw ChatError.notConnected }
        let ids = try journal.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT b.agent_id FROM publication_surfaces b JOIN assignments a
                    ON a.server = b.server AND a.account_id = b.account_id AND a.org_id = b.org_id AND a.agent_id = b.agent_id
                WHERE b.server = ? AND b.account_id = ? AND b.org_id = ? AND b.surface_id = ? AND b.session_id = ? AND b.generation = ?
                    AND a.state = 'active' AND a.published_session = b.session_id AND a.requested IS NULL
                """, arguments: [key.server.description, key.accountId, key.orgId, caller.surface, connection.sessionId, generation])
        }.filter { localAgent($0)?.enabled == true && localAgent($0)?.isSession == true }
        guard ids.count <= 1 else { throw ChatSessionTools.Failure(code: "ambiguous_author") }
        return ids.first.map(ChatSessionAuthor.agent) ?? .session(caller.signature)
    }

    func queueSessionPost(_ key: ChatOrgKey, caller: ChatLocalCaller, generation: String, message: String,
                          channel: String, root: String?, text: String, author savedAuthor: ChatSessionAuthor? = nil) throws -> String {
        guard let connection, connection.orgKey == key, let store = orgSessions[key]?.store else { throw ChatError.notConnected }
        if let held = try store.queue.read({ try Row.fetchOne($0, sql: "SELECT p.*, o.body_bytes, o.state, o.error FROM session_posts p JOIN outbox o ON o.command_id = p.command_id WHERE p.message_id = ?", arguments: [message]) }) {
            guard (held["provenance"] as String) == caller.provenance, (held["generation"] as String) == generation,
                  (held["session_id"] as String) == connection.sessionId,
                  let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: held["body_bytes"]),
                  envelope.args["channel_id"]?.string == channel, envelope.args["thread_root_id"]?.string == root,
                  envelope.args["text"]?.string == text else { throw ChatSessionTools.Failure(code: "message_conflict") }
            if let savedAuthor, envelope.args[savedAuthor.field]?.string != savedAuthor.value {
                throw ChatSessionTools.Failure(code: "message_conflict")
            }
            let command: String = held["command_id"], state: String = held["state"]
            let quota = state == "failed" && (held["error"] as String?) == "rate_limited"
            if quota, let until: Int = held["retry_after"], until > Int(Date().timeIntervalSince1970) {
                throw ChatSessionTools.Failure(code: "rate_limited", retryAfter: until - Int(Date().timeIntervalSince1970))
            }
            if quota || state == "sent" && (held["result"] as String?) == nil {
                try store.queue.write { db in
                    let pending = try String.fetchAll(db, sql: "SELECT p.provenance FROM session_posts p JOIN outbox o ON o.command_id = p.command_id WHERE o.state IN ('pending', 'unconfirmed')")
                    guard pending.count < 10, !pending.contains(caller.provenance) else { throw ChatSessionTools.Failure(code: "busy") }
                    try db.execute(sql: "UPDATE outbox SET state = 'pending', error = NULL, next_attempt_at = NULL WHERE command_id = ?", arguments: [command])
                    try db.execute(sql: "UPDATE messages SET local_state = 'sending', local_error = NULL WHERE message_id = ? AND has_fixed = 0", arguments: [message])
                }
            }
            orgSessions[key]?.outbox?.pump()
            // A repeat is this exact attempt, never a recalculated author.
            return command
        }
        let author = try savedAuthor ?? sessionAuthor(key, caller: caller, generation: generation)
        guard case .object(var args) = Self.postArgs(message, channel, root, text, []) else { throw ChatSessionTools.Failure(code: "invalid_args") }
        args[author.field] = .string(author.value)
        let prepared = try prepareCommand(key, type: "message.post_from_session", args: .object(args))
        try store.queue.write { db in
            let pending = try Row.fetchAll(db, sql: "SELECT p.provenance FROM session_posts p JOIN outbox o ON o.command_id = p.command_id WHERE o.state IN ('pending', 'unconfirmed')")
            guard pending.count < 10, !pending.contains(where: { ($0["provenance"] as String) == caller.provenance }) else { throw ChatSessionTools.Failure(code: "busy") }
            // IDs of manual posts and other local tabs cannot be borrowed.
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE message_id = ?)", arguments: [message]) != true else { throw ChatSessionTools.Failure(code: "message_conflict") }
            try ChatMessages.insertSending(db, id: message, channel: channel, root: root, author: key.accountId, text: text, mentions: [], at: Self.now())
            try db.execute(sql: "UPDATE messages SET \(author.field) = ? WHERE message_id = ?", arguments: [author.value, message])
            _ = try prepared.table.insert(db, prepared.record, seq: prepared.record.seq)
            try db.execute(sql: "INSERT INTO session_posts (message_id, command_id, provenance, generation, session_id) VALUES (?, ?, ?, ?, ?)",
                           arguments: [message, prepared.record.commandId, caller.provenance, generation, connection.sessionId])
        }
        prepared.sent()
        return prepared.record.commandId
    }

    func sessionPostOutcome(_ key: ChatOrgKey, message: String, command: String) throws -> ChatJSON? {
        guard let store = orgSessions[key]?.store else { throw ChatError.notConnected }
        return try store.queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT p.*, o.state, o.error FROM session_posts p JOIN outbox o ON o.command_id = p.command_id WHERE p.message_id = ? AND p.command_id = ?", arguments: [message, command]) else { throw ChatSessionTools.Failure(code: "not_found") }
            if (row["state"] as String) == "sent", let json: String = row["result"],
               case .object(var result) = try JSONDecoder().decode(ChatJSON.self, from: Data(json.utf8)) {
                result["status"] = .string("sent"); result["org_id"] = .string(key.orgId)
                return .object(result)
            }
            if ["failed", "dropped"].contains(row["state"] as String) {
                let until: Int? = row["retry_after"]
                throw ChatSessionTools.Failure(code: row["error"] ?? "not_sent", retryAfter: until.map { max(0, $0 - Int(Date().timeIntervalSince1970)) })
            }
            return nil
        }
    }
}
