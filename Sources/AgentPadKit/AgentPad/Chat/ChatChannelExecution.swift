import Foundation
import GRDB

/// F8's authenticated content endpoint is the source of the execution snapshot.
/// The request row carries no snapshot. Optional references support servers that
/// supply them; the current API supplies ids/revisions only in /content.
struct ChatChannelContent: Codable, Equatable, Sendable {
    struct Reference: Codable, Equatable, Sendable {
        var messageId: String
        var revision: Int
        enum CodingKeys: String, CodingKey { case messageId = "message_id", revision }
    }
    struct Message: Codable, Equatable, Sendable {
        var messageId: String
        var revision: Int
        var authorAccountId: String
        var authorAgentId: String?
        var text: String?
        var createdAt: String?
        enum CodingKeys: String, CodingKey {
            case messageId = "message_id", revision, authorAccountId = "author_account_id", authorAgentId = "author_agent_id"
            case text, createdAt = "created_at"
        }
        var reference: Reference { Reference(messageId: messageId, revision: revision) }
    }
    var requestId: String
    var text: String
    var context: [Message]?
    var declineReason: String?
    var failureReason: String?
    var attachments: [ChatAttachmentManifest]? = nil
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id", text, context, attachments, declineReason = "decline_reason", failureReason = "failure_reason"
    }

    func validates(_ request: ChatRequest, references: [Reference]?) -> Bool {
        guard requestId == request.requestId, text == request.text, let context,
              context.count <= ChatChannelAsk.maxContext,
              Set(context.map(\.messageId)).count == context.count,
              context.allSatisfy({ !$0.messageId.isEmpty && $0.revision > 0 && !$0.authorAccountId.isEmpty }),
              context.reduce(0, { $0 + ($1.text?.utf8.count ?? 0) }) <= ChatChannelAsk.maxContextBytes else { return false }
        let files = attachments ?? []
        guard request.conditionsVersion == 2 ? !files.isEmpty : files.isEmpty,
              files.count <= 4, Set(files.map(\.id)).count == files.count,
              files.reduce(0, { $0 + $1.file.size }) <= 20 * 1024 * 1024,
              files.enumerated().allSatisfy({ index, item in
                  item.file.position == index && item.file.size > 0 && item.file.size <= 10 * 1024 * 1024
                    && item.sha256.count == 64 && item.sha256.allSatisfy { "0123456789abcdef".contains($0) }
                    && context.contains { $0.messageId == item.messageId && $0.revision == item.revision && $0.text != nil }
              }) else { return false }
        return references.map { $0 == context.map(\.reference) } ?? true
    }

    var launchContext: String {
        // Canonical JSON includes ids, revisions and authors in the approval's
        // hash; the runner wraps this in <team-request> as external text.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(context ?? [])) ?? Data("[]".utf8), as: UTF8.self)
    }

    static func read(_ db: Database, request: String) throws -> Self? {
        guard let json = try String.fetchOne(db, sql: """
            SELECT x.content FROM request_contents x JOIN requests r ON r.request_id = x.request_id
            JOIN channels c ON c.channel_id = x.channel_id JOIN teams t ON t.team_id = c.team_id JOIN meta m ON m.id = 1
            WHERE x.request_id = ? AND t.mine = 1 AND m.rights_in_doubt = 0
                AND x.session_id = m.rights_session AND x.generation = m.generation AND m.pending_generation IS NULL
                AND x.epoch = m.channel_access_epoch
            """, arguments: [request]) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }

    static func forgetMessage(_ db: Database, _ id: String) throws {
        try ChatAttachments.forgetMessage(db, id: id)
        try db.execute(sql: """
            DELETE FROM request_contents WHERE EXISTS (
                SELECT 1 FROM json_each(content, '$.context') WHERE json_extract(value, '$.message_id') = ?)
            """, arguments: [id])
        // Also rejects a response in flight, including a deletion of a
        // message not present in this Mac's current message window.
        try db.execute(sql: "UPDATE meta SET channel_access_epoch = channel_access_epoch + 1 WHERE id = 1")
    }
}

