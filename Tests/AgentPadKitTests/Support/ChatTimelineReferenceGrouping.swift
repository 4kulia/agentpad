import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor enum ChatTimelineReferenceGrouping {
    static func run(_ capture: ChatTimelineReferenceCapture, fixture: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        try await grouping(capture, fixture: fixture, dark: dark)
        try await parserBoundary(capture, fixture: fixture, dark: dark)
        try await mentionsAndLocator(capture, fixture: fixture, dark: dark)
        try await wrapBoundary(capture, fixture: fixture, dark: dark)
        try await focusAndDeletedSummary(capture, fixture: fixture, dark: dark)
        try await sourceVariants(capture, fixture: fixture, dark: dark)
    }

    private static func grouping(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        for state in ["sequence-ties", "pending-tail", "same-author", "author-break", "agent-break", "session-break", "day-break", "invalid-date", "unread-break", "deleted-break", "loading-break"] {
            var first = try ChatTimelineReferenceFixture.message("reference-grouping-\(state)-first", me: f.key.accountId, text: "First message: \(state).", seq: 1)
            var second = first
            second.messageId = "reference-grouping-\(state)-second"; second.seq = 2
            second.text = "Second message: \(state)."; second.createdAt = "2026-10-07T12:01:00Z"
            var values = [first, second]
            var unread: String?
            switch state {
            case "sequence-ties": second.seq = 1; values = [second, first]
            case "pending-tail":
                var pending = first; pending.messageId = "reference-grouping-pending-tail-local"; pending.seq = nil
                pending.localState = .sending; pending.text = "Pending message remains after sequenced messages."
                values = [pending, second, first]
            case "author-break": second.authorAccountId = CallJSON.boris; values = [first, second]
            case "agent-break": second.authorAgentId = CallJSON.agent; second.authorAgentName = "Billing agent"; values = [first, second]
            case "session-break": second.authorSessionName = "A distinct agent session"; values = [first, second]
            case "day-break": second.createdAt = "2026-10-08T12:01:00Z"; values = [first, second]
            case "invalid-date": first.createdAt = "invalid-first"; second.createdAt = "invalid-second"; values = [first, second]
            case "unread-break": unread = second.id
            case "deleted-break": second.deletedAt = ChatTimelineReferenceFixture.date; values = [first, second]
            case "loading-break": second.hasMutable = false; values = [first, second]
            default: break
            }
            let rows = ChatFeedLayout.rows(values, unreadID: unread)
            if state == "sequence-ties" { XCTAssertEqual(rows.map(\.id), [second.id, first.id]) }
            if state == "pending-tail" { XCTAssertEqual(rows.map(\.id), [first.id, second.id, "reference-grouping-pending-tail-local"]) }
            if state == "same-author" { XCTAssertEqual(rows.map(\.startsGroup), [true, false]) }
            if !["same-author", "sequence-ties", "pending-tail"].contains(state) { XCTAssertEqual(rows.map(\.startsGroup), [true, true]) }
            if state == "invalid-date" { XCTAssertTrue(rows.allSatisfy { $0.date == nil }) }
            let model = ChatTimelineReferenceModel(f, messages: values); model.feed.unreadID = unread
            for width: CGFloat in [760, 420] {
                try await c.capture("grouping-" + state, inventory: ["T09", "T10", "R02", "R49"], model: model, messages: values, width: width, dark: dark,
                    detail: ["groupingBranch": state, "invalidDateHasNoDivider": state == "invalid-date", "orderedLayout": rows.map { row -> [String: Any] in
                        ["id": row.id, "startsGroup": row.startsGroup, "startsUnread": row.startsUnread, "date": row.date.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()]
                    }], content: c.timeline(model, root: nil, width: width))
            }
        }
    }

    private static func parserBoundary(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let prefix = "**Boundary marker**\n\n"
        for byteCount in [128 * 1024 - 1, 128 * 1024 + 1] {
            let paddingCount = byteCount - prefix.utf8.count
            let text = prefix + String(repeating: "a ", count: paddingCount / 2) + (paddingCount % 2 == 1 ? "a" : "")
            XCTAssertEqual(text.utf8.count, byteCount)
            let fallback = byteCount > 128 * 1024
            let branch = fallback ? "above128KiB" : "below128KiB"
            let message = try ChatTimelineReferenceFixture.message("reference-parser-" + branch, me: f.key.accountId, text: text)
            let model = ChatTimelineReferenceModel(f, messages: [message])
            for width: CGFloat in [760, 420] {
                try await c.capture("markdown-" + branch, inventory: ["R14"], model: model, messages: [message], width: width, dark: dark,
                    detail: ["utf8Bytes": byteCount, "parserBranch": fallback ? "plain fallback" : "markdown", "visiblePrefix": fallback ? "**Boundary marker**" : "Boundary marker", "captureScope": "Top of original production row; full fixture text preserved in metadata"],
                    content: c.row(model, message: message, width: width, thread: width == 420), prepare: { host, _ in
                        let body = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host, NSTextView.self).first { !$0.isEditable })
                        XCTAssertTrue(body.string.hasPrefix(fallback ? "**Boundary marker**" : "Boundary marker"))
                    })
            }
        }
    }

    private static func mentionsAndLocator(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        try ChatTimelineReferenceCapture.prepareOrganization(f.service)
        let agent = try XCTUnwrap(ChatOrgCurrent.shared.model?.agents(in: ChatTimelineReferenceFixture.channel).first { $0.agentId == CallJSON.agent })
        let address = try XCTUnwrap(agent.address)
        let locator = ChatMessageLink(key: f.key, channel: ChatTimelineReferenceFixture.channel, message: ChatTimelineReferenceFixture.root, sequence: 1)
        let url = try XCTUnwrap(locator.url)
        XCTAssertNotNil(ChatMessageLink(components: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))))
        XCTAssertEqual(MarkdownRenderer.chatLinkTarget(url), url)
        for branch in ["channel-agent-quote", "channel-agent-selected", "validated-agentpad-link"] {
            let text = branch == "validated-agentpad-link" ? "[Open the referenced message](\(url.absoluteString))" : "> @\(address) stays highlighted and selectable in quoted text."
            let message = try ChatTimelineReferenceFixture.message("reference-" + branch, me: f.key.accountId, text: text)
            let model = ChatTimelineReferenceModel(f, messages: [message])
            for width: CGFloat in [760, 420] {
                try await c.capture(branch, inventory: branch == "validated-agentpad-link" ? ["R16"] : ["R15"], model: model, messages: [message], width: width, dark: dark,
                    detail: ["mentionAddress": address, "checkedLocator": url.absoluteString, "linkOpened": false, "branch": branch],
                    content: c.row(model, message: message, width: width, thread: width == 420), prepare: { host, window in
                        let body = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host, NSTextView.self).first { !$0.isEditable })
                        if branch == "validated-agentpad-link" {
                            var targets: [URL] = []
                            body.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: (body.string as NSString).length)) { value, _, _ in
                                if let value = value as? URL { targets.append(value) }
                                else if let value = value as? String, let target = URL(string: value) { targets.append(target) }
                            }
                            XCTAssertEqual(targets, [url])
                        } else {
                            let range = (body.string as NSString).range(of: "@" + address)
                            XCTAssertNotEqual(range.location, NSNotFound)
                            XCTAssertNotNil(body.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil))
                            if branch == "channel-agent-selected" { window.makeFirstResponder(body); body.setSelectedRange(range); XCTAssertEqual(body.selectedRange(), range) }
                        }
                    })
            }
        }
    }

    private static func lineCount(_ text: NSAttributedString, width: CGFloat) -> Int {
        let storage = NSTextStorage(attributedString: text), layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; layout.addTextContainer(container); storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var count = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in count += 1 }
        return count
    }

    private static func wrapBoundary(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        for width: CGFloat in [760, 420] {
            let thread = width == 420, fontSize: CGFloat = thread ? 13 : 14
            let contentWidth = width - (thread ? 80 : 92)
            let breakCount = try XCTUnwrap((2...300).first { count in
                lineCount(ChatMentionText.attributed(String(repeating: "w", count: count), addresses: [], fontSize: fontSize), width: contentWidth) > 1
            })
            for after in [false, true] {
                let count = breakCount - (after ? 0 : 1)
                let text = String(repeating: "w", count: count)
                let branch = after ? "after" : "before"
                let message = try ChatTimelineReferenceFixture.message("reference-wrap-\(branch)-\(Int(width))", me: f.key.accountId, text: text)
                let model = ChatTimelineReferenceModel(f, messages: [message])
                try await c.capture("body-wrap-threshold-" + branch, inventory: ["R11"], model: model, messages: [message], width: width, dark: dark,
                    detail: ["proposedContentWidth": contentWidth, "characterCount": count, "branch": branch, "expectedBodyLines": after ? 2 : 1],
                    content: c.row(model, message: message, width: width, thread: thread), prepare: { host, _ in
                        let body = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host, NSTextView.self).first { !$0.isEditable })
                        let layout = try XCTUnwrap(body.layoutManager), container = try XCTUnwrap(body.textContainer)
                        layout.ensureLayout(for: container)
                        var lines = 0
                        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
                        XCTAssertEqual(lines, after ? 2 : 1)
                    })
            }
        }
    }

    private static func focusAndDeletedSummary(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let values = try (0..<3).map { index in
            try ChatTimelineReferenceFixture.message("reference-focus-row-\(index)", me: index == 1 ? CallJSON.boris : f.key.accountId, text: "Focused row \(index + 1).", seq: index + 1)
        }
        for index in 0..<3 {
            let model = ChatTimelineReferenceModel(f, messages: values); model.focusedMessageID = values[index].id
            let branch = index == 0 ? "first-selected" : index == 2 ? "last-selected" : "focused-message"
            for width: CGFloat in [760, 420] {
                try await c.capture("timeline-" + branch, inventory: ["T21", "T23", "R52"], model: model, messages: values, width: width, dark: dark,
                    detail: ["focusedMessageID": values[index].id, "selectedBoundary": branch, "selectionRoute": "Current focusedMessageID initial observer; no keyboard-event claim"], content: c.timeline(model, root: nil, width: width))
            }
        }
        var root = values[0]; root.deletedAt = ChatTimelineReferenceFixture.date
        var reply = values[1]; reply.threadRootId = root.id
        let model = ChatTimelineReferenceModel(f, messages: [root, reply])
        model.feed.replySummaries[root.id] = ChatReplySummary(messages: [reply], complete: true)
        model.feed.unreadReplyCounts[root.id] = 2; model.feed.requests[root.id] = 1
        for width: CGFloat in [760, 420] {
            try await c.capture("deleted-host-reply-summary", inventory: ["R17", "R31", "R32"], model: model, messages: [root, reply], width: width, dark: dark,
                detail: ["deletedHost": root.id, "replySummaryCount": 1, "unreadReplyCount": 2, "requestCount": 1, "requiredVisibleText": ["Message deleted", "1 reply"]], content: c.row(model, message: root, width: width, thread: false))
        }
    }

    private static func sourceVariants(_ c: ChatTimelineReferenceCapture, fixture f: ChatChannelExecutionTests.Fixture, dark: Bool) async throws {
        let source = "reference-grouping-source", channel = ChatTimelineReferenceFixture.channel
        let model = ChatChannelModel(key: f.key, channel: channel); model.service = f.service; model.follow(f.store)
        defer { try? f.write("DELETE FROM requests WHERE request_id LIKE ?", ["reference-grouping-source-%"]) }
        for branch in ["three", "unknown-error-two-lines"] {
            try f.write("DELETE FROM requests WHERE request_id LIKE ?", ["reference-grouping-source-%"])
            let count = branch == "three" ? 3 : 1
            for index in 0..<count {
                let id = "reference-grouping-source-\(branch)-\(index)-\(dark)"
                var body = CallJSON.request(id, state: branch == "three" ? "running" : "unexpected_provider_state", version: 1)
                body["kind"] = "channel"; body["channel_id"] = channel; body["source_message_id"] = source; body["thread_root_id"] = ChatTimelineReferenceFixture.root
                if branch != "three" { body["failure_reason"] = String(repeating: "A long upstream explanation remains in the existing two-line state label. ", count: 3) }
                let wire = CallJSON.wire(body)
                try await f.store.queue.write { try ChatCallStore.apply($0, wire, onThisDevice: false) }
            }
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(model.sourceStatuses.filter { $0.source == source }.count, count)
            for width: CGFloat in [760, 420] {
                try await c.capture("source-grouping-" + branch, inventory: branch == "three" ? ["R43"] : ["R44", "R45"], model: model, messages: [], width: width, dark: dark,
                    detail: ["sourceBranch": branch, "sourceID": source, "statusCount": count, "lineLimit": 2, "captureScope": "Production ChatSourceProgress with real offline channel model"],
                    content: AnyView(VStack(alignment: .leading) { ChatSourceProgress(model: model, source: source); Spacer() }.padding(18).frame(width: width, height: 600)))
            }
        }
    }
}
