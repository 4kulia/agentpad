import AppKit
import SwiftUI
import XCTest
import AgentPadTelegram
@testable import AgentPadKit

@MainActor
final class ToolPresentationTests: XCTestCase {
    func testEveryToolRouteMatchesPopupInventory() throws {
        let org = try OrgKey(server: "https://example.com", accountID: "me", orgID: "org")
        let key = ChatOrgKey(server: org.server, accountId: org.accountID, orgId: org.orgID)
        let scope = TeamScope.server(org), id = UUID()
        let inventory: [(ToolRoute, ToolPresentation)] = [
            (.settings, .popup),
            (.notifications, .tab),
            (.allSessions, .tab),
            (.search, .tab),
            (.telegram(.init(environment: .test, account: 1, chat: 2)), .tab),
            (.directMessage(ChatDMRef(key, dm: "dm")), .tab),
            (.directMessageDraft(org, peer: "peer"), .tab),
            (.newDM(org), .popup),
            (.linkFailure, .popup),
            (.organization(org), .popup),
            (.agent(org, agentID: "agent"), .popup),
            (.ask(org, agentID: "agent"), .popup),
            (.request(scope, requestID: "request"), .popup),
            (.publishedAgents(scope), .tab),
            (.teamActivity(scope), .tab),
            (.publication(scope, publicationID: "publication"), .popup),
            (.publish(scope, draftID: id, sourceSessionID: id, conversationID: "conversation"), .popup),
            (.forward(sourceSessionID: id, answerSnapshotID: id), .popup),
            (.connection, .popup),
            (.newChannel(org, teamID: "team", draftID: id), .popup),
            (.agentProfile(id), .popup),
            (.newAgent(draftID: id), .popup),
            (.newSSH(draftID: id), .popup),
            (.newWorktree(repository: "/tmp", sourceWorkspaceID: id, draftID: id), .popup),
            (.workspaceDetails(id), .popup),
            (.files(canonicalPath: "/tmp"), .tab),
            (.closeWorkspaces(intentID: id), .popup),
            (.fileOperations(operationID: id), .popup),
            (.importSession(agentID: "claude", conversationID: "conversation", externalSourceID: "external"), .popup),
            (.dmViewer(org, dmID: "dm", messageID: "message", attachmentID: "attachment"), .tab),
            (.viewer(org, channelID: "channel", messageID: "message", attachmentID: "attachment"), .tab),
            (.unavailable(id), .tab)
        ]
        XCTAssertEqual(inventory.count, 32)
        XCTAssertEqual(inventory.map { $0.0.presentation }, inventory.map(\.1))
    }

    func testClaudeAccountsSectionTitleAndOrder() {
        XCTAssertEqual(SettingsTabSection.allCases, [.general, .profile, .telegram, .sidebar, .appearance,
            .agents, .claudeAccounts, .terminals, .openIn, .statusBar, .notifications, .search, .advanced, .about, .updates])
        XCTAssertEqual(SettingsTabSection.claudeAccounts.title, "Claude accounts")
    }

