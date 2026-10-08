import Foundation
import GRDB
import SwiftUI

/// Channel review data is shared by its summary and the Request tab. Every
/// read still goes through the channel gate, including local previews.
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
        let changes = CoalescedMainActorAction { [weak self] in self?.revision += 1 }
        if let store = service.orgSessions[key]?.store {
            watch = try? DatabaseRegionObservation(tracking: Table("requests"), Table("request_contents"), Table("channels"),
                                                   Table("teams"), Table("team_members"), Table("members"), Table("agent_channels"), Table("meta"), Table("outbox"), Table("publication_intents"))
                .start(in: store.queue, onError: { _ in }) { _ in changes.schedule() }
        }
        if let journal = service.journal {
            journalWatch = try? DatabaseRegionObservation(tracking: Table("runs"), Table("run_commands"), Table("approvals"),
                                                          Table("channel_authorities"), Table("automatic_request_blocks"), Table("org_generations"), Table("assignments"))
                .start(in: journal.queue, onError: { _ in }) { _ in changes.schedule() }
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
                         OR r.publication IN ('awaiting_publish', 'publish_failed') OR r.request_id = ?)
                ORDER BY r.created_at
                """, arguments: [channel, key.accountId, key.accountId, selectedNotificationRequest]).compactMap { try ChatCallStore.request(db, $0) }
        }) ?? []
    }

    private var selectedNotificationRequest: String? {
        if case .channel(let channel, let request) = AttentionSelection.shared.destination, channel == self.channel { return request }
        return nil
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
    private var calls: TeamCalls { TeamService.shared.calls }
    var body: some View {
        if model.visible {
            let requests = model.requests.filter { !model.isAutomatic($0) || !calls.channelPendingAccess($0.requestId).isEmpty }
            if !requests.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(requests, id: \.requestId) { request in
                        Button {
                            RequestTabs.shared.open(request.requestId, scope: .server(OrgKey(model.key)))
                        } label: {
                            HStack {
                                Text("\(request.agentName ?? "Agent") · \(request.state.rawValue.replacingOccurrences(of: "_", with: " "))")
                                Spacer()
                                Text("Open Request…")
                            }
                        }.buttonStyle(.plain).font(.callout)
                    }
                }.padding(8)
            }
        }
    }
}
