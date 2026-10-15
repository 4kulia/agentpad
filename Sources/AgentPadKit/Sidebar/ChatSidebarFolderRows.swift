import AgentPadTelegram
import SwiftUI

extension ChatSidebarView {
    func personRow(_ person: ChatDMPerson, key: ChatOrgKey, entry: String, folder: SidebarCustomFolder? = nil) -> some View {
        let item = SidebarItemSummary.person(person, scope: key).reference
        let id = ChatSidebarRowID.entryItem(entry: entry, item: item.stableID)
        return ChatDMSidebarRow(store: store, key: key, row: person, custom: folder != nil, attention: personAttention(person.id)) { navigation.selection = id }
            .id(id).overlay(focusBorder(id))
            .sidebarContextMenu(selected: focus == .folders && navigation.selection == id) {
                Button("Open") { ChatDMTabs.open(key, peer: person.id, from: store) }
                folderItemActions(item, entry: entry, folder: folder)
            }
            .addToFolderAnchor(item, windowID: store.windowID, anchor: entry)
            .onDrag { SidebarDragRegistry.provider(.init(item: item, binding: folders.snapshot.binding)) }
    }
    func profileRow(_ profile: AgentProfile, entry: String, folder: SidebarCustomFolder? = nil) -> some View {
        let item = SidebarItemReference.agentpad(.myAgent(profile.id))
        let id = ChatSidebarRowID.entryItem(entry: entry, item: item.stableID)
        return AgentProfileRow(store: store, profile: profile, attentionCount: attention.profileAttentionCounts[profile.id, default: 0],
            selection: navigation.selection == id && focus == .folders ? .profile(profile.id) : focus == .folders ? navigation.selection : nil,
            select: { navigation.selection = $0 == .profile(profile.id) ? id : $0 }, showsSessions: folder == nil,
            folderCaption: folder.map { "My agent · " + relativeActivityLabel(folders.custom[$0.id]?.rows[.agentpad(.myAgent(profile.id))]?.activity ?? profile.createdAt) },
            folderActions: AnyView(folderItemActions(item, entry: entry, folder: folder)))
            .id(id).overlay(focusBorder(id))
            .sidebarContextMenu(selected: focus == .folders && navigation.selection == id) {
                Button("Edit profile…") { SupportTabs.shared.navigation.open(.agentProfile(profile.id), from: store) }
                folderItemActions(item, entry: entry, folder: folder)
            }
            .addToFolderAnchor(item, windowID: store.windowID, anchor: entry)
            .onDrag { SidebarDragRegistry.provider(.init(item: item, binding: folders.snapshot.binding)) }
    }
    @ViewBuilder func customRow(_ item: SidebarItemReference, summary: SidebarItemSummary?, folder: SidebarCustomFolder, snapshot: ChatSidebarSnapshot) -> some View {
        let entry = SidebarEntryIdentity.custom(folder.id)
        let id = ChatSidebarRowID.entryItem(entry: entry, item: item.stableID)
        if let summary {
            switch item {
            case .telegram(let chat):
                if let row = telegram.customRows[chat] {
                    TelegramFolderRow(row: row, store: store, model: telegram, folders: folders, entryID: entry, folder: folder,
                        selected: focus == .folders && navigation.selection == id) { navigation.selection = id }.id(id)
                } else if !summary.available { unavailableRow(item, folder: folder, title: summary.title) }
                else { Color.clear.frame(height: 39).accessibilityLabel("Loading saved chat") }
            case .agentpad(.channel(let ref)):
                if let channel = snapshot.teams.flatMap(\.channels).first(where: { $0.id == ref.channel }), let key = model?.key,
                   ref.server == key.server.description, ref.account == key.accountId, ref.org == key.orgId {
                    channelRow(channel, entry: entry, folder: folder)
                } else { unavailableRow(item, folder: folder, title: summary.title, notConnected: !teamConnected(snapshot)) }
            case .agentpad(.person(let ref)):
                if let key = model?.key, let person = people.first(where: { $0.id == ref.peer }), person.peer.active {
                    personRow(person, key: key, entry: entry, folder: folder)
                } else { unavailableRow(item, folder: folder, title: summary.title, notConnected: !teamConnected(snapshot)) }
            case .agentpad(.myAgent(let ref)):
                if let profile = store.agentProfiles.profile(ref) { profileRow(profile, entry: entry, folder: folder) }
                else { unavailableRow(item, folder: folder, title: summary.title) }
            case .agentpad(.teamAgent(let ref)):
                if let agent = snapshot.agents.first(where: { $0.id == ref.agent }) { agentRow(agent, entry: entry, folder: folder) }
                else { unavailableRow(item, folder: folder, title: summary.title, notConnected: !teamConnected(snapshot)) }
            }
        } else { Color.clear.frame(height: 39).accessibilityLabel("Loading folder item") }
    }
    func teamConnected(_ snapshot: ChatSidebarSnapshot) -> Bool { if case .ready = snapshot.state { true } else { false } }
    func unavailableRow(_ item: SidebarItemReference, folder: SidebarCustomFolder, title: String, notConnected: Bool = false) -> some View {
        let entry = SidebarEntryIdentity.custom(folder.id)
        let id = ChatSidebarRowID.entryItem(entry: entry, item: item.stableID)
        return HStack(spacing: 8) {
            Image(systemName: "questionmark.circle").frame(width: 23)
            VStack(alignment: .leading, spacing: 2) {
                Text(notConnected ? "Not connected" : title).lineLimit(1)
                HStack(spacing: 4) {
                    Text(notConnected ? "Connect a team to open this item" : "Unavailable ·")
                    Button("Remove") { folders.remove(item, from: folder.id) }.buttonStyle(.plain)
                }.font(Theme.display(9))
            }
            Spacer(minLength: 0)
        }.font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary).opacity(0.65)
            .padding(.horizontal, 6).frame(height: 39).id(id).overlay(focusBorder(id))
            .sidebarContextMenu(selected: focus == .folders && navigation.selection == id) { folderItemActions(item, entry: entry, folder: folder) }
            .addToFolderAnchor(item, windowID: store.windowID, anchor: entry)
    }
    func entryItems(_ entry: SidebarFolderEntry, snapshot: ChatSidebarSnapshot) -> [SidebarItemReference] {
        let limit = entryLimit(entry)
        switch entry.kind {
        case .team(let id):
            guard let key = model?.key else { return [] }
            return Array((snapshot.filteredTeams(query: navigation.query, filter: navigation.filter).first { $0.id == id }?.channels ?? []).prefix(limit)).map { SidebarItemSummary.channel($0, scope: key).reference }
        case .people:
            guard let key = model?.key else { return [] }
            return filteredPeople.prefix(limit).map { SidebarItemSummary.person($0, scope: key).reference }
        case .myAgents: return profileGroups(snapshot, limit: limit).flatMap(\.profiles).map { .agentpad(.myAgent($0.id)) }
        case .teamAgents:
            guard let key = model?.key else { return [] }
            return remoteAgents(snapshot).prefix(limit).map { SidebarItemSummary.teamAgent($0, scope: key).reference }
        case .custom(let id): return Array((folders.custom[id]?.items ?? []).prefix(limit))
        case .telegram(let key):
            let pages = telegram.listPages[key] ?? [:]
            return pages.keys.sorted().flatMap { start in
                guard start < limit else { return [SidebarItemReference]() }
                return pages[start]!.rows.filter { ($0.listPosition ?? start) < limit }.prefix(limit - start).map { .telegram($0.id.chat) }
            }
        case .connect: return []
        }
    }
    func keyboardRows(_ snapshot: ChatSidebarSnapshot) -> [ChatSidebarKeyboard.Row] {
        var result: [ChatSidebarKeyboard.Row] = []
        for entry in folderEntries(snapshot) where entry.kind != .connect {
            let id = ChatSidebarRowID.entry(entry.id)
            result.append(.init(id: id, expanded: entryExpanded(entry)))
            guard entryExpanded(entry) else { continue }
            if case .team(let team) = entry.kind, snapshot.teams.first?.id == team {
                for inbox in [ChatInboxKind.unread, .mentions] { result.append(.init(id: .folderInbox(entry.id, inbox), parent: id)) }
            }
            for item in entryItems(entry, snapshot: snapshot) {
                let rowID = ChatSidebarRowID.entryItem(entry: entry.id, item: item.stableID)
                if entry.kind == .myAgents, case .agentpad(.myAgent(let profileID)) = item, let profile = store.agentProfiles.profile(profileID) {
                    let expanded = store.expandedAgentProfiles.contains(profileID)
                    result.append(.init(id: rowID, parent: id, expanded: expanded))
                    if expanded {
                        let rows = store.profileSessionItems(profile), limit = store.profileHistoryLimits[profileID] ?? 5
                        result += AgentProfileSessions.page(rows, limit: limit).map { .init(id: .history(profileID,$0.id), parent: rowID) }
                        if rows.count > limit { result.append(.init(id: .more(profileID), parent: rowID)) }
                    }
                } else { result.append(.init(id: rowID, parent: id)) }
            }
            if entryRemaining(entry) > 0 { result.append(.init(id: .entryMore(entry.id), parent: id)) }
            if entryLimit(entry) > 8 { result.append(.init(id: .entryItem(entry: entry.id, item: "$less"), parent: id)) }
        }
        result.append(.init(id: .allSessions)); return result
    }
    func handle(_ key: ChatSidebarKeyboard.Key, _ snapshot: ChatSidebarSnapshot) {
        switch ChatSidebarKeyboard.route(key, selection: navigation.selection, rows: keyboardRows(snapshot)) {
        case .select(let id): navigation.selection = id
        case .expand(.entry(let id), let expanded):
            if let entry = folderEntries(snapshot).first(where: { $0.id == id }) { setEntryExpanded(entry, expanded) }
        case .expand(.entryItem(_,let item), let expanded):
            if let profile = profiles.first(where: { SidebarItemReference.agentpad(.myAgent($0.id)).stableID == item }) {
                if expanded { store.expandedAgentProfiles.insert(profile.id) } else { store.expandedAgentProfiles.remove(profile.id) }
            }
        case .activate(.entryItem(let id, let item)):
            guard let entry = folderEntries(snapshot).first(where: { $0.id == id }) else { return }
            if item == "$less" {
                if case .telegram(let key) = entry.kind { Task { await telegram.expand(key, showLess: true) } }
                else { folders.less(id) }; return
            }
            if item.hasPrefix("inbox:"), let key = model?.key {
                store.showInbox(ChatInboxRef(key, kind: item == "inbox:unread" ? .unread : .mentions)); return
            }
            if let reference = entryItems(entry, snapshot: snapshot).first(where: { $0.stableID == item }) { activateFolderItem(reference) }
        case .activate(.entryMore(let id)): if let entry = folderEntries(snapshot).first(where: { $0.id == id }) { more(entry) }
        case .activate(.history(let id, let item)):
            if let profile = store.agentProfiles.profile(id), let row = store.profileSessionItems(profile).first(where: { $0.id == item }) { store.openProfileSession(row, profileID: id) }
        case .activate(.more(let id)): store.profileHistoryLimits[id, default: 5] += 5
        case .activate(.allSessions): SupportTabs.shared.navigation.open(.allSessions, from: store)
        default: break
        }
    }
    func activateFolderItem(_ item: SidebarItemReference) {
        switch item {
        case .agentpad(.channel(let ref)): open(ref.channel)
        case .agentpad(.person(let ref)): if let key = model?.key { ChatDMTabs.open(key, peer: ref.peer, from: store) }
        case .agentpad(.myAgent(let id)): store.activateAgentProfile(id)
        case .agentpad(.teamAgent(let ref)): openAgent(ref.agent)
        case .telegram(let id):
            if let row = telegram.customRows[id] ?? telegram.listPages.values.flatMap({ $0.values.flatMap(\.rows) }).first(where: { $0.id.chat == id }) { TelegramTabs.open(row, from: store) }
        }
    }
    func addSelectedToFolder() {
        guard case .entryItem(let id, let item) = navigation.selection,
              let entry = folderEntries(snapshot).first(where: { $0.id == id }),
              let reference = entryItems(entry, snapshot: snapshot).first(where: { $0.stableID == item }) else { return }
        SidebarFolderActions.shared.present(reference, binding: folders.snapshot.binding, windowID: store.windowID, anchor: id)
    }
}

