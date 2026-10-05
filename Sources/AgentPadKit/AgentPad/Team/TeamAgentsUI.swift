import AppKit
import SwiftUI

/// Team → Published Agents…: what this Mac lets colleagues call, and with
/// which rights (docs/agentpad/TEAM.md 6.2).
struct TeamAgentsView: View {
    let service: TeamService
    /// The agent in the editor and the organization it was opened for —
    /// written once, by the button that opens it (review D3b-p1-2).
    @State private var editing: TeamAgentEditing?

    private var calls: TeamCalls { service.calls }
    /// Server mode: the organization agents are published to (D3).
    private var key: ChatOrgKey? { calls.serverMode ? calls.serverKey : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Published agents")
                .font(Theme.display(14, weight: .semibold))
            Text("Colleagues' agents can call these. Every call waits for your Allow in the right panel, then runs Claude Code in the agent's folder with the rights you chose.")
                .font(Theme.display(11))
                .foregroundStyle(Theme.chromeMuted)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if key != nil, let problem = ChatService.shared.publishProblem {
                // Tried again by itself (review D3-p2-5).
                Text(problem).font(Theme.display(11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if calls.agents.isEmpty {
                Text("Nothing published yet.")
                    .font(Theme.display(12))
                    .foregroundStyle(Theme.chromeMuted)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(calls.agents) { agent in
                        row(agent)
                    }
                }
            }
            HStack {
                Button("Publish Agent…") {
                    editing = TeamAgentEditing(agent: TeamPublishedAgent.fresh(serverMode: key != nil), key: key)
                }
                Spacer()
            }
        }
        .padding(18)
        .frame(width: 480)
        .sheet(item: $editing) { open in
            // The organization the form was opened for (review D3-p1-3, D3b-p1-2).
            let agent = open.agent, opened = open.key
            let teams = opened.map { ChatService.shared.myTeams($0) }
            TeamAgentEditor(agent: agent, teams: teams, chosen: chosenTeams(agent, opened, teams ?? [])) { saved, chosen in
                if let opened { try await calls.saveAndPublish([saved], teams: chosen, key: opened) } else { try await calls.save(saved) }
            } onClose: {
                editing = nil
            }
        }
    }

    /// The teams the owner chose for it, else General.
    private func chosenTeams(_ agent: TeamPublishedAgent, _ key: ChatOrgKey?, _ teams: [ChatSnapshot.Team]) -> [String] {
        if let key, let chosen = ChatService.shared.chosenTeams(agent.id, key: key) { return chosen }
        return teams.filter(\.isGeneral).map(\.teamId)
    }

    private func status(_ agent: TeamPublishedAgent) -> (text: String, note: String?, unconfirmed: Bool)? {
        guard let key else { return nil }
        // Read again whenever the cache is (its catalog) — review D3c-p2-4.
        _ = calls.loads
        let (status, note) = ChatService.shared.publishStatus(agent, key: key)
        switch status {
        case .local: return ("Only on this Mac: not published.", note, false)
        case .publishing: return ("Publishing…", note, false)
        case .unconfirmed: return ("Not confirmed: the server was restored from a backup.", note, true)
        case .published(let teams):
            let names = ChatService.shared.myTeams(key).filter { teams.contains($0.teamId) }.map(\.name)
            return ("Published to \(names.isEmpty ? "\(teams.count) team(s)" : names.joined(separator: ", ")).", note, false)
        case .changesNotPublished(let error):
            return ("Changes not published\(error.map { " (the server refused: \($0))" } ?? ""); calls are refused until you publish them.", note, false)
        case .unpublishing:
            return ("Unpublishing…: calls are refused; it leaves this Mac once the server confirms.", note, false)
        case .unpublishUnconfirmed:
            return ("Unpublishing not confirmed: the connection or the server changed before it was taken.", note, true)
        }
    }

    private func row(_ agent: TeamPublishedAgent) -> some View {
        let published = key != nil && ChatService.shared.isAssigned(agent.id)
        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(agent.enabled ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(agent.name) · \(agent.isSession ? "session · " : "")\(agent.access.title)")
                    .font(Theme.display(13, weight: .medium))
                Text(agent.description)
                    .font(Theme.display(11))
                    .foregroundStyle(Theme.chromeMuted)
                    .lineLimit(2)
                Text(agent.folder)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status = status(agent) {
                    Text(status.text).font(Theme.display(10.5)).foregroundStyle(Theme.chromeMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = status.note {
                        Text(note).font(Theme.display(10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if status.unconfirmed, let key {
                        // The same choice for a publication and an unpublishing waiting for the owner.
                        let unpublishing = ChatService.shared.publishStatus(agent, key: key).status == .unpublishUnconfirmed
                        HStack {
                            Button(unpublishing ? "Unpublish Again" : "Send Again") { act { try ChatService.shared.resendPublication(agent.id, key: key) } }
                            Button(unpublishing ? "Keep Published" : "Withdraw") { act { try ChatService.shared.withdrawPublication(agent.id, key: key) } }
                        }
                        .controlSize(.small)
                    }
                }
            }
            Spacer()
            // Pausing and removing an agent published to a server come in D3b.
            Button(agent.enabled ? "Pause" : "Resume") {
                var next = agent
                next.enabled.toggle()
                Task { await save(next) }
            }
            .buttonStyle(.borderless)
            .disabled(published)
            .help(published ? TeamServerCore.pauseNotYet : "")
            Button("Edit…") { editing = TeamAgentEditing(agent: agent, key: key) }.buttonStyle(.borderless)
            // Published: unpublished through the server first (D3b).
            Button(published ? "Unpublish…" : "Remove…") { Task { await remove(agent) } }.buttonStyle(.borderless)
                .disabled(published && ChatService.shared.publishStatus(agent, key: key!).status == .unpublishing)
        }
    }

    private func act(_ body: () throws -> Void) {
        do { try body() } catch { Task { await TeamUI.showError("The publication was not changed", error) } }
    }

    private func save(_ agent: TeamPublishedAgent) async {
        do { try await calls.save(agent) } catch { await TeamUI.showError("The agent was not saved", error) }
    }

    private func remove(_ agent: TeamPublishedAgent) async {
        let alert = NSAlert()
        alert.messageText = "Stop publishing \(agent.name)?"
        alert.informativeText = "Colleagues can no longer call it. Calls already allowed finish."
        alert.addButton(withTitle: key != nil && ChatService.shared.isAssigned(agent.id) ? "Unpublish" : "Remove")
        alert.addButton(withTitle: "Cancel")
        guard await TeamUI.present(alert) == .alertFirstButtonReturn else { return }
        do { try calls.unpublish(agent.id) } catch { await TeamUI.showError("The agent was not removed", error) }
    }
}

/// An editor opened: the agent, and the organization it publishes to (nil:
/// team work off).
struct TeamAgentEditing: Identifiable {
    var agent: TeamPublishedAgent
    let key: ChatOrgKey?
    var id: UUID { agent.id }
}

/// One agent's settings (A-1…A-6).
private struct TeamAgentEditor: View {
    @State var agent: TeamPublishedAgent
    /// Server mode: the member's teams to publish to (D3); nil otherwise.
    let teams: [ChatSnapshot.Team]?
    @State private var chosen: Set<String>
    let onSave: (TeamPublishedAgent, [String]) async throws -> Void
    let onClose: () -> Void

    @State private var deniedText = ""
    @State private var extraText = ""
    @State private var commandsText = ""
    @State private var modelText = ""
    @State private var budgetText = ""
    @State private var error: String?
    @State private var saving = false

    init(agent: TeamPublishedAgent, teams: [ChatSnapshot.Team]? = nil, chosen: [String] = [],
         onSave: @escaping (TeamPublishedAgent, [String]) async throws -> Void, onClose: @escaping () -> Void) {
        _agent = State(initialValue: agent)
        self.teams = teams
        _chosen = State(initialValue: Set(chosen))
        self.onSave = onSave
        self.onClose = onClose
        _deniedText = State(initialValue: agent.deniedPaths.joined(separator: "\n"))
        _extraText = State(initialValue: (agent.extraFolders ?? []).joined(separator: "\n"))
        _commandsText = State(initialValue: agent.allowedCommands.joined(separator: "\n"))
        _modelText = State(initialValue: agent.model ?? "")
        _budgetText = State(initialValue: agent.maxBudgetUSD.map { String($0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(agent.name.isEmpty ? "Publish an agent" : "Agent \(agent.name)")
                .font(Theme.display(14, weight: .semibold))
            Form {
                TextField("Name", text: $agent.name, prompt: Text("backend"))
                TextField("What to ask it", text: $agent.description, prompt: Text("Shop backend: order API, migrations, logs"), axis: .vertical)
                    .lineLimit(2...4)
                HStack {
                    TextField("Folder", text: $agent.folder, prompt: Text("/Users/you/projects/shop"))
                    Button("Choose…") { chooseFolder() }
                }
                Picker("Rights", selection: $agent.access) {
                    ForEach(TeamAccessProfile.allCases) { Text($0.title).tag($0) }
                }
                Text(agent.access.summary)
                    .font(Theme.display(10.5))
                    .foregroundStyle(Theme.chromeMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if agent.access.takesCommands {
                    TextField("Allowed commands, one per line", text: $commandsText, prompt: Text("swift test"), axis: .vertical)
                        .lineLimit(2...5)
                }
                HStack(alignment: .top) {
                    TextField("More folders, one per line", text: $extraText, prompt: Text("e.g. a second checkout"), axis: .vertical)
                        .lineLimit(1...4)
                    Button("Add…") { if let path = TeamUI.chooseFolder() { extraText += (extraText.isEmpty ? "" : "\n") + path } }
                }
                TextField("Never read, one per line", text: $deniedText, axis: .vertical)
                    .lineLimit(3...6)
                if agent.access.runsShell {
                    Text("With shell access these rules guard against accidents, not against a determined request: a command can still read such a file.")
                        .font(Theme.display(10.5))
                        .foregroundStyle(Theme.chromeMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Stepper("Up to \(agent.maxTurns) steps", value: $agent.maxTurns, in: 1...200)
                Stepper("Up to \(agent.timeoutMinutes) minutes", value: $agent.timeoutMinutes, in: 1...120)
                TextField("Model (optional)", text: $modelText, prompt: Text("default"))
                TextField("Budget per call, USD (optional)", text: $budgetText, prompt: Text("no limit"))
                Toggle("Published", isOn: $agent.enabled)
                if let teams {
                    Section("Publish to") {
                        ForEach(teams, id: \.teamId) { team in
                            Toggle(team.name, isOn: Binding(
                                get: { chosen.contains(team.teamId) },
                                set: { on in if on { chosen.insert(team.teamId) } else { chosen.remove(team.teamId) } }
                            ))
                        }
                        let names = teams.filter { chosen.contains($0.teamId) }.map(\.name)
                        ForEach(TeamPublishWarnings.lines(access: agent.access, fromSession: agent.isSession, teamNames: names), id: \.self) { line in
                            Text(line).font(Theme.display(10.5)).foregroundStyle(Theme.chromeMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !agent.enabled {
                            Text("Published is off: the agent is saved on this Mac only.")
                                .font(Theme.display(10.5)).foregroundStyle(Theme.chromeMuted)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 480)
            if let error {
                Text(error).font(Theme.display(11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            agent.folder = url.path
            if agent.name.isEmpty { agent.name = TeamHandle.make(url.lastPathComponent) }
        }
    }

    private func save() async {
        var next = agent
        let lines = { (text: String) in
            text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        next.deniedPaths = lines(deniedText)
        next.extraFolders = lines(extraText)
        next.allowedCommands = lines(commandsText)
        next.model = modelText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : modelText.trimmingCharacters(in: .whitespaces)
        let budget = budgetText.trimmingCharacters(in: .whitespaces)
        if budget.isEmpty {
            next.maxBudgetUSD = nil
        } else if let value = Double(budget.replacingOccurrences(of: ",", with: ".")), value > 0 {
            next.maxBudgetUSD = value
        } else {
            error = "The budget is a number of dollars, e.g. 2.5."
            return
        }
        guard !next.description.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "Say what to ask it: colleagues' agents read this to decide."
            return
        }
        saving = true
        defer { saving = false }
        do {
            try await onSave(next, teams?.filter { chosen.contains($0.teamId) }.map(\.teamId) ?? [])
            onClose()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}
