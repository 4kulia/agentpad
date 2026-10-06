import SwiftUI

struct ChatUX1Composer: View {
    let model: ChatChannelModel
    let root: String?
    let members: [ChatOrgView.Member]
    let mentionable: [(account: String, handle: String)]
    let agents: [ChatChannelAgent]
    @State private var text = ""
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var version: String?
    @State private var mentionOnly = false
    @State private var selected = 0
    @State private var dismissedQuery: String?
    @State private var contextIds = Set<String>()
    @State private var choosingContext = false

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
    private var matches: [ChatMentionCandidate] {
        guard selection.length == 0, let token, dismissedQuery != token.query else { return [] }
        return Array(ChatMentionCandidate.filtered(candidates, query: token.query).prefix(8))
    }
    private var called: [ChatChannelAgent] { ChatMentions.agents(in: text, agents: agents) }
    private var context: [ChatMessage] { model.contextCandidates(root: root ?? "").filter { contextIds.contains($0.messageId) && $0.messageId != root } }
    private var contextBytes: Int { text.utf8.count + context.reduce(0) { $0 + $1.text.utf8.count } + (root.flatMap(model.message)?.text.utf8.count ?? 0) }
    private var contextCount: Int { context.count + (root == nil ? 1 : 2) }
    private var tooMuchContext: Bool { contextCount > 20 || contextBytes > 48 * 1024 }

    private func changed(_ value: String) {
        text = value
        model.saveDraft(value, root: root)
        version = model.draftVersion(root: root)
        selected = 0
        dismissedQuery = nil
    }
    private func send() {
        guard let version, mentionOnly || called.isEmpty || !tooMuchContext else { return }
        if model.send(text, root: root, members: mentionable, agents: agents, draftVersion: version, mentionOnly: mentionOnly, context: context) {
            text = ""; self.version = nil; selection = NSRange(location: 0, length: 0); contextIds = []; mentionOnly = false
        }
    }
    private func choose(_ candidate: ChatMentionCandidate) {
        guard let token else { return }
        let inserted = "@\(candidate.address) "
        changed((text as NSString).replacingCharacters(in: token.range, with: inserted))
        selection = NSRange(location: token.range.location + (inserted as NSString).length, length: 0)
        if candidate.addToChannel, let id = candidate.agentId { add(id) }
    }
    private func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        if code == 36 && modifiers.contains(.command) { send(); return true }
        if code == 126, modifiers.intersection([.command, .control, .option, .shift]).isEmpty, text.isEmpty {
            return model.editLastMessage(root: root, composerText: text)
        }
        guard !matches.isEmpty else { return false }
        switch code {
        case 125: selected = (selected + 1) % matches.count
        case 126: selected = (selected + matches.count - 1) % matches.count
        case 36, 48: choose(matches[min(selected, matches.count - 1)])
        case 53: dismissedQuery = token?.query
        default: return false
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, candidate in
                        Button { choose(candidate) } label: {
                            HStack {
                                Text(candidate.label).fontWeight(.medium)
                                Text("@\(candidate.address)").foregroundStyle(.secondary)
                                Spacer()
                                if candidate.addToChannel { Text("Add to channel").font(.caption) }
                            }.padding(6).background(index == selected ? Color.accentColor.opacity(0.15) : .clear)
                        }.buttonStyle(.plain).help("@\(candidate.address)")
                    }
                }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            }
            ChatMentionEditor(text: Binding(get: { text }, set: { changed($0) }), selection: $selection, candidates: candidates,
                              key: { key($0, $1) })
                .frame(minHeight: 50, maxHeight: 130)
            if !called.isEmpty {
                Toggle("Only mention — don't request an answer", isOn: $mentionOnly).font(.caption)
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
            ForEach(outsideMentions, id: \.agentId) { agent in
                HStack {
                    Text("\(agent.name): agent is not in this channel.")
                    if agent.ownerAccountId == model.key.accountId { Button("Add…") { add(agent.agentId) } }
                    else { Text("Its owner must add it.") }
                }.font(.caption)
            }
            HStack {
                if let problem = model.problem { Text(problem).foregroundStyle(.red).font(.caption) }
                Spacer()
                Text("\(text.utf8.count) / \(ChatChannelModel.maxBytes) bytes").foregroundStyle(.secondary).font(.caption)
                Button("Send") { send() }.disabled(version == nil || ChatChannelModel.textProblem(text) != nil || !mentionOnly && !called.isEmpty && tooMuchContext)
            }
        }.padding(8)
        .task(id: root ?? "") {
            text = model.draft(root: root); version = model.draftVersion(root: root)
            selection = NSRange(location: (text as NSString).length, length: 0)
        }
        .sheet(isPresented: $choosingContext) {
            VStack(alignment: .leading) {
                Text("Context for the agent").font(.headline)
                Text("Your question and the undeleted thread root are included. Choose additional messages.").font(.caption)
                List(model.contextCandidates(root: root ?? "").filter { $0.messageId != root }) { message in
                    Toggle(String(message.text.prefix(160)), isOn: Binding(get: { contextIds.contains(message.messageId) }, set: { on in
                        if on { contextIds.insert(message.messageId) } else { contextIds.remove(message.messageId) }
                    }))
                }
                Text("\(contextCount) / 20 messages · \(contextBytes) / 49152 bytes\(tooMuchContext ? " — reduce the selection before sending" : "")")
                    .font(.caption).foregroundStyle(tooMuchContext ? .red : .secondary)
                Button("Done") { choosingContext = false }
            }.padding(16).frame(width: 480, height: 340)
        }
    }

    private func mode(_ agent: ChatChannelAgent) -> String {
        return model.service.channelCallIsAutomatic(model.key, channel: model.channel, agent: agent)
            ? "will start and publish automatically" : "waits for a decision on the executor Mac"
    }
    private var outsideMentions: [ChatAgentCard] {
        guard org?.agentsVisible == true, let store = model.service.orgSessions[model.key]?.store else { return [] }
        let there = Set(agents.map(\.agentId))
        return ((try? store.calls.catalog()) ?? []).filter { agent in
            !there.contains(agent.agentId) && members.first(where: { $0.accountId == agent.ownerAccountId })
                .map { ChatMentions.contains("\(agent.name)@\($0.handle)", in: text) } == true
        }
    }
    private func add(_ id: String) {
        guard let org, let card, let agent = org.addableAgents(card).first(where: { $0.agentId == id }) else { return }
        let message = ChatOrgSidebarSection.addAgentText(agent, team: org.channelTeam(card)?.name ?? "this channel",
            fromSession: model.service.localAgent(id)?.isSession == true)
        Task { @MainActor in
            guard await ChatOrgWindow.confirm("Add \(agent.name) to #\(card.name)?", message, "Add", while: {
                org.isCurrent() && org.addableAgents(card).contains { $0.agentId == id }
            }) else { return }
            try? org.addAgent(id, to: card)
        }
    }
}
