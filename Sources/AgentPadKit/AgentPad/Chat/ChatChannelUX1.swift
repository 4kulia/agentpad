import Foundation
import GRDB

struct ChatChannelTrust: Codable, Equatable, Sendable {
    var enabled: Bool
    var policyId: String?
    var executorSessionId: String?
    var executorDeviceName: String?
    var access: String?
    enum CodingKeys: String, CodingKey {
        case enabled, access
        case policyId = "policy_id", executorSessionId = "executor_session_id", executorDeviceName = "executor_device_name"
    }
}

/// Executable settings only. Presentation edits cannot widen a permission.
struct ChatExecutionSettings: Codable, Equatable, Sendable {
    var inputs: TeamLaunchInputs
    init(_ agent: TeamPublishedAgent) {
        inputs = TeamLaunchInputs(agent: agent, request: TeamLaunchRequest(requestId: "", prompt: "", callerName: "",
            callerProject: nil, conversationId: nil, expiresAt: Date(timeIntervalSince1970: 0)))
    }
}

/// An application-authored promise, never constructed from an event. The
/// journal is written before the cache; the cache send is a second witness.
struct ChatChannelAuthority: Codable, Equatable, Sendable {
    var id: String
    var server: String
    var account: String
    var org: String
    var session: String
    var generation: String
    var channel: String
    var agent: String
    var basis: String
    var settings: ChatExecutionSettings
    var request: String?
    var source: String?
    var text: String?
    var context: [ChatChannelContent.Message]?
    var root: String?
    var replyMode: String?
    var deliverBy: String?
    var sourceRevision: Int? = nil
    var attachments: [ChatAttachmentManifest]? = nil

    func matchesScope(_ key: ChatOrgKey, session: String, generation: String, agent: TeamPublishedAgent) -> Bool {
        server == key.server.description && account == key.accountId && org == key.orgId
            && self.session == session && self.generation == generation
            && self.agent == agent.id.uuidString.lowercased() && settings == ChatExecutionSettings(agent)
    }

    func matches(_ request: ChatRequest, content: ChatChannelContent) -> Bool {
        guard request.sourceMessageId != nil, request.replyMode == "channel" || request.replyMode == "thread",
              request.channelId == channel, request.agentId == agent else { return false }
        if basis == "channel_trust" { return request.requestedPolicyId == id && !settings.inputs.access.contains("git") && ["read", "edit-files"].contains(settings.inputs.access) }
        guard (attachments ?? []) == (content.attachments ?? []), basis == "self_call", self.request == request.requestId, source == request.sourceMessageId,
              request.initiatorAccountId == account, request.ownerAccountId == account,
              text == content.text, request.text == text, request.threadRootId == root,
              request.replyMode == replyMode, request.sourceRevision == (sourceRevision ?? 1),
              request.deliverBy.flatMap(ChatStore.date) == deliverBy.flatMap(ChatStore.date),
              let expected = context, let actual = content.context, expected.count == actual.count else { return false }
        // created_at is assigned by the server; execution text and attribution are fixed here.
        return zip(expected, actual).allSatisfy { a, b in
            a.messageId == b.messageId && a.revision == b.revision && a.authorAccountId == b.authorAccountId
                && a.authorAgentId == b.authorAgentId && a.text == b.text
        }
    }
}

extension ChatJournal {
    func channelAuthority(_ id: String) throws -> ChatChannelAuthority? {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM channel_authorities WHERE id = ? AND revoked = 0", arguments: [id])
                .map { try JSONDecoder().decode(ChatChannelAuthority.self, from: Data($0.utf8)) }
        }
    }

    func storeAuthority(_ a: ChatChannelAuthority) throws {
        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO channel_authorities (id, server, account_id, org_id, channel_id, agent_id, kind, body)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [a.id, a.server, a.account, a.org, a.channel, a.agent, a.basis, json])
        }
    }

    func revokeAuthority(_ id: String) throws {
        try queue.write { try $0.execute(sql: "UPDATE channel_authorities SET revoked = 1 WHERE id = ?", arguments: [id]) }
    }

    func blockAutomaticRequest(_ key: ChatOrgKey, request: String) throws {
        try queue.write { try $0.execute(sql: "INSERT OR IGNORE INTO automatic_request_blocks (server, account_id, org_id, request_id) VALUES (?, ?, ?, ?)",
                                       arguments: [key.server.description, key.accountId, key.orgId, request]) }
    }

    func automaticRequestBlocked(_ key: ChatOrgKey, request: String) throws -> Bool {
        try queue.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM automatic_request_blocks WHERE server = ? AND account_id = ? AND org_id = ? AND request_id = ?)",
                                         arguments: [key.server.description, key.accountId, key.orgId, request]) == true }
    }
}

