import SwiftUI

/// The top of the right panel: only what waits for this user's decision
/// (docs/agentpad/TEAM.md R-2, R-3; CHAT-PLAN decision 25) — join requests
/// and colleagues' calls, each with its details and Allow / Decline in
/// place. Calls in progress are in the Team tab of the left panel. Shown
/// only while there is something to show.
struct TeamPanelSection: View {
    var service = TeamService.shared
    /// The Team tab lists calls itself and shows only folder requests here.
    var showsCalls = true
    @State private var expanded: String?

    private var calls: TeamCalls { service.calls }
    private var waiting: [TeamCalls.Incoming] { showsCalls ? calls.awaitingDecision : [] }
    /// Incoming calls under way: every state not final that is not waiting
    /// for a decision — also one this build does not know (review D8i-p3-6).
    /// The right panel shows only what needs a decision (decision 25); calls
    /// under way are the Team tab's, by this rule.
    static func activeIncoming(_ calls: TeamCalls) -> [TeamCalls.Incoming] {
        calls.incoming.filter { !$0.state.isFinal && $0.state != .awaitingApproval }
    }

    var body: some View {
        let access = calls.pendingAccess
        let versions = ClaudeVersionApprovals.shared.pending
        let needsYou = waiting.count + access.count + versions.count
        VStack(alignment: .leading, spacing: 0) {
            if needsYou > 0 {
                SessionSectionLabel(title: "team · needs you", count: needsYou)
                ForEach(waiting) { call in
                    incomingRow(call)
                }
                ForEach(access) { request in
                    accessRow(request)
                }
                ForEach(versions) { item in versionRow(item) }
            }
        }
    }

    private func versionRow(_ item: ClaudeVersionApprovals.Pending) -> some View {
        let key = "version-\(item.id)"
        return VStack(alignment: .leading, spacing: 8) {
            header(key: key, icon: "exclamationmark.shield", title: "\(item.agentName) · Claude Code \(item.grant.version)",
                   subtitle: item.grant.profile.title, status: "waiting", attention: true)
            if expanded == key {
                Text(item.message).fixedSize(horizontal: false, vertical: true)
                Text("Выбранное имя: \(item.executable.selectedPath)").textSelection(.enabled)
                Text("Конечный файл: \(item.executable.file.resolvedPath)").textSelection(.enabled)
                if item.grant.profile.runsShell { Text(TeamAccessProfile.shellWarning) }
                HStack {
                    Button(item.allowTitle) { ClaudeVersionApprovals.shared.decide(item.id, allow: true) }
                    Button(ClaudeVersionApprovals.Pending.declineTitle) { ClaudeVersionApprovals.shared.decide(item.id, allow: false) }
                }
                .controlSize(.small)
            }
        }
        .font(Theme.display(11))
        .padding(.horizontal, 14)
        .padding(.vertical, Theme.sidebarRowVerticalPadding)
        .onAppear { if expanded == nil { expanded = key } }
    }

    // MARK: Calls from colleagues

    private func incomingRow(_ call: TeamCalls.Incoming) -> some View {
        let key = "in-\(call.id)"
        let isOpen = expanded == key
        let agent = calls.localAgent(for: call)
        let status = call.serverState == nil
            ? (call.state == .awaitingApproval ? "waiting" : TeamCallsSidebar.word(call.state, activity: call.activity))
            : TeamCallsSidebar.word(call.state, serverState: call.serverState, activity: call.activity)
        return VStack(alignment: .leading, spacing: 8) {
            header(
                key: key, icon: "person.2.wave.2",
                title: "\(call.peerName) → \(call.agentName)",
                subtitle: call.prompt.replacingOccurrences(of: "\n", with: " "),
                status: status, attention: call.needsDecisionHere
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
                    Text(Self.details(call, agent: agent))
                        .font(Theme.display(10.5))
                        .foregroundStyle(Theme.chromeMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        // Each action's gate, mirrored: a server's request is decided
                        // here on its executor (D4); stopping it is D4b.
                        if let refusal = calls.refusal(call.state == .awaitingApproval ? .decide : .stop, for: call) {
                            Text(refusal)
                                .font(Theme.display(10.5))
                                .foregroundStyle(Theme.chromeMuted)
                        } else if call.state == .awaitingApproval {
                            Button("Allow") { calls.decide(call.id, allow: true) }
                                .keyboardShortcut(.defaultAction)
                            Button("Decline") { calls.decide(call.id, allow: false) }
                        } else {
                            Button("Stop") { calls.stop(call.id) }
                            if TeamUI.canWatch(call) { Button("Watch") { TeamUI.watch(call) } }
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
        .onAppear { if expanded == nil, call.needsDecisionHere { expanded = key } }
    }

    /// What the card says of an incoming call: the state's explanation
    /// first, then the run's terms (review D8h-p3-5).
    static func details(_ call: TeamCalls.Incoming, agent: TeamPublishedAgent?) -> String {
        var parts: [String] = []
        if let detail = call.detail, !detail.isEmpty { parts.append(detail) }
        if let agent {
            parts.append("Runs Claude Code in \(agent.folder) with “\(agent.access.title)” rights: \(agent.access.summary)")
            // What a shell may do, said where the owner decides (AG-3, track Y).
            if agent.access.runsShell { parts.append(TeamAccessProfile.shellWarning) }
            parts.append("Up to \(agent.maxTurns) steps and \(agent.timeoutMinutes) minutes.")
        }
        if let project = call.origin?.project { parts.append("Sent from project \(project).") }
        if call.resume { parts.append("Continues an earlier conversation.") }
        return parts.joined(separator: " ")
    }

    // MARK: Folder requests

    private func accessRow(_ request: TeamCalls.AccessRequest) -> some View {
        let call = calls.incoming.first { $0.id == request.callId }
        return VStack(alignment: .leading, spacing: 8) {
            header(
                key: "access-\(request.id)", icon: "folder.badge.questionmark",
                title: "\(call?.agentName ?? "An agent") asks for a folder",
                subtitle: request.path, status: "waiting", attention: true
            )
            VStack(alignment: .leading, spacing: 6) {
                Text("Working on \(call?.peerName ?? "a colleague")'s call. \(request.reason)")
                    .font(Theme.display(11))
                    .foregroundStyle(Theme.chromeMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(request.path)
                    .font(Theme.mono(10))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Button("Allow Once") { Task { await TeamUI.decideAccess(request.id, .once) } }
                    Button("Always") { Task { await TeamUI.decideAccess(request.id, .always) } }
                        .help("Add this folder to the agent for good")
                    Button("Deny") { Task { await TeamUI.decideAccess(request.id, .denied) } }
                    Spacer()
                }
                .controlSize(.small)
            }
            .padding(.leading, 26)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Theme.sidebarRowVerticalPadding)
    }

    /// What the card says of a call this Mac sent: its note, and the
    /// state's explanation (review D8h-p3-5).
    static func outgoingDetails(_ call: TeamCalls.Outgoing) -> [String] {
        [call.note, call.report.detail].compactMap { $0 }.filter { !$0.isEmpty }
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
