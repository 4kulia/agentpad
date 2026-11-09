import AppKit
import AgentPadQuietTestSupport
import GRDB
import Observation
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor final class ChatTimelineSeamTests: XCTestCase {
    private typealias F = ChatTimelineW01
    private var directory: URL!
    private var models: [ChatTimelineW01Model] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-timeline-w01-seam-\(UUID().uuidString)")
        ChatNotifications.badgeChanged = {}
    }
    override func tearDown() async throws {
        for model in models { await model.service.disconnect() }
        models.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
    private func model(dm: Bool = false) -> ChatTimelineW01Model {
        let model = ChatTimelineW01Model(directory: directory.appendingPathComponent(UUID().uuidString))
        model.isDM = dm
        models.append(model)
        return model
    }

    func testAdapterCapturesWholePayloadsForAllFourConversationKinds() {
        for dm in [false, true] {
            for root in [nil, "root"] as [String?] {
                let model = model(dm: dm)
                let message = F.message(root == nil ? "m" : "root", dm: dm)
                model.feed.messages = [message]
                model.threadRoot = root
                let conversation = F.conversation(dm: dm, root: root)
                let actual = ChatTimelineAdapter.capture(model: model, root: root, members: F.members,
                    mentionable: [("w01-me", "anna")], me: "w01-me", archived: false, ownerModel: nil,
                    style: F.style(), selectedID: nil, aliases: [:], now: F.day, conversation: conversation, epoch: F.epoch)
                XCTAssertEqual(actual, ChatTimelineSnapshotBuilder.Input(conversation: conversation, epoch: F.epoch,
                    messages: [F.content(message, adapter: true, dm: dm)],
                    visuals: [F.visual(message: message, key: model.key)], requests: [], threadSummary: root == nil ? nil : "0 replies",
                    members: F.members, mentionable: [.init(account: "w01-me", handle: "anna")], me: "w01-me", style: F.style(),
                    state: F.state(dm: dm, root: root),
                    navigation: .init(reveal: nil, editing: nil, focused: nil, focusID: nil, focusArea: nil, restored: 0),
                    aliases: [:], today: F.calendar.startOfDay(for: F.day)))
            }
        }
    }

    func testAdapterObservesNonMessageAvatarAndEditingChanges() {
        let model = model()
        let message = F.message("m")
        model.feed.messages = [message]
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        let avatarChanged = expectation(description: "avatar epoch observed through existential model")
        withObservationTracking {
            _ = snapshot(adapter, model: model)
        } onChange: { avatarChanged.fulfill() }
        model.service.invalidateAvatars()
        wait(for: [avatarChanged], timeout: 1)
        let avatarSnapshot = snapshot(adapter, model: model)
        let conversation = F.conversation()
        let content = F.content(message, adapter: true)
        let rows: [NativeTimelineSnapshot.Row] = [
            F.row(.topInset, .inset(16)), F.row(.dayBoundary("m"), .day(F.day, label: "Today, Oct 6, 2026")),
            F.row(.message("m"), .message(.init(content: content, startsGroup: true, inThread: false)), content: 2, layout: 1,
                  visual: F.visual(message: message, key: conversation.key, avatarAccess: 1, avatarGeneration: 1)),
            F.row(.bottomInset, .inset(20))
        ]
        XCTAssertEqual(avatarSnapshot, F.expected(rows: rows, ids: ["m"], generation: 2))
        let editingChanged = expectation(description: "editing observed through existential model")
        withObservationTracking { _ = snapshot(adapter, model: model) } onChange: { editingChanged.fulfill() }
        model.editing = .init(messageId: "m", root: nil, text: "Draft", revision: 1, message: message, version: "w01-edit-v1")
        wait(for: [editingChanged], timeout: 1)
        let expectedEdit = ChatChannelModel.Editing(messageId: "m", root: nil, text: "Draft", revision: 1, message: message, version: "w01-edit-v1")
        XCTAssertEqual(snapshot(adapter, model: model), F.expected(rows: [
            F.row(.topInset, .inset(16)), F.row(.dayBoundary("m"), .day(F.day, label: "Today, Oct 6, 2026")),
            F.row(.message("m"), .message(.init(content: F.content(message, editing: expectedEdit, adapter: true), startsGroup: true, inThread: false)), content: 3, layout: 3,
                  visual: F.visual(message: message, key: conversation.key, avatarAccess: 1, avatarGeneration: 1)),
            F.row(.bottomInset, .inset(20))
        ], ids: ["m"], generation: 3, commands: [.init(token: 1, kind: .edit("m"))]))
    }

    func testAdapterObservesRealB1MetadataWriteWithoutMessageChanges() async throws {
        let model = model()
        let files = ChatFiles(directory: directory.appendingPathComponent("metadata-store"))
        let store = try ChatStore.open(files: files, key: model.key).store
        try store.apply(.init(cursors: ["channel:w01-channel": 10, "member:w01-org:w01-me": 4], members: [],
            teams: [.init(teamId: "t", name: "Team")],
            channels: [.init(channelId: "w01-channel", teamId: "t", name: "Timeline", archived: false, version: 1, head: 10, messages: [])]), confirmsRights: "session")
        try store.setGeneration("g1")
        try await store.queue.write { try ChatB1.watch($0, channel: "w01-channel", ids: ["m"]) }
        model.service.serverCapabilities[model.key.server] = ChatB1.capabilities
        model.b1 = ChatB1Channel(key: model.key, channel: "w01-channel", store: store, service: model.service)
        defer { model.b1 = nil }
        let message = F.message("m")
        model.feed.messages = [message]
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        let changed = expectation(description: "B1 cache observation reaches adapter snapshot")
        withObservationTracking { _ = snapshot(adapter, model: model) } onChange: { changed.fulfill() }
        let value = ChatB1.Metadata(messageId: "m", deleted: false, reactions: [.init(emoji: "👍", count: 3, mine: true)],
            pin: .init(pinnedBy: "w01-me", pinnedAt: "2026-10-06T12:01:00Z"), threadSummary: nil)
        try await store.queue.write { db in
            let token = try XCTUnwrap(ChatB1.readToken(db, channel: "w01-channel"))
            XCTAssertTrue(try ChatB1.apply(db, page: .init(asOfSeq: 10, items: [value]), channel: "w01-channel", token: token, tickets: ["m": 0]))
        }
        await fulfillment(of: [changed], timeout: 2)
        let metadata = NativeTimelineSnapshot.Metadata(value: value, intents: [], reactionsSupported: true, pinsSupported: true,
            summarySupported: true, accessible: true, canChange: false, loadError: nil, problem: nil)
        let visual = NativeTimelineSnapshot.Visual(selected: false,
            avatars: [.init(reference: .init(key: model.key, subject: .account("w01-me")), metadata: nil, generation: 0, context: nil)],
            avatarAccess: 0, attachmentPreviews: [:], attachmentEpoch: 0, metadataTicket: 0, metadataHead: 10)
        XCTAssertEqual(snapshot(adapter, model: model), F.expected(rows: [
            F.row(.topInset, .inset(16)), F.row(.dayBoundary("m"), .day(F.day, label: "Today, Oct 6, 2026")),
            F.row(.message("m"), .message(.init(content: F.content(message, metadata: metadata, adapter: true), startsGroup: true, inThread: false)),
                  content: 2, layout: 2, visual: visual), F.row(.bottomInset, .inset(20))
        ], ids: ["m"], generation: 2))
        XCTAssertEqual(model.feed.messages, [message])
    }

    func testReadOnlyFooterAndCurrentAccountChangeRowRevisions() throws {
        let model = model(dm: true)
        var message = F.message("m", dm: true); message.hasMutable = false
        model.feed.messages = [message]
        model.editable = false; model.retryable = false
        model.editing = .init(messageId: "m", root: nil, text: "Recoverable draft", revision: 1, message: message)
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        func capture(archived: Bool, me: String = "w01-me") -> NativeTimelineSnapshot {
            adapter.snapshot(model: model, root: nil, members: F.members, mentionable: [("w01-me", "anna")],
                me: me, archived: archived, ownerModel: nil, style: F.style(), now: F.day)
        }
        let before = capture(archived: false)
        let readOnly = capture(archived: true)
        let old = try XCTUnwrap(before.rows.first { $0.messageID == "m" })
        let new = try XCTUnwrap(readOnly.rows.first { $0.messageID == "m" })
        XCTAssertEqual(old.payload, new.payload, "Action flags were already disabled; the footer is a separate render input")
        XCTAssertGreaterThan(new.contentRevision, old.contentRevision)
        XCTAssertGreaterThan(new.layoutRevision, old.layoutRevision)
        XCTAssertEqual(before.rows.filter { $0.messageID == nil }, readOnly.rows.filter { $0.messageID == nil })
        let otherAccount = try XCTUnwrap(capture(archived: true, me: "another-account").rows.first { $0.messageID == "m" })
        XCTAssertGreaterThan(otherAccount.contentRevision, new.contentRevision, "The current account controls the row's menu")
    }

    func testMemberNamesInvalidateDependentRowsAndAddressInputsRefreshEveryBody() throws {
        let model = model()
        var mentioned = F.message("mentioned", seq: 2)
        mentioned.text = "Hello @bea"; mentioned.mentions = ["bea"]
        var authored = F.message("authored", seq: 3); authored.authorAccountId = "bea"
        model.feed.messages = [F.message("unrelated"), mentioned, authored]
        var members = F.members + [.init(accountId: "bea", handle: "bea", name: "Bea", role: "member")]
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        func capture() -> NativeTimelineSnapshot {
            adapter.snapshot(model: model, root: nil, members: members, mentionable: members.map { ($0.accountId, $0.handle) },
                me: "w01-me", archived: false, ownerModel: nil, style: F.style(), now: F.day)
        }
        let before = capture()
        members[1].name = "Beatrice"
        let after = capture()
        XCTAssertEqual(after.rows.filter { $0.messageID == nil || $0.messageID == "unrelated" },
                       before.rows.filter { $0.messageID == nil || $0.messageID == "unrelated" })
        for id in ["mentioned", "authored"] {
            let old = try XCTUnwrap(before.rows.first { $0.messageID == id })
            let new = try XCTUnwrap(after.rows.first { $0.messageID == id })
            XCTAssertGreaterThan(new.contentRevision, old.contentRevision)
            XCTAssertGreaterThan(new.layoutRevision, old.layoutRevision)
        }
        members[1].handle = "beatrice"
        let renamedAddress = capture()
        XCTAssertEqual(renamedAddress.rows.filter { $0.messageID == nil }, after.rows.filter { $0.messageID == nil })
        for id in ["unrelated", "mentioned", "authored"] {
            let old = try XCTUnwrap(after.rows.first { $0.messageID == id })
            let new = try XCTUnwrap(renamedAddress.rows.first { $0.messageID == id })
            XCTAssertGreaterThan(new.contentRevision, old.contentRevision,
                "Legacy refreshes every body's full address input even when no mention matches")
            XCTAssertGreaterThan(new.layoutRevision, old.layoutRevision)
        }
        members.reverse()
        let reordered = capture()
        XCTAssertEqual(reordered.rows.filter { $0.messageID == nil }, renamedAddress.rows.filter { $0.messageID == nil })
        for id in ["unrelated", "mentioned", "authored"] {
            let old = try XCTUnwrap(renamedAddress.rows.first { $0.messageID == id })
            let new = try XCTUnwrap(reordered.rows.first { $0.messageID == id })
            XCTAssertGreaterThan(new.contentRevision, old.contentRevision, "Ordered legacy inputs must reach the body")
            XCTAssertGreaterThan(new.layoutRevision, old.layoutRevision)
        }
    }

    func testRepeatedRevealReachesMountedSnapshotHostForChannelAndDM() async throws {
        let fixture = model()
        let channel = ChatChannelModel(key: fixture.key, channel: fixture.channel)
        channel.service = fixture.service
        let dm = ChatDMModel(key: fixture.key, dm: ChatTimelineW01Model.dm, service: fixture.service)
        defer { dm.stop() }
        for (presentation, reveal) in [
            (channel as any ChatConversationPresentation, { channel.revealMessageID = "m" }),
            (dm as any ChatConversationPresentation, { dm.revealMessageID = "m" })
        ] {
            var latest: NativeTimelineSnapshot?
            let timeline = ChatTimelineSnapshotHost(model: presentation, root: nil, members: F.members, mentionable: [],
                me: "w01-me", archived: false, ownerModel: nil, content: { snapshot, _ in
                    latest = snapshot
                    return AnyView(ChatTimelineW01Marker())
                })
            let host = mount(AnyView(timeline))
            defer { unmount(host) }
            try await settle(host.0)
            reveal()
            try await settle(host.0)
            let first = try XCTUnwrap(latest?.commands.first { $0.kind == .reveal("m") })
            reveal()
            try await settle(host.0)
            let second = try XCTUnwrap(latest?.commands.first { $0.kind == .reveal("m") })
            XCTAssertGreaterThan(second.token, first.token, "The factory must receive a fresh token for the same target")
            try await settle(host.0)
            XCTAssertEqual(latest?.commands.first { $0.kind == .reveal("m") }, second, "Rendering alone must not replay a command")
        }
    }

    func testMentionDependenciesPreserveRenderedMarkdownHighlighting() throws {
        let model = model()
        var message = F.message("formatted-mention")
        message.text = "Hello @**bea** and [@anna](https://example.com)"
        model.feed.messages = [message]
        let members = F.members + [.init(accountId: "bea", handle: "bea", name: "Bea", role: "member")]
        let captured = ChatTimelineAdapter().snapshot(model: model, root: nil, members: members,
            mentionable: members.map { ($0.accountId, $0.handle) }, me: "w01-me", archived: false,
            ownerModel: nil, style: F.style(), now: F.day)
        let content = try XCTUnwrap(captured.rows.compactMap { row -> NativeTimelineSnapshot.MessageContent? in
            if case .message(let value) = row.payload { return value.content }; return nil
        }.first)
        XCTAssertEqual(content.addresses, ["anna", "bea"])
        XCTAssertEqual(ChatMentionText.attributed(message.text, addresses: content.addresses),
                       ChatMentionText.attributed(message.text, addresses: members.map(\.handle)))
    }

    func testLoadedReactorMembersAreObservedAndScopedUntilDismissal() throws {
        let model = model()
        model.feed.messages = [F.message("plain"), F.message("reaction", seq: 2)]
        var members = F.members + [.init(accountId: "bea", handle: "bea", name: "Bea", role: "member")]
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        func capture() -> NativeTimelineSnapshot {
            adapter.snapshot(model: model, root: nil, members: members, mentionable: [], me: "w01-me",
                archived: false, ownerModel: nil, style: F.style(), now: F.day)
        }
        _ = capture()
        let actions = try XCTUnwrap(adapter.actions)
        let observed = expectation(description: "Renderer's loaded reactor accounts reach the snapshot host")
        withObservationTracking { _ = capture() } onChange: { observed.fulfill() }
        actions.setReactorAccounts(["bea"], messageID: "reaction")
        wait(for: [observed], timeout: 1)
        let loaded = capture()
        members[1].name = "Beatrice"
        let renamed = capture()
        XCTAssertEqual(renamed.rows.filter { $0.messageID != "reaction" }, loaded.rows.filter { $0.messageID != "reaction" })
        XCTAssertGreaterThan(try XCTUnwrap(renamed.rows.first { $0.messageID == "reaction" }).contentRevision,
                             try XCTUnwrap(loaded.rows.first { $0.messageID == "reaction" }).contentRevision)
        actions.setReactorAccounts([], messageID: "reaction")
        let dismissed = capture()
        members[1].name = "Bee"
        XCTAssertEqual(capture().rows, dismissed.rows)
    }

    func testAdapterObservesCatalogOnlyNameAndAddressChanges() async throws {
        let fixture = try await ChatChannelExecutionTests.Fixture(root: directory.appendingPathComponent("catalog"))
        defer { ChatStubProtocol.reset() }
        fixture.service.serverCapabilities[fixture.key.server] = []
        let model = ChatTimelineW01Model(directory: directory.appendingPathComponent("catalog-model"), key: fixture.key, service: fixture.service)
        models.append(model)
        let channel = ChatTimelineReferenceFixture.channel
        model.channel = channel
        var message = F.message("m"); message.authorAgentId = "w01-agent"; message.channelId = channel
        model.feed.messages = [message]
        try ChatTimelineReferenceCapture.prepareOrganization(fixture.service)
        let org = try XCTUnwrap(ChatOrgCurrent.shared.model)
        var view = org.view
        XCTAssertTrue(view.channelsServed)
        XCTAssertTrue(view.agentsServed)
        _ = try XCTUnwrap(view.channels.first { $0.channelId == channel })
        view.channelAgents = [.init(channelId: channel, agentId: "w01-agent", name: "billing", ownerAccountId: "w01-me",
            ownerHandle: "anna", description: "Billing", access: "read", enabled: true, available: true)]
        org.set(view)
        XCTAssertTrue(ChatOrgCurrent.shared.model === org)
        XCTAssertTrue(org.visible)
        XCTAssertFalse(org.inDoubt)
        XCTAssertFalse(org.snapshotOwed())
        XCTAssertTrue(org.channelsVisible)
        XCTAssertTrue(org.agentsVisible)
        XCTAssertEqual(org.agents(in: channel), view.channelAgents)
        let adapter = ChatTimelineAdapter(epoch: F.epoch)
        let changed = expectation(description: "catalog name observed through snapshot capture")
        withObservationTracking { _ = snapshot(adapter, model: model) } onChange: { changed.fulfill() }
        view.channelAgents[0].name = "reviewer"
        org.set(view)
        let captured = snapshot(adapter, model: model)
        await fulfillment(of: [changed], timeout: 2)
        let expected = NativeTimelineSnapshot.MessageContent(message: message, author: "reviewer",
            authorTooltip: "@reviewer@anna · reviewer (Anna's agent) · @anna · w01-me", addresses: [],
            replyToText: nil, replySummary: nil, replyCount: 0, unreadReplyCount: 0, requestCount: 0,
            editing: nil, confirmation: nil,
            actions: .init(reply: true, edit: true, delete: true, retry: true, save: true, recoverEdit: true,
                copyLink: "agentpad://chat?server=https://chat.example.com:443&org=\(fixture.key.orgId)&channel=\(channel)&message=m&seq=1"),
            metadata: nil, sources: [], membershipHints: [],
            attachments: .init(limits: nil, available: false, availableFileIDs: [], pauseReason: nil),
            bodyAddresses: ["anna", "reviewer@anna"])
        XCTAssertEqual(captured.rows.compactMap { row -> NativeTimelineSnapshot.MessageContent? in
            if case .message(let value) = row.payload { return value.content }; return nil
        }, [expected])
        XCTAssertEqual(model.feed.messages, [message])
        await fixture.service.disconnect()
        ChatOrgCurrent.shared.refresh(fixture.service)
    }

    func testSnapshotHostMountsOnceAndBalancesItsVisitForAllFourConversations() async throws {
        XCTAssertTrue(APQuietIsEnabled())
        for dm in [false, true] {
            for root in [nil, "root"] as [String?] {
                let model = model(dm: dm)
                model.threadRoot = root
                model.feed.messages = [F.message(root ?? "m", dm: dm)]
                let probe = ChatTimelineW01Probe()
                let timeline = ChatTimelineSnapshotHost(model: model, root: root, members: F.members, mentionable: [("w01-me", "anna")],
                    me: "w01-me", archived: false, ownerModel: nil, content: { snapshot, actions in
                        probe.conversation = snapshot.conversation
                        return AnyView(ChatTimelineW01Marker().onAppear { probe.appearances += 1; actions.beginReading() })
                    })
                let host = mount(AnyView(timeline))
                try await settle(host.0)
                XCTAssertEqual(probe.conversation, F.conversation(dm: dm, root: root))
                XCTAssertEqual(probe.appearances, 1)
                XCTAssertEqual(descendants(host.0, ChatTimelineW01MarkerView.self).count, 1)
                XCTAssertEqual(descendants(host.0, NSScrollView.self).count, 0)
                XCTAssertEqual(model.readingCalls, ["begin:\(root ?? "feed")"])
                unmount(host)
                try await Task.sleep(for: .milliseconds(20))
                XCTAssertEqual(model.readingCalls, ["begin:\(root ?? "feed")", "end:\(root ?? "feed")"],
                               "Native adapter disposal balances the visit explicitly started by the probe")
            }
        }
    }

    func testDefaultProductMountUsesOneNativeTableInBothAppearances() async throws {
        XCTAssertTrue(APQuietIsEnabled())
        for dark in [false, true] {
            let model = model()
            let timeline = ChatTimelineView(model: model, root: nil, members: F.members, mentionable: [("w01-me", "anna")],
                me: "w01-me", archived: false, ownerModel: nil)
            let host = mount(AnyView(timeline), dark: dark)
            defer { unmount(host) }
            try await settle(host.0)
            let containers = descendants(host.0, NativeChatTimelineContainer.self)
            XCTAssertEqual(containers.count, 1)
            XCTAssertEqual(descendants(host.0, NSTableView.self).count, 1)
            XCTAssertEqual(descendants(host.0, ChatScrollAccess.Reader.self).count, 0)
            XCTAssertEqual(descendants(host.0, ChatTimelineW01MarkerView.self).count, 0)
            XCTAssertEqual(try XCTUnwrap(containers.first?.coordinator.snapshot).messageIDs, [])
            let bitmap = try XCTUnwrap(host.0.bitmapImageRepForCachingDisplay(in: host.0.bounds))
            host.0.cacheDisplay(in: host.0.bounds, to: bitmap)
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).count, 0)
        }
    }

    private func snapshot(_ adapter: ChatTimelineAdapter, model: ChatTimelineW01Model) -> NativeTimelineSnapshot {
        adapter.snapshot(model: model, root: nil, members: F.members, mentionable: [("w01-me", "anna")], me: "w01-me",
            archived: false, ownerModel: nil, style: F.style(), now: F.day)
    }
    private func mount(_ content: AnyView, dark: Bool = false) -> (NSHostingView<AnyView>, NSWindow) {
        let host = NSHostingView(rootView: AnyView(content.environment(\.colorScheme, dark ? .dark : .light)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        APQuietSelectWindow(window)
        return (host, window)
    }
    private func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded(); host.window?.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
    }
    private func unmount(_ host: (NSHostingView<AnyView>, NSWindow)) {
        host.0.rootView = AnyView(EmptyView()); host.1.contentView = nil; host.1.close()
    }
    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
    }
}

@MainActor private final class ChatTimelineW01Probe {
    var appearances = 0
    var conversation: NativeTimelineSnapshot.Conversation?
}
private final class ChatTimelineW01MarkerView: NSView {}
private struct ChatTimelineW01Marker: NSViewRepresentable {
    func makeNSView(context: Context) -> ChatTimelineW01MarkerView { ChatTimelineW01MarkerView() }
    func updateNSView(_ view: ChatTimelineW01MarkerView, context: Context) {}
}
