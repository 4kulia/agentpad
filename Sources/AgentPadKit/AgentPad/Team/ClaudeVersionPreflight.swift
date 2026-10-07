import Darwin
import Foundation

/// Y2: the selected name is not the name passed to exec. Metadata describes
/// the final file, including nanoseconds; it is not a signature of its contents.
struct ClaudeExecutable: Codable, Hashable, Sendable {
    let selectedPath: String
    let file: File

    struct File: Codable, Hashable, Sendable {
        var resolvedPath: String
        var device: Int32
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
    }

    static func inspect(_ selected: String) throws -> Self {
        func unavailable() -> TeamRunnerError {
            .didNotStart(ClaudeLaunchDiagnostic(version: nil, exitCode: nil, fallback: .unavailable).message)
        }
        guard selected.hasPrefix("/") else { throw unavailable() }
        let resolved = URL(fileURLWithPath: selected).resolvingSymlinksInPath().path
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw unavailable() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              access(resolved, X_OK) == 0 else { throw unavailable() }
        var magic: UInt32 = 0
        guard read(fd, &magic, 4) == 4,
              [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe,
               0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) else {
            throw TeamRunnerError.didNotStart("Укажите конечный нативный бинарник Claude Code. "
                + ClaudeLaunchDiagnostic(version: nil, exitCode: nil, fallback: .spawn).message)
        }
        return Self(selectedPath: selected, file: File(
            resolvedPath: resolved, device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        ))
    }
}

struct ClaudeVersionGrant: Codable, Hashable, Sendable {
    let version: String
    let file: ClaudeExecutable.File
    let profile: TeamAccessProfile
    let configuration: String
}

/// Local settings, deliberately separate from the shipped evidence matrix and
/// from D9. Only the owner's button writes a grant. No pending run is persisted.
@MainActor @Observable
final class ClaudeVersionApprovals {
    static let shared = ClaudeVersionApprovals(defaults: .standard)
    static let settingsKey = "AgentPad.claudeVersionGrants.v1"
    static let executableKey = "AgentPad.claudeExecutablePath.v1"

    struct Pending: Identifiable {
        let id: UUID
        let executable: ClaudeExecutable
        let grant: ClaudeVersionGrant
        let agentName: String
        let callId: String?

        var message: String {
            let basis = ClaudeVersionMatrix.basis(version: ClaudeVersionMatrix.probeVersion, profile: .read,
                                                configuration: grant.configuration) != nil
                ? "Граница профилей без Bash проверена пробой на версии \(ClaudeVersionMatrix.probeVersion)"
                : "У конфигурации этой сборки нет проверенного основания границы профилей без Bash"
            return """
            Версия Claude Code \(grant.version) не проверена для профиля «\(grant.profile.title)». \(basis); на версии \(grant.version) ограничения могут работать иначе, граница доступа не гарантируется. Запрос ждёт вашего решения. Разрешить версию \(grant.version) для этого файла и профиля? Разрешение сохранится и будет действовать для следующих запросов этого профиля, пока не сменится версия или файл. Решение сохранится на этом Mac для следующих запросов с этим файлом, версией, профилем и конфигурацией AgentPad. Каждый запрос по-прежнему требует отдельного разрешения.
            """
        }
        var allowTitle: String { "Разрешить версию \(grant.version)" }
        static let declineTitle = "Отклонить запуск"
    }

    private final class Wait: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
        var answer: Bool?
        let validate: @MainActor @Sendable () throws -> Void
        init(validate: @escaping @MainActor @Sendable () throws -> Void) { self.validate = validate }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private let defaults: UserDefaults?
    private var grants: Set<ClaudeVersionGrant>
    private var waits: [UUID: Wait] = [:]
    private(set) var pending: [Pending] = []
    private(set) var admissions: [String: ClaudeVersionPreflight.Ready] = [:]
    private(set) var selectedPath: String?
    var onChange: () -> Void = {}

