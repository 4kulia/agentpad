import Foundation

/// A signature is a literal label of this account, never the badge of a
/// published agent. A channel catalog is not needed to retain the author's name.
struct ChatMessageAttribution {
    var title: String
    var ownerTooltip: String
    var publishedAgentId: String?

    init(_ message: ChatMessage, ownerName: String, ownerHandle: String?, catalogAgentName: String? = nil) {
        ownerTooltip = ownerHandle.map { "@\($0) · \(message.authorAccountId)" } ?? message.authorAccountId
        publishedAgentId = message.authorAgentId
        if !message.hasFixed && message.localState == nil { title = "" }
        else if message.authorAgentId != nil {
            title = "\(message.authorAgentName ?? catalogAgentName ?? "Agent") (\(ownerName)'s agent)"
        } else if let signature = message.authorSessionName {
            title = "\(signature) (\(ownerName)'s agent)"
        } else { title = ownerName }
    }
}
