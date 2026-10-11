import AgentPadTelegram
import AppKit
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

actor ConversationUIFake: TelegramConversationProvider {
    var sent: [TelegramDraft] = []
    var writes: [TelegramDraft] = []
    var observations: [TelegramPresentationObservation] = []
    var sponsoredActions: [TelegramSponsoredAction] = []
    var sponsoredResult: TelegramSponsoredActionResult = .none
    func setSponsoredResult(_ result: TelegramSponsoredActionResult) { sponsoredResult = result }
    func conversation(_ id: TelegramChatID, pane: UUID) -> AsyncStream<TelegramConversationSnapshot> { AsyncStream { $0.finish() } }
    func releaseConversation(_ id: TelegramChatID, pane: UUID, epoch: UUID) {}
    func loadHistory(_ id: TelegramChatID, epoch: UUID, latest: Bool) {}
    func updateDraft(_ id: TelegramChatID, epoch: UUID, draft: TelegramDraft) -> Bool { writes.append(draft); return true }
    func sendDraft(_ id: TelegramChatID, epoch: UUID, draft: TelegramDraft) { sent.append(draft) }
    func retryMessage(_ id: TelegramChatID, epoch: UUID, message: Int64) {}
    func recoverMessage(_ id: TelegramChatID, epoch: UUID, operation: UUID) {}
    func discardRecovery(_ id: TelegramChatID, epoch: UUID, operation: UUID) {}
    func observePresentation(_ id: TelegramChatID, observation: TelegramPresentationObservation) { observations.append(observation) }
    func setApplicationActive(_ active: Bool) {}
    func composerActivity(_ id: TelegramChatID, epoch: UUID, pane: UUID, typing: Bool) {}
    func stageAttachment(_ id: TelegramChatID, epoch: UUID, data: Data, name: String, mime: String, width: Int, height: Int) throws -> TelegramStagedAttachment { throw TelegramConversationError.unavailable }
    func discardAttachment(_ id: TelegramChatID, epoch: UUID, file: UUID) {}
    func downloadAttachment(_ id: TelegramChatID, epoch: UUID, message: Int64, cancel: Bool) {}
    func attachmentURL(_ id: TelegramChatID, epoch: UUID, message: Int64) throws -> URL { throw TelegramConversationError.unavailable }
    func attachmentImportDirectory(_ id: TelegramChatID, epoch: UUID) throws -> URL { throw TelegramConversationError.unavailable }
    func removeAttachmentImportDirectory(_ id: TelegramChatID, epoch: UUID, directory: URL) {}
    func setAttachmentCacheLimit(_ id: TelegramChatID, epoch: UUID, mebibytes: Int) {}
    func clearAttachmentCache(_ id: TelegramChatID, epoch: UUID) {}
    func externalMessageLink(_ id: TelegramChatID, epoch: UUID, message: Int64) -> URL? { nil }
    func performBotAction(_ id: TelegramChatID, epoch: UUID, action: TelegramBotAction) -> TelegramBotActionResult { .notice("Test action") }
    func checkInlineQuery(_ id: TelegramChatID, epoch: UUID, text: String) -> TelegramInlineQueryCheck {
        TelegramInlineQuery.username(in: text) == "helper_bot" ? .inlineBot : .ordinary
    }
    func conversationIsCurrent(_ id: TelegramChatID, epoch: UUID) -> Bool { true }
    func performSponsoredAction(_ id: TelegramChatID, epoch: UUID, action: TelegramSponsoredAction) -> TelegramSponsoredActionResult {
        sponsoredActions.append(action); return sponsoredResult
    }
}

@MainActor final class TelegramConversationUITests: XCTestCase {
    let id = TelegramChatID(environment: .test, account: 101, chat: -202)
    func testModelPublishesVisibilityGenerationBeforeEnqueuingAndInvalidatesOldEpoch() async throws {
        let model = TelegramConversationModel(id: id), provider = ConversationUIFake(), pane = UUID()
        model.provider = provider
        model.observe(.init(pane: pane, epoch: model.snapshot.epoch, active: true, shown: true, ordinaryIDs: [10]))
        model.observe(.init(pane: pane, epoch: model.snapshot.epoch, active: true, shown: true, ordinaryIDs: []))
        for _ in 0..<100 { if await provider.observations.count == 2 { break }; await Task.yield() }
        let values = await provider.observations.sorted { $0.generation < $1.generation }
        XCTAssertEqual(values.count, 2)
        let positive = try XCTUnwrap(values.first), negative = try XCTUnwrap(values.last)
        XCTAssertGreaterThan(positive.generation, 0)
        XCTAssertFalse(positive.isCurrent); XCTAssertTrue(negative.isCurrent)
        XCTAssertEqual(positive.ordinaryIDs, [10]); XCTAssertTrue(negative.ordinaryIDs.isEmpty)
        model.invalidatePresentation(pane: pane)
        XCTAssertFalse(negative.isCurrent, "Geometry changes invalidate synchronously, before coalesced evaluation")
        model.observe(.init(pane: pane, epoch: model.snapshot.epoch, active: true, shown: true, ordinaryIDs: [10]))
        for _ in 0..<100 { if await provider.observations.count == 3 { break }; await Task.yield() }
        let latest = await provider.observations.max { $0.generation < $1.generation }
        let refreshed = try XCTUnwrap(latest)
        XCTAssertTrue(refreshed.isCurrent)
        model.receive(.init(destination: id, epoch: UUID()))
        XCTAssertFalse(refreshed.isCurrent)
    }

