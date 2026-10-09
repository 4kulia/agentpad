import Foundation
import GRDB
import SwiftUI

/// Own commands only, never cards, received messages, drafts or peer names.
/// This survives explicit disconnection while the organization's cache is removed.
struct ChatDMOutboxArchive: Codable {
    var scope: ChatDMRef
    var commands: [ChatCommandRecord]
    var count: Int { Set(commands.filter { $0.type == "dm.message.post" }.compactMap { record -> String? in
        guard let args = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes).args,
              let dm = args["dm_id"]?.string, let id = args["message_id"]?.string else { return nil }
        return dm + ":" + id
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
            return command.type + ":" + (args["dm_id"]?.string ?? "") + ":" + (args["message_id"]?.string ?? command.commandId)
        }
        let finished = Set(commands.filter { $0.state == .sent || $0.error == "dismissed" }.map(address))
        var saved = Dictionary(uniqueKeysWithValues: (try savedDMOutbox(key)?.commands ?? []).map { ($0.commandId, $0) })
        for command in commands where command.state != .sent && command.error != "dismissed" { saved[command.commandId] = command }
        let remaining = saved.values.filter { !finished.contains(address($0)) }.sorted { $0.seq < $1.seq }
        // An empty archive also remembers that this connection was explicitly
        // closed, so the offline row says Reconnect and truthfully shows zero.
        try writePrivate(JSONEncoder().encode(ChatDMOutboxArchive(scope: ChatDMRef(key, dm: ""), commands: remaining)), to: dmOutboxURL(key))
    }
    func restoreDMOutbox(_ key: ChatOrgKey, store: ChatStore) throws {
        guard let archive = try savedDMOutbox(key) else { return }
        try store.dmWrite { db in
            for var command in archive.commands {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM outbox WHERE command_id = ?)", arguments: [command.commandId]) != true else { continue }
                command.state = .unconfirmed; command.error = "unconfirmed"; command.nextAttemptAt = nil
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
    /// Queue rows cannot grant access: call only after a server card was accepted.
    static func restoreOutgoing(_ db: Database, dm: String, me: String) throws {
        guard try card(db, dm) != nil else { return }
        let commands = try ChatCommandRecord.fetchAll(db, sql: "SELECT * FROM outbox WHERE type = 'dm.message.post' AND state != 'sent' AND error IS NOT 'dismissed' ORDER BY seq")
        for command in commands {
            guard let args = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: command.bodyBytes).args,
                  args["dm_id"]?.string == dm, let id = args["message_id"]?.string, let text = args["text"]?.string,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM dm_messages WHERE dm_id = ? AND message_id = ?)", arguments: [dm, id]) != true,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM dm_revisions WHERE dm_id = ? AND message_id = ?)", arguments: [dm, id]) != true else { continue }
            let m = ChatDMMessageWire(messageId: id, dmId: dm, threadRootId: args["thread_root_id"]?.string,
                authorAccountId: me, text: text, mentions: [], revision: 0, seq: 0, createdAt: ISO8601DateFormatter().string(from: command.createdAt))
            try db.execute(sql: "INSERT INTO dm_messages (dm_id, message_id, body, seq, root, revision, deleted, local_state, local_error, command_id) VALUES (?, ?, ?, 0, ?, 0, 0, ?, ?, ?)",
                arguments: [dm, id, try JSONEncoder().encode(m), m.threadRootId, command.state == .pending ? "sending" : "failed", command.error, command.commandId])
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
                    case .newDM(let scope): return key.map { scope == OrgKey($0) } ?? true
                    default: return false
                    }
                }
                for tab in tabs { store.closeTab(tab, in: workspace) }
            }
        }
    }
}
