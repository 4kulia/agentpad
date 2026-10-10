import SwiftUI

struct ChatDMSidebarSection: View {
    let store: WorkspaceStore
    let key: ChatOrgKey
    var service: ChatService = .shared
    @State private var limit = 8
    @State private var expanded = true
    var body: some View {
        if service.dmAllowed(key), let model = service.dmList(key) {
            let entries = model.people, visible = ChatDMPerson.visible(entries, limit: limit, expanded: expanded)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                            Text("People").font(Theme.display(11, weight: .semibold))
                        }
                    }.buttonStyle(.plain).chatFocusRing()
                    Spacer()
                    Button { SupportTabs.shared.navigation.open(.newDM(OrgKey(key)), from: store) } label: { Image(systemName: "plus").frame(width: 26, height: 26) }
                        .disabled(service.socket?.state != .connected).buttonStyle(.plain).help("New direct message").accessibilityLabel("New direct message").chatFocusRing()
                }.foregroundStyle(ChatAppearance.secondary).padding(.horizontal, 7)
                if expanded || entries.contains(where: \.unread) {
                    ForEach(visible) { row in
                        Button { ChatDMTabs.open(key, peer: row.id, from: store, service: service) } label: {
                            HStack(spacing: 8) {
                                ContactAvatar(stableID: row.id, name: row.peer.name, kind: .person, size: 27, remote: .account(row.id, key))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.peer.name).font(Theme.display(12, weight: row.unread ? .semibold : .regular)).lineLimit(1)
                                    if !row.hasMessages { Text("No messages yet").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary) }
                                    else if !row.writable { Text("Read-only").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary) }
                                }
                                Spacer(minLength: 2)
                                if row.roots.muted { Image(systemName: "bell.slash").font(.system(size: 9)).foregroundStyle(ChatAppearance.secondary) }
                                if let badge = row.badge { ChatSidebarBadge(text: badge, mention: !row.roots.muted) }
                            }.padding(.horizontal, 7).padding(.vertical, 6)
                                .background(store.active?.activeSession?.toolRoute == row.route(key) ? Theme.chromeSelection : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).chatFocusRing().accessibilityLabel(row.peer.name)
                            .help("Unread roots: \(row.roots.count)\(row.roots.more ? "+" : ""). Unread replies: \(row.replies). Counts include loaded history only.")
                    }
                    if expanded && visible.count < entries.count {
                        Button("Show more…") { limit += 8 }.buttonStyle(.plain).font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary).padding(8)
                    }
                    if expanded && limit > 8 { Button("Show less") { limit = 8 }.buttonStyle(.plain).font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary).padding(8) }
                }
            }.padding(.top, 18)
        }
    }
}
