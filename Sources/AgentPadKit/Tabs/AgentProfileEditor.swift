import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class AgentProfileEditor {
    enum Recovery: Equatable { case retry, reload, choose }
    enum Operation: Equatable {
        case idle, loading, saving, saved(String), failed(String, recovery: Recovery)
        var busy: Bool { self == .loading || self == .saving }
    }
    let id: UUID
    let profiles: AgentProfileStore
    let avatarService: ChatService
    var name: String
    private var originalName: String
    var source: CGImage?
    var crop = AvatarCrop()
    var operation = Operation.idle
    private(set) var revision: Int
    private var generation = 0
    private var active = true
    private var pending: Data?
    private var removing = false

    init(profile: AgentProfile, profiles: AgentProfileStore, avatarService: ChatService = .shared) {
        self.avatarService = avatarService
        id = profile.id; self.profiles = profiles; name = profile.name; originalName = profile.name
        revision = profiles.details.avatar(profile.id).revision
    }

    func choose(_ url: URL) async {
        guard active, !operation.busy else { return }
        generation += 1; let ticket = generation
        operation = .loading
        let result = await Task.detached(priority: .userInitiated) { Result { try LocalAvatarImage.read(url) } }.value
        guard ticket == generation else { return }
        switch result {
        case .success(let image): source = image; crop = AvatarCrop(); operation = .idle; pending = nil
        case .failure(let error): operation = .failed(error.localizedDescription, recovery: .choose)
        }
    }

    func cancelCrop() {
        guard active, !operation.busy else { return }
        generation += 1; source = nil; pending = nil; operation = .idle
    }

    func invalidate() { active = false; generation += 1; source = nil; pending = nil }

    func saveCrop() async {
        guard active, !operation.busy, let source else { return }
        generation += 1; let ticket = generation, crop = crop
        operation = .saving
        let result = await Task.detached(priority: .userInitiated) { Result { try LocalAvatarImage.png(source, crop: crop) } }.value
        guard ticket == generation else { return }
        switch result {
        case .success(let data): pending = data; removing = false; commitAvatar()
        case .failure(let error): operation = .failed(error.localizedDescription, recovery: .choose)
        }
    }

    func remove() async {
        guard active, !operation.busy else { return }
        operation = .saving; pending = nil; removing = true
        let ticket = generation
        await Task.yield()
        guard ticket == generation else { return }
        commitAvatar()
    }

    func retry() async {
        guard active, !operation.busy else { return }
        if pending != nil || removing {
            let ticket = generation
            operation = .saving; await Task.yield()
            guard ticket == generation else { return }
            commitAvatar()
        } else if source != nil { await saveCrop() }
        else { saveName() }
    }

    private func commitAvatar() {
        do {
            guard profiles.profile(id) != nil else { throw AgentProfileStore.Problem.missingProfile }
            try profiles.details.saveAvatar(pending, for: id, expectedRevision: revision)
            revision = profiles.details.avatar(id).revision
            source = nil; pending = nil
            operation = .saved(removing ? "Avatar removed" : "Avatar saved on this Mac")
            removing = false
            avatarService.publishProfileAvatar(id, profiles: profiles)
        } catch { operation = .failed(error.localizedDescription, recovery: (error as? LocalAvatarError) == .changed ? .reload : .retry) }
    }

    func reload() {
        generation += 1; source = nil; pending = nil; removing = false
        name = profiles.profile(id)?.name ?? name; originalName = name
        revision = profiles.details.avatar(id).revision; operation = .idle
    }

    func saveName() {
        guard active, !operation.busy else { return }
        guard profiles.profile(id)?.name == originalName else {
            operation = .failed("This profile changed in another editor. Reload before saving.", recovery: .reload); return
        }
        guard let value = normalizedTitle(name), InlineNameEdit.problem(value) == nil else {
            operation = .failed("Enter a single-line profile name.", recovery: .retry); return
        }
        do {
            try profiles.rename(id, to: value); name = value; originalName = value
            operation = .saved("Profile saved on this Mac")
        } catch { operation = .failed(error.localizedDescription, recovery: .retry) }
    }
}

struct AgentProfileEditorView: View {
    let state: TabState
    @Bindable var editor: AgentProfileEditor