enum ChatPublication {
    // requests.rs MAX_RESULT_BODY counts the entire encoded command, not text.
    static let maxBodyBytes = 128 * 1024

    static func text(_ original: String, org: String, request: String, run: String) throws -> String {
        func fits(_ text: String) throws -> Bool {
            // prepareCommand always uses a 36-byte UUID. All remaining fields
            // and JSON escaping are the actual wire encoder's, without estimates.
            try ChatCommandEnvelope(commandId: "00000000-0000-0000-0000-000000000000", org: org, type: "result.publish",
                args: .object(["request_id": .string(request), "run_id": .string(run), "text": .string(text)]))
                .encoded().count <= maxBodyBytes
        }
        if try fits(original) { return original }
        let total = original.utf8.count
        // At most maxBodyBytes characters could fit, even for plain ASCII.
        var ends = [original.startIndex]
        var index = original.startIndex
        while index < original.endIndex && ends.count <= maxBodyBytes {
            index = original.index(after: index)
            ends.append(index)
        }
        func candidate(_ count: Int) -> String {
            let prefix = original[..<ends[count]]
            let omittedKiB = (total - prefix.utf8.count + 1023) / 1024
            return String(prefix) + "\n\n…(truncated, \(omittedKiB) KiB omitted)"
        }
        guard try fits(candidate(0)) else { throw ChatError.storage("The publication metadata exceeds the server's size limit.") }
        var low = 0, high = ends.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if try fits(candidate(mid)) { low = mid } else { high = mid - 1 }
        }
        return candidate(low)
    }

    static func isDecision(_ type: String) -> Bool { type == "result.publish" || type == "result.withhold" }

    static func current(_ db: Database, run: String) throws -> ChatCommandRecord? {
        try ChatCommandRecord.fetchOne(db, sql: """
            SELECT o.* FROM outbox o JOIN publication_intents i ON i.command_id = o.command_id WHERE i.run_id = ?
            """, arguments: [run])
    }

    static func isAutomatic(_ db: Database, command: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT automatic FROM publication_intents WHERE command_id = ?", arguments: [command]) ?? true
    }

    static func inFlight(_ db: Database, run: String) throws -> ChatCommandRecord? {
        try ChatCommandRecord.fetchOne(db, sql: """
            SELECT o.* FROM outbox o JOIN publication_intents i ON i.command_id = o.command_id
            WHERE i.run_id = ? AND o.state = 'pending' AND i.send_started_at IS NOT NULL
            """, arguments: [run])
    }

    static func commands(_ db: Database, run: String) throws -> [ChatCommandRecord] {
        try ChatCommandRecord.fetchAll(db, sql: "SELECT * FROM outbox WHERE type IN ('result.publish', 'result.withhold') ORDER BY seq, rowid")
            .filter { (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.bodyBytes))?.args["run_id"]?.string == run }
    }

    static func erase(_ db: Database, run: String) throws {
        for command in try commands(db, run: run) {
            try db.execute(sql: "DELETE FROM outbox WHERE command_id = ?", arguments: [command.commandId])
        }
        try db.execute(sql: "DELETE FROM publication_intents WHERE run_id = ?", arguments: [run])
    }
}

extension ChatAPI {
    func requestContent(_ org: String, request: String, token: String) async throws -> ChatChannelContent {
        try await call(ChatChannelContent.self, "GET", "/v1/orgs/\(org)/requests/\(request)/content", token: token)
    }
}

extension ChatService {
    static let channelCancellationStates: Set<TeamRequestState> = [.submitted, .awaitingDecision, .approved, .starting, .running]

