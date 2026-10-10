import SwiftUI

struct ChatPinBanner: View {
    let b1: ChatB1Channel
    let model: ChatChannelModel
    let members: [ChatOrgView.Member]
    let width: Double

    var body: some View {
        let pins = ChatPins.ordered(b1.state.pins ?? [])
        if !b1.state.bannerHidden, let pin = model.pins.current(in: pins) {
            HStack(spacing: 12) {
                Button {
                    model.pins.prepareJump(pin, width: width)
                    model.navigate(to: ChatMessageLink(key: model.key, channel: b1.channel, message: pin.id, sequence: pin.seq))
                    model.pins.advance(in: pins)
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2).fill(ChatAppearance.accent).frame(width: 3)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "pin.fill")
                                Text("Pinned message").fontWeight(.semibold)
                                Text("\((pins.firstIndex { $0.id == pin.id } ?? 0) + 1) / \(pins.count)")
                                Text("· \(ChatPins.author(pin, members: members))").lineLimit(1)
                            }.font(Theme.display(10)).foregroundStyle(ChatAppearance.accent)
                            Text(pin.excerpt.replacingOccurrences(of: "\n", with: " "))
                                .font(Theme.display(12)).lineLimit(1).foregroundStyle(Theme.chromeForeground)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).chatFocusRing().help("Go to this message and show the next pin")
                Button("All \(pins.count)") { model.pins.open() }
                    .buttonStyle(.borderless).font(Theme.display(11, weight: .medium))
                ChatIconButton(title: "Hide pin banner for this channel", symbol: "xmark") { b1.setBannerHidden(true) }
            }.padding(.horizontal, 20).padding(.vertical, 10).frame(height: 64)
                .background(ChatAppearance.accent.opacity(0.06))
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.chromeHairline).frame(height: 1) }
        }
    }
}

/// Full pin reading surface shared by side-by-side, narrow and expanded layouts.
struct ChatPinnedMessages: View {
    let b1: ChatB1Channel
    let model: ChatChannelModel
    let members: [ChatOrgView.Member]
    var width: Double = 1000
    var dismiss: () -> Void = {}

