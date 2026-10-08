import Foundation
import GRDB

enum ChatMentions {
    /// Markdown code/quotes and mail addresses are data, not requests.
    static func prose(_ text: String) -> String {
        // Use the very same F7 tree as the channel display. If its bounded
        // parser cannot represent the input, it cannot authorize a call.
        guard let blocks = MarkdownRenderer.chatDocument(text) else { return "" }
        func inline(_ nodes: [ChatInline]) -> String {
            nodes.map { node in
                switch node {
                case .text(let s): return String(String.UnicodeScalarView(s))
                case .strong(let c), .em(let c), .del(let c): return inline(c)
                case .code, .literal, .link, .lineBreak: return " "
                }
            }.joined()
        }
        var result = blocks.map { block in
            switch block {
            case .paragraph(let c), .heading(_, let c), .item(_, let c), .continuation(let c): return inline(c)
            case .table(let header, let rows): return ([header] + rows).flatMap { $0 }.map(inline).joined(separator: "\n")
            case .code, .quote, .rule, .listOpen, .listClose, .itemNext: return " "
            }
        }.joined(separator: "\n")
        for pattern in ["(?<!\\w)'[^'\\n]*'", "\"[^\"\\n]*\"", "“[^”\\n]*”", "«[^»\\n]*»"] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
            }
        }
        return result
    }

    static func contains(_ address: String, in text: String) -> Bool {
        !ranges(address, in: prose(text)).isEmpty
    }

    static func ranges(_ address: String, in text: String) -> [NSRange] {
        let pattern = "(?<![\\w@./\\\\-])@" + NSRegularExpression.escapedPattern(for: address) + "(?![\\w@-]|\\.[\\w])"
        return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?
            .matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range) ?? []
    }

    static func agents(in text: String, agents: [ChatChannelAgent]) -> [ChatChannelAgent] {
        var seen = Set<String>()
        let text = prose(text)
        return agents.filter { $0.enabled && $0.address.map { !ranges($0, in: text).isEmpty } == true && seen.insert($0.agentId).inserted }
    }
}

