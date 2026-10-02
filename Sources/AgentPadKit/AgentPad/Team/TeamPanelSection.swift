import SwiftUI

/// The top of the right panel: team work in progress (docs/agentpad/TEAM.md
/// R-2, R-3). "Needs you": join requests and colleagues' calls waiting for
/// this user's decision, each with its details and Allow / Decline in place.
/// "In progress": calls running here and calls this Mac sent. Shown only
/// while there is something to show.
struct TeamPanelSection: View {
    var service = TeamService.shared
    @State private var expanded: String?

    private var calls: TeamCalls { service.calls }
    private var waiting: [TeamCalls.Incoming] { calls.awaitingDecision }
    private var active: [TeamCalls.Incoming] { calls.incoming.filter { $0.state == .queued || $0.state == .running } }
    private var sent: [TeamCalls.Outgoing] { calls.outgoing.filter { !$0.report.state.isFinal } }

    var body: some View {
        let needsYou = service.pendingPairings.count + waiting.count
        VStack(alignment: .leading, spacing: 0) {
            if needsYou > 0 {
                SessionSectionLabel(title: "team · needs you", count: needsYou)
                ForEach(service.pendingPairings) { pending in
                    pairingRow(pending)
                }
                ForEach(waiting) { call in
                    incomingRow(call)
                }
            }
            if !active.isEmpty || !sent.isEmpty {
                SessionSectionLabel(title: "team · in progress", count: active.count + sent.count)
                ForEach(active) { call in
                    incomingRow(call)
                }
                ForEach(sent) { call in
                    outgoingRow(call)
                }
            }
        }
    }

    // MARK: Join requests

    private func pairingRow(_ pending: TeamService.PendingPairing) -> some View {
        let key = "pair-\(pending.id)"
        let isOpen = expanded == key
        return VStack(alignment: .leading, spacing: 8) {
            header(
                key: key, icon: "person.badge.plus",
                title: "\(pending.name) wants to join", subtitle: "code \(pending.code)", status: "waiting", attention: true
            )
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow only if \(pending.name) sees the same code: \(pending.code). Once allowed, you see each other's presence and can call each other's published agents — always with the owner's approval.")
                        .font(Theme.display(11))
                        .foregroundStyle(Theme.chromeMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(pending.peerId)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.chromeMuted.opacity(0.75))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Button("Allow") { service.decide(attempt: pending.attempt, approve: true) }
                            .keyboardShortcut(.defaultAction)
                        Button("Decline") { service.decide(attempt: pending.attempt, approve: false) }
                        Spacer()
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Theme.sidebarRowVerticalPadding)
        .onAppear { if expanded == nil { expanded = key } }
    }

    // MARK: Calls from colleagues

    private func incomingRow(_ call: TeamCalls.Incoming) -> some View {
        let key = "in-\(call.id)"
        let isOpen = expanded == key
        let agent = calls.agents.first { $0.id == call.agentId }
        let status: String = switch call.state {
        case .awaitingApproval: "waiting"
        case .queued: "queued"
        case .running: call.activity.map { "running · \($0)" } ?? "running"
        default: call.state.rawValue
        }
        return VStack(alignment: .leading, spacing: 8) {
            header(
                key: key, icon: "person.2.wave.2",
                title: "\(call.peerName) → \(call.agentName)",
                subtitle: call.prompt.replacingOccurrences(of: "\n", with: " "),
                status: status, attention: call.state == .awaitingApproval
            )
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        Text(call.prompt)
                            .font(Theme.mono(11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .padding(6)
                    .background(Theme.chromeHover)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(details(call, agent: agent))
                        .font(Theme.display(10.5))
                        .foregroundStyle(Theme.chromeMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if call.state == .awaitingApproval {
                            Button("Allow") { calls.decide(call.id, allow: true) }
                                .keyboardShortcut(.defaultAction)
                            Button("Decline") { calls.decide(call.id, allow: false) }
                        } else {
                            Button("Stop") { calls.stop(call.id) }
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Theme.sidebarRowVerticalPadding)
        .onAppear { if expanded == nil, call.state == .awaitingApproval { expanded = key } }
    }

    private func details(_ call: TeamCalls.Incoming, agent: TeamPublishedAgent?) -> String {
        var parts: [String] = []
        if let agent {
            parts.append("Runs Claude Code in \(agent.folder) with “\(agent.access.title)” rights: \(agent.access.summary)")
            parts.append("Up to \(agent.maxTurns) steps and \(agent.timeoutMinutes) minutes.")
        }
        if let project = call.origin?.project { parts.append("Sent from project \(project).") }
        if call.resume { parts.append("Continues an earlier conversation.") }
        return parts.joined(separator: " ")
    }

    // MARK: Calls this Mac sent

    private func outgoingRow(_ call: TeamCalls.Outgoing) -> some View {
        let key = "out-\(call.id)"
        let isOpen = expanded == key
        let status = call.note == nil
            ? (call.report.activity.map { "running · \($0)" } ?? call.report.state.rawValue.replacingOccurrences(of: "_", with: " "))
            : "retrying"
        return VStack(alignment: .leading, spacing: 8) {
            header(
                key: key, icon: "paperplane",
                title: "You → \(call.address)",
                subtitle: call.prompt.replacingOccurrences(of: "\n", with: " "),
                status: status, attention: false
            )
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    if let note = call.note {
                        Text(note).font(Theme.display(10.5)).foregroundStyle(Theme.chromeMuted)
                    }
                    HStack {
                        Button("Cancel Call") { Task { _ = await calls.cancel(call.id) } }
                        Spacer()
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Theme.sidebarRowVerticalPadding)
    }

    // MARK: Shared

    private func header(key: String, icon: String, title: String, subtitle: String, status: String, attention: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded = expanded == key ? nil : key }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.chromeForeground)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.display(12.5, weight: .medium))
                        .foregroundStyle(Theme.chromeForeground)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.chromeMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(status)
                    .font(Theme.display(10, weight: .medium))
                    .foregroundStyle(attention ? agentStateWordColor(.attention) : Theme.chromeMuted)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
