import Foundation
import GRDB

/// What a publication asks the server for: the `agent.publish` arguments
/// but the agent's id (D3, docs/agentpad/DESIGN-D3.md).
struct ChatPublishRequest: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var access: String
    var teamIds: [String]
    /// Asked by the announce after a new session of this Mac (6.4), not by
    /// the owner's button: told with "available again".
    var auto = false
    /// The server generation it was asked under: a command lost with its
    /// session goes on by itself under the same generation only (lead's
    /// decision on review D3c-p2-2).
    var generation: String?
    /// Asks the server to stop publishing the agent (`agent.unpublish`, D3b).
    var unpublish = false

    enum CodingKeys: String, CodingKey {
        case name, description, access, auto, generation, unpublish
        case teamIds = "team_ids"
    }

    init(name: String, description: String, access: String, teamIds: [String], auto: Bool = false) {
        self.name = name
        self.description = description
        self.access = access
        self.teamIds = teamIds.sorted()
        self.auto = auto
    }

    init(agent: TeamPublishedAgent, teams: [String]) {
        self.init(name: agent.name, description: agent.description, access: agent.access.rawValue, teamIds: teams)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        access = try c.decode(String.self, forKey: .access)
        teamIds = try c.decode([String].self, forKey: .teamIds).sorted()
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
        generation = try c.decodeIfPresent(String.self, forKey: .generation)
        unpublish = try c.decodeIfPresent(Bool.self, forKey: .unpublish) ?? false
    }

    /// What colleagues see of it is what the local agent runs with.
    func matches(_ agent: TeamPublishedAgent) -> Bool {
        name == agent.name && description == agent.description && access == agent.access.rawValue
    }

    /// The same publication, whoever asked it.
    func sameAs(_ other: ChatPublishRequest) -> Bool {
        unpublish == other.unpublish && name == other.name && description == other.description && access == other.access && teamIds == other.teamIds
    }

    var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }

    static func decode(_ text: String?) -> ChatPublishRequest? {
        text.flatMap { try? JSONDecoder().decode(ChatPublishRequest.self, from: Data($0.utf8)) }
    }
}

extension ChatAssignment {
    /// The parameters the server accepted (for `pending`: the ones asked).
    var accepted: ChatPublishRequest {
        let teams = (try? JSONDecoder().decode([String].self, from: Data(teamIds.utf8))) ?? []
        return ChatPublishRequest(name: name, description: description, access: access, teamIds: teams)
    }
}

/// How a local agent stands with the server, for the Published Agents
/// window (D3).
enum TeamPublishStatus: Equatable, Sendable {
    /// No publication: only on this Mac.
    case local
    /// Asked; its command is on its way.
    case publishing
    /// Asked before the server was restored: waits for the owner (send
    /// again, or withdraw).
    case unconfirmed
    /// Published as it is here, to these teams.
    case published(teams: [String])
    /// Published, but what is here differs: runs are refused until the
    /// owner publishes again; the server's last refusal, if any.
    case changesNotPublished(error: String?)
    /// Unpublishing asked: runs are refused; the agent goes from this Mac
    /// once the server took it (D3b).
    case unpublishing
    /// Unpublishing not confirmed (its session or the server's generation
    /// changed): the owner unpublishes again or keeps it published (review D3b-2).
    case unpublishUnconfirmed
}

/// The organization's publishing on this Mac (D3). The assignment in the
/// journal is the source of truth: a publication asked stays asked
/// (`requested`) until the server took or refused it, whatever happened to
/// its command meanwhile.
extension ChatService: TeamPublishing {
    static let publishType = "agent.publish"
    static let unpublishType = "agent.unpublish"
    /// Why the owner gave a publication up.
    static let withdrawnError = "withdrawn by the owner"

    private static func publishKey(_ agentId: String) -> String { ChatOutbox.executorKeyPrefix + "agent:\(agentId)" }

