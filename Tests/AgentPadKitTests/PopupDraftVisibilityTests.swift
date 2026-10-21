import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class PopupDraftVisibilityTests: XCTestCase {
    private var previousEnhancedUI: Any?
    private let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    override func setUp() async throws {
        _ = NSApplication.shared
        previousEnhancedUI = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
    }

    override func tearDown() async throws {
        NSApp.accessibilitySetValue(previousEnhancedUI, forAttribute: enhancedUI)
    }

    // Match the app self-check's AX traversal: SwiftUI uses both modern
    // selectors and legacy attribute nodes, and native controls can live below
    // an NSHostingView that does not itself expose AX children.
    private func attribute(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let keys = ["accessibilityChildren": "AXChildren", "accessibilityLabel": "AXDescription",
            "accessibilityTitle": "AXTitle", "accessibilityValue": "AXValue"]
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let key = keys[name], object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: key)?.takeUnretainedValue()
    }

    private func nodes(in window: NSWindow) -> [NSObject] {
        var result: [NSObject] = [], queue: [NSObject] = [window], seen: Set<ObjectIdentifier> = []
        if let content = window.contentView { queue.append(content) }
        while let object = queue.popLast(), result.count < 4000 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            queue += attribute(object, "accessibilityChildren") as? [NSObject] ?? []
            if let view = object as? NSView { queue += view.subviews }
        }
        return result
    }

    private func labels(in window: NSWindow) -> [String] {
        nodes(in: window).flatMap { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { attribute(object, $0) as? String }
        }
    }

    private func press(_ title: String, in window: NSWindow) -> Bool {
        guard let object = nodes(in: window).first(where: { object in
            ["accessibilityLabel", "accessibilityTitle"].contains { attribute(object, $0) as? String == title }
        }) else { return false }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        if object.responds(to: selector) {
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
        }
        let names = NSSelectorFromString("accessibilityActionNames")
        guard object.responds(to: names),
              (object.perform(names)?.takeUnretainedValue() as? [String])?.contains("AXPress") == true else { return false }
        object.perform(NSSelectorFromString("accessibilityPerformAction:"), with: "AXPress")
        return true
    }

    private func fixture() throws -> (WorkspaceStore, SupportTabs, TabState, Session, TabDraft) {
        let owner = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, engineFactory: {
            XCTFail("Draft navigation must not start a terminal"); return TestEngine()
        })
        let router = TabRouter()
        router.stores = { [owner] }; router.ensureHost = { owner }
        let support = SupportTabs(router: router, ledger: AttentionLedger())
        support.navigation.finishStartup()
        let notifications = try XCTUnwrap(support.navigation.open(.notifications, from: owner)?.tabState)
        notifications.navigation.selection = "drafts"
        let popup = try XCTUnwrap(support.navigation.open(.newSSH(draftID: UUID()), from: owner))
        let state = try XCTUnwrap(popup.tabState)
        state.edit(.ssh(name: "Work", host: "work", directory: "/tmp"))
        let draft = try XCTUnwrap(state.draft)
        owner.popups.dismiss(reason: .dismiss)
        XCTAssertEqual(owner.drafts.drafts, [draft])
        XCTAssertFalse(owner.popups.isPresented)
        XCTAssertTrue(owner.popups.backStack.isEmpty)
        XCTAssertEqual(owner.allSessions.map { $0.tabState?.navigation.draftID }, [nil])
        XCTAssertTrue(support.owner(notifications)?.store === owner)
        XCTAssertEqual(notifications.navigation.selection, "drafts")
        return (owner, support, notifications, popup, draft)
    }

    func testDismissedPopupDraftIsListedAndOpenRestoresItsForm() async throws {
        let (owner, support, notifications, popup, draft) = try fixture()
        let host = FoldersUIHost(NotificationTabView(state: notifications, support: support), width: 700, height: 500)
        defer { host.close(); owner.terminate() }
        try await host.settle()
        let screenshotDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/fix-pop1-shots")
        try FileManager.default.createDirectory(at: screenshotDirectory, withIntermediateDirectories: true)
        try host.png(screenshotDirectory.appendingPathComponent("notifications-drafts.png"))
        XCTAssertTrue(labels(in: host.window).contains("Drafts (1)"), "Rendered labels: \(labels(in: host.window))")
        guard press("Open draft", in: host.window) else { return XCTFail("A dismissed popup draft must have an Open draft action. Rendered labels: \(labels(in: host.window))") }
        try await host.settle()

        guard case .tool(let reopened) = owner.popups.page else { return XCTFail("Open draft must reopen its popup") }
        XCTAssertTrue(reopened === popup)
        XCTAssertEqual(reopened.toolRoute, draft.route)
        XCTAssertEqual(reopened.tabState?.draft, draft)
        XCTAssertTrue(owner.popups.draftKept)
        XCTAssertFalse(owner.popups.canGoBack)
        XCTAssertEqual(owner.allSessions.map(\.toolRoute), [.notifications])
        XCTAssertTrue(labels(in: host.window).contains("Drafts (0)"), "A presented popup is not a closed draft")
    }

    func testDiscardClosedPopupDraftRemovesRetainedFormAndCannotResurrectOnSave() async throws {
        let (owner, support, notifications, popup, draft) = try fixture()
        notifications.confirmation.canShow = { true }
        let host = FoldersUIHost(VStack {
            NotificationTabView(state: notifications, support: support)
            InlineConfirmation(coordinator: notifications.confirmation)
        }, width: 700, height: 650)
        defer { host.close(); owner.terminate() }
        try await host.settle()
        guard press("Discard…", in: host.window) else { return XCTFail("A dismissed popup draft must have a Discard action. Rendered labels: \(labels(in: host.window))") }
        try await host.settle()
        XCTAssertEqual(notifications.confirmation.context?.targetID, draft.id.uuidString)
        XCTAssertEqual(owner.drafts.drafts, [draft], "Discard still requires explicit confirmation")
        XCTAssertTrue(press("Discard draft", in: host.window))
        try await host.settle()

        XCTAssertEqual(notifications.confirmation.phase, .completed)
        XCTAssertEqual(owner.drafts.drafts, [])
        XCTAssertTrue(popup.tabState?.isClosed == true)
        XCTAssertFalse(owner.popups.contains(popup.id))
        XCTAssertTrue(owner.flushPersistence())
        XCTAssertEqual(owner.drafts.drafts, [], "A retained popup must not save the discarded draft again")
        let fresh = try XCTUnwrap(support.navigation.open(draft.route, from: owner))
        XCTAssertFalse(fresh === popup)
        XCTAssertNil(fresh.tabState?.draft)
        XCTAssertFalse(owner.popups.draftKept)
    }

    func testRuntimeConnectionDraftHasOpenAndDiscardWithoutPersistence() async throws {
        let (owner, support, notifications, previous, _) = try fixture()
        owner.popups.dismiss(previous, reason: .cancel)
        let session = try XCTUnwrap(support.navigation.open(.connection, from: owner))
        let state = try XCTUnwrap(session.tabState)
        let service = ChatService(files: ChatFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), tokens: FakeTokenStore())
        let model = ChatConnectModel(service: service)
        state.connectionForm = model; model.email = "andrew@example.com"
        owner.popups.dismiss(reason: .dismiss)
        notifications.confirmation.canShow = { true }
        let host = FoldersUIHost(VStack {
            NotificationTabView(state: notifications, support: support)
            InlineConfirmation(coordinator: notifications.confirmation)
        }, width: 700, height: 650)
        defer { host.close(); owner.terminate() }
        try await host.settle()
        XCTAssertEqual(owner.popups.retainedRuntimeDrafts.map(\.title), ["Connect to a Server"])
        XCTAssertTrue(labels(in: host.window).contains("Kept until AgentPad quits"))
        XCTAssertTrue(labels(in: host.window).contains("Drafts (1)"))
        XCTAssertTrue(press("Open draft", in: host.window))
        try await host.settle()
        XCTAssertTrue(owner.popups.find(.connection)?.session === session)
        XCTAssertTrue(state.connectionForm === model)
        XCTAssertEqual(model.email, "andrew@example.com")
        XCTAssertTrue(owner.popups.retainedRuntimeDrafts.isEmpty)
        owner.popups.dismiss(reason: .dismiss)
        try await host.settle()
        XCTAssertTrue(press("Discard…", in: host.window))
        try await host.settle()
        XCTAssertFalse(state.isClosed, "Discard needs an explicit confirmation")
        XCTAssertTrue(press("Discard draft", in: host.window))
        try await host.settle()
        XCTAssertTrue(state.isClosed)
        XCTAssertTrue(model.isClosed)
        XCTAssertTrue(owner.popups.retainedRuntimeDrafts.isEmpty)
        XCTAssertTrue(owner.flushPersistence())
        XCTAssertEqual(owner.drafts.drafts, [])
    }

    func testAccountRuntimeDraftCanBeDiscardedWithoutKeychainWrite() throws {
        let owner = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true)
        defer { owner.terminate() }
        let tokens = MemoryClaudeTokens(), profiles = AgentProfileStore(accountTokens: tokens)
        owner.popups.presentAccount(profiles: profiles)
        guard case .account(let form) = owner.popups.page else { return XCTFail("Account form missing") }
        form.name = "Work"
        owner.popups.dismiss(reason: .dismiss)
        let draft = try XCTUnwrap(owner.popups.retainedRuntimeDrafts.first)
        XCTAssertEqual(draft.title, "Add Claude account")
        try owner.popups.discardRuntimeDraft(draft)
        XCTAssertTrue(owner.popups.retainedRuntimeDrafts.isEmpty)
        XCTAssertTrue(form.name.isEmpty)
        XCTAssertEqual(owner.drafts.drafts, [])
        XCTAssertTrue(try tokens.accounts().isEmpty)
    }

    func testOpenPublicationDraftReplacesStaleRetainedFormWithNewerWindowDraft() async throws {
        let drafts = DraftRepository()
        func makeOwner() -> WorkspaceStore {
            WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, drafts: drafts, engineFactory: {
                XCTFail("Publication draft navigation must not start a terminal"); return TestEngine()
            })
        }
        let first = makeOwner(), second = makeOwner()
        defer { first.terminate(); second.terminate() }
        let router = TabRouter()
        router.stores = { [first, second] }; router.ensureHost = { first }
        let support = SupportTabs(router: router, ledger: AttentionLedger())
        support.navigation.finishStartup()
        let tabs = TeamTabs(router: router)
        let notifications = try XCTUnwrap(support.navigation.open(.notifications, from: first)?.tabState)
        notifications.navigation.selection = "drafts"

        // Edit profile → Manage publication opens this stable route separately
        // in each window. Both forms therefore edit the same archived draft.
        let publication = TeamPublishedAgent(name: "backend", description: "Backend publication", folder: "/tmp")
        let route = ToolRoute.publication(.local, publicationID: publication.id.uuidString.lowercased())
        let stalePopup = try XCTUnwrap(support.navigation.open(route, from: first))
        let staleState = try XCTUnwrap(stalePopup.tabState)
        staleState.edit(.publicationForm(PublicationDraft(publication)))
        let staleForm = tabs.form(staleState)
        let oldDraft = try XCTUnwrap(staleState.draft)
        first.popups.dismiss(reason: .dismiss)
        XCTAssertEqual(drafts.drafts, [oldDraft])

        let newerPopup = try XCTUnwrap(support.navigation.open(route, from: second))
        let newerState = try XCTUnwrap(newerPopup.tabState)
        let newerForm = tabs.form(newerState)
        XCTAssertEqual(newerForm.fields, staleForm.fields)
        newerForm.fields.description = "Updated publication details from the second window"
        let expected = try XCTUnwrap(newerState.draft)
        let expectedFields = newerForm.fields
        XCTAssertEqual(expected.id, oldDraft.id)
        XCTAssertEqual(expected.revision, oldDraft.revision + 1)
        second.popups.dismiss(reason: .dismiss)
        second.terminate()
        XCTAssertEqual(drafts.drafts, [expected])
        XCTAssertEqual(staleState.draft, oldDraft)

        let host = FoldersUIHost(NotificationTabView(state: notifications, support: support), width: 700, height: 500)
        defer { host.close() }
        try await host.settle()
        XCTAssertTrue(labels(in: host.window).contains("Drafts (1)"))
        XCTAssertTrue(press("Open draft", in: host.window))
        try await host.settle()

        guard case .tool(let reopened) = first.popups.page else { return XCTFail("Open draft must reopen the publication popup") }
        let reopenedState = try XCTUnwrap(reopened.tabState)
        XCTAssertFalse(reopened === stalePopup, "The cached older form must be retired before reopening the saved draft")
        XCTAssertTrue(staleState.isClosed)
        XCTAssertEqual(reopened.toolRoute, route)
        XCTAssertEqual(reopenedState.draft, expected)
        XCTAssertEqual(tabs.form(reopenedState).fields, expectedFields)
        XCTAssertEqual(drafts.drafts, [expected], "Retiring a stale form must not discard the newer saved draft")
        XCTAssertTrue(first.flushPersistence())
        XCTAssertEqual(drafts.drafts, [expected])
        XCTAssertEqual(drafts.conflicts, [], "Opening the current draft must not resave the stale revision")
    }
}
