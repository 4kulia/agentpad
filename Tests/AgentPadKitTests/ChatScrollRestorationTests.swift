import AppKit
import AgentPadQuietTestSupport
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatScrollRestorationTests: XCTestCase {
    typealias Fixture = ChatScrollContinuityTests.Fixture
    typealias Mounted = ChatScrollContinuityTests.Mounted<Fixture>

    private func fixture(root: String?, directory: URL) -> Fixture {
        let model = Fixture(root: root, directory: directory)
        if let root {
            var message = Fixture.message(0, root: nil)
            message.messageId = root
            message.text = "Thread root kept first"
            model.feed.messages.insert(message, at: 0)
        }
        return model
    }

    private func textView(_ mounted: Mounted, prefix: String, file: StaticString = #filePath, line: UInt = #line) throws -> NSTextView {
        try XCTUnwrap(Mounted.descendants(mounted.host, NSTextView.self).first { $0.string.hasPrefix(prefix) },
                      "The reading anchor must remain materialized", file: file, line: line)
    }

    private func position(_ mounted: Mounted, id: String, prefix: String, at y: CGFloat) throws {
        mounted.model.revealMessageID = id
        mounted.settle()
        mounted.model.revealMessageID = nil
        mounted.viewport.stopFollowing()
        for _ in 0..<3 {
            let text = try textView(mounted, prefix: prefix)
            mounted.scroll.contentView.scroll(to: NSPoint(x: 0, y: mounted.scroll.contentView.bounds.minY + text.convert(.zero, to: mounted.host).y - y))
            mounted.settle()
        }
        XCTAssertEqual(try textView(mounted, prefix: prefix).convert(.zero, to: mounted.host).y, y, accuracy: 0.75)
    }

    func testAsyncPageKeepsLatestReadingAnchorWithRootFirst() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-page-r2-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (root, adapter) in ChatScrollMounts.bothPanes {
            let model = fixture(root: root, directory: directory)
            let target = try XCTUnwrap(model.feed.messages.firstIndex { $0.id == "fixture-53" })
            model.feed.messages[target].text = "Async page reading anchor\nThe reader moves while earlier messages load."
            let mounted = try Mounted(model: model, root: root, adapter: adapter)
            defer { mounted.close() }
            try position(mounted, id: "fixture-53", prefix: "Async page reading anchor", at: 180.25)
            mounted.viewport.stopFollowing(preservingAnchor: true)
            // A suspended page request: the reader scrolls after requesting it,
            // before the new prefix arrives. The root remains at index zero.
            var completion: CheckedContinuation<Void, Never>?
            let loaded = expectation(description: "Earlier messages received")
            let page = Task { @MainActor in
                await withCheckedContinuation { completion = $0 }
                guard !Task.isCancelled else { return }
                model.feed.messages.insert(contentsOf: (1..<40).map { Fixture.message($0, root: root) }, at: root == nil ? 0 : 1)
                model.feed.hasOlder = false
                loaded.fulfill()
            }
            defer { page.cancel(); completion?.resume() }
            mounted.settle()
            let response = try XCTUnwrap(completion)
            for index in 0..<4 { try mounted.event(8, phase: index == 0 ? 1 : 2) }
            try mounted.event(0, phase: 4)
            mounted.settle()
            let before = try textView(mounted, prefix: "Async page reading anchor").convert(.zero, to: mounted.host).y
            XCTAssertLessThan(before, 180.25 - 20)
            let first = model.feed.messages.first?.id
            completion = nil
            response.resume()
            wait(for: [loaded], timeout: 2)
            mounted.settle()
            if root != nil { XCTAssertEqual(model.feed.messages.first?.id, first) }
            let after = try textView(mounted, prefix: "Async page reading anchor").convert(.zero, to: mounted.host).y
            print("CHAT_RESTORE async-page \(root ?? "channel") before=\(before) after=\(after)")
            XCTAssertEqual(after, before, accuracy: 0.75)
            XCTAssertNil(APQuietFailure())
        }
    }

    func testDeletingOrEditingPredecessorKeepsGroupedMessageText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-group-r2-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (root, adapter) in ChatScrollMounts.bothPanes {
            for deletion in [true, false] {
                let model = fixture(root: root, directory: directory)
                let target = try XCTUnwrap(model.feed.messages.firstIndex { $0.id == "fixture-185" })
                model.feed.messages[target].text = "Grouped reading anchor\nStill reading this unchanged text."
                let mounted = try Mounted(model: model, root: root, adapter: adapter)
                defer { mounted.close() }
                try position(mounted, id: "fixture-185", prefix: "Grouped reading anchor", at: 8.25)
                XCTAssertFalse(try XCTUnwrap(ChatFeedLayout.rows(model.feed.messages).first { $0.id == "fixture-185" }).startsGroup)
                let before = try textView(mounted, prefix: "Grouped reading anchor").convert(.zero, to: mounted.host).y
                let preceding = try XCTUnwrap(mounted.probe.frame("fixture-184"))
                XCTAssertLessThanOrEqual(preceding.maxY, before)
                if deletion { model.feed.messages[target - 1].deletedAt = "2026-10-22T12:00:00Z" }
                else { model.feed.messages[target - 1].stale = model.feed.messages[target - 1].revision + 1 }
                mounted.settle()
                XCTAssertTrue(try XCTUnwrap(ChatFeedLayout.rows(model.feed.messages).first { $0.id == "fixture-185" }).startsGroup)
                let after = try textView(mounted, prefix: "Grouped reading anchor").convert(.zero, to: mounted.host).y
                print("CHAT_RESTORE regroup \(root ?? "channel") deletion=\(deletion) before=\(before) after=\(after)")
                XCTAssertEqual(after, before, accuracy: 0.75, "Preserve the text, including its changing offset inside the row")
                if !deletion {
                    // A remote edit first announces a stale revision (ungrouped),
                    // then hydrates its text and rejoins the following message.
                    model.feed.messages[target - 1].text += "\nThe edit above has arrived."
                    model.feed.messages[target - 1].revision += 1
                    model.feed.messages[target - 1].editedAt = "2026-10-22T12:00:00Z"
                    model.feed.messages[target - 1].stale = nil
                    mounted.settle()
                    XCTAssertFalse(try XCTUnwrap(ChatFeedLayout.rows(model.feed.messages).first { $0.id == "fixture-185" }).startsGroup)
                    XCTAssertEqual(try textView(mounted, prefix: "Grouped reading anchor").convert(.zero, to: mounted.host).y, before, accuracy: 0.75)
                }
            }
        }
    }

    func testLiveWidthChangeKeepsMidHistoryTextAndFollowingDetached() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-resize-r2-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (root, adapter) in ChatScrollMounts.bothPanes {
            let model = fixture(root: root, directory: directory)
            let target = try XCTUnwrap(model.feed.messages.firstIndex { $0.id == "fixture-185" })
            model.feed.messages[target].text = "Resize reading anchor\n" + String(repeating: "Unchanged content reflows as the split pane changes width. ", count: 8)
            let mounted = try Mounted(model: model, root: root, resizable: true, adapter: adapter)
            defer { mounted.close() }
            try position(mounted, id: "fixture-185", prefix: "Resize reading anchor", at: 8.25)
            let before = try textView(mounted, prefix: "Resize reading anchor").convert(.zero, to: mounted.host).y
            let initialWidth = mounted.scroll.contentView.bounds.width
            mounted.host.viewWillStartLiveResize()
            for width in [initialWidth - 40, initialWidth - 100, initialWidth + 40, initialWidth] {
                mounted.window.setContentSize(NSSize(width: width, height: 600))
                mounted.settle()
                XCTAssertEqual(mounted.scroll.contentView.bounds.width, width, accuracy: 2)
                let after = try textView(mounted, prefix: "Resize reading anchor").convert(.zero, to: mounted.host).y
                print("CHAT_RESTORE resize \(root ?? "channel") width=\(width) before=\(before) after=\(after)")
                XCTAssertEqual(after, before, accuracy: 0.75)
                XCTAssertFalse(mounted.viewport.following)
            }
            mounted.host.viewDidEndLiveResize()
        }
    }

}
