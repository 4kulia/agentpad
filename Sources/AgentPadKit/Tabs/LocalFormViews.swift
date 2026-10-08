import SwiftUI

struct LocalFormView: View {
    let state: TabState
    let tabs: LocalFormTabs
    @Bindable var form: LocalFormState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(state.route.title).font(.title2)
                switch state.route {
                case .newSSH: ssh
                case .newWorktree(let path, _, _):
                    Text(path).font(.caption).textSelection(.enabled)
                    worktree
                case .workspaceDetails(let id):
                    if state.navigation.selection == "close", let batch = state.closeWorkspaces {
                        CloseWorkspacesView(batch: batch)
                        Button("Workspace details") {
                            state.confirmation.invalidate(); state.navigation.selection = nil; state.changed()
                        }
                    } else { details(id) }
                default: EmptyView()
                }
                if let error = form.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("local-form-error")
                }
                if form.working { ProgressView().controlSize(.small) }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(form.working || form.completed)
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if case .newWorktree = state.route { await tabs.loadWorktree(state) } }
    }

    private var ssh: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Every new terminal tab in this workspace connects to this SSH destination.")
                .foregroundStyle(.secondary)
            TextField("Workspace name (optional)", text: $form.name)
            TextField("SSH destination · user@host", text: $form.host)
                .accessibilityIdentifier("ssh-destination")
                .onSubmit { tabs.createSSH(state) }
            Text("Host aliases from ~/.ssh/config are supported.").font(.caption)
            Button("Create workspace") { tabs.createSSH(state) }
            Button("New draft") {
                if let owner = tabs.owner(state) { tabs.newSSH(from: owner.store, newDraft: true) }
            }
        }
    }

    private var worktree: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $form.worktree.mode) {
                Text("New branch").tag(WorktreeFormDraft.Mode.newBranch)
                Text("Existing branch").tag(WorktreeFormDraft.Mode.existing)
                Text("Adopt worktrees").tag(WorktreeFormDraft.Mode.adopt)
            }
            if form.worktree.mode == .adopt {
                if form.loading { Text("Loading worktrees…") }
                ForEach(tabs.adoptable(state), id: \.path) { info in
                    let path = canonicalDiskPath(info.path).path
                    Toggle(info.branch.map { "\($0) · \(path)" } ?? path, isOn: Binding(
                        get: { form.worktree.adoptPaths.contains(path) },
                        set: { if $0 { form.worktree.adoptPaths.insert(path) } else { form.worktree.adoptPaths.remove(path) } }
                    ))
                }
            } else {
                if form.worktree.mode == .newBranch {
                    TextField("New branch", text: $form.worktree.branch)
                    TextField("Start from · HEAD, branch, tag or SHA", text: $form.worktree.startRef)
                } else {
                    TextField("Existing branch", text: $form.worktree.existingBranch)
                    let checked = WorktreeManager.checkedOutBranches(in: form.diskWorktrees)
                    Picker("Available branches", selection: $form.worktree.existingBranch) {
                        Text("Choose a branch").tag("")
                        ForEach(form.branches.filter { !checked.contains($0) }, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Worktree path (optional)", text: $form.worktree.directory)
                Text(form.worktree.directory.isEmpty ? tabs.defaultWorktreePath(state) : form.worktree.directory)
                    .font(.caption).textSelection(.enabled)
            }
            Picker("Launch", selection: $form.worktree.templateID) {
                ForEach(AgentTemplate.visibleOrdered(model: .shared)) { Text($0.title).tag($0.id) }
            }
            Button(form.worktree.mode == .adopt ? "Adopt worktrees" : "Create worktree") {
                Task { await tabs.createWorktree(state) }
            }
            Button("New draft") {
                if case .newWorktree(_, let id, _) = state.route, let source = tabs.workspace(id), let owner = tabs.owner(state) {
                    tabs.newWorktree(source: source.workspace, from: owner.store, newDraft: true)
                }
            }
        }
        .onChange(of: tabs.adoptable(state).map(\.path), initial: true) { _, _ in
            if form.loaded { tabs.pruneAdoptPaths(state) }
        }
    }

    @ViewBuilder private func details(_ id: UUID) -> some View {
        if let target = tabs.workspace(id) {
            if form.titleEdit.isEditing {
                InlineNameField(edit: form.titleEdit, label: "Workspace title") { text in
                    target.store.renameWorkspace(target.workspace, to: text); return nil
                }
            } else {
                Text(target.workspace.title).font(.headline)
                Button("Rename workspace") { form.titleEdit.begin(target.workspace.customTitle ?? target.workspace.title) }
            }
            Text(target.workspace.diskPath.path).textSelection(.enabled)
            if let host = target.workspace.sshRemoteHost { Text("SSH · " + host) }
            Button("Close workspace…") { target.store.requestCloseWorkspace(target.workspace) }
            Text("Tag").font(.headline)
            TextField("Tag name (optional)", text: $form.tag.name)
            HStack {
                ForEach(WorkspaceColorTag.allCases, id: \.self) { color in
                    Button {
                        form.tag.hex = color.hex; form.tag.seededPreset = color.rawValue
                    } label: {
                        Circle().fill(color.color).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(form.tag.hex == color.hex ? Color.primary : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).accessibilityLabel(color.title)
                }
            }
            TextField("Color · six-digit hex", text: $form.tag.hex)
            Button("Save tag") { tabs.saveTag(state) }
            Button("Clear tag") { tabs.clearTag(state) }
        } else { Text("The workspace is no longer available.").foregroundStyle(.secondary) }
    }
}
