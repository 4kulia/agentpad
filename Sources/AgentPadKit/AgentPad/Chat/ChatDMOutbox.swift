import Foundation
import GRDB
import SwiftUI

/// A first message is one outbox row. Until dm.open resolves it, its durable
/// address is peer_account_id. Metadata is never sent in the wire command.
@MainActor enum ChatDMFirstSend {
    static func request(_ record: ChatCommandRecord) throws -> ChatCommandEnvelope? {
        guard record.type == "dm.message.post" else { return nil }
        let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes)
        guard let peer = envelope.args["peer_account_id"]?.string else { return nil }
        if envelope.args["dm_id"]?.string == nil {
            guard let open = envelope.args["open_command_id"]?.string else { throw ChatError.storage("The direct message has no opening command.") }
            return .init(commandId: open, org: envelope.org, type: "dm.open", args: .object(["peer_account_id": .string(peer)]))
        }
        var args = ChatService.args(record)
        args["peer_account_id"] = nil; args["open_command_id"] = nil
        return .init(commandId: record.commandId, org: envelope.org, type: record.type, args: .object(args))
    }

    /// Persist the next step before any post can run. Disconnect or a lost
    /// response can replay either step with the same command/message IDs.
    static func opened(_ record: ChatCommandRecord, dm: String, in queue: ChatCommandTable) throws -> Bool {
        let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes)
        var args = ChatService.args(record); args["dm_id"] = .string(dm)
        let bytes = try ChatCommandEnvelope(commandId: record.commandId, org: envelope.org, type: record.type, args: .object(args)).encoded()
        return try queue.queue.write { db in
            try db.execute(sql: "UPDATE outbox SET body_bytes = ?, attempts = 0, next_attempt_at = NULL, error = NULL WHERE command_id = ? AND state = 'pending' AND body_bytes = ?",
                           arguments: [bytes, record.commandId, record.bodyBytes])
            guard db.changesCount == 1 else { return false }
            try db.execute(sql: "UPDATE dm_sends SET dm_id = ? WHERE message_id = ?", arguments: [dm, args["message_id"]?.string])
            if let me = try String.fetchOne(db, sql: "SELECT me FROM meta WHERE id = 1") {
                try ChatDMStore.restoreOutgoing(db, dm: dm, me: me, opened: true)
            }
            return true
        }
    }
}

/// Own outgoing commands and local file-bearing drafts, never received messages,
/// cards or peer names. These survive disconnect while the org cache is removed.
struct ChatDMOutboxArchive: Codable {
    var scope: ChatDMRef
    var commands: [ChatCommandRecord]
    struct Draft: Codable { var dm: String; var root: String; var text: String; var version: String }
    var attachments: [ChatAttachmentDraft]? = nil
    var drafts: [Draft]? = nil
    var count: Int { Set(commands.filter { ["dm.message.post", "dm.message.post_with_attachments"].contains($0.type) && $0.state != .sent }.compactMap { record -> String? in
        guard let args = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes).args,
              let id = args["message_id"]?.string else { return nil }
        return (args["peer_account_id"]?.string ?? args["dm_id"]?.string ?? "") + ":" + id
    }).count }
}

