import AppKit
import SwiftUI

/// Right-click on a Claude Code session in the right panel → Publish to
/// Team ▸ Everyone / a colleague / Choose People…, then a short window to
/// confirm what is published: the session itself (calls continue a copy of
/// its conversation), a fresh agent in its folder, or both.
struct TeamPublishMenu: View {
    /// The Claude Code conversation; nil for other agents, which shows nothing.
    let sessionId: String?
    let title: String
    var service = TeamService.shared

    var body: some View {
        if let sessionId, TeamSessionFiles.isValidId(sessionId) {
            Menu("Publish to Team") {
                if !service.isOn {
                    Button("Turn On Team Work…") { TeamUI.toggleTeamWork() }
                } else {
                    Button("Everyone…") { open(sessionId, audience: nil) }
                    if !service.contacts.isEmpty {
                        Divider()
                        ForEach(service.contacts) { contact in
                            Button("\(contact.displayName)…") { open(sessionId, audience: [contact.id]) }
                        }
                        if service.contacts.count > 1 {
                            Button("Choose People…") { open(sessionId, audience: []) }
                        }
                    } else {
                        Button("Invite Colleague…") { TeamUI.invite() }
                    }
                }
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

    private func open(_ sessionId: String, audience: [String]?) {
        TeamWindows.showPublishSession(sessionId: sessionId, title: title, audience: audience)
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

    @State private var mode: TeamPublishMode = .session
    @State private var sessionName: String
    @State private var folderName = ""
    @State private var description: String
    @State private var access: TeamAccessProfile = .read
    @State private var everyone: Bool
    @State private var chosen: Set<String>
    @State private var folder: String?
    @State private var extraText = ""
    @State private var commandsText = ""
    @State private var error: String?
    @State private var saving = false

    init(sessionId: String, title: String, audience: [String]?, service: TeamService, onClose: @escaping () -> Void) {
        self.sessionId = sessionId.lowercased()
        self.title = title
        self.service = service
        self.onClose = onClose
        let existing = service.calls.agents(forSession: sessionId).first
        let suggested = TeamPublishedAgent.suggestedName(title)
        _sessionName = State(initialValue: existing?.name ?? (suggested.isEmpty ? "session-\(sessionId.prefix(6).lowercased())" : suggested))
        _description = State(initialValue: existing?.description ?? title)
        _access = State(initialValue: existing?.access ?? .read)
        _extraText = State(initialValue: (existing?.extraFolders ?? []).joined(separator: "\n"))
        _commandsText = State(initialValue: (existing?.allowedCommands ?? []).joined(separator: "\n"))
        _everyone = State(initialValue: audience == nil)
        _chosen = State(initialValue: Set(audience ?? []))
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
                if access == .edit {
                    TextField("Allowed commands, one per line", text: $commandsText, prompt: Text("git commit\ncodex exec"), axis: .vertical)
                        .lineLimit(2...5)
                }
                Toggle("Every colleague", isOn: $everyone)
                if !everyone {
                    ForEach(service.contacts) { contact in
                        Toggle(contact.displayName, isOn: Binding(
                            get: { chosen.contains(contact.id) },
                            set: { if $0 { chosen.insert(contact.id) } else { chosen.remove(contact.id) } }
                        ))
                    }
                }
                HStack(alignment: .top) {
                    TextField("More folders, one per line", text: $extraText, prompt: Text("e.g. a second checkout"), axis: .vertical)
                        .lineLimit(1...4)
                    Button("Add…") { if let path = TeamUI.chooseFolder() { extraText += (extraText.isEmpty ? "" : "\n") + path } }
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
                Text("Every call still waits for your Allow.")
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
            folder = await Task.detached { TeamSessionFiles.workingDirectory(of: id) }.value
            if let folder {
                if folderName.isEmpty { folderName = TeamPublishedAgent.suggestedName(URL(fileURLWithPath: folder).lastPathComponent) }
            } else {
                error = "This conversation's file was not found in ~/.claude/projects, so it cannot be published."
            }
        }
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
        let commands = access == .edit
            ? commandsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        let audience: [String]? = everyone ? nil : Array(chosen)
        if audience?.isEmpty == true {
            error = "Choose at least one colleague, or Every colleague."
            return
        }
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
            agent.audience = audience
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
            var agent = service.calls.agents.first { $0.name == folderName.lowercased() && !$0.isSession && $0.folder == folder }
                ?? TeamPublishedAgent(name: folderName, description: text, folder: folder)
            agent.description = text
            agent.folder = folder
            agent.access = access
            agent.audience = audience
            agent.extraFolders = extra
            agent.allowedCommands = commands
            agent.enabled = true
            batch.append(agent)
        }
        saving = true
        defer { saving = false }
        do {
            // Both or neither.
            try await service.calls.save(batch)
            onClose()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}
