import AgentPadTelegram
import SwiftUI

struct TelegramListEntryView: View {
    let list: TelegramListSnapshot
    let store: WorkspaceStore
    var model: TelegramChatsModel
    var folders: SidebarFoldersModel
    var viewport: SidebarFolderViewport
    var selection: ChatSidebarRowID?
    var select: (ChatSidebarRowID) -> Void
    var body: some View {
        ForEach(Array(stride(from: 0, to: list.capacity, by: 50)), id: \.self) { start in
            LazyVStack(spacing: 0) {
                if let page = model.listPages[list.key]?[start] {
                    ForEach(Array(page.rows.filter { ($0.listPosition ?? start) < list.capacity }.prefix(max(0, list.capacity - start)))) { row in
                        let id = ChatSidebarRowID.entryItem(entry: SidebarFolderEntry.telegramID(list.key), item: SidebarItemReference.telegram(row.id.chat).stableID)
                        TelegramFolderRow(row: row, store: store, model: model, folders: folders,
                            entryID: SidebarFolderEntry.telegramID(list.key), selected: selection == id) { select(id) }.id(id)
                    }
                } else {
                    Color.clear.frame(height: CGFloat(min(50, list.capacity - start)) * 39)
                        .accessibilityLabel("Loading Telegram chats")
                }
            }.folderViewport(.telegram(list.key, start), tracker: viewport, telegram: model, folders: folders)
        }
        if list.counts.rows == 0 {
            Text(list.key == .main && list.complete ? "No chats yet · Find a chat ⌘P" : "No chats")
                .font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).padding(8)
        }
        if !list.complete { Text("Updating…").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).padding(8) }
    }
}

struct TelegramFolderRow: View {
    var row: TelegramChatRow
    let store: WorkspaceStore
    var model: TelegramChatsModel
    var folders: SidebarFoldersModel
    var entryID: String
    var folder: SidebarCustomFolder?
    var selected = false
    var select: () -> Void = {}
    @Environment(\.colorSchemeContrast) private var contrast
    private var caption: String {
        if folder != nil, case .paused = model.snapshot.state { return "Offline · saved chat" }
        return row.folderCaption
    }
    var body: some View {
        Button { select(); TelegramTabs.open(row, from: store) } label: {
            HStack(spacing: 8) {
                Image(systemName: row.symbol).font(.system(size: 13)).foregroundStyle(ChatAppearance.accent)
                    .frame(width: 23, height: 23).background(ChatAppearance.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(row.title).font(Theme.display(11, weight: row.unreadCount > 0 || row.markedUnread ? .semibold : .regular)).lineLimit(1)
                        if folder != nil { SidebarFolderTag(text: "TG") }
                    }
                    Text(caption).font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    if folder == nil, row.pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
                    if row.attention != nil { SidebarAttentionDot() }
                    if row.muted { Image(systemName: "bell.slash").font(.system(size: 9)) }
                    if row.unreadCount > 0 { SidebarUnreadBadge(count: row.unreadCount, unmuted: !row.muted) }
                    else if row.markedUnread {
                        Circle().fill(row.muted ? ChatAppearance.secondary : ChatAppearance.accent).frame(width: 6, height: 6)
                            .overlay(Circle().strokeBorder(contrast == .increased ? Theme.chromeForeground : .clear))
                    }
                }.foregroundStyle(ChatAppearance.secondary)
            }.frame(height: 39).padding(.horizontal, 6).contentShape(Rectangle())
                .background(store.active?.activeSession?.toolRoute == .telegram(row.id) ? Theme.chromeSelection : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).foregroundStyle(Theme.chromeForeground)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? ChatAppearance.accent : .clear, lineWidth: 2))
            .help("\(row.title) · \(caption)")
            .accessibilityLabel(row.folderAccessibility(caption: caption, showPin: folder == nil))
            .accessibilityValue(store.active?.activeSession?.toolRoute == .telegram(row.id) ? "Selected" : "")
            .sidebarContextMenu(selected: selected) { menu }
            .addToFolderAnchor(.telegram(row.id.chat), windowID: store.windowID, anchor: entryID)
            .onDrag { SidebarDragRegistry.provider(.init(item: .telegram(row.id.chat), binding: model.snapshot.binding)) }
    }
    @ViewBuilder var menu: some View {
        Button("Open") { TelegramTabs.open(row, from: store) }
        Button("Open in New Tab") { TelegramTabs.open(row, from: store, newTab: true) }
        TelegramChatActions(row: row, model: model, windowID: store.windowID, anchor: entryID)
        if let folder { Button("Remove from \"\(folder.name)\"") { folders.remove(.telegram(row.id.chat), from: folder.id) } }
        Button("Don't show in AgentPad") { Task { await model.mode(row, .hidden) } }
        Divider()
        Text(model.shownIn(row)).font(Theme.display(10)).disabled(true)
    }
}

extension TelegramChatRow {
    var folderCaption: String {
        let time = lastMessageDate > 0 ? relativeActivityLabel(Date(timeIntervalSince1970: Double(lastMessageDate))) : "no activity"
        return "\(displayKind) · \(time)" + (lastOutgoing ? " · You" : "")
    }
    func folderAccessibility(caption: String, showPin: Bool) -> String {
        "\(title), \(displayKind), \(caption), \(unreadCount) unread"
            + (markedUnread ? ", marked unread" : "") + (pinned && showPin ? ", pinned in Telegram" : "")
            + (muted ? ", muted" : "") + (attention != nil ? ", in Needs attention" : "")
    }
}