    func cancelChannelRequest(_ key: ChatOrgKey, requestId: String) -> String? {
        guard let request = try? orgSessions[key]?.store?.calls.request(requestId), request.kind == "channel",
              request.initiatorAccountId == key.accountId, let channel = request.channelId,
              channelAgentAllowed(key, channel: channel) else { return "The channel request is not available." }
        return askToEnd(key, requestId, type: "request.cancel", states: Self.channelCancellationStates)
    }

    func channelAgentAllowed(_ key: ChatOrgKey, channel: String) -> Bool {
        guard ChatNotifications.allowed(self, key, channel: channel), let store = orgSessions[key]?.store else { return false }
        return (try? store.queue.read { try Bool.fetchOne($0, sql: "SELECT agents_served FROM meta WHERE id = 1") }) == true
    }

    /// Nothing received until the channel's full request and a checked snapshot
    /// are available. The capture survives neither revoke/rejoin nor reconnect.
    func loadChannelContent(_ key: ChatOrgKey, request: ChatRequest, refresh: Bool = false) async throws -> Bool {
        guard request.kind == "channel", request.hasFixed, !request.state.isFinal, request.onThisDevice,
              request.ownerAccountId == key.accountId, let channel = request.channelId,
              channelAgentAllowed(key, channel: channel), let connection, let token,
              let session = orgSessions[key], let store = session.store else { return false }
        if !refresh, try await store.queue.read({ try ChatChannelContent.read($0, request: request.requestId) }) != nil {
            return self.connection?.sessionId == connection.sessionId && channelAgentAllowed(key, channel: channel)
        }
        let authority = try await store.queue.write { db -> (String, Int, Int)? in
            if refresh {
                try db.execute(sql: "DELETE FROM request_contents WHERE request_id = ?", arguments: [request.requestId])
            }
            // A fresh read invalidates only an older read of this request.
            // Bumping the membership epoch here would erase another running
            // call's selected files every time a second call is reviewed.
            try db.execute(sql: "INSERT INTO content_read_versions (request_id, version) VALUES (?, 1) ON CONFLICT(request_id) DO UPDATE SET version = version + 1", arguments: [request.requestId])
            guard let row = try Row.fetchOne(db, sql: "SELECT generation, pending_generation, channel_access_epoch FROM meta WHERE id = 1"),
                  let generation: String = row["generation"], (row["pending_generation"] as String?) == nil else { return nil }
            return (generation, row["channel_access_epoch"], try Int.fetchOne(db, sql: "SELECT version FROM content_read_versions WHERE request_id = ?", arguments: [request.requestId]) ?? 0)
        }
        guard let authority else { return false }
        let content = try await readChannelContent(key, request: request.requestId, token: token, session: connection.sessionId, store: store)
        guard self.connection?.sessionId == connection.sessionId, self.connection?.orgKey == key,
              orgSessions[key] === session, channelAgentAllowed(key, channel: channel) else { return false }
        let kept = try await store.queue.write { db -> Bool in
            guard let now = try ChatCallStore.request(db, request.requestId), now.kind == "channel", now.hasFixed, now.onThisDevice,
                  !now.state.isFinal, now.channelId == channel, now.agentId == request.agentId,
                  now.initiatorAccountId == request.initiatorAccountId, now.threadRootId == request.threadRootId,
                  let meta = try Row.fetchOne(db, sql: "SELECT generation, pending_generation, channel_access_epoch FROM meta WHERE id = 1"),
                  (meta["generation"] as String?) == authority.0, (meta["pending_generation"] as String?) == nil,
                  (meta["channel_access_epoch"] as Int) == authority.1,
                  try Int.fetchOne(db, sql: "SELECT version FROM content_read_versions WHERE request_id = ?", arguments: [request.requestId]) == authority.2 else { return false }
            let refs = try String.fetchOne(db, sql: "SELECT context_refs FROM requests WHERE request_id = ?", arguments: [request.requestId])
                .map { try JSONDecoder().decode([ChatChannelContent.Reference].self, from: Data($0.utf8)) }
            if now.conditionsVersion == 2, content.requestId == now.requestId, content.text == now.text,
               content.attachments == [] { throw ChatAttachmentError.contextLost }
            guard content.validates(now, references: refs) else { return false }
            let json = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
            try db.execute(sql: """
                INSERT OR REPLACE INTO request_contents (request_id, channel_id, session_id, generation, epoch, content) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [request.requestId, channel, connection.sessionId, authority.0, authority.1, json])
            return true
        }
        guard self.connection?.sessionId == connection.sessionId, channelAgentAllowed(key, channel: channel) else { return false }
        if kept { publishRevision += 1 }
        return kept
    }

    func readChannelContent(_ key: ChatOrgKey, request: String, token: String, session: String, store: ChatStore) async throws -> ChatChannelContent {
        do { return try await makeAPI(key.server).requestContent(key.orgId, request: request, token: token) }
        catch {
            attachmentAccessFailed(error, key: key, store: store, session: session)
            throw error
        }
    }

    func channelDecisionReady(_ key: ChatOrgKey, request: ChatRequest, requiresContent: Bool = true) -> Bool {
        guard request.onThisDevice, request.ownerAccountId == key.accountId, request.state == .awaitingDecision,
              let channel = request.channelId, channelAgentAllowed(key, channel: channel),
              let store = orgSessions[key]?.store else { return false }
        if !requiresContent { return true }
        return (try? store.queue.read { try ChatChannelContent.read($0, request: request.requestId) != nil }) == true
    }

    /// This is the sole reader of channel drafts for display. Neither Team nor
    /// a disconnected journal can surface them. Re-login on this Mac is allowed.
    func channelPreview(_ key: ChatOrgKey, requestId: String) -> ChatRunRecord? {
        _ = publishRevision
        guard let store = orgSessions[key]?.store, let journal,
              let request = try? store.calls.request(requestId), request.kind == "channel", request.hasFixed,
              request.ownerAccountId == key.accountId, let channel = request.channelId,
              channelAgentAllowed(key, channel: channel), let runId = request.runId,
              let run = try? journal.run(runId), run.kind == "channel", run.channelId == channel,
              run.org == key.orgId, run.requestId == requestId, run.outcome != nil,
              let approval = try? journal.approval(run.approvalId), approval.key == key,
              let params = try? TeamLaunchParams.decode(approval.params), (run.resultErased || params.inputs.prompt == request.text),
              params.inputs.agentId == request.agentId, params.initiator == request.initiatorAccountId,
              params.threadRootId == request.threadRootId else { return nil }
        return run
    }

    /// Cached AG-5 checks; the server makes the final decision under current
    /// membership when it handles result.publish.
    func channelPublishProblem(_ key: ChatOrgKey, requestId: String) -> String? {
        guard let store = orgSessions[key]?.store, let request = try? store.calls.request(requestId),
              request.kind == "channel", request.ownerAccountId == key.accountId,
              let channel = request.channelId, channelAgentAllowed(key, channel: channel) else {
            return "The channel is not available."
        }
        if request.publication == "publish_failed" { return ChatChannelRequests.reason(request.publishReason) }
        guard request.state == .finished, request.publication == "awaiting_publish" else { return "This result is not awaiting publication." }
        let check: String?
        do { check = try store.queue.read { db -> String? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT c.team_id, c.archived, t.archived_at FROM channels c JOIN teams t ON t.team_id = c.team_id WHERE c.channel_id = ?
                """, arguments: [channel]) else { return "The channel is not available." }
            if row["archived"] as Bool || (row["archived_at"] as String?) != nil { return "The channel or team is archived." }
            let team: String = row["team_id"]
            for (account, problem) in [(key.accountId, "The owner left the team."), (request.initiatorAccountId ?? "", "The person who asked left the team.")] {
                guard try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM team_members tm JOIN members m ON m.account_id = tm.account_id WHERE tm.team_id = ? AND tm.account_id = ?)
                    """, arguments: [team, account]) == true else { return problem }
            }
            guard try Bool.fetchOne(db, sql: "SELECT enabled FROM agent_channels WHERE channel_id = ? AND agent_id = ?",
                                    arguments: [channel, request.agentId]) == true else { return "The agent is no longer enabled in this channel." }
            return nil
        } } catch { return "The channel could not be checked." }
        if let check { return check }
        guard let run = channelPreview(key, requestId: requestId), !run.resultErased, run.resultText != nil else {
            return "The result is no longer kept on this Mac."
        }
        return nil
    }

    func channelPublicationInFlight(_ key: ChatOrgKey, requestId: String) -> String? {
        guard let run = channelPreview(key, requestId: requestId), let store = orgSessions[key]?.store,
              let command = try? store.queue.read({ try ChatPublication.inFlight($0, run: run.runId) }) else { return nil }
        return command.type == "result.publish" ? "Publishing…" : "Withholding…"
    }

    /// The owner preview and Publish use this same deterministic wire text.
    /// Omitted KiB is the removed UTF-8 byte count rounded up.
    func channelPublicationText(_ key: ChatOrgKey, requestId: String) throws -> String? {
        guard let run = channelPreview(key, requestId: requestId), !run.resultErased, let text = run.resultText else { return nil }
        // An idempotent retry sends the stored bytes. Keep its preview exact
        // even if an older client queued a different version of the draft.
        if let store = orgSessions[key]?.store {
            let current = try store.queue.read { db -> ChatCommandRecord? in
                if let sending = try ChatPublication.inFlight(db, run: run.runId) { return sending }
                let generation = try String.fetchOne(db, sql: "SELECT generation FROM meta WHERE id = 1")
                guard let kept = try ChatPublication.current(db, run: run.runId), kept.sessionId == connection?.sessionId,
                      kept.state == .pending || (kept.state == .sent && kept.sentGeneration == generation),
                      kept.bodyBytes.count <= ChatPublication.maxBodyBytes else { return nil }
                return kept
            }
            if let current, current.type == "result.publish" { return Self.args(current)["text"]?.string }
        }
        return try ChatPublication.text(text, org: key.orgId, request: requestId, run: run.runId)
    }

    func channelPublicationIssue(_ key: ChatOrgKey, requestId: String) -> String? {
        if let sending = channelPublicationInFlight(key, requestId: requestId) { return sending }
        guard let run = channelPreview(key, requestId: requestId), let store = orgSessions[key]?.store,
              let last = try? store.queue.read({ try ChatPublication.current($0, run: run.runId) }) else { return nil }
        if last.state == .sent, last.sentGeneration != (try? store.generation) {
            return "The earlier publication was not confirmed. Choose Publish or Don't Publish again."
        }
        switch last.state {
        case .pending, .sent: return "Your publication decision is on its way."
        case .failed: return "Not published: \(ChatChannelRequests.reason(last.error)). Try again or choose Don't Publish."
        case .dropped, .unconfirmed: return "The earlier publication was not confirmed. Choose Publish or Don't Publish again."
        }
    }

    /// Owner decisions and the automatic publisher share C2's exact bytes.
    /// A lost answer repeats the command; a new session needs a fresh decision.
    @discardableResult
    func publishChannelResult(_ key: ChatOrgKey, requestId: String, publish: Bool, automatic: Bool = false) throws -> ChatCommandRecord {
        guard let run = channelPreview(key, requestId: requestId), let store = orgSessions[key]?.store,
              let request = try store.calls.request(requestId), request.state == .finished, request.publication == "awaiting_publish" else {
            throw ChatError.storage("This result is not awaiting publication here.")
        }
        if publish, let problem = channelPublishProblem(key, requestId: requestId) { throw ChatError.storage(problem) }
        var args: [String: ChatJSON] = ["request_id": .string(requestId), "run_id": .string(run.runId)]
        if publish { args["text"] = .string(try channelPublicationText(key, requestId: requestId) ?? "") }
        let prepared = try prepareCommand(key, type: publish ? "result.publish" : "result.withhold", args: .object(args))
        let made = try store.queue.write { db in
            func confirmed(_ command: ChatCommandRecord) throws -> ChatCommandRecord {
                if !automatic {
                    try db.execute(sql: "UPDATE publication_intents SET automatic = 0 WHERE command_id = ?", arguments: [command.commandId])
                }
                return command
            }
            let generation = try String.fetchOne(db, sql: "SELECT generation FROM meta WHERE id = 1")
            let previous = try ChatPublication.commands(db, run: run.runId)
            if let sending = try ChatPublication.inFlight(db, run: run.runId) {
                if sending.type == prepared.record.type { return try confirmed(sending) }
                throw ChatError.storage("The earlier publication decision is still in flight. Wait for its answer.")
            }
            guard prepared.record.bodyBytes.count <= ChatPublication.maxBodyBytes else { throw ChatError.storage("The publication exceeds the server's size limit.") }
            if let current = try ChatPublication.current(db, run: run.runId), current.sessionId == prepared.record.sessionId,
               current.state == .pending || (current.state == .sent && current.sentGeneration == generation) {
                if current.type == prepared.record.type, current.bodyBytes.count <= ChatPublication.maxBodyBytes { return try confirmed(current) }
                if current.state == .sent { throw ChatError.storage("The server already accepted the earlier publication decision.") }
            }
            // Intent and queue change together. Deletion also removes old
            // result text and prevents any generic retry from reviving it.
            for command in previous where command.state != .sent {
                try db.execute(sql: "DELETE FROM outbox WHERE command_id = ?", arguments: [command.commandId])
            }
            var record = prepared.record
            record.orderKey = "publish:\(run.runId)"
            let made = try prepared.table.insert(db, record, seq: record.seq)
            try db.execute(sql: "INSERT OR REPLACE INTO publication_intents (run_id, command_id, automatic) VALUES (?, ?, ?)", arguments: [run.runId, made.commandId, automatic])
            return made
        }
        prepared.sent()
        publishRevision += 1
        return made
    }

    func channelPublicationAnswered(_ key: ChatOrgKey, record: ChatCommandRecord, outcome: ChatCommandOutcome) {
        guard case .taken(let answer?) = outcome, let store = orgSessions[key]?.store,
              let id = Self.args(record)["request_id"]?.string, answer.result["request_id"]?.string == id,
              let version = answer.result["version"]?.int, let publication = answer.result["publication"]?.string else { return }
        try? store.queue.write { db in
            try db.execute(sql: """
                UPDATE requests SET publication = ?, publish_reason = ?, version = ? WHERE request_id = ? AND kind = 'channel' AND version <= ?
                """, arguments: [publication, answer.result["publish_reason"]?.string, version, id, version])
        }
        publishRevision += 1
    }

    /// No erasure during Disconnect or an incomplete snapshot: only confirmed
    /// current rights can decide that a channel is gone. Erasure never waits
    /// for the server's fact chain; end() repeats it if a result arrives later.
    func reconcileChannelResults(revoked: ChatOrgKey? = nil) {
        pruneChannelActivity()
        reconcileAttachmentCalls()
        for manager in attachmentManagers.values { manager.scrubConsents() }
        defer { reconcileAutomaticChannels() }
        guard let journal else { return }
        // A transcript belongs to the thread, not to an individual result.
        // Retry confirmed revocations even offline, but preserve any UUID
        // still referenced by a run whose channel has not been revoked.
        // Absence from the request cache is never evidence of revocation.
        defer {
            if let ids = try? journal.queue.read({ db in
                try String.fetchAll(db, sql: """
                    SELECT DISTINCT r.conversation_id FROM runs r
                    WHERE r.kind = 'channel' AND r.channel_revoked = 1
                        AND NOT EXISTS (SELECT 1 FROM runs kept WHERE kept.conversation_id = r.conversation_id
                                        AND kept.channel_revoked = 0)
                    """)
            }) {
                for id in ids { AgentSessionScanner.eraseClaudeTranscript(conversationId: id, root: claudeProjectsRoot) }
            }
        }
        // Connect replaces connection before leaving notMember. A removal
        // must keep its own identity throughout that transition, never borrow
        // the server/account/organization of the newly selected connection.
        let revokedKey: ChatOrgKey?
        if let revoked { revokedKey = revoked }
        else if case .notMember(let key, _) = state { revokedKey = key }
        else { revokedKey = nil }
        guard let key = revokedKey ?? connection?.orgKey else { return }
        let removed = revokedKey == key
        guard removed || ChatNotifications.allowed(self, key, channel: nil) else { return }
        let store = orgSessions[key]?.store
        do {
            if store == nil {
                let cache = files.cacheURL(key).path
                let cacheRemains = ["", "-wal", "-shm"].contains { FileManager.default.fileExists(atPath: cache + $0) }
                guard !cacheRemains else { throw ChatError.storage("The revoked cache is still on disk; result erasure must wait.") }
            }
            // A confirmed removal is not Disconnect: every channel of this
            // organization was revoked.
            let channels: Set<String>
            let cancelled: Set<String>
            if removed { channels = []; cancelled = [] }
            else {
                guard let store else { return }
                (channels, cancelled) = try store.queue.read { db in
                    (Set(try String.fetchAll(db, sql: "SELECT c.channel_id FROM channels c JOIN teams t ON t.team_id = c.team_id WHERE t.mine = 1")),
                     Set(try String.fetchAll(db, sql: "SELECT request_id FROM requests WHERE kind = 'channel' AND state IN ('declined', 'cancelled', 'stop_requested', 'stopped', 'stop_failed')")))
                }
            }
            let rows = try journal.queue.read { db in
                try ChatRunRecord.fetchAll(db, sql: """
                    SELECT r.* FROM runs r JOIN approvals a ON a.id = r.approval_id
                    WHERE r.kind = 'channel'
                        AND a.server = ? AND a.account_id = ? AND a.org_id = ?
                    """, arguments: [key.server.description, key.accountId, key.orgId])
                    .filter { !channels.contains($0.channelId ?? "") || cancelled.contains($0.requestId) }
            }
            // Cache first: never set result_erased while a publish body still
            // survives. Repeating this after a crash also repairs old erasures.
            try store?.queue.write { db in
                for row in rows { try ChatPublication.erase(db, run: row.runId) }
                if removed { try db.execute(sql: "DELETE FROM request_contents") }
                else { try db.execute(sql: "DELETE FROM request_contents WHERE channel_id NOT IN (SELECT channel_id FROM channels)") }
            }
            let erased = try journal.queue.write { db -> Int in
                var count = 0
                for row in rows {
                    let channelRevoked = row.channelRevoked || !channels.contains(row.channelId ?? "")
                    // Check the evidence's full key against the run's owner
                    // in the erasure transaction, not only in the earlier read.
                    try db.execute(sql: """
                        UPDATE runs SET result_text = NULL, result_erased = 1, channel_revoked = ?
                        WHERE run_id = ? AND kind = 'channel'
                            AND EXISTS (SELECT 1 FROM approvals a WHERE a.id = runs.approval_id
                                        AND a.server = ? AND a.account_id = ? AND a.org_id = ?)
                            AND (result_erased = 0 OR result_text IS NOT NULL OR channel_revoked != ?)
                        """, arguments: [channelRevoked, row.runId, key.server.description, key.accountId, key.orgId, channelRevoked])
                    count += db.changesCount
                }
                return count
            }
            if erased > 0 { publishRevision += 1 }
        } catch { NSLog("agentpad: channel results could not be reconciled: \(error.localizedDescription)") }
    }
}
