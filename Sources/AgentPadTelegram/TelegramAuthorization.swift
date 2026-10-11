import Foundation

public struct TelegramAccount: Equatable, Sendable {
    public let userID: Int64
    public let displayName: String
    public let username: String?
}

public struct TelegramCodeInfo: Equatable, Sendable {
    public let delivery: String
    public let resendAvailableAt: Date?
}

public enum TelegramAuthState: Equatable, Sendable {
    case disconnected, starting, requestingQR, qr(link: String), phoneNumber
    case code(TelegramCodeInfo), emailAddress, emailCode(pattern: String), password(hint: String)
    case verifyingAccount, connected(TelegramAccount), loggingOut, closing
    case cleanupPending, reauthenticationRequired, unsupported, blocked, disabled
}

public enum TelegramNetworkState: Equatable, Sendable { case waiting, connecting, updating, ready }

public enum TelegramFailure: Error, Equatable, Sendable {
    case configuration, keyUnavailable, keyMissing, invalidKey, storage, profileInUse, accountMismatch
    case invalidPhone, invalidCode, expiredCode, invalidPassword, invalidEmail, accountUnavailable
    case serverWait, requestFailed, timeout, unsupported, initialization, transport, logoutUnconfirmed

    public var message: String {
        switch self {
        case .configuration: "Telegram is unavailable in this build. Configure a Telegram API ID and hash to connect."
        case .keyUnavailable: "Unlock the login Keychain and allow AgentPad to access its Telegram database key, then retry."
        case .keyMissing: "The Telegram database key is missing from Keychain. Restore the key or remove the local profile to reconnect."
        case .invalidKey: "The Telegram database key could not open this profile. The local data has been preserved."
        case .storage: "The local Telegram profile could not be read or saved. Check disk space and file permissions, then retry."
        case .profileInUse: "This Telegram profile is open in another AgentPad process. Close that process, then retry."
        case .accountMismatch: "This profile belongs to a different Telegram account. Disconnect it before connecting another account."
        case .invalidPhone: "Check the phone number, including its country code."
        case .invalidCode: "That code was not accepted. Check the code and try again."
        case .expiredCode: "This code has expired. Request another code when available."
        case .invalidPassword: "That two-step verification password was not accepted. Try again."
        case .invalidEmail: "That email address or email code was not accepted. Try again."
        case .accountUnavailable: "Telegram cannot authorize this account. Check your account in the official Telegram app."
        case .serverWait: "Telegram asked you to wait. Try again after the server's wait has ended."
        case .requestFailed: "Telegram could not complete this request. Try again."
        case .timeout: "Telegram has not replied yet. You can keep waiting or cancel."
        case .unsupported: "This sign-in step is not supported in AgentPad. Complete it in the official Telegram app."
        case .initialization: "Telegram initialization could not be verified. Close the connection and retry."
        case .transport: "The Telegram connection could not be processed. Close the connection and retry."
        case .logoutUnconfirmed: "Logout is pending. Reconnect to the internet to retry, or remove data only from this Mac and revoke AgentPad in Telegram → Settings → Devices."
        }
    }

    static func classify(_ error: any Error) -> Self {
        guard let error = error as? TelegramStorageError else {
            return error is TelegramConfigurationError ? .configuration : .storage
        }
        return switch error {
        case .keyUnavailable, .keyExists: .keyUnavailable
        case .keyMissing: .keyMissing
        case .invalidKey: .invalidKey
        case .lockedProfile: .profileInUse
        case .accountMismatch: .accountMismatch
        default: .storage
        }
    }

    static func rpc(_ response: TDLibMessage, parameters: Bool = false) -> Self {
        // Allowlist exact pinned errors. Never surface raw text, including 406.
        if response["code"]?.integer == 429 { return .serverWait }
        switch response["message"]?.string {
        case "PHONE_NUMBER_INVALID": return .invalidPhone
        case "PHONE_CODE_INVALID", "PHONE_CODE_EMPTY": return .invalidCode
        case "PHONE_CODE_EXPIRED": return .expiredCode
        case "PASSWORD_HASH_INVALID": return .invalidPassword
        case "EMAIL_ADDRESS_INVALID", "EMAIL_CODE_INVALID", "EMAIL_CODE_EXPIRED": return .invalidEmail
        case "PHONE_NUMBER_BANNED", "USER_DEACTIVATED", "USER_DEACTIVATED_BAN": return .accountUnavailable
        case "API_ID_INVALID", "API_ID_PUBLISHED_FLOOD": return .configuration
        case "Wrong database encryption key": return .invalidKey
        default: return parameters ? .initialization : .requestFailed
        }
    }
}