    /// nil is an isolated, in-memory settings store (tests).
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        selectedPath = defaults?.string(forKey: Self.executableKey)
        grants = defaults?.data(forKey: Self.settingsKey).flatMap {
            try? JSONDecoder().decode(Set<ClaudeVersionGrant>.self, from: $0)
        } ?? []
    }

    func contains(_ grant: ClaudeVersionGrant) -> Bool { grants.contains(grant) }

    /// Explicit owner choice; the preflight itself never chooses a fallback.
    func selectExecutable(_ path: String?) {
        selectedPath = path
        defaults?.set(path, forKey: Self.executableKey)
    }

    func remember(_ ready: ClaudeVersionPreflight.Ready, callId: String?) {
        guard let callId else { return }
        admissions[callId] = ready
        // Transient UI detail only, not a second permission store.
        if admissions.count > 100 { admissions = [callId: ready] }
    }

    func decide(_ id: UUID, allow: Bool) {
        guard let wait = waits[id], let item = pending.first(where: { $0.id == id }),
              (try? wait.validate()) != nil else { return }
        wait.lock.withLock {
            guard !wait.cancelled, wait.answer == nil else { return }
            if allow {
                grants.insert(item.grant)
                if let data = try? JSONEncoder().encode(grants) { defaults?.set(data, forKey: Self.settingsKey) }
            }
            wait.answer = allow
        }
    }

    func require(_ grant: ClaudeVersionGrant, executable: ClaudeExecutable, request: TeamRunRequest,
                 onActivity: @escaping @Sendable (String) -> Void) async throws {
        try ClaudeVersionPreflight.checkCancellation()
        try request.validateBeforeExecutor?()
        if contains(grant) { return }
        let wait = Wait(validate: request.validateBeforeExecutor ?? {})
        let item = Pending(id: UUID(), executable: executable, grant: grant,
                           agentName: request.agent.name, callId: request.runToolsCallId)
        pending.append(item)
        waits[item.id] = wait
        onChange()
        defer {
            pending.removeAll { $0.id == item.id }
            waits[item.id] = nil
            onChange()
        }
        try await withTaskCancellationHandler {
            var nextActivity = ContinuousClock.now
            while true {
                try ClaudeVersionPreflight.checkCancellation()
                try wait.validate()
                if let answer = wait.lock.withLock({ wait.answer }) {
                    guard answer else { throw TeamRunnerError.didNotStart("version_not_allowed") }
                    return
                }
                // Another waiting request may have obtained the same exact
                // permission. One owner decision serves that combination.
                if contains(grant) { return }
                if ContinuousClock.now >= nextActivity {
                    onActivity("Ожидает разрешения владельца на версию Claude Code \(grant.version)")
                    nextActivity = .now + .seconds(2)
                }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { throw TeamRunnerError.cancelledBeforeExecutor }
            }
        } onCancel: { wait.cancel() }
    }
}

/// One last successful version reading in memory. A cached version is neither
/// evidence nor permission. All dependencies can be isolated by tests.
protocol ClaudeVersionChecking: Sendable {
    func prepare(selectedPath: String, request: TeamRunRequest,
                 onActivity: @escaping @Sendable (String) -> Void) async throws -> ClaudeVersionPreflight.Ready
    func verify(_ executable: ClaudeExecutable) throws
}

final class ClaudeVersionPreflight: ClaudeVersionChecking, @unchecked Sendable {
    static let shared = ClaudeVersionPreflight()
    typealias Inspect = @Sendable (String) throws -> ClaudeExecutable
    typealias ReadVersion = @Sendable (ClaudeExecutable, TeamRunRequest) async throws -> String
    private let inspect: Inspect
    private let readVersion: ReadVersion
    private let approvals: @MainActor @Sendable () -> ClaudeVersionApprovals
    let configuration: String
    private let lock = NSLock()
    private var cached: (ClaudeExecutable.File, String)?

    init(configuration: String = ClaudeVersionMatrix.configuration,
         inspect: @escaping Inspect = ClaudeExecutable.inspect,
         readVersion: @escaping ReadVersion = ClaudeVersionCommand.read,
         approvals: @escaping @MainActor @Sendable () -> ClaudeVersionApprovals = { .shared }) {
        self.configuration = configuration
        self.inspect = inspect
        self.readVersion = readVersion
        self.approvals = approvals
    }

