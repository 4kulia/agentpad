import Foundation
import XCTest
@testable import AgentPadKit

@MainActor final class ChatTimelineActionsTests: XCTestCase {
    private typealias F = ChatTimelineW01
    private var directory: URL!
    private var model: ChatTimelineW01Model!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-timeline-w01-actions-\(UUID().uuidString)")
        model = ChatTimelineW01Model(directory: directory)
        model.feed.messages = [F.message("root"), F.message("reply", seq: 2, root: "root")]
    }
    override func tearDown() async throws {
        await model.service.disconnect()
        model = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testAdapterRoutesFeedAndThreadActionsAndFencesUnmountedAdapter() throws {
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        _ = snapshot(adapter)
        let feed = try XCTUnwrap(adapter.actions)
        XCTAssertTrue(feed.perform(.reply, messageID: "root"))
        feed.loadOlder(); feed.markRead(); feed.finishNavigation()
        XCTAssertTrue(feed.dismissTransient())
        XCTAssertEqual(feed.copyText(messageID: "root"), "Text root")
        XCTAssertFalse(feed.perform(.reply, messageID: "reply"), "A thread reply is outside the feed snapshot")
        XCTAssertEqual(model.events, ["thread:root", "older:feed", "read:feed:true", "finish", "dismiss"])
        _ = snapshot(adapter, root: "root")
        let thread = try XCTUnwrap(adapter.actions)
        XCTAssertFalse(feed.perform(.requestDelete(revision: 1), messageID: "root"))
        thread.loadOlder(); thread.markRead()
        XCTAssertTrue(thread.perform(.requestDelete(revision: 1), messageID: "reply"))
        XCTAssertEqual(model.events, ["thread:root", "older:feed", "read:feed:true", "finish", "dismiss", "older:thread", "read:root:true", "delete:reply:root"])
        adapter.invalidate()
        XCTAssertFalse(thread.perform(.reply, messageID: "reply"))
        XCTAssertNil(thread.copyText(messageID: "reply"))
        thread.loadOlder(); thread.markRead(); thread.beginReading(); thread.endReading()
        thread.readIfLooking(appActive: true, shown: true, atBottom: true)
        thread.setPosition(ChatScrollPosition())
        XCTAssertEqual(model.events, ["thread:root", "older:feed", "read:feed:true", "finish", "dismiss", "older:thread", "read:root:true", "delete:reply:root"])
        XCTAssertEqual(model.readingCalls, [])
        XCTAssertEqual(model.positions, [:])
    }

    func testActionsResolveCurrentMessageAndCurrentPermissions() throws {
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        _ = snapshot(adapter)
        let actions = try XCTUnwrap(adapter.actions)
        model.editable = false; model.deletable = false
        XCTAssertFalse(actions.perform(.edit, messageID: "root"))
        XCTAssertFalse(actions.perform(.requestDelete(revision: 1), messageID: "root"))
        model.feed.messages[0].deletedAt = "2026-10-06T12:02:00Z"
        XCTAssertFalse(actions.perform(.reply, messageID: "root"))
        XCTAssertNil(actions.copyText(messageID: "root"))
        model.feed.messages.removeFirst()
        XCTAssertFalse(actions.perform(.reply, messageID: "root"))
        XCTAssertEqual(model.events, [])
        XCTAssertEqual(model.editing, nil)
    }

    func testDeleteRejectsAnUnseenRevisionEvenAfterTheAdapterCapturesIt() throws {
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        let displayed = try XCTUnwrap(snapshot(adapter).rows.compactMap { row -> ChatMessage? in
            if case .message(let value) = row.payload { return value.content.message }; return nil
        }.first)
        let actions = try XCTUnwrap(adapter.actions)
        model.feed.messages[0].revision += 1
        model.feed.messages[0].text = "An unseen edit"
        XCTAssertFalse(model.requestDelete(displayed, root: nil), "The double must enforce the real model's displayed-revision guard")
        XCTAssertFalse(actions.perform(.requestDelete(revision: displayed.revision), messageID: displayed.id))
        _ = snapshot(adapter)
        XCTAssertFalse(actions.perform(.requestDelete(revision: displayed.revision), messageID: displayed.id), "A retained row action must keep its displayed revision")
        XCTAssertEqual(model.events, [])
        XCTAssertTrue(actions.perform(.requestDelete(revision: 2), messageID: displayed.id))
        XCTAssertEqual(model.events, ["delete:root:feed"])
    }

    func testEditingVersionScopeAndMentionTargetsAreCheckedAtDispatch() throws {
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        _ = snapshot(adapter)
        let actions = try XCTUnwrap(adapter.actions)
        XCTAssertTrue(actions.perform(.edit, messageID: "root"))
        let original = ChatChannelModel.Editing(messageId: "root", root: nil, text: "Text root", revision: 1,
            message: F.message("root"), version: "w01-edit-v1")
        XCTAssertEqual(model.editing, original)
        actions.updateEditing(messageID: "root", version: "stale-version", text: "Discard this callback")
        actions.updateEditing(messageID: "reply", version: "w01-edit-v1", text: "Wrong row")
        XCTAssertEqual(model.editing, original)
        actions.updateEditing(messageID: "root", version: "w01-edit-v1", text: "New text")
        XCTAssertEqual(model.editing, ChatChannelModel.Editing(messageId: "root", root: nil, text: "New text", revision: 1,
            message: F.message("root"), version: "w01-edit-v1"))
        XCTAssertTrue(actions.saveEditing(messageID: "root"))
        _ = snapshot(adapter, archived: true)
        XCTAssertFalse(actions.saveEditing(messageID: "root"))
        actions.cancelEditing(messageID: "reply")
        XCTAssertNotNil(model.editing)
        actions.cancelEditing(messageID: "root")
        XCTAssertEqual(model.editing, nil)
        XCTAssertEqual(model.events, ["edit:root:feed:false", "save:w01-me=anna", "cancel:root:false"])
    }

    func testPendingRetryDiscardAndFailedEditRecoveryUseCurrentState() throws {
        var pending = F.message("pending", seq: nil); pending.localState = .failed
        pending.localEdit = .init(kind: "edit", text: "Recovered draft", state: "failed", error: "Offline")
        model.feed.messages = [pending]
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        _ = snapshot(adapter)
        let actions = try XCTUnwrap(adapter.actions)
        XCTAssertTrue(actions.perform(.retry, messageID: "pending"))
        XCTAssertTrue(actions.perform(.discard, messageID: "pending"))
        XCTAssertTrue(actions.perform(.discardEdit, messageID: "pending"))
        XCTAssertEqual(actions.copyFailedEdit(messageID: "pending"), "Recovered draft")
        XCTAssertTrue(actions.perform(.recoverEdit, messageID: "pending"))
        model.retryable = false
        XCTAssertFalse(actions.perform(.retry, messageID: "pending"))
        model.feed.messages[0].localState = nil
        model.feed.messages[0].localEdit = nil
        XCTAssertFalse(actions.perform(.discard, messageID: "pending"))
        XCTAssertFalse(actions.perform(.discardEdit, messageID: "pending"))
        XCTAssertEqual(model.events, ["retry:pending", "discard:pending", "discard-edit:pending", "edit:pending:feed:true"])
    }

    func testOldThreadActionsRejectAChangedThreadBeforeAnotherSnapshot() throws {
        model.threadRoot = "root"
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        _ = snapshot(adapter, root: "root")
        let actions = try XCTUnwrap(adapter.actions)
        model.threadRoot = "another-root"
        XCTAssertFalse(actions.perform(.requestDelete(revision: 1), messageID: "reply"))
        actions.loadOlder(); actions.markRead()
        XCTAssertEqual(model.events, [])
    }

    func testOldActionsRejectServiceReplacementBeforeAnotherSnapshot() async throws {
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        _ = snapshot(adapter)
        let actions = try XCTUnwrap(adapter.actions)
        let oldService = model.service
        model.service = ChatService(files: ChatFiles(directory: directory.appendingPathComponent("replacement")), tokens: FakeTokenStore())
        XCTAssertFalse(actions.perform(.requestDelete(revision: 1), messageID: "root"))
        XCTAssertNil(actions.copyText(messageID: "root"))
        actions.loadOlder(); actions.markRead()
        XCTAssertEqual(model.events, [])
        await oldService.disconnect()
    }

    @discardableResult private func snapshot(_ adapter: ChatTimelineAdapter, root: String? = nil, archived: Bool = false) -> NativeTimelineSnapshot {
        adapter.snapshot(model: model, root: root, members: F.members, mentionable: [("w01-me", "anna")],
            me: "w01-me", archived: archived, ownerModel: nil, style: F.style(), now: F.day)
    }
}
