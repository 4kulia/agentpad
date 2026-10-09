import Foundation
import GRDB

@MainActor
enum ChatAttention {
    nonisolated static func latestLocalRequestIDs(_ db: Database, account: String) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: """
            SELECT request_id FROM (
                SELECT request_id, ROW_NUMBER() OVER (
                    PARTITION BY COALESCE(agent_id, request_id) ORDER BY julianday(created_at) DESC, request_id DESC
                ) AS rank FROM requests WHERE owner_account_id = ? AND on_this_device = 1
            ) WHERE rank = 1
            """, arguments: [account]))
    }

    static func scope(_ key: ChatOrgKey, _ service: ChatService) -> AttentionScope {
        AttentionScope(server: key.server.description, account: key.accountId, organization: key.orgId,
                       generation: (try? service.orgSessions[key]?.store?.generation) ?? "")
    }
    static func key(_ scope: AttentionScope) -> ChatOrgKey? {
        guard let server = try? ChatServerAddress(parsing: scope.server) else { return nil }
        return ChatOrgKey(server: server, accountId: scope.account, orgId: scope.organization)
    }
    static func sameScope(_ scope: AttentionScope, _ service: ChatService) -> Bool {
        guard let key = key(scope), service.connection?.orgKey == key else { return false }
        return self.scope(key, service) == scope
    }
    static func personalAllowed(_ key: ChatOrgKey, _ service: ChatService) -> Bool {
        guard service.state == .signedIn, let connection = service.connection, connection.orgKey == key,
              let session = service.orgSessions[key], !session.doubtNotWritten, !session.snapshotOwed,
              let store = session.store else { return false }
        return (try? store.queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT rights_in_doubt = 0 AND rights_session = ? AND pending_generation IS NULL FROM meta WHERE id = 1",
                              arguments: [connection.sessionId]) == true
        }) ?? false
    }
    static func decisionDue(_ request: ChatRequest, key: ChatOrgKey, service: ChatService) -> Bool {
        guard personalAllowed(key, service), request.hasFixed, request.ownerAccountId == key.accountId,
              request.onThisDevice, request.state == .awaitingDecision,
              request.deliverBy.flatMap(ChatStore.date).map({ $0 > Date() }) != false else { return false }
        if request.kind == "channel" {
            guard service.channelDecisionReady(key, request: request), let channel = request.channelId else { return false }
            return !ChatChannelOwnerModel(service: service, key: key, channel: channel).isAutomatic(request)
        }
        return true
    }
    static func decision(_ request: ChatRequest, key: ChatOrgKey, service: ChatService) -> AttentionEvent {
        var event = AttentionEvent(source: "request", object: request.requestId, kind: .decision,
            destination: request.channelId.map { .channel($0, request: request.requestId) }
                ?? .team(request: request.requestId, outgoing: false), scope: scope(key, service),
            timestamp: request.updatedAt.flatMap(ChatStore.date) ?? request.createdAt.flatMap(ChatStore.date) ?? .distantPast)
        let commands: [ChatCommandRecord] = (try? service.journal?.commands(for: key)) ?? []
        event.actionInFlight = commands.contains { command in
            guard command.type == "request.decide", command.state == .pending,
                  let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: command.bodyBytes) else { return false }
            return envelope.args["request_id"]?.string == request.requestId
        }
        return event
    }
    static func message(key: ChatOrgKey, service: ChatService, channel: String, id: String,
                        thread: String?, sequence: Int, kind: AttentionKind, timestamp: Date? = nil) -> AttentionEvent {
        let created = timestamp ?? (try? service.orgSessions[key]?.store?.queue.read {
            try String.fetchOne($0, sql: "SELECT created_at FROM messages WHERE message_id = ?", arguments: [id])
        }).flatMap(ChatStore.date) ?? .distantPast
        return AttentionEvent(source: "message", object: id, kind: kind,
                       destination: .message(channel: channel, message: id, thread: thread, sequence: sequence),
                       scope: scope(key, service), timestamp: created)
    }

    static func launchHelp(_ diagnosis: ClaudeLaunchDiagnostic.Failure?) -> AttentionKind? {
        switch diagnosis {
        case .authentication: return .signIn
        case .permission, .version, .spawn, .unavailable: return .recovery
        default: return nil
        }
    }

    static func localLaunchFailure(_ key: ChatOrgKey, request id: String, service: ChatService) -> ClaudeLaunchDiagnostic.Failure? {
        guard personalAllowed(key, service), let request = try? service.orgSessions[key]?.store?.calls.request(id),
              request.ownerAccountId == key.accountId, request.onThisDevice,
              let approval = try? service.journal?.approval(key, requestId: id),
              let run = try? service.journal?.run(approval.runId), run.outcome != nil else { return nil }
        if let channel = request.channelId, !service.channelAgentAllowed(key, channel: channel) { return nil }
        return run.launchFailure
    }

    static func valid(_ event: AttentionEvent, service: ChatService) -> Bool {
        guard let scope = event.scope else { return true }
        guard sameScope(scope, service), let key = key(scope) else { return false }
        if event.kind == .signIn, case .needsSignIn = service.state { return true }
        if event.kind == .account {
            if case .notMember = service.state { return true }
            return service.state == .signedIn
        }
        guard personalAllowed(key, service), let store = service.orgSessions[key]?.store else { return false }
        switch event.destination {
        case .directMessage: return ChatDMNotices.valid(event, service: service)
        case .channel(let channel, let id):
            guard service.channelAgentAllowed(key, channel: channel), let row = try? store.calls.request(id) else { return false }
            if event.kind == .decision { return decisionDue(row, key: key, service: service) }
            if event.kind == .publicationReview {
                return row.ownerAccountId == key.accountId && row.onThisDevice && row.publication == "awaiting_publish"
                    && service.channelPreview(key, requestId: id) != nil
            }
            return true
        case .folder(let id, let request):
            return TeamService.shared.calls.accessRequests.contains {
                $0.id == id && $0.callId == request && [.pending, .deciding].contains($0.state) && $0.scope?.key == key
            }
        case .team(let id?, _):
            guard let row = try? store.calls.request(id) else { return false }
            if event.kind == .decision { return decisionDue(row, key: key, service: service) }
            if event.source == "run-outcome", !row.state.isFinal {
                guard row.ownerAccountId == key.accountId, row.onThisDevice,
                      let approval = try? service.journal?.approval(key, requestId: row.requestId),
                      let run = try? service.journal?.run(approval.runId), run.outcome != nil else { return false }
            }
            return row.kind != "channel"
        case .message(let channel, let id, _, _):
            guard ChatNotifications.visible(service, key, channel) else { return false }
            if event.kind == .mention || event.kind == .reply {
                return ChatNotifications.stillDue(ChatNotifications.messageId(key, channel: channel, message: id), service)
            }
            return (try? store.queue.read { db in
                try Bool.fetchOne(db, sql: "SELECT deleted_at IS NULL FROM messages WHERE message_id = ?", arguments: [id]) == true
            }) ?? false
        default: return true
        }
    }

    /// Snapshot projection runs without a SwiftUI window. New outcomes are live
    /// only after the first snapshot; durable metadata handles subsequent restarts.
    static func events(service: ChatService, calls: TeamCalls) -> [AttentionEvent] {
        guard let key = service.connection?.orgKey, personalAllowed(key, service),
              let store = service.orgSessions[key]?.store else { return [] }
        let scope = scope(key, service)
        let finals = TeamRequestState.finals.map(\.rawValue).sorted()
        let placeholders = finals.map { _ in "?" }.joined(separator: ",")
        let requests = (try? store.queue.read { db in
            try String.fetchAll(db, sql: """
                WITH relevant AS (
                    SELECT request_id, updated_at,
                           (state NOT IN (\(placeholders)) OR COALESCE(publication, '') = 'awaiting_publish') AS active
                    FROM requests WHERE owner_account_id = ? OR initiator_account_id = ?
                ), history AS (
                    SELECT request_id FROM relevant WHERE NOT active
                    ORDER BY updated_at DESC, request_id LIMIT 500
                )
                SELECT request_id FROM relevant WHERE active OR request_id IN (SELECT request_id FROM history)
                ORDER BY updated_at DESC, request_id
                """, arguments: StatementArguments(finals + [key.accountId, key.accountId]))
                .compactMap { try ChatCallStore.request(db, $0) }
        }) ?? []
        var result: [AttentionEvent] = []
        // Status updates on an old request cannot make it the latest run.
        let latestRequests = (try? store.queue.read { try Self.latestLocalRequestIDs($0, account: key.accountId) }) ?? []
        for original in requests {
            var request = original
            var timestamp = request.updatedAt.flatMap(ChatStore.date) ?? request.createdAt.flatMap(ChatStore.date) ?? .distantPast
            let localOwner = request.ownerAccountId == key.accountId && request.onThisDevice
            let latestForAgent = localOwner && latestRequests.contains(request.requestId)
            let approval = localOwner ? try? service.journal?.approval(key, requestId: request.requestId) : nil
            let localRun = approval.flatMap { try? service.journal?.run($0.runId) }
            if !request.state.isFinal, let run = localRun, let outcome = run.outcome,
               request.channelId == nil || outcome != .finished {
                request.runId = run.runId
                timestamp = run.endedAt ?? timestamp
                switch outcome {
                case .finished: request.state = .finished
                case .failed: request.state = .failed
                case .didNotStart: request.state = .failedToStart
                case .stoppedLocally: request.state = .stopped
                case .executorRestarted: request.state = .lost
                }
            }
            if decisionDue(request, key: key, service: service) { result.append(decision(request, key: key, service: service)) }
            guard (request.ownerAccountId == key.accountId && request.onThisDevice) || (request.initiatorAccountId == key.accountId && request.askedHere) else { continue }
            let destination: AttentionDestination
            if let channel = request.channelId {
                guard service.channelAgentAllowed(key, channel: channel) else { continue }
                destination = .channel(channel, request: request.requestId)
                if request.publication == "awaiting_publish", request.ownerAccountId == key.accountId, request.onThisDevice,
                   service.channelPreview(key, requestId: request.requestId) != nil {
                    let model = ChatChannelOwnerModel(service: service, key: key, channel: channel)
                    if !model.isAutomatic(request) {
                        var event = AttentionEvent(source: "publication-review", object: request.requestId,
                            episode: (request.runId ?? "") + ":" + (service.connection?.sessionId ?? ""), kind: .publicationReview,
                            destination: destination, scope: scope, timestamp: timestamp)
                        event.actionInFlight = service.channelPublicationInFlight(key, requestId: request.requestId) != nil
                        result.append(event)
                    }
                    // Await confirmation of automatic publication too.
                    continue
                }
                if request.publication == "published", let run = request.runId,
                   let row = try? store.queue.read({ try Row.fetchOne($0, sql: "SELECT message_id, seq, thread_root_id FROM messages WHERE channel_id = ? AND run_id = ? AND deleted_at IS NULL AND seq IS NOT NULL LIMIT 1", arguments: [channel, run]) }) {
                    let id: String = row["message_id"]
                    // F4's marker gives mention/reply priority, regardless of callback order.
                    let owed = try? store.queue.read { try String.fetchOne($0, sql: "SELECT kind FROM notified WHERE object_id = ?", arguments: [id]) }
                    result.append(message(key: key, service: service, channel: channel, id: id,
                        thread: row["thread_root_id"], sequence: row["seq"], kind: owed == "mention" ? .mention : owed == "reply" ? .reply : .publication))
                    continue
                }
            } else { destination = .team(request: request.requestId, outgoing: request.initiatorAccountId == key.accountId) }
            guard request.state.isFinal else { continue }
            // An initiator's successful personal result must actually have arrived.
            if request.state == .finished, request.channelId == nil, request.initiatorAccountId == key.accountId, !request.answered { continue }
            if request.channelId != nil, request.state == .finished, request.publication != "publish_failed" { continue }
            if localOwner, request.state == .stopFailed,
               service.recovery?.blocked.contains(where: { $0.run.requestId == request.requestId }) == true
                || TeamProcesses.shared.leftOvers().contains(where: { $0.agentId == request.agentId }) {
                continue // The actionable process/recovery wait represents this same failure.
            }
            if localOwner, [.failedToStart, .failed].contains(request.state),
               let help = launchHelp(localRun?.launchFailure) {
                if latestForAgent {
                    result.append(AttentionEvent(source: "launch-help", object: request.requestId, episode: request.runId ?? "",
                                                 kind: help, destination: destination, scope: scope, timestamp: timestamp))
                }
                continue
            }
            let kind: AttentionKind = request.state == .finished && request.publication != "publish_failed" ? .completion
                : [.stopped, .cancelled, .declined, .expired].contains(request.state) ? .stopped : .failure
            result.append(AttentionEvent(source: "run-outcome", object: request.requestId, episode: request.runId ?? "",
                                         kind: kind, destination: destination, scope: scope, timestamp: timestamp))
        }
        // Session posts (Forward / chat_post) remain observed after their UI closes.
        let posts = (try? store.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.message_id, m.channel_id, m.thread_root_id, m.seq, m.deleted_at, m.created_at, o.command_id, o.state,
                       o.created_at AS command_created_at
                FROM session_posts p JOIN messages m ON m.message_id = p.message_id
                JOIN outbox o ON o.command_id = p.command_id
                WHERE m.deleted_at IS NULL AND (m.seq IS NOT NULL OR o.state IN ('failed', 'dropped', 'unconfirmed'))
                """)
        }) ?? []
        for row in posts {
            let channel: String = row["channel_id"], id: String = row["message_id"]
            guard ChatNotifications.visible(service, key, channel) else { continue }
            if let seq: Int = row["seq"] {
                let created: String? = row["created_at"]
                result.append(message(key: key, service: service, channel: channel, id: id, thread: row["thread_root_id"],
                                      sequence: seq, kind: .publication, timestamp: created.flatMap(ChatStore.date) ?? .distantPast))
            } else {
                result.append(AttentionEvent(source: "post-outcome", object: row["command_id"], kind: .failure,
                    destination: .message(channel: channel, message: id, thread: row["thread_root_id"], sequence: 0),
                    scope: scope, timestamp: row["command_created_at"]))
            }
        }
        result += ChatDMNotices.events(service, key)
        return result
    }
}