    static func checkCancellation() throws {
        if Task.isCancelled { throw TeamRunnerError.cancelledBeforeExecutor }
    }

    func verify(_ executable: ClaudeExecutable) throws {
        guard (try? inspect(executable.selectedPath)) == executable else {
            lock.withLock { cached = nil }
            throw TeamRunnerError.didNotStart("Claude Code изменился во время подготовки запуска. Повторите запрос")
        }
    }

    struct Ready: Sendable {
        let executable: ClaudeExecutable
        let version: String
        let basis: String
    }

    func prepare(selectedPath: String, request: TeamRunRequest,
                 onActivity: @escaping @Sendable (String) -> Void) async throws -> Ready {
        try Self.checkCancellation()
        let executable = try inspect(selectedPath)
        let version: String
        if let hit = lock.withLock({ cached }), hit.0 == executable.file {
            version = hit.1
        } else {
            // Failure must not leave an older success available for this file.
            lock.withLock { cached = nil }
            version = try await readVersion(executable, request)
            try verify(executable)
            lock.withLock { cached = (executable.file, version) }
        }
        try Self.checkCancellation()
        let basis: String
        if let tested = ClaudeVersionMatrix.basis(version: version, profile: request.agent.access, configuration: configuration) {
            basis = tested
        } else {
            let grant = ClaudeVersionGrant(version: version, file: executable.file,
                                           profile: request.agent.access, configuration: configuration)
            try await approvals().require(grant, executable: executable, request: request, onActivity: onActivity)
            basis = "Непроверенная версия, разрешена владельцем"
        }
        try await request.validateBeforeExecutor?()
        try Self.checkCancellation()
        try verify(executable)
        let ready = Ready(executable: executable, version: version, basis: basis)
        await approvals().remember(ready, callId: request.runToolsCallId)
        return ready
    }
}

/// No shell, help command, prompt or MCP. The same final path and environment
/// as the executor; a separate journal identity, never onProcessStarted.
enum ClaudeVersionCommand {
    static let unreadable = TeamRunnerError.didNotStart(
        "Не удалось определить версию Claude Code. Проверьте выбранную установку и повторите запрос")

