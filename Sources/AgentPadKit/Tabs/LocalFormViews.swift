import SwiftUI

struct LocalFormView: View {
    let state: TabState
    let tabs: LocalFormTabs
    @Bindable var form: LocalFormState
    @FocusState private var workspaceTitleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if state.navigation.selection == "close", let batch = state.closeWorkspaces {
                CloseWorkspacesView(batch: batch, showWorkspaceDetails: {
                    state.confirmation.invalidate(); state.navigation.selection = nil; state.changed()
                })
            } else {
                PopupScrollBody { fields }
                Divider()
                HStack(spacing: 8) {
                    Spacer()
                    if state.isPopup {
                        Button("Cancel") { tabs.cancel(state) }
                            .accessibilityIdentifier("local-form-cancel")
                    }
                    primaryAction
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
            }
        }
        .disabled(form.working || form.completed)
        .task { if case .newWorktree = state.route { await tabs.loadWorktree(state) } }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch state.route {
            case .newSSH: ssh
            case .newWorktree(let path, _, _):
                VStack(alignment: .leading, spacing: 6) {
                    Text("New worktree").font(Theme.display(18, weight: .semibold))
                    Text(path).font(Theme.display(12)).foregroundStyle(Theme.chromeMuted).textSelection(.enabled)
                }
                worktree
            case .workspaceDetails(let id):
                details(id)
            default: EmptyView()
            }
            if let error = form.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("local-form-error")
            }
            if form.working { ProgressView().controlSize(.small) }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ssh: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New SSH workspace").font(Theme.display(18, weight: .semibold))
                Text("Every new terminal tab in this workspace connects to this SSH destination.")
                    .font(Theme.display(12)).foregroundStyle(Theme.chromeMuted)
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Workspace name (optional)")
                TextField("Workspace name (optional)", text: $form.name).labelsHidden()
                    .accessibilityIdentifier("ssh-workspace-name")
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("SSH destination · user@host")
                TextField("SSH destination · user@host", text: $form.host).labelsHidden()
                    .accessibilityIdentifier("ssh-destination")
                    .onSubmit { tabs.createSSH(state) }
                Text("Host aliases from ~/.ssh/config are supported.")
                    .font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
            }
        }
    }

    private var worktree: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Mode")
                Picker("Mode", selection: $form.worktree.mode) {
                    Text("New branch").tag(WorktreeFormDraft.Mode.newBranch)
                    Text("Existing branch").tag(WorktreeFormDraft.Mode.existing)
                    Text("Adopt worktrees").tag(WorktreeFormDraft.Mode.adopt)
                }
                .labelsHidden().frame(maxWidth: .infinity)
                .accessibilityIdentifier("worktree-mode")
            }
            if form.worktree.mode == .adopt {
                Text("Available worktrees").font(Theme.display(12, weight: .semibold))
                if form.loading { Text("Loading worktrees…") }
                if form.loaded && tabs.adoptable(state).isEmpty {
                    Text("No worktrees are available to adopt.").foregroundStyle(Theme.chromeMuted)
                }
                ForEach(tabs.adoptable(state), id: \.path) { info in
                    let path = canonicalDiskPath(info.path).path
                    Toggle(info.branch.map { "\($0) · \(path)" } ?? path, isOn: Binding(
                        get: { form.worktree.adoptPaths.contains(path) },
                        set: { if $0 { form.worktree.adoptPaths.insert(path) } else { form.worktree.adoptPaths.remove(path) } }
                    ))
                }
            } else {
                if form.worktree.mode == .newBranch {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("New branch")
                        TextField("New branch", text: $form.worktree.branch).labelsHidden()
                            .accessibilityIdentifier("worktree-branch")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Start from · HEAD, branch, tag or SHA")
                        TextField("HEAD", text: $form.worktree.startRef)
                            .accessibilityLabel("Start from · HEAD, branch, tag or SHA")
                            .accessibilityIdentifier("worktree-start-ref")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Existing branch")
                        TextField("Existing branch", text: $form.worktree.existingBranch).labelsHidden()
                            .accessibilityIdentifier("worktree-existing-branch")
                    }
                    let checked = WorktreeManager.checkedOutBranches(in: form.diskWorktrees)
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Available branches")
                        Picker("Available branches", selection: $form.worktree.existingBranch) {
                            Text("Choose a branch").tag("")
                            ForEach(form.branches.filter { !checked.contains($0) }, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: .infinity)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Worktree path (optional)")
                    TextField("Worktree path (optional)", text: $form.worktree.directory).labelsHidden()
                        .accessibilityIdentifier("worktree-directory")
                    Text(form.worktree.directory.isEmpty ? tabs.defaultWorktreePath(state) : form.worktree.directory)
                        .font(Theme.display(11)).foregroundStyle(Theme.chromeMuted).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Launch")
                Picker("Launch", selection: $form.worktree.templateID) {
                    ForEach(AgentTemplate.visibleOrdered(model: .shared)) { Text($0.title).tag($0.id) }
                }
                .labelsHidden().frame(maxWidth: .infinity)
                .accessibilityIdentifier("worktree-launch")
            }
        }
        .onChange(of: tabs.adoptable(state).map(\.path), initial: true) { _, _ in
            if form.loaded { tabs.pruneAdoptPaths(state) }
        }
    }

    @ViewBuilder private func details(_ id: UUID) -> some View {
        if let target = tabs.workspace(id) {
            VStack(alignment: .leading, spacing: 6) {
                Text(target.workspace.title).font(Theme.display(18, weight: .semibold))
                Text(target.workspace.diskPath.path).font(Theme.display(12))
                    .foregroundStyle(Theme.chromeMuted).textSelection(.enabled)
                if let host = target.workspace.sshRemoteHost { Text("SSH · " + host).font(Theme.display(12)) }
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Workspace title")
                TextField("Workspace title", text: Binding(
                    get: { form.titleEdit.isEditing ? form.titleEdit.text : target.workspace.customTitle ?? target.workspace.title },
                    set: {
                        form.titleEdit.begin(target.workspace.customTitle ?? target.workspace.title)
                        form.titleEdit.text = $0
                    }
                ))
                .accessibilityIdentifier("workspace-title")
                .focused($workspaceTitleFocused)
                .onSubmit {
                    form.titleEdit.handle(.enter) { text in
                        target.store.renameWorkspace(target.workspace, to: text); return nil
                    }
                }
                .onExitCommand {
                    if form.titleEdit.isEditing { form.titleEdit.handle(.escape) { _ in nil } }
                    else if state.isPopup { tabs.cancel(state) }
                }
                if let error = form.titleEdit.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Button("Rename workspace") {
                        form.titleEdit.begin(target.workspace.customTitle ?? target.workspace.title)
                        workspaceTitleFocused = true
                    }
                    .accessibilityIdentifier("workspace-rename")
                    Button("Close workspace…", role: .destructive) { target.store.requestCloseWorkspace(target.workspace) }
                        .buttonStyle(PopupDestructiveButtonStyle())
                        .accessibilityIdentifier("workspace-close")
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Tag").font(Theme.display(12, weight: .semibold))
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Tag name (optional)")
                        TextField("Tag name (optional)", text: $form.tag.name).labelsHidden()
                            .accessibilityIdentifier("workspace-tag-name")
                    }
                    HStack {
                        ForEach(WorkspaceColorTag.allCases, id: \.self) { color in
                            Button {
                                form.tag.hex = color.hex; form.tag.seededPreset = color.rawValue
                            } label: {
                                Circle().fill(color.color).frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(form.tag.hex == color.hex ? Color.primary : .clear, lineWidth: 2))
                            }.buttonStyle(.plain).accessibilityLabel(color.title)
                                .accessibilityValue(form.tag.hex == color.hex ? "Selected" : "")
                                .accessibilityIdentifier("workspace-tag-color-" + color.rawValue)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Color · six-digit hex")
                        TextField("Color · six-digit hex", text: $form.tag.hex).labelsHidden()
                            .accessibilityIdentifier("workspace-tag-hex")
                    }
                    Button("Clear tag") { tabs.clearTag(state) }.accessibilityIdentifier("workspace-tag-clear")
                }
            }
        } else { Text("The workspace is no longer available.").foregroundStyle(.secondary) }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(Theme.display(12)).foregroundStyle(Theme.chromeMuted)
    }

    @ViewBuilder private var primaryAction: some View {
        switch state.route {
        case .newSSH:
            Button("Create workspace") { tabs.createSSH(state) }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("ssh-create")
        case .newWorktree:
            Button(form.worktree.mode == .adopt ? "Adopt worktrees" : "Create worktree") {
                Task { await tabs.createWorktree(state) }
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("worktree-create")
        case .workspaceDetails(let id):
            Button("Save tag") { tabs.saveTag(state) }
                .buttonStyle(.borderedProminent).disabled(tabs.workspace(id) == nil)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("workspace-tag-save")
        default: EmptyView()
        }
    }
}
