import SwiftUI

struct RequestTabView: View {
    @Bindable var state: TabState
    @Bindable var model: RequestTabModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Request").font(.title2)
                if model.readable {
                    if let request = model.request { serverRequest(request) }
                    else if let call = model.incoming {
                        Text("\(call.peerName) → \(call.agentName)").font(.headline)
                        Text(TeamCallsSidebar.word(call.state, serverState: call.serverState, activity: call.activity))
                        Text(TeamPanelSection.details(call, agent: model.calls.localAgent(for: call)))
                        Text(call.prompt).textSelection(.enabled)
                    } else if let call = model.outgoing {
                        Text("You → \(call.address)").font(.headline)
                        Text(TeamCallsSidebar.word(call.report.state, serverState: call.serverState, activity: call.report.activity))
                        Text(call.prompt).textSelection(.enabled)
                    }
                    if let activity = model.activity { Text(activity).foregroundStyle(.secondary).textSelection(.enabled) }
                    if model.canDecide {
                        TextField("Reason for declining (optional)", text: $model.reason, axis: .vertical)
                        HStack {
                            Button("Decline…") { model.confirm(.decline) }
                            Button("Allow…") { model.confirm(.allow) }
                                .disabled(!model.canAllow)
                        }.disabled(state.confirmation.showsBlock)
                    }
                    if let text = model.result {
                        Text(model.resultTitle).font(.headline)
                        Text(verbatim: text).textSelection(.enabled)
                        Button("Copy as Markdown") { model.copyResult(expected: text) }
                    }
                    if model.request?.kind == "channel", model.request?.state == .awaitingDecision, model.request?.onThisDevice == true {
                        Button("Reload context") { Task { await model.load() } }.disabled(model.loading)
                    }
                    if let key = model.key, model.request?.kind == "channel" {
                        if model.request?.publication == "awaiting_publish",
                           let issue = model.chat.channelPublicationIssue(key, requestId: model.id) { Text(issue).foregroundStyle(.secondary) }
                        if model.request?.publication == "awaiting_publish", model.chat.channelPreview(key, requestId: model.id) != nil {
                            if let problem = model.chat.channelPublishProblem(key, requestId: model.id) { Text(problem).foregroundStyle(.orange) }
                            HStack {
                                Button("Don't Publish…") { model.confirm(.withhold) }
                                Button("Publish…") { model.confirm(.publish) }
                                    .disabled(model.chat.channelPublishProblem(key, requestId: model.id) != nil)
                            }.disabled(state.confirmation.showsBlock || model.chat.channelPublicationInFlight(key, requestId: model.id) != nil)
                        }
                        if model.channelModel?.canOpenSession(model.id) == true {
                            Button("Continue…") { state.message = model.channelModel?.openSession(model.id) }
                        }
                    }
                    if let ready = model.tabs.versions.admissions[model.id] {
                        Text("Claude Code: \(ready.version) · \(ready.basis)\nExecutable: \(ready.executable.file.resolvedPath)").textSelection(.enabled)
                    }
                    ForEach(model.versions) { item in
                        Text(item.message).textSelection(.enabled)
                        Text("Selected: \(item.executable.selectedPath)\nExecutable: \(item.executable.file.resolvedPath)").textSelection(.enabled)
                        HStack {
                            Button(item.allowTitle) { model.confirm(.version(item.id, true)) }
                            Button(ClaudeVersionApprovals.Pending.declineTitle) { model.confirm(.version(item.id, false)) }
                        }.disabled(state.confirmation.showsBlock)
                    }
                    ForEach(model.folders) { folder in
                        Text("Folder requested: \(folder.path)").textSelection(.enabled)
                        Text(folder.reason)
                        HStack {
                            Button("Deny folder…") { model.confirm(.folder(folder.id, .denied)) }
                            Button("Allow folder once…") { model.confirm(.folder(folder.id, .once)) }
                            if model.scope == .local {
                                Button("Always allow folder…") { model.confirm(.folder(folder.id, .always)) }
                            }
                        }.disabled(state.confirmation.showsBlock)
                    }
                    controls
                    if let message = state.message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                    if model.loading { ProgressView("Loading verified context…") }
                } else {
                    Text("Connect to this organization and wait for access to this request to be checked.").foregroundStyle(.secondary)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(model.chat.connection?.sessionId ?? "")|\(model.request?.version ?? 0)") { await model.load() }
        .attentionPlace(model.readable ? Set(destinations) : [])
        .accessibilityIdentifier("request-tab")
    }

