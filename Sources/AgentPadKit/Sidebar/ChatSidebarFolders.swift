import AgentPadTelegram
import AppKit
import SwiftUI

enum SidebarFocusRegion: CaseIterable {
    case attention, search, folders
    static func next(_ current: Self?, backwards: Bool) -> Self {
        let index = allCases.firstIndex(of: current ?? .folders) ?? 2
        return allCases[(index + (backwards ? 2 : 1)) % 3]
    }
}

extension ChatSidebarView {
    var people: [ChatDMPerson] {
        guard let key = model?.key, model?.channelsVisible == true else { return [] }
        return peopleSource(key).values
    }
    var profiles: [AgentProfile] {
        store.agentProfiles.profiles.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
    func folderEntries(_ snapshot: ChatSidebarSnapshot, includeHidden: Bool = false) -> [SidebarFolderEntry] {
        let catalog = folders.snapshot.catalog
        var available: [String:SidebarFolderEntry] = [:]
        if case .ready = snapshot.state, let key = model?.key {
            let teams = includeHidden ? snapshot.teams : snapshot.filteredTeams(query: navigation.query, filter: navigation.filter)
            for team in teams {
                let id = SidebarEntryIdentity.team(key, team: team.id)
                available[id] = .init(id: id, title: snapshot.teams.first?.id == team.id ? "Channels · \(team.card.name)" : team.card.name,
                    kind: .team(team.id), symbol: "number", count: team.channels.count, unread: team.channels.filter(\.isUnread).count,
                    unmuted: team.channels.filter(\.isUnread).count, attention: team.channels.contains { $0.mentions > 0 })
            }
            let persons = includeHidden ? people : filteredPeople
            if includeHidden || !filtering || !persons.isEmpty {
                let id = SidebarEntryIdentity.people(key)
                available[id] = .init(id: id, title: "People", kind: .people, symbol: "person.2", count: persons.count,
                    unread: persons.filter(\.unread).count, unmuted: persons.filter { $0.unread && !$0.roots.muted }.count,
                    attention: persons.contains { personAttention($0.id) })
            }
            let agents = includeHidden ? remoteAgents(snapshot) : remoteAgents(snapshot)
            if snapshot.agentsServed, includeHidden || navigation.filter == .all && (!filtering || !agents.isEmpty) {
                let id = SidebarEntryIdentity.teamAgents(key)
                available[id] = .init(id: id, title: "Team agents", kind: .teamAgents, symbol: "cpu", count: agents.count, attention: agents.contains { agentAttention($0.id) })
            }
        } else if includeHidden {
            for id in catalog.order {
                if id.hasPrefix("team:") { available[id] = .init(id: id, title: "Channels", kind: .team(id), symbol: "number", connected: false) }
                if id.hasPrefix("people:") { available[id] = .init(id: id, title: "People", kind: .people, symbol: "person.2", connected: false) }
                if id.hasPrefix("teamAgents:") { available[id] = .init(id: id, title: "Team agents", kind: .teamAgents, symbol: "cpu", connected: false) }
            }
        }
        for folder in catalog.custom {
            let projection = folders.custom[folder.id] ?? .init()
            if includeHidden || !filtering || !projection.items.isEmpty {
                let id = SidebarEntryIdentity.custom(folder.id)
                available[id] = .init(id: id, title: folder.name, kind: .custom(folder.id), symbol: folder.symbol,
                    count: folders.snapshot.members[folder.id]?.count ?? folder.items.count, unread: projection.unread,
                    unmuted: projection.unmuted, attention: projection.attention, foreign: projection.foreign)
            }
        }
        let local = includeHidden ? profiles : filteredProfiles
        if includeHidden || !filtering || !local.isEmpty {
            available["myAgents"] = .init(id: "myAgents", title: "My agents", kind: .myAgents, symbol: "cpu", count: local.count,
                attention: local.contains { attention.profileAttentionCounts[$0.id, default: 0] > 0 })
        }
        var order = catalog.order
        let defaults = snapshot.teams.compactMap { team in model?.key.map { SidebarEntryIdentity.team($0, team: team.id) } }
            + (model?.key.map { [SidebarEntryIdentity.people($0)] } ?? []) + ["telegram", "myAgents"]
            + (model?.key.map { [SidebarEntryIdentity.teamAgents($0)] } ?? [])
        for id in defaults where !order.contains(id) { order.append(id) }
        return order.flatMap { id -> [SidebarFolderEntry] in
            if id == "telegram" {
                if telegram.connected { return telegram.snapshot.lists.filter { includeHidden || $0.visible }.map(\.sidebarEntry) }
                return [.init(id: "telegram", title: "Telegram", kind: .connect, symbol: "paperplane")]
            }
            guard var entry = available[id] else { return [] }
            entry.visible = !catalog.hidden.contains(id)
            return includeHidden || entry.visible ? [entry] : []
        }
    }
    var filteredPeople: [ChatDMPerson] {
        people.filter { (navigation.query.isEmpty || $0.peer.name.localizedCaseInsensitiveContains(navigation.query.trimmingCharacters(in: .whitespacesAndNewlines)))
            && (navigation.filter == .all || navigation.filter == .unread && $0.unread) }
    }
    var filteredProfiles: [AgentProfile] {
        profiles.filter { navigation.filter == .all && (navigation.query.isEmpty || $0.name.localizedCaseInsensitiveContains(navigation.query.trimmingCharacters(in: .whitespacesAndNewlines))) }
    }
    func personAttention(_ id: String) -> Bool {
        attention.items.contains { $0.subjectID == id && !$0.subjectIsAgent }
    }
    func agentAttention(_ id: String) -> Bool {
        attention.items.contains { $0.subjectID == id && $0.subjectIsAgent }
    }
    func profileGroups(_ snapshot: ChatSidebarSnapshot, limit: Int) -> [(title: String, profiles: [AgentProfile])] {
        AgentProfilesSection.groups(Array(filteredProfiles.prefix(limit)), sharedProfiles: localPublications(snapshot).profiles,
            disconnected: snapshot.state == .notConnected || snapshot.state == .checking)
    }
    func folderTree(_ snapshot: ChatSidebarSnapshot) -> some View {
        let entries = folderEntries(snapshot)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(entries) { entry in folderEntry(entry, snapshot: snapshot) }
                    if filtering, entries.allSatisfy({ $0.kind == .connect }) { caption("No matches") }
                    AllSessionsSidebarLink(store: store).padding(.top, 12).id(ChatSidebarRowID.allSessions).overlay(focusBorder(.allSessions))
                    if snapshot.state == .notConnected || snapshot.state == .checking { ChatDisconnectedRow() }
                    if snapshot.state == .checking { caption(model?.notice ?? "Team content is hidden while access is checked.") }
                    if snapshot.state == .noChannels { caption("This server has no channels.") }
                    if case .ready = snapshot.state, let model {
                        ForEach(model.channelRefusals, id: \.id) { caption("\($0.title): \($0.reason).") }
                        if !model.channelRefusals.isEmpty {
                            Button("Dismiss") { model.dismissRefusals(Set(model.channelRefusals.map(\.id))) }.buttonStyle(.borderless).padding(8)
                        }
                        if let notice = model.notice { caption(notice) }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }.coordinateSpace(name: "sidebar-folders")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    folderViewport.height = $0; folderViewport.schedule(telegram: telegram, folders: folders)
                }
                .focusable().focused($focus, equals: .folders).focusEffectDisabled()
                .accessibilityLabel("Sidebar folders")
                .onKeyPress(keys: [.upArrow,.downArrow,.leftArrow,.rightArrow,.return]) { press in
                    guard focus == .folders else { return .ignored }
                    let modifiers = press.modifiers.intersection([.command,.option,.control,.shift])
                    if press.key == .return, modifiers == [.command,.shift] { addSelectedToFolder(); return .handled }
                    guard modifiers.isEmpty else { return .ignored }
                    let key: ChatSidebarKeyboard.Key = switch press.key { case .upArrow: .up; case .downArrow: .down; case .leftArrow: .left; case .rightArrow: .right; default: .enter }
                    handle(key, snapshot)
                    if let id = navigation.selection {
                        // The outer ForEach ID exists before an offscreen lazy
                        // entry has laid out its nested inbox scroll targets.
                        if case .entryItem(let entry, let item) = id, item.hasPrefix("inbox:") {
                            proxy.scrollTo(entry, anchor: .top)
                        }
                        proxy.scrollTo(id)
                    }
                    return .handled
                }
                .onChange(of: keyboardRows(snapshot).map(\.id)) { _, ids in
                    if let id = navigation.selection, !ids.contains(id) { navigation.selection = ids.first }
                }
                .onChange(of: navigation.selection) { _, _ in syncFolderHolds() }
                .onChange(of: focus) { _, _ in syncFolderHolds() }
                .onChange(of: store.agentProfileRevealRevision) { _, _ in
                    if let id = store.revealedAgentProfileID { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear { folders.start(); mapLocalProfiles() }
                .task(id: model.map(ObjectIdentifier.init)) {
                    folders.observeSummaries(workspace: store, org: model, attention: attention, people: peopleSource)
                    configureFolderProjection(); loadCustomRows()
                }
                .onChange(of: navigation.query) { _, _ in configureFolderProjection() }
                .onChange(of: model?.key) { _, _ in configureFolderProjection() }
                .onChange(of: model?.channelsVisible) { _, _ in configureFolderProjection() }
                .onChange(of: telegram.connected) { _, _ in configureFolderProjection() }
                .onChange(of: folders.custom) { _, _ in loadCustomRows() }
                .onChange(of: telegram.metadataRevision) { _, _ in loadCustomRows() }
                .onDisappear {
                    folderViewport.clear(telegram: telegram, folders: folders); syncFolderHolds(release: true)
                    Task { await telegram.customViewport([],owner: store.windowID) }
                }
                .onChange(of: telegram.snapshot.binding) { _, _ in folderViewport.schedule(telegram: telegram,folders: folders) }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
                    if (notification.object as? NSWindow) === sidebarWindow.view?.window { syncFolderHolds(release: true) }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                    if (notification.object as? NSWindow) === sidebarWindow.view?.window { syncFolderHolds() }
                }
                .onChange(of: store.panelIsPresented) { _, shown in syncFolderHolds(release: !shown) }
                .onChange(of: TeamService.shared.calls.agents) { _, _ in mapLocalProfiles() }
                .onChange(of: ChatService.shared.publishRevision) { _, _ in mapLocalProfiles() }
        }
    }
    func configureFolderProjection() {
        let scope = model?.channelsVisible == true ? model?.key.map { SidebarEntryIdentity.scope(server: $0.server.description, account: $0.accountId, org: $0.orgId) } : nil
        folders.configure(scope: scope, query: navigation.query, telegramOpen: telegram.connected)
    }
    func loadCustomRows() {
        let ids = Set(folders.custom.values.flatMap { $0.rows.keys }.compactMap { ref -> Int64? in if case .telegram(let id) = ref { id } else { nil } })
        Task { await telegram.customViewport(ids, owner: store.windowID) }
    }
    @ViewBuilder func folderEntry(_ entry: SidebarFolderEntry, snapshot: ChatSidebarSnapshot) -> some View {
        if entry.kind == .connect {
            HStack(spacing: 8) {
                SidebarFolderTag(text: "TG")
                Text("Telegram is not connected on this Mac.").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                Button("Connect") { SupportTabs.shared.settings(.telegram) }.font(Theme.display(10))
            }.padding(8).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.chromeHairline, style: StrokeStyle(dash: [3])))
                .padding(.top, 9)
            if let error = telegram.snapshot.error { caption(error) }
            else if let failure = TelegramService.settings.snapshot.failure { caption(failure.message) }
            if TelegramService.settings.snapshot.state == .blocked { caption(TelegramFolderRollback.note) }
        } else {
            SidebarFolderEntryView(entry: entry, expanded: entryExpanded(entry), sticky: entryExpanded(entry) && entryLimit(entry) > 8,
                selected: focus == .folders && navigation.selection == .entry(entry.id),
                toggle: { navigation.selection = .entry(entry.id); setEntryExpanded(entry, !entryExpanded(entry)) },
                drop: { value in
                    guard case .custom(let folder) = entry.kind, let item = value.item else { return }
                    if case .telegram = item, value.binding != folders.snapshot.binding { return }
                    let binding = value.binding ?? folders.snapshot.binding
                    Task { await folders.perform(.member(folder, item, true), binding: binding) }
                }) {
                    if entryExpanded(entry) { folderBody(entry, snapshot: snapshot) }
                } actions: { folderEntryMenu(entry) }
                .onHover { hoveredEntry = $0 ? entry.id : hoveredEntry == entry.id ? nil : hoveredEntry; syncFolderHolds() }
        }
    }
    @ViewBuilder func folderBody(_ entry: SidebarFolderEntry, snapshot: ChatSidebarSnapshot) -> some View {
        switch entry.kind {
        case .team(let id):
            if let team = snapshot.filteredTeams(query: navigation.query, filter: navigation.filter).first(where: { $0.id == id }) {
                if snapshot.teams.first?.id == id { savedViews(snapshot, entry: entry.id) }
                ForEach(Array(team.channels.prefix(entryLimit(entry)))) { channel in channelRow(channel, entry: entry.id) }
                ForEach(team.creating, id: \.self) { caption("#\($0) — creating…") }
                if team.channels.isEmpty { caption("No channels") }
            }
        case .people:
            if let key = model?.key {
                ForEach(Array(filteredPeople.prefix(entryLimit(entry)))) { person in
                    personRow(person, key: key, entry: entry.id)
                }
                if filteredPeople.isEmpty { caption("No conversations yet") }
            }
        case .myAgents:
            let shown = Array(filteredProfiles.prefix(entryLimit(entry)))
            ForEach(profileGroups(snapshot, limit: entryLimit(entry)), id: \.title) { group in
                Text(group.title).font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary).padding(.horizontal, 6).padding(.top, 5)
                ForEach(group.profiles) { profile in profileRow(profile, entry: entry.id) }
            }
            if shown.isEmpty { caption("Add an agent to start a session.") }
        case .teamAgents:
            ForEach(Array(remoteAgents(snapshot).prefix(entryLimit(entry)))) { agent in agentRow(agent, entry: entry.id) }
            if remoteAgents(snapshot).isEmpty { caption("No agents available") }
        case .telegram(let key):
            if let list = telegram.snapshot.lists.first(where: { $0.key == key }) {
                if telegram.snapshot.lists.first(where: \.visible)?.key == key {
                    if let status = telegram.folderStatus { caption(status) }
                    TelegramReadNoticeView(model: telegram)
                }
                TelegramListEntryView(list: list, store: store, model: telegram, folders: folders, viewport: folderViewport,
                    selection: focus == .folders ? navigation.selection : nil, select: { navigation.selection = $0 })
                if filtering { Button("Find a chat ⌘P") { store.search.source = .telegram; store.search.begin() }.buttonStyle(.plain).font(Theme.display(10)).padding(8) }
            }
        case .custom(let id):
            if let folder = folders.snapshot.catalog.custom.first(where: { $0.id == id }) {
                let projection = folders.custom[id] ?? .init()
                ForEach(Array(projection.items.prefix(entryLimit(entry)).enumerated()), id: \.element) { index, item in
                    VStack(spacing: 0) { customRow(item, summary: projection.rows[item], folder: folder, snapshot: snapshot) }
                        .folderViewport(.custom(id,index), tracker: folderViewport, telegram: telegram, folders: folders)
                }

                if projection.waitingForTelegram { caption("Telegram chats in this folder appear after you connect Telegram.") }
                if projection.items.isEmpty && projection.foreign == 0 && !projection.waitingForTelegram {
                    caption("Right-click a chat, channel, person or agent → Add to folder…")
                }
            }
        case .connect: EmptyView()
        }
        entryMore(entry)
    }
    func entryExpanded(_ entry: SidebarFolderEntry) -> Bool {
        if case .telegram(let key) = entry.kind { return telegram.snapshot.lists.first { $0.key == key }?.collapsedWindows.contains(store.windowID) != true }
        if filtering { return !navigation.filterCollapsed.contains(.entry(entry.id)) }
        return !store.chatSidebarPreferences.collapsedEntries.contains(entry.id)
    }
    func setEntryExpanded(_ entry: SidebarFolderEntry, _ expanded: Bool) {
        if case .telegram(let key) = entry.kind { folders.run(.telegramCollapsed(store.windowID, key, !expanded)) }
        else if filtering {
            if expanded { navigation.filterCollapsed.remove(.entry(entry.id)) } else { navigation.filterCollapsed.insert(.entry(entry.id)) }
        } else { store.setEntryCollapsed(entry.id, !expanded) }
    }
    func entryLimit(_ entry: SidebarFolderEntry) -> Int {
        if case .telegram(let key) = entry.kind {
            let list = telegram.snapshot.lists.first { $0.key == key }
            return list?.expanded == true ? max(9, list?.capacity ?? 8) : list?.capacity ?? 8
        }
        return folders.limit(entry.id)
    }
    func entryCount(_ entry: SidebarFolderEntry) -> Int {
        if case .custom(let id) = entry.kind { return folders.custom[id]?.items.count ?? 0 }
        return entry.count
    }
    func entryRemaining(_ entry: SidebarFolderEntry) -> Int {
        if case .telegram(let key) = entry.kind, let list = telegram.snapshot.lists.first(where: { $0.key == key }) {
            let holes = (telegram.listPages[key] ?? [:]).reduce(0) { total, page in
                let width = max(0,min(50,list.capacity - page.key))
                let present = page.value.rows.filter { ($0.listPosition ?? page.key) < list.capacity }.count
                return total + max(0,width - present)
            }
            return max(0,list.counts.rows - max(0,list.capacity - holes))
        }
        return max(0,entryCount(entry) - entryLimit(entry))
    }
    @ViewBuilder func entryMore(_ entry: SidebarFolderEntry) -> some View {
        let remaining = entryRemaining(entry)
        if remaining > 0 {
            Button("\(remaining)\(entry.provisional ? "+" : "") more", systemImage: "chevron.down") { more(entry) }
                .buttonStyle(.plain).font(Theme.display(10)).foregroundStyle(ChatAppearance.accent).padding(7)
                .id(ChatSidebarRowID.entryMore(entry.id)).overlay(focusBorder(.entryMore(entry.id)))
        }
        if entryLimit(entry) > 8 {
            Button("Show less") {
                if case .telegram(let key) = entry.kind { Task { await telegram.expand(key, showLess: true) } }
                else { folders.less(entry.id) }
            }.buttonStyle(.plain).font(Theme.display(10)).foregroundStyle(ChatAppearance.accent).padding(7)
                .id(ChatSidebarRowID.entryItem(entry: entry.id,item: "$less"))
                .overlay(focusBorder(.entryItem(entry: entry.id,item: "$less")))
        }
    }
    func more(_ entry: SidebarFolderEntry) {
        if case .telegram(let key) = entry.kind { Task { await telegram.expand(key) } }
        else { folders.more(entry.id) }
    }
    @ViewBuilder func folderEntryMenu(_ entry: SidebarFolderEntry) -> some View {
        Button(entryExpanded(entry) ? "Collapse" : "Expand") { setEntryExpanded(entry, !entryExpanded(entry)) }
        Button("Hide from sidebar") { folders.setVisible(entry, false) }
        Button("Move up") { folders.move(entry, by: -1) }
        Button("Move down") { folders.move(entry, by: 1) }
        Button("Folders…") { folders.sheetPresented = true }
        switch entry.kind {
        case .custom(let id):
            Button("Rename…") { folders.sheetPresented = true; folders.editing = id }
            Button("Delete…") { folders.sheetPresented = true; folders.deleting = folders.snapshot.catalog.custom.first { $0.id == id } }
        case .telegram: Text("Edited in Telegram").disabled(true)
        case .myAgents: Button("New agent…") { LocalFormTabs.shared.newAgent(from: store) }
        case .people:
            if let key = model?.key { Button("New direct message…") { SupportTabs.shared.navigation.open(.newDM(OrgKey(key)), from: store) } }
        case .team(let id):
            if let model, let team = snapshot.teams.first(where: { $0.id == id }), model.canCreateChannel(in: team.card) {
                Button("New channel…") { ChatSidebarActions.newChannel(in: team.card, model, from: store) }
            }
        default: EmptyView()
        }
    }
    @ViewBuilder var folderFooter: some View {
        if let entry = folders.hiddenToast {
            HStack(spacing: 5) {
                Text("Folder hidden").lineLimit(1)
                Button("Undo") { folders.undoHide() }
                Button("Folders…") { folders.sheetPresented = true; folders.hiddenToast = nil }
            }.font(Theme.display(10)).padding(8).help(entry.title)
        }
        SidebarFolderFailureView(model: folders).padding(.horizontal, 8)
        HStack {
            Button("Folders…", systemImage: "folder") { folders.sheetPresented = true }.buttonStyle(.plain)
            Spacer()
        }.font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).padding(.horizontal, 16).frame(height: 36)
            .overlay(alignment: .top) { Rectangle().fill(Theme.chromeSeparator).frame(height: 1) }
    }
    @ViewBuilder func folderItemActions(_ item: SidebarItemReference, entry: String, folder: SidebarCustomFolder? = nil) -> some View {
        Button("Add to folder…") { SidebarFolderActions.shared.present(item, binding: folders.snapshot.binding, windowID: store.windowID, anchor: entry) }
        if let folder { Button("Remove from \"\(folder.name)\"") { folders.remove(item, from: folder.id) } }
    }
    func syncFolderHolds(release: Bool = false) {
        let focusedEntry: String? = {
            guard focus == .folders else { return nil }
            switch navigation.selection { case .entry(let id), .entryItem(let id, _), .entryMore(let id): return id; default: return nil }
        }()
        let needed = release ? Set<TelegramListKey>() : Set(telegram.snapshot.lists.filter {
            let id = SidebarFolderEntry.telegramID($0.key); return id == hoveredEntry || id == focusedEntry
        }.map(\.key))
        let changed = heldLists.symmetricDifference(needed); heldLists = needed
        Task { for key in changed { await telegram.hold(key, held: needed.contains(key), owner: store.windowID) } }
    }
}

extension TelegramChatsModel {
    var folderStatus: String? {
        if let error = snapshot.error { return error }
        if case .paused(let reason) = snapshot.state { return "Offline · \(reason)" }
        return nil
    }
}
