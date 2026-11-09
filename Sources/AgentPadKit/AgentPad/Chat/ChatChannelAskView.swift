import SwiftUI

/// Above the composer (DESIGN-F5 §2): "Ask" offers after the user's own
/// messages named an agent of the channel, and the asks on their way or
/// refused. Shown only with the channel (F2 "ready"); an offer whose agent
/// left the channel is not shown.
struct ChatAskStrip: View {
    let model: ChatChannelModel
    let agents: [ChatChannelAgent]

    private func name(_ agentId: String) -> String {
        agents.first { $0.agentId == agentId }.map { $0.address ?? $0.name } ?? "the agent"
    }

    var body: some View {
        let offers = model.offers.filter { offer in agents.contains { $0.agentId == offer.agentId } }
        VStack(alignment: .leading, spacing: 0) {
        if !offers.isEmpty || !model.asks.isEmpty || model.channelAsk != nil {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(offers) { offer in
                    HStack {
                        Text("You named \(offer.address).").font(.callout)
                            .chatMetadataParity("boundary/offer/" + offer.id + "/title", "text", text: "You named \(offer.address).",
                                colors: ["foreground": Theme.chromeForeground], font: .callout)
                        Spacer()
                        Button("Ask \(offer.address)…") { model.beginAsk(offer) }
                            .chatMetadataParity("boundary/offer/" + offer.id + "/ask", "text", text: "Ask \(offer.address)…",
                                colors: ["foreground": Theme.chromeForeground], font: .system(size: 13))
                        Button("Dismiss") { model.dismissOffer(offer) }.buttonStyle(.link)
                            .chatMetadataParity("boundary/offer/" + offer.id + "/dismiss", "text", text: "Dismiss",
                                colors: ["foreground": Theme.chromeForeground], font: .body)
                    }
                }
                ForEach(model.asks) { asked in
                    HStack {
                        if asked.failed {
                            Text("Not asked \(name(asked.agentId)): \(ChatChannelAsk.reason(asked.error))").foregroundStyle(.orange).font(.callout)
                                .chatMetadataParity("boundary/ask/" + asked.id + "/status", "text", text: "Not asked \(name(asked.agentId)): \(ChatChannelAsk.reason(asked.error))",
                                    colors: ["foreground": .orange], font: .callout)
                            Spacer()
                            if let root = asked.root, agents.contains(where: { $0.agentId == asked.agentId }) {
                                Button("Ask Again…") {
                                    model.beginAsk(.init(messageId: asked.source ?? root, agentId: asked.agentId, address: name(asked.agentId),
                                                   text: asked.source.flatMap(model.message)?.text ?? asked.text, root: root, ux1: asked.source != nil))
                                }
                                .chatMetadataParity("boundary/ask/" + asked.id + "/again", "text", text: "Ask Again…",
                                    colors: ["foreground": Theme.chromeForeground], font: .system(size: 13))
                            }
                            Button("Dismiss") { model.dismissAsk(asked) }.buttonStyle(.link)
                                .chatMetadataParity("boundary/ask/" + asked.id + "/dismiss", "text", text: "Dismiss",
                                    colors: ["foreground": Theme.chromeForeground], font: .body)
                        } else {
                            Text("Asking \(name(asked.agentId))…").foregroundStyle(.secondary).font(.callout)
                                .chatMetadataParity("boundary/ask/" + asked.id + "/status", "text", text: "Asking \(name(asked.agentId))…",
                                    colors: ["foreground": .secondary], font: .callout)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if let form = model.channelAsk, !form.alreadySent {
                if form.expanded { ChatAskInline(form: form, agents: agents) }
                else { Button("Edit saved channel question") { form.expanded = true }
                        .chatMetadataParity("boundary/ask/saved", "text", text: "Edit saved channel question",
                            colors: ["foreground": Theme.chromeForeground], font: .system(size: 13)) }
            }
        }
        }.task { model.restoreAsk() }
    }
}

/// The channel owns this draft and context independently of SwiftUI mounts.
struct ChatAskInline: View {
    @Bindable var form: ChannelAskModel
    let agents: [ChatChannelAgent]
    var body: some View {
        let fit = form.fit
        let cut = Set(fit.cut.map(\.messageId))
        VStack(alignment: .leading, spacing: 10) {
            if form.replacement.context?.targetID.hasPrefix("channel-ask:") == true {
                InlineConfirmation(coordinator: form.replacement)
            }
            Text("Ask \(form.fields.offer.address)").font(.headline)
                .chatMetadataParity("boundary/ask/title", "text", text: "Ask \(form.fields.offer.address)",
                    colors: ["foreground": Theme.chromeForeground], font: .headline)
            Text("This question and the selected context go to the agent. The answer is shared with this channel.").font(.callout).foregroundStyle(.secondary)
                .chatMetadataParity("boundary/ask/explanation", "text", text: "This question and the selected context go to the agent. The answer is shared with this channel.",
                    colors: ["foreground": .secondary], font: .callout)
            TextEditor(text: $form.fields.text).frame(minHeight: 70, maxHeight: 120)
                .disabled(form.fields.offer.ux1).accessibilityLabel("Channel question")
                .chatMetadataParity("boundary/ask/editor-frame", "control")
            Text("Context: \(fit.taken.count) / \(ChatChannelAsk.maxContext) messages").font(.caption)
                .chatMetadataParity("boundary/ask/context", "text", text: "Context: \(fit.taken.count) / \(ChatChannelAsk.maxContext) messages",
                    colors: ["foreground": Theme.chromeForeground], font: .caption)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(form.candidates) { message in
                        Toggle(isOn: Binding(get: { form.fields.chosen.contains(message.id) }, set: { on in
                            if on { form.fields.chosen.insert(message.id) } else { form.fields.chosen.remove(message.id) }
                        })) {
                            Text(message.text).lineLimit(2)
                                .chatMetadataParity("boundary/ask/context/" + message.id, "text", text: message.text,
                                    colors: ["foreground": Theme.chromeForeground], font: .body)
                            if cut.contains(message.id) { Text("Does not fit: left out").font(.caption).foregroundStyle(.orange) }
                        }.disabled(form.fields.offer.ux1 && [form.fields.offer.root, form.fields.offer.messageId].contains(message.id))
                    }
                }
            }.frame(maxHeight: 180)
            if let problem = form.problem { Text(problem).foregroundStyle(.red)
                    .chatMetadataParity("boundary/ask/problem", "text", text: problem, colors: ["foreground": .red], font: .body) }
            HStack {
                Button("Keep draft") { form.expanded = false }
                    .chatMetadataParity("boundary/ask/keep", "text", text: "Keep draft", colors: ["foreground": Theme.chromeForeground], font: .system(size: 13))
                Button("Ask") { form.send(agents: agents) }
                    .disabled(form.alreadySent || ChatChannelAsk.textProblem(form.fields.text) != nil || !agents.contains { $0.agentId == form.fields.offer.agentId })
                    .chatMetadataParity("boundary/ask/send", "text", text: "Ask", colors: ["foreground": Theme.chromeForeground], font: .system(size: 13))
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .onExitCommand { form.expanded = false }
    }
}
