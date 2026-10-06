import Foundation
import GRDB
import SwiftUI

/// Decisions and local previews have no entry through Team. They live with
/// the channel, and are re-read after every change relevant to its gate.
@MainActor @Observable
final class ChatChannelOwnerModel {
    let service: ChatService
    let key: ChatOrgKey
    let channel: String
    var revision = 0
    @ObservationIgnored private var watch: AnyDatabaseCancellable?
    @ObservationIgnored private var journalWatch: AnyDatabaseCancellable?

    init(service: ChatService, key: ChatOrgKey, channel: String) {
        self.service = service
        self.key = key
        self.channel = channel
        if let store = service.orgSessions[key]?.store {
            watch = try? DatabaseRegionObservation(tracking: Table("requests"), Table("request_contents"), Table("channels"),
                                                   Table("teams"), Table("team_members"), Table("members"), Table("agent_channels"), Table("meta"), Table("outbox"), Table("publication_intents"))
                .start(in: store.queue, onError: { _ in }) { [weak self] _ in
                    Task { @MainActor in self?.revision += 1 }
                }
        }
        if let journal = service.journal {
            journalWatch = try? DatabaseRegionObservation(tracking: Table("runs"), Table("run_commands"), Table("approvals"),
                                                          Table("channel_authorities"), Table("automatic_request_blocks"), Table("org_generations"), Table("assignments"))
                .start(in: journal.queue, onError: { _ in }) { [weak self] _ in
                    Task { @MainActor in self?.revision += 1 }
                }
        }
    }

    var visible: Bool {
        _ = revision
        return service.channelAgentAllowed(key, channel: channel)
    }

