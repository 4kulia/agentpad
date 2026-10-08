import CryptoKit
import Foundation

/// Explicit form schema: raw input survives validation errors. No credentials,
/// environment, temporary consent or process authority is serialized.
struct PublicationDraft: Codable, Equatable {
    var agentID = UUID()
    var name = ""
    var description = ""
    var folder = ""
    var access: TeamAccessProfile = .read
    var deniedText = TeamPublishedAgent.defaultDeniedPaths.joined(separator: "\n")
    var extraText = ""
    var commandsText = ""
    var modelText = ""
    var budgetText = ""
    var maxTurns = 30
    var timeoutMinutes = 15
    var enabled = true
    var teamIDs: Set<String> = []
    var sessionID: String?
    var sessionTitle: String?
    var sourceSurfaceID: UUID?
    var sourceConversationID: String?
    var mode: TeamPublishMode?
    var folderName = ""
    var folderAgentID = UUID()
    /// Digests of domain versions, not a second serialized domain model.
    var versions: [UUID: String] = [:]
    var teamVersions: [UUID: [String]] = [:]

    init() {}
    init(_ agent: TeamPublishedAgent) {
        agentID = agent.id; name = agent.name; description = agent.description; folder = agent.folder
        access = agent.access; deniedText = agent.deniedPaths.joined(separator: "\n")
        extraText = (agent.extraFolders ?? []).joined(separator: "\n")
        commandsText = agent.allowedCommands.joined(separator: "\n")
        modelText = agent.model ?? ""; budgetText = agent.maxBudgetUSD.map(String.init(describing:)) ?? ""
        maxTurns = agent.maxTurns; timeoutMinutes = agent.timeoutMinutes; enabled = agent.enabled
        sessionID = agent.sessionId; sessionTitle = agent.sessionTitle
        versions[agent.id] = Self.version(agent)
    }
    static func version(_ agent: TeamPublishedAgent) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try! encoder.encode(agent)).map { String(format: "%02x", $0) }.joined()
    }
    func applying(to existing: TeamPublishedAgent?) throws -> TeamPublishedAgent {
        var agent = existing ?? TeamPublishedAgent(name: name, description: description, folder: folder)
        agent.id = agentID; agent.name = name; agent.description = description; agent.folder = folder
        agent.access = access; agent.deniedPaths = Self.lines(deniedText); agent.extraFolders = Self.lines(extraText)
        agent.allowedCommands = access.takesCommands ? Self.lines(commandsText) : []
        agent.model = modelText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : modelText.trimmingCharacters(in: .whitespaces)
        let budget = budgetText.trimmingCharacters(in: .whitespaces)
        if budget.isEmpty { agent.maxBudgetUSD = nil }
        else if let value = Double(budget.replacingOccurrences(of: ",", with: ".")), value.isFinite, value > 0 {
            agent.maxBudgetUSD = value
        } else { throw TeamError.storage("The budget is a number of dollars, e.g. 2.5.") }
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TeamError.storage("Say what to ask it: colleagues' agents read this to decide.")
        }
        agent.maxTurns = maxTurns; agent.timeoutMinutes = timeoutMinutes; agent.enabled = enabled
        agent.sessionId = sessionID; agent.sessionTitle = sessionTitle
        return agent
    }
    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

@MainActor @Observable
final class PublicationFormState {
    var fields = PublicationDraft() { didSet { changed(fields) } }
    var error: String?
    var status: String?
    var working = false
    var loading = false
    var loaded = false
    var restoredTargets: [UUID] = []
    @ObservationIgnored var changed: (PublicationDraft) -> Void = { _ in }
}

extension TeamTabs {
    func form(_ state: TabState, title: String = "") -> PublicationFormState {
        if let form = state.publicationForm { return form }
        let form = PublicationFormState()
        state.publicationForm = form
        restore(form, state: state, title: title.isEmpty ? state.transient["publicationSourceTitle"] ?? "" : title)
        form.changed = { [weak state] fields in
            guard let state else { return }
            state.confirmation.invalidate(); state.edit(.publicationForm(fields))
        }
        state.discardEdits = { [weak self, weak state] in
            guard let self, let state, let form = state.publicationForm else { return }
            let changed = form.changed; form.changed = { _ in }
            self.restore(form, state: state); form.changed = changed
        }
        return form
    }

