import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

/// Synthetic native surfaces only. No connector, account, or network.
@MainActor final class TelegramSurfaceSnapshotTests: XCTestCase {
    func testNativeForumAndBotSurfaces() async throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTPAD_TELEGRAM_CAPTURE"] else { throw XCTSkip("Opt-in native captures") }
        _ = NSApplication.shared
        let id = TelegramChatID(environment: .test, account: 101, chat: 202)
        let state = TabState(route: .telegram(id)), model = TelegramConversationModel(id: id)
        state.telegramModel = model
        var snapshot = TelegramConversationSnapshot(destination: id)
        snapshot.epoch = UUID(); snapshot.revision = 1; snapshot.title = "Harbor forum"; snapshot.kind = .forum
        snapshot.isTopicList = true; snapshot.capabilities.canRead = true
        for n in 1...3 {
            let name = ["General", "Release 1.2", "Archive"][n - 1]
            let info: TDLibValue = .typed("forumTopicInfo", ["forum_topic_id": .integer(Int64(n)),
                "name": .string(name), "is_general": .bool(n == 1), "is_closed": .bool(n == 3),
                "icon": .typed("forumTopicIcon", ["color": .integer(0x66A8E6)])])
            let unread: Int64 = n == 3 ? 0 : Int64(n) * 4
            let raw = TDLibMessage("forumTopic", ["info": info, "unread_count": .integer(unread), "unread_mention_count": .integer(n == 3 ? 0 : 1)])
            snapshot.topics.append(TelegramForumTopic(raw, chatMuted: false)!)
        }
        model.receive(snapshot)
        let forum = TelegramConversationView(state: state, id: id)
        try await capture(VStack(spacing: 0) {
            Text("Harbor forum · Telegram").font(Theme.display(17, weight: .semibold)).padding(20)
            Divider(); forum.topicList
            Text("Choose a topic to read or send a message").font(Theme.display(12)).foregroundStyle(.secondary).padding(18)
        }, output: output, name: "forum")
        snapshot.kind = .bot; snapshot.isTopicList = false; snapshot.capabilities.canSend = true; snapshot.capabilities.sender = "You"
        snapshot.title = "Release Helper"; snapshot.connected = true; snapshot.revision += 1
        let inline = TelegramBotDecoder.keyboard(TDLibMessage("replyMarkupInlineKeyboard", ["rows": .array([.array([
            .typed("inlineKeyboardButton", ["text": .string("Check status"), "type": .typed("inlineKeyboardButtonTypeCallback", ["data": .string("YQ==")])]),
            .typed("inlineKeyboardButton", ["text": .string("Help website ↗"), "type": .typed("inlineKeyboardButtonTypeUrl", ["url": .string("https://example.com")])]),
            .typed("inlineKeyboardButton", ["text": .string("Use in another chat ↗"), "type": .typed("inlineKeyboardButtonTypeSwitchInline")])])])]), message: 10)!
        snapshot.replyKeyboard = TelegramBotDecoder.keyboard(TDLibMessage("replyMarkupShowKeyboard", ["resize_keyboard": .bool(true), "is_personal": .bool(true), "rows": .array([.array([
            .typed("keyboardButton", ["text": .string("My checklist"), "type": .typed("keyboardButtonTypeText")]),
            .typed("keyboardButton", ["text": .string("Help"), "type": .typed("keyboardButtonTypeText")])])])]), message: 11)
        snapshot.bot = TelegramBotDecoder.info(TDLibMessage("userFullInfo", ["bot_info": .typed("botInfo", ["commands": .array([
            .typed("botCommand", ["command": .string("status"), "description": .string("Checklist status")])])])]), user: 202)
        model.receive(snapshot)
        let bot = TelegramConversationView(state: state, id: id)
        try await capture(VStack(alignment: .leading, spacing: 12) {
            Text("Release Helper · Bot").font(Theme.display(17, weight: .semibold)).padding(20)
            Divider()
            Text("Keep your release checklist close. Use Start or choose an action below.").font(Theme.display(13)).padding(.horizontal, 20)
            bot.botKeyboard(inline, reply: false).padding(.horizontal, 20)
            Spacer(); Divider(); bot.botControls
            Text("Message…\n\n⌘Return to send · Return for a new line").font(Theme.display(12)).foregroundStyle(.secondary).padding(20)
        }, output: output, name: "bot")
    }
    private func capture(_ content: some View, output: String, name: String) async throws {
        let view = content.frame(width: 760, height: 560).background(ChatAppearance.surface).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: output).appendingPathComponent(name + ".png")
        try await Task.detached { try bytes.write(to: url) }.value
    }
}
