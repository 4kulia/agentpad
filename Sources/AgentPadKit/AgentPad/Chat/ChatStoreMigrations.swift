import Foundation
import GRDB

/// Schemas of the cache and the run journal (docs/agentpad/CHAT-PLAN.md
/// 6.11, C4). Nothing of either was released before: the schemas start at
/// `release-1`, the state the development builds reached (review C10-3).
/// From here migrations are only ever added, named `release-N`; a file
/// migrated by a newer AgentPad is not opened (`ChatDatabase.open`). A file of
/// a development build (migrations named otherwise) is set aside as
/// `<name>.dev-backup` and made anew.
enum ChatStoreMigrations {
    static let releasePrefix = "release-"

    static var cache: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("release-1") { db in
            try db.create(table: "meta") { t in
                t.column("id", .integer).primaryKey(onConflict: .replace).check { $0 == 1 }
                t.column("generation", .text)
                // A generation change under way, until its queues were marked (review C2-8).
                t.column("pending_generation", .text)
                t.column("org_name", .text)
                t.column("schema", .integer).notNull()
            }
            try db.execute(sql: "INSERT INTO meta (id, generation, schema) VALUES (1, NULL, 1)")
            try db.create(table: "cursors") { t in
                t.primaryKey("stream", .text)
                t.column("seq", .integer).notNull()
            }
            try db.create(table: "members") { t in
                t.primaryKey("account_id", .text)
                t.column("handle", .text).notNull()
                t.column("name", .text).notNull()
                t.column("role", .text).notNull()
            }
            try db.create(table: "teams") { t in
                t.primaryKey("team_id", .text)
                t.column("name", .text).notNull()
                // Local: the team's section is folded in the left panel.
                t.column("collapsed", .boolean).notNull().defaults(to: false)
                t.column("is_general", .boolean).notNull().defaults(to: false)
                t.column("archived_at", .text)
                // The signed-in member is in it.
                t.column("mine", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "team_members") { t in
                t.column("team_id", .text).notNull()
                t.column("account_id", .text).notNull()
                t.primaryKey(["team_id", "account_id"])
            }
            try db.create(table: "invitations") { t in
                t.primaryKey("invitation_id", .text)
                t.column("email", .text).notNull()
                t.column("role", .text).notNull()
                t.column("state", .text).notNull()
                t.column("expires_at", .text)
            }
            try createCommandQueue(db, "outbox")
        }
        // Calls of stage D (D8, 6.12): requests as the server has them, their
        // results, the catalog of agents and the actions `reconcile` owes.
        migrator.registerMigration("release-2") { db in
            try db.create(table: "requests") { t in
                t.primaryKey("request_id", .text)
                // The fixed part (`request.create`) has come; an event of a
                // request not known yet keeps only the changing part.
                t.column("has_fixed", .boolean).notNull().defaults(to: false)
                t.column("kind", .text)
                t.column("agent_id", .text)
                t.column("owner_account_id", .text)
                t.column("initiator_account_id", .text)
                t.column("executor_device_name", .text)
                t.column("text", .text)
                t.column("origin_session", .text)
                t.column("origin_project", .text)
                t.column("thread_id", .text)
                t.column("conditions_version", .integer)
                t.column("deliver_by", .text)
                t.column("created_at", .text)
                // The changing part, taken only from a greater version (6.1).
                t.column("state", .text).notNull()
                t.column("version", .integer).notNull()
                t.column("run_id", .text)
                t.column("decline_reason", .text)
                // Why the server moved it, when it says (D7: `cause`).
                t.column("cause", .text)
                t.column("failure_reason", .text)
                t.column("updated_at", .text)
                // The server generation the changing part belongs to: versions
                // compare only within one (6.1).
                t.column("generation", .text)
                // This session executes it.
                t.column("on_this_device", .boolean).notNull().defaults(to: false)
                // Local: asked from this Mac (its outcome is told here).
                t.column("asked_here", .boolean).notNull().defaults(to: false)
                // Local: the full result text and the run's log, kept over snapshots.
                t.column("local_text", .text)
                // The run the local text and log belong to (review D8f-p3-4).
                t.column("local_run_id", .text)
                t.column("local_log", .text)
                // Local: the agent's name when asked (the request carries only its id).
                t.column("agent_name", .text)
                // Local: the owner's handle, kept once known (the address's second half).
                t.column("owner_handle", .text)
                // Local: cleared from the Team tab, each side on its own (a
                // call to my own agent is both).
                t.column("hidden_incoming", .boolean).notNull().defaults(to: false)
                t.column("hidden_outgoing", .boolean).notNull().defaults(to: false)
            }
            // Events of kinds this build does not know, passed over: kept, and
            // said (review D8f-p3-1).
            try db.create(table: "skipped_events") { t in
                t.column("stream", .text).notNull()
                t.column("seq", .integer).notNull()
                t.column("type", .text).notNull()
                t.column("at", .text)
                t.primaryKey(["stream", "seq"])
            }
            // Conversations an initiator may continue with an agent (C-5).
            try db.create(table: "threads") { t in
                t.primaryKey("thread_id", .text)
                t.column("peer", .text).notNull()
                t.column("agent_id", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "results") { t in
                t.primaryKey("run_id", .text)
                t.column("request_id", .text).notNull().indexed()
                t.column("text", .text).notNull()
                // History let go of the text; the delivery is still known.
                t.column("trimmed", .boolean).notNull().defaults(to: false)
                t.column("truncated", .boolean).notNull()
                t.column("thread_id", .text)
                t.column("delivered_at", .text)
            }
            try db.create(table: "agents_catalog") { t in
                t.primaryKey("agent_id", .text)
                t.column("owner_account_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("description", .text).notNull()
                t.column("access", .text).notNull()
                t.column("enabled", .boolean).notNull()
                t.column("executor_session_id", .text)
                t.column("executor_device_name", .text)
                t.column("available", .boolean).notNull()
            }
            // The followed team streams that brought each agent.
            try db.create(table: "agent_teams") { t in
                t.column("agent_id", .text).notNull()
                t.column("team_id", .text).notNull()
                // The card as this team's stream last told it: at its `seq` in
                // the stream, and the order it was applied in here — the
                // catalog shows the last applied (review D8g-p2-7).
                t.column("card", .text)
                t.column("seq", .integer).notNull().defaults(to: 0)
                t.column("applied", .integer).notNull().defaults(to: 0)
                t.primaryKey(["agent_id", "team_id"])
            }
            try db.create(table: "actions") { t in
                t.column("request_id", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("state", .text).notNull()
                t.column("error", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.primaryKey(["request_id", "kind"])
            }
            // This file's identity: a cache deleted and made anew at the same
            // path is another one (review D8h-p2-2).
            try db.alter(table: "meta") { t in t.add(column: "instance", .text) }
            try db.execute(sql: "UPDATE meta SET instance = lower(hex(randomblob(16))) WHERE id = 1")
        }
        // C6: the user's rights are in doubt — a sign said they may have
        // changed, and no snapshot read since was applied. Kept across
        // launches: only the server's snapshot ends it (review C6f). With it,
        // the session whose snapshot last confirmed them: rights count
        // only for that session — a new sign-in, even in the same run, starts
        // in doubt until a snapshot of its own (review C6i). One migration:
        // nothing of these schemas was released.
        migrator.registerMigration("release-3") { db in
            try db.alter(table: "meta") { t in
                t.add(column: "rights_in_doubt", .boolean).notNull().defaults(to: false)
                t.add(column: "rights_session", .text)
            }
        }
        // A refusal the user has read is marked apart from its code: hiding
        // it changes nothing of what is owed (review D4c-p2-2).
        migrator.registerMigration("release-4") { db in try addDismissed(db, "outbox") }
        // Channel cards (F2). `stamp`: the number of the card's last write,
        // from `meta.channel_stamp`; a read of the snapshot drops only the
        // cards of its starting slice. `channels_served`: the last snapshot
        // carried channels. `channels_read_open`: a read of them is under way,
        // or was cut off — what is missing then is not "gone".
        migrator.registerMigration("release-5") { db in
            try db.create(table: "channels") { t in
                t.primaryKey("channel_id", .text)
                t.column("team_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("created_by", .text)
                t.column("created_at", .text)
                t.column("archived", .boolean).notNull().defaults(to: false)
                t.column("archived_at", .text)
                t.column("version", .integer).notNull()
                t.column("stamp", .integer).notNull()
            }
            try db.alter(table: "meta") { t in
                t.add(column: "channel_stamp", .integer).notNull().defaults(to: 0)
                t.add(column: "channels_served", .boolean).notNull().defaults(to: false)
                t.add(column: "channels_read_open", .boolean).notNull().defaults(to: false)
            }
        }
        // Messages (F3). `has_fixed` / `has_mutable`: the server's parts are
        // in (a frame without its message leaves a placeholder); `stale`: a
        // greater revision is known; `local_state`: sending or failed here.
        migrator.registerMigration("release-6") { db in
            try db.create(table: "messages") { t in
                t.primaryKey("message_id", .text)
                t.column("channel_id", .text).notNull()
                t.column("thread_root_id", .text)
                t.column("author_account_id", .text)
                t.column("seq", .integer)
                t.column("created_at", .text)
                t.column("has_fixed", .boolean).notNull().defaults(to: false)
                t.column("has_mutable", .boolean).notNull().defaults(to: false)
                t.column("text", .text)
                t.column("mentions", .text)
                t.column("revision", .integer).notNull().defaults(to: 0)
                t.column("edited_at", .text)
                t.column("deleted_at", .text)
                t.column("stale", .integer)
                t.column("local_state", .text)
                t.column("local_error", .text)

            }
            try db.create(index: "messages_feed", on: "messages", columns: ["channel_id", "thread_root_id", "seq"])
            try db.create(index: "messages_channel", on: "messages", columns: ["channel_id", "seq"])
            try db.create(table: "channel_windows") { t in
                t.primaryKey("channel_id", .text)
                t.column("epoch", .integer).notNull()
                t.column("bottom_seq", .integer).notNull()
                t.column("history_next", .integer)
            }
            try db.create(table: "thread_cursors") { t in
                t.column("channel_id", .text).notNull()
                t.column("root_id", .text).notNull()
                t.column("epoch", .integer).notNull()
                t.column("next", .integer)
                // The oldest reply of the pages read: the thread shows from it.
                t.column("shown_from", .integer)
                t.primaryKey(["channel_id", "root_id"])
            }
            // An edit or deletion of the user's own message not settled yet —
            // apart from the message, so no window or page takes it (review
            // F3c): `saving` while its command is in the queue, `failed` with
            // the server's word (or the queue's) and the text kept.
            try db.create(table: "local_edits") { t in
                t.primaryKey("message_id", .text)
                t.column("channel_id", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("text", .text)
                t.column("command_id", .text).notNull()
                t.column("state", .text).notNull()
                t.column("error", .text)
            }
            try db.create(table: "drafts") { t in
                t.column("channel_id", .text).notNull()
                t.column("thread_root_id", .text).notNull()
                t.column("text", .text).notNull()
                t.column("updated_at", .double).notNull()
                t.primaryKey(["channel_id", "thread_root_id"])
            }
        }
        // Unread and notices (F4). `read_marks`: how far each channel is read
        // here, and whether its thread replies are muted; `notified`: one
        // notice per message or request, ever (per server generation);
        // `my_threads`: threads the user wrote in, kept past the window.
        migrator.registerMigration("release-7") { db in
            try db.create(table: "read_marks") { t in
                t.primaryKey("channel_id", .text)
                t.column("last_read_seq", .integer).notNull().defaults(to: 0)
                t.column("muted", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "notified") { t in
                t.primaryKey("object_id", .text)
                t.column("kind", .text).notNull()
                t.column("channel_id", .text)
                t.column("seq", .integer)
                t.column("read", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "my_threads") { t in
                t.column("channel_id", .text).notNull()
                t.column("root_id", .text).notNull()
                t.primaryKey(["channel_id", "root_id"])
            }
            // Whose cache it is: the triggers below keep the threads the user
            // wrote in, whatever wrote the message — event, page, window or a
            // post from here (review F4-2).
            try db.alter(table: "meta") { t in t.add(column: "me", .text) }
            for (name, when) in [("my_threads_insert", "AFTER INSERT ON messages"),
                                 ("my_threads_update", "AFTER UPDATE OF author_account_id, thread_root_id, channel_id ON messages")] {
                try db.execute(sql: """
                    CREATE TRIGGER \(name) \(when)
                    WHEN NEW.author_account_id IS NOT NULL AND NEW.author_account_id = (SELECT me FROM meta WHERE id = 1)
                    BEGIN
                        INSERT OR IGNORE INTO my_threads (channel_id, root_id) VALUES (NEW.channel_id, IFNULL(NEW.thread_root_id, NEW.message_id));
                    END
                    """)
            }
        }
        // An agent in a channel (F5). `agent_channels`: the agents of the
        // channels kept, each with its card as the channel's stream tells it
        // (not the personal catalog: a member knows the agents of its
        // channels whatever their audience); a channel's request and an
        // agent's message keep where they belong.
        migrator.registerMigration("release-8") { db in
            try db.create(table: "agent_channels") { t in
                t.column("channel_id", .text).notNull()
                t.column("agent_id", .text).notNull()
                t.column("added_by", .text)
                t.column("added_at", .text)
                t.column("name", .text).notNull()
                t.column("owner_account_id", .text).notNull()
                t.column("description", .text)
                t.column("access", .text)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("available", .boolean).notNull().defaults(to: false)
                t.column("executor_device_name", .text)
                t.primaryKey(["channel_id", "agent_id"])
            }
            try db.alter(table: "requests") { t in
                t.add(column: "channel_id", .text)
                t.add(column: "thread_root_id", .text)
                t.add(column: "publication", .text)
                t.add(column: "publish_reason", .text)
            }
            try db.alter(table: "messages") { t in
                t.add(column: "author_agent_id", .text)
                t.add(column: "run_id", .text)
            }
            // The last snapshot carried the agents of channels: the server has them.
            try db.alter(table: "meta") { t in t.add(column: "agents_served", .boolean).notNull().defaults(to: false) }
        }
        // F5: verified channel content and an authority epoch. A revoke followed
        // by a rejoin still invalidates an HTTP response issued before the revoke.
        migrator.registerMigration("release-9") { db in
            try db.alter(table: "requests") { t in t.add(column: "context_refs", .text) }
            try db.alter(table: "meta") { t in t.add(column: "channel_access_epoch", .integer).notNull().defaults(to: 0) }
            try db.create(table: "request_contents") { t in
                t.primaryKey("request_id", .text)
                t.column("channel_id", .text).notNull()
                t.column("session_id", .text).notNull()
                t.column("generation", .text).notNull()
                t.column("epoch", .integer).notNull()
                t.column("content", .text).notNull()
            }
            for (table, events) in [("channels", ["DELETE"]), ("teams", ["INSERT", "UPDATE", "DELETE"]),
                                    ("team_members", ["INSERT", "DELETE"])] {
                for event in events {
                    try db.execute(sql: """
                        CREATE TRIGGER channel_access_\(table)_\(event) AFTER \(event) ON \(table) BEGIN
                            UPDATE meta SET channel_access_epoch = channel_access_epoch + 1 WHERE id = 1;
                        END
                        """)
                }
            }
            try db.execute(sql: """
                CREATE TRIGGER channel_access_meta AFTER UPDATE OF rights_in_doubt, rights_session, generation, pending_generation ON meta
                WHEN OLD.rights_in_doubt IS NOT NEW.rights_in_doubt OR OLD.rights_session IS NOT NEW.rights_session
                    OR OLD.generation IS NOT NEW.generation OR OLD.pending_generation IS NOT NEW.pending_generation
                BEGIN UPDATE meta SET channel_access_epoch = channel_access_epoch + 1 WHERE id = 1; END
                """)
        }
        migrator.registerMigration("release-10") { db in
            try db.create(table: "publication_intents") { t in
                t.primaryKey("run_id", .text)
                t.column("command_id", .text).notNull()
            }
            // Upgrade existing decisions in their original order: the last
            // owner decision is the only command allowed to send.
            for command in try ChatCommandRecord.fetchAll(db, sql: "SELECT * FROM outbox WHERE type IN ('result.publish', 'result.withhold') ORDER BY seq, rowid") {
                guard let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: command.bodyBytes),
                      let run = envelope.args["run_id"]?.string else { continue }
                try db.execute(sql: "INSERT OR REPLACE INTO publication_intents (run_id, command_id) VALUES (?, ?)", arguments: [run, command.commandId])
            }
            try db.execute(sql: """
                DELETE FROM outbox WHERE type IN ('result.publish', 'result.withhold') AND state != 'sent'
                    AND command_id NOT IN (SELECT command_id FROM publication_intents)
                """)
            // Window eviction and channel cleanup must not leave a second
            // copy of a message in the pre-approval content cache.
            try db.execute(sql: """
                CREATE TRIGGER request_content_message_delete AFTER DELETE ON messages BEGIN
                    DELETE FROM request_contents WHERE channel_id = OLD.channel_id;
                    UPDATE meta SET channel_access_epoch = channel_access_epoch + 1 WHERE id = 1;
                END
                """)
        }
        migrator.registerMigration("release-11") { db in
            try db.alter(table: "publication_intents") { t in t.add(column: "send_started_at", .datetime) }
            // Earlier clients did not distinguish a lost answer from a send
            // not yet begun. Keep existing pending decisions locked on upgrade;
            // the same-id retry will resolve them, including a crash during HTTP.
            try db.execute(sql: """
                UPDATE publication_intents SET send_started_at = CURRENT_TIMESTAMP
                WHERE command_id IN (SELECT command_id FROM outbox WHERE state = 'pending')
                """)
        }
        migrator.registerMigration("release-12-ux1") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "author_agent_name", .text)
                t.add(column: "author_session_name", .text)
                t.add(column: "in_reply_to_message_id", .text)
            }
            try db.alter(table: "requests") { t in
                for name in ["source_message_id", "reply_mode", "requested_policy_id", "decision_basis", "decision_policy_id"] {
                    t.add(column: name, .text)
                }
                t.add(column: "source_revision", .integer)
            }
            try db.alter(table: "agent_channels") { t in
                t.add(column: "executor_session_id", .text)
                t.add(column: "trust", .text)
            }
            // A draft version is shared by every composer of this scope.
            try db.alter(table: "drafts") { t in t.add(column: "version", .text) }
            try db.execute(sql: "UPDATE drafts SET version = lower(hex(randomblob(16)))")
            try db.create(table: "channel_sends") { t in
                t.primaryKey("draft_version", .text)
                t.column("channel_id", .text).notNull()
                t.column("thread_root_id", .text)
                t.column("message_id", .text).notNull().unique()
                t.column("command_id", .text).notNull()
            }
            try db.create(table: "channel_call_intents") { t in
                t.primaryKey("request_id", .text)
                t.column("message_id", .text).notNull()
                t.column("agent_id", .text).notNull()
                t.column("command_id", .text).notNull()
                t.column("cancelled", .boolean).notNull().defaults(to: false)
                t.column("send_started_at", .datetime)
                t.uniqueKey(["message_id", "agent_id"])
            }
            try db.create(table: "session_posts") { t in
                t.primaryKey("message_id", .text)
                t.column("command_id", .text).notNull()
                t.column("provenance", .text).notNull()
                t.column("generation", .text).notNull()
                t.column("session_id", .text).notNull()
                t.column("result", .text)
                t.column("retry_after", .integer)
            }
        }
        migrator.registerMigration("release-13-ux1-review") { db in
            // Older intents have no witness of a fresh manual decision. Keep
            // them revocable when their run's automatic consent is revoked.
            try db.alter(table: "publication_intents") { t in
                t.add(column: "automatic", .boolean).notNull().defaults(to: true)
            }
        }
        return migrator
    }

    static var journal: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("release-1") { db in
            try db.create(table: "meta") { t in
                t.column("id", .integer).primaryKey(onConflict: .replace).check { $0 == 1 }
                t.column("schema", .integer).notNull()
            }
            try db.execute(sql: "INSERT INTO meta (id, schema) VALUES (1, 1)")
            try createCommandQueue(db, "run_commands") { t in
                // Every row carries its (server, account, organization).
                t.column("server", .text).notNull()
                t.column("account_id", .text).notNull()
                t.column("org_id", .text).notNull()
                // The full result, kept until delivered and after.
                t.column("result_text", .text)
            }
            // The executor's promises (6.8, D9): what the owner published here,
            // what the owner allowed, and what ran.
            try db.create(table: "assignments") { t in
                t.column("server", .text).notNull()
                t.column("account_id", .text).notNull()
                t.column("org_id", .text).notNull()
                t.column("agent_id", .text).notNull()
                t.column("state", .text).notNull()
                t.column("name", .text).notNull()
                t.column("description", .text).notNull()
                t.column("access", .text).notNull()
                t.column("team_ids", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.primaryKey(["server", "account_id", "org_id", "agent_id"])
            }
            try db.create(table: "approvals") { t in
                t.primaryKey("id", .text)
                t.column("server", .text).notNull()
                t.column("account_id", .text).notNull()
                t.column("org_id", .text).notNull()
                t.column("request_id", .text).notNull()
                t.column("agent_id", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("params", .text).notNull()
                t.column("params_hash", .text).notNull()
                t.column("run_id", .text).notNull().unique()
                t.column("start_command_id", .text).notNull()
                t.column("generation", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("consumed_at", .datetime)
                t.column("void_at", .datetime)
                t.column("void_reason", .text)
                // One per request of one organization of one account on one server (review C6-9).
                t.uniqueKey(["server", "account_id", "org_id", "request_id", "kind"])
            }
            try db.create(table: "runs") { t in
                t.primaryKey("run_id", .text)
                t.column("request_id", .text).notNull()
                t.column("approval_id", .text).notNull().references("approvals")
                t.column("agent_id", .text).notNull()
                t.column("conversation_id", .text).notNull()
                t.column("pid", .integer)
                t.column("pgid", .integer)
                t.column("process_started_at", .integer)
                t.column("started_at", .datetime).notNull()
                t.column("ended_at", .datetime)
                t.column("outcome", .text)
                // Why a run was being stopped when the app could not wait for it (quit).
                t.column("stop_reason", .text)
                // When its processes were confirmed gone (review C6-6).
                t.column("processes_gone_at", .datetime)
            }
            // The server generation each organization's commands belong to, and
            // a change of it under way (review C3-4).
            try db.create(table: "org_generations") { t in
                t.column("server", .text).notNull()
                t.column("account_id", .text).notNull()
                t.column("org_id", .text).notNull()
                t.column("generation", .text)
                t.column("pending_generation", .text)
                t.primaryKey(["server", "account_id", "org_id"])
            }
        }
        // Publishing from the client (D3): what the server accepted and what
        // is asked of it now; the assignment is the source of truth.
        migrator.registerMigration("release-2") { db in
            try db.alter(table: "assignments") { t in
                // The session the server took the last `agent.publish` from (the executor).
                t.add(column: "published_session", .text)
                // A publication asked and not settled yet: its parameters (JSON) and when.
                t.add(column: "requested", .text)
                t.add(column: "requested_at", .datetime)
                // The server's last refusal, until the owner publishes again.
                t.add(column: "last_error", .text)
            }
        }
        // The owner's side (D4): a run's full result, kept with its outcome,
        // until delivered and after — shown here when not delivered.
        migrator.registerMigration("release-3") { db in
            try db.alter(table: "runs") { t in t.add(column: "result_text", .text) }
        }
        migrator.registerMigration("release-4") { db in try addDismissed(db, "run_commands") }
        // D3b: where each team's stream stood when the server took the last
        // publication (`{team: seq}`): an `agent.unpublish` of that team at or
        // before it is older than the publication (DESIGN-D3b-D4b-D5b §11.3).
        migrator.registerMigration("release-5") { db in
            try db.alter(table: "assignments") { t in t.add(column: "team_seqs", .text) }
        }
        // Y5: the automatic stop verdict survives retries and recovery.
        // Older rows and the owner's confirmation remain unconfirmed.
        migrator.registerMigration("release-6") { db in
            try db.alter(table: "runs") { t in t.add(column: "stop_confirmed_at", .datetime) }
        }
        migrator.registerMigration("release-7") { db in
            try db.alter(table: "runs") { t in
                t.add(column: "preflight_pid", .integer)
                t.add(column: "preflight_pgid", .integer)
                t.add(column: "preflight_started_at", .integer)
            }
        }
        migrator.registerMigration("release-8") { db in
            // The channel branch also shipped development migrations 6–7.
            // Their numbers are already recorded in those journals, so add
            // Y5/Y2's missing evidence here and keep existing channel data.
            let columns = Set(try db.columns(in: "runs").map(\.name))
            try db.alter(table: "runs") { t in
                if !columns.contains("stop_confirmed_at") { t.add(column: "stop_confirmed_at", .datetime) }
                if !columns.contains("preflight_pid") { t.add(column: "preflight_pid", .integer) }
                if !columns.contains("preflight_pgid") { t.add(column: "preflight_pgid", .integer) }
                if !columns.contains("preflight_started_at") { t.add(column: "preflight_started_at", .integer) }
                if !columns.contains("kind") { t.add(column: "kind", .text) }
                if !columns.contains("org") { t.add(column: "org", .text) }
                if !columns.contains("channel_id") { t.add(column: "channel_id", .text) }
                if !columns.contains("thread_root_id") { t.add(column: "thread_root_id", .text) }
                if !columns.contains("result_erased") { t.add(column: "result_erased", .boolean).notNull().defaults(to: false) }
            }
            // Earlier journal rows keep their identity, including approvals
            // made by a build that already knew the channel parameters.
            if !columns.contains("kind") {
                try db.execute(sql: """
                    UPDATE runs SET org = (SELECT org_id FROM approvals WHERE id = runs.approval_id),
                        channel_id = (SELECT json_extract(params, '$.channelId') FROM approvals WHERE id = runs.approval_id),
                        thread_root_id = (SELECT json_extract(params, '$.threadRootId') FROM approvals WHERE id = runs.approval_id)
                    """)
                try db.execute(sql: "UPDATE runs SET kind = CASE WHEN channel_id IS NULL THEN 'personal' ELSE 'channel' END")
            }
        }
        migrator.registerMigration("release-9") { db in
            // A cancelled request can share a transcript with other requests.
            // Only confirmed channel revocation authorizes transcript erasure.
            // Legacy result_erased values cannot distinguish these causes.
            if try !db.columns(in: "runs").contains(where: { $0.name == "channel_revoked" }) {
                try db.alter(table: "runs") { t in
                    t.add(column: "channel_revoked", .boolean).notNull().defaults(to: false)
                }
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS runs_conversation ON runs (conversation_id)")
        }
        migrator.registerMigration("release-10-ux1") { db in
            try db.create(table: "automatic_request_blocks") { t in
                t.column("server", .text).notNull()
                t.column("account_id", .text).notNull()
                t.column("org_id", .text).notNull()
                t.column("request_id", .text).notNull()
                t.primaryKey(["server", "account_id", "org_id", "request_id"])
            }
            // Authority exists only here. A server snapshot cannot rebuild it.
            try db.create(table: "channel_authorities") { t in
                t.primaryKey("id", .text)
                t.column("server", .text).notNull()
                t.column("account_id", .text).notNull()
                t.column("org_id", .text).notNull()
                t.column("channel_id", .text).notNull()
                t.column("agent_id", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("body", .text).notNull()
                t.column("revoked", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "publication_surfaces") { t in
                t.column("server", .text).notNull()
                t.column("account_id", .text).notNull()
                t.column("org_id", .text).notNull()
                t.column("agent_id", .text).notNull()
                t.column("surface_id", .text).notNull()
                t.column("session_id", .text).notNull()
                t.column("generation", .text).notNull()
                t.primaryKey(["server", "account_id", "org_id", "agent_id"])
            }
        }
        return migrator
    }

    private static func addDismissed(_ db: Database, _ table: String) throws {
        try db.alter(table: table) { t in t.add(column: "dismissed", .boolean).notNull().defaults(to: false) }
        try db.execute(sql: "UPDATE \(table) SET dismissed = 1 WHERE error = 'dismissed'")
    }

    /// One send queue's shape: the body as the exact bytes sent (a repeat
    /// sends them again, so the server's body hash matches).
    private static func createCommandQueue(_ db: Database, _ name: String, extra: (TableDefinition) -> Void = { _ in }) throws {
        try db.create(table: name) { t in
            t.primaryKey("command_id", .text)
            t.column("session_id", .text).notNull()
            t.column("type", .text).notNull()
            t.column("body_bytes", .blob).notNull()
            t.column("order_key", .text).notNull()
            t.column("depends_on", .text)
            t.column("created_at", .datetime).notNull()
            t.column("state", .text).notNull()
            t.column("error", .text)
            t.column("attempts", .integer).notNull().defaults(to: 0)
            t.column("next_attempt_at", .datetime)
            // A place in the queue that only grows (review C-7).
            t.column("seq", .integer).notNull().defaults(to: 0)
            // The server generation that accepted it (review C4-7).
            t.column("sent_generation", .text)
            extra(t)
        }
        try db.create(index: "\(name)_order", on: name, columns: ["order_key", "created_at"])
    }
}