    func testComposerShortcutsRespectFocusIMEAndRepeat() {
        XCTAssertEqual(TelegramComposerKey.action(code: 36, modifiers: .command, markedText: false, repeatKey: false), .send)
        XCTAssertEqual(TelegramComposerKey.action(code: 76, modifiers: [.command, .shift], markedText: false, repeatKey: false), .pin)
        for flags: NSEvent.ModifierFlags in [[], .shift, .option, [.command, .control]] {
            XCTAssertEqual(TelegramComposerKey.action(code: 36, modifiers: flags, markedText: false, repeatKey: false), .native)
        }
        XCTAssertEqual(TelegramComposerKey.action(code: 36, modifiers: .command, markedText: true, repeatKey: false), .native)
        XCTAssertEqual(TelegramComposerKey.action(code: 36, modifiers: [.command, .shift], markedText: false, repeatKey: true), .native)
        let editor = ChatMentionEditor.Editor()
        editor.suppressCommandReturnRepeat = true
        var invoked = false
        editor.consume = { _, _ in invoked = true; return true }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: true, keyCode: 36)!
        editor.keyDown(with: event)
        XCTAssertFalse(invoked)
    }
    func testSharedDraftIdentityAndCapturedSendDoNotEraseNewerTyping() async throws {
        let registry = TelegramConversations(), model = registry.model(id), provider = ConversationUIFake()
        XCTAssertTrue(registry.model(id) === model)
        XCTAssertFalse(registry.model(.init(environment: .production, account: 101, chat: -202)) === model)
        var snapshot = TelegramConversationSnapshot(destination: id)
        snapshot.capabilities.canSend = true; snapshot.connected = true; snapshot.revision = 1
        model.receive(snapshot); model.provider = provider
        model.change { $0.text = "Captured" }; let original = model.draft
        model.send(); model.send()
        model.change { $0.text = "Newer text" }
        for _ in 0..<100 { if await provider.sent.count == 1 { break }; await Task.yield() }
        let sent = await provider.sent
        XCTAssertEqual(sent, [original])
        snapshot.revision = 2; snapshot.draft = TelegramDraft()
        model.receive(snapshot)
        XCTAssertEqual(model.draft.text, "Newer text")
        snapshot.revision = 3; snapshot.draft = model.draft
        model.receive(snapshot)
        var stale = snapshot; stale.revision = 2; stale.draft.text = "Late older pane"
        model.receive(stale)
        XCTAssertEqual(model.draft.text, "Newer text")
    }
    func testExactContentGeometryAndPresentationGateAreIndependentOfBottom() {
        let frames: [String: CGRect] = ["above": CGRect(x: 0, y: -100, width: 300, height: 90),
            "partial": CGRect(x: 0, y: -10, width: 300, height: 40), "shown": CGRect(x: 0, y: 50, width: 300, height: 40),
            "below": CGRect(x: 0, y: 200, width: 300, height: 30), "empty": .zero]
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 100)
        let visible = ConversationFrames.visible(frames, viewport: viewport)
        XCTAssertEqual(visible, ["partial", "shown"])
        XCTAssertEqual(ConversationFrames.anchor(frames, viewport: viewport), "partial")
        let covered = PresentationObservation(destination: .telegram(id), epoch: UUID(), pane: UUID(), active: false, shown: true, ordinaryIDs: visible)
        XCTAssertTrue(covered.readableIDs.isEmpty)
        let shown = PresentationObservation(destination: .telegram(id), epoch: UUID(), pane: UUID(), active: true, shown: true, ordinaryIDs: visible)
        XCTAssertEqual(shown.readableIDs, visible)
    }
    func testNativeReadGateRejectsSearchOverlayAndHiddenPane() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200)); window.contentView = view
        window.makeKeyAndOrderFront(nil)
        let overlay = UUID()
        NavigationPresentationGate.setOverlay(overlay, window: window, presented: true)
        XCTAssertFalse(NavigationPresentationGate.allowsAcknowledgement(view, appActive: true))
        NavigationPresentationGate.setOverlay(overlay, window: window, presented: false)
        view.isHidden = true
        XCTAssertFalse(NavigationPresentationGate.allowsAcknowledgement(view, appActive: true))
        view.isHidden = false
        XCTAssertFalse(NavigationPresentationGate.allowsAcknowledgement(view, appActive: false))
    }
    func testEntityRenderingPreservesTextWithoutUnfurlsOrAppLinks() throws {
        let raw = TDLibMessage("message", ["id": .integer(1), "chat_id": .integer(-202), "content": .typed("messageText", ["text": .typed("formattedText", [
            "text": .string("😀 safe bad"), "entities": .array([
                .typed("textEntity", ["offset": .integer(3), "length": .integer(4), "type": .typed("textEntityTypeTextUrl", ["url": .string("https://example.com")])]),
                .typed("textEntity", ["offset": .integer(8), "length": .integer(3), "type": .typed("textEntityTypeTextUrl", ["url": .string("file:///etc/passwd")])])])])])])
        let message = try XCTUnwrap(TelegramMessageDecoder.decode(raw, now: Date(), author: "Casey"))
        let rendered = NSAttributedString(TelegramEntityRenderer.attributed(message))
        XCTAssertEqual(rendered.string, "😀 safe bad")
        XCTAssertNotNil(rendered.attribute(.link, at: 3, effectiveRange: nil))
        XCTAssertNil(rendered.attribute(.link, at: 8, effectiveRange: nil))
    }
}

