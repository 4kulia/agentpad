import AppKit
import AgentPadQuietTestSupport
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor final class ChatNativeDrawingParityTests: XCTestCase {
    override func setUp() async throws {
        XCTAssertTrue(APQuietIsEnabled())
        _ = NSApplication.shared
        AgentPadFonts.registerOnce()
    }

    func testNativeShapePathsMatchTheRenderedLegacyPrimitives() async throws {
        let ink = NSColor(srgbRed: 107 / 255, green: 111 / 255, blue: 0, alpha: 1)
        let surface = NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 250 / 255, alpha: 1)
        for shape in ["agent", "badge", "focus", "capsule"] {
            let rect: CGRect = switch shape {
            case "focus": CGRect(x: 0, y: 0, width: 64, height: 64)
            case "capsule": CGRect(x: 4, y: 22.5, width: 56, height: 19)
            case "badge": CGRect(x: 17, y: 25.5, width: 30, height: 13)
            default: CGRect(x: 16, y: 16, width: 32, height: 32)
            }
            let radius: CGFloat = shape == "agent" ? 8.64
                : shape == "capsule" ? 9.5 : 4
            let stroke: CGFloat = shape == "focus" ? 2 : shape == "badge" || shape == "capsule" ? 1 : 0
            let reference: AnyView
            if shape == "capsule" {
                reference = AnyView(Capsule().strokeBorder(Color(nsColor: ink), lineWidth: stroke)
                    .frame(width: rect.width, height: rect.height))
            } else if stroke > 0 {
                reference = AnyView(RoundedRectangle(cornerRadius: radius).strokeBorder(Color(nsColor: ink), lineWidth: stroke)
                    .frame(width: rect.width, height: rect.height))
            } else {
                reference = AnyView(RoundedRectangle(cornerRadius: radius).fill(Color(nsColor: ink))
                    .frame(width: rect.width, height: rect.height).clipShape(RoundedRectangle(cornerRadius: radius)))
            }
            let expected = try await capture(AnyView(reference.frame(width: 64, height: 64).background(Color(nsColor: surface))))
            let canvas = NativeDrawingParityCanvas()
            canvas.render = { context in
                surface.setFill(); CGRect(x: 0, y: 0, width: 64, height: 64).fill()
                ink.setFill(); ink.setStroke()
                context.addPath(ChatNativeShapes.roundedRect(rect.insetBy(dx: stroke / 2, dy: stroke / 2), radius: radius - stroke / 2))
                if stroke == 0 { context.fillPath() }
                else { context.setLineWidth(stroke); context.strokePath() }
            }
            let actual = try await capture(canvas)
            XCTAssertEqual(ChatTimelineParity.exactDifference(expected, actual), 0, shape)
        }
    }

    func testNativeAvatarInitialMatchesLegacyRasterOriginAndOverhangClipping() async throws {
        let fill = NSColor(srgbRed: 107 / 255, green: 111 / 255, blue: 0, alpha: 1)
        for letter in ["A", "F", "R"] {
            let reference = AnyView(Text(letter).font(Theme.display(32 * 0.46, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.white)
                .frame(width: 32, height: 32).frame(width: 64, height: 64).background(Color(nsColor: fill)))
            let expected = try await capture(reference)
            let scale = CGFloat(expected.width) / 64
            let style = ChatTimelineAdapter.style(scale: scale, locale: .current, calendar: .current,
                increasedContrast: false, alwaysShowTime: false)
            let message = ChatTimelineW01.message("avatar-" + letter)
            let snapshot = ChatTimelineSnapshotBuilder().build(ChatTimelineW01.input(
                messages: [ChatTimelineW01.content(message)], style: style))
            let row = try XCTUnwrap(snapshot.rows.first { $0.messageID == message.id })
            var plan = ChatTimelineRowLayoutPlan(id: row.id, width: ChatTimelineWidth(64, scale: Double(scale)), layoutRevision: row.layoutRevision)
            plan.height = 64; plan.avatar = CGRect(x: 16, y: 16, width: 32, height: 32)
            var content = ChatTimelineShellContent(header: NSAttributedString(), body: NSAttributedString(), style: style)
            content.avatar = .init(stableID: "avatar-reference", name: letter, kind: .person)
            let cell = ChatNativeShellCell(kind: .message)
            cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: plan, content: content)
            let canvas = NativeDrawingParityCanvas()
            canvas.render = { context in
                fill.setFill(); CGRect(x: 0, y: 0, width: 64, height: 64).fill()
                cell.drawAvatarText(in: context)
            }
            let actual = try await capture(canvas)
            XCTAssertEqual(expected.width, actual.width); XCTAssertEqual(expected.height, actual.height)
            let maximumDelta = zip(expected.rgba, actual.rgba).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(maximumDelta, 16, "Initial " + letter)
        }
    }

    func testBodyRetainsTextKitHeightAfterMeasurementAndSelectionRepaints() async throws {
        let style = ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
            increasedContrast: false, alwaysShowTime: false)
        for (source, expectedLateHeight) in [("A plain body.", CGFloat(20)), ("A **mixed** body.", CGFloat(19.5))] {
            var message = ChatTimelineW01.message("body-sizing")
            message.text = source
            let snapshot = ChatTimelineSnapshotBuilder().build(ChatTimelineW01.input(
                messages: [ChatTimelineW01.content(message)], root: message.id, style: style))
            let row = try XCTUnwrap(snapshot.rows.first { $0.messageID == message.id })
            let engine = ChatTimelineLayout(), width = ChatTimelineWidth(420, scale: 2)
            let content = engine.content(row, snapshot: snapshot, width: width)
            let plan = engine.plan(row, snapshot: snapshot, width: width)
            let cell = ChatNativeShellCell(kind: .message)
            let host = ChatQuietHost(view: cell, dark: false, width: 420, height: plan.height)
            defer { host.close() }
            cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: plan, content: content)
            try await host.settle()
            XCTAssertEqual(plan.body.height, 20, "The row reserves the whole-point measured height")
            XCTAssertEqual(cell.body.frame.height, 20, "Initial layout does not refresh stable input: " + source)
            let storage = try XCTUnwrap(cell.body.textStorage)
            let normalized = NSAttributedString(attributedString: storage)
            let selection = NSRange(location: 2, length: 3)
            cell.body.setSelectedRange(selection)
            let input = try XCTUnwrap(content.bodyInput)
            var refreshedContent = content
            refreshedContent.bodyInput = .init(markdown: input.markdown, addresses: input.addresses + ["unmatched-address"],
                fontSize: input.fontSize, style: input.style)
            XCTAssertEqual(refreshedContent.body, content.body, "The changed address leaves attributed output equal")
            cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: plan, content: refreshedContent)
            try await host.settle()
            XCTAssertEqual(cell.body.frame.height, expectedLateHeight, "Only a real late input refresh can settle rich text")
            XCTAssertEqual(cell.body.selectedRange(), selection)
            XCTAssertEqual(storage, normalized, "A late attribute refresh keeps the normalized content")
            cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: plan, content: refreshedContent)
            try await host.settle()
            XCTAssertEqual(cell.body.frame.height, expectedLateHeight)
            XCTAssertEqual(cell.body.selectedRange(), selection)
            XCTAssertEqual(storage, normalized, "A repaint keeps TextKit's normalized attributes")
            let narrower = ChatTimelineWidth(390, scale: 2)
            let narrowPlan = engine.plan(row, snapshot: snapshot, width: narrower)
            var narrowContent = engine.content(row, snapshot: snapshot, width: narrower)
            narrowContent.bodyInput = refreshedContent.bodyInput
            cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: narrowPlan, content: narrowContent)
            try await host.settle()
            XCTAssertEqual(cell.body.frame.width, narrowPlan.body.width)
            XCTAssertEqual(cell.body.frame.height, 20, "Width remeasurement reinstalls the whole-point reservation")
            XCTAssertEqual(cell.body.selectedRange(), selection)
            XCTAssertNil(APQuietFailure())
        }
    }

    func testBodyRoundsSettledFractionalHeightOutwardToBackingPixels() async throws {
        let style = ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
            increasedContrast: false, alwaysShowTime: false)
        let message = ChatTimelineW01.message("fractional-body")
        let snapshot = ChatTimelineSnapshotBuilder().build(ChatTimelineW01.input(
            messages: [ChatTimelineW01.content(message)], root: message.id, style: style))
        let row = try XCTUnwrap(snapshot.rows.first { $0.messageID == message.id })
        let text = NSMutableAttributedString(attributedString:
            ChatMessageText.attributed("A **mixed** body.", addresses: [], fontSize: 13))
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 19.25; paragraph.maximumLineHeight = 19.25
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        var content = ChatTimelineShellContent(header: NSAttributedString(), body: text, style: style, selectable: true)
        content.bodyInput = .init(markdown: "A **mixed** body.", addresses: [], fontSize: 13, style: ChatMessageText.style)
        var plan = ChatTimelineRowLayoutPlan(id: row.id, width: ChatTimelineWidth(420, scale: 2), layoutRevision: row.layoutRevision)
        plan.height = 20; plan.body = CGRect(x: 0, y: 0, width: 420, height: 20)
        let cell = ChatNativeShellCell(kind: .message)
        let host = ChatQuietHost(view: cell, dark: false, width: 420, height: 20)
        defer { host.close() }
        cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: plan, content: content)
        try await host.settle()
        let manager = try XCTUnwrap(cell.body.layoutManager), container = try XCTUnwrap(cell.body.textContainer)
        XCTAssertEqual(manager.usedRect(for: container).height, 19.25, "Exercise a layout between backing pixels")
        XCTAssertEqual(cell.body.frame.height, 20, "Initial layout preserves the whole-point reservation")
        XCTAssertEqual(try XCTUnwrap(cell.plan).body.height, 20)
        let selection = NSRange(location: 2, length: 3)
        cell.body.setSelectedRange(selection)
        let normalized = NSAttributedString(attributedString: try XCTUnwrap(cell.body.textStorage))
        content.bodyInput = .init(markdown: "A **mixed** body.", addresses: ["unmatched-address"],
            fontSize: 13, style: ChatMessageText.style)
        cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: plan, content: content)
        try await host.settle()
        XCTAssertEqual(manager.usedRect(for: container).height, 19.25)
        XCTAssertEqual(cell.body.frame.height, 19.5, "A real late refresh rounds outward to backing pixels")
        XCTAssertEqual(cell.body.selectedRange(), selection)
        XCTAssertEqual(cell.body.textStorage, normalized)
        cell.needsLayout = true
        try await host.settle()
        XCTAssertEqual(cell.body.frame.height, 19.5, "A later cell layout keeps the settled size")
        XCTAssertEqual(cell.body.selectedRange(), selection)
        XCTAssertNil(APQuietFailure())
    }

    private func capture(_ content: AnyView) async throws -> ChatTimelineParity.Raster {
        try await capture(NSHostingView(rootView: content.environment(\.colorScheme, .light)))
    }
    private func capture(_ view: NSView) async throws -> ChatTimelineParity.Raster {
        let host = ChatQuietHost(view: view, dark: false, width: 64, height: 64)
        defer { host.close() }
        try await host.settle()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertNil(APQuietFailure())
        return try ChatTimelineParity.Raster(bitmap)
    }
}

@MainActor private final class NativeDrawingParityCanvas: NSView {
    var render: ((CGContext) -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if let context = NSGraphicsContext.current?.cgContext { render?(context) }
    }
}