    func testEveryPopupInventoryRouteStaysOutOfPanesThroughDirectRouterOrRekeyEntry() async throws {
        // Keep the production session engine and presenter, but isolate the
        // form body so this presentation check cannot start account services.
        let previousContent = NativeTabEngine.content
        NativeTabEngine.content = { AnyView(Text($0.route.title)) }
        defer { NativeTabEngine.content = previousContent }
        let org = try OrgKey(server: "https://example.com", accountID: "me", orgID: "org")
        let scope = TeamScope.server(org), id = UUID()
        // All twenty Popup routes use the same entry gate, including legacy
        // direct callers and rekeying an old content tab.
        let routes: [ToolRoute] = [
            .settings, .agentProfile(id), .linkFailure, .organization(org),
            .closeWorkspaces(intentID: id), .fileOperations(operationID: id),
            .importSession(agentID: "claude", conversationID: "conversation", externalSourceID: "external"),
            .newAgent(draftID: id), .newSSH(draftID: id),
            .newWorktree(repository: "/tmp", sourceWorkspaceID: id, draftID: id), .workspaceDetails(id),
            .connection, .newDM(org), .newChannel(org, teamID: "team", draftID: id),
            .forward(sourceSessionID: id, answerSnapshotID: id), .ask(org, agentID: "agent"),
            .request(scope, requestID: "request"), .publish(scope, draftID: id, sourceSessionID: nil, conversationID: nil),
            .publication(scope, publicationID: "publication"), .agent(org, agentID: "agent")
        ]
        XCTAssertEqual(routes.count, 20)
        for route in routes {
            let owner = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
                engineFactory: { XCTFail("Popup route started a process"); return TestEngine() })
            defer { owner.terminate() }
            let host = FoldersUIHost(Color.clear.popupHost(owner.popups), width: 1180, height: 850)
            defer { host.close() }
            let router = TabRouter(); router.stores = { [owner] }
            let direct = owner.openToolTab(route)
            XCTAssertEqual(route.presentation, .popup)
            XCTAssertTrue(direct.tabState?.isPopup == true)
            XCTAssertTrue(router.open(route, from: owner) === direct)
            try await assertPopupInventoryPresentation(in: host.window, root: host.view, coordinator: owner.popups,
                title: try XCTUnwrap(owner.popups.page?.presentationTitle), content: direct.engine.view)
            owner.popups.dismiss(reason: .dismiss)
            let oldContent = owner.openToolTab(.notifications)
            XCTAssertTrue(router.rekey(oldContent.id, to: route) === direct)
            try await assertPopupInventoryPresentation(in: host.window, root: host.view, coordinator: owner.popups,
                title: try XCTUnwrap(owner.popups.page?.presentationTitle), content: direct.engine.view)
            XCTAssertEqual(owner.allSessions.map(\.toolRoute), [])
            XCTAssertEqual(owner.popups.sessions.map(\.toolRoute), [route])
            XCTAssertTrue(owner.flushPersistence())
        }
    }

    func testFirstLaunchPopupInventoryIsMountedInItsStartupWindow() async throws {
        _ = NSApplication.shared
        let startup = AgentPadStartupWindowController(
            ghosttyConfig: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            onChoice: { XCTFail("A presentation check must not complete onboarding") })
        let window = try XCTUnwrap(startup.window), root = try XCTUnwrap(startup.window?.contentView)
        defer { _ = startup.takeWindow(); window.close() }
        // Like FoldersUIHost, give the mounted fixture a fixed layout size.
        // With no screens visible in the read-only sandbox, ordering a titled
        // window can shrink it to 1x1 unless it has a minimum content size.
        let size = NSSize(width: 1100, height: 720)
        window.contentMinSize = size
        window.setContentSize(size)
        startup.showWindow(nil)
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(root.bounds.size, size)
        try await assertPopupInventoryPresentation(in: window, root: root, coordinator: startup.popups,
            title: "Import Ghostty settings?")
    }

    func testAllThreeAdditionalTabContentKindsRemainInPanes() throws {
        let scope = TeamServiceTestScope(); defer { scope.close() }
        let owner = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            engineFactory: { TestEngine() }, optionsProvider: { _ in nil })
        defer { owner.terminate() }
        let key = ChatOrgKey(server: try ChatServerAddress(parsing: "https://example.com"), accountId: "me", orgId: "org")
        let channel = ChannelRef(key, channel: "channel"), inbox = ChatInboxRef(key, kind: .unread)
        let workspace = owner.addEmptyWorkspace()
        _ = owner.addTab(in: workspace, template: .terminal)
        _ = owner.openChannelTab(channel, in: workspace)
        _ = owner.openInboxTab(inbox, in: workspace)
        let inventory: [AgentPadKit.TabContent] = [.terminal, .channel(channel), .chatInbox(inbox)]
        // Exhaustive on purpose: adding a content kind requires an Inventory decision.
        let names = inventory.map { content in
            switch content {
            case .terminal: "terminal"
            case .channel: "channel"
            case .chatInbox: "chatInbox"
            case .tool: "ToolRoute is covered separately"
            }
        }
        XCTAssertEqual(names, ["terminal", "channel", "chatInbox"])
        XCTAssertEqual(owner.allSessions.map(\.content), inventory)
        XCTAssertTrue(owner.popups.sessions.isEmpty)
        XCTAssertFalse(owner.popups.isPresented)
    }

    func testNativeInventoryMatchesPresenters() throws {
        enum Destination { case popup, unchanged }
        let inventory: [(String, Destination)] = [
            ("Folders… sheet", .popup), ("Delete custom folder alert", .popup),
            ("First-launch Ghostty import", .popup),
            ("Telegram bot information / URL alert", .popup),
            ("Telegram sponsored information / report / URL sheet", .popup),
            ("Remove Telegram local data alert", .popup),
            ("Sponsored-video website confirmation", .popup), ("Add to folder… chooser", .popup),
            ("Command palette (⌘P)", .unchanged), ("Context and action-menu popovers", .unchanged),
            ("@mention autocomplete panel", .unchanged), ("Reaction picker / Who reacted popovers", .unchanged),
            ("Workspace rail preview", .unchanged), ("Status-bar details / tool history / Codex usage", .unchanged),
            ("macOS open/save panels", .unchanged), ("Quick Look", .unchanged),
            ("Sponsored video window", .unchanged), ("Sparkle update UI", .unchanged),
            ("macOS notification permission", .unchanged), ("Main workspace / New Window containers", .unchanged)
        ]
        XCTAssertEqual(inventory.count, 20)
        XCTAssertEqual(inventory.filter { $0.1 == .popup }.count, 8)
        XCTAssertEqual(inventory.filter { $0.1 == .unchanged }.count, 12)
        func source(_ path: String) throws -> String {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("Sources/AgentPadKit/" + path), encoding: .utf8)
        }
        let popupPaths = [
            "Tabs/PopupHost.swift",
            "App/AgentPadSettings.swift",
            "Sidebar/FoldersSheet.swift", "Sidebar/SidebarFolderSettings.swift", "AgentPad/Chat/ChatSidebarView.swift",
            "Sidebar/AddToFolderChooser.swift", "Sidebar/SidebarFolderActions.swift",
            "Telegram/TelegramConversationView.swift", "Telegram/TelegramSponsoredCard.swift", "Telegram/TelegramSettingsView.swift",
            "Tabs/ProcessTabs.swift", "Tabs/FileOperationTab.swift", "Tabs/ImportSessionTab.swift",
            "Tabs/OrganizationTabs.swift", "AgentPad/Chat/ChatOrgUI.swift"
        ]
        XCTAssertTrue(popupPaths.contains("Tabs/PopupHost.swift"), "The Inventory check must include its shared presenter")
        let forbidden = #"NSAlert\s*\(|\.(?:sheet|alert|confirmationDialog)\s*\(|\.runModal\s*\(|\.beginSheet|NSWindow\s*\(|NSPanel\s*\("#
        for path in popupPaths {
            XCTAssertNil(try source(path).range(of: forbidden, options: .regularExpression), "Popup Inventory row has a legacy presenter: \(path)")
        }
        let evidence: [(String, String, String)] = [
            ("Folders… sheet", "Sidebar/FoldersSheet.swift", "coordinator.presentNative(page)"),
            ("Delete custom folder alert", "Sidebar/FoldersSheet.swift", "coordinator.presentConfirmation(title: \"Delete custom folder\""),
            ("First-launch Ghostty import", "App/AgentPadWindowController.swift", "popups.presentNative(page)"),
            ("Telegram bot information / URL alert", "Telegram/TelegramConversationView.swift", "TelegramBotPopup.makePage"),
            ("Telegram sponsored information / report / URL sheet", "Telegram/TelegramConversationView.swift", "TelegramSponsoredPopup.makePage"),
            ("Remove Telegram local data alert", "Telegram/TelegramSettingsView.swift", "presentConfirmation"),
            ("Sponsored-video website confirmation", "Telegram/TelegramSponsoredVideoWindow.swift", "presentNative"),
            ("Add to folder… chooser", "Sidebar/SidebarFolderActions.swift", "presentNative")
        ]
        XCTAssertEqual(evidence.map(\.0), inventory.filter { $0.1 == .popup }.map(\.0))
        for (name, path, marker) in evidence { XCTAssertTrue(try source(path).contains(marker), "Missing popup entry: \(name)") }
        let windowController = try source("App/AgentPadWindowController.swift")
        let startup = try XCTUnwrap(windowController.components(separatedBy: "final class AgentPadStartupWindowController:").last?
            .components(separatedBy: "private struct GhosttyImportPopup:").first)
        XCTAssertNil(startup.range(of: forbidden, options: .regularExpression), "First-launch choice has a legacy presenter")
        XCTAssertTrue(startup.contains(".popupHost(popups)"))
        let conversation = try source("Telegram/TelegramConversationView.swift")
        let botBridge = try XCTUnwrap(conversation.components(separatedBy: "if botPopup == nil").last?
            .components(separatedBy: "if sponsoredPopup == nil").first)
        let sponsoredBridge = try XCTUnwrap(conversation.components(separatedBy: "if sponsoredPopup == nil").last?
            .components(separatedBy: "private func dismissNativePopups").first)
        for (name, bridge) in [("bot", botBridge), ("sponsored", sponsoredBridge)] {
            XCTAssertTrue(bridge.contains("owner.presentNative(page)"), "Missing \(name) popup presentation")
            XCTAssertTrue(conversation.contains(".onChange(of: \(name)Dialog?.id, initial: true)"), "Missing live \(name) dialog entry")
        }
        XCTAssertFalse(try source("Sidebar/AddToFolderChooser.swift").contains(".popover("))
        let video = try source("Telegram/TelegramSponsoredVideoWindow.swift")
        let confirmation = try XCTUnwrap(video.components(separatedBy: "func confirm(").last)
        XCTAssertNil(confirmation.range(of: forbidden, options: .regularExpression), "Video confirmation must use its existing window's PopupHost")
        XCTAssertTrue(video.contains(".popupHost("))
        let nativeExceptions: [(String, String)] = [
            ("App/CommandPalette.swift", "NSPanel"), ("App/AttentionOverlay.swift", ".popover("),
            ("AgentPad/Chat/ChatMentionPopup.swift", "NSPanel"), ("AgentPad/Chat/ChatNativeRowActions.swift", "ChatNativeAttentionPopover"),
            ("Sidebar/WorkspaceRailView.swift", "attentionPopover"), ("Terminal/CodexUsagePill.swift", "attentionPopover"),
            ("Tabs/SupportTabs.swift", "NSOpenPanel"), ("AgentPad/QuickLookPanel.swift", "QLPreviewPanel"),
            ("Telegram/TelegramSponsoredVideoWindow.swift", "NSWindow(contentRect:"),
            ("App/NotificationManager.swift", "requestAuthorization"), ("App/AppDelegate.swift", "func addWindow(")
        ]
        for (path, marker) in nativeExceptions { XCTAssertTrue(try source(path).contains(marker), "Named native exception changed: \(path)") }
        let nativeChatPopup = try source("AgentPad/Chat/ChatNativeRowActions.swift")
        XCTAssertTrue(nativeChatPopup.contains("NavigationPresentationGate.setOverlay(id, window: window, presented: true)"))
        XCTAssertTrue(nativeChatPopup.contains("func popoverDidClose("))
        XCTAssertTrue(nativeChatPopup.contains("NavigationPresentationGate.setOverlay(id, window: ownerWindow, presented: false)"))
        XCTAssertTrue(try source("AgentPad/Updater.swift").contains("Sparkle"))
    }

    func testCurrentStateFormatDropsPopupTabsAndPreservesDraftArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state-v2.json")
        let archiveURL = directory.appendingPathComponent("tab-drafts-v1.json")
        let windowID = UUID(), workspaceID = UUID(), rootID = UUID(), leftID = UUID(), rightID = UUID()
        let settingsID = UUID(), sshID = UUID(), notificationsID = UUID(), draftID = UUID()
        let draft = TabDraft(id: draftID, revision: 3, route: .newSSH(draftID: draftID),
            payload: .ssh(name: "Unfinished", host: "invalid host", directory: "relative"))
        try DraftRepository(fileURL: archiveURL).save(draft)
        let archiveBefore = try Data(contentsOf: archiveURL)
        let fixture = """
        {"formatVersion":2,"windows":[{"id":"\(windowID)","state":{
          "activeWorkspaceId":"\(workspaceID)","workspaces":[{
            "id":"\(workspaceID)","workingDirectoryPath":"/tmp","activePaneId":"\(rightID)",
            "root":{"id":"\(rootID)","kind":{"split":{
              "orientation":"horizontal","fraction":0.4,
              "first":{"id":"\(leftID)","kind":{"pane":{
                "id":"\(leftID)","activeTabId":"\(settingsID)","tabs":[{
                  "id":"\(settingsID)","agentId":"terminal","currentDirectoryPath":"/tmp",
                  "content":{"tool":{"_0":{"settings":{}}}},"navigation":{"settingsSection":"agents","zoom":1}
                }]}}},
              "second":{"id":"\(rightID)","kind":{"pane":{
                "id":"\(rightID)","activeTabId":"\(sshID)","tabs":[{
                  "id":"\(sshID)","agentId":"terminal","currentDirectoryPath":"/tmp",
                  "content":{"tool":{"_0":{"newSSH":{"draftID":"\(draftID)"}}}},
                  "navigation":{"settingsSection":"general","zoom":1,"draftID":"\(draftID)"}
                },{
                  "id":"\(notificationsID)","agentId":"terminal","currentDirectoryPath":"/tmp",
                  "content":{"tool":{"_0":{"notifications":{}}}}
                }]}}}
            }}}}]
        }}]}
        """
        try Data(fixture.utf8).write(to: stateURL)
        let original = try JSONDecoder().decode(PersistedApp.self, from: Data(fixture.utf8))
        XCTAssertEqual(original.formatVersion, 2)
        let persistence = AppPersistence(fileURL: stateURL)
        XCTAssertNil(persistence.lastError)
        let store = WorkspaceStore(persistence: WindowPersistence(windowId: windowID, app: persistence), initiallyEmpty: true,
            engineFactory: { XCTFail("Restoring popup tabs must not allocate a process engine"); return TestEngine() })
        defer { store.terminate() }
        XCTAssertEqual(store.workspaces.map(\.id), [workspaceID])
        let workspace = try XCTUnwrap(store.active)
        XCTAssertEqual(workspace.root.allPanes.map(\.id), [leftID, rightID])
        XCTAssertEqual(workspace.root.allPanes.map { $0.tabs.map(\.id) }, [[], [notificationsID]])
        XCTAssertEqual(workspace.activePaneId, rightID)
        XCTAssertEqual(workspace.activePane?.activeTabId, notificationsID)
        XCTAssertEqual(store.allSessions.map(\.content), [.tool(.notifications)])
        XCTAssertEqual(persistence.drafts.drafts, [draft])
        XCTAssertEqual(persistence.drafts.conflicts, [])
        XCTAssertEqual(try Data(contentsOf: archiveURL), archiveBefore)
        XCTAssertTrue(store.flushPersistence())
        let rewritten = try JSONDecoder().decode(PersistedApp.self, from: Data(contentsOf: stateURL))
        XCTAssertEqual(rewritten.formatVersion, 2)
        let saved = try XCTUnwrap(rewritten.windows.first?.state.workspaces.first)
        guard case .split(.horizontal, let first, let second, 0.4) = saved.root.kind,
              case .pane(let left) = first.kind, case .pane(let right) = second.kind else {
            return XCTFail("Restore must retain the existing split layout")
        }
        XCTAssertEqual(left, PersistedPane(id: leftID, tabs: [], activeTabId: nil))
        XCTAssertEqual(right.tabs.map(\.id), [notificationsID])
        XCTAssertEqual(right.activeTabId, notificationsID)
        XCTAssertEqual(DraftRepository(fileURL: archiveURL).drafts, [draft])
        XCTAssertEqual(try Data(contentsOf: archiveURL), archiveBefore)
    }

    func testLegacyPhaseThreeTabsRestoreWithoutShowingPopupsOrStartingProcesses() throws {
        let org = try OrgKey(server: "https://example.com", accountID: "me", orgID: "org")
        let routes: [ToolRoute] = [.linkFailure, .organization(org), .closeWorkspaces(intentID: UUID()),
            .fileOperations(operationID: UUID()), .importSession(agentID: "claude", conversationID: "conversation", externalSourceID: "external")]
        for route in routes {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let window = UUID(), workspace = UUID(), pane = UUID(), tab = UUID()
            let encodedRoute = try XCTUnwrap(String(data: JSONEncoder().encode(route), encoding: .utf8))
            let fixture = """
            {"formatVersion":2,"windows":[{"id":"\(window)","state":{
              "activeWorkspaceId":"\(workspace)","workspaces":[{
                "id":"\(workspace)","workingDirectoryPath":"/tmp","activePaneId":"\(pane)",
                "root":{"id":"\(pane)","kind":{"pane":{
                  "id":"\(pane)","activeTabId":"\(tab)","tabs":[{
                    "id":"\(tab)","agentId":"terminal","currentDirectoryPath":"/tmp",
                    "content":{"tool":{"_0":\(encodedRoute)}}
                  }]}}}
              }]
            }}]}
            """
            let file = directory.appendingPathComponent("state-v2.json")
            try Data(fixture.utf8).write(to: file)
            let persistence = AppPersistence(fileURL: file)
            let owner = WorkspaceStore(persistence: WindowPersistence(windowId: window, app: persistence), initiallyEmpty: true,
                engineFactory: { XCTFail("Legacy popup tab allocated a process"); return TestEngine() })
            defer { owner.terminate() }
            XCTAssertNil(persistence.lastError)
            XCTAssertEqual(owner.workspaces.map(\.id), [workspace])
            XCTAssertTrue(owner.allSessions.isEmpty, "Legacy \(route.title) remained a tab")
            XCTAssertFalse(owner.popups.isPresented, "Legacy consent must not be restored")
            XCTAssertTrue(owner.flushPersistence())
        }
    }
}