    var requests: [ChatRequest] {
        guard visible, let store = service.orgSessions[key]?.store else { return [] }
        return (try? store.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT r.request_id FROM requests r JOIN channels c ON c.channel_id = r.channel_id
                WHERE r.kind = 'channel' AND r.channel_id = ? AND (r.owner_account_id = ? OR r.initiator_account_id = ?)
                    AND (r.state IN ('submitted', 'awaiting_decision', 'approved', 'starting', 'running', 'stop_requested')
                         OR r.publication IN ('awaiting_publish', 'publish_failed'))
                ORDER BY r.created_at
                """, arguments: [channel, key.accountId, key.accountId]).compactMap { try ChatCallStore.request(db, $0) }
        }) ?? []
    }

    func content(_ request: ChatRequest) -> ChatChannelContent? {
        guard visible, let store = service.orgSessions[key]?.store else { return nil }
        return try? store.queue.read { try ChatChannelContent.read($0, request: request.requestId) }
    }

    func isAutomatic(_ request: ChatRequest) -> Bool {
        if let approval = try? service.journal?.approval(key, requestId: request.requestId),
           let params = try? TeamLaunchParams.decode(approval.params) {
            guard approval.voidAt == nil, params.consentBasis != nil, params.consentBasis != "manual",
                  service.automaticApprovalValid(key, request: request, params: params) else { return false }
            if let store = service.orgSessions[key]?.store,
               let command = try? store.queue.read({ try ChatPublication.current($0, run: approval.runId) }),
               command.sessionId != service.connection?.sessionId || [.failed, .dropped, .unconfirmed].contains(command.state)
                || (try? store.queue.read { try ChatPublication.isAutomatic($0, command: command.commandId) }) == false {
                return false
            }
            return true
        }
        if let content = content(request) { return service.automaticAuthority(key, request: request, content: content) != nil }
        // While the verified snapshot is loading, a local Send stays progress,
        // not an extra Allow card. The launch still requires full verification.
        return (try? service.journal?.channelAuthority(request.requestId))?.basis == "self_call"
    }

    func canCancel(_ request: ChatRequest) -> Bool {
        visible && request.initiatorAccountId == key.accountId && ChatService.channelCancellationStates.contains(request.state)
    }

    func cancel(_ request: ChatRequest) -> String? { service.cancelChannelRequest(key, requestId: request.requestId) }

    func publicationText(_ requestId: String) -> String? {
        _ = revision
        return try? service.channelPublicationText(key, requestId: requestId)
    }

    func name(_ account: String?) -> String {
        guard visible, let store = service.orgSessions[key]?.store else { return "a member" }
        return (try? store.queue.read { try String.fetchOne($0, sql: "SELECT name FROM members WHERE account_id = ?", arguments: [account]) }) ?? "a former member"
    }

    func decisionText(_ request: ChatRequest) -> String? {
        guard visible, request.ownerAccountId == key.accountId, let id = request.agentId,
              let store = service.orgSessions[key]?.store,
              let memory = service.channelThreadMemory(key, requestId: request.requestId, channel: channel) else { return nil }
        let agent = service.localAgent(id)
        let names = try? store.queue.read { try Row.fetchOne($0, sql: """
            SELECT c.name, t.name AS team, a.access FROM channels c JOIN teams t ON t.team_id = c.team_id
            LEFT JOIN agent_channels a ON a.channel_id = c.channel_id AND a.agent_id = ? WHERE c.channel_id = ?
            """, arguments: [id, channel]) }
        let channelName: String = names?["name"] ?? "channel", team: String = names?["team"] ?? "team"
        let access = agent?.access ?? (names?["access"] as String?).flatMap(TeamAccessProfile.init(rawValue:))
        var lines = ["From #\(channelName) · asked by \(name(request.initiatorAccountId))",
                     "Profile: \(access?.rawValue ?? "unknown") · terms \(request.conditionsVersion ?? 0)",
                     "Executor: \(request.executorDeviceName ?? "another Mac")",
                     "Audience: members of team \(team), including future members, see the answer only if you publish it.",
                     "Deadline: \(request.deliverBy ?? "unknown")"]
        if access?.runsShell == true { lines.append("EX-7: " + TeamAccessProfile.shellWarning) }
        if let agent {
            lines.append("Limits: \(agent.maxTurns) turns, \(agent.timeoutMinutes) minutes" + (agent.maxBudgetUSD.map { ", $\($0)" } ?? ""))
            if agent.sessionId != nil { lines.append("Memory: a copy of your personal session; its knowledge may appear in an answer published to this team.") }
            lines.append(memory)
        } else { lines.append("Memory and run limits: review them on the executor Mac.") }
        return lines.joined(separator: "\n")
    }

    func canOpenSession(_ requestId: String) -> Bool {
        _ = revision
        return service.channelThreadSession(key, requestId: requestId, channel: channel) != nil
    }

    @discardableResult
    func openSession(_ requestId: String) -> String? {
        // Recheck the gate at the click, even if the button was visible earlier.
        guard let session = service.channelThreadSession(key, requestId: requestId, channel: channel) else {
            return "This conversation is not available through the channel on this Mac."
        }
        TeamUI.openTab(session.folder, "claude --resume \(session.id) --fork-session", "Channel · your copy")
        return nil
    }
}

struct ChatChannelOwnerPanel: View {
    let model: ChatChannelOwnerModel
    @State private var selected: String?
    @State private var problem: String?
    private var calls: TeamCalls { TeamService.shared.calls }

    var body: some View {
        if model.visible {
            let requests = model.requests.filter { !model.isAutomatic($0) || !calls.channelPendingAccess($0.requestId).isEmpty }
            if !requests.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(requests, id: \.requestId) { request in
                        HStack {
                            Text("\(request.agentName ?? "Agent") · \(request.state.rawValue.replacingOccurrences(of: "_", with: " "))").font(.callout)
                            Spacer()
                            if request.ownerAccountId == model.key.accountId {
                                if !model.isAutomatic(request), request.state == .awaitingDecision { Button("Review request…") { selected = request.requestId } }
                                if !model.isAutomatic(request), request.publication != nil { Button("Preview result…") { selected = request.requestId } }
                                if !calls.channelPendingAccess(request.requestId).isEmpty { Button("Review folders…") { selected = request.requestId } }
                                if [.starting, .running].contains(request.state) {
                                    Button("Stop") { problem = model.service.askToEnd(model.key, request.requestId, type: "request.stop", states: [.starting, .running]) }
                                }
                            }
                            if model.canCancel(request) {
                                Button("Cancel request") { problem = model.cancel(request) }
                            }
                        }
                    }
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                }
                .padding(8)
            }
        }
        Color.clear.frame(height: 0).sheet(isPresented: Binding(get: { selected != nil && model.visible }, set: { if !$0 { selected = nil } })) {
            if let id = selected {
                ChatChannelDecisionSheet(model: model, requestId: id) { selected = nil }
            }
        }
        .onChange(of: model.visible) { _, visible in if !visible { selected = nil; problem = nil } }
    }
}

struct ChatChannelDecisionSheet: View {
    let model: ChatChannelOwnerModel
    let requestId: String
    let close: () -> Void
    @State private var problem: String?
    @State private var reason = ""
    @State private var deciding = false
    private var calls: TeamCalls { TeamService.shared.calls }

    var body: some View {
        Group {
            if model.visible, let request = model.requests.first(where: { $0.requestId == requestId }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let terms = model.decisionText(request) { Text(terms).font(.callout).textSelection(.enabled) }
                        if request.state == .awaitingDecision, !model.isAutomatic(request) {
                            Text("Review channel request").font(.headline)
                            Text(ChatMarkdownText.attributed(request.text ?? "")).textSelection(.enabled)
                            if let content = model.content(request) {
                                ForEach(content.context ?? [], id: \.messageId) { message in
                                    Text("\(model.name(message.authorAccountId)) · revision \(message.revision)").font(.caption).foregroundStyle(.secondary)
                                    Text(ChatMarkdownText.attributed(message.text ?? "[Message deleted]")).textSelection(.enabled)
                                }
                            } else { Text("Waiting for the verified context…").foregroundStyle(.secondary) }
                            if request.onThisDevice {
                                TextField("Reason for declining (optional)", text: $reason)
                                HStack {
                                    Button("Decline") { decide(false) }
                                    Button("Allow") { decide(true) }
                                }
                                .disabled(deciding)
                            } else { Text("The decision is made on \(request.executorDeviceName ?? "the executor Mac").") }
                        }
                        if !model.isAutomatic(request), let run = model.service.channelPreview(model.key, requestId: requestId) {
                            Text("Preview · only on this Mac").font(.headline)
                            if model.canOpenSession(requestId) {
                                Button("Continue…") { problem = model.openSession(requestId) }
                            }
                            Text(verbatim: run.resultErased ? "The result is no longer kept on this Mac." : (model.publicationText(requestId) ?? "No result text.")).textSelection(.enabled)
                            if let issue = model.service.channelPublicationIssue(model.key, requestId: requestId) {
                                Text(issue).font(.caption).foregroundStyle(.secondary)
                            }
                            if request.publication == "awaiting_publish" {
                                let refusal = model.service.channelPublishProblem(model.key, requestId: requestId)
                                if let refusal { Text(refusal).font(.caption).foregroundStyle(.orange) }
                                HStack {
                                    Button("Don't Publish") { publish(false) }
                                    Button("Publish") { publish(true) }.disabled(refusal != nil)
                                }
                                .disabled(model.service.channelPublicationInFlight(model.key, requestId: requestId) != nil)
                            } else if request.publication == "publish_failed" {
                                Text("Not published: \(ChatChannelRequests.reason(request.publishReason))").foregroundStyle(.orange)
                            }
                        }
                        ForEach(calls.channelPendingAccess(requestId), id: \.id) { folder in
                            Text("Folder requested: \(folder.path)").textSelection(.enabled)
                            Text(folder.reason).font(.callout)
                            HStack {
                                Button("Deny folder") { grant(folder.id, .denied) }
                                Button("Allow folder once") { grant(folder.id, .once) }
                            }
                        }
                        if let problem { Text(problem).foregroundStyle(.red).font(.caption) }
                        HStack { Spacer(); Button("Close") { close() } }
                    }.padding(16)
                }
            } else { Color.clear.onAppear { close() } }
        }
        .frame(width: 560, height: 540)
        .task(id: requestId) {
            guard let request = model.requests.first(where: { $0.requestId == requestId }), request.state == .awaitingDecision else { return }
            do { _ = try await model.service.loadChannelContent(model.key, request: request) }
            catch { problem = "The context could not be loaded. Close and try again." }
        }
        .onChange(of: model.visible) { _, visible in if !visible { close() } }
    }

    private func decide(_ allow: Bool) {
        deciding = true
        Task {
            problem = await model.service.owner?.decideChannel(model.key, requestId: requestId, allow: allow, reason: reason)
            deciding = false
            if problem == nil { close() }
        }
    }
    private func publish(_ publish: Bool) {
        do { try model.service.publishChannelResult(model.key, requestId: requestId, publish: publish); close() }
        catch { problem = error.localizedDescription }
    }
    private func grant(_ id: String, _ state: TeamCalls.AccessRequest.State) {
        Task { problem = await calls.decideAccess(id, state) }
    }
}
