import AppKit
import SwiftUI

/// Right-click on a Claude Code session in the right panel → Publish to
/// Team ▸ Publish…, then a short window to confirm what is published: the
/// session itself (calls continue a copy of its conversation), a fresh agent
/// in its folder, or both. Every colleague may call it until the server's
/// teams decide who may (D stage).
struct TeamPublishMenu: View {
    /// The Claude Code conversation; nil for other agents, which shows nothing.
    let sessionId: String?
    let title: String
    var surfaceId: UUID? = nil
    var service = TeamService.shared

    var body: some View {
        if let sessionId, TeamSessionFiles.isValidId(sessionId), ChannelConversationFilter.current().allows(conversationId: sessionId) {
            Menu("Publish to Team") {
                Button("Publish…") { TeamWindows.showPublishSession(sessionId: sessionId, title: title, surfaceId: surfaceId) }
                let published = service.calls.agents(forSession: sessionId)
                if !published.isEmpty {
                    Divider()
                    Button("Stop Publishing This Session") {
                        Task { await TeamUI.stopPublishing(published) }
                    }
                }
            }
        }
    }
}

/// What a session is published as.
enum TeamPublishMode: String, CaseIterable, Identifiable {
    case session, folder, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .session: "This session"
        case .folder: "New agent in its folder"
        case .both: "Both"
        }
    }
}

struct TeamPublishSessionView: View {
    let sessionId: String
    let title: String
    let service: TeamService
    let onClose: () -> Void
    let surfaceId: UUID?

    @State private var mode: TeamPublishMode = .session
    @State private var sessionName: String
    @State private var folderName = ""
    @State private var description: String
    @State private var access: TeamAccessProfile = .read
    @State private var folder: String?
    @State private var extraText = ""
    @State private var commandsText = ""
    @State private var error: String?
    @State private var saving = false
    /// Server mode: the organization fixed when the window opened (state,
    /// kept over the view's rebuilds: review D3b-p1-2), the member's teams
    /// and those chosen (D3), General first.
    @State private var key: ChatOrgKey?
    @State private var teams: [ChatSnapshot.Team]?
    @State private var chosen: Set<String>
    /// The agents whose teams `chosen` was last restored from: restored
    /// again only when the agent edited changes (review D3c-p2-3).
    @State private var restoredFor: [UUID]?

