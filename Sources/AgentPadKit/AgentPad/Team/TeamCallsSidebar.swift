import AppKit
import SwiftUI

/// The Team tab of the left sidebar: every call received from colleagues and
/// sent to them — waiting for you, in progress, and the history (kept 30
/// days, also across restarts). Each row opens the same Request tab.
struct TeamCallsSidebar: View {
    var service = TeamService.shared
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", received = "Received", sent = "Sent"
        var id: String { rawValue }
    }

    private var calls: TeamCalls { service.calls }

    /// One row, received or sent.
    private struct Item: Identifiable {
        let id: String
        let incoming: TeamCalls.Incoming?
        let outgoing: TeamCalls.Outgoing?
        var date: Date { incoming?.receivedAt ?? outgoing?.createdAt ?? .distantPast }
        var isFinal: Bool { incoming?.state.isFinal ?? outgoing?.report.state.isFinal ?? true }
        var waitsForMe: Bool { incoming?.needsDecisionHere == true }
    }

    private var items: [Item] {
        var all: [Item] = []
        if filter != .sent {
            all += calls.incoming.filter { $0.hidden != true }.map { Item(id: "in-\($0.id)", incoming: $0, outgoing: nil) }
        }
        if filter != .received {
            all += calls.outgoing.filter { $0.hidden != true }.map { Item(id: "out-\($0.id)", incoming: nil, outgoing: $0) }
        }
        return all.sorted { $0.date > $1.date }
    }

    var body: some View {
        let all = items
        let waiting = all.filter(\.waitsForMe)
        let open = all.filter { !$0.isFinal && !$0.waitsForMe }
        let history = all.filter(\.isFinal)
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            if service.mode != .server && all.isEmpty {
                empty("Team work goes through a server.", action: ("Connect…", { ConnectionTabs.shared.show() }))
            } else if let problem = calls.storeProblem {
                // Not "no calls": they could not be read (review D8e-p3-10).
                empty(problem, action: ("Try Again", { calls.reload() }))
            } else if all.isEmpty && calls.pendingAccess.isEmpty && ClaudeVersionApprovals.shared.pending.isEmpty {
                empty(filter == .sent ? "You have not called a colleague's agent yet." : "No calls yet.", action: nil)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Folder and version summaries open their Request.
                        TeamPanelSection(service: service, showsCalls: false)
                        if !waiting.isEmpty {
                            SessionSectionLabel(title: "needs you", count: waiting.count)
                            ForEach(waiting) { row($0) }
                        }
                        if !open.isEmpty {
                            SessionSectionLabel(title: "in progress", count: open.count)
                            ForEach(open) { row($0) }
                        }
                        if !history.isEmpty {
                            SessionSectionLabel(title: "history", count: history.count)
                            ForEach(history) { row($0) }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Team")
                    .font(Theme.display(13, weight: .semibold))
                    .foregroundStyle(Theme.chromeForeground)
                Spacer()
                Menu {
                    Button("Published Agents…") { TeamUI.showAgents() }
                    Button("Team…") { TeamUI.showTeam() }
                    Button("Organization…") { OrganizationTabs.show() }
                    Divider()
                    Button("Clear History") {
                        if !calls.clearHistory() { Task { await TeamUI.showError("History could not be cleared", TeamError.storage(calls.storeProblem ?? "the calls could not be saved")) } }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, Theme.sidebarContentLeadingX)
        .padding(.vertical, 8)
    }

    private func empty(_ text: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 8) {
            Text(text).font(Theme.display(12)).foregroundStyle(Theme.chromeMuted).multilineTextAlignment(.center)
            if let action { Button(action.0, action: action.1).controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        if let call = item.incoming {
            header(key: call.id, scope: call.scope, icon: "arrow.down.left", title: "\(call.peerName) → \(call.agentName)",
                   prompt: call.prompt, state: Self.word(call.state, serverState: call.serverState, activity: call.activity),
                   attention: call.needsDecisionHere, date: call.receivedAt)
                .padding(.horizontal, 14).padding(.vertical, Theme.sidebarRowVerticalPadding)
        } else if let call = item.outgoing {
            header(key: call.id, scope: call.scope, icon: "arrow.up.right", title: "You → \(call.address)", prompt: call.prompt,
                   state: call.note ?? Self.word(call.report.state, serverState: call.serverState, activity: call.report.activity),
                   attention: false, date: call.createdAt)
                .padding(.horizontal, 14).padding(.vertical, Theme.sidebarRowVerticalPadding)
        }
    }

    private func header(key: String, scope: TeamCallScope?, icon: String, title: String, prompt: String, state: String, attention: Bool, date: Date) -> some View {
        Button {
            RequestTabs.shared.open(key, callScope: scope)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.chromeMuted)
                    .frame(width: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.display(12.5, weight: .medium))
                        .foregroundStyle(Theme.chromeForeground)
                        .lineLimit(1)
                    Text(prompt.replacingOccurrences(of: "\n", with: " "))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.chromeMuted)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(state)
                            .font(Theme.display(10, weight: .medium))
                            .foregroundStyle(attention ? agentStateWordColor(.attention) : Theme.chromeMuted)
                        Text(relativeActivityLabel(date))
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.chromeMuted.opacity(0.7))
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A row's word: the server's state when there is one (D10's words,
    /// DESIGN-D6 §7.4) — a call that finished waits for its result, one
    /// being stopped says so — else the state of 1.0.x.
    static func word(_ state: TeamCallState, serverState: String? = nil, activity: String?) -> String {
        if let serverState {
            switch serverState {
            case "awaiting_decision": return "waiting for approval"
            case "running": return activity.map { "running · \($0)" } ?? "running"
            case "starting": return activity ?? "starting"
            case "finished": return state == .done ? "done" : "finished · waiting for its result"
            case "resyncing": return "being read again"
            default: return serverState.replacingOccurrences(of: "_", with: " ")
            }
        }
        switch state {
        case .awaitingApproval: return "waiting for approval"
        case .running: return activity.map { "running · \($0)" } ?? "running"
        default: return state.rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }

}