extension ChatService {
    /// Settings cannot commit before revocation and its server command are durable.
    /// The journal covers disconnected organizations and survives cache deletion.
    func revokeAgentAuthorities(_ ids: [UUID]) throws {
        let journal = try journal ?? ChatJournal.open(files: files)
        let ids = Set(ids.map { $0.uuidString.lowercased() })
        let cacheSeq = try ChatCommandTable.maxSeq(orgSessions.values.compactMap { $0.store?.outbox })
        try journal.queue.write { db in
            var seq = max(cacheSeq, try Int64.fetchOne(db, sql: "SELECT max(seq) FROM run_commands") ?? 0)
            let authorities = try String.fetchAll(db, sql: "SELECT body FROM channel_authorities WHERE revoked = 0")
                .map { try JSONDecoder().decode(ChatChannelAuthority.self, from: Data($0.utf8)) }
            for a in authorities where ids.contains(a.agent) {
                try db.execute(sql: "UPDATE channel_authorities SET revoked = 1 WHERE id = ?", arguments: [a.id])
                guard a.basis == "channel_trust" else { continue }
                let key = ChatOrgKey(server: try ChatServerAddress(parsing: a.server), accountId: a.account, orgId: a.org)
                let id = ChatUUID.v7()
                let bytes = try ChatCommandEnvelope(commandId: id, org: a.org, type: "agent.channel_trust.set", args: .object([
                    "agent_id": .string(a.agent), "channel_id": .string(a.channel), "enabled": .bool(false),
                    "expected_policy_id": .string(a.id)])).encoded()
                seq += 1
                _ = try journal.runCommands(key).insert(db, ChatCommandRecord(commandId: id, sessionId: a.session,
                    type: "agent.channel_trust.set", bodyBytes: bytes, orderKey: a.org, dependsOn: nil,
                    createdAt: Date(), state: .pending), seq: seq)
            }
        }
        reconcileAutomaticChannels()
        for session in orgSessions.values { session.outbox?.pump() }
    }

    func localChannelExecutor(_ key: ChatOrgKey, channel: String, agent: ChatChannelAgent) -> TeamPublishedAgent? {
        guard let connection, connection.orgKey == key, agent.ownerAccountId == key.accountId,
              agent.enabled, agent.executorSessionId == connection.sessionId,
              channelAgentAllowed(key, channel: channel), let local = localAgent(agent.agentId), local.enabled,
              let assignment = try? journal?.assignment(key, agentId: agent.agentId), assignment.state == .active,
              assignment.publishedSession == connection.sessionId, assignment.requested == nil,
              let generation = try? journal?.generation(key), generation.pending == nil, generation.generation != nil,
              local.access.rawValue == agent.access,
              let store = orgSessions[key]?.store,
              (try? store.queue.read { try Bool.fetchOne($0, sql: "SELECT archived FROM channels WHERE channel_id = ?", arguments: [channel]) }) == false else { return nil }
        return local
    }

