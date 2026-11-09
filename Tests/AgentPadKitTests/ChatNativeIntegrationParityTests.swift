import AppKit
import AgentPadQuietTestSupport
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

/// W09 integration through the production caller and its native timeline seam.
/// These checks use local stores, stub transports and contained view actions.
@MainActor final class ChatNativeIntegrationParityTests: XCTestCase {
    private var fixtures: [ChatNativeActionFixture] = []
    private var hosts: [ChatQuietHost] = []
    private var dmModels: [ChatDMModel] = []
    private var syncs: [ChatDMSync] = []
    private var sockets: [ChatSocket] = []
    private var previousActive: (@MainActor () -> Bool)!
    private var previousEnhanced: Any?
    private let dm = "2c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f"

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
        for host in hosts {
            for view in ChatTimelineReferenceCapture.descendants(host.view, NSHostingView<AnyView>.self) {
                view.rootView = AnyView(EmptyView())
            }
            try await host.settle()
            host.close()
        }
        hosts = []
        dmModels.forEach { $0.stop() }; syncs.forEach { $0.stop() }; sockets.forEach { $0.stop() }
        dmModels = []; syncs = []; sockets = []
        for fixture in fixtures.reversed() { await fixture.close() }
        fixtures = []
        ChatNotifications.appActive = previousActive
        NSApp.accessibilitySetValue(previousEnhanced, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        XCTAssertNil(APQuietFailure())
    }

    private func fixture() async throws -> ChatNativeActionFixture {
        let value = try await ChatNativeActionFixture(count: 35)
        fixtures.append(value)
        value.dispose()
        value.base.service.isServerKnown = { _, _ in true }
        return value
    }

    private func channelContent(_ f: ChatNativeActionFixture, dark: Bool = false) throws -> (ChatChannelModel, AnyView) {
        let card = ChatChannelCard(channelId: ChatTimelineReferenceFixture.channel,
            teamId: "f5000000-0000-4000-8000-000000000004", name: "Native integration", createdBy: f.base.key.accountId,
            archived: false, version: 1)
        let session = ChatChannelSession()
        session.update(.ready(card, team: "Team", offline: true), key: f.base.key, store: f.base.store, service: f.base.service)
        let model = try XCTUnwrap(session.model)
        return (model, AnyView(ChatChannelView(card: card, team: "Team", offline: true, key: f.base.key,
            conversation: session, service: f.base.service)
            .environment(\.colorScheme, dark ? .dark : .light)))
    }

    private func mount(_ content: AnyView, dark: Bool = false) async throws -> ChatQuietHost {
        let host = ChatQuietHost(content: content, dark: dark, width: 1_100, height: 650)
        hosts.append(host)
        try await settle(host)
        return host
    }

    private func settle(_ host: ChatQuietHost) async throws {
        for _ in 0..<3 { try await host.settle() }
    }

    private func pane(_ host: ChatQuietHost, root: String? = nil) throws -> NativeChatTimelineCoordinator {
        let values = ChatTimelineReferenceCapture.descendants(host.view, NativeChatTimelineContainer.self)
            .map(\.coordinator).filter { $0.snapshot?.conversation.root == root }
        XCTAssertEqual(values.count, 1)
        return try XCTUnwrap(values.first)
    }

