import Foundation

@MainActor
extension WorkspaceStore {
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
            customTitle: profile.name, connection: .local, profile: profile)
        expandedAgentProfiles.insert(id)
        return .success(session)
    }

    func bindProfileConversation(_ session: Session) {
        guard let profileID = session.profileID, let profile = agentProfiles.profile(profileID),
              session.agent.rosterId == profile.rosterID,
              let conversation = session.conversationId, let cwd = session.profileOriginalCwd,
              conversationVisibility().allows(agentId: profile.rosterID, conversationId: conversation) else { return }
        do {
            try agentProfiles.bind(AgentSessionRecord(agentId: profile.rosterID, conversationId: conversation,
                title: session.title, cwd: cwd, lastActivity: max(session.hookStateAt, session.catalogStartedAt)), to: profileID)
        } catch { agentProfileErrors[profileID] = "The session's agent binding could not be saved: \(error.localizedDescription)" }
    }

    func profileSessionItems(_ profile: AgentProfile) -> [AgentProfileSessionItem] {
        AgentProfileSessions.items(profile: profile, profiles: agentProfiles,
            sessions: profileStores.flatMap(\.allSessions), visibility: conversationVisibility(), names: SessionNames.shared.values)
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
                owner.activateWorkspace(location.workspace); owner.activateTab(session, in: location.workspace)
                TabRouter.shared.revealWindow(owner)
                return .success(session)
            }
        }
        guard let profile = agentProfiles.profile(id) else { return refuse(.profileUnavailable) }
        guard isDirectory(record.cwd) else { return refuse(.missingFolder(record.cwd.path)) }
        guard let template = profileTemplates().first(where: { $0.id == profile.templateID && $0.rosterId == profile.rosterID }) else {
            return refuse(.templateUnavailable)
        }
        guard template.supportsResume else { return refuse(.agentCannotResume) }
        guard template.persistsConversation(extraOptions: profile.launchOptions) else { return refuse(.launchOptionsDisablePersistence) }
        let resolution = record.agentId == AgentTemplate.claudeCodeID
            ? claudeResolution ?? ClaudeSessionResume.resolve(record.conversationId, root: claudeProjectsRoot, visibility: conversationVisibility()) : nil
        if let refusal = Self.resumeRefusal(agentId: record.agentId, conversationId: record.conversationId,
            options: { _ in profile.launchOptions }, visibility: conversationVisibility(),
            claudeProjectsRoot: claudeProjectsRoot, claudeResolution: resolution) { return refuse(refusal) }
        let workspace = active ?? addEmptyWorkspace()
        agentProfileErrors[id] = nil
        let session = addTab(in: workspace, template: template, initialCwd: record.cwd,
            conversationId: record.conversationId, forceResume: true, claudeResolution: resolution,
            customTitle: record.title, connection: .local, profile: profile)
        return .success(session)
    }
}
