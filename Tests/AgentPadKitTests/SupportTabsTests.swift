import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class SupportTabsTests: XCTestCase {
    private func empty(_ persistence: any Persistence = InMemoryPersistence()) -> WorkspaceStore {
        WorkspaceStore(persistence: persistence, initiallyEmpty: true, engineFactory: {
            XCTFail("support navigation allocated a terminal"); return TestEngine()
        })
    }
    func testStartupGateDefersEveryEntryWithoutHostOrAutosave() throws {
        for imported in [false, true] {
            let router = TabRouter()
            var hosts = 0
            let store = empty(); defer { store.terminate() }
            let gate = SupportTabNavigation(router: router)
            router.stores = { [store] }; router.ensureHost = { hosts += 1; return store }
            for section in SettingsTabSection.allCases { XCTAssertNil(gate.open(.settings, section: section)) }
            XCTAssertNil(gate.open(.notifications)); XCTAssertNil(gate.open(.linkFailure))
            XCTAssertEqual(hosts, 0); XCTAssertTrue(store.allSessions.isEmpty)
            XCTAssertTrue(store.popups.sessions.isEmpty); XCTAssertFalse(store.popups.isPresented)
            // The unchanged startup operation commits first; only then is the
            // Settings model constructed. Both import and fresh follow this gate.
            var values: [String: Any] = imported ? ["terminal": ["font-size": 17]] : [:]
            var writes = 0
            let model = AgentPadSettingsModel(read: { values }, write: { values = $0; writes += 1 }, appliesRuntimeEffects: false)
            XCTAssertEqual(writes, 0)
            gate.finishStartup()
            XCTAssertEqual(store.allSessions.map(\.toolRoute), [.notifications])
            XCTAssertEqual(store.popups.sessions.map(\.toolRoute), [.settings, .linkFailure])
            XCTAssertEqual(store.popups.sessions.first { $0.toolRoute == .settings }?.tabState?.navigation.settingsSection, .updates)
            model.addCustomAgent()
            try model.flushSaveChecked()
            let restored = AgentPadSettingsModel(read: { values }, write: { _ in }, appliesRuntimeEffects: false)
            XCTAssertEqual(restored.customAgents, model.customAgents)
            if imported { XCTAssertEqual(restored.fontSize, 17) }
        }
    }
    func testSupportSectionsUseOnePopupPerWindowAndRetainSectionUntilRelaunch() throws {
        let memory = InMemoryPersistence(), store = empty(InMemoryPersistence())
        let other = empty(memory)
        defer { store.terminate(); other.terminate() }
        let router = TabRouter(); router.stores = { [store, other] }; router.ensureHost = { store }
        let navigation = SupportTabNavigation(router: router); navigation.finishStartup()
        let first = try XCTUnwrap(navigation.open(.settings, section: .about))
        for section in SettingsTabSection.allCases {
            XCTAssertTrue(navigation.open(.settings, section: section) === first)
            XCTAssertEqual(first.tabState?.navigation.settingsSection, section)
        }
        let second = try XCTUnwrap(navigation.open(.settings, from: other, section: .advanced))
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.tabState?.navigation.settingsSection, .updates)
        XCTAssertTrue(store.allSessions.isEmpty); XCTAssertTrue(other.allSessions.isEmpty)
        XCTAssertTrue(other.flushPersistence())
        let restored = empty(InMemoryPersistence(initial: memory.saved)); defer { restored.terminate() }
        XCTAssertTrue(restored.allSessions.isEmpty)
        XCTAssertTrue(restored.popups.sessions.isEmpty); XCTAssertFalse(restored.popups.isPresented)
        other.popups.dismiss(reason: .dismiss)
        XCTAssertFalse(other.popups.isPresented)
        let reopened = try XCTUnwrap(navigation.open(.settings, from: other))
        XCTAssertTrue(reopened === second)
        XCTAssertEqual(reopened.tabState?.navigation.settingsSection, .advanced)
        XCTAssertNil(other.reopenLastClosedTab(), "Popup dismissal does not create closed tab history")
        XCTAssertEqual(restored.openToolTab(.settings).tabState?.navigation.settingsSection, .general)
    }
    func testUpdateCheckIsSingleFlightAndResultSurvivesReopening() async throws {
        var fetches = 0
        var resume: CheckedContinuation<UpdateChecker.Outcome, Never>?
        let model = UpdatesTabModel(currentVersion: "1.1.8", packaged: { false }, sparkleCheck: { XCTFail("fallback used Sparkle") },
                                    attention: UpdateAttention(ledger: AttentionLedger())) { version in
            XCTAssertEqual(version, "1.1.8"); fetches += 1
            return await withCheckedContinuation { resume = $0 }
        }
        model.check(); model.check()
        await Task.yield()
        XCTAssertEqual(fetches, 1); XCTAssertTrue(model.checking)
        resume?.resume(returning: .upToDate(current: "1.1.8"))
        let deadline = Date().addingTimeInterval(2)
        while model.checking, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.checking)
        guard case .upToDate = model.outcome else { return XCTFail("missing inline result") }
        _ = SettingsUpdatesView(model: model)
        XCTAssertEqual(fetches, 1, "mounting must not repeat a check")
        var sparkle = 0
        let packaged = UpdatesTabModel(packaged: { true }, sparkleCheck: { sparkle += 1 }, fetch: { _ in XCTFail("packaged fallback"); return .upToDate(current: "1.1.8") })
        packaged.check(); XCTAssertEqual(sparkle, 1)
    }
    func testLinkErrorsCoalesceAndNeverPersistOrLogRawURL() throws {
        let store = empty()
        defer { store.terminate() }
        let router = TabRouter(); router.stores = { [store] }; router.ensureHost = { store }
        let ledger = AttentionLedger()
        let support = SupportTabs(router: router, ledger: ledger); support.navigation.finishStartup()
        let marker = "SECRET-OTP-TOKEN-RAW-URL"
        for _ in 0..<5 { support.linkFailed("Invalid agentpad://resume?token=\(marker)") }
        XCTAssertTrue(store.allSessions.isEmpty)
        XCTAssertEqual(store.popups.sessions.count, 1)
        let popup = try XCTUnwrap(store.popups.sessions.first)
        let state = try XCTUnwrap(popup.tabState)
        XCTAssertEqual(state.message, LinkFailureMessage.parameters.text)
        let snapshot = try JSONEncoder().encode(PersistedTab(popup))
        XCTAssertFalse(String(decoding: snapshot, as: UTF8.self).contains(marker))
        for event in ledger.events where event.source == "link-failure" {
            XCTAssertFalse(event.body.contains(marker))
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains(marker))
        }
    }

    func testLinkFailureOKClosesAndNotificationsOpensItsExistingTab() async throws {
        let store = empty(); defer { store.terminate() }
        let router = TabRouter(); router.stores = { [store] }; router.ensureHost = { store }
        let support = SupportTabs(router: router, ledger: AttentionLedger())
        support.navigation.finishStartup()
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        support.linkFailed("Unavailable session")
        let state = try XCTUnwrap(store.popups.sessions.first?.tabState)
        let host = FoldersUIHost(support.content(state), width: 580, height: 280)
        defer { host.close() }
        try await host.settle()
        XCTAssertTrue(host.press("OK"))
        XCTAssertFalse(store.popups.isPresented)
        XCTAssertTrue(store.allSessions.isEmpty)

        let notifications = try XCTUnwrap(router.open(.notifications, from: store))
        support.linkFailed("Unavailable session")
        let next = try XCTUnwrap(store.popups.sessions.first?.tabState)
        let secondHost = FoldersUIHost(support.content(next), width: 580, height: 280)
        defer { secondHost.close() }
        try await secondHost.settle()
        XCTAssertTrue(secondHost.press("Open Notifications"))
        XCTAssertFalse(store.popups.isPresented)
        XCTAssertEqual(store.allSessions.map(\.id), [notifications.id])
        XCTAssertEqual(store.allSessions.map(\.toolRoute), [.notifications])
    }
    func testSettingsCloseFailureCannotBeBypassedAndDiscardRestoresSharedModel() throws {
        let store = empty(); defer { store.terminate() }
        let model = AgentPadSettingsModel(read: { [:] }, write: { _ in throw CocoaError(.fileWriteOutOfSpace) }, appliesRuntimeEffects: false)
        let support = SupportTabs(ledger: AttentionLedger()); support.settingsModel = { model }
        let session = store.openToolTab(.settings), state = try XCTUnwrap(session.tabState)
        _ = support.content(state)
        model.addCustomAgent()
        store.popups.dismiss(reason: .dismiss)
        XCTAssertNotNil(state.saveError); XCTAssertTrue(store.popups.isPresented)
        store.popups.dismiss(reason: .dismiss)
        XCTAssertTrue(store.popups.isPresented); XCTAssertTrue(store.popups.contains(session.id))
        store.popups.dismiss(reason: .cancel)
        XCTAssertTrue(model.customAgents.isEmpty)
        XCTAssertNil(model.saveError); XCTAssertFalse(model.isSaving)
        XCTAssertTrue(store.allSessions.isEmpty)
        XCTAssertFalse(store.popups.isPresented); XCTAssertFalse(store.popups.contains(session.id))
        XCTAssertTrue(state.isClosed)
    }
    func testSettingsReloadPreservesUnsavedEditsAndReadsExternalChangesWhenClean() throws {
        var values: [String: Any] = [:]
        let model = AgentPadSettingsModel(read: { values }, write: { values = $0 }, appliesRuntimeEffects: false)
        model.addCustomAgent(); model.reloadIfClean()
        XCTAssertEqual(model.customAgents.count, 1)
        try model.flushSaveChecked()
        values["terminal"] = ["font-size": 19]
        model.reloadIfClean()
        XCTAssertEqual(model.fontSize, 19)
    }
    func testSettingsLayoutSavePreservesExternalEditsWithoutReloading() throws {
        let store = empty(); defer { store.terminate() }
        var values: [String: Any] = ["terminal": ["font-size": 14]], writes = 0
        let model = AgentPadSettingsModel(read: { values }, write: { values = $0; writes += 1 }, appliesRuntimeEffects: false)
        let support = SupportTabs(ledger: AttentionLedger()); support.settingsModel = { model }
        let session = store.openToolTab(.settings)
        _ = support.content(try XCTUnwrap(session.tabState))
        XCTAssertTrue(store.flushPersistence())
        XCTAssertEqual(writes, 0, "opening Settings does not change settings.json")

        values["terminal"] = ["font-size": 19]
        XCTAssertTrue(store.flushPersistence())
        XCTAssertEqual((values["terminal"] as? [String: Any])?["font-size"] as? Int, 19)
        store.popups.dismiss(reason: .dismiss)
        XCTAssertTrue(store.allSessions.isEmpty)
        XCTAssertFalse(store.popups.isPresented)
        XCTAssertEqual(writes, 0, "layout saves and closing clean Settings must not write stale values")
    }
    func testSettingsDirtySaveRejectsExternalEditsUntilDiscarded() throws {
        var values: [String: Any] = ["terminal": ["font-size": 14]], writes = 0
        let model = AgentPadSettingsModel(read: { values }, write: { values = $0; writes += 1 }, appliesRuntimeEffects: false)
        model.fontSize = 16; model.scheduleSave()
        values["terminal"] = ["font-size": 19]

        XCTAssertThrowsError(try model.flushSaveChecked())
        XCTAssertNotNil(model.saveError)
        XCTAssertFalse(model.isSaving)
        model.reloadIfClean()
        XCTAssertEqual(model.fontSize, 16, "failed saves retain the unsaved edit")
        XCTAssertThrowsError(try model.flushSaveChecked())
        XCTAssertEqual(writes, 0)
        XCTAssertEqual((values["terminal"] as? [String: Any])?["font-size"] as? Int, 19)

        model.discardUnsavedChanges()
        XCTAssertEqual(model.fontSize, 19)
        XCTAssertNil(model.saveError)
        try model.flushSaveChecked()
        XCTAssertEqual(writes, 0)
        for size in [21, 22] {
            model.fontSize = size; model.scheduleSave()
            try model.flushSaveChecked()
            XCTAssertEqual((values["terminal"] as? [String: Any])?["font-size"] as? Int, size)
        }
        try model.flushSaveChecked()
        XCTAssertEqual(writes, 2, "successful saves clear dirty and update the conflict baseline")
    }
    func testSettingsInlineRetryAllowsClosingAfterFailedClose() throws {
        let store = empty(); defer { store.terminate() }
        var failing = true, values: [String: Any] = [:]
        let model = AgentPadSettingsModel(read: { values }, write: {
            if failing { throw CocoaError(.fileWriteOutOfSpace) }; values = $0
        }, appliesRuntimeEffects: false)
        let support = SupportTabs(ledger: AttentionLedger()); support.settingsModel = { model }
        let session = store.openToolTab(.settings), state = try XCTUnwrap(session.tabState)
        _ = support.content(state)
        model.addCustomAgent()
        store.popups.dismiss(reason: .dismiss)
        XCTAssertTrue(store.popups.isPresented)
        XCTAssertTrue(store.popups.contains(session.id))
        XCTAssertNotNil(state.saveError)

        failing = false
        // The Settings "Retry saving" button saves directly, then Close retries dismissal.
        try model.flushSaveChecked(); state.saveError = nil
        XCTAssertNil(model.saveError)
        store.popups.dismiss(reason: .dismiss)
        XCTAssertTrue(store.allSessions.isEmpty)
        XCTAssertFalse(store.popups.isPresented)
        XCTAssertFalse(store.tabCloseCoordinator.hasPending(session.id))
    }
    func testPickerCallbackRejectsMovedClosedAndEditedTarget() {
        for change in ["move", "close", "target", "cancel", "current"] {
            let state = TabState(route: .settings)
            var current = true, accepted = 0
            let complete = TabFilePicker.completion(state: state, stillValid: { current }) { _ in accepted += 1 }
            switch change {
            case "move": state.leave()
            case "close": state.close()
            case "target": current = false
            default: break
            }
            complete(change == "cancel" ? .cancel : .OK, URL(fileURLWithPath: "/tmp/picked-icon.png"))
            XCTAssertEqual(accepted, change == "current" ? 1 : 0, change)
        }
    }
    func testSettingsEntryDoesNotConstructModelBeforeStartup() {
        let router = TabRouter(), store = empty(); defer { store.terminate() }
        router.stores = { [store] }; router.ensureHost = { store }
        let support = SupportTabs(router: router, ledger: AttentionLedger())
        var models = 0
        support.settingsModel = {
            models += 1
            return AgentPadSettingsModel(read: { [:] }, write: { _ in XCTFail("early autosave") }, appliesRuntimeEffects: false)
        }
        support.settings(.about)
        XCTAssertEqual(models, 0); XCTAssertTrue(store.allSessions.isEmpty)
        XCTAssertTrue(store.popups.sessions.isEmpty)
        support.navigation.finishStartup()
        XCTAssertTrue(store.allSessions.isEmpty)
        XCTAssertEqual(store.popups.sessions.count, 1); XCTAssertTrue(store.popups.isPresented)
        support.settings(.updates)
        XCTAssertEqual(models, 1)
    }
    func testIconFailureStaysWithAgentAndSaveFailureIsRetryable() throws {
        var failure = true, values: [String: Any] = [:]
        let model = AgentPadSettingsModel(read: { values }, write: {
            if failure { throw CocoaError(.fileWriteOutOfSpace) }; values = $0
        }, appliesRuntimeEffects: false)
        model.addCustomAgent()
        let id = try XCTUnwrap(model.customAgents.last?.id), screen = SettingsScreenState()
        let url = URL(fileURLWithPath: "/tmp/broken.png")
        SettingsIconImport.apply(url, agentID: id, model: model, screen: screen, importIcon: { _, _ in throw CocoaError(.fileReadCorruptFile) })
        XCTAssertNotNil(screen.iconErrors[id])
        XCTAssertTrue(model.customAgents.last?.iconAsset.isEmpty == true)
        XCTAssertThrowsError(try model.flushSaveChecked())
        XCTAssertNotNil(model.saveError)
        failure = false
        try model.flushSaveChecked()
        XCTAssertNil(model.saveError)
        SettingsIconImport.apply(url, agentID: id, model: model, screen: screen, importIcon: { _, _ in "test-icon" })
        XCTAssertNil(screen.iconErrors[id]); XCTAssertEqual(model.customAgents.last?.iconAsset, "test-icon")
        try model.flushSaveChecked()
    }
    #if DEBUG
    func testDiagnosticsCannotQueueAfterSessionChangesBeforeTaskRuns() async throws {
        let scope = TeamServiceTestScope(); defer { scope.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        let server = try ChatServerAddress(parsing: "https://chat.example.com")
        let first = ChatConnection(server: server, accountId: UUID().uuidString, sessionId: "first", deviceName: "Test", orgId: UUID().uuidString)
        try service.saveSignIn(first, token: "test-token")
        let model = SettingsDiagnostics(); model.name = "Test Name"; model.send(service: service)
        try service.saveSignIn(ChatConnection(server: server, accountId: first.accountId, sessionId: "second", deviceName: "Test", orgId: first.orgId), token: "replacement-token")
        await Task.yield(); await Task.yield()
        XCTAssertFalse(model.sending)
        XCTAssertEqual(model.status, "The connection changed before sending. Review the name and try again.")
        let commands = try service.orgSessions.values.flatMap { try $0.store?.commands() ?? [] }
        XCTAssertTrue(commands.isEmpty)
    }
    func testDiagnosticsHasInlineValidationAndNoConnectionResult() {
        let model = SettingsDiagnostics()
        model.send(service: ChatService(files: ChatFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), tokens: FakeTokenStore()))
        XCTAssertEqual(model.status, "Not signed in to a server")
        XCTAssertFalse(model.sending)
    }
    #endif
}
