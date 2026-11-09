import AppKit
import AgentPadQuietTestSupport
import GRDB
import Observation
import SwiftUI
import XCTest
@testable import AgentPadKit

/// W09 composition checks. The stores, models, request gates and native mount
/// seam are the same ones used by the existing offline chat suites.
@MainActor final class ChatNativeCompositionParityTests: XCTestCase {
    private typealias F = ChatNativeActionFixture
    private var fixtures: [F] = []
    private var hosts: [ChatQuietHost] = []
    private var syncs: [ChatSync] = []
    private var sockets: [ChatSocket] = []
    private var dmModels: [ChatDMModel] = []
    private var gates: [Gate] = []
    private var previousActive: (@MainActor () -> Bool)!
    private var previousEnhanced: Any?
    private let dm = "2c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f"
    private let team = "f5000000-0000-4000-8000-000000000004"

    override func setUp() async throws {
        guard APQuietIsEnabled() else { throw NSError(domain: "Quiet harness required", code: 1) }
        previousActive = ChatNotifications.appActive
        ChatNotifications.appActive = { false }
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        previousEnhanced = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
    }

    override func tearDown() async throws {
        gates.forEach { $0.open() }; gates = []
        for host in hosts {
            (host.view as? NSHostingView<AnyView>)?.rootView = AnyView(EmptyView())
            try await host.settle()
            host.close()
        }
        hosts = []
        dmModels.forEach { $0.stop() }; dmModels = []
        syncs.forEach { $0.stop() }; syncs = []
        sockets.forEach { $0.stop() }; sockets = []
        for fixture in fixtures.reversed() { await fixture.close() }
        fixtures = []
        ChatNotifications.appActive = previousActive
        NSApp.accessibilitySetValue(previousEnhanced, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        XCTAssertNil(APQuietFailure())
    }

    private func fixture(count: Int = 3) async throws -> F {
        let value = try await F(count: count)
        fixtures.append(value)
        return value
    }

    private func write(_ f: F, _ body: (Database) throws -> Void) throws { try f.base.store.queue.write(body) }
    private func read<T>(_ f: F, _ body: (Database) throws -> T) throws -> T { try f.base.store.queue.read(body) }

    private func settle(_ host: ChatQuietHost) async throws {
        for _ in 0..<3 { try await host.settle() }
    }

    private func wait(_ host: ChatQuietHost, _ stage: String, _ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Composition did not settle: " + stage)
                throw NSError(domain: "ChatNativeCompositionParity", code: 1)
            }
            try await host.settle()
        }
    }

    private func mount(_ content: AnyView, width: CGFloat = 1_100, height: CGFloat = 650) async throws -> ChatQuietHost {
        // Keep the replaceable root's concrete type. ChatQuietHost(content:)
        // applies its color-scheme modifier outside AnyView, so that host is
        // not an NSHostingView<AnyView> and cannot replace its root this way.
        let view = NSHostingView(rootView: AnyView(content.environment(\.colorScheme, .light)))
        let host = ChatQuietHost(view: view, dark: false, width: width, height: height)
        hosts.append(host)
        try await settle(host)
        return host
    }

    private func panes(_ host: ChatQuietHost) -> [NativeChatTimelineCoordinator] {
        ChatTimelineReferenceCapture.descendants(host.view, NativeChatTimelineContainer.self).map(\.coordinator)
    }

    private func pane(_ host: ChatQuietHost, root: String? = nil) throws -> NativeChatTimelineCoordinator {
        let matches = panes(host).filter { $0.snapshot?.conversation.root == root }
        XCTAssertEqual(matches.count, 1)
        return try XCTUnwrap(matches.first)
    }

    private func timeline(_ model: any ChatConversationPresentation, root: String? = nil) -> AnyView {
        AnyView(ChatTimelineView(model: model, root: root, members: [], mentionable: [],
            me: model.key.accountId, archived: model.feed.archived, ownerModel: nil)
            .environment(\.chatParityEnabled, true))
    }

    private func channelContent(_ f: F, _ session: ChatChannelSession) -> AnyView {
        AnyView(ChatChannelView(card: channelCard(f), team: "Team", offline: true,
            key: f.base.key, conversation: session, service: f.base.service)
            )
    }

    private func channelCard(_ f: F) -> ChatChannelCard {
        ChatChannelCard(channelId: f.model.channel, teamId: team, name: "Composition fixture",
            createdBy: f.base.key.accountId, archived: false, version: 1)
    }

    private func channelSession(_ f: F) -> ChatChannelSession {
        let session = ChatChannelSession()
        session.update(.ready(channelCard(f), team: "Team", offline: true),
            key: f.base.key, store: f.base.store, service: f.base.service)
        return session
    }

    private func wire(_ f: F, id: String, seq: Int, root: String? = nil,
                      revision: Int = 3, text: String = "Composition fixture") throws -> ChatMessageWire {
        var object: [String: Any] = ["message_id": id, "channel_id": f.model.channel,
            "author_account_id": f.base.key.accountId, "text": text, "revision": revision,
            "seq": seq, "created_at": ChatTimelineReferenceFixture.date]
        if let root { object["thread_root_id"] = root }
        return try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func install(_ routes: ChannelRoutes) {
        ChatStubProtocol.reset { request, _ in
            let path = request.url?.path ?? ""
            let full = path + (request.url?.query.map { "?" + $0 } ?? "")
            // Freeze the answer before the gate, as the shared late-page tests
            // do: replacing the route cannot turn an old response into a new one.
            let answer = routes.answer(full) ?? routes.answer(path)
            if routes.gated == full { routes.gate?.pass() }
            guard let answer else { return .failure(URLError(.unsupportedURL)) }
            return .success(.init(status: answer.0, body: answer.1))
        }
    }

    private func route<T: Encodable>(_ routes: ChannelRoutes, _ path: String, _ value: T) throws {
        routes.set(path, String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }

    private func channelSync(_ f: F, routes: ChannelRoutes) async throws -> ChatSync {
        let transport = FakeSocketTransport()
        let socket = ChatSocket(server: f.base.key.server, token: "test-only", makeTransport: { transport })
        sockets.append(socket) // The fixture never opens a socket or a real URL.
        let sync = ChatSync(key: f.base.key, store: f.base.store,
            api: ChatAPI(server: f.base.key.server, protocolClasses: [ChatStubProtocol.self]),
            socket: socket, outbox: nil, token: "test-only")
        sync.sessionId = "s-anna"
        syncs.append(sync)
        f.base.service.orgSessions[f.base.key]?.sync = sync
        let messages = try f.messages.map { try wire(f, id: $0.id, seq: $0.seq!, text: $0.text) }
        var card = channelCard(f)
        card.head = messages.count; card.messages = messages
        let state = ChatOrgState(org: .init(orgId: f.base.key.orgId, name: "Fixture"),
            members: [.init(accountId: f.base.key.accountId, handle: "anna", name: "Anna", role: "owner"),
                .init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
            teams: [.init(teamId: team, name: "Team", isGeneral: false, archivedAt: nil,
                members: [f.base.key.accountId, CallJSON.boris])], myTeams: [team], admin: nil,
            channels: [card], streams: [:])
        try route(routes, "/v1/orgs/\(f.base.key.orgId)/state", state)
        install(routes)
        await sync.snapshotNow()
        XCTAssertFalse(sync.needsSnapshot)
        return sync
    }

    private func setupDM(_ f: F, routes: ChannelRoutes) async throws -> (ChatDMModel, ChatDMSync) {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dm")
        routes.set("/v1/orgs/\(f.base.key.orgId)/dms",
            String(decoding: try Data(contentsOf: directory.appendingPathComponent("dms_response.json")), as: UTF8.self))
        install(routes)
        let transport = FakeSocketTransport()
        let socket = ChatSocket(server: f.base.key.server, token: "test-only", makeTransport: { transport })
        sockets.append(socket)
        let owner = ChatSync(key: f.base.key, store: f.base.store,
            api: ChatAPI(server: f.base.key.server, protocolClasses: [ChatStubProtocol.self]),
            socket: socket, outbox: nil, token: "test-only")
        syncs.append(owner)
        f.base.service.orgSessions[f.base.key]?.sync = owner
        owner.dm.sessionId = "s-anna"
        f.base.service.serverCapabilities[f.base.key.server, default: []].insert("chat.dm")
        owner.dm.configure(true)
        try await owner.dm.reloadCatalog(valid: { true })
        let model = ChatDMModel(key: f.base.key, dm: dm, service: f.base.service)
        dmModels.append(model)
        XCTAssertTrue(model.readable)
        return (model, owner.dm)
    }

    private func dmWire(_ id: String, seq: Int, root: String? = nil) throws -> ChatDMMessageWire {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dm/dm_message.json")
        var message = try JSONDecoder().decode(ChatDMMessageWire.self, from: Data(contentsOf: url))
        message.messageId = id; message.seq = seq; message.threadRootId = root
        message.text = "Private composition \(id)"
        return message
    }

    private func messageRow(_ snapshot: NativeTimelineSnapshot, _ id: String) throws -> NativeTimelineSnapshot.Row {
        try XCTUnwrap(snapshot.rows.first { $0.messageID == id })
    }

    func testSavedAnchorInitialAndExplicitRestoreIncludesPrecedingDecorations() async throws {
        let f = try await fixture(count: 3)
        f.dispose()
        for width: CGFloat in [760, 420] {
            for state in ["grouped", "header", "day", "unread", "day-unread", "thread-summary", "thread-day-unread-summary"] {
                var values = try (0..<35).map { index -> ChatMessage in
                    var value = try ChatTimelineReferenceFixture.message("w09-restore-\(index)", me: f.base.key.accountId,
                        text: "Restore message \(index).\nThe actual body and row positions are independently observed.", seq: index + 1)
                    value.authorAccountId = CallJSON.boris
                    return value
                }
                if state == "header" {
                    for index in [10, 20] { values[index].authorAccountId = f.base.key.accountId }
                }
                let root = state.hasPrefix("thread-") ? values[0].id : nil
                let initialIndex = root == nil ? 10 : 1
                let explicitIndex = root == nil ? 20 : 1
                if let root {
                    // A real thread contains its root followed by its replies.
                    // Tall root context gives the first reply room to restore
                    // without the scroll view's top-boundary clamp.
                    values[0].text = String(repeating: "Root context before the first reply.\n", count: 22)
                    for index in 1..<values.count { values[index].threadRootId = root }
                    XCTAssertEqual(values.first(where: { $0.threadRootId == root })?.id, values[initialIndex].id)
                }
                if state.contains("day") {
                    for index in initialIndex..<values.count {
                        values[index].createdAt = root != nil || index < explicitIndex
                            ? "2026-10-08T12:00:00Z" : "2026-10-09T12:00:00Z"
                    }
                }
                let models = [ChatTimelineReferenceModel(f.base, messages: values),
                              ChatTimelineReferenceModel(f.base, messages: values)]
                for model in models {
                    var saved = ChatScrollPosition()
                    _ = saved.update(values, me: f.base.key.accountId)
                    saved.atBottom = false; saved.anchor = values[initialIndex].id
                    model.threadRoot = root
                    model.positions[root ?? ""] = saved
                    if state.contains("unread") {
                        if root == nil { model.feed.unreadID = values[initialIndex].id }
                        else { model.threadUnreadID = values[initialIndex].id }
                    }
                }
                let candidate = try await mount(timeline(models[1], root: root), width: width, height: 400)
                let coordinator = try pane(candidate, root: root)
                defer {
                    for host in [candidate] {
                        (host.view as? NSHostingView<AnyView>)?.rootView = AnyView(EmptyView())
                        host.close()
                        hosts.removeAll { $0 === host }
                    }
                }
                func body(_ host: ChatQuietHost, _ value: ChatMessage) throws -> NSTextView {
                    let matches = ChatTimelineReferenceCapture.descendants(host.view, NSTextView.self).filter {
                        !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty && $0.string == value.text
                    }
                    XCTAssertEqual(matches.count, 1, "Exactly one visible message body is required")
                    return try XCTUnwrap(matches.first)
                }
                for (phase, targetIndex) in [("initial", initialIndex), ("explicit", explicitIndex)] {
                    let target = values[targetIndex]
                    if phase == "explicit" {
                        if root != nil {
                            // The summary belongs only to the first reply.
                            // Move both actual clips away before restoring it
                            // again so an ignored revision cannot pass.
                            for host in [candidate] {
                                let scroll = try XCTUnwrap(try body(host, target).enclosingScrollView)
                                let document = try XCTUnwrap(scroll.documentView)
                                let before = scroll.contentView.bounds.minY
                                let bottom = max(0, document.bounds.maxY - scroll.contentView.bounds.height)
                                scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: bottom))
                                scroll.reflectScrolledClipView(scroll.contentView)
                                try await settle(host)
                                XCTAssertGreaterThan(scroll.contentView.bounds.minY, before + 20)
                            }
                        }
                        for model in models {
                            var saved = try XCTUnwrap(model.positions[root ?? ""])
                            saved.atBottom = false; saved.anchor = target.id
                            model.positions[root ?? ""] = saved
                            if state.contains("unread") {
                                if root == nil { model.feed.unreadID = target.id }
                                else { model.threadUnreadID = target.id }
                            }
                            model.readingPositionRestored += 1
                        }
                    }
                    for host in [candidate] {
                        try await wait(host, "\(state) \(phase) saved anchor") {
                            ChatTimelineReferenceCapture.descendants(host.view, NSTextView.self).contains {
                                !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty && $0.string == target.text
                            }
                        }
                        try await settle(host)
                    }
                    let actualBody = try body(candidate, target)
                    let clip = coordinator.scrollView.contentView
                    let index = try XCTUnwrap(coordinator.messageIndex(target.id))
                    // Saved reading anchors include their preceding decorations;
                    // explicit body navigation is a separate contract.
                    var expectedKinds: [NativeTimelineSnapshot.RowID.Kind] = []
                    if state.contains("day") { expectedKinds.append(.dayBoundary(target.id)) }
                    if state.contains("unread") { expectedKinds.append(.unreadBoundary(target.id)) }
                    if let root { expectedKinds.append(.threadSummary(root)) }
                    let first = index - expectedKinds.count
                    XCTAssertGreaterThanOrEqual(first, 0)
                    XCTAssertEqual(coordinator.rows[first..<index].map { $0.id.kind }, expectedKinds)
                    let firstFrame = coordinator.tableView.rect(ofRow: first)
                    XCTAssertEqual(firstFrame.minY - clip.bounds.minY, 0, accuracy: 0.01,
                        "Saved anchor must restore its entire decorated row: \(state) \(phase)")
                    let cell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell)
                    let plan = try XCTUnwrap(cell.plan)
                    let actualRow = coordinator.tableView.rect(ofRow: index)
                    let bodyFrame = actualBody.convert(actualBody.bounds, to: coordinator.tableView)
                    XCTAssertEqual(bodyFrame.minY, actualRow.minY + plan.body.minY, accuracy: 0.01)
                    XCTAssertEqual(actualRow.height, plan.height, accuracy: 0.01)
                    if first < index {
                        for previous in first..<index {
                            XCTAssertEqual(coordinator.tableView.rect(ofRow: previous).maxY,
                                coordinator.tableView.rect(ofRow: previous + 1).minY, accuracy: 0.01)
                        }
                    }
                    XCTAssertFalse(coordinator.scrollController.following)
                    XCTAssertNil(models[0].focusedMessageID); XCTAssertNil(models[1].focusedMessageID)
                    XCTAssertFalse(APQuietWindowHasOSFocus(candidate.window))
                    XCTAssertNil(APQuietFailure())
                }
            }
        }
    }

    func testNativeToolbarRemainsAtTopAndTrailingViewportEdgesAfterScroll() async throws {
        let f = try await fixture(count: 1)
        f.dispose()
        for (width, inThread): (CGFloat, Bool) in [(760, false), (420, true), (320, false), (260, true)] {
            let root = inThread ? "toolbar-edge-0" : nil
            let messages = try (0..<80).map { index in
                var value = try ChatTimelineReferenceFixture.message("toolbar-edge-\(index)", me: f.base.key.accountId,
                    text: "Viewport edge message \(index).", seq: index + 1)
                value.threadRootId = index == 0 ? nil : root
                return value
            }
            let target = messages[20]
            let model = ChatTimelineReferenceModel(f.base, messages: messages)
            model.threadRoot = root; model.focusedMessageID = target.id
            let host = try await mount(timeline(model, root: root), width: width, height: 700)
            defer {
                (host.view as? NSHostingView<AnyView>)?.rootView = AnyView(EmptyView())
                host.close(); hosts.removeAll { $0 === host }
            }
            let coordinator = try pane(host, root: root)
            coordinator.scrollController.stopFollowing()
            coordinator.scrollController.scrollTo(messageID: target.id, alignment: .center)
            try await settle(host)
            func cell() throws -> ChatNativeShellCell {
                let index = try XCTUnwrap(coordinator.messageIndex(target.id))
                return try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell)
            }
            let body = try cell().body
            let before = ChatTimelineParityLayout.frame(body.bounds, from: body, in: host.view).minY
            let delta = Int32((before - 5).rounded())
            for (amount, phase): (Int32, Int64) in [(delta, 1), (0, 4)] {
                let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                    wheel1: -amount, wheel2: 0, wheel3: 0))
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(host.window.windowNumber))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(host.window.windowNumber))
                let point = host.window.convertPoint(toScreen: NSPoint(x: width / 2, y: 300))
                cg.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
                APQuietSelectWindow(host.window)
                APQuietSendEvent(try XCTUnwrap(NSEvent(cgEvent: cg)), host.window)
                try await settle(host)
            }
            let mounted = try cell()
            mounted.rowActions.hover(true)
            try await settle(host)
            func geometry() throws -> (CGRect, CGRect, CGRect, CGRect) {
                let bodyFrame = ChatTimelineParityLayout.frame(mounted.body.bounds, from: mounted.body, in: host.view)
                let buttons = mounted.rowActions.toolbar.buttons
                let reply = try XCTUnwrap(buttons.first { $0.title == "Reply in thread" })
                let more = try XCTUnwrap(buttons.first { $0.title == "More" || $0.accessibilityLabel() == "More message actions" })
                let replyFrame = ChatTimelineParityLayout.frame(reply.bounds, from: reply, in: host.view)
                let moreFrame = ChatTimelineParityLayout.frame(more.bounds, from: more, in: host.view)
                XCTAssertEqual(bodyFrame.minY, 5, accuracy: 0.75)
                XCTAssertFalse(reply.isHiddenOrHasHiddenAncestor)
                XCTAssertTrue(replyFrame.intersects(host.view.bounds), "Reply stays reachable at the top edge")
                XCTAssertFalse(more.isHiddenOrHasHiddenAncestor)
                XCTAssertLessThanOrEqual(moreFrame.maxX, width)
                XCTAssertGreaterThan(moreFrame.maxX, width - 40)
                XCTAssertGreaterThan(moreFrame.minX, 0)
                return (coordinator.scrollView.contentView.bounds, bodyFrame, replyFrame, moreFrame)
            }
            let resting = try geometry()
            try await Task.sleep(for: .seconds(2))
            try await settle(host)
            XCTAssertTrue(try geometry() == resting, "The resting viewport and toolbar must keep their geometry")
            XCTAssertFalse(APQuietWindowHasOSFocus(host.window))
            XCTAssertNil(APQuietFailure())
        }
    }

    func testCatalogAndCurrentOrganizationChangesReachMountedNativeRowsWithoutLosingReadingSelectionOrFocus() async throws {
        let f = try await fixture(count: 45)
        f.dispose()
        let target = f.messages[20].id
        let missing = UUID().uuidString.lowercased()
        let text = "Selectable text keeps its position. @anna @billing@anna @reviewer@anna @missing@anna @elsewhere@anna"
        try f.base.write("UPDATE messages SET author_agent_id = ?, author_agent_name = NULL, text = ? WHERE message_id = ?",
            [CallJSON.agent, text, target])
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        try f.base.write("INSERT OR REPLACE INTO agents_catalog (agent_id, owner_account_id, name, description, access, enabled, available) VALUES (?, ?, 'missing', '', 'read', 1, 1)",
            [missing, f.base.key.accountId])
        let oldTeam = TeamService.sharedForTesting, oldCurrent = ChatOrgCurrent.sharedForTesting
        let current = ChatOrgCurrent()
        TeamService.sharedForTesting = f.base.teamService
        ChatOrgCurrent.sharedForTesting = current
        defer {
            TeamService.sharedForTesting = oldTeam
            ChatOrgCurrent.sharedForTesting = oldCurrent
        }
        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
        let org = try XCTUnwrap(current.model)
        var initial = org.view
        initial.channelAgents = [.init(channelId: f.model.channel, agentId: CallJSON.agent,
            name: "billing", ownerAccountId: f.base.key.accountId, ownerHandle: "anna",
            description: "Billing", access: "read", enabled: true, available: true)]
        org.set(initial)
        let members = [ChatOrgView.Member(accountId: f.base.key.accountId, handle: "anna", name: "Anna", role: "owner")]
        let content = AnyView(ChatTimelineView(model: f.model, root: nil, members: members,
            mentionable: [(f.base.key.accountId, "anna")], me: f.base.key.accountId,
            archived: false, ownerModel: nil))
        let host = try await mount(content, width: 760, height: 400)
        let coordinator = try pane(host)
        func payload() throws -> NativeTimelineSnapshot.MessageContent {
            let snapshot = try XCTUnwrap(coordinator.snapshot)
            let row = try messageRow(snapshot, target)
            guard case .message(let value) = row.payload else {
                throw NSError(domain: "ChatNativeCompositionParity", code: 21)
            }
            return value.content
        }
        try await wait(host, "catalog baseline") {
            let value = try payload()
            return value.author == "billing" && value.membershipHints.map(\.agentID) == [missing]
        }
        coordinator.scrollController.scrollTo(messageID: target, alignment: .top)
        try await settle(host)
        let rowIndex = try XCTUnwrap(coordinator.messageIndex(target))
        let cell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: rowIndex,
            makeIfNecessary: false) as? ChatNativeShellCell)
        let body = cell.body
        let selection = NSRange(location: 0, length: 15)
        APQuietSelectWindow(host.window)
        XCTAssertTrue(host.window.makeFirstResponder(body))
        body.setSelectedRange(selection)
        let offset = body.convert(body.bounds, to: coordinator.scrollView.contentView).minY
            - coordinator.scrollView.contentView.bounds.minY
        XCTAssertEqual(offset, 0, accuracy: 0.01)
        let pixelOrigin = coordinator.scrollView.contentView.bounds.minY * host.window.backingScaleFactor
        XCTAssertEqual(pixelOrigin, pixelOrigin.rounded(), accuracy: 0.01)
        let messages = f.model.feed.messages
        let baseline = try payload()
        XCTAssertEqual(baseline.author, "billing")
        XCTAssertEqual(baseline.bodyAddresses, ["anna", "billing@anna"])
        XCTAssertEqual(baseline.addresses, ["anna", "billing@anna"])
        XCTAssertEqual(baseline.membershipHints, [.init(agentID: missing, address: "missing@anna", canAdd: true,
            guidance: "Add it to request an answer.")])
        func assertRetained(_ stage: String) throws {
            XCTAssertTrue(try pane(host) === coordinator, stage)
            let index = try XCTUnwrap(coordinator.messageIndex(target))
            let visible = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: index,
                makeIfNecessary: false) as? ChatNativeShellCell)
            XCTAssertTrue(visible.body === body, stage)
            XCTAssertTrue(host.window.firstResponder === body, stage)
            XCTAssertEqual(body.selectedRange(), selection, stage)
            XCTAssertEqual(body.convert(body.bounds, to: coordinator.scrollView.contentView).minY
                - coordinator.scrollView.contentView.bounds.minY, offset, accuracy: 0.01, stage)
            XCTAssertFalse(coordinator.scrollController.following, stage)
            XCTAssertEqual(f.model.feed.messages, messages, stage)
            XCTAssertEqual(try payload().message, baseline.message, stage)
            XCTAssertFalse(ChatTimelineReferenceCapture.descendants(coordinator.tableView, NSView.self)
                .contains { String(reflecting: type(of: $0)).contains("NSHosting") }, stage)
        }
        var changed = initial
        changed.channelAgents[0].name = "reviewer"
        changed.channelAgents.append(.init(channelId: f.model.channel, agentId: missing,
            name: "missing", ownerAccountId: f.base.key.accountId, ownerHandle: "anna",
            description: "Missing", access: "read", enabled: true, available: true))
        org.set(changed)
        try await wait(host, "catalog-only name address and membership") {
            let value = try payload()
            return value.author == "reviewer" && value.membershipHints.isEmpty
                && value.bodyAddresses == ["anna", "reviewer@anna", "missing@anna"]
        }
        XCTAssertEqual(try payload().addresses, ["anna", "missing@anna", "reviewer@anna"])
        XCTAssertEqual(try payload().authorTooltip, "@reviewer@anna · reviewer (Anna's agent) · @anna · " + f.base.key.accountId)
        try assertRetained("catalog-only")

        let other = ChatService(files: ChatFiles(directory: f.directory.appendingPathComponent("s21-other-org")), tokens: FakeTokenStore())
        defer { current.refresh(f.base.service) }
        other.followsFeed = false
        other.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        other.closeRemoteSession = { _, _ in }
        let otherKey = ChatOrgKey(server: f.base.key.server, accountId: f.base.key.accountId, orgId: UUID().uuidString.lowercased())
        try other.saveSignIn(.init(server: otherKey.server, accountId: otherKey.accountId,
            sessionId: "s21-other-session", deviceName: "Fixture Mac", orgId: otherKey.orgId), token: "test-only")
        let otherSession = other.session(for: otherKey), otherStore = try XCTUnwrap(otherSession.store)
        try otherStore.finishGeneration("g1")
        try otherStore.apply(ChatSnapshot(cursors: [:], members: [
            .init(accountId: otherKey.accountId, handle: "anna", name: "Anna", role: "owner")],
            teams: [.init(teamId: team, name: "Other", mine: true)],
            teamMembers: [.init(teamId: team, accountId: otherKey.accountId)],
            channels: [.init(channelId: f.model.channel, teamId: team, name: "other", archived: false, version: 1)],
            channelsComplete: true, agentChannels: []), confirmsRights: "s21-other-session")
        try otherStore.endChannelsRead(since: 0, seen: [f.model.channel])
        let otherChannel = f.model.channel
        try await otherStore.queue.write { db in
            try db.execute(sql: "UPDATE meta SET agents_served = 1 WHERE id = 1")
            try db.execute(sql: "INSERT OR REPLACE INTO agent_channels (channel_id, agent_id, name, owner_account_id, description, access, enabled, available) VALUES (?, ?, 'elsewhere', ?, 'Other organization', 'read', 1, 1)",
                arguments: [otherChannel, CallJSON.agent, otherKey.accountId])
        }
        otherSession.snapshotOwed = false
        try ChatTimelineReferenceCapture.prepareOrganization(other)
        let otherOrg = try XCTUnwrap(current.model)
        XCTAssertTrue(otherOrg.isCurrent())
        XCTAssertTrue(otherOrg.visible)
        XCTAssertFalse(otherOrg.inDoubt)
        XCTAssertFalse(otherOrg.snapshotOwed())
        XCTAssertTrue(otherOrg.channelsVisible)
        XCTAssertTrue(otherOrg.agentsVisible)
        XCTAssertEqual(otherOrg.agents(in: f.model.channel).map(\.address), ["elsewhere@anna"])
        try await wait(host, "current organization replacement") {
            let value = try payload()
            return value.author == "elsewhere" && value.membershipHints.isEmpty
                && value.bodyAddresses == ["anna", "elsewhere@anna"]
        }
        XCTAssertTrue(current.model === otherOrg)
        XCTAssertNotEqual(otherOrg.key, f.model.key)
        XCTAssertEqual(try payload().addresses, ["anna", "elsewhere@anna"])
        try assertRetained("current organization replacement")
        current.refresh(f.base.service)
        try XCTUnwrap(current.model).set(initial)
        try await wait(host, "original organization restored") { try payload() == baseline }
        try assertRetained("original organization restored")
        await other.disconnect()
    }

    func testMatchingInboxReadClearsOnlyItsMountedBoundaryAndUnrelatedEventsLeaveRowsEqual() async throws {
        let f = try await fixture()
        try write(f) { db in
            try db.execute(sql: "UPDATE messages SET author_account_id = ?", arguments: [CallJSON.boris])
            try db.execute(sql: "INSERT OR REPLACE INTO read_marks (channel_id, last_read_seq) VALUES (?, 0)", arguments: [f.model.channel])
        }
        f.model.follow(f.base.store)
        try await f.settle()
        let before = try XCTUnwrap(f.coordinator.snapshot), messages = f.model.feed.messages
        XCTAssertEqual(before.state.unreadID, f.messages[0].id)
        XCTAssertEqual(before.rows.filter { if case .unread = $0.payload { true } else { false } }.count, 1)
        for (object, channels) in [(f.base.store as AnyObject, Set(["unrelated-channel"])),
                                   (NSObject(), Set([f.model.channel]))] {
            NotificationCenter.default.post(name: .chatInboxMarkedRead, object: object, userInfo: ["channels": channels])
            try await f.settle()
            XCTAssertEqual(f.coordinator.snapshot?.rows, before.rows)
            XCTAssertEqual(f.model.feed.messages, messages)
        }
        NotificationCenter.default.post(name: .chatInboxMarkedRead, object: f.base.store,
            userInfo: ["channels": Set([f.model.channel])])
        try await f.settle()
        let after = try XCTUnwrap(f.coordinator.snapshot)
        XCTAssertNil(after.state.unreadID)
        XCTAssertEqual(after.rows, before.rows.filter { if case .unread = $0.payload { false } else { true } })
        XCTAssertEqual(f.model.feed.messages, messages)
    }

    func testOutboxOnlyPublicationFailureUpdatesMountedDetailWithEqualMessagesAndStatuses() async throws {
        let f = try await fixture(count: 2)
        let run = try await f.base.finish(), source = f.messages[0].id
        try f.base.write("UPDATE requests SET source_message_id = ? WHERE request_id = ?", [source, run.requestId])
        let command = try f.base.service.publishChannelResult(f.base.key, requestId: run.requestId, publish: true)
        try await f.settle()
        let before = try XCTUnwrap(f.coordinator.snapshot), old = try messageRow(before, source)
        let messages = f.model.feed.messages, statuses = f.model.sourceStatuses
        guard case .message(let oldPayload) = old.payload else { return XCTFail("Missing source row") }
        XCTAssertEqual(oldPayload.content.sources.map(\.word), ["finished · Your publication decision is on its way."])
        let observed = expectation(description: "outbox detail reaches the native adapter")
        withObservationTracking { f.update() } onChange: { observed.fulfill() }
        try f.base.write("UPDATE outbox SET state = 'failed', error = 'channel_archived' WHERE command_id = ?", [command.commandId])
        await fulfillment(of: [observed], timeout: 2)
        try await f.settle()
        let after = try XCTUnwrap(f.coordinator.snapshot), changed = try messageRow(after, source)
        guard case .message(let payload) = changed.payload else { return XCTFail("Missing updated source row") }
        XCTAssertEqual(payload.content.sources.map(\.word),
            ["finished · Not published: the channel was archived. Try again or choose Don't Publish."])
        XCTAssertEqual(payload.content.message, oldPayload.content.message)
        XCTAssertEqual(payload.content.sources.map(\.value), oldPayload.content.sources.map(\.value))
        XCTAssertEqual(changed.visual, old.visual)
        XCTAssertGreaterThan(changed.contentRevision, old.contentRevision)
        XCTAssertGreaterThan(changed.layoutRevision, old.layoutRevision)
        XCTAssertEqual(after.rows.filter { $0.messageID != source }, before.rows.filter { $0.messageID != source })
        XCTAssertEqual(f.model.feed.messages, messages); XCTAssertEqual(f.model.sourceStatuses, statuses)
        XCTAssertTrue(f.host.strings.contains { $0.contains("Not published:") })
    }

    private func pressEarlier(_ host: ChatQuietHost) async throws {
        func rowCount() -> Int { panes(host).first?.snapshot?.messageIDs.count ?? 0 }
        let coordinator = try pane(host)
        coordinator.scrollController.stopFollowing()
        let index = try XCTUnwrap(coordinator.rows.firstIndex {
            if case .olderControl = $0.payload { true } else { false }
        })
        coordinator.tableView.scrollRowToVisible(index)
        let scroll = coordinator.scrollView
        scroll.contentView.scroll(to: CGPoint(x: 0, y: coordinator.tableView.rect(ofRow: index).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        print("W09_EARLIER before renderer=native rows=\(rowCount())")
        try host.press("Load earlier messages", diagnosticContext: "earlier/native")
        try await settle(host)
        print("W09_EARLIER after renderer=native rows=\(rowCount())")
    }

    func testChannelRollingWindowAndCachedEarlierExpansionKeepNativeIDsAndActiveDraft() async throws {
        let f = try await fixture(count: 65)
        f.dispose()
        let pending = "w09-channel-pending"
        try write(f) { db in
            try db.execute(sql: "INSERT OR REPLACE INTO channel_windows (channel_id, epoch, bottom_seq, history_next) VALUES (?, 1, 1, NULL)", arguments: [f.model.channel])
            try ChatMessages.insertSending(db, id: pending, channel: f.model.channel, root: nil,
                author: f.base.key.accountId, text: "Pending local post", mentions: [], at: ChatService.now())
        }
        let models = (0..<2).map { _ in ChatChannelModel(key: f.base.key, channel: f.model.channel) }
        for model in models { model.service = f.base.service; model.follow(f.base.store) }
        XCTAssertTrue(models[0].beginEditing(f.messages[0], root: nil))
        models[0].editing?.text = "Retained outside the rolling window"
        models[1].follow(f.base.store)
        let saved = try XCTUnwrap(models[0].editing)
        let candidate = try await mount(timeline(models[1]), width: 760, height: 9_000)
        func assertIDs(_ ids: [String]) throws {
            XCTAssertEqual(try pane(candidate).snapshot?.messageIDs, ids)
            XCTAssertEqual(models.map { $0.editing }, [saved, saved])
        }
        try assertIDs([f.messages[0].id] + f.messages.dropFirst(15).map(\.id) + [pending])
        try await pressEarlier(candidate)
        try await settle(candidate)
        try assertIDs(f.messages.map(\.id) + [pending])
        try f.base.write("UPDATE channel_windows SET bottom_seq = 25, epoch = epoch + 1")
        try await settle(candidate)
        try assertIDs([f.messages[0].id] + f.messages.dropFirst(24).map(\.id) + [pending])
        XCTAssertFalse(ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/messages") == true })
    }

    func testDMOrphanPendingAndCachedEarlierExpansionKeepNativeIDsAndActiveDraft() async throws {
        let f = try await fixture(count: 1); f.dispose()
        let routes = ChannelRoutes(), (first, _) = try await setupDM(f, routes: routes)
        let roots = try (1...65).map { try dmWire("w09-dm-root-\($0)", seq: $0) }
        var orphan = try dmWire("w09-orphan", seq: 0, root: "missing-root")
        orphan.authorAccountId = f.base.key.accountId; orphan.revision = 0
        try write(f) { db in
            try db.execute(sql: "DELETE FROM dm_messages")
            for root in roots { try ChatDMStore.write(db, root) }
            try db.execute(sql: "UPDATE dm_cards SET history_next = NULL WHERE dm_id = ?", arguments: [dm])
            try db.execute(sql: """
                INSERT INTO dm_messages (dm_id, message_id, body, seq, root, revision, deleted, local_state)
                VALUES (?, ?, ?, 0, ?, 0, 0, 'sending')
                """, arguments: [dm, orphan.messageId, try JSONEncoder().encode(orphan), orphan.threadRootId])
        }
        try await Task.sleep(for: .milliseconds(80))
        let second = ChatDMModel(key: f.base.key, dm: dm, service: f.base.service); dmModels.append(second)
        let target = try XCTUnwrap(first.message(roots[0].messageId))
        XCTAssertTrue(first.beginEditing(target, root: nil))
        first.editing?.text = "Private saved edit"
        try await Task.sleep(for: .milliseconds(80))
        let saved = try XCTUnwrap(first.editing)
        let candidate = try await mount(timeline(second), width: 760, height: 9_000)
        func assertIDs(_ ids: [String]) throws {
            XCTAssertEqual(try pane(candidate).snapshot?.messageIDs, ids)
            XCTAssertEqual(first.editing, saved); XCTAssertEqual(second.editing, saved)
        }
        try assertIDs([roots[0].messageId] + roots.dropFirst(16).map(\.messageId) + ["w09-orphan"])
        try await pressEarlier(candidate)
        try await settle(candidate)
        try assertIDs(roots.map(\.messageId) + ["w09-orphan"])
        XCTAssertFalse(ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/messages") == true })
    }

    func testNativeMaterializationAddsNoSingleMessageOrHistoryRequests() async throws {
        let f = try await fixture(count: 45), routes = ChannelRoutes()
        _ = try await channelSync(f, routes: routes)
        let path = "/v1/orgs/\(f.base.key.orgId)/channels/\(f.model.channel)/messages"
        let id = f.messages[0].id
        try route(routes, path + "?before=2", ChatMessagesPage(messages: [try wire(f, id: id, seq: 1, revision: 4)], next: nil, head: 45))
        try f.base.write("UPDATE messages SET has_mutable = 0, stale = 4 WHERE message_id = ?", [id])
        try await wait(f.host, "model-owned readOne") { f.model.message(id)?.revision == 4 }
        try await f.settle()
        let reads = { ChatStubProtocol.seen.filter { $0.request.url?.path == path }.map { $0.request.url?.query ?? "" } }
        XCTAssertEqual(reads(), ["before=2"])
        for width in [420.0, 760.0] {
            f.host.window.setContentSize(NSSize(width: width, height: 400))
            for index in f.coordinator.rows.indices {
                _ = f.coordinator.tableView.view(atColumn: 0, row: index, makeIfNecessary: true)
            }
            f.coordinator.scrollController.scrollTo(messageID: id, alignment: .top)
            f.view.isHidden = true; try await f.settle()
            f.view.isHidden = false; try await f.settle()
        }
        XCTAssertEqual(reads(), ["before=2"], "Materialization and reflow do not own hydration or pagination")
        try route(routes, path + "?before=1", ChatMessagesPage(messages: [], next: nil, head: 45))
        try f.base.write("UPDATE channel_windows SET history_next = 1 WHERE channel_id = ?", [f.model.channel])
        try await f.settle()
        let older = try XCTUnwrap(f.coordinator.rows.firstIndex { if case .olderControl = $0.payload { true } else { false } })
        let control = try XCTUnwrap(f.coordinator.tableView.view(atColumn: 0, row: older, makeIfNecessary: true) as? ChatNativeShellCell)
        control.actionButton.performClick(nil)
        try await wait(f.host, "explicit native older action") { reads().count == 2 }
        try await f.settle()
        XCTAssertEqual(reads(), ["before=2", "before=1"])
        XCTAssertFalse(f.coordinator.scrollController.following)
    }

    func testEntireComposeRecordsSurviveNativePinsAndThreadReplacement() async throws {
        let f = try await fixture(); f.dispose()
        f.base.service.isServerKnown = { _, _ in true }
        f.base.service.serverCapabilities[f.base.key.server] = ["chat.pins", "chat.attachments", "chat.attachments_context", "chat.channel_ux1"]
        let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        f.base.service.serverAttachmentLimits[f.base.key.server] = limits
        let bytes = Data("Context file selection".utf8)
        let file = try ChatAttachmentStorage.descriptor(data: bytes, name: "context.txt", limits: limits)
        let source = f.messages[0].id, root = f.messages[1].id, other = f.messages[2].id
        try f.base.write("UPDATE messages SET attachments = ? WHERE message_id = ?", [String(decoding: try JSONEncoder().encode([file]), as: UTF8.self), source])
        let session = channelSession(f), model = try XCTUnwrap(session.model)
        let selected = ChatAttachmentManifest(file: file, messageId: source, revision: 3, sha256: ChatAttachments.digest(bytes))
        model.saveDraft("Feed draft @billing@anna", root: nil, mentionOnly: true, contextIds: [source], attachmentSelection: [selected])
        model.saveDraft("Thread draft", root: root, mentionOnly: false, contextIds: [source, root], attachmentSelection: [selected])
        model.saveDraft("Other thread draft", root: other, mentionOnly: true, contextIds: [source, other], attachmentSelection: [selected])
        let slots: [String?] = [nil, root, other]
        let expected = slots.map { model.composerDraft(root: $0) }
        XCTAssertTrue(expected.allSatisfy { $0.version != nil && !$0.attachmentSelection.isEmpty })
        let stored = try read(f) { try Row.fetchAll($0, sql: "SELECT * FROM drafts ORDER BY channel_id, thread_root_id") }
        let host = try await mount(channelContent(f, session), width: 700)
        for next in [root, other, nil] as [String?] {
            model.openThread(next)
            try await settle(host)
            XCTAssertEqual(try pane(host, root: next).snapshot?.conversation.root, next)
            session.togglePins(); try await settle(host)
            XCTAssertTrue(session.pinsShown); XCTAssertEqual(panes(host).count, 0)
            session.togglePins(); try await settle(host)
            XCTAssertEqual(try pane(host, root: next).snapshot?.conversation.root, next)
            XCTAssertEqual(slots.map { model.composerDraft(root: $0) }, expected)
            XCTAssertEqual(try read(f) { try Row.fetchAll($0, sql: "SELECT * FROM drafts ORDER BY channel_id, thread_root_id") }, stored,
                "Mounting panes must preserve the complete persisted record, including version and selection")
        }
    }

    func testDelayedChannelInitialPagesCannotRepopulateAReplacedRootAccessOrWindow() async throws {
        for transition in ["root", "access", "window"] { try await staleChannelPage(transition, earlier: false) }
    }

    func testDelayedChannelEarlierPagesCannotRepopulateAReplacedRootAccessOrWindow() async throws {
        for transition in ["root", "access", "window"] { try await staleChannelPage(transition, earlier: true) }
    }

    private func staleChannelPage(_ transition: String, earlier: Bool) async throws {
        let f = try await fixture(count: 2); f.dispose()
        let routes = ChannelRoutes(), sync = try await channelSync(f, routes: routes)
        defer { sync.stop() }
        let root = f.messages[0].id, other = f.messages[1].id
        let base = "/v1/orgs/\(f.base.key.orgId)/channels/\(f.model.channel)/threads/"
        let oldPath = base + root + (earlier ? "?before=10" : "")
        let stale = try wire(f, id: "stale-\(transition)-\(earlier)", seq: 3, root: root)
        let fresh = try wire(f, id: "fresh-\(transition)-\(earlier)", seq: 101, root: transition == "root" ? other : root)
        let initial = try wire(f, id: "initial-\(transition)", seq: 10, root: root)
        try route(routes, base + root, ChatMessagesPage(messages: [try wire(f, id: root, seq: 1), initial], next: 10, head: 101))
        let session = channelSession(f), model = try XCTUnwrap(session.model)
        let host = try await mount(channelContent(f, session))
        if earlier {
            model.openThread(root)
            try await wait(host, "initial channel page") { model.thread.contains { $0.id == initial.messageId } }
        }
        let gate = Gate(); gates.append(gate); gate.close()
        defer { gate.open() }
        routes.gate = gate; routes.gated = oldPath
        try route(routes, oldPath, ChatMessagesPage(messages: [try wire(f, id: root, seq: 1), stale], next: nil, head: 101))
        let before = ChatStubProtocol.seen.count
        if earlier { model.earlierReplies() } else { model.openThread(root) }
        try await wait(host, "held channel page") {
            ChatStubProtocol.seen.dropFirst(before).contains { seen in
                seen.request.url.map { $0.path + ($0.query.map { "?" + $0 } ?? "") } == oldPath
            }
        }
        routes.gated = nil
        let currentRoot = transition == "root" ? other : root
        try route(routes, base + currentRoot,
            ChatMessagesPage(messages: [try wire(f, id: currentRoot, seq: transition == "root" ? 2 : 1), fresh], next: nil, head: 101))
        switch transition {
        case "root": model.openThread(other)
        case "access":
            session.update(.checking, key: f.base.key, store: f.base.store, service: f.base.service)
            (host.view as? NSHostingView<AnyView>)?.rootView = AnyView(EmptyView())
            try await settle(host)
            XCTAssertEqual(panes(host).count, 0)
        default:
            let replacement = try wire(f, id: other, seq: 100)
            try write(f) { try ChatMessages.applyWindow($0, channel: f.model.channel, head: 100, messages: [replacement], before: 100) }
        }
        gate.open()
        try await settle(host)
        XCTAssertNil(try read(f) { try String.fetchOne($0, sql: "SELECT message_id FROM messages WHERE message_id = ?", arguments: [stale.messageId]) })
        if transition == "access" {
            session.update(.ready(channelCard(f), team: "Team", offline: true), key: f.base.key, store: f.base.store, service: f.base.service)
            (host.view as? NSHostingView<AnyView>)?.rootView = channelContent(f, session)
        }
        // Resuming a cached thread retains its accepted first page. Checking
        // cancels the held older request; it does not require a refetch.
        let expectedID = transition == "access" && earlier ? initial.messageId : fresh.messageId
        try await wait(host, "current channel page mounted") {
            self.panes(host).contains { $0.snapshot?.conversation.root == currentRoot && $0.snapshot?.messageIDs.contains(expectedID) == true }
        }
        let ids = try XCTUnwrap(pane(host, root: currentRoot).snapshot).messageIDs
        XCTAssertEqual(ids, model.conversationMessages(root: currentRoot).map(\.id))
        XCTAssertFalse(ids.contains(stale.messageId))
        XCTAssertEqual(model.threadRoot, currentRoot)
        (host.view as? NSHostingView<AnyView>)?.rootView = AnyView(EmptyView())
        try await settle(host)
    }

    func testDelayedDMThreadPagesCannotRepopulateAReplacedRootAccessOrWindow() async throws {
        for transition in ["root", "access", "window"] {
            let f = try await fixture(count: 1); f.dispose()
            let routes = ChannelRoutes(), (model, sync) = try await setupDM(f, routes: routes)
            let root = try dmWire("w09-private-root", seq: 3), other = try dmWire("w09-private-other", seq: 4)
            try write(f) { try ChatDMStore.write($0, root); try ChatDMStore.write($0, other) }
            let host = try await mount(AnyView(ChatDMView(model: model, card: try XCTUnwrap(model.card))
                ))
            let base = "/v1/orgs/\(f.base.key.orgId)/dms/\(dm)/threads/"
            let stale = try dmWire("w09-private-stale-" + transition, seq: 5, root: root.messageId)
            let currentRoot = transition == "root" ? other.messageId : root.messageId
            let fresh = try dmWire("w09-private-fresh-" + transition, seq: 101, root: currentRoot)
            let gate = Gate(); gates.append(gate); gate.close()
            defer { gate.open() }
            routes.gate = gate; routes.gated = base + root.messageId
            try route(routes, base + root.messageId, ChatDMMessagesPage(messages: [root, stale], next: nil, head: 101))
            model.openThread(root.messageId)
            try await wait(host, "held DM thread") { ChatStubProtocol.seen.contains { $0.request.url?.path == base + root.messageId } }
            routes.gated = nil
            try route(routes, base + currentRoot, ChatDMMessagesPage(messages: [transition == "root" ? other : root, fresh], next: nil, head: 101))
            switch transition {
            case "root": model.openThread(other.messageId)
            case "access":
                sync.invalidate()
                try write(f) { try ChatDMStore.remove($0, dm) }
            default:
                var card = try XCTUnwrap(model.card)
                card.head = 100; card.messages = [other]; card.messagesBefore = 100
                try write(f) { try ChatDMStore.writeCard($0, card) }
            }
            gate.open()
            try await settle(host)
            XCTAssertFalse(try read(f) { try ChatDMStore.messages($0, dm).contains { $0.id == stale.messageId } })
            if transition == "access" {
                XCTAssertFalse(model.readable)
                XCTAssertTrue(panes(host).allSatisfy { $0.snapshot?.messageIDs == [] })
            } else {
                try await wait(host, "current DM thread mounted") {
                    self.panes(host).contains { $0.snapshot?.conversation.root == currentRoot && $0.snapshot?.messageIDs.contains(fresh.messageId) == true }
                }
                XCTAssertEqual(try pane(host, root: currentRoot).snapshot?.messageIDs,
                    model.conversationMessages(root: currentRoot).map(\.id))
                XCTAssertFalse(try XCTUnwrap(pane(host, root: currentRoot).snapshot).messageIDs.contains(stale.messageId))
            }
            model.stop(); sync.stop()
            (host.view as? NSHostingView<AnyView>)?.rootView = AnyView(EmptyView())
            try await settle(host)
        }
    }

    func testNativeBegunReadingPaneDemandKeepsPinsOwnershipIndependent() async throws {
        let f = try await fixture(count: 60); f.dispose()
        let routes = ChannelRoutes(), sync = try await channelSync(f, routes: routes)
        let root = f.messages.last!.id, reply = try wire(f, id: "w09-b1-reply", seq: 61, root: root)
        try write(f) { db in
            _ = try ChatMessages.write(db, reply)
            try db.execute(sql: "INSERT OR REPLACE INTO thread_cursors (channel_id, root_id, epoch, next, shown_from) VALUES (?, ?, ?, NULL, 61)",
                arguments: [f.model.channel, root, try ChatMessages.epoch(db, f.model.channel)])
            try ChatMessages.insertSending(db, id: "w09-b1-pending", channel: f.model.channel, root: nil,
                author: f.base.key.accountId, text: "Local pending", mentions: [], at: ChatService.now())
        }
        f.base.service.serverCapabilities[f.base.key.server] = ["chat.reactions", "chat.pins"]
        sync.b1.configure(["chat.reactions", "chat.pins"])
        f.model.follow(f.base.store)
        f.model.openThread(root)
        let feed = try await mount(timeline(f.model), width: 760, height: 350)
        let thread = try await mount(timeline(f.model, root: root), width: 420, height: 350)
        let b1 = try XCTUnwrap(f.model.b1)
        let allFeed = Set(f.messages.suffix(50).map(\.id)), threadIDs = Set([root, reply.messageId])
        XCTAssertLessThan(try pane(feed).scrollController.visibleIDs.count, allFeed.count)
        func demand(_ expected: Set<String>, pins: Bool) async throws {
            sync.b1.suspend()
            try await settle(feed)
            try write(f) { db in
                try db.execute(sql: "UPDATE b1_metadata SET dirty = 1, ticket = ticket + 1")
                try db.execute(sql: "UPDATE b1_pins SET dirty = 1, ticket = ticket + 1")
            }
            ChatStubProtocol.reset { request, _ in
                let url = request.url!
                if url.path.hasSuffix("/message-metadata") {
                    let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ids" }?.value?.split(separator: ",").map(String.init) ?? []
                    let data = try! JSONSerialization.data(withJSONObject: ["as_of_seq": 10_000,
                        "items": ids.map { ["message_id": $0, "deleted": false, "reactions": [], "pin": NSNull()] as [String: Any] }])
                    return .success(.init(status: 200, body: data))
                }
                if url.path.hasSuffix("/pins") { return .success(.init(status: 200, body: Data(#"{"as_of_seq":10000,"pins":[]}"#.utf8))) }
                return .failure(URLError(.unsupportedURL))
            }
            sync.b1.resume()
            if !expected.isEmpty || pins {
                try await wait(feed, "B1 demand completed") {
                    try self.read(f) { db in
                        let dirty = Set(try String.fetchAll(db, sql: "SELECT message_id FROM b1_metadata WHERE dirty = 1"))
                        let dirtyPins = try Int.fetchOne(db, sql: "SELECT dirty FROM b1_pins WHERE channel_id = ?", arguments: [f.model.channel])
                        return dirty.isDisjoint(with: expected) && (!pins || dirtyPins == 0)
                    }
                }
            }
            try await settle(feed)
            let metadata = ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/message-metadata") == true }
            let ids = Set(metadata.flatMap { seen in
                URLComponents(url: seen.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ids" }?.value?.split(separator: ",").map(String.init) ?? []
            })
            XCTAssertEqual(ids, expected)
            XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/pins") == true }.count, pins ? 1 : 0)
        }
        try await demand(allFeed.union(threadIDs), pins: false)
        b1.showPins(true)
        try await demand(allFeed.union(threadIDs), pins: true)
        feed.view.isHidden = true; try await settle(feed)
        try await demand(threadIDs, pins: true)
        thread.view.isHidden = true; try await settle(thread)
        try await demand([], pins: true)
        b1.showPins(false)
        try await demand([], pins: false)
        feed.view.isHidden = false; try await settle(feed)
        try await demand(allFeed, pins: false)
    }

    func testReservationExpiryReachesMountedPendingRowAndRetainsUnchangedRows() async throws {
        let f = try await fixture(count: 2)
        let server = AttachmentTestServer()
        ChatStubProtocol.reset { server.answer($0, $1) }
        f.base.service.isServerKnown = { _, _ in true }
        f.base.service.serverCapabilities[f.base.key.server] = ["chat.attachments", "chat.attachments_context", "chat.channel_ux1"]
        let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        f.base.service.serverAttachmentLimits[f.base.key.server] = limits
        let manager = try XCTUnwrap(f.base.service.attachments(f.base.key))
        manager.pollDelay = { _ in .milliseconds(15) }
        let bytes = Data("Owned bytes survive reservation expiry".utf8)
        try manager.add(data: bytes, name: "expiring.txt", channel: f.model.channel, root: nil)
        try await wait(f.host, "prepared file") { manager.drafts.first?.state == .ready }
        let draft = try XCTUnwrap(manager.drafts.first)
        f.model.saveDraft("Pending expiring file", root: nil, mentionOnly: true)
        let posted = try f.base.service.sendChannel(f.base.key, channel: f.model.channel, root: nil,
            text: "Pending expiring file", mentions: [], agents: [], draftVersion: XCTUnwrap(f.model.draftVersion(root: nil)), mentionOnly: true)
        manager.reconcile()
        try await f.settle()
        let before = try XCTUnwrap(f.coordinator.snapshot)
        XCTAssertEqual(f.model.message(posted)?.localState, .sending)
        let row = try f.row(posted)
        XCTAssertNotNil(row.window)
        // A queued unfinished upload is the existing TTL failure path. Ready
        // posts instead replay their exact command because an ACK may be lost.
        // Keep the existing clock transition in one transaction so upload
        // pumping cannot complete the reservation between the two clock reads.
        let deadline = Date().addingTimeInterval(60)
        let command = try XCTUnwrap(f.base.commands().first { $0.type == "message.post_with_attachments" })
        try write(f) { db in
            var queued = try XCTUnwrap(ChatAttachments.drafts(db, includingQueued: true).first)
            queued.state = .waiting; queued.expiresAt = deadline
            try ChatAttachments.put(db, queued)
            XCTAssertNil(try ChatAttachments.postFailure(db, command, now: deadline.addingTimeInterval(-1)))
            _ = try ChatAttachments.reconcileOwnership(db, now: deadline.addingTimeInterval(1))
        }
        manager.reconcile()
        try await f.settle()
        let after = try XCTUnwrap(f.coordinator.snapshot)
        XCTAssertEqual(f.model.message(posted)?.localState, .failed)
        XCTAssertEqual(f.model.message(posted)?.localError, "attachment_expired")
        XCTAssertEqual(try f.base.commands().first { $0.commandId == command.commandId }?.error, "attachment_expired")
        XCTAssertEqual(manager.queued.map(\.state), [.failed])
        XCTAssertEqual(after.rows.filter { $0.messageID != posted }, before.rows.filter { $0.messageID != posted })
        XCTAssertGreaterThan(try messageRow(after, posted).contentRevision, try messageRow(before, posted).contentRevision)
        XCTAssertTrue(f.host.strings.contains { $0.contains("not sent:") })
        XCTAssertEqual(try Data(contentsOf: manager.storage.url(f.base.key, id: draft.id)), bytes)
        // Expiry does not revoke a confirmed message/file stamp. Native card
        // revocation/late-preview clearing remains in ChatNativeAttachmentTests.
    }
}
