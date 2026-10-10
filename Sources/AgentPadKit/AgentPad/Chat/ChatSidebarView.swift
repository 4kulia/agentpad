import AppKit
import SwiftUI

typealias ChatSidebarStyle = ChatAppearance

struct ChatSidebarBadge: View {
    let text: String
    var mention = false
    var body: some View {
        Text(text).font(Theme.display(10, weight: .semibold)).monospacedDigit()
            .foregroundStyle(mention ? ChatSidebarStyle.attention : ChatSidebarStyle.secondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(mention ? ChatSidebarStyle.attention.opacity(0.12) : Theme.chromeSelection,
                        in: RoundedRectangle(cornerRadius: 4))
    }
}

/// The bottom switch remains available in the compact rail too: choosing
/// Chat expands it, through the same store action used by every entry point.
struct ChatSidebarModePicker: View {
    let store: WorkspaceStore
    var compact: Bool
    let model: ChatOrgModel?

    var body: some View {
        let mentions = model?.mentionsForBadge ?? 0
        VStack(spacing: 0) {
            Rectangle().fill(Theme.chromeSeparator).frame(height: 1)
            let layout = compact ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
            layout {
                mode(.workspaces, title: "Sessions", icon: "rectangle.stack",
                     badge: compact && !AttentionSidebarModel.shared.items.isEmpty ? "•" : nil)
                mode(.files, title: "Files", icon: "folder")
                mode(.team, title: "Team", icon: "person.2", badge: teamNeedsAttention ? "•" : nil)
                mode(.chat, title: "Chat", icon: "bubble.left.and.bubble.right",
                     badge: compact && !AttentionSidebarModel.shared.items.isEmpty ? "•" : mentions > 0 ? "\(mentions)" : nil)
            }.padding(.horizontal, compact ? 4 : 9).padding(.top, 9).padding(.bottom, 12)
        }
        .task(id: ChatOrgCurrent.identity()) { ChatOrgCurrent.shared.refresh() }
    }

    private var teamNeedsAttention: Bool {
        AttentionLedger.shared.events.contains { event in
            event.kind.needsDecision && [.decisions, .failure, .account].contains(event.kind.category)
        }
    }

    private func mode(_ content: SidebarContent, title: String, icon: String, badge: String? = nil) -> some View {
        let active = store.sidebarContent == content
        return Button { store.setSidebarContent(content) } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17))
                    .foregroundStyle(active ? ChatSidebarStyle.accent : ChatSidebarStyle.secondary)
                if !compact { Text(title).font(Theme.display(9, weight: active ? .semibold : .regular)) }
            }
            .frame(maxWidth: .infinity).frame(height: compact ? 36 : 48)
            .background(active ? Theme.chromeSelection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Theme.chromeForeground : ChatSidebarStyle.secondary)
        .overlay(alignment: .topTrailing) {
            if let badge {
                ChatSidebarBadge(text: badge, mention: true).allowsHitTesting(false)
                    .offset(x: 2, y: -3)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(active ? "Selected" : "")
        .accessibilityHint(content == .chat && badge != nil ? "\(badge!) unread mentions" : content == .team && badge != nil ? "Decisions waiting for you" : "")
        .help(title)
        .chatFocusRing()
    }
}

struct ChatSidebarView: View {
    @Bindable var store: WorkspaceStore
    @Bindable var navigation: ChatSidebarNavigation
    let model: ChatOrgModel?
    var attention = AttentionSidebarModel.shared
    var profileHistory = AgentSessionHistory.shared
    @State private var organizationMenu = false
    @State private var channelNameEdit = InlineNameEdit()
    @State private var renamingChannel: ChatChannelCard?
    @State private var renamingKey: ChatOrgKey?
    @FocusState private var focus: Focus?
    private enum Focus { case search, tree }
    @Environment(\.colorSchemeContrast) private var contrast

    private var active: ChannelRef? { store.active?.activeSession?.channel }
    private var snapshot: ChatSidebarSnapshot { ChatSidebarSnapshot(model: model, active: active) }
    private var filtering: Bool { !navigation.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || navigation.filter != .all }