    func automaticAuthority(_ key: ChatOrgKey, request: ChatRequest, content: ChatChannelContent) -> ChatChannelAuthority? {
        guard request.onThisDevice, request.ownerAccountId == key.accountId,
              ![.cancelled, .declined, .stopRequested, .stopped, .stopFailed].contains(request.state),
              let channel = request.channelId, channelAgentAllowed(key, channel: channel),
              let store = orgSessions[key]?.store, let journal, let connection, connection.orgKey == key,
              let generation = try? journal.generation(key), generation.pending == nil, let current = generation.generation,
              let agentId = request.agentId, let card = try? store.channelAgents(channel).first(where: { $0.agentId == agentId }),
              let local = localChannelExecutor(key, channel: channel, agent: card),
              (try? journal.automaticRequestBlocked(key, request: request.requestId)) == false else { return nil }
        for id in [request.requestId, request.requestedPolicyId].compactMap({ $0 }) {
            guard let a = try? journal.channelAuthority(id), a.matchesScope(key, session: connection.sessionId, generation: current, agent: local),
                  a.matches(request, content: content) else { continue }
            if a.basis == "self_call" {
                let committed = (try? store.queue.read { db in
                    try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM channel_call_intents i JOIN channel_sends s ON s.message_id = i.message_id
                            JOIN outbox o ON o.command_id = s.command_id
                            WHERE i.request_id = ? AND i.message_id = ? AND i.agent_id = ? AND i.cancelled = 0
                                AND o.state = 'sent' AND o.session_id = ?)
                        """, arguments: [a.request, a.source, a.agent, a.session])
                }) == true
                if !committed { continue }
            } else {
                guard card.trust?.enabled == true, card.trust?.policyId == a.id,
                      card.trust?.executorSessionId == a.session, !local.access.runsShell else { continue }
            }
            return a
        }
        return nil
    }

    /// The same local executor gate as Send. For a remote executor only the
    /// public, confirmed policy can make the promise visible to the caller.
    func channelCallIsAutomatic(_ key: ChatOrgKey, channel: String, agent: ChatChannelAgent) -> Bool {
        if localChannelExecutor(key, channel: channel, agent: agent) != nil { return true }
        if agent.ownerAccountId == key.accountId && agent.executorSessionId == connection?.sessionId { return false }
        return agent.enabled && agent.trust?.enabled == true && agent.trust?.policyId != nil
            && agent.trust?.executorSessionId == agent.executorSessionId
            && TeamAccessProfile(rawValue: agent.access)?.runsShell == false
    }

    /// This check also runs before D9 spends an automatic approval and after
    /// executor preflight. Frozen context is the originally approved snapshot.
    func automaticApprovalValid(_ key: ChatOrgKey, request: ChatRequest, params: TeamLaunchParams) -> Bool {
        guard params.consentBasis != "manual", params.consentBasis != nil else { return true }
        guard let json = params.inputs.context,
              let messages = try? JSONDecoder().decode([ChatChannelContent.Message].self, from: Data(json.utf8)),
              let authority = automaticAuthority(key, request: request,
                content: ChatChannelContent(requestId: request.requestId, text: params.inputs.prompt, context: messages, attachments: params.inputs.attachments)),
              authority.basis == params.consentBasis, authority.id == params.consentReference else { return false }
        return request.decisionBasis == nil || request.decisionBasis == authority.basis
            && (authority.basis != "channel_trust" || request.decisionPolicyId == authority.id)
    }

    func setChannelTrust(_ key: ChatOrgKey, channel: String, agent: ChatChannelAgent, enabled: Bool) throws {
        guard supports("chat.channel_ux1", key: key), let journal, agent.ownerAccountId == key.accountId,
              let connection, connection.orgKey == key else { throw ChatError.notConnected }
        if enabled {
            guard let current = trustReview(key, channel: channel, agent: agent.agentId), current.agent == agent else {
                throw ChatError.storage("The channel, agent or trust policy changed. Review it again.")
            }
        }
        let old = agent.trust?.policyId
        // Revocation is durable before its network command; no offline promise.
        if let old { try journal.revokeAuthority(old) }
        var args: [String: ChatJSON] = ["agent_id": .string(agent.agentId), "channel_id": .string(channel),
            "enabled": .bool(enabled), "expected_policy_id": old.map(ChatJSON.string) ?? .null]
        if enabled {
            guard let local = localChannelExecutor(key, channel: channel, agent: agent), !local.access.runsShell,
                  let generation = try journal.generation(key).generation else { throw ChatError.storage("Enable trust on the executor Mac with a profile without shell access.") }
            let id = UUID().uuidString.lowercased()
            try journal.storeAuthority(ChatChannelAuthority(id: id, server: key.server.description, account: key.accountId,
                org: key.orgId, session: connection.sessionId, generation: generation, channel: channel, agent: agent.agentId,
                basis: "channel_trust", settings: ChatExecutionSettings(local)))
            args["policy_id"] = .string(id)
        }
        _ = try enqueue(key, type: "agent.channel_trust.set", args: .object(args))
        reconcileAutomaticChannels()
    }

    /// Normal publication intents remain the only publisher. A finished server
    /// event alone cannot replace the executor's acknowledged fact chain.
    func reconcileAutomaticChannels() {
        guard let key = connection?.orgKey, let journal, let store = orgSessions[key]?.store,
              ChatNotifications.allowed(self, key, channel: nil) else { return }
        invalidateChannelAuthorities(key)
        let approvals = (try? journal.approvals()) ?? []
        for approval in approvals where approval.key == key && approval.kind == "initial" && approval.voidAt == nil {
            guard let params = try? TeamLaunchParams.decode(approval.params), params.consentBasis != nil, params.consentBasis != "manual",
                  let request = try? store.calls.request(approval.requestId) else { continue }
            if !automaticApprovalValid(key, request: request, params: params) {
                try? journal.blockAutomaticRequest(key, request: request.requestId)
                _ = try? journal.void(approval.id, reason: "automatic_consent_revoked", at: Date())
                if !request.state.isFinal { _ = askToEnd(key, request.requestId, type: "request.stop", states: [.starting, .running, .stopRequested]) }
                // A queued publication may not survive a local revocation.
                try? store.queue.write { db in
                    for command in try ChatPublication.commands(db, run: approval.runId) where command.state == .pending {
                        guard try ChatPublication.isAutomatic(db, command: command.commandId) else { continue }
                        try db.execute(sql: "UPDATE outbox SET state = 'dropped', error = 'automatic_consent_revoked' WHERE command_id = ?", arguments: [command.commandId])
                    }
                }
                continue
            }
            guard request.state == .finished, request.publication == "awaiting_publish",
                  let commands = try? journal.commands(for: key), commands.contains(where: {
                      $0.type == "run.finished" && $0.state == .sent && $0.sessionId == params.session
                          && $0.sentGeneration == params.generation && Self.args($0)["run_id"]?.string == approval.runId
                  }),
                  (try? store.queue.read { try ChatPublication.current($0, run: approval.runId) }) == nil else { continue }
            _ = try? publishChannelResult(key, requestId: request.requestId, publish: true, automatic: true)
        }
    }

    /// Revocation is monotonic: returning to old settings/session/generation
    /// never resurrects a policy. A pending enable is only a promise to send.
    func invalidateChannelAuthorities(_ key: ChatOrgKey) {
        guard let journal, let store = orgSessions[key]?.store, let connection,
              let gen = try? journal.generation(key), gen.pending == nil, let generation = gen.generation else { return }
        let authorities = (try? journal.queue.read { db in
            try String.fetchAll(db, sql: "SELECT body FROM channel_authorities WHERE server = ? AND account_id = ? AND org_id = ? AND revoked = 0",
                arguments: [key.server.description, key.accountId, key.orgId]).compactMap { try? JSONDecoder().decode(ChatChannelAuthority.self, from: Data($0.utf8)) }
        }) ?? []
        let commands = ((try? store.outbox.commands()) ?? []) + ((try? journal.commands(for: key)) ?? [])
        // A missing journal policy cannot be recovered from the public flag.
        // Tell the server it is off on this executor, so colleagues see it too.
        let publicAgents = (try? store.queue.read { db in
            try String.fetchAll(db, sql: "SELECT channel_id FROM channels").flatMap { try ChatChannelAgents.read(db, channel: $0) }
        }) ?? []
        for card in publicAgents where card.ownerAccountId == key.accountId && card.executorSessionId == connection.sessionId && card.trust?.enabled == true {
            guard let id = card.trust?.policyId, (try? journal.channelAuthority(id)) == nil,
                  !commands.contains(where: { $0.type == "agent.channel_trust.set" && $0.state == .pending && Self.args($0)["expected_policy_id"]?.string == id }) else { continue }
            _ = try? enqueue(key, type: "agent.channel_trust.set", args: .object([
                "agent_id": .string(card.agentId), "channel_id": .string(card.channelId), "enabled": .bool(false), "expected_policy_id": .string(id)]))
        }
        for a in authorities {
            let card = (try? store.channelAgents(a.channel))?.first { $0.agentId == a.agent }
            let local = card.flatMap { localChannelExecutor(key, channel: a.channel, agent: $0) }
            let enabling = commands.contains { $0.type == "agent.channel_trust.set" && $0.state == .pending && Self.args($0)["policy_id"]?.string == a.id }
            let publicMatches = a.basis == "self_call" || enabling || card?.trust?.enabled == true && card?.trust?.policyId == a.id
            guard !publicMatches || local.map({ !a.matchesScope(key, session: connection.sessionId, generation: generation, agent: $0) }) != false else { continue }
            try? journal.revokeAuthority(a.id)
            if a.basis == "channel_trust", card?.trust?.policyId == a.id {
                _ = try? enqueue(key, type: "agent.channel_trust.set", args: .object([
                    "agent_id": .string(a.agent), "channel_id": .string(a.channel), "enabled": .bool(false), "expected_policy_id": .string(a.id)]))
            }
        }
    }
}
