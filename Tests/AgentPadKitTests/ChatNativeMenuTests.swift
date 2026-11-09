import AppKit
import AgentPadQuietTestSupport
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor final class ChatNativeMenuTests: XCTestCase {
    private var fixture: ChatNativeActionFixture?

    override func tearDown() async throws {
        if let fixture { await fixture.close() }
        fixture = nil
    }

    private func setup() async throws -> ChatNativeActionFixture {
        let f = try await ChatNativeActionFixture(count: 2)
        fixture = f
        try await f.connectSocket()
        try await f.settle()
        return f
    }

    func testRecursiveMenuComparisonIncludesEveryFieldAndSubmenuOrder() throws {
        func menu() -> NSMenu {
            let root = NSMenu(), child = NSMenu(), grandchild = NSMenu()
            for menu in [root, child, grandchild] { menu.autoenablesItems = false }
            let parent = NSMenuItem(title: "Parent", action: nil, keyEquivalent: "")
            parent.submenu = child; root.addItem(parent)
            let checked = NSMenuItem(title: "Checked", action: nil, keyEquivalent: "")
            checked.state = .on; checked.isEnabled = false; child.addItem(checked)
            let separator = NSMenuItem.separator(); separator.isEnabled = false; child.addItem(separator)
            let nested = NSMenuItem(title: "Nested", action: nil, keyEquivalent: "")
            nested.submenu = grandchild; child.addItem(nested)
            grandchild.addItem(withTitle: "Leaf", action: nil, keyEquivalent: "")
            return root
        }
        let expected = ChatNativeMenuParity.items(menu())
        XCTAssertEqual(expected, [.init(title: "Parent", enabled: true, state: 0, separator: false, submenu: [
            .init(title: "Checked", enabled: false, state: 1, separator: false, submenu: nil),
            .init(title: "", enabled: false, state: 0, separator: true, submenu: nil),
            .init(title: "Nested", enabled: true, state: 0, separator: false, submenu: [
                .init(title: "Leaf", enabled: true, state: 0, separator: false, submenu: nil)
            ])
        ])])
        let mutations: [(NSMenu) -> Void] = [
            { $0.items[0].submenu!.items[0].title = "Wrong title" },
            { $0.items[0].submenu!.items[0].isEnabled = true },
            { $0.items[0].submenu!.items[0].state = .mixed },
            { let child = $0.items[0].submenu!; child.removeItem(at: 1); child.insertItem(NSMenuItem(), at: 1) },
            { let child = $0.items[0].submenu!; let item = child.items[0]; child.removeItem(at: 0); child.addItem(item) },
            { $0.items[0].submenu!.items[2].submenu!.items[0].title = "Wrong leaf" },
            { $0.items[0].submenu!.items[2].submenu = nil },
            { $0.items[0].submenu!.items[2].submenu!.removeAllItems() }
        ]
        for (index, mutation) in mutations.enumerated() {
            let actual = menu(); mutation(actual)
            XCTAssertNotEqual(ChatNativeMenuParity.items(actual), expected, "Recursive field mutation \(index)")
        }
    }

    func testEveryNativeMenuVariantMatchesTheRecordedContract() async throws {
        let f = try await setup()
        // This matrix outlives the fixture's two advertised heartbeats.
        // The fixture factory returns its already-connected fake transport;
        // keep that server alive with normal frames without changing timeouts.
        let transport = try XCTUnwrap(f.base.service.makeSocketTransport() as? FakeSocketTransport)
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
                guard !Task.isCancelled else { return }
                transport.frame(#"{"frame":"ping"}"#)
            }
        }
        defer { heartbeat.cancel() }
        let oldTime = UserDefaults.standard.object(forKey: "chat.ux2.alwaysShowTime")
        defer { UserDefaults.standard.set(oldTime, forKey: "chat.ux2.alwaysShowTime") }
        struct Variant {
            var mine = true, dm = false, thread = false, archived = false, time = false
            var capabilities = ["chat.reactions", "chat.pins"]
            var state = "normal"
            var name: String { "\(mine ? "own" : "other")/\(dm ? "dm" : "channel")/\(thread ? "thread" : "feed")/archived=\(archived)/time=\(time)/\(capabilities.joined(separator: ","))/\(state)" }
        }
        var variants: [Variant] = []
        for mine in [false, true] { for dm in [false, true] { for thread in [false, true] {
            for archived in [false, true] { for time in [false, true] {
                for capabilities in [[], ["chat.reactions"], ["chat.pins"], ["chat.reactions", "chat.pins"]] {
                    variants.append(Variant(mine: mine, dm: dm, thread: thread, archived: archived, time: time, capabilities: capabilities))
                }
            } }
            for state in ["pinned", "pin-pending", "metadata-missing", "editing", "deleted", "loading", "sending", "failed", "agent", "session"] {
                variants.append(Variant(mine: mine, dm: dm, thread: thread, state: state))
            }
        } } }
        var records: [[String: Any]] = []
        let cell = ChatNativeShellCell(kind: .message)
        defer { cell.unbind() }
        for variant in variants {
            UserDefaults.standard.set(variant.time, forKey: "chat.ux2.alwaysShowTime")
            f.base.service.serverCapabilities[f.base.key.server] = Set(variant.capabilities)
            try f.base.write("UPDATE channels SET archived = ?", [variant.archived])
            var message = f.messages[1]
            if !variant.mine { message.authorAccountId = CallJSON.boris }
            if variant.thread { message.threadRootId = f.messages[0].id }
            switch variant.state {
            case "deleted": message.deletedAt = ChatTimelineReferenceFixture.date
            case "loading": message.hasMutable = false
            case "sending": message.hasFixed = false; message.localState = .sending
            case "failed": message.hasFixed = false; message.localState = .failed
            case "agent": message.authorAgentId = CallJSON.agent
            case "session": message.authorSessionName = "Fixture session"
            default: break
            }
            let metadata = ChatB1.Metadata(messageId: message.id, deleted: message.deleted, reactions: [],
                pin: variant.state == "pinned" ? .init(pinnedBy: f.base.key.accountId, pinnedAt: ChatTimelineReferenceFixture.date) : nil)
            try f.base.write("DELETE FROM b1_metadata")
            try f.base.write("DELETE FROM b1_intents")
            try f.base.write("DELETE FROM outbox")
            if variant.state != "metadata-missing" {
                try f.base.write("INSERT INTO b1_metadata (channel_id, message_id, data, dirty) VALUES (?, ?, ?, 0)",
                    [message.channelId, message.id, try ChatB1.encode(metadata)])
            }
            let model = ChatTimelineReferenceModel(f.base, messages: [message])
            model.isDM = variant.dm; model.feed.archived = variant.archived
            model.threadRoot = variant.thread ? f.messages[0].id : nil
            if !variant.dm {
                model.b1 = ChatB1Channel(key: f.base.key, channel: message.channelId, store: f.base.store, service: f.base.service)
                if variant.state == "pin-pending" {
                    model.b1?.togglePin(message.id)
                    // The command writes synchronously; the observed pending
                    // projection must arrive before the native snapshot.
                    try await f.settle()
                }
            }
            if variant.state == "editing" {
                model.editing = .init(messageId: f.messages[0].id, root: model.threadRoot,
                    text: "Another message is being edited", revision: 3, message: f.messages[0])
            }
            if !variant.dm {
                XCTAssertEqual(model.b1?.supports("chat.reactions"), variant.capabilities.contains("chat.reactions"), variant.name)
                XCTAssertEqual(model.b1?.supports("chat.pins"), variant.capabilities.contains("chat.pins"), variant.name)
                XCTAssertEqual(model.b1?.canChange, !variant.archived, variant.name)
            }
            let adapter = ChatTimelineAdapter()
            defer { adapter.invalidate() }
            let snapshot = adapter.snapshot(model: model, root: model.threadRoot, members: [], mentionable: [],
                me: f.base.key.accountId, archived: variant.archived, ownerModel: nil,
                style: ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
                    increasedContrast: false, alwaysShowTime: variant.time))
            let row = try XCTUnwrap(snapshot.rows.first { $0.messageID == message.id })
            cell.rowActions.configure(cell: cell, row: row, snapshot: snapshot, actions: adapter.actions, layer: nil)
            if variant.state == "pin-pending", !variant.dm { XCTAssertTrue(model.b1?.pending(message.id, choice: "pin") == true) }
            // Literal menu contract retained from the frozen SwiftUI reference.
            // Expectations are built from fixture inputs, never from the native menu.
            var expected: [ChatNativeMenuParity.Item] = []
            func item(_ title: String, enabled: Bool = true, checked: Bool = false) {
                expected.append(.init(title: title, enabled: enabled, state: checked ? 1 : 0, separator: false, submenu: nil))
            }
            let unsent = ["sending", "failed"].contains(variant.state)
            let deleted = variant.state == "deleted"
            if !unsent {
                if !deleted || variant.dm {
                    if !variant.dm && variant.capabilities.contains("chat.reactions") { item("Add reaction…", enabled: !variant.archived) }
                    if !variant.dm && variant.capabilities.contains("chat.pins") {
                        item(variant.state == "pinned" ? "Unpin message" : "Pin message",
                            enabled: !variant.archived && !["pin-pending", "metadata-missing"].contains(variant.state))
                    }
                    item("Reply in Thread")
                }
                item("Open as tab")
                if !deleted || variant.dm {
                    if !variant.dm { item("Copy message link") }
                    item("Always show time", checked: variant.time)
                    item("Copy text")
                    let editable = variant.mine && !deleted && variant.state != "loading"
                        && (variant.dm ? variant.state != "session" : !["agent", "session"].contains(variant.state))
                    if editable && !variant.archived { item("Edit", enabled: variant.state != "editing") }
                    if variant.mine && !deleted && (!variant.dm || variant.state != "loading") { item("Delete…") }
                }
            }
            let actual = cell.rowActions.makeMenu().map(ChatNativeMenuParity.items) ?? []
            XCTAssertEqual(actual, expected, variant.name)
            let menus = try JSONSerialization.jsonObject(with: JSONEncoder().encode(["contract": expected, "native": actual]))
            records.append(["variant": variant.name, "menus": menus, "equal": actual == expected])
        }
        XCTAssertEqual(records.count, 208)
        if let directory = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_PARITY_EVIDENCE"] {
            let url = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                .write(to: url.appendingPathComponent("context-menu-variants.json"))
        }
    }

    func testEveryNativeMenuCommandDispatchesAfterReuseAndOldMenuIsInert() async throws {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let oldEnhanced = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        let oldTime = UserDefaults.standard.object(forKey: "chat.ux2.alwaysShowTime")
        defer {
            NSApp.accessibilitySetValue(oldEnhanced, forAttribute: enhanced)
            UserDefaults.standard.set(oldTime, forKey: "chat.ux2.alwaysShowTime")
        }
        let f = try await setup(), target = f.messages[1]
        let commands = ["Add reaction…", "Pin message", "Unpin message", "Reply in Thread", "Open as tab",
                        "Copy message link", "Always show time", "Copy text", "Edit", "Delete…"]
        var exercised: Set<String> = [], offered: Set<String> = []
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let oldStores = TabRouter.shared.stores
        let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            agentProfiles: AgentProfileStore(fileURL: f.directory.appendingPathComponent("profiles.json")),
            drafts: DraftRepository(fileURL: f.directory.appendingPathComponent("drafts.json")),
            engineFactory: { XCTFail("No terminal should launch"); return TestEngine() })
        TabRouter.shared.stores = { [store] }
        defer { store.terminate(); TabRouter.shared.stores = oldStores }
        let ref = ChannelRef(f.base.key, channel: target.channelId)
        let session = Session(engine: TestEngine(), currentDirectory: f.directory, agent: .terminal)
        session.content = .channel(ref)
        XCTAssertTrue(store.popups.presentConversation(session))
        f.model.tabID = session.id

        for title in commands {
            print("W05 channel menu dispatch after reuse: \(title)")
            do {
                f.model.cancelEditing(); f.model.openThread(nil); f.confirmation.invalidate()
                try f.base.write("DELETE FROM b1_intents")
                try f.base.write("DELETE FROM outbox")
                for message in f.messages {
                    let metadata = ChatB1.Metadata(messageId: message.id, deleted: false, reactions: [],
                        pin: title == "Unpin message" ? .init(pinnedBy: f.base.key.accountId, pinnedAt: ChatTimelineReferenceFixture.date) : nil)
                    try f.base.write("INSERT OR REPLACE INTO b1_metadata (channel_id, message_id, data, dirty) VALUES (?, ?, ?, 0)",
                        [message.channelId, message.id, try ChatB1.encode(metadata)])
                }
                UserDefaults.standard.set(false, forKey: "chat.ux2.alwaysShowTime")
                try await f.settle()
                let (cell, stale, menu) = try ChatNativeMenuParity.reusedMenu(f, from: f.messages[0].id, to: target.id)
                offered.formUnion(menu.items.filter { !$0.isSeparatorItem }.map(\.title))
                cell.rowActions.pasteboard = board
                board.clearContents(); board.setString("Unchanged", forType: .string)
                for index in stale.items.indices { stale.performActionForItem(at: index) }
                XCTAssertNil(f.model.threadRoot); XCTAssertNil(f.model.editing)
                XCTAssertFalse(f.confirmation.showsBlock)
                XCTAssertFalse(cell.rowActions.popup.popover.isShown)
                XCTAssertEqual(board.string(forType: .string), "Unchanged")
                XCTAssertFalse(UserDefaults.standard.bool(forKey: "chat.ux2.alwaysShowTime"))
                XCTAssertTrue(try f.base.commands().isEmpty)

                try ChatNativeMenuParity.dispatch(title, in: menu)
                exercised.insert(title)
                switch title {
                case "Add reaction…":
                    XCTAssertTrue(cell.rowActions.popup.popover.isShown)
                    let window = try XCTUnwrap(cell.rowActions.popup.popover.contentViewController?.view.window)
                    try await f.host.settle()
                    let selector = NSSelectorFromString("accessibilityPerformPress")
                    let button = try XCTUnwrap(ChatTimelineReferenceCapture.accessibilityNodes(window).first {
                        $0.responds(to: selector) && ChatTimelineReferenceCapture.accessibilityAttribute($0, "accessibilityLabel") as? String == "👍"
                    })
                    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                    XCTAssertTrue(unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector))
                    cell.rowActions.popup.close(returnFocus: false)
                case "Reply in Thread":
                    XCTAssertEqual(f.model.threadRoot, target.id)
                    XCTAssertTrue(store.popups.isPresented, "Reply keeps the conversation in its popup")
                case "Open as tab":
                    XCTAssertEqual(f.model.threadRoot, target.id)
                    XCTAssertFalse(store.popups.isPresented)
                    XCTAssertTrue(store.active?.activeSession === session, "The command must promote the owning session, not just open a thread")
                    XCTAssertEqual(store.allSessions.filter { $0 === session }.count, 1)
                case "Copy message link":
                    XCTAssertEqual(board.string(forType: .string), ChatMessageLink(key: f.base.key, message: target).url?.absoluteString)
                    XCTAssertNotEqual(board.string(forType: .string), ChatMessageLink(key: f.base.key, message: f.messages[0]).url?.absoluteString)
                case "Always show time":
                    XCTAssertTrue(UserDefaults.standard.bool(forKey: "chat.ux2.alwaysShowTime"))
                    try ChatNativeMenuParity.dispatch(title, in: menu)
                    XCTAssertFalse(UserDefaults.standard.bool(forKey: "chat.ux2.alwaysShowTime"))
                case "Copy text": XCTAssertEqual(board.string(forType: .string), target.text)
                case "Edit":
                    XCTAssertEqual(f.model.editing?.messageId, target.id)
                    XCTAssertEqual(f.model.editing?.text, target.text)
                    XCTAssertEqual(f.model.editing?.revision, target.revision)
                    XCTAssertNil(f.model.editing?.root)
                case "Delete…":
                    XCTAssertEqual(f.confirmation.context?.targetID, "message:" + target.id)
                    XCTAssertNil(f.model.deletionRoot)
                    try await f.settle()
                    try f.row(target.id).inlineControls.confirmation.accept.performClick(nil)
                default: break
                }
                try await f.settle()
                let queued = try f.base.commands()
                let expected: (String, [String: ChatJSON])?
                switch title {
                case "Pin message", "Unpin message": expected = ("message.pin.set", ["channel_id": .string(target.channelId),
                    "message_id": .string(target.id), "present": .bool(title == "Pin message")])
                case "Add reaction…": expected = ("message.reaction.set", ["channel_id": .string(target.channelId),
                    "message_id": .string(target.id), "present": .bool(true), "emoji": .string("👍")])
                case "Delete…": expected = ("message.delete", ["message_id": .string(target.id), "expected_revision": .number(Double(target.revision))])
                default: expected = nil
                }
                XCTAssertEqual(queued.map(\.type), expected.map { [$0.0] } ?? [], title)
                if let expected { XCTAssertEqual(ChatService.args(try XCTUnwrap(queued.first)), expected.1, title) }
            } catch { XCTFail("Menu command \(title): \(error)") }
        }
        XCTAssertEqual(exercised, Set(commands))
        XCTAssertEqual(offered, exercised, "Every offered native command must have a dispatch assertion")
    }
}
