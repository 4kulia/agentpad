import Foundation
import Observation

/// MainActor only captures immutable source values and observes individual live
/// sessions. Diffing, history reduction and summary construction belong to the
/// worker actor; no ChatSidebarSnapshot is built for custom folders.
@MainActor
final class SidebarFolderSummarySource {
    private weak var workspace: WorkspaceStore?
    private weak var folders: SidebarFoldersModel?
    let org: ChatOrgModel?
    private let attention: AttentionSidebarModel
    private let people: (ChatOrgKey) -> ChatDMPeopleInput
    private let worker = SidebarFolderSummaryWorker()
    private var members: Set<SidebarAgentPadReference> = []
    private var epochs: [String: UUID] = [:]
    private var sessions: [UUID: Session] = [:]
    private var sessionEpochs: [UUID: UUID] = [:]
    private var followedEpochs: [String: UUID] = [:]
    private(set) var delivery: Task<Void, Never>?
    private(set) var updatedSummaryCount = 0
    private(set) var sessionReadCount = 0
    private(set) var chatReadCount = 0

    init(workspace: WorkspaceStore, folders: SidebarFoldersModel, org: ChatOrgModel?,
         attention: AttentionSidebarModel, people: @escaping (ChatOrgKey) -> ChatDMPeopleInput, after: Task<Void, Never>? = nil) {
        self.workspace = workspace; self.folders = folders; self.org = org
        self.attention = attention; self.people = people; delivery = after
        observeMembers()
    }
    private func track<Value>(_ name: String, read: () -> Value,
                              update: @escaping @MainActor (SidebarFolderSummarySource) -> Void) -> Value {
        let epoch = UUID(); epochs[name] = epoch
        return withObservationTracking(read) { [weak self] in
            Task { @MainActor in
                guard let self, self.epochs[name] == epoch else { return }
                update(self)
            }
        }
    }
    private func submit(_ change: SidebarFolderSummaryWorker.Change) {
        guard let store = folders?.store else { return }
        let previous = delivery, worker = worker
        delivery = Task { [weak self] in
            await previous?.value
            let values = await worker.apply(change)
            guard !values.isEmpty else { return }
            self?.updatedSummaryCount += values.count
            await store.updateSummaries(values)
        }
    }
    private func observeMembers() {
        let next = track("members", read: { folders?.summaryMembers ?? [] }, update: { $0.observeMembers() })
        guard next != members else { return }
        members = next
        submit(.members(next))
        guard !next.isEmpty else {
            epochs = epochs.filter { $0.key == "members" }
            followedEpochs = [:]; sessionEpochs = [:]; sessions = [:]
            submit(.sessions([])); return
        }
        if epochs["chat"] == nil { observeChats() }
        if epochs["attention"] == nil { observeAttention() }
        let channels = Set(next.compactMap { ref -> String? in if case .channel(let id) = ref { id.channel } else { nil } })
        followedEpochs = followedEpochs.filter { channels.contains($0.key) }
        for id in channels where followedEpochs[id] == nil { observeFollowed(id) }
        if next.contains(where: { if case .person = $0 { true } else { false } }) {
            if epochs["people"] == nil { observePeople() }
        } else { epochs["people"] = nil }
        if next.contains(where: { if case .myAgent = $0 { true } else { false } }) {
            if epochs["profiles"] == nil {
                observeProfiles(); observeCatalog(); observeVisibility(); observeSessions()
            }
        } else {
            for name in ["profiles", "catalog", "visibility", "sessions"] { epochs[name] = nil }
            sessionEpochs = [:]; sessions = [:]; submit(.sessions([]))
        }
    }
    private func observeChats() {
        chatReadCount += 1
        let input = track("chat", read: {
            guard let org, org.channelsVisible, let key = org.key else { return SidebarFolderSummaryWorker.ChatInput() }
            return .init(key: key, view: org.view, me: org.me)
        }, update: { $0.observeChats() })
        submit(.chat(input))
    }
    private func observePeople() {
        guard members.contains(where: { if case .person = $0 { true } else { false } }) else { return }
        let input = track("people", read: {
            guard let org, org.channelsVisible, let key = org.key else { return ChatDMPeopleInput() }
            return people(key)
        }, update: { $0.observePeople() })
        submit(.people(input))
    }
    private func observeFollowed(_ id: String) {
        let epoch = UUID(); followedEpochs[id] = epoch
        let value = withObservationTracking { org?.isFollowed(id) ?? false } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.followedEpochs[id] == epoch else { return }
                self.observeFollowed(id)
            }
        }
        submit(.followed(id, value))
    }
    private func observeAttention() {
        let input = track("attention", read: { (attention.items, attention.profileAttentionCounts) }, update: { $0.observeAttention() })
        submit(.attention(input.0, input.1))
    }
    private func observeProfiles() {
        guard let workspace else { return }
        let input = track("profiles", read: { (workspace.agentProfiles.profiles, workspace.agentProfiles.bindingsSnapshot) }, update: { $0.observeProfiles() })
        submit(.profiles(input.0, input.1))
    }
    private func observeCatalog() {
        guard let workspace else { return }
        let input = track("catalog", read: { workspace.sessionDisplaySources.catalog.recordsSnapshot }, update: { $0.observeCatalog() })
        submit(.catalog(input))
    }
    private func observeVisibility() {
        guard let workspace else { return }
        let input = track("visibility", read: { workspace.conversationVisibility() }, update: { $0.observeVisibility() })
        submit(.visibility(input))
    }
    private func observeSessions() {
        guard let workspace else { return }
        let next = track("sessions", read: {
            _ = AgentMonitor.shared.windowGeneration
            return workspace.profileStores.flatMap(\.allSessions)
        }, update: { $0.observeSessions() })
        let ids = Set(next.map(\.id))
        sessions = sessions.filter { ids.contains($0.key) }
        sessionEpochs = sessionEpochs.filter { ids.contains($0.key) }
        submit(.sessions(ids))
        for session in next where sessions[session.id] !== session {
            sessions[session.id] = session
            observeSession(session)
        }
    }
    private func observeSession(_ session: Session) {
        sessionReadCount += 1
        let id = session.id, epoch = UUID(); sessionEpochs[id] = epoch
        let input = withObservationTracking {
            SidebarFolderSummaryWorker.Live(session: session)
        } onChange: { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session, self.sessionEpochs[id] == epoch else { return }
                self.observeSession(session)
            }
        }
        submit(.session(id, input))
    }
}