    /// The teams of the signed-in member in the organization, General first.
    func myTeams(_ key: ChatOrgKey) -> [ChatSnapshot.Team] {
        guard let store = orgSessions[key]?.store else { return [] }
        let rows = (try? store.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT team_id, name, is_general FROM teams WHERE mine AND archived_at IS NULL ORDER BY is_general DESC, name")
        }) ?? []
        return rows.map { ChatSnapshot.Team(teamId: $0["team_id"], name: $0["name"], isGeneral: $0["is_general"]) }
    }

    /// The teams the owner chose for the agent — of the publication on its
    /// way, else the accepted one; nil when it was never published (review
    /// D3-p1-4, p2-3).
    func chosenTeams(_ agentId: UUID, key: ChatOrgKey) -> [String]? {
        guard let journal, let row = try? journal.assignment(key, agentId: agentId.uuidString.lowercased()) else { return nil }
        return ChatPublishRequest.decode(row.requested)?.teamIds ?? row.accepted.teamIds
    }

    /// The current organization, if any.
    var currentKey: ChatOrgKey? { connection?.orgKey }

    /// An assignment of this agent exists anywhere: it may not be removed
    /// or paused here until D3b. Not known — a journal that could not be
    /// opened or read — says yes: nothing is removed on a guess (review
    /// D3b-p2-1). Only no journal ever made says no.
    func isAssigned(_ agentId: UUID) -> Bool {
        guard let journal else { return journalProblem != nil || FileManager.default.fileExists(atPath: files.journalURL.path) }
        let id = agentId.uuidString.lowercased()
        return (try? journal.queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM assignments WHERE agent_id = ?)", arguments: [id])
        } ?? false) ?? true
    }

    /// The owner's button: each agent whose publication differs from what
    /// the server has (or has none) is asked, in one transaction of the
    /// journal with its command; the rest are left as they are. Refused
    /// whole when an agent is paused (`enabled == false`), when the teams
    /// are not the member's, or when another publication of it is on its way.
    func publish(_ agents: [TeamPublishedAgent], teams: [String], key: ChatOrgKey) throws {
        guard let journal, let connection, connection.orgKey == key else { throw TeamError.notConnected }
        let mine = Set(myTeams(key).map(\.teamId))
        guard !teams.isEmpty, Set(teams).isSubset(of: mine) else {
            throw TeamError.storage("choose one or more of your teams to publish to")
        }
        if let paused = agents.first(where: { !$0.enabled }) {
            throw TeamError.storage("\(paused.name) is not published: Published is off")
        }
        if let refusal = TeamAccessProfile.notOnServerYet(agents) { throw TeamError.storage(refusal) }
        let first = try ChatCommandTable.maxSeq(commandTables(key)) + 1
        let now = Date()
        let table = journal.runCommands(key)
        // The cards the server lists now: one it no longer lists, or lists
        // otherwise, is published again (review D3-p2-2, D3b-p2-3).
        let cards = (try? orgSessions[key]?.store?.calls.catalog()) ?? []
        try journal.queue.write { db in
            var seq = first
            for agent in agents {
                let id = agent.id.uuidString.lowercased()
                // One organization per agent: one assigned elsewhere is
                // unpublished there first (review D3b3-2).
                if let elsewhere = try ChatAssignment.fetchOne(db, sql: """
                    SELECT * FROM assignments WHERE agent_id = ? AND NOT (server = ? AND account_id = ? AND org_id = ?)
                    """, arguments: [id, key.server.description, key.accountId, key.orgId]) {
                    let host = (try? ChatServerAddress(parsing: elsewhere.server))?.host ?? elsewhere.server
                    throw TeamError.storage("\(agent.name) is published to another organization (\(host)); unpublish it from there first")
                }
                var wasRemoving = false
                var asked = ChatPublishRequest(agent: agent, teams: teams)
                asked.generation = try Self.generation(db, key)
                var row = try Self.assignment(db, key, id)
                if let current = row, let inFlight = ChatPublishRequest.decode(current.requested) {
                    if inFlight.sameAs(asked) { continue }
                    guard inFlight.unpublish else {
                        throw TeamError.storage("a publication of \(current.name) is on its way; wait for it, then publish again")
                    }
                    // Publish while being unpublished: the unpublish not taken
                    // yet gives way; one taken meanwhile is followed by this
                    // publication (DESIGN-D3b-D4b-D5b §1.1).
                    try db.execute(sql: """
                        UPDATE run_commands SET state = 'dropped', error = ?
                        WHERE server = ? AND account_id = ? AND org_id = ? AND order_key = ? AND type = ? AND state IN ('pending', 'unconfirmed')
                        """, arguments: [Self.withdrawnError, key.server.description, key.accountId, key.orgId, Self.publishKey(id), Self.unpublishType])
                    // It was published: a refusal of this publication keeps the
                    // earlier one (`active`, with the error), never removes it (review D3b2-1).
                    row?.state = .active
                    wasRemoving = true
                }
                // What the server has already — accepted as it is, from this
                // session, listed, not refused or withdrawn since: nothing to
                // ask (review D3b-3). Otherwise the button asks again, also
                // with the same parameters (review D3-p2-2).
                // Asked while unpublishing: always asked of the server (review D3b3-1).
                if !wasRemoving, let row, row.state == .active, row.accepted.sameAs(asked), row.publishedSession == connection.sessionId,
                   row.lastError == nil, let card = cards.first(where: { $0.agentId == id }), Self.shows(card, row.accepted) { continue }
                if row == nil {
                    row = ChatAssignment(server: key.server.description, accountId: key.accountId, orgId: key.orgId, agentId: id,
                                         state: .pending, name: asked.name, description: asked.description, access: asked.access,
                                         teamIds: Self.teamsJSON(asked.teamIds), createdAt: now)
                }
                try Self.ask(db, into: table, &row!, asked, key: key, session: connection.sessionId, seq: seq, at: now)
                seq += 1
            }
        }
        publishRevision += 1
        factStored(key)
    }

    /// The request written into the assignment and its command, inside the
    /// journal's transaction.
    private static func ask(_ db: Database, into table: ChatCommandTable, _ row: inout ChatAssignment, _ asked: ChatPublishRequest,
                            key: ChatOrgKey, session: String, seq: Int64, at now: Date) throws {
        row.requested = asked.json
        row.requestedAt = now
        row.lastError = nil
        try row.save(db)
        try insertCommand(db, into: table, row.agentId, asked, key: key, session: session, seq: seq, at: now)
    }

    private static func insertCommand(_ db: Database, into table: ChatCommandTable, _ agentId: String, _ asked: ChatPublishRequest,
                                      key: ChatOrgKey, session: String, seq: Int64, at now: Date) throws {
        let id = ChatUUID.v7(now: now)
        let args: ChatJSON = asked.unpublish ? .object(["agent_id": .string(agentId)]) : .object([
            "agent_id": .string(agentId), "name": .string(asked.name), "description": .string(asked.description),
            "access": .string(asked.access), "team_ids": .array(asked.teamIds.map { .string($0) }),
        ])
        let type = asked.unpublish ? unpublishType : publishType
        let bytes = try ChatCommandEnvelope(commandId: id, org: key.orgId, type: type, args: args).encoded()
        var record = ChatCommandRecord(commandId: id, sessionId: session, type: type, bodyBytes: bytes,
                                       orderKey: publishKey(agentId), dependsOn: nil, createdAt: now, state: .pending)
        record.seq = seq
        _ = try table.insert(db, record, seq: seq)
    }

    /// The card the server lists is the accepted publication: its name,
    /// description, rights and the owner's teams of its audience.
    static func shows(_ card: ChatAgentCard, _ accepted: ChatPublishRequest) -> Bool {
        card.name == accepted.name && card.description == accepted.description && card.access == accepted.access
            && (card.teamIds ?? []).sorted() == accepted.teamIds
    }

    private static func teamsJSON(_ teams: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(teams.sorted())) ?? Data("[]".utf8), as: UTF8.self)
    }

    private static func assignment(_ db: Database, _ key: ChatOrgKey, _ agentId: String) throws -> ChatAssignment? {
        try ChatAssignment.fetchOne(db, sql: "SELECT * FROM assignments WHERE server = ? AND account_id = ? AND org_id = ? AND agent_id = ?",
                                    arguments: [key.server.description, key.accountId, key.orgId, agentId])
    }

    private func commandTables(_ key: ChatOrgKey) -> [ChatCommandTable] {
        var tables: [ChatCommandTable] = []
        if let journal { tables.append(journal.runCommands(key)) }
        if let store = orgSessions[key]?.store { tables.append(store.outbox) }
        return tables
    }

    /// The commands of an assignment's publication (or unpublishing) asked at `since`.
    private static func publications(_ db: Database, _ key: ChatOrgKey, _ agentId: String, since: Date,
                                     type: String = publishType) throws -> [ChatCommandRecord] {
        try ChatCommandRecord.fetchAll(db, sql: """
            SELECT * FROM run_commands WHERE server = ? AND account_id = ? AND org_id = ? AND type = ? AND order_key = ? AND created_at >= ?
            ORDER BY seq, rowid
            """, arguments: [key.server.description, key.accountId, key.orgId, type, publishKey(agentId), since])
    }

    private static func publications(_ db: Database, _ key: ChatOrgKey, _ row: ChatAssignment, _ asked: ChatPublishRequest,
                                     since: Date) throws -> [ChatCommandRecord] {
        try publications(db, key, row.agentId, since: since, type: asked.unpublish ? unpublishType : publishType)
    }

    /// Where each team's stream stood when the server took a publication
    /// (its answer's events), kept with the assignment: an `agent.unpublish`
    /// of a team at or before it is older than this publication
    /// (DESIGN-D3b-D4b-D5b §11.3).
    func keepTeamSeqs(_ key: ChatOrgKey, _ record: ChatCommandRecord, _ answer: ChatCommandAnswer) {
        guard let journal, let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes),
              let agentId = envelope.args["agent_id"]?.string else { return }
        var seqs: [String: Int] = [:]
        for written in answer.events where written.stream.hasPrefix("team:") { seqs[String(written.stream.dropFirst(5))] = written.seq }
        let json = String(decoding: (try? JSONEncoder().encode(seqs)) ?? Data("{}".utf8), as: UTF8.self)
        do {
            try journal.queue.write { db in
                try db.execute(sql: "UPDATE assignments SET team_seqs = ? WHERE server = ? AND account_id = ? AND org_id = ? AND agent_id = ?",
                               arguments: [json, key.server.description, key.accountId, key.orgId, agentId])
            }
        } catch {
            NSLog("agentpad: where publication \(agentId) stands could not be kept: \(error.localizedDescription)")
        }
    }

    /// The audience as the server's team streams tell it now (D3b, §10.4,
    /// §11.3): a team whose stream unpublished the agent after the
    /// publication the server took leaves the assignment; with no team left
    /// and nothing asked, the assignment goes — the local agent stays. A
    /// stream not read past the publication, or a publication whose place is
    /// not known, changes nothing.
    func settleAudiences(_ key: ChatOrgKey) {
        guard let journal, let store = orgSessions[key]?.store else { return }
        do {
            let rows = try journal.queue.read { db in
                try ChatAssignment.fetchAll(db, sql: """
                    SELECT * FROM assignments WHERE server = ? AND account_id = ? AND org_id = ? AND state = 'active' AND requested IS NULL
                    """, arguments: [key.server.description, key.accountId, key.orgId])
            }
            guard !rows.isEmpty else { return }
            let listed = try store.calls.queue.read { db in
                Set(try Row.fetchAll(db, sql: "SELECT agent_id, team_id FROM agent_teams").map { "\($0["agent_id"] as String)/\($0["team_id"] as String)" })
            }
            // Teams this member is in now (the snapshot's `my_teams`): one left
            // — its stream and cursor gone — leaves every audience, whatever
            // the boundary (review D3b-1).
            let mine = Set(myTeams(key).map(\.teamId))
            var changed = false
            try journal.queue.write { db in
                for var row in rows {
                    // No boundary known (its answer lost, or kept before it was
                    // kept): the stream's word counts from its start.
                    let seqs = (try? JSONDecoder().decode([String: Int].self, from: Data((row.teamSeqs ?? "{}").utf8))) ?? [:]
                    let teams = row.accepted.teamIds
                    let left = teams.filter { team in
                        if !mine.isEmpty, !mine.contains(team) { return true }
                        guard !listed.contains("\(row.agentId)/\(team)") else { return false }
                        return ((try? store.cursor("team:\(team)")) ?? 0) > seqs[team, default: 0]
                    }
                    guard !left.isEmpty else { continue }
                    // Read again inside the transaction: nothing asked since.
                    guard let now = try Self.assignment(db, key, row.agentId), now.requested == nil, now.state == .active else { continue }
                    let kept = teams.filter { !left.contains($0) }
                    if kept.isEmpty {
                        _ = try now.delete(db)
                    } else {
                        row.teamIds = Self.teamsJSON(kept)
                        try row.update(db)
                    }
                    changed = true
                }
            }
            if changed { publishRevision += 1 }
        } catch {
            NSLog("agentpad: the audiences of \(key.orgId) could not be read: \(error.localizedDescription)")
        }
    }

    /// The organization an agent is published to from this Mac, whichever is
    /// connected now (review D3b2-2).
    func assignmentKey(_ agentId: UUID) -> ChatOrgKey? {
        guard let journal else { return nil }
        let row = try? journal.queue.read { db in
            try ChatAssignment.fetchOne(db, sql: "SELECT * FROM assignments WHERE agent_id = ?", arguments: [agentId.uuidString.lowercased()])
        }
        guard let row = row ?? nil, let server = try? ChatServerAddress(parsing: row.server) else { return nil }
        return ChatOrgKey(server: server, accountId: row.accountId, orgId: row.orgId)
    }

    /// The owner stops publishing the agent (D3b): `removing`, and
    /// `agent.unpublish`, in one transaction of the journal. The local agent
    /// goes only once the server took it (`settlePublications`).
    func unpublish(_ agentId: UUID, key: ChatOrgKey) throws {
        guard let journal, let connection, connection.orgKey == key else { throw TeamError.notConnected }
        let id = agentId.uuidString.lowercased()
        let first = try ChatCommandTable.maxSeq(commandTables(key)) + 1
        let now = Date()
        let table = journal.runCommands(key)
        let already = try journal.queue.write { db -> Bool in
            guard var row = try Self.assignment(db, key, id) else {
                throw TeamError.storage("it is not published to this organization; connect to the one it was published to, then unpublish it")
            }
            var asked = row.accepted
            asked.unpublish = true
            asked.generation = try Self.generation(db, key)
            if let inFlight = ChatPublishRequest.decode(row.requested), inFlight.unpublish { return true }
            // A publication not taken yet gives way.
            try db.execute(sql: """
                UPDATE run_commands SET state = 'dropped', error = ?
                WHERE server = ? AND account_id = ? AND org_id = ? AND order_key = ? AND type = ? AND state IN ('pending', 'unconfirmed')
                """, arguments: [Self.withdrawnError, key.server.description, key.accountId, key.orgId, Self.publishKey(id), Self.publishType])
            row.state = .removing
            try Self.ask(db, into: table, &row, asked, key: key, session: connection.sessionId, seq: first, at: now)
            return false
        }
        // Asked before: unpublished again when it waits for the owner (review D3b-2).
        if already { return try resendPublication(agentId, key: key) }
        publishRevision += 1
        factStored(key)
    }

    /// Each publication asked is settled from what its commands came to —
    /// one transaction, from what is stored only, so it may run again any
    /// time (review D3-5):
    /// - one taken by the server: the assignment has its parameters, active;
    /// - one on its way: nothing yet;
    /// - refused, or withdrawn by the owner: a new one goes, an asked change
    ///   is given up (the server's word kept);
    /// - sent again by the owner (Send Again, Try Again): asked anew under
    ///   the current session;
    /// - else — unconfirmed by a new generation, dropped with its session —
    ///   it waits for the owner, as the core's Try Again does: one condition,
    ///   kept in the journal, so a restart or a session changed before the
    ///   generation does not send it by itself (lead's rule on review D3b-p1-1).
    func settlePublications(_ key: ChatOrgKey) {
        guard let journal else { return }
        let session = connection?.orgKey == key ? connection?.sessionId : nil
        var again: [String] = []
        var gone: [String] = []
        do {
            let first = try ChatCommandTable.maxSeq(commandTables(key)) + 1
            let now = Date()
            let table = journal.runCommands(key)
            try journal.queue.write { db in
                var seq = first
                let rows = try ChatAssignment.fetchAll(db, sql: """
                    SELECT * FROM assignments WHERE server = ? AND account_id = ? AND org_id = ? AND requested IS NOT NULL
                    """, arguments: [key.server.description, key.accountId, key.orgId])
                for var row in rows {
                    guard let asked = ChatPublishRequest.decode(row.requested), let since = row.requestedAt else { continue }
                    let commands = try Self.publications(db, key, row, asked, since: since)
                    if asked.unpublish {
                        // Taken, or the server does not know the agent: the
                        // assignment and the local agent go. Refused
                        // otherwise: published as before, the refusal said.
                        let refused = commands.last(where: { $0.state == .failed })
                        if commands.contains(where: { $0.state == .sent }) || refused?.error == "not_found" {
                            _ = try row.delete(db)
                            gone.append(row.agentId)
                        } else if commands.contains(where: { $0.state == .pending }) {
                            continue
                        } else if let refused {
                            row.state = .active
                            try Self.giveUp(db, &row, error: refused.error ?? "refused")
                        } else if commands.contains(where: { $0.state == .dropped && $0.error == Self.withdrawnError }) {
                            // Kept published: the owner's word (review D3b-2).
                            row.state = .active
                            try Self.giveUp(db, &row, error: nil)
                        } else if Self.wait(commands, asked, settled: try Self.settledGeneration(db, key)) == .goOn, let session {
                            try Self.insertCommand(db, into: table, row.agentId, asked, key: key, session: session, seq: seq, at: max(now, since))
                            seq += 1
                        }
                        continue
                    }
                    if let taken = commands.last(where: { $0.state == .sent }) {
                        let args = (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: taken.bodyBytes)).flatMap { envelope -> ChatPublishRequest? in
                            guard case .object(let o) = envelope.args, let name = o["name"]?.string, let description = o["description"]?.string,
                                  let access = o["access"]?.string, case .array(let teams)? = o["team_ids"] else { return nil }
                            return ChatPublishRequest(name: name, description: description, access: access, teamIds: teams.compactMap(\.string))
                        } ?? asked
                        row.name = args.name
                        row.description = args.description
                        row.access = args.access
                        row.teamIds = Self.teamsJSON(args.teamIds)
                        row.state = .active
                        row.publishedSession = taken.sessionId
                        row.requested = nil
                        row.requestedAt = nil
                        row.lastError = nil
                        try row.update(db)
                        if asked.auto { again.append(row.name) }
                    } else if commands.contains(where: { $0.state == .pending }) {
                        continue
                    } else if let refused = commands.last(where: { $0.state == .failed }) {
                        try Self.giveUp(db, &row, error: refused.error ?? "refused")
                    } else if commands.contains(where: { $0.state == .dropped && $0.error == Self.withdrawnError }) {
                        // Kept as the owner's word: nothing announces it again
                        // until the owner publishes (review D3-p1-2).
                        try Self.giveUp(db, &row, error: Self.withdrawnError)
                    } else if Self.wait(commands, asked, settled: try Self.settledGeneration(db, key)) == .goOn, let session {
                        try Self.insertCommand(db, into: table, row.agentId, asked, key: key, session: session, seq: seq, at: max(now, since))
                        seq += 1
                    }
                }
            }
        } catch {
            NSLog("agentpad: publications of \(key.orgId) could not be settled: \(error.localizedDescription)")
            publishProblems[Self.problemKey("settle", key)] = "Publications could not be checked: \(error.localizedDescription)"
            reconcileLater(key)
            return
        }
        publishProblems[Self.problemKey("settle", key)] = nil
        publishRevision += 1
        factStored(key)
        if !again.isEmpty { onNotice(againNotice(again, key: key)) }
        for agentId in gone { onAgentUnpublished(agentId) }
        settleAudiences(key)
    }

    /// What a publication with no command on its way and none taken or
    /// refused waits for (review D3c-p2-2, lead's decision):
    /// - `goOn`: asked again under the current session by itself — the
    ///   owner sent it again, or its command was lost with its session
    ///   while the server's generation stayed the one it was asked under;
    /// - `owner`: the owner decides (Send Again, Try Again, Withdraw) —
    ///   unconfirmed by a new generation, or lost with its session under
    ///   another generation;
    /// - `hello`: lost with its session, the new session's generation not
    ///   settled yet — decided after its hello.
    enum Wait: Equatable { case goOn, owner, hello, none }

    static func wait(_ commands: [ChatCommandRecord], _ asked: ChatPublishRequest, settled: String?) -> Wait {
        if commands.contains(where: { $0.state == .pending || $0.state == .sent || $0.state == .failed }) { return .none }
        if commands.contains(where: { $0.state == .dropped && $0.error == withdrawnError }) { return .none }
        if commands.last?.state == .dropped, commands.last?.error == sentAgainError { return .goOn }
        if commands.contains(where: { $0.state == .unconfirmed }) { return .owner }
        guard let settled else { return .hello }
        return asked.generation == settled ? .goOn : .owner
    }

    /// The organization's server generation as the journal has it settled; nil while a change is under way.
    private static func settledGeneration(_ db: Database, _ key: ChatOrgKey) throws -> String? {
        let row = try Row.fetchOne(db, sql: "SELECT generation, pending_generation FROM org_generations WHERE server = ? AND account_id = ? AND org_id = ?",
                                   arguments: [key.server.description, key.accountId, key.orgId])
        guard let row, (row["pending_generation"] as String?) == nil else { return nil }
        return row["generation"]
    }

    /// The generation a publication is asked under: the one under way, else the settled one.
    private static func generation(_ db: Database, _ key: ChatOrgKey) throws -> String? {
        let row = try Row.fetchOne(db, sql: "SELECT generation, pending_generation FROM org_generations WHERE server = ? AND account_id = ? AND org_id = ?",
                                   arguments: [key.server.description, key.accountId, key.orgId])
        return (row?["pending_generation"] as String?) ?? row?["generation"]
    }

    private static func giveUp(_ db: Database, _ row: inout ChatAssignment, error: String?) throws {
        if row.state == .pending {
            _ = try row.delete(db)
        } else {
            row.requested = nil
            row.requestedAt = nil
            row.lastError = error
            try row.update(db)
        }
    }

    private func againNotice(_ names: [String], key: ChatOrgKey) -> String {
        let cards = (try? orgSessions[key]?.store?.calls.catalog()) ?? []
        let off = names.filter { name in cards.contains { $0.name == name && $0.ownerAccountId == key.accountId && !$0.enabled } }
        var text = "Agents \(names.sorted().joined(separator: ", ")) are available again from this Mac."
        if !off.isEmpty { text += " Disabled by an admin: \(off.sorted().joined(separator: ", "))." }
        return text
    }

    /// After a new session of this Mac (6.4): each active publication the
    /// server took from another session is asked again, exactly as it was
    /// accepted — never written to `agents.json`, and only for an agent this
    /// Mac can run whose local parameters are still the accepted ones
    /// (lead's decision on review D3b-1). Nothing else announces.
    func announceAfterNewSession(_ key: ChatOrgKey) {
        guard let journal, let connection, connection.orgKey == key else { return }
        do {
            let first = try ChatCommandTable.maxSeq(commandTables(key)) + 1
            let now = Date()
            var asked = false
            let table = journal.runCommands(key)
            try journal.queue.write { db in
                var seq = first
                let rows = try ChatAssignment.fetchAll(db, sql: """
                    SELECT * FROM assignments WHERE server = ? AND account_id = ? AND org_id = ? AND state = 'active'
                        AND requested IS NULL AND last_error IS NULL AND published_session IS NOT ?
                    """, arguments: [key.server.description, key.accountId, key.orgId, connection.sessionId])
                for var row in rows {
                    guard let agent = localAgent(row.agentId), agent.enabled, row.accepted.matches(agent), Self.canRun(agent) else { continue }
                    var again = row.accepted
                    again.auto = true
                    again.generation = try Self.generation(db, key)
                    try Self.ask(db, into: table, &row, again, key: key, session: connection.sessionId, seq: seq, at: now)
                    seq += 1
                    asked = true
                }
            }
            publishProblems[Self.problemKey("announce", key)] = nil
            if asked {
                publishRevision += 1
                factStored(key)
            }
        } catch {
            // Tried again like any other write, and said (review D3-p2-4).
            NSLog("agentpad: publications of \(key.orgId) could not be announced: \(error.localizedDescription)")
            publishProblems[Self.problemKey("announce", key)] = "Published agents could not be announced again: \(error.localizedDescription)"
            reconcileLater(key)
        }
    }

    /// This Mac can run the agent: its folder is there, and its conversation
    /// for a session agent.
    static func canRun(_ agent: TeamPublishedAgent) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: agent.folder, isDirectory: &isDir), isDir.boolValue else { return false }
        return agent.sessionId.map { TeamSessionFiles.exists($0) } ?? true
    }

    /// The owner gives up a publication waiting for the owner — unconfirmed,
    /// or lost with its session — whatever way it waits: the waiting
    /// commands, and the last one, are marked withdrawn, and settling ends
    /// the assignment (review D3c-p1-1).
    func withdrawPublication(_ agentId: UUID, key: ChatOrgKey) throws {
        try mark(key, agentId: agentId.uuidString.lowercased(), as: Self.withdrawnError)
        settlePublications(key)
    }

    /// A problem of one operation of one organization: only that operation's
    /// success clears it (review D3b-p2-4).
    static func problemKey(_ operation: String, _ key: ChatOrgKey) -> String {
        "\(operation)|\(key.server.description)|\(key.accountId)|\(key.orgId)"
    }

    /// The publications' problem of the current organization, if any.
    var publishProblem: String? {
        guard let key = currentKey else { return nil }
        return ["settle", "announce"].compactMap { publishProblems[Self.problemKey($0, key)] }.first
    }

    /// Why the owner sent a publication again: its successor is asked by
    /// `settlePublications` under the current session.
    static let sentAgainError = "sent again by the owner"

    /// Sends again a publication left unconfirmed by a restored server: the
    /// waiting command is dropped and the assignment's publication asked
    /// anew under the current session, in the settling's way; the queue goes
    /// on as after the core's Try Again (review D3-p1-1).
    func resendPublication(_ agentId: UUID, key: ChatOrgKey) throws {
        try mark(key, agentId: agentId.uuidString.lowercased(), as: Self.sentAgainError)
        settlePublications(key)
        if let outbox = orgSessions[key]?.outbox, outbox.paused == .generationChanged { outbox.resume() }
    }

    /// The owner's Try Again of the whole queue: every publication waiting
    /// for the owner goes again too.
    func resendPublications(_ key: ChatOrgKey) {
        do { try mark(key, agentId: nil, as: Self.sentAgainError) } catch {
            NSLog("agentpad: publications of \(key.orgId) could not be sent again: \(error.localizedDescription)")
        }
        settlePublications(key)
    }

    /// The owner's word on each publication waiting for the owner (or its
    /// new session's hello): its unconfirmed commands, and its last one,
    /// dropped as `word` — sent again, or withdrawn.
    private func mark(_ key: ChatOrgKey, agentId: String?, as word: String) throws {
        guard let journal else { throw TeamError.notConnected }
        try journal.queue.write { db in
            let rows = try ChatAssignment.fetchAll(db, sql: """
                SELECT * FROM assignments WHERE server = ? AND account_id = ? AND org_id = ? AND requested IS NOT NULL
                """, arguments: [key.server.description, key.accountId, key.orgId])
            let settled = try Self.settledGeneration(db, key)
            for row in rows where agentId == nil || row.agentId == agentId {
                guard let since = row.requestedAt, let asked = ChatPublishRequest.decode(row.requested) else { continue }
                let commands = try Self.publications(db, key, row, asked, since: since)
                guard [.owner, .hello].contains(Self.wait(commands, asked, settled: settled)) else { continue }
                for command in commands where command.state == .unconfirmed || command.commandId == commands.last?.commandId {
                    try db.execute(sql: "UPDATE run_commands SET state = 'dropped', error = ? WHERE command_id = ?",
                                   arguments: [word, command.commandId])
                }
            }
        }
    }

    /// How `agent` stands with the server, and what the catalog says of it.
    func publishStatus(_ agent: TeamPublishedAgent, key: ChatOrgKey) -> (status: TeamPublishStatus, note: String?) {
        _ = publishRevision
        let id = agent.id.uuidString.lowercased()
        guard let journal, let (row, waiting) = try? journal.queue.read({ db -> (ChatAssignment, Bool)? in
            guard let row = try Self.assignment(db, key, id) else { return nil }
            let asked = ChatPublishRequest.decode(row.requested)
            let commands = try row.requestedAt.flatMap { since in try asked.map { try Self.publications(db, key, row, $0, since: since) } } ?? []
            return (row, asked.map { Self.wait(commands, $0, settled: try? Self.settledGeneration(db, key)) == .owner } ?? false)
        }) ?? nil else { return (.local, nil) }
        let card = (try? orgSessions[key]?.store?.calls.catalog())?.first { $0.agentId == id }
        var note: String?
        if row.state == .active {
            if card == nil { note = "The server does not list it now (unpublished, or a restored server); publish it again if it should be." }
            else if card?.enabled == false { note = "Disabled by an admin." }
            else if let card, !Self.shows(card, row.accepted) {
                note = "The server lists it with other settings or teams (a restored server); publish it again if it should be as here."
            }
            else if row.publishedSession != connection?.sessionId, row.requested == nil {
                note = "Published from an earlier sign-in; publish it again to run it from this one."
            }
        }
        if row.state == .removing { return (waiting ? .unpublishUnconfirmed : .unpublishing, note) }
        if row.requested != nil { return (waiting ? .unconfirmed : .publishing, note) }
        guard row.state == .active else { return (.publishing, note) }
        if !row.accepted.matches(agent) { return (.changesNotPublished(error: row.lastError), note) }
        return (.published(teams: row.accepted.teamIds), note)
    }
}

