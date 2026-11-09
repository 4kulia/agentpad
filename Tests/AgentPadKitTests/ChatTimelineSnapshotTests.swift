import Foundation
import XCTest
@testable import AgentPadKit

@MainActor final class ChatTimelineSnapshotTests: XCTestCase {
    private typealias F = ChatTimelineW01
    private typealias S = NativeTimelineSnapshot

    func testWholeOrderedSnapshotForChannelAndTypedDMFeedsAndThreads() {
        for dm in [false, true] {
            for root in [nil, "root"] as [String?] {
                let builder = ChatTimelineSnapshotBuilder()
                let first = F.message("root", seq: 1, dm: dm)
                let reply = F.message("reply", seq: 2, root: root, dm: dm)
                let contents = [F.content(reply), F.content(first)]
                let state = F.state(dm: dm, root: root, older: true, earlierUnread: root == nil, unread: "reply")
                let input = F.input(messages: contents, dm: dm, root: root, state: state)
                let conversation = F.conversation(dm: dm, root: root)
                var rows: [S.Row] = [F.row(.topInset, .inset(16), conversation: conversation)]
                if root == nil { rows.append(F.row(.earlierUnread, .earlierUnread, conversation: conversation)) }
                rows += [F.row(.olderControl, .olderControl(root == nil ? "Load earlier messages" : "Earlier replies"), conversation: conversation),
                         F.row(.dayBoundary("root"), .day(F.day, label: "Today, Oct 6, 2026"), conversation: conversation),
                         F.row(.message("root"), .message(.init(content: F.content(first), startsGroup: true, inThread: root != nil)), conversation: conversation, visual: F.visual()),
                         F.row(.unreadBoundary("reply"), .unread, conversation: conversation)]
                if root != nil { rows.append(F.row(.threadSummary("root"), .threadSummary("2 replies"), conversation: conversation)) }
                rows += [F.row(.message("reply"), .message(.init(content: F.content(reply), startsGroup: true, inThread: root != nil)), conversation: conversation, visual: F.visual()),
                         F.row(.bottomInset, .inset(20), conversation: conversation)]
                let expected = F.expected(rows: rows, ids: ["root", "reply"], dm: dm, root: root, state: state)
                XCTAssertEqual(builder.build(input), expected)
                XCTAssertEqual(builder.build(input), expected, "An identical capture does not create a generation")
            }
        }
    }

    func testSequenceOrderingStableTiesPendingOrderAndRepeatedDayBoundaryIdentity() {
        let builder = ChatTimelineSnapshotBuilder()
        let first = F.message("first", seq: 1)
        let tie = F.message("tie", seq: 1)
        let tomorrow = F.message("tomorrow", seq: 2, day: "2026-10-07T12:00:00Z")
        let clockBack = F.message("clock-back", seq: 3)
        let pendingA = F.message("pending-a", seq: nil)
        let pendingB = F.message("pending-b", seq: nil)
        let actual = builder.build(F.input(messages: [pendingA, first, tie, tomorrow, clockBack, pendingB].map { F.content($0) }))
        XCTAssertEqual(actual, F.expected(rows: [
            F.row(.topInset, .inset(16)),
            F.row(.dayBoundary("first"), .day(F.day, label: "Today, Oct 6, 2026")),
            F.row(.message("first"), .message(.init(content: F.content(first), startsGroup: true, inThread: false)), visual: F.visual()),
            F.row(.message("tie"), .message(.init(content: F.content(tie), startsGroup: false, inThread: false)), visual: F.visual()),
            F.row(.dayBoundary("tomorrow"), .day(F.day.addingTimeInterval(86_400), label: "Oct 7, 2026")),
            F.row(.message("tomorrow"), .message(.init(content: F.content(tomorrow), startsGroup: true, inThread: false)), visual: F.visual()),
            F.row(.dayBoundary("clock-back"), .day(F.day, label: "Today, Oct 6, 2026")),
            F.row(.message("clock-back"), .message(.init(content: F.content(clockBack), startsGroup: true, inThread: false)), visual: F.visual()),
            F.row(.message("pending-a"), .message(.init(content: F.content(pendingA), startsGroup: false, inThread: false)), visual: F.visual()),
            F.row(.message("pending-b"), .message(.init(content: F.content(pendingB), startsGroup: false, inThread: false)), visual: F.visual()),
            F.row(.bottomInset, .inset(20))
        ], ids: ["first", "tie", "tomorrow", "clock-back", "pending-a", "pending-b"]))
    }

