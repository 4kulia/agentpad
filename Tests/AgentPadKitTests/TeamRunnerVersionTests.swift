import Darwin
import XCTest
@testable import AgentPadKit

/// The failure table in DESIGN-Y2 §4. All files, processes and settings are
/// isolated; the native fixture never calls Claude Code or accesses credentials.
@MainActor
final class TeamRunnerVersionTests: XCTestCase {
    var root: URL!
    var binary: URL!
    var approvals: ClaudeVersionApprovals!
    var preflight: ClaudeVersionPreflight!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("y2-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binary = try NativeVersionFixture.make(in: root)
        approvals = ClaudeVersionApprovals()
        let approvals = approvals!
        preflight = ClaudeVersionPreflight(approvals: { approvals })
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func request(_ profile: TeamAccessProfile = .read, resume: Bool = false) -> TeamRunRequest {
        TeamRunRequest(agent: TeamPublishedAgent(name: "y2", description: "test", folder: root.path, access: profile),
                       prompt: "test", sessionId: UUID().uuidString, resume: resume, callerName: "test", callerProject: nil)
    }

    func setVersion(_ text: String) throws { try text.write(to: root.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8) }
    func count(_ name: String) -> Int { ((try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "").count }
    func runner(_ path: String? = nil) -> ClaudeCodeRunner { ClaudeCodeRunner(claudePath: path ?? binary.path, preflight: preflight) }
    func wait(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    func failure(_ operation: () async throws -> Void, contains text: String,
                 file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("unexpected success", file: file, line: line) }
        catch { XCTAssertTrue(error.localizedDescription.contains(text), "\(error)", file: file, line: line) }
    }

    // §4.1: exact, shipped evidence for no-Bash profiles only.
    func testMatrixAndNativeCache() async throws {
        for profile in [TeamAccessProfile.read, .editFiles] {
            _ = try await runner().run(request(profile), onActivity: { _ in })
        }
        XCTAssertEqual(count("versions"), 1)
        XCTAssertEqual(count("runs"), 2)
        for profile in [TeamAccessProfile.readGit, .edit] {
            XCTAssertNil(ClaudeVersionMatrix.basis(version: "2.1.289", profile: profile, configuration: ClaudeVersionMatrix.configuration))
        }
        for version in ["2.1.288", "2.1.290", "2.1.289-beta", "2.1.289+build"] {
            XCTAssertNil(ClaudeVersionMatrix.basis(version: version, profile: .read, configuration: ClaudeVersionMatrix.configuration))
        }
        XCTAssertNil(ClaudeVersionMatrix.basis(version: "2.1.289", profile: .read, configuration: "changed"))
        XCTAssertNil(TeamAccessProfile(rawValue: "unrecognized"))
    }

    // §4.2–3: one wait, one decision, same process, no onProcessStarted while waiting.
    func testUnknownVersionWaitsThenRunsOnceAndRemainsUntested() async throws {
        try setVersion("2.1.290 (Claude Code)\n")
        let starts = Counter(), activity = TeamValueBox<String>()
        let task = Task { try await runner().run(request(), onActivity: { activity.set($0) }, onProcessStarted: { _ in starts.increment() }) }
        try await wait { self.approvals.pending.count == 1 }
        XCTAssertEqual(count("runs"), 0)
        XCTAssertEqual(starts.value, 0)
        let item = try XCTUnwrap(approvals.pending.first)
        XCTAssertTrue(item.message.contains("сохранится"))
        XCTAssertTrue(item.message.contains("для следующих запросов"))
        XCTAssertTrue(item.message.contains("Разрешение сохранится и будет действовать для следующих запросов этого профиля, пока не сменится версия или файл."))
        XCTAssertTrue(item.message.contains("2.1.289"))
        XCTAssertTrue(item.message.contains("Каждый запрос по-прежнему требует отдельного разрешения"))
        XCTAssertEqual(item.executable.selectedPath, binary.path)
        XCTAssertEqual(item.allowTitle, "Разрешить версию 2.1.290")
        XCTAssertEqual(ClaudeVersionApprovals.Pending.declineTitle, "Отклонить запуск")
        XCTAssertEqual(activity.get(), "Ожидает разрешения владельца на версию Claude Code 2.1.290")
        XCTAssertFalse(activity.get()?.contains(root.path) ?? true)
        // Collapsing a card has no state transition or implicit answer.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(approvals.pending.count, 1)
        approvals.decide(item.id, allow: true)
        approvals.decide(item.id, allow: true)
        _ = try await task.value
        XCTAssertEqual(starts.value, 1)
        _ = try await runner().run(request(), onActivity: { _ in })
        XCTAssertEqual(count("versions"), 1)
        XCTAssertEqual(count("runs"), 2)
        let ready = try await preflight.prepare(selectedPath: binary.path, request: request(), onActivity: { _ in })
        XCTAssertEqual(ready.basis, "Непроверенная версия, разрешена владельцем")
        XCTAssertNil(ClaudeVersionMatrix.basis(version: ready.version, profile: .read, configuration: ClaudeVersionMatrix.configuration))
    }

    func testSuffixAndBashProfileRequireTheirOwnDecision() async throws {
        for (version, profile) in [("2.1.289-beta", TeamAccessProfile.read), ("2.1.289", .readGit), ("2.1.289", .edit)] {
            try setVersion(version + " (Claude Code)\n")
            let approvals = approvals!
            let check = ClaudeVersionPreflight(approvals: { approvals })
            let task = Task { try await check.prepare(selectedPath: binary.path, request: request(profile), onActivity: { _ in }) }
            try await wait { !self.approvals.pending.isEmpty }
            let item = try XCTUnwrap(approvals.pending.first)
            XCTAssertEqual(item.grant.version, version)
            XCTAssertEqual(item.grant.profile, profile)
            approvals.decide(item.id, allow: false)
            await failure({ _ = try await task.value }, contains: "version_not_allowed")
        }
        XCTAssertEqual(count("runs"), 0)
    }

    // §4.5–7: no fallback, wrappers never execute (including --version).
    func testMissingUnavailableAndWrappersRefuseBeforeVersion() async throws {
        XCTAssertThrowsError(try ClaudeCodeRunner.selectClaude(explicit: nil, configured: nil, locate: { nil })) {
            XCTAssertEqual($0 as? TeamRunnerError, .claudeNotFound)
        }
        XCTAssertEqual(try ClaudeCodeRunner.selectClaude(explicit: "/chosen/claude", configured: nil, locate: { "/path/claude" }), "/chosen/claude")
        XCTAssertEqual(try ClaudeCodeRunner.selectClaude(explicit: nil, configured: "/configured/claude", locate: { "/path/claude" }), "/configured/claude")
        let wrapper = root.appendingPathComponent("wrapper")
        try "#!/bin/sh\ntouch '\(root.path)/WRAPPER-RAN'\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let link = root.appendingPathComponent("shim")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: wrapper)
        for path in [wrapper.path, link.path] {
            await failure({ _ = try await self.runner(path).run(self.request(), onActivity: { _ in }) }, contains: "конечный нативный бинарник")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("WRAPPER-RAN").path))
        await failure({ _ = try await self.runner(self.root.appendingPathComponent("missing").path).run(self.request(), onActivity: { _ in }) }, contains: "недоступен")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binary.path)
        await failure({ _ = try await self.runner().run(self.request(), onActivity: { _ in }) }, contains: "недоступен")
        XCTAssertEqual(count("versions"), 0)
        XCTAssertEqual(count("runs"), 0)
        XCTAssertTrue(TeamRunnerError.claudeNotFound.localizedDescription.contains("Установите его"))
    }

