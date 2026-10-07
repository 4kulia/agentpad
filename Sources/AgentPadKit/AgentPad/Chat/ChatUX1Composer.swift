import SwiftUI

struct ChatUX1Composer: View {
    let model: ChatChannelModel
    let root: String?
    let members: [ChatOrgView.Member]
    let mentionable: [(account: String, handle: String)]
    let agents: [ChatChannelAgent]
    @State private var text = ""
    @State private var control = ChatEditorControl()
    @State private var editorHeight: CGFloat = 58
    @AppStorage("chat.ux2.formatting") private var formatting = true
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var version: String?
    @State private var mentionOnly = false
    @State private var selected = 0
    @State private var dismissedQuery: String?
    @State private var contextIds = Set<String>()
    @State private var choosingContext = false
    @State private var draftLoaded = false

    private var org: ChatOrgModel? { ChatOrgCurrent.shared.model }
    private var card: ChatChannelCard? { org?.visibleChannel(model.channel) }
    private var candidates: [ChatMentionCandidate] {
        let people = mentionable.map { member in
            ChatMentionCandidate(id: member.account, address: member.handle,
                label: members.first { $0.accountId == member.account }?.name ?? member.handle)
        }
        let present = agents.compactMap { agent -> ChatMentionCandidate? in
            agent.address.map { ChatMentionCandidate(id: agent.agentId, address: $0, label: agent.name, agentId: agent.agentId) }
        }
        let outside = card.map { org?.addableAgents($0) ?? [] } ?? []
        let mine = outside.compactMap { agent -> ChatMentionCandidate? in
            guard let handle = members.first(where: { $0.accountId == agent.ownerAccountId })?.handle else { return nil }
            return ChatMentionCandidate(id: agent.agentId, address: "\(agent.name)@\(handle)", label: agent.name,
                                        addToChannel: true, agentId: agent.agentId)
        }
        return people + present + mine
    }
    private var token: (range: NSRange, query: String)? { ChatMentionCandidate.token(text, caret: selection.location) }
    private var sections: [ChatMentionSection] {
        guard selection.length == 0, let token, dismissedQuery != token.query else { return [] }
        return ChatMentionSection.grouped(ChatMentionCandidate.filtered(candidates, query: token.query))
    }
    private var matches: [ChatMentionCandidate] { sections.flatMap(\.rows).map(\.candidate) }
    private var called: [ChatChannelAgent] {
        model.service.supports("chat.channel_ux1", key: model.key) ? ChatMentions.agents(in: text, agents: agents) : []
    }
    private var context: [ChatMessage] { model.contextCandidates(root: root ?? "").filter { contextIds.contains($0.messageId) && $0.messageId != root } }
    private var contextBytes: Int { text.utf8.count + context.reduce(0) { $0 + $1.text.utf8.count } + (root.flatMap(model.message)?.text.utf8.count ?? 0) }
    private var contextCount: Int { context.count + (root == nil ? 1 : 2) }
    private var tooMuchContext: Bool { contextCount > 20 || contextBytes > 48 * 1024 }

