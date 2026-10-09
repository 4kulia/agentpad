import Foundation
import GRDB

/// What each event type does to the cache (docs/agentpad/CHAT-PLAN.md C8):
/// a registry of handlers by type, run inside the transaction that also moves
/// the stream's cursor (`ChatStore.apply`). Objects are written as "insert or
/// replace" by their id, so one change seen in two streams lands once.
/// Agents, requests and results are applied by `ChatCallStore` (D8), by
/// version, with their `reconcile`.
enum ChatEvents {
    typealias Handler = @Sendable (Database, ChatEvent) throws -> Void

    static let handlers: [String: Handler] = [
        "member.joined": { db, event in
            let body = event.body
            guard let account = body["account_id"]?.string else { return }
            try db.execute(
                sql: """
                    INSERT INTO members (account_id, handle, name, role) VALUES (?, ?, ?, ?)
                    ON CONFLICT(account_id) DO UPDATE SET handle = excluded.handle, name = excluded.name, role = excluded.role
                    """,
                arguments: [account, body["handle"]?.string ?? "", body["name"]?.string ?? "", body["role"]?.string ?? "member"]
            )
            try ChatCallStore.rememberNames(db)
        },
        "member.set_name": { db, event in
            guard let account = event.body["account_id"]?.string, let name = event.body["name"]?.string else { return }
            try db.execute(sql: "UPDATE members SET name = ? WHERE account_id = ?", arguments: [name, account])
        },
        // The admin stream (owners and admins): the cache keeps open
        // invitations, as the snapshot's `admin.invitations` does.
        "invitation.create": { db, event in
            let body = event.body
            guard let id = body["invitation_id"]?.string, let email = body["email"]?.string else { return }
            try db.execute(
                sql: """
                    INSERT INTO invitations (invitation_id, email, role, state, expires_at) VALUES (?, ?, ?, 'open', ?)
                    ON CONFLICT(invitation_id) DO UPDATE SET email = excluded.email, role = excluded.role, state = 'open',
                        expires_at = excluded.expires_at
                    """,
                arguments: [id, email, body["role"]?.string ?? "member", body["expires_at"]?.string]
            )
        },
        "invitation.revoke": { db, event in
            guard let id = event.body["invitation_id"]?.string else { return }
            try db.execute(sql: "DELETE FROM invitations WHERE invitation_id = ?", arguments: [id])
        },
        "invitation.accept": { db, event in
            guard let id = event.body["invitation_id"]?.string else { return }
            try db.execute(sql: "DELETE FROM invitations WHERE invitation_id = ?", arguments: [id])
        },
        "team.add_member": joinedTeam,
        "team.join": joinedTeam,
        "team.remove_member": leftTeam,
        "team.leave": leftTeam,
        // A team's events come in its own stream (its members) and in the
        // admin stream: a team seen in its own stream is the user's.
        "team.create": { db, event in
            guard try !managerHasIt(db, event) else { return }
            guard let team = event.body["team_id"]?.string, let name = event.body["name"]?.string else { return }
            try db.execute(
                sql: """
                    INSERT INTO teams (team_id, name, mine) VALUES (?, ?, ?)
                    ON CONFLICT(team_id) DO UPDATE SET name = excluded.name, mine = teams.mine OR excluded.mine
                    """,
                arguments: [team, name, event.stream.hasPrefix("team:")]
            )
        },
        "team.rename": { db, event in
            guard try !managerHasIt(db, event) else { return }
            guard let team = event.body["team_id"]?.string, let name = event.body["name"]?.string else { return }
            try db.execute(sql: "UPDATE teams SET name = ? WHERE team_id = ?", arguments: [name, team])
        },
        "team.archive": { db, event in
            guard try !managerHasIt(db, event) else { return }
            guard let team = event.body["team_id"]?.string else { return }
            try db.execute(sql: "UPDATE teams SET archived_at = ? WHERE team_id = ?",
                           arguments: [event.body["archived_at"]?.string ?? event.at, team])
        },
        "member.set_role": { db, event in
            guard let account = event.body["account_id"]?.string, let role = event.body["role"]?.string else { return }
            try db.execute(sql: "UPDATE members SET role = ? WHERE account_id = ?", arguments: [role, account])
        },
        // The server keeps a removed member's row, but its snapshot no longer
        // lists it, nor in any team: neither does the cache. Each stream
        // changes only what it also brings back after a new invitation —
        // the organization's its members, a team's its own members, the
        // admin stream every team's — so a removal seen late in one stream
        // never undoes a return seen in another (review C6 p2-1).
        "member.remove": { db, event in
            guard let account = event.body["account_id"]?.string else { return }
            if event.stream.hasPrefix("org:") {
                try db.execute(sql: "DELETE FROM members WHERE account_id = ?", arguments: [account])
            } else if event.stream.hasPrefix("team:"), try !managerHasIt(db, event) {
                try db.execute(sql: "DELETE FROM team_members WHERE team_id = ? AND account_id = ?",
                               arguments: [String(event.stream.dropFirst("team:".count)), account])
            } else if event.stream.hasPrefix("org-admin:") {
                try db.execute(sql: "DELETE FROM team_members WHERE account_id = ?", arguments: [account])
            }
        },
    ]