extension ChatFiles {
    func dmOutboxURL(_ key: ChatOrgKey) -> URL { directory.appendingPathComponent(key.cacheFileName + ".dm-outbox.json") }
    func savedDMOutbox(_ key: ChatOrgKey) throws -> ChatDMOutboxArchive? {
        let url = dmOutboxURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let archive = try JSONDecoder().decode(ChatDMOutboxArchive.self, from: Data(contentsOf: url))
        guard archive.scope.belongs(to: key) else { throw ChatError.storage("The saved direct-message queue belongs to another connection.") }
        return archive
    }
    func saveDMOutbox(_ key: ChatOrgKey, store: ChatStore?, preservingFiles: Bool = true) throws {
        let readCommands: (Database) throws -> ([ChatCommandRecord], [ChatAttachmentDraft], [ChatDMOutboxArchive.Draft]) = { db in
            let commands = try ChatCommandRecord.fetchAll(db, sql: "SELECT * FROM outbox WHERE type LIKE 'dm.%' ORDER BY seq")
            guard preservingFiles, try db.columns(in: "attachment_drafts").contains(where: { $0.name == "dm_id" }) else { return (commands, [], []) }
            let files = try ChatAttachments.drafts(db, includingQueued: true).filter { $0.owner.dmID != nil }
            let drafts = try Row.fetchAll(db, sql: "SELECT * FROM dm_drafts").map {
                ChatDMOutboxArchive.Draft(dm: $0["dm_id"], root: $0["root"], text: $0["text"], version: $0["version"])
            }
            return (commands, files, drafts.filter { draft in files.contains { $0.owner == .dm(draft.dm) && $0.root == draft.root && $0.queued != true } })
        }
        let snapshot: ([ChatCommandRecord], [ChatAttachmentDraft], [ChatDMOutboxArchive.Draft])
        if let store {
            snapshot = try store.dmRead(readCommands)
        } else if FileManager.default.fileExists(atPath: cacheURL(key).path) {
            // A revoked session never opens its cache. Read its queue without
            // migrations or recovery that could replace an unreadable file.
            var config = Configuration(); config.readonly = true
            let cache = try DatabaseQueue(path: cacheURL(key).path, configuration: config)
            defer { try? cache.close() }
            snapshot = try cache.read(readCommands)
        } else {
            if !preservingFiles, var archive = try savedDMOutbox(key) {
                archive.attachments = nil; archive.drafts = nil
                try writePrivate(JSONEncoder().encode(archive), to: dmOutboxURL(key))
                try? FileManager.default.removeItem(at: attachmentStorage.directory(key))
            }
            return // No cache: any previously saved archive is already safe.
        }
        let commands = snapshot.0
        func address(_ command: ChatCommandRecord) -> String {
            let args = (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: command.bodyBytes).args) ?? .object([:])
            return command.type + ":" + (args["peer_account_id"]?.string ?? args["dm_id"]?.string ?? "") + ":" + (args["message_id"]?.string ?? command.commandId)
        }
        let finished = Set(commands.filter { !$0.isSessionDM && ($0.state == .sent || $0.error == "dismissed") }.map(address))
        var saved = Dictionary(uniqueKeysWithValues: (try savedDMOutbox(key)?.commands ?? []).map { ($0.commandId, $0) })
        for command in commands where command.isSessionDM || (command.state != .sent && command.error != "dismissed") { saved[command.commandId] = command }
        var latest: [String: ChatCommandRecord] = [:]
        for command in saved.values.sorted(by: { $0.seq < $1.seq }) where !finished.contains(address(command)) {
            latest[address(command)] = command
        }
        let remaining = latest.values.sorted { $0.seq < $1.seq }
        // An empty archive also remembers that this connection was explicitly
        // closed, so the offline row says Reconnect and truthfully shows zero.
        try writePrivate(JSONEncoder().encode(ChatDMOutboxArchive(scope: ChatDMRef(key, dm: ""), commands: remaining, attachments: snapshot.1, drafts: snapshot.2)), to: dmOutboxURL(key))
    }
    func restoreDMOutbox(_ key: ChatOrgKey, store: ChatStore) throws {
        guard let archive = try savedDMOutbox(key) else { return }
        try store.dmWrite { db in
            for file in archive.attachments ?? [] {
                guard file.owner.dmID != nil else { continue }
                try ChatAttachments.put(db, file)
            }
            for draft in archive.drafts ?? [] {
                try db.execute(sql: "INSERT OR IGNORE INTO dm_drafts (dm_id, root, text, version) VALUES (?, ?, ?, ?)", arguments: [draft.dm, draft.root, draft.text, draft.version])
            }
            for var command in archive.commands {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM outbox WHERE command_id = ?)", arguments: [command.commandId]) != true else { continue }
                if !command.isSessionDM { command.state = .unconfirmed; command.error = "unconfirmed"; command.nextAttemptAt = nil }
                _ = try store.outbox.insert(db, command)
            }
        }
        try FileManager.default.removeItem(at: dmOutboxURL(key))
    }
    var savedDMCount: Int? {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let saved = urls.filter { $0.lastPathComponent.hasSuffix(".dm-outbox.json") }
        guard !saved.isEmpty else { return nil }
        return saved.reduce(0) { total, url in
            total + ((try? JSONDecoder().decode(ChatDMOutboxArchive.self, from: Data(contentsOf: url)).count) ?? 0)
        }
    }
}