    var body: some View {
        @Bindable var presentation = model.pins
        let state = b1.state
        let pins = ChatPins.ordered(state.pins ?? [])
        let matches = ChatPins.matching(pins, messages: state.pinMessages, members: members,
                                       query: presentation.query, filter: presentation.filter)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "pin.fill").foregroundStyle(ChatAppearance.accent)
                Text("Pinned messages").font(Theme.display(14, weight: .semibold))
                Text("\(pins.count)").font(Theme.mono(11)).foregroundStyle(ChatAppearance.secondary)
                Spacer(minLength: 0)
                ChatIconButton(title: state.bannerHidden ? "Show pin banner" : "Hide pin banner", symbol: state.bannerHidden ? "eye.slash" : "eye") {
                    b1.setBannerHidden(!state.bannerHidden)
                }
                ChatIconButton(title: presentation.expanded ? "Restore side panel" : "Expand for reading",
                               symbol: presentation.expanded ? "sidebar.right" : "arrow.up.left.and.arrow.down.right") {
                    presentation.expanded.toggle()
                }
                ChatIconButton(title: "Close pinned messages", symbol: "xmark") { presentation.close(); dismiss() }
            }.padding(.horizontal, 16).frame(height: 64)
            Divider()
            VStack(spacing: 10) {
                TextField("Search text or author", text: $presentation.query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search pinned messages")
                HStack {
                    Picker("Authors", selection: $presentation.filter) {
                        ForEach(ChatPinFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    Text("\(matches.count) of \(pins.count)").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).fixedSize()
                }
            }.padding(16)
            Divider()
            if !state.accessible {
                empty("Channel unavailable")
            } else {
                if let error = state.loadError {
                    HStack { Text(error); Button("Retry") { b1.retryReads() } }.font(Theme.display(11)).padding(12)
                }
                if state.pins == nil, state.loadError == nil {
                    ProgressView("Loading pins…").controlSize(.small).padding(24)
                } else if pins.isEmpty {
                    empty("No pinned messages")
                } else {
                    if !ChatPins.missing(pins, messages: state.pinMessages).isEmpty {
                        HStack {
                            Text("Loading complete messages…").foregroundStyle(ChatAppearance.secondary)
                            Spacer()
                            Button("Retry") { b1.loadPinBodies(retry: true) }
                        }.font(Theme.display(11)).padding(.horizontal, 16).padding(.top, 10)
                    }
                    if matches.isEmpty {
                        VStack(spacing: 10) {
                            Text("No matching pins").foregroundStyle(ChatAppearance.secondary)
                            Button("Clear search and filters") { presentation.query = ""; presentation.filter = .all }
                        }.padding(24)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(matches) { pin in pinCard(pin, state: state).id(pin.id) }
                        }.scrollTargetLayout().padding(16)
                    }.scrollPosition(id: $presentation.scrollID, anchor: .top)
                }
            }
        }.font(Theme.display(12)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
            .environment(\.openURL, OpenURLAction { ChatMarkdownText.open($0) })
            .onAppear { b1.loadPinBodies() }
            .onChange(of: state.pins) { _, _ in b1.loadPinBodies() }
            .onChange(of: state.pinMessages) { _, _ in b1.loadPinBodies() }
            .onChange(of: presentation.query) { _, _ in presentation.scrollID = nil }
            .onChange(of: presentation.filter) { _, _ in presentation.scrollID = nil }
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(ChatAppearance.secondary).padding(24).frame(maxWidth: .infinity)
    }

    private func pinCard(_ pin: ChatB1.PinnedMessage, state: ChatB1Channel.State) -> some View {
        let message = state.pinMessages[pin.id]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                ChatAvatar(identity: .init(account: pin.authorAccountId, agent: pin.authorAgentId,
                                           session: pin.authorAgentId == nil ? pin.authorSessionName : nil),
                           name: ChatPins.author(pin, members: members), size: 28, key: model.key)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(ChatPins.author(pin, members: members)).font(Theme.display(12, weight: .semibold))
                        if ChatPins.isAgent(pin) { Text("BOT").font(Theme.mono(9)).foregroundStyle(ChatAppearance.secondary) }
                    }
                    Text("Pinned by \(ChatPins.name(pin.pinnedBy, members: members)) · \(ChatMessageRow.time(pin.pinnedAt))")
                        .font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                }
                Spacer(minLength: 0)
            }
            if message?.deleted == true {
                Text("Message deleted").foregroundStyle(ChatAppearance.secondary)
            } else if let message, !message.loading {
                ChatMentionText(markdown: message.text, addresses: members.map(\.handle), fontSize: 13)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(pin.excerpt).foregroundStyle(ChatAppearance.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Preview · the complete message has not loaded yet").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
            }
            Divider()
            HStack {
                Button {
                    model.pins.prepareJump(pin, width: width)
                    model.navigate(to: ChatMessageLink(key: model.key, channel: b1.channel, message: pin.id, sequence: pin.seq))
                } label: { Label("In conversation", systemImage: "arrow.turn.up.left") }
                Spacer()
                if b1.pending(pin.id, choice: "pin") {
                    ProgressView().controlSize(.mini).accessibilityLabel("Unpinning message")
                }
                Button("Unpin") { b1.unpin(pin.id) }
                    .disabled(!b1.canChange || b1.pending(pin.id, choice: "pin") || message?.hasFixed != true || message?.deleted == true)
            }.buttonStyle(.borderless).font(Theme.display(11))
            if let error = b1.problem(pin.id) ?? state.intents[pin.id]?.first(where: { $0.choice == "pin" })?.error {
                Text(error).font(Theme.display(11)).foregroundStyle(ChatAppearance.attention)
            }
        }.padding(14).background(Theme.chromeHover.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.chromeHairline, lineWidth: 1))
    }
}
