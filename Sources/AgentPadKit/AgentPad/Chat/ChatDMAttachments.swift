import Foundation
import GRDB

extension ChatAttachments {
    static let postCommands: Set<String> = ["message.post_with_attachments", "dm.message.post_with_attachments"]

    static func migrateDM(_ db: Database) throws {
        try db.execute(sql: """
            DROP TRIGGER attachment_draft_removed;
            DROP TRIGGER attachment_channel_deleted;
            DROP TRIGGER attachment_team_revoked;
            ALTER TABLE attachment_drafts RENAME TO attachment_drafts_channel;
            CREATE TABLE attachment_drafts (
                attachment_id TEXT PRIMARY KEY, channel_id TEXT, dm_id TEXT,
                thread_root_id TEXT NOT NULL, body TEXT NOT NULL,
                CHECK ((channel_id IS NOT NULL) + (dm_id IS NOT NULL) = 1));
            INSERT INTO attachment_drafts (attachment_id, channel_id, thread_root_id, body)
                SELECT attachment_id, channel_id, thread_root_id, body FROM attachment_drafts_channel;
            DROP TABLE attachment_drafts_channel;
            CREATE TRIGGER attachment_draft_removed AFTER DELETE ON attachment_drafts BEGIN
                UPDATE drafts SET attachment_selection = (
                    SELECT json_group_array(json(value)) FROM json_each(attachment_selection)
                    WHERE json_extract(value, '$.attachment_id') != OLD.attachment_id
                ), version = lower(hex(randomblob(16)))
                WHERE channel_id = OLD.channel_id AND thread_root_id = OLD.thread_root_id
                    AND EXISTS (SELECT 1 FROM json_each(attachment_selection) WHERE json_extract(value, '$.attachment_id') = OLD.attachment_id);
                UPDATE dm_drafts SET version = lower(hex(randomblob(16)))
                    WHERE dm_id = OLD.dm_id AND root = OLD.thread_root_id;
            END;
            CREATE TRIGGER attachment_channel_deleted AFTER DELETE ON channels
            WHEN (SELECT pending_generation FROM meta WHERE id = 1) IS NULL BEGIN
                DELETE FROM attachment_drafts WHERE channel_id = OLD.channel_id;
            END;
            CREATE TRIGGER attachment_team_revoked AFTER UPDATE OF mine ON teams WHEN OLD.mine = 1 AND NEW.mine = 0 BEGIN
                DELETE FROM attachment_drafts WHERE channel_id IN (SELECT channel_id FROM channels WHERE team_id = NEW.team_id);
            END;
            CREATE TRIGGER attachment_dm_revoked AFTER DELETE ON dm_cards BEGIN
                DELETE FROM attachment_drafts WHERE dm_id = OLD.dm_id;
                UPDATE dm_meta SET epoch = epoch + 1;
            END;
            CREATE TABLE attachment_scope (id INTEGER PRIMARY KEY CHECK (id = 1), body BLOB NOT NULL);
            """)
    }
}

extension ChatFiles {
    /// DM cleanup must include scopes that have not been opened this app lifetime.
    func attachmentScopes(server: ChatServerAddress, account: String) -> Set<ChatOrgKey> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var keys = Set<ChatOrgKey>()
        for url in urls where url.lastPathComponent.hasSuffix(".dm-outbox.json") {
            if let data = try? Data(contentsOf: url), let archive = try? JSONDecoder().decode(ChatDMOutboxArchive.self, from: data),
               let key = archive.scope.key, key.server == server, key.accountId == account, dmOutboxURL(key).standardizedFileURL.path == url.standardizedFileURL.path { keys.insert(key) }
        }
        for url in urls where url.pathExtension == "sqlite" && url.lastPathComponent != "journal.sqlite" {
            var config = Configuration(); config.readonly = true
            guard let queue = try? DatabaseQueue(path: url.path, configuration: config) else { continue }
            defer { try? queue.close() }
            if let data = try? queue.read({ try Data.fetchOne($0, sql: "SELECT body FROM attachment_scope WHERE id = 1") }),
               let ref = try? JSONDecoder().decode(ChatDMRef.self, from: data), let key = ref.key,
               key.server == server, key.accountId == account, cacheURL(key).standardizedFileURL.path == url.standardizedFileURL.path { keys.insert(key) }
        }
        return keys
    }
}