    private func restore(_ form: PublicationFormState, state: TabState, title: String = "") {
        form.error = nil
        if case .publicationForm(let fields) = state.draft?.payload {
            form.fields = fields; form.restoredTargets = targetIDs(fields); return
        }
        guard let scope = state.route.teamScope, canRead(scope) else { return }
        var fields = PublicationDraft()
        if case .publication(_, let id) = state.route {
            guard let agent = agents(scope).first(where: { $0.id.uuidString.lowercased() == id.lowercased() }) else {
                form.error = "This publication is no longer available."; return
            }
            fields = PublicationDraft(agent)
        } else if case .publish(_, _, let surface, let conversation) = state.route {
            if let conversation, let existing = agents(scope).first(where: { $0.sessionId == conversation }) {
                fields = PublicationDraft(existing)
            }
            fields.sourceSurfaceID = surface; fields.sourceConversationID = conversation
            if let conversation {
                fields.mode = .session; fields.sessionID = conversation
                fields.sessionTitle = fields.sessionTitle ?? title
                let name = TeamPublishedAgent.suggestedName(title)
                if fields.name.isEmpty { fields.name = name.isEmpty ? "session-\(conversation.prefix(6))" : name }
                if fields.description.isEmpty { fields.description = title }
            } else if scope == .local {
                fields.access = .readGit
            }
        }
        if case .server(let key) = scope {
            let chosen = chosenTeams(fields.agentID, key.chatKey)
            fields.teamIDs = Set(chosen ?? teams(scope).filter(\.isGeneral).map(\.teamId))
            fields.teamVersions[fields.agentID] = chosen?.sorted()
        }
        if case .publication(let name, let folder, let instructions, let teams) = state.draft?.payload {
            fields.name = name; fields.folder = folder; fields.description = instructions; fields.teamIDs = Set(teams)
        }
        form.fields = fields
        form.restoredTargets = targetIDs(fields)
        // Stable new publication IDs are durable before the first submission.
        if case .publish = state.route { state.edit(.publicationForm(fields)) }
    }

    func loadSource(_ state: TabState) async {
        let form = form(state)
        guard !form.loaded, !form.loading, let conversation = form.fields.sourceConversationID else { return }
        form.loading = true
        let root = service.calls.sessionFilesRoot
        let folder = await Task.detached { TeamSessionFiles.workingDirectory(of: conversation, root: root) }.value
        form.loading = false
        guard !state.isClosed else { return }
        form.loaded = true
        guard let folder else { form.error = "This conversation's file was not found in ~/.claude/projects."; return }
        if form.fields.folder.isEmpty {
            form.fields.folder = folder
            if form.fields.folderName.isEmpty { form.fields.folderName = TeamPublishedAgent.suggestedName(URL(fileURLWithPath: folder).lastPathComponent) }
            updateFolderTarget(state)
        } else if form.fields.folder != folder {
            form.error = "The source conversation's folder changed. The saved draft has been kept."
        }
    }

    func updateFolderTarget(_ state: TabState) {
        let form = form(state), fields = form.fields
        guard !form.working, fields.mode != nil, let scope = state.route.teamScope, canRead(scope) else { return }
        let existing = agents(scope).first { !$0.isSession && $0.name == fields.folderName.lowercased() && $0.folder == fields.folder }
        if let existing, existing.id != fields.folderAgentID {
            form.fields.folderAgentID = existing.id
            form.fields.versions[existing.id] = PublicationDraft.version(existing)
            if case .server(let key) = scope { form.fields.teamVersions[existing.id] = chosenTeams(existing.id, key.chatKey)?.sorted() }
        } else if existing == nil, fields.versions[fields.folderAgentID] != nil {
            form.fields.folderAgentID = UUID()
        }
        let ids = targetIDs(form.fields)
        if case .server(let key) = scope,
           let chosen = TeamSessionPublication.restored(edited: ids.compactMap { id in agents(scope).first { $0.id == id } },
               previous: form.restoredTargets, general: teams(scope).filter(\.isGeneral).map(\.teamId),
               earlier: { chosenTeams($0, key.chatKey) }) { form.fields.teamIDs = chosen }
        form.restoredTargets = ids
    }

    private func targetIDs(_ fields: PublicationDraft) -> [UUID] {
        var ids: [UUID] = []
        if fields.mode != .folder, fields.versions[fields.agentID] != nil { ids.append(fields.agentID) }
        if let mode = fields.mode, mode != .session, fields.versions[fields.folderAgentID] != nil { ids.append(fields.folderAgentID) }
        return ids
    }