    func testPendingAcknowledgementKeepsIdentityAndReplacementRequiresExplicitAlias() {
        let builder = ChatTimelineSnapshotBuilder()
        var pending = F.message("pending", seq: nil); pending.localState = .sending
        _ = builder.build(F.input(messages: [F.content(pending)]))
        let acknowledged = F.message("pending", seq: 4)
        let stable = builder.build(F.input(messages: [F.content(acknowledged)]))
        XCTAssertEqual(stable, F.expected(rows: singleRows(acknowledged, messageRevision: 2), ids: ["pending"], generation: 2))
        let replaced = F.message("server", seq: 4)
        XCTAssertEqual(builder.build(F.input(messages: [F.content(replaced)])),
            F.expected(rows: singleRows(replaced, boundaryRevision: 3, messageRevision: 3), ids: ["server"], generation: 3))

        let aliasBuilder = ChatTimelineSnapshotBuilder()
        _ = aliasBuilder.build(F.input(messages: [F.content(pending)]))
        XCTAssertEqual(aliasBuilder.build(F.input(messages: [F.content(replaced)], aliases: ["pending": "server", "absent": "server", "server": "server"])),
            F.expected(rows: singleRows(replaced, boundaryRevision: 2, messageRevision: 2), ids: ["server"], generation: 2, aliases: ["pending": "server"]))
    }

    func testUnreadMovementAndDeletedPredecessorInvalidateFollowingGroup() {
        let builder = ChatTimelineSnapshotBuilder()
        let first = F.message("first", seq: 1), second = F.message("second", seq: 2)
        _ = builder.build(F.input(messages: [F.content(first), F.content(second)]))
        let unreadState = F.state(unread: "second")
        XCTAssertEqual(builder.build(F.input(messages: [F.content(first), F.content(second)], state: unreadState)), F.expected(rows: [
            F.row(.topInset, .inset(16)), F.row(.dayBoundary("first"), .day(F.day, label: "Today, Oct 6, 2026")),
            F.row(.message("first"), .message(.init(content: F.content(first), startsGroup: true, inThread: false)), visual: F.visual()),
            F.row(.unreadBoundary("second"), .unread, content: 2, layout: 2),
            F.row(.message("second"), .message(.init(content: F.content(second), startsGroup: true, inThread: false)), content: 2, layout: 2, visual: F.visual()),
            F.row(.bottomInset, .inset(20))
        ], ids: ["first", "second"], generation: 2, state: unreadState))
        var deleted = first; deleted.deletedAt = "2026-10-06T12:01:00Z"
        XCTAssertEqual(builder.build(F.input(messages: [F.content(deleted), F.content(second)])), F.expected(rows: [
            F.row(.topInset, .inset(16)), F.row(.dayBoundary("first"), .day(F.day, label: "Today, Oct 6, 2026")),
            F.row(.message("first"), .message(.init(content: F.content(deleted), startsGroup: true, inThread: false)), content: 3, layout: 3, visual: F.visual()),
            F.row(.message("second"), .message(.init(content: F.content(second), startsGroup: true, inThread: false)), content: 2, layout: 2, visual: F.visual()),
            F.row(.bottomInset, .inset(20))
        ], ids: ["first", "second"], generation: 3))
    }

    func testMetadataEditMemberAppearanceSelectionAndMetricRevisions() {
        let message = F.message("m")
        let builder = ChatTimelineSnapshotBuilder()
        _ = builder.build(F.input(messages: [F.content(message)]))
        let metadata = S.Metadata(value: .init(messageId: "m", deleted: false,
            reactions: [.init(emoji: "👍", count: 2, mine: true)], pin: nil, threadSummary: nil), intents: [],
            reactionsSupported: true, pinsSupported: true, summarySupported: true, accessible: true, canChange: true, loadError: nil, problem: nil)
        let enriched = F.content(message, metadata: metadata)
        XCTAssertEqual(builder.build(F.input(messages: [enriched])), F.expected(rows: singleRows(message, content: enriched, messageRevision: 2), ids: ["m"], generation: 2))
        let edit = ChatChannelModel.Editing(messageId: "m", root: nil, text: "Draft", revision: 1, message: message, version: "edit-v1")
        let edited = F.content(message, metadata: metadata, editing: edit)
        XCTAssertEqual(builder.build(F.input(messages: [edited])), F.expected(rows: singleRows(message, content: edited, messageRevision: 3), ids: ["m"], generation: 3))
        let renamed: [ChatOrgView.Member] = [.init(accountId: "w01-me", handle: "anna", name: "Anne", role: "owner")]
        let named = F.content(message, author: "Anne", metadata: metadata, editing: edit)
        XCTAssertEqual(builder.build(F.input(messages: [named], members: renamed)), F.expected(rows: singleRows(message, content: named, messageRevision: 4), ids: ["m"], generation: 4, members: renamed))
        let dark = F.style(appearance: "DarkAqua", alwaysShowTime: true)
        XCTAssertEqual(builder.build(F.input(messages: [named], visuals: [F.visual(selected: true)], style: dark, members: renamed)),
            F.expected(rows: singleRows(message, content: named, boundaryRevision: 5, messageRevision: 5, insetRevision: 5, layoutRevision: 4, decorationLayoutRevision: 1, visual: F.visual(selected: true)), ids: ["m"], generation: 5, style: dark, members: renamed))
        let scaled = F.style(scale: 1, appearance: "DarkAqua", alwaysShowTime: true)
        XCTAssertEqual(builder.build(F.input(messages: [named], visuals: [F.visual(selected: true)], style: scaled, members: renamed)),
            F.expected(rows: singleRows(message, content: named, boundaryRevision: 6, messageRevision: 6, insetRevision: 6, visual: F.visual(selected: true)), ids: ["m"], generation: 6, style: scaled, members: renamed))
    }

