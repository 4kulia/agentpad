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

/// Own commands only, never cards, received messages, drafts or peer names.
/// This survives explicit disconnection while the organization's cache is removed.
struct ChatDMOutboxArchive: Codable {
    var scope: ChatDMRef
    var commands: [ChatCommandRecord]
    var count: Int { Set(commands.filter { $0.type == "dm.message.post" && $0.state != .sent }.compactMap { record -> String? in
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
    func saveDMOutbox(_ key: ChatOrgKey, store: ChatStore?) throws {
        let readCommands: (Database) throws -> [ChatCommandRecord] = { db in
            try ChatCommandRecord.fetchAll(db, sql: "SELECT * FROM outbox WHERE type LIKE 'dm.%' ORDER BY seq")
        }
        let commands: [ChatCommandRecord]
        if let store {
            commands = try store.dmRead(readCommands)
        } else if FileManager.default.fileExists(atPath: cacheURL(key).path) {
            // A revoked session never opens its cache. Read its queue without
            // migrations or recovery that could replace an unreadable file.
            var config = Configuration(); config.readonly = true
            let cache = try DatabaseQueue(path: cacheURL(key).path, configuration: config)
            defer { try? cache.close() }
            commands = try cache.read(readCommands)
        } else {
            return // No cache: any previously saved archive is already safe.
        }
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
        try writePrivate(JSONEncoder().encode(ChatDMOutboxArchive(scope: ChatDMRef(key, dm: ""), commands: remaining)), to: dmOutboxURL(key))
    }
    func restoreDMOutbox(_ key: ChatOrgKey, store: ChatStore) throws {
        guard let archive = try savedDMOutbox(key) else { return }
        try store.dmWrite { db in
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
        let commands = try ChatCommandRecord.fetchAll(db, sql: "SELECT * FROM outbox WHERE type = 'dm.message.post' AND state != 'sent' AND error IS NOT 'dismissed' ORDER BY seq")
        for command in commands {
            guard let args = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: command.bodyBytes).args,
                  args["dm_id"]?.string == dm || (args["dm_id"] == nil && card.map { args["peer_account_id"]?.string == $0.peer.accountId } == true),
                  let id = args["message_id"]?.string, let text = args["text"]?.string,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM dm_messages WHERE dm_id = ? AND message_id = ?)", arguments: [dm, id]) != true,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM dm_revisions WHERE dm_id = ? AND message_id = ?)", arguments: [dm, id]) != true else { continue }
            let m = ChatDMMessageWire(messageId: id, dmId: dm, threadRootId: args["thread_root_id"]?.string,
                authorAccountId: me, text: text, mentions: [], revision: 0, seq: 0, createdAt: ISO8601DateFormatter().string(from: command.createdAt),
                authorSessionName: args["author_session_name"]?.string)
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
