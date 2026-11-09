import AppKit
import AgentPadQuietTestSupport
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor final class ChatNativeMetadataTests: XCTestCase {
    private typealias S = NativeTimelineSnapshot
    private var fixtures: [ChatNativeActionFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures.reversed() { await fixture.close() }
        fixtures.removeAll()
    }
    private func fixture(count: Int = 1) async throws -> ChatNativeActionFixture {
        let value = try await ChatNativeActionFixture(count: count)
        fixtures.append(value)
        try await value.settle()
        return value
    }
    private func message(_ f: ChatNativeActionFixture, _ id: String) throws -> S.Message {
        let row = try XCTUnwrap(f.coordinator.snapshot?.rows.first { $0.messageID == id })
        guard case .message(let value) = row.payload else { throw ChatTimelineParityLayout.failure("Message missing") }
        return value
    }
    private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(ChatTimelineReferenceCapture.descendants(view, NSButton.self).first {
            !$0.isHiddenOrHasHiddenAncestor && ($0.title == title || $0.accessibilityLabel() == title)
        }, "Missing live native action: " + title)
    }
    private func rebind(_ cell: ChatNativeShellCell, to id: String, in f: ChatNativeActionFixture) throws {
        let snapshot = try XCTUnwrap(f.coordinator.snapshot)
        let index = try XCTUnwrap(f.coordinator.messageIndex(id))
        let row = snapshot.rows[index], plan = try XCTUnwrap(f.coordinator.layoutPlan(at: index))
        cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: plan,
            content: f.coordinator.layoutEngine.content(row, snapshot: snapshot, width: plan.width), actions: f.adapter.actions)
        cell.configureActions(row: row, snapshot: snapshot, actions: f.adapter.actions,
            layer: try XCTUnwrap(f.coordinator.tableView.documentLayer))
        cell.setMediaVisible(true)
        cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(cell.binding?.id, row.id)
    }

    func testMetadataRetryUsesReboundConversationAndUnbindClearsItsAction() async throws {
        let first = try await fixture(), second = try await fixture()
        for f in [first, second] {
            f.base.service.serverCapabilities[f.base.key.server] = ["chat.reactions", "chat.pins"]
            try f.base.write("INSERT OR REPLACE INTO b1_metadata (channel_id, message_id, error, dirty, ticket) VALUES (?, ?, 'Could not load. Please retry.', 0, 7)",
                [f.model.channel, f.messages[0].id])
            try f.base.write("INSERT OR REPLACE INTO b1_pins (channel_id, error, dirty, ticket) VALUES (?, 'Could not load. Please retry.', 0, 7)", [f.model.channel])
            try await f.settle()
        }
        func database(_ f: ChatNativeActionFixture) async throws -> [[String: String]] {
            try await f.base.store.queue.read { db in
                try ["b1_metadata", "b1_pins", "read_marks"].flatMap { table in
                    try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY channel_id").map { row in
                        var fields = Dictionary(uniqueKeysWithValues: row.columnNames.map { name in
                            let value: DatabaseValue = row[name]
                            return (name, value.description)
                        })
                        fields["table"] = table
                        return fields
                    }
                }
            }
        }
        let beforeFirst = try await database(first), beforeSecond = try await database(second)
        let cell = try first.row(first.messages[0].id)
        let retry = try button("Retry", in: cell.metadata)
        try rebind(cell, to: second.messages[0].id, in: second)
        XCTAssertTrue(try button("Retry", in: cell.metadata) === retry)
        retry.performClick(nil)
        let expected = beforeSecond.map { value in
            var value = value
            if ["b1_metadata", "b1_pins"].contains(value["table"] ?? "") {
                value["error"] = DatabaseValue.null.description
                value["dirty"] = true.databaseValue.description
                value["ticket"] = 8.databaseValue.description
            }
            return value
        }
        let afterFirst = try await database(first), afterSecond = try await database(second)
        XCTAssertEqual(afterFirst, beforeFirst)
        XCTAssertEqual(afterSecond, expected)
        cell.metadata.unbind()
        retry.performClick(nil)
        let afterUnbind = try await database(second)
        XCTAssertEqual(afterUnbind, expected)
        XCTAssertNil(APQuietFailure())
    }


    func testWholeMetadataStateAcrossEveryCapabilitySubsetAndReadIndependentUpdates() async throws {
        let f = try await fixture()
        try await f.connectSocket()
        let id = f.messages[0].id
        let value = ChatB1.Metadata(messageId: id, deleted: false,
            reactions: [.init(emoji: "👍", count: 2, mine: true), .init(emoji: "❤️", count: 4, mine: false)],
            pin: .init(pinnedBy: f.base.key.accountId, pinnedAt: ChatTimelineReferenceFixture.date),
            threadSummary: .init(rootId: id, replyCount: 1, lastReplyAt: ChatTimelineReferenceFixture.date,
                lastReplySeq: 2, lastParticipants: [.init(authorAccountId: CallJSON.boris)]))
        try f.base.write("INSERT OR REPLACE INTO b1_metadata (channel_id, message_id, data, dirty) VALUES (?, ?, ?, 0)",
            [f.model.channel, id, try ChatB1.encode(value)])
        try f.base.write("INSERT OR REPLACE INTO read_marks (channel_id, last_read_seq, muted) VALUES (?, 19, 1)", [f.model.channel])
        let before = try await f.base.store.queue.read {
            try Row.fetchAll($0, sql: "SELECT * FROM read_marks ORDER BY channel_id").map(\.description)
        }
        for subset in 0..<8 {
            let flags = ["chat.reactions", "chat.pins", "chat.thread_summary"]
            f.base.service.serverCapabilities[f.base.key.server] = Set(flags.enumerated().compactMap {
                subset & (1 << $0.offset) == 0 ? nil : $0.element
            })
            try await f.settle()
            XCTAssertEqual(try message(f, id).content.metadata, S.Metadata(value: value, intents: [],
                reactionsSupported: subset & 1 != 0, pinsSupported: subset & 2 != 0,
                summarySupported: subset & 4 != 0, accessible: true, canChange: true,
                loadError: nil, problem: nil))
            let after = try await f.base.store.queue.read {
                try Row.fetchAll($0, sql: "SELECT * FROM read_marks ORDER BY channel_id").map(\.description)
            }
            XCTAssertEqual(after, before)
        }
        f.base.service.orgSessions[f.base.key]?.snapshotOwed = true
        try await f.settle()
        XCTAssertEqual(try message(f, id).content.metadata, S.Metadata(value: nil, intents: [],
            reactionsSupported: true, pinsSupported: true, summarySupported: true,
            accessible: false, canChange: false, loadError: nil, problem: nil))
        XCTAssertNil(f.adapter.actions?.reactionContext(messageID: id))
    }

    func testWholeMetadataPreservesPendingFailedAndUnconfirmedIntentsAndReadErrors() async throws {
        let f = try await fixture()
        try await f.connectSocket()
        f.base.service.serverCapabilities[f.base.key.server] = ["chat.reactions", "chat.pins", "chat.thread_summary"]
        let id = f.messages[0].id
        let value = ChatB1.Metadata(messageId: id, deleted: false,
            reactions: [.init(emoji: "👍", count: 2, mine: true)],
            pin: .init(pinnedBy: CallJSON.boris, pinnedAt: ChatTimelineReferenceFixture.date))
        try f.base.write("INSERT OR REPLACE INTO b1_metadata (channel_id, message_id, data, dirty, error) VALUES (?, ?, ?, 0, ?)",
            [f.model.channel, id, try ChatB1.encode(value), "Message details could not be loaded."])
        for choice in ["pin", "👍", "🎉"] {
            try f.base.write("DELETE FROM b1_intents")
            try f.base.write("DELETE FROM outbox")
            let command = ChatCommandRecord(commandId: "w07-state-intent", sessionId: "s-anna", type: choice == "pin" ? "message.pin.set" : "message.reaction.set",
                bodyBytes: Data(), orderKey: "w07-state-intent", createdAt: Date(timeIntervalSince1970: 1), state: .pending)
            try await f.base.store.queue.write { try command.insert($0) }
            try f.base.write("INSERT INTO b1_intents (command_id, channel_id, message_id, choice, present) VALUES (?, ?, ?, ?, 0)",
                [command.commandId, f.model.channel, id, choice])
            for state in ["pending", "failed", "dropped", "unconfirmed"] {
                let error = state == "failed" ? "The change was rejected." : nil
                try f.base.write("UPDATE outbox SET state = ?, error = ?", [state, error])
                try await f.settle()
                XCTAssertEqual(try message(f, id).content.metadata, S.Metadata(value: value,
                    intents: [.init(choice: choice, present: false, error: state == "pending" ? nil : error ?? "Change not confirmed. Try again.")],
                    reactionsSupported: true, pinsSupported: true, summarySupported: true, accessible: true, canChange: true,
                    loadError: "Message details could not be loaded.", problem: nil), "\(choice), \(state)")
            }
        }
        f.model.b1?.toggle(id, emoji: "not an emoji")
        try await f.settle()
        XCTAssertEqual(try message(f, id).content.metadata, S.Metadata(value: value,
            intents: [.init(choice: "🎉", present: false, error: "Change not confirmed. Try again.")],
            reactionsSupported: true, pinsSupported: true, summarySupported: true, accessible: true, canChange: true,
            loadError: "Message details could not be loaded.", problem: "Choose one emoji."))
    }

    func testWholeSourceStatePreservesEveryStatusPublicationAndActivityWithoutLeakingBetweenMessages() async throws {
        let f = try await fixture(count: 2)
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        f.base.service.isServerKnown = { _, _ in true }
        let id = "w07-source-state", source = f.messages[0].id
        let states: [(String, String?, String?, String)] = [
            ("submitted", nil, nil, "queued"),
            ("awaiting_decision", nil, nil, "waiting for the owner's decision"),
            ("approved", nil, nil, "starting…"), ("starting", nil, nil, "starting…"),
            ("running", nil, nil, "working…"), ("stop_requested", nil, nil, "stop requested"),
            ("failed", nil, "Failed fixture", "failed: Failed fixture"),
            ("declined", nil, "Declined fixture", "declined: Declined fixture"),
            ("cancelled", nil, nil, "cancelled"), ("stopped", nil, nil, "stopped"), ("lost", nil, nil, "lost"),
            ("finished", nil, nil, "finished · not published"),
            ("finished", "published", nil, "answered"),
            ("finished", "awaiting_publish", nil, "finished · awaiting publication"),
            ("finished", "withheld", nil, "finished · answer withheld"),
            ("finished", "publish_failed", "agent_removed", "finished · not published: the agent left the channel")]
        for (offset, entry) in states.enumerated() {
            let (state, publication, error, word) = entry
            try f.base.move(state, offset + 1, id: id, publication: publication)
            try f.base.write("""
                UPDATE requests SET source_message_id = ?, owner_account_id = ?, initiator_account_id = ?,
                    publication = ?, publish_reason = ?, failure_reason = ?, decline_reason = ? WHERE request_id = ?
                """, [source, f.base.key.accountId, CallJSON.boris, publication,
                        publication == "publish_failed" ? error : nil, state == "failed" ? error : nil,
                        state == "declined" ? error : nil, id])
            let activity = ["starting", "running"].contains(state) ? "Reading fixture files" : nil
            f.base.service.channelActivity[id] = activity.map {
                ChatChannelActivity(key: f.base.key, request: id, text: $0, expires: Date().addingTimeInterval(600))
            }
            try await f.settle()
            XCTAssertEqual(try message(f, source).content.sources, [.init(
                value: ChatSourceStatus(id: id, source: source, agent: "billing", state: state,
                    initiator: CallJSON.boris, owner: f.base.key.accountId, publication: publication, error: error),
                word: word, activity: activity, connected: true, canGoToAnswer: false)], "\(state), \(publication ?? "none")")
            XCTAssertEqual(try message(f, f.messages[1].id).content.sources, [])
        }
        let retained = try message(f, source).content.sources
        f.base.service.orgSessions[f.base.key]?.snapshotOwed = true
        try await f.settle()
        XCTAssertEqual(try message(f, source).content.sources, retained)
        XCTAssertFalse(try XCTUnwrap(f.adapter.actions).performSource(.details, messageID: source, requestID: id))
    }

    func testReactionControlDispatchesCurrentRowAfterReuseAndRejectsPendingRevokedAndDeletedState() async throws {
        let f = try await fixture(count: 2)
        try await f.connectSocket()
        for id in f.messages.map(\.id) {
            let value = ChatB1.Metadata(messageId: id, deleted: false,
                reactions: [.init(emoji: "👍", count: 2, mine: false)], pin: nil)
            try f.base.write("INSERT OR REPLACE INTO b1_metadata (channel_id, message_id, data, dirty) VALUES (?, ?, ?, 0)",
                [f.model.channel, id, try ChatB1.encode(value)])
        }
        try await f.settle()
        let cell = try f.row(f.messages[0].id)
        try rebind(cell, to: f.messages[1].id, in: f)
        let action = try button("👍, 2", in: cell.metadata)
        action.performClick(nil)
        try await f.settle()
        let commands = try f.base.commands().filter { $0.type == "message.reaction.set" }
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(ChatService.args(try XCTUnwrap(commands.first)), ["channel_id": .string(f.model.channel),
            "message_id": .string(f.messages[1].id), "present": .bool(true), "emoji": .string("👍")])
        action.performClick(nil)
        XCTAssertEqual(try f.base.commands().filter { $0.type == "message.reaction.set" }.count, 1)
        f.base.service.orgSessions[f.base.key]?.snapshotOwed = true
        XCTAssertFalse(try XCTUnwrap(f.adapter.actions).perform(.toggleReaction("❤️"), messageID: f.messages[1].id))
        f.base.service.orgSessions[f.base.key]?.snapshotOwed = false
        try f.base.write("UPDATE messages SET deleted_at = ? WHERE message_id = ?", [ChatTimelineReferenceFixture.date, f.messages[1].id])
        try await f.settle()
        XCTAssertFalse(try XCTUnwrap(f.adapter.actions).perform(.toggleReaction("❤️"), messageID: f.messages[1].id))
        XCTAssertEqual(try f.base.commands().filter { $0.type == "message.reaction.set" }.count, 1)
    }

    func testSourceActionsUseCurrentRequestAfterCellReuseAndCurrentAuthority() async throws {
        let f = try await fixture(count: 2)
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        for (id, source) in zip([first, second], f.messages) {
            try f.base.move("running", 1, id: id)
            try f.base.write("UPDATE requests SET source_message_id = ?, owner_account_id = ? WHERE request_id = ?",
                [source.id, f.base.key.accountId, id])
        }
        try await f.settle()
        XCTAssertTrue(f.base.service.channelAgentAllowed(f.base.key, channel: f.model.channel))
        let cell = try f.row(f.messages[0].id)
        try rebind(cell, to: f.messages[1].id, in: f)
        var opened: [String] = []
        f.adapter.actions?.requestDetails = { id, key in XCTAssertEqual(key, f.base.key); opened.append(id) }
        try button("Request details", in: cell.sources).performClick(nil)
        try button("Stop agent", in: cell.sources).performClick(nil)
        XCTAssertEqual(opened, [second])
        let commands = try f.base.commands().filter { $0.type == "request.stop" }
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(ChatService.args(try XCTUnwrap(commands.first)), ["request_id": .string(second)])
        let actions = try XCTUnwrap(f.adapter.actions)
        XCTAssertFalse(actions.performSource(.stop, messageID: f.messages[1].id, requestID: first))
        try f.base.move("finished", 2, id: second, publication: "published")
        try await f.settle()
        XCTAssertFalse(actions.performSource(.stop, messageID: f.messages[1].id, requestID: second))
        f.base.service.orgSessions[f.base.key]?.snapshotOwed = true
        XCTAssertFalse(actions.performSource(.details, messageID: f.messages[0].id, requestID: first))
        XCTAssertEqual(opened, [second])
        XCTAssertEqual(try f.base.commands().filter { $0.type == "request.stop" }.count, 1)
    }

    func testReactorsActualMenuPaginationHoverExitAndReuseReleaseAttentionGate() async throws {
        let f = try await fixture(count: 2)
        try await f.connectSocket()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let sync = ChatSync(key: f.base.key, store: f.base.store,
            api: ChatAPI(server: f.base.key.server, protocolClasses: [ChatStubProtocol.self]),
            socket: try XCTUnwrap(f.base.service.socket), outbox: nil, token: "test-only")
        f.base.service.orgSessions[f.base.key]?.sync = sync
        sync.b1.configure(["chat.reactions"]); sync.b1.resume()
        defer { sync.stop() }
        let id = f.messages[0].id, account = f.base.key.accountId
        ChatStubProtocol.reset { request, _ in
            guard request.url?.path.hasSuffix("/reactions") == true else { return .failure(URLError(.unsupportedURL)) }
            let more = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "after" } == true
            let data = more
                ? "{\"as_of_seq\":10,\"account_ids\":[\"former-member\"],\"next\":null}"
                : "{\"as_of_seq\":10,\"account_ids\":[\"\(account)\"],\"next\":\"page-2\"}"
            return .success(.init(status: 200, body: Data(data.utf8)))
        }
        let value = ChatB1.Metadata(messageId: id, deleted: false, reactions: [.init(emoji: "👍", count: 2, mine: true)], pin: nil)
        try f.base.write("INSERT OR REPLACE INTO b1_metadata (channel_id, message_id, data, dirty) VALUES (?, ?, ?, 0)",
            [f.model.channel, id, try ChatB1.encode(value)])
        try await f.settle()
        let cell = try f.row(id), chip = try button("👍, 2, including you", in: cell.metadata)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
            location: chip.convert(CGPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: f.host.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(chip.menu(for: event))
        XCTAssertEqual(menu.items.map(\.title), ["Who reacted"])
        XCTAssertEqual(menu.items.map(\.isEnabled), [true])
        XCTAssertEqual(menu.items.map(\.state), [.off])
        XCTAssertEqual(menu.items.map(\.isSeparatorItem), [false])
        XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil })
        menu.performActionForItem(at: 0)
        try await f.host.settle()
        let popup = try XCTUnwrap(cell.metadata.parityPopovers["👍"])
        XCTAssertTrue(popup.popover.isShown)
        XCTAssertTrue(NavigationPresentationGate.obscures(f.host.window))
        chip.mouseExited(with: event)
        XCTAssertTrue(popup.popover.isShown, "Moving from chip to popup must retain the popup")
        let window = try XCTUnwrap(popup.popover.contentViewController?.view.window)
        XCTAssertFalse(APQuietWindowHasOSFocus(window))
        try await Task.sleep(for: .milliseconds(120))
        window.contentView?.layoutSubtreeIfNeeded()
        func labels() -> [String] {
            ChatTimelineReferenceCapture.accessibilityNodes(window).flatMap { node in
                ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap {
                    ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String
                }
            }
        }
        XCTAssertTrue(labels().contains("Anna"))
        XCTAssertTrue(ChatTimelineReferenceCapture.press("Show more", window: window))
        try await Task.sleep(for: .milliseconds(120))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(labels().contains("Former member"))
        XCTAssertEqual(f.adapter.actions?.reactorAccounts[id], [account, "former-member"])
        let requests = ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/reactions") == true }
        XCTAssertEqual(requests.count, 2)
        try rebind(cell, to: f.messages[1].id, in: f)
        try await f.host.settle()
        XCTAssertFalse(popup.popover.isShown)
        XCTAssertFalse(NavigationPresentationGate.obscures(f.host.window))
        XCTAssertNil(f.adapter.actions?.reactorAccounts[id])
        XCTAssertNil(APQuietFailure())
    }

    func testSourceCancelExpansionAndRequestTailFilteringRemainScopedToMessageAndThread() async throws {
        let f = try await fixture(count: 2)
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        let ids = (0..<4).map { _ in UUID().uuidString.lowercased() }
        for id in ids {
            try f.base.move("submitted", 1, id: id)
            try f.base.write("UPDATE requests SET source_message_id = ?, thread_root_id = ?, initiator_account_id = ? WHERE request_id = ?",
                [f.messages[0].id, f.messages[0].id, f.base.key.accountId, id])
        }
        try await f.settle()
        let actions = try XCTUnwrap(f.adapter.actions)
        let cell = try f.row(f.messages[0].id)
        try button("1 more requests", in: cell.sources).performClick(nil)
        try await f.settle()
        XCTAssertTrue(try message(f, f.messages[0].id).content.sourcesExpanded)
        XCTAssertFalse(try message(f, f.messages[1].id).content.sourcesExpanded)
        XCTAssertTrue(actions.performSource(.cancel, messageID: f.messages[0].id, requestID: ids[0]))
        let commands = try f.base.commands().filter { $0.type == "request.cancel" }
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(ChatService.args(try XCTUnwrap(commands.first)), ["request_id": .string(ids[0])])
        let tailID = UUID().uuidString.lowercased()
        try f.base.move("finished", 1, id: tailID, publication: "publish_failed")
        try f.base.write("UPDATE requests SET thread_root_id = ?, publish_reason = 'agent_removed' WHERE request_id = ?",
            [f.messages[0].id, tailID])
        f.model.openThread(f.messages[0].id)
        try await f.settle()
        let owner = ChatChannelOwnerModel(service: f.base.service, key: f.base.key, channel: f.model.channel)
        let adapter = ChatTimelineAdapter()
        let snapshot = adapter.snapshot(model: f.model, root: f.messages[0].id, members: [], mentionable: [],
            me: f.base.key.accountId, archived: false, ownerModel: owner,
            style: ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
                increasedContrast: false, alwaysShowTime: false))
        let cards = snapshot.rows.compactMap { row -> S.Request? in
            if case .legacyRequest(let card) = row.payload { return card }; return nil
        }
        let live = try XCTUnwrap(f.model.threadRequests.first { $0.id == tailID })
        XCTAssertEqual(cards, [.init(id: tailID, agentName: live.agentName,
            initiatorAccountID: live.initiatorAccountId, ownerAccountID: live.ownerAccountId,
            state: "finished", publication: "publish_failed", publishReason: "agent_removed", cause: live.cause,
            title: "a former member asked \(live.agentName) (a former member's agent)",
            stateWord: "done · not published: the agent left the channel", help: live.state.meaning ?? live.state.rawValue,
            canOpenRequest: true, canOpenSession: false)])
        var opened: [String] = []
        adapter.actions?.requestDetails = { id, _ in opened.append(id) }
        XCTAssertTrue(try XCTUnwrap(adapter.actions).openRequest(requestID: tailID))
        XCTAssertFalse(try XCTUnwrap(adapter.actions).openRequest(requestID: ids[0]))
        XCTAssertEqual(opened, [tailID])
        f.model.openThread(nil)
        XCTAssertFalse(try XCTUnwrap(adapter.actions).openRequest(requestID: tailID))
    }
}