    func batch(_ fields: PublicationDraft) throws -> [TeamPublishedAgent] {
        let current = service.calls.agents.first { $0.id == fields.agentID }
        let agent = try fields.applying(to: current)
        guard let mode = fields.mode else { return [agent] }
        var batch: [TeamPublishedAgent] = mode == .folder ? [] : [agent]
        if mode != .session {
            var folder = fields
            folder.agentID = fields.folderAgentID; folder.name = fields.folderName
            folder.sessionID = nil; folder.sessionTitle = nil
            batch.append(try folder.applying(to: service.calls.agents.first { $0.id == fields.folderAgentID }))
        }
        return batch
    }

    func validate(_ fields: PublicationDraft, scope: TeamScope, identity: String?) throws {
        guard canRead(scope), connectionIdentity() == identity else { throw TeamError.notYet(TeamServerCore.changedMeanwhile) }
        if case .server = scope, fields.enabled {
            guard !fields.teamIDs.isEmpty, fields.teamIDs.isSubset(of: Set(teams(scope).map(\.teamId))) else {
                throw TeamError.storage("A chosen team is no longer available. Check the publication's teams.")
            }
        }
        for agent in try batch(fields) {
            let current = service.calls.agents.first { $0.id == agent.id }
            guard current.map(PublicationDraft.version) == fields.versions[agent.id] else {
                throw TeamError.storage("This publication changed since the editor was opened. Your edits have been kept. Review the current version before saving.")
            }
            if let assigned = assignment(agent.id), scope != .server(OrgKey(assigned)) { throw TeamError.notConnected }
            if case .server(let key) = scope, chosenTeams(agent.id, key.chatKey)?.sorted() != fields.teamVersions[agent.id] {
                throw TeamError.storage("This publication's teams changed. Your edits have been kept. Review the current version before saving.")
            }
        }
        if let source = fields.sourceConversationID ?? fields.sessionID {
            guard service.calls.conversationVisibility().allows(conversationId: source),
                  TeamSessionFiles.workingDirectory(of: source, root: service.calls.sessionFilesRoot) == fields.folder else {
                throw TeamError.storage("The source conversation is no longer available in the saved folder.")
            }
        }
    }

    func requestSave(_ state: TabState) {
        let form = form(state)
        guard !form.working, !form.loading, let scope = state.route.teamScope, let location = owner(state) else { return }
        let fields = form.fields, identity = connectionIdentity()
        do {
            try validate(fields, scope: scope, identity: identity)
            try location.store.tabCloseCoordinator.save(state)
        }
        catch { form.error = error.localizedDescription; return }
        let names = teams(scope).filter { fields.teamIDs.contains($0.teamId) }.map(\.name)
        let warning = TeamPublishWarnings.lines(access: fields.access, fromSession: fields.sessionID != nil && fields.mode != .folder, teamNames: names)
        state.confirmation.request(.init(tabID: location.session.id, targetID: fields.agentID.uuidString,
            scope: state.route.organizationScope, generation: identity, revision: String(state.draft?.revision ?? 0),
            deadline: Date().addingTimeInterval(120)),
            title: "Save publication \(fields.name)?", consequences: ([fields.access.summary] + warning).joined(separator: "\n\n"),
            verb: fields.enabled ? "Publish" : "Save", stillValid: { [self] in
                form.fields == fields && (try? validate(fields, scope: scope, identity: identity)) != nil
            }) { [self] in
                try await save(state, fields: fields, scope: scope, identity: identity)
            }
    }