public struct TelegramSnapshot: Equatable, Sendable {
    public var state: TelegramAuthState = .disconnected
    public var network: TelegramNetworkState = .waiting
    public var attemptID = UUID()
    public var revision: UInt64 = 0
    public var isSubmitting = false
    public var failure: TelegramFailure?
    public var optionsVerified = false
    public var receivedNotificationSnapshot = false
    public init() {}
}

/// Pure auth reducer, shared across windows. Ok responses never imply Ready.
struct TelegramAuthorizationMachine: Sendable {
    enum Effect { case none, initialize, qr, identify, closed }
    var snapshot = TelegramSnapshot()
    var authorizationReady = false
    var cleanup = false

    mutating func transition(_ state: TDLibMessage, now: Date) -> Effect {
        snapshot.revision &+= 1
        snapshot.isSubmitting = false
        snapshot.failure = nil
        if cleanup, state.type != "authorizationStateClosed" {
            snapshot.state = .loggingOut
            return .none
        }
        switch state.type {
        case "authorizationStateWaitTdlibParameters": snapshot.state = .starting; return .initialize
        case "authorizationStateWaitPhoneNumber": snapshot.state = .requestingQR; return .qr
        case "authorizationStateWaitOtherDeviceConfirmation":
            guard let link = state["link"]?.string, link.hasPrefix("tg://login?token="), link.utf8.count < 8192 else {
                snapshot.state = .unsupported; snapshot.failure = .unsupported; return .none
            }
            snapshot.state = .qr(link: link)
        case "authorizationStateWaitPassword": snapshot.state = .password(hint: state["password_hint"]?.string ?? "")
        case "authorizationStateWaitCode":
            let info = state["code_info"]?.object
            let type = info?["type"]?.object?.type
            let delivery: String
            switch type {
            case "authenticationCodeTypeTelegramMessage": delivery = "Enter the code sent in Telegram."
            case "authenticationCodeTypeSms": delivery = "Enter the code sent by SMS."
            case "authenticationCodeTypeSmsWord": delivery = "Enter the word sent by SMS."
            case "authenticationCodeTypeSmsPhrase": delivery = "Enter the phrase sent by SMS."
            case "authenticationCodeTypeCall": delivery = "Enter the code from Telegram's phone call."
            case "authenticationCodeTypeFlashCall": delivery = "Enter the phone number from Telegram's flash call."
            case "authenticationCodeTypeMissedCall": delivery = "Enter the requested digits from Telegram's missed call."
            default: snapshot.state = .unsupported; snapshot.failure = .unsupported; return .none
            }
            let canResend = info?["next_type"]?.object != nil
            snapshot.state = .code(TelegramCodeInfo(delivery: delivery,
                resendAvailableAt: canResend ? now.addingTimeInterval(Double(max(0, info?["timeout"]?.integer ?? 0))) : nil))
        case "authorizationStateWaitEmailAddress": snapshot.state = .emailAddress
        case "authorizationStateWaitEmailCode":
            snapshot.state = .emailCode(pattern: state["code_info"]?.object?["email_address_pattern"]?.string ?? "")
        case "authorizationStateReady": authorizationReady = true; snapshot.state = .verifyingAccount; return .identify
        case "authorizationStateLoggingOut": authorizationReady = false; snapshot.state = .reauthenticationRequired
        case "authorizationStateClosing": snapshot.state = .closing
        case "authorizationStateClosed": authorizationReady = false; return .closed
        default: snapshot.state = .unsupported; snapshot.failure = .unsupported
        }
        return .none
    }
}

public enum TelegramAuthInput: Sendable {
    case phone(String), code(String), email(String), emailCode(String), password(String), resend
}

public protocol TelegramConnector: Sendable {
    func snapshots() async -> AsyncStream<TelegramSnapshot>
    func restore() async
    func connect() async
    func retry() async
    func usePhone(attemptID: UUID, revision: UInt64) async
    func useQR(attemptID: UUID, revision: UInt64) async
    func submit(_ input: TelegramAuthInput, attemptID: UUID, revision: UInt64) async
    func disconnect() async
    func removeLocalData() async
    func close() async -> Bool
}
