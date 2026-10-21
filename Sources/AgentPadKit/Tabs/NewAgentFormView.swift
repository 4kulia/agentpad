import AppKit
import SwiftUI

struct NewAgentDraft: Codable, Equatable {
    var templateID = AgentTemplate.claudeCodeID
    var folder = ""
    var name = ""
}

struct NewAgentFormView: View {
    let state: TabState
    let tabs: LocalFormTabs
    @Bindable var form: LocalFormState

    var body: some View {
        VStack(spacing: 0) {
            PopupScrollBody { fields }
            Divider()
            HStack(spacing: 8) {
                Spacer()
                if state.isPopup {
                    Button("Cancel") { tabs.cancel(state) }
                        .accessibilityIdentifier("new-agent-cancel")
                }
                Button("Add agent") { tabs.addAgent(state) }
                    .buttonStyle(.borderedProminent).disabled(!canAdd)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("add-agent")
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .disabled(form.completed)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("New agent").font(Theme.display(18, weight: .semibold))
                        Text("Agent type").font(Theme.display(12, weight: .semibold))
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(tabs.agentTemplates()) { template in
                            Button { form.newAgent.templateID = template.id } label: {
                                HStack(spacing: 8) {
                                    AgentIconView(asset: template.iconAsset, fallbackSymbol: template.symbol, size: 20)
                                    Text(template.title).font(Theme.display(12)).lineLimit(2)
                                    Spacer(minLength: 0)
                                    if form.newAgent.templateID == template.id {
                                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                                    }
                                }
                                .padding(8).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                                .background(form.newAgent.templateID == template.id ? Theme.chromeSelection : Theme.chromeHover,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(form.newAgent.templateID == template.id ? Theme.activityRunning : Theme.chromeHairline,
                                            lineWidth: 1))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(template.title)
                            .accessibilityValue(form.newAgent.templateID == template.id ? "Selected" : "")
                            .accessibilityIdentifier("new-agent-type-" + template.id)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Folder").font(Theme.display(12)).foregroundStyle(Theme.chromeMuted)
                    HStack(spacing: 10) {
                        TextField("Choose a folder", text: $form.newAgent.folder)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Folder")
                            .accessibilityIdentifier("new-agent-folder")
                            .onSubmit { if canAdd { tabs.addAgent(state) } }
                        Button("Choose…", action: chooseFolder).accessibilityLabel("Choose agent folder")
                            .accessibilityIdentifier("new-agent-choose-folder")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name (optional)").font(Theme.display(12)).foregroundStyle(Theme.chromeMuted)
                    TextField(defaultName, text: $form.newAgent.name)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Agent name (optional)")
                        .accessibilityIdentifier("new-agent-name")
                        .onSubmit { if canAdd { tabs.addAgent(state) } }
                    Text("Folder name is used when no name is provided.")
                        .font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
                }
                if let duplicate = tabs.duplicateAgent(state) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(duplicate.name) already uses this agent type in that folder.")
                            .foregroundStyle(.secondary)
                        Button("Show \(duplicate.name) in Agents") { tabs.addAgent(state) }
                    }
                }
                if let error = form.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("new-agent-error")
                }
        }
        .padding(24).frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var defaultName: String {
        form.newAgent.folder.isEmpty ? "Folder name" : URL(fileURLWithPath: form.newAgent.folder).lastPathComponent
    }
    private var canAdd: Bool {
        !form.newAgent.folder.isEmpty && tabs.agentTemplates().contains { $0.id == form.newAgent.templateID }
            && tabs.duplicateAgent(state) == nil
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose folder"
        if !form.newAgent.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: form.newAgent.folder) }
        let revision = state.revision
        guard let window = tabs.owner(state)?.session.engine.view.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            _ = state.accept(revision: revision) {
                form.newAgent.folder = canonicalDiskPath(url).path
                form.error = nil
            }
        }
    }
}
