import AppKit

@MainActor
extension WorkspaceStore {
    /// UI activation coalesces the second mouse-up of a double click. Programmatic
    /// starts remain independent; keyboard repeat goes through this same gate.
    func activateAgentProfile(_ id: UUID, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let last = lastProfileActivation, last.id == id,
           timestamp - last.time < max(0.65, NSEvent.doubleClickInterval) { return }
        lastProfileActivation = (id, timestamp)
        startAgentProfile(id)
    }

    /// Tab structure and shell-to-agent upgrades trigger adoption. Automatic runs use TeamRunner /
    /// TeamSpawn, never Session tabs, so no transcript/automatic check belongs here.
    func scheduleAgentProfileAdoption() {
        agentProfiles.scheduleTabAdoption(sourceID: windowID, candidates: { [weak self] in
            guard let self, !isTerminated else { return [] }
            return profileStores.filter { $0.agentProfiles === agentProfiles }.flatMap { owner in
                owner.allSessions.compactMap { session in
                    guard session.hasProcess, session.effectiveRemoteHost == nil,
                          !session.agent.isShell, !session.agent.rosterId.isEmpty,
                          session.profileID.flatMap(agentProfiles.profile) == nil,
                          let candidate = session.profileAdoption,
                          candidate.templateID == session.agent.id,
                          candidate.rosterID == session.agent.rosterId else { return nil }
                    return candidate
                }
            }
        }, apply: { [weak self] assignments in
            guard let self, !isTerminated else { return }
            for owner in profileStores where owner.agentProfiles === agentProfiles {
                var changed = false
                for session in owner.allSessions {
                    guard let assignment = assignments[session.id],
                          session.hasProcess, session.effectiveRemoteHost == nil,
                          session.profileID.flatMap(agentProfiles.profile) == nil,
                          session.profileAdoption == assignment.candidate,
                          session.agent.id == assignment.candidate.templateID,
                          session.agent.rosterId == assignment.candidate.rosterID else { continue }
                    session.profileID = assignment.profileID
                    session.profileOriginalCwd = assignment.folder
                    changed = true
                }
                if changed { owner.scheduleSave() }
            }
        })
    }

    /// The same binding path for profile-button launches and adopted tabs.
    /// Reports can attach history only after the tab already belongs to a profile.
    func bindProfileConversation(_ session: Session) {
        guard let profileID = session.profileID, let profile = agentProfiles.profile(profileID),
              session.agent.rosterId == profile.rosterID,
              let conversation = session.conversationId, let cwd = session.profileOriginalCwd,
              conversationVisibility().allows(agentId: profile.rosterID, conversationId: conversation) else { return }
        do {
            try agentProfiles.bind(AgentSessionRecord(agentId: profile.rosterID, conversationId: conversation,
                title: "", cwd: cwd, lastActivity: .distantPast),
                to: profileID, origin: session.launchOrigin)
        } catch { agentProfileErrors[profileID] = "The session's agent binding could not be saved: \(error.localizedDescription)" }
    }

    @discardableResult
    func startAgentProfile(_ id: UUID) -> Result<Session, ResumeRefusal> {
        guard !isTerminated, let profile = agentProfiles.profile(id) else { return .failure(.profileUnavailable) }
        guard isDirectory(profile.folder) else {
            agentProfileErrors[id] = "Folder not found: \(profile.folder.path). No session was started. Choose a folder for new sessions."
            expandedAgentProfiles.insert(id)
            return .failure(.missingFolder(profile.folder.path))
        }
        guard let template = profileTemplates().first(where: { $0.id == profile.templateID && $0.rosterId == profile.rosterID }),
              !template.isShell else {
            agentProfileErrors[id] = ResumeRefusal.templateUnavailable.message(agentId: profile.rosterID, conversationId: "")
            return .failure(.templateUnavailable)
        }
        // Profile launches are local even when the current workspace holds SSH tabs.
        let workspace = active ?? addEmptyWorkspace()
        agentProfileErrors[id] = nil
        let session = addTab(in: workspace, template: template, initialCwd: profile.folder,
            connection: .local, profile: profile)
        expandedAgentProfiles.insert(id)
        return .success(session)
    }

    func profileSessionItems(_ profile: AgentProfile, catalog: SessionCatalog = .shared) -> [AgentProfileSessionItem] {
        AgentProfileSessions.items(profile: profile, profiles: agentProfiles,
            sessions: profileStores.flatMap(\.allSessions), catalog: catalog,
            visibility: conversationVisibility(), names: SessionNames.shared.values)
    }

