import Foundation
import Observation

struct RemoteSSHProcessResult: Equatable, Sendable {
    let exitCode: Int32
    var output = Data()
}

typealias RemoteSSHRunner = @Sendable (String, [String], Data?, TimeInterval) async -> RemoteSSHProcessResult

enum RemoteClaudeAccountState: Equatable, Sendable {
    case unchecked, checking, notInstalled, current, stale, installing, removing
    case failed(RemoteClaudeAccountFailure)

    var failureMessage: String? {
        if case .failed(let reason) = self { return reason.message }
        return nil
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum RemoteClaudeAccountFailure: Equatable, Sendable {
    case connection, permissions, localToken, invalidRecord, missingAccount, changedAccount

    var message: String {
        switch self {
        case .connection: "The SSH connection failed. Check the connection and try again."
        case .permissions: "The server couldn’t write the account file. Check permissions and try again."
        case .localToken: "The account token couldn’t be read from Keychain. Replace it and try again."
        case .invalidRecord: "The account file on this server couldn’t be read. Install the account again."
        case .missingAccount: "This Claude account is no longer available."
        case .changedAccount: "The account changed while this action was waiting. Review the current account and try again."
        }
    }
}

/// No per-host facts are archived: a status is evidence from this app session.
@MainActor @Observable
final class RemoteClaudeAccountService {
    private struct Key: Hashable { let accountID: UUID; let host: String }
    private struct Entry { var state: RemoteClaudeAccountState; var revision: UUID? }
    private var entries: [Key: Entry] = [:]
    @ObservationIgnored private let accounts: ClaudeAccountStore
    @ObservationIgnored private let runner: RemoteSSHRunner
    @ObservationIgnored private var operations: [Key: Task<RemoteClaudeAccountState, Never>] = [:]

    init(accounts: ClaudeAccountStore, runner: @escaping RemoteSSHRunner = { executable, arguments, input, timeout in
        await Task.detached(priority: .userInitiated) {
            AgentPadShellIntegration.runSSHProcess(executable, arguments, stdin: input, timeout: timeout,
                captureOutput: input == nil)
        }.value
    }) {
        self.accounts = accounts; self.runner = runner
    }

    func state(accountID: UUID, host: String) -> RemoteClaudeAccountState {
        guard let entry = entries[Key(accountID: accountID, host: host)] else { return .unchecked }
        if entry.state == .current || entry.state == .stale {
            return entry.revision == accounts.account(accountID)?.credentialRevision ? .current : .stale
        }
        return entry.state
    }

    /// The launch guard is newer evidence than a successful preflight.
    func recordLaunchRefusal(accountID: UUID, host: String, exitCode: Int) -> RemoteClaudeAccountState? {
        let state: RemoteClaudeAccountState
        switch exitCode {
        case Int(RemoteClaudeAccount.missingExit): state = .notInstalled
        case Int(RemoteClaudeAccount.staleExit): state = .stale
        default: return nil
        }
        return publish(state, key: Key(accountID: accountID, host: host))
    }

    @discardableResult
    func check(accountID: UUID, host: String) async -> RemoteClaudeAccountState {
        await perform(.check, accountID: accountID, host: host)
    }

    @discardableResult
    func install(accountID: UUID, host: String, expectedRevision: UUID? = nil) async -> RemoteClaudeAccountState {
        await perform(.install, accountID: accountID, host: host, expectedRevision: expectedRevision)
    }

    @discardableResult
    func remove(accountID: UUID, host: String, expectedRevision: UUID? = nil) async -> RemoteClaudeAccountState {
        await perform(.remove, accountID: accountID, host: host, expectedRevision: expectedRevision)
    }

    private enum Operation { case check, install, remove }

    private func perform(_ operation: Operation, accountID: UUID, host: String,
                         expectedRevision: UUID? = nil) async -> RemoteClaudeAccountState {
        let key = Key(accountID: accountID, host: host)
        while let pending = operations[key] { _ = await pending.value }
        let task = Task { [self] in
            defer { operations[key] = nil }
            return await run(operation, key: key, expectedRevision: expectedRevision)
        }
        operations[key] = task
        return await task.value
    }

    private func run(_ operation: Operation, key: Key, expectedRevision: UUID?) async -> RemoteClaudeAccountState {
        guard let account = accounts.account(key.accountID) else { return publish(.failed(.missingAccount), key: key) }
        // Revalidate after waiting for this host's previous operation. Nothing
        // below may read a token or mutate a host under superseded consent.
        if let expectedRevision, expectedRevision != account.credentialRevision {
            return publish(.failed(.changedAccount), key: key)
        }
        switch operation {
        case .check:
            publish(.checking, key: key)
            let result = await request(host: key.host, command: RemoteClaudeAccount.checkCommand(accountID: key.accountID))
            if result.exitCode == RemoteClaudeAccount.missingExit { return publish(.notInstalled, key: key) }
            guard result.exitCode == 0 else { return publish(.failed(failure(result.exitCode, reading: true)), key: key) }
            guard let revision = UUID(uuidString: String(decoding: result.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)) else { return publish(.failed(.invalidRecord), key: key) }
            entries[key] = Entry(state: .current, revision: revision)
        case .install:
            guard let token = try? accounts.token(id: key.accountID) else { return publish(.failed(.localToken), key: key) }
            publish(.installing, key: key)
            let input = Data((account.credentialRevision.uuidString + "\n" + token + "\n").utf8)
            let result = await request(host: key.host, command: RemoteClaudeAccount.installCommand(accountID: key.accountID,
                revision: account.credentialRevision), input: input)
            guard result.exitCode == 0 else { return publish(.failed(failure(result.exitCode)), key: key) }
            entries[key] = Entry(state: .current, revision: account.credentialRevision)
        case .remove:
            publish(.removing, key: key)
            let result = await request(host: key.host, command: RemoteClaudeAccount.removeCommand(accountID: key.accountID))
            return publish(result.exitCode == 0 ? .notInstalled : .failed(failure(result.exitCode)), key: key)
        }
        return state(accountID: key.accountID, host: key.host)
    }

    private func failure(_ exitCode: Int32, reading: Bool = false) -> RemoteClaudeAccountFailure {
        exitCode == 46 ? (reading ? .invalidRecord : .permissions) : .connection
    }

    @discardableResult private func publish(_ state: RemoteClaudeAccountState, key: Key) -> RemoteClaudeAccountState {
        entries[key] = Entry(state: state, revision: nil)
        return state
    }

    private func request(host: String, command: String, input: Data? = nil) async -> RemoteSSHProcessResult {
        guard !host.isEmpty, !host.hasPrefix("-"), !host.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else { return RemoteSSHProcessResult(exitCode: -1) }
        let connectionOptions = input == nil ? AgentPadShellIntegration.sshMultiplexOptions
            : AgentPadShellIntegration.sshCredentialOptions
        let arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
            + connectionOptions + [host, command]
        return await runner("/usr/bin/ssh", arguments, input, 20)
    }
}

enum RemoteClaudeAccount {
    static let missingExit: Int32 = 44
    static let staleExit: Int32 = 45

    private static func record(_ accountID: UUID) -> String {
        "'\(accountID.uuidString).credential'"
    }

    /// Walk from HOME one component at a time, pinning each verified inode as
    /// cwd. A rename of an ancestor cannot redirect subsequent record access.
    private static func privateDirectory(create: Bool = false, absentExit: Int32 = missingExit) -> String {
        """
        umask 077
        _agentpad_uid=$(id -u) || exit 46
        _agentpad_stat() {
            stat -c '%u:%a:%d:%i' -- "$1" 2>/dev/null || stat -f '%u:%Lp:%d:%i' -- "$1" 2>/dev/null
        }
        _agentpad_enter() {
            [ ! -L "$1" ] || exit 46
            if [ ! -e "$1" ]; then
                \(create ? "mkdir -m 700 -- \"$1\" || exit 46" : "exit \(absentExit)")
            fi
            [ -d "$1" ] || exit 46
            _agentpad_before=$(_agentpad_stat "$1") || exit 46
            case "$_agentpad_before" in "$_agentpad_uid":700:*) ;; *) exit 46 ;; esac
            CDPATH= cd -P -- "$1" || exit 46
            [ "$(_agentpad_stat .)" = "$_agentpad_before" ] || exit 46
        }
        CDPATH= cd -P -- "$HOME" || exit 46
        _agentpad_enter .agentpad
        _agentpad_enter claude-accounts
        """
    }

    private static func shell(_ script: String) -> String {
        "/usr/bin/env -u BASH_ENV -u ENV /bin/sh +x -c "
            + AgentPadShellIntegration.quote("ulimit -c 0 || exit 46\n" + script)
    }

    static func checkCommand(accountID: UUID) -> String {
        shell("""
        \(privateDirectory())
        _agentpad_record=\(record(accountID))
        [ ! -L "$_agentpad_record" ] || exit 46
        [ -e "$_agentpad_record" ] || exit \(missingExit)
        [ -f "$_agentpad_record" ] && [ -r "$_agentpad_record" ] || exit 46
        IFS= read -r _agentpad_revision < "$_agentpad_record" || exit 46
        printf '%s\\n' "$_agentpad_revision" | LC_ALL=C grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' || exit 46
        printf '%s\\n' "$_agentpad_revision"
        """)
    }

    static func installCommand(accountID: UUID, revision: UUID) -> String {
        shell("""
        \(privateDirectory(create: true))
        _agentpad_record=\(record(accountID))
        [ ! -L "$_agentpad_record" ] || exit 46
        [ ! -e "$_agentpad_record" ] || [ -f "$_agentpad_record" ] || exit 46
        _agentpad_temp='.\(accountID.uuidString).'$$
        set -C
        exec 3> "$_agentpad_temp" || exit 46
        set +C
        trap 'rm -f -- "$_agentpad_temp"' EXIT
        trap 'exit 46' HUP INT TERM
        IFS= read -r _agentpad_revision && IFS= read -r _agentpad_oauth || exit 46
        [ "$_agentpad_revision" = '\(revision.uuidString)' ] && [ -n "$_agentpad_oauth" ] || exit 46
        IFS= read -r _agentpad_extra && exit 46
        [ -z "$_agentpad_extra" ] || exit 46
        printf '%s\\n%s\\n' "$_agentpad_revision" "$_agentpad_oauth" >&3 || exit 46
        exec 3>&-
        mv -f -- "$_agentpad_temp" "$_agentpad_record" || exit 46
        """)
    }

    static func removeCommand(accountID: UUID) -> String {
        shell("""
        \(privateDirectory(absentExit: 0))
        _agentpad_record=\(record(accountID))
        [ ! -L "$_agentpad_record" ] || exit 46
        rm -f -- "$_agentpad_record"
        """)
    }

    /// Evaluated on the remote after its login files. No server helper or
    /// settings probe is installed; the token enters only exec's environment.
    static func command(accountID: UUID, revision: UUID, launch: String, launchID: UUID? = nil) -> String {
        let removals = (ClaudeAccountSettings.competingEnvironmentKeys + ["BASH_ENV", "ENV"])
            .map { "-u " + $0 }.joined(separator: " ")
        let script = """
        \(launchID.map { id in """
        trap '_agentpad_status=$?; case "$_agentpad_status" in 44|45) printf "\\033]2;\(AgentLaunchExitMarker.prefix)\(id.uuidString):%s\\007" "$_agentpad_status" >&2 ;; esac' EXIT
        """ } ?? "")
        _agentpad_launch_directory=$PWD
        \(privateDirectory())
        _agentpad_record=\(record(accountID))
        [ ! -L "$_agentpad_record" ] && [ -f "$_agentpad_record" ] && [ -r "$_agentpad_record" ] || exit \(missingExit)
        exec 3< "$_agentpad_record" || exit \(missingExit)
        IFS= read -r _agentpad_revision <&3 || exit \(missingExit)
        [ "$_agentpad_revision" = '\(revision.uuidString)' ] || exit \(staleExit)
        IFS= read -r _agentpad_oauth <&3 || exit \(missingExit)
        exec 3<&-
        [ -n "$_agentpad_oauth" ] || exit \(missingExit)
        # Record access is complete. Restore the caller's working directory
        # for the agent; no credential path is resolved again.
        CDPATH= cd -P -- "$_agentpad_launch_directory" || exit \(missingExit)
        for _agentpad_key in $(/usr/bin/env | sed -n 's/^\\(CLAUDE_CODE_USE_[A-Za-z0-9_]*\\)=.*/\\1/p'); do unset "$_agentpad_key"; done
        CLAUDE_CODE_OAUTH_TOKEN="$_agentpad_oauth" exec \(launch)
        """
        return "/usr/bin/env \(removals) " + shell(script)
    }
}