    static func parse(_ data: Data, exitCode: Int32, overflow: Bool = false) throws -> String {
        guard exitCode == 0, !overflow, data.count <= 4096, let text = String(data: data, encoding: .utf8) else { throw unreadable }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)? \(Claude Code\)\z"#,
                         options: .regularExpression) != nil else { throw unreadable }
        return String(line.dropLast(" (Claude Code)".count))
    }

    static func read(_ executable: ClaudeExecutable, request: TeamRunRequest) async throws -> String {
        try await read(executable, request: request, timeout: .seconds(3))
    }

    static func read(_ executable: ClaudeExecutable, request: TeamRunRequest, timeout: Duration,
                     timing: TeamRunStop.Timing = .init(grace: .milliseconds(200), killWait: .seconds(1), output: .seconds(1)),
                     isolatedConfigDirectory: URL? = nil, isolatedHomeDirectory: URL? = nil) async throws -> String {
        try ClaudeVersionPreflight.checkCancellation()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let woke = TeamExit(), exited = TeamExit(), outDone = TeamExit(), errDone = TeamExit()
        let bytes = VersionBytes()
        for (pipe, done, isError) in [(output, outDone, false), (errors, errDone, true)] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; done.finish(0) }
                else if bytes.append(data, isError: isError) { woke.finish(2) }
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
        }
        let spawned: TeamSpawned
        do {
            spawned = try TeamSpawn.suspended(
                path: executable.file.resolvedPath, arguments: ["--version"],
                environment: try environment(executable: executable.file.resolvedPath, request: request,
                                             isolatedConfigDirectory: isolatedConfigDirectory, isolatedHomeDirectory: isolatedHomeDirectory),
                directory: request.agent.folder, stdin: input, stdout: output, stderr: errors)
        } catch {
            throw TeamRunnerError.didNotStart(ClaudeLaunchDiagnostic(version: nil, exitCode: nil, fallback: .spawn).message)
        }
        try? input.fileHandleForWriting.close()
        spawned.onExit { exited.finish($0); woke.finish(1) }
        let seen = TeamPidSet()
        let registered = TeamProcesses.shared.add(spawned.identity, seen: seen, callId: nil, spawned: spawned,
                                                   agentId: request.agent.id.uuidString.lowercased())
        var recordingError: Error?
        do { try request.onPreflightProcess?(spawned.identity) } catch { recordingError = error }
        let watcher = Task.detached {
            while !Task.isCancelled {
                if let found = TeamProcesses.descendantIdentities(of: spawned.identity.identity) { seen.insert(found) }
                else { seen.markIncomplete() }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let stop = TeamRunStop(spawned: spawned, seen: seen, output: [outDone, errDone], timing: timing,
                               beforeVerdict: { watcher.cancel(); _ = await watcher.value })
        stop.finished.onFinish { woke.finish(3) }
        if !registered || recordingError != nil || Task.isCancelled { spawned.kill() }
        else { kill(spawned.pid, SIGCONT) }
        let ended = await withTaskCancellationHandler {
            await woke.wait(timeout: timeout)
        } onCancel: { stop.begin() }
        let cleanup = await stop.outcome()
        watcher.cancel()
        guard cleanup == .stopped else {
            TeamProcesses.shared.markLeftOver(spawned.identity, outputOpen: !stop.sawOutputClosed)
            throw TeamRunnerError.preflightCleanupUnconfirmed(spawned.identity, cleanup)
        }
        TeamProcesses.shared.remove(spawned.identity)
        spawned.release()
        do { try request.onPreflightProcess?(nil) } catch {
            throw TeamRunnerError.didNotStart("Не удалось записать завершение проверки версии Claude Code: \(error.localizedDescription)")
        }
        try ClaudeVersionPreflight.checkCancellation()
        guard registered, recordingError == nil, ended == 1, let code = exited.exitCode else {
            throw bytes.failure(exitCode: exited.exitCode, timedOut: ended == nil)
        }
        do { return try bytes.version(exitCode: code) }
        catch { throw bytes.failure(exitCode: code) }
    }

    static func environment(executable: String, request: TeamRunRequest, isolatedConfigDirectory: URL?,
                            isolatedHomeDirectory: URL? = nil) throws -> [String: String] {
        let runner = ClaudeCodeRunner(claudePath: executable, sessionFilesRoot: isolatedConfigDirectory?.appendingPathComponent("projects") ?? TeamSessionFiles.root,
                                      isolatedConfigDirectory: isolatedConfigDirectory, isolatedHomeDirectory: isolatedHomeDirectory)
        return try runner.executionEnvironment(claudePath: executable, isolateGit: !request.agent.access.takesCommands,
                                                ownersPath: request.agent.access.runsShell)
    }

    private final class VersionBytes: @unchecked Sendable {
        private let lock = NSLock()
        private var output = Data()
        private var errors = Data()
        private var count = 0
        private var overflow = false
        func append(_ data: Data, isError: Bool) -> Bool {
            lock.withLock {
                count += data.count
                overflow = overflow || count > 4096
                if !isError, !overflow { output.append(data) }
                if isError, !overflow { errors.append(data) }
                return overflow
            }
        }
        func version(exitCode: Int32) throws -> String {
            try lock.withLock { try ClaudeVersionCommand.parse(output, exitCode: exitCode, overflow: overflow) }
        }
        func failure(exitCode: Int32?, timedOut: Bool = false) -> TeamRunnerError {
            lock.withLock {
                let diagnostic = ClaudeLaunchDiagnostic(
                    version: try? ClaudeVersionCommand.parse(output, exitCode: 0, overflow: overflow),
                    exitCode: timedOut ? nil : exitCode,
                    output: String(decoding: errors, as: UTF8.self), fallback: .version)
                return .didNotStart(diagnostic.message + (timedOut ? " Время ожидания истекло." : ""))
            }
        }
    }
}
