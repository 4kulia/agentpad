import Foundation
import CoreFoundation

/// Shared by stdio MCP and the app's socket dispatcher. Neither trusts schema
/// hints supplied to the model; mixed channel/DM addresses are always refused.
public enum AgentPadChatToolArguments {
    public static func valid(_ tool: String, _ args: [String: Any]) -> Bool {
        let allowed: Set<String>
        switch tool {
        case "chat_channels": allowed = ["org_id", "scope", "after"]
        case "chat_read": allowed = ["org_id", "kind", "channel_id", "dm_id", "thread_root_id", "before", "attachment_id"]
        case "chat_post": allowed = ["org_id", "kind", "channel_id", "dm_id", "peer_account_id", "thread_root_id", "text", "message_id", "open_only"]
        default: return false
        }
        guard Set(args.keys).isSubset(of: allowed) else { return false }
        for key in ["org_id", "channel_id", "dm_id", "peer_account_id", "thread_root_id", "message_id", "attachment_id"] where args[key] != nil {
            guard let raw = args[key] as? String, UUID(uuidString: raw) != nil else { return false }
        }
        if tool == "chat_channels" {
            if let scope = args["scope"], !(scope is String && ["channels", "dms", "members"].contains(scope as! String)) { return false }
            if let after = args["after"], !(after is String && (after as! String).utf8.count <= 512) { return false }
            return true
        }
        guard args["org_id"] != nil else { return false }
        let kind = args["kind"] as? String ?? "channel"
        guard args["kind"] == nil || args["kind"] is String, ["channel", "dm"].contains(kind) else { return false }
        if kind == "channel" {
            guard args["channel_id"] != nil, args["dm_id"] == nil, args["peer_account_id"] == nil, args["open_only"] == nil else { return false }
        } else {
            guard args["channel_id"] == nil, (args["dm_id"] != nil) != (args["peer_account_id"] != nil) else { return false }
            if args["peer_account_id"] != nil, args["thread_root_id"] != nil { return false }
        }
        if tool == "chat_read" {
            guard args["peer_account_id"] == nil else { return false }
            if let before = args["before"] {
                guard let n = before as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue > 0, n.doubleValue < Double(Int.max), n.doubleValue.rounded() == n.doubleValue else { return false }
            }
            return true
        }
        if let open = args["open_only"] {
            guard let flag = open as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue,
                  kind == "dm", args["peer_account_id"] != nil,
                  args["text"] == nil, args["message_id"] == nil, args["thread_root_id"] == nil else { return false }
            return true
        }
        guard let text = args["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 16 * 1024 else { return false }
        return true
    }
}
