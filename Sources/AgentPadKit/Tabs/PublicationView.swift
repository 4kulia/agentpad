import SwiftUI

/// All entry points render this editor. Its fields and operations are owned by
/// TabState, so moving the native host never recreates the form.
struct TeamPublicationEditor: View {
    @Bindable var state: TabState
    @Bindable var form: PublicationFormState
    let scope: TeamScope
    let tabs: TeamTabs

    var body: some View {
        VStack(spacing: 0) {
        PopupScrollBody {
            VStack(alignment: .leading, spacing: 16) {
                if !state.isPopup { Text(state.route.title).font(.title2) }
                if let source = form.fields.sourceConversationID {
                    let title = form.fields.sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    Text("Source conversation: \(title.isEmpty ? source : title)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let source = form.fields.sessionID ?? form.fields.sourceConversationID,
                   ChatDMHistory(files: ChatService.shared.files).needsFreshSession(source) {
                    Text(ChatDMHistory.publicationNote).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 16) {
                    if form.fields.mode != nil {
                        field("Publish") {
                            Picker("Publish", selection: Binding(get: { form.fields.mode ?? .session }, set: { form.fields.mode = $0 })) {
                                ForEach(TeamPublishMode.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(maxWidth: .infinity)
                        }
                        note(modeExplanation)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        if form.fields.mode != .folder {
                            let title = form.fields.sessionID == nil ? "Name" : "Session's name"
                            field(title) { TextField(title, text: $form.fields.name) }
                        }
                        if let mode = form.fields.mode, mode != .session {
                            field("Agent's name") { TextField("Agent's name", text: $form.fields.folderName) }
                        }
                        field("What to ask it") {
                            TextField("What to ask it", text: $form.fields.description, axis: .vertical).lineLimit(1...6)
                        }
                    }
                    field("Folder") {
                        HStack {
                            TextField("Folder", text: $form.fields.folder).disabled(form.fields.sessionID != nil && form.fields.mode != .folder)
                            if form.fields.sessionID == nil || form.fields.mode == .folder {
                                Button("Choose…") { chooseFolder(extra: false) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        field("Rights") {
                            Picker("Rights", selection: $form.fields.access) {
                                ForEach(TeamAccessProfile.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(maxWidth: .infinity)
                        }
                        Text(form.fields.access.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    if form.fields.access.takesCommands {
                        field("Allowed commands, one per line") {
                            multiline("Allowed commands, one per line", text: $form.fields.commandsText, height: 64)
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            field("More folders, one per line") {
                                multiline("More folders, one per line", text: $form.fields.extraText, height: 64)
                            }
                            Button("Add…") { chooseFolder(extra: true) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        field("Never read, one per line") {
                            multiline("Never read, one per line", text: $form.fields.deniedText, height: 84)
                        }
                    }
                    if form.fields.access.runsShell {
                        Text("With shell access these rules guard against accidents: a command can still read such a file.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Limits").font(.headline)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            field("Up to \(form.fields.maxTurns) steps") {
                                Stepper(value: $form.fields.maxTurns, in: 1...200) { Text("\(form.fields.maxTurns)") }
                                    .accessibilityLabel("Maximum steps")
                            }
                            field("Up to \(form.fields.timeoutMinutes) minutes") {
                                Stepper(value: $form.fields.timeoutMinutes, in: 1...120) { Text("\(form.fields.timeoutMinutes)") }
                                    .accessibilityLabel("Maximum minutes")
                            }
                            field("Model (optional)") { TextField("Model (optional)", text: $form.fields.modelText) }
                            field("Budget per call, USD (optional)") {
                                TextField("Budget per call, USD (optional)", text: $form.fields.budgetText)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Visibility").font(.headline)
                        Toggle("Published", isOn: $form.fields.enabled)
                        if case .server = scope {
                            let teams = tabs.teams(scope)
                            Text("Publish to").font(.subheadline.weight(.semibold))
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                                ForEach(teams) { team in
                                    Toggle(team.name, isOn: teamBinding(team.id))
                                }
                                ForEach(Array(form.fields.teamIDs.subtracting(teams.map(\.id))).sorted(), id: \.self) { id in
                                    Toggle("Unavailable team", isOn: teamBinding(id))
                                }
                            }
                            let names = teams.filter { form.fields.teamIDs.contains($0.id) }.map(\.name)
                            ForEach(TeamPublishWarnings.lines(access: form.fields.access,
                                fromSession: form.fields.sessionID != nil && form.fields.mode != .folder, teamNames: names), id: \.self) { line in
                                note(line)
                            }
                            if !form.fields.enabled { note("Published is off: saved on this Mac only.") }
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
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
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        Divider()
        ViewThatFits(in: .horizontal) {
            HStack { actions }
            VStack(alignment: .leading) { actions }
        }.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .task { await tabs.loadSource(state) }
        .onChange(of: form.fields.folderName) { _, _ in tabs.updateFolderTarget(state) }
        .onChange(of: form.fields.mode) { _, _ in tabs.updateFolderTarget(state) }
        .accessibilityIdentifier("publication-editor")
    }
    @ViewBuilder private var actions: some View {
        if case .publication(_, let id) = state.route,
           let agent = tabs.agents(scope).first(where: { $0.id.uuidString.lowercased() == id.lowercased() }) {
            Button("Unpublish…", role: .destructive) { tabs.requestUnpublish([agent], state: state) }
                .buttonStyle(PopupDestructiveButtonStyle())
                .disabled(form.working || state.confirmation.showsBlock)
        }
        if !state.isPopup { Button("Published Agents") { tabs.showAgents(from: tabs.owner(state)?.store) } }
        if case .publish(_, _, let source, let conversation) = state.route {
            Button("New draft") {
                tabs.publish(sessionID: conversation, folder: URL(fileURLWithPath: form.fields.folder), surfaceID: source,
                    from: tabs.owner(state)?.store, newDraft: true)
            }
        }
        Spacer()
        if state.isPopup {
            Button("Cancel") {
                guard let owner = tabs.owner(state) else { return }
                owner.store.popups.dismiss(owner.session, reason: .cancel)
            }.disabled(form.working || state.confirmation.isExecuting)
                .accessibilityIdentifier("publication-cancel")
        }
        Button(form.fields.enabled ? "Publish…" : "Save…") { tabs.requestSave(state) }
            .disabled(form.working || form.loading || state.confirmation.showsBlock)
            .buttonStyle(PopupPrimaryButtonStyle()).keyboardShortcut(.defaultAction).accessibilityIdentifier("publication-save")
    }
    private var columns: [GridItem] { [.init(.flexible(), spacing: 16), .init(.flexible(), spacing: 16)] }
    private func multiline(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).font(.system(size: 12)).scrollContentBackground(.hidden)
            .frame(height: height).padding(6).accessibilityLabel(title)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.10)))
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
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
