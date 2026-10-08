import AppKit
import SwiftUI

struct ChatReactionPicker: View {
    let b1: ChatB1Channel
    let message: String
    @State private var emoji = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add reaction").font(Theme.display(12, weight: .semibold))
            HStack(spacing: 4) {
                ForEach(ChatEmoji.quick, id: \.self) { value in
                    Button(value) { b1.toggle(message, emoji: value) }
                        .buttonStyle(.plain).font(.system(size: 21)).frame(width: 32, height: 32)
                        .disabled(!b1.canChange || b1.pending(message, choice: value)).chatFocusRing()
                }
            }
            HStack {
                TextField("Emoji", text: $emoji).frame(width: 110).accessibilityLabel("Choose or paste one emoji")
                Button("Emoji & Symbols") { NSApp.orderFrontCharacterPalette(nil) }
                Button("Add") { b1.toggle(message, emoji: emoji); emoji = "" }
                    .disabled(ChatEmoji.canonical(emoji) == nil || !b1.canChange || b1.pending(message, choice: ChatEmoji.canonical(emoji) ?? ""))
            }
            if let problem = b1.problem(message) { Text(problem).font(.caption).foregroundStyle(ChatAppearance.failure) }
        }.padding(14).background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
    }
}

struct ChatReactionStrip: View {
    let b1: ChatB1Channel
    let message: String
    let members: [ChatOrgView.Member]
    var body: some View {
        let reactions = b1.state.metadata[message]?.reactions ?? []
        let pending = (b1.state.intents[message] ?? []).filter { $0.choice != "pin" }
        // Adaptive columns keep all twenty possible emoji visible in narrow threads.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70, maximum: 100), spacing: 5)], alignment: .leading, spacing: 5) {
            ForEach(reactions) { reaction in
                ChatReactionChip(b1: b1, message: message, reaction: reaction, members: members)
            }
            ForEach(pending.filter { intent in !reactions.contains { $0.emoji == intent.choice } }, id: \.choice) { intent in
                HStack(spacing: 4) {
                    Text(intent.choice)
                    if intent.error == nil { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "exclamationmark.circle").help(intent.error ?? "") }
                }.font(Theme.display(11)).padding(5)
            }
        }.fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: CGFloat(max(1, reactions.count + pending.count)) * 86, alignment: .leading)
    }
}

struct ChatReactionChip: View {
    let b1: ChatB1Channel
    let message: String
    let reaction: ChatB1.Reaction
    let members: [ChatOrgView.Member]
    @State private var tooltip = ""
    @State private var showing = false
    @State private var hovering = false
    private var pending: Bool { b1.pending(message, choice: reaction.emoji) }
    var body: some View {
        Button { if b1.canChange && !pending { b1.toggle(message, emoji: reaction.emoji) } } label: {
            HStack(spacing: 5) {
                Text(reaction.emoji).font(.system(size: 12))
                Text("\(reaction.count)")
                if reaction.mine { Text("you").font(Theme.display(9, weight: .medium)) }
                if pending { ProgressView().controlSize(.mini) }
            }.font(Theme.display(11)).padding(.horizontal, 8).frame(minHeight: 25)
                .background(reaction.mine ? ChatAppearance.accent.opacity(0.11) : Theme.chromeHover, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(reaction.mine ? ChatAppearance.accent.opacity(0.45) : ChatAppearance.border))
        }.buttonStyle(.plain)
            .accessibilityLabel("\(reaction.emoji), \(reaction.count)\(reaction.mine ? ", including you" : "")")
            .accessibilityValue(reaction.mine ? "Selected" : "Not selected")
            .help(tooltip.isEmpty ? "Who reacted · right-click for the full list" : tooltip)
            .contextMenu { Button("Who reacted") { showing = true } }
            .popover(isPresented: $showing) { ChatReactorsView(b1: b1, message: message, emoji: reaction.emoji, members: members) }
            .onHover { hovering = $0 }
            .task(id: hovering ? b1.state.versions[message] : nil) {
                tooltip = ""
                guard hovering else { return }
                do {
                    let page = try await b1.reactors(message: message, emoji: reaction.emoji, after: nil, at: nil)
                    guard !Task.isCancelled else { return }
                    tooltip = page.accountIds.map { id in members.first { $0.accountId == id }?.name ?? "Former member" }.joined(separator: ", ")
                        + (page.next == nil ? "" : "…")
                } catch { }
            }.onDisappear { hovering = false; tooltip = ""; showing = false }
            .onChange(of: b1.state.accessible) { _, accessible in if !accessible { tooltip = ""; showing = false; hovering = false } }
    }
}

struct ChatReactorsView: View {
    let b1: ChatB1Channel
    let message: String
    let emoji: String
    let members: [ChatOrgView.Member]
    @State private var list: ChatReactionAccounts
    init(b1: ChatB1Channel, message: String, emoji: String, members: [ChatOrgView.Member]) {
        self.b1 = b1; self.message = message; self.emoji = emoji; self.members = members
        _list = State(initialValue: ChatReactionAccounts(b1: b1, message: message, emoji: emoji))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(emoji) · Who reacted").font(Theme.display(13, weight: .semibold))
            if !b1.state.accessible { Text("Channel unavailable") }
            else {
                ForEach(list.accounts, id: \.self) { id in
                    Text(members.first { $0.accountId == id }?.name ?? "Former member")
                }
                if list.loading { ProgressView().controlSize(.small) }
                else if let error = list.error { Text(error).foregroundStyle(ChatAppearance.failure); Button("Retry") { Task { await list.load(restart: true) } } }
                else if list.next != nil { Button("Show more") { Task { await list.load(restart: false) } } }
                else if list.accounts.isEmpty { Text("No reactions yet").foregroundStyle(ChatAppearance.secondary) }
            }
        }.font(Theme.display(12)).padding(16).frame(minWidth: 220)
            .background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
            .task(id: b1.state.versions[message]) { await list.load(restart: true) }
            .onDisappear { list.clear() }
            .onChange(of: b1.state.accessible) { _, access in if !access { list.clear() } }
    }
}

struct ChatServerReplies: View {
    let summary: ChatB1.Summary
    let members: [ChatOrgView.Member]
    var unreadCount = 0
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HStack(spacing: -4) {
                    ForEach(summary.lastParticipants) { participant in
                        ChatAvatar(identity: participant.identity, name: participant.authorAgentName ?? participant.authorSessionName
                            ?? members.first { $0.accountId == participant.authorAccountId }?.name ?? "Former member", size: 21)
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ChatAppearance.surface, lineWidth: 2))
                    }
                }
                Text(summary.label).font(Theme.display(11, weight: .medium)).foregroundStyle(ChatAppearance.accent)
                ChatUnreadReplyBadge(count: unreadCount)
                if let date = summary.lastReplyAt.flatMap(ChatFeedLayout.date) {
                    Text(date.formatted(date: .omitted, time: .shortened)).font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary)
                }
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(ChatAppearance.accent)
            }.padding(.vertical, 5)
        }.buttonStyle(.plain).help("Open thread").accessibilityLabel("\(summary.label)\(unreadCount > 0 ? ", \(unreadCount) new" : ""), \(summary.lastParticipants.map { participant in participant.authorAgentName ?? participant.authorSessionName ?? members.first { $0.accountId == participant.authorAccountId }?.name ?? "Former member" }.joined(separator: ", ")), open thread").chatFocusRing()
    }
}
