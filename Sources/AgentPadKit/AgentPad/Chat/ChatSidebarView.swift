import AppKit
import AgentPadTelegram
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
    var includesNewWorkspace = false

    var body: some View {
        let mentions = model?.mentionsForBadge ?? 0
        VStack(spacing: 0) {
            Rectangle().fill(Theme.chromeSeparator).frame(height: 1)
            let layout = compact ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
            layout {
                if includesNewWorkspace { NewWorkspaceDropZone(store: store, isCompact: compact) }
                if !store.leftNavigation.railVisible {
                    mode(.workspaces, title: "Workspaces", icon: "rectangle.stack")
                }
                mode(.files, title: "Files", icon: "folder")
                mode(.team, title: "Team", icon: "person.2", badge: teamNeedsAttention ? "•" : nil)
                mode(.chat, title: "Chat", icon: "bubble.left.and.bubble.right",
                     badge: mentions > 0 ? "\(mentions)" : nil)
            }.padding(.horizontal, compact ? 4 : 9).padding(.top, 9).padding(.bottom, 12)
        }
    }

    private var teamNeedsAttention: Bool {
        AttentionLedger.shared.events.contains { event in
            event.kind.needsDecision && [.decisions, .failure, .account].contains(event.kind.category)
        }
    }

    private func mode(_ content: SidebarContent, title: String, icon: String, badge: String? = nil) -> some View {
        let active = content != .workspaces && store.sidebarContent == content && store.panelIsPresented
        return Button {
            if content == .workspaces { store.openWorkspaceList() }
            else if let panel = LeftNavigationPreferences.Panel(rawValue: content.rawValue) { store.selectNavigationPanel(panel) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17))
                    .foregroundStyle(active ? ChatSidebarStyle.accent : ChatSidebarStyle.secondary)
                if !compact { Text(title).font(Theme.display(9, weight: active ? .semibold : .regular)) }
            }
            .frame(maxWidth: .infinity).frame(height: compact ? 40 : 48)
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
    @State var organizationMenu = false
    @State var channelNameEdit = InlineNameEdit()
    @State var renamingChannel: ChatChannelCard?
    @State var renamingKey: ChatOrgKey?
    @FocusState var focus: SidebarFocusRegion?
    @State var folders = SidebarFoldersModel()
    @State var folderViewport = SidebarFolderViewport()
    var telegram = TelegramService.chats
    var peopleSource: (ChatOrgKey) -> ChatDMPeopleInput = { key in
        ChatService.shared.dmAllowed(key) ? ChatService.shared.dmList(key)?.peopleInput ?? .init() : .init()
    }
    @State var hoveredEntry: String?
    @State var heldLists = Set<TelegramListKey>()
    @State var sidebarWindow = WindowBox()
    @Environment(\.colorSchemeContrast) var contrast

    var active: ChannelRef? { store.active?.activeSession?.channel }
    var snapshot: ChatSidebarSnapshot { ChatSidebarSnapshot(model: model, active: active) }
    var filtering: Bool { !navigation.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || navigation.filter != .all }

    var body: some View {
        let snapshot = snapshot
        sidebar(snapshot)
        .task(id: ChatOrgCurrent.identity()) {
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
            if value == .folders, navigation.selection == nil { navigation.selection = keyboardRows(snapshot).first?.id }
        }
        .onChange(of: navigation.focusRequested, initial: true) { _, requested in
            if requested { focus = .folders; navigation.focusRequested = false }
        }
        // Scoped to this focus subtree: terminal Cmd-F remains untouched.
        .onKeyPress(characters: CharacterSet(charactersIn: "f")) { press in
            guard press.modifiers == .command else { return .ignored }
            focus = .search; return .handled
        }
    }

    func sidebar(_ snapshot: ChatSidebarSnapshot) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                organization(snapshot)
                AttentionSidebarSection(store: store, model: attention, telegram: telegram, alwaysShowsHeader: true, maximumHeight: geometry.size.height * 0.4)
                    .focusable().focused($focus, equals: .attention).focusEffectDisabled()
                searchField
                folderTree(snapshot)
                folderFooter
                if case .ready = snapshot.state, let me = model?.members.first(where: { $0.accountId == model?.me }) { account(me) }
            }
        }
        .background(WindowReader(box: sidebarWindow))
        .onKeyPress(keys: [.tab]) { press in
            guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
            focus = SidebarFocusRegion.next(focus, backwards: press.modifiers == .shift)
            return .handled
        }
        .sheet(isPresented: $folders.sheetPresented) {
            FoldersSheet(model: folders, entries: folderEntries(snapshot, includeHidden: true), telegram: telegram) { folders.sheetPresented = false }
        }
    }

    func organization(_ snapshot: ChatSidebarSnapshot) -> some View {
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
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
        .accessibilityLabel("Organization and connection")
        .accessibilityValue("\(orgName), \(connection.text)")
        .attentionPopover(isPresented: $organizationMenu, arrowEdge: .bottom) {
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

    var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).accessibilityHidden(true)
            TextField("Find a channel or agent", text: $navigation.query)
                .textFieldStyle(.plain).font(Theme.display(10)).focused($focus, equals: .search)
                .accessibilityLabel("Filter channels and agents by name")
                .onKeyPress(.downArrow) { focus = .folders; navigation.selection = keyboardRows(snapshot).first?.id; return .handled }
                .onKeyPress(.escape) { navigation.query = ""; focus = .folders; return .handled }
        }
        .foregroundStyle(ChatSidebarStyle.secondary)
        .padding(.horizontal, 8).frame(height: 28)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focus == .search ? ChatSidebarStyle.accent : borderColor))
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
    }

    func savedViews(_ snapshot: ChatSidebarSnapshot, entry: String) -> some View {
        VStack(spacing: 0) {
            inboxRow(.unread, badge: ChatSidebarSnapshot.unreadLabel(snapshot.unread))
                .id(ChatSidebarRowID.folderInbox(entry, .unread)).overlay(focusBorder(.folderInbox(entry, .unread)))
            inboxRow(.mentions, badge: snapshot.mentions > 0 ? "@\(snapshot.mentions)" : nil)
                .id(ChatSidebarRowID.folderInbox(entry, .mentions)).overlay(focusBorder(.folderInbox(entry, .mentions)))
            if snapshot.incomplete {
                Text("From loaded history").font(Theme.display(10)).foregroundStyle(ChatSidebarStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9).padding(.top, 4)
            }
        }.padding(.horizontal, 12)
    }

    func inboxRow(_ value: ChatInboxKind, badge: String?) -> some View {
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

    func heading(_ title: String) -> some View {
        Text(title).font(Theme.display(11, weight: .semibold)).foregroundStyle(ChatSidebarStyle.secondary)
            .padding(.horizontal, 7).padding(.top, 18).padding(.bottom, 6)
    }

    func mapLocalProfiles() {
        do {
            try store.agentProfiles.mapPublications(TeamService.shared.calls.agents)
            try ChatService.shared.rememberProfilePublications(store.agentProfiles)
        }
        catch { store.agentProfiles.report(error) }
    }

    func localPublications(_ snapshot: ChatSidebarSnapshot) -> LocalProfilePublications {
        let remembered = store.agentProfiles.details.archive.confirmedPublications ?? []
        guard case .ready = snapshot.state, let key = model?.key else {
            return .init(profiles: Set(remembered.map(\.profileID)))
        }
        var current = ChatService.shared.localProfilePublications(store.agentProfiles, key: key, agents: snapshot.agents)
        current.profiles.formUnion(remembered.filter { $0.scope != OrgKey(key) }.map(\.profileID))
        return current
    }

    func remoteAgents(_ snapshot: ChatSidebarSnapshot) -> [ChatSidebarSnapshot.Agent] {
        let local = localPublications(snapshot).agents
        return snapshot.filteredAgents(query: navigation.query, filter: navigation.filter).filter { !local.contains($0.id) }
    }

    func channelRow(_ channel: ChatSidebarSnapshot.Channel, entry: String, folder: SidebarCustomFolder? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            channelButton(channel, entry: entry, folder: folder)
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


    func channelButton(_ channel: ChatSidebarSnapshot.Channel, entry: String, folder: SidebarCustomFolder?) -> some View {
        let item = SidebarItemSummary.channel(channel, scope: model!.key!).reference
        let id = ChatSidebarRowID.entryItem(entry: entry, item: item.stableID)
        let selected = model?.key.map { active == ChannelRef($0, channel: channel.id) } == true
        let unreadStatus = channel.isUnread ? "Unread. " : ""
        let archivedStatus = channel.card.archived ? "Archived · read only. " : ""
        let selectedStatus = selected ? "Selected. " : ""
        let unreadMessages = channel.unreadLabel.map { "\($0) unread messages. " } ?? ""
        let accessibilityValue = "\(unreadStatus)\(archivedStatus)\(selectedStatus)\(unreadMessages)\(channel.mentions) unread mentions"
        return Button { navigation.selection = id; open(channel.id) } label: {
            HStack(alignment: .top, spacing: 9) {
                Text("#").font(Theme.display(19)).foregroundStyle(ChatSidebarStyle.secondary).frame(width: 17).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.card.name).font(Theme.display(11, weight: channel.isUnread ? .semibold : .regular)).lineLimit(1)
                    if folder != nil {
                        Text(channel.card.archived ? "Archived · read only" : "Channel · " + (channel.activity.map { relativeActivityLabel($0) } ?? "no activity"))
                            .font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if channel.card.archived { Image(systemName: "archivebox").font(.system(size: 10)).help("Archived: read only") }
                if channel.mentions > 0 { SidebarAttentionDot() }
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
            .sidebarContextMenu(selected: focus == .folders && navigation.selection == id) {
                channelMenu(channel.id)
                folderItemActions(item, entry: entry, folder: folder)
            }
            .addToFolderAnchor(item, windowID: store.windowID, anchor: entry)
            .onDrag { SidebarDragRegistry.provider(.init(item: item, binding: folders.snapshot.binding)) }
    }

    @ViewBuilder func channelMenu(_ id: String) -> some View {
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

    func agentRow(_ agent: ChatSidebarSnapshot.Agent, entry: String, folder: SidebarCustomFolder? = nil) -> some View {
        let item = SidebarItemSummary.teamAgent(agent, scope: model!.key!).reference
        let id = ChatSidebarRowID.entryItem(entry: entry, item: item.stableID)
        return Button { navigation.selection = id; openAgent(agent.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                ContactAvatar(stableID: agent.id, name: agent.name, kind: .agent, size: 23, remote: .agent(agent.id, model?.key))
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(Theme.display(11)).lineLimit(2)
                    Text(folder == nil ? agentCaption(agent) : "Team agent · no activity").font(Theme.display(9)).foregroundStyle(ChatSidebarStyle.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if agentAttention(agent.id) { SidebarAttentionDot() }
                Text("BOT").font(Theme.mono(9)).foregroundStyle(ChatSidebarStyle.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(borderColor))
            }.padding(.horizontal, 9).padding(.vertical, 6).frame(minHeight: 34).contentShape(Rectangle())
        }.buttonStyle(ChatSidebarRowStyle()).foregroundStyle(Theme.chromeForeground).overlay(focusBorder(id)).chatFocusRing().id(id)
            .help("\(agent.name) · Owner: \(agent.owner) · \(agentCaption(agent))")
            .accessibilityLabel("\(agent.name), BOT, owner \(agent.owner), \(agentCaption(agent))")
            .sidebarContextMenu(selected: focus == .folders && navigation.selection == id) {
                Button("Open") { openAgent(agent.id) }
                folderItemActions(item, entry: entry, folder: folder)
            }
            .addToFolderAnchor(item, windowID: store.windowID, anchor: entry)
            .onDrag { SidebarDragRegistry.provider(.init(item: item, binding: folders.snapshot.binding)) }

    }

    func openAgent(_ id: String) {
        guard let key = model?.key else { return }
        CompositionTabs.shared.agent(id, key: key, channel: active?.channel, from: store)
    }

    func agentCaption(_ agent: ChatSidebarSnapshot.Agent) -> String {
        [agent.mine ? "You" : agent.owner, agent.device ?? (agent.mine ? "Another Mac" : nil),
         agent.enabled ? (agent.available ? nil : "Unavailable") : "Disabled"].compactMap { $0 }.joined(separator: " · ")
    }

    func account(_ me: ChatOrgView.Member) -> some View {
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

    var borderColor: Color { contrast == .increased ? Theme.chromeForeground.opacity(0.5) : Theme.chromeHairline }
    func focusBorder(_ id: ChatSidebarRowID) -> some View {
        RoundedRectangle(cornerRadius: 6).strokeBorder(focus == .folders && navigation.selection == id ? ChatSidebarStyle.accent : .clear, lineWidth: 2)
            .allowsHitTesting(false)
    }
    func caption(_ text: String) -> some View {
        Text(text).font(Theme.display(10)).foregroundStyle(ChatSidebarStyle.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(9)
    }
    func resetFilteredFocus() { navigation.selection = nil; navigation.agentID = nil; navigation.filterCollapsed = [] }
    func open(_ id: String, newTab: Bool = false) {
        guard let model = model, let key = model.key, model.visibleChannel(id) != nil else { return }
        store.showChannel(ChannelRef(key, channel: id), newTab: newTab)
    }
    func openCreated() {
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
