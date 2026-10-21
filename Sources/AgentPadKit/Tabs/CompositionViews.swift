import SwiftUI
import UniformTypeIdentifiers

struct PersonalAskTab: View {
    @Bindable var state: TabState
    @Bindable var model: PersonalAskModel
    var body: some View {
        VStack(spacing: 0) {
            PopupScrollBody {
                VStack(alignment: .leading, spacing: 16) {
                if model.readable {
                    if let request = model.sentRequest {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark").font(.system(size: 22, weight: .semibold)).foregroundStyle(.green)
                                .frame(width: 45, height: 45)
                                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                            Text("Sent — Open request").font(Theme.display(18, weight: .semibold)).padding(.top, 6)
                            Text(model.actions.map { "Request sent to \($0.agent.name)." } ?? "Request sent.")
                                .font(Theme.display(11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 20)
                        Text(request.text ?? model.prompt).textSelection(.enabled)
                            .font(Theme.display(12)).fixedSize(horizontal: false, vertical: true)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.chromeMuted.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.chromeMuted.opacity(0.2)))
                        Text(request.state.meaning ?? request.state.rawValue).font(Theme.display(11)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("personalAskProgress")
                        Text("Follow progress and the answer in the request. Closing this receipt does not cancel it.")
                            .font(.caption).foregroundStyle(.secondary)
                        if request.state == .finished, let text = request.localText ?? request.result?.shownText {
                            Text(ChatMarkdownText.attributed(text)).textSelection(.enabled)
                            Button("Copy as Markdown") { model.copy(request) }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.actions.map { "Ask \($0.agent.name)" } ?? "Ask agent").font(Theme.display(18, weight: .semibold))
                            Text("A personal request. Only the participants can read it.").font(Theme.display(11)).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Personal question").font(Theme.display(11)).foregroundStyle(.secondary)
                            TextEditor(text: $model.prompt).font(Theme.display(12)).frame(height: 104)
                                .scrollContentBackground(.hidden).accessibilityLabel("Personal question")
                                .accessibilityIdentifier("personalAskPrompt")
                                .padding(6).background(Theme.chromeMuted.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.chromeMuted.opacity(0.2)))
                        }.padding(.top, 4)
                    }
                    if let problem = model.problem { Text(problem).foregroundStyle(.red) }
                } else { Text("Connect to this organization and wait for access to be checked.").foregroundStyle(.secondary) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if model.sentRequest != nil {
                    Button("Close") { model.closeReceipt() }.accessibilityIdentifier("personalAskClose")
                    Spacer()
                    Button("Open request") { model.openRequest() }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("personalAskOpenRequest")
                } else {
                    Spacer()
                    Button("Cancel") { model.tabs.cancel(state) }.accessibilityIdentifier("personalAskCancel")
                    Button("Send request") { model.send() }.buttonStyle(.borderedProminent).disabled(!model.canSend)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("personalAskSend")
                }
            }.padding(.horizontal, 20).padding(.vertical, 13)
        }.task(id: "\(ChatOrgCurrent.identity(model.tabs.chat) ?? "")|\(model.readable)") { model.follow() }
            .accessibilityIdentifier("personalAskForm")
    }
}

struct NewChannelTab: View {
    @Bindable var model: NewChannelModel
    var body: some View {
        VStack(spacing: 0) {
          PopupScrollBody {
            VStack(alignment: .leading, spacing: 14) {
                Text("New channel").font(.title3.weight(.semibold))
                if model.readable {
                    Text(model.teamName + " · " + (model.model?.orgName ?? model.key.orgId))
                        .font(.callout).foregroundStyle(.secondary)
                    Text("The team's members, including future members, can read and write here.").font(.callout).foregroundStyle(.secondary)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                    Text("Channel name").font(.callout).foregroundStyle(.secondary)
                    TextField("Channel name", text: $model.fields.name).textFieldStyle(.roundedBorder).disabled(model.fields.submitted)
                        .accessibilityIdentifier("newChannelName")
                    if let problem = model.problem { Text(problem).foregroundStyle(.red) }
                } else { Text("Connect to this organization and wait for access to be checked.") }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
          }
          Divider()
          HStack {
              Spacer()
              Button("Cancel") { model.cancel() }.accessibilityIdentifier("newChannelCancel")
              Button(model.fields.submitted ? "Creating…" : "Create channel") { model.create() }
                  .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                  .disabled(!model.canCreate).accessibilityIdentifier("newChannelCreate")
          }.padding(.horizontal, 20).padding(.vertical, 13)
        }.onChange(of: model.model?.view, initial: true) { _, _ in model.reconcile() }
            .accessibilityIdentifier("newChannelForm")
    }
}

struct AgentTab: View {
    let state: TabState
    let tabs: CompositionTabs
    var body: some View {
        if case .agent(let key, let id) = state.route,
           let model = tabs.orgModel(), model.key == key.chatKey,
           let owner = tabs.owner(state), ChatAttention.personalAllowed(key.chatKey, tabs.chat) {
            VStack(spacing: 0) {
                PopupScrollBody {
                    ChatSidebarAgentCard(agentID: id, active: state.navigation.anchor.map { ChannelRef(key.chatKey, channel: $0) },
                        window: owner.store.popups.window, store: owner.store, model: model)
                }
                Divider()
                HStack { Spacer(); Button("Done") { tabs.complete(state) }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("publishedAgentDone") }.padding(.horizontal, 20).padding(.vertical, 13)
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
                AgentAnswerForwardView(model: model, save: save, cancel: { tabs.cancel(state) })
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
