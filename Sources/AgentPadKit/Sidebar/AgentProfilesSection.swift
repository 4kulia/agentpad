import AppKit
import SwiftUI

struct AgentProfilesSection: View {
    let store: WorkspaceStore
    var history = AgentSessionHistory.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Agents").font(Theme.display(11, weight: .semibold)).foregroundStyle(Theme.chromeMuted)
                Spacer()
                Button { LocalFormTabs.shared.newAgent(from: store) } label: {
                    Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("New agent (⌥⌘N)").accessibilityLabel("New agent")
            }
            ForEach(store.agentProfiles.profiles) { profile in
                AgentProfileRow(store: store, profile: profile).id(profile.id)
            }
            if let problem = store.agentProfiles.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 12)
        .onAppear { history.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in history.refresh() }
        .task { await SessionNames.shared.load() }
    }
}

private struct AgentProfileRow: View {
    let store: WorkspaceStore
    let profile: AgentProfile
    @State private var limit = AgentProfileSessions.pageSize
    @State private var folderExists = true

    private var expanded: Bool { store.expandedAgentProfiles.contains(profile.id) }
    private var template: AgentTemplate? { store.profileTemplates().first { $0.id == profile.templateID } }

    var body: some View {
        let items = store.profileSessionItems(profile)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Button {
                    if expanded { store.expandedAgentProfiles.remove(profile.id) }
                    else { store.expandedAgentProfiles.insert(profile.id) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10)).frame(width: 22, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Sessions for \(profile.name)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                Button {
                    folderExists = isDirectory(profile.folder)
                    store.startAgentProfile(profile.id)
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        AgentIconView(asset: template?.iconAsset, fallbackSymbol: template?.symbol ?? "sparkles", size: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).font(Theme.display(12, weight: .medium)).lineLimit(1)
                            Text(folderExists ? (template?.title ?? profile.templateID) : "Folder not found")
                                .font(Theme.display(10)).foregroundStyle(folderExists ? Theme.chromeMuted : .orange)
                            Text((profile.folder.path as NSString).abbreviatingWithTildeInPath)
                                .font(Theme.mono(9.5)).foregroundStyle(Theme.chromeMuted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Start a new session in \(profile.folder.path)")
                .accessibilityLabel("Start a new session with \(profile.name)")
            }
            .background(store.revealedAgentProfileID == profile.id ? Theme.chromeSelection : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            if let error = store.agentProfileErrors[profile.id] {
                Text(error).font(Theme.display(11)).foregroundStyle(.orange).textSelection(.enabled)
                    .padding(.leading, 24)
            }
            if !folderExists {
                Button("Choose folder…", action: chooseFolder).font(Theme.display(11)).padding(.leading, 24)
            }
            if expanded {
                ForEach(AgentProfileSessions.page(items, limit: limit)) { item in
                    Button {
                        store.openProfileSession(item, profileID: profile.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.session == nil ? "clock" : "terminal")
                                .font(.system(size: 10)).foregroundStyle(Theme.chromeMuted)
                            Text(item.title).font(Theme.display(11)).lineLimit(1)
                            Spacer(minLength: 3)
                            Text(relativeActivityLabel(item.lastActivity)).font(Theme.mono(9)).foregroundStyle(Theme.chromeMuted)
                        }
                        .padding(.vertical, 5).padding(.leading, 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!item.canOpen)
                    .help(item.canOpen ? "\(item.title)\n\(item.cwd.path)" : item.unavailableReason)
                    .accessibilityHint(item.canOpen ? "Open this session" : item.unavailableReason)
                    .accessibilityIdentifier(item.id)
                    if !item.canOpen {
                        Text("Original folder not found — resume unavailable")
                            .font(Theme.display(10)).foregroundStyle(Theme.chromeMuted).padding(.leading, 24)
                    }
                }
                if items.count > max(AgentProfileSessions.pageSize, limit) {
                    Button("Show more") { limit += AgentProfileSessions.pageSize }
                        .buttonStyle(.plain).font(Theme.display(11)).foregroundStyle(.tint).padding(.leading, 24)
                }
                Text(items.isEmpty ? "No sessions found in checked sources" : "Recent sessions found · results may be incomplete")
                    .font(Theme.display(10)).foregroundStyle(Theme.chromeMuted).padding(.leading, 24)
            }
        }
        .onAppear { folderExists = isDirectory(profile.folder) }
        .onChange(of: profile.folder) { _, folder in folderExists = isDirectory(folder) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            folderExists = isDirectory(profile.folder)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose folder"
        guard let window = TabRouter.shared.stores().first(where: { $0 === store })?.active?.activeSession?.engine.view.window
            ?? NSApp.keyWindow else { return }
        let originalFolder = profile.folder
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, !store.isTerminated,
                  store.agentProfiles.profile(profile.id)?.folder == originalFolder else { return }
            do {
                try store.agentProfiles.move(profile.id, to: url)
                store.agentProfileErrors[profile.id] = nil
                folderExists = true
            } catch { store.agentProfileErrors[profile.id] = error.localizedDescription }
        }
    }
}