    init(sessionId: String, title: String, service: TeamService, surfaceId: UUID? = nil, onClose: @escaping () -> Void) {
        self.sessionId = sessionId.lowercased()
        self.title = title
        self.service = service
        self.onClose = onClose
        self.surfaceId = surfaceId
        let existing = service.calls.agents(forSession: sessionId).first
        let suggested = TeamPublishedAgent.suggestedName(title)
        _sessionName = State(initialValue: existing?.name ?? (suggested.isEmpty ? "session-\(sessionId.prefix(6).lowercased())" : suggested))
        _description = State(initialValue: existing?.description ?? title)
        _access = State(initialValue: existing?.access ?? .read)
        _extraText = State(initialValue: (existing?.extraFolders ?? []).joined(separator: "\n"))
        _commandsText = State(initialValue: (existing?.allowedCommands ?? []).joined(separator: "\n"))
        let key = service.calls.serverMode ? service.calls.serverKey : nil
        let teams = key.map { ChatService.shared.myTeams($0) }
        _key = State(initialValue: key)
        _teams = State(initialValue: teams)
        _chosen = State(initialValue: Set((teams ?? []).filter(\.isGeneral).map(\.teamId)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Publish “\(title.isEmpty ? "untitled session" : title)”")
                .font(Theme.display(14, weight: .semibold))
                .lineLimit(2)
            Form {
                Picker("Publish", selection: $mode) {
                    ForEach(TeamPublishMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: mode) { restoreTeams() }
                .onChange(of: folderName) { restoreTeams() }
                Text(modeExplanation)
                    .font(Theme.display(10.5))
                    .foregroundStyle(Theme.chromeMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if mode != .folder {
                    TextField("Session's name", text: $sessionName, prompt: Text("fix-login"))
                }
                if mode != .session {
                    TextField("Agent's name", text: $folderName, prompt: Text("backend"))
                }
                TextField("What to ask it", text: $description, axis: .vertical)
                    .lineLimit(2...4)
                Picker("Rights", selection: $access) {
                    ForEach(TeamAccessProfile.allCases) { Text($0.title).tag($0) }
                }
                Text(access.summary)
                    .font(Theme.display(10.5))
                    .foregroundStyle(Theme.chromeMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if access.takesCommands {
                    TextField("Allowed commands, one per line", text: $commandsText, prompt: Text("git commit\ncodex exec"), axis: .vertical)
                        .lineLimit(2...5)
                }
                HStack(alignment: .top) {
                    TextField("More folders, one per line", text: $extraText, prompt: Text("e.g. a second checkout"), axis: .vertical)
                        .lineLimit(1...4)
                    Button("Add…") { if let path = TeamUI.chooseFolder() { extraText += (extraText.isEmpty ? "" : "\n") + path } }
                }
                if let teams {
                    Section("Publish to") {
                        ForEach(teams, id: \.teamId) { team in
                            Toggle(team.name, isOn: Binding(
                                get: { chosen.contains(team.teamId) },
                                set: { on in if on { chosen.insert(team.teamId) } else { chosen.remove(team.teamId) } }
                            ))
                        }
                        let names = teams.filter { chosen.contains($0.teamId) }.map(\.name)
                        ForEach(TeamPublishWarnings.lines(access: access, fromSession: mode != .folder, teamNames: names), id: \.self) { line in
                            Text(line).font(Theme.display(10.5)).foregroundStyle(Theme.chromeMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                LabeledContent("Folder") {
                    Text(folder ?? "…")
                        .font(Theme.mono(10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .formStyle(.grouped)
            .frame(height: 440)
            .disabled(saving)
            if let error {
                Text(error).font(Theme.display(11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Channel calls can run and publish automatically.")
                    .font(Theme.display(10.5))
                    .foregroundStyle(Theme.chromeMuted)
                Spacer()
                Button("Cancel", action: onClose).disabled(saving)
                Button("Publish") { Task { await publish() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || folder == nil)
            }
        }
        .padding(18)
        .frame(width: 500)
        .task {
            let id = sessionId
            let sessionRoot = service.calls.sessionFilesRoot
            folder = await Task.detached { TeamSessionFiles.workingDirectory(of: id, root: sessionRoot) }.value
            if let folder {
                if folderName.isEmpty { folderName = TeamPublishedAgent.suggestedName(URL(fileURLWithPath: folder).lastPathComponent) }
                restoreTeams()
            } else {
                error = "This conversation's file was not found in ~/.claude/projects, so it cannot be published."
            }
        }
    }

    /// The teams the owner chose for the agents this mode publishes — the
    /// session's, the folder's (found as `publish` finds it) — else General
    /// (review D3-p1-4, D3b-p1-4).
    private func restoreTeams() {
        guard let key, let teams else { return }
        let edited = Self.edited(mode: mode, sessionId: sessionId, folderName: folderName, folder: folder, calls: service.calls)
        if let next = Self.restored(edited: edited, previous: restoredFor, general: teams.filter(\.isGeneral).map(\.teamId),
                                    earlier: { ChatService.shared.chosenTeams($0, key: key) }) {
            chosen = next
        }
        restoredFor = edited.map(\.id)
    }

    /// The teams to show when the agents edited are `edited` (they were
    /// `previous`): theirs — General only for a new publication — or nil
    /// when the agent edited did not change, so the owner's own choice stays.
    static func restored(edited: [TeamPublishedAgent], previous: [UUID]?, general: [String],
                         earlier: (UUID) -> [String]?) -> Set<String>? {
        guard edited.map(\.id) != previous else { return nil }
        return Set(edited.compactMap { earlier($0.id) }.first ?? general)
    }

    /// The existing agents a publication in `mode` changes.
    static func edited(mode: TeamPublishMode, sessionId: String, folderName: String, folder: String?,
                       calls: TeamCalls) -> [TeamPublishedAgent] {
        var out: [TeamPublishedAgent] = []
        if mode != .folder, let agent = calls.agents(forSession: sessionId).first { out.append(agent) }
        if mode != .session, let folder, let agent = folderAgent(name: folderName, folder: folder, calls: calls) { out.append(agent) }
        return out
    }

    /// The folder agent of this session's folder by that name: an update of it.
    static func folderAgent(name: String, folder: String, calls: TeamCalls) -> TeamPublishedAgent? {
        calls.agents.first { $0.name == name.lowercased() && !$0.isSession && $0.folder == folder }
    }

    private var modeExplanation: String {
        switch mode {
        case .session:
            "Each call runs on a copy of this conversation: the agent knows everything discussed here, and the session itself is not touched. Colleagues may learn from answers what was discussed. When the conversation is deleted, the agent disappears."
        case .folder:
            "A fresh agent that starts from a clean slate in this session's folder each time."
        case .both:
            "Colleagues see both and choose: this session, with its conversation, or a fresh agent in its folder."
        }
    }

    private func publish() async {
        guard let folder, !saving else { return }
        // Fixed now: the form may change while the save waits.
        let mode = self.mode, access = self.access
        let sessionName = self.sessionName, folderName = self.folderName
        let extra = extraText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let commands = access.takesCommands
            ? commandsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            error = "Say what to ask it: colleagues' agents read this to decide."
            return
        }
        var batch: [TeamPublishedAgent] = []
        if mode != .folder {
            // Republishing the same session updates its agent.
            var agent = service.calls.agents(forSession: sessionId).first
                ?? TeamPublishedAgent(name: sessionName, description: text, folder: folder)
            agent.name = sessionName
            agent.description = text
            agent.access = access
            agent.sessionId = sessionId
            agent.sessionTitle = title
            agent.extraFolders = extra
            agent.allowedCommands = commands
            agent.enabled = true
            batch.append(agent)
        }
        if mode != .session {
            // Same name and folder: an update. A name taken by another
            // agent is refused by `save`.
            var agent = Self.folderAgent(name: folderName, folder: folder, calls: service.calls)
                ?? TeamPublishedAgent(name: folderName, description: text, folder: folder)
            agent.description = text
            agent.folder = folder
            agent.access = access
            agent.extraFolders = extra
            agent.allowedCommands = commands
            agent.enabled = true
            batch.append(agent)
        }
        saving = true
        defer { saving = false }
        do {
            // Both or neither on this Mac; through a server each is published
            // on its own, and the Published Agents window says how each went.
            if let teams, let key {
                try await service.calls.saveAndPublish(batch, teams: teams.filter { chosen.contains($0.teamId) }.map(\.teamId), key: key)
                for agent in batch where agent.isSession {
                    try ChatService.shared.bindPublication(key, agent: agent.id.uuidString.lowercased(), surface: surfaceId)
                }
            } else {
                try await service.calls.save(batch)
            }
            onClose()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}
