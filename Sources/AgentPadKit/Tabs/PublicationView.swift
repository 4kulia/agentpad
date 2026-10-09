import SwiftUI

/// All entry points render this editor. Its fields and operations are owned by
/// TabState, so moving the native host never recreates the form.
struct TeamPublicationEditor: View {
    @Bindable var state: TabState
    @Bindable var form: PublicationFormState
    let scope: TeamScope
    let tabs: TeamTabs

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(state.route.title).font(.title2)
                if let source = form.fields.sourceConversationID {
                    Text("Source conversation: \(source)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let source = form.fields.sessionID ?? form.fields.sourceConversationID,
                   ChatDMHistory(files: ChatService.shared.files).needsFreshSession(source) {
                    Text(ChatDMHistory.publicationNote).font(.caption).foregroundStyle(.secondary)
                }
                Form {
                    if form.fields.mode != nil {
                        Picker("Publish", selection: Binding(get: { form.fields.mode ?? .session }, set: { form.fields.mode = $0 })) {
                            ForEach(TeamPublishMode.allCases) { Text($0.title).tag($0) }
                        }
                        Text(modeExplanation).font(.caption).foregroundStyle(.secondary)
                    }
                    if form.fields.mode != .folder {
                        TextField(form.fields.sessionID == nil ? "Name" : "Session's name", text: $form.fields.name)
                    }
                    if let mode = form.fields.mode, mode != .session {
                        TextField("Agent's name", text: $form.fields.folderName)
                    }
                    TextField("What to ask it", text: $form.fields.description, axis: .vertical).lineLimit(2...6)
                    HStack {
                        TextField("Folder", text: $form.fields.folder).disabled(form.fields.sourceConversationID != nil || form.fields.sessionID != nil)
                        if form.fields.sourceConversationID == nil, form.fields.sessionID == nil {
                            Button("Choose…") { chooseFolder(extra: false) }
                        }
                    }
                    Picker("Rights", selection: $form.fields.access) {
                        ForEach(TeamAccessProfile.allCases) { Text($0.title).tag($0) }
                    }
                    Text(form.fields.access.summary).font(.caption).foregroundStyle(.secondary)
                    if form.fields.access.takesCommands {
                        TextField("Allowed commands, one per line", text: $form.fields.commandsText, axis: .vertical).lineLimit(2...5)
                    }
                    HStack(alignment: .top) {
                        TextField("More folders, one per line", text: $form.fields.extraText, axis: .vertical).lineLimit(1...4)
                        Button("Add…") { chooseFolder(extra: true) }
                    }
                    TextField("Never read, one per line", text: $form.fields.deniedText, axis: .vertical).lineLimit(3...6)
                    if form.fields.access.runsShell {
                        Text("With shell access these rules guard against accidents: a command can still read such a file.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Stepper("Up to \(form.fields.maxTurns) steps", value: $form.fields.maxTurns, in: 1...200)
                    Stepper("Up to \(form.fields.timeoutMinutes) minutes", value: $form.fields.timeoutMinutes, in: 1...120)
                    TextField("Model (optional)", text: $form.fields.modelText)
                    TextField("Budget per call, USD (optional)", text: $form.fields.budgetText)
                    Toggle("Published", isOn: $form.fields.enabled)
                    if case .server = scope {
                        Section("Publish to") {
                            let teams = tabs.teams(scope)
                            ForEach(teams) { team in
                                Toggle(team.name, isOn: teamBinding(team.id))
                            }
                            ForEach(Array(form.fields.teamIDs.subtracting(teams.map(\.id))).sorted(), id: \.self) { id in
                                Toggle("Unavailable team", isOn: teamBinding(id))
                            }
                            let names = teams.filter { form.fields.teamIDs.contains($0.id) }.map(\.name)
                            ForEach(TeamPublishWarnings.lines(access: form.fields.access,
                                fromSession: form.fields.sessionID != nil && form.fields.mode != .folder, teamNames: names), id: \.self) { line in
                                Text(line).font(.caption).foregroundStyle(.secondary)
                            }
                            if !form.fields.enabled { Text("Published is off: saved on this Mac only.").font(.caption) }
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(form.working || state.confirmation.isAwaiting)
                if form.loading { ProgressView("Reading the source conversation…") }
                if let error = form.error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("publication-error") }
                if form.error != nil, !tabs.reviewTargets(form.fields, scope: scope).isEmpty {
                    Button("Review current version…") { tabs.reviewCurrentVersion(state) }
                        .disabled(form.working || state.confirmation.showsBlock)
                }
                if let status = form.status { Text(status).foregroundStyle(.secondary) }
                if let draft = state.draft {
                    Text(state.savedRevision == draft.revision ? "Draft saved" : "Saving draft…").font(.caption).foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading) { actions }
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await tabs.loadSource(state) }
        .onChange(of: form.fields.folderName) { _, _ in tabs.updateFolderTarget(state) }
        .onChange(of: form.fields.mode) { _, _ in tabs.updateFolderTarget(state) }
        .accessibilityIdentifier("publication-editor")
    }
    @ViewBuilder private var actions: some View {
        Button(form.fields.enabled ? "Publish…" : "Save…") { tabs.requestSave(state) }
            .disabled(form.working || form.loading || state.confirmation.showsBlock)
        if case .publication(_, let id) = state.route,
           let agent = tabs.agents(scope).first(where: { $0.id.uuidString.lowercased() == id.lowercased() }) {
            Button("Unpublish…") { tabs.requestUnpublish([agent], state: state) }
                .disabled(form.working || state.confirmation.showsBlock)
        }
        Button("Published Agents") { tabs.showAgents(from: tabs.owner(state)?.store) }
        if case .publish(_, _, let source, let conversation) = state.route {
            Button("New draft") {
                tabs.publish(sessionID: conversation, title: form.fields.sessionTitle ?? "", surfaceID: source,
                    from: tabs.owner(state)?.store, newDraft: true)
            }
        }
    }
    private func teamBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { form.fields.teamIDs.contains(id) }, set: {
            if $0 { form.fields.teamIDs.insert(id) } else { form.fields.teamIDs.remove(id) }
        })
    }
    private func chooseFolder(extra: Bool) {
        let revision = state.revision
        guard let path = TeamUI.chooseFolder() else { return }
        _ = state.accept(revision: revision) {
            if extra { form.fields.extraText += (form.fields.extraText.isEmpty ? "" : "\n") + path }
            else {
                form.fields.folder = path
                if form.fields.name.isEmpty { form.fields.name = TeamHandle.make(URL(fileURLWithPath: path).lastPathComponent) }
            }
        }
    }
    private var modeExplanation: String {
        switch form.fields.mode {
        case .session: "Each call uses a copy of this conversation. Colleagues may learn from answers what was discussed."
        case .folder: "A fresh agent starts in this session's folder each time."
        case .both: "Colleagues choose this conversation or a fresh agent in its folder."
        case nil: ""
        }
    }
}