/// What the publish windows say before an agent is published to an
/// organization (Р3, EX-7, the Y1 report): its rights, its memory, who may
/// call it. One composition for both windows.
enum TeamPublishWarnings {
    // No promise of isolation: what the Y1 report proved is said as it is
    // (review D3b-p1-3).
    static let readGit = "The agent runs git commands that read, in the project folder. It can read the repository's whole history, including files deleted from it and secrets ever committed."
    /// Y1, row 6: a git driver of the repository's own config runs on plain git diff, log and show.
    static let gitDriver = "A git driver set in the repository's own .git/config (for example a diff textconv) runs with your rights on ordinary git diff, log and show, and can read files outside the folder: check the repository's config before publishing it."
    static let edit = "The agent changes, creates and deletes files in the project folder and the folders you give it, including CLAUDE.md, Makefile, package.json and build scripts, which you or your next Claude Code session then run: check the changes before running them. Every command you allow (for example make, npm, swift test) runs the project's code with your rights: through it the agent can read any of your files, reach the network and the keychain (the system asks first), and act through agentpad-cli."
    /// Until Y3 fixes finding 1 of the Y1 report, said with `edit`; Y3 takes it out.
    static let editShellGap = "For now the agent can also create, move and delete files in the project folder and the folders you give it with shell commands (touch, mv, rm, >), even ones you did not allow, and its shell sees your environment variables, secrets in them included."
    static let read = "The agent only reads files in its folders; it runs no commands."
    static let session = "Answers draw on this session's memory: everyone who can call the agent may learn from them what was discussed here."

