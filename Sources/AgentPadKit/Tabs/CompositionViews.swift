import SwiftUI
import UniformTypeIdentifiers

struct PersonalAskTab: View {
    @Bindable var state: TabState
    @Bindable var model: PersonalAskModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.readable {
                    Text(model.actions.map { "Ask \($0.agent.name)" } ?? "Personal Ask").font(.title2)
                    Text("A personal request. Only the participants can read it.").foregroundStyle(.secondary)
                    if model.sentRequest != nil {
                        Text("Request sent. Its progress and answer appear below.")
                        Button("New question") { model.prompt = "" }
                    } else {
                        TextEditor(text: $model.prompt).frame(minHeight: 140).accessibilityLabel("Personal question")
                        Button("Send request") { model.send() }.disabled(!model.canSend)
                    }
                    if let problem = model.problem { Text(problem).foregroundStyle(.red) }
                    ForEach(model.history, id: \.requestId) { request in
                        Divider()
                        Text(request.text ?? "").textSelection(.enabled)
                        Text(request.state.rawValue).font(.caption).foregroundStyle(.secondary)
                        if request.state == .finished, let text = request.localText ?? request.result?.shownText {
                            Text(ChatMarkdownText.attributed(text)).textSelection(.enabled)
                            Button("Copy as Markdown") { model.copy(request) }
                        }
                        Button("Open request") { RequestTabs.shared.open(request.requestId, scope: .server(OrgKey(model.key))) }
                    }
                } else { Text("Connect to this organization and wait for access to be checked.").foregroundStyle(.secondary) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.task(id: "\(ChatOrgCurrent.identity(model.tabs.chat) ?? "")|\(model.readable)") { model.follow() }
    }
}

struct NewChannelTab: View {
    @Bindable var model: NewChannelModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("New channel").font(.title2)
                if model.readable {
                    Text("The team's members, including future members, can read and write here.").foregroundStyle(.secondary)
                    TextField("Channel name", text: $model.fields.name).disabled(model.fields.submitted)
                    Button(model.fields.submitted ? "Creating…" : "Create channel") { model.create() }.disabled(!model.canCreate)
                    Button("New draft") { model.newDraft() }
                    if let problem = model.problem { Text(problem).foregroundStyle(.red) }
                } else { Text("Connect to this organization and wait for access to be checked.") }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.onChange(of: model.model?.view, initial: true) { _, _ in model.reconcile() }
    }
}

struct AgentTab: View {
    let state: TabState
    let tabs: CompositionTabs
    var body: some View {
        if case .agent(let key, let id) = state.route,
           let model = tabs.orgModel(), model.key == key.chatKey,
           let owner = tabs.owner(state), ChatAttention.personalAllowed(key.chatKey, tabs.chat) {
            ScrollView {
                ChatSidebarAgentCard(agentID: id, active: state.navigation.anchor.map { ChannelRef(key.chatKey, channel: $0) },
                    window: nil, store: owner.store, model: model)
            }
        } else { Text("Connect to this organization and wait for access to be checked.").foregroundStyle(.secondary) }
    }
}

struct ForwardTab: View {
    let state: TabState
    let tabs: CompositionTabs
    var body: some View {
        if let model = tabs.forwardModel(state) {
            if model.readable {
                AgentAnswerForwardView(model: model, save: save)
            } else { Text("Connect to the snapshot's organization and wait for access to be checked.").foregroundStyle(.secondary) }
        } else { Text(state.message ?? "The saved answer could not be loaded.").foregroundStyle(.secondary) }
    }
    private func save() {
        guard let model = tabs.forwardModel(state), let owner = tabs.owner(state), let window = owner.session.engine.view.window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "agent-answer.md"
        let text = model.text, revision = state.revision
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, !state.isClosed, state.revision == revision,
                  tabs.owner(state)?.store === owner.store,
                  model.destination == nil || ChatAttention.personalAllowed(model.destination!.chatKey, tabs.chat) else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8); model.status = "Saved as Markdown." }
            catch { model.problem = "The file could not be saved. Choose another location and retry." }
        }
    }
}