    private func wait(_ host: ChatQuietHost, _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while try !condition() {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "Native integration did not settle", code: 1) }
            try await host.settle()
        }
    }

    func testLateRevealRetainsActualNativeRowGeometryAfterInsertion() async throws {
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce()
        let f = try await fixture()
        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
        let members = [ChatOrgView.Member(accountId: f.base.key.accountId, handle: "anna", name: "Anna", role: "owner")]
        for width: CGFloat in [760, 420, 320] {
            let root: String? = width == 420 ? "w09-reveal-0" : nil
            let messages = try (0..<40).map { index in
                var value = try ChatTimelineReferenceFixture.message("w09-reveal-\(index)", me: f.base.key.accountId,
                    text: "Reveal fixture message \(index), kept at its exact timeline identity.", seq: index + 1)
                value.threadRootId = index == 0 ? nil : root
                return value
            }
            let target = messages[20]
            let model = ChatTimelineReferenceModel(f.base, messages: messages.filter { $0.id != target.id })
            model.threadRoot = root; model.revealMessageID = target.id
            let content = AnyView(ChatTimelineView(model: model, root: root, members: members,
                mentionable: [(f.base.key.accountId, "anna")], me: f.base.key.accountId, archived: false, ownerModel: nil)
                .frame(width: width, height: 700).background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
                .environment(\.colorScheme, .light))
            let view = NSHostingView(rootView: content)
            let host = ChatQuietHost(view: view, dark: false, width: width, height: 700)
            defer { view.rootView = AnyView(EmptyView()); host.close() }
            try await settle(host)
            let coordinator = try pane(host, root: root), table = coordinator.tableView
            func assertGeometry(_ phase: String) {
                var observed = 0
                for (index, row) in coordinator.rows.enumerated() {
                    guard let id = row.messageID,
                          table.rect(ofRow: index).intersects(coordinator.scrollView.contentView.bounds),
                          let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatNativeShellCell,
                          let plan = cell.plan else { continue }
                    let rowFrame = table.rect(ofRow: index), cellFrame = cell.convert(cell.bounds, to: table)
                    let bodyOrigin = cell.body.convert(cell.body.bounds.origin, to: table)
                    let expectedBody = CGPoint(x: rowFrame.minX + plan.body.minX, y: rowFrame.minY + plan.body.minY)
                    let context = "\(phase) width=\(width) \(id)"
                    XCTAssertEqual(cellFrame.minY, rowFrame.minY, accuracy: 0.01, "Realized cell must occupy its table row: " + context)
                    XCTAssertEqual(bodyOrigin.y, expectedBody.y, accuracy: 0.01, "Body must retain the row's planned origin: " + context)
                    observed += 1
                }
                XCTAssertGreaterThan(observed, 0)
            }
            assertGeometry("before")
            XCTAssertNil(coordinator.messageIndex(target.id))
            model.feed.messages = messages
            try await wait(host) { coordinator.scrollController.visibleIDs.contains(target.id) }
            try await settle(host)
            XCTAssertTrue(try pane(host, root: root) === coordinator)
            assertGeometry("arrived")
            XCTAssertFalse(APQuietWindowHasOSFocus(host.window)); XCTAssertNil(APQuietFailure())
        }
    }

    func testNativeEditorNaturalAttachmentPreservesSelectionViewportAndFocus() async throws {
        let f = try await fixture()
        let members = [ChatOrgView.Member(accountId: f.base.key.accountId, handle: "anna", name: "Anna", role: "owner")]
        for width: CGFloat in [760, 420] {
            for inThread in [false, true] {
                for long in [false, true] {
                    let message = try ChatTimelineReferenceFixture.message("w09-natural-editor", me: f.base.key.accountId)
                    let draft = long ? (1...24).map { "Line \($0): A saved draft keeps its full text while the editor scrolls." }.joined(separator: "\n")
                        : "Saved text remains in the inline editor."
                    let root = inThread ? message.id : nil
                    let model = ChatTimelineReferenceModel(f.base, messages: [message])
                    model.threadRoot = root
                    model.editing = .init(messageId: message.id, root: root, text: draft, revision: message.revision, message: message)
                    let host = ChatQuietHost(content: AnyView(ChatNativeRowFixture(model: model, message: message,
                        members: members, mentionable: [], me: f.base.key.accountId, archived: false,
                        inThread: inThread).frame(width: width).padding(.top, 24)), dark: false, width: width, height: 600)
                    defer { host.close() }
                    try await settle(host)
                    let coordinator = try pane(host, root: root)
                    let session = try XCTUnwrap(coordinator.editorSession), editor = session.editor
                    let scroll = try XCTUnwrap(editor.enclosingScrollView)
                    let context = "width=\(width) thread=\(inThread) long=\(long)"
                    XCTAssertTrue(scroll.documentView === editor, context)
                    XCTAssertEqual(editor.string, draft, context)
                    XCTAssertEqual(editor.selectedRange(), NSRange(location: (draft as NSString).length, length: 0), context)
                    XCTAssertEqual(editor.textContainerInset, NSSize(width: 8, height: 12), context)
                    XCTAssertEqual(scroll.frame.height, 160, context)
                    XCTAssertEqual(editor.frame.size.width, scroll.contentSize.width, accuracy: 0.01, context)
                    XCTAssertGreaterThanOrEqual(editor.frame.height, scroll.contentSize.height, context)
                    if long { XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "The initial caret is visible at the draft end: " + context) }
                    XCTAssertTrue(host.window.firstResponder === editor, context)
                    XCTAssertTrue(session.host.focused, context)
                    XCTAssertTrue(session.control.focused, context)
                    editor.setSelectedRange(NSRange(location: 1, length: 2))
                    editor.setMarkedText("入力", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
                    let marked = editor.markedRange(), selection = editor.selectedRange()
                    model.editing?.problem = "Keep the current draft."
                    try await settle(host)
                    XCTAssertTrue(coordinator.editorSession === session, context)
                    XCTAssertTrue(session.editor === editor, context)
                    XCTAssertTrue(editor.hasMarkedText(), context)
                    XCTAssertEqual(editor.markedRange(), marked, context)
                    XCTAssertEqual(editor.selectedRange(), selection, context)
                    XCTAssertTrue(host.window.firstResponder === editor, context)
                    XCTAssertFalse(APQuietWindowHasOSFocus(host.window)); XCTAssertNil(APQuietFailure())
                }
            }
        }
    }

    private struct PickerArchiveOwner: View {
        let model: ChatChannelModel
        let me: String
        var body: some View {
            ChatTimelineView(model: model, root: nil,
                members: [.init(accountId: me, handle: "anna", name: "Anna", role: "owner")],
                mentionable: [(me, "anna")], me: me, archived: model.feed.archived, ownerModel: nil)
        }
    }

    private struct PickerGuardIntent: Equatable, Sendable {
        let commandID: String
        let channelID: String
        let messageID: String
        let choice: String
        let present: Bool
    }

    private struct PickerGuardStore: Equatable, Sendable {
        let intents: [PickerGuardIntent]
        let outbox: [ChatCommandRecord]
    }

    private func pickerGuardStore(_ f: ChatNativeActionFixture) async throws -> PickerGuardStore {
        try await f.base.store.queue.read { db in
            PickerGuardStore(intents: try Row.fetchAll(db, sql: "SELECT * FROM b1_intents ORDER BY command_id").map {
                PickerGuardIntent(commandID: $0["command_id"], channelID: $0["channel_id"],
                    messageID: $0["message_id"], choice: $0["choice"], present: $0["present"])
            }, outbox: try ChatCommandRecord.fetchAll(db, sql: "SELECT * FROM outbox ORDER BY seq"))
        }
    }

    private func pickerButton(_ title: String, host: ChatQuietHost) throws -> NSObject {
        let nodes = host.nodes.filter { node in
            ChatTimelineReferenceCapture.accessibilityAttribute(node, "accessibilityRole") as? String
                == NSAccessibility.Role.button.rawValue
                && node.responds(to: NSSelectorFromString("accessibilityPerformPress"))
                && ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                    ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String == title
                }
        }
        XCTAssertEqual(nodes.count, 1, "One actual picker AX button: " + title)
        return try XCTUnwrap(nodes.first)
    }

    private func pickerButtonEnabled(_ title: String, host: ChatQuietHost) throws -> Bool {
        let node = try pickerButton(title, host: host)
        if let control = node as? NSControl { return control.isEnabled }
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        if node.responds(to: legacy), let value = node.perform(legacy, with: "AXEnabled")?.takeUnretainedValue() as? NSNumber {
            return value.boolValue
        }
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard node.responds(to: selector) else {
            throw NSError(domain: "Picker button has no public enabled getter: " + title, code: 1)
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: selector), to: Getter.self)(node, selector)
    }

    func testNativePickerGuardRefreshPreservesTypedEntrySelectionAndFocus() async throws {
        let quick = ["👍", "❤️", "😂", "🎉", "✨", "👀"]
        XCTAssertEqual(ChatEmoji.quick, quick)
        let f = try await fixture()
        try await f.connectSocket()
        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
        let model = f.model, id = try XCTUnwrap(f.messages.last?.id)
        let metadata = ChatB1.Metadata(messageId: id, deleted: false, reactions: [], pin: nil)
        try f.base.write("INSERT OR REPLACE INTO b1_metadata (channel_id, message_id, data, dirty) VALUES (?, ?, ?, 0)",
            [model.channel, id, try ChatB1.encode(metadata)])
        let host = try await mount(AnyView(PickerArchiveOwner(model: model, me: f.base.key.accountId)
            ))
        let timeline = try pane(host), b1 = try XCTUnwrap(model.b1)
        XCTAssertTrue(b1.canChange)
        XCTAssertTrue(timeline.scrollController.scrollTo(messageID: id, alignment: .center))
        try await settle(host)
        let rowIndex = try XCTUnwrap(timeline.messageIndex(id))
        let row = try XCTUnwrap(timeline.tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? ChatNativeShellCell)
        row.rowActions.hover(true)
        let open = try XCTUnwrap(row.rowActions.toolbar.buttons.first { $0.title == "Add reaction" })
        XCTAssertTrue(open.isEnabled)
        open.performClick(nil)
        try await settle(host)
        let popup = row.rowActions.popup
        defer { popup.close(returnFocus: false) }
        XCTAssertTrue(popup.popover.isShown)
        let controller = try XCTUnwrap(popup.popover.contentViewController)
        let popupWindow = try XCTUnwrap(controller.view.window)
        let popupHost = try ChatQuietHost(observing: popupWindow, capturingFullWindow: true)
        // SwiftUI materializes the native field/cell labels when its actual AX
        // tree is first queried. Observe that tree before selecting the field.
        XCTAssertTrue(popupHost.strings.contains("Choose or paste one emoji"))
        try await popupHost.settle()
        let fields = ChatTimelineReferenceCapture.descendants(popupHost.view, NSTextField.self).filter {
            ChatTimelineReferenceCapture.accessibilityAttribute($0, "accessibilityLabel") as? String == "Choose or paste one emoji"
        }
        XCTAssertEqual(fields.count, 1)
        let field = try XCTUnwrap(fields.first)
        XCTAssertTrue(popupWindow.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let entry = "🔥"
        editor.insertText(entry, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        try await popupHost.settle()
        XCTAssertEqual(field.stringValue, entry)
        XCTAssertEqual(editor.string, entry)
        let selection = NSRange(location: 0, length: (entry as NSString).length)
        editor.setSelectedRange(selection)
        XCTAssertTrue(popupWindow.firstResponder === editor)
        XCTAssertTrue(try pickerButtonEnabled("Add", host: popupHost))
        for emoji in quick { XCTAssertTrue(try pickerButtonEnabled(emoji, host: popupHost)) }

        var card = try XCTUnwrap(f.base.store.channels().first { $0.channelId == model.channel })
        card.archived = true; card.version += 1
        XCTAssertEqual(try f.base.store.apply(channels: [card]), [model.channel])
        try await wait(host) { model.feed.archived && timeline.snapshot?.state.archived == true }
        try await popupHost.settle()
        XCTAssertFalse(b1.canChange)
        XCTAssertNil(b1.problem(id))
        // Preserve the existing untouched-open behavior until a real action
        // causes a new problem; archive alone must not recreate the picker.
        for emoji in quick { XCTAssertTrue(try pickerButtonEnabled(emoji, host: popupHost)) }
        XCTAssertTrue(popup.popover.contentViewController === controller)
        XCTAssertEqual(field.stringValue, entry)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(popupWindow.firstResponder === editor)
        let beforePress = try await pickerGuardStore(f)
        XCTAssertEqual(beforePress, PickerGuardStore(intents: [], outbox: []))
        let button = try pickerButton("👍", host: popupHost)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector))
        let expectedProblem = ChatError.storage("Connect to change reactions or pins.").localizedDescription
        try await wait(host) {
            guard b1.problem(id) == expectedProblem,
                  let value = timeline.rows.first(where: { $0.messageID == id }),
                  case .message(let message) = value.payload else { return false }
            return message.content.metadata?.problem == expectedProblem
        }
        try await settle(host); try await popupHost.settle()
        XCTAssertEqual(f.base.service.socket?.state, .connected)
        XCTAssertFalse(b1.canChange)
        XCTAssertEqual(b1.problem(id), expectedProblem)
        let afterPress = try await pickerGuardStore(f)
        XCTAssertEqual(afterPress, beforePress, "The guarded real action must leave every intent and outbox row unchanged")
        XCTAssertTrue(popup.popover.isShown)
        XCTAssertTrue(popup.popover.contentViewController === controller)
        XCTAssertTrue(controller.view.window === popupWindow)
        XCTAssertTrue(NavigationPresentationGate.obscures(host.window))
        for emoji in quick { XCTAssertFalse(try pickerButtonEnabled(emoji, host: popupHost)) }
        XCTAssertFalse(try pickerButtonEnabled("Add", host: popupHost))
        let currentFields = ChatTimelineReferenceCapture.descendants(popupHost.view, NSTextField.self).filter {
            ChatTimelineReferenceCapture.accessibilityAttribute($0, "accessibilityLabel") as? String == "Choose or paste one emoji"
        }
        XCTAssertEqual(currentFields.count, 1)
        XCTAssertTrue(currentFields.first === field)
        XCTAssertTrue(field.window === popupWindow)
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertEqual(field.stringValue, entry)
        XCTAssertEqual(editor.string, entry)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(popupWindow.firstResponder === editor)
        XCTAssertFalse(APQuietWindowHasOSFocus(host.window))
        XCTAssertFalse(APQuietWindowHasOSFocus(popupWindow))
        XCTAssertNil(APQuietFailure())
    }

    private func setupDM(_ f: ChatNativeActionFixture) async throws -> ChatDMModel {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dm")
        let catalog = try Data(contentsOf: directory.appendingPathComponent("dms_response.json"))
        ChatStubProtocol.reset { request, _ in
            request.url?.path.hasSuffix("/dms") == true
                ? .success(.init(status: 200, body: catalog)) : .failure(URLError(.unsupportedURL))
        }
        let transport = FakeSocketTransport()
        let socket = ChatSocket(server: f.base.key.server, token: "test-only", makeTransport: { transport })
        sockets.append(socket) // Deliberately never start this fixture socket.
        let owner = ChatSync(key: f.base.key, store: f.base.store,
            api: ChatAPI(server: f.base.key.server, protocolClasses: [ChatStubProtocol.self]),
            socket: socket, outbox: nil, token: "test-only")
        f.base.service.orgSessions[f.base.key]?.sync = owner
        syncs.append(owner.dm)
        owner.dm.sessionId = "s-anna"
        f.base.service.serverCapabilities[f.base.key.server, default: []].insert("chat.dm")
        owner.dm.configure(true)
        try await owner.dm.reloadCatalog(valid: { true })
        let template = try JSONDecoder().decode(ChatDMMessageWire.self,
            from: Data(contentsOf: directory.appendingPathComponent("dm_message.json")))
        let messages = (0..<35).map { index in
            var message = template
            message.messageId = UUID().uuidString.lowercased(); message.seq = index + 3
            message.text = "Private history \(index).\nAnother line keeps the timeline taller than the pane."
            return message
        }
        try f.base.store.dmWrite { db in
            for message in messages { try ChatDMStore.write(db, message) }
            try db.execute(sql: "UPDATE dm_marks SET seq = 0")
        }
        let model = ChatDMModel(key: f.base.key, dm: dm, service: f.base.service)
        dmModels.append(model)
        XCTAssertTrue(model.readable); XCTAssertTrue(model.writable)
        return model
    }

    private func mountDM(_ model: ChatDMModel) async throws -> ChatQuietHost {
        try await mount(AnyView(ChatDMView(model: model, card: try XCTUnwrap(model.card))
            ))
    }

    private func captureOverlay(_ host: ChatQuietHost, state: String, dark: Bool) throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W09_INTEGRATION_CAPTURE"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "overlay-\(state)-\(dark ? "dark" : "light")"
        let bitmap = try ChatTimelineCaptureColor.bitmap(host.view)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"), options: .withoutOverwriting)
        try JSONSerialization.data(withJSONObject: ["state": state, "dark": dark, "strings": host.strings], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"), options: .withoutOverwriting)
    }

    func testActualNativeOverlayClearsNavigationAndNewMessageCount() async throws {
        for dark in [false, true] {
            let f = try await fixture()
            let (model, content) = try channelContent(f, dark: dark)
            let host = try await mount(content, dark: dark), timeline = try pane(host)
            for counted in [false, true] {
                model.navigate(to: try XCTUnwrap(model.message(f.messages[10].id)))
                try await settle(host)
                XCTAssertTrue(model.hasNavigationReturn)
                XCTAssertFalse(timeline.scrollController.atBottom)
                if counted {
                    let channelID = model.channel
                    try await f.base.store.queue.write { db in
                        try db.execute(sql: """
                            INSERT INTO messages (message_id, channel_id, author_account_id, seq, created_at, has_fixed, has_mutable, text, mentions, revision)
                            VALUES (?, ?, ?, 36, ?, 1, 1, 'A new message while reading history.', '[]', 1)
                            """, arguments: [UUID().uuidString.lowercased(), channelID, CallJSON.boris, ChatTimelineReferenceFixture.date])
                    }
                    try await wait(host) { model.positions[""]?.unseen.count == 1 }
                }
                let title = counted ? "New messages · 1" : "Jump to latest"
                XCTAssertTrue(host.strings.contains(title))
                try captureOverlay(host, state: counted ? "new-message" : "jump", dark: dark)
                try host.press(title)
                try await settle(host)
                XCTAssertFalse(model.hasNavigationReturn); XCTAssertNil(model.revealMessageID)
                XCTAssertTrue(timeline.scrollController.following); XCTAssertTrue(timeline.scrollController.atBottom)
                XCTAssertEqual(model.positions[""]?.unseen, [])
                XCTAssertFalse(host.strings.contains(title), "The actual overlay disappears at bottom")
            }
        }
    }

    func testNativeChannelAndDMSendFromHistoryKeepTheirDistinctFocusAndReadPolicies() async throws {
        let f = try await fixture()
        let lastMessageID = f.messages[34].id
        try await f.base.store.queue.write { db in
            try db.execute(sql: "UPDATE messages SET author_account_id = ? WHERE message_id = ?", arguments: [CallJSON.boris, lastMessageID])
            try db.execute(sql: "INSERT OR REPLACE INTO read_marks (channel_id, last_read_seq) VALUES (?, 0)", arguments: [ChatTimelineReferenceFixture.channel])
        }
        let (channel, content) = try channelContent(f)
        let channelHost = try await mount(content), feed = try pane(channelHost)
        let anchor = f.messages[10].id
        XCTAssertTrue(feed.scrollController.scrollTo(messageID: anchor, alignment: .top))
        try await settle(channelHost)
        let before = try XCTUnwrap(feed.scrollController.bodyFrames[anchor]).minY
        XCTAssertFalse(feed.scrollController.atBottom)
        XCTAssertNotNil(channel.feed.unreadID)
        XCTAssertTrue(channel.send("Channel send from history", root: nil, members: []), channel.problem ?? "")
        try await wait(channelHost) { channel.feed.messages.contains { $0.text == "Channel send from history" } }
        try await settle(channelHost)
        XCTAssertNil(channel.focusedMessageID)
        XCTAssertFalse(feed.scrollController.following)
        XCTAssertEqual(try XCTUnwrap(feed.scrollController.bodyFrames[anchor]).minY, before, accuracy: 0.75)
        XCTAssertNil(channel.feed.unreadID)
        let channelID = channel.channel
        let lastRead = try await f.base.store.queue.read {
            try Int.fetchOne($0, sql: "SELECT last_read_seq FROM read_marks WHERE channel_id = ?", arguments: [channelID])
        }
        XCTAssertEqual(lastRead, 35)

        let dmModel = try await setupDM(f)
        let dmHost = try await mountDM(dmModel), dmFeed = try pane(dmHost)
        let dmAnchor = try XCTUnwrap(dmModel.feed.messages.dropFirst(10).first)
        XCTAssertTrue(dmFeed.scrollController.scrollTo(messageID: dmAnchor.id, alignment: .top))
        try await settle(dmHost)
        XCTAssertFalse(dmFeed.scrollController.atBottom)
        let mark = try f.base.store.dmRead { try ChatDMStore.mark($0, self.dm, root: nil) }
        let version = try XCTUnwrap(dmModel.saveDraft("DM send from history", root: nil))
        XCTAssertTrue(dmModel.send("DM send from history", root: nil, members: [], version: version), dmModel.problem ?? "")
        let posted = try XCTUnwrap(dmModel.focusedMessageID)
        try await wait(dmHost) { dmFeed.scrollController.selectedID == posted }
        XCTAssertTrue(dmFeed.scrollController.visibleIDs.contains(posted))
        XCTAssertFalse(dmFeed.scrollController.following, "DM send requests focus; it does not enable following")
        XCTAssertEqual(try f.base.store.dmRead { try ChatDMStore.mark($0, self.dm, root: nil) }, mark,
            "With automatic reading disabled, DM send itself does not mark history read")
        let commands = try f.base.commands().filter { ["message.post", "dm.message.post"].contains($0.type) }
        XCTAssertEqual(commands.map(\.type), ["message.post", "dm.message.post"])
    }

    func testDelayedNativeCallerConsumesOnlyItsDestinationAncestry() async throws {
        let f = try await fixture()
        let (otherModel, otherContent) = try channelContent(f)
        let other = try await mount(otherContent)
        let target = NSView(frame: CGRect(x: 0, y: 0, width: 1_100, height: 650))
        let link = ChatMessageLink(key: f.base.key, message: f.messages[12])
        ChatMessageNavigation.request(link, key: f.base.key, destination: target)
        try await settle(other)
        XCTAssertNil(otherModel.revealMessageID)
        XCTAssertNil(ChatMessageNavigation.take(key: f.base.key, channel: link.channel, from: other.view))
        let (model, content) = try channelContent(f)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = target.bounds
        target.addSubview(hosting)
        let host = ChatQuietHost(view: target, dark: false, width: 1_100, height: 650)
        hosts.append(host)
        try await wait(host) { model.revealMessageID == link.message }
        try await settle(host)
        XCTAssertEqual(try pane(host).scrollController.selectedID, link.message)
        XCTAssertTrue(try pane(host).scrollController.visibleIDs.contains(link.message))
        XCTAssertNil(otherModel.revealMessageID)
        XCTAssertNil(ChatMessageNavigation.take(key: f.base.key, channel: link.channel, from: hosting), "The pending locator is consumed once")
    }

    func testNativeTablesLeaveFileImportWithEachChannelAndDMComposer() async throws {
        let f = try await fixture()
        var limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        limits.dmSenderBytes = 5 * 1024 * 1024 * 1024
        f.base.service.serverAttachmentLimits[f.base.key.server] = limits
        f.base.service.serverCapabilities[f.base.key.server] = ["chat.attachments", "chat.channel_ux1", "chat.dm", "chat.dm.attachments"]
        let dmModel = try await setupDM(f)
        let (channel, content) = try channelContent(f)
        let channelHost = try await mount(content), dmHost = try await mountDM(dmModel)
        let channelRoot = f.messages[0].id, dmRoot = try XCTUnwrap(dmModel.feed.messages.first?.id)
        channel.openThread(channelRoot); dmModel.openThread(dmRoot)
        try await settle(channelHost); try await settle(dmHost)
        let manager = try XCTUnwrap(f.base.service.attachments(f.base.key))
        let cases: [(ChatQuietHost, ChatAttachmentOwner, String?, String)] = [
            (channelHost, .channel(channel.channel), nil, "Message in #"),
            (channelHost, .channel(channel.channel), channelRoot, "Reply in thread"),
            (dmHost, .dm(dm), nil, "Direct message"), (dmHost, .dm(dm), dmRoot, "Reply")
        ]
        for (index, item) in cases.enumerated() {
            let (host, owner, root, label) = item
            let table = try pane(host, root: root).tableView
            XCTAssertTrue(Set(table.registeredDraggedTypes).isDisjoint(with: ChatAttachmentPaste.types),
                "The timeline must not register the composer's incoming file types")
            let editor = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host.view, ChatMentionEditor.Editor.self)
                .first { label == "Message in #" ? $0.accessibilityLabel()?.hasPrefix(label) == true : $0.accessibilityLabel() == label })
            XCTAssertTrue(editor.registeredDraggedTypes.contains(.fileURL))
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let file = f.directory.appendingPathComponent("w09-composer-\(index).txt")
            try Data("Composer-owned local attachment \(index).".utf8).write(to: file)
            XCTAssertTrue(board.writeObjects([file as NSURL]))
            let drop = try XCTUnwrap(editor.dropAttachments)
            XCTAssertTrue(drop(board), "Invoke the actual mounted composer's incoming-drop callback")
            try await wait(host) { manager.files(owner: owner, root: root).contains { $0.file.name == file.lastPathComponent } }
            let imported = try XCTUnwrap(manager.files(owner: owner, root: root).first { $0.file.name == file.lastPathComponent })
            XCTAssertEqual(imported.owner, owner); XCTAssertEqual(imported.root, root ?? "")
            XCTAssertEqual(manager.drafts.filter { $0.file.name == file.lastPathComponent }.count, 1)
        }
    }
}
