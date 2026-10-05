import Foundation

// The calls' messages and the small helpers team work shares.

/// Someone calling this Mac's agents: an id and the name shown for them.
/// (Direct mode's paired colleagues are gone; the server names callers from D8 on.)
struct TeamCaller: Equatable, Sendable {
    let id: String
    let displayName: String
}

/// Names and short texts from another Mac: no control characters, line
/// breaks or direction marks, trimmed, at most 64 characters.
enum TeamText {
    static func sanitizedName(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.newlines.contains(scalar)
                && !(0x2028...0x2029).contains(scalar.value)   // line / paragraph separator
                && !(0x200E...0x200F).contains(scalar.value)   // direction marks
                && !(0x202A...0x202E).contains(scalar.value)   // direction overrides
                && !(0x2066...0x2069).contains(scalar.value)   // direction isolates
        }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces).prefix(64).description
    }
}

final class TeamOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// `operation`, or `TeamError.timedOut` after `timeout`, whichever comes first.
func teamDeadline<T: Sendable>(
    _ timeout: Duration,
    onTimeout: (@Sendable () -> Void)? = nil,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = TeamOnce()
    return try await withCheckedThrowingContinuation { continuation in
        Task {
            do {
                let value = try await operation()
                if gate.claim() { continuation.resume(returning: value) }
            } catch {
                if gate.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: timeout)
            if gate.claim() {
                onTimeout?()
                continuation.resume(throwing: TeamError.timedOut)
            }
        }
    }
}

/// One message of the calls' protocol (TEAM.md 7.3): a request and its
/// answer. The server carries them from D8 on.
struct TeamMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        // Stage 2: the catalog and calls (TEAM.md 7.3). Every call message is
        // answered with `call.status`, which carries the call as it stands.
        case catalogGet = "catalog.get", catalog
        case callStart = "call.start", callAttach = "call.attach", callCancel = "call.cancel"
        case callStatus = "call.status"
        /// The caller has the outcome; the owner may let the record age out (D-7).
        case callAck = "call.ack"
        case error
    }

    var type: Kind
    var protocolVersion: Int = TeamWire.version
    /// Machine-readable reason for `error`.
    var code: String?
    /// catalog: the agents this colleague may call.
    var agents: [TeamCatalogEntry]?
    /// call.*: which call.
    var callId: String?
    /// call.start: the agent's name, the request, and the thread it continues.
    var agent: String?
    var prompt: String?
    var threadId: String?
    var from: TeamCallOrigin?
    /// call.start: how long the caller still wants the call to wait for the owner.
    var deliverBy: Date?
    /// call.start, call.attach: answer when the call changes, or after this
    /// many seconds (capped by the owner).
    var waitSeconds: Int?
    /// call.status: the call as the owner sees it.
    var call: TeamCallReport?

    static func error(_ code: String) -> TeamMessage { TeamMessage(type: .error, code: code) }
}

enum TeamWire {
    static let version = 1
}


enum TeamError: Error, Equatable, LocalizedError {
    case storage(String)
    case timedOut
    case refused(String)
    /// Something of team work still runs here: the move to a server waits (C0).
    case teamWorkOn
    /// Calls to colleagues go through a server; none is connected (or its
    /// delivery is not in yet: D8, D4–D6).
    case notConnected
    /// Not done through a server yet (`TeamServerCore`): the text as it is.
    case notYet(String)
    /// A check's calls are no longer the current ones (review D8h-p2-7).
    case scopeChanged

    var errorDescription: String? {
        switch self {
        case .teamWorkOn: "A team call is still running here; wait until it ends."
        case .notConnected: "Calls to colleagues are available after connecting to a server."
        case .notYet(let text): text
        case .scopeChanged: "Team work moved to other calls (another organization, server or account) while this call was followed; it is no longer followed here."
        case .storage(let detail): "Team data: \(detail)"
        case .timedOut: "The other Mac did not answer in time."
        case .refused(let reason): Self.refusalText(reason)
        }
    }

    static func refusalText(_ code: String) -> String {
        switch code {
        case "denied": return "Your colleague declined the request."
        case "protocol_too_new": return "The other AgentPad is older. Ask your colleague to update."
        case "unknown_agent": return "Your colleague has no agent by that name open to you."
        case "unknown_call": return "Your colleague's Mac does not know this call (it may have restarted)."
        case "unknown_thread": return "That thread is unknown on your colleague's Mac; start a new one."
        case "rate_limited": return "Too many calls to this colleague in the last hour. Try later."
        case "too_large": return "The request is too long."
        case "expired": return "The call's delivery deadline has passed."
        case "busy_calls": return "Your colleague already has several of your calls waiting for a decision."
        default:
            // Codes come from another machine: show only a short, plain one.
            let plain = code.prefix(32).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            return plain.isEmpty ? "The other Mac refused the request." : "The other Mac refused (\(plain))."
        }
    }
}
