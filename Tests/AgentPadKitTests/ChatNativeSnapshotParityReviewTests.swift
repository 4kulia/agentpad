import Foundation
import GRDB
import Observation
import SwiftUI
import XCTest
@testable import AgentPadKit

/// W09: exercise the actual observable adapter boundary, including inputs that
/// deliberately belong to caller chrome rather than to native timeline rows.
@MainActor final class ChatNativeSnapshotParityReviewTests: XCTestCase {
    #if !AGENTPAD_CHAT_NATIVE_W09_CAPTURE
    func testW09ProbeIsInertOutsideCaptureBuilds() {
        var evaluations = 0
        func observed<T>(_ value: T) -> T { evaluations += 1; return value }
        let original = Text("Uninstrumented caller")
        let result = original.chatReviewParity(observed("unused"), text: observed("unused"),
            colors: observed([String: Color]()), font: observed(Font?.none))
        XCTAssertEqual(evaluations, 0, "Ordinary builds must not evaluate probe-only operands")
        XCTAssertEqual(String(reflecting: type(of: result)), String(reflecting: type(of: original)),
            "Ordinary builds must preserve the exact view type without an observation modifier")
    }
    #endif

    private typealias F = ChatTimelineW01
    private typealias S = NativeTimelineSnapshot
    private typealias Input = ChatTimelineSnapshotBuilder.Input
    private var directory: URL!
    private var models: [ChatTimelineW01Model] = []
    private var nativeFixtures: [ChatNativeActionFixture] = []
    private var previousBadge: (@MainActor () -> Void)!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-w09-snapshot-\(UUID())")
        previousBadge = ChatNotifications.badgeChanged
        ChatNotifications.badgeChanged = {}
    }

    override func tearDown() async throws {
        for fixture in nativeFixtures.reversed() { await fixture.close() }
        for model in models { await model.service.disconnect() }
        nativeFixtures.removeAll(); models.removeAll()
        try? FileManager.default.removeItem(at: directory)
        ChatNotifications.badgeChanged = previousBadge
    }

    private func model(dm: Bool) -> ChatTimelineW01Model {
        let value = ChatTimelineW01Model(directory: directory.appendingPathComponent(UUID().uuidString))
        value.isDM = dm; models.append(value)
        return value
    }

    private func capture(_ model: ChatTimelineW01Model, root: String? = nil) -> Input {
        ChatTimelineAdapter.capture(model: model, root: root, members: F.members,
            mentionable: [("w01-me", "anna")], me: "w01-me", archived: model.feed.archived,
            ownerModel: nil, style: F.style(), selectedID: nil, aliases: [:], now: F.day,
            conversation: F.conversation(dm: model.isDM, root: root), epoch: F.epoch)
    }

    private func snapshot(_ adapter: ChatTimelineAdapter, _ model: ChatTimelineW01Model, root: String? = nil) -> S {
        adapter.snapshot(model: model, root: root, members: F.members, mentionable: [("w01-me", "anna")],
            me: "w01-me", archived: model.feed.archived, ownerModel: nil, style: F.style(), now: F.day)
    }

    private func replacing(_ value: Input, messages: [S.MessageContent]? = nil, visuals: [S.Visual]? = nil,
                           state: S.State? = nil, threadSummary: String?? = nil) -> Input {
        .init(conversation: value.conversation, epoch: value.epoch, messages: messages ?? value.messages,
            visuals: visuals ?? value.visuals, requests: value.requests,
            threadSummary: threadSummary ?? value.threadSummary, members: value.members,
            mentionable: value.mentionable, me: value.me, style: value.style, state: state ?? value.state,
            navigation: value.navigation, aliases: value.aliases, today: value.today,
            reactorAccounts: value.reactorAccounts)
    }

    private func content(_ value: S.MessageContent, message: ChatMessage? = nil, author: String? = nil,
                         tooltip: String? = nil, addresses: [String]? = nil, replyTo: String?? = nil,
                         summary: ChatReplySummary?? = nil, replies: Int? = nil, unread: Int? = nil,
                         requests: Int? = nil, actions: S.Availability? = nil,
                         bodyAddresses: [String]?? = nil, sources: [S.SourceStatus]? = nil) -> S.MessageContent {
        .init(message: message ?? value.message, author: author ?? value.author,
            authorTooltip: tooltip ?? value.authorTooltip, addresses: addresses ?? value.addresses,
            replyToText: replyTo ?? value.replyToText, replySummary: summary ?? value.replySummary,
            replyCount: replies ?? value.replyCount, unreadReplyCount: unread ?? value.unreadReplyCount,
            requestCount: requests ?? value.requestCount, editing: value.editing, confirmation: value.confirmation,
            actions: actions ?? value.actions, metadata: value.metadata, sources: sources ?? value.sources,
            membershipHints: value.membershipHints, attachments: value.attachments,
            bodyAddresses: bodyAddresses ?? value.bodyAddresses, sourcesExpanded: value.sourcesExpanded,
            sourceProblem: value.sourceProblem)
    }

    private struct MessageMutation {
        let field: String
        let change: (inout ChatMessage) -> Void
    }

    func testEveryMessageStoredInputReachesAllFourAdapterPanesAndInvalidatesItsRow() throws {
        let mutations: [MessageMutation] = [
            .init(field: "messageId", change: { $0.messageId = "renamed" }),
            .init(field: "channelId", change: { $0.channelId = "another-channel" }),
            .init(field: "dmId", change: { $0.dmId = "another-dm" }),
            .init(field: "authorAccountId", change: { $0.authorAccountId = "former" }),
            .init(field: "seq", change: { $0.seq = nil }),
            .init(field: "createdAt", change: { $0.createdAt = "2026-10-05T12:00:00Z" }),
            .init(field: "hasFixed", change: { $0.hasFixed = false }),
            .init(field: "hasMutable", change: { $0.hasMutable = false }),
            .init(field: "text", change: { $0.text = "Hello **@anna**" }),
            .init(field: "mentions", change: { $0.mentions = ["w01-me"] }),
            .init(field: "revision", change: { $0.revision = 2 }),
            .init(field: "editedAt", change: { $0.editedAt = "2026-10-06T12:01:00Z" }),
            .init(field: "deletedAt", change: { $0.deletedAt = "2026-10-06T12:01:00Z" }),
            .init(field: "authorAgentId", change: { $0.authorAgentId = "w09-agent" }),
            .init(field: "authorAgentName", change: { $0.authorAgentName = "Stored agent" }),
            .init(field: "authorSessionName", change: { $0.authorSessionName = "Fixture session" }),
            .init(field: "inReplyToMessageId", change: { $0.inReplyToMessageId = "unloaded" }),
            .init(field: "stale", change: { $0.stale = 2 }),
            .init(field: "localState", change: { $0.localState = .sending }),
            .init(field: "localError", change: { $0.localError = "Fixture delivery error" }),
            .init(field: "attachments", change: { $0.attachments = [.init(attachmentId: "file", position: 0,
                name: "fixture.txt", mime: "text/plain", size: 12, hasPreview: false, width: nil, height: nil)] }),
            .init(field: "attachmentOnly", change: { $0.attachmentOnly = true }),
            .init(field: "localEdit", change: { $0.localEdit = .init(kind: "edit", text: "Recovery text", state: "failed", error: "Fixture edit error") })
        ]
        // This fails when a new stored field has no transition case. Pane
        // membership (threadRootId) has its own explicit remove/insert test.
        XCTAssertEqual(Set(mutations.map(\.field)).union(["threadRootId"]),
            Set(Mirror(reflecting: F.message("m")).children.compactMap(\.label)))
        for dm in [false, true] {
            for root in [nil, "thread"] as [String?] {
                let model = model(dm: dm)
                let original = F.message("m", root: root, dm: dm)
                for mutation in mutations {
                    model.feed.messages = [original]
                    let adapter = ChatTimelineAdapter(epoch: F.epoch)
                    defer { adapter.invalidate() }
                    let beforeInput = capture(model, root: root)
                    let before = snapshot(adapter, model, root: root)
                    let observed = expectation(description: "\(dm)/\(root ?? "feed")/\(mutation.field)")
                    withObservationTracking { _ = capture(model, root: root) } onChange: { observed.fulfill() }
                    var changed = original; mutation.change(&changed)
                    XCTAssertNotEqual(changed, original, mutation.field)
                    model.feed.messages = [changed]
                    wait(for: [observed], timeout: 1)
                    let expected = expectedMessage(changed, field: mutation.field, dm: dm,
                        baseline: try XCTUnwrap(beforeInput.messages.first))
                    let expectedVisual: S.Visual
                    if mutation.field == "authorAgentId" {
                        expectedVisual = .init(selected: false,
                            avatars: [.init(reference: .init(key: model.key, subject: .agent("w09-agent")),
                                metadata: nil, generation: 0, context: nil)], avatarAccess: 0,
                            attachmentPreviews: [:], attachmentEpoch: 0, metadataTicket: nil, metadataHead: nil)
                    } else { expectedVisual = F.visual(message: changed, key: model.key) }
                    let summary: String? = root == nil ? nil : mutation.field == "seq" ? "0 replies" : mutation.field == "hasFixed" ? "1+ replies" : "1 reply"
                    XCTAssertEqual(capture(model, root: root), replacing(beforeInput,
                        messages: [expected], visuals: [expectedVisual], threadSummary: .some(summary)), mutation.field)
                    let after = snapshot(adapter, model, root: root)
                    XCTAssertEqual(after.messageIDs, [changed.id], mutation.field)
                    let row = try XCTUnwrap(after.rows.first { $0.messageID == changed.id })
                    XCTAssertEqual(row.payload, .message(.init(content: expected, startsGroup: true, inThread: root != nil)), mutation.field)
                    XCTAssertEqual(row.visual, expectedVisual, mutation.field)
                    XCTAssertEqual(after.generation, before.generation + 1, mutation.field)
                    XCTAssertEqual(row.contentRevision, after.generation, mutation.field)
                    XCTAssertEqual(row.layoutRevision, after.generation, mutation.field)
                    XCTAssertEqual(snapshot(adapter, model, root: root), after, "Unchanged \(mutation.field) must not rebuild")
                    model.feed.messages = [original]
                    XCTAssertEqual(capture(model, root: root), beforeInput, "Reverse \(mutation.field)")
                    let restored = snapshot(adapter, model, root: root)
                    XCTAssertEqual(restored.messageIDs, before.messageIDs, mutation.field)
                    XCTAssertEqual(restored.rows.map(\.payload), before.rows.map(\.payload), mutation.field)
                    XCTAssertEqual(restored.rows.map(\.visual), before.rows.map(\.visual), mutation.field)
                    XCTAssertEqual(model.readingCalls, [], "Snapshot capture must not create read visits")
                    XCTAssertEqual(model.events, [])
                }
            }
        }
    }

    private func expectedMessage(_ message: ChatMessage, field: String, dm: Bool, baseline: S.MessageContent) -> S.MessageContent {
        var author = "Anna", tooltip = "Anna · @anna · w01-me"
        var reply = true, edit = true, delete = true, save = true
        var body: [String]? = ["anna"]
        switch field {
        case "authorAccountId": author = "Former member"; tooltip = "Former member · former"
        case "hasFixed": author = ""; tooltip = " · @anna · w01-me"; reply = false
        case "hasMutable": body = nil
        case "deletedAt": reply = dm; edit = false; delete = false; save = false; body = nil
        case "authorAgentId": author = "Agent"; tooltip = "Agent (Anna's agent) · @anna · w01-me"
        case "authorSessionName": author = "Fixture session (Anna's agent)"; tooltip = author + " · @anna · w01-me"
        case "localState": reply = false; edit = false; delete = false; save = false
        default: break
        }
        let link: String? = !dm && message.seq != nil
            ? "agentpad://chat?server=https://timeline.invalid:443&org=w01-org&channel=\(message.channelId)&message=\(message.id)&seq=\(message.seq!)" : nil
        return content(baseline, message: message, author: author, tooltip: tooltip,
            addresses: field == "text" ? ["anna"] : [], replyTo: .some(field == "inReplyToMessageId" ? "original message" : nil),
            actions: .init(reply: reply, edit: edit, delete: delete, retry: true, save: save, recoverEdit: true, copyLink: link),
            bodyAddresses: .some(body))
    }

    func testThreadRootInputMovesTheMessageBetweenFeedAndThreadWithoutInventingAliases() {
        for dm in [false, true] {
            let model = model(dm: dm), original = F.message("m", dm: dm)
            let feedAdapter = ChatTimelineAdapter(epoch: F.epoch), threadAdapter = ChatTimelineAdapter(epoch: F.otherEpoch)
            defer { feedAdapter.invalidate(); threadAdapter.invalidate() }
            model.feed.messages = [original]
            let feedBefore = snapshot(feedAdapter, model), threadBefore = snapshot(threadAdapter, model, root: "thread")
            XCTAssertEqual(feedBefore.messageIDs, ["m"]); XCTAssertEqual(threadBefore.messageIDs, [])
            var reply = original; reply.threadRootId = "thread"
            model.feed.messages = [reply]
            let feedAfter = snapshot(feedAdapter, model), threadAfter = snapshot(threadAdapter, model, root: "thread")
            XCTAssertEqual(feedAfter.rows.map(\.payload), [.inset(16), .empty("No messages yet"), .inset(20)])
            XCTAssertEqual(threadAfter.messageIDs, ["m"])
            XCTAssertEqual(capture(model, root: "thread").messages.map(\.message), [reply])
            XCTAssertEqual(threadAfter.messageAliases, [:]); XCTAssertEqual(feedAfter.messageAliases, [:])
            XCTAssertEqual(threadAfter.rows.compactMap { row -> String? in
                if case .threadSummary(let label) = row.payload { return label }; return nil
            }, ["1 reply"])
            model.feed.messages = [original]
            XCTAssertEqual(snapshot(feedAdapter, model).rows.map(\.payload), feedBefore.rows.map(\.payload))
            XCTAssertEqual(snapshot(threadAdapter, model, root: "thread").rows.map(\.payload), threadBefore.rows.map(\.payload))
        }
    }

    func testEveryFeedStoredInputIsObservedAndProjectsOnlyItsTimelineDependencies() throws {
        let fields = ["messages", "replies", "replySummaries", "unreadReplyCounts", "unloadedUnreadReplyCount",
            "firstUnloadedUnreadThread", "unreadID", "earlierUnread", "boundaryDismissed", "requests", "hasOlder", "historyNext", "archived"]
        XCTAssertEqual(Set(fields), Set(Mirror(reflecting: ChatChannelModel.Feed()).children.compactMap(\.label)))
        let unprojected = Set(["unloadedUnreadReplyCount", "firstUnloadedUnreadThread", "boundaryDismissed", "historyNext"])
        for dm in [false, true] {
            let model = model(dm: dm)
            let original = F.message("m", dm: dm)
            for field in fields {
                model.feed = .init(); model.feed.archived = false; model.feed.messages = [original]
                let originalFeed = model.feed
                let adapter = ChatTimelineAdapter(epoch: F.epoch)
                defer { adapter.invalidate() }
                let beforeInput = capture(model), before = snapshot(adapter, model)
                let observed = expectation(description: "feed/\(dm)/\(field)")
                withObservationTracking { _ = capture(model) } onChange: { observed.fulfill() }
                let base = try XCTUnwrap(beforeInput.messages.first)
                var expectedContent = base, expectedVisual = try XCTUnwrap(beforeInput.visuals.first)
                var archived = false, hasOlder = false, earlierUnread = false, unreadID: String?
                switch field {
                case "messages":
                    var changed = original; changed.text = "Updated feed message"
                    model.feed.messages = [changed]; expectedContent = content(base, message: changed)
                case "replies": model.feed.replies = ["m": 2]; expectedContent = content(base, replies: 2)
                case "replySummaries":
                    let summary = ChatReplySummary(messages: [F.message("reply", seq: 2, root: "m", dm: dm)], complete: true)
                    model.feed.replySummaries = ["m": summary]; expectedContent = content(base, summary: .some(summary))
                    expectedVisual = .init(selected: false, avatars: expectedVisual.avatars + expectedVisual.avatars,
                        avatarAccess: 0, attachmentPreviews: [:], attachmentEpoch: 0, metadataTicket: nil, metadataHead: nil)
                case "unreadReplyCounts": model.feed.unreadReplyCounts = ["m": 3]; expectedContent = content(base, unread: 3)
                case "unloadedUnreadReplyCount": model.feed.unloadedUnreadReplyCount = 4
                case "firstUnloadedUnreadThread": model.feed.firstUnloadedUnreadThread = "unloaded"
                case "unreadID": model.feed.unreadID = "m"; unreadID = "m"
                case "earlierUnread": model.feed.earlierUnread = true; earlierUnread = true
                case "boundaryDismissed": model.feed.boundaryDismissed = true
                case "requests": model.feed.requests = ["m": 5]; expectedContent = content(base, requests: 5)
                case "hasOlder": model.feed.hasOlder = true; hasOlder = true
                case "historyNext": model.feed.historyNext = 17
                case "archived":
                    model.feed.archived = true; archived = true
                    expectedContent = content(base, actions: .init(reply: true, edit: true, delete: true,
                        retry: false, save: false, recoverEdit: true, copyLink: base.actions.copyLink))
                default: XCTFail("Missing feed case \(field)")
                }
                wait(for: [observed], timeout: 1)
                let state = S.State(isDM: dm, archived: archived, hasOlder: hasOlder, earlierUnread: earlierUnread,
                    unreadID: unreadID, searching: false, hasNavigationReturn: false, position: F.state().position,
                    accessibilityLabel: dm ? "Direct messages" : "Channel messages")
                XCTAssertEqual(capture(model), replacing(beforeInput, messages: [expectedContent], visuals: [expectedVisual], state: state), field)
                let after = snapshot(adapter, model)
                if unprojected.contains(field) {
                    XCTAssertEqual(after, before, "\(field) belongs outside the timeline snapshot")
                } else {
                    XCTAssertEqual(after.generation, before.generation + 1, field)
                    XCTAssertEqual(after.state, state, field)
                    let row = try XCTUnwrap(after.rows.first { $0.messageID == "m" })
                    XCTAssertEqual(row.payload, .message(.init(content: expectedContent, startsGroup: true, inThread: false)), field)
                    XCTAssertEqual(row.visual, expectedVisual, field)
                    if ["messages", "replies", "replySummaries", "unreadReplyCounts", "requests", "archived"].contains(field) {
                        XCTAssertEqual(row.contentRevision, after.generation, field)
                        XCTAssertEqual(row.layoutRevision, after.generation, field)
                    }
                    XCTAssertEqual(after.rowIDs.map(\.kind), [.topInset]
                        + (earlierUnread ? [.earlierUnread] : []) + (hasOlder ? [.olderControl] : [])
                        + [.dayBoundary("m")] + (unreadID == nil ? [] : [.unreadBoundary("m")])
                        + [.message("m"), .bottomInset], field)
                }
                XCTAssertEqual(snapshot(adapter, model), after, field)
                model.feed = originalFeed
                XCTAssertEqual(capture(model), beforeInput, "Reverse \(field)")
                XCTAssertEqual(snapshot(adapter, model).rows.map(\.payload), before.rows.map(\.payload), field)
                XCTAssertEqual(model.readingCalls, []); XCTAssertEqual(model.events, [])
            }
        }
    }

    func testLocalDeliveryAndEditRecoverySubstatesRemainWholeInputsAtTheSameMessageID() throws {
        let model = model(dm: false), adapter = ChatTimelineAdapter(epoch: F.epoch)
        defer { adapter.invalidate() }
        let original = F.message("m")
        let edits: [ChatMessage.LocalEdit?] = [nil,
            .init(kind: "edit", text: "First draft", state: "saving", error: nil),
            .init(kind: "edit", text: "First draft", state: "failed", error: "Conflict"),
            .init(kind: "edit", text: "Second draft", state: "failed", error: "Offline"),
            .init(kind: "delete", text: nil, state: "saving", error: nil),
            .init(kind: "delete", text: nil, state: "failed", error: "Denied"), nil]
        var previous: S.Row?
        for edit in edits {
            var message = original; message.localEdit = edit; model.feed.messages = [message]
            let value = snapshot(adapter, model), row = try XCTUnwrap(value.rows.first { $0.messageID == "m" })
            XCTAssertEqual(capture(model).messages.map(\.message), [message])
            if let previous { XCTAssertGreaterThan(row.contentRevision, previous.contentRevision); XCTAssertEqual(row.id, previous.id) }
            previous = row
        }
        for state in [ChatMessage.LocalState.sending, .failed, .sending] {
            var message = original; message.seq = nil; message.localState = state
            message.localError = state == .failed ? "Delivery refused" : nil
            model.feed.messages = [message]
            let row = try XCTUnwrap(snapshot(adapter, model).rows.first { $0.messageID == "m" })
            guard case .message(let payload) = row.payload else { return XCTFail("Expected message payload") }
            XCTAssertEqual(payload.content.message, message)
            XCTAssertEqual(payload.content.actions, .init(reply: false, edit: false, delete: false,
                retry: true, save: false, recoverEdit: true, copyLink: nil))
            if let previous { XCTAssertGreaterThan(row.contentRevision, previous.contentRevision); XCTAssertEqual(row.id, previous.id) }
            previous = row
        }
    }

    func testJournalOnlyPublicationCancellationReachesTheMountedNativeRowWithEqualMessages() async throws {
        let f = try await ChatNativeActionFixture(count: 2); nativeFixtures.append(f)
        let id = UUID().uuidString.lowercased(), source = f.messages[0].id
        try f.base.move("finished", 1, id: id, publication: "awaiting_publish")
        try f.base.write("UPDATE requests SET source_message_id = ?, owner_account_id = ?, initiator_account_id = ? WHERE request_id = ?",
            [source, f.base.key.accountId, CallJSON.boris, id])
        try await f.settle()
        let before = try XCTUnwrap(f.coordinator.snapshot)
        let messages = f.model.feed.messages, statuses = f.model.sourceStatuses
        let old = try XCTUnwrap(before.rows.first { $0.messageID == source })
        guard case .message(let oldPayload) = old.payload else { return XCTFail("Expected source message") }
        XCTAssertEqual(oldPayload.content.sources.map(\.word), ["finished · awaiting publication"])
        let observed = expectation(description: "journal detail observation reaches adapter")
        withObservationTracking { f.update() } onChange: { observed.fulfill() }
        try f.base.journal.blockAutomaticRequest(f.base.key, request: id)
        await fulfillment(of: [observed], timeout: 2)
        try await f.settle()
        let after = try XCTUnwrap(f.coordinator.snapshot), row = try XCTUnwrap(after.rows.first { $0.messageID == source })
        let status = try XCTUnwrap(oldPayload.content.sources.first)
        let expected = content(oldPayload.content, sources: [.init(value: status.value,
            word: "finished · automatic publication cancelled", activity: status.activity,
            connected: status.connected, canGoToAnswer: status.canGoToAnswer)])
        XCTAssertEqual(row.payload, .message(.init(content: expected, startsGroup: oldPayload.startsGroup, inThread: false)))
        XCTAssertEqual(row.visual, old.visual); XCTAssertEqual(row.id, old.id)
        XCTAssertGreaterThan(row.contentRevision, old.contentRevision); XCTAssertGreaterThan(row.layoutRevision, old.layoutRevision)
        XCTAssertEqual(after.rows.filter { $0.messageID != source }, before.rows.filter { $0.messageID != source })
        XCTAssertEqual(f.model.feed.messages, messages); XCTAssertEqual(f.model.sourceStatuses, statuses)
    }

    func testDatabaseReadOnlyTransitionUpdatesMountedNativeAvailabilityWithEqualMessages() async throws {
        let f = try await ChatNativeActionFixture(count: 1); nativeFixtures.append(f)
        try await f.settle()
        let id = f.messages[0].id, before = try XCTUnwrap(f.coordinator.snapshot)
        let messages = f.model.feed.messages, old = try XCTUnwrap(before.rows.first { $0.messageID == id })
        guard case .message(let oldPayload) = old.payload else { return XCTFail("Expected message") }
        XCTAssertTrue(oldPayload.content.actions.edit); XCTAssertTrue(oldPayload.content.actions.delete)
        let observed = expectation(description: "archive database observation reaches adapter")
        withObservationTracking { f.update() } onChange: { observed.fulfill() }
        try f.base.write("UPDATE channels SET archived = 1 WHERE channel_id = ?", [f.model.channel])
        await fulfillment(of: [observed], timeout: 2)
        try await f.settle()
        let after = try XCTUnwrap(f.coordinator.snapshot), row = try XCTUnwrap(after.rows.first { $0.messageID == id })
        let expected = content(oldPayload.content, actions: .init(reply: true, edit: false, delete: true,
            retry: false, save: false, recoverEdit: true, copyLink: oldPayload.content.actions.copyLink))
        XCTAssertTrue(after.state.archived)
        XCTAssertEqual(row.payload, .message(.init(content: expected, startsGroup: oldPayload.startsGroup, inThread: false)))
        XCTAssertEqual(row.visual, old.visual); XCTAssertEqual(row.id, old.id)
        XCTAssertGreaterThan(row.contentRevision, old.contentRevision); XCTAssertGreaterThan(row.layoutRevision, old.layoutRevision)
        XCTAssertEqual(after.rows.filter { $0.messageID != id }, before.rows.filter { $0.messageID != id })
        XCTAssertEqual(f.model.feed.messages, messages)
        try f.base.write("UPDATE channels SET archived = 0 WHERE channel_id = ?", [f.model.channel])
        try await f.settle()
        XCTAssertEqual(f.coordinator.snapshot?.rows.map(\.payload), before.rows.map(\.payload))
        XCTAssertFalse(try XCTUnwrap(f.coordinator.snapshot).state.archived)
    }
}