extension ChatService {
    /// One synchronous entry point for button/keyboard/all windows. Nothing
    /// can await before the exact draft version has a committed send attempt.
    func sendChannel(_ key: ChatOrgKey, channel: String, root: String?, text: String, mentions: [String],
                     agents: [ChatChannelAgent], draftVersion: String, mentionOnly: Bool,
                     additionalContext: [ChatMessage] = []) throws -> String {
        guard let store = orgSessions[key]?.store, let connection, connection.orgKey == key,
              ChatNotifications.allowed(self, key, channel: channel) else { throw ChatError.notConnected }
        if let id = try store.queue.read({ try String.fetchOne($0, sql: "SELECT message_id FROM channel_sends WHERE draft_version = ?", arguments: [draftVersion]) }) { return id }
        let uploads = try attachments(key)?.prepared(channel: channel, root: root) ?? []
        if let problem = ChatChannelModel.textProblem(text), !(text.isEmpty && !uploads.isEmpty) { throw ChatError.storage(problem) }
        let message = uploads.first?.messageId ?? UUID().uuidString.lowercased()
        var postArgs = Self.postArgs(message, channel, root, text, mentions)
        if case .object(var fields) = postArgs, !uploads.isEmpty {
            fields["attachment_ids"] = .array(uploads.map { .string($0.id) }); postArgs = .object(fields)
        }
        let post = try prepareCommand(key, type: uploads.isEmpty ? "message.post" : "message.post_with_attachments", args: postArgs)
        let targets = mentionOnly || !supports("chat.channel_ux1", key: key) ? [] : ChatMentions.agents(in: text, agents: agents)
        var context = targets.isEmpty ? [] : additionalContext.filter { $0.channelId == channel && ChatChannelAsk.eligible($0) }
        if let root, !targets.isEmpty {
            guard let row = try store.queue.read({ try Row.fetchOne($0, sql: "SELECT * FROM messages WHERE message_id = ? AND channel_id = ?", arguments: [root, channel]) }),
                  ChatChannelAsk.eligible(ChatMessage(row: row)) else { throw ChatError.storage("Load the undeleted thread root before asking an agent.") }
            if !context.contains(where: { $0.messageId == root }) { context.append(ChatMessage(row: row)) }
        }
        // The source and root are mandatory and budgeted before optional context.
        let sorted = context.sorted { a, b in a.messageId == root && b.messageId != root || (a.messageId != root && b.messageId != root && (a.seq ?? 0) < (b.seq ?? 0)) }
        var snapshots = [ChatChannelContent.Message](), bytes = text.utf8.count, seen = Set<String>()
        for m in sorted where seen.insert(m.messageId).inserted {
            guard snapshots.count < ChatChannelAsk.maxContext - 1, bytes + m.text.utf8.count <= ChatChannelAsk.maxContextBytes else {
                throw ChatError.storage("The selected context exceeds 20 messages / 48 KiB. Reduce it before sending.")
            }
            snapshots.append(.init(messageId: m.messageId, revision: m.revision, authorAccountId: m.authorAccountId,
                                   authorAgentId: m.authorAgentId, text: m.text, createdAt: nil))
            bytes += m.text.utf8.count
        }
        snapshots.append(.init(messageId: message, revision: 1, authorAccountId: key.accountId, text: text))
        var manifest = try store.queue.read { db -> [ChatAttachmentManifest] in
            let json = try String.fetchOne(db, sql: "SELECT attachment_selection FROM drafts WHERE channel_id = ? AND thread_root_id = ?", arguments: [channel, root ?? ""]) ?? "[]"
            return try JSONDecoder().decode([ChatAttachmentManifest].self, from: Data(json.utf8))
        }
        // A rollback may withdraw agent calls as well as attachment support.
        // Check the saved selection before reducing the send to plain text.
        if !manifest.isEmpty, !mentionOnly {
            guard supports("chat.attachments_context", key: key), attachments(key)?.limits != nil else { throw ChatAttachmentError.paused }
        }
        if targets.isEmpty { manifest = [] }
        if !manifest.isEmpty {
            guard let limits = serverAttachmentLimits[key.server],
                  manifest.count <= limits.contextFiles, manifest.reduce(0, { $0 + $1.file.size }) <= limits.contextBytes,
                  Set(manifest.map(\.id)).count == manifest.count else { throw ChatAttachmentError.size }
            guard targets.allSatisfy({ ["read", "edit-files"].contains($0.access) }) else { throw ChatAttachmentError.bash }
            for item in manifest {
                if item.messageId == message {
                    guard let draft = uploads.first(where: { $0.id == item.id }), item.revision == 1,
                          draft.sha256 == item.sha256, draft.file == item.file else { throw ChatAttachmentError.changed }
                } else {
                    guard let source = context.first(where: { $0.id == item.messageId }), source.revision == item.revision,
                          source.attachments.contains(item.file) else { throw ChatAttachmentError.changed }
                }
            }
            // Context selection order is preserved, then normalized for the server manifest.
            for index in manifest.indices { manifest[index].file.position = index }
        }
        let deadline = ChatCallStore.timestamp(Date().addingTimeInterval(7 * 24 * 60 * 60))
        var calls: [(request: String, agent: String, record: ChatCommandRecord)] = []
        for agent in targets {
            let request = UUID().uuidString.lowercased()
            let policy = agent.trust?.enabled == true ? agent.trust?.policyId : nil
            var args: [String: ChatJSON] = [
                "request_id": .string(request), "agent_id": .string(agent.agentId), "channel_id": .string(channel),
                "text": .string(text), "conditions_version": .number(manifest.isEmpty ? 1 : 2), "deliver_by": .string(deadline),
                "source_message_id": .string(message), "source_revision": .number(1),
                "reply_mode": .string(root == nil ? "channel" : "thread"),
                "context": .array(snapshots.map { .object(["message_id": .string($0.messageId), "revision": .number(Double($0.revision))]) })]
            if let root { args["thread_root_id"] = .string(root) }
            if let policy { args["requested_policy_id"] = .string(policy) }
            if !manifest.isEmpty { args["attachments"] = .array(manifest.map(\.reference)) }
            var command = try prepareCommand(key, type: manifest.isEmpty ? "request.create_in_channel_v2" : "request.create_in_channel_with_attachments", args: .object(args)).record
            command.dependsOn = post.record.commandId
            command.seq = post.record.seq + Int64(calls.count) + 1
            calls.append((request, agent.agentId, command))
            if let local = localChannelExecutor(key, channel: channel, agent: agent), let journal,
               let generation = try journal.generation(key).generation {
                try journal.storeAuthority(ChatChannelAuthority(id: request, server: key.server.description, account: key.accountId,
                    org: key.orgId, session: connection.sessionId, generation: generation, channel: channel, agent: agent.agentId,
                    basis: "self_call", settings: ChatExecutionSettings(local), request: request, source: message, text: text,
                    context: snapshots, root: root ?? message, replyMode: root == nil ? "channel" : "thread", deliverBy: deadline, attachments: manifest.isEmpty ? nil : manifest))
            }
        }
        try store.queue.write { db in
            guard try String.fetchOne(db, sql: "SELECT version FROM drafts WHERE channel_id = ? AND thread_root_id = ? AND text = ?", arguments: [channel, root ?? "", text]) == draftVersion else {
                throw ChatError.storage("The draft changed in another window. Review it before sending.")
            }
            try ChatMessages.insertSending(db, id: message, channel: channel, root: root, author: key.accountId, text: text, mentions: mentions, at: Self.now())
            if !uploads.isEmpty {
                try ChatAttachments.write(db, id: message, files: uploads.enumerated().map { index, draft in var file = draft.file; file.position = index; return file }, only: text.isEmpty)
            }
            _ = try post.table.insert(db, post.record, seq: post.record.seq)
            try db.execute(sql: "INSERT INTO channel_sends (draft_version, channel_id, thread_root_id, message_id, command_id) VALUES (?, ?, ?, ?, ?)",
                           arguments: [draftVersion, channel, root, message, post.record.commandId])
            for call in calls {
                _ = try post.table.insert(db, call.record, seq: call.record.seq)
                try db.execute(sql: "INSERT INTO channel_call_intents (request_id, message_id, agent_id, command_id, attachment_manifest) VALUES (?, ?, ?, ?, ?)",
                               arguments: [call.request, message, call.agent, call.record.commandId, String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)])
            }
            try db.execute(sql: "DELETE FROM drafts WHERE channel_id = ? AND thread_root_id = ? AND version = ?", arguments: [channel, root ?? "", draftVersion])
            if !uploads.isEmpty {
                for var upload in uploads { upload.queued = true; try ChatAttachments.put(db, upload) }
            }
        }
        post.sent()
        return message
    }

    func cancelChannelIntent(_ key: ChatOrgKey, request: String) -> String? {
        guard let store = orgSessions[key]?.store else { return "Not connected" }
        do {
            let local = try store.queue.write { db -> Bool in
                guard let command = try ChatCommandRecord.fetchOne(db, sql: "SELECT o.* FROM outbox o JOIN channel_call_intents i ON i.command_id = o.command_id WHERE i.request_id = ?", arguments: [request]),
                      command.state == .pending,
                      try Bool.fetchOne(db, sql: "SELECT send_started_at IS NULL FROM channel_call_intents WHERE request_id = ?", arguments: [request]) == true else { return false }
                try db.execute(sql: "UPDATE channel_call_intents SET cancelled = 1 WHERE request_id = ?", arguments: [request])
                try db.execute(sql: "UPDATE outbox SET state = 'dropped', error = 'cancelled' WHERE command_id = ?", arguments: [command.commandId])
                return true
            }
            try journal?.revokeAuthority(request)
            if local { return nil }
            if (try? store.calls.request(request)) == nil,
               let parent = try store.queue.read({ try String.fetchOne($0, sql: "SELECT command_id FROM channel_call_intents WHERE request_id = ?", arguments: [request]) }) {
                _ = try enqueue(key, type: "request.cancel", args: .object(["request_id": .string(request)]),
                                orderKey: "out:\(request)", dependsOn: parent)
                return nil
            }
            return cancelChannelRequest(key, requestId: request)
        } catch { return error.localizedDescription }
    }

    /// A refused create is retried only by this explicit review action. It
    /// creates a new request and consent, retaining the already posted question.
    @discardableResult
    func retryChannelCall(_ key: ChatOrgKey, source: ChatMessage, agent: ChatChannelAgent, context: [ChatMessage]) throws -> String {
        guard supports("chat.channel_ux1", key: key), let store = orgSessions[key]?.store, let connection, connection.orgKey == key,
              channelAgentAllowed(key, channel: source.channelId), ChatChannelAsk.eligible(source),
              source.authorAccountId == key.accountId, source.authorAgentId == nil, source.authorSessionName == nil,
              agent.channelId == source.channelId, agent.enabled else { throw ChatError.notConnected }
        let old = try store.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT i.request_id, i.command_id, i.attachment_manifest, o.type, s.command_id AS post_command FROM channel_call_intents i
                JOIN channel_sends s ON s.message_id = i.message_id JOIN outbox o ON o.command_id = i.command_id
                JOIN outbox p ON p.command_id = s.command_id
                WHERE i.message_id = ? AND i.agent_id = ? AND o.state = 'failed' AND p.state = 'sent' AND p.session_id = ?
                    AND NOT EXISTS(SELECT 1 FROM requests r WHERE r.request_id = i.request_id AND r.has_fixed)
                """, arguments: [source.messageId, agent.agentId, connection.sessionId])
        }
        guard let old else { throw ChatError.storage("Only a refused request can be retried. Wait for its outcome.") }
        let manifest = try JSONDecoder().decode([ChatAttachmentManifest].self, from: Data((old["attachment_manifest"] as String).utf8))
        if (old["type"] as String) == "request.create_in_channel_with_attachments" {
            guard !manifest.isEmpty, supports("chat.attachments_context", key: key), ["read", "edit-files"].contains(agent.access) else { throw ChatAttachmentError.changed }
        }
        var chosen = context.filter { $0.channelId == source.channelId && ChatChannelAsk.eligible($0) }
        if let selected = chosen.first(where: { $0.messageId == source.messageId }), selected.revision != source.revision {
            throw ChatError.storage("The question changed. Review it and choose the context again.")
        }
        if !chosen.contains(where: { $0.messageId == source.messageId }) { chosen.append(source) }
        if let root = source.threadRootId {
            guard let current = try store.queue.read({ try Row.fetchOne($0, sql: "SELECT * FROM messages WHERE message_id = ? AND channel_id = ?", arguments: [root, source.channelId]) }).map(ChatMessage.init(row:)),
                  ChatChannelAsk.eligible(current) else { throw ChatError.storage("Load the undeleted thread root.") }
            if !chosen.contains(where: { $0.messageId == root }) { chosen.append(current) }
        }
        var seen = Set<String>()
        let fit = ChatChannelAsk.fit(chosen.filter { seen.insert($0.messageId).inserted }, root: source.threadRootId ?? source.messageId)
        guard fit.cut.isEmpty else { throw ChatError.storage("Reduce the context to 20 messages / 48 KiB.") }
        for item in manifest {
            guard let message = chosen.first(where: { $0.id == item.messageId }), message.revision == item.revision,
                  message.attachments.contains(where: { var normalized = $0; normalized.position = item.file.position; return normalized == item.file }) else { throw ChatAttachmentError.changed }
        }
        let request = UUID().uuidString.lowercased(), deadline = ChatCallStore.timestamp(Date().addingTimeInterval(7 * 24 * 60 * 60))
        let snapshots = fit.taken.map { ChatChannelContent.Message(messageId: $0.messageId, revision: $0.revision,
            authorAccountId: $0.authorAccountId, authorAgentId: $0.authorAgentId, text: $0.text) }
        var args: [String: ChatJSON] = ["request_id": .string(request), "agent_id": .string(agent.agentId), "channel_id": .string(source.channelId),
            "source_message_id": .string(source.messageId), "source_revision": .number(Double(source.revision)), "text": .string(source.text),
            "conditions_version": .number(manifest.isEmpty ? 1 : 2), "deliver_by": .string(deadline), "reply_mode": .string(source.threadRootId == nil ? "channel" : "thread"),
            "context": .array(snapshots.map { .object(["message_id": .string($0.messageId), "revision": .number(Double($0.revision))]) })]
        if let root = source.threadRootId { args["thread_root_id"] = .string(root) }
        if agent.trust?.enabled == true, let policy = agent.trust?.policyId { args["requested_policy_id"] = .string(policy) }
        if !manifest.isEmpty { args["attachments"] = .array(manifest.map(\.reference)) }
        let prepared = try prepareCommand(key, type: manifest.isEmpty ? "request.create_in_channel_v2" : "request.create_in_channel_with_attachments", args: .object(args))
        var command = prepared.record; command.dependsOn = old["post_command"]
        if let local = localChannelExecutor(key, channel: source.channelId, agent: agent), let journal,
           let generation = try journal.generation(key).generation {
            try journal.storeAuthority(ChatChannelAuthority(id: request, server: key.server.description, account: key.accountId,
                org: key.orgId, session: connection.sessionId, generation: generation, channel: source.channelId, agent: agent.agentId,
                basis: "self_call", settings: ChatExecutionSettings(local), request: request, source: source.messageId, text: source.text,
                context: snapshots, root: source.threadRootId ?? source.messageId, replyMode: source.threadRootId == nil ? "channel" : "thread",
                deliverBy: deadline, sourceRevision: source.revision, attachments: manifest.isEmpty ? nil : manifest))
        }
        try store.queue.write { db in
            try db.execute(sql: "DELETE FROM channel_call_intents WHERE request_id = ?", arguments: [old["request_id"] as String])
            try db.execute(sql: "UPDATE outbox SET dismissed = 1 WHERE command_id = ?", arguments: [old["command_id"] as String])
            _ = try prepared.table.insert(db, command, seq: command.seq)
            try db.execute(sql: "INSERT INTO channel_call_intents (request_id, message_id, agent_id, command_id, attachment_manifest) VALUES (?, ?, ?, ?, ?)",
                           arguments: [request, source.messageId, agent.agentId, command.commandId, String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)])
        }
        try? journal?.revokeAuthority(old["request_id"] as String)
        prepared.sent()
        return request
    }
}