/// Shared by the Inventory's twenty ToolRoute rows and eight native families.
/// Inspect the mounted AppKit hierarchy, not just the coordinator's route: a
/// sheet/window, a pane replacement, or a missing host cannot satisfy this.
@MainActor
func assertPopupInventoryPresentation(in window: NSWindow, root: NSView, coordinator: PopupCoordinator,
                                     title: String, content: NSView? = nil,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for _ in 0..<100 {
        root.layoutSubtreeIfNeeded()
        if let dialog = descendants(root).first(where: { $0.accessibilityIdentifier() == "popup-dialog" }),
           dialog.accessibilityLabel() == title, dialog.bounds.width > 0, dialog.bounds.height > 0,
           content.map({ $0.isDescendant(of: dialog) }) ?? true { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(window.contentView === root, "\(title): the popup replaced its owner's content", file: file, line: line)
    XCTAssertNil(window.attachedSheet, "\(title): the popup became a sheet", file: file, line: line)
    XCTAssertNil(window.sheetParent, "\(title): the owner became a sheet", file: file, line: line)
    XCTAssertNil(NSApp.modalWindow, "\(title): the popup became modal", file: file, line: line)
    let dialogs = descendants(root).filter { $0.accessibilityIdentifier() == "popup-dialog" }
    XCTAssertEqual(dialogs.count, 1, "\(title): expected one mounted popup in the owner's content", file: file, line: line)
    let dialog = try XCTUnwrap(dialogs.first, "\(title): the popup is not mounted in its owner", file: file, line: line)
    XCTAssertTrue(dialog.window === window, "\(title): the dialog moved to another window", file: file, line: line)
    XCTAssertTrue(coordinator.window === window, "\(title): the presenter attached to another window", file: file, line: line)
    XCTAssertEqual(dialog.accessibilityRole(), .group, file: file, line: line)
    XCTAssertEqual(dialog.accessibilitySubrole()?.rawValue, "AXDialog", file: file, line: line)
    XCTAssertEqual(dialog.accessibilityLabel(), title, file: file, line: line)
    XCTAssertFalse(dialog.isHiddenOrHasHiddenAncestor, "\(title): the mounted dialog is hidden", file: file, line: line)
    let frame = dialog.convert(dialog.bounds, to: root)
    // A full-size-content startup window includes its transparent titlebar
    // in root.bounds; SwiftUI centers the popup in the usable content area.
    let contentFrame = root.convert(window.contentLayoutRect, from: nil)
    XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
    XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
    XCTAssertLessThan(frame.width, root.bounds.width, file: file, line: line)
    XCTAssertLessThan(frame.height, root.bounds.height, file: file, line: line)
    XCTAssertEqual(frame.midX, contentFrame.midX, accuracy: 1, "\(title): the popup is not centered", file: file, line: line)
    XCTAssertEqual(frame.midY, contentFrame.midY, accuracy: 1, "\(title): the popup is not centered", file: file, line: line)
    if let content {
        XCTAssertTrue(content.isDescendant(of: dialog), "\(title): the actual tool view is outside the popup", file: file, line: line)
        XCTAssertTrue(content.window === window, file: file, line: line)
    }
}
