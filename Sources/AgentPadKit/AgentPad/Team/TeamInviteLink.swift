import AgentPadHookKit
import CryptoKit
import Foundation

/// `agentpad://team/join?t=<ticket>&s=<secret>&n=<name>` (TEAM.md 7.2).
///
/// `t` is the inviter's endpoint ticket built from its public key and home
/// relay only — no IP addresses: they are found when dialing, so the link
/// neither reveals the machine's addresses nor goes stale when its network
/// changes. `s` is a one-time 128-bit secret; the inviter keeps only its hash.
struct TeamInviteLink: Equatable, Sendable {
    let ticket: String
    let secret: String
    let inviterName: String

    static let host = "team"
    static let path = "/join"

    var url: URL? {
        var components = URLComponents()
        components.scheme = AppIdentity.urlScheme
        components.host = Self.host
        components.path = Self.path
        components.queryItems = [
            URLQueryItem(name: "t", value: ticket),
            URLQueryItem(name: "s", value: secret),
            URLQueryItem(name: "n", value: inviterName),
        ]
        return components.url
    }

    /// Nil for a URL that is not a team link at all; throws for one that is,
    /// but is malformed — the caller then says so instead of staying silent.
    static func parse(_ url: URL) throws -> TeamInviteLink? {
        guard url.scheme?.lowercased() == AppIdentity.urlScheme,
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        guard components.path.lowercased() == path else { throw TeamError.invalidLink("unknown team action") }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let ticket = value("t"), !ticket.isEmpty, ticket.count <= 512,
              ticket.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { throw TeamError.invalidLink("missing or malformed address") }
        guard let secret = value("s"), isValidSecret(secret) else { throw TeamError.invalidLink("missing or malformed secret") }
        let name = sanitizedName(value("n") ?? "")
        return TeamInviteLink(ticket: ticket, secret: secret, inviterName: name.isEmpty ? "a colleague" : name)
    }

    /// 128 random bits, base64url. Throws rather than hand out a guessable
    /// value when the system generator fails.
    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw TeamError.storage("the system random generator failed")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func newSecret() throws -> String { try randomToken() }

    /// Secrets and pairing nonces share one shape: 22 base64url characters.
    static func isValidSecret(_ secret: String) -> Bool {
        secret.count == 22 && secret.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Names arrive from another machine and reach dialogs and lists: one
    /// line, no direction overrides, at most 64 characters.
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

enum TeamPairingCode {
    /// Six digits both sides compute from the two public keys, the invitation
    /// secret and one nonce from each side. Matching codes mean each side
    /// talks to the Mac it thinks it does.
    ///
    /// Six digits are enough only because neither side can choose its nonce
    /// after seeing the other's: the joiner commits to `joinerNonce` (sends
    /// its hash) before the inviter reveals `inviterNonce`, and reveals its
    /// own only afterwards. Someone relaying between two people therefore
    /// cannot steer the two codes to match — they meet by chance, 1 in 10⁶.
    /// (Same idea as Bluetooth's numeric comparison.)
    static func code(_ a: String, _ b: String, secret: String, inviterNonce: String, joinerNonce: String) -> String {
        let pair = [a.lowercased(), b.lowercased()].sorted().joined(separator: ":")
        let digest = SHA256.hash(data: Data("agentpad-pairing-v2:\(pair):\(secret):\(inviterNonce):\(joinerNonce)".utf8))
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", value)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    static func commitment(to nonce: String) -> String {
        SHA256.hash(data: Data("agentpad-pairing-commit:\(nonce)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