struct ChatDMSidebarRow: View {
    let store: WorkspaceStore
    let key: ChatOrgKey
    var row: ChatDMPerson
    var custom = false
    var attention = false
    var select: () -> Void = {}
    var body: some View {
        Button { select(); ChatDMTabs.open(key, peer: row.id, from: store) } label: {
            HStack(spacing: 8) {
                ContactAvatar(stableID: row.id, name: row.peer.name, kind: .person, size: 23, remote: .account(row.id, key))
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.peer.name).font(Theme.display(11, weight: row.unread ? .semibold : .regular)).lineLimit(1)
                    Text(!row.hasMessages ? "No messages yet" : !row.writable ? "Read-only" : "Direct message" + (custom ? row.conversation.map { " · " + relativeActivityLabel($0.lastUsed) } ?? "" : ""))
                        .font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary)
                }
                Spacer(minLength: 2)
                if attention { SidebarAttentionDot() }
                if row.roots.muted { Image(systemName: "bell.slash").font(.system(size: 9)).foregroundStyle(ChatAppearance.secondary) }
                if let badge = row.badge { Text(badge).font(Theme.display(9)).foregroundStyle(row.roots.muted ? ChatAppearance.secondary : ChatAppearance.accent) }
            }.padding(.horizontal, 6).frame(height: 39)
                .background(store.active?.activeSession?.toolRoute == row.route(key) ? Theme.chromeSelection : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Theme.chromeForeground)
            .accessibilityLabel("\(row.peer.name), Direct message, \(row.badge ?? "0") unread" + (attention ? ", in Needs attention" : ""))
            .help("Unread roots: \(row.roots.count)\(row.roots.more ? "+" : ""). Unread replies: \(row.replies). Counts include loaded history only.")
    }
}