    /// `team.add_member`, `team.join`.
    private static let joinedTeam: Handler = { db, event in
        guard try !managerHasIt(db, event) else { return }
        guard let team = event.body["team_id"]?.string, let account = event.body["account_id"]?.string else { return }
        // The user's own, in its own stream: it may be older than a removal
        // another stream already brought — the snapshot it asks for says
        // which (`ChatSync`), so nothing of it is written here (review C6d p1-2).
        guard !isOwn(event, account) else { return }
        try db.execute(sql: "INSERT OR IGNORE INTO team_members (team_id, account_id) VALUES (?, ?)", arguments: [team, account])
    }

    /// `team.remove_member`, `team.leave`. The user's own is also a
    /// revocation, handled by `ChatStore.apply` whatever stream brings it.
    private static let leftTeam: Handler = { db, event in
        guard try !managerHasIt(db, event) else { return }
        guard let team = event.body["team_id"]?.string, let account = event.body["account_id"]?.string else { return }
        try db.execute(sql: "DELETE FROM team_members WHERE team_id = ? AND account_id = ?", arguments: [team, account])
    }

    /// A team's own stream, while the admin stream is followed: the admin
    /// stream brings every change of every team, and is the one source of a
    /// manager's teams — a team stream stops once the user leaves the team,
    /// and what it still owed would be lost (review C6c p2-1).
    private static func managerHasIt(_ db: Database, _ event: ChatEvent) throws -> Bool {
        guard event.stream.hasPrefix("team:") else { return false }
        return try ChatStore.followsAdmin(db)
    }

    /// The event came in the stream of `account` itself, `member:<org>:<account>`.
    private static func isOwn(_ event: ChatEvent, _ account: String) -> Bool {
        event.stream.hasPrefix("member:") && event.stream.hasSuffix(":\(account)")
    }

    /// Types whose events carry nothing for the cache.
    static let pointers: Set<String> = ["account.membership_changed", "account.session_opened"]

    /// Forward compatibility: later channel features invalidate only their
    /// channel. Malformed *known* events still need the existing full resync.
    static func channelPointer(_ event: ChatEvent) -> String? {
        guard handlers[event.type] == nil, !pointers.contains(event.type),
              !ChatB1.events.contains(event.type), !ChatChannels.eventTypes.contains(event.type), !ChatMessages.eventTypes.contains(event.type),
              !ChatChannelAgents.eventTypes.contains(event.type), !ChatCallStore.eventTypes.contains(event.type),
              let channel = event.body["channel_id"]?.string, !channel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return channel
    }

    /// Applies a type with a handler; false for any other. What this build
    /// does not know is not lost in silence: the cache records it, and the
    /// sync rereads its channel or takes an organization snapshot.
    @discardableResult
    static func apply(_ db: Database, _ event: ChatEvent) throws -> Bool {
        if ChatDMStore.events.contains(event.type) { return try ChatDMStore.apply(db, event) }
        if ChatB1.events.contains(event.type) { return true }
        if ChatChannels.eventTypes.contains(event.type) { return try ChatChannels.apply(db, event) }
        if ChatChannelAgents.reads(event) { return try ChatChannelAgents.apply(db, event) }
        if ChatMessages.eventTypes.contains(event.type) { return try ChatMessages.apply(db, event) }
        if let handler = handlers[event.type] {
            try handler(db, event)
            return true
        }
        return pointers.contains(event.type)
    }
}