    private func changed(_ value: String) {
        text = value
        saveDraft()
        selected = 0
        dismissedQuery = nil
    }
    private func saveDraft() {
        model.saveDraft(text, root: root, mentionOnly: mentionOnly, contextIds: contextIds)
        version = model.draftVersion(root: root)
    }
    private func send() {
        guard let version, mentionOnly || called.isEmpty || !tooMuchContext else { return }
        if model.send(text, root: root, members: mentionable, agents: agents, draftVersion: version, mentionOnly: mentionOnly, context: context) {
            text = ""; self.version = nil; selection = NSRange(location: 0, length: 0); contextIds = []; mentionOnly = false
            control.clearAfterSend()
        }
    }
    private func choose(_ candidate: ChatMentionCandidate) {
        guard let token else { return }
        let inserted = "@\(candidate.address) "
        control.replace(token.range, with: inserted)
        if candidate.addToChannel, let id = candidate.agentId { ChatAgentMembershipHint.add(id, model: model) }
    }
    private func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        if code == 53, modifiers.intersection([.command, .control, .option, .shift]).isEmpty, matches.isEmpty {
            return model.dismissTransient()
        }
        switch ChatComposerKey.action(code: code, modifiers: modifiers, hasCandidates: !matches.isEmpty, text: text, inThread: model.threadRoot != nil) {
        case .send: send()
        case .editLast: return model.editLastMessage(root: root, composerText: text)
        case .nextCandidate: selected = (selected + 1) % matches.count
        case .previousCandidate: selected = (selected + matches.count - 1) % matches.count
        case .chooseCandidate: choose(matches[min(selected, matches.count - 1)])
        case .dismissCandidates: dismissedQuery = token?.query
        case .closeThread:
            model.dismissTransient()
        case .native: return false
        }
        return true
    }

    private var recipient: String { root == nil ? "Message in #\(card?.name ?? "channel")" : "Reply in thread" }
    private var canSend: Bool { version != nil && ChatChannelModel.textProblem(text) == nil && (mentionOnly || called.isEmpty || !tooMuchContext) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(recipient)
                Spacer()
                if !text.isEmpty { Label("Draft", systemImage: "pencil").font(Theme.display(9)) }
            }.font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
            VStack(spacing: 0) {
                if formatting { ChatFormattingBar(control: control) }
                ChatMentionEditor(text: Binding(get: { text }, set: { changed($0) }), selection: $selection, candidates: candidates,
                                  autofocus: root != nil, navigationTarget: root == nil && draftLoaded ? ChannelRef(model.key, channel: model.channel) : nil,
                                  control: control,
                                  heightChanged: { if editorHeight != $0 { editorHeight = $0 } }, placeholder: recipient,
                                  accessibilityName: recipient,
                                  suggestions: .init(sections: sections, selected: min(selected, max(0, matches.count - 1)),
                                                     title: "Mention in \(root == nil ? "channel" : "thread")", choose: choose),
                                  key: { key($0, $1) })
                    .frame(height: editorHeight)
                    .accessibilityLabel(recipient)
                HStack(spacing: 2) {
                    ChatIconButton(title: "Insert emoji", symbol: "face.smiling", action: control.emoji)
                    ChatIconButton(title: "Mention a person or agent", symbol: "at") { control.insert("@") }
                    Button("Aa") { formatting.toggle() }.buttonStyle(.plain).frame(width: 28, height: 28)
                        .help("Show formatting").accessibilityLabel("Show formatting").accessibilityValue(formatting ? "Shown" : "Hidden").chatFocusRing()
                    Spacer()
                    Button(action: send) { Image(systemName: "paperplane.fill").frame(width: 32, height: 28) }
                        .buttonStyle(.plain).foregroundStyle(canSend ? ChatAppearance.surface : ChatAppearance.secondary)
                        .background(canSend ? ChatAppearance.accent : Theme.chromeSelection, in: RoundedRectangle(cornerRadius: 5))
                        .disabled(!canSend).help("Send (⌘↩)").accessibilityLabel("Send").chatFocusRing()
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }
            .background(ChatAppearance.composerSurface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(control.focused ? ChatAppearance.accent : ChatAppearance.border, lineWidth: control.focused ? 2 : 1))
            agentContext
            if let problem = model.problem { Text(problem).foregroundStyle(ChatAppearance.failure).font(Theme.display(11)).textSelection(.enabled) }
            HStack {
                if text.utf8.count > ChatChannelModel.maxBytes * 3 / 4 {
                    Text("\(text.utf8.count) / \(ChatChannelModel.maxBytes) bytes").foregroundStyle(ChatAppearance.failure)
                }
                Spacer()
                Text("⌘↩ Send · Return for a new line")
            }.font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary)
        }
        .padding(.horizontal, root == nil ? 24 : 16).padding(.top, 10).padding(.bottom, 12)
        .background(ChatAppearance.surface)
        .onChange(of: model.problem) { _, problem in
            if let problem, control.focused { ChatAccessibility.announce(problem, in: control.view) }
        }
        .onChange(of: selected) { _, value in
            if control.focused, matches.indices.contains(value) {
                ChatAccessibility.announce(matches[value].accessibilityName, in: control.view)
            }
        }
        .onChange(of: model.focusRequest) { _, request in
            if request?.area == .composer, root == model.threadRoot { control.focus() }
        }
        .task(id: root ?? "") {
            let draft = model.composerDraft(root: root)
            text = draft.text; version = draft.version
            contextIds = draft.contextIds; mentionOnly = draft.mentionOnly
            selection = NSRange(location: (text as NSString).length, length: 0)
            selected = 0; dismissedQuery = nil
            draftLoaded = true
        }
        .sheet(isPresented: $choosingContext) {
            VStack(alignment: .leading) {
                Text("Context for the agent").font(.headline)
                Text("Your question and the undeleted thread root are included. Choose additional messages.").font(.caption)
                List(model.contextCandidates(root: root ?? "").filter { $0.messageId != root }) { message in
                    Toggle(String(message.text.prefix(160)), isOn: Binding(get: { contextIds.contains(message.messageId) }, set: { on in
                        if on { contextIds.insert(message.messageId) } else { contextIds.remove(message.messageId) }
                        saveDraft()
                    }))
                }
                Text("\(contextCount) / 20 messages · \(contextBytes) / 49152 bytes\(tooMuchContext ? " — reduce the selection before sending" : "")")
                    .font(.caption).foregroundStyle(tooMuchContext ? .red : .secondary)
                Button("Done") { choosingContext = false }
            }.padding(16).frame(width: 480, height: 340)
        }
    }

    @ViewBuilder private var agentContext: some View {
            if !called.isEmpty {
                Toggle("Only mention — don't request an answer", isOn: Binding(get: { mentionOnly }, set: {
                    mentionOnly = $0; saveDraft()
                })).font(.caption)
                if !mentionOnly {
                    ForEach(called) { agent in
                        Text("\(agent.name): \(mode(agent))").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Context…") { choosingContext = true }.buttonStyle(.link)
                        Text("\(contextCount) / 20 messages · \(contextBytes) / 49152 bytes")
                            .foregroundStyle(tooMuchContext ? .red : .secondary)
                    }.font(.caption)
                }
            }
            ChatAgentMembershipHint(model: model, text: text)
    }

    private func mode(_ agent: ChatChannelAgent) -> String {
        return model.service.channelCallIsAutomatic(model.key, channel: model.channel, agent: agent)
            ? "will start and publish automatically" : "waits for a decision on the executor Mac"
    }
}
