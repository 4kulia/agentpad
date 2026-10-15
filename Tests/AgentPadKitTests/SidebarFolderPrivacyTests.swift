import Foundation
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

@MainActor final class SidebarFolderPrivacyTests: XCTestCase {
    func testFullStateV2SurvivesFrozen121DecoderAndNextSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state-v2.json")
        let windows = (0..<2).map { window in
            let workspaces = (0..<2).map { workspace in
                let directory = "/projects/window-\(window)/workspace-\(workspace)"
                let panes = (0..<2).map { pane in
                    let tabs = (0..<2).map { tab in
                        PersistedTab(id: UUID(), agentId: tab == 0 ? "terminal" : "claude",
                                     currentDirectoryPath: "\(directory)/pane-\(pane)/tab-\(tab)",
                                     conversationId: tab == 1 ? UUID().uuidString : nil)
                    }
                    let pane = PersistedPane(id: UUID(), tabs: tabs, activeTabId: tabs[1].id)
                    return PersistedPaneNode(id: pane.id, kind: .pane(pane))
                }
                return PersistedWorkspace(id: UUID(), workingDirectoryPath: directory,
                    root: .init(id: UUID(), kind: .split(orientation: .horizontal, first: panes[0], second: panes[1], fraction: 0.4)),
                    activePaneId: panes[1].id, customTitle: "Workspace \(workspace)")
            }
            var preferences = ChatSidebarPreferences(attentionCollapsed: true, width: 284)
            if window == 0 {
                preferences.setCollapsed(.init(server: "https://a.example", account: "account", org: "org", team: "team"), true)
                preferences.setCollapsed(.init(server: "https://a.example", account: "account", org: "org", team: nil), true)
            }
            preferences.collapsedEntries += ["people:https://a.example|account|org", "myAgents", "custom:\(UUID())",
                                             "telegram", "main", "archive", "folder:123456"]
            return PersistedWindow(id: UUID(),
                state: PersistedState(workspaces: workspaces, activeWorkspaceId: workspaces[1].id,
                                      sidebarMode: .full, chatSidebarPreferences: preferences),
                frame: .init(x: 120, y: 80, width: 1440, height: 900))
        }
        try AppPersistence(fileURL: url).setWindows(windows).get()
        let data = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("123456"))
        let legacy = try JSONDecoder().decode(LegacySidebarV121PersistedApp.self, from: data)
        XCTAssertEqual(legacy.formatVersion, 2)
        XCTAssertEqual(legacy.windows.map(\.id), windows.map(\.id))
        // Simulate the next 1.2.1 save, then inspect every workspace, split and tab.
        let saved = try JSONDecoder().decode(PersistedApp.self, from: JSONEncoder().encode(legacy))
        for (actual, expected) in zip(saved.windows, windows) {
            XCTAssertEqual(actual.state.workspaces, expected.state.workspaces)
            XCTAssertEqual(actual.state.activeWorkspaceId, expected.state.activeWorkspaceId)
            XCTAssertEqual(actual.frame, expected.frame)
            XCTAssertEqual(actual.state.chatSidebarPreferences?.collapsed, expected.state.chatSidebarPreferences?.collapsed)
            XCTAssertEqual(actual.state.chatSidebarPreferences?.width, 284)
            XCTAssertEqual(actual.state.chatSidebarPreferences?.attentionCollapsed, true)
        }
    }

    func testScriptedTwoWindowSessionWritesNoTelegramDataOutsideProfileExceptOneExistingTabRoute() async throws {
        for withTab in [false,true] {
            let fixture = try SidebarFolderFixture(), provider = try SidebarFolderProvider(fixture), store = SidebarFoldersStore(url: fixture.catalogURL)
            try await provider.seed(); let binding = await provider.binding(), custom = UUID(), windows = [UUID(),UUID()]
            for operation: SidebarFoldersStore.Operation in [.load(defaults: []),.attach(provider,binding),.create(custom,name: "Local collection",symbol: "folder"),
                .member(custom,.telegram(fixture.chat),true),.telegramVisible(.folder(fixture.folder),false),.telegramVisible(.folder(fixture.folder),true),
                .telegramCollapsed(windows[0],.folder(fixture.folder),true),.telegramCollapsed(windows[1],.main,true)] {
                let result = await store.perform(operation, binding: binding); XCTAssertEqual(result,.success)
            }
            var damaged = try Data(contentsOf: fixture.catalogURL); damaged.append(contentsOf: "invalid".utf8)
            try damaged.write(to: fixture.catalogURL)
            let loaded = await store.perform(.load(defaults: []), binding: binding); XCTAssertEqual(loaded,.success)
            let stateURL = fixture.root.appendingPathComponent("state-v2.json")
            try Data("invalid state".utf8).write(to: stateURL)
            let persistence = AppPersistence(fileURL: stateURL)
            for (offset,window) in windows.enumerated() {
                var preferences = ChatSidebarPreferences()
                preferences.setEntryCollapsed(SidebarEntryIdentity.custom(custom),true)
                // Guarding the persistence boundary also rejects misrouted Telegram collapse.
                preferences.setEntryCollapsed("folder:\(fixture.folder)",true)
                preferences.setEntryCollapsed("main",true)
                var state = PersistedState(workspaces: [],chatSidebarPreferences: preferences)
                if withTab && offset == 0 {
                    var tab = PersistedTab(id: UUID(),agentId: "shell",currentDirectoryPath: fixture.root.path)
                    tab.content = .tool(.telegram(.init(environment: .test,account: fixture.account,chat: fixture.chat)))
                    let pane = PersistedPaneNode(id: UUID(),kind: .pane(.init(id: UUID(),tabs: [tab])))
                    state.workspaces = [.init(id: UUID(),workingDirectoryPath: fixture.root.path,root: pane)]
                }
                _ = persistence.setWindow(window,state: state)
            }
            if !withTab { try FileManager.default.copyItem(at: stateURL,to: fixture.root.appendingPathComponent("state-v2.rollback.json")) }
            let team = TeamFileCallStore(storage: TeamStorage(directory: fixture.root.appendingPathComponent("team")))
            try team.saveLog(.init(incoming: [],outgoing: [])); try team.saveThreads([])
            let forbidden = [String(fixture.account),String(fixture.chat),String(fixture.folder),fixture.name]
            var files = 0, routes = 0
            func removeOnlyExistingTabRoute(_ value: Any) -> Any {
                if var dictionary = value as? [String:Any] {
                    if dictionary.count == 1, dictionary["telegram"] != nil {
                        routes += 1
                        let bytes = try! JSONSerialization.data(withJSONObject: dictionary)
                        let text = String(decoding: bytes,as: UTF8.self)
                        XCTAssertTrue(text.contains(String(fixture.account))); XCTAssertTrue(text.contains(String(fixture.chat)))
                        dictionary["telegram"] = "allowed existing ToolRoute.telegram"
                        return dictionary
                    }
                    return dictionary.mapValues(removeOnlyExistingTabRoute)
                }
                if let array = value as? [Any] { return array.map(removeOnlyExistingTabRoute) }
                return value
            }
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: fixture.root,includingPropertiesForKeys: [.isRegularFileKey]))
            while let file = enumerator.nextObject() as? URL {
                if file.path == fixture.profile.path { enumerator.skipDescendants(); continue }
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                files += 1
                var bytes = try Data(contentsOf: file)
                if withTab, file == stateURL {
                    bytes = try JSONSerialization.data(withJSONObject: removeOnlyExistingTabRoute(JSONSerialization.jsonObject(with: bytes)))
                }
                let text = String(decoding: bytes,as: UTF8.self)
                for needle in forbidden { XCTAssertFalse(text.contains(needle),"Privacy leak in \(file.lastPathComponent)") }
            }
            XCTAssertGreaterThanOrEqual(files,6); XCTAssertEqual(routes,withTab ? 1 : 0)
        }
    }
    func testLegacyCollapseDecodesButOnlyAgentPadEntryIDsAreEncoded() throws {
        let old = Data(#"{"width":268,"attentionCollapsed":true,"collapsed":[{"server":"https://a.example","account":"account","org":"org","team":"team"},{"server":"https://a.example","account":"account","org":"org"}]}"#.utf8)
        var preferences = try JSONDecoder().decode(ChatSidebarPreferences.self,from: old)
        XCTAssertEqual(preferences.collapsedEntries,["team:https://a.example|account|org|team","teamAgents:https://a.example|account|org"])
        preferences.collapsedEntries += ["main","archive","folder:123456"]
        let encoded = try JSONEncoder().encode(preferences)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String:Any])
        XCTAssertEqual((json["collapsed"] as? [[String:Any]])?.count,2)
        XCTAssertEqual((json["collapsedEntries"] as? [String])?.count,2)
        XCTAssertFalse(String(decoding: encoded,as: UTF8.self).contains("123456"))
    }
}