    @discardableResult
    func openProfileSession(_ item: AgentProfileSessionItem, profileID: UUID) -> Result<Session, ResumeRefusal> {
        // A live tab can still be focused if its folder was removed since launch.
        if let session = item.session, let owner = profileStores.first(where: { $0.allSessions.contains { $0 === session } }),
           let location = owner.location(ofSessionId: session.id) {
            owner.activateWorkspace(location.workspace); owner.activateTab(session, in: location.workspace)
            TabRouter.shared.revealWindow(owner)
            return .success(session)
        }
        guard let record = item.record,
              let binding = agentProfiles.binding(agentID: record.agentId, conversationID: record.conversationId),
              binding.profileID == profileID else { return .failure(.unusableConversationId) }
        return resumeProfileConversation(binding)
    }

    func resumeProfileConversation(_ binding: AgentProfileBinding,
        claudeResolution: Result<String, ClaudeSessionResume.Refusal>? = nil) -> Result<Session, ResumeRefusal> {
        let record = binding.record, id = binding.profileID
        func refuse(_ reason: ResumeRefusal) -> Result<Session, ResumeRefusal> {
            agentProfileErrors[id] = reason.message(agentId: record.agentId, conversationId: record.conversationId)
            return .failure(reason)
        }
        guard conversationVisibility().allows(agentId: record.agentId, conversationId: record.conversationId) else {
            return refuse(.channelConversation)
        }
        for owner in profileStores {
            if let session = owner.allSessions.first(where: {
                $0.hasProcess && $0.sshWorkspaceHost == nil && $0.agent.rosterId == record.agentId
                    && ($0.conversationId ?? $0.resumedConversationId) == record.conversationId
            }), let location = owner.location(ofSessionId: session.id) {
                // A history/deep-link request still needs an existing transcript.
                // Direct live-row activation above can focus an already-open tab.
                if record.agentId == AgentTemplate.claudeCodeID,
                   case .failure(let refusal) = claudeResolution ?? ClaudeSessionResume.resolve(
                    record.conversationId, root: claudeProjectsRoot, visibility: conversationVisibility()) {
                    return refuse(.claudeResume(refusal))
                }
                owner.activateWorkspace(location.workspace); owner.activateTab(session, in: location.workspace)
                TabRouter.shared.revealWindow(owner)
                return .success(session)
            }
        }
        let profile = agentProfiles.profile(id)
        guard isDirectory(record.cwd) else { return refuse(.missingFolder(record.cwd.path)) }
        let origin = agentProfiles.details.archive.origins[record.id]
        let template: AgentTemplate
        if let origin {
            guard profile != nil else { return refuse(.profileUnavailable) }
            guard let original = profileTemplates().first(where: { origin.matches($0) }) else {
                return refuse(.launchOriginUnavailable)
            }
            template = original
        } else {
            // 1.1.14 bindings have only the record's agent identity. The
            // profile's current template is not evidence of that launch.
            guard let recorded = profileTemplates().first(where: { $0.id == record.agentId })
                ?? AgentTemplate.builtin(id: record.agentId) else { return refuse(.agentCannotResume) }
            template = recorded
        }
        let options = origin?.options ?? optionsProvider(template.id) ?? ""
        guard template.supportsResume else { return refuse(.agentCannotResume) }
        guard template.persistsConversation(extraOptions: options) else { return refuse(.launchOptionsDisablePersistence) }
        let resolution = template.rosterId == AgentTemplate.claudeCodeID
            ? claudeResolution ?? ClaudeSessionResume.resolve(record.conversationId, root: claudeProjectsRoot, visibility: conversationVisibility()) : nil
        if let refusal = Self.resumeRefusal(agentId: template.rosterId, conversationId: record.conversationId,
            options: { _ in options }, visibility: conversationVisibility(),
            claudeProjectsRoot: claudeProjectsRoot, claudeResolution: resolution) { return refuse(refusal) }
        let workspace = active ?? addEmptyWorkspace()
        agentProfileErrors[id] = nil
        let session = addTab(in: workspace, template: template, initialCwd: record.cwd,
            conversationId: record.conversationId, forceResume: true, claudeResolution: resolution,
            customTitle: record.title, connection: .local, profile: origin == nil ? nil : profile, launchOrigin: origin)
        if origin == nil, let profile, profile.rosterID == template.rosterId {
            session.profileID = profile.id; session.profileOriginalCwd = record.cwd
        }
        return .success(session)
    }
}
