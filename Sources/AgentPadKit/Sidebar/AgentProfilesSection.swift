import AppKit
import SwiftUI

struct AgentProfilesSection: View {
    let store: WorkspaceStore
    var history = AgentSessionHistory.shared
    var sharedProfiles: Set<UUID> = []
    var disconnected = false
    var selection: ChatSidebarRowID?
    var select: (ChatSidebarRowID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("My agents").font(Theme.display(11, weight: .semibold)).foregroundStyle(Theme.chromeMuted)
                Spacer()
                Button { LocalFormTabs.shared.newAgent(from: store) } label: {
                    Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("New agent (⌥⌘N)").accessibilityLabel("New agent")
            }
            let profiles = store.agentProfiles.profiles.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
            let attentionCounts = AttentionSidebarModel.shared.profileAttentionCounts
            ForEach(Self.groups(profiles, sharedProfiles: sharedProfiles, disconnected: disconnected), id: \.title) { entry in
                group(entry.title, profiles: entry.profiles, attentionCounts: attentionCounts)
            }
            if profiles.isEmpty {
                Text("Add an agent to start a session.").font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
            }
            if let problem = store.agentProfiles.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            if let problem = store.agentProfiles.details.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 12)
        .onAppear { history.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in history.refresh() }
        .task { await SessionNames.shared.load() }
    }

    static func groups(_ profiles: [AgentProfile], sharedProfiles: Set<UUID>, disconnected: Bool = false)
        -> [(title: String, profiles: [AgentProfile])] {
        [
            (disconnected ? "Shared with team · not connected" : "Shared with team", profiles.filter { sharedProfiles.contains($0.id) }),
            ("Only you", profiles.filter { !sharedProfiles.contains($0.id) })
        ].filter { !$0.1.isEmpty }
    }

    private func group(_ title: String, profiles: [AgentProfile], attentionCounts: [UUID: Int]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.display(10)).foregroundStyle(Theme.chromeMuted).padding(.top, 8)
            ForEach(profiles) { profile in
                AgentProfileRow(store: store, profile: profile, attentionCount: attentionCounts[profile.id] ?? 0,
                    selection: selection, select: select).id(profile.id)
            }
        }
    }
}

private struct AgentProfileRow: View {
    let store: WorkspaceStore
    let profile: AgentProfile
    var attentionCount: Int
    var selection: ChatSidebarRowID?
    var select: (ChatSidebarRowID) -> Void
    private var limit: Int { store.profileHistoryLimits[profile.id] ?? AgentProfileSessions.pageSize }
    @State private var folderExists = true

    private var expanded: Bool { store.expandedAgentProfiles.contains(profile.id) }
    private var template: AgentTemplate? { store.profileTemplates().first { $0.id == profile.templateID } }

    var body: some View {
        let items = expanded ? store.profileSessionItems(profile) : []
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
                    select(.profile(profile.id))
                    folderExists = isDirectory(profile.folder)
                    store.activateAgentProfile(profile.id)
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        ContactAvatar(stableID: profile.id.uuidString, name: profile.name, kind: .agent, size: 24, image: store.agentProfiles.details.image(profile.id))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).font(Theme.display(12, weight: .medium)).lineLimit(1)
                            Text(folderExists ? (template?.title ?? profile.templateID) + (expanded ? " · \(items.isEmpty ? "No sessions yet" : "\(items.count) sessions")" : "") : "Folder not found")
                                .font(Theme.display(10)).foregroundStyle(folderExists ? Theme.chromeMuted : .orange)
                        }
                        Spacer(minLength: 0)
                        if attentionCount > 0 { ChatSidebarBadge(text: "\(attentionCount)", mention: true) }
                    }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).chatFocusRing().help("Start a new session in \(profile.folder.path)")
                .accessibilityLabel("Start a new session with \(profile.name)")
                .onKeyPress(.rightArrow) { store.expandedAgentProfiles.insert(profile.id); return .handled }
                .onKeyPress(.leftArrow) { store.expandedAgentProfiles.remove(profile.id); return .handled }
                Menu {
                    Button("Edit profile…") { SupportTabs.shared.navigation.open(.agentProfile(profile.id), from: store) }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Edit profile")
                .accessibilityLabel("Profile menu for \(profile.name)")
            }
            .id(ChatSidebarRowID.profile(profile.id))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selection == .profile(profile.id) ? ChatAppearance.accent : .clear, lineWidth: 2))
            .background(store.revealedAgentProfileID == profile.id ? Theme.chromeSelection : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            if let error = store.agentProfileErrors[profile.id] {
                Text(error).font(Theme.display(11)).foregroundStyle(.orange).textSelection(.enabled)
                    .padding(.leading, 24)
                Button("All sessions…") { SupportTabs.shared.navigation.open(.allSessions, from: store) }
                    .buttonStyle(.plain).font(Theme.display(11)).padding(.leading, 24)
            }
            if !folderExists {
                Button("Choose folder…", action: chooseFolder).font(Theme.display(11)).padding(.leading, 24)
            }
            if expanded {
                ForEach(AgentProfileSessions.page(items, limit: limit)) { item in
                    Button {
                        select(.history(profile.id, item.id))
                        store.openProfileSession(item, profileID: profile.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.session == nil ? "clock" : "terminal")
                                .font(.system(size: 10)).foregroundStyle(Theme.chromeMuted)
                            Text(item.title).font(Theme.display(11)).lineLimit(1)
                            Spacer(minLength: 3)
                            if let session = item.session, !store.allSessions.contains(where: { $0 === session }) {
                                Image(systemName: "arrow.up.forward.square").help("Open in another window")
                            } else {
                                Text(relativeActivityLabel(item.lastActivity)).font(Theme.mono(9)).foregroundStyle(Theme.chromeMuted)
                            }
                        }
                        .padding(.vertical, 5).padding(.leading, 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!item.canOpen)
                    .help(item.canOpen ? "\(item.title)\n\(item.cwd.path)" : item.unavailableReason)
                    .accessibilityHint(item.canOpen ? "Open this session" : item.unavailableReason)
                    .accessibilityIdentifier(item.id).chatFocusRing().id(ChatSidebarRowID.history(profile.id, item.id))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selection == .history(profile.id, item.id) ? ChatAppearance.accent : .clear, lineWidth: 2))
                    if !item.canOpen {
                        Text("Original folder not found — resume unavailable")
                            .font(Theme.display(10)).foregroundStyle(Theme.chromeMuted).padding(.leading, 24)
                    }
                }
                if items.count > max(AgentProfileSessions.pageSize, limit) {
                    Button("Show more…") { store.profileHistoryLimits[profile.id] = limit + AgentProfileSessions.pageSize }
                        .buttonStyle(.plain).font(Theme.display(11)).foregroundStyle(.tint).padding(.leading, 24).chatFocusRing().id(ChatSidebarRowID.more(profile.id))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selection == .more(profile.id) ? ChatAppearance.accent : .clear, lineWidth: 2))
                }
                Text(items.isEmpty ? "No sessions yet" : "Recent sessions found · results may be incomplete")
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
