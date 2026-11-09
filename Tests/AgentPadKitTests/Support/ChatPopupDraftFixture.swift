import AgentPadQuietTestSupport
import AppKit
import Observation
import SwiftUI
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

@MainActor final class ChatPopupDraftFixture {
    enum Kind: String, CaseIterable { case channel, dm, telegram }
    enum Drafts: Equatable {
        case channel(ChatChannelModel.Draft, ChatChannelModel.Draft, [ChatAttachmentDraft], String?)
        case dm(ChatDMContent.Draft?, ChatDMContent.Draft?, [ChatAttachmentDraft], String?)
        case telegram(TelegramDraft)
    }
    struct Conversation {
        let kind: Kind
        let session: Session
        let model: AnyObject
        let view: NSView
        let root: String?
        let fileName: String
    }
    let capture: ChatPopupCaptureFixture
    private let scope = TeamServiceTestScope()
    private let root: URL
    private let oldContent = NativeTabEngine.content
    private let oldBadgeChanged = ChatNotifications.badgeChanged
    private let oldApplicationActive = ChatNotifications.appActive

    init() async throws {
        XCTAssertTrue(APQuietIsEnabled(), "Use scripts/test-quiet.py")
        ChatScrollAppKitSettings.install()
        AgentPadFonts.registerOnce()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-popup-drafts-\(UUID().uuidString)", isDirectory: true)
        ChatNotifications.badgeChanged = {}
        ChatNotifications.appActive = { false }
        capture = try await ChatPopupCaptureFixture(root: root)
        let fixture = capture
        NativeTabEngine.content = { state in
            switch state.route {
            case .directMessage(let ref): AnyView(ChatDMTab(state: state, ref: ref, service: fixture.service))
            case .telegram(let id): AnyView(TelegramConversationView(state: state, id: id,
                chats: fixture.telegramChats, applicationInteractive: { true }))
            default: AnyView(EmptyView())
            }
        }
        var limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        limits.dmSenderBytes = limits.messageBytes
        fixture.service.serverCapabilities[fixture.base.key.server] = ["chat.dm", "chat.attachments", "chat.dm.attachments", "chat.channel_ux1"]
        fixture.service.serverAttachmentLimits[fixture.base.key.server] = limits
        fixture.service.isServerKnown = { _, _ in true }
    }

    func conversation(_ kind: Kind) throws -> Conversation {
        let session = try capture.session(kind == .channel ? "thread" : kind == .dm ? "dm-draft" : "telegram")
        let root: String?
        let model: AnyObject
        switch kind {
        case .channel:
            let channel = try XCTUnwrap(session.channelConversation?.model)
            root = ChatPopupCaptureFixture.thread
            model = channel
        case .dm:
            let dm = try XCTUnwrap(session.tabState?.dmModel)
            root = "popup-dm-0"
            dm.openThread(root)
            model = dm
        case .telegram:
            root = nil
            model = try XCTUnwrap(session.tabState?.telegramModel)
        }
        return Conversation(kind: kind, session: session, model: model, view: session.engine.view,
                            root: root, fileName: "\(kind.rawValue)-unsent-fixture.txt")
    }

    func seed(_ conversation: Conversation) throws {
        let text = "Unsent \(conversation.kind.rawValue) reply 🦊\nKeep the attachment and reply context."
        switch conversation.kind {
        case .channel:
            let model = try XCTUnwrap(conversation.model as? ChatChannelModel)
            try attach(conversation, owner: .channel(ChatPopupCaptureFixture.channel))
            model.saveDraft("Separate channel parent draft", root: nil)
            model.saveDraft(text, root: conversation.root, mentionOnly: true,
                contextIds: [ChatPopupCaptureFixture.thread], attachmentSelection: [])
        case .dm:
            let model = try XCTUnwrap(conversation.model as? ChatDMModel)
            try attach(conversation, owner: .dm(ChatPopupCaptureFixture.dm))
            XCTAssertNotNil(model.saveDraft("Separate DM parent draft", root: nil))
            XCTAssertNotNil(model.saveDraft(text, root: conversation.root))
        case .telegram:
            let model = try XCTUnwrap(conversation.model as? TelegramConversationModel)
            model.change {
                $0.text = text
                $0.replyTo = 102
                $0.attachments = [.init(id: UUID(), name: conversation.fileName, mime: "text/plain", size: 41)]
            }
        }
    }