@MainActor final class TelegramForumBotUITests: XCTestCase {
    let id = TelegramChatID(environment: .test, account: 101, chat: 202)
    private func ready(_ id: TelegramChatID? = nil) -> TelegramConversationSnapshot {
        var value = TelegramConversationSnapshot(destination: id ?? self.id)
        value.revision = 1; value.title = "Release Helper"; value.kind = .bot
        value.connected = true; value.capabilities.canRead = true; value.capabilities.canSend = true
        return value
    }
    private func forceKeyboard(_ message: Int64, personal: Bool = true) -> TelegramBotKeyboard {
        TelegramBotDecoder.keyboard(TDLibMessage("replyMarkupForceReply", ["is_personal": .bool(personal), "input_field_placeholder": .string("Reply here")]), message: message)!
    }
    func testTopicTabsReuseExactRouteAcrossWindowsAndPreserveIndependentDrafts() throws {
        let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, engineFactory: { XCTFail("No terminal for Telegram"); return TestEngine() })
        defer { store.terminate() }
        let router = TabRouter(); router.stores = { [store] }
        let root = try XCTUnwrap(router.open(.telegram(id), from: store)), state = try XCTUnwrap(root.tabState)
        let a = try XCTUnwrap(TelegramTabs.openTopic(id.withTopic(.forum(7)), title: "General renamed", state: state, router: router))
        let b = try XCTUnwrap(TelegramTabs.openTopic(id.withTopic(.forum(9)), title: "Release", state: state, router: router))
        XCTAssertFalse(a === b); XCTAssertEqual(a.displayTitle, "General renamed")
        XCTAssertTrue(TelegramTabs.openTopic(id.withTopic(.forum(7)), title: "General renamed", state: state, router: router) === a)
        XCTAssertTrue(TelegramTabs.openTopic(id, title: nil, state: a.tabState!, router: router) === root)
        let registry = TelegramConversations(), ma = registry.model(id.withTopic(.forum(7))), mb = registry.model(id.withTopic(.forum(9)))
        ma.receive(ready(ma.id)); mb.receive(ready(mb.id))
        ma.change { $0.text = "Seven" }; mb.change { $0.text = "Nine" }
        ma.scrollAnchor = "7:100"; mb.scrollAnchor = "9:200"
        XCTAssertEqual(ma.draft.text, "Seven"); XCTAssertEqual(mb.draft.text, "Nine")
        XCTAssertNotEqual(ma.presentation.destination, mb.presentation.destination); XCTAssertNotEqual(ma.scrollAnchor, mb.scrollAnchor)
        let route = ToolRoute.telegram(ma.id)
        XCTAssertEqual(try JSONDecoder().decode(ToolRoute.self, from: JSONEncoder().encode(route)), route)
        XCTAssertEqual(ma.id.root, id)
    }
    func testInlineBotDraftRequiresExplicitTextChoiceAndEditingResetsIt() async throws {
        let model = TelegramConversationModel(id: id), provider = ConversationUIFake()
        model.provider = provider; model.receive(ready())
        model.change { $0.text = "@helper_bot launch notes" }
        XCTAssertFalse(model.canSend)
        for _ in 0..<100 { if model.checkedInlineName == "helper_bot" { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.inlineCheck, .inlineBot); XCTAssertFalse(model.canSend)
        model.send(); let before = await provider.sent; XCTAssertTrue(before.isEmpty)
        model.applyBotResult(.openTelegram("Inline mode is available in Telegram"))
        XCTAssertEqual(model.botDialog?.url?.absoluteString, "https://t.me/helper_bot")
        let draft = model.draft
        model.botDialog = nil; XCTAssertEqual(model.draft, draft)
        model.sendInlineAsText(); XCTAssertTrue(model.canSend); model.send()
        for _ in 0..<100 { if await provider.sent.count == 1 { break }; await Task.yield() }
        let sends = await provider.sent
        XCTAssertEqual(sends.count, 1); XCTAssertEqual(sends.first?.text, draft.text); XCTAssertEqual(sends.first?.sendAsText, true)
        model.change { $0.text += " changed" }; XCTAssertNil(model.draft.sendAsText); XCTAssertFalse(model.canSend)
        model.change { $0.text = "@person just a mention" }
        for _ in 0..<100 { if model.checkedInlineName == "person" { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.canSend)
    }
    func testForceReplyCanBeCancelledAndRemovalPreservesTypedText() {
        let model = TelegramConversationModel(id: id)
        var snapshot = ready(); model.receive(snapshot)
        model.change { $0.text = "Keep this draft" }
        snapshot.replyKeyboard = forceKeyboard(10); snapshot.revision += 1; model.receive(snapshot)
        XCTAssertEqual(model.draft.replyTo, 10); XCTAssertEqual(model.draft.text, "Keep this draft")
        model.cancelReply(); snapshot.revision += 1; model.receive(snapshot)
        XCTAssertNil(model.draft.replyTo) // same revision must not force it again
        snapshot.replyKeyboard = forceKeyboard(20); snapshot.revision += 1; model.receive(snapshot)
        XCTAssertEqual(model.draft.replyTo, 20)
        snapshot.replyKeyboard = nil; snapshot.revision += 1; model.receive(snapshot)
        XCTAssertNil(model.draft.replyTo); XCTAssertEqual(model.draft.text, "Keep this draft")
        model.change { $0.replyTo = 30 }
        snapshot.replyKeyboard = forceKeyboard(40); snapshot.revision += 1; model.receive(snapshot)
        XCTAssertEqual(model.draft.replyTo, 30) // an explicit reply is never overwritten
    }
    func testCommandsAppendToDraftAndOldDialogCannotOpenAfterEditOrLogout() throws {
        let model = TelegramConversationModel(id: id)
        var snapshot = ready(); model.receive(snapshot)
        model.change { $0.text = "My notes" }; model.applyBotResult(.insertCommand("/status"))
        XCTAssertEqual(model.draft.text, "My notes\n/status")
        let raw = TDLibMessage("message", ["id": .integer(10), "chat_id": .integer(id.chat), "can_be_saved": .bool(true),
            "content": .typed("messageText", ["text": .typed("formattedText", ["text": .string("Bot reply")])]),
            "reply_markup": .typed("replyMarkupInlineKeyboard", ["rows": .array([.array([.typed("inlineKeyboardButton", ["text": .string("Website"), "type": .typed("inlineKeyboardButtonTypeUrl", ["url": .string("https://example.com")])])])])])])
        let message = try XCTUnwrap(TelegramMessageDecoder.decode(raw, now: Date(), author: "Bot"))
        snapshot.messages = [message]; snapshot.revision += 1; model.receive(snapshot)
        let action = TelegramBotAction.button(message: 10, revision: message.inlineKeyboard!.revision, row: 0, column: 0, replyKeyboard: false)
        model.applyBotResult(.confirmURL(URL(string: "https://example.com")!), action: action)
        let dialog = try XCTUnwrap(model.botDialog)
        XCTAssertTrue(model.canConfirmBotURL(dialog))
        snapshot.messages[0].inlineKeyboard = nil; snapshot.revision += 1; model.receive(snapshot)
        XCTAssertFalse(model.canConfirmBotURL(dialog)); XCTAssertEqual(model.draft.text, "My notes\n/status")
        snapshot.epoch = UUID(); model.receive(snapshot)
        XCTAssertNil(model.botDialog); XCTAssertFalse(model.canConfirmBotURL(dialog))
    }
}