    private var profile: AgentProfile? { editor.profiles.profile(editor.id) }
    private var sharedWithTeam: Bool {
        let model = ChatOrgCurrent.shared.model
        let snapshot = ChatSidebarSnapshot(model: model, active: nil)
        guard case .ready = snapshot.state, let key = model?.key else {
            return editor.profiles.details.archive.confirmedPublications?.contains { $0.profileID == editor.id } == true
        }
        return ChatService.shared.localProfilePublications(editor.profiles, key: key, agents: snapshot.agents).profiles.contains(editor.id)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(editor.source == nil ? "Edit profile" : "Crop agent avatar").font(Theme.display(22, weight: .semibold))
                        Text(editor.source == nil ? "A familiar identity for every session." : "Position your image")
                            .font(Theme.display(12)).foregroundStyle(Theme.chromeMuted)
                    }
                    Spacer()
                    Label(sharedWithTeam ? "Shared with team" : "Only you", systemImage: sharedWithTeam ? "person.2" : "lock").font(Theme.display(11))
                }
                VStack(alignment: .leading, spacing: 22) {
                    if let source = editor.source { cropArea(source) }
                    else { profileFields }
                    operationBlock
                    PublishedProfileAvatars(profile: editor.id, profiles: editor.profiles)
                    if let problem = editor.profiles.details.problem {
                        Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    let publications = TeamService.shared.calls.agents.filter {
                        editor.profiles.details.archive.publications[$0.id.uuidString] == editor.id
                    }
                    if !publications.isEmpty {
                        Menu("Manage publication…") {
                            ForEach(publications) { publication in
                                Button(publication.name) {
                                    let scope = TeamTabs.shared.assignment(publication.id).map { TeamScope.server(OrgKey($0)) } ?? .local
                                    TeamTabs.shared.open(.publication(scope, publicationID: publication.id.uuidString.lowercased()), from: SupportTabs.shared.owner(state)?.store)
                                }
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Text(sharedWithTeam ? "Save also updates the team avatar when connected. Unconfirmed changes stay marked until Retry succeeds." : "Saved with your local profile. Connecting a team won’t upload this avatar.")
                            .font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
                        Spacer()
                        Button("Cancel") {
                            if editor.source != nil { editor.cancelCrop() }
                            else { close() }
                        }.keyboardShortcut(.cancelAction)
                        Button("Save") {
                            if editor.source != nil { Task { await editor.saveCrop() } }
                            else { editor.saveName() }
                        }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                    }.disabled(editor.operation.busy)
                }.padding(24).background(Theme.chromeSelection.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.chromeHairline))
            }.frame(maxWidth: 700).padding(32).frame(maxWidth: .infinity)
        }.foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
            .environment(\.colorScheme, Theme.chromeColorScheme)
    }

    private var profileFields: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 20) {
                ContactAvatar(stableID: editor.id.uuidString, name: profile?.name ?? editor.name, kind: .agent, size: 88,
                              image: editor.profiles.details.image(editor.id))
                VStack(alignment: .leading, spacing: 8) {
                    Text(profile?.name ?? editor.name).font(Theme.display(18, weight: .semibold))
                    Text("Agent avatar").font(Theme.display(12)).foregroundStyle(Theme.chromeMuted)
                    HStack {
                        Button(editor.profiles.details.avatar(editor.id).file == nil ? "Choose photo…" : "Change…", action: choose)
                        if editor.profiles.details.avatar(editor.id).file != nil {
                            Button("Remove") { Task { await editor.remove() } }
                        }
                    }.disabled(editor.operation.busy)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                GridRow { Text("Name"); TextField("Name", text: $editor.name).textFieldStyle(.roundedBorder) }
                GridRow {
                    Text("Tool")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.flatMap { p in AgentTemplate.all.first { $0.id == p.templateID } }?.title ?? profile?.templateID ?? "Unavailable")
                        Text("To use another tool, add a new agent.").font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
                    }
                }
                GridRow {
                    Text("Folder")
                    Text(profile?.folder.path ?? "Unavailable").font(Theme.mono(11)).textSelection(.enabled)
                        .lineLimit(3).truncationMode(.middle)
                }
            }.font(Theme.display(12)).disabled(editor.operation.busy)
        }
    }

    private func cropArea(_ source: CGImage) -> some View {
        AvatarCropView(source: source, crop: $editor.crop, stableID: editor.id.uuidString, name: editor.name,
                       kind: .agent, disabled: editor.operation.busy, choose: choose)
    }

    @ViewBuilder private var operationBlock: some View {
        switch editor.operation {
        case .idle: EmptyView()
        case .loading, .saving:
            HStack { ProgressView().controlSize(.small); Text(editor.operation == .loading ? "Reading image…" : "Saving…") }
                .font(Theme.display(12)).accessibilityLabel("Your current avatar stays visible until saving finishes")
        case .saved(let message): Label(message, systemImage: "checkmark.circle").font(Theme.display(12)).foregroundStyle(.green)
        case .failed(let message, let recovery):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle").font(Theme.display(12)).textSelection(.enabled)
                HStack {
                    if recovery == .reload { Button("Reload", action: editor.reload) }
                    else {
                        if recovery == .retry { Button("Retry") { Task { await editor.retry() } } }
                        Button("Choose another…", action: choose)
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func choose() {
        guard !editor.operation.busy, let window = NSApp.keyWindow else { return }
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.jpeg, .png]
        picker.allowsMultipleSelection = false; picker.canChooseDirectories = false
        let revision = state.revision
        picker.beginSheetModal(for: window) { response in
            guard response == .OK, let url = picker.url, !state.isClosed, state.revision == revision else { return }
            Task { await editor.choose(url) }
        }
    }
    private func close() {
        guard let owner = SupportTabs.shared.owner(state) else { return }
        editor.invalidate(); owner.store.closeTab(owner.session, in: owner.workspace)
    }
}
