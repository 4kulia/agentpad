import SwiftUI

/// Above the composer (DESIGN-F5 §2): "Ask" offers after the user's own
/// messages named an agent of the channel, and the asks on their way or
/// refused. Shown only with the channel (F2 "ready"); an offer whose agent
/// left the channel is not shown.
struct ChatAskStrip: View {
    let model: ChatChannelModel
    let agents: [ChatChannelAgent]
    @State private var asking: ChatChannelAsk.Offer?

    private func name(_ agentId: String) -> String {
        agents.first { $0.agentId == agentId }.map { $0.address ?? $0.name } ?? "the agent"
    }

    var body: some View {
        let offers = model.offers.filter { offer in agents.contains { $0.agentId == offer.agentId } }
        if !offers.isEmpty || !model.asks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(offers) { offer in
                    HStack {
                        Text("You named \(offer.address).").font(.callout)
                        Spacer()
                        Button("Ask \(offer.address)…") { asking = offer }
                        Button("Dismiss") { model.dismissOffer(offer) }.buttonStyle(.link)
                    }
                }
                ForEach(model.asks) { asked in
                    HStack {
                        if asked.failed {
                            Text("Not asked \(name(asked.agentId)): \(ChatChannelAsk.reason(asked.error))").foregroundStyle(.orange).font(.callout)
                            Spacer()
                            if let root = asked.root, agents.contains(where: { $0.agentId == asked.agentId }) {
                                Button("Ask Again…") {
                                    asking = .init(messageId: root, agentId: asked.agentId, address: name(asked.agentId), text: asked.text, root: root)
                                    model.dismissAsk(asked)
                                }
                            }
                            Button("Dismiss") { model.dismissAsk(asked) }.buttonStyle(.link)
                        } else {
                            Text("Asking \(name(asked.agentId))…").foregroundStyle(.secondary).font(.callout)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .sheet(item: $asking) { offer in
                ChatAskSheet(model: model, offer: offer, agents: agents) { asking = nil }
            }
        }
    }
}

/// "Ask <agent>": the request's text, and the messages given as context —
/// the thread's root first; what the limits cut shows before it is sent.
struct ChatAskSheet: View {
    let model: ChatChannelModel
    let offer: ChatChannelAsk.Offer
    let agents: [ChatChannelAgent]
    let close: () -> Void
    @State private var text = ""
    @State private var candidates: [ChatMessage] = []
    @State private var chosen: Set<String> = []
    @State private var problem: String?

    private var fit: (taken: [ChatMessage], cut: [ChatMessage]) {
        ChatChannelAsk.fit(candidates.filter { chosen.contains($0.messageId) }, root: offer.root)
    }

    var body: some View {
        let fit = fit
        let cut = Set(fit.cut.map(\.messageId))
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask \(offer.address)").font(.headline)
            Text("The agent's owner decides on their Mac whether it runs, and whether its answer is published here.")
                .foregroundStyle(.secondary).font(.callout)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
            Text("Context: \(fit.taken.count) of at most \(ChatChannelAsk.maxContext) messages, "
                 + "\(fit.taken.reduce(0) { $0 + $1.text.utf8.count } / 1024) of \(ChatChannelAsk.maxContextBytes / 1024) KiB")
                .font(.caption).foregroundStyle(.secondary)
            List(candidates) { m in
                Toggle(isOn: Binding(get: { chosen.contains(m.messageId) },
                                     set: { if $0 { chosen.insert(m.messageId) } else { chosen.remove(m.messageId) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.text).lineLimit(2)
                        if cut.contains(m.messageId) { Text("does not fit: left out").font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
            .frame(minHeight: 160)
            if let problem { Text(problem).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Ask") {
                    // Read again: the root may be the server's only now, and each revision is the current one.
                    candidates = model.contextCandidates(root: offer.root)
                    problem = model.ask(offer, text: text, context: candidates.filter { chosen.contains($0.messageId) }, agents: agents)
                    if problem == nil { close() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ChatChannelAsk.textProblem(text) != nil)
            }
        }
        .padding(16)
        .frame(width: 480)
        .onAppear {
            text = offer.text
            candidates = model.contextCandidates(root: offer.root)
            chosen = [offer.root]
        }
        // The agent gone from the channel: the sheet closes, keeping nothing.
        .onChange(of: agents.contains { $0.agentId == offer.agentId }) { _, there in if !there { close() } }
    }
}
