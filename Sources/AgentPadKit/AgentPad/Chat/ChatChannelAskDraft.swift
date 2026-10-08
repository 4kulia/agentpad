import Foundation
import GRDB

struct ChannelAskDraft: Codable, Equatable {
    var offer: ChatChannelAsk.Offer
    var text: String
    var chosen: Set<String>
    var requestID = UUID().uuidString.lowercased()
    var submitted = false
}

@MainActor @Observable
final class ChannelAskModel {
    private weak var model: ChatChannelModel?
    var fields: ChannelAskDraft { didSet { save() } }
    var problem: String?
    var expanded = true
    let replacement: ConfirmationCoordinator
    private var saved: Bool
    init(model: ChatChannelModel, fields: ChannelAskDraft, saved: Bool = false) {
        self.model = model; self.fields = fields; self.saved = saved
        replacement = model.confirmation ?? ConfirmationCoordinator()
    }
    private var stillStored: Bool {
        guard saved else { return true }
        guard let model, let store = model.service.orgSessions[model.key]?.store else { return false }
        return (try? ChatCompositionDrafts.read(ChannelAskDraft.self, id: "channel-ask:" + model.channel, store: store))?.requestID == fields.requestID
    }
    var candidates: [ChatMessage] { model?.contextCandidates(root: fields.offer.root) ?? [] }
    var fit: (taken: [ChatMessage], cut: [ChatMessage]) { ChatChannelAsk.fit(candidates.filter { fields.chosen.contains($0.id) }, root: fields.offer.root) }
    var alreadySent: Bool {
        guard stillStored, let model, let store = model.service.orgSessions[model.key]?.store else { return true }
        return fields.submitted || (try? store.outbox.commands().contains { ChatService.args($0)["request_id"]?.string == fields.requestID }) == true
    }
    func save() {
        guard let model, model.service.channelAgentAllowed(model.key, channel: model.channel), let store = model.service.orgSessions[model.key]?.store else { return }
        guard stillStored else { problem = "The saved question is no longer available."; return }
        do { try ChatCompositionDrafts.save(fields, id: "channel-ask:" + model.channel, channel: model.channel, store: store); saved = true; problem = nil }
        catch { problem = error.localizedDescription }
    }
    func send(agents: [ChatChannelAgent]) {
        guard !alreadySent, let model, model.service.channelAgentAllowed(model.key, channel: model.channel) else { return }
        save(); guard problem == nil else { return }
        problem = model.ask(fields.offer, text: fields.text, context: fit.taken, agents: agents, requestID: fields.requestID)
        if problem == nil { fields.submitted = true; expanded = false }
    }
    func offerReplacement(_ offer: ChatChannelAsk.Offer) {
        expanded = true
        guard offer.id != fields.offer.id, let model else { return }
        let original = fields
        replacement.request(.init(tabID: model.tabID ?? UUID(), targetID: "channel-ask:" + model.channel,
            scope: OrgKey(model.key), revision: original.requestID),
            title: "Replace saved channel question?",
            consequences: "Your saved question and selected context will be replaced with the question for \(offer.address):\n\n\(offer.text)",
            verb: "Replace draft", destructive: true, cancelTitle: "Keep draft",
            stillValid: { [weak self, weak model] in
                guard let self, let model, model.service.channelAgentAllowed(model.key, channel: model.channel),
                      let store = model.service.orgSessions[model.key]?.store else { return false }
                return model.channelAsk === self && self.fields == original && !self.alreadySent
                    && (try? ChatCompositionDrafts.read(ChannelAskDraft.self, id: "channel-ask:" + model.channel, store: store)) == original
            }) { [weak self, weak model] in
                guard let self, let model, let store = model.service.orgSessions[model.key]?.store else { throw ChatError.notConnected }
                let next = ChannelAskDraft(offer: offer, text: offer.text, chosen: offer.ux1 ? [offer.root, offer.messageId] : [offer.root])
                try ChatCompositionDrafts.save(next, id: "channel-ask:" + model.channel, channel: model.channel, store: store)
                self.fields = next
            }
    }
}

extension ChatChannelModel {
    func beginAsk(_ offer: ChatChannelAsk.Offer) {
        guard restoreAsk() else { return }
        if let channelAsk, !channelAsk.alreadySent { channelAsk.offerReplacement(offer); return }
        let fields = ChannelAskDraft(offer: offer, text: offer.text, chosen: offer.ux1 ? [offer.root, offer.messageId] : [offer.root])
        channelAsk = ChannelAskModel(model: self, fields: fields); channelAsk?.save()
    }
    @discardableResult func restoreAsk() -> Bool {
        guard service.channelAgentAllowed(key, channel: channel), let store = service.orgSessions[key]?.store else { return false }
        do {
            if let fields = try ChatCompositionDrafts.read(ChannelAskDraft.self, id: "channel-ask:" + channel, store: store),
               channelAsk == nil || channelAsk?.fields.requestID != fields.requestID {
                channelAsk = ChannelAskModel(model: self, fields: fields, saved: true)
                channelAsk?.expanded = !fields.submitted
            }
            return true
        } catch { attachmentProblem(error); return false }
    }
}
