import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class AllSessionsTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("all-sessions-\(UUID())") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func record(_ id: String, agent: String = "codex", folder: String = "/tmp/Café", time: TimeInterval = 1, automatic: Bool = false) -> AgentSessionRecord {
        .init(agentId: agent, conversationId: id, title: "Сессия \(id)", cwd: URL(fileURLWithPath: folder), lastActivity: Date(timeIntervalSince1970: time),
              firstPrompt: "Проверить клавиатуру. Release café", automatic: automatic)
    }
    private func live(_ record: AgentSessionRecord, status: AllSessionStatus = .working, id: String = "live") -> AllSessionItem {
        .init(id: id, record: record, source: .own(UUID()), status: status, title: record.title)
    }
    func testSearchIsFoldedAllWordsAcrossMetadataAndManualNames() {
        let a = record("one")
        for query in ["ПРОВЕРИТЬ", "клавиатуру CAFE", "RELEASE cafe", "tmp КЛАВИАТУРУ"] {
            XCTAssertEqual(AllSessionsList.filter(records: [a], live: [], names: [:], query: query, filters: .init()).shown, 1, query)
        }
        XCTAssertEqual(AllSessionsList.filter(records: [a], live: [], names: [a.nameKey: "Особое имя"], query: "ОСОБОЕ cafe", filters: .init()).shown, 1)
        XCTAssertEqual(AllSessionsList.filter(records: [a], live: [], names: [:], query: "release missing", filters: .init()).shown, 0)
    }
    func testChronologicalOrderHasFullTiesAndFolderGrouping() {
        let records = [record("b", folder: "/z", time: 3), record("a", folder: "/z", time: 3), record("x", agent: "claude-code", folder: "/a", time: 3), record("new", folder: "/a", time: 4)]
        let expected = ["new", "x", "a", "b"]
        for input in [records, Array(records.reversed())] {
            XCTAssertEqual(AllSessionsList.filter(records: Array(input), live: [], names: [:], query: "", filters: .init()).items.map { $0.record.conversationId }, expected)
        }
        let grouped = AllSessionsList.filter(records: records, live: [], names: [:], query: "", filters: .init(grouping: .folder))
        XCTAssertEqual(grouped.sections.map(\.id), ["/a", "/z"])
        XCTAssertEqual(grouped.items.map { $0.record.conversationId }, expected)
    }
    func testLiveProcessesAreIndependentButSuppressOnlyTheirDiskRecord() {
        let a = record("same")
        let rows = [live(a, id: "own"), live(a, status: .needsInput, id: "external-1"), live(a, status: .idle, id: "external-2")]
        let result = AllSessionsList.filter(records: [a], live: rows, names: [:], query: "", filters: .init())
        XCTAssertEqual(result.shown, 3)
        XCTAssertEqual(Set(result.items.map(\.id)), ["own", "external-1", "external-2"])
        XCTAssertFalse(result.items.contains { $0.source == .disk })
        let ended = AllSessionsList.filter(records: [a], live: [], names: [:], query: "", filters: .init())
        XCTAssertEqual(ended.items.first?.source, .disk)
    }
    func testEveryFilterDimensionAndAutomaticCriticalExceptions() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), recent = record("recent", time: now.timeIntervalSince1970)
        let old = record("old", agent: "claude-code", folder: "/other", time: 1)
        let automatic = record("automatic", automatic: true)
        let liveRows = [live(automatic, status: .needsInput, id: "waiting"), live(automatic, status: .error, id: "failed"), live(automatic, status: .working, id: "working")]
        let defaults = AllSessionsList.filter(records: [recent, old, automatic], live: liveRows, names: [:], query: "", filters: .init(), now: now)
        XCTAssertEqual(defaults.shown, 4); XCTAssertEqual(defaults.hiddenAutomatic, 1)
        for period in [AllSessionsFilterState.Period.today, .week, .month] {
            XCTAssertEqual(AllSessionsList.filter(records: [recent, old], live: [], names: [:], query: "", filters: .init(period: period), now: now).shown, 1)
        }
        XCTAssertEqual(AllSessionsList.filter(records: [recent, old], live: [], names: [:], query: "", filters: .init(tool: "claude-code")).items.first?.record.conversationId, "old")
        XCTAssertEqual(AllSessionsList.filter(records: [recent, old], live: [], names: [:], query: "", filters: .init(folder: "/other")).shown, 1)
        XCTAssertEqual(AllSessionsList.filter(records: [recent], live: liveRows, names: [:], query: "", filters: .init(status: .error)).items.map(\.id), ["failed"])
        XCTAssertEqual(AllSessionsList.filter(records: [recent], live: liveRows, names: [:], query: "", filters: .init(hideAutomatic: false)).shown, 4)
        for status in AllSessionStatus.allCases {
            let filtered = AllSessionsList.filter(records: [recent], live: [live(old, status: status)], names: [:], query: "", filters: .init(status: status))
            XCTAssertTrue(filtered.items.allSatisfy { $0.status == status })
        }
    }
    func testWindowScopedRouteFiltersRestoreWithoutSearchAndDoNotCreateTerminal() throws {
        let memory = InMemoryPersistence(), store = makeTestStore(persistence: InMemoryPersistence()), other = makeTestStore(persistence: memory)
        defer { store.terminate(); other.terminate() }
        let filters = AllSessionsFilterState(tool: "codex", folder: "/tmp", status: .idle, period: .month, hideAutomatic: false, grouping: .folder)
        var navigation = TabNavigation(); navigation.allSessions = filters
        let first = store.openToolTab(.allSessions, navigation: navigation)
        XCTAssertTrue(store.openToolTab(.allSessions) === first)
        let second = other.openToolTab(.allSessions, navigation: navigation)
        XCTAssertFalse(second === first)
        XCTAssertFalse(first.content.hasProcess)
        let data = try JSONEncoder().encode(first.tabState!.navigation)
        XCTAssertEqual(try JSONDecoder().decode(TabNavigation.self, from: data).allSessions, filters)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("query"))
        XCTAssertNotEqual(ToolRoute.allSessions.key(windowID: store.windowID), ToolRoute.allSessions.key(windowID: other.windowID))
        XCTAssertTrue(other.flushPersistence())
        let restored = makeTestStore(persistence: InMemoryPersistence(initial: memory.saved)); defer { restored.terminate() }
        XCTAssertEqual(restored.allSessions.first { $0.toolRoute == .allSessions }?.tabState?.navigation.allSessions, filters)
    }
    func testTenThousandRecordsFilterOffMainAndCancelsObsoleteQuery() async throws {
        let records = (0..<10_000).map { record("\($0)", time: Double($0)) }, calls = CatalogCounter(), stalls = CatalogCounter()
        let catalog = SessionCatalog { _ in .init(records: records, scanned: records.count, total: records.count, skipped: 0) }
        let model = AllSessionsModel(state: TabState(route: .allSessions), catalog: catalog, names: SessionNames(url: root.appendingPathComponent("names.sqlite")))
        model.visibility = { .init(channelIds: []) }
        model.filterWork = { records, live, names, query, filters in
            XCTAssertFalse(Thread.isMainThread); calls.increment()
            return AllSessionsList.filter(records: records, live: live, names: names, query: query, filters: filters)
        }
        let watchdog = MainThreadWatchdog(threshold: 0.25) { _ in stalls.increment() }
        watchdog.start(); defer { watchdog.stop(); model.stop() }
        await model.start()
        try await wait { !catalog.isScanning }
        model.refilter()
        try await wait { model.result.shown == 10_000 }
        model.query = "obsolete"; model.refilter(debounce: true)
        model.query = "Café"; model.filters.grouping = .folder; model.refilter(debounce: true)
        try await wait { calls.count >= 2 && model.result.sections.first?.id == "/tmp/Café" }
        XCTAssertEqual(model.result.shown, 10_000)
        XCTAssertEqual(stalls.count, 0)
    }
    func testRenameWriteFailureKeepsInlineEditorAndSavedTitle() async throws {
        let record = record("one"), catalog = SessionCatalog { _ in .init(records: [], scanned: 0, total: 0, skipped: 0) }
        let names = SessionNames(url: root.appendingPathComponent("names.sqlite"))
        try await names.rename("Saved", for: record.nameKey)
        let model = AllSessionsModel(state: TabState(route: .allSessions), catalog: catalog, names: names)
        model.visibility = { .init(channelIds: []) }
        let item = live(record)
        model.beginRename(item); model.renameText = "Uncommitted"
        var locking = Configuration(); locking.allowsUnsafeTransactions = true
        let blocker = try DatabaseQueue(path: root.appendingPathComponent("names.sqlite").path, configuration: locking)
        try sql(blocker, "BEGIN EXCLUSIVE")
        await model.saveName(item)
        XCTAssertEqual(model.renamingID, item.id); XCTAssertNotNil(model.renameError)
        XCTAssertEqual(names.values[record.nameKey], "Saved")
        try sql(blocker, "ROLLBACK")
        await model.saveName(item)
        XCTAssertNil(model.renamingID); XCTAssertEqual(names.values[record.nameKey], "Uncommitted")
        XCTAssertNil(model.renameError); XCTAssertNil(names.problem)
    }
    func testChannelPolicyIsRecheckedForCachedRecordsAndLiveRows() async throws {
        let record = record("channel", agent: "claude-code")
        let catalog = SessionCatalog { _ in .init(records: [record], scanned: 1, total: 1, skipped: 0) }
        let model = AllSessionsModel(state: TabState(route: .allSessions), catalog: catalog, names: SessionNames(url: root.appendingPathComponent("names.sqlite")))
        model.visibility = { .init(channelIds: []) }
        await model.start(); try await wait { !catalog.isScanning }
        model.refilter(); try await wait { model.result.shown == 1 }
        model.visibility = { .init(channelIds: ["channel"]) }
        model.updateLive([live(record)])
        try await wait { model.result.shown == 0 }
        XCTAssertEqual(model.result.total, 0)
        model.stop()
    }
    private func sql(_ queue: DatabaseQueue, _ sql: String) throws { try queue.writeWithoutTransaction { try $0.execute(sql: sql) } }
    func testResumeRefusalIsInlineAndSuccessfulSplitMovesOnlyNewSession() async throws {
        let fixture = try ClaudeResumeFixture(), store = makeTestStore(claudeProjectsRoot: fixture.root)
        defer { store.terminate() }
        store.conversationVisibility = { .init(channelIds: []) }
        let tab = store.openToolTab(.allSessions)
        let catalog = SessionCatalog { _ in .init(records: [], scanned: 0, total: 0, skipped: 0) }
        let model = AllSessionsModel(state: tab.tabState!, catalog: catalog, names: SessionNames(url: root.appendingPathComponent("names.sqlite")))
        model.visibility = { .init(channelIds: []) }
        let before = store.allSessions.count
        let bad = record("invalid", agent: "unknown-tool")
        await AllSessionsActions.activate(.init(id: "bad", record: bad, source: .disk, status: .finished, title: "Bad"), model: model, store: store)
        XCTAssertNotNil(model.resumeError); XCTAssertEqual(store.allSessions.count, before)
        let good = SessionStoreFixtures.record(cwd: URL(fileURLWithPath: "/tmp"), conversationId: fixture.id)
        await AllSessionsActions.activate(.init(id: "good", record: good, source: .disk, status: .finished, title: "Good"), model: model, store: store, split: true)
        XCTAssertNil(model.resumeError)
        let workspace = try XCTUnwrap(store.active)
        XCTAssertEqual(workspace.root.allPanes.count, 2)
        XCTAssertEqual(workspace.root.allPanes.flatMap(\.tabs).count, before + 1)
        XCTAssertTrue(workspace.root.allPanes.contains { $0.tabs.contains { $0 === tab } })
        XCTAssertTrue(workspace.activePane?.tabs.contains { $0.resumedConversationId == fixture.id } == true)
    }

    private func actionModel() -> AllSessionsModel {
        AllSessionsModel(state: TabState(route: .allSessions),
            catalog: SessionCatalog { _ in .init(records: [], scanned: 0, total: 0, skipped: 0) },
            names: SessionNames(url: root.appendingPathComponent("names.sqlite")))
    }

    private func disk(_ record: AgentSessionRecord) -> AllSessionItem {
        .init(id: record.id, record: record, source: .disk, status: .finished, title: record.title)
    }

    func testStaleDiskRowFocusesExistingConversationAcrossWindowsWithoutResolvingOrSplitting() async throws {
        let first = makeTestStore(), second = makeTestStore(), monitor = AgentMonitor(), model = actionModel()
        defer { first.terminate(); second.terminate() }
        first.conversationVisibility = { .init(channelIds: []) }
        second.conversationVisibility = { .init(channelIds: []) }
        monitor.storesProvider = { [first, second] }
        var focused: [UUID] = []
        monitor.onActivate = { focused.append($0) }
        let item = disk(record(UUID().uuidString, agent: "claude-code"))
        let tab = first.addTab(in: first.workspaces[0], template: .claudeCode)
        let before = [first.allSessions.count, second.allSessions.count]
        // Persisted hook ID and the pre-hook resumed ID must both suppress a spawn.
        for useHookID in [true, false] {
            tab.conversationId = useHookID ? item.record.conversationId : nil
            tab.resumedConversationId = useHookID ? "older-conversation" : item.record.conversationId
            model.resumeError = "previous error"
            await AllSessionsActions.activate(item, model: model, store: second, split: true, monitor: monitor,
                resolveClaude: { _, _, _ in XCTFail("An open tab needs no transcript lookup"); return .failure(.notFound) })
            XCTAssertNil(model.resumeError)
            XCTAssertEqual(focused.last, tab.id)
            XCTAssertEqual([first.allSessions.count, second.allSessions.count], before)
            XCTAssertEqual(first.workspaces[0].root.allPanes.count, 1)
            XCTAssertEqual(second.workspaces[0].root.allPanes.count, 1)
        }
        XCTAssertEqual(focused.count, 2)
    }

    func testResumeIgnoresOtherAgentAndStaleResumeID() async throws {
        let fixture = try ClaudeResumeFixture(), store = makeTestStore(claudeProjectsRoot: fixture.root)
        defer { store.terminate() }
        store.conversationVisibility = { .init(channelIds: []) }
        let monitor = AgentMonitor(), model = actionModel()
        monitor.storesProvider = { [store] }
        monitor.onActivate = { _ in XCTFail("Neither tab is running this conversation") }
        let otherAgent = store.addTab(in: store.workspaces[0], template: .gemini)
        otherAgent.conversationId = fixture.id
        let cleared = store.addTab(in: store.workspaces[0], template: .claudeCode)
        cleared.conversationId = UUID().uuidString
        cleared.resumedConversationId = fixture.id
        let before = store.allSessions.count
        await AllSessionsActions.activate(disk(record(fixture.id, agent: "claude-code", folder: FileManager.default.temporaryDirectory.path)), model: model, store: store, monitor: monitor)
        XCTAssertNil(model.resumeError)
        XCTAssertEqual(store.allSessions.count, before + 1)
        XCTAssertEqual(store.active?.activeSession?.conversationId, fixture.id)
    }

    func testClaudeResumeResolvesOnceOffMainAndUsesResultForBothLandingPaths() async throws {
        // Exercise addTab and the new local workspace seed tab used from SSH-only windows.
        for onlySSH in [false, true] {
            let fixture = try ClaudeResumeFixture(), store = makeTestStore(claudeProjectsRoot: fixture.root)
            defer { store.terminate() }
            store.conversationVisibility = { .init(channelIds: []) }
            if onlySSH { store.workspaces[0].sshRemoteHost = "host" }
            let calls = CatalogCounter(), model = actionModel()
            let item = disk(record(fixture.id.uppercased(), agent: "claude-code", folder: FileManager.default.temporaryDirectory.path))
            await AllSessionsActions.activate(item, model: model, store: store, monitor: AgentMonitor(), resolveClaude: { id, root, visibility in
                XCTAssertFalse(Thread.isMainThread)
                calls.increment()
                let result = ClaudeSessionResume.resolve(id, root: root, visibility: visibility)
                // Any later resolver call would now fail, including command construction.
                do { try FileManager.default.removeItem(at: root) } catch { XCTFail("\(error)") }
                return result
            })
            XCTAssertEqual(calls.count, 1)
            XCTAssertNil(model.resumeError)
            let session = try XCTUnwrap(store.active?.activeSession)
            XCTAssertEqual(session.conversationId, fixture.id)
            XCTAssertEqual(session.resumedConversationId, fixture.id)
            XCTAssertNil(store.active?.sshRemoteHost)
            let engine = try XCTUnwrap(session.engine as? TestEngine)
            XCTAssertEqual(engine.startedConfigs.count, 1)
            XCTAssertEqual(engine.startedConfigs.first?.environment["AGENTPAD_AGENT"], "claude --resume \(fixture.id)")
        }
    }

    func testConcurrentResumesRecheckOtherWindowsAfterBackgroundResolution() async throws {
        let fixture = try ClaudeResumeFixture()
        let first = makeTestStore(claudeProjectsRoot: fixture.root), second = makeTestStore(claudeProjectsRoot: fixture.root)
        defer { first.terminate(); second.terminate() }
        first.conversationVisibility = { .init(channelIds: []) }
        second.conversationVisibility = { .init(channelIds: []) }
        let monitor = AgentMonitor(), firstModel = actionModel(), secondModel = actionModel()
        monitor.storesProvider = { [first, second] }
        var focused: UUID?
        monitor.onActivate = { focused = $0 }
        let item = disk(record(fixture.id, agent: "claude-code", folder: FileManager.default.temporaryDirectory.path)), entered = CatalogCounter()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let before = first.allSessions.count + second.allSessions.count
        let pending = Task {
            await AllSessionsActions.activate(item, model: firstModel, store: first, split: true, monitor: monitor, resolveClaude: { id, root, visibility in
                XCTAssertFalse(Thread.isMainThread)
                entered.increment()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return ClaudeSessionResume.resolve(id, root: root, visibility: visibility)
            })
        }
        try await wait { entered.count == 1 }
        await AllSessionsActions.activate(item, model: secondModel, store: second, monitor: monitor)
        let opened = try XCTUnwrap(second.active?.activeSession)
        release.signal()
        await pending.value
        XCTAssertNil(firstModel.resumeError); XCTAssertNil(secondModel.resumeError)
        XCTAssertEqual(focused, opened.id)
        XCTAssertEqual(first.allSessions.count + second.allSessions.count, before + 1)
        XCTAssertEqual(first.workspaces[0].root.allPanes.count, 1)
    }

    func testClosingOrStoppingAllSessionsCancelsPendingResume() async throws {
        for close in [false, true] {
            let fixture = try ClaudeResumeFixture(), store = makeTestStore(claudeProjectsRoot: fixture.root)
            defer { store.terminate() }
            store.conversationVisibility = { .init(channelIds: []) }
            let model = actionModel(), entered = CatalogCounter(), release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            model.state.allSessionsModel = model
            let before = store.allSessions.count
            model.resume {
                await AllSessionsActions.activate(self.disk(self.record(fixture.id, agent: "claude-code", folder: FileManager.default.temporaryDirectory.path)), model: model,
                    store: store, resolveClaude: { id, root, visibility in
                        entered.increment()
                        _ = release.wait(timeout: .now() + 5)
                        return ClaudeSessionResume.resolve(id, root: root, visibility: visibility)
                    })
            }
            let pending = try XCTUnwrap(model.resumeTask)
            try await wait { entered.count == 1 }
            if close { model.state.close() } else { model.stop() }
            XCTAssertTrue(pending.isCancelled)
            release.signal()
            await pending.value
            XCTAssertEqual(store.allSessions.count, before)
            XCTAssertNil(model.resumeError)
        }
    }

    func testClosedTabRejectsLateResumeEvenWithoutTaskCancellation() async throws {
        let fixture = try ClaudeResumeFixture(), store = makeTestStore(claudeProjectsRoot: fixture.root)
        defer { store.terminate() }
        store.conversationVisibility = { .init(channelIds: []) }
        let model = actionModel(), entered = CatalogCounter(), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let before = store.allSessions.count
        let pending = Task {
            await AllSessionsActions.activate(disk(record(fixture.id, agent: "claude-code", folder: FileManager.default.temporaryDirectory.path)), model: model,
                store: store, resolveClaude: { id, root, visibility in
                    entered.increment()
                    _ = release.wait(timeout: .now() + 5)
                    return ClaudeSessionResume.resolve(id, root: root, visibility: visibility)
                })
        }
        try await wait { entered.count == 1 }
        model.state.close()
        XCTAssertFalse(pending.isCancelled)
        release.signal()
        await pending.value
        XCTAssertEqual(store.allSessions.count, before)
    }

    func testBackgroundResumeRefusalDoesNotCreateTab() async throws {
        let fixture = try ClaudeResumeFixture(), store = makeTestStore(claudeProjectsRoot: fixture.root)
        defer { store.terminate() }
        store.conversationVisibility = { .init(channelIds: []) }
        let model = actionModel(), before = store.allSessions.count, calls = CatalogCounter()
        await AllSessionsActions.activate(disk(record(fixture.id, agent: "claude-code", folder: FileManager.default.temporaryDirectory.path)), model: model, store: store,
            monitor: AgentMonitor(), resolveClaude: { _, _, _ in
                XCTAssertFalse(Thread.isMainThread); calls.increment()
                return .failure(.notFound)
            })
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(model.resumeError, ClaudeSessionResume.Refusal.notFound.message)
        XCTAssertEqual(store.allSessions.count, before)
    }

    private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < end else { XCTFail("Model did not settle"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testOfflineStartupCatalogSearchPreviewResumeAndAttentionUseNoNetworkOrCredentials() async throws {
        let scope = TeamServiceTestScope(); defer { scope.close() }
        ChatStubProtocol.reset(); URLProtocol.registerClass(ChatStubProtocol.self)
        defer { URLProtocol.unregisterClass(ChatStubProtocol.self); ChatStubProtocol.reset() }
        let tokens = FakeTokenStore()
        let offline = ChatService(files: ChatFiles(directory: root.appendingPathComponent("offline")), tokens: tokens)
        var apiCalls = 0
        offline.makeAPI = { address in apiCalls += 1; return ChatAPI(server: address, protocolClasses: [ChatStubProtocol.self]) }
        try await offline.start(mode: .off)
        let fixture = try ClaudeResumeFixture()
        let roots = [AgentTemplate.claudeCodeID: fixture.root], cache = root.appendingPathComponent("session-headers.json")
        let catalog = SessionCatalog { progress in
            SessionCatalogScanner.scan(roots: roots, cacheURL: cache, visibility: .init(channelIds: []), progress: progress)
        }
        let store = makeTestStore(claudeProjectsRoot: fixture.root)
        store.conversationVisibility = { .init(channelIds: []) }
        let tab = store.openToolTab(.allSessions)
        let model = AllSessionsModel(state: tab.tabState!, catalog: catalog, names: SessionNames(url: root.appendingPathComponent("session-names.sqlite")))
        model.visibility = { .init(channelIds: []) }
        await model.start(); try await wait { !catalog.isScanning }
        model.query = "fixture"; model.refilter(debounce: true)
        try await wait { model.result.shown == 1 }
        let item = try XCTUnwrap(model.result.items.first)
        model.select(item); try await wait { !model.previewLoading }
        XCTAssertEqual(model.preview.first?.text, "fixture")
        await AllSessionsActions.activate(item, model: model, store: store)
        XCTAssertNil(model.resumeError)
        XCTAssertTrue(store.allSessions.contains { $0.resumedConversationId == fixture.id })
        let ledger = AttentionLedger()
        let event = AttentionEvent(source: "terminal", object: "local", kind: .input, destination: .terminal(UUID()))
        ledger.upsert(event)
        let attention = AttentionSidebarModel(); attention.refresh(service: offline, ledger: ledger)
        XCTAssertEqual(AttentionList.items(ledger: ledger.events, current: attention.serverCurrent).count, 1)
        XCTAssertNil(attention.aggregates.gate); XCTAssertTrue(attention.aggregates.mentions.isEmpty)
        XCTAssertEqual(apiCalls, 0); XCTAssertEqual(ChatStubProtocol.seen.count, 0)
        XCTAssertEqual(tokens.calls, 0); XCTAssertTrue(tokens.items.isEmpty)
        XCTAssertTrue(offline.orgSessions.isEmpty); XCTAssertNil(offline.connection)
        model.stop()
    }
}