    static func lines(access: TeamAccessProfile, fromSession: Bool, teamNames: [String]) -> [String] {
        var out: [String]
        switch access {
        case .read: out = [read]
        case .editFiles: out = [TeamAccessProfile.editFilesWarning]
        case .readGit: out = [readGit, gitDriver, TeamAccessProfile.shellWarning]
        case .edit: out = [edit, gitDriver, editShellGap, TeamAccessProfile.shellWarning]
        }
        if fromSession { out.append(session) }
        let who = teamNames.isEmpty ? "No team chosen yet." : "Members of \(teamNames.joined(separator: ", ")) can call it; every call still waits for your Allow."
        out.append(who)
        return out
    }
}

extension TeamPublishedAgent {
    /// A new agent of the Published Agents window: through a server it
    /// starts with the least rights, `read` (D3(5)).
    static func fresh(serverMode: Bool) -> TeamPublishedAgent {
        var agent = TeamPublishedAgent(name: "", description: "", folder: "")
        if serverMode { agent.access = .read }
        return agent
    }
}

/// How the server answered a command for good.
enum ChatCommandOutcome: Sendable {
    case taken(ChatCommandAnswer?)
    case refused(String)
}

extension ChatService {
    /// The one dispatcher of the queue's final answers, by command type:
    /// `agent.publish` settles publications (D3); other types go to their
    /// owner's handler in `commandOwners` (D5: `request.create`).
    func commandAnswered(_ key: ChatOrgKey, _ record: ChatCommandRecord, _ outcome: ChatCommandOutcome) {
        if record.type == Self.publishType || record.type == Self.unpublishType {
            if record.type == Self.publishType, case .taken(let answer?) = outcome { keepTeamSeqs(key, record, answer) }
            settlePublications(key)
            return
        }
        commandOwners[record.type]?(key, record, outcome)
    }
}
