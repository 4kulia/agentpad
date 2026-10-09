import Foundation
import GRDB

extension ChatCommandRecord {
    /// Local metadata is retained in the private DM outbox/archive, never sent
    /// on the wire. Only an explicit, verified MCP retry can dispatch this row.
    var isSessionDM: Bool {
        type.hasPrefix("dm.") && (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: bodyBytes).args["_mcp"]) != nil
    }
    var requiresDMSignature: Bool {
        guard type.hasPrefix("dm."), let args = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: bodyBytes).args else { return false }
        return args["author_session_name"] != nil || args["text_format"] == .string("canonical")
    }
}

extension ChatSessionTools {
    static func postDM(_ input: [String: ChatJSON], key: ChatOrgKey, caller: ChatLocalCaller, conversation: ChatPersonalAccess.Conversation,
                       generation: String, service: ChatService, store: ChatStore, api: ChatAPI, token: String,
                       current: () throws -> Void, recordUse: () throws -> Void) async throws -> ChatJSON {
        let openOnly = input["open_only"] == .bool(true)
        let peer = input["peer_account_id"]?.string?.lowercased()
        let addressedDM = input["dm_id"]?.string?.lowercased()
        let message = openOnly ? nil : input["message_id"]?.string?.lowercased() ?? UUID().uuidString.lowercased()
        let root = input["thread_root_id"]?.string?.lowercased()
        let text = input["text"]?.string
        // Live process identity is revalidated separately. Retry ownership
        // follows the tab and current conversation across /resume and restarts.
        let provenance = "\(caller.surface)/\(conversation.id)"
        let commands = try store.outbox.commands()
        let existing = commands.first { command in
            guard command.isSessionDM else { return false }
            let args = ChatService.args(command)
            if let message { return args["message_id"]?.string == message }
            return command.type == "dm.open" && args["peer_account_id"]?.string == peer && args["_mcp"]?["provenance"]?.string == provenance
        }
        var record: ChatCommandRecord
        var args: [String: ChatJSON]
        if let existing {
            args = ChatService.args(existing)
            guard args["_mcp"]?["provenance"]?.string == provenance,
                  args["_mcp"]?["conversation"]?.string == conversation.id,
                  args["_mcp"]?["generation"]?.string == generation,
                  args["_mcp"]?["address_dm"]?.string == addressedDM,
                  args["peer_account_id"]?.string == peer,
                  args["thread_root_id"]?.string == root, args["text"]?.string == text else { throw Failure(code: "message_conflict") }
            record = existing
        } else {
            if let message {
                let occupied = try store.dmRead { db in
                    try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM dm_messages WHERE message_id = ?)", arguments: [message]) == true
                }
                guard !occupied, !commands.contains(where: { ChatService.args($0)["message_id"]?.string == message }) else { throw Failure(code: "message_conflict") }
            }
            var metadata: [String: ChatJSON] = ["provenance": .string(provenance), "conversation": .string(conversation.id),
                "generation": .string(generation)]
            if let addressedDM { metadata["address_dm"] = .string(addressedDM) }
            args = ["_mcp": .object(metadata)]
            if let peer { args["peer_account_id"] = .string(peer); args["open_command_id"] = .string(ChatUUID.v7()) }
            if let addressedDM { args["dm_id"] = .string(addressedDM) }
            if let message, let text {
                args["message_id"] = .string(message); args["text"] = .string(text)
                args["author_session_name"] = .string(caller.signature); args["mentions"] = .array([])
            }
            if let root { args["thread_root_id"] = .string(root) }
            let prepared = try service.prepareCommand(key, type: openOnly ? "dm.open" : "dm.message.post", args: .object(args))
            record = prepared.record
            record.state = .unconfirmed; record.error = "mcp_retry_required"
            record.orderKey = "mcp-dm:\(record.commandId)"
            try current()
            record = try store.dmWrite { try store.outbox.insert($0, record, seq: record.seq) }
        }
        guard service.dmToolSending.insert(record.commandId).inserted else { throw Failure(code: "busy") }
        defer { service.dmToolSending.remove(record.commandId) }
        func liveRecord(_ db: Database) throws -> ChatCommandRecord {
            guard let latest = try ChatCommandRecord.fetchOne(db, sql: "SELECT * FROM outbox WHERE command_id = ? AND dismissed = 0",
                                                             arguments: [record.commandId]),
                  latest.state != .dropped, latest.error != "dismissed" else { throw Failure(code: "dismissed") }
            return latest
        }
        func refresh() throws {
            try current()
            record = try store.dmRead(liveRecord)
        }
        // Never save the copy held across a network wait. Read and mutate the
        // current row in one transaction so Delete remains authoritative.
        func save(_ update: (inout ChatCommandRecord) -> Void = { _ in }) throws {
            try current()
            let bytes = try ChatCommandEnvelope(commandId: record.commandId, org: key.orgId, type: record.type, args: .object(args)).encoded()
            record = try store.dmWrite { db in
                var latest = try liveRecord(db)
                update(&latest)
                latest.bodyBytes = bytes
                try latest.update(db)
                return latest
            }
        }
        func outcome(_ status: String, error: String? = nil) -> ChatJSON {
            var fields: [String: ChatJSON] = ["org_id": .string(key.orgId), "kind": .string("dm"), "status": .string(status)]
            if let dm = args["dm_id"] { fields["dm_id"] = dm }
            if let message { fields["message_id"] = .string(message); fields["author_session_name"] = args["author_session_name"] }
            if let root { fields["thread_root_id"] = .string(root) }
            if openOnly { fields["operation"] = .string("open") }
            if let error { fields["error"] = .string(error) }
            return .object(fields)
        }
        try refresh()
        if let peer {
            guard peer != key.accountId,
                  try store.dmRead({ try ChatOrgView.Member.read($0, account: peer).first }) != nil else { throw Failure(code: "not_found") }
        }
        do {
            if args["dm_id"] == nil, let peer {
                try recordUse()
                let bytes = try ChatCommandEnvelope(commandId: args["open_command_id"]!.string!, org: key.orgId, type: "dm.open",
                                                    args: .object(["peer_account_id": .string(peer)])).encoded()
                try refresh()
                let response = try await api.postCommand(bytes, token: token)
                try refresh()
                try ChatAPI.check(response)
                let ack = try JSONDecoder().decode(ChatCommandAnswer.self, from: response.body)
                guard let raw = ack.result["dm_id"]?.string, let dm = UUID(uuidString: raw) else { throw Failure(code: "not_found") }
                args["dm_id"] = .string(dm.uuidString.lowercased())
                try save()
            }
            guard let dm = args["dm_id"]?.string else { throw Failure(code: "invalid_args") }
            let card = try await api.dm(key.orgId, id: dm, token: token)
            try refresh()
            guard card.dmId == dm else { throw Failure(code: "not_found") }
            if openOnly {
                try save { $0.state = .sent; $0.error = nil }
                return outcome("opened")
            }
            if record.state == .sent { return outcome("sent") }
            guard card.writable else { return outcome("unknown", error: "dm_read_only") }
            try recordUse()
            var wire = args
            wire["_mcp"] = nil; wire["peer_account_id"] = nil; wire["open_command_id"] = nil
            let bytes = try ChatCommandEnvelope(commandId: record.commandId, org: key.orgId, type: "dm.message.post", args: .object(wire)).encoded()
            try save { $0.attempts += 1 }
            let response = try await api.postCommand(bytes, token: token)
            try refresh()
            try ChatAPI.check(response)
            let ack = try JSONDecoder().decode(ChatCommandAnswer.self, from: response.body)
            guard ack.result["dm_id"]?.string == dm, ack.result["message_id"]?.string == message,
                  ack.result["author_session_name"] == args["author_session_name"] else { return outcome("unknown") }
            try save { $0.state = .sent; $0.error = nil; $0.sentGeneration = generation }
            return outcome("sent")
        } catch let error as Failure { throw error }
        catch let ChatAPIError.server(status, code, retry) {
            try refresh()
            if status == 403 || status == 404 { throw Failure(code: "not_found") }
            if status == 401 { throw Failure(code: "not_connected") }
            var result = outcome("unknown", error: code)
            if let retry, case .object(var fields) = result { fields["retry_after_seconds"] = .number(ceil(retry)); result = .object(fields) }
            return result
        } catch {
            try refresh()
            return outcome("unknown")
        }
    }
}
