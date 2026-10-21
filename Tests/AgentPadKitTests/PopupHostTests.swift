import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class PopupHostTests: XCTestCase {
    private func store(drafts: DraftRepository = DraftRepository()) -> WorkspaceStore {
        WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, drafts: drafts,
            engineFactory: { XCTFail("A popup must not start a process"); return TestEngine() })
    }

    func testRouterAndDirectEntryKeepPopupsOutOfTabsAndScopedToWindow() throws {
        let first = store(), second = store()
        defer { first.terminate(); second.terminate() }
        let router = TabRouter(); router.stores = { [first, second] }
        let profile = UUID()
        let settings = try XCTUnwrap(router.open(.settings, from: first))
        let editor = try XCTUnwrap(router.open(.agentProfile(profile), from: first))
        XCTAssertEqual(first.allSessions.map(\.toolRoute), [])
        XCTAssertEqual(first.popups.sessions.map(\.toolRoute), [.settings, .agentProfile(profile)])
        XCTAssertEqual(first.popups.page?.title, "Edit profile")
        XCTAssertEqual(first.popups.backStack.count, 1)
        XCTAssertTrue(router.owner(of: editor.id)?.store === first)
        XCTAssertTrue(first.openToolTab(.settings) === settings)
        XCTAssertEqual(first.popups.backStack.count, 0)
        let another = try XCTUnwrap(router.open(.settings, from: second))
        XCTAssertFalse(settings === another)
        XCTAssertEqual(first.popups.page?.title, "Settings")
        XCTAssertEqual(second.popups.page?.title, "Settings")
        XCTAssertTrue(second.allSessions.isEmpty)
        let notifications = try XCTUnwrap(router.open(.notifications, from: first))
        XCTAssertFalse(first.popups.isPresented)
        XCTAssertTrue(second.popups.isPresented)
        XCTAssertEqual(first.allSessions.map(\.toolRoute), [.notifications])
        XCTAssertTrue(router.rekey(notifications.id, to: .settings) === settings)
        XCTAssertTrue(first.allSessions.isEmpty)
        XCTAssertEqual(first.popups.page?.title, "Settings")
    }

    func testIncidentalDismissRetainsSameModelAndCancelDiscardsArchive() throws {
        let drafts = DraftRepository(), owner = store(drafts: drafts)
        defer { owner.terminate() }
        let route = ToolRoute.newSSH(draftID: UUID())
        let session = owner.openToolTab(route), state = try XCTUnwrap(session.tabState)
        state.edit(.ssh(name: "Unfinished", host: "work", directory: "/tmp"))
        let draft = try XCTUnwrap(state.draft)
        owner.popups.dismiss(reason: .dismiss)
        XCTAssertFalse(owner.popups.isPresented)
        XCTAssertFalse(state.isClosed)
        XCTAssertEqual(drafts.drafts, [draft])
        XCTAssertTrue(owner.openToolTab(route) === session)
        XCTAssertTrue(owner.popups.draftKept)
        XCTAssertEqual(state.draft, draft)
        owner.popups.dismiss(reason: .cancel)
        XCTAssertTrue(state.isClosed)
        XCTAssertEqual(drafts.drafts, [])
        XCTAssertTrue(owner.popups.sessions.isEmpty)
        let fresh = owner.openToolTab(route)
        XCTAssertFalse(fresh === session)
        XCTAssertNil(fresh.tabState?.draft)
        XCTAssertFalse(owner.popups.draftKept)
    }

    func testBackRetainsProfileAndAccountDraftWithoutPersistingCredential() throws {
        let tokens = MemoryClaudeTokens(), profiles = AgentProfileStore(accountTokens: tokens)
        let owner = store(); defer { owner.terminate() }
        let parent = owner.openToolTab(.agentProfile(UUID()))
        let state = try XCTUnwrap(parent.tabState)
        state.message = "Parent draft"
        owner.popups.presentAccount(profiles: profiles)
        guard case .account(let form) = owner.popups.page else { return XCTFail("account popup missing") }
        form.name = "Work"; form.token = UUID().uuidString
        let credential = form.token
        owner.popups.back()
        XCTAssertEqual(owner.popups.page?.title, "Edit profile")
        XCTAssertEqual(state.message, "Parent draft")
        owner.popups.presentAccount(profiles: profiles)
        guard case .account(let reopened) = owner.popups.page else { return XCTFail("account popup missing") }
        XCTAssertTrue(reopened === form)
        XCTAssertTrue(reopened.token == credential)
        XCTAssertTrue(owner.popups.draftKept)
        XCTAssertTrue(try tokens.accounts().isEmpty)
        XCTAssertTrue(owner.flushPersistence())
        XCTAssertTrue(owner.drafts.drafts.isEmpty)
        owner.popups.dismiss(reason: .cancel)
        XCTAssertTrue(form.token.isEmpty)
        XCTAssertEqual(owner.popups.page?.title, "Edit profile")
    }

    func testRequestDraftNoticeAppearsOnlyForRetainedDeclineReason() throws {
        let drafts = DraftRepository(), owner = store(drafts: drafts)
        defer { owner.terminate() }
        let route = ToolRoute.request(.local, requestID: "decline-draft")
        let session = owner.openToolTab(route), state = try XCTUnwrap(session.tabState)
        XCTAssertFalse(owner.popups.showsDraftNotice)
        owner.popups.dismiss(reason: .dismiss)
        _ = owner.openToolTab(route)
        XCTAssertFalse(owner.popups.showsDraftNotice, "Read-only requests have no reason draft")

        state.edit(.reason("Please narrow the scope first."))
        let draft = try XCTUnwrap(state.draft)
        owner.popups.dismiss(reason: .dismiss)
        XCTAssertEqual(drafts.drafts, [draft])
        XCTAssertTrue(owner.openToolTab(route) === session)
        XCTAssertTrue(owner.popups.showsDraftNotice, "Reopening a retained reason must show Draft kept")
        XCTAssertEqual(state.draft, draft)

        owner.popups.dismiss(reason: .dismiss)
        let restored = store(drafts: drafts)
        defer { restored.terminate() }
        _ = restored.openToolTab(route)
        XCTAssertTrue(restored.popups.showsDraftNotice, "Archived reasons need the notice before a request model mounts")

        state.edit(.reason(""))
        owner.popups.dismiss(reason: .dismiss)
        _ = owner.openToolTab(route)
        XCTAssertFalse(owner.popups.showsDraftNotice, "Clearing the reason leaves no retained text")
    }

    func testOrganizationDecisionHidesParentDraftNoticeWithoutDiscardingFields() throws {
        let drafts = DraftRepository(), owner = store(drafts: drafts)
        defer { owner.terminate() }
        let org = try OrgKey(server: "https://example.com", accountID: "me", orgID: "org")
        let route = ToolRoute.organization(org), session = owner.openToolTab(route)
        let state = try XCTUnwrap(session.tabState), form = OrganizationFormState.form(state, model: nil)
        let expected = OrganizationDraft(name: "Andrew", newTeam: "Design", email: "jane@example.test",
            role: "admin", teams: ["engineering"], renameTeamID: "team", renameText: "Platform")
        form.fields = expected
        let draft = try XCTUnwrap(state.draft)
        owner.popups.dismiss(reason: .dismiss)
        XCTAssertTrue(owner.openToolTab(route) === session)
        XCTAssertTrue(owner.popups.showsDraftNotice)

        XCTAssertTrue(state.confirmation.request(.init(tabID: session.id, targetID: "member"),
            title: "Remove member?", consequences: "Access will be revoked.", verb: "Remove member",
            destructive: true, stillValid: { true }, operation: { XCTFail("This decision was cancelled") }))
        XCTAssertFalse(owner.popups.showsDraftNotice, "A decision must not show its parent form's draft notice")
        XCTAssertTrue(owner.popups.draftKept)
        XCTAssertEqual(form.fields, expected)
        XCTAssertEqual(state.draft, draft)
        XCTAssertEqual(drafts.drafts, [draft])

        state.confirmation.cancel()
        XCTAssertEqual(state.confirmation.phase, .cancelled)
        XCTAssertTrue(owner.popups.showsDraftNotice)
        XCTAssertEqual(form.fields, expected)
        XCTAssertEqual(state.draft, draft)
        XCTAssertEqual(drafts.drafts, [draft])
    }

    func testDirectProfileEntryHasNoBackButSettingsToProfileDoes() throws {
        let owner = store(); defer { owner.terminate() }
        let router = TabRouter(); router.stores = { [owner] }
        let profile = ToolRoute.agentProfile(UUID())

        // This is the sidebar Edit profile route, with no popup parent.
        _ = try XCTUnwrap(router.open(profile, from: owner))
        XCTAssertFalse(owner.popups.canGoBack)
        XCTAssertTrue(owner.popups.backStack.isEmpty)
        owner.popups.dismiss(reason: .dismiss)

        // The original pop1 screenshot opened Edit profile above Settings.
        _ = try XCTUnwrap(router.open(.settings, from: owner))
        _ = try XCTUnwrap(router.open(profile, from: owner))
        XCTAssertTrue(owner.popups.canGoBack)
        XCTAssertEqual(owner.popups.backStack.map(\.title), ["Settings"])
        owner.popups.back()
        XCTAssertEqual(owner.popups.page?.title, "Settings")
        XCTAssertFalse(owner.popups.canGoBack)

        // Retained drafts must not be mistaken for a navigation parent.
        owner.popups.dismiss(reason: .dismiss)
        _ = try XCTUnwrap(router.open(profile, from: owner))
        XCTAssertFalse(owner.popups.canGoBack)
        XCTAssertTrue(owner.popups.backStack.isEmpty)
    }

    func testAccountApplySelectsParentAndClearsCredential() throws {
        let profiles = AgentProfileStore(accountTokens: MemoryClaudeTokens())
        let owner = store(); defer { owner.terminate() }
        _ = owner.openToolTab(.agentProfile(UUID()))
        var selected: UUID?
        owner.popups.presentAccount(profiles: profiles, onAdded: { selected = $0.id })
        guard case .account(let form) = owner.popups.page else { return XCTFail("account popup missing") }
        form.name = "Work"; form.token = UUID().uuidString
        let account = try XCTUnwrap(form.apply())
        owner.popups.completeAccount(account, form: form)
        XCTAssertEqual(selected, account.id)
        XCTAssertEqual(profiles.claudeAccounts.list, [account])
        XCTAssertTrue(form.token.isEmpty)
        XCTAssertEqual(owner.popups.page?.title, "Edit profile")
    }

    func testDestructiveConfirmationBlocksIncidentalDismissAndBack() throws {
        let owner = store(); defer { owner.terminate() }
        _ = owner.openToolTab(.settings)
        var actions = 0
        owner.popups.presentConfirmation(title: "Remove Claude account?", message: "Remove Work?", verb: "Remove") { actions += 1 }
        guard case .confirmation(let confirmation) = owner.popups.page else { return XCTFail("confirmation missing") }
        XCTAssertTrue(owner.popups.locksDismissal)
        XCTAssertFalse(owner.popups.canGoBack)
        owner.popups.dismiss(reason: .dismiss); owner.popups.back()
        XCTAssertTrue(owner.popups.isPresented)
        XCTAssertEqual(owner.popups.page?.title, "Remove Claude account?")
        XCTAssertEqual(actions, 0)
        owner.popups.dismiss(reason: .cancel)
        XCTAssertEqual(confirmation.phase, .cancelled)
        XCTAssertEqual(owner.popups.page?.title, "Settings")
        XCTAssertEqual(actions, 0)
    }

    func testPopupOwnsOverlayGateUntilClosedOrTerminated() throws {
        let owner = store()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        defer { owner.terminate(); window.orderOut(nil) }
        owner.popups.attach(to: window)
        XCTAssertFalse(NavigationPresentationGate.obscures(window))
        _ = owner.openToolTab(.settings)
        XCTAssertTrue(NavigationPresentationGate.obscures(window))
        owner.popups.dismiss(reason: .dismiss)
        XCTAssertFalse(NavigationPresentationGate.obscures(window))
        _ = owner.openToolTab(.settings)
        owner.terminate()
        XCTAssertFalse(NavigationPresentationGate.obscures(window))
    }

    func testNativeDraftUsesExistingBackAndDiscardLifecycleWithoutATab() throws {
        let owner = store(); defer { owner.terminate() }
        _ = owner.openToolTab(.settings)
        var text = "Unfinished folder", callbacks: [String] = []
        let native = PopupCoordinator.NativePage(title: "Folders…", keepsDraft: { !text.isEmpty }, onDismiss: { reason in
            callbacks.append(String(describing: reason))
            if reason != .dismiss { text = "" }
        })
        XCTAssertTrue(owner.popups.presentNative(native))
        XCTAssertEqual(owner.popups.backStack.map(\.title), ["Settings"])
        owner.popups.back()
        XCTAssertEqual(callbacks, ["dismiss"])
        XCTAssertEqual(text, "Unfinished folder")
        XCTAssertTrue(owner.popups.presentNative(native))
        XCTAssertTrue(owner.popups.showsDraftNotice)
        owner.popups.dismiss(reason: .dismiss)
        XCTAssertFalse(owner.popups.isPresented)
        XCTAssertEqual(owner.popups.retainedRuntimeDrafts.map(\.title), ["Folders…"])
        owner.popups.reopenRuntimeDraft(.native(native))
        XCTAssertTrue(owner.popups.showsDraftNotice)
        owner.popups.dismiss(native, reason: .cancel)
        XCTAssertEqual(text, "")
        XCTAssertTrue(owner.popups.retainedRuntimeDrafts.isEmpty)
        XCTAssertEqual(callbacks, ["dismiss", "dismiss", "cancel"])
        XCTAssertTrue(owner.allSessions.isEmpty)
    }

    func testNativeCompletionTargetsItsOwnPageAndTeardownCleansHiddenDialogsOnce() {
        let coordinator = PopupCoordinator()
        var firstDismissals = 0, secondDismissals = 0
        let first = PopupCoordinator.NativePage(title: "Telegram bot", onDismiss: { _ in firstDismissals += 1 })
        let second = PopupCoordinator.NativePage(title: "Sponsored message", onDismiss: { _ in secondDismissals += 1 })
        coordinator.presentNative(first); coordinator.presentNative(second)
        coordinator.dismiss(first, reason: .applied)
        XCTAssertEqual(coordinator.page?.title, "Sponsored message")
        XCTAssertTrue(coordinator.backStack.isEmpty)
        XCTAssertEqual(firstDismissals, 1)
        coordinator.terminate(); coordinator.terminate()
        XCTAssertEqual(secondDismissals, 1)
        XCTAssertFalse(coordinator.isPresented)
    }

    func testNativePresentationCannotReplaceDestructiveDecisionOrCrossWindows() {
        let first = store(), second = store()
        defer { first.terminate(); second.terminate() }
        first.popups.presentConfirmation(title: "Delete custom folder", message: "Items stay where they are.", verb: "Delete", action: {})
        let page = PopupCoordinator.NativePage(title: "Folders…")
        XCTAssertFalse(first.popups.presentNative(page))
        XCTAssertTrue(second.popups.presentNative(page))
        XCTAssertEqual(first.popups.page?.title, "Delete custom folder")
        XCTAssertEqual(second.popups.page?.title, "Folders…")
        second.popups.dismiss(reason: .dismiss)
        XCTAssertTrue(first.popups.locksDismissal)
        XCTAssertFalse(second.popups.isPresented)
    }

    func testConsecutiveEqualHeightNativePagesMeasureTheirOwnContentAndLiveChanges() async throws {
        _ = NSApplication.shared
        let owner = store()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Color.clear.popupHost(owner.popups))
        window.orderFront(nil)
        defer { owner.terminate(); window.orderOut(nil) }

        func page() -> PopupCoordinator.NativePage {
            let result = PopupCoordinator.NativePage(title: "Website")
            result.content = { [weak result] in
                AnyView(Text("Website confirmation")
                    .frame(height: result?.title == "Expanded" ? 140 : 70).padding(20))
            }
            return result
        }
        func waitUntil(_ ready: () -> Bool) async throws -> Bool {
            for _ in 0..<100 {
                window.contentView?.layoutSubtreeIfNeeded()
                if ready() { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        func dialogHeight() throws -> CGFloat {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            return try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).first {
                $0.accessibilityIdentifier() == "popup-dialog"
            }).bounds.height
        }

        let first = page()
        XCTAssertTrue(owner.popups.presentNative(first))
        let firstMeasured = try await waitUntil { first.contentHeight == 110 }
        XCTAssertTrue(firstMeasured, "The first native page must measure its body")
        let firstFitted = try await waitUntil { (try? dialogHeight()) == 173 }
        XCTAssertTrue(firstFitted, "The host must fit the first body plus its header")

        let second = page()
        XCTAssertTrue(owner.popups.presentNative(second))
        let secondMeasured = try await waitUntil { second.contentHeight == 110 }
        XCTAssertTrue(secondMeasured, "An equal-height replacement needs its own measurement")
        XCTAssertEqual(second.contentHeight, first.contentHeight)
        XCTAssertEqual(try dialogHeight(), 173, accuracy: 1)

        second.title = "Expanded"
        let expanded = try await waitUntil { second.contentHeight == 180 && (try? dialogHeight()) == 243 }
        XCTAssertTrue(expanded, "The replacement must still resize when its live content changes")
        XCTAssertEqual(first.contentHeight, 110, "A replacement must not write measurements into its predecessor")
    }

    func testReopeningParentCleansNativeDescendantsAndTerminationDiscardsRetainedText() {
        let owner = store(); defer { owner.terminate() }
        var ended: [String] = [], hasText = true
        _ = owner.openToolTab(.settings)
        let first = PopupCoordinator.NativePage(title: "Folders…", keepsDraft: { hasText }, onDismiss: { reason in
            ended.append("folders-\(reason)")
            if reason == .cancel { hasText = false }
        })
        let second = PopupCoordinator.NativePage(title: "Sponsored message", onDismiss: { ended.append("sponsored-\($0)") })
        owner.popups.presentNative(first); owner.popups.presentNative(second)
        _ = owner.openToolTab(.settings)
        XCTAssertEqual(owner.popups.page?.title, "Settings")
        XCTAssertTrue(owner.popups.backStack.isEmpty)
        XCTAssertEqual(ended, ["folders-dismiss", "sponsored-dismiss"])
        XCTAssertEqual(owner.popups.retainedRuntimeDrafts.map(\.title), ["Folders…"])
        owner.terminate()
        XCTAssertFalse(hasText)
        XCTAssertEqual(ended, ["folders-dismiss", "sponsored-dismiss", "folders-cancel"])
    }
}