    // §4.8,12: version, environment and executor use the chosen final file.
    func testSelectedNameFinalPathAndSwitchAfterLastCheck() async throws {
        let installation = root.appendingPathComponent("installation")
        try FileManager.default.createDirectory(at: installation, withIntermediateDirectories: true)
        let installed = installation.appendingPathComponent("claude")
        try FileManager.default.moveItem(at: binary, to: installed)
        binary = installed
        let link = root.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        let before = try ClaudeExecutable.inspect(link.path)
        let reads = Counter(), inspections = Counter()
        let other = root.appendingPathComponent("other")
        try FileManager.default.copyItem(at: binary, to: other)
        let check = ClaudeVersionPreflight(inspect: { name in
            let found = try ClaudeExecutable.inspect(name)
            inspections.increment()
            if inspections.value == 4 { // Last verify returns its snapshot; symlink switches immediately after.
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
            }
            return found
        }, readVersion: { executable, request in
            reads.increment()
            XCTAssertEqual(executable, before)
            return try await ClaudeVersionCommand.read(executable, request: request)
        })
        var req = request()
        let ready = TeamValueBox<ClaudeVersionPreflight.Ready>()
        req.onVersionReady = { ready.set($0) }
        _ = try await ClaudeCodeRunner(claudePath: link.path, preflight: check).run(req, onActivity: { _ in })
        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(ready.get()?.executable.selectedPath, link.path)
        XCTAssertEqual(ready.get()?.executable.file.resolvedPath, binary.path)
        let executed = try String(contentsOf: root.appendingPathComponent("executed-path"), encoding: .utf8)
        XCTAssertEqual(executed, binary.path)
        let versioned = try String(contentsOf: root.appendingPathComponent("version-path"), encoding: .utf8)
        XCTAssertEqual(versioned, binary.path)
        let path = try String(contentsOf: root.appendingPathComponent("executor-env-path"), encoding: .utf8)
        XCTAssertTrue(path.split(separator: ":").contains(Substring(binary.deletingLastPathComponent().path)))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("version-env-path"), encoding: .utf8), path)
    }

    // §4.9: precise parsing, hard byte/time limits, no caching of failures.
    func testVersionFormatLimitsAndFailureIsNotCached() async throws {
        for text in ["", "error 2.1.289", "2.1.289", "2.1.289 (Claude Code)\n2.1.290 (Claude Code)", "bad\n2.1.289 (Claude Code)", "2.1.289 (Claude Code)\nwarning"] {
            XCTAssertThrowsError(try ClaudeVersionCommand.parse(Data(text.utf8), exitCode: 0))
        }
        XCTAssertThrowsError(try ClaudeVersionCommand.parse(Data("2.1.289 (Claude Code)".utf8), exitCode: 1))
        XCTAssertThrowsError(try ClaudeVersionCommand.parse(Data(repeating: 32, count: 4097), exitCode: 0))
        XCTAssertEqual(try ClaudeVersionCommand.parse(Data("2.1.289-beta+1 (Claude Code)".utf8), exitCode: 0), "2.1.289-beta+1")
        for mode in ["error", "overflow", "garbage", "hang"] {
            try setVersion(mode)
            let began = ContinuousClock.now
            await failure({ _ = try await self.runner().run(self.request(), onActivity: { _ in }) }, contains: "Не удалось определить версию")
            if mode == "hang" { XCTAssertLessThan(ContinuousClock.now - began, .seconds(5), "three seconds plus confirmed cleanup") }
        }
        try setVersion("2.1.289 (Claude Code)\n")
        _ = try await runner().run(request(), onActivity: { _ in })
        XCTAssertEqual(count("versions"), 5)
        XCTAssertEqual(count("runs"), 1)
    }

    // §4.10: every part of a grant is significant; only exact persisted grants survive restart.
    func testGrantBindingAndPersistence() async throws {
        let suite = "y2-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClaudeVersionApprovals(defaults: defaults)
        store.selectExecutable(binary.path)
        XCTAssertEqual(ClaudeVersionApprovals(defaults: defaults).selectedPath, binary.path)
        store.selectExecutable(nil)
        XCTAssertNil(ClaudeVersionApprovals(defaults: defaults).selectedPath)
        let check = ClaudeVersionPreflight(readVersion: { _, _ in "2.1.290" }, approvals: { store })
        let task = Task { try await check.prepare(selectedPath: binary.path, request: request(), onActivity: { _ in }) }
        try await wait { store.pending.count == 1 }
        let grant = try XCTUnwrap(store.pending.first?.grant)
        store.decide(try XCTUnwrap(store.pending.first?.id), allow: true)
        _ = try await task.value
        let reopened = ClaudeVersionApprovals(defaults: defaults)
        guard reopened.contains(grant) else { return XCTFail("the exact grant was not persisted") }
        XCTAssertEqual(reopened.pending.count, 0, "no run resumes after restart")
        let files: [ClaudeExecutable.File] = [
            { var f = grant.file; f.resolvedPath += "-new"; return f }(),
            { var f = grant.file; f.device += 1; return f }(),
            { var f = grant.file; f.inode += 1; return f }(),
            { var f = grant.file; f.size += 1; return f }(),
            { var f = grant.file; f.modifiedSeconds += 1; return f }(),
            { var f = grant.file; f.modifiedNanoseconds += 1; return f }(),
        ]
        for file in files {
            XCTAssertFalse(reopened.contains(.init(version: grant.version, file: file, profile: grant.profile, configuration: grant.configuration)))
        }
        XCTAssertFalse(reopened.contains(.init(version: "2.1.291", file: grant.file, profile: grant.profile, configuration: grant.configuration)))
        XCTAssertFalse(reopened.contains(.init(version: grant.version, file: grant.file, profile: .editFiles, configuration: grant.configuration)))
        XCTAssertFalse(reopened.contains(.init(version: grant.version, file: grant.file, profile: grant.profile, configuration: "new")))
        let afterRestart = ClaudeVersionPreflight(readVersion: { _, _ in "2.1.290" }, approvals: { reopened })
        let ready = try await afterRestart.prepare(selectedPath: binary.path, request: request(), onActivity: { _ in })
        XCTAssertEqual(ready.basis, "Непроверенная версия, разрешена владельцем")
    }

    func testCacheInvalidationIncludesIdentitySizeNanosecondsAndSymlinkTarget() async throws {
        let original = try ClaudeExecutable.inspect(binary.path)
        let current = TeamValueBox<ClaudeExecutable>(); current.set(original)
        let reads = Counter()
        let check = ClaudeVersionPreflight(inspect: { _ in current.get()! }, readVersion: { _, _ in reads.increment(); return "2.1.289" })
        func prepare() async throws { _ = try await check.prepare(selectedPath: binary.path, request: request(), onActivity: { _ in }) }
        try await prepare(); try await prepare()
        XCTAssertEqual(reads.value, 1)
        var file = original.file
        for change in 0..<6 {
            switch change {
            case 0: file.resolvedPath += "-new"
            case 1: file.device += 1
            case 2: file.inode += 1
            case 3: file.size += 1
            case 4: file.modifiedSeconds += 1
            default: file.modifiedNanoseconds += 1
            }
            current.set(.init(selectedPath: original.selectedPath, file: file))
            try await prepare()
            XCTAssertEqual(reads.value, change + 2)
        }
    }

    // §4.11: replacement at each control check refuses and clears the cache.
    func testDetectedReplacementAtEveryCheckRefuses() async throws {
        for at in [2, 3, 4] {
            let inspections = Counter(), reads = Counter()
            let original = try ClaudeExecutable.inspect(binary.path)
            let check = ClaudeVersionPreflight(inspect: { _ in
                inspections.increment()
                var file = original.file
                if inspections.value >= at { file.inode += 1 }
                return .init(selectedPath: original.selectedPath, file: file)
            }, readVersion: { _, _ in reads.increment(); return "2.1.289" })
            let runner = ClaudeCodeRunner(claudePath: binary.path, preflight: check)
            await failure({ _ = try await runner.run(self.request(), onActivity: { _ in }) }, contains: "изменился")
            XCTAssertEqual(count("runs"), 0)
            _ = try await check.prepare(selectedPath: binary.path, request: request(), onActivity: { _ in })
            XCTAssertEqual(reads.value, 2, "change invalidated the cache")
        }
    }

    func testChangedFileWhileOwnerDecidesCannotUseOldGrant() async throws {
        try setVersion("2.1.290 (Claude Code)\n")
        let task = Task { try await runner().run(request(), onActivity: { _ in }) }
        try await wait { !self.approvals.pending.isEmpty }
        let item = try XCTUnwrap(approvals.pending.first)
        let replacement = root.appendingPathComponent("replacement")
        try FileManager.default.copyItem(at: binary, to: replacement)
        try FileManager.default.removeItem(at: binary)
        try FileManager.default.moveItem(at: replacement, to: binary)
        approvals.decide(item.id, allow: true)
        await failure({ _ = try await task.value }, contains: "изменился")
        XCTAssertFalse(approvals.contains(.init(version: item.grant.version, file: try ClaudeExecutable.inspect(binary.path).file,
                                              profile: item.grant.profile, configuration: item.grant.configuration)))
        XCTAssertEqual(count("runs"), 0)
    }

    func testGrantedFoldersAreRecheckedAfterOwnerWaitInitialAndResume() async throws {
        try await replacedGrantDuringWait(ownerDecision: true)
    }

    func testGrantedFoldersAreRecheckedAfterVersionProbeInitialAndResume() async throws {
        try await replacedGrantDuringWait(ownerDecision: false)
    }

    private func replacedGrantDuringWait(ownerDecision: Bool) async throws {
        for resume in [false, true] {
            let store = ClaudeVersionApprovals()
            let checker = ClaudeVersionPreflight(approvals: { store })
            try setVersion(ownerDecision ? "2.1.290 (Claude Code)\n" : "2.1.289 (Claude Code)\n")
            let hold = root.appendingPathComponent("version-hold")
            if !ownerDecision { try Data().write(to: hold) }
            let grant = root.appendingPathComponent("grant-\(resume)")
            let outside = root.appendingPathComponent("outside-\(resume)")
            try FileManager.default.createDirectory(at: grant, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            var req = request(resume: resume)
            req.agent.extraFolders = [grant.path]
            let starts = Counter(), versionsBefore = count("versions")
            let task = Task {
                try await ClaudeCodeRunner(claudePath: binary.path, preflight: checker)
                    .run(req, onActivity: { _ in }, onProcessStarted: { _ in starts.increment() })
            }
            defer { task.cancel(); try? FileManager.default.removeItem(at: hold) }
            try await wait { ownerDecision ? !store.pending.isEmpty : self.count("versions") > versionsBefore }
            XCTAssertEqual(starts.value, 0)
            try FileManager.default.removeItem(at: grant)
            try FileManager.default.createSymbolicLink(at: grant, withDestinationURL: outside)
            if ownerDecision {
                store.decide(try XCTUnwrap(store.pending.first?.id), allow: true)
            } else {
                try FileManager.default.removeItem(at: hold)
            }
            await failure({ _ = try await task.value }, contains: "granted_folders_changed")
            XCTAssertEqual(starts.value, 0, "no executor for resume=\(resume)")
            XCTAssertEqual(count("runs"), 0)
        }
    }

    func testGrantedFoldersMustAlreadyBeCanonicalBeforePreflight() async throws {
        let folder = root.appendingPathComponent("granted")
        let child = folder.appendingPathComponent("child")
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        for path in [link.path, link.appendingPathComponent("child").path, folder.path + "/child/..", "relative"] {
            var req = request()
            req.agent.extraFolders = [path]
            await failure({ _ = try await self.runner().run(req, onActivity: { _ in }) }, contains: "granted_folders_changed")
        }
        XCTAssertEqual(count("versions"), 0)
        XCTAssertEqual(count("runs"), 0)
        var valid = request()
        valid.agent.extraFolders = [folder.path, child.path]
        _ = try await runner().run(valid, onActivity: { _ in })
        XCTAssertEqual(count("runs"), 1)
    }

    // §4.13,16: a live process survives an installation change; next process,
    // including forks and resumed threads, does not inherit version permission.
    func testUpdateDoesNotStopLiveRunAndNextForkAndResumeRecheck() async throws {
        try "yes".write(to: root.appendingPathComponent("run-hold"), atomically: true, encoding: .utf8)
        let starts = Counter()
        let task = Task { try await runner().run(request(), onActivity: { _ in }, onProcessStarted: { _ in starts.increment() }) }
        try await wait { self.count("runs") == 1 }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: binary.path)
        try setVersion("2.1.290 (Claude Code)\n")
        try await Task.sleep(for: .milliseconds(100))
        try FileManager.default.removeItem(at: root.appendingPathComponent("run-hold"))
        let answer = try await task.value
        XCTAssertFalse(answer.isError)
        for resume in [false, true] {
            var req = request()
            if !resume { req.agent.sessionId = UUID().uuidString }
            let next = TeamRunRequest(agent: req.agent, prompt: req.prompt, sessionId: req.sessionId, resume: resume,
                                      callerName: req.callerName, callerProject: nil)
            let waiting = Task { try await runner().run(next, onActivity: { _ in }) }
            try await wait { !self.approvals.pending.isEmpty }
            approvals.decide(try XCTUnwrap(approvals.pending.first?.id), allow: false)
            await failure({ _ = try await waiting.value }, contains: "version_not_allowed")
        }
        XCTAssertEqual(starts.value, 1)
        XCTAssertEqual(count("versions"), 2)
        XCTAssertEqual(count("runs"), 1)
    }

    // §4.17–18: actual --version group stopped; owner wait has no process.
    func testStopDuringVersionAndOwnerWaitNeverCreatesExecutor() async throws {
        for version in ["hang", "2.1.290 (Claude Code)\n"] {
            try setVersion(version)
            let starts = Counter(), helper = TeamStartBox()
            var req = request()
            req.onPreflightProcess = { if let start = $0 { helper.set(start) } }
            let task = Task { try await runner().run(req, onActivity: { _ in }, onProcessStarted: { _ in starts.increment() }) }
            try await wait { helper.get() != nil && (version == "hang" || !self.approvals.pending.isEmpty) }
            let pending = approvals.pending.first
            task.cancel()
            do { _ = try await task.value; XCTFail("not cancelled") }
            catch { XCTAssertEqual(error as? TeamRunnerError, .cancelledBeforeExecutor) }
            if let pending { approvals.decide(pending.id, allow: true); XCTAssertFalse(approvals.contains(pending.grant)) }
            XCTAssertEqual(starts.value, 0)
            XCTAssertEqual(count("runs"), 0)
            XCTAssertEqual(TeamProcesses.liveness(try XCTUnwrap(helper.get()).identity), .gone)
            XCTAssertTrue(approvals.pending.isEmpty)
        }
    }

    func testCancellationBeforeVersionCreatesNoProcess() async throws {
        let starts = Counter()
        let check = preflight!
        let path = binary.path, req = request()
        let gate = TeamExit()
        let task = Task {
            _ = await gate.wait(timeout: .seconds(1))
            return try await ClaudeCodeRunner(claudePath: path, preflight: check).run(req, onActivity: { _ in }, onProcessStarted: { _ in starts.increment() })
        }
        task.cancel(); gate.finish(0)
        do { _ = try await task.value; XCTFail("not cancelled") }
        catch { XCTAssertEqual(error as? TeamRunnerError, .cancelledBeforeExecutor) }
        XCTAssertEqual(count("versions"), 0)
        XCTAssertEqual(starts.value, 0)
    }

    func testOneDecisionAlsoReleasesOtherWaitersForTheSameGrant() async throws {
        let check = ClaudeVersionPreflight(readVersion: { _, _ in "2.1.290" }, approvals: { self.approvals })
        let first = Task { try await check.prepare(selectedPath: binary.path, request: request(), onActivity: { _ in }) }
        let second = Task { try await check.prepare(selectedPath: binary.path, request: request(), onActivity: { _ in }) }
        try await wait { self.approvals.pending.count == 2 }
        let item = try XCTUnwrap(approvals.pending.first)
        approvals.decide(item.id, allow: true)
        // A bounded assertion, even if the release regresses.
        try await wait { self.approvals.pending.isEmpty }
        if !approvals.pending.isEmpty { first.cancel(); second.cancel() }
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(count("runs"), 0)
        let noEvidence = ClaudeVersionApprovals.Pending(id: UUID(), executable: item.executable,
            grant: .init(version: item.grant.version, file: item.grant.file, profile: .read, configuration: "changed"),
            agentName: "test", callId: nil)
        XCTAssertTrue(noEvidence.message.contains("нет проверенного основания"))
        XCTAssertFalse(noEvidence.message.contains("проверена пробой на версии"))
    }

    func testNativeSymlinkCacheAndNewTargetRequireAnotherVersionRead() async throws {
        let link = root.appendingPathComponent("selected")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        for _ in 0..<2 { _ = try await preflight.prepare(selectedPath: link.path, request: request(), onActivity: { _ in }) }
        XCTAssertEqual(count("versions"), 1)
        let other = root.appendingPathComponent("other")
        try FileManager.default.copyItem(at: binary, to: other)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        _ = try await preflight.prepare(selectedPath: link.path, request: request(), onActivity: { _ in })
        XCTAssertEqual(count("versions"), 2)
        XCTAssertEqual(count("runs"), 0)
    }

    func testVersionJournalFailureCleansUpAndIsDidNotStart() async throws {
        let helper = TeamStartBox()
        var req = request()
        req.onPreflightProcess = { start in
            if let start { helper.set(start) }
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            _ = try await runner().run(req, onActivity: { _ in })
            XCTFail("journal failure did not refuse")
        } catch {
            guard case .didNotStart = error as? TeamRunnerError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(TeamProcesses.liveness(try XCTUnwrap(helper.get()).identity), .gone)
        XCTAssertFalse(TeamProcesses.shared.blocks(agentId: req.agent.id.uuidString.lowercased()))
        XCTAssertEqual(count("runs"), 0)
    }
}