    private var destinations: [AttentionDestination] {
        let request: AttentionDestination = model.request?.channelId.map { .channel($0, request: model.id) }
            ?? .team(request: model.id, outgoing: model.incoming == nil)
        return [request] + model.folders.map { .folder($0.id, request: model.id) } + model.versions.map { .version($0.id) }
    }

    @ViewBuilder private func serverRequest(_ request: ChatRequest) -> some View {
        Text(request.agentName ?? "Agent").font(.headline)
        Text(request.state.rawValue.replacingOccurrences(of: "_", with: " "))
        if let publication = request.publication {
            Text(publication.replacingOccurrences(of: "_", with: " "))
            if let reason = request.publishReason { Text(ChatChannelRequests.reason(reason)).foregroundStyle(.orange) }
        }
        if let why = request.failureReason ?? request.declineReason { Text(why).textSelection(.enabled) }
        if let key = model.key { ClaudeLaunchHelpView(key: key, request: model.id, service: model.chat) }
        if let terms = model.channelModel?.decisionText(request) { Text(terms).textSelection(.enabled) }
        else {
            Text("Executor: \(request.executorDeviceName ?? "executor Mac")\nDeadline: \(request.deliverBy ?? "unknown")")
            Text(request.kind == "channel"
                ? "Audience: current and future members of the channel's team see the answer if it is published."
                : "Audience: the requester and the agent's owner.")
            if let call = model.incoming { Text(TeamPanelSection.details(call, agent: model.calls.localAgent(for: call))) }
        }
        Text(ChatMarkdownText.attributed(request.text ?? "")).textSelection(.enabled)
        if request.ownerAccountId == model.key?.accountId, !request.onThisDevice {
            Text("The decision is made on \(request.executorDeviceName ?? "the executor Mac").").foregroundStyle(.secondary)
        }
        if let content = model.channelModel?.content(request) {
            ForEach(content.attachments ?? []) { item in
                Label("\(item.file.name) · \(item.file.sizeText) · \(item.file.mime)", systemImage: item.file.isImage ? "photo" : "doc")
            }
            ForEach(content.context ?? [], id: \.messageId) { message in
                Text("\(model.channelModel?.name(message.authorAccountId) ?? "Member") · revision \(message.revision)").font(.caption)
                Text(ChatMarkdownText.attributed(message.text ?? "[Message deleted]")).textSelection(.enabled)
            }
        }
    }
    @ViewBuilder private var controls: some View {
        if model.canStop { Button("Stop") { model.stop() } }
        if let request = model.request, let key = model.key, request.kind == "channel" {
            if request.initiatorAccountId == key.accountId, ChatService.channelCancellationStates.contains(request.state) {
                Button("Cancel request") { state.message = model.chat.cancelChannelRequest(key, requestId: model.id) }
            }
        } else {
            if let call = model.incoming {
                if TeamUI.canWatch(call) { Button("Watch") { TeamUI.watch(call) } }
                if call.state == .done, !model.calls.refuses(call) {
                    Button("Continue…") { state.message = TeamUI.continueYourself(call) }
                }
            }
            if let call = model.outgoing, !call.report.state.isFinal, model.calls.refusal(.cancel, for: call) == nil {
                Button("Cancel request") { Task { _ = await model.calls.cancel(model.id) } }
            }
        }
    }
}
