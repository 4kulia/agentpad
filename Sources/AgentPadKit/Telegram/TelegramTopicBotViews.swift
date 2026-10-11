import AgentPadTelegram
import SwiftUI

extension TelegramConversationView {
    var topicList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Topics").font(Theme.display(13, weight: .semibold))
                Spacer()
                if model.snapshot.topics.contains(where: { $0.isGeneral && $0.isHidden }) {
                    Button(showHiddenGeneral ? "Hide General" : "Show General") { showHiddenGeneral.toggle() }
                }
                Button("Reload topics") { model.load(latest: true) }.disabled(model.snapshot.loading)
            }.padding(14)
            if model.snapshot.topicsWindowed {
                Text("Showing a window of topics. Reload topics to return to the beginning.")
                    .font(Theme.display(11)).foregroundStyle(.secondary).padding(.horizontal, 14)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.snapshot.topics.filter { !$0.isGeneral || !$0.isHidden || showHiddenGeneral }) { topic in
                        Button {
                            TelegramTabs.openTopic(id.root.withTopic(.forum(topic.id)), title: topic.name, state: state)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: topic.isClosed ? "lock" : "number")
                                    .font(.system(size: 18, weight: .medium)).frame(width: 30)
                                    .foregroundStyle(topicColor(topic.iconColor))
                                    .help(topic.customEmojiID == 0 ? "Topic" : "Custom topic icon")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(topic.name).font(Theme.display(13, weight: .semibold))
                                    Text(topicStatus(topic)).font(Theme.display(11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if topic.muted { Image(systemName: "bell.slash").foregroundStyle(.secondary).help("Topic muted") }
                                if topic.unreadCount > 0 { Text("\(topic.unreadCount)").font(Theme.display(11)).padding(5).background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 5)).help("Unread messages in this topic") }
                                if topic.mentionCount > 0 { Text("@ \(topic.mentionCount)").font(Theme.display(11)).foregroundStyle(ChatAppearance.accent).help("Unread mentions and replies in this topic") }
                            }.padding(14).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .accessibilityLabel("\(topic.name), \(topic.unreadCount) unread messages, \(topic.mentionCount) mentions and replies, \(topicStatus(topic))")
                        Divider().padding(.leading, 56)
                    }
                    if model.snapshot.topics.isEmpty { Text(model.snapshot.loading ? "Loading topics…" : "No topics available").foregroundStyle(.secondary).padding(30) }
                    if model.snapshot.hasOlder {
                        Button(model.snapshot.loading ? "Loading…" : "Load more topics") { model.loadOlder() }
                            .disabled(model.snapshot.loading).padding(16)
                    }
                }
            }
        }
    }
    var topicBar: some View {
        HStack {
            Button { TelegramTabs.openTopic(id.root, title: nil, state: state) } label: { Label("Back to topics", systemImage: "chevron.left") }
            if let topic = model.snapshot.topicInfo {
                Text(topicStatus(topic)).foregroundStyle(.secondary)
                Spacer()
                if topic.muted { Image(systemName: "bell.slash").help("Topic muted") }
                Text("\(topic.unreadCount) unread · @ \(topic.mentionCount)").foregroundStyle(.secondary)
            }
        }.font(Theme.display(11)).padding(.horizontal, 16).padding(.vertical, 8)
    }
    private func topicStatus(_ topic: TelegramForumTopic) -> String {
        [topic.isGeneral ? "General topic" : "Topic", topic.isHidden ? "Hidden" : nil, topic.isClosed ? "Closed" : nil,
         !topic.muteKnown ? "Notifications inherited" : nil].compactMap { $0 }.joined(separator: " · ")
    }
    private func topicColor(_ value: Int) -> Color {
        value == 0 ? ChatAppearance.accent : Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    var composerPlaceholder: String {
        if let keyboard = model.snapshot.replyKeyboard, !model.snapshot.keyboardHidden, !keyboard.placeholder.isEmpty { return keyboard.placeholder }
        if let topic = model.snapshot.topicInfo { return "Message in \(topic.name)…" }
        return "Message…"
    }
    @ViewBuilder var botControls: some View {
        if model.snapshot.kind == .bot || !model.snapshot.bot.commands.isEmpty || model.snapshot.replyKeyboard != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if model.snapshot.kind == .bot, id.topic == nil {
                        Button(model.snapshot.isTopicList ? "Start in Telegram" : "Start") { model.botAction(.start, pane: pane) }.disabled(!model.snapshot.connected)
                    }
                    if !model.snapshot.isTopicList, !model.snapshot.bot.commands.isEmpty {
                        Menu("/commands") {
                            ForEach(model.snapshot.bot.commands) { command in
                                Button("/\(command.command) · \(command.isEphemeral ? "Open in Telegram" : command.description)") {
                                    model.botAction(.command(command.id), pane: pane)
                                }
                            }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                    Spacer()
                    if let keyboard = model.snapshot.replyKeyboard, keyboard.kind == .reply {
                        Button(model.snapshot.keyboardHidden ? "Show keyboard" : "Hide keyboard") {
                            model.botAction(model.snapshot.keyboardHidden ? .showKeyboard(revision: keyboard.revision) : .dismissKeyboard(revision: keyboard.revision), pane: pane)
                        }.help(keyboard.persistent ? "The bot requests a persistent keyboard" : "Bot reply keyboard")
                    }
                }
                if let keyboard = model.snapshot.replyKeyboard, !model.snapshot.keyboardHidden {
                    if keyboard.forceReply, model.draft.replyTo != keyboard.messageID {
                        HStack {
                            Text("The bot requests a reply").foregroundStyle(.secondary)
                            Button("Reply") { model.replyToKeyboard() }
                            Button("Dismiss") { model.botAction(.dismissKeyboard(revision: keyboard.revision), pane: pane) }
                        }
                    }
                    if keyboard.kind == .reply {
                        ScrollView { botKeyboard(keyboard, reply: true) }
                            .frame(height: min(keyboard.resize ? 140 : 200, CGFloat(keyboard.rows.count) * (keyboard.resize ? 44 : 52)))
                    }
                }
            }.font(Theme.display(11)).padding(.horizontal, 14).padding(.top, 10)
        }
    }
    func botKeyboard(_ keyboard: TelegramBotKeyboard, reply: Bool) -> some View {
        let pending = model.snapshot.pendingBotButtons.contains("\(keyboard.messageID):\(keyboard.revision)")
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(keyboard.rows.indices, id: \.self) { row in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(keyboard.rows[row].indices, id: \.self) { column in
                            let button = keyboard.rows[row][column]
                            Button {
                                model.botAction(.button(message: keyboard.messageID, revision: keyboard.revision, row: row, column: column, replyKeyboard: reply), pane: pane) { destination, _ in
                                    guard !state.isClosed, state.route == .telegram(id), let origin = SupportTabs.shared.owner(state)?.store else { return }
                                    TabRouter.shared.open(.telegram(destination), from: origin)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(button.text).fixedSize(horizontal: false, vertical: true)
                                    if !button.explanation.isEmpty { Text(button.explanation).font(Theme.display(10)).foregroundStyle(.secondary) }
                                }.frame(maxWidth: 260, alignment: .leading).padding(.vertical, keyboard.resize ? 2 : 5)
                            }.buttonStyle(.bordered).disabled(!button.enabled || pending)
                                .help(button.explanation.isEmpty ? button.text : button.explanation)
                                .accessibilityLabel(button.text + (button.explanation.isEmpty ? "" : ", " + button.explanation))
                        }
                    }
                }
            }
            if pending { Text("Waiting for the bot…").foregroundStyle(.secondary) }
        }.font(Theme.display(12))
    }
}
