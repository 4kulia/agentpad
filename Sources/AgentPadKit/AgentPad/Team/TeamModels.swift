import CryptoKit
import Foundation

// Team work, stage 1: identity, invitations, the list of colleagues and
// whether each one is online (docs/agentpad/TEAM.md, 6.1 and 7.1–7.3).

/// A colleague this Mac has paired with. Identified by the public key of
/// their AgentPad's endpoint — never by name, so another Mac calling itself
/// by the same name gets none of their rights.
struct TeamContact: Codable, Equatable, Identifiable, Sendable {
    /// Endpoint public key, lowercase hex.
    let id: String
    /// The name they gave their AgentPad, as received at pairing.
    var name: String
    /// A local name for them, if the user set one.
    var alias: String?
    /// Their home relay when last known — a dialing hint only; the key is
    /// enough to find them.
    var relayURL: String?
    let addedAt: Date
    var lastSeen: Date?

    var displayName: String { alias?.isEmpty == false ? alias! : name }

    /// Answering within two presence rounds (`TeamService.presenceInterval`)
    /// counts as online.
    static let onlineWindow: TimeInterval = 150

    /// Online means answered within the last presence round or two.
    func isOnline(now: Date = Date()) -> Bool {
        guard let lastSeen else { return false }
        return now.timeIntervalSince(lastSeen) < Self.onlineWindow
    }
}

/// What this Mac stores about an invitation it issued: only a hash of the
/// secret, so the file alone cannot be used to join.
struct TeamInviteRecord: Codable, Equatable, Sendable {
    let secretHash: String
    let createdAt: Date
    let expiresAt: Date
    var usedBy: String?

    static func hash(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Team settings kept beside the rest of the team state, so deleting the team
/// folder fully resets team work.
struct TeamConfig: Codable, Equatable, Sendable {
    var enabled = false
    /// How this Mac introduces itself to colleagues.
    var displayName = ""
}

/// One message on the wire. Each request is one bidirectional stream: one
/// JSON line up, one JSON line back (TEAM.md 7.3).
struct TeamMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello, helloOK = "hello.ok"
        case pairCommit = "pair.commit", pairNonce = "pair.nonce"
        case pairRequest = "pair.request", pairOK = "pair.ok", pairDenied = "pair.denied"
        case error
    }

    var type: Kind
    var protocolVersion: Int = TeamWire.version
    /// Sender's display name (hello, pair.*).
    var name: String?
    /// Invitation secret (pair.commit, pair.request).
    var secret: String?
    /// pair.commit: hash of the joiner's nonce. pair.nonce: the inviter's
    /// nonce. pair.request: the joiner's nonce, revealed (TEAM.md 7.2).
    var commitment: String?
    var nonce: String?
    var appVersion: String?
    /// Machine-readable reason for `error` / `pair.denied`.
    var code: String?

    static func error(_ code: String) -> TeamMessage { TeamMessage(type: .error, code: code) }
}

enum TeamWire {
    static let version = 1
    static let alpn = "agentpad/team/1"
    /// Upper bound for one message, enforced while reading.
    static let maxMessageBytes = 64 * 1024

    static func encode(_ message: TeamMessage) throws -> Data {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        return data
    }

    /// Exactly one UTF-8 JSON line, terminated by a newline; anything else is
    /// refused, so a truncated message can never pass as a complete one.
    static func decode(_ data: Data) throws -> TeamMessage {
        guard data.count <= maxMessageBytes else { throw TeamError.protocolViolation("message too large") }
        guard let newline = data.firstIndex(of: 0x0A), newline == data.index(before: data.endIndex) else {
            throw TeamError.protocolViolation("expected one complete line")
        }
        return try JSONDecoder().decode(TeamMessage.self, from: data[data.startIndex..<newline])
    }
}

/// Where to dial a peer: a ticket from an invitation link, or a known key.
enum TeamPeerAddress: Equatable, Sendable {
    case ticket(String)
    case endpoint(id: String, relayURL: String?)
}

enum TeamError: Error, Equatable, LocalizedError {
    case notEnabled
    case identity(String)
    case storage(String)
    case invalidLink(String)
    case protocolViolation(String)
    case timedOut
    case unreachable(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .notEnabled: "Team work is turned off."
        case .identity(let detail): "Team identity key: \(detail)"
        case .storage(let detail): "Team data: \(detail)"
        case .invalidLink(let detail): "Invitation link: \(detail)"
        case .protocolViolation(let detail): "Unexpected message from the other Mac: \(detail)"
        case .timedOut: "The other Mac did not answer in time."
        case .unreachable(let detail): "Could not reach the other Mac: \(detail)"
        case .refused(let reason): Self.refusalText(reason)
        }
    }

    static func refusalText(_ code: String) -> String {
        switch code {
        case "denied": return "Your colleague declined the request."
        case "invite_invalid": return "The invitation is unknown, already used, or expired. Ask for a new one."
        case "not_paired": return "That Mac does not know this one. Pair again with a new invitation."
        case "busy": return "Your colleague has another join request open. Try again in a minute."
        case "join_in_progress": return "A join is already waiting for an answer."
        case "protocol_too_new": return "The other AgentPad is older. Ask your colleague to update."
        case "storage": return "The other Mac could not save the pairing. Try again."
        default:
            // Codes come from another machine: show only a short, plain one.
            let plain = code.prefix(32).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            return plain.isEmpty ? "The other Mac refused the request." : "The other Mac refused (\(plain))."
        }
    }
}
