import SwiftUI

struct AttentionSidebarSection: View {
    @Bindable var store: WorkspaceStore
    var model = AttentionSidebarModel.shared
    var telegram = TelegramService.chats
    var title = "Needs attention"
    var alwaysShowsHeader = false
    var maximumHeight: CGFloat? = nil
    @State private var interactionID = UUID()
    @State private var interactionHeld = false
    @State private var window = WindowBox()
    var body: some View {
        AttentionSectionContent(title: title + (model.projection.telegram.attentionNewCount > 0 ? " · \(model.projection.telegram.attentionNewCount) new" : ""),
            items: model.items, telegram: telegram, total: model.total, revealedTotal: model.projection.revealedCount, alwaysShowsHeader: alwaysShowsHeader, maximumHeight: maximumHeight,
            collapsed: Binding(get: { store.chatSidebarPreferences.attentionCollapsed ?? false },
                               set: { store.chatSidebarPreferences.attentionCollapsed = $0; store.scheduleSave() }),
            expanded: $store.attentionExpanded,
            activate: { model.activate($0, from: store) }, secondary: model.secondary,
            settings: { SupportTabs.shared.navigation.open(.settings, from: store, section: .notifications) },
            itemTitle: model.title, loadMore: { await telegram.expandAttention() },
            viewportChanged: { telegram.attentionViewport($0, owner: interactionID) }, windowID: store.windowID, interactionChanged: { held in
                interactionHeld = held
                let id = interactionID
                Task { await telegram.holdAttention(held, owner: id) }
            })
            .background(WindowReader(box: window))
            .onDisappear {
                let id = interactionID
                telegram.attentionViewport([], owner: id)
                Task { await telegram.holdAttention(false, owner: id) }
            }
            .onChange(of: store.panelIsPresented) { _, presented in
                let id = interactionID, held = presented && interactionHeld
                Task { await telegram.holdAttention(held, owner: id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
                if (notification.object as? NSWindow) === window.view?.window {
                    let id = interactionID; Task { await telegram.holdAttention(false, owner: id) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                if (notification.object as? NSWindow) === window.view?.window {
                    let id = interactionID, held = interactionHeld && store.panelIsPresented
                    Task { await telegram.holdAttention(held, owner: id) }
                }
            }
    }
}

struct AttentionSectionContent: View {
    var title = "Needs attention"
    var items: [AttentionItem]
    var telegram = TelegramService.chats
    var total: Int? = nil
    var revealedTotal: Int? = nil
    var alwaysShowsHeader = false
    var maximumHeight: CGFloat? = nil
    @Binding var collapsed: Bool
    @Binding var expanded: Bool
    var activate: (AttentionItem) -> Void
    var secondary: (AttentionItem) -> Void
    var settings: () -> Void
    var itemTitle: (AttentionItem) -> String = { $0.title }
    var loadMore: () async -> Void = {}
    var viewportChanged: (Set<Int64>) -> Void = { _ in }
    var windowID: UUID?
    var interactionChanged: (Bool) -> Void = { _ in }
    @FocusState private var focused: String?
    @State private var hovered: String?
    @State private var regionHovered = false
    @State private var loadingMore = false

    var body: some View {
        if alwaysShowsHeader || (total ?? items.count) > 0 || !items.isEmpty {
            let visible = AttentionList.visible(items, expanded: expanded, collapsed: collapsed)
            // Closed reasons keep their geometry during a hold, but do not
            // consume the live total used by the expansion control.
            let shownActiveCount = visible.filter { $0.telegramPlaceholder != .inactive }.count
            let shownCount = expanded ? revealedTotal ?? shownActiveCount : shownActiveCount
            let controls = !collapsed ? ((total ?? items.count) > shownCount ? 28 : 0) + (expanded ? 28 : 0) : 0
            let contentHeight = CGFloat(visible.count * 39 + controls)
            let scrollHeight = max(0, min(contentHeight, (maximumHeight ?? .infinity) - 49))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Button { collapsed.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 9))
                            Text(title).font(Theme.display(11, weight: .semibold))
                            Text("\(total ?? items.count)").monospacedDigit().font(Theme.display(10))
                        }
                    }.buttonStyle(.plain).accessibilityValue(collapsed ? "Collapsed" : "Expanded")
                    Spacer(minLength: 0)
                    Button(action: settings) { Image(systemName: "gearshape").font(.system(size: 11)) }
                        .buttonStyle(.plain).help("Needs attention settings").accessibilityLabel("Needs attention settings")
                }.foregroundStyle(ChatAppearance.attention).padding(.horizontal, 7).padding(.vertical, 6)
                ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { item in
                        if let placeholder = item.telegramPlaceholder {
                            if placeholder == .inactive {
                                Text("No longer needs attention").font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary)
                                    .padding(.horizontal,7).frame(height: 39)
                            } else {
                                Color.clear.frame(height: 39).accessibilityLabel("Loading Telegram attention")
                            }
                        } else {
                            let title = itemTitle(item)
                            HStack(spacing: 3) {
                                Button { activate(item) } label: {
                                    HStack(spacing: 8) {
                                        if case .telegram(let summary) = item.action {
                                            Image(systemName: summary.kind == .direct ? "person" : "person.2")
                                                .font(.system(size: 13)).foregroundStyle(ChatAppearance.accent)
                                                .frame(width: 24, height: 24).background(ChatAppearance.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                                        } else if let id = item.subjectID, !id.isEmpty {
                                            ContactAvatar(stableID: id, name: item.subjectName ?? title,
                                                          kind: item.subjectIsAgent ? .agent : .person, size: 24, localProfileID: item.localProfileID, remote: item.remoteAvatar)
                                        } else {
                                            Image(systemName: item.tier == 3 ? "at" : item.tier == 2 ? "exclamationmark.triangle" : "hand.raised")
                                                .font(.system(size: 14)).frame(width: 24)
                                                .foregroundStyle(item.tier == 2 ? Color.red : ChatAppearance.attention)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 4) {
                                                Text(title).font(Theme.display(11, weight: .medium)).lineLimit(1)
                                                if item.telegramChat != nil { SidebarFolderTag(text: "TG") }
                                            }
                                            Text(item.subtitle.isEmpty ? "Needs your attention" : item.subtitle)
                                                .font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary).lineLimit(2)
                                        }
                                        Spacer(minLength: 0)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(item.inFlight).focused($focused, equals: item.id)
                                    .accessibilityLabel("\(item.subtitle), \(title)").chatFocusRing()
                                if let action = item.secondary {
                                    Button { secondary(item) } label: {
                                        Image(systemName: action == .dismiss ? "xmark" : action == .snooze ? "moon" : "checkmark").font(.system(size: 10))
                                    }.buttonStyle(.plain).help(action.rawValue).accessibilityLabel(action.rawValue)
                                        .opacity(hovered == item.id || focused == item.id ? 1 : 0)
                                }
                            }.padding(.horizontal, 7).frame(height: 39)
                                .background(hovered == item.id ? Theme.chromeSelection : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .onHover { hovered = $0 ? item.id : nil }
                                .sidebarContextMenu(selected: focused == item.id) {
                                    if let action = item.secondary { Button(action.rawValue) { secondary(item) } }
                                    if case .telegram(let summary) = item.action, let row = telegram.loadedRow(summary.destination) {
                                        TelegramChatActions(row: row, model: telegram, windowID: windowID, anchor: "attention:" + item.id)
                                    }
                                }
                                .addToFolderAnchor(item.telegramChat.map(SidebarItemReference.telegram), windowID: windowID, anchor: "attention:" + item.id)
                        }
                    }
                }.scrollTargetLayout()
                if !collapsed && (total ?? items.count) > shownCount {
                    Button(loadingMore ? "Loading…" : "Show \((total ?? items.count) - shownCount) more") {
                        loadingMore = true
                        Task { await loadMore(); expanded = true; loadingMore = false }
                    }.disabled(loadingMore)
                        .buttonStyle(.plain).font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).padding(7)
                }
                if !collapsed && expanded {
                    Button("Show less") { expanded = false }
                        .buttonStyle(.plain).font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).padding(7)
                }
                }.frame(height: scrollHeight)
                    .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
                        let visible = Set(ids)
                        viewportChanged(Set(items.filter { visible.contains($0.id) }.compactMap(\.telegramChat)))
                    }
                    .onDisappear { viewportChanged([]) }
                    .mask {
                        VStack(spacing: 0) {
                            if contentHeight > scrollHeight { LinearGradient(colors: [.clear,.black], startPoint: .top, endPoint: .bottom).frame(height: 5) }
                            Rectangle().fill(.black)
                            if contentHeight > scrollHeight { LinearGradient(colors: [.black,.clear], startPoint: .top, endPoint: .bottom).frame(height: 5) }
                        }
                    }
            }.padding(5)
                .background(ChatAppearance.attention.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ChatAppearance.attention.opacity(0.25)))
                .padding(.horizontal, 8).padding(.bottom, 7)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Needs attention, pinned, \(total ?? items.count) items")
                // A metadata refresh can replace a row with a placeholder. The
                // hover hold belongs to the region and survives that replacement.
                .onChange(of: focused) { _, _ in interactionChanged(focused != nil || regionHovered) }
                .onHover { regionHovered = $0; interactionChanged(focused != nil || $0) }
                .onMoveCommand { direction in
                    let focusable = visible.filter { $0.telegramPlaceholder == nil }
                    guard direction == .up || direction == .down, !focusable.isEmpty else { return }
                    let index = focusable.firstIndex { $0.id == focused } ?? (direction == .down ? -1 : focusable.count)
                    focused = focusable[min(focusable.count - 1, max(0, index + (direction == .down ? 1 : -1)))].id
                }
        }
    }
}
