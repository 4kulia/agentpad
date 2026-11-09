import AgentPadQuietTestSupport
import AgentPadTelegram
import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor final class ChatPopupHostTests: XCTestCase {
    private var oldAccessibility: Any?
    private let enhancedAccessibility = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    override func setUp() async throws {
        _ = NSApplication.shared
        oldAccessibility = NSApp.accessibilityAttributeValue(enhancedAccessibility)
        NSApp.accessibilitySetValue(true, forAttribute: enhancedAccessibility)
    }
    override func tearDown() async throws {
        NSApp.accessibilitySetValue(oldAccessibility, forAttribute: enhancedAccessibility)
    }
    private let ref = ChannelRef(server: "https://chat.example.test", account: "fixture", org: "northstar", channel: "design")
    private func store() -> WorkspaceStore {
        WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, drafts: DraftRepository(),
                       engineFactory: { TestEngine() })
    }
    private func telegram(_ chat: Int64) -> ToolRoute {
        .telegram(.init(environment: .test, account: 42, chat: chat))
    }
    private final class ClickRouteView: NSView {
        var clicked: (NSEvent) -> Void = { _ in }
        override func mouseDown(with event: NSEvent) { clicked(event) }
    }
    func testCommandClickUsesTheDeliveredMouseEventAndOrdinaryClickLeavesTheAgentSelected() async throws {
        let owner = store(); defer { owner.terminate() }
        let workspace = try XCTUnwrap(owner.active)
        let agent = owner.addTab(in: workspace, template: .terminal)
        let surface = ClickRouteView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        // Quiet dispatch intentionally bypasses AppKit's event queue/currentEvent.
        // Decode the directly delivered event through the same production helper.
        surface.clicked = { _ = owner.showChannel(self.ref, asTab: ConversationOpenIntent.isCommandClick($0)) }
        let host = ChatQuietHost(view: surface, dark: true, width: 700, height: 500)
        defer { host.close() }
        try await host.settle()
        for modifiers: NSEvent.ModifierFlags in [[], .command] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 50),
                modifierFlags: modifiers, timestamp: 0, windowNumber: host.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            APQuietSendEvent(event, host.window)
            if modifiers.isEmpty {
                XCTAssertNotNil(owner.popups.visibleConversation)
                XCTAssertTrue(workspace.activeSession === agent)
                owner.popups.dismiss(reason: .dismiss)
            } else {
                XCTAssertFalse(owner.popups.isPresented)
                XCTAssertEqual(workspace.activeSession?.channel, ref)
            }
        }
        XCTAssertFalse(APQuietWindowHasOSFocus(host.window))
    }
    func testHeaderButtonPromotesExactConversationDraftTargetRootAndAnchor() async throws {
        let fixture = try await ChatPopupDraftFixture(); defer { fixture.close() }
        for kind in ChatPopupDraftFixture.Kind.allCases {
            let owner = store(); defer { owner.terminate() }
            let conversation = try fixture.conversation(kind)
            let surface = ChatPopupDraftTabSurface(store: owner)
            let host = ChatQuietHost(content: AnyView(ChatPopupDraftTabMount(surface: surface)), dark: true, width: 950, height: 740)
            defer { host.close() }
            owner.popups.attach(to: host.window)
            XCTAssertTrue(owner.popups.presentConversation(conversation.session))
            try await host.settle()
            try fixture.seed(conversation)
            try await host.settle()
            try fixture.assertMounted(conversation, in: host)
            let expected = try fixture.drafts(conversation)
            let state = conversation.session.tabState
            let channel = conversation.session.channelConversation
            let content = conversation.session.content
            if let model = conversation.model as? ChatChannelModel {
                let reply = try XCTUnwrap(model.message("f7000000-0000-4000-8000-000000000005"))
                model.navigate(to: reply)
                try await host.settle()
                XCTAssertEqual(model.threadRoot, conversation.root)
                XCTAssertEqual(model.revealMessageID, reply.id)
                XCTAssertNotNil(model.positions[conversation.root ?? ""]?.anchor)
            }
            if let model = conversation.model as? TelegramConversationModel {
                model.scrollAnchor = model.snapshot.messages.first?.id
                model.showMessage(999)
            }
            let telegram = conversation.model as? TelegramConversationModel
            let anchor = telegram?.scrollAnchor, target = telegram?.requestedMessage
            let channelAnchor = (conversation.model as? ChatChannelModel)?.positions[conversation.root ?? ""]?.anchor
            let channelTarget = (conversation.model as? ChatChannelModel)?.revealMessageID
            let dmAnchor = (conversation.model as? ChatDMModel)?.positions[conversation.root ?? ""]?.anchor
            try host.press("Open as tab")
            try await host.settle()
            XCTAssertFalse(owner.popups.isPresented)
            XCTAssertNil(conversation.view.window, "Promotion must tear down the popup mount")
            XCTAssertTrue(owner.active?.activeSession === conversation.session)
            XCTAssertTrue(conversation.session.tabState === state)
            XCTAssertTrue(conversation.session.channelConversation === channel)
            XCTAssertEqual(conversation.session.content, content)
            XCTAssertEqual(try fixture.drafts(conversation), expected)
            XCTAssertEqual(telegram?.scrollAnchor, anchor)
            XCTAssertEqual(telegram?.requestedMessage, target)
            XCTAssertEqual((conversation.model as? ChatChannelModel)?.positions[conversation.root ?? ""]?.anchor, channelAnchor)
            XCTAssertEqual((conversation.model as? ChatChannelModel)?.revealMessageID, channelTarget)
            XCTAssertEqual((conversation.model as? ChatDMModel)?.positions[conversation.root ?? ""]?.anchor, dmAnchor)
            surface.mountsTab = true
            try await host.settle()
            try fixture.assertMounted(conversation, in: host)
            XCTAssertEqual(try fixture.drafts(conversation), expected)
            XCTAssertEqual((conversation.model as? ChatChannelModel)?.revealMessageID, channelTarget)
            XCTAssertEqual(owner.allSessions.map(\.id), [conversation.session.id])
        }
    }
    func testPlainChannelActivationBorrowsExistingTabWithoutSelectingIt() throws {
        let owner = store(); defer { owner.terminate() }
        let workspace = try XCTUnwrap(owner.active)
        let chat = owner.openChannelTab(ref, in: workspace)
        let agent = owner.addTab(in: workspace, template: .terminal)
        let selection = workspace.activePane?.activeTabId
        XCTAssertEqual(selection, agent.id)
        XCTAssertTrue(owner.showChannel(ref) === chat)
        XCTAssertTrue(owner.popups.visibleConversation === chat)
        XCTAssertEqual(workspace.activePane?.activeTabId, selection)
        XCTAssertEqual(owner.allSessions.map(\.id), [chat.id, agent.id])
        XCTAssertTrue(chat.isConversationPopup)
        owner.popups.promoteConversation()
        XCTAssertFalse(owner.popups.isPresented)
        XCTAssertFalse(chat.isConversationPopup)
        XCTAssertEqual(workspace.activePane?.activeTabId, chat.id)
        XCTAssertEqual(owner.allSessions.map(\.id), [chat.id, agent.id])
    }
    func testPopupOnlyConversationBecomesOneLocalTabAndKeepsItsState() async throws {
        let fixture = try await ChatPopupDraftFixture(); defer { fixture.close() }
        let owner = store(), remote = store(), router = TabRouter()
        defer { owner.terminate(); remote.terminate() }
        router.stores = { [remote, owner] }
        var raised: [UUID] = []; router.revealWindow = { raised.append($0.windowID) }
        let conversation = try fixture.conversation(.telegram)
        let route = try XCTUnwrap(conversation.session.toolRoute)
        let remoteTab = remote.openToolTab(route)
        let popup = conversation.session
        let surface = ChatPopupDraftTabSurface(store: owner)
        let host = ChatQuietHost(content: AnyView(ChatPopupDraftTabMount(surface: surface)), dark: true, width: 950, height: 740)
        defer { host.close() }
        owner.popups.attach(to: host.window)
        XCTAssertTrue(owner.popups.presentConversation(popup))
        try await host.settle()
        try fixture.seed(conversation)
        try await host.settle()
        try fixture.assertMounted(conversation, in: host)
        let expected = try fixture.drafts(conversation)
        let state = try XCTUnwrap(popup.tabState)
        let view = popup.engine.view
        XCTAssertTrue(owner.allSessions.isEmpty)
        XCTAssertFalse(popup === remoteTab)
        XCTAssertTrue(router.open(route, from: owner, asTab: true) === popup)
        try await host.settle()
        XCTAssertNil(view.window)
        XCTAssertTrue(popup.engine.view === view)
        XCTAssertTrue(popup.tabState === state)
        XCTAssertEqual(try fixture.drafts(conversation), expected)
        surface.mountsTab = true
        try await host.settle()
        try fixture.assertMounted(conversation, in: host)
        XCTAssertEqual(try fixture.drafts(conversation), expected)
        XCTAssertEqual(owner.allSessions.map(\.id), [popup.id])
        XCTAssertEqual(remote.allSessions.map(\.id), [remoteTab.id])
        XCTAssertTrue(raised.isEmpty)
    }
    func testConversationSwitchReplacesOnePageAndRetainsBothModels() async throws {
        let fixture = try await ChatPopupDraftFixture(); defer { fixture.close() }
        let owner = store(); defer { owner.terminate() }
        let host = ChatQuietHost(content: AnyView(Color.gray.popupHost(owner.popups)), dark: true, width: 950, height: 740)
        defer { host.close() }
        owner.popups.attach(to: host.window)
        let conversations = try ChatPopupDraftFixture.Kind.allCases.map(fixture.conversation)
        var expected: [ChatPopupDraftFixture.Drafts] = []
        var previous: ChatPopupDraftFixture.Conversation?
        for conversation in conversations {
            owner.popups.showConversationPicker = previous != nil
            XCTAssertTrue(owner.popups.presentConversation(conversation.session))
            try await host.settle()
            if let previous { XCTAssertNil(previous.view.window, "Switching must detach the outgoing production view") }
            try fixture.seed(conversation)
            try await host.settle()
            try fixture.assertMounted(conversation, in: host)
            expected.append(try fixture.drafts(conversation))
            previous = conversation
        }
        for (index, conversation) in conversations.enumerated() {
            try host.press("Switch conversation")
            try await host.settle()
            XCTAssertTrue(owner.popups.showConversationPicker)
            try fixture.choose(conversation, in: host)
            try await host.settle()
            if let previous { XCTAssertNil(previous.view.window) }
            XCTAssertTrue(owner.popups.visibleConversation === conversation.session)
            XCTAssertTrue(owner.popups.backStack.isEmpty)
            XCTAssertFalse(owner.popups.showConversationPicker)
            try fixture.assertMounted(conversation, in: host)
            XCTAssertEqual(try fixture.drafts(conversation), expected[index])
            previous = conversation
        }
        XCTAssertTrue(owner.allSessions.isEmpty)
    }
    func testOnlyVisibleConversationSubtreeAcknowledgesRead() async throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let behind = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 100))
        let foreground = NSView(frame: NSRect(x: 200, y: 100, width: 300, height: 300))
        let message = NSView(frame: NSRect(x: 10, y: 10, width: 150, height: 45))
        root.addSubview(behind); root.addSubview(foreground); foreground.addSubview(message)
        let host = ChatQuietHost(view: root, dark: true, width: 600, height: 500)
        let overlay = UUID(), child = UUID()
        defer {
            NavigationPresentationGate.setOverlay(overlay, window: host.window, presented: false)
            NavigationPresentationGate.setOverlay(child, window: host.window, presented: false)
            host.close()
        }
        try await host.settle()
        NavigationPresentationGate.setOverlay(overlay, window: host.window, presented: true, visibleContent: foreground)
        XCTAssertTrue(NavigationPresentationGate.obscures(host.window))
        XCTAssertTrue(NavigationPresentationGate.allowsAcknowledgement(message, appActive: true))
        XCTAssertFalse(NavigationPresentationGate.allowsAcknowledgement(behind, appActive: true))
        XCTAssertFalse(NavigationPresentationGate.allowsAcknowledgement(message, appActive: false))
        NavigationPresentationGate.setOverlay(child, window: host.window, presented: true)
        XCTAssertFalse(NavigationPresentationGate.allowsAcknowledgement(message, appActive: true))
        NavigationPresentationGate.setOverlay(child, window: host.window, presented: false)
        foreground.isHidden = true
        XCTAssertFalse(NavigationPresentationGate.allowsAcknowledgement(message, appActive: true))
        foreground.isHidden = false
        NavigationPresentationGate.setOverlay(overlay, window: host.window, presented: true)
        XCTAssertFalse(NavigationPresentationGate.allowsAcknowledgement(message, appActive: true), "Picker grants no visible chat subtree")
    }
    func testServicePageKeepsConversationMountedAndBackRestoresItsView() async throws {
        let owner = store(); defer { owner.terminate() }
        let host = ChatQuietHost(content: AnyView(Color.gray.popupHost(owner.popups)), dark: true, width: 950, height: 740)
        defer { host.close() }
        let session = try XCTUnwrap(owner.popups.presentConversation(.tool(telegram(1))))
        try await host.settle()
        let content = session.engine.view
        XCTAssertTrue(content.window === host.window)
        let service = PopupCoordinator.NativePage(title: "Review website", content: { AnyView(Text("Fictional website approval")) })
        XCTAssertTrue(owner.popups.presentNative(service))
        try await host.settle()
        XCTAssertTrue(content.window === host.window, "A child must not cancel the Telegram observer or approval")
        XCTAssertTrue(content.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(NavigationPresentationGate.allowsAcknowledgement(content, appActive: true))
        owner.popups.back(); try await host.settle()
        XCTAssertTrue(owner.popups.visibleConversation === session)
        XCTAssertTrue(session.engine.view === content)
        XCTAssertFalse(content.isHiddenOrHasHiddenAncestor)
    }
    func testEscapeOutsideAndCloseKeepRetainedSessionAndConsumeOutsideClick() async throws {
        let fixture = try await ChatPopupDraftFixture(); defer { fixture.close() }
        for kind in ChatPopupDraftFixture.Kind.allCases {
            let owner = store(); defer { owner.terminate() }
            var behindClicks = 0
            let host = ChatQuietHost(content: AnyView(Button { behindClicks += 1 } label: {
                Color.gray.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.buttonStyle(.plain).popupHost(owner.popups)), dark: true, width: 950, height: 740)
            defer { host.close() }
            owner.popups.attach(to: host.window)
            let conversation = try fixture.conversation(kind)
            let session = conversation.session
            XCTAssertTrue(owner.popups.presentConversation(session))
            try await host.settle()
            try fixture.seed(conversation)
            try await host.settle()
            let expected = try fixture.drafts(conversation)
            for action in ["escape", "outside", "close"] {
                try fixture.assertMounted(conversation, in: host)
                switch action {
                case "escape":
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: host.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                        isARepeat: false, keyCode: 53))
                    APQuietSendEvent(event, host.window)
                case "outside":
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 5, y: 5), modifierFlags: [],
                            timestamp: 0, windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                        APQuietSendEvent(event, host.window)
                    }
                default: try host.press("Close popup")
                }
                try await host.settle()
                XCTAssertFalse(owner.popups.isPresented, "\(kind): \(action)")
                XCTAssertNil(conversation.view.window, "Dismissal must detach the production conversation view")
                XCTAssertEqual(try fixture.drafts(conversation), expected, "\(kind): \(action)")
                XCTAssertFalse(session.tabState?.isClosed == true)
                XCTAssertTrue(owner.popups.sessions.contains { $0 === session })
                XCTAssertTrue(owner.popups.presentConversation(session.content) === session)
                try await host.settle()
                try fixture.assertMounted(conversation, in: host)
                XCTAssertEqual(try fixture.drafts(conversation), expected, "Reopened \(kind): \(action)")
            }
            XCTAssertEqual(behindClicks, 0)
            XCTAssertFalse(APQuietWindowHasOSFocus(host.window))
            }
    }
}