extension ChatDMStore {
    /// An accepted card or dm.open can restore our own outgoing text. These
    /// rows cannot grant access: readers still require a current server card.
    static func restoreOutgoing(_ db: Database, dm: String, me: String, opened: Bool = false) throws {
        let card = try card(db, dm)
        guard opened || card != nil else { return }
        // Select each message's latest attempt across all states before restoring:
        // a sent retry suppresses older failures and their retired attachment IDs.
        let commands = try ChatCommandRecord.fetchAll(db, sql: "SELECT * FROM outbox WHERE type IN ('dm.message.post', 'dm.message.post_with_attachments') ORDER BY seq DESC")
        var seen = Set<String>()
        for command in commands {
            guard let args = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: command.bodyBytes).args,
                  args["dm_id"]?.string == dm || (args["dm_id"] == nil && card.map { args["peer_account_id"]?.string == $0.peer.accountId } == true),
                  let id = args["message_id"]?.string, seen.insert(id).inserted,
                  command.state != .sent, command.error != "dismissed", let text = args["text"]?.string,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM dm_messages WHERE dm_id = ? AND message_id = ?)", arguments: [dm, id]) != true,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM dm_revisions WHERE dm_id = ? AND message_id = ?)", arguments: [dm, id]) != true else { continue }
            var m = ChatDMMessageWire(messageId: id, dmId: dm, threadRootId: args["thread_root_id"]?.string,
                authorAccountId: me, text: text, mentions: [], revision: 0, seq: 0, createdAt: ISO8601DateFormatter().string(from: command.createdAt),
                authorSessionName: args["author_session_name"]?.string)
            if command.type == "dm.message.post_with_attachments" {
                let owned = try ChatAttachments.drafts(db, includingQueued: true).filter { $0.owner == .dm(dm) && $0.messageId == id && $0.queued == true }
                let ids: [String]
                if case .array(let values) = args["attachment_ids"] { ids = values.compactMap(\.string) } else { ids = [] }
                m.attachments = ids.compactMap { id in owned.first { $0.id == id }?.file }
                m.attachmentOnly = text.isEmpty
            }
            try db.execute(sql: "INSERT INTO dm_messages (dm_id, message_id, body, seq, root, revision, deleted, local_state, local_error, command_id) VALUES (?, ?, ?, 0, ?, 0, 0, ?, ?, ?)",
                arguments: [dm, id, try JSONEncoder().encode(m), m.threadRootId, command.state == .pending ? "sending" : "failed", command.error, command.commandId])
            try db.execute(sql: "UPDATE dm_cards SET last_activity = MAX(last_activity, ?) WHERE dm_id = ?", arguments: [m.createdAt, dm])
        }
    }
}

struct ChatDisconnectedRow: View {
    var service: ChatService = .shared
    var body: some View {
        if service.state != .signedIn {
            HStack(spacing: 6) {
                Button(service.disconnectedDMCount != nil ? "Reconnect" : "Connect a team") { ConnectionTabs.shared.show() }.buttonStyle(.plain)
                if let count = service.disconnectedDMCount {
                    Text("\(count) unsent DMs").foregroundStyle(ChatAppearance.secondary)
                }
            }.font(Theme.display(11)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
enum ChatConversationTabs {
    static func close(_ key: ChatOrgKey?, stores: [WorkspaceStore] = TabRouter.shared.stores()) {
        for store in stores {
            for workspace in store.workspaces {
                let tabs = workspace.root.allPanes.flatMap(\.tabs).filter { tab in
                    if let channel = tab.channel { return key.map { channel.belongs(to: $0) } ?? true }
                    switch tab.toolRoute {
                    case .directMessage(let ref): return key.map { ref.belongs(to: $0) } ?? true
                    case .directMessageDraft(let scope, _), .newDM(let scope): return key.map { scope == OrgKey($0) } ?? true
                    default: return false
                    }
                }
                for tab in tabs { store.closeTab(tab, in: workspace) }
            }
        }
    }
}
