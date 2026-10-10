import AppKit
import GRDB
import SwiftUI

extension AgentProfileDetailsStore {
    struct PublishedAvatar: Codable, Equatable, Sendable {
        let scope: OrgKey
        let agentID: String
        let profileID: UUID
        let localRevision: Int
        let generation: String
        let avatar: ChatAvatarMetadata
    }
    func publishedAvatar(_ ref: ChatAvatarReference, profile: UUID) -> PublishedAvatar? {
        archive.publishedAvatars?.first { $0.scope == OrgKey(ref.key) && $0.agentID == ref.subject.id && $0.profileID == profile }
    }
    func confirmAvatar(_ ref: ChatAvatarReference, profile: UUID, localRevision: Int, generation: String, avatar: ChatAvatarMetadata) throws {
        var next = archive
        var entries = next.publishedAvatars ?? []
        entries.removeAll { $0.scope == OrgKey(ref.key) && $0.agentID == ref.subject.id }
        entries.append(.init(scope: OrgKey(ref.key), agentID: ref.subject.id, profileID: profile, localRevision: localRevision, generation: generation, avatar: avatar))
        next.publishedAvatars = entries
        try commit(next)
    }
}

extension ChatService {
    func avatarWriteAuthorization(_ ref: ChatAvatarReference) -> ChatAvatarAuthorization? {
        guard let context = avatarContext(ref.key), let token else { return nil }
        switch ref.subject {
        case .account(let id): guard id == ref.key.accountId else { return nil }
        case .agent(let id):
            guard let journal, (try? journal.queue.read { db in
                try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM assignments WHERE server = ? AND account_id = ? AND org_id = ?
                                  AND agent_id = ? AND state = 'active' AND published_session IS NOT NULL)
                    """, arguments: [ref.key.server.description, ref.key.accountId, ref.key.orgId, id])
            }) == true else { return nil }
        }
        return .init(context: context, api: avatarAPI(for: context), token: token, limits: avatarLimits[ref.key.server] ?? .init())
    }
    func publishedAvatarReferences(_ profile: UUID, profiles: AgentProfileStore) -> [ChatAvatarReference] {
        var refs = Set((profiles.details.archive.confirmedPublications ?? []).filter { $0.profileID == profile }.map {
            ChatAvatarReference(key: $0.scope.chatKey, subject: .agent($0.agentID))
        })
        if let journal, let rows = try? journal.queue.read({ try ChatAssignment.fetchAll($0, sql: "SELECT * FROM assignments WHERE state = 'active' AND published_session IS NOT NULL") }) {
            for row in rows {
                guard let id = UUID(uuidString: row.agentId), profiles.details.archive.publications[id.uuidString] == profile,
                      let server = try? ChatServerAddress(parsing: row.server) else { continue }
                refs.insert(.init(key: .init(server: server, accountId: row.accountId, orgId: row.orgId), subject: .agent(row.agentId)))
            }
        }
        return refs.sorted { "\($0.key.server)|\($0.key.accountId)|\($0.key.orgId)|\($0.subject.id)" < "\($1.key.server)|\($1.key.accountId)|\($1.key.orgId)|\($1.subject.id)" }
    }
    func avatarNotPublished(_ profile: UUID, ref: ChatAvatarReference, profiles: AgentProfileStore) -> Bool {
        let local = profiles.details.avatar(profile)
        guard let accepted = profiles.details.publishedAvatar(ref, profile: profile) else { return local.revision > 0 }
        guard accepted.localRevision == local.revision else { return true }
        if let generation = avatarGenerations[ref.key.server], accepted.generation != generation { return true }
        if avatars.context?.key == ref.key, let current = avatars.metadata[ref.subject], current != accepted.avatar { return true }
        return false
    }
    /// Called only by an explicit local Save/Remove, or the accepted explicit
    /// publication below. Connecting and automatic announcements never call it.
    func publishProfileAvatar(_ profile: UUID, profiles: AgentProfileStore) {
        for ref in publishedAvatarReferences(profile, profiles: profiles) where ref.key == connection?.orgKey {
            beginProfileAvatar(profile, ref: ref, profiles: profiles, revision: profiles.details.avatar(profile).revision)
        }
    }
    func beginProfileAvatar(_ profile: UUID, ref: ChatAvatarReference, profiles: AgentProfileStore, revision: Int) {
        guard avatarUploads[ref] == nil else { return }
        let ticket = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.uploadProfileAvatar(profile, ref: ref, profiles: profiles, revision: revision)
            if self.avatarUploads[ref]?.0 == ticket { self.avatarUploads[ref] = nil }
        }
        avatarUploads[ref] = (ticket, task)
    }
    func uploadProfileAvatar(_ profile: UUID, ref: ChatAvatarReference, profiles: AgentProfileStore, revision: Int) async {
        guard !Task.isCancelled, case .agent = ref.subject, profiles.profile(profile) != nil, profiles.details.avatar(profile).revision == revision,
              let agentID = UUID(uuidString: ref.subject.id), profiles.details.archive.publications[agentID.uuidString] == profile else { return }
        var editor: ChatAvatarEditor
        if let existing = avatarEdits[ref] { editor = existing }
        else { editor = ChatAvatarEditor(reference: ref, service: self); editor.profileRevision = revision; avatarEdits[ref] = editor }
        guard !editor.inFlight, editor.canRetry else { return }
        guard let auth = avatarWriteAuthorization(ref) else { await editor.load(); return }
        if editor.needsCheck {
            await editor.retry()
            guard editor.operation == .saved, editor.command == nil else { return }
        }
        if editor.profileRevision != revision {
            editor.invalidate()
            editor = ChatAvatarEditor(reference: ref, service: self)
            editor.profileRevision = revision; avatarEdits[ref] = editor
        }
        // A specific recovery action (Reload, smaller image, wait) stays in the
        // shared operation block; Retry cannot bypass a revision conflict.
        if case .failed(_, let action) = editor.operation, action != .retry { return }
        guard editor.canRetry else { return }
        do {
            let url = profiles.details.avatarURL(profile)
            let result = await Task.detached(priority: .userInitiated) { () throws -> Data? in
                guard let url else { return nil }
                return try ChatAvatarImage.prepare(LocalAvatarImage.read(url), limits: auth.limits)
            }.result
            let data = try result.get()
            guard !Task.isCancelled, profiles.profile(profile) != nil, profiles.details.avatar(profile).revision == revision,
                  avatarWriteAuthorization(ref)?.context == auth.context else { return }
            editor.onConfirmed = { [weak self, weak profiles] metadata in
                guard let self, let profiles, profiles.profile(profile) != nil,
                      self.avatarWriteAuthorization(ref)?.context == auth.context else { throw CancellationError() }
                try profiles.details.confirmAvatar(ref, profile: profile, localRevision: revision, generation: auth.context.generation, avatar: metadata)
            }
            await editor.load()
            guard editor.operation == .idle, profiles.details.avatar(profile).revision == revision,
                  avatarWriteAuthorization(ref)?.context == auth.context else { return }
            guard avatarNotPublished(profile, ref: ref, profiles: profiles) else { return }
            await editor.save(data)
        } catch { editor.preparationFailed(error) }
    }
    /// Capture just the explicitly chosen local version in the publication
    /// journal. It is never part of the agent.publish wire arguments.
    func profileAvatarIntents(_ agents: [TeamPublishedAgent]) -> [UUID: (UUID, Int)] {
        let profiles = avatarProfiles()
        try? profiles.mapPublications(agents)
        return Dictionary(agents.compactMap { agent in
            guard let profile = profiles.details.archive.publications[agent.id.uuidString], profiles.details.avatar(profile).revision > 0 else { return nil }
            return (agent.id, (profile, profiles.details.avatar(profile).revision))
        }, uniquingKeysWith: { first, _ in first })
    }
}

struct PublishedProfileAvatars: View {
    let profile: UUID
    let profiles: AgentProfileStore
    var service: ChatService = .shared
    var body: some View {
        ForEach(service.publishedAvatarReferences(profile, profiles: profiles), id: \.self) { ref in
            let pending = service.avatarNotPublished(profile, ref: ref, profiles: profiles)
            let capable = service.connection?.orgKey == ref.key && service.supports("chat.avatars", key: ref.key)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(ref.key.server.host, systemImage: "person.2")
                    Spacer()
                    Text(pending ? "Avatar not published" : "Shared with team").foregroundStyle(pending ? Color.orange : .green)
                }.font(Theme.display(12, weight: .semibold))
                Text(capable ? (pending ? "Saved on this Mac. Your team still sees the previous avatar." : "Your team sees the confirmed avatar below.")
                     : service.connection?.orgKey == ref.key ? "This server doesn’t support avatars yet. Your image stays on this Mac."
                     : "Connect to this team to update the published photo.")
                    .font(Theme.display(11)).foregroundStyle(Theme.chromeMuted)
                HStack(spacing: 14) {
                    ContactAvatar(stableID: profile.uuidString, name: profiles.profile(profile)?.name ?? "Agent", kind: .agent, size: 48,
                                  image: profiles.details.image(profile))
                    Text("On this Mac").font(Theme.display(11))
                    Image(systemName: "arrow.right").foregroundStyle(Theme.chromeMuted)
                    ContactAvatar(stableID: ref.subject.id, name: profiles.profile(profile)?.name ?? "Agent", kind: .agent, size: 48, remote: ref)
                    Text("Team sees").font(Theme.display(11))
                }
                if let editor = service.avatarEdits[ref], editor.operation != .saved, editor.operation != .idle,
                   editor.profileRevision == profiles.details.avatar(profile).revision || editor.needsCheck || !editor.canRetry {
                    AvatarOperationBlock(editor: editor, retry: {
                        service.beginProfileAvatar(profile, ref: ref, profiles: profiles, revision: profiles.details.avatar(profile).revision)
                    }) { SupportTabs.shared.navigation.open(.agentProfile(profile)) }
                } else if pending, capable {
                    Button("Retry") { service.beginProfileAvatar(profile, ref: ref, profiles: profiles, revision: profiles.details.avatar(profile).revision) }
                        .disabled(service.avatarUploads[ref] != nil)
                }
            }.padding(16).background(Theme.chromeSelection.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
