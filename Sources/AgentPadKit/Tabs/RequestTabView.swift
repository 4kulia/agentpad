import SwiftUI

struct RequestTabView: View {
    @Bindable var state: TabState
    @Bindable var model: RequestTabModel

    var body: some View {
        VStack(spacing: 0) {
            content
            if model.readable && (model.canDecide || canReviewPublication || !model.folders.isEmpty) {
                Divider()
                decisionActions.padding(.horizontal, 24).padding(.vertical, 14)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Request decisions")
            }
        }
        .task(id: "\(model.chat.connection?.sessionId ?? "")|\(model.request?.version ?? 0)") { await model.load() }
        .attentionPlace(model.readable ? Set(destinations) : [])
        .accessibilityIdentifier("request-tab")
    }

    private var content: some View {
        PopupScrollBody {
            VStack(alignment: .leading, spacing: 16) {
                if !state.isPopup { Text("Request").font(.title2) }
                if model.readable {
                    identity
                    if !model.folders.isEmpty { folderContent }
                    else if canReviewPublication { publicationContent }
                    else { requestContent }
                    statusDetails
                    versionApprovals
                    controls
                    if let message = state.message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                    if model.loading { ProgressView("Loading verified context…") }
                } else {
                    Text("Connect to this organization and wait for access to this request to be checked.").foregroundStyle(.secondary)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var identity: some View {
        HStack(spacing: 10) {
            ContactAvatar(stableID: model.request?.agentId ?? model.incoming?.agentId.uuidString ?? model.id,
                name: agentName, kind: .agent, size: 32,
                remote: (model.request?.agentId).flatMap { .agent($0, model.key) }, service: model.chat)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(requesterName) → \(agentName)").font(.headline)
                Text(requestSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(status).font(.caption).foregroundStyle(.orange).lineLimit(2)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private var requestContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                if let executor { fact("Executor", executor) }
                if let deadline { fact("Deadline", readableDate(deadline)) }
                if let rights { fact("Rights", rights) }
            }
            note(audience)
            VStack(alignment: .leading, spacing: 10) {
                Text("Request").font(.headline)
                Text(ChatMarkdownText.attributed(model.request?.text ?? model.incoming?.prompt ?? model.outgoing?.prompt ?? ""))
                    .textSelection(.enabled)
                if let request = model.request, let content = model.channelModel?.content(request) {
                    context(content)
                }
                if model.request?.kind == "channel", model.request?.state == .awaitingDecision, model.request?.onThisDevice == true {
                    Button("Reload context") { Task { await model.load() } }.disabled(model.loading)
                }
            }
            if model.canDecide {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reason for declining (optional)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $model.reason)
                        .scrollContentBackground(.hidden).padding(6).frame(height: 54)
                        .background(Theme.chromeHover, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.chromeHairline))
                        .accessibilityLabel("Reason for declining (optional)")
                        .accessibilityIdentifier("request-decline-reason")
                }
                Text("Run the request with the context, executor and limits shown above. Claude Code version approval is separate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !runNotes.isEmpty { note(runNotes.joined(separator: "\n\n")) }
            if let text = model.result { result(text, title: model.resultTitle) }
            if !model.canDecide {
                Text("You can close this popup while waiting. Progress is available in Team activity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var folderContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(model.folders) { folder in
                VStack(alignment: .leading, spacing: 10) {
                    Text("Folder requested: \(folder.path)").font(.headline).textSelection(.enabled)
                    Text(folder.reason).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if model.scope == .local {
                note("Local scope. “Always allow” adds this folder to this agent for future calls.")
            }
            VStack(alignment: .leading, spacing: 10) {
                fact("Agent", agentName)
                if let access { fact("Access", access.title) }
                if let executor { fact("Executor", executor) }
            }
        }
    }

    private var publicationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let text = model.result { result(text, title: "Result preview") }
            note(audience)
            Text("Nothing is published by closing this preview.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func result(_ text: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(verbatim: text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10)))
            Button("Copy as Markdown") { model.copyResult(expected: text) }
        }
    }

    private func context(_ content: ChatChannelContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let count = content.context?.count ?? 0
            Text(count == 0 ? "Verified context" : "Verified context · \(count) \(count == 1 ? "message" : "messages")")
                .font(.subheadline.weight(.semibold))
            ForEach(content.attachments ?? []) { item in
                Label("\(item.file.name) · \(item.file.sizeText) · \(item.file.mime)", systemImage: item.file.isImage ? "photo" : "doc")
            }
            ForEach(content.context ?? [], id: \.messageId) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.channelModel?.name(message.authorAccountId) ?? "Member") · revision \(message.revision)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(ChatMarkdownText.attributed(message.text ?? "[Message deleted]")).textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10)))
    }

    @ViewBuilder private var statusDetails: some View {
        if let request = model.request {
            if let reason = request.publishReason { Text(ChatChannelRequests.reason(reason)).foregroundStyle(.orange) }
            if let why = request.failureReason ?? request.declineReason { Text(why).textSelection(.enabled) }
            if let key = model.key { ClaudeLaunchHelpView(key: key, request: model.id, service: model.chat) }
            if request.ownerAccountId == model.key?.accountId, !request.onThisDevice {
                Text("The decision is made on \(request.executorDeviceName ?? "the executor Mac").").foregroundStyle(.secondary)
            }
        }
        if let activity = model.activity { Text(activity).foregroundStyle(.secondary).textSelection(.enabled) }
        if let key = model.key, model.request?.kind == "channel" {
            if model.request?.publication == "awaiting_publish",
               let issue = model.chat.channelPublicationIssue(key, requestId: model.id) { Text(issue).foregroundStyle(.secondary) }
            if canReviewPublication,
               let problem = model.chat.channelPublishProblem(key, requestId: model.id) { Text(problem).foregroundStyle(.orange) }
            if model.channelModel?.canOpenSession(model.id) == true {
                Button("Continue…") { state.message = model.channelModel?.openSession(model.id) }
            }
        }
    }

    @ViewBuilder private var versionApprovals: some View {
        if let ready = model.tabs.versions.admissions[model.id] {
            Text("Claude Code: \(ready.version) · \(ready.basis)\nExecutable: \(ready.executable.file.resolvedPath)").textSelection(.enabled)
        }
        ForEach(model.versions) { item in
            Text(item.message).textSelection(.enabled)
            Text("Selected: \(item.executable.selectedPath)\nExecutable: \(item.executable.file.resolvedPath)").textSelection(.enabled)
            HStack {
                Button(item.allowTitle) { model.confirm(.version(item.id, true)) }
                Button(ClaudeVersionApprovals.Pending.declineTitle, role: .destructive) { model.confirm(.version(item.id, false)) }
                    .buttonStyle(PopupDestructiveButtonStyle())
            }.disabled(state.confirmation.showsBlock)
        }
    }

    private var canReviewPublication: Bool {
        guard let key = model.key, model.request?.kind == "channel",
              model.request?.publication == "awaiting_publish" else { return false }
        return model.chat.channelPreview(key, requestId: model.id) != nil
    }

    private var decisionActions: some View {
        VStack(spacing: 10) {
            if model.canDecide {
                HStack {
                    Button("Decline…", role: .destructive) { model.confirm(.decline) }
                        .buttonStyle(PopupDestructiveButtonStyle())
                        .accessibilityIdentifier("request-decline")
                    Spacer()
                    Button("Allow…") { model.confirm(.allow) }
                        .disabled(!model.canAllow)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityIdentifier("request-allow")
                }.disabled(state.confirmation.showsBlock)
            }
            if canReviewPublication, let key = model.key {
                HStack {
                    Button("Don't Publish…", role: .destructive) { model.confirm(.withhold) }
                        .buttonStyle(PopupDestructiveButtonStyle())
                    Spacer()
                    Button("Publish…") { model.confirm(.publish) }
                        .disabled(model.chat.channelPublishProblem(key, requestId: model.id) != nil)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityIdentifier("request-publish")
                }.disabled(state.confirmation.showsBlock || model.chat.channelPublicationInFlight(key, requestId: model.id) != nil)
            }
            ForEach(model.folders) { folder in
                if model.folders.count > 1 { Text(folder.path).font(.caption).lineLimit(1).truncationMode(.middle) }
                HStack {
                    Button("Deny folder…", role: .destructive) { model.confirm(.folder(folder.id, .denied)) }
                        .buttonStyle(PopupDestructiveButtonStyle())
                    if model.scope == .local {
                        Button("Always allow folder…") { model.confirm(.folder(folder.id, .always)) }
                    }
                    Spacer()
                    Button("Allow folder once…") { model.confirm(.folder(folder.id, .once)) }
                        .buttonStyle(.borderedProminent)
                }.disabled(state.confirmation.showsBlock)
            }
        }
    }

    private var destinations: [AttentionDestination] {
        let request: AttentionDestination = model.request?.channelId.map { .channel($0, request: model.id) }
            ?? .team(request: model.id, outgoing: model.incoming == nil)
        return [request] + model.folders.map { .folder($0.id, request: model.id) } + model.versions.map { .version($0.id) }
    }

    private var organization: ChatOrgView? {
        guard model.readable, let key = model.key, let store = model.chat.orgSessions[key]?.store else { return nil }
        return try? store.queue.read { try ChatOrgView.read($0) }
    }
    private var agent: TeamPublishedAgent? {
        model.request?.agentId.flatMap { model.chat.localAgent($0) } ?? model.incoming.flatMap { model.calls.localAgent(for: $0) }
    }
    private var agentName: String { model.request?.agentName ?? model.incoming?.agentName ?? model.outgoing?.agent ?? "Agent" }
    private var requesterName: String {
        if model.request?.initiatorAccountId == model.key?.accountId, model.key != nil { return "You" }
        if let call = model.incoming { return call.peerName }
        if let request = model.request {
            return organization?.members.first { $0.accountId == request.initiatorAccountId }?.name
                ?? model.channelModel?.name(request.initiatorAccountId) ?? "Requester"
        }
        return "You"
    }
    private var requestSubtitle: String {
        guard model.scope != .local else { return "Local request" }
        if let request = model.request, request.kind == "channel" {
            let view = organization
            if let channel = view?.channels.first(where: { $0.channelId == request.channelId }) {
                let team = view?.teams.first { $0.teamId == channel.teamId }?.name
                return "# \(channel.name)" + (team.map { " · \($0)" } ?? "")
            }
            return "Channel request"
        }
        return "Personal request · only the participants can read it."
    }
    private var status: String {
        if !model.folders.isEmpty { return "Folder access" }
        if let publication = model.request?.publication { return publication.replacingOccurrences(of: "_", with: " ").capitalized }
        if let request = model.request { return request.state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
        if let call = model.incoming { return TeamCallsSidebar.word(call.state, serverState: call.serverState, activity: call.activity).capitalized }
        if let call = model.outgoing { return TeamCallsSidebar.word(call.report.state, serverState: call.serverState, activity: call.report.activity).capitalized }
        return "Request"
    }
    private var executor: String? {
        if model.scope == .local { return "This Mac" }
        if let request = model.request, let name = request.executorDeviceName {
            return name + (request.onThisDevice ? " · this device" : "")
        }
        return model.incoming?.executorDeviceName ?? model.outgoing?.executorDeviceName
    }
    private var deadline: Date? {
        model.request?.deliverBy.flatMap(ChatStore.date) ?? model.incoming?.decideBy ?? model.outgoing?.deliverBy
    }
    private var access: TeamAccessProfile? {
        if let agent { return agent.access }
        guard let request = model.request,
              let access = organization?.channelAgents.first(where: { $0.agentId == request.agentId && $0.channelId == request.channelId })?.access else { return nil }
        return TeamAccessProfile(rawValue: access)
    }
    private var rights: String? {
        guard let access else { return nil }
        guard let agent else { return access.title }
        return "\(access.title) · up to \(agent.maxTurns) steps · \(agent.timeoutMinutes) minutes"
            + (agent.maxBudgetUSD.map { " · \($0.formatted(.currency(code: "USD"))) per call" } ?? "")
    }
    private var audience: String {
        model.request?.kind == "channel"
            ? "Audience: current and future members of the channel's team see the answer if it is published."
            : "Audience: the requester and the agent's owner."
    }
    private var runNotes: [String] {
        var notes: [String] = []
        if let agent {
            notes.append("Folder: \(agent.folder)\n\(agent.access.summary)")
            if agent.access.runsShell { notes.append(TeamAccessProfile.shellWarning) }
            if model.request?.kind == "channel", agent.sessionId != nil {
                notes.append("Memory: a copy of your personal session; its knowledge may appear in an answer published to this team.")
            }
        } else if model.request?.kind == "channel" {
            notes.append("Memory and run limits: review them on the executor Mac.")
        }
        if let request = model.request, request.kind == "channel" {
            if let version = request.conditionsVersion { notes.append("Terms version: \(version)") }
            if let key = model.key, let channel = request.channelId,
               let memory = model.chat.channelThreadMemory(key, requestId: model.id, channel: channel) { notes.append(memory) }
        }
        if let call = model.incoming {
            if let detail = call.detail, !detail.isEmpty { notes.append(detail) }
            if let project = call.origin?.project { notes.append("Sent from project \(project).") }
            if call.resume { notes.append("Continues an earlier conversation.") }
        }
        return notes
    }
    private func readableDate(_ date: Date) -> String {
        let format = DateFormatter()
        format.dateStyle = .medium
        format.timeStyle = .short
        format.doesRelativeDateFormatting = true
        return format.string(from: date)
    }
    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.callout)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var controls: some View {
        if model.canStop { Button("Stop", role: .destructive) { model.stop() }.buttonStyle(PopupDestructiveButtonStyle()) }
        if let request = model.request, let key = model.key, request.kind == "channel" {
            if request.initiatorAccountId == key.accountId, ChatService.channelCancellationStates.contains(request.state) {
                Button("Cancel request", role: .destructive) { state.message = model.chat.cancelChannelRequest(key, requestId: model.id) }
                    .buttonStyle(PopupDestructiveButtonStyle())
            }
        } else {
            if let call = model.incoming {
                if TeamUI.canWatch(call) { Button("Watch") { TeamUI.watch(call) } }
                if call.state == .done, !model.calls.refuses(call) {
                    Button("Continue…") { state.message = TeamUI.continueYourself(call) }
                }
            }
            if let call = model.outgoing, !call.report.state.isFinal, model.calls.refusal(.cancel, for: call) == nil {
                Button("Cancel request", role: .destructive) { Task { _ = await model.calls.cancel(model.id) } }
                    .buttonStyle(PopupDestructiveButtonStyle())
            }
        }
    }
}