    var body: some View {
        let snapshot = snapshot
        sidebar(snapshot)
        .task(id: ChatOrgCurrent.identity()) {
            ChatOrgCurrent.shared.refresh()
            navigation.adopt(ChatOrgCurrent.identity())
            openCreated()
        }
        .onChange(of: model?.view.channels) { _, _ in openCreated() }
        .onChange(of: model?.channelsVisible) { _, visible in
            if visible == true { openCreated() } else { navigation.hideRestrictedContent() }
        }
        .onChange(of: snapshot.agents.map(\.id)) { _, ids in
            if let id = navigation.agentID, !ids.contains(id) { navigation.agentID = nil }
        }
        .onChange(of: navigation.query) { _, _ in resetFilteredFocus() }
        .onChange(of: navigation.filter) { _, _ in resetFilteredFocus() }
        .onChange(of: focus) { _, value in
            if value == .tree, navigation.selection == nil { navigation.selection = keyboardRows(snapshot).first?.id }
        }
        .onChange(of: navigation.focusRequested, initial: true) { _, requested in
            if requested { focus = .tree; navigation.focusRequested = false }
        }
        // Scoped to this focus subtree: terminal Cmd-F remains untouched.
        .onKeyPress(characters: CharacterSet(charactersIn: "f")) { press in
            guard press.modifiers == .command else { return .ignored }
            focus = .search; return .handled
        }
    }

    private func sidebar(_ snapshot: ChatSidebarSnapshot) -> some View {
        VStack(spacing: 0) {
            organization(snapshot)
            if case .ready = snapshot.state { searchField }
            tree(snapshot)
            Spacer(minLength: 0)
            if case .ready = snapshot.state, let me = model?.members.first(where: { $0.accountId == model?.me }) {
                account(me)
            }
        }
    }

