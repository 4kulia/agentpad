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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("New agent").font(Theme.display(22, weight: .semibold))
                VStack(alignment: .leading, spacing: 10) {
                    Text("Agent type").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
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
                                .padding(10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .background(form.newAgent.templateID == template.id ? Theme.chromeSelection : Theme.chromeHover,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(template.title)
                            .accessibilityValue(form.newAgent.templateID == template.id ? "Selected" : "")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Folder").font(.headline)
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(form.newAgent.folder.isEmpty ? "Choose a folder" : form.newAgent.folder)
                            .font(Theme.mono(12)).lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button("Choose…", action: chooseFolder).accessibilityLabel("Choose agent folder")
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Name (optional)").font(.headline)
                    TextField(defaultName, text: $form.newAgent.name)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Agent name (optional)")
                        .onSubmit { if canAdd { tabs.addAgent(state) } }
                }
                if let duplicate = tabs.duplicateAgent(state) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(duplicate.name) already uses this agent type in that folder.")
                            .foregroundStyle(.secondary)
                        Button("Show \(duplicate.name) in Agents") { tabs.addAgent(state) }
                    }
                }
                if let error = form.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Button("Add agent") { tabs.addAgent(state) }
                    .buttonStyle(.borderedProminent).disabled(!canAdd)
                    .accessibilityIdentifier("add-agent")
            }
            .padding(28).frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .disabled(form.completed)
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