    func save(_ state: TabState, fields: PublicationDraft, scope: TeamScope, identity: String?) async throws {
        let form = form(state)
        guard !form.working else { return }
        let batch = try batch(fields)
        let submittedDraft = state.draft
        let initialRepository = owner(state)?.store.drafts
        form.working = true; form.error = nil; form.status = nil
        defer { form.working = false }
        let check = { [self] in try validate(fields, scope: scope, identity: identity) }
        // A local save may succeed before the server rejects publication. Keep
        // the new base version in that case, along with all the user's input.
        var savedFields = fields
        let committed = { [self] in
            for agent in batch {
                if let current = service.calls.agents.first(where: { $0.id == agent.id }) {
                    savedFields.versions[agent.id] = PublicationDraft.version(current)
                }
            }
        }
        do {
            if case .server(let key) = scope {
                try await service.calls.saveAndPublish(batch, teams: fields.teamIDs.sorted(), key: key.chatKey, validate: check, didCommit: committed)
                for agent in batch { savedFields.teamVersions[agent.id] = chosenTeams(agent.id, key.chatKey)?.sorted() }
                for agent in batch where agent.isSession && fields.sourceConversationID != nil {
                    try bindPublication(key.chatKey, agent.id, liveSource(fields))
                }
            } else { try await service.calls.save(batch, validate: check, didCommit: committed) }
        } catch {
            if state.draft == submittedDraft, form.fields != savedFields { form.fields = savedFields }
            form.error = error.localizedDescription
            if state.isClosed, let draft = state.draft {
                do { try initialRepository?.save(draft) } catch { state.saveError = error.localizedDescription }
                report("The publication was not completed", error, scope: scope)
            }
            throw error
        }
        form.status = scope == .local ? "Saved on this Mac." : "Saved. Delivery is tracked in Published Agents."
        guard let target = batch.first else { return }
        // Equality includes the ID and revision, as in LocalFormTabs.finish.
        // A reopened editor can also have saved newer input in the repository.
        guard state.draft == submittedDraft else { return }
        // Discard is a checked write. If it fails, the saved IDs still make a
        // retry idempotent, and the form keeps its input and the disk error.
        do {
            let repository = owner(state)?.store.drafts ?? initialRepository
            if let submittedDraft, let saved = repository?.draft(submittedDraft.id) {
                guard saved == submittedDraft else { return }
                try repository?.discard(submittedDraft.id)
            }
            state.draft = nil; state.navigation.draftID = nil; state.savedRevision = nil
        } catch { form.fields = savedFields; state.saveError = error.localizedDescription; return }
        if let location = owner(state) {
            _ = router.rekey(location.session.id, to: .publication(scope, publicationID: target.id.uuidString.lowercased()))
            // The editor now describes one publication, even when Both was used.
            let current = service.calls.agents.first { $0.id == target.id } ?? target
            let changed = form.changed; form.changed = { _ in }
            form.fields = PublicationDraft(current)
            form.fields.teamIDs = fields.teamIDs; form.fields.sourceSurfaceID = fields.sourceSurfaceID
            if current.isSession { form.fields.sourceConversationID = fields.sourceConversationID }
            if case .server(let key) = scope { form.fields.teamVersions[target.id] = chosenTeams(target.id, key.chatKey)?.sorted() }
            form.changed = changed
            state.changed()
        }
    }

    /// A restored surface address is not authority to speak as a publication.
    /// Bind only a currently verified process of the pinned conversation.
    func liveSource(_ fields: PublicationDraft) -> UUID? {
        guard let surface = fields.sourceSurfaceID, let session = router.owner(of: surface)?.session,
              session.answerBinding?.conversation.lowercased() == fields.sourceConversationID?.lowercased(),
              AgentAnswerSource.problem(session, inspector: sourceInspector) == nil else { return nil }
        return surface
    }

    func reviewTargets(_ fields: PublicationDraft, scope: TeamScope) -> [TeamPublishedAgent] {
        agents(scope).filter {
            ($0.id == fields.agentID && fields.mode != .folder)
                || ($0.id == fields.folderAgentID && fields.mode != nil && fields.mode != .session)
        }
    }

    func reviewCurrentVersion(_ state: TabState) {
        let form = form(state)
        guard let scope = state.route.teamScope, canRead(scope), let owner = owner(state) else { return }
        let current = reviewTargets(form.fields, scope: scope).map { agent in
            let chosen: [String]? = { if case .server(let key) = scope { return chosenTeams(agent.id, key.chatKey) }; return nil }()
            return (agent: agent, teams: chosen)
        }
        guard !current.isEmpty else { return }
        let identity = connectionIdentity()
        let details = current.map { version in
            let agent = version.agent
            let names = teams(scope).filter { version.teams?.contains($0.id) == true }.map(\.name)
            return "\(agent.name)\n\(agent.description)\n\(agent.folder)\n\(agent.access.title)\n\(names.joined(separator: ", "))"
        }.joined(separator: "\n\n")
        state.confirmation.request(.init(tabID: owner.session.id, targetID: current.map { $0.agent.id.uuidString }.joined(separator: ","),
            scope: state.route.organizationScope, generation: identity), title: "Review current publication",
            consequences: "\(details)\n\nYour edits will be kept. Saving them will replace these settings.",
            verb: "Keep edits on this version", stillValid: { [self] in
                canRead(scope) && connectionIdentity() == identity && current.allSatisfy { version in
                    agents(scope).contains(version.agent)
                        && { if case .server(let key) = scope { return chosenTeams(version.agent.id, key.chatKey) == version.teams }; return true }()
                }
            }) {
                for version in current {
                    form.fields.versions[version.agent.id] = PublicationDraft.version(version.agent)
                    form.fields.teamVersions[version.agent.id] = version.teams?.sorted()
                }
                form.error = nil
            }
    }
}