    private func organization(_ snapshot: ChatSidebarSnapshot) -> some View {
        let orgName = snapshot.state == .notConnected || snapshot.state == .checking ? "This Mac" : model?.orgName ?? "This Mac"
        let connection = ChatConnectionStatus(snapshot: snapshot.state, service: ChatService.shared.state, socket: ChatService.shared.socket?.state)
        return Button { organizationMenu = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "building.2.crop.circle")
                    .font(.system(size: 23)).foregroundStyle(ChatSidebarStyle.attention)
                    .frame(width: 32, height: 32)
                    .background(ChatSidebarStyle.attention.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ChatSidebarStyle.attention.opacity(0.22)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(orgName).font(Theme.display(14, weight: .semibold)).lineLimit(2)
                    ChatConnectionLabel(status: connection)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(ChatSidebarStyle.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatFocusRing()
        .foregroundStyle(Theme.chromeForeground)
        .padding(.horizontal, 16).padding(.top, 17).padding(.bottom, 15)
        .accessibilityLabel("Organization and connection")
        .accessibilityValue("\(orgName), \(connection.text)")
        .popover(isPresented: $organizationMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                if case .ready = snapshot.state, let me = model?.members.first(where: { $0.accountId == model?.me }) {
                    Text("\(me.name) · @\(me.handle)").font(Theme.display(12))
                    Divider()
                }
                Button("Organization…") { organizationMenu = false; OrganizationTabs.show() }
                Button("Change Connection…") { organizationMenu = false; ConnectionTabs.shared.show() }
                Button("Close") { organizationMenu = false }.keyboardShortcut(.cancelAction)
            }.padding(16).foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
                .preferredColorScheme(Theme.chromeColorScheme)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).accessibilityHidden(true)
            TextField("Find a channel or agent", text: $navigation.query)
                .textFieldStyle(.plain).font(Theme.display(10)).focused($focus, equals: .search)
                .accessibilityLabel("Filter channels and agents by name")
                .onKeyPress(.downArrow) { focus = .tree; navigation.selection = keyboardRows(snapshot).first?.id; return .handled }
                .onKeyPress(.escape) { navigation.query = ""; focus = .tree; return .handled }
        }
        .foregroundStyle(ChatSidebarStyle.secondary)
        .padding(.horizontal, 8).frame(height: 32)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focus == .search ? ChatSidebarStyle.accent : borderColor))
        .padding(.horizontal, 15).padding(.bottom, 13)
    }

    private func savedViews(_ snapshot: ChatSidebarSnapshot) -> some View {
        VStack(spacing: 0) {
            inboxRow(.unread, badge: ChatSidebarSnapshot.unreadLabel(snapshot.unread))
            inboxRow(.mentions, badge: snapshot.mentions > 0 ? "@\(snapshot.mentions)" : nil)
            if snapshot.incomplete {
                Text("From loaded history").font(Theme.display(10)).foregroundStyle(ChatSidebarStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9).padding(.top, 4)
            }
        }.padding(.horizontal, 12)
    }

    private func inboxRow(_ value: ChatInboxKind, badge: String?) -> some View {
        let ref = model?.key.map { ChatInboxRef($0, kind: value) }
        let selected = ref != nil && store.active?.activeSession?.inbox == ref
        return Button {
            guard let ref, case .ready = ref.state(model) else { return }
            navigation.filter = .all
            store.showInbox(ref)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: value.symbol).frame(width: 17).accessibilityHidden(true)
                Text(value.title).font(Theme.display(12))
                Spacer(minLength: 0)
                if let badge { ChatSidebarBadge(text: badge, mention: value == .mentions) }
            }.padding(.horizontal, 9).frame(minHeight: 34)
                .background(selected ? Theme.chromeSelection : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(ChatSidebarStyle.secondary)
            .chatFocusRing().accessibilityLabel(value.title).accessibilityValue(badge ?? "0")
            .accessibilityHint(selected ? "Selected. Show message list." : "Open message list in a tab")
            .accessibilityIdentifier("chat-inbox-\(value.rawValue)")
    }

    private func tree(_ snapshot: ChatSidebarSnapshot) -> some View {
        let teams = snapshot.filteredTeams(query: navigation.query, filter: navigation.filter)
        let agents = remoteAgents(snapshot)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    AttentionSidebarSection(store: store, model: attention, title: "Attention")
                    if case .ready = snapshot.state {
                        heading("Channels")
                        savedViews(snapshot)
                        ForEach(teams) { team in teamSection(team) }
                        if let key = model?.key { ChatDMSidebarSection(store: store, key: key) }
                    } else if snapshot.state == .checking {
                        caption(model?.notice ?? "Team content is hidden while access is checked.")
                    } else if snapshot.state == .noChannels {
                        caption("This server has no channels.")
                    }
                    AgentProfilesSection(store: store, history: profileHistory, sharedProfiles: localPublications(snapshot).profiles,
                        disconnected: snapshot.state == .notConnected || snapshot.state == .checking,
                        selection: focus == .tree ? navigation.selection : nil, select: { navigation.selection = $0 })
                        .padding(.top, 18)
                    if snapshot.agentsServed, navigation.filter == .all, !agents.isEmpty || !filtering {
                        sectionHeading(.agents, title: "Team agents")
                            .padding(.top, 24).id(ChatSidebarRowID.agents)
                        if expanded(.agents) {
                            ForEach(agents) { agent in agentRow(agent) }
                            if agents.isEmpty { caption("No agents available") }
                        }
                    }
                    if filtering && teams.isEmpty && agents.isEmpty { caption("No matches") }
                    AllSessionsSidebarLink(store: store).padding(.top, 16).id(ChatSidebarRowID.allSessions).overlay(focusBorder(.allSessions))
                    if snapshot.state == .notConnected || snapshot.state == .checking {
                        ChatDisconnectedRow()
                        if ChatService.shared.state == .signedIn {
                            Button("Connect a team") { ConnectionTabs.shared.show() }.buttonStyle(.plain).padding(10)
                        }
                    }
                    if case .ready = snapshot.state, let model = model {
                        ForEach(model.channelRefusals, id: \.id) { item in
                            caption("\(item.title): \(item.reason).")
                        }
                        if !model.channelRefusals.isEmpty {
                            Button("Dismiss") { model.dismissRefusals(Set(model.channelRefusals.map(\.id))) }
                                .buttonStyle(.borderless).padding(8)
                        }
                        if let notice = model.notice { caption(notice) }
                    }
                }.padding(.horizontal, 12).padding(.bottom, 20)
            }
            .focusable().focused($focus, equals: .tree).focusEffectDisabled()
            .accessibilityLabel("Unified sidebar")
            .onChange(of: store.agentProfileRevealRevision) { _, _ in
                if let id = store.revealedAgentProfileID { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                mapLocalProfiles()
                if let id = store.revealedAgentProfileID { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: TeamService.shared.calls.agents) { _, _ in mapLocalProfiles() }
            .onChange(of: ChatService.shared.publishRevision) { _, _ in mapLocalProfiles() }
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return]) { press in
                guard press.modifiers.isEmpty, focus == .tree else { return .ignored }
                let key: ChatSidebarKeyboard.Key
                switch press.key {
                case .upArrow: key = .up
                case .downArrow: key = .down
                case .leftArrow: key = .left
                case .rightArrow: key = .right
                default: key = .enter
                }
                handle(key, snapshot)
                if let selected = navigation.selection { proxy.scrollTo(selected, anchor: nil) }
                return .handled
            }
            .onChange(of: keyboardRows(snapshot).map(\.id)) { _, ids in
                if let selected = navigation.selection, !ids.contains(selected) { navigation.selection = ids.first }
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(Theme.display(11, weight: .semibold)).foregroundStyle(ChatSidebarStyle.secondary)
            .padding(.horizontal, 7).padding(.top, 18).padding(.bottom, 6)
    }

    private func mapLocalProfiles() {
        do {
            try store.agentProfiles.mapPublications(TeamService.shared.calls.agents)
            try ChatService.shared.rememberProfilePublications(store.agentProfiles)
        }
        catch { store.agentProfiles.report(error) }
    }

    private func localPublications(_ snapshot: ChatSidebarSnapshot) -> LocalProfilePublications {
        let remembered = store.agentProfiles.details.archive.confirmedPublications ?? []
        guard case .ready = snapshot.state, let key = model?.key else {
            return .init(profiles: Set(remembered.map(\.profileID)))
        }
        var current = ChatService.shared.localProfilePublications(store.agentProfiles, key: key, agents: snapshot.agents)
        current.profiles.formUnion(remembered.filter { $0.scope != OrgKey(key) }.map(\.profileID))
        return current
    }

    private func remoteAgents(_ snapshot: ChatSidebarSnapshot) -> [ChatSidebarSnapshot.Agent] {
        let local = localPublications(snapshot).agents
        return snapshot.filteredAgents(query: navigation.query, filter: navigation.filter).filter { !local.contains($0.id) }
    }

    private func teamSection(_ team: ChatSidebarSnapshot.Team) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                sectionHeading(.team(team.id), title: team.card.name + (team.card.archived ? " · archived" : ""))
                if let model = model, model.canCreateChannel(in: team.card) {
                    Button {
                        setExpanded(.team(team.id), true)
                        ChatSidebarActions.newChannel(in: team.card, model, from: store)
                    } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).foregroundStyle(ChatSidebarStyle.secondary).chatFocusRing()
                    .help("Create a channel in \(team.card.name)").accessibilityLabel("Create a channel in \(team.card.name)")
                }
            }.id(ChatSidebarRowID.team(team.id))
            if expanded(.team(team.id)) {
                ForEach(team.channels) { channel in channelRow(channel) }
                ForEach(Array(team.creating.enumerated()), id: \.offset) { _, name in caption("#\(name) — creating…") }
                if team.channels.isEmpty && team.creating.isEmpty { caption("No channels") }
            }
        }.padding(.top, 24)
    }

    private func sectionHeading(_ id: ChatSidebarRowID, title: String) -> some View {
        Button { navigation.selection = id; setExpanded(id, !expanded(id)) } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded(id) ? "chevron.down" : "chevron.right").font(.system(size: 9)).accessibilityHidden(true)
                Text(title).font(Theme.display(11, weight: .medium)).lineLimit(2)
                Spacer(minLength: 0)
            }.padding(.horizontal, 6).frame(minHeight: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(ChatSidebarStyle.secondary)
            .overlay(focusBorder(id)).chatFocusRing()
            .accessibilityValue(expanded(id) ? "Expanded" : "Collapsed")
            .accessibilityHint("Left and right arrows collapse or expand this section")
    }

    private func channelRow(_ channel: ChatSidebarSnapshot.Channel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            channelButton(channel)
            if renamingChannel?.channelId == channel.id, channelNameEdit.isEditing {
                InlineNameField(edit: channelNameEdit, label: "Channel name") { value in
                    guard let model, model.key == renamingKey, let original = renamingChannel,
                          model.visibleChannel(channel.id) == original else { return "The channel changed. Start Rename again." }
                    if let problem = ChatOrgModel.channelNameProblem(value) { return problem }
                    do { try model.renameChannel(original, to: value); return nil } catch { return error.localizedDescription }
                }.padding(.horizontal, 12)
            }
        }
    }


    private func channelButton(_ channel: ChatSidebarSnapshot.Channel) -> some View {
        let id = ChatSidebarRowID.channel(channel.id)
        let selected = model?.key.map { active == ChannelRef($0, channel: channel.id) } == true
        let unreadStatus = channel.isUnread ? "Unread. " : ""
        let archivedStatus = channel.card.archived ? "Archived. " : ""
        let selectedStatus = selected ? "Selected. " : ""
        let unreadMessages = channel.unreadLabel.map { "\($0) unread messages. " } ?? ""
        let accessibilityValue = "\(unreadStatus)\(archivedStatus)\(selectedStatus)\(unreadMessages)\(channel.mentions) unread mentions"
        return Button { navigation.selection = id; open(channel.id) } label: {
            HStack(alignment: .top, spacing: 9) {
                Text("#").font(Theme.display(19)).foregroundStyle(ChatSidebarStyle.secondary).frame(width: 17).accessibilityHidden(true)
                Text(channel.card.name).font(Theme.display(12, weight: channel.isUnread ? .semibold : .regular))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                if channel.card.archived { Image(systemName: "archivebox").font(.system(size: 10)).help("Archived: read only") }
                if let count = channel.unreadLabel { ChatSidebarBadge(text: count).accessibilityLabel("Unread messages: \(count)") }
                if let mentions = channel.mentionLabel {
                    ChatSidebarBadge(text: mentions, mention: true).accessibilityLabel("\(channel.mentions) unread mentions from loaded history")
                }
            }.padding(.leading, 13).padding(.trailing, 9).padding(.vertical, 6).frame(minHeight: 34)
                .background(selected ? Theme.chromeSelection : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(ChatSidebarRowStyle()).foregroundStyle(channel.isUnread || selected ? Theme.chromeForeground : ChatSidebarStyle.secondary)
            .overlay(focusBorder(id)).chatFocusRing().id(id)
            .help("#\(channel.card.name)" + (channel.card.archived ? " · Archived: read only" : ""))
            .accessibilityLabel("#\(channel.card.name)")
            .accessibilityValue(accessibilityValue)
            .contextMenu { channelMenu(channel.id) }
    }

    @ViewBuilder private func channelMenu(_ id: String) -> some View {
        if let model = model, let card = model.visibleChannel(id) {
            Button("Open in New Tab") { open(id, newTab: true) }
            if let unread = model.unread(id) {
                Button(unread.muted ? "Unmute Thread Replies" : "Mute Thread Replies") { model.setMuted(id, !unread.muted) }
            }
            if model.canRenameChannel(card) { Button("Rename…") { channelNameEdit.handle(.escape, save: { _ in nil }); renamingChannel = card; renamingKey = model.key; channelNameEdit.begin(card.name) } }
            if model.canArchiveChannel(card) { Button("Archive…") { ChatSidebarActions.archiveChannel(card, model, from: store) } }
            let addable = model.addableAgents(card)
            if !addable.isEmpty {
                Menu("Add Agent") {
                    ForEach(addable, id: \.agentId) { agent in
                        Button("\(agent.name)…") { ChatSidebarActions.addAgent(agent, to: card, model) }
                    }
                }
            }
            let removable = model.agents(in: id).filter(model.canRemoveAgent)
            if !removable.isEmpty {
                Menu("Remove Agent") {
                    ForEach(removable) { agent in
                        Button("\(agent.address ?? agent.name)…") { ChatSidebarActions.removeAgent(agent, from: card, model) }
                    }
                }
            }
        }
    }

    private func agentRow(_ agent: ChatSidebarSnapshot.Agent) -> some View {
        let id = ChatSidebarRowID.agent(agent.id)
        return Button { navigation.selection = id; openAgent(agent.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                ContactAvatar(stableID: agent.id, name: agent.name, kind: .agent, size: 23, remote: .agent(agent.id, model?.key))
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(Theme.display(11)).lineLimit(2)
                    Text(agentCaption(agent)).font(Theme.display(9)).foregroundStyle(ChatSidebarStyle.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text("BOT").font(Theme.mono(9)).foregroundStyle(ChatSidebarStyle.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(borderColor))
            }.padding(.horizontal, 9).padding(.vertical, 6).frame(minHeight: 34).contentShape(Rectangle())
        }.buttonStyle(ChatSidebarRowStyle()).foregroundStyle(Theme.chromeForeground).overlay(focusBorder(id)).chatFocusRing().id(id)
            .help("\(agent.name) · Owner: \(agent.owner) · \(agentCaption(agent))")
            .accessibilityLabel("\(agent.name), BOT, owner \(agent.owner), \(agentCaption(agent))")

    }

    private func openAgent(_ id: String) {
        guard let key = model?.key else { return }
        CompositionTabs.shared.agent(id, key: key, channel: active?.channel, from: store)
    }

    private func agentCaption(_ agent: ChatSidebarSnapshot.Agent) -> String {
        [agent.mine ? "You" : agent.owner, agent.device ?? (agent.mine ? "Another Mac" : nil),
         agent.enabled ? (agent.available ? nil : "Unavailable") : "Disabled"].compactMap { $0 }.joined(separator: " · ")
    }

    private func account(_ me: ChatOrgView.Member) -> some View {
        HStack(spacing: 9) {
            Button { SupportTabs.shared.settings(.profile) } label: {
                HStack(spacing: 9) {
            ContactAvatar(stableID: me.accountId, name: me.name, kind: .person, size: 27, remote: .account(me.accountId, model?.key))
            VStack(alignment: .leading, spacing: 2) {
                Text(me.name).font(Theme.display(11, weight: .medium)).lineLimit(1)
                Text("@\(me.handle)").font(Theme.display(10)).foregroundStyle(ChatSidebarStyle.secondary).lineLimit(1)
            }
                }
            }.buttonStyle(.plain).chatFocusRing().help("Edit account photo")
            Spacer(minLength: 0)
            Button { OrganizationTabs.show() } label: { Image(systemName: "gearshape").frame(width: 28, height: 28) }
                .buttonStyle(.plain).chatFocusRing().help("Account and organization").accessibilityLabel("Account and organization")
        }.foregroundStyle(Theme.chromeForeground).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Theme.chromeSeparator).frame(height: 1) }
            .padding(.horizontal, 16)
    }

    private var borderColor: Color { contrast == .increased ? Theme.chromeForeground.opacity(0.5) : Theme.chromeHairline }
    private func focusBorder(_ id: ChatSidebarRowID) -> some View {
        RoundedRectangle(cornerRadius: 6).strokeBorder(focus == .tree && navigation.selection == id ? ChatSidebarStyle.accent : .clear, lineWidth: 2)
            .allowsHitTesting(false)
    }
    private func caption(_ text: String) -> some View {
        Text(text).font(Theme.display(10)).foregroundStyle(ChatSidebarStyle.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(9)
    }
    private func expanded(_ id: ChatSidebarRowID) -> Bool {
        if case .profile(let id) = id { return store.expandedAgentProfiles.contains(id) }
        if filtering { return !navigation.filterCollapsed.contains(id) }
        guard let key = model?.key else { return false }
        switch id {
        case .team(let team): return !store.chatSidebarPreferences.collapsed.contains(.init(key, team: team))
        case .agents: return !store.chatSidebarPreferences.collapsed.contains(.init(key, team: nil))
        default: return false
        }
    }
    private func setExpanded(_ id: ChatSidebarRowID, _ value: Bool) {
        if case .profile(let id) = id {
            if value { store.expandedAgentProfiles.insert(id) } else { store.expandedAgentProfiles.remove(id) }
            return
        }
        if filtering {
            if value { navigation.filterCollapsed.remove(id) } else { navigation.filterCollapsed.insert(id) }
            return
        }
        guard let key = model?.key else { return }
        switch id {
        case .team(let team): store.setChatSectionCollapsed(.init(key, team: team), !value)
        case .agents: store.setChatSectionCollapsed(.init(key, team: nil), !value)
        default: break
        }
    }
    private func keyboardRows(_ snapshot: ChatSidebarSnapshot) -> [ChatSidebarKeyboard.Row] {
        var rows: [ChatSidebarKeyboard.Row] = []
        for team in snapshot.filteredTeams(query: navigation.query, filter: navigation.filter) {
            let id = ChatSidebarRowID.team(team.id)
            rows.append(.init(id: id, expanded: expanded(id)))
            if expanded(id) { rows += team.channels.map { .init(id: .channel($0.id), parent: id) } }
        }
        let shared = localPublications(snapshot).profiles
        let profiles = store.agentProfiles.profiles.sorted {
            if shared.contains($0.id) != shared.contains($1.id) { return shared.contains($0.id) }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        for profile in profiles {
            let id = ChatSidebarRowID.profile(profile.id)
            rows.append(.init(id: id, expanded: expanded(id)))
            if expanded(id) {
                let items = store.profileSessionItems(profile), limit = store.profileHistoryLimits[profile.id] ?? 5
                rows += AgentProfileSessions.page(items, limit: limit).map { .init(id: .history(profile.id, $0.id), parent: id) }
                if items.count > limit { rows.append(.init(id: .more(profile.id), parent: id)) }
            }
        }
        let agents = remoteAgents(snapshot)
        if snapshot.agentsServed, navigation.filter == .all, !agents.isEmpty || !filtering {
            rows.append(.init(id: .agents, expanded: expanded(.agents)))
            if expanded(.agents) { rows += agents.map { .init(id: .agent($0.id), parent: .agents) } }
        }
        rows.append(.init(id: .allSessions))
        return rows
    }
    private func handle(_ key: ChatSidebarKeyboard.Key, _ snapshot: ChatSidebarSnapshot) {
        switch ChatSidebarKeyboard.route(key, selection: navigation.selection, rows: keyboardRows(snapshot)) {
        case .select(let id): navigation.selection = id
        case .expand(let id, let expanded): setExpanded(id, expanded)
        case .activate(.channel(let id)): open(id)
        case .activate(.agent(let id)): openAgent(id)
        case .activate(.profile(let id)): store.activateAgentProfile(id)
        case .activate(.history(let id, let item)):
            if let profile = store.agentProfiles.profile(id), let row = store.profileSessionItems(profile).first(where: { $0.id == item }) {
                store.openProfileSession(row, profileID: id)
            }
        case .activate(.more(let id)): store.profileHistoryLimits[id, default: 5] += 5
        case .activate(.allSessions): SupportTabs.shared.navigation.open(.allSessions, from: store)
        default: break
        }
    }
    private func resetFilteredFocus() { navigation.selection = nil; navigation.agentID = nil; navigation.filterCollapsed = [] }
    private func open(_ id: String, newTab: Bool = false) {
        guard let model = model, let key = model.key, model.visibleChannel(id) != nil else { return }
        store.showChannel(ChannelRef(key, channel: id), newTab: newTab)
    }
    private func openCreated() {
        guard let model = model, let key = model.key else { return }
        for ref in navigation.toOpen where ref.belongs(to: key) && model.visibleChannel(ref.channel) != nil {
            navigation.toOpen.remove(ref)
            store.showChannel(ref)
        }
    }
}

private struct ChatSidebarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hover(configuration: configuration)
    }
    private struct Hover: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false
        var body: some View {
            configuration.label.background(hovered || configuration.isPressed ? Theme.chromeHover : .clear,
                                           in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
        }
    }
}
