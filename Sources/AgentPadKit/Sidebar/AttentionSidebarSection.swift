import SwiftUI

struct AttentionSidebarSection: View {
    @Bindable var store: WorkspaceStore
    var model = AttentionSidebarModel.shared
    var title = "Needs attention"
    var body: some View {
        AttentionSectionContent(title: title, items: model.items,
            collapsed: Binding(get: { store.chatSidebarPreferences.attentionCollapsed ?? false },
                               set: { store.chatSidebarPreferences.attentionCollapsed = $0; store.scheduleSave() }),
            expanded: $store.attentionExpanded,
            activate: { model.activate($0, from: store) }, secondary: model.secondary,
            settings: { SupportTabs.shared.navigation.open(.settings, from: store, section: .notifications) })
    }
}

struct AttentionSectionContent: View {
    var title = "Needs attention"
    var items: [AttentionItem]
    @Binding var collapsed: Bool
    @Binding var expanded: Bool
    var activate: (AttentionItem) -> Void
    var secondary: (AttentionItem) -> Void
    var settings: () -> Void
    @FocusState private var focused: String?
    @State private var hovered: String?

    var body: some View {
        if !items.isEmpty {
            let visible = AttentionList.visible(items, expanded: expanded, collapsed: collapsed)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Button { collapsed.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 9))
                            Text(title).font(Theme.display(11, weight: .semibold))
                            Text("\(items.count)").monospacedDigit().font(Theme.display(10))
                        }
                    }.buttonStyle(.plain).accessibilityValue(collapsed ? "Collapsed" : "Expanded")
                    Spacer(minLength: 0)
                    Button(action: settings) { Image(systemName: "gearshape").font(.system(size: 11)) }
                        .buttonStyle(.plain).help("Needs attention settings").accessibilityLabel("Needs attention settings")
                }.foregroundStyle(ChatAppearance.attention).padding(.horizontal, 7).padding(.vertical, 6)
                ForEach(visible) { item in
                    HStack(spacing: 3) {
                        Button { activate(item) } label: {
                            HStack(spacing: 8) {
                                if let id = item.subjectID, !id.isEmpty {
                                    ContactAvatar(stableID: id, name: item.subjectName ?? item.title,
                                                  kind: item.subjectIsAgent ? .agent : .person, size: 24, localProfileID: item.localProfileID, remote: item.remoteAvatar)
                                } else {
                                    Image(systemName: item.tier == 3 ? "at" : item.tier == 2 ? "exclamationmark.triangle" : "hand.raised")
                                        .font(.system(size: 14)).frame(width: 24)
                                        .foregroundStyle(item.tier == 2 ? Color.red : ChatAppearance.attention)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(Theme.display(12, weight: .medium)).lineLimit(1)
                                    Text(item.subtitle.isEmpty ? "Needs your attention" : item.subtitle)
                                        .font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(item.inFlight).focused($focused, equals: item.id)
                            .accessibilityLabel("\(item.subtitle), \(item.title)").chatFocusRing()
                        if let action = item.secondary {
                            Button { secondary(item) } label: {
                                Image(systemName: action == .dismiss ? "xmark" : "checkmark").font(.system(size: 10))
                            }.buttonStyle(.plain).help(action.rawValue).accessibilityLabel(action.rawValue)
                                .opacity(hovered == item.id || focused == item.id ? 1 : 0)
                        }
                    }.padding(.horizontal, 7).padding(.vertical, 5)
                        .background(hovered == item.id ? Theme.chromeSelection : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .onHover { hovered = $0 ? item.id : nil }
                        .contextMenu {
                            if let action = item.secondary { Button(action.rawValue) { secondary(item) } }
                        }
                }
                if !collapsed && (items.count > visible.count || expanded) {
                    Button(expanded ? "Show less" : "Show \(items.count - visible.count) more") { expanded.toggle() }
                        .buttonStyle(.plain).font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).padding(7)
                }
            }.padding(5)
                .background(ChatAppearance.attention.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ChatAppearance.attention.opacity(0.25)))
                .padding(.horizontal, 8).padding(.bottom, 7)
                .onMoveCommand { direction in
                    guard direction == .up || direction == .down, !visible.isEmpty else { return }
                    let index = visible.firstIndex { $0.id == focused } ?? (direction == .down ? -1 : visible.count)
                    focused = visible[min(visible.count - 1, max(0, index + (direction == .down ? 1 : -1)))].id
                }
        }
    }
}