    private func attach(_ conversation: Conversation, owner: ChatAttachmentOwner) throws {
        let manager = try XCTUnwrap(capture.service.attachments(capture.base.key))
        let bytes = Data("Fictional original for \(conversation.kind.rawValue).\n".utf8)
        let file = try ChatAttachmentStorage.descriptor(data: bytes, name: conversation.fileName,
                                                       limits: try XCTUnwrap(manager.limits(for: owner)))
        let draft = ChatAttachmentDraft(file: file, messageId: UUID().uuidString.lowercased(), owner: owner,
            root: conversation.root ?? "", session: "s-anna", generation: "g1", sha256: ChatAttachments.digest(bytes),
            createdAt: Date(), expiresAt: Date().addingTimeInterval(86_000), state: .ready, progress: 1)
        try manager.storage.save(bytes, key: capture.base.key, id: draft.id)
        try capture.base.store.queue.write { db in
            try ChatAttachments.put(db, draft)
            try ChatAttachments.bumpDraft(db, owner: owner, root: conversation.root ?? "")
        }
        manager.reconcile()
        XCTAssertTrue(manager.files(owner: owner, root: conversation.root).contains(draft))
    }

    func drafts(_ conversation: Conversation) throws -> Drafts {
        switch conversation.kind {
        case .channel:
            let model = try XCTUnwrap(conversation.session.channelConversation?.model)
            XCTAssertTrue(model === conversation.model)
            let files = capture.service.attachments(capture.base.key)?.files(channel: ChatPopupCaptureFixture.channel, root: conversation.root) ?? []
            return .channel(model.composerDraft(root: nil), model.composerDraft(root: conversation.root), files, model.threadRoot)
        case .dm:
            let model = try XCTUnwrap(conversation.session.tabState?.dmModel)
            XCTAssertTrue(model === conversation.model)
            let files = capture.service.attachments(capture.base.key)?.files(owner: .dm(ChatPopupCaptureFixture.dm), root: conversation.root) ?? []
            return .dm(model.draft(root: nil), model.draft(root: conversation.root), files, model.threadRoot)
        case .telegram:
            let model = try XCTUnwrap(conversation.session.tabState?.telegramModel)
            XCTAssertTrue(model === conversation.model)
            return .telegram(model.draft)
        }
    }

    func assertMounted(_ conversation: Conversation, in host: ChatQuietHost,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(conversation.session.engine.view === conversation.view, file: file, line: line)
        XCTAssertTrue(conversation.view.window === host.window, file: file, line: line)
        XCTAssertFalse(conversation.view.isHiddenOrHasHiddenAncestor, file: file, line: line)
        let text: String
        switch try drafts(conversation) {
        case .channel(_, let draft, let attachments, _):
            text = draft.text
            try assertOriginals(attachments)
        case .dm(_, let draft, let attachments, _):
            text = try XCTUnwrap(draft).text
            try assertOriginals(attachments)
        case .telegram(let draft): text = draft.text
        }
        XCTAssertTrue(editors(conversation.view).contains { $0.string == text },
                      "The production composer must display its retained draft", file: file, line: line)
        XCTAssertTrue(host.strings.contains { $0.contains(conversation.fileName) },
                      "The production attachment strip must remain mounted", file: file, line: line)
    }

    private func assertOriginals(_ attachments: [ChatAttachmentDraft]) throws {
        XCTAssertFalse(attachments.isEmpty)
        let manager = try XCTUnwrap(capture.service.attachments(capture.base.key))
        for attachment in attachments {
            let url = try manager.storage.url(capture.base.key, id: attachment.id)
            XCTAssertEqual(ChatAttachments.digest(try Data(contentsOf: url)), attachment.sha256)
        }
    }
    private func editors(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors)
    }

    func choose(_ conversation: Conversation, in host: ChatQuietHost) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let button = try XCTUnwrap(host.nodes.first { node in
            (ChatTimelineReferenceCapture.accessibilityAttribute(node, "accessibilityRole") as? String) == NSAccessibility.Role.button.rawValue
                && node.responds(to: selector) && ["accessibilityLabel", "accessibilityTitle"].contains {
                (ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String)?
                    .contains(conversation.session.conversationTitle) == true
            }
        }, "Missing production picker choice: \(conversation.session.conversationTitle)")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector))
    }
    func close() {
        NativeTabEngine.content = oldContent
        capture.service.attachmentManagers.values.forEach { $0.suspend() }
        capture.close()
        scope.close()
        ChatNotifications.badgeChanged = oldBadgeChanged
        ChatNotifications.appActive = oldApplicationActive
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor @Observable final class ChatPopupDraftTabSurface {
    let store: WorkspaceStore
    var mountsTab = false
    init(store: WorkspaceStore) { self.store = store }
}

struct ChatPopupDraftTabMount: View {
    @Bindable var surface: ChatPopupDraftTabSurface
    var body: some View {
        Group {
            if surface.mountsTab, !surface.store.popups.isPresented, let session = surface.store.active?.activeSession {
                ChatPopupDraftEngineMount(session: session)
            } else { Color.gray }
        }.popupHost(surface.store.popups)
    }
}

private struct ChatPopupDraftEngineMount: NSViewRepresentable {
    let session: Session
    func makeNSView(context: Context) -> NSView { session.engine.view }
    func updateNSView(_ view: NSView, context: Context) {}
}
