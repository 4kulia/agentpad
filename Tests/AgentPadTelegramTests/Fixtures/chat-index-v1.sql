-- Schema copied from the 1.2.1 implementation at 96dc29b; no version checkpoint.
                CREATE TABLE IF NOT EXISTS chats (
                    id INTEGER PRIMARY KEY, title TEXT NOT NULL DEFAULT '', username TEXT NOT NULL DEFAULT '',
                    kind TEXT NOT NULL DEFAULT 'unknown', userID INTEGER NOT NULL DEFAULT 0, groupID INTEGER NOT NULL DEFAULT 0,
                    mainOrder INTEGER NOT NULL DEFAULT 0, archiveOrder INTEGER NOT NULL DEFAULT 0,
                    lastDate INTEGER NOT NULL DEFAULT 0, recentDate INTEGER NOT NULL DEFAULT 0,
                    candidateDate INTEGER NOT NULL DEFAULT 0, candidateSender INTEGER NOT NULL DEFAULT 0,
                    unread INTEGER NOT NULL DEFAULT 0, mentions INTEGER NOT NULL DEFAULT 0,
                    pinOrder INTEGER, hidden INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX IF NOT EXISTS chat_user ON chats(userID);
                CREATE INDEX IF NOT EXISTS chat_group ON chats(groupID);
                CREATE TABLE IF NOT EXISTS entities (id INTEGER, family TEXT, title TEXT, username TEXT, kind TEXT, PRIMARY KEY(id, family));
                CREATE TABLE IF NOT EXISTS checkpoint (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS chat_order (position INTEGER PRIMARY KEY, chat INTEGER UNIQUE);
                CREATE TABLE IF NOT EXISTS recently_opened (chat INTEGER PRIMARY KEY, opened INTEGER);
                DELETE FROM chat_order;
                CREATE TABLE IF NOT EXISTS tg_state (
                  chat INTEGER PRIMARY KEY, inbox INTEGER NOT NULL DEFAULT 0, lastMessage INTEGER NOT NULL DEFAULT 0,
                  snooze INTEGER NOT NULL DEFAULT 0, previousSnooze INTEGER NOT NULL DEFAULT 0,
                  channelEnabled INTEGER NOT NULL DEFAULT 0, activation INTEGER NOT NULL DEFAULT 0,
                  generation TEXT NOT NULL DEFAULT '', episode TEXT, complete INTEGER NOT NULL DEFAULT 0,
                  signature TEXT NOT NULL DEFAULT '', checked TEXT NOT NULL DEFAULT '', fresh TEXT NOT NULL DEFAULT '', activationRequested INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS tg_messages (
                  chat INTEGER, id INTEGER, topic TEXT NOT NULL, date INTEGER NOT NULL, sender INTEGER NOT NULL,
                  mentioned INTEGER NOT NULL, unreadMention INTEGER NOT NULL, replyChat INTEGER NOT NULL,
                  replyID INTEGER NOT NULL, replyToMe INTEGER, viewed INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY(chat,id));
                CREATE INDEX IF NOT EXISTS tg_messages_topic ON tg_messages(chat,topic,id);
                CREATE TABLE IF NOT EXISTS tg_receipts (chat INTEGER, id INTEGER, mentionRead INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(chat,id));
                CREATE TABLE IF NOT EXISTS tg_scan_seen (chat INTEGER,id INTEGER,version TEXT,PRIMARY KEY(chat,id));
                CREATE TABLE IF NOT EXISTS tg_settings (
                  chat INTEGER, topic TEXT, muteUntil INTEGER, disableMention INTEGER, inbox INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY(chat,topic));
                CREATE TABLE IF NOT EXISTS tg_scopes (scope TEXT PRIMARY KEY, muteUntil INTEGER NOT NULL, disableMention INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS tg_work (
                  key TEXT PRIMARY KEY, method TEXT NOT NULL, chat INTEGER NOT NULL, topic TEXT NOT NULL DEFAULT '',
                  message INTEGER NOT NULL DEFAULT 0, cursor INTEGER NOT NULL DEFAULT 0, pageSize INTEGER NOT NULL DEFAULT 50,
                  lane INTEGER NOT NULL, age INTEGER NOT NULL, retry INTEGER NOT NULL DEFAULT 0, version TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS tg_reason_messages (chat INTEGER, id INTEGER, topic TEXT, date INTEGER, kind TEXT, viewed INTEGER, PRIMARY KEY(chat,id));
                CREATE INDEX IF NOT EXISTS tg_reason_chat ON tg_reason_messages(chat,topic,id);
                CREATE VIEW IF NOT EXISTS tg_channel_pending AS
                  SELECT s.chat FROM tg_state s JOIN chats c ON c.id=s.chat
                  LEFT JOIN tg_settings cs ON cs.chat=s.chat AND cs.topic=''
                  LEFT JOIN tg_scopes sc ON sc.scope='notificationSettingsScopeChannelChats'
                  WHERE s.episode IS NOT NULL AND s.complete=0 AND s.channelEnabled=1 AND c.hidden=0 AND c.pinOrder IS NOT NULL
                    AND coalesce(cs.muteUntil,sc.muteUntil,9223372036854775807) <= coalesce((SELECT value FROM checkpoint WHERE key='attentionNow'),0);
                CREATE TABLE IF NOT EXISTS tg_notification_groups (id INTEGER PRIMARY KEY, type TEXT, chat INTEGER, settingsChat INTEGER, sound INTEGER);
                CREATE TABLE IF NOT EXISTS tg_notifications (groupID INTEGER, id INTEGER, chat INTEGER, message INTEGER, date INTEGER, silent INTEGER, fresh INTEGER,
                  PRIMARY KEY(groupID,id));
                CREATE TABLE IF NOT EXISTS tg_notification_seen (groupID INTEGER, id INTEGER, PRIMARY KEY(groupID,id));
                CREATE TABLE IF NOT EXISTS tg_notification_consumed (id TEXT PRIMARY KEY);
                DELETE FROM tg_notification_groups; DELETE FROM tg_notifications;
                DELETE FROM checkpoint WHERE key='notificationRetired';

ALTER TABLE tg_messages ADD COLUMN senderIsChat INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tg_state ADD COLUMN notifiedEpisode TEXT;
ALTER TABLE tg_notification_seen ADD COLUMN date INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tg_notification_consumed ADD COLUMN date INTEGER NOT NULL DEFAULT 0;