@MainActor
enum NativeVersionFixture {
    static func make(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("fixture.c")
        let executable = directory.appendingPathComponent("native-claude")
        try #"""
        #include <stdio.h>
        #include <string.h>
        #include <unistd.h>
        #include <stdlib.h>
        static void save(const char *name, const char *s, const char *mode) {
            FILE *f = fopen(name, mode); if (f) { fputs(s, f); fclose(f); }
        }
        int main(int argc, char **argv) {
            if (argc == 2 && !strcmp(argv[1], "--version")) {
                save("versions", "x", "a"); save("version-path", argv[0], "w");
                save("version-env-path", getenv("PATH") ? getenv("PATH") : "", "w");
                char version[8192] = "2.1.289 (Claude Code)\n";
                FILE *f = fopen("version.txt", "r");
                if (f) { size_t n = fread(version, 1, sizeof(version)-1, f); version[n] = 0; fclose(f); }
                if (!strcmp(version, "hang")) { sleep(30); return 0; }
                if (!strcmp(version, "error")) { puts("2.1.289 (Claude Code)"); return 1; }
                if (!strcmp(version, "overflow")) { for (int i=0; i<5000; i++) putchar(' '); puts("2.1.289 (Claude Code)"); return 0; }
                while (!access("version-hold", F_OK)) usleep(10000);
                fputs(version, stdout); return 0;
            }
            save("runs", "x", "a"); save("executed-path", argv[0], "w");
            save("executor-env-path", getenv("PATH") ? getenv("PATH") : "", "w");
            while (!access("run-hold", F_OK)) usleep(10000);
            puts("{\"type\":\"result\",\"result\":\"fixture answer\",\"is_error\":false}");
            return 0;
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = [source.path, "-o", executable.path]
        compile.standardOutput = Pipe(); compile.standardError = Pipe()
        try compile.run(); compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0)
        return executable
    }
}
