import Foundation
import CoreFoundation

/// Shared by stdio MCP and the app's socket dispatcher. Neither trusts schema
/// hints supplied to the model; mixed channel/DM addresses are always refused.
public enum AgentPadChatToolArguments {
    public struct Problem: Error, Equatable, Sendable {
        public let field: String
        public let reason: String
        public var message: String { "\(field) \(reason)" }
    }

    public static let textLimit = 16 * 1024
    public static let cursorLimit = 512
    public static let payloadLimit = 24 * 1024

    public static func valid(_ tool: String, _ args: [String: Any]) -> Bool { problem(tool, args) == nil }

    /// Names the first invalid field deterministically, without echoing private
    /// message text, IDs or unexpected argument values into diagnostics.
    public static func problem(_ tool: String, _ args: [String: Any]) -> Problem? {
        func bad(_ field: String, _ reason: String) -> Problem { Problem(field: field, reason: reason) }
        let allowed: Set<String>
        switch tool {
        case "chat_channels": allowed = ["org_id", "scope", "after"]
        case "chat_read": allowed = ["org_id", "kind", "channel_id", "dm_id", "thread_root_id", "before", "attachment_id"]
        case "chat_post": allowed = ["org_id", "kind", "channel_id", "dm_id", "peer_account_id", "thread_root_id", "text", "message_id", "open_only"]
        default: return bad("tool", "must be chat_channels, chat_read, or chat_post")
        }
        if let field = args.keys.sorted().first(where: { !allowed.contains($0) }) { return bad(field, "is not a supported argument for \(tool)") }
        for field in ["org_id", "channel_id", "dm_id", "peer_account_id", "thread_root_id", "message_id", "attachment_id"] where args[field] != nil {
            guard let raw = args[field] as? String, UUID(uuidString: raw) != nil else { return bad(field, "must be a UUID") }
        }
        if tool == "chat_channels" {
            if let scope = args["scope"] {
                guard let scope = scope as? String, ["channels", "dms", "members"].contains(scope) else {
                    return bad("scope", "must be channels, dms, or members")
                }
            }
            if let after = args["after"] {
                guard let after = after as? String else { return bad("after", "must be a string") }
                guard after.utf8.count <= cursorLimit else { return bad("after", "must be at most \(cursorLimit) UTF-8 bytes") }
            }
            return nil
        }
        guard args["org_id"] != nil else { return bad("org_id", "is required and must be a UUID") }
        let kind = args["kind"] as? String ?? "channel"
        guard args["kind"] == nil || args["kind"] is String, ["channel", "dm"].contains(kind) else {
            return bad("kind", "must be channel or dm")
        }
        if kind == "channel" {
            for field in ["dm_id", "peer_account_id", "open_only"] where args[field] != nil { return bad(field, "is only allowed when kind is dm") }
            guard args["channel_id"] != nil else { return bad("channel_id", "is required when kind is channel") }
        } else {
            guard args["channel_id"] == nil else { return bad("channel_id", "must be omitted when kind is dm") }
            guard (args["dm_id"] != nil) != (args["peer_account_id"] != nil) else {
                return bad("dm_id", "requires exactly one of dm_id or peer_account_id when kind is dm")
            }
            if args["peer_account_id"] != nil, args["thread_root_id"] != nil {
                return bad("thread_root_id", "requires dm_id; it cannot be combined with peer_account_id")
            }
        }
        if tool == "chat_read" {
            if let before = args["before"] {
                guard let n = before as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue > 0, n.doubleValue < Double(Int.max), n.doubleValue.rounded() == n.doubleValue else {
                    return bad("before", "must be a positive whole number less than \(Int.max)")
                }
            }
            return nil
        }
        if let open = args["open_only"] {
            guard let flag = open as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue else {
                return bad("open_only", "must be true when provided")
            }
            guard args["peer_account_id"] != nil else { return bad("peer_account_id", "is required when open_only is true") }
            for field in ["text", "message_id", "thread_root_id"] where args[field] != nil {
                return bad(field, "must be omitted when open_only is true")
            }
            return nil
        }
        guard let text = args["text"] as? String else { return bad("text", "is required and must be a string") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return bad("text", "must not be empty or whitespace only") }
        guard text.utf8.count <= textLimit else { return bad("text", "must be at most \(textLimit) UTF-8 bytes") }
        return nil
    }
}
