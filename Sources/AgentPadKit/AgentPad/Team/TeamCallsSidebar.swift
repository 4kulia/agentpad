import AppKit
import SwiftUI

/// The Team tab of the left sidebar: every call received from colleagues and
/// sent to them — waiting for you, in progress, and the history (kept 30
/// days, also across restarts) — with the full request, the answer, and
/// Allow / Decline / Stop / Cancel in place (docs/agentpad/TEAM.md R-2, R-3, J-1).
struct TeamCallsSidebar: View {
    var service = TeamService.shared
    @State private var filter = Filter.all
    @State private var expanded: String?

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
        ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            if service.mode != .server && all.isEmpty {
                empty("Team work goes through a server.", action: ("Connect…", { ChatConnectWindow.show() }))
            } else if let problem = calls.storeProblem {
                // Not "no calls": they could not be read (review D8e-p3-10).
                empty(problem, action: ("Try Again", { calls.reload() }))
            } else if all.isEmpty && calls.pendingAccess.isEmpty && ClaudeVersionApprovals.shared.pending.isEmpty {
                empty(filter == .sent ? "You have not called a colleague's agent yet." : "No calls yet.", action: nil)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Folder requests are decided here too.
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
        .onChange(of: AttentionSelection.shared.revision, initial: true) { _, _ in
            let destination = AttentionSelection.shared.destination
            let target: String?
            switch destination {
            case .team(let id?, let outgoing): target = "\(outgoing ? "out" : "in")-\(id)"; expanded = target; filter = .all
            case .version(let id): target = "version-\(id)"
            case .folder(let id, _): target = "access-\(id)"
            default: target = nil
            }
            if let target { DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) } }
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
                    Button("Organization…") { ChatOrgWindow.show() }
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
            incomingRow(call, key: item.id).id(item.id)
                .attentionPlace(expanded == item.id ? [.team(request: call.id, outgoing: false)] : [])
        } else if let call = item.outgoing {
            outgoingRow(call, key: item.id).id(item.id)
                .attentionPlace(expanded == item.id ? [.team(request: call.id, outgoing: true)] : [])
        }
    }

    private func incomingRow(_ call: TeamCalls.Incoming, key: String) -> some View {
        let agent = calls.localAgent(for: call)
        return VStack(alignment: .leading, spacing: 8) {
            header(key: key, icon: "arrow.down.left", title: "\(call.peerName) → \(call.agentName)",
                   prompt: call.prompt, state: Self.word(call.state, serverState: call.serverState, activity: call.activity),
                   attention: call.needsDecisionHere, date: call.receivedAt)
            if expanded == key {
                VStack(alignment: .leading, spacing: 8) {
                    facts([
                        ("Agent", agent.map { "\($0.isSession ? "session · " : "")\($0.access.title) · \($0.folder)" }
                            // A server's request run on another Mac of the owner: said so, not "gone" (review D8f-p3-9).
                            ?? (call.onThisDevice == false ? "runs on \(call.executorDeviceName ?? "the owner's other Mac")" : "no longer published")),
                        ("Project", call.origin?.project),
                        ("Thread", call.resume ? "continues an earlier conversation" : nil),
                        ("Why", call.detail),
                        ("Claude Code", ClaudeVersionApprovals.shared.admissions[call.id].map { "\($0.version) · \($0.basis)" }),
                        ("Выбранное имя", ClaudeVersionApprovals.shared.admissions[call.id]?.executable.selectedPath),
                        ("Конечный файл", ClaudeVersionApprovals.shared.admissions[call.id]?.executable.file.resolvedPath),
                        // What a shell may do, said where the owner decides (AG-3, track Y).
                        ("Shell", agent.flatMap { $0.access.runsShell ? TeamAccessProfile.shellWarning : nil }),
                    ])
                    block("Request", call.prompt)
                    if let answer = call.answer { block(call.truncated ? "Answer (truncated)" : "Answer", answer.text) }
                    HStack(spacing: 8) {
                        // Each action's gate, mirrored: a server's request is
                        // decided here on its executor (D4); stopping it is D4b.
                        switch call.state {
                        case .awaitingApproval:
                            if let refusal = calls.refusal(.decide, for: call) {
                                Text(refusal).foregroundStyle(.secondary)
                            } else {
                                Button("Allow") { calls.decide(call.id, allow: true) }
                                Button("Decline…") { Task { await decline(call) } }
                            }
                        case .queued, .running:
                            if let refusal = calls.refusal(.stop, for: call) {
                                Text(refusal).foregroundStyle(.secondary)
                            } else {
                                Button("Stop") { calls.stop(call.id) }
                            }
                        default:
                            EmptyView()
                        }
                        if let key = calls.serverKey {
                            ClaudeLaunchHelpView(key: key, request: call.id)
                        }
                        if TeamUI.canWatch(call) {
                            Button("Watch") { TeamUI.watch(call) }
                                .help("Open a tab that shows what this agent does, live")
                        }
                        if call.state == .done, !calls.refuses(call) {
                            Button("Continue…") {
                                if let refusal = TeamUI.continueYourself(call) {
                                    Task { await TeamUI.showError("The conversation could not be opened", TeamError.storage(refusal)) }
                                }
                            }
                                .help("Open this conversation in a tab and carry on with it yourself")
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
    }

    private func outgoingRow(_ call: TeamCalls.Outgoing, key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(key: key, icon: "arrow.up.right", title: "You → \(call.address)", prompt: call.prompt,
                   state: call.note == nil ? Self.word(call.report.state, serverState: call.serverState, activity: call.report.activity) : "retrying",
                   attention: false, date: call.createdAt)
            if expanded == key {
                VStack(alignment: .leading, spacing: 8) {
                    facts([
                        ("Status", call.note),
                        ("Why", call.report.detail),
                        ("Call id", call.id),
                        ("Thread", call.report.threadId),
                    ])
                    block("Request", call.prompt)
                    if let text = call.report.text {
                        block(call.report.truncated == true ? "Answer (truncated)" : "Answer", text)
                    }
                    HStack(spacing: 8) {
                        if !call.report.state.isFinal {
                            if let refusal = calls.refusal(.cancel, for: call) {
                                Text(refusal).foregroundStyle(.secondary)
                            } else {
                                Button("Cancel Call") { Task { _ = await calls.cancel(call.id) } }
                            }
                        }
                        if let text = call.report.text {
                            Button("Copy Answer") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            }
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
    }

    private func header(key: String, icon: String, title: String, prompt: String, state: String, attention: Bool, date: Date) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded = expanded == key ? nil : key }
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

    private func facts(_ rows: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows.filter { $0.1 != nil }, id: \.0) { row in
                (Text(row.0 + "  ").foregroundStyle(Theme.chromeMuted) + Text(row.1 ?? ""))
                    .font(Theme.display(10.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(Theme.display(9.5, weight: .semibold)).foregroundStyle(Theme.chromeMuted)
            ScrollView {
                Text(text)
                    .font(Theme.mono(10.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .padding(6)
            .background(Theme.chromeHover)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private func decline(_ call: TeamCalls.Incoming) async {
        let alert = NSAlert()
        alert.messageText = "Decline \(call.peerName)'s call?"
        alert.informativeText = "Optionally say why; \(call.peerName) sees it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Reason (optional)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Decline")
        alert.addButton(withTitle: "Cancel")
        guard await TeamUI.present(alert) == .alertFirstButtonReturn else { return }
        calls.decide(call.id, allow: false, reason: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
