import AppKit
import AgentPadQuietTestSupport
import SwiftUI
import XCTest
@testable import AgentPadKit

/// The old live SwiftUI/native screenshot pairs are archived externally.
/// These native-only checks retain row states not duplicated by service tests.
@MainActor final class ChatNativeActionCaptureTests: XCTestCase {
    private func model(_ messages: [ChatMessage]) -> ChatTimelineW01Model {
        let model = ChatTimelineW01Model(directory: FileManager.default.temporaryDirectory.appendingPathComponent("native-action-states"))
        model.feed.messages = messages
        return model
    }

    func testNativeInvalidTimestampAndToolbarHoverTransitions() async throws {
        XCTAssertTrue(APQuietIsEnabled()); AgentPadFonts.registerOnce()
        let message = ChatTimelineW01.message("invalid-time", day: "invalid fixture timestamp")
        let model = model([message])
        let host = ChatQuietHost(content: AnyView(ChatNativeRowFixture(model: model, message: message,
            members: ChatTimelineW01.members, mentionable: [], me: model.key.accountId, archived: false)
            .frame(width: 760)), dark: false, width: 760, height: 600)
        defer { host.close() }
        try await host.settle()
        let cell = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host.view, ChatNativeShellCell.self).first)
        XCTAssertEqual(cell.timestamp.text.string, "")
        XCTAssertEqual(cell.timestamp.toolTip, message.createdAt)
        XCTAssertFalse(cell.timestamp.isAccessibilityElement())
        cell.rowActions.hover(true)
        XCTAssertTrue(cell.rowActions.active); XCTAssertFalse(cell.rowActions.toolbar.isHidden)
        cell.rowActions.hover(false)
        XCTAssertTrue(cell.rowActions.active, "Row-to-toolbar movement retains the existing grace period")
        cell.rowActions.hover(true, toolbar: true)
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertTrue(cell.rowActions.active)
        cell.rowActions.hover(false, toolbar: true)
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertFalse(cell.rowActions.active); XCTAssertTrue(cell.rowActions.toolbar.isHidden)
        XCTAssertNil(APQuietFailure())
    }

    func testNativeReplySourceTruncationDeletedMissingAndDeletedHost() async throws {
        XCTAssertTrue(APQuietIsEnabled()); AgentPadFonts.registerOnce()
        for state in ["truncated", "deleted-source", "missing", "deleted-host"] {
            var message = ChatTimelineW01.message("reply-source")
            message.inReplyToMessageId = "source"
            if state == "deleted-host" { message.deletedAt = "2026-10-06T12:01:00Z" }
            var source = ChatTimelineW01.message("source", seq: 2)
            source.text = String(repeating: "A retained source excerpt. ", count: 7)
            if state == "deleted-source" { source.deletedAt = "2026-10-06T12:01:00Z" }
            let model = model(state == "missing" ? [message] : [message, source])
            let host = ChatQuietHost(content: AnyView(ChatNativeRowFixture(model: model, message: message,
                members: ChatTimelineW01.members, mentionable: [], me: model.key.accountId, archived: false)
                .frame(width: 420)), dark: false, width: 420, height: 600)
            defer { host.close() }
            try await host.settle()
            let expected = state == "missing" ? "original message" : state == "deleted-source"
                ? "Message deleted" : String(source.text.prefix(90))
            XCTAssertTrue(host.strings.contains("Reply to: " + expected), state)
            try host.press("Reply to: " + expected)
            XCTAssertEqual(model.threadRoot, source.id, state)
        }
        XCTAssertNil(APQuietFailure())
    }

    func testNativeConfirmationPhasesRetainContentAndNarrowButtonGeometry() async throws {
        XCTAssertTrue(APQuietIsEnabled()); AgentPadFonts.registerOnce()
        let style = ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
            increasedContrast: false, alwaysShowTime: false)
        for dm in [false, true] {
            for paneWidth: CGFloat in [260, 420, 760] {
                for phase: NativeTimelineSnapshot.Confirmation.Phase in [.awaiting, .executing, .failed("The deletion could not be confirmed.")] {
                    let consequences = dm ? "Its text will be removed. Replies stay in the thread."
                        : "Copies already in the context of a running agent stay."
                    let value = NativeTimelineSnapshot.Confirmation(actionID: UUID(), phase: phase,
                        title: "Delete this message?", consequences: consequences, verb: "Delete",
                        cancelTitle: "Cancel", destructive: true)
                    let width = paneWidth - 92
                    let plan = ChatNativeConfirmationLayout(value, width: width, scale: 2)
                    let view = ChatNativeInlineConfirmation(frame: CGRect(x: 0, y: 0, width: width, height: plan.height))
                    let host = ChatQuietHost(view: view, dark: false, width: width, height: plan.height)
                    defer { view.unbind(); host.close() }
                    view.configure(value, style: style, coordinator: nil)
                    try await host.settle()
                    XCTAssertEqual(view.title.text.string, "Delete this message?")
                    XCTAssertEqual(view.consequences.text.string, consequences)
                    XCTAssertEqual(view.cancel.isEnabled, phase != .executing)
                    XCTAssertEqual(view.accept.isEnabled, phase == .awaiting)
                    if case .failed(let problem) = phase {
                        XCTAssertEqual(view.error.text.string, problem)
                        XCTAssertEqual(view.cancel.title, "Keep editing")
                        XCTAssertTrue(view.accept.isHidden)
                    } else {
                        XCTAssertEqual(view.cancel.title, "Cancel")
                        XCTAssertTrue(view.error.isHidden)
                    }
                    if paneWidth == 260 {
                        XCTAssertGreaterThan(view.consequences.frame.height, 16)
                        if phase == .executing { XCTAssertGreaterThanOrEqual(view.accept.frame.minY, view.cancel.frame.maxY) }
                    }
                    for control in [view.title, view.consequences, view.error, view.cancel, view.accept, view.spinner] where !control.isHidden {
                        XCTAssertTrue(view.bounds.contains(control.frame), "Every confirmation control stays in its measured reservation")
                    }
                }
            }
        }
        XCTAssertNil(APQuietFailure())
    }
}
