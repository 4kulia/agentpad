import AppKit
import AgentPadQuietTestSupport
import GRDB
import Observation
import SwiftUI
import XCTest
@testable import AgentPadKit

/// Drives the production timeline through its native scroll view. Events stay
/// inside the quiet XCTest process; none are posted to the desktop.
@MainActor
final class ChatScrollContinuityTests: XCTestCase {
    typealias Fixture = ChatScrollFixture
    typealias Probe = ChatScrollProbe
    typealias Mounted<Model: ChatConversationPresentation> = ChatScrollMounted<Model>

    func testNativeMixedHeightScrollContinuity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-scroll-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (root, adapter) in ChatScrollMounts.bothPanes {
            let mounted = try Mounted(model: Fixture(root: root, directory: directory), root: root, adapter: adapter)
            defer { mounted.close() }
            // Begin inside history so elastic boundary clamping is not a jump.
            mounted.viewport.stopFollowing()
            mounted.scroll.contentView.scroll(to: NSPoint(x: 0, y: mounted.scroll.contentView.bounds.minY - 1800))
            mounted.settle()
            try mounted.recordFixture(.mixed, root: root)
            try mounted.drive(.mixed)
            try mounted.recordDiagnostics(ChatScrollWorkload.mixed.caseName(root: root) + "-counters")
            let samples = mounted.probe.samples
            try ChatScrollRecords.write(samples, workload: .mixed, root: root, renderer: adapter.name)
            try ChatScrollRecords.validate(samples, workload: .mixed)
            XCTAssertGreaterThan(samples.flatMap { ($0["heights"] as? [String: CGFloat])?.values.map { $0 } ?? [] }.max() ?? 0, 300,
                                 "Long markdown/code must be laid out, not collapsed to a transient empty text height")
            for kind in ["up", "down"] {
                let values = samples.filter { $0["kind"] as? String == kind }
                let errors = values.compactMap { $0["error"] as? Double }.map(abs)
                XCTAssertEqual(errors.count, values.count, "Every event needs a surviving native message measurement")
                let costs = values.compactMap { $0["milliseconds"] as? Double }.sorted()
                print("CHAT_SCROLL \(root ?? "channel") \(kind) events=\(values.count) jumps=\(errors.filter { $0 > 0.75 }.count) maxJump=\(errors.max() ?? 0) p95ms=\(ChatScrollRecords.percentile95(costs)) maxms=\(costs.last ?? 0)")
                XCTAssertLessThanOrEqual(errors.max() ?? .infinity, 0.75, "\(root ?? "channel") \(kind) continuity")
            }
            XCTAssertNil(APQuietFailure()); XCTAssertFalse(APQuietWindowHasOSFocus(mounted.window))
        }
    }

    func testOlderInsertionAndHeightChangeKeepScreenOffset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-scroll-page-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (root, adapter) in ChatScrollMounts.bothPanes {
            let mounted = try Mounted(model: Fixture(root: root, directory: directory), root: root, adapter: adapter)
            defer { mounted.close() }
            mounted.viewport.stopFollowing()
            mounted.scroll.contentView.scroll(to: NSPoint(x: 0, y: 170))
            mounted.settle()
            for _ in 0..<3 {
                let frame = try XCTUnwrap(mounted.probe.frames["fixture-41"])
                mounted.scroll.contentView.scroll(to: NSPoint(x: 0, y: mounted.scroll.contentView.bounds.minY + frame.minY - 90.25))
                mounted.settle()
            }
            // The first row loses its date/thread-summary header on prepend.
            // Track the next message, whose own content is unchanged.
            let anchor = ("fixture-41", try XCTUnwrap(mounted.probe.frames["fixture-41"]))
            XCTAssertEqual(anchor.1.minY, 90.25, accuracy: 0.75)
            mounted.model.loadOlder()
            mounted.settle()
            XCTAssertFalse(mounted.model.feed.hasOlder)
            let inserted = try XCTUnwrap(mounted.probe.frames[anchor.0])
            print("CHAT_SCROLL \(root ?? "channel") page anchor=\(anchor.0) before=\(anchor.1.minY) after=\(inserted.minY) jump=\(inserted.minY - anchor.1.minY)")
            XCTAssertEqual(inserted.minY, anchor.1.minY, accuracy: 0.75, "Older insertion preserves fractional screen offset")
            let visible = try XCTUnwrap(mounted.anchor())
            let index = try XCTUnwrap(mounted.model.feed.messages.firstIndex { $0.id == visible.0 })
            guard index > 0 else { return XCTFail("Height-change fixture needs a preceding row") }
            mounted.model.feed.messages[index - 1].text += String(repeating: "\nAdditional line of hydrated content.", count: 6)
            mounted.settle()
            let grown = try XCTUnwrap(mounted.probe.frames[visible.0])
            print("CHAT_SCROLL \(root ?? "channel") height before=\(visible.1.minY) after=\(grown.minY) jump=\(grown.minY - visible.1.minY)")
            XCTAssertEqual(grown.minY, visible.1.minY, accuracy: 0.75, "Height changes above preserve fractional screen offset")
            for _ in 0..<4 {
                let origin = mounted.scroll.contentView.bounds.minY
                try mounted.event(1, phase: 0, precise: false)
                XCTAssertGreaterThan(mounted.scroll.contentView.bounds.minY, origin, "A phase-less wheel must release page restoration")
                let sample = try XCTUnwrap(mounted.probe.samples.last)
                XCTAssertEqual(try XCTUnwrap(sample["layoutError"] as? Double), 0, accuracy: 0.75)
            }
        }
    }

    func testLoadEarlierButtonKeepsVisibleMessage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-scroll-button-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (root, adapter) in ChatScrollMounts.bothPanes {
            let mounted = try Mounted(model: Fixture(root: root, directory: directory), root: root, adapter: adapter)
            defer { mounted.close() }
            mounted.viewport.stopFollowing()
            for _ in 0..<3 { mounted.scroll.contentView.scroll(to: .zero); mounted.settle() }
            let before = try XCTUnwrap(mounted.probe.frames["fixture-41"])
            try mounted.clickEarlierButton()
            mounted.settle()
            guard !mounted.model.feed.hasOlder else { return XCTFail("The quiet earlier-page button click must load the page") }
            let after = try XCTUnwrap(mounted.probe.frames["fixture-41"])
            print("CHAT_PAGE_BUTTON \(root ?? "channel") before=\(before.minY) after=\(after.minY) jump=\(after.minY - before.minY)")
            XCTAssertEqual(after.minY, before.minY, accuracy: 0.75)
            XCTAssertNil(APQuietFailure()); XCTAssertFalse(APQuietWindowHasOSFocus(mounted.window))
        }
    }

    func testProjectionAndMarkdownCost() {
        AgentPadFonts.registerOnce()
        let messages = (0..<320).map { Fixture.message($0, root: nil) }
        let start = CACurrentMediaTime()
        for _ in 0..<10 { _ = ChatFeedLayout.rows(messages) }
        let projection = (CACurrentMediaTime() - start) * 100
        let markdownStart = CACurrentMediaTime()
        for _ in 0..<20 { _ = ChatMentionText.attributed(messages[1].text, addresses: []) }
        print("CHAT_SCROLL projection320ms=\(projection) markdownOneLongRowMs=\((CACurrentMediaTime() - markdownStart) * 50)")
    }

    func testGeometricBottomFollowsAfterRevealIsDismissed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-scroll-follow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (root, adapter) in ChatScrollMounts.bothPanes {
            let mounted = try Mounted(model: Fixture(root: root, directory: directory), root: root, adapter: adapter)
            defer { mounted.close() }
            mounted.model.revealMessageID = "fixture-359"; mounted.settle()
            XCTAssertTrue(mounted.viewport.atBottom)
            XCTAssertFalse(mounted.viewport.following)
            mounted.model.revealMessageID = nil; mounted.settle()
            mounted.model.feed.messages.append(Fixture.message(360, root: root)); mounted.settle()
            XCTAssertTrue(mounted.viewport.atBottom, "A dismissed reveal must not strand a reader already at bottom")
            XCTAssertTrue(mounted.viewport.following)
            mounted.model.revealMessageID = "fixture-360"; mounted.settle()
            XCTAssertTrue(mounted.viewport.atBottom)
            mounted.model.feed.messages.append(Fixture.message(363, root: root)); mounted.settle()
            XCTAssertFalse(mounted.viewport.following, "An active reveal stays detached on append")
            // Geometric bottom and follow intent are separate: the legacy
            // stack can remain at bottom as its final row grows or appends.
            XCTAssertNil(APQuietFailure()); XCTAssertFalse(APQuietWindowHasOSFocus(mounted.window))
        }
    }

    func testFollowingRevealEditingAndUnreadAcrossBothPanes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-scroll-behavior-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (root, adapter) in ChatScrollMounts.bothPanes {
            let mounted = try Mounted(model: Fixture(root: root, directory: directory), root: root, adapter: adapter)
            defer { mounted.close() }
            mounted.viewport.jumpToBottom(); mounted.settle()
            mounted.model.feed.messages.append(Fixture.message(360, root: root))
            mounted.settle()
            XCTAssertTrue(mounted.viewport.atBottom, "New messages follow at bottom")
            mounted.model.revealMessageID = "fixture-190"; mounted.settle()
            let revealed = try XCTUnwrap(mounted.probe.frames["fixture-190"])
            XCTAssertGreaterThan(revealed.maxY, 0); XCTAssertLessThan(revealed.minY, 600)
            XCTAssertFalse(mounted.viewport.following)
            mounted.model.revealMessageID = nil
            let old = try XCTUnwrap(mounted.anchor())
            mounted.model.feed.messages.append(Fixture.message(363, root: root))
            mounted.settle()
            XCTAssertEqual(try XCTUnwrap(mounted.probe.frames[old.0]).minY, old.1.minY, accuracy: 0.75)
            XCTAssertTrue(mounted.model.positions[root ?? ""]?.unseen.contains("fixture-363") == true)
            XCTAssertTrue(ChatFeedLayout.rows(mounted.model.feed.messages, unreadID: "fixture-190").contains { $0.id == "fixture-190" && $0.startsUnread })
            let edited = try XCTUnwrap(mounted.model.message("fixture-188"))
            mounted.model.editing = .init(messageId: edited.id, root: root, text: edited.text, revision: 1, message: edited)
            mounted.settle()
            let editor = try XCTUnwrap(mounted.probe.frames[edited.id])
            XCTAssertGreaterThan(editor.maxY, 0); XCTAssertLessThan(editor.minY, 600)
            mounted.model.editing = nil; mounted.settle()
            mounted.viewport.jumpToBottom(); mounted.settle()
            XCTAssertTrue(mounted.viewport.atBottom); XCTAssertTrue(mounted.viewport.following)
            XCTAssertTrue(mounted.model.positions[root ?? ""]?.unseen.isEmpty == true)
            XCTAssertNil(APQuietFailure()); XCTAssertFalse(APQuietWindowHasOSFocus(mounted.window))
        }
    }
}
