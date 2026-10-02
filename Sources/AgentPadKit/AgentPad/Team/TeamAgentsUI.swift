import AppKit
import SwiftUI

/// Team → Published Agents…: what this Mac lets colleagues call, and with
/// which rights (docs/agentpad/TEAM.md 6.2).
struct TeamAgentsView: View {
    let service: TeamService
    @State private var editing: TeamPublishedAgent?

    private var calls: TeamCalls { service.calls }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Published agents")
                .font(Theme.display(14, weight: .semibold))
            Text("Colleagues' agents can call these. Every call waits for your Allow in the right panel, then runs Claude Code in the agent's folder with the rights you chose.")
                .font(Theme.display(11))
                .foregroundStyle(Theme.chromeMuted)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
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
                Button("Publish Agent…") { editing = TeamPublishedAgent(name: "", description: "", folder: "") }
                Spacer()
            }
        }
        .padding(18)
        .frame(width: 480)
        .sheet(item: $editing) { agent in
            TeamAgentEditor(agent: agent, contacts: service.contacts) { saved in
                try await calls.save(saved)
            } onClose: {
                editing = nil
            }
        }
    }

    private func row(_ agent: TeamPublishedAgent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(agent.enabled ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(agent.name) · \(agent.access.title)")
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
            }
            Spacer()
            Button(agent.enabled ? "Pause" : "Resume") {
                var next = agent
                next.enabled.toggle()
                Task { await save(next) }
            }
            .buttonStyle(.borderless)
            Button("Edit…") { editing = agent }.buttonStyle(.borderless)
            Button("Remove…") { Task { await remove(agent) } }.buttonStyle(.borderless)
        }
    }

    private func save(_ agent: TeamPublishedAgent) async {
        do { try await calls.save(agent) } catch { await TeamUI.showError("The agent was not saved", error) }
    }

    private func remove(_ agent: TeamPublishedAgent) async {
        let alert = NSAlert()
        alert.messageText = "Stop publishing \(agent.name)?"
        alert.informativeText = "Colleagues can no longer call it. Calls already allowed finish."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard await TeamUI.present(alert) == .alertFirstButtonReturn else { return }
        do { try calls.unpublish(agent.id) } catch { await TeamUI.showError("The agent was not removed", error) }
    }
}

/// One agent's settings (A-1…A-6).
private struct TeamAgentEditor: View {
    @State var agent: TeamPublishedAgent
    let contacts: [TeamContact]
    let onSave: (TeamPublishedAgent) async throws -> Void
    let onClose: () -> Void

    @State private var deniedText = ""
    @State private var commandsText = ""
    @State private var everyone = true
    @State private var chosen: Set<String> = []
    @State private var modelText = ""
    @State private var budgetText = ""
    @State private var error: String?
    @State private var saving = false

    init(agent: TeamPublishedAgent, contacts: [TeamContact],
         onSave: @escaping (TeamPublishedAgent) async throws -> Void, onClose: @escaping () -> Void) {
        _agent = State(initialValue: agent)
        self.contacts = contacts
        self.onSave = onSave
        self.onClose = onClose
        _deniedText = State(initialValue: agent.deniedPaths.joined(separator: "\n"))
        _commandsText = State(initialValue: agent.allowedCommands.joined(separator: "\n"))
        _everyone = State(initialValue: agent.audience == nil)
        _chosen = State(initialValue: Set(agent.audience ?? []))
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
                if agent.access == .edit {
                    TextField("Allowed commands, one per line", text: $commandsText, prompt: Text("swift test"), axis: .vertical)
                        .lineLimit(2...5)
                }
                TextField("Never read, one per line", text: $deniedText, axis: .vertical)
                    .lineLimit(3...6)
                if agent.access != .read {
                    Text("With shell access these rules guard against accidents, not against a determined request: a command can still read such a file.")
                        .font(Theme.display(10.5))
                        .foregroundStyle(Theme.chromeMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Stepper("Up to \(agent.maxTurns) steps", value: $agent.maxTurns, in: 1...200)
                Stepper("Up to \(agent.timeoutMinutes) minutes", value: $agent.timeoutMinutes, in: 1...120)
                TextField("Model (optional)", text: $modelText, prompt: Text("default"))
                TextField("Budget per call, USD (optional)", text: $budgetText, prompt: Text("no limit"))
                Toggle("Every colleague may call it", isOn: $everyone)
                if !everyone {
                    ForEach(contacts) { contact in
                        Toggle(contact.displayName, isOn: Binding(
                            get: { chosen.contains(contact.id) },
                            set: { if $0 { chosen.insert(contact.id) } else { chosen.remove(contact.id) } }
                        ))
                    }
                }
                Toggle("Published", isOn: $agent.enabled)
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
        next.allowedCommands = lines(commandsText)
        next.audience = everyone ? nil : Array(chosen)
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
            try await onSave(next)
            onClose()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}