    func testCommandsUseMonotonicTokensAndDiscardQueuedRequestsAcrossScopeReset() {
        let builder = ChatTimelineSnapshotBuilder()
        let message = F.message("m"), contents = [F.content(F.message("m"))]
        _ = builder.build(F.input(messages: contents))
        builder.request(.reveal("m"))
        XCTAssertEqual(builder.build(F.input(messages: contents)), F.expected(rows: singleRows(message), ids: ["m"], generation: 2, commands: [.init(token: 1, kind: .reveal("m"))]))
        builder.request(.reveal("m")); builder.request(.reveal("m"))
        XCTAssertEqual(builder.build(F.input(messages: contents)), F.expected(rows: singleRows(message), ids: ["m"], generation: 3, commands: [.init(token: 2, kind: .reveal("m"))]))
        builder.request(.focusMessage("m"))
        XCTAssertEqual(builder.build(F.input(messages: contents, epoch: F.otherEpoch)), F.expected(rows: singleRows(message, boundaryRevision: 4, messageRevision: 4, insetRevision: 4), ids: ["m"], generation: 4, epoch: F.otherEpoch))
        builder.request(.edit("m"))
        let dm = F.message("m", dm: true)
        let conversation = F.conversation(dm: true)
        let dmRows: [S.Row] = [
            F.row(.topInset, .inset(16), conversation: conversation, content: 5, layout: 5),
            F.row(.dayBoundary("m"), .day(F.day, label: "Today, Oct 6, 2026"), conversation: conversation, content: 5, layout: 5),
            F.row(.message("m"), .message(.init(content: F.content(dm), startsGroup: true, inThread: false)), conversation: conversation, content: 5, layout: 5, visual: F.visual()),
            F.row(.bottomInset, .inset(20), conversation: conversation, content: 5, layout: 5)
        ]
        XCTAssertEqual(builder.build(F.input(messages: [F.content(dm)], dm: true)), F.expected(rows: dmRows, ids: ["m"], generation: 5, dm: true))
        builder.request(.reveal("m"))
        let next = builder.build(F.input(messages: [F.content(dm)], dm: true))
        XCTAssertEqual(next, F.expected(rows: dmRows, ids: ["m"], generation: 6, dm: true, commands: [.init(token: 3, kind: .reveal("m"))]))
    }

    private func singleRows(_ message: ChatMessage, content: S.MessageContent? = nil, boundaryRevision: UInt64 = 1,
                            messageRevision: UInt64 = 1, insetRevision: UInt64 = 1, layoutRevision: UInt64? = nil,
                            decorationLayoutRevision: UInt64? = nil,
                            visual: S.Visual = F.visual()) -> [S.Row] {
        [F.row(.topInset, .inset(16), content: insetRevision, layout: decorationLayoutRevision ?? layoutRevision ?? insetRevision),
         F.row(.dayBoundary(message.id), .day(F.day, label: "Today, Oct 6, 2026"), content: boundaryRevision, layout: decorationLayoutRevision ?? layoutRevision ?? boundaryRevision),
         F.row(.message(message.id), .message(.init(content: content ?? F.content(message), startsGroup: true, inThread: false)), content: messageRevision, layout: layoutRevision ?? messageRevision, visual: visual),
         F.row(.bottomInset, .inset(20), content: insetRevision, layout: decorationLayoutRevision ?? layoutRevision ?? insetRevision)]
    }
}
